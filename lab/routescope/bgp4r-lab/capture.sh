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
#   - inj1 announces 10.1.0.0/24 with MED 100 and all three kinds of
#     community, and inj2 the same prefix with MED 50, so rtr holds two
#     paths and says why one won;
#   - r1 keeps what rtr sends before policy (soft reconfiguration
#     inbound), and r2 does not, so both answers are captured;
#   - r2 (FRR) and r3 (BIRD) both originate 172.16.9.0/24, so r1 holds
#     two paths to it and the exits from AS 65001 differ;
#   - the inj1 to rtr session is flapped, r1's link to rtr goes down and
#     up, and r3 restarts its session to r1, so the flap counters move.
#
#   LAB=bgp4r-lab lab/routescope/bgp4r-lab/capture.sh
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
spost() { ex "$1" ruby -rnet/http -e 'r = Net::HTTP.post(URI("http://127.0.0.1:8080" + ARGV[0]), ARGV[1], "X-BGP4R" => "capture"); puts r.code, r.body' "$2" "$3"; }
sshow() { echo "===== $1 sim GET $2"; sget "$1" "$2" 2>&1; echo; }

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
sleep 20

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
  'show route all for 172.16.9.0/24' 'show route all for 10.1.0.0/24' 'show route count'; do
  bshow r3 "$c"
done

echo "### bgp4rd"
rshow rtr show.status
rshow rtr show.peers
rshow rtr show.routes
rshow rtr show.rib '{"prefix":"10.1.0.0/24"}'
rshow rtr show.adj_in '{"peer":"10.0.10.1"}'
rshow rtr show.adj_out '{"peer":"10.0.20.2"}'

echo "### bgp4r-sim"
for n in inj1 inj2; do
  sshow $n /api/status
  sshow $n /api/peers
  sshow $n /api/sent
done

echo "### a flap"
spost inj1 /api/session.flap '{}'
ex r1 ip link set eth1 down; sleep 15; ex r1 ip link set eth1 up
ex r3 birdc 'disable r1' >/dev/null; sleep 3; ex r3 birdc 'enable r1' >/dev/null
sleep 40
vshow r1 'show bgp summary json'
vshow r1 'show bgp neighbors 10.0.20.1 json'
bshow r3 'show protocols all r1'
rshow rtr show.peers
sshow inj1 /api/peers
echo "### done"
