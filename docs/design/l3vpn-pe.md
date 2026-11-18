# L3VPN PE in bgp4rd

Status: approved by the owner 2026-11-17. Pull requests 1, the VPN
table, 2, VRFs and both transports, 3, export and labels, and 4, the
lab and the interop test, and 5, VPN-IPv6 over the IPv4 core, built
the same day; 7, PE to CE by eBGP, on 2026-11-18. The gate passed on the VM, through routescope. The open questions
at the end keep the answers this document gives until the owner changes
them.

This is P2 in routescope's `docs/protocol-coverage.md`: "L3VPN PE in
bgp4rd". It builds on P1, SR-MPLS in IS-IS (isis
`docs/design/sr-mpls.md`, built), which gives the transport labels. A
routescope spec for the views, `docs/design/l3vpn-views.md`, follows
once this one is approved. `docs/design/l3vpn-ruby-pe.md` builds labs
where every PE runs our own daemons, with isisd or ospfd as the IGP.

## The problem

We want a lab where a customer's IP traffic crosses our routers inside a
VPN, on two labels: a transport label to the far PE, and a VPN label
the far PE gave for the route. And we want bgp4rd to be one of the PEs,
interoperating with FRR as the other.

```
                    AS 65000, IS-IS Level 2 with SR-MPLS
  ce1 ---- pe1 ------------- p ------------- pe2 ---- ce2
           isis4r + bgp4rd   isis4r          FRR
           VRF A, VRF B                      VRF A, VRF B
             \________ iBGP VPNv4 (AFI 1, SAFI 128) ______/
```

A PE has to do five things that bgp4rd does not:

1. keep VPN routes, keyed on Route Distinguisher and prefix;
2. hold VRFs, each with its Route Targets, and import into each VRF the
   VPN routes whose RTs it imports;
3. export its VRFs' own routes as VPN routes, with an RD, its export
   RTs and a label it allocated;
4. install a VRF's remote routes in the kernel, pushing the transport
   label and the VPN label;
5. install a label route for each label it allocated, so a packet
   arriving with it is popped into the right VRF.

RFC 4364 section 4.3.2 says what the PE advertises:

> "When a PE router distributes a VPN-IPv4 route via BGP, it uses its
> own address as the "BGP next hop". This address is encoded as a
> VPN-IPv4 address with an RD of 0. [...] It also assigns and
> distributes an MPLS label."

And section 4.3.1 which VRF takes a route:

> "a particular VPN-IPv4 route is only eligible for installation in a
> particular VRF if there is some Route Target that is both one of the
> route's Route Targets and one of the VRF's Import Targets."

## What exists

Read on master at f53e4f5, and measured on the lab VM on 2026-11-16.

**The wire is complete.**
- VPN NLRI: `BGP::Vpn` (`bgp/nlris/vpn.rb:11`), RD and prefix, with
  `encode_next_hop` writing RD 0 and the address (`:48`).
- Labels: `BGP::Labeled` (`bgp/nlris/labeled.rb:3`) wraps a `Vpn` for
  SAFI 128 and 129 (`:78-81`); `BGP::Label_stack` takes several labels
  (`bgp/nlris/label.rb:85`).
- The RFC 8277 section 2.4 withdrawal: the 3-octet Compatibility field
  is kept on receive (`label.rb:167-171`). On build it must be asked
  for, with `:compatibility => '800000'` (`bgp/path_attributes/mp_reach.rb:251`).
- RDs of types 0, 1 and 2: `BGP::Rd` (`bgp/nlris/rd.rb:26`).
- Route Targets: `BGP::Route_target` (`bgp/path_attributes/extended_community.rb:425`)
  and the IPv6 address-specific one of RFC 5701
  (`ipv6_extended_communities.rb:39`). Neither has a public reader for
  its global and local fields; values come out through `to_hash`.
- MP_REACH builds SAFI 128 from `{prefix, rd, label, path_id}`
  (`mp_reach.rb:86-92`) and parses its next hop as a `Vpn` with RD 0
  (`:562-567`).
- The generator, `bgp4r-sim`, already sends VPNv4 and VPNv6 routes with
  RDs, RTs and labels (`bgp/gen/vpn.rb`, `bgp/gen/per_vrf.rb`).
- 152 codec tests cover labels and VPN NLRI (routescope
  `docs/protocol-coverage.md`). But `test/coverage_matrix.rb:126` vouches
  `'vpn'` as `:none` against both GoBGP and FRR: never checked against
  a real router.

**The daemon keeps unicast only.**
- `PeerAdapter::MP_SAFIS` is SAFI 1 and 2 (`bgp/rib/peer_adapter.rb:62`).
  Its comment says why SAFI 4, 128 and 129 are left out: `Rib::Route`
  keys on the prefix and the Path Identifier, so routes that differ only
  in label or RD would collide.
- `docs/daemon.md`, "What is not here", records it as a decision: "No
  new address family in a RIB."
- No AFI/SAFI is negotiated: the OPEN's capabilities are stored, not
  intersected (`bgp/neighbor/neighbor.rb:821-840`).
- The decision process (`bgp/rib/decision.rb`) takes a `resolver` for
  the next hop's IGP cost; the daemon passes none, so every next hop is
  reachable at cost 0.
- Route reflection (RFC 4456) is done for unicast (`bgp/rib/export.rb`).
- There is no policy language; import and export take a Ruby block
  (`docs/daemon.md`, "What is not here").

**The FIB is `ip route` with no labels.** `Rib::Fib::IpRoute`
(`bgp/rib/ip_route.rb:75`) runs `ip route replace P via NH [dev D] table
T proto bgp`. No VRF device, no `encap mpls`, no `ip -f mpls`, no ECMP,
no recursive next hop.

**The kernel does L3VPN.** Measured on ospflab in network namespaces,
ce1, pe1, p, pe2 and ce2, with a VRF `A` (table 100) on each PE:

```
pe1# ip route add vrf A 192.168.2.0/24 encap mpls 100/2001 via 10.1.0.2 dev pe1-p
pe1# ip route add vrf A 192.168.3.2/32 encap mpls 100/2002 via 10.1.0.2 dev pe1-p
p#   ip -f mpls route add 100 via inet 10.2.0.2 dev p-pe2
pe2# ip -f mpls route add 2001 dev A
pe2# ip -f mpls route add 2002 via inet 192.168.2.2 dev pe2-ce2
```

Both pings from ce1 passed. 2001 is a label per VRF: pe2 pops it and
looks the address up in VRF A. 2002 is a label per prefix: pe2 pops it
and sends to ce2 with no lookup. A route in VRF A can leave on `pe1-p`,
an interface outside the VRF. tcpdump on p, toward pe1:

```
MPLS (label 100, tc 0, ttl 63) (label 2001, tc 0, [S], ttl 63) IP 192.168.1.2 > 192.168.2.2: ICMP echo request
MPLS (label 1001, tc 0, [S], ttl 63) IP 192.168.2.2 > 192.168.1.2: ICMP echo reply
```

**And over GRE, across a core with no MPLS.** The same five namespaces,
p routing IP only, with no MPLS at all, and a GRE tunnel between the
PEs' loopbacks:

```
pe1# ip link add gre-pe2 type gre local 10.255.0.1 remote 10.255.0.2 ttl 64
pe1# sysctl -w net.mpls.conf.gre-pe2.input=1
pe1# ip route add vrf A 192.168.2.0/24 encap mpls 2001 dev gre-pe2
pe2# ip -f mpls route add 2001 dev A
```

The ping from ce1 to ce2 passed both ways. tcpdump on p:

```
10.255.0.1 > 10.255.0.2: GREv0, Flags [none], length 92
    MPLS (label 2001, tc 0, [S], ttl 63)
    IP 192.168.1.2 > 192.168.2.2: ICMP echo request
```

**The transport label is in the kernel already.** isisd and FRR both
install a route to the far PE's loopback that pushes its SR label, and
`ip -j route` shows it. On r1 of isis's `isis4r-sr` lab:

```
r1$ ip -j route get 10.255.0.4
[{"dst":"10.255.0.4","encap":{"encap_type":"mpls","dst":"18004"},"gateway":"10.0.23.2","dev":"eth2",...}]
```

FRR's f1 gives the same shape. When the far PE is the next router, PHP
leaves no label and the route has no `encap`.

**Two daemons can share a PE.** In containerlab, a node with
`network-mode: container:pe1` runs in pe1's network namespace: tested
with a bgp4r-lab container beside an isis4r one, both seeing the same
`eth1`. So isis4rd and bgp4rd each keep their own image.

**FRR 10.2.1 takes the other PE's configuration.** These lines were
accepted, as `show running-config` gave them back:

```
router bgp 65000
 address-family ipv4 vpn
  neighbor 10.255.0.2 activate
router bgp 65000 vrf A
 address-family ipv4 unicast
  redistribute connected
  label vpn export auto
  rd vpn export 65000:1
  rt vpn both 65000:100
  export vpn
  import vpn
```

## Decisions

Each has the draft's choice. The owner may change any.

### 1. Where VPN routes live: a table of their own (A)

- **A. A VPN table beside the unicast one.** A new `Rib::VpnTable`,
  keyed on [RD, prefix], holding each route's labels and RTs. It reuses
  `Rib::Decision` for the best path per [RD, prefix]: RFC 4364 section
  4.3.1, "the BGP rules for route preference are used to choose which
  VPN-IPv4 route is installed by BGP". The unicast `Route`, `Table` and
  every show command stay as they are. This is how BGP-LS was done
  (`docs/design/bgp-ls-producer.md`, option A).
- **B. A RIB keyed on any NLRI.** `Route` would take an NLRI key, and
  every table, view and show command would follow. It is CLAUDE.md's
  "phase 2" for BGP-LS, not started, and large.

The draft takes A. It lifts "No new address family in a RIB" for SAFI
128 (and 129 later) only, and `docs/daemon.md` says so in the same pull
request.

### 2. One label per VRF

RFC 4364 section 4.3.2 leaves the choice to the egress PE: "The choice
of algorithm is entirely at the discretion of the egress PE". The draft
allocates one label per VRF: one label route per VRF, `ip -f mpls route
add L dev VRF`, whatever the number of routes. A label per prefix
(measured above too) comes later, if a lab needs it.

Labels come from a block of their own, configured. It must not overlap
the PE's own SRGB and SRLB, since isisd installs label routes from those
in the same kernel. In the lab, pe1's SRGB is 16000 to 23999 and its
SRLB 15000 to 15999, so bgp4rd takes 24000 to 24999. Other routers'
blocks do not matter: a label is local to the router that gave it.

### 3. Two transports to the far PE: MPLS and GRE

bgp4rd runs no IGP and no LDP. The VPN label has to reach the BGP next
hop some way, and RFC 4364 names two:

- section 4.3.2: "either that a label switched path exist between
  those two routers or else that some other tunneling technology (e.g.,
  [MPLS-in-IP-GRE]) can be used between them";
- section 5: "If the backbone does not support MPLS, the MPLS packet
  carrying only the VPN route label may be tunneled to the BGP Next Hop
  using the techniques of [MPLS-in-IP-GRE]" (RFC 4023).

bgp4rd does both, chosen per remote PE, so one PE can reach FRR over an
SR core and another PE over GRE:

| Transport | The VRF route | When |
| --- | --- | --- |
| `mpls`, the default | the IGP's labels to the next hop, then the VPN label | the core switches labels: isisd or FRR with SR |
| `gre` | the VPN label alone, out of a GRE tunnel to the next hop | the core routes IP only: ospfd today, or any core without labels |

Both were measured on the lab VM ("What exists"): two labels across an
SR core, and one label inside GRE across a core that had no MPLS.

**`mpls`.** To reach a remote PE bgp4rd reads the kernel's route to
the BGP next hop, `ip -j route get NH`: its `encap` labels, gateway and
device. The VRF route then pushes those labels and the VPN label below
them. With r1's route of isis4r-sr above and a VPN label 24001:

```
ip route replace vrf A 192.168.2.0/24 encap mpls 18004/24001 via 10.0.23.2 dev eth2 proto bgp
```

With no `encap` (PHP, the far PE is next door) it pushes the VPN label
alone. With no route to the next hop, the VPN route is unusable in that
VRF: RFC 4364 section 4.3.2 presupposes "that an MPLS packet carrying
such a label can be tunneled [...] to the router that is the BGP next
hop".

The kernel's routes change when the IGP converges, so bgp4rd watches
them: `ip monitor route` in a child process, as a trigger only, then
`ip -j route get` again for each next hop in use. (`ip -j monitor route`
prints plain text, not JSON, with iproute2 6.19: measured.)

**`gre`.** The VRF route sends the VPN label alone out of the tunnel
device toward that PE:

```
ip route replace vrf A 192.168.2.0/24 encap mpls 24001 dev gre-pe2 proto bgp
```

The tunnel runs between the two PEs' loopbacks, so its outer packets
follow the IGP's routes and a core reroute needs nothing from bgp4rd.
The far PE needs `net.mpls.conf.gre-X.input=1` on its end; its label
route is the same as with `mpls`. A next hop whose tunnel is missing or
down is unusable, as one with no route under `mpls`. The lab makes the
tunnels, as it makes the VRF devices; bgp4rd checks each one exists and
is up.

Either way, this is the first next-hop resolver the decision process
has had: a next hop with no transport is `next_hop_unreachable`
(`decision.rb:61`).

### 4. iproute2, as today

The FIB keeps running `ip` commands, as `Rib::Fib::IpRoute` does, not
netlink. The new forms are the measured ones: `ip route replace vrf V
... encap mpls T/L via GW dev D` (`mpls`), `ip route replace vrf V ...
encap mpls L dev TUNNEL` (`gre`), `ip -f mpls route replace L dev V`,
and their `del`. Each carries `proto bgp`, so a restart can flush what
bgp4rd put there.

**What is installed is the kernel's**, read back at each sync with `ip
-j route show vrf V proto bgp` (and `-6`, and the bgp label routes),
compared as labels, gateway and device. Pull requests 2 to 5 compared
with a record of what bgp4rd had sent, so a route removed by hand
stayed removed until a restart: found on `l3vpn-lab` on 2026-11-17,
when one `ip route flush vrf A proto bgp` left VRF A empty. Fixed after
pull request 5. A sync whose read-back matches sends nothing, so the
route events of its own commands settle: 0 events in 10 quiet seconds
on the lab.

### 5. What fills a VRF

Phase 1: the VRF's connected prefixes and its `prefixes` list,
configured; the lab's CEs need only a default route. Pull request 7
adds routes learned from a CE by eBGP inside the VRF, so a CE can be a
bgp4rd too ("PE to CE by eBGP", below).

### 6. IPv6 VRF routes over an IPv4 core: the neighbor's link-local (approved 2026-11-17, pull request 5)

RFC 4659 section 3.2.1.2: over an IPv4 transport, the BGP next hop is
"an IPv4-mapped IPv6 address containing the IPv4 address of the
advertising BGP speaker", with RD 0. Section 4: with such a next hop,
"the ingress PE MUST use IPv4 tunneling". So an IPv6 VRF route is
resolved as an IPv4 one: `ip -j route get 10.255.0.3` gives the
transport labels, the gateway 10.0.12.2 and the device eth1.

**The kernel will not install an IPv6 route with an IPv4 gateway.**
Measured on the lab VM (kernel 7.0, iproute2 6.19), 2026-11-17:

```
ip -6 route replace vrf A 2001:db8:2::/64 encap mpls 17003/16 via inet 10.0.12.2 dev eth1
  Error: IPv6 does not support RTA_VIA attribute.
ip nexthop add id 9001 encap mpls 17003/16 via 10.0.12.2 dev eth1
ip -6 route replace vrf A 2001:db8:2::/64 nhid 9001
  Error: IPv6 routes can not use an IPv4 nexthop.
```

What works is the same neighbor's IPv6 link-local address as the
gateway. The gateway only chooses the MAC address the labeled frame
goes to, and that MAC is the same whichever address names the
neighbor:

```
ip -6 route replace vrf A 2001:db8:2::/64 encap mpls 17003/16 via fe80::a8c1:abff:fef2:d683 dev eth1 proto bgp
```

On `l3vpn-lab`, with that route on pe1 and its twin on pe2 by hand,
ce1a pinged ce2a over IPv6 through the IPv4 SR core. The VPN label
routes needed no change: one label per VRF pops into the VRF, and the
kernel looks up the packet in the family it carries (FRR's label 16,
allocated for IPv4, took IPv6 too; so did bgp4rd's 24000).

**How bgp4rd finds the link-local.** The IGP gives an IPv4 gateway, and
an IS-IS core over IPv4 sends no IPv6 packet that would fill the
neighbor table. The draft takes, in order:

1. the IPv6 neighbor entry on that device with the IPv4 gateway's MAC
   address (`ip -j neigh show 10.0.12.2 dev eth1`, then `ip -6 -j neigh
   show dev eth1`);
2. else the modified EUI-64 link-local made from that MAC, which is
   what Linux makes when `addr_gen_mode` is 0, its default. On
   the lab VM it is 0 on isis4r's and FRR's containers alike, and p1's
   eth1, MAC `aa:c1:ab:f2:d6:83`, has `fe80::a8c1:abff:fef2:d683`.

The second can be wrong for a neighbor that makes its link-local
another way (stable privacy, RFC 7217). The route then installs and
the neighbor never answers its Neighbor Solicitation, so traffic
drops. show.vrf names the gateway and which rule gave it, so a reader
can see it. An option is a third rule, a probe: one ping to ff02::1
on the device fills the table with every neighbor's real address.

**Built in pull request 5, and measured on `l3vpn-lab`, 2026-11-17:**

- pe1 installed pe2's IPv6 subnet in both VRFs as `encap mpls 17003/19
  via fe80::a8c1:abff:fe93:d7c0 dev eth1`, p1's link-local, with nothing
  set by hand. With p1's eth2 down it moved to `19003/19` through p2's,
  and back. p1 saw `17003` over `19` on an IPv6 packet.
- **A sync can come before the ARP entry.** On a fresh deploy the first
  sync found no ARP entry for p1, a moment before BGP's own traffic made
  one, and nothing changed in the routing table to start another. So a
  route waiting for its gateway's MAC makes VrfSync sync again every 5
  seconds until it is installed.
- **FRR 10.2.1 receives bgp4rd's VPN-IPv6 routes but cannot install
  them.** `show bgp ipv6 vpn` lists them with next hop
  `::ffff:10.255.0.1`, labels 24000 and 24001; `show ipv6 route vrf A`
  marks them `r`, since zebra tries the IPv4 gateway the kernel refuses.
  The route added on pe2 by hand through p1's link-local made the ping
  cross both ways, the reply popped by bgp4rd's 24000.
- **FRR needs a global IPv6 address to run VPN-IPv6 over IPv4.** With
  none it answers an OPEN offering AFI 2 / SAFI 128 with Cease 6/0, and
  with one it sends that address as the VPN next hop, whatever `nexthop
  vpn export` says. The lab gives pe2's loopback `::ffff:10.255.0.3`, so
  FRR sends the mapped next hop section 3.2.1.2 asks for.
- FRR's bgpd without zebra, as CI runs it, refuses AFI 2 on an IPv4
  session the same way, so `vpn_frr_test.rb` has no VPN-IPv6 case.

A next hop that is a real IPv6 address, not IPv4-mapped, needs an IPv6
transport (section 3.2.1.1). bgp4rd marks it unreachable, with that
reason: no core in our labs carries IPv6 labels yet.

**Export.** A VRF's IPv6 connected prefixes are read with `ip -6 -j
route show vrf A proto kernel`, keeping unicast routes and leaving out
`fe80::/64`, anycast and multicast, which the same command lists. They
go out as AFI 2, SAFI 128, with next hop `::ffff:` + `local_address`
and RD 0, to sessions that negotiated AFI 2 / SAFI 128 (section 3.4).
The VRF's one label serves both families. `prefixes:` takes IPv6 too.

## The design

### Configuration

```yaml
as: 65000
router_id: 10.255.0.1
local_address: 10.255.0.1          # the BGP next hop we advertise
l3vpn:
  labels: { start: 24000, size: 1000 }
  transport: mpls                  # the default for every remote PE
  tunnels:                         # the PEs reached over GRE instead
    10.255.0.9: { gre: gre-pe9 }   # next hop: the tunnel device
vrfs:
  - name: A                        # the kernel VRF device
    table: 100
    rd: 65000:1
    import: [65000:100]            # Route Targets
    export: [65000:100]
    prefixes: [192.168.1.0/24]     # besides its connected prefixes
  - name: B
    table: 200
    rd: 65000:2
    import: [65000:200]
    export: [65000:200]
neighbors:
  - address: 10.255.0.4
    as: 65000
    capabilities: [mbgp_ipv4_mpls_vpn_unicast]
```

`mbgp_ipv4_mpls_vpn_unicast` is the capability name `Neighbor#capability`
takes today for AFI 1, SAFI 128 (and `mbgp_ipv6_mpls_vpn_unicast` for
AFI 2): checked.

bgp4rd creates no VRF device and moves no interface: the lab does that,
as it sets the addresses. bgp4rd checks the device exists and has the
configured table, and says so when it does not.

### Who filters: the receiver

RFC 4364 sends every VPN route to every VPN peer and has the receiver
choose. Section 4.3.1:

> "Any route associated with Route Target T must be distributed to every
> PE router that has a VRF associated with Route Target T. When such a
> route is received by a PE router, it is eligible to be installed in
> those of the PE's VRFs that are associated with Route Target T."

And section 4.3.2, on what the receiver does with the rest:

> "A PE router, UNLESS it is a route reflector [...] should not install
> a VPN-IPv4 route unless it has at least one VRF with an Import Target
> identical to one of the route's Route Target attributes. Inbound
> filtering should be used to cause such routes to be discarded."

The same section names the cost: when a VRF gains an Import Target (a
"VPN Join"), the PE "must then acquire the routes it may previously have
discarded", by route refresh (RFC 2918).

Filtering at the sender came later, in RFC 4684 (Route Target
Constraint). A PE advertises the RTs it imports, and its peers then
send it only the VPN routes it wants: "Received Route Target membership
information can then be used to restrict advertisement of VPN NLRI to
peers that have advertised their respective Route Targets". It is
negotiated, and out of scope here.

So bgp4rd sends every VPN route to every VPN peer, and filters what it
receives by its VRFs' Import Targets.

### Receiving

1. `PeerAdapter` reads SAFI 128 out of MP_REACH and MP_UNREACH into the
   `VpnTable`, with each route's RD, labels and RTs.
2. A route none of whose RTs any VRF imports is not installed, as
   section 4.3.2 says. The draft still keeps it in the Adj-RIB-In, so a
   VPN Join (a VRF given a new Import Target by a config change) takes
   it from there, with no route refresh: bgp4rd sends refreshes but
   does not answer them yet (routescope's `protocol-coverage.md`, 2918
   and 7313), and a lab's tables are small. A route reflector keeps and
   reflects them all: pull request 6.
3. Best path per [RD, prefix], with the resolver of decision 3.
4. Import: each VRF takes the best route of every [RD, prefix] whose RTs
   it imports. Two RDs may give the same prefix to one VRF; the decision
   process picks one of them for the VRF's table.
5. The VRF's table is installed: `ip route replace vrf V P encap mpls
   T/L via GW dev D proto bgp`, T the transport labels, L the route's
   VPN label.

### Exporting

1. Each VRF's own prefixes become VPN routes: its RD, its export RTs as
   extended communities, the VRF's label, and next hop `local_address`
   as a VPN-IPv4 address with RD 0.
2. The label route goes in first: `ip -f mpls route replace L dev V
   proto bgp`.
3. The routes go to every neighbor that sent the VPNv4 capability in
   its OPEN, with no Route Target filtering at the sender (above). A
   neighbor that did not send the capability gets none: RFC 4364
   section 4.3.4, "In order for two BGP speakers to exchange labeled
   VPN-IPv4 NLRI, they must use BGP Capabilities Advertisement to ensure
   that they both are capable of properly processing such NLRI".
4. A withdrawal sends Compatibility 0x800000 (RFC 8277 section 2.4:
   "Upon transmission, the Compatibility field SHOULD be set to
   0x800000").

### The API

New methods, for routescope's views and for `bgp4r-cli`:

| Method | Answers |
| --- | --- |
| `show.vrfs` | each VRF: name, table, RD, import and export RTs, label, route counts |
| `show.vpn` | the VPN table: RD, prefix, next hop, labels, RTs, from, best, and the VRFs that imported it |
| `show.vrf` | one VRF's routes: prefix, next hop, VPN label, transport labels, gateway and device, installed or not |
| `show.vpn_labels` | the labels bgp4rd allocated, each with its VRF, and whether the kernel has it |

`show.fib` stays the unicast FIB. Every answer is additive; none of
today's changes (routescope `docs/design/api-contract.md`).

### The kernel

Each PE container needs `mpls_router`, `mpls_iptunnel` and `vrf` on the
host, `net.mpls.platform_labels` above 24999, and
`net.mpls.conf.IF.input=1` on its core interfaces. The lab VMs load the
first two at boot; routescope's `tools/vm-update.sh` adds `vrf` to
`/etc/modules-load.d/mpls.conf`.

## The lab

`routescope/labs/l3vpn-lab` in bgp4r, AS 65000:

```
                       p1 (isis4r, SRGB 17000)
  ce1a --+            /   metric 10        \            +-- ce2a
         |           /                      \           |
         pe1 -------                          ------- pe2
         |  isis4r + bgp4rd                    FRR      |
  ce1b --+  SRGB 16000     \                  /  SRGB   +-- ce2b
                            \   metric 20    /   18000
                       p2 (FRR, SRGB 19000)
```

- pe1 is two nodes: `pe1` (isis4r) and `pe1-bgp` (bgp4r-lab image,
  `network-mode: container:pe1`). routescope shows both.
- p1 is isis4r and p2 FRR, both with SR. The path through p1 is the
  shorter, so traffic takes it; p2 is there for the reroute.
- pe2 is FRR, with IS-IS SR and bgpd's VPN.
- VRF A joins ce1a and ce2a, VRF B joins ce1b and ce2b. Both use
  192.168.1.0/24 and 192.168.2.0/24: the same addresses in two VPNs,
  kept apart by their RDs (65000:1 and 65000:2) and RTs.
- The CEs are plain Linux nodes with a default route to their PE.

## Pull requests

1. **The VPN table and receiving.** `VpnTable`, `PeerAdapter` reading
   SAFI 128, the decision per [RD, prefix], `show.vpn`. Checked against
   `bgp4r-sim` sending VPN routes. No VRF yet.
2. **VRFs and import.** The `vrfs:` configuration, RT import, both
   transports (`mpls` with its resolver and `ip monitor` watch, `gre`
   with its `tunnels:` and their check), the VRF FIB, `show.vrfs` and
   `show.vrf`, which names each route's transport.
3. **Export and labels.** Label allocation, label routes, VPN routes
   sent with RD, RTs and label, withdrawals with 0x800000,
   `show.vpn_labels`.
4. **The lab.** `l3vpn-lab`, its ABOUT.md and a scenario; the interop
   gate against FRR; `coverage_matrix.rb` vouches `'vpn'` for FRR.
5. **IPv6 VPNs (RFC 4659).** AFI 2, SAFI 128, with an IPv4 transport:
   the next hop as an IPv4-mapped IPv6 address with RD 0 (RFC 4659
   section 3.2.1.2).
6. **A VPN route reflector.** bgp4rd reflecting SAFI 128 between PEs,
   keeping every route (RFC 4364 section 4.3.3).

7. **PE to CE by eBGP.** A neighbor bound to a VRF, so a CE can run
   bgp4rd: see "PE to CE by eBGP" below.

routescope's views come in its own spec, after PR 2, when `show.vrfs`
and `show.vrf` exist.

## A VPN route reflector (pull request 6)

RFC 4364 section 4.3.3: "Rather than having a complete IBGP mesh among
the PEs, it is advantageous to make use of BGP Route Reflectors". Of its
two ways to share VPN routes among reflectors, the second fits one
reflector: it "accepts all the routes received from all of its clients
(PEs)", with no Route Target filter. bgp4rd's VPN table already keeps
every route it receives, whatever its Route Targets ("Who filters: the
receiver"), so what is missing is sending them on.

**The rules are RFC 4456's, and already in `Rib::Export`.** Section 6:
a route from a non-client goes to every client, a route from a client to
every client and non-client. Section 8: the reflector adds ORIGINATOR_ID
if there is none and prepends its CLUSTER_ID to CLUSTER_LIST, and the
decision process already drops a route carrying our BGP Identifier as
ORIGINATOR_ID or our CLUSTER_ID in CLUSTER_LIST (`originator_id_loop`,
`cluster_list_loop`). `Export#for(route, peer)` answers the refusal
(`back_to_sender`, `non_client_to_non_client`, ...) or a copy of the
route's attributes with those two added and MP_REACH_NLRI taken out.

The design:

1. **On** when the speaker reflects unicast: `export: { route_reflector:
   true }`, or any neighbor with `route_reflector_client: true`, with the
   same `clients` and `cluster_id`. No new key.
2. **`Daemon::VpnReflector`.** For each [RD, prefix] the VPN table
   chose, and each established internal session that negotiated the
   route's family (AFI 1 or 2, SAFI 128) and is not a CE: `Export#for`
   decides, and the UPDATE carries its attributes plus an MP_REACH_NLRI
   with the route's own next hop, RD and labels. RFC 4271 section 5.1.3:
   the next hop of a route sent to an internal peer is not changed, so
   the label the far PE gave still points at it. External VPN peers
   (inter-AS) are out of scope.
3. **The difference only**, kept per peer as VpnExporter keeps it: a
   route gone or no longer chosen is withdrawn with the Compatibility
   field, and a session coming up gets everything. It runs on a thread
   of its own, poked by the VPN table, so a session's dispatch thread
   never waits on another session's send.
4. A reflector may be a PE too: its own VRFs' routes still go out
   through VpnExporter, under its own RDs.

**The lab.** `l3vpn-lab` gets `p1-bgp`, a bgp4rd in p1's namespace on
10.255.0.2, reflecting for pe1 (bgp4rd) and pe2 (FRR), its two clients,
which no longer peer with each other. So FRR reads routes reflected by
bgp4rd, and bgp4rd routes reflected from FRR.

## PE to CE by eBGP (pull request 7)

RFC 4364 section 7 lists four ways a PE learns a site's routes, and
says of eBGP: "Unlike the IGP alternatives, this does not require the
PE to run multiple routing algorithm instances". It is also the one
bgp4rd can do on both ends: as a CE, bgp4rd needs nothing new, since it
already speaks unicast eBGP, announces its `originate` prefixes and
installs what it learns.

On the PE:

- **A neighbor in a VRF.** `vrf: A` on a neighbor. Its TCP session is
  bound to the VRF's device. bgp4rd opens sessions unbound today
  (`bgp/neighbor/neighbor.rb:512`, `bgp/daemon/speaker.rb:390`); ospfd
  already binds its sockets with `SO_BINDTODEVICE`
  (ospfv2 `lib/ospfv2/infra/transport.rb:59`).
- **A unicast table per VRF.** The CE's routes go into VRF A's table,
  not the speaker's global one. They are exported as VPN routes along
  the export path above, with the VRF's connected and configured
  prefixes.
- **Back to the CE.** VRF A's imported routes are advertised to the CE,
  with the PE's AS prepended.
- **One ASN at every site.** Section 7: a site not in a transit VPN
  "need not have a unique Autonomous System Number [...] Every CE whose
  site is not in a transit VPN can use the same ASN. This can be chosen
  from the private ASN space, and it will be stripped out by the PE."
  The draft has the PE replace the CE's ASN by its own when it sends a
  route to another site's CE with the same ASN (vendors call it AS
  override), and sets the Site of Origin extended community, as the
  same section says, so a route is not sent back into its own site.

```yaml
neighbors:
  - address: 192.168.1.2      # ce1, in VRF A
    as: 65101
    vrf: A
    as_override: true
    soo: "65000:11"           # Site of Origin, optional
```

### The design, pull request 7

Measured on `l3vpn-lab`'s pe1 (kernel 7.0), 2026-11-18, before writing
it:

- A TCP socket with `SO_BINDTODEVICE` set to the VRF device reaches a CE
  in that VRF; an unbound one gets `ENETUNREACH`.
- `net.ipv4.tcp_l3mdev_accept` is 0, so the speaker's one listener, on
  0.0.0.0 in the default VRF, never sees a CE's connection. A listener
  bound to the VRF device accepts it. So **each VRF with a passive CE
  neighbor gets a listener of its own**, on the same port.

The pieces:

1. **The session.** A neighbor with `vrf:` dials with its socket bound
   to the VRF device and no source address, so the kernel takes the
   VRF interface's. Its session is attached to nothing global: not the
   RIB, not the VPN table, not BGP-LS, and the speaker's `announce`
   blocks are not sent to it. Its NEXT_HOP is its own address on that
   socket.
2. **The VRF's CE routes** (`Rib::VrfCeTable`). A `PeerAdapter` reads
   the CE's unicast UPDATEs into a table per VRF, one decision per
   prefix across that VRF's CEs, the CE's own Adj-RIB-In cleared when
   its session ends (RFC 4271 section 6). The decision drops a route
   whose AS_PATH holds our AS (`as_loop`).
3. **Into the VRF's kernel table.** A CE route is installed as `ip route
   replace vrf A P via CE proto bgp`. **A CE route wins over a VPN route
   for the same prefix**, as an eBGP route wins over an iBGP one. The
   read-back compares the gateway, and the device only when bgp4rd
   named one.
4. **Out as VPN routes.** The VRF's best CE routes join its connected
   and configured prefixes in `exports`, carrying the CE's AS_PATH and
   ORIGIN, and the neighbor's `soo:` as a Route Origin extended
   community (RFC 4360 section 5) beside the Route Targets.
5. **Back to the CE** (`Daemon::VrfCeExporter`). Each CE gets its VRF's
   installed routes: the imported VPN routes and the other CEs' routes,
   never its own (split horizon), and not a route whose Site of Origin
   is its own `soo:`. Our AS is prepended. With `as_override`, each
   occurrence of the CE's AS in the path is our AS first: RFC 4364
   section 7's "it will be stripped out by the PE". IPv4 only: an IPv6
   route to a CE needs an IPv6 next hop on that link, which comes later.
   Sent after each VRF sync, the difference only, and all of it when the
   session comes up.

`show.vrf` lists a CE route with `transport` `ce` and `peer` the CE.

## Tests

- Unit, one file per new class: the table, RT import (with two RDs for
  one prefix), the label allocator (a block used up, a VRF removed),
  the resolver reading `ip -j route` answers recorded from isisd and
  FRR, the tunnel check (a device missing, a device down, a next hop
  with no tunnel), the iproute2 argv of each form for both transports.
- Functional: two bgp4rd speakers, one sending VPN routes, the other
  importing them, with the FIB as a recorder.
- Interop: bgp4rd and FRR 10.2.1 exchange VPNv4 routes, each reading
  the other's RD, RTs and label (`show bgp ipv4 vpn` on FRR, `show.vpn`
  on bgp4rd).
  **Built in pull request 4** as `test/functional/lab/vpn_frr_test.rb`,
  in CI's `lab frr` group, against FRR 10.5.1, which ubuntu-latest
  installs. FRR runs there with no zebra and so no VRF; it sends VPN
  routes from its static form, `network P rd RD label L route-map M`,
  with the Route Target set by the route-map. Measured on 2026-11-17:
  FRR read the RD, label, Route Target and next hop of the UPDATEs
  `VpnExporter` builds, kept one prefix under two RDs as two routes,
  and withdrew one RD's route on our withdrawal, whose label field its
  log shows as 524288, the 0x800000 Compatibility value. bgp4rd's
  `VpnTable` read FRR's two routes back with their RDs (an AS one and
  an IPv4 one), labels and Route Targets. `test/coverage_matrix.rb`
  vouches `'vpn'` as `:both` for FRR. A `network` whose route-map is
  defined after it originated nothing.
- Lab: the gate below, as a scenario.

## Gate

On `l3vpn-lab`, against FRR 10.2.1:

- ce1a pings ce2a. tcpdump on the pe1 to p1 link shows two labels,
  pe2's Node-SID in p1's block (17000 + its index) and the VPN label pe2
  gave. On the p1 to pe2 link only the VPN label is left: p1 popped the
  transport label (PHP). The reply comes back the same way, with a
  label from bgp4rd's block, 24000 and up.
- ce1b pings ce2b on the same addresses, through VRF B, with other VPN
  labels. ce1a cannot reach ce2b.
- FRR's `show bgp ipv4 vpn` lists pe1's routes with RDs 65000:1 and
  65000:2, their RTs and the labels from bgp4rd's block.
- The p1 to pe2 link down: pe1's VRF routes move to the transport
  label through p2 (in p2's block, 19000 + pe2's index), with none left
  stale, and the pings cross again. Link up: they move back.

**Passed on 2026-11-17**, on the VM with FRR 10.2.1 and bgp4rd from
master after pull request 3, every point above, with nothing set by
hand:
- ce1a to ce2a: `17003/16` on pe1 to p1, `16` alone on p1 to pe2; the
  reply `17001/24000`, then `24000` alone. FRR's label manager gave 16
  and 17.
- ce1b to ce2b: `17003/17`, reply `24001`. A tcpdump on ce2b saw
  nothing of ce1a's pings.
- FRR's `show bgp ipv4 vpn` listed RDs 65000:1 and 65000:2, RTs
  65000:100 and 65000:200, labels 24000 and 24001.
- p1's eth2 down: pe1's VRF routes became `19003/16` and `19003/17` via
  p2, and the pings crossed; up, back to `17003`.

`scenarios/gate.yml` runs all of it but the captures and the
separation, which a scenario cannot see. Through routescope it passed
twice: failover 2.6 s and 1.6 s, restore 2.2 s both times.

This lab's core runs SR, so it gates `mpls`. `gre` is gated by
`docs/design/l3vpn-ruby-pe.md`'s OSPF lab, whose core has no labels.

## Out of scope

Each later, with its own spec:

- PE to CE routing by an IGP (RFC 4364 section 7): OSPF (RFC 4577),
  and RIP. eBGP is pull request 7.
- Labels per prefix and per attachment circuit.
- Route Target Constraint (RFC 4684) and route refresh for a VPN join.
- Multi-AS backbones and carriers' carriers (RFC 4364 sections 9 and 10).
- VPN multicast (SAFI 129), EVPN (P5), SRv6 services (P6).
- Labeled unicast, SAFI 4.
- LDP: P2 needs none (routescope `docs/protocol-coverage.md`).
- **IPv6 transport for VPN-IPv6** (RFC 4659 section 3.2.1.1): a core
  carrying the PEs' IPv6 loopbacks with SR labels, so a PE sends its
  IPv6 loopback as the next hop and not an IPv4-mapped one. Pull request
  5 marks such a next hop unreachable (decision 6). It is the way to an
  `l3vpn-lab` where IPv6 crosses both ways with FRR as the far PE.
  Measured with pull request 5, 2026-11-17: FRR 10.2.1 receives
  bgp4rd's VPN-IPv6 routes but marks them `r` in `show ipv6 route vrf
  A`, its zebra trying the IPv4 gateway the kernel refuses; it sends
  Cease 6/0 to an OPEN offering VPN-IPv6 over IPv4 when it has no global
  IPv6 address. Not checked: whether isis4r and FRR's IS-IS install
  label routes for IPv6 Prefix-SIDs. Measure that first, then write a
  decision 7. bgp4rd's own part is small: resolve the IPv6 next hop
  with `ip -6 route get`, whose answer already carries the labels and a
  link-local gateway.

## Open questions

1. **Decision 1.** A table of its own (A), or a RIB keyed on any NLRI
   (B)? The draft takes A.
2. **Who makes the VRF devices and the GRE tunnels?** The draft has the
   lab make both and bgp4rd check them. bgp4rd could make them itself,
   which a config change would then cover.
3. **GRE's MTU.** GRE and one label add 28 octets (112 against 84 in
   the capture). containerlab's links are 9500 (measured on isis4r-sr
   and frr-sr), so 1500-octet packets from a CE fit; the draft keeps
   9500. A lab that lowers its core links lowers the CE links by 28.
4. **`network-mode: container:`** makes pe1 two nodes in routescope.
   The alternative is one image with both daemons. The draft keeps two
   images.
5. ~~**Capability negotiation.**~~ Answered by RFC 4364 section 4.3.4:
   VPN routes go only to a neighbor whose OPEN carried AFI 1, SAFI 128
   (Exporting, step 3). It is the first family check bgp4rd makes;
   unicast stays as it is, sent to every neighbor.
