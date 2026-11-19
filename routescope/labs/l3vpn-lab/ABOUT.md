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

IPv6 rides the same VRFs as VPN-IPv6 (RFC 4659), 2001:db8:1::/64 and 2001:db8:2::/64. bgp4rd installs pe2's IPv6 routes through p1's IPv6 link-local and sends its own; FRR 10.2.1 receives them but cannot install them over an IPv4 next hop, so IPv6 crosses one way only. README.md has the details.

ce1a and ce2a are CEs running bgp4rd in AS 65101 by eBGP inside VRF A. Each PE replaces 65101 by 65000 in what it sends them (AS override), so each site reaches the other's loopback, 172.16.1.1 and 172.16.2.1.

`scenarios/gate.yml` checks the pings, the labels and the failover, and the VPN routes on the way: in p1-bgp's VPN table, and in each PE's VRF A with the far PE's transport label, through the failover too. README.md has the addresses, the images, and the tcpdump and vtysh commands to read the labels on the wire.
