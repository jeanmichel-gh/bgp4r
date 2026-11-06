#!/usr/bin/env bash
# Prints what every router in rr-lab answers about reflected routes, and
# checks the RFC 4456 facts the scenario language cannot assert:
# ORIGINATOR_ID and CLUSTER_LIST, as FRR, BIRD, GoBGP and bgp4rd each
# read them, the refusals rr1 records, and the step dual decided on.
#
# CI runs it on a deployed lab (.github/workflows/capture.yml). Each read
# is one block, in bgp4r-lab's capture.sh format:
#
#   ===== c1 vtysh show bgp ipv4 unicast 10.10.1.0/24 json
#   ...the answer...
#
# Each check prints one `CHECK ok` or `CHECK FAIL` line. The script prints
# everything first and exits 1 at the end if any check failed, so a
# failing run still carries the output that says why.
#
# It changes the running lab: it announces from the three injectors and
# replays two looped UPDATEs, then flaps inj-c. Run it on a lab you can
# redeploy.
#
#   LAB=rr-lab lab/routescope/rr-lab/capture.sh
set -uo pipefail
LAB="${LAB:-rr-lab}"
SOCK=/run/bgp4r/bgp4rd.sock

# The two UPDATEs scenarios/cluster-loop-is-dropped.yml and
# scenarios/originator-loop-is-dropped.yml replay. rr_lab_topology_test.rb
# holds these to the scenario files and decodes them.
CLUSTER_LOOP=ffffffffffffffffffffffffffffffff0037020000001c400101004002004003040a64010140050400000064800a0401010101180a0a06
ORIGINATOR_LOOP=ffffffffffffffffffffffffffffffff0037020000001c400101004002004003040a640101400504000000648009040a64ff02180a0a07

ex() { docker exec "clab-$LAB-$1" "${@:2}"; }
vt() { ex "$1" vtysh -c "$2"; }
vshow() { echo "===== $1 vtysh $2"; vt "$1" "$2" 2>&1; echo; }
bshow() { echo "===== $1 birdc $2"; ex "$1" birdc "$2" 2>&1; echo; }
cli() { ex "$1" ruby -I/app exe/bgp4r-cli -s "$SOCK" "${@:2}"; }
rshow() { echo "===== $1 bgp4r-cli $2 ${3:-}"; cli "$1" "$2" ${3:+"$3"} 2>&1; echo; }
sget() { ex "$1" ruby -rnet/http -e "print Net::HTTP.get(URI('http://127.0.0.1:8080' + ARGV[0]))" "$2"; }
sshow() { echo "===== $1 sim GET $2"; sget "$1" "$2" 2>&1; echo; }
spost() {
  ex "$1" ruby -rnet/http -e 'r = Net::HTTP.post(URI("http://127.0.0.1:8080" + ARGV[0]), ARGV[1], "X-BGP4R" => "routescope"); puts r.code, r.body; exit(r.code.start_with?("2") ? 0 : 1)' "$2" "$3" \
    || { echo "$1 refused POST $2"; exit 1; }
}
gshow() { echo "===== $1 gobgp $2"; ex "$1" sh -c "gobgp -u 127.0.0.1 -p 50051 $2" 2>&1; echo; }

FAILED=0
# check WHAT FUNCTION: the function must return 0.
check() {
  if "$2" >/dev/null 2>&1; then echo "CHECK ok   $1"; else echo "CHECK FAIL $1"; FAILED=1; fi
}
# A Ruby predicate over JSON on standard input, run on the CI host. The
# parsed answer is `d`; a missing key fails the check rather than raising.
jq_rb() { ruby -rjson -e "d = (JSON.parse(STDIN.read) rescue exit(1)); exit((begin; $1; rescue StandardError; false; end) ? 0 : 1)"; }

frr_path() { vt "$1" "show bgp ipv4 unicast $2 json"; }
bird_path() { ex "$1" birdc "show route all for $2"; }
gobgp_path() { ex "$1" sh -c "gobgp -u 127.0.0.1 -p 50051 global rib $2 -j"; }
rr_rib() { cli "$1" show.rib "{\"prefix\":\"$2\"}"; }

all_up() {
  cli rr1 show.peers 2>/dev/null | jq_rb 'Array(d).size == 8 && Array(d).all? { |p| p["state"] == "established" }'
}

echo "### waiting for rr1's eight sessions"
for i in $(seq 1 60); do all_up && break; sleep 3; done
all_up || { echo "rr1's sessions did not come up"; cli rr1 show.peers; exit 1; }
for i in $(seq 1 30); do
  cli dual show.peers 2>/dev/null | jq_rb 'Array(d).size == 2 && Array(d).all? { |p| p["state"] == "established" }' && break
  sleep 2
done

echo "### versions"
vshow rr2 'show version'
bshow c2 'show status'
echo "===== c3 gobgp --version"; ex c3 gobgp --version 2>&1; echo
echo "===== rr1 bgp4r-cli api.info"; cli rr1 api.info 2>&1; echo

echo "### changing the running lab"
spost inj-c /api/announce '{"prefixes":["10.10.1.0/24"]}'
spost inj-n /api/announce '{"prefixes":["10.10.2.0/24"]}'
spost inj-e /api/announce '{"prefixes":["10.20.3.0/24"]}'
spost inj-c /api/replay "{\"hex\":\"$CLUSTER_LOOP\"}"
spost inj-c /api/replay "{\"hex\":\"$ORIGINATOR_LOOP\"}"
arrived() {
  bird_path c2 10.10.1.0/24 | grep -q 'BGP.cluster_list' &&
    bird_path c2 10.20.3.0/24 | grep -q unicast &&
    rr_rib dual 10.10.1.0/24 | jq_rb 'd["rows"][0]["paths"].size == 2'
}
for i in $(seq 1 30); do arrived && break; sleep 2; done
sleep 5

echo "### bgp4rd, the reflector"
rshow rr1 show.status
rshow rr1 show.peers
rshow rr1 show.routes
rshow rr1 show.rib '{"prefix":"10.10.1.0/24"}'
rshow rr1 show.adj_in '{"peer":"10.100.1.1"}'
rshow rr1 show.adj_out '{"peer":"10.100.20.2"}'
rshow rr1 show.adj_out '{"peer":"10.100.11.2"}'

echo "### bgp4rd, the client of both reflectors"
rshow dual show.peers
rshow dual show.rib '{"prefix":"10.10.1.0/24"}'
rshow dual show.rib '{"prefix":"10.20.3.0/24"}'

echo "### FRR"
for n in rr2 c1; do
  vshow $n 'show bgp summary json'
  vshow $n 'show bgp ipv4 unicast json'
  vshow $n 'show bgp ipv4 unicast 10.10.1.0/24 json'
  vshow $n 'show bgp ipv4 unicast 10.10.2.0/24 json'
  vshow $n 'show bgp ipv4 unicast 10.20.3.0/24 json'
done
vshow rr2 'show bgp ipv4 unicast neighbors 10.100.21.2 advertised-routes json'

echo "### BIRD"
for c in 'show protocols all' 'show route all' \
  'show route all for 10.10.1.0/24' 'show route all for 10.20.3.0/24'; do
  bshow c2 "$c"
done

echo "### GoBGP"
gshow c3 'neighbor -j'
gshow c3 'global rib -j'
gshow c3 'global rib 10.10.1.0/24 -j'
gshow c3 'global rib 10.20.3.0/24 -j'

echo "### bgp4r-sim"
for n in inj-c inj-n inj-e; do
  sshow $n /api/status
  sshow $n /api/sent
done

echo "### RFC 4456, as each implementation read it"
# Each predicate is a function, so check can run it in this shell.

rr1_role() { cli rr1 show.status | jq_rb 'd["route_reflector"] == true && d["cluster_id"] == "1.1.1.1"'; }
check 'rr1 says it is a reflector in cluster 1.1.1.1' rr1_role

# Client to client, with both attributes, on each reader.
c1_client_route() { frr_path c1 10.10.1.0/24 | jq_rb 'p = d["paths"][0]; p["originatorId"] == "10.100.255.11" && p["clusterList"]["list"] == ["1.1.1.1"] && p["nexthops"][0]["ip"] == "10.100.1.1"'; }
check 'c1, FRR: 10.10.1.0/24 with ORIGINATOR_ID inj-c, CLUSTER_LIST 1.1.1.1, next hop unchanged' c1_client_route
c2_originator() { bird_path c2 10.10.1.0/24 | grep -q 'BGP.originator_id: 10.100.255.11'; }
check 'c2, BIRD: 10.10.1.0/24 with ORIGINATOR_ID inj-c' c2_originator
c2_cluster() { bird_path c2 10.10.1.0/24 | grep -qE 'BGP.cluster_list: 1\.1\.1\.1\s*$'; }
check 'c2, BIRD: 10.10.1.0/24 with CLUSTER_LIST 1.1.1.1' c2_cluster
c3_client_route() { gobgp_path c3 10.10.1.0/24 | jq_rb 'a = d["10.10.1.0/24"][0]["attrs"].to_h { |x| [x["type"], x] }; a[9]["value"] == "10.100.255.11" && a[10]["value"] == ["1.1.1.1"]'; }
check 'c3, GoBGP: 10.10.1.0/24 with ORIGINATOR_ID inj-c and CLUSTER_LIST 1.1.1.1' c3_client_route

# Client to non-client.
rr2_client_route() { frr_path rr2 10.10.1.0/24 | jq_rb 'd["paths"][0]["clusterList"]["list"] == ["1.1.1.1"]'; }
check 'rr2, FRR: 10.10.1.0/24 reaches a non-client, CLUSTER_LIST 1.1.1.1' rr2_client_route

# Non-client to clients only.
c1_non_client_route() { frr_path c1 10.10.2.0/24 | jq_rb 'd["paths"][0]["originatorId"] == "10.100.255.12"'; }
check 'c1, FRR: 10.10.2.0/24 from the non-client, ORIGINATOR_ID inj-n' c1_non_client_route
rr2_no_non_client_route() { frr_path rr2 10.10.2.0/24 | jq_rb 'Array(d["paths"]).empty?'; }
check 'rr2, FRR: 10.10.2.0/24 absent, no non-client to non-client' rr2_no_non_client_route
rr1_names_refusal() { cli rr1 show.adj_out '{"peer":"10.100.20.2"}' | jq_rb 'd["skipped"]["rows"].any? { |r| r["prefix"] == "10.10.2.0/24" && r["reason"].to_s == "non_client_to_non_client" }'; }
check 'rr1 names the refusal toward rr2 as non_client_to_non_client' rr1_names_refusal

# An external route is not reflection.
c1_ebgp_route() { frr_path c1 10.20.3.0/24 | jq_rb 'p = d["paths"][0]; p["originatorId"].nil? && p["clusterList"].nil? && p["nexthops"][0]["ip"] == "10.100.3.1"'; }
check 'c1, FRR: 10.20.3.0/24 from the external peer, no ORIGINATOR_ID or CLUSTER_LIST, next hop unchanged' c1_ebgp_route
rr2_ebgp_route() { frr_path rr2 10.20.3.0/24 | jq_rb 'd["paths"].size >= 1'; }
check 'rr2, FRR: 10.20.3.0/24 reaches a non-client too' rr2_ebgp_route

# FRR reflecting into bgp4r, and the section 9 tie break.
dual_frr_reflected() { rr_rib dual 10.10.1.0/24 | jq_rb 'd["rows"][0]["paths"].any? { |p| p["from"] == "10.100.21.1" && p["cluster_list"] == ["2.2.2.2", "1.1.1.1"] && p["originator_id"] == "10.100.255.11" }'; }
check 'dual, bgp4rd: rr2 reflected 10.10.1.0/24 with CLUSTER_LIST 2.2.2.2 1.1.1.1' dual_frr_reflected
dual_tie_break() { rr_rib dual 10.10.1.0/24 | jq_rb 'r = d["rows"][0]; r["decided_by"].to_s == "cluster_list_length" && r["paths"].find { |p| p["best"] }["from"] == "10.100.14.1"'; }
check 'dual, bgp4rd: 10.10.1.0/24 decided by cluster_list_length, rr1 copy best' dual_tie_break
dual_ebgp_tie_break() { rr_rib dual 10.20.3.0/24 | jq_rb 'r = d["rows"][0]; r["decided_by"].to_s == "cluster_list_length" && r["paths"].any? { |p| p["from"] == "10.100.21.1" && p["originator_id"] == "10.100.255.2" }'; }
check 'dual, bgp4rd: 10.20.3.0/24 via rr2 carries ORIGINATOR_ID rr1 and loses on cluster_list_length' dual_ebgp_tie_break

# The two loops.
rr1_no_cluster_loop() { rr_rib rr1 10.10.6.0/24 | jq_rb 'Array(d["rows"]).empty?'; }
check 'rr1: 10.10.6.0/24, carrying CLUSTER_LIST 1.1.1.1, is not in the Loc-RIB' rr1_no_cluster_loop
rr1_no_originator_loop() { rr_rib rr1 10.10.7.0/24 | jq_rb 'Array(d["rows"]).empty?'; }
check 'rr1: 10.10.7.0/24, carrying ORIGINATOR_ID 10.100.255.2, is not in the Loc-RIB' rr1_no_originator_loop
rr1_kept_both() { cli rr1 show.adj_in '{"peer":"10.100.1.1"}' | jq_rb 'ps = d["rows"].map { |r| r["prefix"] }; ps.include?("10.10.6.0/24") && ps.include?("10.10.7.0/24")'; }
check 'rr1: both looped routes are in the Adj-RIB-In from inj-c' rr1_kept_both
c1_no_loops() { frr_path c1 10.10.6.0/24 | jq_rb 'Array(d["paths"]).empty?' && frr_path c1 10.10.7.0/24 | jq_rb 'Array(d["paths"]).empty?'; }
check 'c1, FRR: neither looped route was reflected' c1_no_loops
inj_c_up() { cli rr1 show.peers | jq_rb 'd.find { |p| p["address"] == "10.100.1.1" }["state"] == "established"'; }
check 'rr1: the session to inj-c stayed up through both loops' inj_c_up

echo "### a flap"
spost inj-c /api/session/flap '{}'
sleep 40
rshow rr1 show.peers
bshow c2 'show route all for 10.10.1.0/24'
check 'after a flap of inj-c, c2 holds 10.10.1.0/24 again' c2_originator

[ "$FAILED" = 0 ] || { echo "### at least one RFC 4456 check failed"; exit 1; }
