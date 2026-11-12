#!/usr/bin/env bash
# Prints what every router in bgp4r-lab answers to the commands
# routescope's BGP drivers send, so routescope's unit test fixtures are
# real output and not invented. CI runs it on a deployed lab
# (.github/workflows/capture.yml) and the output goes to the job log, one
# block per command:
#
#   ===== r1 vtysh show bgp summary json
#   ...the answer...
#
# routescope's test/capture/extract.rb turns a saved log back into fixture
# files. The markers are its format: NODE, then the tool (vtysh, birdc,
# bgp4r-cli or sim), then the command.
#
# The lab is BGP only, on purpose: a lab with no IGP is a lab routescope
# has to handle, and this one has three implementations in it.
#
# Before capturing it changes the running lab, not its files, so the
# output has what the panes need to show:
#   - inj1 announces 10.1.0.0/24 and 10.2.0.0/24 with MED 100 and all
#     three kinds of community, and inj2 10.1.0.0/24 with MED 50, so rtr
#     holds two paths to it and says why inj2's won; 10.2.0.0/24 is the
#     one that carries the communities on to r3;
#   - r1 keeps what rtr sends before policy (soft reconfiguration
#     inbound), and r2 does not, so both answers are captured;
#   - r2 (FRR) and r3 (BIRD) both originate 172.16.9.0/24, so r1 holds
#     two paths to it and the exits from AS 65001 differ;
#   - the inj1 to rtr session is flapped, r1's link to rtr goes down and
#     up, and r3 restarts its session to r1, so the flap counters move.
#
#   LAB=bgp4r-lab routescope/labs/bgp4r-lab/capture.sh
set -uo pipefail
LAB="${LAB:-bgp4r-lab}"
SOCK=/run/bgp4r/bgp4rd.sock

ex() { docker exec "clab-$LAB-$1" "${@:2}"; }
vt() { ex "$1" vtysh -c "$2"; }
cfg() { local n="$1"; shift; local a=(); for l in "$@"; do a+=(-c "$l"); done; ex "$n" vtysh -c 'configure terminal' "${a[@]}" >/dev/null; }
vshow() { echo "===== $1 vtysh $2"; vt "$1" "$2" 2>&1; echo; }
bshow() { echo "===== $1 birdc $2"; ex "$1" birdc "$2" 2>&1; echo; }
# bgp4rd's control socket, the result only, as routescope's driver reads it.
cli() { ex "$1" ruby -I/app exe/bgp4r-cli -s "$SOCK" "${@:2}"; }
rshow() { echo "===== $1 bgp4r-cli $2 ${3:-}"; cli "$1" "$2" ${3:+"$3"} 2>&1; echo; }
# The injector's HTTP API on its loopback, as routescope's driver reaches it.
sget() { ex "$1" ruby -rnet/http -e "print Net::HTTP.get(URI('http://127.0.0.1:8080' + ARGV[0]))" "$2"; }
# A POST must carry X-BGP4R: routescope, the injector's one guard; a
# refusal stops the capture rather than capturing a lab with nothing in it.
spost() {
  ex "$1" ruby -rnet/http -e 'r = Net::HTTP.post(URI("http://127.0.0.1:8080" + ARGV[0]), ARGV[1], "X-BGP4R" => "routescope"); puts r.code, r.body; exit(r.code.start_with?("2") ? 0 : 1)' "$2" "$3" \
    || { echo "$1 refused POST $2"; exit 1; }
}
sshow() { echo "===== $1 sim GET $2"; sget "$1" "$2" 2>&1; echo; }
# GoBGP's own client, over the API Dockerfile.gobgp binds to the
# loopback. `-u 127.0.0.1 -p 50051` are the client's own defaults, read
# in cmd/gobgp/root.go, and are written out because they have to match
# that entrypoint's `--api-hosts` and a reader comparing the two should
# not have to check. No node here has a routescope driver yet, so the
# tool name is `gobgp` and the commands are the ones
# `LabHelper::Gobgpd` already sends, which is what such a driver would
# be built from.
gshow() { echo "===== $1 gobgp $2"; ex "$1" sh -c "gobgp -u 127.0.0.1 -p 50051 $2" 2>&1; echo; }

established() {
  vt r1 'show bgp summary json' 2>/dev/null | ruby -rjson -e '
    d = JSON.parse(STDIN.read) rescue exit(1)
    ps = d.dig("ipv4Unicast", "peers") || {}
    exit(ps.size == 3 && ps.values.all? { _1["state"] == "Established" } ? 0 : 1)'
}

echo "### waiting for r1's three sessions"
for i in $(seq 1 60); do established && break; sleep 3; done
established || { echo "r1's sessions did not come up"; vt r1 'show bgp summary'; exit 1; }

echo "### versions"
vshow r1 'show version'
bshow r3 'show status'
echo "===== rtr bgp4r-cli api.info"; cli rtr api.info 2>&1; echo

echo "### changing the running lab"
spost inj1 /api/announce '{"prefixes":["10.1.0.0/24","10.2.0.0/24"],"med":100,"communities":["65010:100","65010:200"],"extended_communities":["route_target:65010:7"],"large_communities":["65010:1:1"]}'
spost inj2 /api/announce '{"prefixes":["10.1.0.0/24"],"med":50}'
cfg r1 'router bgp 65001' 'address-family ipv4 unicast' 'neighbor 10.0.20.1 soft-reconfiguration inbound' \
  'neighbor 10.1.12.2 send-community all' 'neighbor 10.1.13.2 send-community all'
vt r1 'clear bgp 10.0.20.1 soft in' >/dev/null
cfg r2 'ip route 172.16.9.0/24 blackhole' 'router bgp 65001' 'address-family ipv4 unicast' 'network 172.16.9.0/24'
# r3 advertises nothing of its own in the lab's file; for this run it
# originates 172.16.9.0/24 too.
ex r3 sh -c 'cat >> /etc/bird/bird.conf <<EOF
protocol static capture { ipv4; route 172.16.9.0/24 blackhole; }
EOF
sed -i "s/export none;/export where proto = \"capture\";/" /etc/bird/bird.conf'
ex r3 birdc configure
# Wait for what was set up to arrive, and stop if it does not.
two_paths() { vt r1 'show bgp ipv4 unicast 172.16.9.0/24 json' | ruby -rjson -e 'exit(Array((JSON.parse(STDIN.read) rescue {})["paths"]).size == 2 ? 0 : 1)'; }
for i in $(seq 1 30); do
  ex r3 birdc show route all for 10.2.0.0/24 | grep -q 'BGP.large_community' && \
    ex r3 birdc show route all for 172.16.9.0/24 | grep -q unicast && \
    two_paths && break
  sleep 2
done
# Each router's view of the two prefixes, for when a check below fails.
why() {
  echo "### $1"
  cli rtr show.routes; echo
  vt r1 'show bgp ipv4 unicast'; vt r1 'show bgp ipv4 unicast 10.1.0.0/24'
  vt r2 'show bgp ipv4 unicast'
  ex r3 birdc show route all; ex r3 birdc show protocols all r1
  docker logs --tail 30 "clab-$LAB-r3" 2>&1
  exit 1
}
ex r3 birdc show route all for 10.2.0.0/24 | grep -q 'BGP.large_community' || why "10.2.0.0/24 did not reach r3 with its communities"
two_paths || why "r1 does not hold two paths to 172.16.9.0/24"
sleep 5

echo "### FRR"
for n in r1 r2; do
  vshow $n 'show bgp summary json'
  vshow $n 'show bgp neighbors json'
  vshow $n 'show bgp ipv4 unicast json'
  vshow $n 'show bgp ipv4 unicast detail json'
  vshow $n 'show bgp ipv4 unicast 172.16.9.0/24 json'
  vshow $n 'show bgp ipv4 unicast 10.1.0.0/24 json'
done
vshow r1 'show bgp ipv4 unicast neighbors 10.0.20.1 received-routes json'
vshow r1 'show bgp ipv4 unicast neighbors 10.0.20.1 routes json'
vshow r1 'show bgp ipv4 unicast neighbors 10.0.20.1 advertised-routes json'
vshow r1 'show bgp ipv4 unicast neighbors 10.1.12.2 advertised-routes json'
vshow r2 'show bgp ipv4 unicast neighbors 10.1.12.1 received-routes json'
vshow r2 'show bgp ipv4 unicast neighbors 10.1.12.1 routes json'

echo "### BIRD"
for c in 'show protocols all' 'show route all' \
  'show route all protocol r1' 'show route all export r1' \
  'show route all for 172.16.9.0/24' 'show route all for 10.1.0.0/24' 'show route all for 10.2.0.0/24' \
  'show route count'; do
  bshow r3 "$c"
done

echo "### bgp4rd"
rshow rtr show.status
rshow rtr show.peers
rshow rtr show.routes
rshow rtr show.rib '{"prefix":"10.1.0.0/24"}'
rshow rtr show.adj_in '{"peer":"10.0.10.1"}'
rshow rtr show.adj_out '{"peer":"10.0.20.2"}'

# The second reader of what rtr's export side sends, which is the one
# thing this node is on the topology for. It receives and originates
# nothing, so everything here came out of rtr, and nothing about
# `export` is per peer: r1 and g1 are handed the same decision from the
# same encoder. 10.2.0.0/24 is the prefix that carries all three kinds
# of community, so g1's reading of it is a second implementation's view
# of how rtr exported them.
#
# `neighbor` without -j as well as with, and the reason written here
# first was wrong, which the first run of this block showed.
# `LabHelper::Gobgpd#remote_add_path` parses the human output because
# the JSON form wraps every capability in a protobuf Any with a base64
# value, and on **4.10.0 it does not**: measured 2026-11-03, where
# `neighbor -j` prints `"local_cap":[{"Cap":{"ExtendedMessage":{}}}...]`
# readably. That helper runs against 3.23.0 as well, which is where its
# own claim was measured, so this is a version difference and not an
# error in it. Both forms are captured because the human one is the one
# that labels each capability advertised, received or both, which
# neither JSON form does.
echo "### GoBGP"
# Not through gshow: read in cmd/gobgp/main.go, `--version` is handled
# before cobra sees the arguments and only as os.Args[1], so it has to
# come first and gshow's own -u and -p would be in front of it.
echo "===== g1 gobgp --version"; ex g1 gobgp --version 2>&1; echo
gshow g1 'global -j'
gshow g1 'neighbor'
gshow g1 'neighbor 10.0.21.1'
gshow g1 'neighbor -j'
gshow g1 'neighbor 10.0.21.1 -j'
gshow g1 'global rib -j'
gshow g1 'global rib 10.1.0.0/24 -j'
gshow g1 'global rib 10.2.0.0/24 -j'
gshow g1 'neighbor 10.0.21.1 adj-in -j'

echo "### bgp4r-sim"
for n in inj1 inj2; do
  sshow $n /api/status
  sshow $n /api/peers
  sshow $n /api/sent
done

echo "### a flap"
spost inj1 /api/session/flap '{}'
ex r1 ip link set eth1 down; sleep 15; ex r1 ip link set eth1 up
ex r3 birdc 'disable r1' >/dev/null; sleep 3; ex r3 birdc 'enable r1' >/dev/null
sleep 40
vshow r1 'show bgp summary json'
vshow r1 'show bgp neighbors json'
vshow r1 'show bgp neighbors 10.0.20.1 json'
bshow r3 'show protocols all r1'
# Both programs answer routescope's status read with their peers in it,
# so the status is what the Peers pane reads after the flap.
rshow rtr show.status
rshow rtr show.peers
sshow inj1 /api/status
sshow inj1 /api/peers
echo "### done"
