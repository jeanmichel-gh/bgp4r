#!/usr/bin/env bash
# The interop gate of bfd-frr-lab: bgp4rd's `bfd: true` against FRR's
# bfdd. It prints what both ends answer and one `CHECK ok` or `CHECK
# FAIL` line per fact, as rr-lab's capture.sh does, and exits 1 at the
# end if any failed, so a failing run still carries why.
#
#   1. BFD is Up on both ends and the BGP session is Established.
#   2. The link loses every packet: netem 100% on both ends' eth1. bgp4rd
#      resets the session in under a second, with a NOTIFICATION 6/10,
#      "BFD Down" (RFC 9384 section 3), sent; the hold time is 9 s.
#   3. The loss ends, and BFD and BGP come back on their own.
#
# It changes the running lab and leaves it as it found it.
#
#   LAB=bfd-frr-lab routescope/labs/bfd-frr-lab/gate.sh
set -uo pipefail
LAB="${LAB:-bfd-frr-lab}"
B="clab-$LAB-bgp"
F="clab-$LAB-frr"

FAILED=0
check() {
  if "${@:2}" >/dev/null 2>&1; then echo "CHECK ok   $1"; else echo "CHECK FAIL $1"; FAILED=1; fi
}
jq_rb() { ruby -rjson -e "d = (JSON.parse(STDIN.read) rescue exit(1)); exit((begin; $1; rescue StandardError; false; end) ? 0 : 1)"; }
peers() { docker exec "$B" bgp4r-cli show.peers; }
vt() { docker exec "$F" vtysh -c "$1"; }
show() { echo "===== $1"; shift; "$@" 2>&1; echo; }

ours_up() { peers | jq_rb 'p = d.find { |r| r["address"] == "10.0.12.2" }; p["state"] == "established" && p["bfd"] == "up"'; }
frr_bfd_up() { vt 'show bfd peer 10.0.12.1 json' | jq_rb 'd["status"] == "up"'; }
frr_bgp_up() { vt 'show bgp neighbor 10.0.12.1 json' | jq_rb 'd["10.0.12.1"]["bgpState"] == "Established"'; }
all_up() { ours_up && frr_bfd_up && frr_bgp_up; }

wait_for() {
  local n=$1; shift
  for _ in $(seq "$n"); do "$@" >/dev/null 2>&1 && return 0; sleep 0.5; done
  return 1
}

# 1. Up on both.
wait_for 120 all_up
show "bgp bgp4r-cli show.peers" peers
show "frr show bfd peer 10.0.12.1" vt 'show bfd peer 10.0.12.1'
check "bgp4rd: session Established, BFD up" ours_up
check "FRR: BFD peer 10.0.12.1 up" frr_bfd_up
check "FRR: BGP session to 10.0.12.1 Established" frr_bgp_up

# 2. The link loses everything. netem with tc in each node's network
# namespace, through nsenter, because that applies in milliseconds where
# `containerlab tools netem set` takes a few hundred: the clock below
# measures BFD and not the tool. The time the loss starts, against the
# time on bgp4rd's own log line, both from this host's clock: docker logs
# --timestamps stamps each line as the daemon wrote it.
pids_b=$(docker inspect -f '{{.State.Pid}}' "$B"); pids_f=$(docker inspect -f '{{.State.Pid}}' "$F")
since=$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)
t0=$(date +%s.%N)
sudo nsenter -t "$pids_b" -n tc qdisc replace dev eth1 root netem loss 100%
sudo nsenter -t "$pids_f" -n tc qdisc replace dev eth1 root netem loss 100%
line=""
for _ in $(seq 50); do
  line=$(docker logs --timestamps --since "$since" "$B" 2>&1 | grep -m1 'Cease 6/10 BFD Down sent')
  [ -n "$line" ] && break
  sleep 0.1
done
echo "===== bgp log"; echo "${line:-no reset line}"; echo
took=$(ruby -rtime -e 'l = ARGV[0]; exit 1 if l.empty?; printf("%.3f", Time.iso8601(l.split.first).to_f - ARGV[1].to_f)' "$line" "$t0")
echo "reset ${took:-never} s after the loss began"
under_a_second() { ruby -e 'exit(ARGV[0].to_f > 0 && ARGV[0].to_f < 1.0 ? 0 : 1)' "${took:-0}"; }
reset_by_bfd() { peers | jq_rb 'p = d.find { |r| r["address"] == "10.0.12.2" }; p["last_error"].to_s.include?("BFD Down") && p["state"] != "established"'; }
check "bgp4rd: Cease 6/10 BFD Down sent" test -n "$line"
check "bgp4rd: reset in under a second (${took:-never} s)" under_a_second
check "bgp4rd: last error BFD Down, session not Established" reset_by_bfd
show "bgp bgp4r-cli show.peers" peers
show "frr show bfd peer 10.0.12.1" vt 'show bfd peer 10.0.12.1'

# 3. The loss ends.
sudo nsenter -t "$pids_b" -n tc qdisc del dev eth1 root
sudo nsenter -t "$pids_f" -n tc qdisc del dev eth1 root
wait_for 120 all_up
check "after the loss: BFD and BGP back on both ends" all_up
show "bgp bgp4r-cli show.peers" peers

exit "$FAILED"
