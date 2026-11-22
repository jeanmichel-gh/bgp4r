---
title: L3VPN over SR-MPLS, bgp4rd and FRR as PEs
tags: [l3vpn, mpls, sr]
role: main
---
# l3vpn-lab

An L3VPN across an SR-MPLS core, with `bgp4rd` as one PE and FRR as the other (RFC 4364). AS 65000 runs IS-IS level 2 with SR-MPLS. `pe1` is isis4r plus `bgp4rd` (`pe1-bgp`, in pe1's namespace). `pe2` is FRR. The core has two paths: `p1` (isis4r, metric 10) and `p2` (FRR, metric 20). The two PEs exchange VPN routes through `p1-bgp`, a bgp4rd in p1's namespace that reflects them (RFC 4456), each peering with it from its loopback.

VRF A joins `ce1a` and `ce2a`, and VRF B joins `ce1b` and `ce2b`. Both use the same addresses, 192.168.1.0/24 and 192.168.2.0/24, kept apart by their RDs (65000:1, 65000:2) and Route Targets (65000:100, 65000:200).

It shows:
- each CE learning the other's site with AS_PATH `65000 65000`, and pe1 sending ce1a's site as a VPN route with its Site of Origin
- a ping from ce1a to ce2a crossing p1 with two labels: pe2's Node-SID in p1's block (17003) over the VPN label FRR gave (from its label manager, 16 and up; one per VRF and family)
- p1 popping the transport label toward pe2 (PHP), so only the VPN label reaches it
- the reply with one label from bgp4rd's block, 24000 for A and 24001 for B, after p1 popped 17001
- ce1b reaching ce2b on the same addresses through VRF B, while ce1a's packets never reach ce2b
- the p1 to pe2 link failing: pe1's VRF routes move to 19003, p2's label for pe2, and the pings go through p2, then come back when the link does
- the same link losing every packet while it keeps its carrier: BFD finds it, and the same failover follows
- pe2 to ce2a losing every packet: BFD resets their eBGP session in about a second, not 30
- the same on pe1 to ce1a, where pe1's end is in VRF A

IPv6 rides the same VRFs as VPN-IPv6 (RFC 4659), 2001:db8:1::/64 and 2001:db8:2::/64. bgp4rd installs pe2's IPv6 routes through p1's IPv6 link-local and sends its own; FRR receives them but cannot install them over an IPv4 next hop (10.2.1, and the master build here), so IPv6 crosses one way only. README.md has the details.

ce1a and ce2a are CEs running bgp4rd in AS 65101 by eBGP inside VRF A. Each PE replaces 65101 by 65000 in what it sends them (AS override), so each site reaches the other's loopback, 172.16.1.1 and 172.16.2.1.

`scenarios/gate.yml` checks the pings, the labels and the failover, and the VPN routes on the way: in p1-bgp's VPN table, and in each PE's VRF A with the far PE's transport label, through the failover too. README.md has the addresses, the images, and the tcpdump and vtysh commands to read the labels on the wire.

## BFD on the core link

p1 and pe2 run BFD on their link, at 300 ms x 3, a 900 ms detection time. p1's `isisd` has `bfd: true` on eth2 and runs under `with-bfdd4r`, so a `bfdd4r` answers in p1's namespace (p1-bgp shares it). pe2 runs FRR's `bfdd`, with `isis bfd` on eth1.

The gate fails the link twice. First the link goes down: both ends lose carrier and see it at once. Then it keeps its carrier and loses every packet (routescope's `netem:` step at `loss: 100%`), as a bad optic or a switch in between would. Neither end sees that. BFD does, and both IS-IS routers drop the adjacency. Without BFD, IS-IS would wait out its hold time, 3 s here (hello 1 s x 3).

Measured through routescope on ospflab on 2026-11-22, FRR master as below, two runs (recordings `20261122-052921-scenario-gate` and `20261122-053034-scenario-gate`):

| Measure | Run 1 | Run 2 |
| --- | --- | --- |
| Link down: pe1's route to pe2 on 19003 | 161 ms | 473 ms |
| Packet loss: pe1's route to pe2 on 19003 | 880 ms | 1050 ms |
| `failover`, link down | 1902 ms | 3126 ms |
| `failover_loss`, packet loss | 3409 ms | 9078 ms |
| `restore`, link up | 4135 ms | 5057 ms |
| `restore_loss`, netem cleared | 5111 ms | 4666 ms |

The first two rows are the time from the action to the first check, the route that moved. The `failover` and `restore` measures run from the action to a ping that passes, and include the VRF checks the gate makes before it, about a second each. So they say that the sites reach each other again, not how fast the routers moved. In run 2 the two VRF checks after the loss took 3.7 and 3.1 s, against under 0.9 s in run 1, with the VM's load average near 20.

## BFD on a PE to CE session

pe2 and ce2a run BFD on their eBGP session: `neighbor 192.168.2.2 bfd` in pe2's VRF A, and `bfd: true` on ce2a's neighbor. ce2a starts bgp4rd once eth1 has its address, since bgp4rd checks at start that pe2 is one hop away. A CE is single-homed, so loss on its link has no other path. The gate checks that the BFD session goes down and ce2a drops pe1's site, 172.16.1.0/24, within 5 s, where the hold time alone takes 30. It does not time the failover. In the two runs above, ce2a's BFD session was down 1070 and 840 ms after the loss began, and the route was gone 221 and 228 ms after that.

pe1 and ce1a run BFD on their eBGP session too, and pe1's end is in VRF A (routescope `docs/design/bfd-vrf.md`). pe1 starts `isisd` under `with-bfdd4r`, and pe1-bgp's `bgp4rd` uses that `bfdd4r`, since they share a namespace. bgp4rd checks the hop in the neighbor's VRF, `ip route get 192.168.1.2 vrf A`, so pe1-bgp waits for eth3's address before it starts. pe1's `bfdd4r` receives on a socket bound to VRF A, `192.168.1.1%A:3784` in `ss`. The gate checks this session as pe2 to ce2a's. In the two runs above, ce1a's BFD session was down 826 and 2113 ms after the loss began, and the route from pe1, 172.16.2.0/24, was gone 168 and 239 ms after that. The checks poll, so these times include up to a poll's wait.

## FRR version

p2 and pe2 run FRR master, pinned by digest: `quay.io/frrouting/frr:master@sha256:4e4981ce…`, which says `10.9.0-dev_git20261122`. No FRR release has the fix this lab needs yet. Until FRRouting/frr#24040 (merged 2026-11-14), bgpd registered a BFD session to a BGP neighbor before it knew its local address, and replaced it with a new one once BGP connected. The old session's last packet said Down, so a peer that keeps its session, as bfdd4r does, took it as a failure and reset BGP. That happened at some starts of this lab, when BFD came up before BGP. On FRR 10.2.1 pe2 then also reset its own session. With the master build, the session is made once, already keyed, and three starts of a two-node copy and a start of this lab showed no BFD flap.

FRR master also drops the `remoteLabel` JSON field for `remoteLabels` (FRRouting/frr#24296). routescope reads either from its pull request on that (routescope `claude/frr-remote-labels`); an older routescope shows pe2's VPN routes as different from the kernel, and the gate fails at pe2's VRF route.

Move to the first FRR release that has #24040 when there is one.

