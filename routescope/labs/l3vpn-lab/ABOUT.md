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

IPv6 rides the same VRFs as VPN-IPv6 (RFC 4659), 2001:db8:1::/64 and 2001:db8:2::/64. bgp4rd installs pe2's IPv6 routes through p1's IPv6 link-local and sends its own; FRR receives them but cannot install them over an IPv4 next hop (10.2.1, 10.7.1 and master, measured 2026-11-22), so IPv6 crosses one way only. README.md has the details.

ce1a and ce2a are CEs running bgp4rd in AS 65101 by eBGP inside VRF A. Each PE replaces 65101 by 65000 in what it sends them (AS override), so each site reaches the other's loopback, 172.16.1.1 and 172.16.2.1.

`scenarios/gate.yml` checks the pings, the labels and the failover, and the VPN routes on the way: in p1-bgp's VPN table, and in each PE's VRF A with the far PE's transport label, through the failover too. README.md has the addresses, the images, and the tcpdump and vtysh commands to read the labels on the wire.

## BFD on the core link

p1 and pe2 run BFD on their link, at 300 ms x 3, a 900 ms detection time. p1's `isisd` has `bfd: true` on eth2 and runs under `with-bfdd4r`, so a `bfdd4r` answers in p1's namespace (p1-bgp shares it). pe2 runs FRR's `bfdd`, with `isis bfd` on eth1.

The gate fails the link twice. First the link goes down: both ends lose carrier and see it at once. Then it keeps its carrier and loses every packet (routescope's `netem:` step at `loss: 100%`), as a bad optic or a switch in between would. Neither end sees that. BFD does, and both IS-IS routers drop the adjacency. Without BFD, IS-IS would wait out its hold time, 3 s here (hello 1 s x 3).

Measured through routescope on ospflab on 2026-11-22, FRR 10.7.1, two runs (recordings `20261122-192157-scenario-gate` and `20261122-192438-scenario-gate`). The VM's load average was 41 to 73 from other work, so these are slow; on FRR master earlier the same day, at a load near 10, `failover` was 1902 ms and `failover_loss` 3409 ms.

| Measure | Run 1 | Run 2 |
| --- | --- | --- |
| Link down: pe1's route to pe2 on 19003 | 517 ms | 2687 ms |
| Packet loss: pe1's route to pe2 on 19003 | 3505 ms | 529 ms |
| `failover`, link down | 4870 ms | 11381 ms |
| `failover_loss`, packet loss | 15251 ms | 11468 ms |
| `restore`, link up | 4993 ms | 7589 ms |
| `restore_loss`, netem cleared | 7916 ms | 11806 ms |

The first two rows are the time from the action to the first check, the route that moved. The `failover` and `restore` measures run from the action to a ping that passes, and include the VRF checks the gate makes before it, about a second each. So they say that the sites reach each other again, not how fast the routers moved.

## BFD on a PE to CE session

pe2 and ce2a run BFD on their eBGP session: `neighbor 192.168.2.2 bfd` in pe2's VRF A, and `bfd: true` on ce2a's neighbor. ce2a starts bgp4rd once eth1 has its address, since bgp4rd checks at start that pe2 is one hop away. A CE is single-homed, so loss on its link has no other path. The gate checks that the BFD session goes down and ce2a drops pe1's site, 172.16.1.0/24, within 5 s, where the hold time alone takes 30. It does not time the failover. In the two runs above, ce2a's BFD session was down 1091 and 1436 ms after the loss began, and the route was gone 370 and 732 ms after that.

pe1 and ce1a run BFD on their eBGP session too, and pe1's end is in VRF A (routescope `docs/design/bfd-vrf.md`). pe1 starts `isisd` under `with-bfdd4r`, and pe1-bgp's `bgp4rd` uses that `bfdd4r`, since they share a namespace. bgp4rd checks the hop in the neighbor's VRF, `ip route get 192.168.1.2 vrf A`, so pe1-bgp waits for eth3's address before it starts. pe1's `bfdd4r` receives on a socket bound to VRF A, `192.168.1.1%A:3784` in `ss`. The gate checks this session as pe2 to ce2a's. In the two runs above, ce1a's BFD session was down 1785 and 2600 ms after the loss began, and the route from pe1, 172.16.2.0/24, was gone 997 and 2180 ms after that. The checks poll, so these times include up to a poll's wait.

## FRR version, and what to watch

p2 and pe2 run FRR 10.7.1, the newest FRR release on 2026-11-22. FRR is here for interop, and an interop lab runs released images only: when no release has a fix, the lab waits for one (the owner's rule, 2026-11-22).

**Watch for FRRouting/frr#24040 in a release.** It is merged in FRR master on 2026-11-14 ("bgpd: register single-hop BFD sessions already keyed") and in no release yet: not in 10.7.1, nor in the stable/10.7 or stable/10.6 branches, checked on 2026-11-22. When a release has it, move p2 and pe2 to that release, run the gate twice, and drop this section's flap.

What it fixes. FRR's bgpd registers its BFD session to a neighbor before it knows its own address (`local:0.0.0.0`), then replaces it once BGP connects. The old session's last packet says Down, Diagnostic 3, not AdminDown. So a peer that keeps one session per neighbor, as bfdd4r and BIRD do, takes it as a failure. When it comes after BGP is Established, the peer resets BGP: bgp4rd recovers in about 2 s (bgp4r #361); BIRD waits 60 s.

What it does here, on 2026-11-22:

| FRR | When FRR swaps the session | BGP reset at start |
| --- | --- | --- |
| 10.2.1 | at BGP Established | ce2a's session, in 1 start of 3; pe2 also sent a Cease 6/10 |
| 10.7.1 | when BGP's TCP connects, before Established | none in the one start measured: ce2a's bgpd logs "the BGP session is Idle, nothing to reset" |
| master | never: one session, keyed from the start | none |

ce2a's BFD session still goes Up, Down, Up once at a start on 10.7.1, so the gate checks BFD only after that.

A second FRR behaviour: bfdd sends the same Down, not AdminDown, from any session its last client deregisters, so `no neighbor X bfd` on an Established FRR peer resets the peer's BGP (measured against BIRD, 2026-11-22). It does not happen in the gate.
