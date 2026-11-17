# L3VPN PE in bgp4rd

Status: draft, for the owner's review. No code yet. The open questions
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

### 3. The transport from the kernel

bgp4rd runs no IGP and no LDP. To reach a remote PE it reads the
kernel's route to the BGP next hop, `ip -j route get NH`: its `encap`
labels, gateway and device. The VRF route then pushes those labels and
the VPN label below them. With r1's route of isis4r-sr above and a VPN
label 24001:

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

This is also the first next-hop resolver the decision process has had:
a next hop with no route is `next_hop_unreachable` (`decision.rb:61`).

### 4. iproute2, as today

The FIB keeps running `ip` commands, as `Rib::Fib::IpRoute` does, not
netlink. The three new forms are the measured ones: `ip route replace
vrf V ... encap mpls ...`, `ip -f mpls route replace L dev V`, and their
`del`. Each carries `proto bgp`, so a restart can flush what bgp4rd put
there.

### 5. What fills a VRF

Phase 1: the VRF's connected prefixes and its `originate` list,
configured; the lab's CEs need only a default route. Pull request 7
adds routes learned from a CE by eBGP inside the VRF, so a CE can be a
bgp4rd too ("PE to CE by eBGP", below).

## The design

### Configuration

```yaml
as: 65000
router_id: 10.255.0.1
local_address: 10.255.0.1          # the BGP next hop we advertise
l3vpn:
  labels: { start: 24000, size: 1000 }
vrfs:
  - name: A                        # the kernel VRF device
    table: 100
    rd: 65000:1
    import: [65000:100]            # Route Targets
    export: [65000:100]
    originate: [192.168.1.0/24]    # besides its connected prefixes
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

### Receiving

1. `PeerAdapter` reads SAFI 128 out of MP_REACH and MP_UNREACH into the
   `VpnTable`, with each route's RD, labels and RTs.
2. A route none of whose RTs any VRF imports is not kept, as RFC 4364
   section 4.3.2 says a PE "should not install a VPN-IPv4 route unless
   it has at least one VRF with an Import Target identical to one of the
   route's Route Target attributes". (A route reflector keeps them all:
   pull request 6.)
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
   its OPEN. A neighbor that did not gets none.
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
2. **VRFs and import.** The `vrfs:` configuration, RT import, the
   transport resolver and its `ip monitor` watch, the VRF FIB, `show.vrfs`
   and `show.vrf`.
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
```

## Tests

- Unit, one file per new class: the table, RT import (with two RDs for
  one prefix), the label allocator (a block used up, a VRF removed),
  the resolver reading `ip -j route` answers recorded from isisd and
  FRR, the iproute2 argv of each form.
- Functional: two bgp4rd speakers, one sending VPN routes, the other
  importing them, with the FIB as a recorder.
- Interop: bgp4rd and FRR 10.2.1 exchange VPNv4 routes, each reading
  the other's RD, RTs and label (`show bgp ipv4 vpn` on FRR, `show.vpn`
  on bgp4rd).
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

## Open questions

1. **Decision 1.** A table of its own (A), or a RIB keyed on any NLRI
   (B)? The draft takes A.
2. **Who makes the VRF devices?** The draft has the lab make them and
   bgp4rd check them. bgp4rd could make them itself, which a config
   change would then cover.
3. **`network-mode: container:`** makes pe1 two nodes in routescope.
   The alternative is one image with both daemons. The draft keeps two
   images.
4. **Capability negotiation.** The draft sends VPN routes only to a
   neighbor whose OPEN carried SAFI 128. That is the first family check
   bgp4rd makes; unicast stays as it is (it is sent to every neighbor
   today).
