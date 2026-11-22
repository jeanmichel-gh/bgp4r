# l3vpn-lab

An L3VPN with `bgp4rd` as one PE and FRR as the other, across an
IS-IS core with SR-MPLS. It is the lab of `docs/design/l3vpn-pe.md`
(pull request 4), and the place its gate runs.

`ABOUT.md` is the short version, the one routescope shows.

```
                       p1 (isis4r, SRGB 17000)
  ce1a --+            /  metric 10        \             +-- ce2a
         |  eth1     /                     \     eth1   |
         pe1 -------                         ------- pe2
         |  isis4r + bgp4rd                   FRR       |
  ce1b --+  SRGB 16000  \  eth2         eth2 / SRGB     +-- ce2b
                         \   metric 20     /   18000
                       p2 (FRR, SRGB 19000)
```

## The nodes

| Node | Runs | Loopback, SID index | Addresses |
|---|---|---|---|
| `pe1` | isis4r; makes VRFs A (table 100) and B (table 200) | 10.255.0.1, 1 | eth1 10.0.12.1/30, eth2 10.0.14.1/30, eth3 192.168.1.1/24 in A, eth4 192.168.1.1/24 in B |
| `pe1-bgp` | `bgp4rd`, in pe1's namespace | | |
| `p1` | isis4r | 10.255.0.2, 2 | eth1 10.0.12.2/30, eth2 10.0.23.1/30 |
| `p1-bgp` | `bgp4rd`, in p1's namespace: the VPN route reflector for pe1 and pe2 | | |
| `p2` | FRR master (ABOUT.md, "FRR version"), IS-IS | 10.255.0.4, 4 | eth1 10.0.14.2/30, eth2 10.0.34.1/30 |
| `pe2` | FRR master, IS-IS, bgpd and bfdd; VRFs A and B made at start | 10.255.0.3, 3 | eth1 10.0.23.2/30, eth2 10.0.34.2/30, eth3 192.168.2.1/24 in A, eth4 192.168.2.1/24 in B |
| `ce1a`, `ce1b` | Linux, default route to pe1 | | eth1 192.168.1.2/24 |
| `ce2a`, `ce2b` | Linux, default route to pe2 | | eth1 192.168.2.2/24 |

Every SRGB is 8000 labels, so a node's label for pe2 is its base plus 3.
The SRLBs are all 15000 to 15999.

| VRF | RD | Route Target | pe1's label (bgp4rd) | pe2's label (FRR) |
|---|---|---|---|---|
| A | 65000:1 | 65000:100 | 24000 | 16 (first deploy) |
| B | 65000:2 | 65000:200 | 24001 | 17 (first deploy) |

bgp4rd's labels come from its `l3vpn: labels:` block, 24000 and up, in
VRF order. FRR's come from its own label manager (`label vpn export
auto`): 16 and 17 on the first deploy, before the VRFs carried IPv6.
FRR gives one per VRF and family, in the order it starts them, so they
change from one deploy to the next (17, 16, 19 and 18 on a later one).
bgp4rd's one label per VRF serves both families.

## What happens to a packet

A ping from ce1a to ce2a, read with tcpdump on p1's two links
(2026-11-17, on the VM):

```
p1 eth1, from pe1:
  MPLS (label 17003, tc 0, ttl 63) (label 16, tc 0, [S], ttl 63) IP 192.168.1.2 > 192.168.2.2: ICMP echo request
  MPLS (label 24000, tc 0, [S], ttl 63) IP 192.168.2.2 > 192.168.1.2: ICMP echo reply
p1 eth2, toward pe2:
  MPLS (label 16, tc 0, [S], ttl 63) IP 192.168.1.2 > 192.168.2.2: ICMP echo request
  MPLS (label 17001, tc 0, ttl 63) (label 24000, tc 0, [S], ttl 63) IP 192.168.2.2 > 192.168.1.2: ICMP echo reply
```

- pe1's VRF A route for 192.168.2.0/24 pushes `17003/16`: p1's label for
  pe2's loopback, which isisd put in the kernel, then FRR's VPN label.
  bgp4rd read the first from `ip route get 10.255.0.3`.
- p1 pops 17003 (PHP), so pe2 sees 16 alone. FRR's label 16 sends it to
  VRF A.
- FRR pushes `17001/24000` on the way back. p1 pops 17001, and pe1's label
  route for 24000 (`ip -f mpls route`: `24000 dev A proto bgp`) pops
  24000 and looks the address up in VRF A.

From ce1b the same addresses carry 17 and 24001, through VRF B. A
tcpdump on ce2b while ce1a pings 192.168.2.2 sees nothing.

With p1's eth2 down, pe1's route to pe2 becomes `encap mpls 19003 via
10.0.14.2 dev eth2`, and bgp4rd moves every VRF route onto it
(`19003/16`, `19003/17`) within the IGP's convergence. When the link
comes back they move back to `17003`. Two runs of the gate scenario
measured 2.6 s and 1.6 s to fail over, and 2.2 s to restore. On
2026-11-19 the gate read pe1-bgp's VRF route on 19003 1.2 s after the
link went down, and pe2's on 19001 at 1.7 s, through routescope's
`vrf_route`.

## Reading it by hand

```sh
docker exec clab-l3vpn-lab-pe1-bgp bgp4r-cli show vrf
docker exec clab-l3vpn-lab-pe1-bgp bgp4r-cli show vrf A
docker exec clab-l3vpn-lab-pe1-bgp bgp4r-cli show bgp vpnv4
docker exec clab-l3vpn-lab-pe1 ip route show vrf A
docker exec clab-l3vpn-lab-pe1 ip -f mpls route
docker exec clab-l3vpn-lab-pe2 vtysh -c 'show bgp ipv4 vpn'
docker exec clab-l3vpn-lab-pe2 vtysh -c 'show ip route vrf A'
docker exec clab-l3vpn-lab-pe2 vtysh -c 'show mpls table'
docker exec clab-l3vpn-lab-ce1a ping -c 3 192.168.2.2
```

The labels on the wire, on p1's link from pe1 (eth2 is toward pe2):

```sh
docker exec clab-l3vpn-lab-p1 tcpdump -nn -i eth1 mpls
```

## Scenarios

| Scenario | What it checks |
|---|---|
| `gate` | IS-IS and the VPN session up; each site's route in p1-bgp's VPN table, and installed in the far PE's VRF A on p1's label (17003 on pe1-bgp, 17001 on pe2); both VRFs reaching across in both directions; then p1 to pe2 down: pe1 on p2's label 19003, the VRF routes on 19003 and 19001, and the pings crossing again; then the link back |

## Running it

Images: `isis4r:latest` (isis), `bgp4r-lab:latest` from this repository
(`docker build --target lab-node --build-context bfd4r=../bfd4r -t bgp4r-lab:latest .`, with L3VPN pull
request 3 or later) and FRR master, pinned by digest in `l3vpn-lab.clab.yml`. The host needs
the `vrf`, `mpls_router` and `mpls_iptunnel` modules.

```sh
routescope-labs install bgp4r/l3vpn-lab
```

and start it from routescope's Labs panel, or here: `sudo containerlab
deploy -t l3vpn-lab.clab.yml`.

## The route reflector

pe1 and pe2 do not peer with each other: each peers with `p1-bgp`, a
bgp4rd in p1's namespace on 10.255.0.2 that reflects VPN routes for both
(bgp4r pull request 6). It has no VRF and keeps every route, whatever
its Route Targets. Measured on 2026-11-18:

- pe2 (FRR) holds ce1a's site `from 10.255.0.2 (10.255.0.1)`, with
  `Originator: 10.255.0.1, Cluster list: 10.255.0.2`, next hop pe1's
  loopback and label 24000, as pe1 sent it.
- pe1 installs FRR's routes, reflected the same way, with FRR's labels.
- A prefix added to pe1's VRF A reached FRR through the reflector, and
  went when it was removed.

## The CEs of VRF A, by eBGP

ce1a and ce2a run bgp4rd in AS 65101, one ASN for every site, each with
its site on its loopback: 172.16.1.1/24 and 172.16.2.1/24. Each dials
its PE inside VRF A. pe1 takes ce1a as a neighbor with `vrf: A`,
`as_override` and `soo: "65000:11"` (bgp4r pull request 7); FRR's pe2
takes ce2a with `as-override` and `soo 65000:22`. Measured on
2026-11-18:

- ce1a has `172.16.2.0/24` from pe1 with AS_PATH `65000 65000`, and
  ce2a has `172.16.1.0/24` from FRR the same: each PE put its AS where
  the far site's 65101 was, so the CE does not drop it as a loop.
- pe1 installs ce1a's site in VRF A, `172.16.1.0/24 via 192.168.1.2 dev
  eth3 proto bgp`, and sends it as a VPN route: FRR shows it with AS_PATH
  `65101`, `RT:65000:100 SoO:65000:11`, label 24000.
- `ping -I 172.16.1.1 172.16.2.1` from ce1a crosses p1 as `17003/18`,
  and the reply as `24000`, popped into VRF A and sent to ce1a.

**ce2a needs bgp4r #346 to forward.** FRR sends ce2a its own link,
192.168.2.0/24. Before #346, ce2a's bgp4rd installed that over its
connected route; then 192.168.2.1 was a gateway only through itself,
and the kernel refused ce2a's routes to pe1's side ("Nexthop has invalid
gateway"). pe1 never sends a CE its own link, so ce1a did not meet it.
With #346 the FIB leaves a connected route alone, and ce2a's `show fib`
lists `192.168.2.0/24 connected`. With both, the gate scenario passed
through routescope on 2026-11-18, CE steps included: failover 1.0 s,
restore 2.5 s.

## IPv6

Both VRFs carry IPv6 too, as VPN-IPv6 (RFC 4659) over the same IPv4
core: 2001:db8:1::/64 at pe1 and 2001:db8:2::/64 at pe2, `::1` the PE
and `::2` the CE. Measured on 2026-11-17:

- bgp4rd installs pe2's IPv6 subnet in each VRF with the same transport
  label and FRR's IPv6 VPN label, through p1's IPv6 link-local, since
  the kernel takes no IPv4 gateway for an IPv6 route
  (`docs/design/l3vpn-pe.md`, decision 6):
  `2001:db8:2::/64 encap mpls 17003/19 via fe80::a8c1:abff:fe93:d7c0 dev eth1`.
  With p1's eth2 down it moves to `19003/19` through p2's link-local,
  and back.
- p1 sees `MPLS (label 17003) (label 19, [S]) IP6 2001:db8:1::2 >
  2001:db8:2::2`, and ce2a receives the echo request.
- **The reply does not come back, and that is FRR.** pe2 shows bgp4rd's
  routes in `show bgp ipv6 vpn`, labels 24000 and 24001, next hop
  `::ffff:10.255.0.1`, but cannot install them: `show ipv6 route vrf A`
  marks them `r`, because zebra tries the IPv4 gateway the kernel
  refuses. With that one route added on pe2 by hand through p1's
  link-local, `ip -6 route replace vrf A 2001:db8:1::/64 encap mpls
  17001/24000 via fe80::... dev eth1`, the ping crosses both ways and
  the reply arrives at pe1 as `24000` alone.
- pe2's loopback carries `::ffff:10.255.0.3`. Without a global IPv6
  address FRR answers an OPEN offering VPN-IPv6 over IPv4 with Cease
  6/0, and with one it sends that address as the next hop. The mapped
  one is what RFC 4659 section 3.2.1.2 asks for.

## What it does not have yet

- **PE to CE routing.** The CEs have a default route; each PE sends its
  connected CE subnet. eBGP from a CE is pull request 7.
- **Per-prefix labels.** One label per VRF on both PEs.
- **IPv6 from pe2's side.** FRR, 10.2.1 and the master build here, does not install IPv6 VPN routes
  over an IPv4 next hop (above).
