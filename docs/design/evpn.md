# EVPN in bgp4rd, VXLAN first

Status: approved by the owner, 2026-11-25, with the answers to its six
questions at the end. Pull request 0 is vtep4r #15; pull request 1, the
EVPN table, is built (its "As built" is below).

This is P5 in routescope's `docs/protocol-coverage.md`: "EVPN in
bgp4rd. MAC-VRF and an EVPN RIB, VXLAN first". routescope's
`docs/design/evpn-vxlan-lab.md` (approved 2026-11-17) gives bgp4rd its
part, in its table of pieces:

> "bgp4rd with an EVPN RIB and a MAC-VRF. It sends type 3 for its VNIs
> and type 2 for local MACs it reads from `vtep4rd`. It writes what it
> receives into `vtep4rd`, and reflects EVPN on the spine. P5, with its
> own bgp4r spec"

This is that spec. Its step 6 is lab 2, `evpn-ruby`, and bgp4rd in lab
3, `evpn-vxlan-frr`.

## The problem

```
              s1  isisd, bgp4rd (route reflector)
             10.255.0.1
            /           \
          l1             l2        isisd, vtep4rd, bgp4rd
   10.255.0.11       10.255.0.12
   VNI 100           VNI 100
        |                 |
       h1                h2
        \_ iBGP L2VPN EVPN (AFI 25, SAFI 70), AS 65000 _/
```

vtep4rd bridges a leaf's host port to VXLAN tunnels in user space. In
`vxlan-ruby` today its flood list is static and it learns remote MACs
from the tunnels (RFC 7348). With EVPN, both come from BGP, and the
leaf tells the others which MACs it has. A leaf's bgp4rd must:

1. keep EVPN routes, types 2 and 3, keyed as RFC 7432 says;
2. hold MAC-VRFs, one per VNI, each with an RD and Route Targets, and
   import the routes whose RTs it imports;
3. send a type 3 route for each MAC-VRF, so the others flood to it;
4. send a type 2 route for each MAC vtep4rd learns on a port, and
   withdraw it when the MAC ages or moves;
5. write the remote VTEPs and MACs it imports into vtep4rd;
6. follow MAC Mobility (RFC 7432 section 15) when a host moves;
7. on the spine, reflect EVPN routes it does not import.

RFC 8365 section 7.2 gives the same list for an NVE whose hosts are
single-homed:

> "1. Local learning of MAC addresses received from the VMs [...]
> 2. Advertising locally learned MAC addresses in BGP using the MAC/IP
> Advertisement routes.
> 3. Performing remote learning using BGP per Section 9.2 of [RFC7432].
> 4. Discovering other NVEs and constructing the multicast tunnels
> using the IMET routes.
> 5. Handling MAC address mobility events per the procedures of
> Section 15 in [RFC7432]."

Section 7.1 of the same RFC names the four parts of RFC 7432 this
takes: "MAC/IP Advertisement Route, Inclusive Multicast Ethernet Tag
Route, MAC Mobility Extended Community, Default Gateway Extended
Community". Multihoming is not in it.

## What exists

Read on bgp4r master `6c0986c` and vtep4r main `9c36005`, 2026-11-25.

**The wire is complete in bgp4r.** `docs/evpn.md` is its guide.
- All eleven route types are in `bgp/nlris/evpn_route.rb`. Type 2 is
  `Evpn::Mac_ip_advertisement` (`:1277`), with `rd, esi,
  ethernet_tag_id, mac, ip, label1, label2` (`:1284`). Type 3 is
  `Evpn::Inclusive_multicast` (`:1422`), with `rd, ethernet_tag_id,
  ip`.
- The PMSI Tunnel attribute is `BGP::Pmsi_tunnel`
  (`bgp/path_attributes/pmsi_tunnel.rb:41`), with
  `INGRESS_REPLICATION = 6`. Its label is an MPLS label; a VNI goes in
  whole as `:label_bits`.
- The extended communities are in
  `bgp/path_attributes/extended_community.rb`: `Encapsulation`
  (`:869`, `:vxlan => 8`), `Mac_mobility` (`:1097`), `Esi_label`,
  `Es_import` and `Router_mac`.
- `validation.rb` checks EVPN framing on receipt, and the bodies of
  types 5, 6 and 254. Types 2 and 3 have no body checks.
- The generator sends types 2 and 3 with a whole 24-bit VNI (`vni`,
  bgp4r #379) and a MAC Mobility sequence (`mac_mobility`).
  routescope's lab 3 sends them through `bgp4r-sim` to FRR 10.7.1,
  which installs all 1000 (its `ABOUT.md`).

**The daemon keeps no EVPN route.**
- The unicast RIB reads SAFI 1 and 2 only:
  `PeerAdapter::MP_SAFIS` (`bgp/rib/peer_adapter.rb:63`).
- VPN-IPv4 and VPN-IPv6 have a table of their own,
  `BGP::Rib::VpnTable` (`bgp/rib/vpn_table.rb:56`). It keys on [RD,
  prefix, path ID], runs the unicast `Decision` per [RD, prefix], and
  is fed only on a session whose two OPENs carried the family
  (`VpnTable.families`, `:93`). BGP-LS has the same shape in
  `bgp/daemon/link_state_table.rb`.
- `UnreachTable` reads AFI 25 SAFI 70 but keeps route type 254 only
  (`bgp/daemon/unreachability.rb:271-283`).
- So an EVPN type 2 or 3 route is parsed, validated and then dropped,
  and nothing logs it.
- `docs/daemon.md`, "What is not here", records it: "No new address
  family in a RIB. [...] a flow spec rule or an EVPN route is not a
  prefix."
- A neighbor can already offer the family: `capabilities:
  [mbgp_l2vpn_evpn]` (`test/functional/unreachability_daemon_test.rb:37`).

**bgp4rd already talks to other daemons.** `bgp/daemon/link_state_sources.rb`
has a JSON-lines client, `Conn` (`:36-70`). It reads isisd's and
ospfd's sockets and subscribes to their events. `bgp/daemon/bfd.rb`
uses bfd4r's `BFD::Client`.

**The VPN reflector** is `bgp/daemon/vpn_reflector.rb`. It sends the
VpnTable's winner per key to internal, established clients that
negotiated the family, with RFC 4456's ORIGINATOR_ID and CLUSTER_LIST.

**vtep4rd takes orders for EVPN.** Its socket is
`/run/vtep4r/vtep4rd.sock`, JSON lines in bgp4rd's own envelope
(vtep4r `vxlan/daemon/api.rb`).
- `vni.flood.add` and `vni.flood.del` take `vni` and `vtep`.
- `mac.add` takes `vni`, `mac`, `vtep` and `seq`; `mac.del` and
  `mac.flush` remove.
- `show.vnis` and `show.macs` answer the tables; `show.macs` gives each
  MAC's `type` (local or remote), `port` or `vtep`, `origin` (learned or
  api) and `seq`.
- `events.subscribe` with `kinds: ["mac"]` streams `learned`, `moved`
  and `aged`, with `vni`, `mac` and `port`. A streaming connection takes
  no other request, so a client needs two connections.
- A VNI has `mode: evpn` (`vxlan/vtep/bridge_domain.rb:35`). In it,
  vtep4rd learns MACs on its ports but not from its tunnels
  (`forwarder.rb:90`).

**What vtep4rd lacks for this** (measured in its code):
1. **A host that comes back is not learned.** `MacTable#learn` returns
   at once for an entry from the API: `return nil if e.origin == :api`
   (`vxlan/vtep/mac_table.rb:54`). So when h2 moves from behind l2 to
   l1's port, l1 keeps sending to l2, and tells bgp4rd nothing. RFC
   7432 section 15's move from remote to local cannot start.
2. **An `aged` event has no port** (`switch.rb:73`), and a `moved`
   event gives only the new place.
3. **`mac.add` has no IP**, so ARP suppression has nothing to stand on.
   Nor does vtep4rd answer ARP.
4. In `evpn` mode a static `flood:` list is still taken and used.

**FRR's routes, as lab 3 recorded them.** In
`test/fixtures/frr/evpn/l1-bgp-l2vpn-evpn-route-detail.json` in
routescope, each FRR leaf's type 3 route has `"pmsi": {"tunnelType":
"Ingress Replication", "label": 100, "id": "10.255.0.11"}`: the label
field is the VNI, and the tunnel ID, the originator's IP and the next
hop are one address. Its RD is `10.255.0.11:2`, a type 1 RD.

## Decisions

Each has the draft's choice. The owner may change any.

### 1. Where EVPN routes live: a table of their own

An `EvpnTable` beside the `VpnTable`, as L3VPN did (`l3vpn-pe.md`,
decision 1, option A). It keys a route on its RD and the part of the
NLRI RFC 7432 calls the route's key. For type 2, section 7.2:

> "For the purpose of BGP route key processing, only the Ethernet Tag
> ID, MAC Address Length, MAC Address, IP Address Length, and IP
> Address fields are considered to be part of the prefix in the NLRI.
> The Ethernet Segment Identifier, MPLS Label1, and MPLS Label2 fields
> are to be treated as route attributes"

For type 3, section 7.3: "only the Ethernet Tag ID, IP Address Length,
and Originating Router's IP Address fields".

So the key is [RD, 2, tag, MAC, IP] or [RD, 3, tag, originator], with
the path ID. The table runs the unicast `Decision` per key, as
`VpnTable` does. `docs/daemon.md` lifts "No new address family in a
RIB" for AFI 25 SAFI 70 in the same pull request.

It keeps types 2 and 3. A route of another type is counted per peer,
shown in `show.peers`, and not kept. Type 254 stays in the
`UnreachTable`, as today.

One table holds both types, not one table per type (the owner,
2026-11-25):
- The types share the RD, RT import, the session's feed, a peer's
  routes going when its session does, reflection and `show.evpn`. One
  table does each once.
- One UPDATE can carry several types; one table takes it whole.
- A later type (1, 4 or 5) adds a key and what it installs.
- The cost: rows differ in shape (a type 3 route has no MAC), and what
  a route installs depends on its type. MAC Mobility is type 2's alone.

### 2. One MAC-VRF per VNI, configured

RFC 8365 section 5.1.2 has two options. The draft takes option 1, "A
Single Broadcast Domain per EVI": "a BGP Route Distinguisher (RD) and
Route Target (RT) are needed per VNI on every NVE". The Ethernet Tag is
0, as section 5.1.3 says for the VLAN-Based Service: it "MUST be set to
zero".

RFC 7432 section 7.9 recommends a type 1 RD, the PE's address and a
number. The draft's default is `local_address:VNI`; a file may set
another. FRR sent `10.255.0.11:2`, a number of its own.

The RTs default to `AS:VNI`, import and export, and a file may set
others. That is what lab 3's FRR sent: its leaves configure no RT
(`advertise-all-vni` alone), and their routes carry `RT:65000:100`. It
is not RFC 8365 section 5.1.2.1's derivation, whose Local Administrator
carries an A bit and a 3-bit Type before the VNI; the draft leaves that
one out.

The VNI travels whole in the label fields, RFC 8365 section 5.1.3:
"the entire 24-bit field is used to encode the VNI value". That is the
Label1 of type 2, and the PMSI Tunnel attribute's label of type 3.

### 3. The data plane is vtep4rd, through its API

bgp4rd writes what it imports into vtep4rd and reads what vtep4rd
learns. It does not program the kernel's VXLAN device or bridge: FRR's
zebra does that, and the kernel stays the interop peer
(`evpn-vxlan-lab.md`, "The pieces"). A `kernel` data plane through
`bridge fdb` is out of scope.

Like BGP-LS's sources, the client is injected, so the unit tests run
on a recorder and the functional tests on a fake vtep4rd.

### 4. Who decides a MAC's place: bgp4rd

vtep4rd keeps `seq` and never compares it (`mac_table.rb:64-65`: "+seq+
is bgp4rd's, for RFC 7432 MAC Mobility; vtep4rd only keeps it"). So
bgp4rd keeps one place per [VNI, MAC]: local, or a remote VTEP with a
sequence. It decides by section 15's rules, below, and tells vtep4rd
the result.

### 5. MAC only: no IP in the type 2 routes it sends

vtep4rd learns MACs, not IP bindings, and does no ARP suppression. So
bgp4rd sends type 2 routes with no IP, which RFC 7432 section 9.2.1
allows: "By default, the IP Address Length field is set to 0, and the
IP Address field is omitted from the route." Received routes with an IP
are kept and shown, and their MAC is installed once per MAC.

## The design

### Configuration

```yaml
as: 65000
router_id: 10.255.0.12
local_address: 10.255.0.12           # the next hop and the VTEP address
evpn:
  vtep: /run/vtep4r/vtep4rd.sock     # vtep4rd's socket, the default
  duplicate: { moves: 5, seconds: 180 }   # RFC 7432 section 15.1's N and M
macvrfs:
  - vni: 100
    rd: 10.255.0.12:100              # the default is local_address:vni
    import: [65000:100]              # the default is as:vni, both ways
    export: [65000:100]
neighbors:
  - address: 10.255.0.1
    as: 65000
    capabilities: [as4_byte, mbgp_l2vpn_evpn]
```

bgp4rd checks at start that vtep4rd has each VNI and that its mode is
`evpn`, from `show.vnis`. A VNI that is missing or in `learn` mode is
an error in `show.status`, and that MAC-VRF sends nothing. A reflector
has `evpn:` with no `macvrfs:`.

### Receiving

1. `PeerAdapter` gains `evpn_operations`, as `vpn_operations`. It reads
   AFI 25 SAFI 70 out of MP_REACH and MP_UNREACH into the `EvpnTable`,
   with each route's ESI, VNI, RTs, PMSI Tunnel, Encapsulation and MAC
   Mobility. Only on a session whose two OPENs carried the family.
2. The table keeps every route, whatever its RTs, so a reflector has
   them all and a MAC-VRF added later finds them.
3. A MAC-VRF imports a route when one of its RTs is an import RT, as
   RFC 7432 section 7.10 and RFC 4364 section 4.3.1 do.
4. **Type 3: the flood list.** An imported type 3 route whose PMSI
   tunnel type is Ingress Replication gives a flood VTEP: the PMSI
   Tunnel Identifier, which RFC 7432 section 11.2 sets "to a routable
   address of the PE". bgp4rd sends `vni.flood.add`; the route's
   withdrawal sends `vni.flood.del`. A route with another tunnel type
   is kept and not installed, with a reason.
5. **Type 2: remote MACs.** An imported type 2 route gives a MAC behind
   its next hop, which RFC 7432 section 9.2.1 sets to "the IPv4 or IPv6
   address of the advertising PE". The MAC's place follows MAC
   Mobility, below. A new winner sends `mac.add` with its sequence; no
   winner left sends `mac.del`.
6. **The VNI must match.** A type 2 or 3 route whose VNI is not the
   MAC-VRF's is kept and not installed, with the reason `vni`. vtep4rd
   sends every frame of a bridge domain with its own VNI, so installing
   it would send frames the far VTEP drops. This holds for global VNIs,
   which the labs use. RFC 8365 section 5.1.3 also allows "locally
   assigned VNIs", where two VTEPs give one broadcast domain different
   VNIs and the RT joins them; that needs vtep4rd to send with each
   VTEP's VNI, and is out of scope.
7. **The encapsulation must say VXLAN.** RFC 8365 section 5.1.3 has
   the Encapsulation community "included with all EVPN routes", and
   says "if the BGP Encapsulation Extended Community is not present,
   then either MPLS encapsulation or a statically configured
   encapsulation is assumed". A route with none may come from a PE
   that expects MPLS, and its label field is then an MPLS label, not a
   VNI. So bgp4rd installs only a route whose Encapsulation community
   names VXLAN (tunnel type 8). A route with none, or with another, is
   kept and not installed, with the reason `encapsulation` (the owner,
   2026-11-25: no VXLAN to a router that expects MPLS). FRR's leaves
   send `ET:8` on both types (lab 3's fixtures), and the injector's
   routes carry `encapsulation:vxlan` since bgp4r #378.
8. A non-zero ESI is a multihomed segment. RFC 7432 section 9.2.2 then
   asks for the Ethernet A-D per ES routes before installing. The draft
   keeps such a route and does not install it, with the reason `esi`.

### Exporting

1. **Type 3**, one per MAC-VRF, once vtep4rd answers for its VNI: RD,
   Ethernet Tag 0, originator `local_address`, the export RTs, the
   Encapsulation community VXLAN, and a PMSI Tunnel attribute of type
   Ingress Replication with identifier `local_address` and the VNI as
   its label. RFC 7432 section 11.2 says the Leaf Information Required
   flag "MUST be set to zero".
2. **Type 2**, one per local MAC: RD, ESI 0, Ethernet Tag 0, the MAC,
   no IP, the VNI in Label1, the export RTs, the Encapsulation community
   VXLAN, and MAC Mobility when section 15 asks for it.
3. The next hop is `local_address`.
4. EVPN routes go only to a neighbor whose OPEN carried AFI 25 SAFI 70,
   as VPN routes do.
5. **Where local MACs come from.** At start and after each reconnect,
   `show.macs` for each VNI, then `events.subscribe` for `mac` events
   with `since`. `learned` and `moved` to a port announce; `aged`, and
   `moved` to a VTEP, withdraw. An `overflow` event, or a lost
   connection, makes bgp4rd read `show.macs` again and send the
   difference.
6. When vtep4rd's connection drops, bgp4rd keeps its routes for a hold
   time (`evpn: vtep_hold`, 30 s by default), then withdraws them all.
   A vtep4rd restarted inside it is read again, and only the
   difference is sent.

### MAC Mobility, RFC 7432 section 15

bgp4rd keeps one place per [MAC-VRF, MAC], from every imported type 2
route and every local MAC:

- **The first time.** "A PE advertising a MAC address for the first
  time advertises it with no MAC Mobility extended community
  attribute."
- **A remote MAC learned locally.** When vtep4rd reports a MAC on a
  port that bgp4rd holds behind another VTEP with sequence S, bgp4rd
  sends its own route with S + 1. With ESI 0 the section says it
  "advertises it with a MAC Mobility extended community attribute with
  the sequence number set properly". A route with no community counts as
  0.
- **A higher sequence elsewhere.** "A PE receiving a MAC/IP
  Advertisement route for a MAC address with a different Ethernet
  segment identifier and a higher sequence number than that which it
  had previously advertised withdraws its MAC/IP Advertisement route."
  bgp4rd withdraws, and sends `mac.add` with the remote VTEP.
- **The same sequence.** "selects the route advertised by the PE with
  the lowest IP address as the best route", and bgp4rd withdraws its
  own if it lost.
- **Wraparound.** "an implementation MUST handle scenarios in which
  sequence number wraparound occurs". The draft compares sequences as
  32-bit serial numbers, RFC 1982 section 3.2. FRR's rule is not
  measured; lab 3 gains a scenario that does (Labs, below).
- **Sticky.** A route with the sticky flag (section 7.7, "the MAC
  address is static and cannot move") always wins. A local learn of
  such a MAC is logged, as section 15.2 asks: "the PE MUST alert the
  operator".
- **Duplicates**, section 15.1. N moves in M seconds of one MAC (5 and
  180 by default) mark it duplicate: bgp4rd logs a warning and an event,
  withdraws its route, and stops sending and processing type 2 routes
  for that MAC "until a corrective action is taken by the operator".
  The action is `evpn.clear_duplicate`.

Among several remote routes for one MAC (two RDs), the same rules pick
the one installed. They are what decides across RDs; the `Decision`
decides only among paths of one key.

### The reflector

`EvpnReflector`, as `VpnReflector`: it sends the `EvpnTable`'s winner
per key to the internal clients that negotiated the family, with
ORIGINATOR_ID and CLUSTER_LIST, and the next hop, RD, labels and
attributes kept. Built when the speaker is a reflector. RFC 7432 asks
nothing more of it.

### The API

| Method | What |
| --- | --- |
| `show.evpn` | the table: one row per path, routescope's `evpn_routes` columns: `rd route_type eth_tag mac ip originator next_hop route_targets encap best from vni seq valid`, plus `reason` when not installed |
| `show.macvrfs` | one row per MAC-VRF: `vni rd import export vtep_state flood macs_local macs_remote duplicates` |
| `show.macvrf` | one MAC-VRF's MACs: `mac place vtep seq sticky moves duplicate since` |
| `evpn.clear_duplicate` | `vni`, `mac`: clears a duplicate mark |

`show.peers` counts EVPN routes per peer, as it does VPN routes. MAC
events (`moved`, `duplicate`) go in bgp4rd's event stream under a new
kind, `evpn`.

routescope's `Bgp4rd` driver reads `show.evpn` into `evpn_routes`. Its
`evpn_vnis` and `evpn_macs` stay vtep4rd's, from the `Vtep4r` driver.
That change is routescope's, in its own pull request.

## What vtep4r needs first

One pull request in vtep4r, step 0 below, before bgp4rd's pull request
3:

1. **A MAC learned on a port replaces an entry from the API**, and is
   reported as `moved`. That is the remote to local move of section 15.
   vtep4rd keeps forwarding to the port from then on; bgp4rd then
   decides, and may put the remote VTEP back with `mac.add` if it loses.
2. **A `moved` event carries the old place, and an `aged` event its
   port.**
3. **In `evpn` mode, a static `flood:` is refused** by the config check.
   vtep4rd keeps one flood list per VNI (`bridge_domain.rb:48`), for
   the file's VTEPs and the API's alike. Mixed, a type 3 withdrawal
   would remove a VTEP the file named, a static VTEP would be flooded
   to whatever EVPN says, and the gate's "from type 3 routes alone"
   could pass with EVPN doing nothing.

## Labs

**Lab 2, `evpn-ruby`, in routescope** (`evpn-vxlan-lab.md`): `vxlan-ruby`
plus a bgp4rd beside each leaf's vtep4rd and one on s1 as the
reflector. The VNIs are `mode: evpn`, with no `flood:`.

Each daemon has its container, and a leaf's containers share its
network (`network-mode: container:`), as isisd and vtep4rd do today
(the owner, 2026-11-25). vtep4rd's socket is a file, and that mode
shares the network namespace, not the file system. So a leaf's vtep4rd
and bgp4rd containers both mount one folder of the lab at
`/run/vtep4r`.

**Lab 3, `evpn-vxlan-frr`**: l2 becomes vtep4rd with bgp4rd, and s1
bgp4rd as the reflector. l1 stays FRR with the kernel's VXLAN. That is
the interop check. It gains a scenario for the sequence's wraparound:
the injector claims a MAC at 4294967295, then at 0, and the scenario
records which FRR keeps and which bgp4rd keeps.

## Pull requests

0. **vtep4r: a port learn over an API entry, the events, and `flood:`
   refused in `evpn` mode.** Its own repository's rules.
1. **bgp4r: the EVPN table and receiving.** `EvpnTable`,
   `evpn_operations`, the key and the decision, `show.evpn`, the counts
   in `show.peers`, `docs/daemon.md` and `docs/evpn.md` changed.
   Checked against `bgp4r-sim` sending types 2 and 3. No MAC-VRF yet.
2. **MAC-VRFs and import.** `macvrfs:` and `evpn:`, RT import, the
   vtep4rd client with its check, flood VTEPs and remote MACs written
   into vtep4rd, `show.macvrfs` and `show.macvrf`.
3. **Export and MAC Mobility.** Type 3 and type 2 routes sent, local
   MACs from vtep4rd's events, section 15 and 15.1, the hold on a lost
   vtep4rd, `evpn.clear_duplicate`.
4. **The reflector.** `EvpnReflector`.
5. **Interop.** `test/functional/lab/evpn_frr_test.rb` gains a bgp4rd
   against FRR, each reading the other's types 2 and 3;
   `coverage_matrix.rb` follows.

Then in routescope: the `Bgp4rd` driver's `evpn_routes`, lab 2 and its
scenarios, and bgp4rd in lab 3, each with its own pull request.

## As built

**Pull request 1.** `bgp/rib/evpn_table.rb` and `bgp/rib/evpn_path.rb`,
`PeerAdapter.evpn_operations`, `show.evpn`, and an `evpn` entry in
`show.peers`' `families`. What changed from the plan:

- `show.evpn`'s rows name the peer `peer`, as `show.vpn` does, where
  routescope's `evpn_routes` says `from`, and have no `valid`: every
  path held is valid until pull request 2 gives a reason not to install
  one. routescope's driver maps the names. A row also carries `esi`,
  `sticky`, `pmsi` and the path attributes `show.vpn` gives.
- `seq` and `sticky` are given on type 2 rows only, and `pmsi` on type
  3 rows only: one UPDATE can carry both types under one set of
  attributes, and RFC 7432 ties MAC Mobility to type 2 (section 7.7)
  and the PMSI Tunnel to type 3 (section 11.2).
- The decision process needs a `Rib::Route`, which keys on an IP
  prefix. `EvpnPath`, a subclass, keeps the EVPN key as text in its
  place; `Decision` reads only the attributes and the peer.
- Type 2's VNI is read from Label1's three octets as received.
  `Label#to_hash` leaves the bottom of stack bit out when it is 1, so a
  VNI read from the hash came out one less when it was odd.

**Pull request 2.** `bgp/rib/macvrf.rb` and `bgp/rib/macvrfs.rb`,
`bgp/daemon/evpn_sync.rb` (the vtep4rd client and the sync thread),
`show.macvrfs`, `show.macvrf`, and `evpn` in `show.status`. What
changed from the plan:

- **bgp4rd reads vtep4rd at each sync** and sends only the difference,
  as `l3vpn.rb` reads the kernel. It owns every flood VTEP and every
  MAC with `origin: api` of an `evpn` VNI, and deletes those no route
  asks for, so a bgp4rd restart clears what the one before it left. A
  MAC vtep4rd learned on a port is left alone, route or no route, until
  MAC Mobility decides (pull request 3).
- **It syncs on each change of the EVPN table and every 10 seconds.**
  The check "at start that vtep4rd has each VNI" is made at every sync,
  so a vtep4rd that starts after bgp4rd, or restarts, is found and
  filled. Its state per VNI is `ok`, `missing`, `mode` (not `evpn`),
  `down` (no connection) or `error`.
- **Section 15's choice among remote routes is here**, not in pull
  request 3: with two RDs bringing one MAC, a sticky MAC, then the
  higher sequence as an RFC 1982 serial number, then the lower next
  hop. Something has to pick one MAC's VTEP as soon as routes are
  imported. Pull request 3 adds the local MAC to the same choice.
- **A fifth reason, `own`**: a type 2 route whose next hop, or a type 3
  route whose tunnel, is this VTEP's address is not installed. bgp4rd
  sends none yet; it guards against a reflector sending ours back.
- **A type 3 route's tunnel is checked before its VNI**, since its VNI
  is the PMSI Tunnel's label: a route with no PMSI Tunnel says `pmsi`,
  not `vni`.
- **`show.evpn`'s `reason` was taken**, by the decision process's
  reason since pull request 1. Why a route is not installed is
  `invalid`, with `valid` its absence and `imported` the VNIs of the
  MAC-VRFs that import it. These three columns are there only with
  `macvrfs:`.
- **`evpn:` takes `vtep` only.** `duplicate` and `vtep_hold` come with
  pull request 3, which uses them; until then they are refused by name.
- `macvrfs` is keyed by `vni` in the set-line form of the configuration
  (`bgp/daemon/config.rb`). A change to it needs a restart, as `vrfs`.

## Tests

- Unit, one file per class: the table's key (one MAC with two IPs is
  two routes, one MAC under two RDs two routes), RT import, the VNI,
  encapsulation and ESI reasons, MAC Mobility as a table of cases from
  section 15 (first time, remote then local, higher, same with lower
  and higher address, sticky, wraparound, five moves in 180 s), and the
  vtep4rd client on a recorder: the orders sent for each case.
- Functional: a bgp4rd and a library `BGP::Neighbor` on loopback, as
  `vpn_daemon_test.rb`, with a fake vtep4rd on a Unix socket that
  records orders and sends `mac` events.
- Interop: pull request 5, against FRR as lab 3 has it.
- Lab: the gate.

## Gate

On `evpn-ruby`, every node our own code:

- h1 pings h2, and each leaf's vtep4rd floods to the other from type 3
  routes alone, with no `flood:` in its file.
- Each leaf's vtep4rd holds the far host's MAC with `origin: api`, from
  a type 2 route, and the reflector's `show.evpn` holds both leaves'
  routes.
- h2's link down: l1 loses h2's MAC when l2's vtep4rd ages it and l2's
  bgp4rd withdraws. Link up: it comes back.
- The injector claims h2's MAC with sequence 1: both leaves move it. h2
  speaks: l2 sends sequence 2, and l1 moves it back. The same scenario
  as lab 3's `mac-move`, on our code.
- Five moves in 180 s: the MAC is marked duplicate on the leaf that
  learns it, and `evpn.clear_duplicate` clears it.

On `evpn-vxlan-frr` with l2 and s1 on bgp4rd: h1 pings h2; FRR's l1
installs l2's MAC and floods to l2; l2's vtep4rd holds h1's MAC from
FRR's route.

Each scenario run twice through routescope on the VM, with times
recorded in the lab's `ABOUT.md`.

## Out of scope

Each later, with its own spec if asked for:

- Multihoming: route types 1 and 4, the ESI label, the DF election, and
  aliasing (RFC 7432 section 8). RFC 8365 section 7 leaves it out for
  single-homed NVEs.
- ARP and ND suppression with the IP in type 2 (RFC 7432 section 10).
  It needs vtep4rd to keep IP bindings and answer ARP.
- Type 5, IP prefixes (RFC 9136), and routing between VNIs (RFC 9135).
- More than one VNI per EVI, the VLAN-Aware Bundle Service.
- Locally assigned VNIs (RFC 8365 section 5.1.3), which need vtep4rd
  to send with each far VTEP's VNI.
- RT auto-derivation from the VNI (RFC 8365 section 5.1.2.1).
- EVPN over MPLS, the second half of P5.
- EVPN over SRv6 (RFC 9252), with SRv6 services (P6). A route that
  carries the SRv6 L2 Service TLV and no VXLAN Encapsulation community
  is kept and not installed (Receiving, step 7).
- The kernel's VXLAN as bgp4rd's data plane.
- Route Target Constraint (RFC 4684) for EVPN.
- The Default Gateway community (RFC 7432 section 10.1): it goes with
  routing, so with type 5.

## Questions, answered

The owner answered all six on 2026-11-25.

1. **Decision 1.** A table of its own, as L3VPN did, and one table for
   every type it keeps, not one per type.
2. **Containers.** One per daemon, sharing the leaf's network and
   vtep4rd's socket folder (Labs).
3. **A static `flood:` in `evpn` mode** is refused in vtep4r (What
   vtep4r needs first, item 3).
4. **Wraparound.** RFC 1982 section 3.2, and a lab 3 scenario that
   measures FRR's rule.
5. **A route with no Encapsulation community** is not installed: no
   VXLAN to a router that may expect MPLS (Receiving, step 7).
6. **A VNI that does not match** is not installed. Locally assigned
   VNIs are out of scope (Receiving, step 6).
