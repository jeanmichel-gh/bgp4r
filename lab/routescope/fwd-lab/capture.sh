#!/usr/bin/env bash
# Checks that packets follow the routes four bgp4rd routers install, on a
# deployed fwd-lab, and prints what each router answers along the way.
#
# A pings D from its loopback. Which way the packets went is read twice:
# from traceroute, for a person, and from C's eth1 receive counter, for
# the check, since every packet through C arrives there. Then the B to D
# link goes down and up, the session is stopped and started, and D is
# cut off, each with the time it took.
#
# Each check prints one `CHECK ok` or `CHECK FAIL` line. The script
# prints everything and exits 1 at the end if any check failed.
#
# It changes the running lab and puts it back. CI runs it
# (.github/workflows/capture.yml). Its twin with no containers is
# test/functional/lab/fwd_lab_netns_test.rb.
#
#   LAB=fwd-lab lab/routescope/fwd-lab/capture.sh
set -uo pipefail
LAB="${LAB:-fwd-lab}"
SOCK=/run/bgp4r/bgp4rd.sock
A_LO=10.255.0.1
D_LO=10.255.0.4
DIRECT=10.200.4.2
VIA_C=10.200.2.2
PINGS=50

ex() { docker exec "clab-$LAB-$1" "${@:2}"; }
cli() { ex "$1" ruby -I/app exe/bgp4r-cli -s "$SOCK" "${@:2}"; }
rshow() { echo "===== $1 bgp4r-cli $2 ${3:-}"; cli "$1" "$2" ${3:+"$3"} 2>&1; echo; }
show() { echo "===== $1 $2"; ex "$1" sh -c "$2" 2>&1; echo; }

FAILED=0
# check WHAT FUNCTION: the function must return 0. What it prints, the
# times and the ping counts, goes above the CHECK line.
check() {
  local out rc
  out=$("$2" 2>&1); rc=$?
  [ -n "$out" ] && echo "$out"
  if [ $rc = 0 ]; then echo "CHECK ok   $1"; else echo "CHECK FAIL $1"; FAILED=1; fi
}

next_hop() { ex "$1" ip route get "$2" 2>/dev/null | sed -n 's/.* via \([^ ]*\).*/\1/p'; }
c_rx() { ex c cat /sys/class/net/eth1/statistics/rx_packets; }
# Pings D from A's loopback; prints "received through_c".
ping_d() {
  local before after got
  before=$(c_rx)
  got=$(ex a ping -q -c $PINGS -i 0.02 -W 1 -I $A_LO $D_LO 2>&1 | sed -n 's/.* \([0-9]*\) received.*/\1/p')
  after=$(c_rx)
  echo "${got:-0} $((after - before))"
}
direct() { read -r got c <<<"$(ping_d)"; echo "  $got of $PINGS answered, $c packets through c"; [ "$got" = $PINGS ] && [ "$c" -lt $((PINGS / 5)) ]; }
via_c() { read -r got c <<<"$(ping_d)"; echo "  $got of $PINGS answered, $c packets through c"; [ "$got" = $PINGS ] && [ "$c" -ge $PINGS ]; }
trace() { show a "traceroute -n -q 1 -w 1 -s $A_LO $D_LO"; }

# wait_until SECONDS NODE DEST WANT: polls the kernel's next hop, prints
# the seconds it took, and fails when it never came.
wait_until() {
  local t0 t1 i
  t0=$(date +%s.%N)
  for i in $(seq 1 $(($1 * 5))); do
    [ "$(next_hop "$2" "$3")" = "$4" ] && { t1=$(date +%s.%N); echo "  $2 next hop for $3 is ${4:-none} after $(awk "BEGIN { printf \"%.1f\", $t1 - $t0 }")s"; return 0; }
    sleep 0.2
  done
  echo "  $2 next hop for $3 never became ${4:-none}; it is $(next_hop "$2" "$3")"
  return 1
}

all_up() {
  for n in a b c d; do
    cli "$n" show.peers 2>/dev/null | ruby -rjson -e 'd = JSON.parse(STDIN.read) rescue exit(1); exit(d.all? { |p| p["state"] == "established" } && !d.empty? ? 0 : 1)' || return 1
  done
}

echo "### waiting for the four routers"
for i in $(seq 1 60); do all_up && break; sleep 3; done
all_up || { echo "the sessions did not come up"; for n in a b c d; do rshow $n show.peers; done; exit 1; }

echo "### versions and forwarding"
rshow a api.info
for n in a b c d; do show $n 'cat /proc/sys/net/ipv4/ip_forward'; done
forwarding() { for n in b c d; do [ "$(ex $n cat /proc/sys/net/ipv4/ip_forward)" = 1 ] || return 1; done; }
check 'b, c and d forward' forwarding

echo "### the direct link"
learned() { wait_until 60 a $D_LO 10.200.1.2 && wait_until 30 b $D_LO $DIRECT && wait_until 30 d $A_LO 10.200.4.1; }
check 'a learns d, and b and d prefer the direct link' learned
for n in a b c d; do rshow $n show.fib; show $n 'ip route show proto bgp'; done
rshow b show.rib '{"prefix":"10.255.0.4/32"}'
b_decided() { cli b show.rib '{"prefix":"10.255.0.4/32"}' | ruby -rjson -e 'r = JSON.parse(STDIN.read)["rows"][0]; exit(r["decided_by"].to_s == "as_path_length" && r["paths"].size == 2 ? 0 : 1)'; }
check 'b holds two paths to d and chose on as_path_length' b_decided
b_skips_own() { cli b show.fib | ruby -rjson -e 'f = JSON.parse(STDIN.read)["fib"]; exit(f["skipped"] == [{"prefix" => "10.255.0.2/32", "reason" => "originated"}] && f["failed"].empty? ? 0 : 1)'; }
check 'b installs no route for its own loopback, and nothing failed' b_skips_own
trace
check 'a pings d over the direct link' direct

echo "### b to d link down"
ex b ip link set eth3 down
failover() { wait_until 20 b $D_LO $VIA_C && wait_until 20 d $A_LO 10.200.3.1; }
check 'link down: b and d route through c within the hold time' failover
rshow a show.rib '{"prefix":"10.255.0.4/32"}'
trace
check 'a pings d through c' via_c

echo "### b to d link up"
ex b ip link set eth3 up
restore() { wait_until 40 b $D_LO $DIRECT && wait_until 30 d $A_LO 10.200.4.1; }
check 'link up: the direct link wins again' restore
trace
check 'a pings d over the direct link again' direct

echo "### b stops its session to d"
cli b peer.stop "{\"peer\":\"$DIRECT\"}"
fast() { wait_until 5 b $D_LO $VIA_C; }
check 'peer.stop: b routes through c with no hold timer to wait' fast
check 'a pings d through c' via_c
cli b peer.start "{\"peer\":\"$DIRECT\"}"
check 'peer.start: the direct link wins again' restore

echo "### d cut off"
ex d ip link set eth1 down
ex d ip link set eth2 down
# Not `ip route get`: a containerlab node has a default route out of its
# management interface, eth0, so the lookup answers that gateway once
# the BGP route is gone. Measured on the first CI run. The check is that
# no route for the /32 is left in the main table.
gone() {
  local i
  for i in $(seq 1 125); do
    [ -z "$(ex a ip route show exact $D_LO/32)" ] && { echo "  a has no route for $D_LO/32"; return 0; }
    sleep 0.2
  done
  echo "  a still has: $(ex a ip route show exact $D_LO/32)"
  return 1
}
check 'a withdraws d when d has no link' gone
no_answer() { read -r got c <<<"$(ping_d)"; [ "$got" = 0 ]; }
check 'no ping answered' no_answer
ex d ip link set eth1 up
ex d ip link set eth2 up
back() { wait_until 60 a $D_LO 10.200.1.2 && wait_until 30 b $D_LO $DIRECT; }
check 'd back: learned again over the direct link' back
check 'a pings d over the direct link once more' direct

[ "$FAILED" = 0 ] || { echo "### at least one forwarding check failed"; exit 1; }
