# CLAUDE.md

Guide for AI agents working on bgp4r. Read this before changing anything.

## What this is

bgp4r is a pure Ruby library to build, parse and speak BGP-4 (RFC 4271 and many extensions). It is used to script BGP peers for testing and research. Its only runtime gem is `logger`, which ships with Ruby.

## Layout

```
bgp4r.rb                 entry point, requires everything
bgp/common.rb            shared helpers (IPAddr extensions, hex dumps)
bgp/iana.rb              IANA constants (AFI, SAFI, attribute codes)
bgp/messages/            OPEN, UPDATE, KEEPALIVE, NOTIFICATION, ROUTE-REFRESH, CAPABILITY
bgp/path_attributes/     one file per path attribute (origin, as_path, communities, mp_reach...)
bgp/nlris/               prefix encodings (inet, labeled, VPN, RD, mapped IPv4)
                         flow_spec_component.rb: the RFC 8955 section 4.2.2 and
                         RFC 8956 section 3 flow spec components, and flow_spec.rb
                         the NLRI that carries them, with the section 4.1 length
                         framing and the section 8 RD. Both are wired in now, so
                         a flow spec UPDATE reads and writes: Nlri.factory and
                         MpReachCommon#set dispatch to them, and the two parse
                         loops in mp_reach.rb and mp_unreach.rb ask
                         MpReachCommon::ClassMethods#nlri_size how long an NLRI is
                         rather than computing it from a prefix length.
                         docs/flow-spec.md is the guide, see also
                         "Breadth, the one SAFI lever"
                         evpn_route.rb: the primitives the eleven EVPN route
                         types share, the Esi of RFC 7432 section 5, the
                         Ethernet Tag ID, the MAC and the length-prefixed
                         address, with the Route base and Evpn::Unknown under
                         them, the Flags octet of RFC 9251, the Region ID of
                         RFC 9572 and the Multicast_fields module that carries
                         the address triple, and **all eleven route types**:
                         the whole of RFC 7432 section 7, RFC 9136's IP Prefix
                         route, RFC 9251 sections 9.1 to 9.3 and RFC 9572
                         sections 3.1 to 3.3. Route type 11's Route Key is a
                         whole NLRI, so Leaf_a_d reaches Evpn at call time and
                         is the one class here that does not work against
                         evpn_route.rb alone;
                         evpn.rb the NLRI with
                         the section 7 Route Type and Length framing and
                         Evpn.nlri_size. Both are wired in now, so an EVPN
                         UPDATE reads and writes: Nlri.factory and
                         MpReachCommon#set dispatch on AFI 25 SAFI 70, the two
                         parse loops ask nlri_size, and parse_next_hops reads
                         the RFC 7432 section 14 next hop by its length, since
                         the AFI is 25 for both families. Evpn::ROUTES holds
                         all eleven types; a type outside 1 to 11 reads back as
                         an Evpn::Unknown that replays byte for byte, and so
                         does a body a registered type cannot reproduce.
                         docs/evpn.md is the guide, see also
                         "Breadth, the one SAFI lever"
                         rt_constrain.rb: the RFC 4684 section 4 Route
                         Target membership NLRI, AFI 1 SAFI 132. Wired
                         in now, so a membership UPDATE reads and
                         writes: Nlri.factory and MpReachCommon#set
                         dispatch to it and parse_next_hops reads the
                         section 4 next hop by its length. It needs no
                         framing rule of its own, unlike the two
                         families above, because section 4's encoding is
                         the prefix arithmetic nlri_size already does,
                         and the route target inside it is partial by
                         design. See "Breadth, the one SAFI lever"
                         mcast_vpn_route.rb: the three primitives the
                         MCAST-VPN route types of RFC 6514 section 4 share,
                         the length-prefixed Addr for the Multicast Source
                         and Group, the 4-octet Source_as, and the
                         Originating_router that has no length field in any
                         document, with the Route base and
                         Mcast_vpn::Unknown under them, the
                         Source_and_group module that carries the Multicast
                         Source and Group pair for the four layouts that
                         have it, the C_multicast module that is the whole
                         of section 4.6, and **all seven route types**:
                         Intra_as_i_pmsi (4.1), Inter_as_i_pmsi (4.2),
                         S_pmsi (4.3), Leaf_a_d (4.4), Source_active (4.5)
                         and Shared_tree_join with Source_tree_join (4.6,
                         one layout and two type numbers). Route type 4's
                         Route Key is a whole nested NLRI on a reading the
                         documents do not settle, so Leaf_a_d reaches
                         Mcast_vpn at call time and is the one class here
                         that does not work against mcast_vpn_route.rb
                         alone;
                         mcast_vpn.rb the NLRI with the section 4 Route Type
                         and Length framing and Mcast_vpn.nlri_size, which
                         is Evpn.nlri_size again because the framing is the
                         same shape. Both are wired in now, so an
                         MCAST-VPN UPDATE reads and writes: Nlri.factory
                         and MpReachCommon#set dispatch on SAFI 5, the two
                         parse loops ask nlri_size, and parse_next_hops
                         reads the next hop by its length, which is RFC
                         6515's rule and not an analogy with EVPN's.
                         Mcast_vpn::ROUTES holds all seven, and a type
                         outside them reads back as an Unknown that
                         replays byte for byte, which is where RFC 7441's
                         three mLDP types land by decision.
                         docs/mcast-vpn.md is the
                         guide, see also "Breadth, the one SAFI lever"
                         link_state_tlv.rb: the one TLV of RFC 9552
                         section 5.1, which is one rule for the whole
                         family, with its registry, Tlv::Unknown, the
                         list reader, the section 5.1 ordering rule and
                         the **five shared value shapes** every other
                         file here builds on: Opaque32 a 32-bit
                         integer, Addr_tlv one address of a fixed
                         width, Opaque_tlv variable opaque octets,
                         Text_tlv a 7-bit ASCII name and Int_list_tlv a
                         list of integers whose element width is stated
                         once, by the subclass's PACK. Each was written
                         where its first user was and moved here once a
                         second of the RFC's tables wanted it, four in
                         part 5b-i and Int_list_tlv out of Srlg in part
                         5c, which changed no constant path because
                         every file in the family reopens
                         BGP::Link_state::Tlv;
                         link_state.rb the NLRI of section 5.2 with the
                         NLRI Type and Total NLRI Length framing,
                         Link_state.nlri_size, the SAFI 72 Route
                         Distinguisher and Link_state::Unknown;
                         link_state_descriptor.rb the whole of section
                         5.2.1, TLV 256 and 257 and the four sub-TLVs
                         of 5.2.1.4, where 256 and 257 are one layout
                         and two type numbers;
                         link_state_link_descriptor.rb the six of
                         section 5.2.2, where **Table 4 has no Length
                         column** so every width is a citation to
                         another RFC, and the MT-ID of 5.2.2.1 is this
                         family's first reserved field;
                         link_state_prefix_descriptor.rb the two of
                         section 5.2.3, whose widths Table 5 does
                         give; link_state_nlri.rb **all four NLRI
                         types**, with Headed carrying the
                         Protocol-ID, Identifier and TLV list that
                         figures 7 to 9 share, Node, Link and the
                         Prefix_nlri base under Ipv4_prefix and
                         Ipv6_prefix, which are one layout and two
                         type numbers. TLV 263 is registered once and
                         is in both of the RFC's tables.
                         **All four dispatch sites are wired now**,
                         so a BGP-LS UPDATE reads and writes in both
                         SAFIs: Nlri.factory and MpReachCommon#set
                         dispatch on SAFI 71 and 72, the two parse
                         loops ask nlri_size, and parse_next_hops
                         reads the section 5.5 next hop, which is
                         three-way where EVPN's and RT-constrain's are
                         two-way and whose VPN form prepends one zero
                         RD to the whole field rather than one per
                         address. **The SAFI reaches the parse gate**,
                         which only flow spec also needs: figures 5
                         and 6 differ by the Route Distinguisher and
                         by nothing in the octets, so the same capture
                         is valid read either way.
                         link_state_node_attribute.rb the six node
                         attribute TLVs of section 5.3.1 that are new,
                         1024 to 1029;
                         link_state_link_attribute.rb the thirteen of
                         section 5.3.2 that are new, 1030, 1031 and
                         1088 to 1098, where **Table 8 has no Length
                         column** so five widths are citations to RFC
                         5305 and RFC 5307, and with Float32_tlv, the
                         IEEE float two of them share;
                         link_state_prefix_attribute.rb **all six of
                         section 5.3.3**, 1152 to 1157, where Table 10
                         does give a Length and disagrees with its own
                         section about 1156, the OSPF Forwarding
                         Address, which is 4 or 16 and not the table's
                         4. 1154 is the family's only 64-bit field.
                         **So every attribute TLV RFC 9552 defines is
                         in**, all 25 code points across its three
                         tables. The attribute
                         that carries all of them is code 29 and is a
                         path attribute, so it lives in
                         bgp/path_attributes/link_state_attribute.rb
                         and goes through Attr.register rather than
                         either NLRI gate. TLV 263 is in Table 4 and
                         Table 6 and is one class, and 1028 and 1029
                         are in Table 6 and Table 8, which is the flat
                         registry paying for itself twice.
                         A TLV or NLRI
                         type with no class reads back as its level's
                         Unknown and replays byte for byte. **One flat
                         registry covers TLVs and sub-TLVs alike**,
                         which is IANA's doing: a sub-TLV number means
                         the same thing under every parent. Two
                         Unknowns one level apart, so write both names
                         in full. docs/bgp-ls.md is the guide, see also
                         "Breadth, the one SAFI lever"
bgp/optional_parameters/ OPEN capabilities (4-byte AS, add-path, graceful restart...)
bgp/orfs/                outbound route filtering
bgp/neighbor/            the BGP finite state machine and TCP session (neighbor.rb)
bgp/rib/                 routes and the decision process (RFC 4271 section 9); require 'bgp/rib'
                         peer_adapter.rb turns a Neighbor's UPDATEs into table operations,
                         peer_feed.rb applies them on one worker thread; rib.attach(neighbor)
                         export.rb decides what goes to a peer and what its attributes become,
                         adj_rib_out.rb records what was sent, update_builder.rb packs
                         prefixes into UPDATEs, mrai.rb paces them per destination,
                         router.rb joins them and sends; rib.advertise; show.rb prints
                         the Loc-RIB the way a router would, rib.show;
                         fib.rb plans what a forwarding table needs, ip_route.rb
                         builds and runs the iproute2 command and fib_installer.rb
                         joins them on the worker thread; rib.install;
                         see "Where the work is going"
bgp/misc/                extras: route_generator.rb (many prefixes packed in UPDATEs), live_feed.rb (a client for an old public BGP feed)
docs/                    protocol-testing.md: using bgp4r to test a router
                         flow-spec.md: RFC 8955 and RFC 8956 on the wire, as much
                         as is needed to write the encoding and decoding. Read it
                         before touching flow_spec_component.rb or flow_spec.rb,
                         before changing how mp_reach.rb and mp_unreach.rb frame
                         an NLRI, before touching the flow spec checks in
                         validation.rb, or before adding one of the missing
                         action communities. Its load bearing claims
                         are asserted by test/unit/flow_spec_doc_test.rb
                         evpn.md: RFC 7432 and six more RFCs on the wire. Read it
                         before touching evpn_route.rb or evpn.rb, before adding a
                         route type or an EVPN extended community, before touching
                         the EVPN checks in validation.rb, and before
                         changing how mp_reach.rb and mp_unreach.rb frame an NLRI.
                         Its load bearing claims are asserted by
                         test/unit/evpn_doc_test.rb, which **discovers** the route
                         type table rather than comparing it against a list, so a
                         route type class cannot join the library without the
                         document being told. Proved by sabotage in both
                         directions, which a listed table would have let through.
                         mcast-vpn.md: RFC 6514 and the two RFCs that
                         update it, **RFC 6515** and RFC 7441, on the wire.
                         Read
                         it before touching mcast_vpn_route.rb or mcast_vpn.rb,
                         before adding a route type, before changing how
                         mp_reach.rb and mp_unreach.rb frame an NLRI or read
                         a next hop, and
                         before putting an MCAST-VPN check in validation.rb.
                         Its load bearing claims are asserted by
                         test/unit/mcast_vpn_doc_test.rb, whose route type
                         table **and** section 8 check table are
                         **discovered** rather than listed. **All four of
                         part 1's forward-looking guards have now fired
                         and been re-pointed rather than weakened**, which
                         is what they were for: the no-route-type one, the
                         no-dispatch one, the one that said no document
                         gives the Originating Router a width, and the one
                         that said validation.rb knew nothing of this
                         family. So nothing here is waiting on a later
                         part any more. The section 8 count is discovered
                         differently from evpn_doc_test.rb's, by the arms
                         of mcast_vpn_route_finding's case rather than by
                         Finding.new, because RFC 6515 states one sentence
                         four times and the library answers it once
                         bgp-ls.md: RFC 9552 on the wire, the whole
                         document, which was attached rather than fetched
                         because four sources truncate it in section 5.2
                         or 5.3. Read it before touching
                         link_state_tlv.rb or link_state.rb, before
                         adding a TLV type or an NLRI type, before
                         changing how mp_reach.rb and mp_unreach.rb frame
                         an NLRI or read a next hop, and before putting a
                         BGP-LS check in validation.rb, whose scope
                         section 8.2.2 **narrows** rather than widens;
                         section 3c is the link and prefix descriptors,
                         and its width table is the only place each
                         citation lives, since Table 4 of the RFC
                         gives no widths at all. Section 8.2.2:
                         it lists four kinds of semantic check bgp4r
                         makes for other families and says not to make
                         them here. Its load bearing claims are asserted
                         by test/unit/bgp_ls_doc_test.rb, whose NLRI type
                         and TLV code point tables are both
                         **discovered** and which carries
                         forward-looking guards for the later parts;
                         four of six have now fired and been re-pointed.
                         Section 11 is interoperability, and it is the
                         only one of the four family guides whose lab
                         measures **both** directions: GoBGP can
                         originate a BGP-LS route, so its encoder feeds
                         our decoder. Read it before trusting either
                         direction, because what each vouches for is
                         not the same and the receive one cannot check
                         the framing at all.
                         **It requires every file that registers**, and
                         that is a requirement rather than tidiness: the
                         two registries are mutable and filled across
                         files, so a run that loaded only some of them
                         measures a subset and says so with confidence.
                         Part 2's two guards passed standalone and
                         failed in the suite for exactly that reason
                         building-objects.md: the three ways into every class and how
                         initialize dispatches between them; read it before changing a
                         constructor or chasing an object that does not come back.
                         Its load-bearing claims are asserted by
                         test/unit/building_objects_test.rb
                         routescope-labs.md: how bgp4r becomes a node the
                         routescope console can drive, and the eight labs
                         worth building once it is, with **section 9** the
                         `bgp4r-sim` injector in detail: the config that
                         brings a session up, its actions, and the
                         scenarios that drive it. Mostly a **design**:
                         little of its sections 6 to 10 exists yet, and
                         every fact in it about routescope or ospfv2 is a
                         read of another repository at a named commit,
                         which this suite cannot assert. The exception is
                         **section 8's porting subsection**, which says
                         which of the 23 files in test/functional/lab/
                         want to be scenarios and which do not, with
                         lab/topologies/add-path as a worked example that
                         exists and has a test. Read that one before
                         porting any other lab test. Its section 12 says
                         which claims become assertable here and when.
                         Read it before adding an executable, a state
                         dump, a capture command, an action API or a lab
                         topology, because each of those has a contract
                         in it
examples/                runnable scripts
test/unit/               unit tests, mirroring bgp/
test/functional/         tests that open real TCP sessions
test/helpers/            a small test BGP server
lab/                     speakers in containers: lab/speaker.rb and lab/topologies/ (see lab/README.md)
                         lab/fault_matrix.rb sends BGP::Fault::CATALOG to a router; lab/conformance/ has a config per router
                         lab/topologies/fault-matrix runs that matrix against GoBGP in one command, and in CI
test/functional/lab/     lab tests: loopback speaker test and one Compose test per topology;
                         speaker_test.rb also checks the capability names a topology can ask for;
                         fault_matrix_scenario.rb holds the RFC 7606 checks, and both
                         fault_matrix_test.rb (Compose) and fault_matrix_native_test.rb
                         (a gobgpd on loopback, no Docker) assert them;
                         rib_router_gobgp_test.rb points bgp4r's export side at a
                         native gobgpd, so a real router says what it makes of it,
                         and add_path_gobgp_test.rb does the same for RFC 7911;
                         fib_test.rb puts the Loc-RIB in a real kernel routing
                         table inside a network namespace, no Docker, needs root;
                         fault_matrix_frr_test.rb runs the same matrix against
                         FRR's bgpd, standalone on loopback, no Docker and no zebra,
                         and rib_router_frr_test.rb points our export side at it;
                         flow_spec_gobgp_test.rb and flow_spec_frr_test.rb send a
                         flow spec rule to each and assert what it reads back,
                         which is the only check on our components, operator
                         octets and section 4.1 length that is not bgp4r's own
                         opinion. They send only; see docs/flow-spec.md section 12;
                         evpn_gobgp_test.rb and evpn_frr_test.rb do the same for
                         EVPN, and both routers know route types 1 to 5 only, so
                         the other six are asserted as ignored without the session
                         dying. GoBGP is the only check on route type 5's GW IP,
                         and FRR is the one that sends 3/9 on a malformed NLRI,
                         which is what part 9 chose. They send only too; see
                         docs/evpn.md section 9;
                         rt_constrain_gobgp_test.rb does the same for
                         RT-constrain, and has no FRR twin because FRR
                         8.4.4 has no such family. It carries the two
                         GoBGP 3.23.0 crashes this family found, one of
                         them on entirely conformant traffic;
                         attr_set_gobgp_test.rb is the only one that runs
                         a router **in the middle**, two bgp4r speakers
                         with a gobgpd between them, because RFC 6368's
                         ATTR_SET exists to survive transit and neither
                         router implements it. LabHelper::Gobgpd's peer2
                         is what makes that possible;
                         mcast_vpn_gobgp_test.rb and
                         mcast_vpn_frr_test.rb are the only two that
                         measure an **absence**: neither router has
                         SAFI 5, so they assert how each says so and
                         what it does with an MCAST-VPN UPDATE sent
                         anyway, where GoBGP discards it and FRR resets
                         the session. They vouch for nothing about our
                         octets;
                         link_state_gobgp_test.rb is the **only one here
                         that measures both directions**, since GoBGP
                         can originate a BGP-LS route, so its encoder
                         feeds our decoder as well as its parser reading
                         what we send. It also carries the two GoBGP
                         3.23.0 faults this family found and the
                         ordering finding that decided part 6's scope;
                         link_state_frr_test.rb is an absence again,
                         FRR 8.4.4 having neither SAFI, and FRR cannot
                         name the AFI either where for MCAST-VPN it
                         could
```

## Running tests

Ruby 3.3, 3.4 and 4.0 are supported and tested in CI. Tests use test-unit. The load path is the repo root, so pass `-I.` when you run a single file.

All unit tests:
```
ruby test/run_unit.rb
```
`rake test` runs the same files.

One file:
```
ruby -I. test/unit/path_attributes/as_path_test.rb
```

Functional test over loopback (port 3456):
```
ruby -I. test/functional/add_path_test.rb
```

Route generator over loopback: `examples/routegen` against the test server, with `bgp/misc/route_generator.rb` doing the prefixes:
```
ruby -I. test/functional/routegen_test.rb
```

A table fed by a real session over loopback, the whole path from socket to Loc-RIB:
```
ruby -I. test/functional/rib_feed_test.rb
```

Three speakers over loopback, so a route crosses a bgp4r router and comes out with the export rules applied: transit and route reflection.
```
ruby -I. test/functional/rib_router_test.rb
```

A flow spec UPDATE over a real session, which is the only test that proves
the four wiring sites agree with each other, since both sides are pure and
each unit test reads octets it wrote itself:
```
ruby -I. test/functional/flow_spec_test.rb
```

The same for an EVPN UPDATE, AFI 25 SAFI 70, and the only test that
proves its five wiring sites agree. It also carries the one case that
puts an NLRI inside an NLRI, route type 11's Route Key, and the only
place the receive side checks run on octets that crossed a socket
rather than ones a test wrote. About a second:
```
ruby -I. test/functional/evpn_test.rb
```

The same for an RT-constrain UPDATE, AFI 1 SAFI 132, and the only test
that proves its three wiring sites agree. Under a second:
```
ruby -I. test/functional/rt_constrain_test.rb
```

The same for an MCAST-VPN UPDATE, SAFI 5, and the only test that proves
its four wiring sites agree. **For this family it is the only check
there is**, since neither lab router carries SAFI 5, so do not read it
as interoperability; see `docs/mcast-vpn.md` section 9. Under a second:
```
ruby -I. test/functional/mcast_vpn_test.rb
```

The same for a BGP-LS UPDATE, AFI 16388 SAFI 71 and 72, and the only
test that proves its four wiring sites agree. It carries the only cases
in this family that send a two-address next hop, a VPN NLRI and an
unknown NLRI type beside a known one over a socket, and the one that
reads the same octets under both SAFIs to show the SAFI is a parse time
input. Its last two cases are not about a wiring site at all, since the
BGP-LS Attribute goes through `Attr.register`: they are here because
this is the only place the NLRI and the attribute that describes it
travel together over a socket: part 5b-ii added the link attribute TLVs
beside a Link NLRI and part 5c the prefix attribute TLVs beside a Prefix
NLRI, which is the pairing section 5.3.3 names. Part 6b added the one
case where a BGP-LS check runs on octets that crossed a socket, as
`evpn_test.rb` and `mcast_vpn_test.rb` each carry one. About a second:
```
ruby -I. test/functional/link_state_test.rb
```

The Loc-RIB in a real kernel routing table, inside a network namespace of
its own, so nothing can touch the routing table of the machine it runs on.
No Docker. It needs root, or any way to get CAP_NET_ADMIN, and omits
itself without it unless `LAB_REQUIRE_NETNS=1` asks for a failure instead:
```
sudo ruby -I. test/functional/lab/fib_test.rb
```

Lab tests (the Compose ones skip without Docker, the native fault matrix
without `gobgpd`, the FIB one without root):
```
ruby test/run_lab.rb
```
One group, which is how CI runs them, a job each. `test/lab_groups.rb`
says which file is in which group and why, and
`test/unit/lab_groups_test.rb` fails the unit suite until every lab test
file is in exactly one group and every group has a job, so neither can
drift:
```
ruby test/run_lab.rb --groups
ruby test/run_lab.rb gobgp-matrix
```

Against a real router, with no Docker at all. These need `gobgpd` on
`PATH`, or `GOBGPD` and `GOBGP` naming the binaries, which is how one
machine answers for more than one GoBGP version. Measured on 2026-10-31
against gobgpd 3.23.0: the fault matrix 2 minutes, `rib_router` 29
seconds, `add_path` 35 seconds. The matrix was more than twice that
before it passed `--dial`; see "Lab and conformance" below.
```
ruby -I. test/functional/lab/fault_matrix_native_test.rb
ruby -I. test/functional/lab/rib_router_gobgp_test.rb
ruby -I. test/functional/lab/add_path_gobgp_test.rb
```

The same matrix against a second implementation, FRR's `bgpd`, also with
no Docker and no zebra. It needs the FRR package, whose `bgpd` is not on
`PATH`: `/usr/lib/frr/bgpd` is looked for, and `FRR_BGPD` and `VTYSH`
name them elsewhere. No root: `bgpd` runs with `-S` so it keeps the
invoking user, and both ends get ports of their own. Checked as a
non-root user and not only as root, because the difference is not
nothing: `vtysh` cannot read `/etc/frr/vtysh.conf` without the `frrvty`
group and prefixes a warning to every answer, which broke the first CI
run of this. 25 seconds, measured on 2026-10-31 against bgpd 8.4.4, and
about twice that before it passed `--dial`:
```
ruby -I. test/functional/lab/fault_matrix_frr_test.rb
```

And bgp4r's export side against FRR, the twin of the GoBGP one. 4
seconds, which the "about a minute" recorded here until 2026-10-31 was
simply wrong about:
```
ruby -I. test/functional/lab/rib_router_frr_test.rb
```

A flow spec rule from bgp4r read back by each router, which is the only
check on our components, operator octets, section 4.1 length, RFC 8956
offset and section 8 RD that is not bgp4r's own opinion. 61 and 45
seconds, and both need the binaries above:
```
ruby -I. test/functional/lab/flow_spec_gobgp_test.rb
ruby -I. test/functional/lab/flow_spec_frr_test.rb
```

The same for EVPN. Both routers know route types 1 to 5 only, so the
other six are asserted as ignored without the session dying. GoBGP is
the only check on route type 5's GW IP Address, since FRR prints a
constant there, and FRR is the one that answers a malformed NLRI with
3/9, which is what `validation.rb` reports for the same octets. 71 and 15
seconds, where the second was recorded as a minute until it was measured:
```
ruby -I. test/functional/lab/evpn_gobgp_test.rb
ruby -I. test/functional/lab/evpn_frr_test.rb
```

An ATTR_SET carried **through** a gobgpd rather than read back by one:
two bgp4r speakers with the router between them, which is what an
optional transitive attribute is for and the only lab test here shaped
that way. 50 seconds, measured on 2026-10-31 against gobgpd 3.23.0:
```
ruby -I. test/functional/lab/attr_set_gobgp_test.rb
```

The two that measure an **absence**: neither router has SAFI 5, so
these assert how each says so and what it does with an MCAST-VPN UPDATE
sent anyway, where the two disagree. 30 and 7 seconds:
```
ruby -I. test/functional/lab/mcast_vpn_gobgp_test.rb
ruby -I. test/functional/lab/mcast_vpn_frr_test.rb
```

BGP-LS, and the **only lab test here measured in both directions**:
GoBGP 3.23.0 can originate a BGP-LS route, so its encoder feeds our
decoder as well as its parser reading what we send. It carries the two
GoBGP faults this family found, both deterministic and both asserted,
and the ordering finding that decided part 6's scope. Its FRR twin is
an absence again, FRR 8.4.4 having neither SAFI. 87 and 6 seconds:
```
ruby -I. test/functional/lab/link_state_gobgp_test.rb
ruby -I. test/functional/lab/link_state_frr_test.rb
```

Which `#to_hash` read back and which do not, printed from
`test/unit/to_hash_catalog.rb` rather than written down anywhere:
```
rake to_hash:status
rake to_hash:pending
```
`rake` is not on PATH everywhere, so without it:
```
ruby -I. test/unit/to_hash_status.rb
ruby -I. test/unit/to_hash_status.rb pending
```

Do not run `test/functional/live_feed_test.rb`. It connects to a public feed that no longer answers and hangs forever.

In Docker, on any Ruby version (the default is 3.4):
```
docker build --target test --build-arg RUBY_VERSION=4.0 -t bgp4r-test .
docker run --rm bgp4r-test
docker run --rm bgp4r-test ruby -I. test/functional/add_path_test.rb
```
The image runs as the non-root user `bgp`. It can still bind TCP 179, because Docker sets `net.ipv4.ip_unprivileged_port_start=0` in a container's own network namespace. With `--network host` the host's setting applies.

CI: `.github/workflows/test.yml` runs both suites on every push to master and every pull request, on Ruby 3.3, 3.4, 4.0 and head (head may fail), both on the runner and in the Docker image. The `lab` job is a matrix, one job per group in `test/lab_groups.rb`, so its cost is the slowest group and not the total: it was 12m42s as one serial suite. Each job installs only what its group needs, which is why the matrix entry carries a `gobgp`, `frr`, `docker` or `netns` flag. The `gobgp` groups pin 3.23.0, where the Compose topology pins a 4.x image, so CI measures both.

Baseline on 2026-11-01: 2412 tests, 28774 assertions, all passing. Line coverage of `bgp/` from the unit suite: 98.5%.

There is no coverage gem in the `Gemfile`. To measure, use Ruby's built-in `Coverage`: start it, register the report with `at_exit` before requiring any test file so it runs after the suite, then require `test/unit/**/*_test.rb`.

## Conventions

* **Building and encoding are never validated, and that is a feature.** This library is used for negative testing: it has to put bytes on the wire that no RFC allows, so a real router can be watched handling them. Any attribute, any length, any combination, any flags. Never add a check to a constructor, to `encode`, or to `to_hash` that refuses something merely invalid. Removing that ability breaks the main reason the library exists.
  * Validation lives in exactly one place, `bgp/path_attributes/validation.rb`, and runs only when parsing what was received. It is reported through `Path_attribute#errors` and raised only under the `:strict` receive policy. Add a rule there, with its RFC section, never in the attribute.
  * `Path_attribute#errors` means what the peer got wrong, and nothing else. A valid attribute bgp4r cannot decode is bgp4r's coverage gap, not a protocol error: RFC 7606 section 7 says attribute by attribute what makes one malformed, and a reader's missing code is on none of those lists. Those go in `Path_attribute#undecoded` as `Attr::Gap`, which `:strict` never raises on. Do not put a fact about bgp4r in `errors`; a conformance tool that calls its own gap a protocol error gives a confident wrong verdict about a correct router.
  * A constructor may refuse an input it cannot represent at all, such as an Integer too large for the field it goes in, because the alternative is silently sending a different value. It must never refuse a combination that is simply wrong by the RFC. Where a constructor does refuse, the octet level routes stay open and must keep working: wire bytes, `Attr::Raw`, and the `BGP::Fault` helpers.
  * **The message header Length is computed, not configurable, and that is deliberate.** `Message#encode` writes `message.size + 19`, and `Message#parse` unpacks the field into `_` and discards it. A tool for testing the protocol needs the header arithmetic right every time or every other result it produces is in doubt, so `encode` takes no length argument and **should not grow one**: that plumbing belongs in the test, not in the library. A test that wants a wrong Length overrides `encode` at runtime on the one object it is lying with, and `bgp/io.rb` writes `obj.encode` at send time, so the override reaches the wire through the ordinary `send_message` path while the class stays untouched: `u.define_singleton_method(:encode) { |*a| s = super(*a) ; s[16,2] = [9999].pack('n') ; s }`. Patching the encoded String and passing that to `send_message`, which takes a String and queues it unchanged, is the other route. Checked against GoBGP, which took the octets as written and waited for the rest of the length it had been promised. An earlier version of this file filed this as a bug, calling the Length the one field that cannot be made to lie. That was wrong twice over.
  * **A path attribute's own header is made to lie through `Attr::OVERRIDE_KEYS`, and that mechanism shadows an option name.** `Attr.new` pops a trailing Hash whose keys are **all** of `[:flags, :type, :length]` and hands it to `override`, so `Origin.new(:igp, :flags => 0x40)` writes a wrong flags octet with the class untouched. The catch is `Pmsi_tunnel`, whose RFC 6514 section 5 value begins with a flags octet of its own: `Pmsi_tunnel.new(:no_tunnel, nil, :flags => 0x41)` sets the **header** flags and never reaches that octet, where `Pmsi_tunnel.new(:tunnel_type => :no_tunnel, :flags => 0x41)` sets the octet, because `:tunnel_type` is not an override key and so the Hash is not popped. A Hash carrying any other key is left alone too, which is why `:label => 100, :flags => 1` reaches the octet after all and made this look like it depended on the number of keys. Measured on 2026-10-30 after an hour chasing it as a bug; `test_the_flags_option_is_the_header_override_at_the_multi_arg_call_site` pins both meanings. Nothing here is worth renaming: the override facility is the reason the library exists and `to_hash` goes through the single Hash form, which always reaches the octet.
  * `lab/fault_matrix.rb` and `BGP::Fault::CATALOG` depend on all of this. `docs/protocol-testing.md` is the guide to it.
* When parsing cannot interpret something at all, keep it whole and write it back. The family of classes for that is one per level: `Path_attribute::Unknown`, `Optional_parameter::Unknown` for a Parameter Type bgp4r does not implement or a Parameter Length that overruns its octets, `Capability::Unknown` one level down inside a Capabilities parameter, and `Orf::Unknown` for an ORF type. Each builds three ways and keeps the declared length when it disagrees with the value, so a malformed capture can be sent again.
* When parsing cannot interpret trailing octets, keep them and write them back, so `encode` returns byte for byte what arrived. `prefix_sid.rb` keeps a `@tail`, `pmsi_tunnel.rb` keeps a value too short to read in its own `@tail`, and `communities.rb`, `cluster_list.rb`, `extended_communities.rb`, `large_communities.rb` and `ipv6_extended_communities.rb` all keep a tail. Report the fault in `validation.rb`; do not drop the octets.
  * The hash forms carry a kept tail as one `{:tail=>hex}` entry at the end of the value list, so `sort`, `sort!`, `uniq` and `to_hash` keep it as `encode` does. `Attr::TAIL_KEY`, `Attr#tail`, `Attr#tail_entry` and `Attr#take_tail` do it in one place; an attribute with no tail has no such entry, so its hash is the plain list it has always been.
  * `prefix_sid.rb` and `pmsi_tunnel.rb` hash under a nested hash rather than a value list, so they carry the tail as a `:tail` key inside that hash. `Attr#take_tail_key` reads it back. Same rule: no tail, no key.
  * `path_attribute.rb` keeps a tail too, one level up: the octets after the last whole attribute in the set, which `parse_wire` holds so `encode` gives back what arrived. Its hash is one key per attribute, so the tail is one more key, `Attr::TAIL_KEY` again, and `new` takes it off a **copy** of the caller's hash before iterating, so the key never reaches `Attr.by_key` and the caller can build twice from one hash. Same rule: no tail, no key, and an ordinary attribute set hashes as it always did.
  * `Path_attribute::DUP_KEY`, `:duplicates`, is the same rule for the other thing one key per type cannot hold: a second attribute of a type already in the hash. The occurrences after the first ride in a list of their own hashes and `new` builds them after the distinct types, so no attribute is dropped and an ordinary set has no such key. A repeat that arrived **before** a type it does not repeat comes back in that order rather than its own, which is normalising and not a loss: nothing in BGP orders path attributes, and `Path_attribute#<=>` says so by sorting each side before comparing. Note what that `sort` does and does not do, since a test may lean on it: it sorts by type code only, so two attributes of one type keep their relative order and `<=>` answers non-zero for two sets that differ only in which of them came first. Compare the multiset of each attribute's own octets when that matters.
  * A reserved field inside a fixed layout value is the same rule one level down. An `Extended_community::Typed` parsed from the wire keeps its 6 value octets, so `encode` gives them back, and its hash carries a `:bits` entry, all 48 bits of the value, when a bit outside the fields its own RFC defines is set. `DEFINED_BITS` on the class says which bits it reads, with the RFC text beside it, and `Typed#value_bits`, `#undefined_bits?`, `#keep_bits` and `#with_bits` do the rest in one place. Same rule as a tail: no reserved bit set, no `:bits` entry, so the hash stays the value or the list it has always been. `Traffic_action` is where the shape came from. A build from field values still writes the reserved fields as 0, which is what those RFCs ask an encoder for.
    * **Echoing a reserved field is the intended behaviour, confirmed by the owner on 2026-10-29**, and the reason is the one in the first Conventions bullet rather than anything in the RFCs: a reserved octet arriving as `0xff` is a negative test, and a tool that can send a value no RFC describes but cannot replay what it just sent is the wrong shape of tool. So the keep-and-echo rule is not up for revisiting as over-engineering. It is worth knowing it is **recent**: #77, #145, #155 and #167 added it across 2026-10-26 to 2026-10-29, where the rest of the library is a decade older, so a class that writes a reserved field as 0 has simply not been reached yet.
  * `Prefix_entry` is the second instance, since #155, and the smallest: RFC 5291 section 4 puts Action in two bits, Match in one and "Reserved is a 5-bit field. It is set to 0 on transmit and ignored on receipt", all in one octet. `DEFINED_BITS = 0xe0` says which bits it reads, `Prefix_entry#bits` keeps all 8 when a reserved one arrived set, and the hash gains `:bits` only then. The one octet REMOVE-ALL entry goes through the same `_first_octet_`, so it is covered by the same change.
* Every class can be built three ways: from field values, from a hash, and from its wire bytes (a binary String). Most take a fourth, another instance of the class, which they re-parse through its `encode`. Keep them all working when you change a class. **`docs/building-objects.md` is the guide**: the branch order `initialize` uses, why a binary String is recognised only by its `is_packed?` mark and what it does when the mark is missing, how the attribute registry turns a hash key into a class, and a checklist for an object that does not come back. Read it before changing a constructor, and paste it into a session that is debugging one. Its load-bearing claims are asserted by `test/unit/building_objects_test.rb`, because a primer nothing checks goes stale and a reader who trusts a wrong primer loses more time than one with no primer at all. Writing that guard immediately corrected two claims in the document, which is the argument for it.
  * **Two of those claims are worth knowing even without the document.** A constructor may **consume** the String it is handed, since `parse` reads with `slice!`: `Origin`, `Aggregator`, `Communities` and `Path_attribute` all empty it and `Nlri` does not, so pass a `dup` if you need the octets afterwards. This is what makes `assert_equal(octets, Klass.new(octets).encode)` fail while both sides print the same hex, because the left side was emptied before the comparison ran; compare `to_shex`. And **not every class reads wire bytes**: `Prefix` takes a prefix string, and octets are the business of `Nlri` or `Withdrawn`, which slice them, so binary handed to `Prefix` dies inside `IPAddr` whether it is marked or not.
* `encode` returns wire bytes. `to_hash` returns a hash that round trips through `new`. `to_s` returns the human readable form.
  * **A generic `encode` in the parent, finalized by `super` in the child, is a deliberate shape here and not an accident.** Measured on 2026-10-29, after a session read "base encode" as a git revision and the owner meant the parent method. Two instances. `Orf#encode` writes the whole RFC 5291 section 4 layout, ORF Type, Length and the entries joined, and `Prefix_orf` does **not** override it: the subclass supplies `Entry` objects and never touches encoding. On the capability side it is three layers, each wrapping the one below: `CAP::Orf#encode` joins its entries and hands them to `Capability#encode`, which wraps them in code and length and hands that to `Optional_parameter#encode` with `extended:`. So when a field is missing from the wire, find which layer owns it before editing: a plain class nested inside one of these, such as `CAP::Orf::Entry`, has `Object` for a superclass and no `super` at all, so its own `encode` is the only place its octets can come from.
  * **That round trip is kept by most classes and broken by some, and the record is `test/unit/to_hash_catalog.rb`**, one entry per class, with what the hash loses, a reproduction, and what has been decided about it. Read it before assuming a hash form works or assuming it does not; both have been assumed wrongly here. **Do not write the counts down anywhere**, including here: `rake to_hash:status` prints them, and `rake to_hash:pending` prints what is still to fix. Without rake, which is not on PATH everywhere, `ruby -I. test/unit/to_hash_status.rb` and the same with `pending`. Every line of that output is read out of the catalog, which the suite measures against the library on every run, so a number it prints cannot be stale without a test failing first.
    * **There used to be a document, `docs/to-hash-round-trips.md`, and it was retired rather than updated.** Its table was generated from the catalog and stayed true. Its prose was not and did not: it spent four pull requests ranking work that two of them had already finished, in the same file as the table that was correct. The generated view replaced it once the root cause was understood, which is that a hash is an argument to `initialize` and what has to come back is the instance state, so a field no key sets cannot survive. Every lossy entry is an instance of that one sentence, which is why 97 paragraphs of prose were not buying anything a list and a reason each does not.
  * **The rule is one way: a gap may stay a gap, a round trip that works must not stop working.** The hash form exists so test code can be written as values rather than hex, so a working round trip is something other people's tests are already built on. `test/unit/to_hash_round_trip_test.rb` enforces that, from declarations in `test/unit/to_hash_catalog.rb`: breaking a working one fails the suite, and closing a gap fails it too, so the record is struck rather than left reading as verified. A new class answering `to_hash` and listed in neither place also fails, so it has to be measured and decided.
  * **`Klass.new(Klass#to_hash)` was never the contract, which is why 38 of those 97 read back through their attribute rather than themselves.** These classes were written test first: the hash build test came first, then `initialize` until it passed, then `to_hash` written to answer the hash that test had used. So `new` reads the **bare** hash a test writes, `Aggregator.new(:address=>..., :asn=>...)`, while `to_hash` answers the **wrapped** form, `{:aggregator=>{...}}`, because `Path_attribute#to_hash` merges one key per attribute and `Extended_communities` does the same for its list. Both halves work and neither is a defect. Do not "fix" one by adding a Hash branch for the wrapped form without a reason beyond symmetry.
  * The same history explains the rows that do lose information: each is a field that entered the object **after** the hash shape was settled, so no construction hash ever carried it. The reserved bits and tails came with the keep-what-you-cannot-read work, `Mpls_label_stack`'s TC and TTL and `Label_stack`'s Rsrv only arrive by parsing, and `Labeled`'s Path Identifier is RFC 7911 and later than the class. `CAP::Add_path`, `CAP::Graceful_restart` and `CAP::Orf` were the clean case: all three had **no hash build test at all**, so no `to_hash` was ever written for them and they inherited `Capability`'s bare `{:code=>n}`, where every capability that did round trip had such a test. All three are fixed, and the moral stands: a class with no hash build test is where to look first.
  * **Requirement: if an object can be rebuilt from its own `to_hash`, a test must prove it.** A working round trip is a feature and needs a test like any other. Where `Klass.new(obj.to_hash)` reproduces `obj`'s wire bytes, something must assert that, in two places, both required:
    * **The class's own test file**, which is where a reader looks. Build the object, feed its own hash back to `new`, and compare `encode` with the original. Exercise every field the object carries, since an assertion that misses a field passes for the wrong reason.
    * **Its entry in `test/unit/to_hash_catalog.rb`**, which is what makes the guarantee hold across the library rather than one class at a time, and what fails the suite when a working round trip stops working.
    The converse is not required, and that asymmetry is deliberate. The hash form is a convenience for people reading test code, not part of the protocol, so a class whose hash does not read back is allowed: it gets an entry in `test/unit/to_hash_catalog.rb` with what it loses, a reproduction and a decision. What is not allowed is a round trip that works with nothing saying so, because an untested round trip is a claim rather than a feature, and the next person to change the class has nothing to tell them they broke it. Both halves are enforced rather than asked for: `test_the_round_trips_that_work_still_work` covers the catalog half, and `test_every_working_round_trip_is_asserted_in_a_class_test_file` covers the other, so a working round trip that nothing asserts fails the suite. Its match is loose on purpose, a line naming `to_hash` and a constructor in a file naming the class, because it is answering "does anything assert this at all" and not policing which file does.
  * A recipe in that catalog has to exercise every field the class carries. Three thin ones passed for the wrong reason while it was written: `Label_stack.new(100,101)` never sets the Rsrv bits its hash drops, `CAP::Orf.new(1,1,[64,3])` quietly builds a capability with no ORF entries, and `Mpls_label_stack.new(100,200)` sets neither the TC nor the TTL that a parsed stack loses. Where a field only arrives by parsing, parse.
* Tests check round trips: build, encode, parse back, compare. Use real hex captures from the RFCs or from Wireshark when possible.
* One test file per source file, same name with `_test.rb`, in the matching folder under `test/unit/`.
* Write `BGP::` names out in full in a test file, and `include` into the test class, never at the top level. A top level `include` goes into `Object`, so every test file the suite loads after it sees those names, and `BGP::OPT_PARM::CAP` wins the ones it shares with `BGP`: a bare `Orf` then means the ORF capability and not `BGP::Orf`, and a bare `Route_refresh` the capability and not the message. A test written that way passes on its own and fails in the suite. `test/unit/neighbor/neighbor_test.rb` did this until it was fixed, and `test_no_test_file_leaks_bgp_names_into_object` there now guards it for the whole suite, since `run_unit.rb` requires every file before any test runs.
  * A nested class does **not** see the `include` in the class around it, because constant lookup goes up the lexical scope and then the ancestors of the innermost class, not the ancestors of the enclosing one. `TestBgpNeighbor::UpdateCatcher` resolved `Update` only through that top level leak. Write the full name in a nested class.
  * **The mirror image of that leak: a test file that does not require what it names passes in the suite and fails on its own.** `run_unit.rb` requires every file before any test runs, so one file's requires cover every file after it. `as_path_test.rb` asserted on `Path_attribute` without requiring it and `extended_community_test.rb` built an `Extended_communities` without requiring it, both found in one afternoon, and both pass `ruby test/run_unit.rb` and fail `ruby -I. <that file>`. So the two load order traps fail in opposite directions, and **one run cannot catch both**: run a file you changed on its own as well as in the suite.
  * A `NameError` in an observer is invisible: `Neighbor` logs an exception from an observer rather than raising it, deliberately, so nothing outside can kill the FSM. A test observer with a wrong constant therefore fails as "nothing was received" and says nothing about the name. That is how the leak stayed load bearing.
* **A test method defined twice in one class never runs either, and that is the second shape of the same silent skip.** The second definition replaces the first and Ruby says nothing, so the tell is the same as the `private` one below: a test count lower than `grep -c 'def test_'`. It cost a cycle in #226, where a new case in `test/functional/link_state_test.rb` took the name of one already there: 20 tests reported with 21 defined, and the case that vanished was the one being asserted against. `test_no_test_file_defines_a_test_method_twice` in `test/unit/neighbor/neighbor_test.rb` guards the whole suite now, beside the include-leak guard, which is already this repo's home for a guard over every test file.
  * **Its first two drafts were wrong and each failure named the tree while the fault was the guard**, which is worth knowing before writing another textual guard over source. It has to be scoped **per class**, because ten files here hold more than one test case and `test_1` in each of `Label_Test` and `Label_stack_Test` is two methods. And the name pattern has to take a trailing `!` or `?`, because `\w+` stops before it and `test_sort!` then collides with the `test_sort` beside it in `extended_communities_test.rb`. Sabotage a guard like this, and also read what it reports on a clean tree.
* **A test method after `private` in a test file never runs, and nothing says so.** `test/unit/path_attributes/mp_unreach_test.rb` keeps an `attr_len` helper under a `private`, and two tests appended after it in #161 left the file reporting 7 tests where 9 were defined: test-unit collects public methods only, so both were skipped in silence and the file passed. It was the regression check that caught it, not the run, because proving a new test fails against the unfixed code is the one thing a skipped test cannot do. Add tests above any `private`, and if a count looks low, compare it against `grep -c 'def test_'`.
* Two space indent. Match the style of the file you edit.
* Copyright headers. A new Ruby file or Dockerfile starts with the standard GPL header from `bgp/observable.rb`, with `Copyright <current year> Jean-Michel Esnault.` (a Dockerfile drops the `#--` and `#++` lines). When you change a file that has a header, add the current year to its years if it is missing: `2008, 2009` becomes `2008, 2009, 2026`. Do not add headers to files that never had one. YAML, Markdown and other config files get no header.
* Keep the library free of runtime gem dependencies. The one exception is `logger`: it ships with Ruby, but Ruby 4.0 made it a bundled gem, so `bgp4r.gemspec` and the `Gemfile` declare it.
* Before requiring a standard library, check that it is still a default gem. Ruby keeps moving libraries to bundled gems (`observer` in 3.4, `logger` in 4.0, **`base64` in 3.4**), and under Bundler those fail to load unless declared. Prefer a small built-in copy, as with `BGP::Observable`.
  * **This rule applies to test files too, and it was broken the day after it was written down.** `attr_set_gobgp_test.rb` required `base64` for one decode. It passed here on Ruby 3.3, where `base64` is still a default gem, and **failed CI on 3.4 before a single test ran**: `cannot load such file -- base64`, from `run_lab.rb`'s require loop, with the whole `gobgp-families` job red after 10 seconds. `ruby -e 'Gem::Specification.find_by_name("base64").default_gem?'` is the one line that answers the question, and it answers it per Ruby version, so the local answer is not the CI answer.
  * **The replacement is core and needs no require**: `String#unpack1('m0')` is strict base64 decoding, which is what `Base64.strict_decode64` meant, and `'m'` is the lenient form. Reach for `pack`/`unpack` before a Gemfile entry; adding a gem for one decode in one test is the wrong trade when the library's whole point is having one runtime dependency.
  * The failure mode is worth knowing because it is not a test failure. A bundled gem missing under Bundler kills the **require**, so the job dies before any test runs and the annotation names the requiring file rather than anything about the feature. A 10 second red job is almost always this shape.
* Do not redefine methods of standard library classes. Newer versions may add the same method with different behavior (`IPAddr#+` in Ruby 4.0). Guard additions with `unless method_defined?`.
* **`const_defined?` searches the ancestors unless you pass `false`.** Several files guard a generated class with `unless const_defined? :Unknown` so the file is safe to require twice. That guard asks the wrong question: adding `Optional_parameter::Unknown` in #154 made `Capability.const_defined?(:Unknown)` true by inheritance, so `Capability::Unknown` was never defined and every reference to it resolved up the chain to the parameter level class, which has a different hash and a different constructor. Three tests in two other files failed and not one of them named a constant. Write `const_defined?(:Unknown, false)`, which asks whether this class defines it. `test_the_three_unknown_classes_are_distinct` in `test/unit/optional_parameters/optional_parameter_test.rb` guards the three that now exist. The same guard in `bgp/path_attributes/path_attribute.rb` is still the ancestor searching form; it is correct only because nothing above `Path_attribute` defines an `Unknown`, which is luck.
  * **The same guard has a second failure mode, which is a file loading earlier defining the constant.** `bgp/nlris/nlri.rb` creates both its classes inside `unless const_defined?(:Nlri)`:
    ```ruby
    unless const_defined?(:Nlri)
      Nlri      = Class.new(Base_nlri) do ... end
      Withdrawn = Class.new(Base_nlri) do ... end
    end
    ```
    So anything defining `BGP::Nlri` before that line runs skips the **whole block**, and `Withdrawn` is never defined either. Found in #173, which opened `class Nlri` in a file `nlri.rb` requires: a dozen failures naming `new_ntop`, `empty?`, `<<` and `BGP::Update::Withdrawn`, and not one of them naming the guard or the constant that tripped it. That pull request is closed, so this is the only thing kept from it. **Do not reopen `class Nlri` outside that file.**
* Do not mutate string literals. CI runs the suite with `--enable-frozen-string-literal`. Use `String.new` or `+''` for a buffer.
  * **`String.new` and `+''` are not interchangeable: an octet buffer must be `String.new`.** With no argument `String.new` is `ASCII-8BIT`, where `+''` is `US-ASCII` and `String.new('abc')` is too. That only shows when the buffer stays empty, because concatenating any packed octets onto it makes the result binary, so the bug hides until an object's value happens to be empty. It bit in #218: `Link_state::Tlv::Ip_reachability` defaulted its octets to `+''`, and the default route handed that empty US-ASCII string to `IPAddr.new_ntoh`. **Ruby 3.3 accepted it and 3.4 raises** `IPAddr::InvalidAddressError: invalid encoding (given UTF-8, expected BINARY)`, because 3.3's `IPAddr.ntop` only switched on `addr.size` and 3.4 checks the encoding. CI went green on 3.3 and red on 3.4, 4.0 and head, on one test out of 2217, and no local run could reproduce it. Same family as the `base64` entry above: the local Ruby is not the CI Ruby.
  * **Assert the encoding rather than trusting it**, because that is the only form of the test that fails on the Ruby you are running. `assert_equal(Encoding::BINARY, obj.octets.encoding)` fails on 3.3 against the unfixed code, where every assertion about the value passes. And assert the **buffer**, not `encode`: `encode` goes through `pack`, which forces binary on its result whatever went in, so a guard on `encode.encoding` passes against every one of these and is worth nothing. The first draft of #218's guard did exactly that and survived four sabotages.
  * The related trap, from the isis4r notes and true here: **`String#<<` with an Integer appends a codepoint**, so on a non-binary buffer any value above 0x7f becomes two octets, and calling `.b` afterwards relabels the string without undoing the expansion. One more reason the buffer's encoding is set where it is created and not later.
  * **`is_packed` is a mutation, which is not obvious from the name, so `'literal'.is_packed` dies under the flag.** It sets `@__is_packed__`, and a frozen literal cannot take an instance variable: the call raises `FrozenError`. #219 wrote `BGP::Nlri.factory('x'.is_packed, 1, 255)` in three tests, which passed locally and failed the `--enable-frozen-string-literal` run on all four Rubies. **`Array#pack` marks its result packed already**, so `['01'].pack('H*')` is the library's own route and needs no mutation; `(+'x').is_packed` also works where a literal is really wanted.
    * **The damage is worse than a red job, because the test asserted nothing.** It raised before reaching the gate it was about, so under the flag those three were testing the frozen-literal rule rather than the dispatch. **The tell is the assertion count**: the two runs printed 27283 and 27288 and the suite prints both, so a gap between them means a test is bailing out early under the flag rather than running differently. Compare the two counts when the flagged run fails, not just the failure list.

## Rules for agents

* Work on a branch named `claude/<short-topic>`. Never push to master. The agent tooling may put its scratch worktrees in `.claude/worktrees/`, which `.gitignore` covers; they are whole checkouts, not bgp4r source, and must never be committed.
* If `gh pr create` fails with HTTP 403, GitHub's GraphQL API is blocked in that sandbox. Open the pull request with `gh api repos/{owner}/{repo}/pulls --method POST` instead.
* **Do not stack a pull request on another one's branch.** Merging the parent deletes its branch, and GitHub then **closes** the child rather than retargeting it, and a closed pull request can be neither reopened nor rebased onto master through the API: "The pull request cannot be reopened" and "Cannot change the base branch of a closed pull request". The work is not lost, since the branch is still there, but the review history is, and a new pull request has to be opened. That happened to #163, stacked on #162. If a change really does depend on an unmerged one, branch from master anyway and say in the description which pull request to merge first, or wait.
* One topic per pull request. Small diffs.
* Run the full unit suite before opening a PR. All tests must pass.
* New behavior needs a test. Bug fixes need a test that failed before the fix.
  * **Check that the proof proved something.** Two "this test catches the regression" runs in one session proved nothing: the first patched a marker string that did not match, so the library was unchanged and the test passed for the obvious reason, and the second made a change the constructor was lenient enough to absorb, so the round trip still worked and the test was right to pass. A sabotage run that passes means the sabotage missed, not that the test is weak. Assert on the thing you changed before you believe the result, and prefer breaking the code the way it would really break, which is usually deleting a line rather than mutating a value.
  * **Commit before you sabotage, or revert from a copy rather than from git.** A sabotage pass that reverts with `git checkout -- <files>` reverts **nothing** when any of those files is untracked, because git aborts the whole command on an unknown pathspec. So a pull request adding new files is exactly where this bites: eleven sabotages in #218 accumulated into one broken tree, two of them reporting failures that were really earlier sabotages still in place, and unpicking it by hand took four repairs. Check the revert worked before trusting the next run, which is this rule applied to the harness instead of the test.
* **A claim nothing checks reads as verified, in a document as much as in a comment.** The lesson came twice. Once from the conformance table, measured by hand and never re-run. Once from `docs/to-hash-round-trips.md`, since **retired**, where the tables stayed true across four pull requests because `to_hash_round_trip_test.rb` compares them against the catalog row by row, while the prose beside them drifted into ranking work that two of those pull requests had already finished. The enforced half held and the unenforced half did not, in one file, with nobody noticing. That is what retiring it was for: what a person reads is printed from the catalog now, by `rake to_hash:status`, so there is no unenforced half left to drift. So when a document makes claims a test could make, assert the load-bearing ones: `test/unit/building_objects_test.rb` is what that looks like, and writing it corrected two claims in the document it guards within the hour.
* **Work out what the code and the tests were built to do before concluding that any of it is wrong.** bgp4r is behind on BGP features and it is not behind on robustness: encoding and decoding have held up for years because the test coverage around them is extensive and deliberate. So a shape that looks odd is far more likely to be a decision whose reason is not written down than a defect, and the burden is on the reader to find the reason first. This was said on 2026-10-29 after two claims in one afternoon that failed the same way.
  * **The two NLRI dispatch points.** Recorded as drifted apart, because parse groups SAFI 4 with 128 and 129 and build does not. `Labeled#parse` branches on the SAFI itself: parse is one entry point dispatching internally, build dispatches externally because the caller must supply an RD for the VPN families and not for SAFI 4. A difference in the work, read as a defect in the code. It cost a closed pull request, #173.
  * **The `#TODO class Error.....` in `Nlri.factory`.** Recorded as asking for the wrong thing. It asks for a typed exception where there is a bare `RuntimeError`, which is both modest and right. Four words were read as the opposite of what the surrounding code does.
  * What would have caught both in a minute each: read the method the branch calls before calling the branching wrong, and read what a TODO's own words ask for rather than what a plan needs them to ask for. **Say "I do not know why this is like this" rather than "this is wrong"** until the first has been answered; the file is full of entries that exist because somebody wrote the second.
* **A "won't fix" has to record the mechanism, not the verdict.** One was written in this session and reversed an hour later by a single question from the owner: "order should not matter when you recreate an object from a hash, care to explain the concern?" The premise was true, that a Hash keyed by attribute type cannot hold two of a type or say which came first. The conclusion, that nothing readable could be done, did not follow from it, and the prose had carried the premise's authority over to the conclusion. Two things would have caught it. State the premise and the conclusion as separate sentences and check the second follows from the first. And name the bar you are measuring against, because the real mistake was taking byte-exact octets as the bar for a hash whose job is to rebuild instance state.
* **An IANA registry is reachable from this sandbox, so "check the registry" is a real instruction and not a wish.** Several entries in this file were written as though it were not. The catch is the fetch tool's allowlist: a URL **built by editing a path** is refused, so `https://www.rfc-editor.org/rfc/rfc8556.html` fails even right after `rfc9574.html` succeeded. Search first and fetch a **result link**. `https://www.iana.org/assignments/bgp-parameters` came back from a search and served the whole BGP parameters page, registry by registry. Measured on 2026-10-31, where it settled all six PMSI tunnel type names at once. Two things that went with it: a third party mirror, codepoints.org, was **stale and wrong** on a name it did carry, hyphenating "Assisted Replication Tunnel" where RFC 9574's own IANA table does not, so corroboration from a mirror is worth less than one read of the defining document; and #120's hand measurement of that registry, which this file had flagged as second hand and to be re-checked, turned out **right in every particular**. Re-checking it was still the correct move, since that is what turned "probably right" into something a test could state.
* Cite the RFC section in a comment when you implement or fix wire format logic. Open the RFC and check the section number against its text; do not write one from memory. Six citations in this file and in the code were found wrong on 2026-10-27. One of them, "RFC 5291 section 5" for the ROUTE-REFRESH and ORF layout, is section 4, and it had been copied forward into two pull requests before anyone read the RFC. **Both numbers are live in that RFC and mean different things**, which is how the mix up happened and how it could happen again: section 4 is the ORF entry inside a ROUTE-REFRESH, whose Reserved is 5 bits of one octet and is "set to 0 on transmit and ignored on receipt", and section 5 is the Outbound Route Filtering Capability, whose Reserved is a whole octet that the section labels in Figure 3 and never describes. Do not quote section 4's sentence about the capability's octet. Figure 3 also says "Number of ORFs" where section 5's own text says "Number of ORF Types"; they are one field. Another called 0x02 and 0x03 extended community types when they are sub-types. A wrong citation is worse than none, because it reads as verified and sends the next person to the wrong page.
* **Edit this file with the `Edit` tool, one passage at a time.** Nothing
  in bgp4r is written in anything but Ruby; this is about an agent's own
  scratch tooling. A script that rewrites several passages of a long
  document at once corrupted CLAUDE.md in #188: three sections were
  mangled, the file grew 241 lines, and one entry appeared three times. The
  script asserted that each passage it searched for occurred once, and
  every one of those assertions passed, because the fault was in the
  replacement text and nothing checked that. #189's commit message has the
  mechanism if it is ever wanted again.
  * **That failure is silent and leaves valid text**: no exception, no
    failing test, since no test reads this file. It surfaced only when the
    next session re-read CLAUDE.md and the prose did not make sense.
  * So a scripted document edit must **assert on the result and not only on
    the match**: count the headings that should appear once and print the
    line count. Repair by rebuilding from the last good version, `git show
    <rev>:CLAUDE.md`, because a patch on top of mangled text leaves residue.
* Do not delete or weaken existing tests to make a change pass.
* If you find a bug you are not fixing, list it in the PR description.
* A plan that spans more than one session goes under "Where the work is going" as phases with their status, before the work starts. A plan that lives only in a chat is lost the moment the context is: the RIB plan below had to be recovered from a transcript because nothing in this file recorded it, or recorded that phase 1 was finished.
* Keep this file true in the same pull request that makes it false. If your change fixes something under "Known issues to work on", delete that entry. If it adds or removes tests, update the baseline counts above. **Copy the baseline counts out of the run, never work them out.** Writing 22721 assertions and 97.8% while the measurement in the same command said 22701 and 97.7% took one session; arithmetic on top of a previous baseline is how a count drifts, and a wrong count here is indistinguishable from a real change in the suite. For the same reason the baseline line conflicts whenever two pull requests are open at once, which is normal and not worth avoiding: the one that merges second re-measures rather than resolving the numbers by hand. Nobody reconciles this file later, and a stale entry is worse than no entry: it sends the next reader after work that no longer exists. Both halves of this have already happened here, once to seven entries at once, and once to a fix that landed without removing its own entry.

## Where the work is going

A plan that spans more than one session lives here, as phases with their
status, so the next reader can see the direction without reconstructing it.
Update the status in the pull request that moves a phase.

### Phase 0, before the RIB work resumes. Done

Fixing the existing path attribute bugs came first, deliberately, and that is
substantially done: 19 were fixed on 2026-10-27. Two audits that evening
compared bgp4r against the IANA registries and the current RFCs, code point by
code point. The verdict: bgp4r is not dangerously behind, because every unknown
attribute, community, TLV and capability round trips byte for byte, so a real
router's traffic cannot break it. What it is behind on is meaning, and the
breadth gap is concentrated in one limit (below).

The audits found something worse than any gap: five things bgp4r already
implements are wrong against the RFC they claim. A wrong implementation is
worse than a missing one, because it gives a confident wrong answer. These come
before phase 2, in this order. Each is verified against the RFC text, with the
reproduction one liners in "Known issues to work on".

1. **ADD-PATH Send and Receive were inverted. Done**, in #115. RFC 7911
   section 4: value 1 is able to receive, value 2 is able to send, and
   `CAP::Add_path#_send_recv` had it the other way. The diagnosis first
   recorded here was wrong: `Neighbor::Base_Capabilities#_path_id?` was **not**
   inverted. It already implemented RFC 7911 section 5's pair rule correctly
   in terms of the symbols, and `add_path_cap.rb` needed comments only. The
   one lying method was `has?`, and it lied about both halves, which is
   exactly why two bgp4r speakers cancelled out and nobody noticed. Section 5:
   to send multiple paths a speaker must have advertised 2 or 3 and received 1
   or 3 from the peer. No lab topology exercises add-path against GoBGP, which
   is why this survived; that topology is the recorded follow up under "Lab
   and conformance", with the four pieces it needs.
2. **A valid attribute bgp4r cannot decode was reported as malformed. Done**,
   in #116: a decoder that raises now files an `Attr::Gap` in
   `Path_attribute#undecoded`, and `errors` keeps meaning what the peer got
   wrong. `Attr::Gap` carries no `action` or `subcode`, so `Malformed_attribute`
   structurally cannot take one. The two channels are independent, because
   `Attr::Check.attribute` runs on the raw octets before the decoder, so an
   attribute that is both undecodable and malformed gets an entry in each and
   still raises under `:strict`.
   The bug was:
   `Path_attribute#decode_attribute` files "bgp4r could not decode it" as an
   `Attr::Finding`, so `parse_wire` raises `Malformed_attribute` under
   `:strict` on a perfectly valid EVPN or flowspec UPDATE. bgp4r invents a
   protocol error out of its own coverage and gives a wrong verdict about a
   correct router, which for a conformance tool is the worst failure there is.
   Smallest diff on this list. "Could not decode" is not a protocol error and
   must not be one.
3. **ROUTE-REFRESH dropped the subtype octet. Done**, in #117. RFC 7313
   section 3.2 redefines the Reserved octet as Message Subtype: 0 normal, 1
   BoRR, 2 EoRR, 255 reserved. `Route_refresh` now carries it, with `NORMAL`,
   `BORR`, `EORR`, `subtype`, `subtype=` and `subtype_to_s`, shaped on how
   `Orf_route_refresh` carries RFC 5291's When-to-refresh. A subtype the RFC
   does not define still builds and encodes. Capability 70 is now
   `CAP::Enhanced_route_refresh`; it is defined in section **3.1**, not
   section 4 as this list first said. Section 4 is Operation.
4. **NOTIFICATION error code 7 named the wrong registry. Done**, in #117.
   RFC 7313 section 5 defines it and section 6 allocates it: "ROUTE-REFRESH
   Message Error", subcode 1 "Invalid Message Length". The four subcodes of
   the expired dynamic capability draft are gone. #117 also found OPEN Message
   Error subcode 7 repeating subcode 4's name, where RFC 5492 section 5 makes
   it "Unsupported Capability", and filled in error codes 8 and 9, the RFC
   6608 FSM subcodes and Cease subcodes 9 and 10. The section 5 length check
   itself is receive side and applies only once the peer has advertised
   capability 70, so it goes with `rcv_route_refresh` in RIB phase 2.
5. **RFC 9072 extended OPEN was half done. Done**, in #119. The audit was
   right. Section 2, Figure 2 "Extended Parameters Format": "The rules for
   encoding Optional Parameters are unchanged with respect to those given in
   [RFC4271], except that the Parameter Length field is extended to be a
   two-octet unsigned integer." The outer header was already right; each
   inner parameter wrote and read a one octet length, which was self
   consistent and wrong on the wire, and made bgp4r raise "Optional
   parameter type '6' not implemented" on a conformant extended OPEN. The
   form belongs to the message and not to the parameter, so `Open#encode`
   decides it and passes `extended:` down to every parameter's `encode`.
   `Open#extended?` and `extended=` go with it: section 2 says "an
   implementation MUST accept an OPEN message that uses the encoding of
   this specification" even below 256 octets, so a message read in the
   extended form is written back in it, and the form can be asked for with
   any parameter list. Two more things came out of reading the RFC: only the
   Non-Ext OP Type octet decides on receipt, since the Non-Ext OP Len.
   before it "MUST be ignored on receipt once the use of the extended
   format is determined positively", where bgp4r required 255 in both; and
   the capability inside keeps the one octet code and length of RFC 5492
   section 4, because RFC 9072 widens the parameter header and nothing
   else.

**The BGP Role capability, code 9. Done**, in #118, the cheap one taken while
there. It is defined in RFC 9234 section **4.1**, not section 4
as this list first said; section 4 is BGP Role and section 4.2 is Role
Correctness. Section 4.1 gives code 9, a length of one octet, and Table 1,
"Predefined BGP Role Values": 0 Provider, 1 RS, 2 RS-Client, 3 Customer, 4
Peer, 5 to 255 unassigned. `CAP::Role` carries it through all three build
paths, and a Role the RFC does not define still builds and encodes. The
reading recorded here was right: section 4.2 says a speaker that advertised a
Role and received none SHOULD proceed, and then "The locally configured BGP
Role is used for the procedures described in Section 5", which is why the OTC
attribute was already usable. The capability buys Role Correctness, whose
three pairs are Provider with Customer, RS with RS-Client and Peer with Peer,
and the strict mode that requires the peer's Role. OPEN Message Error subcode
11, "Role Mismatch", is named in `notification.rb` now, with 8, 9 and 10 as
Deprecated, all from RFC 9234 section 7. Comparing the two Roles is session
state and belongs with the OPEN handling, not with a capability that never
validates. GoBGP does not implement Role, so no lab topology can exercise it
and it is unit tested only.

Also in phase 0: the stale citations the audits found. **Done**, in #120,
comments and one constant, no behaviour change. Every claim was re-read
against the document before anything was written, and six of the seven held:

* Eight wrong RFC 9012 section numbers in `tunnel_encap.rb`, seven distinct,
  with `Encapsulation` and `Egress_endpoint` citing each other's sections.
  Held exactly. The real structure: 3.1 is the Tunnel Egress Endpoint sub-TLV,
  3.2 the Encapsulation ones, 3.3.1 DS Field, 3.3.2 UDP Destination Port,
  3.4.1 Protocol Type, 3.4.2 Color, 3.5 Embedded Label Handling, 3.6 MPLS
  Label Stack, 3.7 Prefix-SID. Only the Protocol Type citation was already
  right. Each now carries the section's own title, so the next reader can
  check it without opening the RFC.
* `draft-ietf-idr-link-bandwidth` became **RFC 10005**, "BGP Link Bandwidth
  Extended Community", June 2026. Held, except the count: it was cited as a
  draft **seven** times in `extended_community.rb`, not six, and six more
  times in the tests. All thirteen now say RFC 10005 section 2. The units are
  bytes per second, which the RFC puts as "bytes (not bits!) per second", and
  three comments now say so. Both type octets are indeed assigned, 0x00
  transitive and 0x40 non-transitive under sub-type 0x04, and bgp4r already
  read both, because `FACTORY` masks the transitive bit off its key.
* **RFC 3107 is obsoleted by RFC 8277**. Held. The verbatim RFC 3107 text
  below `__END__` in `nlris/nlri.rb` now carries a note saying so and listing
  what changed. `0x800000` is no longer a label: RFC 8277 section 2.4 makes it
  a Compatibility field whose "value of this field is of no significance",
  SHOULD be sent as 0x800000 and MUST be ignored on reception. bgp4r still
  reads it as label 524288 and writes it back as `800001`, which is a
  behaviour bug and is filed under "Known issues to work on" rather than
  fixed here.
* `IANA::SAFI::ENCASPSULATION_SAFI` is a typo and SAFI 7 is obsolete. Held:
  IANA reads "Encapsulation SAFI (OBSOLETE)", referencing RFC 9012.
  `ENCAPSULATION_SAFI` is now defined beside it, both 7. Nothing in the tree
  used the old name, but it stays, so no caller breaks; defining the correct
  spelling second makes it the one `IANA.safi?(7)` prints.
* `Pmsi_tunnel`'s "the rest are reserved" was stale. Held. Five more tunnel
  types are assigned (8, 10, 11, 12, 13; 9 is unassigned), and RFC 7902 turned
  the flags octet into a registry with five more entries above the RFC 6514
  bit, so only bit 0 is unassigned and "reserved" was wrong. Both comments now
  list what is assigned.
* **The one claim that did not hold**: that `Router_mac` should cite RFC 9012
  section 4.2 rather than RFC 9135 section 8.1. RFC 9012 section 4.2 carries
  the title "Router's MAC Extended Community" but defines nothing; its whole
  body points at EVPN-INTER-SUBNET, which is RFC 9135. RFC 9135 section 8.1
  is "EVPN Router's MAC Extended Community" and gives the encoding, and IANA
  names RFC 9135 as the reference for EVPN sub-type 0x03. The citation was
  already right and was left alone; the comment now says why, so the next
  audit does not reopen it.
* The two wrong citations in this file's own "Attribute work left" both held
  and are corrected there: the Encapsulation sub-TLV shapes are five, at RFC
  9012 sections 3.2.1 to 3.2.5, there is no section 3.1.6, the SR Policy
  sub-TLVs are RFC 9830 and not RFC 9256, and the Prefix-SID sub-TLV type 11
  is RFC 9012 section 3.7.

That is all of phase 0. Eight pull requests, #113 to #120: two recorded this
plan, four fixed the five wrong implementations, since #117 took items 3 and 4
together, one added the BGP Role capability and one swept the citations.
Nothing bgp4r implements is now known to disagree with the RFC it cites. The
tests went from 727 to 956 across the day and coverage from 94.8% to 97.1%.

What phase 0 did not do is breadth, deliberately, and the reasons are under
"Deliberately not in phase 0" below so the decision is not re-litigated. The
thirteen bugs still open are under "Known issues to work on": every one is
either display only or needs a design decision rather than a patch, which is
why none of them blocked this phase.

Phase 2, the peer adapter, came next and is **Done**: a table is fed from a
live session. **Phase 3, the export side, is now Done in full**, including
GoBGP's opinion of it. **Phase 4 is Done too**: the show commands in all
three styles, and the FIB adapter putting the Loc-RIB in a real kernel
routing table, which needed a network namespace and not a container. This
paragraph claimed a container until #156 measured otherwise, and the
detailed entry below says what came apart. **Phase 5 is Done as well**,
so the whole RIB and FIB plan is finished: FRR is a reference in the lab
for both receive, through the RFC 7606 matrix, and send, through our
export side. What is left in this file is under "Known issues to work
on", and every one of those needs a decision rather than a patch.

### RIB and FIB, five phases

The design follows RFC 4271 section 9:

```
Neighbor ──UPDATE──▶ Adj-RIB-In (per peer) ──import──▶ Decision ──▶ Loc-RIB ──▶ FIB adapter
                                                                      │
                                               export ◀───────────────┘
                                                    │
Neighbor ◀──UPDATE── Adj-RIB-Out (per peer) ◀───────┘
```

1. **Route, Adj-RIB-In, the decision process and Loc-RIB. Done**, in #52 and
   #53. No networking. `bgp/rib/` holds `route.rb`, `adj_rib_in.rb`,
   `decision.rb`, `loc_rib.rb` and `table.rb`, with a test file each: 60
   tests. `Decision#best` is a pure function returning the winner, the step
   that decided it, and why each other route lost. It drops routes from the
   whole set at each step, so arrival order never changes the answer and the
   MED comparison cannot cycle (RFC 3345). Loop checks run before it: our AS
   in the AS_PATH, our ORIGINATOR_ID, our cluster ID in the CLUSTER_LIST.
   Import drops LOCAL_PREF from an eBGP peer (RFC 4271 section 5.1.5), then an
   optional Ruby block may change or reject a route. `table_test.rb` carries a
   model check: after every random step the table must equal a full recompute,
   and `RIB_MODEL_STEPS` makes it longer. That check caught all six bugs
   planted against it.
2. **The peer adapter and `rib.attach`, with loopback tests. Done**, in
   #122, #123 and #124: three PRs rather than the two first estimated,
   because the locking was a topic of its own and was worth landing before
   anything depended on it. `rib.attach(neighbor)` feeds a table from a
   live session, over IPv4 and IPv6, with add-path.
   1. **`Table` made thread safe. Done**, in #122. One reentrant lock around
      every method, so several sessions can feed one table while a console
      thread reads it. The lock has to be reentrant: `announce` calls
      `adj_rib_in`, and `decide` runs the `on_change` listeners while holding
      it, so a listener may read or change the table. `Mutex#owned?` does it
      without requiring `monitor`. `Table#synchronize` is public, because
      `decision`, `loc_rib` and the `AdjRibIn` that `adj_rib_in` returns are
      the objects themselves and have no lock of their own.
   2. **The adapter, `rib.attach` and the worker thread. Done**, in #123.
      IPv4 unicast only: the NLRI and Withdrawn Routes fields of RFC 4271
      section 4.3. `bgp/rib/peer_adapter.rb` translates and nothing else,
      so `PeerAdapter#operations` can be tested with no session, table or
      thread; `bgp/rib/peer_feed.rb` holds the queue, the one worker and the
      adapters, and `Table#attach`, `#detach` and `#drain` reach it.
      * The adapter listens as an **observer**, not through `rcv_update`.
        `rcv_update` is a hook for a subclass to override, and a table is
        handed a `Neighbor` it did not build. `dispatch_event` notifies the
        observers after the `rcv_` hook, so an observer sees every message.
        `Neighbor#rcv_update` is therefore still empty, and that is now by
        choice rather than for want of a caller.
      * The worker is not what makes the table safe, since #122 did that.
        It keeps the decision process off the event dispatch thread, which
        also runs the session: stall that thread and the peer stops getting
        KEEPALIVEs and the session dies on a holdtime expiry (RFC 4271
        section 4.4). It also means a read right after feeding can be early,
        which is what `Table#drain` is for.
      * Two things `Neighbor` was missing. `attr_reader :rmt_as,
        :rmt_bgp_id, :rmt_version` for what the peer's OPEN said, and
        `:my_as, :remote_addr, :local_addr` for our own side, none of which
        had readers. And `Neighbor#on_state_change`, because the message
        observers cannot see a session drop: `:ev_conn_reset` calls `stop`
        without notifying anyone, and `stop` is called directly too, so the
        only thing every path shares is `new_state` going to `:Idle`. The
        listeners run outside `@mutex` and an exception from one is logged,
        never raised, so nothing outside can kill the FSM.
      * `test/functional/rib_feed_test.rb` is the proof over a real socket,
        and it is named in `.github/workflows/test.yml`, which lists each
        functional test by hand.
   3. **MP_REACH, MP_UNREACH and add-path path identifiers. Done**, in #124.
      All four reachability fields are read now: the two of RFC 4271 section
      4.3 and the MP_REACH_NLRI and MP_UNREACH_NLRI attributes of RFC 4760
      sections 3 and 4. Both withdrawal fields are applied before both
      announcement fields.
      * **Only SAFI 1 and 2 go in a table**, `PeerAdapter::MP_SAFIS`. The
        other three bgp4r parses are left out because the prefix is not the
        whole key: SAFI 4 carries a label with it (RFC 8277 section 2) and
        SAFI 128 and 129 a Route Distinguisher (RFC 4364 section 4.2), so
        two routes differing only in label or RD would collide.
        `BGP::Rib::Route` keys on the prefix and the Path Identifier and has
        nowhere to put either. Carrying them is a change to `Route`, the
        decision process and every show command, so it is its own piece of
        work and not a line in the adapter.
      * The gap reports itself rather than looking like an UPDATE that
        carried nothing: `PeerAdapter#unreachable?` answers true for an
        unread family and `#unread_families` says which, as `[afi, safi]`.
      * Add-path needed nothing in the adapter, which already carried each
        prefix's Path Identifier (RFC 7911 section 3) into the `Route`. What
        it needed was a test: `test_add_path_puts_two_paths_to_one_prefix_in_the_table`
        negotiates the capability on both sides of a loopback session, sends
        two paths to one prefix, checks both reach the Adj-RIB-In with their
        Identifiers, and withdraws one by Path Identifier to see the other
        take over. Before this nothing had carried a Path Identifier into a
        RIB over a session.
3. **Adj-RIB-Out, the export rules and the speaker's router mode. Done.**
   Eight pull requests, #125 to #130, #133 and #152, where three were first
   estimated: the UPDATE building turned out to be a topic of its own, the
   same way the locking was in phase 2, three export rules that part 1 had
   recorded as "not in it" were worth doing rather than leaving as gaps, and
   the MinRouteAdvertisement interval could not be written until section 9
   of RFC 4271 became readable.

   `rib.attach(neighbor)` then `rib.advertise` is a router: it takes routes
   from its peers, decides, and advertises the result with the export rules
   applied. `rib.originate(prefix)` adds prefixes of its own, and
   `rib.advertise(mrai: ...)` paces what goes out. A second
   implementation's opinion of all of it is part 7.
   1. **The export rules and `AdjRibOut`, pure. Done**, in #125. Nothing
      calls them yet; part 2 wires them to a session.
      * `bgp/rib/export.rb` is a pure function like `Decision#best`:
        `Export#for(route, peer)` returns a `Result` with the attributes to
        send, the next hop chosen, and a reason. It holds no Adj-RIB-Out and
        sends nothing, so the whole policy is testable with no session.
      * **Reachability is deliberately not in the result.** The attributes
        never carry MP_REACH_NLRI or MP_UNREACH_NLRI, because which prefixes
        go in which UPDATE is the sender's job and it packs prefixes that
        share attributes into one message. `Result#next_hop` is there so the
        sender can build MP_REACH_NLRI, which is also why it is filled for
        IPv4 routes where the attribute already carries it.
      * The rules, each read in the RFC rather than recalled: AS_PATH
        prepending in all four cases of RFC 4271 section 5.1.2, including
        the 255 AS overflow and the AS_SET case; NEXT_HOP per section 5.1.3,
        ours toward an external peer and untouched toward an internal one;
        LOCAL_PREF per section 5.1.5, never to an external peer and always
        to an internal one, so a route out of another AS gets the default
        here; MED per section 5.1.4, not propagated to another neighbouring
        AS; NO_ADVERTISE, NO_EXPORT and NO_EXPORT_SUBCONFED from RFC 1997,
        whose sections are **unnumbered**, so cite it by name; the base IBGP
        rule as RFC 4456 **section 4** describes it, with a
        `route_reflector` option and the ORIGINATOR_ID and CLUSTER_LIST
        handling of **section 8**.
      * `next_hop:` is required for an external peer and raises without it.
        Export cannot know our address on a session, and the alternative to
        raising is sending a next hop that is not ours, which is how a route
        becomes a black hole. The refusals are checked first, so a route
        that is not going to that peer never needs one.
      * Not in it: confederations (RFC 5065), so a leftmost confederation
        segment is treated as the section 5.1.2 AS_SET case. The route
        reflector client matrix of RFC 4456 section 6 was left out here and
        landed in #129; originating our own routes landed in #130.
      * `bgp/rib/adj_rib_out.rb` records what was sent, keyed by prefix and
        Path Identifier like the Adj-RIB-In. `advertise` answers `:new`,
        `:changed` or `:same`, and `withdraw` answers nil for a prefix the
        peer never had, so the sender can leave both messages unsent.
        Attributes are compared by their encoded octets in the 4-octet AS
        form, because `Export` builds a new `Path_attribute` every run.
   2. **The UPDATE builder. Done**, in #126. `bgp/rib/update_builder.rb`
      turns the tuples the export step produces into UPDATE messages, and
      is pure like `Export`: it reads tuples and returns messages, so the
      packing is testable on its own.
      * Prefixes that share a path attribute set, a next hop and an address
        family travel in one UPDATE, which is the whole economy of BGP. The
        grouping key is the **encoded** attributes, as `AdjRibOut` compares
        them, because `Export` builds a new `Path_attribute` every run.
      * IPv4 unicast uses the RFC 4271 section 4.3 fields; every other
        family uses MP_REACH_NLRI and MP_UNREACH_NLRI (RFC 4760 sections 3
        and 4), where the next hop travels inside the attribute, so
        `Next_hop` is removed from the copy. This is where
        `Export::Result#next_hop` is used.
      * **The packing is arithmetic, not measurement.** RFC 4271 section 4
        caps a message at 4096 octets, and section 4.3 gives a prefix as
        1+(length+7)/8 octets, 4 more with a Path Identifier (RFC 7911
        section 3). Measuring instead would mean re-encoding the message
        for every prefix added, and a full table is about a million. Every
        finished message is measured once, so a slip in the arithmetic
        raises rather than putting an oversized message on the wire.
      * The 4096 is `BGP::Message::MAX_SIZE`, defined once there and read
        from here and from `bgp/misc/route_generator.rb`, which packs
        prefixes the same way for a different reason. It started as a copy
        in each and was moved in #139.
   3. **Router mode. Done**, in #127. `bgp/rib/router.rb` is the only part
      of the export side that is not pure, and all it does is join the pure
      ones: a Loc-RIB change goes through `Export#for`, is diffed against
      the peer's `AdjRibOut`, and what is left goes to `UpdateBuilder` and
      out. `rib.attach(neighbor)` then `rib.advertise` makes a bgp4r
      speaker a router rather than a listener, so it is off until asked for.
      * Three things set it going: a session reaching Established gets the
        whole Loc-RIB, a Loc-RIB change goes to every peer, and a session
        leaving Established empties its Adj-RIB-Out, because the peer keeps
        nothing across a session.
      * Everything runs on the feed's one worker thread. The `on_change`
        listener only queues the change: a send inside the listener would
        hold the table's lock, and a send on a neighbour's event dispatch
        thread would stall the session that thread runs.
      * **No Path Identifier is ever sent**, whatever a route arrived with.
        One is the sender's to allocate (RFC 7911 section 3) and may only go
        on a session that negotiated add-path in that direction. This
        advertises the one best route per prefix, so there is nothing for an
        Identifier to tell apart, and forwarding the one a route arrived
        with would put four octets the peer is not expecting in front of
        every prefix: a corrupt UPDATE, not a wrong route. The first draft
        of this file did exactly that.
      * An address family with no next hop of ours is skipped, not raised
        and not guessed. `Export` will not invent our address, and an IPv6
        route over an IPv4 session has no next hop of the right family (RFC
        4760 section 3), so `advertise(next_hops: {2 => '...'})` is how one
        is given. `Router#skipped` says what was not advertised and why,
        keyed by prefix and peer, because a route silently not advertised
        is the hardest kind of bug to see from outside.
      * A change the peer cannot see sends nothing. MED does not cross into
        another AS (RFC 4271 section 5.1.4), so a MED-only change leaves the
        attributes this peer would get identical and the Adj-RIB-Out says
        so. `test_a_change_the_peer_cannot_see_is_not_sent` pins it.
      * The MinRouteAdvertisement interval landed later, in part 8, once
        section 9 could be read. Until then a change went out as soon as
        it was decided, which is the interval set to 0.
   4. **Route reflection and transit, over loopback. Done**, in #128.
      `test/functional/rib_router_test.rb` runs three speakers: one Table
      with two Neighbors is what makes a router, since a Neighbor holds one
      session. A route crosses it and comes out the far side with the
      export rules applied, which is what the recorded plan wanted the
      Compose topologies to show.
      * Transit: a route from one external peer reaches another with our AS
        in front of theirs and our address as the next hop, read off the
        wire on the far side. Route reflection: an internal peer's route
        reaches another internal peer only with `route_reflector`, and
        arrives with the ORIGINATOR_ID and CLUSTER_LIST of RFC 4456 section
        8 and an unchanged AS_PATH and NEXT_HOP. Neither of those two
        attributes leaves the AS. Withdrawals cross too, and so does a
        session dropping, which withdraws its routes from the other peer.
      * **A peer is identified by its address**, and `PeerAdapter` builds
        the `Peer` from the Neighbor's configured `remote_addr`, not from
        the accepted socket. Two listeners both configured 127.0.0.1 are
        one `Peer` as far as the table is concerned, which collapses the
        Adj-RIB-Outs into one and makes every route look like it is going
        back to its sender. All six tests failed that way first. On a real
        network two peers have two addresses; over loopback they have to be
        given them, so each listener gets its own 127.0.0.x.
      * Named in `.github/workflows/test.yml`, which lists each functional
        test by hand.
   5. **The route reflector client matrix. Done**, in #129, RFC 4456
      section 6, whose two rules are quoted in `Export#refuse`. "A route
      from a Non-Client IBGP peer: Reflect to all the Clients", so a
      non-client's route goes only to a client; "A route from a Client
      peer: Reflect to all the Non-Client peers and also to the Client
      peers", so a client's route goes to either. What is left over is
      non-client to non-client, refused as `:non_client_to_non_client`,
      because those peers are fully meshed and have the route already.
      * `Export.new(clients: [...])` takes the addresses, and with **no**
        list every internal peer is a client. That is the single cluster
        case, which section 6 describes as "The Clients will be configured
        to maintain IBGP session only with the RR in their cluster", and it
        keeps `route_reflector: true` on its own behaving as it did before
        #129. A list is wanted as soon as some internal peers are other
        reflectors, which section 6 calls Non-Client peers and expects to be
        fully meshed.
      * Section 6 says nothing about a route from an **external** peer:
        Appendix B records that "the reference to EBGP routes/peers are
        removed" from the document. So such a route reaches every internal
        peer under the ordinary rules and is not reflection, which is why it
        gets no ORIGINATOR_ID and no CLUSTER_LIST. There is a test for it.
   6. **Originating our own routes. Done**, in #130. `rib.originate(prefix)`
      announces a prefix of ours, and `rib.withdraw(rib.local_peer, prefix)`
      takes it back. Three RFC 4271 sections give the rules and all three
      were read: 5.1.1 for ORIGIN, 5.1.2 for AS_PATH, 5.1.3 for NEXT_HOP.
      * Every `Route` has a peer it came from, so a route we originate gets
        `BGP::Rib::LocalPeer`, us: in our own AS, carrying our router ID,
        and answering `local?`. That is instead of a special case in every
        reader of `route.peer`, which is the decision process, the import
        step, the Adj-RIB-In and the export rules.
      * **The empty AS_PATH does the work.** Section 5.1.2 wants an empty
        AS_PATH toward an internal peer, "one whose length field contains
        the value zero", and toward an external peer our AS as "the only
        entry the path segment, and this path segment will be the only
        segment". Both fall out of originating with an empty AS_PATH
        attribute: the export step leaves an internal peer's alone, and
        prepending onto an empty one gives exactly one segment with exactly
        one AS. No origination branch was needed for either.
      * Section 5.1.3 did need one. A route we originated carries **our**
        next hop toward an internal peer too, where a learned route's is
        left alone: the section says that when the route "is directly
        connected to the speaker" the speaker "SHOULD use its own IP
        address for the NEXT_HOP attribute". So `next_hop:` is required for
        an originated route whichever kind of peer it goes to. The first
        draft set `Result#next_hop` and left the attribute on its
        placeholder, so the two disagreed.
      * Section 5.1.3 also has a SHALL NOT: "A route originated by a BGP
        speaker SHALL NOT be advertised to a peer using an address of that
        peer as NEXT_HOP." That is `:next_hop_is_the_peers_address`, and it
        binds only a route we originated.
      * Two refusals do not apply to our own route, because both are about
        a route another peer sent us: `:back_to_sender` and
        `:ibgp_to_ibgp`. The communities still do, since a script may
        originate a route carrying NO_EXPORT. A reflector does not reflect
        its own route either, so no ORIGINATOR_ID and no CLUSTER_LIST.
      * ORIGIN is the caller's: section 5.1.1 says "The ORIGIN attribute is
        generated by the speaker that originates the associated routing
        information" and names no value, so `originate` defaults to 0, IGP,
        and takes `origin:`.
   7. **GoBGP's opinion of the export side. Done**, in #152, as
      `test/functional/lab/rib_router_gobgp_test.rb`: bgp4r is the router,
      GoBGP is the far peer, no Docker. Four cases, 18 assertions, about 30
      seconds. GoBGP accepts our reflected route and reads both RFC 4456
      section 8 attributes back as we meant them, accepts our transit route
      with our AS prepended as one AS_SEQUENCE segment and our next hop,
      accepts a prefix we originate, and drops it again when we withdraw.
      Passes on 3.23.0 and on 4.10.0 alike, unlike the fault matrix, so
      the expectations need no version split.
      * This was recorded as blocked on a Docker daemon. That was the wrong
        conclusion, and #151 is where it came apart: GoBGP needs no
        container. A Compose topology is still worth having for the
        addressing a real link gives, but it was never what gated the
        interop claim.
      * **The absence of a route is the assertion that matters**, not any
        value. A route GoBGP dropped as a loop or as a malformed attribute
        never reaches its RIB, so `installed` waiting and failing is what
        catches that. Proved by turning `route_reflector` off: the test
        fails with "GoBGP to install 198.51.100.0/24 (waited 30s)".
      * `LabHelper::Gobgpd#rib` and `#path`, with `Gobgpd.attrs` and
        `Gobgpd.as_path`, read the router's RIB as JSON through the `gobgp`
        client. Attributes come back keyed by type code, and the client
        prints no attribute that did not arrive, so `assert_nil` on a type
        code is how "we did not send this" is checked.
      * Keep this test and `test/functional/rib_router_test.rb` in step. The
        bgp4r only one asserts far more, because it reads the UPDATE off the
        wire; this one asserts the part two bgp4r speakers cannot tell you,
        which is whether anyone else agrees. Two bgp4r speakers agreeing is
        how the inverted ADD-PATH field survived for years.
   8. **The MinRouteAdvertisement interval. Done**, in #133, once section 9
      of RFC 4271 could be read. `bgp/rib/mrai.rb` holds the rules of
      section 9.2.1.1 and is pure, like `Export` and `UpdateBuilder`, with
      an injected clock, so every rule is tested by moving time rather than
      by sleeping. `Router` owns the one thread that acts on it.
      * **Off by default**, which is what the recorded decision asked for.
        `Mrai.suggested` asks for section 10's suggested values, 30 seconds
        on eBGP and 5 on iBGP, with its jitter factor of 0.75 to 1.0 picked
        fresh each time a window is armed. Off is right for this library: a
        script driving a router through a sequence of UPDATEs wants each one
        on the wire when it says so, and 30 seconds of silence reads as a
        bug in the device under test.
      * The value is per peer and the window is per destination, which is
        what the section says in its first paragraph. Section 9.2.1.1 calls
        a timer per destination "unwarranted overhead" and allows any
        technique that keeps the interval at or above the value and gives
        "a constant upper bound on the interval". This keeps one deadline
        per destination inside its window and one timer per Router, and the
        bound is the interval itself.
      * Both of the section's choices for internal peers are reachable,
        since the two values are separate: `ibgp: 5` with `ebgp: 30` is its
        option (a), and `ibgp: 0` is option (b), because an interval of 0
        never holds anything.
      * Withdrawals are paced too, because the section says "an
        advertisement and/or withdrawal of routes to a particular
        destination".
      * **Every decision about a destination must end in a hold, an arm or
        a drop.** That is `Mrai#drop`, and it is the bug this part nearly
        shipped: an announcement waiting inside its window, for a prefix
        that then changed back to what the peer already has, would have
        gone out at the end of the window and left the peer holding
        something the Adj-RIB-Out said it did not have. Two tests pin it.
      * **At most one flush is outstanding at a time.** The sending happens
        on the feed's worker thread, so from the moment a window ends until
        the worker gets through it the deadline is still in the past, and
        without that guard the pacer queued another flush on every turn of
        its loop: 99,255 of them in the test that now bounds it. It showed
        up as a drain timing out behind the backlog, not as a wrong route,
        which is why `Router#flush_requests` exists.
      * `plan` was restructured so the Adj-RIB-Out is written in one place,
        `commit`, reached both by an item sent at once and by one that
        waited. Before this it was written as the decision was made, which
        would have recorded a held UPDATE as sent.
      * Not here, and its own piece of work: MinASOriginationIntervalTimer,
        RFC 4271 section 9.2.1.2, which paces UPDATEs "that report changes
        within the advertising BGP speaker's own autonomous systems" and so
        applies to what `rib.originate` announces rather than per
        destination. Section 10 suggests 15 seconds for it.
4. **FIB adapters, and the show commands. Done**, in #132, #157, #156 and
   #158.
   1. **The show commands. Done**, in #132 for IOS and Junos and in #157
      for IOS-XR, so all three styles the plan named are real.
      `bgp/rib/show.rb`, reached as `rib.show`, `rib.show(:junos)`,
      `rib.show(:iosxr)` and any of those with a prefix. The decision
      result already held what they needed, including the Junos "Inactive
      reason" line.
      * **These are in the style of those commands, not copies.** Two
        things are reproduced from samples in the vendors' own
        documentation: the IOS header, legend and column layout, and the
        Junos detail shape with its Preference, State and Inactive reason
        lines. Nothing here has been diffed against a real device, so no
        test anywhere should depend on this text byte for byte.
      * **IOS-XR was the recorded gap and is closed**, in #157, because
        the sample that could not be found was found: the "Remove and
        Replace Private AS Numbers from AS Path in BGP" section of Cisco's
        BGP Configuration Guide for the NCS 5500, IOS XR release 7.11.x
        carries both a `show bgp` table and a `show bgp <prefix>` detail.
        The entry said inventing a format while calling it IOS-XR is worse
        than not having it, and that still holds; what changed is that
        there is something to check against.
        * The legend is where it differs from IOS rather than being IOS
          relabelled, and all three differences are the sample's: the line
          breaks after "> best" with "i - internal" below rather than
          above, stale is spelled with a small s where IOS prints "S
          Stale", and N for Nexthop-discard has no IOS equivalent at all.
        * The columns differ too. The sample's own header and rows agree
          that Next Hop starts 22 characters in, which makes the Network
          column wider here than IOS's and Next Hop narrower. The column
          test measures at the heading offsets, as the IOS one does.
        * A single prefix gets the **detail** form, since that is what
          IOS-XR gives for one: the entry line, "Paths: (N available, best
          #1)", and a block per path with the AS path, the next hop and
          the peer that sent it, the origin spelled out, and the Received
          Path ID of RFC 7911 section 3.
        * What is deliberately left out, each because printing it would
          claim something bgp4r does not have: the header's Table ID, RD
          version, scan intervals, non-stop routing and the NSR and ISSU
          sync lines; the detail's Versions block, Last Modified, Local
          Path ID, version, and whether a path was advertised to a peer,
          which needs the Adj-RIB-Outs and those belong to a `Router`, not
          a `Table`; and group-best and multipath, since there is one best
          path per prefix and no multipath.
        * **IOS-XR has no line for why a path lost**, so this prints none.
          `show(:junos, prefix)` is the one with an Inactive reason line to
          put it on, and a test pins that difference so it is not read as
          a hole in the IOS-XR style.
        * The one borrowing: a locally originated route prints 0.0.0.0 and
          a weight of 32768 in the table form, which came from the **IOS**
          sample because the IOS-XR one has no local route in it. The
          detail form borrows nothing and prints what the `Route` carries,
          so the two forms disagree about a local route's next hop on
          purpose. If a real device disagrees, that is the line to look at.
      * Only three Junos "Inactive reason" strings are Junos's own, from
        its sample output: Local Preference, IGP metric and the Interior
        over Exterior one. Every other step prints bgp4r's symbol in
        snake_case, `router_id` rather than `Router ID`, so an invention
        cannot be read as a quote from a router. `:med` is deliberately
        **not** labelled "IGP metric": that reason is the IGP cost to the
        next hop, which is `:igp_cost`.
      * Two details came out of the samples rather than from memory. A
        locally originated route prints `0.0.0.0` as its next hop and a
        weight of 32768, where a learned route gets 0. And the Junos
        preference is `170/-(localpref+1)`, which its sample shows as
        170/-201 for localpref 200.
      * The column test measures each field at the offset its own heading
        sits at, so the header is the source of truth. It also pins that
        the LocPrf column is blank for an external peer's route, which is
        RFC 4271 section 5.1.5 and `Table#import` showing through.
   2. **The FIB adapter and the Linux lab test. Done**, 2 PRs as
      estimated: #156 and #158. `rib.install(table: 100)` puts the Loc-RIB
      in a forwarding table and keeps it there, `rib.fib` reads back what
      it believes is in it, and `rib.uninstall` takes its routes out again.
      * **It does not want a container, and the entry here said it did.**
        What the plan actually asked for is a network namespace of its
        own, with a dedicated routing table, routes marked `proto bgp` and
        removed on exit, and `ip netns` gives all of that with no daemon:
        measured in this sandbox, routes added to table 100 inside a
        namespace while the host's table 100 stayed empty, and `ip netns
        del` took the lot with it. The reasoning that reached "container"
        was that a native run would write to the machine's own routing
        table, which is true of a native run with no namespace and not of
        one with a namespace. **That is the third recorded Docker block in
        this file to come apart on being tried**, after phase 3 part 7 in
        #151 and add-path in #153, and the lesson is the same each time:
        probe before recording a block.
      * **The pure part. Done**, in #156, and nothing calls it yet, the
        way #125 landed the export rules before anything sent them.
        `bgp/rib/fib.rb` holds the installed table and plans operations
        from a Loc-RIB change, the way `Router` plans against an
        `AdjRibOut`, and `bgp/rib/ip_route.rb` turns one operation into an
        `ip route` command line without running it. 36 tests, both files
        at 100% line coverage, no kernel and no iproute2 involved.
        * **`plan` records nothing and `commit` writes**, which is the
          `Mrai` lesson from part 8 of phase 3 taken up front: a planner
          that recorded its own intent would claim a route the kernel went
          on to refuse. `test_planning_records_nothing` pins it.
        * `replace` rather than `add`, because it adds a prefix the table
          does not have and changes the next hop of one it does, so a
          single action covers a new route and a changed one and
          re-running it is harmless. Every form was run against iproute2
          6.1.0 in a namespace before it was written down, which is also
          where `ip -n NS` was preferred to `ip netns exec NS ip`.
        * **What the `proto` filter buys, corrected in #158.** #156 said
          `proto` on the `del` stops a removal taking out a route of the
          same prefix that something else owns. That is wrong, and trying
          to break it is what showed it: removing `proto` from the `del`
          broke no test, because a `del` names one prefix and the kernel
          will not hold two protos for it anyway (`ip route add` for a
          prefix already there answers "File exists" whatever the proto).
          It is `proto` on the **flush** that protects a shared table, and
          `test_the_flush_leaves_a_route_bgp4r_did_not_put_there` fails
          without it. The `del` filter is kept because it costs nothing.
        * **`replace` takes over a foreign route of the same prefix**,
          which is the price of using it: it overwrites the route, marks
          it `proto bgp`, and the flush on the way out then removes it. No
          filter can prevent that, since by then the route is marked as
          ours. So a table shared with another daemon is safe only where
          the prefixes do not overlap, which is another reason `table:`
          has no default. Measured and asserted in
          `test_a_foreign_route_of_the_same_prefix_is_taken_over`.
        * **It does not resolve a next hop.** A real router resolves the
          BGP next hop recursively against its IGP; bgp4r has no IGP, so
          the next hop goes to the kernel as it arrived and the kernel
          decides whether it can reach it. Said in the class comment as
          well, because a reader will come looking for it.
        * `table:` has no default and `IpRoute.new` raises without it. A
          route in the main table changes where the machine sends its own
          traffic, so naming it is required; any table is accepted once
          named, including the main one, so this refuses no value.
        * One route per prefix and no multipath, because the Loc-RIB has
          one best route per prefix. ECMP means reading the whole
          candidate set and is its own piece of work.
      * **Running it, and the kernel's opinion. Done**, in #158.
        `bgp/rib/fib_installer.rb` is the only impure part and all it does
        is join the pure ones, the way `Router` does on the export side:
        `Fib#plan`, then the command, then `Fib#commit`. `rib.install`,
        `rib.fib`, `rib.fib_installer` and `rib.uninstall` reach it, and
        `test/functional/lab/fib_test.rb` proves it against a real kernel
        in a network namespace, 10 tests, no Docker.
        * **A bug this found: the feed's worker started only on the first
          `attach`.** So `rib.install` on a table with no peers queued
          work nobody applied, and `drain` answered true because it
          returns early when there is no worker: the FIB forwarded nothing
          and said nothing. A table fed only by `rib.originate` has no
          peer to attach, and that is a normal FIB use, so
          `PeerFeed#start` now starts the worker without attaching
          anything and `FibInstaller#start` calls it. `Router` has the
          same shape but not the same problem, since a router with no
          peers has nobody to advertise to.
        * **A second bug, in the first draft of the runner: `IO` inside
          `module BGP` is `BGP::IO`.** `bgp/io.rb` defines it, so a bare
          `IO.popen` never reaches core Ruby and fails with "undefined
          method `popen' for module BGP::IO". It is `::IO.popen` now. Same
          family as the `const_defined?` trap in Conventions: a name
          resolved up the lexical scope to something nearer than intended.
        * `::IO.popen` and **not** `Open3`, which would read better. Open3
          is a default gem today, and Conventions says to check that before
          requiring one, because Ruby keeps moving these to bundled gems:
          `observer` went in 3.4 and `logger` in 4.0. `IO.popen` is core
          and does the whole job in a line, so the library keeps its one
          runtime gem. The argv Array form never reaches a shell.
        * **An install is committed only on success; a removal always.**
          `ip route del` exits 2 for a route the table does not have, so
          the commonest way a removal fails is that the route was already
          gone, which is the outcome it wanted. Going on believing it is
          installed would mean never trying again. The failure is still
          recorded in `FibInstaller#failed`, keyed by prefix, which is
          what `Router#skipped` is on the export side.
        * `runner:` on `IpRoute` is the seam that keeps the unit tests
          free of a kernel, root and iproute2. It is useful outside them
          too: `sudo`, a remote shell, or a dry run that only logs.
        * `start` guards against registering a second `on_change`
          listener, since `uninstall` then `install` would otherwise add
          one. **That guard is hygiene, not a fix.** Removing it moves no
          test: the duplicate change comes to nothing, because `Fib#plan`
          answers nil for an install the FIB already agrees with and nil
          for a removal of a prefix it no longer holds. It is kept so the
          work is not queued and thrown away, which matters at a million
          prefixes. The comment on it first claimed a double removal and a
          spurious failure, which trying to break it disproved.
        * `uninstall` flushes both families, because a flush names one and
          a table can hold both. A flush of a table that does not exist
          yet exits 2, which is not a failure: there is nothing to flush.
        * **`Fib`'s `:no_next_hop` branch cannot be reached through a live
          table.** `Decision#eligible` answers `:next_hop_unreachable` for
          a route whose next hop is nil and that is in
          `Decision::INELIGIBLE`, so such a route never becomes a best
          route and there is no change to plan. The branch stays because
          `plan` is public and pure, and `fib_test.rb` asserts the real
          behaviour rather than the unreachable one.
        * **IPv6 is not exercised against a kernel.** The sandbox this was
          written in has IPv6 compiled out: `/proc/sys/net/ipv6` is absent
          and `ip -6 route add` answers "Operation not supported" on the
          host as much as in a namespace. The v6 command building is unit
          tested; the v6 data path is not, and that is the one gap here.
        * CI runs it. The lab job is unprivileged, so the test omits
          itself there, and a second step runs that one file under `sudo`
          with `LAB_REQUIRE_NETNS=1` so it fails rather than omits. A
          claim nothing checks reads as verified, which is the lesson
          under "Lab and conformance".
5. **FRR as a reference in the lab. Done**, in #159 and #160, which is
   the whole plan finished. `LabHelper::Frr` runs FRR's `bgpd` standalone
   on loopback, no Docker and no zebra, and two tests use it: the RFC 7606
   matrix in `fault_matrix_frr_test.rb`, so the FRR column in
   `docs/protocol-testing.md` is asserted rather than remembered, and
   `rib_router_frr_test.rb`, which points bgp4r's export side at it.
   * **FRR agrees on 6 of the 18 rows**, where GoBGP 4.10.0 agrees on 16
     and 3.23.0 on 15. It is much further from RFC 7606 than either, and
     in one specific way: its own log says `Attribute ORIGIN, parse error
     - treating as withdrawal` and then it sends `3/10 (UPDATE Message
     Error/Invalid Network Field)`. So it is not a router that disagrees
     about treat-as-withdraw; it is one whose implementation of it falls
     over on the withdraw path. All 11 treat-as-withdraw cases.
   * **Two rows of the hand-measured column were wrong**, and the fault
     was the hand measurement, not a change in FRR. "attribute discard
     cases: agrees" missed that a duplicated attribute resets with 3/1,
     where RFC 7606 section 3 bullet (g) says "all the occurrences of the
     attribute other than the first one SHALL be discarded" and names no
     subcode; subcode 1 is what (g) reserves for a duplicated
     MP_REACH_NLRI or MP_UNREACH_NLRI. That is the one row where GoBGP
     and FRR disagree with each other, and the RFC is flatly against FRR.
     And "attribute overruns the list" was a dash because the hand run
     skipped it: it is 3/5, exactly the bug GoBGP 3.23.0 had and GoBGP 4
     fixed.
   * **Four harness facts, each measured rather than assumed**, because
     each one silently voids the whole run.
     * `bgpd` needs `-S`, or it drops to the `frr` user and cannot write
       into `Dir.mktmpdir`. There is no `--vty_group` in 8.4.4 either, so
       `-u root -g root` is not an answer.
     * It needs **an address of its own**, not the peer's, or every route
       is rejected under RFC 4271 section 6.3 for a NEXT_HOP equal to the
       receiving speaker's own address.
     * It needs a **non-loopback next hop** in the test routes.
       `Frr::NEXT_HOP` is 192.0.2.1, because with 127.0.0.1 FRR keeps the
       session up and silently drops the route, where GoBGP accepts it.
     * **`vtysh` must be read past its own warning.** Run as any user that
       is neither root nor in the `frrvty` group, which is exactly what CI
       does, every answer begins `% Can't open configuration file
       /etc/frr/vtysh.conf due to 'Permission denied'.` with the real
       output after it. `JSON.parse` on the whole thing fails, so
       `Frr#summary` answered nil forever and `up` raised after its
       timeout even though the session had established. `Frr#vty_json`
       takes the JSON from the first brace now.

     **Those two middle facts are what made the first two measurement runs
     here void**, and what caught both was the scenario's own
     `test_the_rib_answer_was_usable`, which refuses to score route
     verdicts when the clean baseline route did not install. Without that
     guard this would have recorded "FRR resets on all 18 cases", which is
     wrong and would have read as verified.

     The `vtysh` one is the fourth because nothing local showed it: root
     reads that file, and the harness was only ever run as root here. It
     took the first CI run of #159, and **that failure reported nothing at
     all**, because the workflow's annotation step ran `msg=$(grep ...)`
     under `bash -e` and grep exits 1 when it matches nothing, so the step
     died before reaching its own `tail` fallback. That now ends in
     `|| true`.
   * Two additions to `fault_matrix_scenario.rb` rather than weakening
     what was there. `reset_subcode_overrides` is for a router that resets
     where the catalog expects a reset but names another subcode, which is
     FRR's `unknown_wellknown`: that is not a divergence and must not be
     counted as one. `wholesale_divergences` lets a router declare a
     category it gets wrong in full, so the guard against a divergence
     list that empties a derived test still protects the GoBGP runs while
     FRR's breadth is stated and reviewed instead of quietly passing.
   * **The export side against FRR. Done**, in #160, as
     `rib_router_frr_test.rb`: the twin of `rib_router_gobgp_test.rb`,
     three cases and 13 assertions, about a minute. FRR accepts our
     reflected route and reads both RFC 4456 section 8 attributes back as
     we meant them, accepts our transit route with our AS prepended and
     our next hop, and takes a prefix we originate and drops it again.
     * **So two independent routers now agree with our export side**,
       which is the point of the lab: two bgp4r speakers agreeing proves
       only that they agree. After the fault matrix showed how far apart
       two routers can be on receive, their agreeing here is worth
       recording rather than assumed.
     * Two things differ from the GoBGP twin, both FRR's. The next hop
       cannot be a loopback address, so the transit case passes
       `advertise(next_hops: {1 => '192.0.2.9'})` rather than letting the
       router use the session's local address; putting that back makes the
       case fail with "FRR to install 203.0.113.0/24", which is the same
       silent drop `Frr::NEXT_HOP` records, found again from another
       direction. And the two section 8 attributes have to be read from
       **`Frr#detail`**, the per-prefix form: `show bgp ipv4 unicast json`
       has no `originatorId` or `clusterList` key at all, so reading them
       off the table form answers nil however correct the UPDATE was,
       which is a wrong answer rather than a missing one.
     * Checked the way the matrix is: each case proved to fail against a
       broken version, and the whole file run as a non-root user as well
       as root.

Decisions already taken that constrain the later phases:

* Loc-RIB and FIB are separate. The Loc-RIB runs anywhere; the FIB is an
  adapter and optional.
* No policy language. Import and export take a Ruby block.
* The MRAI timer (RFC 4271 section 9.2.1.1) is a setting, defaulting to 0,
  so no test depends on timing. Done in part 8 of phase 3. **Section 9 of
  RFC 4271 is readable now**: it was attached to the session on 2026-10-28
  and is the whole RFC, where both fetchable web sources truncate the
  document around page 55. That truncation is why nothing in #125 to #130
  cites a section 9 rule and why the timer waited. Everything written
  against section 9 before that date was written from memory, so all 38 of
  those citations were audited in #134, against the text and not the web.
  What it found is recorded there; the short version is that every lettered
  tie break step a) to g) was right, and the one wrong citation repeated six
  times was the session down rule, which is section 6 and section 8.2.2 and
  not section 9.1.2 at all. **RFC 4456 section 9 was checked too** and holds:
  it is "Impact on Route Selection", it says "the ORIGINATOR_ID SHOULD be
  treated as the BGP Identifier of the BGP speaker that has advertised the
  route" and "a BGP Speaker SHOULD prefer a route with the shorter
  CLUSTER_LIST length", and it puts that step between f) and g), which is
  what `decision.rb` says. Do not reopen either.
  Two things that paragraph used to imply and should not: "oldest route
  wins" is **not** one of section 9.1.2.2's tie breaks, which are a) to g)
  with no age among them, so it is vendor behaviour and bgp4r does not have
  it; and the "not back to the peer it came from" rule in `Export` is
  marked as not an RFC rule because RFC 4271 genuinely has no such rule,
  which was checked across the whole document and not just section 9.
* A full table is about a million IPv4 prefixes, so share identical attribute
  sets keyed by their encoded bytes rather than one object per route. Measure
  with `routegen`, do not guess.
* Dump the RIB to JSON, as the lab speaker dumps its state, so a test and a
  person can both see why a route won.

### Deliberately not in phase 0

Breadth, because it is a month and phases 2 and 3 are worth more. Recorded so
the decision is not re-litigated from scratch. **That deferral has now
expired**: the RIB and FIB plan is finished, and the plan for lifting this
limit is the section that follows, "Breadth, the one SAFI lever". What stays
true here is the shape of the gap:

* **MP_REACH and MP_UNREACH read and write SAFIs 1, 2, 4, 5, 128, 129, 132,
  133 and 134, plus AFI 25 SAFI 70.** 133 and 134 are flowspec, which arrived
  with phase 2 below, AFI 25 SAFI 70 is EVPN, which arrived with phase 3 part
  5, 132 is RT-constrain, which arrived with phase 4 part 1, 5 is
  MCAST-VPN, which arrived with phase 4 part 3, and AFI 16388 SAFI 71
  and 72 are BGP-LS, which arrived with phase 4 part 4. What that
  one limit still blocks is VPLS and SR Policy.
  **This bullet said `Mp_reach.new(:afi=>25, :safi=>70, ...)` raises, which
  #185 made false and did not correct here.** It does not raise:
  `ruby -I. -e 'require "bgp4r"; puts BGP::Mp_reach.new(:afi=>25,
  :safi=>70, :nexthop=>["10.0.0.1"], :nlris=>[{:inclusive_multicast=>{:rd=>
  [100,200], :tag=>0, :originator=>"10.0.0.1"}}]).to_shex'` prints the
  attribute. A stale entry sends the next reader after work that is done.
* **BGP-LS is in whole: the NLRI, attribute 29, every attribute TLV RFC
  9552 defines, and the receive side checks.** AFI 16388
  SAFI 71 and 72 read and write since part 4 of phase 4 below, so the
  "one limit" this section named is lifted for the last family too. The
  BGP-LS **Attribute**, code 29, is a path attribute rather than an
  NLRI, so it goes through `Attr.register` and not through either
  dispatch gate; it landed with Table 6's node attribute TLVs in part
  5a, Table 8's in part 5b and Table 10's in part 5c, so **every
  attribute TLV RFC 9552 defines is in**, and part 6 added the ten
  syntactic checks of section 8.2.2. What is left for this family is
  the attribute TLVs the **other** RFCs define, which the plan's own
  measure deliberately excludes.
  Flowspec, EVPN, RT-constrain, ATTR_SET and MCAST-VPN were all on this list
  and all five are off it, because the
  rule and the route can be sent now: flowspec had every traffic filtering
  action of RFC 8955 section 7 implemented and no way to send the rule they
  filter, and EVPN had none of its eleven route types and four of its eleven
  extended communities. Phase 3 below measured that community registry rather
  than recalling it, 18 assigned entries with 14 carrying an RFC, and all 14
  are in.
* Coverage as measured: 24 of 34 live path attribute code points, and 8 of 22
  live capability code points. The attribute figure reads worse than it is:
  FRR's `bgpd.h` defines exactly bgp4r's 22 plus two, where the 23rd is
  ATTR_SET, which FRR does not define at all, and the 24th is the BGP-LS
  Attribute, which FRR does not define either.
  `ruby -I. -e 'require "bgp4r"; p BGP::Attr.registrations.size'` prints
  the first figure rather than leaving it to be counted. **The extended community
  figure is not written down here**, because it moved three times in a week
  and `ruby -I. -e 'require "bgp4r"; p BGP::Extended_community::FACTORY.size'`
  prints the registered code points, against the 115 the IANA registries
  listed when this was last counted by hand.

### Breadth, the one SAFI lever. Done. Phases 2, 3 and 4 complete, all seven BGP-LS parts included; phase 1 deferred by decision

The section above deferred breadth and named the single limit. This is the
plan for lifting it, recorded before the work starts.

**Where the limit actually is**, read in the code rather than recalled.
Two dispatch points, both a hard coded `case safi`, and no registry. **The
three bullets below describe the gates as they were before any of the
phases below landed**, which is what the registry argument was made
against. Each family since has added one arm to each gate, so flow spec,
EVPN, RT-constrain and MCAST-VPN are four more apiece: `set` now has 7
arms and `Nlri.factory` 6, counted on 2026-10-31 rather than worked out,
because working it out the first time gave seven when it was six. The
argument's conclusion has
not changed, and phase 1 says why it was re-tested each time rather than
assumed.

* **Build**: `MpReachCommon#set` in `mp_reach.rb`, the module both
  `Mp_reach` and `Mp_unreach` include. Branches for SAFI 1 and 2, for 4,
  and for 128 and 129, then `raise "SAFI #{safi} not implemented!"`.
* **Parse**: `Nlri.factory`. Branches for AFI 1 with SAFI 1, then SAFI 1
  and 2, then 4, 128 and 129, then `raise RuntimeError, "Afi #{afi} Safi
  #{safi} not supported!"`. `MpReachCommon#nlri_ntop` is a thin wrapper
  over it.
* `MpReachCommon#prefix_klass` raises for anything but SAFI 1 and 2. That
  is the prefix assumption, written down in one place.

The path attributes solved this shape differently, with
`Attr.register(type, klass, *keys)`, so adding an attribute is a class and
a registration rather than an edit to a case statement. A registry for the
NLRI side was tried in #173 and **closed unmerged**, and why is worth
keeping, because the argument for it was wrong in a way that is easy to
repeat.

**It claimed the two gates had drifted apart**, since the parse side
groups SAFI 4 with 128 and 129 and the build side does not. They have not.
`Labeled#parse` branches on the SAFI itself, so the parse side is one
entry point that dispatches internally, while the build side dispatches
externally because the caller must supply a Route Distinguisher for the
VPN families and not for SAFI 4. **The two sides differ because the work
differs**, and reading that as latent drift is reading a difference in the
problem as a defect in the code.

What was left once that went: locality for families not yet written, which
removes no code and is a bet on the phases below landing, against a module
and a file of indirection over a `case` with five arms, and twelve broken
tests on the way from the `const_defined?` trap in `nlri.rb` that
Conventions now records. Revisit a registry when a family actually needs
the sixth and seventh arm, so the case comes from need rather than
anticipation.

**What is already handled, and what the first draft of this plan got
wrong.** That draft opened with an `Nlri::Unknown`, the fifth
keep-what-you-cannot-read class, on the grounds that an UPDATE in an
unimplemented family raises rather than keeping its octets. Measured, it
does not:

```
ruby -I. -e 'require "bgp4r"
  hex = "800e0e" + "001946" + "04" + "0a000001" + "00" + "0102030405"
  pa = BGP::Path_attribute.new([hex].pack("H*").is_packed)
  p [pa.attributes.collect(&:class), pa.to_shex == hex,
     pa.errors.size, pa.undecoded.collect(&:class)]'
#=> [[BGP::Attr::Raw], true, 0, [BGP::Attr::Gap]]
```

An MP_REACH for EVPN comes back as an `Attr::Raw` that encodes byte for
byte, with an `Attr::Gap` in `undecoded` and nothing in `errors`. That is
#116 working as designed, one level up from the NLRI. So a capture from an
EVPN or flowspec router already parses and replays today, and a session
does not raise.

Two consequences, both of which change the plan rather than decorate it:

* **The raise in `Nlri.factory` is load bearing**, and that is worth a
  comment it does not have. It is the mechanism by which `Path_attribute`
  files the `Attr::Gap` and keeps the octets, so returning an object
  instead would delete the Gap and make bgp4r claim it understood a family
  it does not, which Conventions calls the worst failure a conformance
  tool has.
  * **The `#TODO class Error.....` beside it is not asking for that, and
    this file said it was.** `Path_attribute` rescues `StandardError` and
    records `e.class` in the Gap, so what the TODO wants is a typed
    exception in place of a bare `RuntimeError`: it would still raise,
    still file the Gap, and name itself in the Gap rather than appearing
    as `RuntimeError`. That is a good small change and it is still open.
    Reading a four word TODO as asking for the opposite of what the code
    around it does is how an author's intent gets overwritten.
* **A generic `Nlri::Unknown` is not writable anyway**, because the NLRI
  list framing is per family: SAFI 1, 2, 4, 128 and 129 are self
  delimiting through a length octet, and EVPN and flowspec each frame
  their own way. Without the family you cannot split the list, so the
  most such a class could hold is the whole remainder as one blob, which
  is what `Attr::Raw` already does. Recorded so the next reader does not
  propose it again.

1. **A registry for NLRI classes. Deferred by decision, not pending.**
   The shape would be `[afi, safi]` keyed and modelled on
   `Attr.register`, read by both gates so they cannot disagree. #173
   built it and was closed unmerged, for the reasons above: the drift it
   was premised on does not exist, and what was left removed no code and
   bet on these later phases landing.
   * **The decision point is phase 2 part 2**, where the two parse loops
     do have to learn a second framing rule. If putting that one
     question behind a lookup reads better than a sixth arm on a `case`,
     that is the need arriving and the registry is worth revisiting
     then. Build it from that need and not ahead of it.
2. **Flowspec, SAFI 133 and 134, RFC 8955 and RFC 8956. Done**, in
   #175, #176, #177, #178 and #179. The family reads and writes on the
   wire, two real routers agree, and a malformed rule is reported on
   receive without bgp4r losing the ability to send one. That is the
   measure this plan set itself, so **the whole of phase 2 is
   finished**; what is left for flow spec is the three action
   communities at the end of this entry, each its own piece of work.
   Part 5, the lab, was taken before part 4 deliberately: what the two
   routers do with a rule decided which checks were worth adding and to
   which channel.
   First of the real families, for three reasons. bgp4r was already
   half built here, since every traffic filtering action of RFC 8955
   section 7 was implemented and the rule they filter could not be
   sent, which is the worst combination to leave standing. **Count those
   carefully, because this file used to say five and the code has
   seven**: Table 8 lists seven type and sub-type combinations
   representing **five action kinds**, since rt-redirect has three
   encodings, 0x8008, 0x8108 and 0x8208, for the three Route Target
   forms of RFC 4360 and RFC 5668. Both numbers are right about
   different things and neither is right on its own. Its NLRI is a list
   of typed components rather than a prefix, so it is the family that
   breaks the prefix assumption properly rather than decoratively. And
   it is small enough to finish.

   Both RFCs were read in full on 2026-10-30, attached to the session
   rather than fetched, because the fetch tool caps quoted material at
   125 characters and so will not give back a figure. Every section
   number below was read in the text.
   **`docs/flow-spec.md` is the guide to all of it**, written on
   2026-10-30 after a review of an earlier summary found six things to
   revise. Read it before any of the parts below.
   `test/unit/flow_spec_doc_test.rb` asserts its load bearing claims
   against the library, the way `building_objects_test.rb` guards the
   other primer, and the type number table is **discovered** rather than
   listed so a new component class cannot join the library without the
   document being told. That hole was found by sabotage: a fourteenth
   type was added and the first version of the guard passed.
   1. **The components. Done**, in `bgp/nlris/flow_spec_component.rb`:
      the two operator octets, 19 component types, `Component::Unknown`,
      and the four abstract bases under them. Pure, and nothing
      dispatches to it, the way #125 landed the export rules and #156
      the FIB planner before anything called either. 27 tests.
      * **The five worked examples in the RFCs are the test vectors**,
        RFC 8955 section 4.3 and RFC 8956 section 3.8. Each gives the
        octets for a flow the document describes in words. What that
        buys is narrower than "cannot pass for the wrong reason", which
        is an overstatement this file carried for a day: a vector is
        worth more than an expectation derived here because it is
        independent of **this reader's** understanding of the RFC, and
        that is all it is. It does not make a test immune, as the
        erratum below shows. **Four hand written expectations were wrong
        while this was written and the RFC's hex caught all four**,
        which is the check-the-proof rule in Rules for agents arriving
        from the other direction: the probe was wrong, not the library,
        and the only reason that was visible is that it printed both
        sides rather than a pass or fail.
      * **One of those five vectors is wrong in the published RFC, and
        the test uses the corrected octets.** RFC 8956 errata ID 7571,
        Technical, Verified by John Scudder on 2024-01-12: section 3.8.1
        Table 1 prints the destination as `01 20 00 20 01 0d bb` where
        it should read `01 20 00 20 01 0d b8`. Table 2 of the same
        section decodes that octet as 0xb8 and the prose says
        2001:db8::/32, so the document disagrees with itself and the
        erratum settles it. The test file cites the erratum, so nobody
        "fixes" the vector to match Table 1.
        * Worth recording how that was nearly got wrong. The
          discrepancy was spotted and the conclusion, use 0xb8, was
          right, but the **reason** given was that the HTML to text
          conversion had mangled it. It had not: the RFC itself prints
          `bb`. Right answer, invented mechanism, which is the same
          failure as a wrong RFC citation and leaves the next reader
          nothing to check. **Read the errata for any RFC whose own
          example you are about to disbelieve**, at
          `https://www.rfc-editor.org/errata/rfcNNNN`, before explaining
          the discrepancy some other way.
      * The API shape was the owner's choice on 2026-10-30:
        `initialize(*args)` taking one Array per {op, value} pair, so
        `Port.new([:ge, 137], [:and_le, 139], [:eq, 8080])` is RFC 8955
        section 4.3.2's port component. An `and_` prefix on the operator
        sets the AND bit. A pair may be a Hash instead where a field has
        to be named, which is what a negative test wants, since the
        Array form infers `len` and the end-of-list bit.
      * **One Hash is ambiguous and the rule is written down**: a single
        Hash argument is either one {op, value} pair or the component's
        own `to_hash`. Pairs carry `:op` or `:value` and the wrapped form
        carries the class's own key, which is how they are told apart.
        `test_a_single_pair_hash_is_not_read_as_the_components_own_hash`
        pins it.
      * Every class round trips through its own `to_hash` and all 20 are
        in `test/unit/to_hash_catalog.rb` as `:ok`. That is not luck: the
        hash shape was written against these classes, so no field here
        entered the object after the hash was settled, which is the one
        sentence behind every lossy row in that catalog.
      * **`Component::Unknown` keeps the remainder, and the reasoning
        matters more than the verdict.** The owner had no preference, so
        the decision was made on the plan's own measure: what breadth
        buys over #116 is meaning, since `Attr::Raw` already replays the
        bytes, and raising would give back exactly what #116 gives while
        costing the known components before the odd one their meaning.
        So an unknown type keeps its type octet and all that is left of
        that NLRI value, and encode replays the capture.
        * **This does not contradict the entry below** saying a generic
          `Nlri::Unknown` is not writable, and the difference is the
          whole point: NLRI list framing is per family and cannot be
          split without knowing the family, but inside one flow spec
          NLRI the extent is known from the section 4.1 length field, so
          the remainder is bounded.
        * RFC 8955 section 4.2 is explicit that an unknown component type
          makes the NLRI malformed, so this is a protocol error by the
          RFC's own words and belongs in `Path_attribute#errors` through
          `validation.rb`, not in `#undecoded`. Note what that costs and
          that the RFC asks for it anyway: types 14 to 254 are Unassigned
          in RFC 8956 section 8.1.2, so a type IANA assigns tomorrow will
          read as malformed until bgp4r implements it.
   2. **The NLRI. Done**, in `bgp/nlris/flow_spec.rb`: the section 4.1
      length framing, the component list with its AFI dispatch, and the
      section 8 Route Distinguisher for SAFI 134. Pure again, so nothing
      reaches it yet. 32 tests, the file at 100% line coverage.
      * **The five RFC vectors are worth more here than they were for
        the components**, because each one also prints the **length** a
        correct encoder writes: 0x0b, 0x12, 0x09, 0x12 and 0x0f. So the
        section 4.1 arithmetic is checked against the document rather
        than against a reading of it, and all five agree.
      * **`Flow_spec.nlri_size` is the answer to the framing problem**,
        and it lives with the family rather than in `mp_reach.rb`, so
        the loops can ask instead of calculating. `encode_length` writes
        the field, refusing above 4095 because section 4.1 says that is
        "The highest value that can be represented", which is the one
        refusal Conventions allows a constructor.
      * **That also answers the registry question, and the answer is
        no.** The need turned out to be one more arm on one `case`, read
        by both loops, because the framing belongs to the family and the
        family can own it. One arm is not a registry. Phase 1 stays
        deferred by decision, now on measurement rather than estimate.
      * **A component is kept only if it can give its own octets back,
        which is stricter than catching an exception and has to be.**
        `Prefix` does not raise on a truncated prefix: it pads the value
        out to what its length octet demands and reports the fault
        through `syntactically_correct?`. That is deliberate and long
        predates this, because in the prefix families `Mp_reach#parse`
        slices exactly the right number of octets, so the padding only
        shows on a malformed NLRI. A component list has no such
        guarantee, so `01 18 c0` came back as `01 18 c0 00 00`, three
        octets longer than it arrived. Each component is parsed on a
        **copy** now and the consumption committed only when its
        `encode` matches the octets it ate; otherwise they are kept as a
        tail. The IPv6 prefix class does raise on the same shape, dying
        on a nil offset, so both outcomes are covered and both are
        tested.
      * The hash is one key per component type, so it had the same two
        problems `Path_attribute#to_hash` had and #169's answer is
        reused unchanged: `:duplicates` holds the occurrences after the
        first. The AFI needs no key, because the six shared type numbers
        have a key each per family, so a hash says which family it is.
      * **Type 13 reads two ways and the AFI decides.** RFC 8956 section
        8.1.2 gives its IPv4 name as Unassigned and its IPv6 name as
        Flow Label, so the same octets are a `Flow_label` in an IPv6
        flow spec and a `Component::Unknown` in an IPv4 one. Both
        replay. That is the single registry of section 8.1.2 showing
        through, and it is the clearest demonstration that the AFI is a
        parse time input and not decoration.
   3. **Wiring it to the dispatch points. Done**, in #177. bgp4r reads
      and writes a flow spec UPDATE now, over a real session. Four sites,
      and the count was right but the split was not: site 4 turned out
      to be two halves facing opposite directions, and only one of them
      needed nothing.
      * **The framing. `MpReachCommon::ClassMethods#nlri_size(s, afi,
        safi)` is the one new method**, and both parse loops ask it
        instead of computing `(blen+7)/8+1` themselves. It answers the
        prefix arithmetic for every other family and defers to
        `Flow_spec.nlri_size` for SAFI 133 and 134, so the framing rule
        stays with the family that owns it. It answers nil for octets
        too short to hold a length field, and the loops break on that
        and let the leftover raise, which is how an attribute bgp4r
        cannot read still becomes an `Attr::Raw` with an `Attr::Gap`.
        The third loop in `Mp_reach#parse`, for AFI 3, goes through the
        same method and flowspec does not reach it.
      * `Nlri.factory` for parse and `MpReachCommon#set` for build, one
        arm each. **That is also where the registry question got its
        answer**: one arm on one `case`, read by both loops, is not a
        registry. See phase 1 above.
      * **The AFI cannot be read off a flow spec NLRI, and that broke
        the build gate before it worked.** `afi_from_nlris` reads the
        family off an address, and a rule has components instead, so it
        handed nil to `IPAddr`. `set` skips that inference for these two
        SAFIs and the arm answers from `@nlris.first.afi`, which the
        component keys decide. An explicit `:afi` still wins.
      * **The next hop was two MUSTs, not one, and the receive half was
        a real bug.** Section 4: "the Length of the Next-Hop Network
        Address MUST be set to 0. The Network Address of the Next-Hop
        field MUST be ignored." The first binds a sender and needed no
        code at all: `Mp_reach#encode` writes `@nexthops.size`, which is
        0 with no `:nexthop`, so the rule holds by construction, and
        this entry used to say site 4 was that one sentence. The second
        binds a **receiver**, and `parse_next_hops` raised on a next hop
        for an unknown SAFI, so a flow spec UPDATE carrying any next hop
        at all came back as an `Attr::Raw` with a `Gap` and the rule
        inside was never read. Ignoring a field cannot mean refusing the
        attribute. It is read as an address now, the same way SAFI 1 and
        2 read theirs, which is also what keeps `encode` byte for byte
        and leaves the hash able to rebuild it, for the same reason a
        reserved field is kept and echoed. `nexthop_klass` gained the
        matching arm so one can be built too, because building never
        validates. Nothing claims RFC 8950 applies to flowspec, so
        `ipv6_nexthop_length?` was left alone.
      * **`test/functional/flow_spec_test.rb` is the proof, and it is
        the only one there can be.** Both sides are pure, so every unit
        test on the build side reads octets it wrote itself and every
        one on the parse side is handed octets the test wrote: neither
        can say that what `encode` puts on a socket is what `parse`
        takes off it. 7 tests over loopback, half a second. Named in
        `.github/workflows/test.yml`, which lists each functional test
        by hand.
        * **The assertion that matters is the class, not the hex**, and
          the sabotage is what showed why. With the parse gate's arm
          deleted, `assert_equal(sent.to_shex, got.to_shex)` still
          **passed** on every case and only the `Mp_reach` assertion
          failed: the UPDATE crosses intact and degrades to an
          `Attr::Raw`, which is #116 working as designed. The session
          stays up and nothing looks wrong, so a test checking only the
          session or the octets would have passed against the unwired
          library.
        * Four sabotages, each a site: the parse gate's arm deleted
          fails all 7, the pre-wiring prefix arithmetic in `nlri_size`
          fails all 7, the build gate's arm made unreachable fails all
          7, and **reverting only `Mp_unreach`'s own loop fails exactly
          1**, the withdrawal case, which is what says the two loops are
          independent copies and that one test is all that covers the
          second.
   4. **Validation. Done**, in #179, which finishes phase 2.
      `validation.rb` and nowhere else, per Conventions. **Be exact
      about whose rule it is, because an earlier version of this entry
      called it a receive side rule and it is not.** Section 4.2:
      "Components MUST follow strict type ordering by increasing
      numerical order. A given component type MAY (exactly once) be
      present in the Flow Specification." That MUST binds a **sender**
      as much as a receiver, so bgp4r building a rule out of order is a
      deliberate deviation from a MUST and not merely an unenforced
      receive check. Conventions is why, and the deviation is the
      feature: a test has to be able to put an out of order or repeated
      component on the wire and watch a router decide, which
      `test_a_rule_no_rfc_allows_crosses_a_session` now does over a real
      session. Say that rather than implying the RFC only constrains
      readers. Section 4.2 also makes an unknown component type
      malformed, so that one belongs in `errors` and not `undecoded`.
      * **Part 5 measured what two routers actually do, and it bears
        directly on this.** Neither enforces the ordering MUST; GoBGP
        enforces the once-only rule by resetting and FRR ignores it;
        FRR treats an unknown type as malformed and GoBGP installs it.
        So for the unknown type the RFC and one router agree, which is
        the case for putting it in `errors`, and for the other two rules
        there is no agreement to lean on and the RFC decides. Do not
        copy either router: one agreeing is not a quorum, and the fault
        matrix already showed how far apart two can be on receive.
      * **A missing end-of-list bit is not always detectable**, so do
        not try to recover the sender's intent. The octets that follow
        are read on as further pairs, and where they happen to form a
        valid operator sequence nothing distinguishes that from what was
        meant. `Flow_spec` bounds the walk with the section 4.1 length,
        which is the only bound there is, and keeps what it cannot read.
      * **The subcode is not RFC 8955's to give, and that is the one
        thing this part had to read the RFC for.** Its section 10 is
        four lines, "Error handling according to [RFC7606] and [RFC4760]
        applies to this specification", and names no subcode and no
        action. Section 4.2 sends a malformed NLRI there in its own
        words: one "not encoded as specified here, including an NLRI
        that contains an unknown component type, is considered malformed
        and error handling according to Section 10 is performed". So a
        malformed rule makes the attribute carrying it malformed, and it
        gets what bgp4r already gives a malformed MP_REACH: **subcode 9
        with a session reset**, read from RFC 7606 section 7.11 in the
        two findings that were already there. Inventing a subcode would
        have been the error. FRR 8.4.4 was measured sending 3/9 on an
        unknown component type, which is corroboration and not the
        reason. `test_the_documented_subcode_is_what_the_library_reports`
        in `flow_spec_doc_test.rb` keeps the document and the library
        agreeing on it.
      * **It walks the octets and does not ask `Flow_spec` to parse
        them**, which is the house style of `prefix_sid_finding` and
        `tunnel_encap_finding` and is right for the same reason:
        `Attr::Check` runs on the raw octets and never on the decoder's
        output, so the two channels stay independent. A rule that is
        both malformed and undecodable gets a Finding in `errors` and an
        `Attr::Gap` in `undecoded`, and neither waits on the other.
        Parsing first would mean a rule bgp4r cannot read is never
        reported as a protocol error however plainly the RFC says it is
        one.
        * What it does **not** reimplement is anything the family owns:
          `Flow_spec.nlri_size` gives the section 4.1 framing,
          `Flow_spec::COMPONENTS` the type numbers known per family, and
          `Flow_spec::Pair` the operator masks. So a component class
          added to the library stops being unknown here the same day,
          the masks cannot drift, and **type 13 is malformed for IPv4
          and a Flow Label for IPv6** without validation knowing why.
          Only the component boundary walk is local, because nothing
          else needs it.
      * Each of the three rules was proved to have a test that fails
        when that rule is deleted, and the unknown type guard turns out
        to be load bearing twice: without it `known[comp]` is nil and
        the walk raises, so its test errors rather than passing.
      * **RFC 9117 updates RFC 8955's validation procedure and nothing
        in RFC 8955 or RFC 8956 points forward to it.** "Revised
        Validation Procedure for BGP Flow Specifications", August 2021,
        Updates: 8955. Section 4.1 redefines step (b) of the section 6
        procedure so an empty AS_PATH, or one holding only an
        AS_CONFED_SEQUENCE, also validates; section 4.2 redefines the
        AS_PATH rule so a route server peer works. Both are route
        feasibility, so neither is what `validation.rb` checks and
        neither changes an octet. Recorded because an audit that reads
        only the two flow spec RFCs will conclude the section 6
        procedure stands as written, and it does not.
   5. **The lab. Done**, in #178, and taken **before** part 4 on purpose, because
      what two real routers do with a rule is what tells you which
      checks are worth adding and to which channel. `docs/flow-spec.md`
      section 12 has the measurements; this is what they change.
      * The entry here said to probe first, and probing paid: **both
        routers accept a rule from bgp4r and both give a RIB answer a
        test can read**, which is more than this plan assumed. So there
        are two tests, the twins of the two `rib_router_*` ones:
        `test/functional/lab/flow_spec_gobgp_test.rb`, 8 cases and 50
        assertions in about a minute, and `flow_spec_frr_test.rb`, 9
        cases and 45 assertions in about 45 seconds. Both are picked up
        by `test/run_lab.rb`, which globs the directory, and CI already
        pins the two versions they assert against.
      * **What a second implementation vouches for, which no bgp4r test
        can**: the components by type number, the **operator octet
        whole** (GoBGP prints `op => 129`, our end-of-list bit plus eq),
        the **section 4.1 length** (FRR puts it in the rule's own name,
        `/11`), the RFC 8956 **offset**, the section 8 **RD**, the
        section 7.1 **traffic-rate action**, and a withdrawal.
      * **The two routers disagree on every part of section 4.2**, which
        is the finding that matters for part 4. Out of order: GoBGP
        accepts and normalises, FRR accepts and keeps our order. A type
        twice: GoBGP resets, FRR keeps both. An unknown type, which the
        RFC calls malformed: GoBGP installs it, FRR resets with 3/9. So
        each enforces one of the two enforceable rules, a different one,
        and neither enforces the ordering MUST. **bgp4r follows the RFC
        and not either router**: one router agreeing is not a quorum.
      * GoBGP's reset is its ordering check firing on the repeat, in its
        own words, `ipv4-flowspec nlri violate strict type ordering`,
        and the NOTIFICATION it sends is **code 0 subcode 0**, which RFC
        4271 section 4.5 does not define and its own log calls `code
        0(undefined)`. Recorded, not filed: the job is bgp4r catching
        up, and bgp4r reads the undefined code back correctly.
      * Two harness facts, each measured because each silently voids a
        run. **GoBGP's config file and its client use different names
        for the VPN family**: the config takes `l3vpn-ipv4-flowspec` and
        the client `ipv4-l3vpn-flowspec`, each rejecting the other, which
        is what `Gobgpd::FS_CLIENT` maps. And **FRR 8.4.4 has no VPN flow
        spec family**, failing two ways: SAFI 134 alone is refused with
        2/7 Unsupported Capability, and SAFI 134 beside 133 comes up and
        discards the rule **in silence**. Both asserted, the second
        because a silent discard is the worse one to meet unknowingly.
      * **These two tests send only**, and that is worth knowing before
        trusting them: each asserts a router's reading of what bgp4r put
        on the wire, so reverting `nlri_size` to the pre-wiring prefix
        arithmetic leaves both passing. Measured, by trying it. The parse
        direction belongs to `test/functional/flow_spec_test.rb`. What
        does fail them is an encode-side slip: dropping the end-of-list
        bit fails 5 of the 8 GoBGP cases and 3 of the 9 FRR ones, and a
        section 4.1 length off by one fails 7 of the 9 FRR cases.
   * **Build validates nothing**, per Conventions: any component type,
     any value, any order, any repetition, so a test can put a rule on
     the wire that no RFC allows and watch a router decide. The action
     communities already there do not validate either, and
     `test_nothing_validates` in the component test file pins six
     specific things no RFC allows.
   * **RFC 8956 is not purely an encoding delta, and two of its changes
     are outside the wire format.** Section 4, ordering: RFC 8955
     section 5.1 is reused "with new consideration for the IPv6 prefix
     offset", and "If the offsets are not equal, the lowest offset has
     precedence, as this Flow Specification matches the most significant
     bit". Section 5, validation: item (a) of the RFC 8955 section 6
     procedure "should now read" as "A destination prefix component with
     offset=0 is embedded in the Flow Specification". Neither changes
     any octet, so neither is part 2's work, but do not record RFC 8956
     as an encoding delta alone, which an earlier version of this
     summary did.
   * **Three action communities are missing and none is part of these
     three parts.** Each is small and each is its own piece of work.
     * `rt-redirect-ipv6`, RFC 8956 section 6.1, **type 0x000d**, "the
       same encoding as the IPv6-Address-Specific Route-Target Extended
       Community (Section 2 of [RFC5701])". That community is **20
       octets**, not the 8 of RFC 4360: two type octets, sixteen address
       octets, two Local Administrator octets. Measured on 2026-10-30,
       `Ipv6_extended_community.new(:route_target, '2001:db8::1', 100)`
       encodes 20 octets as `0002`, the address, then `0064`. So this
       goes in `ipv6_extended_communities.rb`, which carries attribute
       **25** and today knows only sub-types 0x02 Route Target and 0x03
       Route Origin; adding 0x0d is an entry in `NAMES` and `LABELS`.
     * The two redirect-to-IP communities of
       `draft-ietf-idr-flowspec-redirect-ip-08`,
       IPv4-address-specific sub-type 0x0c and IPv6-address-specific
       type 0x000c. A draft, so lower priority than the one above.
     * The registration that draft asks IANA to **deprecate** is type
       0x08 of the Transitive Extended Community **Types** registry,
       which is not what bgp4r registered: `Redirect` sits at
       `[0x80,0x08]`, `[0x81,0x08]` and `[0x82,0x08]`, the section 7.4
       redirect-to-VRF encodings, so nothing there is affected. Checked
       on 2026-10-30.
3. **EVPN, SAFI 70, RFC 7432 and six more. Done**, all ten parts: all
   eleven route types read and write on the wire, an EVPN UPDATE
   crosses a session, **every EVPN extended community with an RFC
   behind it is in** (all eleven, five with RFC 9251 and six with the
   rest), a malformed route is reported on receive, and two real
   routers have said what they make of what we send. Planned on
   2026-10-30 from eleven RFCs read in full, attached to the session
   rather than fetched, and finished the same week.

   By the measure this plan set itself, which is the wire and not the
   table, the family was done at part 5: bgp4r parses an EVPN capture,
   replays it byte for byte, and builds one from field values that no
   RFC allows. Parts 9 and 10 added the receive side verdict and the
   outside opinion of it, and part 10 is where the two met: FRR sends
   the same subcode and takes the same action part 9 had to derive with
   no RFC naming either.

   **Two counts in the earlier version of this entry were wrong, and
   both were wrong by reading one RFC where the registry spans seven.**
   It said "five route types" and "the 14 EVPN extended community
   sub-types". The route type count is **eleven**, and that is not an
   IANA-only claim: RFC 9572 section 3 Table 1 lists the eight already
   defined across RFC 7432, RFC 9136 and RFC 9251, and its Table 2 adds
   9, 10 and 11. So the RFC says eleven as plainly as the registry does.
   The 14 figure is right about the EVPN sub-type registry and **misses
   one community**, because RFC 7432 section 7.8's Default Gateway is
   **type 0x03 sub-type 0x0d**, a Transitive Opaque community, not an
   EVPN 0x06 one. It is invisible to anyone counting only the 0x06
   registry. bgp4r's `FACTORY` has no 0x03 sub-types at all, so EVPN
   needs **eleven** communities added, not ten.

   **The NLRI framing is the same shape flowspec just taught us**, which
   is why that experience transfers whole. RFC 7432 section 7: Route
   Type (1 octet), Length (1 octet), Route Type specific (variable). So
   `Evpn.nlri_size` is the analogue of `Flow_spec.nlri_size`, read by
   the same `MpReachCommon::ClassMethods#nlri_size` the flowspec wiring
   added, and the two dispatch gates each take one more arm. **Not a
   registry**, for the reason phase 1 records.
   * **One difference, and it is in our favour: the framing is
     recursive and still self delimiting.** Route type 11's Route Key is
     "the NLRI of the route for which this Leaf A-D route is generated"
     (RFC 9572 section 3.3), and its terminology section says the Leaf
     A-D route "embeds the entire NLRI of the triggering PMSI A-D
     route". Entire, so type and length included, so the Route Key's
     extent is readable from its own length octet and the variable field
     that precedes a length-prefixed address needs no outer arithmetic.
   * **A second difference: no AFI input.** Flowspec needed the AFI at
     parse time, because RFC 8956 section 8.1.2 gives type 13 two
     meanings. EVPN needs none: route type 5's Length field is **34 for
     IPv4 and 58 for IPv6** (RFC 9136 section 3.1), and every other
     variable address is length-prefixed, so the octets say which family
     they are. `Flow_spec::COMPONENTS[afi]` has no EVPN counterpart.

   **Shared primitives, which is what makes ten parts rather than
   eleven.** Reading all eleven layouts together rather than one RFC at
   a time: the Ethernet Segment Identifier, 10 octets, is in types 1, 2,
   4, 7 and 8; the Ethernet Tag ID, 4 octets, is in all but 4 and 11; a
   6-octet MAC is type 2 only; and a **length-prefixed address**, a
   1-octet length then a variable address, carries the IP in types 2, 3,
   4 and 5 and the Multicast Source, Multicast Group and Originator
   Router triple in types 6, 7, 8, 10 and 11. RFC 9251 calls the third
   of those "Originator Router" and RFC 9572 "Originator's Addr"; they
   are one shape under two names, so do not write two classes.
   `Rd` and `Label` bgp4r already has.

   **Two keep-and-echo cases arrive with RFC 9251**, and both are the
   rule Conventions already records for `Traffic_action` and
   `Prefix_entry` rather than anything new. Route types 6, 7 and 8 carry
   a Flags octet whose layout is `| reserved |IE|v3|v2|v1|`, so
   `DEFINED_BITS = 0x0f` and the hash gains `:bits` only when a reserved
   bit arrived set. Route type 8 additionally has a **4-octet Reserved
   field**, which is bigger than any reserved field bgp4r keeps today.
   Conventions' note that the keep-and-echo rule is recent applies: it
   has simply not been reached here yet.

   1. **Primitives and the framing, pure. Done**, in #181. ESI,
      Ethernet Tag ID, MAC, the length-prefixed address, the Route Type
      plus Length framing with `Evpn.nlri_size`, and an `Evpn::Unknown`
      that keeps the remainder and replays it. `docs/evpn.md` is the
      guide, and `test/unit/evpn_doc_test.rb` **discovers** the route
      type table rather than comparing it against a list, so a route
      type class cannot join the library without the document being
      told; proved by sabotage in both directions, since with no route
      type implemented the guard would otherwise have been vacuous.
      * **Two bugs found by probing rather than by reading**, each with
        a regression test. `Esi#encode` returned `@value` itself, so
        building from it emptied the ESI being copied, because `parse`
        reads with `slice!`: the symptom is the one Conventions warns
        about, a round trip that fails while both sides print the same
        hex. And an ESI built from an Integer used `String#<<` with an
        Integer, which appends a **codepoint**, so every octet from 0x80
        up became the two bytes of its UTF-8 encoding and `.b` afterwards
        relabelled without undoing the expansion; the ESI came back 12
        octets. A test using only low octets passes against that, so the
        test goes all the way up.
      * **A third error was caught in the document before it shipped**,
        and only because the doc test reads `FACTORY` rather than taking
        the claim on trust: a draft said bgp4r registers no 0x03
        extended community sub-types. It registers three, `[0x03,0x00]`
        Origin Validation State, `[0x03,0x0b]` Color and `[0x03,0x0c]`
        Encapsulation. Only 0x0d is missing, which is the Default
        Gateway of section 7.8.
      * **Every length field in this family is in bits**, which is the
        detail memory reverses, and the four citations are quoted in the
        guide. **RFC 9572 is the one that does not say**: it has no such
        sentence and for route type 10 defers to RFC 7117, which has not
        been read here. Recorded as open rather than guessed, and it is
        part 7's question.
      * **The MAC and the IP disagree about what a length means**, on
        consecutive lines of one figure: section 7.2 gives the MAC as
        "(6 octets)" flat and the IP as "(0, 4, or 16 octets)". So
        `Sized#parse` does not infer its own width, it is told, and
        `Mac_addr` overrides `octets_for`.
   2. **Route types 1 and 4. Done**, in #182, RFC 7432 sections 7.1
      and 7.4, taken together because both are RD plus ESI shaped.
      Route type 1 is fixed at 25 octets; route type 4 is 23 with an
      IPv4 address and 35 with an IPv6 one.
      * **`BGP::Label` is reused for the MPLS Label rather than
        reimplemented.** Section 7.1 says only "MPLS Label (3 octets)"
        and describes no internal layout, and `Label` already writes a
        20-bit label in the top 20 bits of three octets, which is what
        GoBGP and FRR read back, while keeping the three bits below and
        the low bit so an unusual value replays. Its hash keys `:label`
        and `:exp` merge flat into the route's hash, since neither
        collides with a field of the route.
      * **A route type is kept only if it can give its own octets
        back**, which is the rule `Flow_spec` already applies to its
        components and is right here for the same reason: both layouts
        are fixed width and nothing in the framing guarantees the Length
        agrees, so a short body would invent the fields it did not find
        and answer `encode` with octets the peer never sent. The body is
        parsed on a **copy** and accepted only when its `encode` matches.
        A body that fails falls back to `Evpn::Unknown`, so a route type
        number the library does implement can read back as Unknown. That
        looks odd and is the honest answer; `declared_len` still records
        the Length that lied.
      * **`Rd` does not consume the String it is handed, where all four
        primitives from part 1 do.** Measured, not assumed. So the route
        parse slices the 8 RD octets itself and lets the rest read
        themselves. Conventions already records that which classes
        consume is per class and has to be checked.
      * **An Array field is splatted in `coerce`**, because that is the
        shape `Rd#to_hash` answers with: `{:rd => [100, 200]}` against
        an `Rd.new(100, 200)`. Without the splat the Array lands in the
        Administrator field and `encode` dies on a nil Assigned Number,
        which is how this was found.
      * Route key processing is not implemented and is not a gap:
        section 7.1 makes the MPLS Label "a route attribute as opposed
        to being part of the route" and section 7.4 names its own prefix
        fields, which matters to a RIB, and no EVPN route goes in one.
   3. **Route types 2 and 3. Done**, in #183, RFC 7432 sections 7.2
      and 7.3, which finishes the whole of section 7. Type 3 is 17
      octets with an IPv4 address and 29 with an IPv6 one, and is **the
      only one of the five with no Ethernet Segment Identifier**, worth
      saying because every other type has one and a reader will look.
      Type 2 is the largest layout in the family.
      * **The field rules for type 2 are in section 14, not section
        7.2.** That is where to look and all three matter. The MAC:
        "The MAC Address Length field is in bits, and it is set to 48.
        MAC address length values other than 48 bits are outside the
        scope of this document" — outside the scope is **not** an error,
        which is exactly why part 1's `Mac_addr` echoes any length and
        keeps its 6 octets. The IP: "The IP Address field is optional.
        By default, the IP Address Length field is set to 0, and the IP
        Address field is omitted from the route." And Label2: "The MPLS
        Label2 field is an optional field. If it is present, then it is
        encoded as 3 octets."
      * **Six lengths are possible and all six are distinct**: 33, 36,
        37, 40, 49 and 52. That is what lets section 14 say "The Length
        field of the EVPN NLRI ... is sufficient to determine whether an
        IP address is encoded in this route and, if so, whether the
        encoded IP address is IPv4 or IPv6." bgp4r does **not** use the
        outer Length for it: the IP Address Length field is the in-band
        discriminator and `Addr` reads it directly. The two can only
        disagree on a malformed route, and part 2's encode-matches rule
        catches that. The distinctness is asserted from the library
        rather than from the document's list.
      * **Label2 is decided by what is left**, which is sound only
        because the body is bounded: `Evpn` slices exactly Length octets
        and hands them down. Two octets left over are not a Label2 and
        not an error there either; `encode` then cannot reproduce the
        body and the NLRI falls back to `Unknown`, replaying it.
      * **The two labels are named rather than merged flat, unlike route
        type 1, and the reason is the count.** One label can merge its
        own `:label` and `:exp` keys into the route's hash because
        nothing collides; two cannot. So each rides under `:label1` and
        `:label2` holding `Label`'s own hash, and `:label2` appears only
        when there is one.
      * **A bug #182 shipped, found while writing this and fixed here.**
        `BGP::Label.new` with no argument leaves its label unset, so
        `Ethernet_ad.new(rd, esi, tag)` with the label omitted raised
        `NoMethodError` inside `Label#encode`, "undefined method `<<'
        for false". The four argument form and the no argument form both
        worked, which is why it went unnoticed. `coerce_label` defaults
        to label 0 in one place for both route types that carry one, and
        `test_a_route_type_built_without_its_label_still_encodes` is the
        regression.
      * **An empty route type 2 is 33 octets, not 27**, because the MAC
        defaults to 48 zero bits where the IP defaults to absent. That
        difference is the RFC's: section 14 calls the IP optional in so
        many words and fixes the MAC's length at 48. A MAC left out
        entirely still builds, since nothing validates; it is just not
        the default.
   4. **Route type 5. Done**, in #184, RFC 9136 section 3.1, the IP
      Prefix route, which completes the core set every EVPN
      implementation has. The section states the sizes outright: "The
      Length field of the BGP EVPN NLRI for an EVPN IP Prefix route MUST
      be either 34 (if IPv4 addresses are carried) or 58 (if IPv6
      addresses are carried)."
      * **Two things make this layout unlike every other route type and
        both are easy to get wrong.** The IP Prefix Length octet is a
        **prefix length and not a field width**: section 3.1 says it
        "specifies the number of bits in the prefix" while "The IP
        prefix is a 4- or 16-octet field", so unlike `BGP::Prefix` the
        octets are not packed down and 10.0.0.0/8 still occupies four of
        them. And the **GW IP Address has no length octet at all**, so
        it is raw octets; `Addr` is wrong for both fields.
      * **The family comes from the body's own size**, 34 or 58, which
        is the one place in the family with no in-band discriminator to
        prefer. That is the same information the outer Length carries,
        read locally so the class stays readable on its own. Do not
        read this as contradicting part 3: there the IP Address Length
        field was available and better, here nothing of the kind exists.
      * **A bug found by probing a value the RFC forbids.** Section 3.1
        says the prefix length "MUST NOT be greater than 128"; nothing
        validates, so 200 builds, and the hash carried it as
        `"10.0.0.0/200"`, a string `IPAddr` refuses, so the round trip
        died. An out-of-range length is part of the unusual case and
        hashes as the `{:len, :octets}` pair with the odd widths.
      * **Three of RFC 9136's own rules are receive side and are part
        9's work, recorded in `docs/evpn.md` so they are not lost.** All
        three are stated as RFC 7606 treat-as-withdraw, so they are
        error handling and not policy: a zero label with no Overlay
        Index (section 3.1, MUST); a non-zero GW IP and a non-zero ESI
        at once (section 3.2, SHOULD); and ESI, GW IP, MAC and Label all
        zero at once (section 3.2, SHOULD). **The complication to know
        before starting them**: the third reads the EVPN Router's MAC
        Extended Community, a different path attribute, so it is not a
        check `validation.rb` can make from the MP_REACH octets alone.
      * Route key, for the record: section 3.1 says "The RD, Ethernet
        Tag ID, IP prefix length, and IP prefix are part of the route
        key used by BGP to compare routes. The rest of the fields are
        not part of the route key." Matters to a RIB, and no EVPN route
        goes in one.
   5. **Wiring to the dispatch sites, plus a loopback functional test.
      Done**, in #185. bgp4r reads and writes an EVPN UPDATE now, over a
      real session. **Five sites, not four**: flow spec needed the
      framing, the two gates and a next hop sentence that cost no code,
      where EVPN needs a next hop that does.
      * `IANA::SAFI::EVPN` did not exist and is now 70, from RFC 7432
        section 11, "IANA has assigned BGP EVPNs a SAFI value of 70".
        AFI 25 was already `IANA::AFI::L2VPN`.
      * `nlri_size` defers to `Evpn.nlri_size`, `Nlri.factory` and
        `MpReachCommon#set` take one arm each, and `set` skips
        `afi_from_nlris` as it does for flow spec. **The difference is
        that flow spec answers from its components' keys and EVPN has
        nothing to answer from and nothing to ask**: section 7 fixes AFI
        25, so the arm sets it.
      * **The next hop is where EVPN differs from every family already
        wired.** Section 14: "The Next Hop field of the MP_REACH_NLRI
        attribute of the route MUST be set to the IPv4 or IPv6 address
        of the advertising PE." So unlike flow spec, which must write a
        length of 0, EVPN writes a real address, and unlike SAFI 1 and 2
        **the AFI cannot say which family it is**, because it is 25 for
        both. The field's length is the only discriminator, 4 octets or
        16. `ipv6_nexthop_length?` is left alone: nothing says RFC 8950
        applies to EVPN and its lengths are keyed on AFI 1 anyway. A
        field too short for either reads as IPv4 and `Prefix` pads it,
        which is what SAFI 1 already does, so that is consistency with
        the library rather than a new rule. `nexthop_klass` answers a
        plain `Prefix` with no `Ipv4_mapped` branch, since that one
        exists only because an IPv4 next hop under AFI 2 is written as
        an IPv4-mapped address.
      * **`test/functional/evpn_test.rb` is the proof and the only one
        there can be**, for the reason `flow_spec_test.rb` records. 9
        tests, 117 assertions, under a second. Named in
        `.github/workflows/test.yml`, which lists each functional test
        by hand.
      * **Five sabotages, one per site, and the last two are the
        informative ones.** The parse gate's arm, `nlri_size` reverted
        to the prefix arithmetic, and the build gate's arm made
        unreachable each fail or error all 9. The next hop arm deleted
        fails **8**, sparing the withdrawal case, which carries no next
        hop. And reverting only `Mp_unreach`'s own loop fails **exactly
        1**, the withdrawal, which is what says the two parse loops are
        independent copies and that one test is all that covers the
        second. The flow spec wiring measured the same signature, so
        expect it again for the next family.
      * **Two of #116's tests used EVPN as their example of an
        undecodable family, and wiring EVPN in made them fail.** They
        assert that a valid attribute bgp4r cannot decode becomes an
        `Attr::Gap` and not a protocol error, and SAFI 70 now decodes,
        so the example stopped being one. The constant is `UNDECODABLE`
        now and points at BGP-LS, AFI 16388 SAFI 71, which is phase 4
        and so the furthest out. **Every assertion is unchanged; only
        the family moved.** Whoever wires BGP-LS in will have to move
        them again, and the same rule applies then: re-point the
        example, do not weaken the assertion. Conventions says not to
        weaken an existing test to make a change pass, and this is what
        that looks like when the test is right and its example has
        expired.
   6. **Route types 6, 7 and 8. Done**, in #186, RFC 9251 sections 9.1
      to 9.3, which brings the two keep-and-echo cases part 1 planned
      for. Route type 7 is route type 6 with an ESI, and route type 8 is
      route type 7 with a 4-octet Reserved field and a Maximum Response
      Time before the Flags, so the three are one layout with two
      additions and share the address triple through
      `Evpn::Multicast_fields`.
      * **The first layouts in the family variable in more than one
        place.** Each carries three length prefixed addresses in a row,
        so neither the route type nor the outer Length says where a
        field ends: the body describes itself, field by field. Route
        types 2 to 5 each had at most one variable field.
      * **A module and not a base class, and the reason is the doc
        test.** `evpn_doc_test.rb` discovers the route type table from
        the `Route` subclasses the library defines, so an abstract
        `Multicast < Route` would read as a twelfth route type with no
        row to put it in. A module is in `Evpn.constants` and that
        guard does not count it. The guard fired on the table rows for
        6, 7 and 8 while this was written, which is it working.
      * **The four defined Flags bits are the low nibble**, which the
        sections say rather than leaving to the figure: "The least
        significant bit (bit 7) indicates support for IGMP version 1",
        then bit 6 version 2, bit 5 version 3, bit 4 Include/Exclude.
        So `DEFINED_BITS` is `0x0f` and the reserved field is the high
        nibble, which is the opposite of what the figure reads like
        left to right. Sabotaged to `0xf0`: 2 failures and 18 errors.
      * **Route type 8's Reserved field is the first one an RFC asks to
        be echoed in so many words.** Section 9.3.1: "The originator
        MUST set the Reserved field to 0; the receiver SHOULD ignore
        it, and if it needs to be propagated, it MUST propagate it
        unchanged." Conventions mandates keep and echo on bgp4r's own
        grounds, which are that a tool able to send a value no RFC
        describes has to be able to replay what it just sent. Here an
        RFC agrees, which is worth knowing before anyone files the
        behaviour as over-engineering. Four octets, the largest
        reserved field in the library.
      * **A bug this found in `Sized#parse`, from part 1.** It read its
        length octet with `unpack1('C')`, which answers nil when the
        body has run out, and `octets_for` then raised `NoMethodError:
        undefined method '+' for nil`. Route types 2 to 5 could only
        reach that with a truncated body, where these three reach it
        with a body of exactly the right length and one field lying:
        a Multicast Source Length of 200 bits claims the rest of the
        body, so the two fields behind it find nothing. `.to_i` reads
        an absent field as length 0, `encode` then comes back the wrong
        length, and `Evpn#read_route` falls back to `Unknown`, which
        replays the capture. Found by probing a value no RFC allows,
        not by reading. Regression test, and reverting it fails 1 and
        errors 1.
      * **`addr_hash` was lifted into `Route`**, where three route
        types had identical private copies of it and these three would
        have added nine more uses. No behaviour change: the third copy
        had an extra `empty?` guard that answered the same thing, since
        an empty `Addr` has no address.
      * **An absent Multicast Source is the ordinary case here, not the
        unusual one**, which is the opposite of route type 2's optional
        IP. Section 9.1.1: "In case of a (*,G) Membership Report, the
        Multicast Source Length is set to 0" and the address "field is
        not used". `to_s` prints the `*` the section writes, and
        section 9.1.3's default route is (*,*).
      * The functional test gained four cases, 13 now, which is still
        the only test that proves the five wiring sites agree.
   7. **Route types 9, 10 and 11. Done**, in #187, RFC 9572 sections
      3.1 to 3.3, so **all eleven route types are in**. The three have
      less in common with each other than the RFC 9251 trio do. Route
      type 9 is fixed at 20 octets; route type 10 is route type 6
      without its Flags octet; route type 11 is the recursive one.
      * **The units question part 1 recorded as open is closed, and
        how it was closed is the part to keep.** RFC 9572 has no "in
        bits" sentence anywhere, confirmed by reading the whole text.
        Section 3.2 says only that route type 10 is "identical to the
        S-PMSI A-D route as defined in [RFC7117]" apart from two added
        fields, and that route carries the RFC 6514 section 4.3
        encoding, which answers it by value rather than by the word:
        "If the Multicast Source field contains an IPv4 address, then
        the value of the Multicast Source Length field is 32." 32 for
        IPv4 and 128 for IPv6 is a bit count. So `Addr` is right for
        all three fields of route type 10 and for route type 11's
        Originator's Addr.
        * **Which link is first hand is recorded, because that is what
          an audit needs.** The RFC 6514 sentence was read in
          draft-ietf-bess-rfc6514bis-00 section 4.3, which obsoletes
          RFC 6514. **RFC 7117 section 9.2.1 itself was not read**:
          three fetches got no further than section 8.4.3, and
          rfc-editor.org is not reachable from this session. The
          doc test asserts both halves, so the answer cannot keep its
          confidence while losing its provenance.
        * RFC 6514 section 4.3 also says "Usage of other values of the
          Multicast Source Length and Multicast Group Length fields is
          outside the scope of this document", the same "outside the
          scope is not an error" shape RFC 7432 section 14 uses for the
          MAC length. Which is why `Addr` echoes any length here too.
      * **`Region_id` holds 8 octets and is not an extended community,
        measured rather than assumed.** Section 3.1 says it "is encoded
        in the same way that an EC is encoded", so reusing
        `BGP::Extended_community` was the obvious move, the way `Label`
        is reused for the MPLS Label. Two things rule it out. It
        **cannot be rebuilt from its own `to_hash`**: neither `factory`
        nor `new` takes a Hash, so route type 9's hash round trip would
        break and have to be recorded as a loss. And it buys no meaning
        anyway, because when this was written **all three of section
        6.2's own examples read back as `Extended_community::Unknown`**:
        two use sub-type 0x09, Source AS of RFC 6514 section **6**, and
        the third is "a Transitive IPv4-Address-specific EC of any
        sub-type". Sub-type 0x09 is registered now, in #197, so the
        first two read back as a `Source_as`. The third still does not,
        and the verdict stands either way, since it rests on the hash
        round trip. **The citation here used to say section 4.5, twice
        in this file, and 4.5 is "Source Active A-D Route"**: read in
        the RFC on 2026-10-31 rather than carried forward again.
      * **The Flags moved out of `Multicast_fields`**, where part 6 put
        it. Route type 10 carries the triple and no Flags, so an
        `attr_reader :flags` in the shared module would answer nil for
        it and read as a field that is there and unset. The three RFC
        9251 types declare their own now.
      * **Route type 11 is the only one with neither an RD nor an
        Ethernet Tag ID**, and that follows from the Route Key rather
        than being an omission: section 3.3 makes it "the NLRI of the
        route for which this Leaf A-D route is generated" and the
        terminology section says the route "embeds the entire NLRI of
        the triggering PMSI A-D route". Entire, so whatever the
        triggering route carried is reached through the Route Key.
        Section 3 confirms it from the other side, since the RD rule it
        states for types 9 and 10 names "non-Leaf A-D routes" as the
        ones that must match.
      * **The recursion cost nothing, which is what part 1 predicted.**
        A Route Key's extent comes from its own Length octet, so
        `Evpn.nlri_size` answers it and `Evpn` parses it, and the
        variable width field in front of the Originator's Addr needs no
        outer arithmetic.
      * **`Leaf_a_d` reaches `Evpn` at call time and not at load
        time**, which is what makes a route type in `evpn_route.rb`
        able to hold an NLRI from `evpn.rb`: `Evpn` is the class around
        every route type and the NLRI's own methods are added by the
        file that requires this one. So it is the one class there that
        does not work against `evpn_route.rb` alone, and **its tests
        live in `test/unit/nlris/evpn_test.rb`** beside the framing they
        exercise. Keeping the other ten tested against `evpn_route.rb`
        by itself is what proves they need no NLRI, and the doc test
        asserts that too.
      * The functional test gained four cases, 17 now, including two
        Leaf A-D routes in one attribute, which is the only thing that
        says the recursion does not over-read.
   8. **The eleven extended communities. Done**, in two pull requests,
      because eleven classes in one is not a small diff: **8a** in #188
      with the five of RFC 9251, and **8b** in #190 with the other six.
      * **The registry, measured on 2026-10-30 rather than recalled,
        and it explains both figures this file carried.** The "EVPN
        Extended Community Sub-Types" subregistry under type 0x06 has
        **18 assigned entries**, 0x00 to 0x10 and 0x15. **Fourteen have
        an RFC**, three cite only drafts (0x0e EVPN Attachment Circuit,
        0x10 EVPN Link Bandwidth, 0x15 RT-derived-EC) and one is
        Reserved (0x07). bgp4r had four of the fourteen, so ten were
        missing, and the eleventh is the Default Gateway at `[0x03,
        0x0d]`. **So the fourteen and the ten were right about different
        things**: the count with an RFC and the count still to write.
        The prose here read as though they disagreed.
      * **8a, the five of RFC 9251. Done**, in #188: Multicast Flags at
        0x09 (section 9.4) and the four EVI-RT types at 0x0a to 0x0d
        (section 9.5). Taken first because route types 7 and 8 need
        them, since section 9.5 says each "MUST carry exactly one EVI-RT
        EC".
        * **The EVI-RT value is a Route Target's value field and the
          sub-type says which kind**, so the six octets split the way
          that RT's structure splits them: 2 plus 4 for a Two-Octet
          AS-specific RT, 4 plus 2 for an IPv4-Address-specific or a
          Four-Octet AS-specific one. None has a reserved bit, because
          every octet is a field of the RT. They are their own classes
          and not `Route_target` under another sub-type because section
          9.5 says an EVI-RT EC "is not a Route Target extended
          community, is not visible to the RT Constrain mechanism
          [RFC4684], and is not intended to influence the propagation of
          routes by BGP".
        * **Type 3 is the one RFC 9251 contradicts itself about, and
          bgp4r follows the figure and the registry.** Section 9.5 says
          its value is identical to the value field of "a Transitive
          IPv6-Address-specific EC", which RFC 5701 section 2 makes
          **18 octets**; an EVPN extended community has 6. The same
          section's figure shows the 8-octet form and section 12.1
          registers 0x0d in the 0x06 subregistry, which is the 8-octet
          family, and a 20-octet community would need a code point in
          the IPv6-address-specific registry that IANA does not list.
          There is no erratum on RFC 9251 about it, checked. So
          `Evi_rt_3` carries its six octets and does not split them, and
          `docs/evpn.md` records the mechanism rather than the verdict.
        * **The two defined Multicast Flags bits are the least
          significant of the Flags field**, which section 9.4 says
          rather than leaving to the figure, and section 12.3's registry
          numbers the bits "0-15, from high order to low order". So in
          the 48-bit value IGMP is bit 32 and MLD bit 33.
        * **A FACTORY entry with no HASH_BUILDERS entry is half a
          wiring, and `extended_communities_test.rb` already guards
          it.** `test_every_wire_form_the_factory_knows_survives_its_own_hash`
          pins `FACTORY.size + 1` forms, so five new registrations fail
          it until five forms are added, and each form goes through
          `factory`, `to_hash`, `new` and `encode`. Measured the hard
          way first: the classes parsed and `Extended_communities.new(a
          hash)` raised `NoMethodError` inside `factory`.
        * **These five unwrap their own hash key, where their four EVPN
          siblings do not, and `Traffic_action`'s comment is the
          reason.** Without the unwrap the wrapped hash gives nil for
          every field and a community of **zeros** is built in silence,
          because these field defaults pass their own check. That is the
          exact failure that comment records, measured here before the
          unwrap went in, so these are `:ok` in the catalog where
          `Mac_mobility`, `Esi_label`, `Es_import` and `Router_mac` are
          `:elsewhere` with `NO_HASH_BRANCH`: those four raise rather
          than building a wrong one, so nothing there is quiet.
        * **The community table in `docs/evpn.md` section 7 is
          discovered, not listed**, the twin of the route type guard: it
          reads `FACTORY` and cross-checks the "In bgp4r" column in both
          directions. The hard coded count it replaced said "four", and
          adding these five is what made it false. **The DF Election
          citation was wrong in a draft of that table and reading RFC
          8584 caught it**: that community is section **2.2**, not 5.1.
          Section 5 is "Solution Benefits".
      * **8b, the other six. Done**, in #190: EVPN Layer 2 Attributes
        at 0x04 (RFC 8214 section 3.1), E-Tree at 0x05 (RFC 8317
        section 6.1), DF Election at 0x06 (RFC 8584 section 2.2,
        extended by RFC 9785 section 3),
        ARP/ND at 0x08 (RFC 9047 section 2), Service Carving Time at
        0x0f (RFC 9722 section 2.1), and the Default Gateway at `[0x03,
        0x0d]` (RFC 7432 section 7.8, whose IANA reference is an
        author's name rather than an RFC). `docs/evpn.md` section 7b is
        the guide.
        * **The split of shapes was not quite what the earlier version
          of this entry said.** It read "five of the six are flags plus
          reserved fields". Four are: 0x04, 0x05, 0x06 and 0x08.
          Service Carving Time has no reserved bit at all, which that
          sentence had right, and **the Default Gateway has no fields
          at all**, which it did not: RFC 7432 section 7.8 says "The
          Value field of this community is reserved (set to 0 by the
          senders, ignored by the receivers)", so all 48 bits are
          reserved. It is the purest keep-and-echo case in the library,
          `DEFINED_BITS` is 0, and its hash is an empty list until a
          peer puts something in there. The miscount came from reading
          section 7.8 last.
        * **E-Tree is `Esi_label` with a different name on the bit**,
          same layout and the same mask, `(1 << 40) | (0xfffff << 4)`.
          Unlike RFC 7432 section 7.5 it does say where the label sits:
          "The value of the 20-bit MPLS label is encoded in the
          high-order 20 bits of the Leaf label field".
        * **Three RFCs define bits in the one DF Election Bitmap and
          all three are read**, which is a correction to what #190
          shipped and what this entry first said. RFC 8584 section 2.2
          gives bit 1, AC-DF, and leaves bits 0 and 2 to 15
          unassigned; **RFC 9722 section 2.1 adds bit 3**, Time
          Synchronization; **RFC 9785 section 3 adds bit 0**, the D or
          "Don't Preempt" bit. Nothing in RFC 8584 points forward to
          either. A mask covering only RFC 8584 would report a correct
          T or D bit as a reserved one. Same shape as the
          `Pmsi_tunnel` flags registry: a bit one RFC leaves
          unassigned is a bit a later RFC can fill, so check the
          registry and not only the defining RFC.
          * **#190 wrote that sentence down and then missed RFC 9785
            by it**, which is the part worth keeping. The RFC was
            uploaded with the EVPN set and named in `docs/evpn.md`'s
            own RFC table as "further communities and procedures",
            and was never opened: the registry was read through the
            two RFCs in hand rather than looked up. So the rule is
            not enough on its own. **Read every RFC that lists itself
            as updating the one you are implementing**, and RFC
            9785's header says `Updates: 8584` in so many words.
          * Fixed in the DF Election follow up, with the two DF Alg
            values and the DF Preference field below. Nothing was
            wrong on the wire while it was missing, because
            keep-and-echo replayed the octets as reserved bits; what
            was missing was the meaning, which is the whole of what a
            breadth phase buys over #116.
        * **RFC 9785 section 3 also takes the last two of RFC 8584's
          three reserved octets**, for a DF Preference, and section 6
          allocates DF Alg 2 Highest-Preference and 3
          Lowest-Preference. So `ALGORITHMS` has five entries now and
          4 to 30 are what is left unassigned.
          * The field is "specific to Highest-Preference and
            Lowest-Preference Algorithms", where "the default value
            MUST be 32767", and for any other algorithm the section
            says only that "these 2 octets can be encoded
            differently". **So bgp4r reads it under every algorithm
            and names it a preference under only those two**: reading
            it always is what makes the octets replay, and `to_s`
            prints `last octets 0x1234` elsewhere rather than
            claiming a meaning the RFC withholds. `DEFINED_BITS`
            gains the low 16 bits either way, so the one remaining
            reserved octet is still what earns a `:bits` entry.
          * The default is per algorithm, so a preference algorithm
            **always** carries the value in its hash, where any other
            carries it only when non-zero. Without that an alg 2
            community with a preference of 0 would hash as the pair
            and read back as the section 3 default of 32767, which is
            a wrong value rather than a lost one. A test pins it.
        * **Four RFCs number their flag bits twice, and the
          second number is what the placements were checked against.**
          RFC 9047 section 2 says R is "Bit 7 of the Flags field" and
          "Bit 23 of the Extended Community", O is bit 6 and bit 22, I
          is bit 4 and bit 20; RFC 8584 says the Bitmap's bit 0
          "corresponds to Bit 24"; RFC 9722 says its T bit
          "corresponds to Bit 27"; RFC 9785 says its D bit is Bitmap
          "Bit 0 (corresponds to Bit 24 of the DF Election Extended
          Community)", which is RFC 8584's sentence from the other end
          and so pins the Bitmap's own origin twice over. All six hold.
          `test_each_flag_sits_at_the_bit_number_its_own_rfc_gives_it`
          asserts them, and `docs/evpn.md` section 7b has the table,
          which `evpn_doc_test.rb` reads out of the document rather
          than trusting. **That is worth as much here as the five RFC
          vectors are for flow spec**, and for the same narrow reason:
          the number is the document's own, so it is independent of
          this reader's arithmetic.
        * **`DEFINED_BITS` is derived by a test now rather than
          restated.**
          `test_every_defined_bits_mask_is_exactly_what_its_own_fields_can_write`
          sets every field of a class to its widest value, ORs the
          value bits, and requires the result to be exactly the mask.
          Less means `encode` writes a bit the class calls reserved, so
          a community built from field values would carry a `:bits`
          entry; more means a field the class reads cannot be reached.
          It covers the four older EVPN classes, `Traffic_marking` and
          `Encapsulation` too, and all ten agreed first time. A one bit
          typo in any of them fails it.
        * **A bug #188 shipped, found here and fixed.**
          `Multicast_flags` unwrapped the hash `to_hash` answers and
          then read the list inside it as a Hash, so
          `Multicast_flags.new(its own to_hash)` raised `TypeError`.
          Part 8a's test only ever fed it the value under the key, so
          nothing caught it. The unwrap is one method on the base now,
          `Extended_community::Typed#unwrap`: unwrap, then dispatch on
          the shape, in one place for all nine classes that take the
          wrapped form. `Evi_rt` had already got the order right and
          `Traffic_action` survived only because its hash value is
          always a Hash.
        * **And a bug this part nearly shipped**, which is why `Arp_nd`
          has a test asserting the community is 8 octets: its first
          draft packed the value as `CNn`, one Flags octet and 5
          reserved, which is 1 + 4 + 2 and writes 7. Found by probing a
          round trip, not by reading.
        * **Two guards over every `Typed` class the factory knows**,
          discovered from `FACTORY` so a new class cannot join without
          being covered. A wrapped hash handed back to `new` must build
          the same octets or be refused, and a refusal must be an
          `ArgumentError`, which is a class saying no. A `TypeError` or
          a `NoMethodError` is a class reading a shape it never
          checked, which is the `Multicast_flags` bug. Conventions'
          rule that `Klass.new(Klass#to_hash)` was never the contract
          still stands: a class may refuse the wrapped form, it may not
          accept it and build something else.
        * The doc test's "the Default Gateway is still missing"
          assertion failed the moment the class landed, which is the
          guard working. It was re-pointed at the new truth rather than
          weakened, the same way #185 re-pointed #116's undecodable
          family from EVPN to BGP-LS.
   9. **Validation. Done**, in #191, in `validation.rb` and nowhere
      else per Conventions. `evpn_finding` is reached from both the
      MP_REACH and the MP_UNREACH arm, reuses `Evpn.nlri_size` for the
      framing and takes each route type number from the class that
      defines it. Eight checks; `docs/evpn.md` section 8a is the guide
      and has them in a table the doc test reads.
      * **Three of the eleven route type RFCs were measured for error
        handling text and two have none at all.** RFC 7432 and RFC 9572
        never say "malformed" and never mention RFC 7606. **RFC 9251
        section 9.7, "BGP Error Handling", is the only EVPN RFC that
        does**, and what it says agrees with what bgp4r already gives a
        malformed MP_REACH: "If a received BGP update is malformed such
        that BGP route keys cannot be extracted, then the BGP update
        MUST be considered invalid. The receiving PE MUST apply the
        'session reset' procedure per [RFC7606]." So the framing and
        length findings are subcode 9 with a session reset, citing RFC
        7606 section 7.11 as the two MP_REACH findings already there
        do, and the two that a route type's own RFC calls
        treat-as-withdraw get that instead, which is RFC 7606 section 3
        working as intended. **Inventing a subcode was the trap here**,
        the same one flow spec part 4 recorded.
      * **An unknown route type is reported nowhere, where an unknown
        flow spec component type is malformed.** The asymmetry is the
        RFCs' and is worth knowing before anyone "fixes" it: RFC 8955
        section 4.2 says in so many words that an NLRI with an unknown
        component type "is considered malformed", and no EVPN RFC says
        anything of the kind. Types 12 to 255 are unassigned, so
        reporting one would make bgp4r call a correct router malformed
        the day IANA assigns type 12. A test pins the decision, and
        sabotaging it to report one fails.
      * **Two of the eight run on an MP_REACH only, and the route key
        is the reason.** RFC 9136 section 3.1 says only "The RD,
        Ethernet Tag ID, IP prefix length, and IP prefix are part of
        the route key", and RFC 9251 section 9.1 says "all the fields
        are considered to be part of the prefix in the NLRI, except for
        the 1-octet Flags field". So a withdrawal's ESI, GW IP and
        Flags are don't-care. The version flag rule is the one where
        checking a withdrawal would be **actively wrong** rather than
        noisy: section 4.1 asks a PE to withdraw the route rather than
        re-advertise it with the flags reset, so bgp4r would report the
        very withdrawal the RFC asked for. Both guards are sabotaged
        and both fail when removed.
      * **A correction to `docs/evpn.md`, which part 4 had wrong.** It
        said one of RFC 9136's three treat-as-withdraw rules needs the
        EVPN Router's MAC Extended Community. **Two do.** Section 3.2
        lets an Overlay Index be "an ESI or IP address in the address
        space of the tenant or MAC address", and says it is indicated
        "in the ESI field, GW IP field, or EVPN Router's MAC Extended
        Community", so the zero-label rule cannot be decided without
        reading that community either. Both are cross-attribute and
        `Attr::Check.attribute` is handed one attribute at a time,
        which is the same reason the missing well-known mandatory check
        is not there. Only section 3.2's ESI-and-GW-IP rule is in.
      * **Two tests elsewhere had examples that expired, and both were
        re-pointed rather than weakened.**
        `mp_reach_test.rb`'s `test_an_unimplemented_safi_still_raises`
        used AFI 25 SAFI 70, which stopped being unimplemented at #185;
        it now uses BGP-LS, as #116's two tests already do, and every
        assertion is unchanged. And the doc test's "the three RFC 9136
        rules are still to do" assertion failed the moment one landed,
        which is the guard working.
      * **A bug this found in `test/functional/evpn_test.rb`.** Its
        IPv6 route type 5 case passed a non-zero ESI **and** a non-zero
        gateway, which is exactly what RFC 9136 section 3.2 forbids, so
        the test had been sending a route no RFC allows by accident
        while asserting no protocol error. The ESI is zero there now,
        which changes none of its assertions, and the forbidden
        combination has a case of its own where it is the subject. The
        `crosses` helper takes an expected error count instead of
        asserting zero, which is stronger rather than weaker.
      * `validation.rb` is at 100% line coverage.
      * **What is deliberately left, each with its reason in
        `docs/evpn.md` section 8a**: RFC 9136's other two rules and RFC
        9251 section 9.5's exactly-one-EVI-RT rule, all cross-attribute;
        RFC 9251 section 9.4's M-and-I rule, because its two sentences
        ask for different things and the second is narrower than any
        action RFC 7606 names, so it wants a decision rather than a
        patch; RFC 9136 Table 1's invalid-MAC rule, which is **within**
        the extended communities attribute and so is the best candidate
        for the next piece of work here; and RFC 9251 section 10's
        "IGMPv1 routes are considered invalid", because the section does
        not say whether a route with v1 and v2 both set is one, and
        guessing would be inventing a rule rather than implementing it.
   10. **The lab. Done**, in #192, which finishes the EVPN plan.
       `test/functional/lab/evpn_gobgp_test.rb`, 11 cases and 65
       assertions in about 70 seconds, and `evpn_frr_test.rb`, 9 cases
       and 55 assertions in about a minute. No Docker. Both are picked
       up by `test/run_lab.rb`, which globs the directory, so CI needed
       no change. `docs/evpn.md` section 9 has the measurements.
       * **Probing paid again, and it answered a question this plan had
         guessed at.** Both routers implement **route types 1 to 5 and
         neither knows 6 to 11**: GoBGP logs `Unknown EVPN Route type:
         N` and FRR says nothing at all. So the recorded decision that
         "types 1 to 5 are what a router will actually send" was right,
         and bgp4r having all eleven is the point of a protocol testing
         tool rather than a gap in the routers.
       * **The best result is corroboration of a decision part 9 had to
         make alone.** FRR answers a malformed EVPN NLRI with `3/9
         (UPDATE Message Error/Optional Attribute Error)` and resets,
         which is exactly the subcode and the action `validation.rb`
         reports for the same octets. Part 9 derived both rather than
         copying them: RFC 7432 and RFC 9572 say nothing about error
         handling, RFC 9251 section 9.7 asks for a reset and names no
         subcode, and the 9 came from RFC 7606 section 7.11. GoBGP
         keeps the session up instead, so the two disagree and bgp4r is
         with FRR. One router agreeing is not a quorum, so both are
         recorded as what each does.
       * **GoBGP's "Capability was disabled" overstates what it did.**
         Measured: after an unknown route type, a route type 3 on the
         same session still installs. A test that trusted that line
         would give every case a session of its own for no reason.
       * **FRR prints a constant for route type 5's GW IP Address**,
         `gateway IP 2.0.0.0` for every non-zero gateway sent, and
         nothing when the field is zero. So it tells zero from non-zero
         and renders the wrong member; 2 is AF_INET. A display bug on
         FRR's side, recorded and not filed, per the standing decision
         that the job here is bgp4r catching up. **GoBGP is the only
         check on those four octets**, which is the one place the two
         tests are not twins.
       * **Two harness facts, each measured because each silently voids
         a run.** GoBGP's config file and its client disagree about the
         family name for the second time, `l2vpn-evpn` against `evpn`,
         which is why `FS_CLIENT` in `lab_helper.rb` is `CLIENT_FAMILY`
         now and no longer flow spec's alone. And FRR's EVPN JSON has
         **no `routes` key** and is keyed by Route Distinguisher at the
         top level, where every other family nests under `routes`, so
         `Frr#rib` answers `{}` for this family however many routes are
         in it: a wrong answer rather than a missing one. `Frr#evpn_rib`
         and `#evpn_count` exist for that.
       * **Which JSON keys FRR carries is per route type, not uniform**,
         which is worth knowing before writing another of these: a route
         type 2 path has `ethTag`, `macLen`, `mac`, `ipLen`, `ip` and
         `esi` as separate keys, more than GoBGP's one rendered string
         gives, and a route type 1 path has **none of them**. Found by
         an assertion on `path['ethTag']` answering nil.
       * **Both tests send only, and the sabotage that passed is the one
         to know about.** Reverting `nlri_size` to the pre-wiring prefix
         arithmetic leaves both passing, because that method is on the
         parse path and `test/functional/evpn_test.rb` covers it. The
         flow spec lab tests record the same caveat and it holds here
         for the same reason. What does fail them is an encode-side
         slip: the section 7 Length one short fails 2 GoBGP cases,
         swapping route type 5's GW IP with its prefix fails the gateway
         case, and shifting the MPLS label 3 bits instead of 4 fails
         both label assertions.
       * **Both routers read the 3-octet MPLS Label field whole**, 1601
         for our label 100, so two implementations agree on the `Label`
         reuse down to the bottom bit. Do not "fix" either assertion
         to 100.
       * The doc test's "interoperability is not measured yet"
         assertion failed the moment this landed, the third guard in
         that file to catch its own document going stale this week. It
         now reads the two versions out of the document and out of the
         two tests' own constants and requires them to agree, since a
         pin moved in one place and not the other is how this table
         would go quietly wrong: both tests omit themselves on an
         unmeasured version, so a reader would see the table and no
         failure.

   Decisions taken before this starts:
   * **Route types 6 to 11 are in, and that is a change from the
     earlier entry**, which named five. RFC 9251 and RFC 9572 are both
     uploaded, so the reason for leaving them out is gone. They are
     last because types 1 to 5 are what a router will actually send.
   * **The Flags octet of types 6, 7 and 8 is part of the NLRI and not
     part of the route key.** RFC 9251 section 9.1: "all the fields are
     considered to be part of the prefix in the NLRI, except for the
     1-octet Flags field", and section 9.3 excludes the Reserved and
     Maximum Response Time fields too. That distinction is BGP route key
     processing, which matters to a RIB and not to an encoder, and no
     EVPN route goes in a RIB by the decision below. Recorded so nobody
     implements a route key here looking for it.
4. **The rest, as appetite allows. Done, all four.**
   RT-constrain (SAFI 132, RFC 4684), ATTR_SET (attribute 128, RFC
   6368), MCAST-VPN (SAFI 5, RFC 6514) and BGP-LS (attribute 29, AFI
   16388, SAFI 71 and 72, RFC 9552) are all in, BGP-LS in **all seven
   parts** of the plan below. Part 7 was taken
   out of order on purpose, because what a router does decides which
   checks part 6 is worth writing, and it did: 8.2.2's list turned out
   not to cover the one rule GoBGP breaks, so the document and the
   measurement agree with neither moving. This entry used to
   say "each of
   these is a class and a registration", which held for the first and
   understates the last considerably: BGP-LS is a whole TLV language of
   node, link and prefix descriptors, not one layout. **Measured since:
   139 assigned TLV code points**, a minority of them RFC 9552's, so
   the understatement was by about that much. It understated
   MCAST-VPN too, though less: seven route types across one RFC, three
   more across another, no router here to check them against, and a
   third RFC nobody had noticed updates the first.

   **Those three tests have moved for the last time.**
   `mp_reach_test.rb`'s
   `test_an_unimplemented_safi_still_raises_so_the_octets_survive` and
   the two behind `path_attribute_test.rb`'s `UNDECODABLE` used BGP-LS
   as their example of a family bgp4r cannot decode. BGP-LS was wired in
   at part 4, and it was the last unimplemented family, so there is
   nothing left to point them at: they use **SAFI 255**, which IANA has
   Reserved, so nothing can ever be assigned there and no later part can
   make the example expire. `UNDECODABLE_SAFI` names it and two tests
   assert the range. Every assertion is unchanged across all three
   moves, which is the rule when a test is right and its example is
   not.

   1. **RT-constrain, SAFI 132, RFC 4684. Done**, in #200 and #202: the
      NLRI, then the wiring. bgp4r reads and writes a membership UPDATE
      now, over a real session. The RFC is read, not fetched.
      **Three wiring sites, not four or five**, which is what made this
      the cheapest of the four families: the two dispatch gates and the
      next hop. `nlri_size` needed no arm, for the reason below.
      * **This family needs no new framing rule, which is what makes it
        the cheapest of the four.** Section 4: "The NLRI field in the
        MP_REACH_NLRI and MP_UNREACH_NLRI is a prefix of 0 to 96 bits,
        encoded as defined in Section 4 of [5]", where its [5] is RFC
        2858, which RFC 4760 obsoletes. So `nlri_size`'s `else` branch,
        `(s.getbyte(0) + 7) / 8 + 1`, is already exactly it, where flow
        spec and EVPN each needed an arm. Measured against the three
        cases section 4 describes: 1 octet for the zero-length default,
        5 for a 32-bit prefix and 13 for a 96-bit one. A reader looking
        for an arm will not find one, and `rt_constrain.rb` says why.
      * **The route target inside is partial by design, and that is the
        whole point of the family.** Section 4: "Route targets can then
        be expressed as prefixes, where, for instance, a prefix would
        encompass all route target extended communities assigned by a
        given Global Administrator". A two-octet-AS route target is
        type, sub-type, a 2-octet Global Administrator and a 4-octet
        Local Administrator (RFC 4360 section 3.1), so that prefix is 64
        bits and holds 4 of the community's 8 octets. **So
        `BGP::Route_target` is not reused as a field** the way
        `BGP::Label` is in the EVPN route types: at 64 bits half of it is
        absent and a class that always decoded one would invent the half
        it did not get. `Rt_constrain` holds the length and the octets,
        and answers `origin_as` and `route_target` only where the length
        makes them whole.
      * The hash has two shapes and which one is the only question: at
        exactly 32 or 96 bits the two fields of the figure reproduce the
        octets and the hash is those fields; everything else is the
        length and the octets verbatim. Same rule as `:tail` and
        `:bits`, so an ordinary hash is the two fields alone.
      * **Nothing validates**, per Conventions. Section 4's "the minimum
        prefix length is 32 bits" and its 96-bit maximum are both
        deviated from on purpose, and `test_nothing_validates` puts a
        16-bit and a 200-bit prefix on the wire. **RFC 4684 says nothing
        about malformed NLRIs anywhere in its text**, measured by
        reading it, so what a receiver answers with is not this RFC's to
        give and is not invented; that is the RFC 7432 and RFC 9572
        situation again, not the RFC 8955 one.
      * **Two hand written expectations in the test were wrong and the
        library was right**, which is worth recording because the cause
        is structural: RFC 4684 carries no worked example, where RFC
        8955 and RFC 8956 carry five between them. A route target's own
        octets begin with its type and sub-type, so the widest
        two-octet-AS one is `0002` then six `ff` and not eight; and 16
        bits is two octets, not one. The test file says so, and says
        that it therefore checks the library against this reader's
        arithmetic rather than against the document.
      * **Sabotage found a real gap and an unreachable guard.** Dropping
        the length check from `route_target` passed, because the test
        stepped `(0..95).step(8)` and so skipped 89 to 95 bits, which
        all occupy twelve octets: there the community's octets are all
        present and only the length says its last bits are padding.
        The test walks every length now. Dropping the `@mlen < 32` guard
        from `origin_as` also passed, and that one is genuinely
        unreachable, since `@value` is fitted to the length by both
        `fit_to_mlen` and `parse` and `unpack1('N')` answers nil on
        fewer than 4 octets. It is kept and recorded as unreachable, the
        way `Fib`'s `:no_next_hop` branch is.
      * **The next hop is the one site with no precedent in the
        library**, and it is a length-only rule for a different reason
        than EVPN's. Section 4: the field "shall be interpreted as an
        IPv4 address whenever the length of NextHop address is 4 octets,
        and as a IPv6 address whenever the length of the NextHop address
        is 16 octets." EVPN reads by length because its AFI is 25 and
        **cannot** say which family a next hop is; here the AFI is 1 and
        **could** have said, and the RFC says to use the length anyway.
        So the two share the arm and the comment carries both sentences.
        Do not read the 16-octet half as RFC 8950 reaching the same
        answer: `ipv6_nexthop_length?` answers false for SAFI 132, so
        without this arm a 16-octet field reads as **four** IPv4
        addresses, and nothing claims RFC 8950 applies here.
      * `prefix_klass` was recorded as the thing to look at, since it
        raises for SAFI 132 and this family's value is not an address.
        It needed nothing: its only caller is the `when 1,2` arm of
        `set`, measured rather than assumed, so a SAFI 132 build never
        reaches it.
      * **An Array of field values cannot travel inside `:nlris`, and
        that is `set`'s flatten rather than a decision.** Every arm
        reads `[h[:nlris]].flatten`, which is a **deep** flatten, so
        `[[65000, [65000, 100]]]` arrives as `[65000, 65000, 100]` and
        builds three 32-bit prefixes where one of 96 bits was asked for.
        Found by probing the first draft of the arm, which had an
        `is_a?(Array)` branch that was therefore unreachable. A Hash
        survives flatten untouched, which is why every family here takes
        one. `Rt_constrain.new(65000, [65000, 100])` is still the field
        value form; it just has to be built before it goes in.
      * **The framing is more forgiving here than in the other two
        families, which changes what a test has to cover.**
        `nlri_size` off by one fails only 3 of the functional test's 9
        cases, and they are exactly the three carrying two or more
        NLRIs: the last NLRI in an attribute has nothing behind it to
        over-read into, so a single-prefix case passes against
        arithmetic wrong by a constant. Flow spec and EVPN both failed
        **every** case on the same slip, because their length fields sit
        inside a body the loop re-reads. So the multi-prefix cases are
        the only cover the framing has and must not be thinned out.
      * `test/functional/rt_constrain_test.rb` is the proof and the only
        one there can be, for the reason `flow_spec_test.rb` records. 9
        tests, 87 assertions, under a second. Named in
        `.github/workflows/test.yml`, which lists each functional test
        by hand. Five sabotages, one per site plus the framing; the next
        hop one errors 8 and spares exactly the withdrawal, which
        carries no next hop, the same signature #185 measured for EVPN.
      * **The lab. Done**, in #203, as
        `test/functional/lab/rt_constrain_gobgp_test.rb`: 9 cases, 41
        assertions, 86 seconds, no Docker. **Only GoBGP can carry it**,
        so there is no FRR twin, which makes this the second family
        after VPN flow spec with one reference rather than two.
        * **FRR 8.4.4 has no RT-constrain family at all.** Its `bgpd`
          carries `bgp_nlri_parse_` functions for evpn, flowspec, ip,
          label and vpn and none for this, and its `address-family`
          grammar offers only the two unicast blocks, `ipv4`, `ipv6` and
          `l2vpn evpn`. Its `route-target` strings are the extended
          community and VNI config, not an address family, so do not
          read them as support.
        * **The config and the client agree on `rtc`**, measured, which
          corrects the caution the previous entry here carried. It said
          to expect a `CLIENT_FAMILY` entry because the two sides had
          already disagreed for VPN flow spec and for EVPN. They do not
          disagree here: the client takes `rtc` and refuses `ipv4-rtc`,
          `route-target-constraints`, `rtfilter` and `ipv4-rtfilter`.
          Two precedents are not a pattern, and the entry should have
          said unmeasured rather than expected.
        * **What a second implementation vouches for**: that the 96-bit
          prefix splits 4 and 8 where section 4 says, since GoBGP prints
          the origin AS and the route target as separate fields; that
          the route target inside is a real one, since it renders all
          three RFC 4360 and RFC 5668 forms by their own structure, a
          four-octet AS among them as asdot (`65002:1.4464:5` for AS
          70000); that the zero-length default is read as the default
          and not as a prefix of nothing (`0:default`); and that the
          framing holds across two NLRIs in one attribute.
        * **What it cannot vouch for is our length octet**, and the
          mechanism is worth knowing: **GoBGP reads the prefix as `mlen
          / 8` octets, flooring, where section 4's encoding rounds up.**
          So 96, 97 and 103 bits over the same 12 octets all read back
          as the same route. Proved by sabotage, where writing `@mlen +
          1` left every case in that file passing. The length is covered
          by `test/functional/rt_constrain_test.rb` instead. Flooring
          and rounding up agree on every length section 4 produces, 0,
          32, 64 and 96, so this is reachable only by sending one no RFC
          describes.
        * **GoBGP drops a partial prefix in silence**, 32 bits and 64
          bits alike: session up, nothing logged, nothing installed. The
          64-bit one is section 4's own motivating example, "a prefix
          would encompass all route target extended communities assigned
          by a given Global Administrator", so the family's headline use
          does not work on 3.23.0. Asserted as a divergence.
        * **Two crashes in GoBGP 3.23.0, both found by writing this
          test, both deterministic, and the first is the serious one.**
          Recorded and not filed, per the standing decision that the job
          here is bgp4r catching up.
          * **The zero-length default plus any second membership route
            GoBGP accepts panics it**: a nil pointer dereference in
            `propagateUpdate`, SIGSEGV, daemon down. **Both routes are
            entirely conformant**, so this is not negative testing:
            section 4 blesses the zero-length default in so many words
            and its last paragraph makes it what "a route reflector
            speaking to one of its PE router clients" sends. The trigger
            is a sequence and not a value, which is why it is stated as
            one: the default alone is fine, two 96-bit prefixes are
            fine, and the default followed by a 32-bit prefix is fine
            because that one is dropped before reaching the code. The
            default sent **twice** crashes it, and so does a 96-bit
            prefix followed by the default.
          * **A prefix whose length demands more octets than the NLRI
            holds panics it too**, which is a missing bounds check: 104
            bits floors to 13 where 12 are present. 103 is fine, so the
            boundary is exactly where the floored count passes what
            arrived. This one needs a malformed NLRI, so it is ordinary
            negative testing.
          * Both are asserted rather than avoided, because a lab test
            that quietly skips the sequence that breaks the router is
            the unchecked claim this file keeps getting burned by. If a
            later GoBGP fixes either, that case fails and says to
            re-measure.
   2. **ATTR_SET, attribute 128, RFC 6368. Done**, in one pull request,
      because it is one attribute and not a family: no NLRI, no
      dispatch gate, no framing rule. Section 5: an optional transitive
      attribute whose value is a 4-octet Origin AS then "a
      variable-length field that conforms to the BGP UPDATE message
      path attribute encoding rules". It is a `Path_attribute` inside a
      `Path_attribute`, the attribute-level analogue of EVPN route type
      11's Route Key. `Path_attribute` consuming the String it is
      handed cost nothing in the end, because the nested parse is given
      a slice of our own making.
      * **Two encoding rules that are not free, and both are in
        `Attr_set::INNER`.** The Origin AS is a 32-bit unsigned integer
        "regardless of whether or not the originating PE supports
        4-octet AS numbers", so unlike AGGREGATOR it never follows the
        session. And the AS_PATH and AGGREGATOR inside MUST use 4-octet
        AS numbers "regardless of the capabilities advertised by the
        BGP speaker to which the ATTR_SET attribute is transmitted", so
        `INNER` forces `:as4byte` in **both** directions. The receive
        half is the one with teeth: a 2-octet nested parse reads AS
        4200000001 back as 59905 in silence, which is the same
        truncation `As4_aggregator`'s catalog entry records.
      * `INNER` also carries `:policy => :lenient`, so a malformed
        nested attribute cannot raise out of the decoder and get filed
        as an `Attr::Gap`. Section 5 does make it a malformed ATTR_SET,
        and that is `errors`' business through `validation.rb`.
      * **The three malformed conditions of section 5 are in
        `validation.rb`**: a length under 4 octets, MP_REACH or
        MP_UNREACH carried inside, and an included attribute malformed
        itself. The third **reuses `Attr::Check.attribute`** on each
        nested attribute rather than repeating a rule, so a rule added
        anywhere else reaches inside a set the same day, and it
        recurses for a set inside a set. NEXT_HOP "SHOULD NOT be
        included" and "SHOULD be ignored" when it is, so it is not
        reported: ignoring a field cannot mean refusing the attribute.
      * **The paragraph of section 5 that must not be implemented as
        written is now moot, and RFC 7606 says so itself.** That
        paragraph conditions the handling on "its Partial flag is set
        and its Neighbor-Complete flag is clear" per `[OPT-TRANS-BGP]`,
        which RFC 6368's own reference list gives as Work in Progress,
        September 2010; the draft became RFC 7606, which has no such
        flag. **RFC 7606 section 7.16 replaces the paragraph
        outright**: "An UPDATE message with a malformed ATTR_SET
        attribute SHALL be handled using the approach of 'treat as
        withdraw'", and "the normative reference to [OPT-TRANS-BGP] in
        [RFC6368] is removed". So every finding is TAW and none reads a
        flag. This entry used to say the action had to be derived from
        RFC 7606; it did not, because 7.16 names it. Read the revising
        RFC before deriving anything, which is the lesson RFC 9785
        taught in EVPN part 8b from the other direction.
      * A value too short to hold the Origin AS is kept and echoed, in
        `@tail`, the way `pmsi_tunnel.rb` keeps a value shorter than
        its own fixed part. **That is the one thing sabotage caught as
        untested**: the behaviour was written and no test in the
        class's own file covered it, so deleting the branch passed.
      * **Four hand written length expectations were wrong in this one
        pull request**, every time by putting an attribute's total size
        where its value size belonged or the reverse, and the library
        was right all four times. RFC 6368 carries no worked example
        and no hex, so there is nothing here to check a reading
        against, which is the RFC 4684 situation again. Compute the
        vectors with the library and paste the result; do not type
        them.
      * **The lab. Done**, as
        `test/functional/lab/attr_set_gobgp_test.rb`: 6 cases, 29
        assertions, 50 seconds, no Docker. **Neither router implements
        attribute 128**, measured with `strings` before anything was
        written: gobgpd 3.23.0 carries PMSI_TUNNEL, TUNNEL_ENCAP,
        LARGE_COMMUNITY, AIGP, PREFIX_SID and AGGREGATOR and no
        ATTR_SET, and FRR 8.4.4 has none either. So there is no FRR
        twin, which makes this the third case after VPN flow spec and
        RT-constrain with one reference rather than two.
        * **So the test runs the router in the middle, and that is the
          only lab test here shaped that way.** A router with one peer
          can only say what it made of what we sent. RFC 6368 section 5
          makes the set optional transitive so a customer's attributes
          survive the provider network, and only a router between two
          speakers can say whether they do. `LabHelper::Gobgpd` takes a
          `peer2` for it.
        * Measured: GoBGP accepts it, installs the route, keeps the
          value whole and base64 encodes it in the client's JSON, and
          **propagates it to the far peer byte for byte** with the
          nested 4-octet AGGREGATOR intact.
        * **Be exact about what that corroborates, because it is less
          than it looks.** GoBGP never parses the attributes inside, so
          this does **not** vouch for the meaning of section 5's
          4-octet AS rule; nothing but another ATTR_SET implementation
          could. It vouches for the framing, since a wrong length or
          wrong flags would send the UPDATE to RFC 7606 instead of the
          RIB, and for the transit property itself.
        * **One measurement recorded and not filed: GoBGP propagates
          with the Partial bit clear**, flags 0xc0 rather than 0xe0, on
          an attribute it does not recognize. RFC 4271 section 9 is the
          part that would settle whether that is a divergence, and this
          file records that both fetchable sources truncate the
          document before it, so the test asserts the measurement and
          claims nothing about conformance. If a later GoBGP sets the
          bit, that case fails and says to re-measure.
        * The helper refactor is byte for byte safe for the ten tests
          that share `LabHelper::Gobgpd`: five option sets were diffed
          before and after, and **that check is in
          `test/unit/lab_helper_test.rb`** rather than left as a claim,
          since a claim nothing runs reads as verified.
        * A name collision worth knowing: `Gobgpd#neighbor(address)`
          already existed, reading one neighbor's detail from the
          client, so the config builder is `neighbor_block`. Caught by
          "wrong number of arguments (given 3, expected 1)" and not by
          reading.
        * **Three sabotages, each landing, and the framing claim above
          is the one they were for.** Forcing the nested AS to the
          2-octet form fails 2 of the 6 cases, which is the encode half
          of section 5's rule. Writing the attribute's length one short
          makes the route **never install**, so "a wrong length sends
          the UPDATE to RFC 7606 rather than the RIB" is measured and
          not argued. Building the router with `peer2` nil fails at
          "both sessions came up", which is what says the far speaker
          is real and that the transit assertion is not reading our own
          send.
          * **The first attempt at that third one missed, and how is
            the part to keep.** Appending `if false` to the `G.new(...)`
            call nil'd `router` and the test died on `NoMethodError:
            undefined method 'up' for nil`, two errors and zero
            assertions. It caught nothing about transit: it broke the
            constructor. **A sabotage that errors for a reason
            unrelated to the claim is the same miss as one that
            passes**, which is the Rules for agents rule arriving from
            a third direction. Change the one input the claim rests on,
            here `:peer2 => nil`, and read the failure message to check
            it names the assertion you meant.
          * Run these one test method at a time, `-n
            test_the_set_crosses_the_router_octet_for_octet`. A
            sabotaged full file is 6 cases each sitting out a 30s
            `wait_for`, which overran the foreground limit twice and
            left a patched working tree behind both times. One method
            is about 45s.
   3. **MCAST-VPN, SAFI 5, RFC 6514. Done**, all seven parts, in #208,
      #209, #210, #211, #212, #213 and #214: the framing and the
      primitives, then route types 1, 2 and 5, then 3, 6 and 7, then 4,
      then the wiring, then validation, then the lab. **Every layout of
      section 4 is in, an MCAST-VPN UPDATE crosses a session, a
      malformed one is reported on receive, and the absence this
      family's whole scope rests on is asserted rather than written
      down.** What the lab does not give is agreement about our octets,
      because neither router has the family; part 7 says so in as many
      words.
      **The RFC is readable now**, which corrects the note
      this entry used to carry: it was fetched in full on 2026-10-31,
      along with draft-ietf-bess-rfc6514bis-00, which obsoletes it, and
      RFC 7441, which updates it. EVPN part 7's note that the only first
      hand reading here came through the bis draft applied to RFC 6514
      section 4.3 and no longer applies.
      * **Two RFCs update RFC 6514, not one, and the second was found
        four parts late.** RFC 7441 was found before any code was
        written; **RFC 6515** was found at the wiring part, after four
        parts had shipped against RFC 6514 and the bis draft alone. It
        settles the next hop, confirms route type 4's split, supplies
        the Originating Router's width, states one octet count, and
        gives the family its only receive side rule. Part 5's entry has
        all of it, and the corrections it forces are marked in parts 2
        and 4. The lesson is in part 5 too: applying the
        read-the-updating-RFCs rule once per family is not applying it.
      * **The registry has ten route types and RFC 6514 defines seven.**
        IANA's "BGP MCAST-VPN Route Types" registry, read on 2026-10-31:
        0x01 Intra-AS I-PMSI A-D, 0x02 Inter-AS I-PMSI A-D, 0x03 S-PMSI
        A-D, 0x04 Leaf A-D, 0x05 Source Active A-D, 0x06 Shared Tree
        Join and 0x07 Source Tree Join from RFC 6514 section 4, then
        0x43, 0x44 and 0x47 from **RFC 7441**, the mLDP forms of 0x03,
        0x04 and 0x07. 0x00 and 0x80 to 0xff are Reserved.
        * **RFC 7441's header says `Updates: 6514` in so many words**,
          so EVPN part 8b's rule found this one before it cost anything:
          read every RFC that lists itself as updating the one you are
          implementing. That rule was written after RFC 9785 was missed
          by it; this is the first time it has paid.
        * The relationship is stated rather than arithmetic. RFC 7441:
          the new types' "high-order two bits have the value 0x01, and
          (b) the low-order six bits have the same value as the
          codepoints for the corresponding route types". So 0x40 to 0x7f
          is the mLDP range and `base + 0x40` is the result, not the
          rule.
      * **The three mLDP types are deliberately out of scope**, and the
        reason is that they are not BGP. Each carries an mLDP FEC
        Element, which RFC 7441 does not lay out at all: it points at
        "the FEC Element diagram in Section 2.2 of RFC 6388", so the
        extent of that field belongs to LDP and bgp4r has nothing of
        LDP. They read back as `Mcast_vpn::Unknown` and replay byte for
        byte, which is what #116 already gives one level up. Revisit
        only if someone wants mLDP, and then it is an RFC 6388 reader
        first and three route types second.
      * **The framing is the EVPN shape exactly**, which is why that
        experience transfers whole. RFC 6514 section 4: a Route Type
        octet, a Length octet, and a Route Type specific field, where
        "The Length field indicates the length in octets of the Route
        Type specific field of the MCAST-VPN NLRI". So
        `Mcast_vpn.nlri_size` is `Evpn.nlri_size` again, read by the
        same `MpReachCommon::ClassMethods#nlri_size`, and the two
        dispatch gates take one more arm each. **Not a registry**, for
        the reason phase 1 records.
      * **Two AFIs, where EVPN has one.** Section 4: "with an Address
        Family Identifier (AFI) of 1 or 2 and a Subsequent AFI (SAFI) of
        MCAST-VPN". The parse needs no AFI input, because the source and
        group are length prefixed and say their own width, so
        `Nlri.factory` passes none down. **"Nothing inside the NLRI
        reads differently per family" was how this read and it is too
        strong**: RFC 6515 section 1.1 says the AFI decides whether the
        customer multicast addresses are IPv4 or IPv6, so it does decide
        something; it is just redundant with a field already in the
        octets, and preferring the in-band one is the house rule. Where
        the AFI must not be used at all is the next hop, which part 5
        measured and RFC 6515 settles.
      * **Section 4 gives no SAFI number**, and neither does the bis
        draft: both say "a SAFI of MCAST-VPN" and leave it to IANA. The
        registry says 5, and `IANA::SAFI::MCAST_VPN` is already 5 with
        `iana.rb` already printing 'Multicast VPN', so that is one site
        this family needs nothing at.
      * **The Leaf A-D route's split was the design problem of the
        family, and RFC 6515 settled it.** Route type 4's body is a
        Route Key of no stated length followed by an Originating
        Router's IP Address of no stated length. Section 4.4 says only
        that "the Route Key of the Leaf A-D route is set to the NLRI of
        the received route", and **the bis draft does not close it
        either**, which was checked rather than assumed.
        * The readable reading is that the Route Key is a whole nested
          NLRI, Route Type and Length octets included, which makes it
          self delimiting and leaves the address as what is behind it.
          That is the same shape as EVPN route type 11, and **RFC 9572
          needed its own terminology section to say "entire NLRI"**
          before it was more than a reading. RFC 6514 has no such
          sentence.
        * **RFC 6515 section 2 item 4 is that sentence for this family:
          "The Route Key has its own length field."** So the split is in
          the band after all. Part 4 took the reading and said in the
          code that it was a reading, per Rules for agents; part 5 found
          the document and the reading was right, so the comment is a
          citation now and no code moved. **Two things this bullet has
          been wrong about are worth keeping**: it said the replay check
          is what keeps the reading from being an assertion, which part
          4 disproved, and it said the documents do not settle the
          split, which part 5 disproved. Both corrections are in those
          parts' own entries.
      * **The Originating Router's IP Address has no length field in any
        of the three types that carry it**, 1, 3 and 4. Its width is
        what is left of the body, which the Length bounds, and its
        family comes from its own size, 4 or 16. That is
        `Ip_prefix_route`'s rule and route type 2's Label2 rule, both
        already in the EVPN work. **This entry said no document states
        or derives the width, which was true of the two that had been
        read**: RFC 6514 and the bis draft give only section 8's "MUST
        be of the same address family as the 'Originating Router's IP
        Address'", which implies a family and no width. RFC 6515 section
        2 items 2 to 4 give the derivation, one per route type that
        carries the field, and it is this one. So the rule was right and
        is cited now rather than derived.
      * **No worked example and no hex anywhere in RFC 6514**, the RFC
        4684 and RFC 6368 situation rather than the flow spec one. Those
        two cost four wrong hand written length expectations in #204 and
        two in #200, every one of them the library being right. So
        compute the vectors with the library and paste the result, and
        say in the test file that it therefore checks the library
        against this reader's arithmetic and not against the document.
      * **There is almost no NLRI error handling text, and "none" was
        what this entry said.** "Malformed" appears in RFC 6514 and the
        bis draft only for the PMSI Tunnel attribute and the PE
        Distinguisher Labels attribute, and neither references RFC 7606
        for an NLRI, so that much holds. **RFC 6515 section 2 states one
        rule four times**, once per place a provider address appears: an
        address length that "is neither 4 nor 16" makes the
        MP_REACH_NLRI "incorrect", handled per section 7 of RFC 4760. So
        part 6 is four checks and not the decision this plan expected,
        and not the one check part 5 reported either: **this bullet said
        one until part 6 read section 2 properly**. The subcode and the
        action came out of RFC 7606 section 7.11, which updates RFC 4760
        and states 6515's sentence generally, so nothing was derived;
        part 6's entry has it. Everything else about
        a bad MCAST-VPN NLRI is still not these RFCs' to give, which is
        the RFC 7432, RFC 9572 and RFC 4684 situation and not RFC
        8955's.
      * **Neither lab router has SAFI 5, so this is the first family
        with no outside reference at all.** Measured with `strings`
        before any of this was written, the way ATTR_SET's absence was.
        GoBGP 3.23.0's family list is `ipv4-multicast` (SAFI 2),
        `l3vpn-ipv4-multicast` and `l3vpn-ipv6-multicast` (SAFI 129),
        `l2vpn-vpls`, `l2vpn-evpn` and the unicast, labelled and flow
        spec entries, with nothing for MCAST-VPN; FRR 8.4.4 has five
        `bgp_nlri_parse_` functions, for evpn, flowspec, ip, label and
        vpn, and none for this.
        * **The ATTR_SET trick does not transfer**, and it is worth
          saying why before someone tries it. A router carries an
          optional transitive **attribute** it has never heard of,
          which is what made a gobgpd in the middle worth building. An
          NLRI in a family the router did not negotiate does not cross
          anything, so there is nothing in the middle to measure.
        * So the wire format of this family will be bgp4r's own opinion
          checked only against the field widths the two documents state,
          which is weaker than every family since flow spec. **Say so
          in `docs/mcast-vpn.md` rather than leaving it implied**, and
          do not read the loopback functional test in part 5 as
          interoperability: it proves the wiring sites agree with each
          other, which is all it has ever proved.
      * **The primitives are this family's own and not EVPN's**, which
        is a decision with a cost and so is recorded with its mechanism.
        The Multicast Source and Multicast Group are a length in bits
        with that many bits of value, which is `Evpn::Addr` exactly, and
        the sharing is by citation rather than coincidence: EVPN route
        type 10 is "identical to the S-PMSI A-D route as defined in
        [RFC7117]", which carries this encoding. Against that is #173's
        argument: sharing removes no code today and bets on a third
        family. **Revisit when a third family needs them**, and until
        then an `Mcast_vpn::Addr` whose comment cites RFC 6514's own
        sentence is the smaller mistake.
        * **This entry overstated the cost of sharing, and #208
          corrected it.** It said sharing means lifting `Sized`, `Addr`,
          `Route` and `Unknown` out of `class Evpn`, a refactor across a
          2426 line file, its test file and `evpn_doc_test.rb`, which
          discovers `Evpn.constants`. There is a cheaper shape: a module
          holding only `coerce`, `coerce_or_default`, `read_rd` and
          `addr_hash`, included by both `Route` bases. It is additive, it
          leaves `Evpn.constants` alone and it leaves every subclass
          working. The decision did not change, because that is still a
          second topic in one pull request, but the reason for it is
          weaker than this entry claimed and a reader should know which.
      1. **Primitives and the framing, pure. Done**, in #208. The Route
         Type plus Length framing with `Mcast_vpn.nlri_size`, an
         `Mcast_vpn::Unknown` that keeps the remainder and replays it,
         and the three fields the layouts share: `Addr` for the
         Multicast Source and Multicast Group, the 4-octet `Source_as`,
         and `Originating_router`, the trailing address with no length
         of its own. Nothing dispatches to it, the way #181 landed
         EVPN's primitives and #156 the FIB planner. `docs/mcast-vpn.md`
         is the guide and `test/unit/mcast_vpn_doc_test.rb` asserts its
         load bearing claims, with the route type table **discovered**
         rather than listed.
         * **Four of the doc test's guards are aimed at this family
           being half built**, which is the lesson `docs/evpn.md` taught
           three times in one week. A claim that is true only today is
           asserted as true only today: when a route type arrives, when
           the dispatch gates learn SAFI 5, when a receive side check
           appears, and when the prose saying no route type exists stops
           being true, the matching assertion fails and its message
           names which section to rewrite. `validation.rb` is read as
           **text** for one of those, so the guard needs no MCAST-VPN
           code to exist in order to watch for it.
         * **Seven sabotages, six landing and one passing, and the one
           that passed is the useful one.** `octets_for(bitlen)`
           returning `bitlen` unrounded passed every test in the first
           version of the file. The reason is structural rather than
           careless: the only parse of an `Addr` there was of octets
           that ran out anyway, where `[octets_for(200), 2].min` is 2
           either way, so nothing measured where the field **ends**. In
           route types 3, 5, 6 and 7 an `Addr` is followed by another
           field, so that is the whole job of the rounding. Two tests
           now parse an `Addr` with something behind it, one on an octet
           boundary and one at 20 bits, and the sabotage fails both.
           Check the proof proved something, from Rules for agents,
           arriving from the same direction as the ESI bug in #181.
         * **A test-local `Probe` subclass is what covers the `Route`
           base's four private helpers**, since no real route type calls
           them yet. It lives under the test class, so
           `Mcast_vpn.constants` never sees it and the doc test's
           discovery cannot count it, it is in no `ROUTES` entry, and
           its `TYPE` is 0, which IANA reserves. That took
           `mcast_vpn_route.rb` to 100% line coverage.
         * **The one uncovered piece is `read_route`'s body**, three
           lines, unreachable while `ROUTES` is empty because the guard
           above it answers nil for every type. Said in a comment there
           rather than left for a coverage report to raise as a
           question; part 2 is where those lines first run.
      2. **Route types 1, 2 and 5. Done**, in #209, which are the three
         whose bodies split with no guess. Type 2 is fixed at 12 octets,
         RD and Source AS. Type 5 is RD, source and group, 18 octets or
         42. Type 1 is RD and the trailing address, 12 or 24, so it is
         the first to need the what-is-left rule and was the smallest
         place to get it right.
         * **None of those six octet counts is in either document.**
           Section 4 gives a Length field and no subsection gives a
           total, so each is this reader's arithmetic from the figure,
           computed with the library and pasted per the rule #200 and
           #204 earned. `docs/mcast-vpn.md` section 3 has them in a
           table the doc test measures against the classes, so the
           document cannot drift from what they encode.
           * **Two of the six are in a document after all**, found with
             RFC 6515 at part 5: section 2 item 2 gives route type 1's
             NLRI length as "either 12 or 24, respectively", and both
             agree with what the class encodes. The sentence above was
             true of the two documents that had been read. A doc test
             guard holds the pair against the classes now, so these two
             are the document's and the other four are still
             arithmetic.
         * **Route type 1 with an IPv4 address and route type 2 are
           both 12 octets**, exactly, so nothing in either body tells
           them apart and the Route Type octet is the only
           discriminator. Not a problem the framing has to solve, since
           the type is read first, but a reader comparing lengths across
           this family would otherwise meet it by surprise. Asserted
           rather than noted.
         * **Section 4.2 carries the one sentence in section 4 that
           constrains a field's value rather than its width**:
           "Two-octet ASNs are encoded in the two low-order octets of
           the Source AS field, with the two high-order octets set to
           zero." `Source_as` writes a 32-bit unsigned integer, so it
           holds by construction and needed no code; a test asserts it
           anyway, because a rule that holds by accident of
           implementation is one a later change can break in silence.
         * **Two receive-side rules were found in section 4.5 and
           neither is a `validation.rb` rule**, which is a correction to
           part 1's reading rather than a discovery: section 8 of the
           guide said there was no error handling text, and that is
           still true, but it read as though there were no receive-side
           rules at all. There are two, and the guide now says why each
           is out: "Use of the Source Active A-D routes with the
           Multicast Source Length field of 0 is outside the scope of
           this document", which is the third such sentence in this
           family; and a group in the SSM range "MUST NOT be advertised
           by a router and MUST be discarded if received", which needs
           the group's **value** against a range RFC 6514 does not
           number, deferring to RFC 4607 and letting a router extend it
           locally, and where "discarded" is not one of the actions RFC
           7606 names. That is route feasibility rather than encoding,
           the RFC 9117 situation `docs/flow-spec.md` records. Part 6
           has it in writing rather than having to rediscover it.
         * **Three tests had examples that expired and all three were
           re-pointed rather than weakened**, which is the third time
           this week after #185 and #191. `mcast_vpn_test.rb`'s
           "every route type reads back as Unknown" was true only while
           `ROUTES` was empty, so it now says that of the types that
           still have no class; its hash-shape and `to_s` assertions
           moved to route type 3, which has none. And the doc test's
           "no route type is implemented" guard fired the moment these
           landed, which is the guard working: it is two-sided now, so
           the sentence must be gone while any type is in and must come
           back if ever none is.
         * **Six sabotages, all landing**, and the two layout ones are
           the informative pair: swapping the RD and the trailing
           address in route type 1 fails 4 in the class file and 3 in
           the NLRI file, and reading `Source_as` as two octets fails 2
           and 1. Removing the encode-matches rule from `read_route`
           fails 2 and errors 4, dropping a type from `ROUTES` fails the
           half-wiring guard and two NLRI cases, swapping route type 5's
           source and group fails 2, and making one octet count in the
           document wrong fails the table guard.
         * Both files are at 100% line coverage. The one gap part 1
           recorded, `read_route`'s body, is closed: it runs for the
           first time here.
      3. **Route types 3, 6 and 7. Done**, in #210, which leaves route
         type 4 the only layout outstanding. Type 3 is type 5 with the
         trailing address behind it, 22 octets all IPv4 and 58 all
         IPv6. Types 6 and 7 share one layout, RD, Source AS, source
         and group, 22 or 46.
         * **Two modules came out of it, and both are modules rather
           than base classes for the doc test's sake**, which is EVPN
           part 6's lesson taken up front: `evpn_doc_test.rb` and its
           twin here discover the route type table from the `Route`
           subclasses the library defines, so an abstract
           `Multicast < Route` would read as a route type with no row.
           `Source_and_group` is the Multicast Source and Multicast
           Group pair, which **four of the seven layouts carry**, types
           3, 5, 6 and 7, so route type 5 was refactored onto it in the
           same change. `C_multicast` is the whole of section 4.6.
         * **Section 4.6 defines two route types with one layout, so
           `Shared_tree_join` and `Source_tree_join` are identity and
           nothing else**: a `TYPE`, a `HASH_KEY` and a `NAME` the
           shared `to_s` reads off the class. That is the honest
           statement of what the section says, in one sentence: "A
           Shared Tree Join route and a Source Tree Join Route Type
           specific MCAST-VPN NLRI consists of the following". A test
           asserts the two encode identically.
         * **The second length collision in this family**: route type 3
           with IPv4 addresses and the section 4.6 layout with IPv4
           addresses are both 22 octets, after route type 1 against
           route type 2 at 12. Harmless for the same reason, since the
           Route Type octet is read before the body, and asserted so a
           reader comparing lengths does not meet it by surprise.
         * **Route type 3 is the first layout with a variable field
           after a variable field.** The two lengths are read first and
           each takes what it claims, so the trailing address gets what
           is left and needs no arithmetic. The cost is that a length
           claiming more than the body holds eats the fields behind it
           and leaves the address empty, which is ordinary negative
           testing: the route then cannot reproduce its own body and
           `read_route` keeps the octets as an `Unknown`.
         * **The expiring-example count is now three in one family**, so
           the fix went further than re-pointing. `mcast_vpn_test.rb`'s
           three Unknown cases used route type 3, which part 2 chose and
           this part made wrong, and route type 4 would have been the
           obvious replacement and expires in part 4. They use `0x43`
           now, through a named `NO_CLASS` constant: it is **assigned**,
           as the mLDP form of route type 3, and out of scope by
           decision rather than by backlog, so it cannot expire again.
           Pick an example that cannot expire rather than re-pointing a
           third time.
         * **Seven sabotages, six landing and one missing for a reason
           worth recording.** The six: route type 3's address written
           before the pair fails 4, 1 and 1 across the three files; the
           Source AS written after the pair in 6 and 7 fails 3 and 1;
           the source and group swapped inside the shared module fails
           5; route type 7 given route type 6's `TYPE` fails 3 and 3;
           a type dropped from `ROUTES` fails the half-wiring guard and
           two NLRI cases; and one octet count in the document made
           wrong fails the table guard.
           * **The miss: making `Source_and_group` a Class instead of a
             module died at load with `wrong argument type Class
             (expected Module)`**, so it tested nothing about the
             discovery guard it was aimed at. That is #205's `if false`
             failure again: a sabotage that breaks something unrelated
             to the claim is the same miss as one that passes. The
             claim is that an abstract base class would read as a route
             type, so the sabotage that tests it is **adding** one:
             `class Multicast < Route` with no `TYPE` errors both
             discovery guards with `NameError: uninitialized constant
             BGP::Mcast_vpn::Multicast::TYPE`, naming the constant.
      4. **Route type 4, the Leaf A-D route. Done**, in #211, so **every
         layout of RFC 6514 section 4 is in**. Last because RFC 6514 and
         the bis draft do not settle it: a Route Key of no stated length
         followed by an Originating Router's IP Address of no stated
         length, so where one ends is not readable from those two
         documents. `Leaf_a_d` takes the readable reading, that the
         Route Key is a whole nested NLRI whose extent comes from its
         own Length octet.
         * **RFC 6515 settles it and the reading was right**, found at
           part 5 and recorded there in full. Section 2 item 4: "The
           Route Key has its own length field", and "From the NLRI
           length and the route key length, one can compute the length"
           of the address behind it. So this is a citation now rather
           than a reading, and **the code did not change**, because the
           nested read already took its extent from that octet. What
           follows is corrected below where it says "a reading"; what
           does not change is everything about the replay check, since
           a settled split still is not what the check verifies.
         * **This entry's own middle clause was wrong and that is the
           finding of the part.** It read "the replay check that stops it
           being an assertion", and the replay check does no such thing.
           The split is read from the nested Length octet, which is one
           of the body's own octets, so the fields always reproduce the
           body and `read_route`'s check is satisfied **by
           construction**. What it catches is a body too short to frame a
           Route Key at all, and a nested Length that overruns the body.
           Neither is the thing that matters.
           * **An earlier draft of the class comment went further and
             was flatly wrong**, saying the body could be split anywhere
             and still replay. It cannot: two field pairs of one total
             size encode to different octets, because the Length that
             decides the split is one of them. `0101ff` plus a 4-octet
             address is `0101ff0a000001`; `0104ff0a0000` plus a 1-octet
             remainder is `0104ff0a000001`. Same length, second octet
             different. So the reading is at least self consistent.
           * **The sharper fact, found by sabotage: a reader using
             another split replays too.** Reading the Route Key two
             octets short leaves a route type 3 that is still a route
             type 3, with a shorter Originating Router inside it, and the
             outer body comes back byte for byte, because the nested
             Length that lied is echoed. So neither the replay check nor
             an assertion on the **class** catches a mis-split. Only an
             assertion on the field values does, which is what
             `test_the_split_is_pinned_by_the_field_values_and_nothing_else`
             is for, and it is the only guard on the split there can be.
             Without it that sabotage failed one unrelated test.
         * **A sender using another rule is undetectable**, which is the
           same point from the other end: if the authors meant the Route
           Type specific part alone with a fixed width address behind it,
           their octets read into different fields here and nothing on
           the wire shows it. The one signal available is the remainder's
           width, since `originator.address` answers nil when what is
           left is neither 4 nor 16 octets. bgp4r does **not** pick the
           split by it: choosing by it would be inventing a rule where
           the documents have none.
         * **`Leaf_a_d` reaches `Mcast_vpn` at call time and not at load
           time**, which is what lets a route type in
           `mcast_vpn_route.rb` hold an NLRI from `mcast_vpn.rb`. So it
           is the one class there that does not work against that file
           alone, and **its tests live in
           `test/unit/nlris/mcast_vpn_test.rb`** beside the framing they
           exercise. `Evpn::Leaf_a_d` records the same thing for the same
           reason. The doc test asserts the placement rather than the
           claim, by reading `mcast_vpn_route_test.rb` for a require of
           the NLRI and for the class name: a test of it in that file
           would make the other six route types' independence vacuous.
           Sabotaged by adding one, which fails the doc guard and errors
           that file on its own.
         * **The recursion cost nothing, as part 1 predicted**, and it is
           the second instance of the shape after EVPN route type 11. A
           Leaf A-D route inside a Leaf A-D route builds and replays,
           which no RFC describes and nothing validates.
         * **The expiring-example count reached four in this family** and
           the fix was not another re-point. `mcast_vpn_test.rb`'s
           Unknown cases had already moved off route type 1 in #209 and
           off route type 3 in #210, where the list was `[4, NO_CLASS]`;
           route type 4 landing made the 4 wrong. `NO_CLASS`, which is
           0x43, is assigned and out of scope by **decision** rather than
           by backlog, so it cannot expire, and the list should have been
           `NO_CLASS` alone from the start.
         * Seven sabotages, all landing: the two fields written in the
           other order fails 5 and errors 1 in the NLRI file plus 1 doc
           guard; the Route Key read two octets short fails the field
           value test and `test_nothing_validates_about_a_route_key`; the
           overrun guard removed fails 1; the too-short-to-frame guard
           removed fails 1; route type 4 dropped from `ROUTES` fails 2
           and errors 1 plus the half-wiring guard; the document's table
           row flipped to no fails the discovery guard; and a `Leaf_a_d`
           test added to `mcast_vpn_route_test.rb` fails the placement
           guard and errors that file standalone.
         * Both files are at 100% line coverage. The last uncovered line
           was `Leaf_a_d`'s refusal of a third argument, which the layout
           has no field for, and that is the kind Conventions allows: an
           input the class cannot represent, not a combination the RFC
           forbids.
      5. **Wiring to the dispatch sites, plus a loopback functional
         test. Done**, in #212. bgp4r reads and writes an MCAST-VPN
         UPDATE now, over a real session. Four sites, the EVPN count:
         the framing in `nlri_size`, the two dispatch gates, and the
         next hop.
         * **The next hop question is answered by a document this plan
           had missed, and it answers more than the next hop.** RFC
           6515, "IPv4 and IPv6 Infrastructure Addresses in BGP Updates
           for Multicast VPN", February 2012, header `Updates: 6514`,
           four pages. It exists because an MVPN route carries both
           customer and provider addresses and only the customer ones
           have an AFI field to describe them.
           * **Section 1.1: the PE address family "MUST NOT be inferred
             from the AFI field."** Section 2 item 1, on the next hop:
             "it is always clear whether the address is an IPv4 address
             (length is 4) or an IPv6 address (length is 16)." So SAFI
             5 joins the length-only arm EVPN and RT-constrain share,
             and with the strongest of the three citations: RFC 7432
             section 14 and RFC 4684 section 4 each say to read the
             length, where this one forbids using the AFI.
           * **No `Ipv4_mapped` branch, by citation rather than
             analogy.** Section 1.1 names RFC 4659 and RFC 4798, which
             did require an IPv4 PE address to be written as a mapped
             address in a route carrying IPv6 customer addresses, and
             says of that: "This document does not use that approach."
             So an MCAST-VPN next hop under AFI 2 is a plain 4-octet
             IPv4 address, which the functional test asserts by reading
             the length octet.
           * **It settles route type 4's split**, which part 4 recorded
             as something the documents do not settle. Section 2 item
             4: "The Route Key has its own length field", and "From the
             NLRI length and the route key length, one can compute the
             length" of the address behind it. So bgp4r's reading was
             right and is a citation now. **The code did not change**:
             the nested read already took its extent from that octet.
             Part 4's entry above is corrected rather than left
             standing.
           * **It states the one octet count any document in this
             family gives**, section 2 item 2: the Intra-AS I-PMSI
             route's NLRI length "will be either 12 or 24,
             respectively". Part 2 recorded that none of its six counts
             was in any document; two of them are, and both agree with
             what the classes encode. A doc test guard holds them.
           * **It gives the family its one receive side rule**, which
             part 6 inherits: a length that is neither 4 nor 16 makes
             the MP_REACH_NLRI "incorrect", handled per section 7 of
             RFC 4760. So `docs/mcast-vpn.md` section 8 no longer says
             there is no error handling text. Note before starting part
             6 that RFC 6515 names no subcode and RFC 4760 section 7
             predates RFC 7606, so what "incorrect" means now is a
             question to answer rather than assume.
           * **How it was missed is the part worth keeping, because the
             rule that would have caught it was already written down.**
             EVPN part 8b earned it after RFC 9785: read every RFC that
             lists itself as updating the one you are implementing. RFC
             7441 was found that way before any MCAST-VPN code was
             written, and this file credits that as the rule's first
             payoff. RFC 6515 was not found, because the search that
             found RFC 7441 was about route types and nothing was
             searched again when the question became addresses. **So
             applying the rule once per family is not applying it**:
             read the updating RFCs for their own sake, as a list,
             before the parts start.
         * **The AFI is defaulted and not inferred, and that is this
           family's own case.** Flow spec answers from its components'
           keys, EVPN and RT-constrain have one value fixed by their
           RFC, and here section 4 allows 1 or 2 with nothing in the
           NLRI to read it off. RFC 6515 section 1.1 says what the
           choice decides: AFI 1 means the customer multicast addresses
           are IPv4 and AFI 2 means IPv6. Those fields carry their own
           length in bits, so the parse never needs it and
           `Nlri.factory` passes no AFI down; a **sender** still has to
           pick one, so the arm defaults to 1 and a caller sending IPv6
           customer addresses passes `:afi => 2`. Said as a default
           rather than dressed as an inference.
           * That also corrects `docs/mcast-vpn.md`, which said nothing
             inside the NLRI reads differently per family. The AFI does
             decide what those addresses are; it is just redundant with
             a field already in the octets, and preferring the in-band
             one is the house rule, as EVPN route type 2's IP Address
             Length is preferred over the NLRI's own Length.
         * `test/functional/mcast_vpn_test.rb` is the proof and the
           only one there can be, for the reason `flow_spec_test.rb`
           records. 12 tests, 116 assertions, under a second. Named in
           `.github/workflows/test.yml`, which lists each functional
           test by hand. It carries the only case in this family that
           puts an NLRI inside an NLRI over a socket.
         * **Seven sabotages, all landing, and the signature is the one
           the last two families measured.** The parse gate's arm
           deleted fails all 12; the build gate's arm made unreachable
           errors all 12; not skipping the AFI inference errors 11; and
           reverting only `Mp_unreach`'s own loop fails **exactly 1**,
           the withdrawal, which is what says the two parse loops are
           independent copies and that one test is all that covers the
           second. Both next hop sites spare exactly the withdrawal
           too, 11 of 12, which carries no next hop: the same signature
           #185 measured for EVPN.
           * **The framing slip spares one case and it is worth knowing
             which.** `nlri_size` reverted to the prefix arithmetic
             fails 11 of 12, and the survivor is the single-NLRI mLDP
             case, where the wrong arithmetic overshoots past the end of
             the attribute and there is nothing behind it to over-read
             into. That is RT-constrain's lesson arriving in a family
             whose Length does sit inside a body the loop re-reads, so
             the multi-NLRI cases stay.
         * **Three more hand written expectations were wrong and the
           library was right all three times**, which is the RFC 6514
           pattern again: no worked example anywhere, so there is
           nothing to check a reading against. Two were API shape,
           `Rd#to_s(false)` keeping its `RD=` prefix and `Source_as`
           having `value` rather than `to_i`. The third was a claim
           about behaviour and is the instructive one: an NLRI Length
           that disagrees with its body does **not** make the route read
           back as an `Unknown`. `read_route`'s rule is that a route
           type must reproduce **its body**, and a Length that lies sits
           outside the body, so a good route type 1 in a 12-octet body
           stays a route type 1 while `declared_len` echoes the Length
           that lied. Only a body a type cannot reproduce falls back.
         * A load order trap caught in passing, the Conventions one:
           the doc test's new guards reach `Mp_reach`, which that file
           did not require, so it passed in the suite and errored on its
           own. Run a file you changed both ways.
      6. **Validation. Done**, in #213, in `validation.rb` and nowhere
         else per Conventions. **Four checks, not the nothing this plan
         expected and not the one part 5 found**, and all four are RFC
         6515 section 2's, one per item. `docs/mcast-vpn.md` section 8
         is the guide and has them in a table the doc test reads.
         * **The count went 0, then 1, then 4 across three parts, and
           that history is the lesson.** Part 1 recorded "there is no
           error handling text", measured by reading RFC 6514 and the
           bis draft. Part 5 found RFC 6515 and corrected it to one
           rule, the next hop. Part 6 read section 2 properly: it names
           **four** places a provider address appears in an MCAST-VPN
           route and repeats the same sentence for each, so there are
           four checks. An absence recorded as measured is the claim
           that stops the next reader looking, and it did that twice.
         * **The subcode and the action are RFC 7606's, not derived, and
           that was part 5's open question.** Part 5 left it as: RFC
           6515 points at RFC 4760 section 7, names no subcode, and RFC
           4760 predates RFC 7606, so what "incorrect" means now has to
           be answered rather than assumed. The answer is that **the
           rule bgp4r already had is this rule**. RFC 7606's header says
           `Updates: 4760`, and section 7.11 states it generally: "If
           the Length of Next Hop Network Address field of the MP_REACH
           attribute is inconsistent with that which was expected, the
           attribute is considered malformed", and because "the next hop
           precedes the NLRI field in the attribute" the NLRI cannot be
           located, so "the 'session reset' or 'AFI/SAFI disable'
           approach MUST be used". So subcode 9 with a reset, which is
           what the two MP_REACH findings already answer.
           * **7.11 leaves the expectation to the family and gives the
             worked example in RFC 6515's own words**: "'That which was
             expected' ... is potentially modified by any extensions in
             use. For example, if [RFC5549] is in use, then the next hop
             would have to have a length of 4 or 16." So this is 7.11's
             clause with one family's expectation filled in rather than
             a new rule. **Inventing a subcode was the trap**, the one
             flow spec part 4 and EVPN part 9 each recorded, and the way
             out was reading the RFC that updates the one being pointed
             at. That is the same rule that found RFC 6515 one part
             earlier, applied one level further down the chain.
         * **Only this family's next hop length is checked, and the
           reason is which RFC names the error.** Three families share
           the length-only next hop arm in `mp_reach.rb`. RFC 7432
           section 14 says an EVPN next hop "MUST be set to the IPv4 or
           IPv6 address of the advertising PE", binding a sender and
           naming no receiver action; RFC 4684 section 4 tells a reader
           how to read the field and says nothing about other lengths;
           RFC 6515 states the error and the handling. Extending the
           check to the other two is deriving from 7.11 alone, which is
           legitimate and is a **decision rather than an
           implementation**, so it is recorded in the guide as the
           obvious next piece of work with the citations in hand.
         * **All four checks are MP_REACH only, and that is the
           document's choice rather than a reading of the route key.**
           Every one of section 2's items names the MP_REACH_NLRI
           attribute and none mentions MP_UNREACH_NLRI, measured by
           reading them. EVPN's two reach-only rules had to be derived
           from what its RFCs call the route key; this is simply what
           RFC 6515 says. The framing findings run on both, because
           octets that cannot be split are not a question about which
           attribute holds them.
         * **The row count guard counts something other than
           `Finding.new`, and the difference is the library's shape.**
           `evpn_doc_test.rb` counts findings because each EVPN check has
           its own. RFC 6515 states one sentence four times, so
           `originator_finding` is one `Finding.new` reached by three
           route types: counting findings gives 2 where the table has 4
           rows. What matches the rows is the next hop check plus the
           arms of `mcast_vpn_route_finding`'s case, and those are as
           discoverable from the library as a finding is, each naming its
           route type through the class.
         * **The four methods sit after `nonzero?` rather than beside
           the EVPN checks, and the guard is why.**
           `evpn_doc_test.rb`'s row count slices validation.rb from `def
           evpn_finding` to `def nonzero?`, so code written in that
           window counts as an EVPN check. Writing them there is what
           happened first and the guard caught it, which is a discovered
           count working in a direction nobody designed it for.
           `nonzero?` is EVPN's own helper and nothing else calls it, so
           that window is exactly the EVPN block and is worth leaving
           exact. Said in a comment there.
         * **One expired example, re-pointed and made stronger.** Part
           5's `test_a_route_no_rfc_allows_crosses_a_session` sent a
           route type 1 whose Length overran its body and asserted no
           finding, because none existed then. That is now the framing
           check, so the case expects one finding and asserts which,
           which is stronger than the zero it replaced. Fifth expired
           example in this family and the first that moved a count
           rather than an octet.
         * **`test/functional/mcast_vpn_test.rb` gained the one case
           where a check runs on octets that crossed a socket**, the way
           EVPN's does: a route type 1 with an 8-octet Originating
           Router, reported once with subcode 9 and a reset, with the
           attribute still parsing so the two channels of #116 are
           visibly independent.
         * Eight sabotages, all landing, each on the check it was aimed
           at: the next hop check removed, the MP_REACH call removed, the
           MP_UNREACH call removed, `originator_finding` accepting any
           width, `reach` ignored so the route checks run on a
           withdrawal, one route type arm dropped from the case, route
           type 3's two `Addr` widths not walked, and one row cut from
           the document's table.
         * **A hand written attribute length was wrong again**, the
           tenth time across this family's six parts and the library
           right every time. RFC 6514 carries no hex, so there is
           nothing to check a reading against; the clean vectors in the
           tests are built with the library and pasted, and only the
           malformed ones are hand built, because the library will not
           encode those. Compute even those with a script rather than
           counting nibbles.
         * **A load order trap, for the second part running.** The doc
           test's new guards build an attribute set to read its findings,
           so they reach `Path_attribute`, which that file did not
           require: it passed in the suite and errored on its own. Part 5
           did the same thing with `Mp_reach`. Both requires are there
           now with a comment saying why.
         * `validation.rb` is back at 100% line coverage.
         * **What is deliberately left, with its reason in the guide.**
           The two receive side rules of section 4.5 that part 2 found,
           one an "outside the scope" sentence and the other needing a
           multicast range RFC 6514 does not number; and extending the
           next hop length check to EVPN and RT-constrain, above.
      7. **The lab. Done**, in #214, which finishes the MCAST-VPN plan.
         `test/functional/lab/mcast_vpn_gobgp_test.rb`, 4 cases and 26
         assertions in about 30 seconds, and `mcast_vpn_frr_test.rb`, 4
         cases and 23 assertions in 7. No Docker. **These two are the
         only lab tests here that measure an absence**, which is why
         the plan called this a measurement rather than a test: neither
         router has SAFI 5, so there is nothing to ask it about our
         octets, and what they assert is how each router says it does
         not have the family. `docs/mcast-vpn.md` section 9 has the
         measurements and the whole table.
         * **Probing paid for the fourth family running, and this time
           it overturned a verdict rather than adding to one.** The
           plan expected to assert one fact. What the routers gave is
           three readings each and a **disagreement in the last one**:
           GoBGP discards the MCAST-VPN UPDATE and keeps the session,
           where FRR calls it `Attribute MP_REACH_NLRI, parse error`,
           fails the whole UPDATE and **tears the session down with no
           NOTIFICATION**. So two routers with the same gap answer
           differently, which is the flow spec section 4.2 situation
           again and means neither behaviour is bgp4r's to copy.
         * **The first reading of FRR was wrong, and the mechanism is
           the part to keep: `is_established?` cannot see a reset.**
           FRR dials back in within a second or two, so a read a few
           seconds after the send finds a session established and
           concludes nothing happened. That is what the first
           measurement here recorded, and it was wrong about the
           verdict and not merely the detail. Both tests watch
           `Neighbor#on_state_change` instead, which is what phase 2 of
           the RIB work added it for, and here there is not even a
           NOTIFICATION to observe. **A router that resets and
           reconnects is indistinguishable from one that never
           objected, to any reading of session state taken afterwards.**
         * **Read GoBGP's capability before sending anything in the
           family.** It records the pair as `UnknownFamily(65541)`,
           which is afi << 16 | safi, and stops printing it once an
           MCAST-VPN UPDATE arrives, logging `Capability was disabled`.
           A test reading it afterwards would find nothing and could
           conclude the capability was never received. Measured both
           ways, since the line persists with no UPDATE. Be exact about
           that log line: EVPN part 10 records it overstating what GoBGP
           did, where a route type 3 still installed afterwards. Here
           the family really is dropped from the neighbor output, and
           what the line never means either way is that the session is
           over.
         * **The control route is an MP_REACH_NLRI for SAFI 1 and not
           an RFC 4271 section 4.3 UPDATE**, which is what makes it
           worth having: it holds the attribute, the next hop and the
           AS_PATH constant and varies only the SAFI, so a discard or a
           reset cannot be the router objecting to MP_REACH or to our
           encoding of it. Both routers install it. That is
           `fault_matrix_scenario.rb`'s `test_the_rib_answer_was_usable`
           discipline with the one input the claim rests on isolated,
           which is #205's lesson about a sabotage that misses.
         * **Neither test makes this family interoperability checked**,
           and that has to be said because a lab test for a family
           usually means the opposite. A router with no parser for SAFI
           5 never reads our octets. The wire format is still bgp4r's
           own opinion against the field widths RFC 6514 and RFC 6515
           state, and `test/functional/mcast_vpn_test.rb` still proves
           only that the wiring sites agree with each other.
         * Four sabotages, all landing, and none of them is on a router
           since neither is ours to break: the SAFI pointed at 2, which
           both routers have, fails 3 of 4 cases in each file and
           spares the config one; the capability left out of the OPEN
           fails 2 and 1; the MCAST-VPN UPDATE not sent fails 2 and 2;
           and a family name each router really has, `ipv4-multicast`
           and `ipv4 multicast`, fails the config case in each.
         * The doc test gained a guard that reads the measured version
           out of each test's own constant **and** out of the
           document's table and requires them to agree, which is
           `evpn_doc_test.rb`'s shape: a pin moved in one place and not
           the other is how this table would go quietly wrong, since
           both tests omit themselves on an unmeasured version and a
           reader would see the table and no failure.
           * **Its first draft passed a sabotage, and why is worth
             keeping: a guard that reads a test file as text matches
             the file's prose as readily as its code.** It asserted a
             bare `/on_state_change/`, and deleting the listener from
             the test left it passing, because both files name the
             method in a comment. Every pattern is anchored at the
             start of a line of code now, `^\s+n\.on_state_change`,
             which a comment cannot match. The same applies to the
             `validation.rb` text guards and to
             `to_hash_round_trip_test.rb`: when the subject is whether
             a file **does** something, match the call and not the
             word. Found only by sabotage, which is the
             check-the-proof rule in Rules for agents paying for
             itself again.
   4. **BGP-LS, attribute 29 and AFI 16388 SAFI 71 and 72, RFC 9552.
      Done, all seven parts**, largest of the four by a long way, and
      last for the reason above. Planned on 2026-10-31 before any code,
      from RFC 9552 read as far as it was then fetchable, its two
      errata, and the IANA registries. Seven parts, the MCAST-VPN
      shape.

      **What was read, and what could not be.** RFC 9552, December
      2023, obsoletes RFC 7752 **and RFC 9029**, the second "by
      incorporating the updates that it made to RFC 7752". **Nothing
      updates RFC 9552**, checked as a list before the parts start
      rather than once mid-family, which is the rule MCAST-VPN part 5
      earned after RFC 6515 was missed by applying it only to route
      types.
      * **Two verified errata, and the first one matters.** EID 7789,
        section 5.3.1.1, Node Flag Bits TLV: the figure prints `T`
        where the bit descriptions define `A`, the Attached bit. That
        is the RFC 8956 situation exactly, a document disagreeing with
        itself in a figure, and `docs/flow-spec.md` records what it
        cost to explain such a thing with an invented mechanism. Read
        the errata before disbelieving a figure, and cite the erratum.
        EID 8766, section 5.2.2, is a stray "and" and is editorial.
      * **Sections 5.4 onward were not fetchable, and the answer was
        to ask**, which is the RFC 4271 section 9 situation twice over.
        Four sources were tried on 2026-10-31 and all four truncate in
        section 5.2 or 5.3: rfc-editor.org's HTML, datatracker's HTML,
        a translation mirror, and a PDF mirror. The two that were
        missing and wanted were section 8.2.2 "Fault Management", where
        this RFC's error handling lives, and section 9 "TLV/Sub-TLV
        Code Points Summary". **Both are read now**, because the
        document was attached to the session, which is how section 9 of
        RFC 4271 was eventually read as well. So nothing in this plan
        is second hand any more and part 6 is no longer gated.
        **The lesson is that asking took one message and four fetches
        bought nothing**, so for an RFC whose tail matters, ask early.
      * **The IANA registry stands in for section 9 and is the better
        source anyway**, since IANA maintains it and a summary in a
        2023 document does not. `bgp-ls-parameters`, read on
        2026-10-31: **139 assigned TLV code points** in "BGP-LS NLRI
        and Attribute TLVs", 7 NLRI types, 9 Protocol-IDs, and five
        smaller flag and sub-type registries. Do not corroborate it
        from a third party mirror, which is the codepoints.org lesson
        in Rules for agents.

      **The framing is the cheapest of the five families and the
      breadth is the dearest.** One TLV rule covers descriptors,
      attribute TLVs and sub-TLVs alike: section 5.1 figure 4 gives
      Type 2 octets, Length 2 octets, Length counting **the value
      only** and not the 4-octet header, and **no padding to 4-octet
      alignment**. Against EVPN's eleven layouts and MCAST-VPN's seven,
      that is one shape. What is expensive is the 139 code points, a
      minority of which are RFC 9552's: the rest come from RFC 9085,
      RFC 9086, RFC 9514, RFC 9294, RFC 8571, RFC 8814 and more. **So
      this entry's own remark that "each of these is a class and a
      registration" understated BGP-LS considerably, and it is worth
      saying by how much**: the framing is a part, and the code points
      are an open-ended backlog that the measure below deliberately
      does not require.

      **Two findings that invert what the earlier families taught, both
      the RFC's own words.**
      * **Keep-and-echo is mandated here, in the strongest terms bgp4r
        has met in any RFC.** Section 5.1: "Unknown and unsupported
        types MUST be preserved and propagated within both the NLRI and
        the BGP-LS Attribute", and "The presence of unknown or
        unexpected TLVs MUST NOT result in the NLRI or the BGP-LS
        Attribute being considered malformed." So an unknown TLV goes
        in **neither `errors` nor `undecoded`**: it is a first-class
        preserved object, not a gap and not a protocol error. That is
        the **opposite** of flow spec, where RFC 8955 section 4.2 makes
        an unknown component type malformed in so many words. Both are
        their own RFC's instruction and bgp4r follows each; do not
        carry one family's answer across. Conventions' note that the
        keep-and-echo rule is bgp4r's own ground is still right, and
        here an RFC agrees with it outright, as RFC 9251 section 9.3.1
        did for one reserved field.
      * **An `Nlri::Unknown` is writable here, and required.** Section
        5.2: "An implementation MUST handle unknown Link-State NLRI
        types as opaque objects and MUST preserve and propagate them."
        The Total NLRI Length bounds each one, so the extent is
        readable and the octets can be replayed. **This does not
        reverse the entry under phase 1**, which says a *generic*
        `Nlri::Unknown` is unwritable because list framing is per
        family: that stays true, and this is a family-local
        `Link_state::Unknown`, the same resolution
        `Flow_spec::Component::Unknown` reached for the same reason.

      **Framing details that are easy to get backwards, so measure
      them.**
      * Total NLRI Length "contains the cumulative length, in octets,
        of the rest of the NLRI", excluding the Type field and itself,
        and **for SAFI 72 it includes the 8-octet Route
        Distinguisher**. Section 5.2, figures 5 and 6.
      * Inside a Node, Link or Prefix NLRI: Protocol-ID 1 octet, then
        the Identifier, **8 octets**, which is the BGP-LS Instance-ID.
        Then Local Node Descriptors; Link adds Remote Node Descriptors
        and Link Descriptors, Prefix adds Prefix Descriptors. Figures 7
        to 9.
      * **Section 5.4, Private Use**: a private-use TLV carries a
        4-octet Enterprise Code first in its value, and a private-use
        NLRI type carries the Enterprise Code immediately after Total
        NLRI Length. **Read first hand in part 1**, which discharges
        the provenance note this entry carried: the claim had come out
        of a PDF mirror whose extraction had lost the normative
        keywords, and both are MUSTs. **The TLV rule is settled and the
        NLRI one is not**: for SAFI 72 that sentence and figure 6 both
        claim the octets immediately after the Total NLRI Length, and
        nothing in the document settles which comes first. So
        `Link_state::Tlv::Unknown` reads an Enterprise Code and
        `Link_state::Unknown` deliberately does not. Whoever implements
        a private-use NLRI type decides that, and the doc test asserts
        the asymmetry so the decision cannot be made by accident.
      * The attribute is **optional non-transitive**, code 29, section
        5.3. So the ATTR_SET lab trick is doubly inapplicable: a
        non-transitive attribute does not cross a router that does not
        understand it, where RFC 6368's whole point was that it does.

      **The error handling outside section 8.2.2.** All of it is
      readable now and 8.2.2's own substance is in the part 6 entry
      below; these three are elsewhere in the document and are easy to
      miss from there. Inventing an action or a subcode is still the
      trap flow spec part 4 and EVPN part 9 each recorded.
      * Section 5.1: unordered TLVs **in an NLRI** "MUST be considered
        as malformed by a BGP-LS Propagator", while unordered TLVs in
        the BGP-LS Attribute are **not** malformed. Note the role:
        "by a BGP-LS Propagator", not by every receiver, which is a
        scope qualifier nothing else in bgp4r's validation has and
        which wants a decision rather than a patch.
      * Section 5.2.1.4: "At most, there MUST be one instance of each
        sub-TLV type present in any Node Descriptor." No action named.
      * Section 5.3: a propagator whose UPDATE would exceed the maximum
        message size because of another attribute "MUST consider the
        BGP-LS Attribute to be malformed" and apply "Attribute
        Discard", and "MUST first discard the BGP-LS Attribute to
        enable the detection and diagnosis of this error condition".
        **That is the only RFC 7606 action in the readable text**, and
        it is a sender-side condition, so it is not a `validation.rb`
        rule as it stands.

      **The lab, and this is the part that probing changed.** The
      entry above said BGP-LS was the last family and said nothing
      about whether a router could check it. Measured on 2026-10-31,
      before planning rather than after, which is the
      probe-before-recording-a-block lesson that has now paid four
      times in this file:
      * **GoBGP 3.23.0 has BGP-LS and FRR 8.4.4 does not.** GoBGP's
        config name is **`ls`**, and a live session negotiates `ls:
        advertised and received` for AFI 16388 SAFI 71. FRR's
        `bgp_nlri_parse_` functions are evpn, flowspec, ip, label and
        vpn, with none for this. **So this family gets one outside
        reference**, like RT-constrain and VPN flow spec, and is not
        the MCAST-VPN case of none.
      * **SAFI 72 has no reference, inside a family whose SAFI 71
        does.** GoBGP has no `ls-vpn`: the config refuses that name and
        a live session reads SAFI 72 back as
        `UnknownFamily(1074004040)`, which is its afi << 16 | safi
        packing for 16388 and 72. That is the VPN flow spec shape
        again, one SAFI of a pair checkable and the other not.
      * **The third config-and-client naming divergence, and the first
        of its shape.** The config accepts only `ls`; the **client**
        accepts `ls` **and** `linkstate`. So `CLIENT_FAMILY` in
        `lab_helper.rb` needs no entry, because `ls` works on both
        sides, which is why this one costs nothing where VPN flow spec
        and EVPN each cost a mapping. Worth recording all the same, so
        a reader meeting `linkstate` in client output does not take it
        for a second family. Two precedents were not a pattern for
        RT-constrain either; say measured, not expected.
      * **The best find: GoBGP can originate a BGP-LS route, so the
        parse direction is checkable against a router for the first
        time in the lab.** `gobgp global rib add -a ls link ...`
        builds a Link NLRI and wants at least 26 tokens after `link`,
        while `node` and `prefix` are refused outright with "invalid
        nlriType. expect [link]". **Every lab test since flow spec
        sends only and records that caveat**; here GoBGP's encoder can
        feed our decoder for NLRI type 2. Finding the exact invocation
        is part 7's first step and was deliberately left there.

      1. **The TLV primitive and the NLRI framing, pure. Done**, in
         #216. `bgp/nlris/link_state_tlv.rb` holds the one TLV of
         section 5.1 with its registry, its `Unknown`, the list reader
         and the ordering rule; `bgp/nlris/link_state.rb` holds the
         NLRI of section 5.2 with `Link_state.nlri_size`, the section
         5.2 Route Distinguisher and `Link_state::Unknown`. Nothing
         dispatches to either, the way #181 and #208 landed their
         families' primitives. `docs/bgp-ls.md` is the guide and
         `test/unit/bgp_ls_doc_test.rb` asserts its load bearing
         claims, with the NLRI type table **discovered** and six
         forward-looking guards for the parts below. Both files at 100%
         line coverage.
         * **A registry, not a `case`, which departs from the four
           families before this one and is measured rather than
           assumed.** `Link_state::Tlv.register` and
           `Link_state.register`, both refusing a type or a hash key
           already taken. Phase 1 above records why a lookup was not
           worth building for flow spec, EVPN, RT-constrain and
           MCAST-VPN, where each added one arm to each of two `case`
           statements. These numbers are not those numbers: 39 TLV code
           points in RFC 9552's own Table 18 and 139 assigned in the
           registry. This is `Attr.register`'s shape one and two levels
           down.
         * **The whole RFC is readable, so two things the plan recorded
           as provisional are discharged.** It was attached to the
           session rather than fetched, the way section 9 of RFC 4271
           eventually was. Section 5.4's normative keywords, which a
           PDF mirror had lost, read as the plan guessed: a 4-octet
           Enterprise Code MUST be first in a private-use TLV's value.
           And section 8.2.2 is read, so **part 6 is no longer gated**;
           its substance is in `docs/bgp-ls.md` section 8 and in the
           part 6 entry below.
         * **The SAFI is a parse-time input, which is flow spec's
           situation rather than EVPN's.** Nothing in the octets says
           whether the section 5.2 RD is there, since figures 5 and 6
           differ by eight octets and by nothing a reader can see. So
           `Link_state.new(octets, safi)` takes it, defaulting to 71,
           and the same capture read either way replays byte for byte.
           **`nlri_size` needs none of that**, because the Total NLRI
           Length covers the RD, so one arithmetic frames both SAFIs.
           That pair is asserted in the doc test.
         * **Two `Unknown`s, one per level, and this is the first
           family where both are required by the document** rather than
           decided by bgp4r: section 5.1 for an unknown TLV type and
           section 5.2 for an unknown NLRI type, each a MUST. The NLRI
           one keeps **opaque** octets and frames no TLVs out of them,
           which is the RFC's own word: the four defined types start
           with a Protocol-ID octet and an 8-octet Identifier before
           any TLV, so a reader that framed from the first octet would
           invent structure. Mind the names, since a bare `Unknown`
           means a different class inside `Link_state` than inside
           `Link_state::Tlv`.
         * **Keep and echo is mandated here, which inverts flow spec.**
           Section 5.1: unknown types "MUST be preserved and
           propagated", and their presence "MUST NOT result in the NLRI
           or the BGP-LS Attribute being considered malformed", where
           RFC 8955 section 4.2 makes an unknown component type
           malformed in so many words. Each is its own RFC's
           instruction. Worth knowing before anyone files bgp4r's
           keep-and-echo rule as over-engineering: here an RFC agrees
           with it outright.
         * **The ordering rule lives with the TLV**, so part 6 asks
           rather than reimplementing it, which is the lesson flow spec
           part 4 recorded. Three levels, and two details a readable
           implementation gets wrong: the second level is the **Length
           field** and not the value's real size, so a TLV whose
           declared Length lies sorts by the lie, and the third is
           bytewise and numerical, which the section spells out. The
           attribute's own ordering rule is a SHOULD whose breach is
           explicitly not malformed, so `ordered?` answers the question
           and not the policy.
         * **A bug found and not fixed, because it is four other
           families and its own topic**:
           `Klass.new(an_extended_instance)` answers garbage for
           `Evpn`, `Mcast_vpn`, `Flow_spec` and `Rt_constrain`. It is
           under "Known issues to work on" with the reproduction and
           the two-line fix. `Link_state` takes the Path Identifier off
           before the re-parse and has a test for it, and the doc test
           asserts the other four still have it, so a fix fails that
           guard and says to strike the paragraph.
         * **The twelfth wrong hand-written expectation, within the
           hour.** RFC 9552 carries no worked example and no hex
           anywhere, measured: the six occurrences of "0x" are section
           5.2.3.1's OSPF route type values. So this is the RFC 4684,
           RFC 6368 and RFC 6514 situation, and the first hand-written
           vector here was wrong, asserting 77865 for `0x00013039`
           where it is 77881. Both test files say in their header that
           the arithmetic is the thing to doubt first. That case now
           uses Enterprise Number 2636, which is checkable outside this
           repository.
         * **The TLV level stands on its own**, which is what says it
           is a primitive rather than half of a pair:
           `link_state_tlv_test.rb` requires `link_state_tlv` alone and
           asserts nothing about the NLRI level, so the cross-level
           cases live in `link_state_test.rb`. That is the independence
           `mcast_vpn_route_test.rb` keeps by putting `Leaf_a_d`'s
           tests in the NLRI file, and the doc test asserts it, since
           it is the kind of thing a later part erodes by adding one
           convenient require.
         * Eleven sabotages, each landing on the guard it was aimed at:
           each registry given a class, a table row flipped to yes,
           `nlri_size` grown a SAFI argument, `sort_key` using the real
           size, a dispatch arm added to `nlri.rb`, a check added to
           `validation.rb`, a lab file created, the undecodable example
           moved, the copy constructor fixed in `Mcast_vpn`, and the
           TLV test file given a require of the NLRI level.
      2. **The Node NLRI, type 1, and the Node Descriptor sub-TLVs.
         Done**, in #217, which is the whole of section 5.2.1.
         `bgp/nlris/link_state_descriptor.rb` holds TLV 256 and 257 and
         the four sub-TLVs of section 5.2.1.4;
         `bgp/nlris/link_state_nlri.rb` holds `Headed`, the head that
         figures 7 to 9 share, and `Node` on top of it. Still pure:
         the dispatch gates are part 4. All four BGP-LS files at 100%
         line coverage.
         * **Taken first because Link and Prefix both carry Local Node
           Descriptors**, which is what the plan said, and the shape
           that came out of it is worth more than the one TLV: reading
           figures 7, 8 and 9 together, the three layouts share a
           Protocol-ID octet, an 8-octet Identifier and a set of
           descriptor TLVs, and differ only in which TLVs follow. So
           `Headed` carries all of that and part 3 is three type
           numbers and three hash keys on top of it.
         * **The body after the head is a TLV list and not named
           fields**, which is section 5.1 rather than convenience: an
           unknown TLV "MUST be preserved and propagated" and must not
           make the NLRI malformed, and a layout of named fields has
           nowhere to put one. It also means a Node NLRI with no Local
           Node Descriptors builds and parses, which is right twice
           over, since section 8.2.2 names "presence of a mandatory
           TLV" among the semantic validations not to perform.
         * **One flat registry covers TLVs and sub-TLVs alike, and that
           is IANA's doing rather than a simplification.** The registry
           is "BGP-LS NLRI and Attribute TLVs", one space for both, and
           Table 18 lists 256 and 257 beside 512 to 515 with no column
           saying which is which. So a sub-TLV number means the same
           thing under every parent, the opposite of the EVPN extended
           community sub-types and of the IS-IS sub-TLVs where the
           parent decides, and part 1's single `Tlv::REGISTRY` needed
           nothing here.
         * **TLV 256 and 257 are one layout and two type numbers**,
           which is what sections 5.2.1.2 and 5.2.1.3 say: the same
           sentence with "local end" and "remote end", and figures 10
           and 11 identical. `Mcast_vpn::Shared_tree_join` and
           `Source_tree_join` are the same shape for the same reason.
         * **513 is deprecated and implemented anyway.** Table 18
           carries the row and marks it deprecated, and section 5.2.1.4
           says implementations "SHOULD support the advertisement of
           this sub-TLV for backward compatibility" with RFC 7752
           producers. A deprecated code point a peer still sends is
           what a protocol testing tool has to read.
         * **The node type rule needs two levels and is implemented
           across them.** Section 5.2.1.4: "The TLV size in combination
           with the protocol identifier enables the decoder to
           determine the type of the node."
           `Igp_router_id::SHAPES` holds the width half, keyed by width
           with the Protocol-IDs each belongs to, and
           `Headed#node_type` combines them, because that is the one
           place with the Protocol-ID. Threading the Protocol-ID down
           into the sub-TLV would buy nothing, since the octets replay
           without it, and a class that accepted it would eventually
           use it. **nil is an answer**: a 6-octet Router-ID under
           Protocol-ID 4, 'Direct', is legal and the section describes
           no node kind for it, so reporting one would be inventing it.
         * **Section 5.2.1.4's ordering rule is section 5.1's with the
           tiebreakers made unnecessary**, and noticing why is worth
           more than the two sentences: 5.1 orders by type, then Length,
           then Value, because several TLVs of one type can share an
           NLRI, and here the once-only rule means two sub-TLVs never
           share a type. So `Node_descriptors#ordered?` asks
           `Tlv.ordered?` rather than keeping a second comparison, and
           `#duplicate_types` reports the other rule. Both report and
           neither refuses; part 6 is where a check reads them.
         * **Part 1 chose test examples from the ranges parts 2 to 5
           fill, and this part paid for it.** Its TLV cases used types
           256, 513 and 1024, which are a node descriptor, a node
           descriptor sub-TLV and a node attribute, so four broke the
           day the first descriptor landed and a fifth would have broken
           in part 5; its NLRI cases used types 1, 2 and 5. Both files
           now use a type that **cannot** acquire a class, named in a
           constant with the range asserted: Table 17 reserves TLV code
           points 0 to 255 as "not to be allocated", and Table 12
           reserves NLRI type 0. **The lesson was already written down**
           in `docs/mcast-vpn.md`, four times, and part 1 did it anyway:
           pick an example that cannot expire rather than re-pointing
           one later.
         * **A third shape of the load order trap, and it cost two
           guards their first firing.** `bgp_ls_doc_test.rb` discovers
           from `Tlv::REGISTRY` and `Link_state::TYPES`, which are
           **mutable** and filled by `register` calls spread across
           files. It required part 1's two files only, so when this part
           landed its two forward-looking guards **passed standalone and
           failed in the suite**, where the registering file had been
           loaded. The two traps Conventions records fail in opposite
           directions and are about constants; this one is about global
           mutable state, so the answer is not "run it both ways" but
           **require every file that writes to what you read**. The
           sibling doc tests do not have it, because each discovers from
           a frozen hash literal one file defines.
         * **The doc test's table parser had to be scoped for the same
           reason.** Part 1's read four-column numeric rows out of the
           whole document, and part 2 added a second such table, so one
           regexp would have read each table's rows into the other's
           answer, silently. It slices by heading now.
         * Nineteen sabotages, each landing on the guard it was aimed
           at: twelve on the library, including `Opaque32::WIDTH`, the
           `SHAPES` protocol lists, the container's tail, `ordered?`,
           `duplicate_types`, the 256 and 257 type numbers swapped, a
           missing `register`, `Headed::ID_WIDTH`, the Identifier packed
           as 4 octets, `node_type` skipping the Protocol-ID check, the
           head parse dropping its tail, and `Ospf_area_id` refusing a
           dotted quad; and seven on the doc guards.
           * **One missed first and the reason is #205's again.**
             Swapping the two node descriptor type numbers with one
             `sed` rule set both to 256, so `register` raised at load
             and every test errored on the require. That is the
             duplicate-type guard working, not the claim, and a
             sabotage that breaks something unrelated to the claim is
             the same miss as one that passes. Redone with both numbers
             changed at once: 10 failures in one file and 7 in the
             other.
      3. **The Link NLRI, type 2, and the two Prefix NLRIs, types 3
         and 4, with their descriptor TLVs. Done**, in #218, so **all
         four NLRI types of Table 1 and every descriptor TLV RFC 9552
         defines are in**, which is the whole of sections 5.2.1, 5.2.2
         and 5.2.3. `bgp/nlris/link_state_link_descriptor.rb` holds
         the six of section 5.2.2 and
         `link_state_prefix_descriptor.rb` the two of 5.2.3; the three
         NLRI types go on part 2's `Headed`, which is what that base
         was for. Still pure: the gates are part 4. All six BGP-LS
         files at 100% line coverage.
         * **Table 4 has no Length column and Table 5 has one**, which
           is the first thing to know before writing either set,
           because it decides where the widths come from. So the two
           prefix descriptor widths are RFC 9552's own, 1 for the OSPF
           Route Type and variable for the IP Reachability
           Information, and **every link descriptor width is a
           citation to a different RFC**: TLV 258 is 8 octets from RFC
           5307 section 1.1, 259 and 260 are 4 from RFC 5305 sections
           3.2 and 3.3, 261 and 262 are 16 from RFC 6119 sections 4.2
           and 4.3. A wrong width among those cannot be caught by
           reading RFC 9552, which is why `docs/bgp-ls.md` section 3c
           puts the citation beside each one and the doc test holds
           the table against the classes.
         * **Four of the link descriptors can repeat, and that
           confirms part 1's reading of section 5.1 from the other
           end.** Section 5.2.2 says of TLVs 259 to 262 "This sub-TLV
           can occur multiple times", so two of a type in one NLRI is
           ordinary traffic here and **that is what section 5.1's
           Length and Value tiebreakers are for**. One section earlier
           the once-only rule of 5.2.1.4 makes those same tiebreakers
           unreachable, which part 2 recorded. Same rule, two
           opposite consequences, and the doc test asserts the
           contrast rather than the half.
         * **The MT-ID is the family's first reserved field**, and its
           R bits mean two different things in one sentence of section
           5.2.2.1: "In the case of the MT-ID TLV being used as a
           descriptor of an IGP link or prefix, the Bits R are
           reserved and MUST be set to 0 when originated and ignored
           on receipt", where in a Node attribute they are "set as per
           Section 7.1 of [RFC5120]". So it is the ordinary
           keep-and-echo rule rather than a new one: the nibble is
           echoed, `reserved_set?` reports it, and the hash carries
           the words rather than the bare IDs only when one is set.
           Part 5 is where the attribute's reading of the same field
           lands.
         * **The IP Reachability TLV holds no family, which is the
           second cross-level read after part 2's node type rule.**
           Section 5.2.3.2 gives a Prefix Length in bits and
           `(bits + 7) / 8` octets of prefix and nothing that says
           whether they are IPv4 or IPv6; the NLRI type does, 3 or 4.
           So `Tlv::Ip_reachability` holds the halves and
           `Prefix_nlri#prefix` combines them, the same split as
           `Igp_router_id` and `Headed#node_type` for the same reason.
           The section states its first four octet counts rather than
           leaving them to be derived, and the doc test reads them out
           of the document's quotation of them.
         * **A mis-typed Prefix NLRI is wrong without being malformed,
           and a hand written expectation had it backwards.** The test
           asserted that an IPv6 prefix in an NLRI of type 3 reads
           back as nothing. It reads back as a **different valid
           prefix**: 2001:db8::/32 packs down to the same four octets
           as 32.1.13.184/32, so nothing in the octets can tell them
           apart. That is the split put as sharply as it goes, and it
           is the thirteenth hand written expectation wrong across
           these families with the library right every time. RFC 9552
           carries no hex anywhere, which is the RFC 4684, RFC 6368
           and RFC 6514 situation.
         * **NLRI types 3 and 4 are one layout and two type numbers**,
           the third instance of that shape after TLV 256 and 257 and
           `Mcast_vpn`'s two section 4.6 types: figure 9 says they
           "use the same format". `Prefix_nlri` is the layout and the
           two subclasses are the type numbers and the family.
           **A base class costs nothing here where MCAST-VPN part 3
           needed a module**, and the difference is discovery: that
           family's doc test discovers route types from `Route`
           subclasses, where this one discovers from
           `Link_state::TYPES`, so an unregistered base cannot read as
           a fifth NLRI type. A guard asserts it is registered
           nowhere.
         * **Two bugs the tests found in `Addr_tlv`, both by probing a
           value no RFC allows.** A 4-octet value parsed as an
           `Ipv6_interface_address`, because `IPAddr.new_ntoh` reads 4
           octets as IPv4 and `hton` gives them straight back, so the
           encode-matches rule was satisfied by a class of the wrong
           width; `parse` now requires exactly WIDTH octets. And
           `Ipv4_interface_address.new('2001:db8::1')` built a
           16-octet value into a 4-octet TLV; `coerce` refuses it now
           and names `Tlv::Unknown.new(259, octets)` as the open
           octet-level route, which Conventions requires and which the
           test exercises.
         * **Thirteen sabotages, and the pass itself went wrong twice
           before any of them meant anything.** First the script
           reverted with `git checkout` after each one, and the two
           new library files were **untracked**, so that command
           aborted on an unknown pathspec and reverted **nothing at
           all**, including the tracked files. Eleven sabotages
           accumulated into one broken tree that took four repairs to
           unpick, and two of them reported failures that were really
           earlier sabotages still in place. **Commit before
           sabotaging**, or revert from a copy rather than from git,
           and assert the tree is clean after each revert rather than
           hoping. Same family as the scripted CLAUDE.md edit in
           #188: a script that asserts on its match and not on its
           result.
           * **Then one of the thirteen passed, and it was the script
             again rather than a weak test.** Swapping TLV 258's
             local and remote on encode changed nothing, because the
             `@` in the replacement was escaped wrong for the
             heredoc and the pattern never matched. Applied by hand
             it fails 3 and errors 1. A sabotage that passes means
             the sabotage missed, which Rules for agents already
             says; what this adds is that a script of `perl -pi`
             rules is exactly where the missing happens, so read the
             diff before reading the result.
           * Each one then lands on what it was aimed at: a width
             swapped fails 4 and errors 7 in the link descriptor
             file; the MT-ID mask one nibble wider fails 3;
             `Addr_tlv` accepting any width fails 1; `octets_for`
             flooring fails the prefix descriptor file and the
             document's own quoted list; route type 6 dropped from
             the table fails 1; `trailing_bits_set?` stubbed to false
             fails 1; TLV 265 unregistered fails across four files;
             `prefix` reading the other family fails 5 in the NLRI
             file; the two prefix type numbers swapped **both at
             once** fails 3, where changing one would have been
             #205's miss, since `register` refuses a duplicate and
             the file would die at load; and a document width row,
             the status table or a cut table row each fails the
             matching discovery guard.
         * **A Ruby version bug the suite could not see, found by
           CI.** `Ip_reachability` defaulted its octets to `+''`,
           which is US-ASCII, so the default route handed an empty
           US-ASCII string to `IPAddr.new_ntoh`: Ruby 3.3 accepts it
           and 3.4, 4.0 and head raise. One test of 2217, green here
           and red on three of four Rubies. All eight buffers in the
           family are `String.new` now, which is BINARY with no
           argument, and the mechanism is in Conventions beside the
           frozen-literal rule.
           * **The encoding is asserted rather than trusted**, since
             that is the only form of the test that fails on 3.3
             against the unfixed code. The general guard reads every
             octet buffer through its own accessor, 11 of them, with
             the count pinned: **its first draft asserted
             `encode.encoding` and survived four sabotages**, because
             `encode` goes through `pack` and that forces binary on
             the result whatever went in.
           * `Tlv::Unknown` and `Link_state::Unknown` keep a
             `String.new` default that **cannot be reached**: every
             branch of each constructor assigns `@value`, and the
             one-argument form goes through `nil.to_s.b`. Sabotage
             showed it, and they are kept and recorded as unreachable
             the way `Fib`'s `:no_next_hop` branch is.
         * **A doc guard that reads a document has to say how many
           rows it expected**, which cost one of these its first
           firing. The octet count guard used a literal space in
           `prefix length (\d+)` and the wrapped document had a
           newline there, so it measured three of section 5.2.3.2's
           four cases and passed. It asserts the count first now, and
           every pattern in it uses `\s+`. Found by being suspicious
           of an assertion that could pass by luck, which is the one
           rule in Rules for agents that keeps paying.
         * The table parser in `bgp_ls_doc_test.rb` reads the first
           cell and the last and ignores the column count, because
           section 3's table has four columns and 3c's have five. A
           fixed-group regexp read one and skipped the other in
           silence, which is the same failure one level up.
      4. **Wiring the NLRI to the dispatch sites, plus a loopback
         functional test. Done**, in #219. bgp4r reads and writes a
         BGP-LS UPDATE now, over a real session, in both SAFIs. Four
         sites, the EVPN and MCAST-VPN count: the framing in
         `nlri_size`, the two dispatch gates, and the next hop. **Two
         of them are this family's own and no earlier family has
         either.**
         * **The SAFI is a parse-time input, which only flow spec also
           needs, and it reaches the parse gate alone.** Figures 5 and
           6 of section 5.2 differ by the 8-octet Route Distinguisher
           and by **nothing a reader can see in the octets**: no key,
           no flag, no length. So the same capture is a valid NLRI read
           either way and only the attribute's SAFI decides, which is
           why `Link_state.new_ntop(s, safi, path_id)` is told.
           `test_the_same_octets_read_two_ways_under_the_two_safis`
           sends that home: one reading gives Protocol-ID 0 with no RD
           and the other Protocol-ID 2 with RD=100:200, both replaying
           byte for byte, so a capture is only as good as the SAFI it
           is read with and nothing on the wire catches a mix-up.
           `nlri_size` needs none of it, because section 5.2 says the
           Total NLRI Length "also includes the length of the Route
           Distinguisher", so one arithmetic frames both.
         * **The next hop is three-way where the other three families
           are two-way, and the VPN form differs from SAFI 128 and
           129.** Section 5.5, verbatim: length 4 is IPv4, 16 a global
           IPv6 address, and 32 "one global IPv6 address followed by an
           IPv6 link-local address", which is RFC 2545's form read by
           the loop turning twice. **This is the first family to ask
           for that under an AFI other than 1**, so
           `ipv6_nexthop_length?` could not have answered: it keys on
           the SAFI, answers false for these two, and nothing claims
           RFC 8950 applies here.
           * For SAFI 72, "an 8-byte Route Distinguisher set to all
             zero is prepended to the next hop". **Prepended to the
             next hop, singular**, so the lengths are 12, 24 and 40
             where RFC 8950 gives SAFI 128 and 129 24 or 48 by
             repeating the RD per address. The 12, 24 and 40 is this
             reader's arithmetic from that one sentence and not a list
             the section gives; the sentence is verbatim. **RFC 7752
             section 3.4 carries the whole passage word for word**,
             fetched on 2026-11-01 after four attempts on RFC 9552
             itself truncated at section 5.3.3.4, so it is
             corroboration of the reading rather than a second source.
             It adds one sentence RFC 9552 is not known here to carry,
             cited as RFC 7752's: "The link-local IPv6 address should
             be used as described in [RFC2545]."
           * So a 40-octet field is one `Vpn`, which writes its own
             zero RD, then one bare `Prefix`, which writes none. That
             makes this **the one place in the library where a next hop
             class depends on its position**, so `nexthop_klass` takes
             an index and `set` passes one; every other family ignores
             it. All six lengths are asserted over a socket.
         * **Three tests moved off this family and cannot move again.**
           `mp_reach_test.rb`'s
           `test_an_unimplemented_safi_still_raises_so_the_octets_survive`
           and the two behind `path_attribute_test.rb`'s `UNDECODABLE`
           each used BGP-LS as their example of a family bgp4r cannot
           decode. They were EVPN until #185 and BGP-LS until this, and
           there is **no unimplemented family left to point at**. So
           the third choice is not a family but a SAFI IANA has
           **Reserved**: the registry gives 255 as Reserved citing RFC
           4760 and 241 to 254 as Reserved for Private Use and "Not to
           be assigned", read on 2026-11-01. Nothing can be assigned
           there, so this example is permanent. `UNDECODABLE_SAFI`
           names it and two tests assert the range, which is what parts
           1 to 3 paid four times to learn. Every assertion is
           unchanged across all three moves.
           * **One of them failed on the count rather than the family,
             which is the sharper reading.**
             `test_an_attribute_that_is_both_undecodable_and_malformed`
             sends an MP_REACH whose next hop length overruns, so it is
             malformed and undecodable at once. Wired in, SAFI 71's next
             hop arm read the 4 octets that did arrive as an IPv4
             address and raised nothing, so the `Attr::Gap` disappeared
             and only the `errors` entry was left: `1 expected but was
             0`. An expired example usually shows as a wrong name; here
             it showed as a missing channel.
         * **A bug in part 2's code, found by writing the functional
           test rather than by reading.**
           `Igp_router_id#from_hash` used `pack('H*')` where the field
           value form used `coerce`, which strips separators first. On
           bare hex the two agree, which is why part 2's tests passed;
           on the dotted form they do not, because `pack('H*')` maps a
           separator by its **low nibble** instead of skipping it. So
           `{:igp_router_id => '1921.6800.1001.02'}` built nine octets,
           `1921e6800e1001e020`, against the correct seven, every `.`
           shifting what followed. It surfaced as `node_type` answering
           nil, since no shape has a width of 9. One method for both
           forms now, so they cannot disagree again, with a regression
           test at each level.
         * **`test/functional/link_state_test.rb` is the proof and the
           only one there can be**, for the reason
           `flow_spec_test.rb` records. 16 tests and 173 assertions at
           part 4, 20 and 225 once parts 5b-ii and 5c added a case each,
           about a second. Named in `.github/workflows/test.yml`, which
           lists each functional test by hand. It carries the only cases
           in this family that send a two-address next hop, a VPN NLRI
           and an unknown NLRI type beside a known one over a socket.
         * **Ten sabotages, each landing, and four of the signatures
           say something the assertions do not.** Reverting only
           `Mp_unreach`'s own loop fails **exactly the two withdrawal
           cases**, which is the signature flow spec, EVPN,
           RT-constrain and MCAST-VPN each measured: the two parse
           loops are independent copies and those two cases are all
           the cover the second has. The next hop arm deleted fails
           **13 of 16**, sparing the two withdrawals, which carry no
           next hop, and the one case that works on octets directly,
           which is #185's EVPN signature again. The parse gate's arm
           deleted fails **15**, sparing only that same direct case.
           And **not passing the SAFI down fails exactly 2**,
           `test_a_vpn_nlri_crosses_a_session` and
           `test_a_vpn_withdrawal_crosses_a_session`, which is the
           narrowest signature in the family and says precisely what
           that argument is for: nothing but a VPN NLRI can tell.
           * The other six: the framing reverted to the prefix
             arithmetic fails 15, the build gate's arm made
             unreachable errors 15, inferring the AFI errors 15 and
             fails a doc guard, repeating the RD per address on build
             fails exactly the 40-octet case, reading an RD per
             address on parse fails the same one, and
             `Igp_router_id#from_hash` back to `pack('H*')` fails one
             test at each of the three levels that now pin it.
         * **Two guards had to be re-pointed and both were made
           two-sided rather than weakened.** The no-dispatch one now
           asserts all four sites, by reading each gate as text with
           patterns anchored at the start of a line of code **and** by
           calling through them, since reading a file cannot say the
           wiring works. The undecodable one now asserts the examples
           are **not** this family and names the reserved SAFI.
         * **Two parsing traps in the doc test, both self-inflicted and
           both already written down.** A guard's phrase straddled a
           line break, so a literal space did not match: #218 recorded
           that rule one pull request earlier, and this time the guard
           failed outright rather than measuring a subset, which is the
           better of the two outcomes. And the status table parser read
           the **whole** document, so the new section 9 next hop table,
           whose rows are three columns starting with a digit, wrote
           "IPv4" over part 4's status. Part 2 fixed exactly that for
           the code point tables; the lesson did not carry, and it is
           scoped by heading now.
         * **A third shape of the load order trap, in the file that
           already records two.** The wiring guards stopped reading the
           gates as text and started calling through them, so
           `BGP::Nlri` and `BGP::Mp_reach` became code the doc test
           needs: it errored standalone with `uninitialized constant
           BGP::Nlri` while the suite stayed green. Requires added with
           the reason.
      5. **The BGP-LS Attribute, code 29, and the RFC 9552 attribute
         TLVs.** A path attribute, so it goes through `Attr.register`,
         which is the registry that already works, rather than through
         either NLRI gate. The node, link and prefix attribute TLVs of
         section 5.3 and no others: the rest of the 139 are other
         RFCs' and are the backlog the measure below excludes.
         **Three parts, one per table**, planned on 2026-11-01 from
         section 5.3 read first hand, since 25 TLV classes in one pull
         request is not a small diff.
         * **5a, the attribute and Table 6. Done**, in #221.
           `ATTR::BGP_LS = 29`, `Link_state_attribute`, and the
           **six** node attribute TLVs that are new: 1024 Node Flag
           Bits, 1025 Opaque Node Attribute, 1026 Node Name, 1027
           IS-IS Area Identifier, 1028 IPv4 Router-ID of Local Node,
           1029 IPv6 Router-ID of Local Node. A BGP-LS Attribute
           reads back out of an attribute set now with no protocol
           error and no coverage gap, where before it was an
           `Attr::Unknown` with an `Attr::Gap`.
           * **The hash is a list and not a map keyed by type**, which
             is the one thing this attribute does differently from
             `Path_attribute`'s own hash, and the RFC gives the reason
             twice: section 5.3.1.2 says the IS-IS Area Identifier
             repeats and section 5.3.1.4 says each auxiliary Router-ID
             is "a separate TLV". `Path_attribute` had to bolt a
             `:duplicates` key onto a hash keyed by type for exactly
             this; a list carries it for free. That is isis4r's
             CLAUDE.md lesson arriving in bgp4r, where repetition is
             the design rather than the exception.
           * **Erratum 7789 applied.** `Node_flag_bits` names bit 1
             Attached, as Table 7 does, and has no T bit, which is
             what Figure 15 prints. `DEFINED_BITS` is 0xfc and the low
             two bits are kept and echoed, which section 5.3.1.1 asks
             for outright: "The bits that are not defined MUST be set
             to 0 by the originator and MUST be ignored by the
             receiver." The mask table is in `docs/bgp-ls.md` section
             10a and the doc test reads it out of the document against
             `BITS`, both ways, so a bit renamed or moved in either
             place fails.
           * **Section 5.3.1.3's 255 does not say whether the framing
             octets are in it.** "The maximum length of the Node Name
             TLV is 255 octets", where every other width in the family
             is a value width. 255 of value and 251 of value are both
             readings and the section settles neither, so nothing
             enforces either and a longer name builds, which the
             2-octet Length field can carry. Recorded rather than
             resolved.
           * **Three more hand written expectations wrong, the
             fourteenth to sixteenth in these families, and the
             library right every time.** Two attribute Length octets
             computed by hand, and one hex string split in the wrong
             place. RFC 9552 carries no worked example and no hex
             anywhere, measured in part 1, so there is nothing here to
             check a reading against: compute the vectors with the
             library and paste the result.
           * **`Attr.by_key` answers a `Registration` and not the
             class**, which cost one assertion. Every other caller
             reads `.klass`.
           * **The `to_hash` catalog allows one entry per class**,
             because the guard resolves an entry's key with
             `Object.const_get`. A second recipe named
             `'...Node_flag_bits (undefined bits)'` failed two guards
             at once. So the one recipe has to reach the field a
             names-only hash would drop, which is the
             exercise-every-field rule this file already records three
             instances of, with the names path left to the class's own
             test file.
           * **The lab example expired and is re-pointed rather than
             weakened**, the fifth in this family.
             `link_state_gobgp_test.rb` asserted the attribute came
             back as an `Attr::Unknown`; it parses now. Re-measured on
             2026-11-01 against gobgpd 3.23.0: what GoBGP puts in it
             is one TLV of type **1101**, the Adjacency SID of RFC
             9085, which is in **no table of RFC 9552**, so it stays a
             `Tlv::Unknown` through 5b and 5c as well and the example
             cannot expire again. That is the keep-and-echo MUST of
             section 5.1 met inside the attribute, where the NLRI case
             beside it meets the same MUST in the descriptors with
             sub-TLV 516.
           * **Two things #220 left stale, and they agreed with each
             other so nothing caught them.** The parts table in
             `docs/bgp-ls.md` section 7 still said part 7 was to do,
             and `test_the_document_names_the_seven_parts` still
             asserted that word. A guard that compares a document
             against a hard coded word is not a guard, which is that
             method's own opening paragraph: part 7's status is tied
             to the lab files existing now, and part 5's to Table 6
             being registered while Tables 8 and 10 are not.
           * **The doc test's row parser was tightened from `\w+` to
             exactly yes or no**, because section 10a's mask table has
             a digit in its first cell and a word in its last and was
             kept out of the code point answer only by the space in
             "ISO 10589". Part 2 and part 4 each paid for that shape
             once already. Saying what the cell has to be is cheaper
             than scoping around every table somebody adds later.
           * **Fifteen sabotages, fourteen landing, and the one that
             passed is a guard that is defensive rather than load
             bearing.** The fourteen: the six flag masks reversed, bit
             1 named T rather than Attached, `DEFINED_BITS` widened to
             0xff, `Node_name` hashing as hex, `Opaque_tlv` reading
             its hash as raw octets, the attribute's hash keyed by
             type, the attribute's parse dropping the tail, the
             attribute's flags made transitive, TLV 1028's width made
             16, a `from_hash` dropping the declared length, a
             document table row flipped to no, the document's mask
             table saying T, a seventh class registered at 1030, and
             the attribute registered at the wrong code point. The
             miss: **loosening the doc test's row parser back to
             `\w+` passes the whole suite**, because every Reference
             cell in the section 10a mask table has a space in it, so
             the loose form never read a bit number as a code point.
             The tightening is kept for the next table somebody adds
             and the comment on it now says that rather than implying
             it catches something today.
           * **The load order trap, fourth shape in that one file.**
             The new guards need `Link_state_attribute` as code and the
             registries are filled by a fifth file, so both requires
             are named at the top with the reason. And a guard's phrase
             wrapped in the document again, so a literal space missed
             it: `\s+`, which #218 recorded and #219 met one pull
             request later.
         * **5b, Table 8.** The **thirteen** link attribute TLVs that
           are new: 1030 and 1031, the remote Router-IDs, then 1088 to
           1098. **Two pull requests**, because 5a's deferred refactor
           is now a measured need and is its own topic.
           * **5b-i, the shared bases lifted into
             `link_state_tlv.rb`. Done**, in #222. No new TLV and no
             behaviour change. `Opaque32` was in `link_state_descriptor.rb`,
             `Addr_tlv` in `link_state_link_descriptor.rb` and
             `Opaque_tlv` in `link_state_node_attribute.rb`, each
             written where its first user was, and Table 8 wants all
             three: 1088 and 1092 are `Opaque32`, 1030 and 1031 are
             `Addr_tlv`, 1097 is `Opaque_tlv`. 1098 Link Name is
             1026's shape, so `Node_name`'s text handling comes out as
             a `Text_tlv` base in the same move. 5a's entry said to do
             this when a second file reached for `Opaque32`, and that
             is now; the alternative is three sideways requires and
             file names that stop describing what they hold. **The
             move changes no constant path**, since every one of these
             files reopens `BGP::Link_state::Tlv`, so the test is the
             suite passing unchanged.
             * **`Node_descriptors` stayed with Table 3**, which is
               the line the move draws: it is a base too, and only
               Table 3 uses it. Shared means more than one of the
               RFC's tables, not merely abstract.
             * **Two guards could not be written the obvious way.**
               Inheriting `Tlv` directly does not make a class a
               base, since six concrete classes do too; a base is one
               with no `TYPE`. And **`constants(false)` cannot say
               which file defined a constant**, because every file
               here reopens `class Tlv`, so the file placement is
               held by a text guard and nothing else can hold it.
               That is the same fact that made the move free,
               arriving as a limit on checking it.
             * **Seven sabotages, all landing**: `Text_tlv` moved
               back out of the framing file, `Opaque32` given a TYPE
               so it stops being abstract, a fifth base added with no
               document row, a base row cut from the document,
               `Node_descriptors` registered at a third type so
               "shared means two tables" stops holding, `Text_tlv`
               hashing as hex rather than text, and `Addr_tlv`'s
               width check dropped, which is part 3's rule now one
               file over.
             * **Removing a sideways require is where the load order
               trap bites**, and it bit twice in one change: the node
               attribute test file and the attribute test file each
               leaned on `link_state_link_descriptor.rb` arriving
               transitively through the source's require of it, and
               both failed standalone while the suite stayed green.
               The files that lean on a transitive require are not
               the file being edited, so run every file in the family
               on its own after a move, not just the ones changed.
           * **5b-ii, the thirteen classes. Done**, in #223, in
             `bgp/nlris/link_state_link_attribute.rb`, against bases
             that were not moving under them. All thirteen round trip
             through their own hash and all are in the catalog.
             * **`Float32_tlv` is a fifth base and stays with Table
               8**, which is 5b-i's line deciding its first case
               rather than a judgement: shared means more than one of
               the RFC's tables, and only Table 8 has floats. The doc
               guard asserts each single-table base's registered
               subclasses, so a third table reaching for one fails and
               says to move it.
             * **TLV 1088 numbers its bits from the least
               significant**, which RFC 5305 section 3.1 says
               outright: "the least significant bit is referred to as
               'group 0', and the most significant bit is referred to
               as 'group 31'". Every other bitfield in this family
               numbers from the most significant, so the mask for
               group 0 is 0x00000001 and a reader carrying the
               family's convention across gets all 32 backwards. It is
               also the only one of the four bitfields here with
               nothing reserved: all 32 bits are groups.
             * **The width of TLV 1095 is a fact about the source IGP
               and not about the value**, so it is carried rather than
               inferred: a metric of 10 is legal at 1, 2 and 3 octets
               and section 5.3.2.4 picks none. `Igp_metric.new(10)`
               defaults to 3 and the hash carries `:width` beside
               `:metric`. Inferring from the magnitude would be a rule
               the section does not have. Its two reserved bits belong
               to the 1-octet form alone, so `undefined_bits` answers
               0 at the wider widths however the value's high bits
               read.
             * **A NaN with a payload is the one value here that does
               not replay as its own class**, and it is Ruby rather
               than the library: `unpack1('g')` on `7fc00001` gives
               NaN and packing that back gives `7fc00000`. So it fails
               the encode-matches rule and `Tlv::Unknown` keeps it
               whole. Measured on 2026-11-01, where 0, -0, both
               infinities and the canonical NaN are all exact. **This
               was found by probing before writing the class**, which
               is the only reason the comment is a measurement rather
               than a guess.
             * **A claim part 5a wrote was wrong and this part
               disproved it.** `docs/bgp-ls.md` section 11 said GoBGP
               sends Table 8's TLVs, so part 5b would give that
               measurement more to say. It does not: the one TLV GoBGP
               puts in the attribute is **1101**, the Adjacency SID of
               RFC 9085, which is in no table of RFC 9552. The claim
               was an inference from the attribute being present, and
               a claim about what a router sends is a measurement like
               any other.
             * **Coverage found a real gap rather than a cosmetic
               one.** Nine lines were uncovered and one was
               `Srlg#parse`: every other class here had a case that
               parsed it from octets and the SRLG had none, so its
               whole wire path was untested. The other eight were
               refusals and a `to_s`.
             * **Two of thirteen sabotages passed, and both found a
               dead constant rather than a weak test.** Setting
               `Unreserved_bandwidth::PRIORITIES` to 1 passed the
               whole suite, because nothing read it; setting
               `Srlg::WIDTH` to 2 passed too, because the 4 octets of
               an element are what `pack('N*')` is and the constant
               only moved a truncation boundary that `unpack` already
               enforced. **Both were a second statement of a fact the
               pack format already made**, which is the drift shape
               this file records for a document beside a table. The
               fix is not a test: `Srlg::WIDTH` is gone, both `parse`
               methods consume the whole value and let `unpack` group
               it, and `PRIORITIES` earned a reader, `full?`, which
               answers whether the value carries section 3.6's eight
               and which a test asserts both ways. So a sabotage that
               passes is worth reading twice: here it was neither a
               miss nor a weak test but a constant with no job.
             * **The load order trap, third time in this family and
               now predictable.** Three cases compare a Table 8 class
               against its Table 6 counterpart, since `Text_tlv` and
               `Opaque_tlv` each serve one of each, so the test needs
               the node attribute file and the source does not. The
               shape to expect: a cross-table claim needs the other
               table's file in the test.
             * **Four guards fired and all four were re-pointed.** The
               shared-bases table gained `Float32_tlv` as a
               single-table base, the forward-looking Tables-8-and-10
               guard became a Table-10 one, the code point table's
               thirteen rows went to yes, and the five-widths guard
               now asserts **the width beside the citation**, which is
               the half that matters: 1091 at 32 and 1093 at 2 are
               what memory gives as 4.
         * **Five of Table 8's widths read first hand on 2026-11-01,
           and two are not what memory gives.** 1091 Unreserved
           bandwidth is **32 octets**, not 4: RFC 5305 section 3.6 is
           "eight 32-bit IEEE floating point numbers", one per setup
           priority 0 to 7, priority 0 first. And 1093 Link Protection
           Type is **2 octets**, RFC 5307 section 1.2, a protection
           capability octet then one the section says "SHOULD be set
           to zero by the sender, and SHOULD be ignored by the
           receiver", which is keep and echo. The other three are 4
           each: 1088 a bit mask (section 3.1), 1089 and 1090 single
           IEEE floats (sections 3.4 and 3.5). **The units are "bytes
           (not bits!) per second"** in all three bandwidth sections,
           which is RFC 10005's phrase for the Link Bandwidth
           extended community and the same trap.
           * **RFC 5305 fetched from a search result and RFC 5307
             refused when its URL was reached by editing that path**,
             one call later. That is the allowlist rule in Rules for
             agents met again: search first and fetch a result link,
             every time, not once per session.
         * **Three of RFC 9552's own link attribute TLVs carry
           reserved bits**, so 5b-ii is where this family's
           keep-and-echo rule gets most of its work. 1094 MPLS
           Protocol Mask is `|L|R| Reserved |`, so `DEFINED_BITS` is
           0xc0 and "The bits that are not defined MUST be set to 0 by
           the originator and MUST be ignored by the receiver"; 1093's
           second octet, above; and **1095 IGP Metric in its 1-octet
           form**, where "IS-IS small metrics are 6 bits in size but
           are encoded in a 1-octet field; therefore, the two most
           significant bits of the field MUST be set to 0". 1095 is
           also the only variable-width TLV in the family whose widths
           are an enumeration rather than a multiple: 1 for IS-IS
           small, 2 for OSPF, 3 for IS-IS wide.
         * **5c, Table 10. Done**, in
           `bgp/nlris/link_state_prefix_attribute.rb`: the **six**
           prefix attribute TLVs, 1152 to 1157, so **every attribute
           TLV RFC 9552 defines is in**, all 25 code points across its
           three tables. All six round trip through their own hash and
           all are in the catalog. Section 5.3.3 was read first hand.
           * **Table 10 has a Length column and five of the six widths
             are stated twice**, by the table and by the section, and
             they agree. That is the opposite of Table 8, where not one
             of fifteen rows carries a width, so 5c needed no outside
             document for a width: RFC 5130 and RFC 5305 are cited as
             the origin of the fields rather than as the only statement
             of their size. Worth knowing before planning this part
             from Table 8's experience.
           * **The sixth is 1156 and the table and the section
             disagree.** Table 10 says 4; section 5.3.3.5 says "The
             length is 4 for an IPv4 forwarding address and 16 for an
             IPv6 forwarding address" and Figure 29 says "Forwarding
             Address (variable)". The prose and the figure agree
             against the table, which is the reading bgp4r follows, and
             no erratum covers it. **The guard on it used to assert the
             document's prose only, which is weaker than it looks**:
             the phrase was one this guide's own author controls, so
             rewording section 10c failed the guard with nothing about
             the claim changing. It asserts the library too now, which
             is the half a reader cares about.
           * **A width that is neither 4 nor 16 is not an
             `Ospf_forwarding_address`**, which is `Addr_tlv`'s rule
             and right here for the reason part 3 recorded there: the
             class is a claim about meaning. One holding eight octets
             and no readable address would claim bgp4r read a
             forwarding address and found none in it, where
             `Tlv::Unknown.new(1156, octets)` claims only that these
             are the octets of TLV 1156. **That is not the length check
             section 8.2.2 forbids**: nothing is reported either way,
             so only the class differs. The first draft of the class
             had the opposite and its own comment said so, which is how
             it was caught: the comment promised a kept off-width value
             and the dispatch sent it to `Unknown`, so one of the two
             was wrong and the comment was.
           * **It is `Addr_tlv`'s shape with a set of widths and not a
             subclass of it.** Generalising `WIDTH` to a set for one
             caller is the anticipation phase 1 warns against, and the
             two differ in the empty form as well: `Addr_tlv` with no
             arguments builds the all zeroes address of its own width
             and this has no width to pick, so there is **no empty
             form** and `new('0.0.0.0')` is the explicit route. Fourth
             place in the library where a width alone says which family
             a field is, after EVPN's IP Prefix route, EVPN route type
             2's Label2 and MCAST-VPN's Originating Router.
           * **`Int_list_tlv` came out of `Srlg`**, because 1153 is a
             4-octet integer list and 1154 an 8-octet one and 1096 is
             the same shape: three subclasses across two of the RFC's
             tables, which is the line part 5b-i drew for where a base
             lives. **Its `PACK` is the only place each element width
             is stated**, which is part 5b-ii's dead-constant finding
             applied up front rather than after a sabotage: the `WIDTH
             = 4` that `Srlg` carried beside its `'N*'` said the same
             thing twice and nothing read it. A doc guard asserts the
             base reaches both tables, so a later part that leaves it
             serving one fails and says to move it back.
           * **1154 is the family's only 64-bit field**, so it is the
             one place `'Q>*'` appears and the whole reason the base
             takes its pack code from the subclass. A tag below 2^32
             encodes the same either way, so the test and the catalog
             recipe both use one above it: that is the only assertion
             that cannot pass against the narrower code.
           * **An absent 1155 means something, which no other TLV in
             section 5.3 does.** Section 5.3.3.4: "If not present, it
             means that the prefix is advertised without any
             reachability." Nothing in bgp4r acts on it, since it never
             computes reachability, and section 8.2.2 forbids reporting
             a mandatory TLV absent in any case. Its "may only appear
             once" in the same sentence is a sender's rule bgp4r does
             not enforce, per Conventions, and the attribute's hash is
             a list so there is somewhere to put the second.
           * **Table 11 gives no bit numbers**, where Table 7 does for
             the node flags, so Figure 25's `|D|N|L|P|       |` is the
             only statement of 1152's bit placement there is. Nothing
             cross-checks it, which is the opposite of 1024, where a
             figure and a table disagreed and erratum 7789 settled it.
             The masks are asserted against the figure's order rather
             than against a round trip, which passes whenever encoder
             and decoder share a reversal.
           * **An assertion that looked right and was not:
             `assert_raise(ArgumentError)` fails on
             `IPAddr::InvalidAddressError`**, which is an
             `ArgumentError` by ancestry, because test-unit matches the
             exact class. So the refusal satisfied the rule and the
             test said otherwise. `assert_raise_kind_of` is what says
             what the rule means, which is that a class refusing an
             input it cannot read answers an `ArgumentError` descendant
             and not a `TypeError` or a `NoMethodError`.
           * `Prefix_metric` is left off that case, as the two
             `Opaque32` subclasses in part 5b-ii's equivalent are:
             `Opaque32#coerce` is `v.to_i` and opaque is the RFC's own
             word for the shape, so it takes anything answering `to_i`.
             Not reachable from a hash or from the wire, since both
             hand it a number.
           * **Coverage found one unreachable line and it is kept**,
             the way `Fib`'s `:no_next_hop` branch and
             `Rt_constrain#origin_as`'s length guard are:
             `Ospf_forwarding_address#coerce` refuses a width outside
             the section's two, and `IPAddr` has two families whose
             `hton` is 4 octets or 16, so the check cannot fire. It
             stays because it is the sentence `Addr_tlv#coerce` makes
             where it **is** reachable. `parse` is where an off-width
             value really arrives.
           * **The load order trap, fourth time in this family**, and
             now in both directions at once: one case compares a Table
             10 class against its Table 8 counterpart and another spans
             all three tables, since the Opaque envelope has a row in
             each, so the test requires two files the source does not.
           * `test/functional/link_state_test.rb` gained the case that
             sends all six beside a **Prefix** NLRI, which is the
             pairing section 5.3.3 names and the only attribute case
             there whose NLRI is a prefix. A hand-written expectation
             was wrong in it, the seventeenth across these families:
             `Link_state` is the NLRI and `#nlri` is the typed layout
             inside it, so the type assertion goes one level down.
           * **Seventeen sabotages: fifteen landed, one was a real
             finding and one the registry refusing at load.** The
             finding is the width check above. The load failure is
             `Igp_route_tag` given `Igp_extended_route_tag`'s hash key,
             which `register` refuses so the suite dies on the require:
             that is the duplicate-key guard working rather than the
             claim, which part 2 met from the type-number side, and the
             right reading of it is that the registry is what enforces
             one key per class.
             * **A second load failure was the sabotage's own fault and
               is worth separating from that one.** Moving
               `Int_list_tlv` out of the framing file and into
               `link_state_prefix_attribute.rb`, to check the placement
               guard, put it **after** `Srlg`'s use of it in require
               order, so every test errored on the require and nothing
               about placement was measured. Moved into
               `link_state_descriptor.rb` instead, which `nlris.rb`
               requires before the link attributes, it fails exactly
               `test_each_shared_base_is_defined_with_the_framing`.
               **So a sabotage on where a shared class lives has to
               keep it loading before its first user**, or it tests the
               require order it just broke.
             * The fifteen, each on what it was aimed at: the four flag
               masks reversed fails 4; `'Q>*'` changed to `'N*'` fails
               5 and the functional case; `WIDTHS` reduced to Table
               10's single 4 fails 2 and errors 2; `DEFINED_BITS`
               widened to 0xff fails 3; 1155's type number moved fails
               9; 1152's and 1157's swapped fails 10; the base moved
               fails the placement guard; the base given a `TYPE` fails
               the shared-bases guard; `Srlg` given a `WIDTH` beside
               its `PACK` fails 2; the list parse keeping its trailing
               partial group fails the three wire cases; the width
               refusal's message removed fails 1; a document table row
               flipped to no, and the document's own 1156 row changed
               to 4, each fail their discovery guard; the
               `Int_list_tlv` row cut from `NO_RECIPE` fails the
               catalog coverage guard; and the attribute not sent
               beside the prefix NLRI fails the functional case.
         * **The three tables hold 28 rows and 25 distinct new code
           points**, counted from the document rather than added up.
           Table 6 lists 7 and one of them, 263, is already in from
           part 3. Table 8 lists 15 and two of them, 1028 and 1029,
           are Table 6's rows again, because a local Router-ID is a
           node attribute and a link attribute both. Table 10 lists 6
           and all are its own. **`docs/bgp-ls.md` said "1024 to 1031
           node, 1088 to 1098 link, 1152 to 1157 prefix", which is
           wrong about the first range**: 1030 and 1031 are link only.
           The total was right.
         * **This is where the flat registry pays for itself**, which
           part 2 recorded as IANA's doing rather than a
           simplification. TLV 263 is in Table 4 and Table 6 both, and
           it is registered once and already works in both places. So
           the attribute reuses `Tlv.parse_list`, `Tlv.from_hash`,
           `Tlv.ordered?`, `Opaque32` and `Addr_tlv` whole, and 5a is
           an attribute class plus six values rather than a second TLV
           layer.
         * **Table 8 has no Length column at all**, which is part 3's
           Table 4 situation exactly and is worse than this entry first
           said. It was written as "five of Table 8's widths are not in
           RFC 9552", corrected on reading the table: where Table 6 and
           Table 10 each give a Length, Table 8 gives an "IS-IS
           TLV/Sub-TLV" column instead, so **not one of its fifteen
           rows carries a width**. Five of them have no width anywhere
           in RFC 9552: 1088 Administrative group cites RFC 5305
           section 3.1, 1089 Maximum link bandwidth section 3.4, 1090
           Max. reservable link bandwidth section 3.5, 1091 Unreserved
           bandwidth section 3.6, and 1093 Link Protection Type RFC
           5307 section 1.2. The other ten are in RFC 9552's own
           subsections or in Table 6. Read each in the document that
           gives it and put the citation beside the class, because a
           wrong width among the five cannot be caught by reading RFC
           9552 at all.
         * **Table 10 disagrees with its own section about TLV 1156,
           and no erratum covers it.** The table's Length column says 4
           for the OSPF Forwarding Address; section 5.3.3.5 says "The
           length is 4 for an IPv4 forwarding address and 16 for an
           IPv6 forwarding address" and its figure says "Forwarding
           Address (variable)". So the prose and the figure agree with
           each other against the table, which is the reading 5c
           follows. Checked against the errata on 2026-11-01: the two
           verified ones are 7789 and 8766 and neither is this. **Third
           self contradiction in this document**, after the Node Flag
           Bits figure and Table 8's missing widths, which is worth
           knowing before trusting any single table of it.
         * **Erratum EID 7789 is this family's second self
           contradiction and it lands in 5a.** Figure 15 prints the
           Node Flag Bits as `|O|T|E|B|R|V|` where Table 7 of the same
           section defines O Overload, **A Attached**, E External, B
           ABR, R Router and V V6. Confirmed in the text on
           2026-11-01. So bit 1 is A and the figure's T is the error,
           which the erratum settles. Same shape as RFC 8956's wrong
           flow spec vector: read the errata before explaining a
           document disagreeing with itself some other way.
         * **The attribute's TLV ordering rule is a SHOULD and its
           breach is explicitly not malformed**, where the NLRI's is a
           MUST. Section 5.1 says both. So the attribute reports
           through `Tlv.ordered?` and refuses nothing, which is what
           that method was written for. Part 7 measured GoBGP breaking
           the NLRI's MUST on traffic it originates itself, so do not
           read either rule off a router.
         * **The attribute class goes in `bgp/path_attributes/` and
           its TLV classes stay in `bgp/nlris/` with the family.**
           One flat registry means one class family, and a family
           lives in one place: a node attribute TLV file reopens
           `BGP::Link_state::Tlv` beside the descriptor files. The
           alternative, a second TLV namespace under the attribute,
           would need a second registry and would make TLV 263 two
           classes.
      6. **Validation. Done**, in two pull requests, 6a the action
         vocabulary and 6b the ten checks. `docs/bgp-ls.md` section 8
         is the guide and has a table of the checks the doc test
         discovers from `validation.rb`. What the section says:
         * **Every check is syntactic.** Two MUST NOTs open the
           section: neither the NLRI nor the attribute may "be
           considered malformed or invalid based on the
           inclusion/exclusion of TLVs or contents of the TLV fields
           (i.e., semantic errors)". **Seven syntactic NLRI checks** are
           listed, and three attribute ones of the same shape.
         * **And a list of checks it says not to make**, which narrows
           this part further than any other family's: a BGP-LS
           Propagator "should not perform semantic validation", with
           the presence of a mandatory TLV, whether a fixed-length
           TLV's length is correct, whether field values are
           permissible, and whether a TLV is valid with a given NLRI
           type all named as examples. **bgp4r writes checks of all
           four shapes for EVPN and MCAST-VPN**, so this is an
           instruction not to rather than a gap to fill.
         * **Two things bgp4r has never done, and reading RFC 7606
           first hand settled both.** They are why this part is **two
           pull requests, 6a and 6b**, the way 5b was split: 6a is the
           action vocabulary alone and 6b the ten checks on top of it,
           so the checks land against machinery that is not moving
           under them. That is #125's and #156's shape, and 5b-i's.
           * **`ACTIONS` is missing one of RFC 7606 section 2's
             four.** Section 2 lists them "from the one with the
             'strongest' action to the one with the 'weakest'":
             session reset, **AFI/SAFI disable**, treat-as-withdraw,
             attribute discard. bgp4r has the other three in exactly
             that relative order, reversed, since `strongest` is
             `max_by` over the index. So `:afi_safi_disable` goes
             between `:treat_as_withdraw` and `:session_reset` and
             nothing else moves.
           * **`NLRI discard` is not one of section 2's four at all**,
             which is the finding that matters. Section 2 is about
             **attributes**; 9552 section 8.2.2 calls NLRI discard
             "processing similar to what is described in Section 5.4
             of [RFC7606]", and **section 5.4 is "Typed NLRI"**,
             about discarding one unrecognized typed NLRI and carrying
             on. So it is per-NLRI where every action bgp4r has is
             per-attribute, and `Attr::Finding`'s granularity is the
             attribute. 6a adds it and **records the granularity gap**
             rather than pretending it is not there: the Finding says
             the attribute carries a malformed NLRI and the reason
             names which, and a caller that wants to act per-NLRI
             reads the reason.
           * **Where it sits in `ACTIONS` is a decision and not the
             RFC's**, so record the mechanism. Section 2 does not rank
             it, since it is not in section 2. What 8.2.2 does say is
             that it is the case where the router "continue[s] the
             processing of the rest of the BGP UPDATE message", which
             is the property section 2 gives attribute discard, so
             both are continue-actions and neither escalates. It goes
             **first**, weakest, because it loses one NLRI where
             attribute discard loses every TLV of an attribute.
           * **A Finding whose action is not in `ACTIONS` crashes
             `strongest`**, since `ACTIONS.index` answers nil and
             `max_by` then compares nil. So the two have to be added to
             the list and not only used, and that is what makes 6a
             worth landing on its own. A test pins the crash, so the
             next action added to a Finding alone fails there rather
             than in whatever reads the findings.
           * **`Neighbor` acts on `:session_reset` by name**, in
             `bgp/neighbor/neighbor.rb`, so neither new action resets a
             session and neither should: 8.2.2 reaches session reset
             through its own branch, below.
           * **Six sabotages, all landing, and two say more than their
             assertions do.** Dropping `:nlri_discard` from the list
             while keeping the constant **errors** rather than fails,
             which is the nil-compare crash above demonstrated instead
             of argued. And reordering the three older actions fails
             `test_strongest` and `test_malformed_attribute`, **tests
             that predate this change**, which is what says the
             insertion moved neither: had it, those two would have
             caught it. The other four: `:afi_safi_disable` put below
             treat-as-withdraw, `:nlri_discard` made the strongest, the
             FSM keyed on `:afi_safi_disable`, and the guide's 6a
             heading removed.
           * **bgp4r cannot choose between AFI/SAFI disable and session
             reset**, because 8.2.2 keys it on whether other AFI/SAFIs
             are up on the session and `Attr::Check.attribute` is
             handed one attribute at a time. **That is not a gap to
             paper over: the RFC provides the branch.** "Alternately,
             the router MUST perform a 'session reset' when the session
             is only being used for BGP-LS or if 'AFI/SAFI disable'
             action is not possible." Not possible is bgp4r's case, so
             session reset is the RFC's own answer and not a guess, and
             it is what bgp4r already reports for a malformed MP_REACH.
             `:afi_safi_disable` is still added, since a caller with
             session state may want it and the vocabulary is
             incomplete without it.
         * **Do not invent a subcode**, the trap flow spec part 4, EVPN
           part 9 and MCAST-VPN part 6 each recorded. This is the one
           family whose own RFC names the actions outright, so there is
           less excuse here than in any of them.
         * **What 8.2.2 forbids, bgp4r already does not do, and that is
           worth knowing before writing a check.** Its forbidden list
           includes "the length of a fixed-length TLV is correct", and
           part 5c's 1156 is exactly that case: a width that is neither
           4 nor 16 becomes a `Tlv::Unknown` and **nothing is
           reported**. So the keep-and-echo design satisfies the
           instruction by construction. The syntactic check 8.2.2 does
           ask for, "The length of the TLVs ... are valid", is about the
           length field being consistent with its framing, not about
           matching a class's expected width. **Those two sound alike
           and are opposite**, and getting them the wrong way round
           would make bgp4r report what the section forbids.
           * **A functional case written four parts earlier turned out
             to be the guard for three of the four forbidden shapes.**
             `test_an_nlri_no_rfc_allows_crosses_a_session` sends a
             Node NLRI with no Local Node Descriptors, a Protocol-ID of
             0 and a prefix descriptor inside a Link NLRI, and asserts
             zero findings. That zero is the instruction and not an
             absence of coverage, which the case now says.
         * **6b, the ten checks. Done.** Eight `Finding` sites answer
           the ten bullets, because several of them describe one walk
           from a different angle: a Length that overruns its container
           breaks the sum of the lengths **and** is an invalid length,
           so NLRI bullets 3 and 4 are one loop and the attribute's 1
           and 3 are that same loop reached from the attribute, with
           the action the only difference. The guide's table is one row
           per site and `bgp_ls_doc_test.rb` counts `Finding.new` in
           the BGP-LS block against it.
           * **The block sits at the end of `Check` and not beside the
             families it resembles.** Two sibling doc tests slice
             `validation.rb` by method name and count `Finding.new`
             between the markers: EVPN from `def evpn_finding` to `def
             nonzero?`, MCAST-VPN from `def
             mcast_vpn_next_hop_finding` to `def
             flow_spec_component_size`. A BGP-LS check in either window
             is counted as that family's and fails its guard. MCAST-VPN
             part 6 recorded the same thing about the EVPN window one
             family earlier, so this is the second time and it is now
             written where the block starts.
           * **`BGP_LS` is three numbers and this module sees the wrong
             one.** `ATTR::BGP_LS` is 29 and `include ATTR` is in
             effect in `Check`, so a bare `BGP_LS` is the attribute
             code; `IANA::AFI::BGP_LS` is 16388 and
             `IANA::SAFI::BGP_LS` is 71. `iana.rb` warns about the
             first two sharing a bare name and there is a third here.
           * **The whole NLRI set runs on MP_UNREACH too**, which no
             earlier family does: EVPN's and MCAST-VPN's route checks
             are MP_REACH only. Bullets 1 and 2 name MP_REACH_NLRI and
             MP_UNREACH_NLRI in two sentences of one shape and the rest
             are about the NLRI, which is the same object in either, so
             `link_state_finding` takes no `reach` argument at all.
             Only the next hop is MP_REACH's alone.
           * **The actions come from 8.2.2's criterion and not from its
             parenthetical, and the two disagree.** The criterion is
             whether the error "allows for the router to skip the
             malformed NLRI(s) and continue the processing of the rest
             of the BGP UPDATE message"; the example of the other case
             is "length-related encoding errors". While each NLRI's
             Total NLRI Length lands inside the attribute every other
             NLRI is locatable, so the error is skippable, and a TLV
             Length overrunning one body is length-related and still
             skippable. Both of the section's own examples fall out of
             the criterion, so read the sentence rather than the
             brackets.
           * **Every attribute finding is attribute discard**, because
             the non-skippable attribute case is its own length against
             the Path Attribute Length and `next_attribute` and
             `attribute` answer that for every attribute already.
           * **The next hop check is in scope here and the citation is
             a chain of three**, which puts BGP-LS between MCAST-VPN,
             where RFC 6515 states the error itself, and EVPN and
             RT-constrain, where nothing points at RFC 7606 for it.
             Bullet 5 asks that "the syntactic correctness of the NLRI
             fields has been verified as per [RFC7606]", RFC 7606
             section 7.11 carries the rule and leaves the expectation
             to the family, and section 5.5 states it. The one reading
             it rests on is that "the NLRI fields" means the
             MP_REACH_NLRI attribute's fields and not only the
             Link-State NLRI's own: bullets 1 and 2 name the attribute
             and its length, and under the narrow reading bullet 5
             would say nothing bullets 3 and 4 do not.
           * **Section 5.2.1.4's sub-TLV ordering MUST is not in
             8.2.2's list, and that is what keeps the only router that
             can originate BGP-LS conformant.** Bullet 6 cites section
             5.1, whose rule is "all TLVs within the NLRI"; 5.2.1.4
             states a separate ascending-order MUST for a Node
             Descriptor's sub-TLVs, and 8.2.2 takes only the other half
             of that section, bullet 7's once-only rule. That it picked
             one of the two is what says its authors had the section
             open and chose. So part 7's measurement, that GoBGP 3.23.0
             sends 512, 516, 513 on every route it originates, and part
             6b's checks agree with **neither moving**, which is the
             outcome taking part 7 early was for. Its two lab
             assertions are unchanged.
           * **Section 5.1's own ordering rule has a scope qualifier
             and 8.2.2 settles it.** 5.1 says unordered NLRI TLVs "MUST
             be considered as malformed by a BGP-LS Propagator", and
             bgp4r propagates no BGP-LS so it would not be one. 8.2.2
             introduces its list with "A BGP-LS Speaker MUST perform
             the following syntactic validation" and puts the ordering
             rule in it. Speaker, not Propagator, in the fault
             management section, so the check is in by the document's
             word rather than by a reading. This file recorded the
             qualifier as wanting a decision; it wanted a second
             sentence of the same document.
           * **The sub-TLV half of the attribute's bullet 3 has no
             reachable case.** The Node Descriptors, 256 and 257, are
             the only recognized TLVs in this family that carry
             sub-TLVs, and no attribute TLV of RFC 9552's three tables
             carries any. So "when the TLV is recognized" descends only
             inside an NLRI.
           * **A functional case was sending an NLRI no RFC allows and
             the ordering check found it.**
             `test_an_unknown_tlv_inside_an_nlri_crosses_a_session` put
             TLV 255 after TLV 256, breaking section 5.1's MUST while
             asserting no protocol error. The octets move, every
             assertion stays, and the unordered case gets a test of its
             own. Third time this has happened: EVPN part 9 found the
             same thing with RFC 9136 section 3.2, and it is the
             argument for writing a check at all, since a suite that
             only sends what it means to send cannot tell you whether
             it did.
           * **Eighteen sabotages, all landing**, five on the wiring,
             seven on the checks and six on the document. Three of the
             four new doc guards were wrong before they were right and
             each failure named the tree while the fault was the guard:
             `/x` free-spacing **ate the literal spaces inside `nlri
             discard`** so the table parsed as empty, a first cell
             starting with a capital letter missed the `[a-z]` anchor,
             and a phrase straddling a line break needed `\s+`. The
             floor assertions are what turned the first into a loud
             failure rather than a vacuous pass, which is why they are
             asserted before the count.
      7. **The lab. Done**, in #220, and taken **before** part 6
         because what GoBGP does decides which checks are worth
         having, which is what flow spec part 5 and EVPN part 10 both
         found and what it found again here.
         `test/functional/lab/link_state_gobgp_test.rb`, 12 cases and
         122 assertions in 87 seconds, and `link_state_frr_test.rb`,
         3 cases and 24 assertions in 6. No Docker. It was 119 in 85
         until part 5a re-pointed its attribute case, which is the
         ordinary reason a count here moves. **Those figures were
         wrong twice before that**, and both ways are worth knowing
         because CLAUDE.md asks for counts copied out of a run and
         both of these were. First 126 and 124, from a run with two
         cases failing and waiting out their 30s timeouts: a timing
         taken from a red run measures the timeouts and not the work.
         Then 118, from a green run of a version of the file that was
         two assertions shorter, so the count was a measurement of
         something that no longer existed. **Re-measure after the last
         edit, not after the last green run.**
         `docs/bgp-ls.md` section 11 has the measurements and the
         table.
         * **The first lab test here where the router encodes the
           family under test**, which is what the plan promised. Every
           lab test since flow spec sends only and records that caveat
           in its own comments. GoBGP can originate a BGP-LS route, so
           its own octets feed bgp4r's decoder: the head of figure 8
           with its Protocol-ID and Identifier, both node descriptors,
           five of the six link descriptors and the 4-octet next hop
           of section 5.5, all read from octets this reader did not
           write.
           * **Be exact about that first**, because
             `attr_set_gobgp_test.rb` is the nearest precedent and is
             not this: its far speaker parses an UPDATE GoBGP built,
             so the ORIGIN, AS_PATH, next hop and NLRI are GoBGP's,
             but attribute 128, the thing under test, is copied
             verbatim and never parsed by the router. Here GoBGP
             builds the NLRI itself.
         * **The client's grammar, since nothing documents it.**
           `gobgp global rib add -a ls link` wants **sixteen** keyword
           and value pairs, not the 26 tokens its own error names,
           which is a minimum: every pair is read without a presence
           check, so leaving one out is an error rather than a
           default. `node` and `prefix` are refused outright, so NLRI
           type 2 is the only one it can be made to originate.
           `LINK_ARGS` in the test has the list. Found by reading
           `cmd/gobgp/global.go` at the tag after probing the error
           messages got as far as 23 tokens.
         * **The keep-and-echo MUST of section 5.1 met real traffic
           for the first time.** GoBGP sends sub-TLV **516**, the BGP
           Router Identifier of RFC 9086, which part 2 left out
           because Table 3 is RFC 9552's, and the NLRI still replays
           byte for byte with no protocol error and no coverage gap.
           The BGP-LS Attribute arrives too and comes back as an
           `Attr::Unknown` with neither, which is #116 one level up
           and what part 5 gives meaning to.
         * **A library bug the measurement found: Protocol-ID 7 read
           as Unassigned.** `Headed::PROTOCOLS` carried **Table 2** of
           section 5.2, 1 to 6, where the IANA registry has nine: 7
           BGP from RFC 9086, 8 RSVP-TE from a draft and 9 Segment
           Routing from RFC 9857. GoBGP originates with 7. Nothing in
           the library turns on a Protocol-ID, so this was a wrong
           answer about a correct router in `to_s` and nothing worse,
           which is still the thing this file most wants not to give.
           **Read the registry and not a table in the document that
           asked for it**, which `docs/bgp-ls.md` section 4 already
           said one paragraph above the row that was wrong.
         * **Two faults in GoBGP 3.23.0, recorded and not filed**, per
           the standing decision. Both deterministic and both
           asserted, because a lab test that quietly sends only the
           shape that works is the unchecked claim this file keeps
           getting burned by.
           * **It requires a sub-TLV RFC 9552 does not, and refusing
             it costs the whole family.** Every node descriptor must
             carry either an IGP Router-ID or both a BGP Router-ID and
             an Autonomous System, whatever the Protocol-ID; one
             holding only an Autonomous System is answered with
             "Required TLV missing" and `Capability was disabled`.
             Section 5.2.1.4 makes the IGP Router-ID mandatory **when
             originating** from IS-IS, OSPF, Direct or Static
             configuration, names no receiver action, and calls the
             Autonomous System optional. **Section 8.2.2 names
             "presence of a mandatory TLV" among the semantic
             validations a BGP-LS Propagator should not perform.**
           * **Its client panics rendering an IP Reachability TLV
             whose prefix is more than one octet**, `index out of
             range [1] with length 1` in `ToIPNet`. The daemon stores
             the route either way and a /8 renders, so it is the
             renderer; /16, /24 and /32 all panic. That is why the
             send-direction prefix case uses a /8.
         * **What it decided for part 6, which is why it came first.**
           GoBGP's own node descriptors are **not in ascending
           sub-TLV order**, 512 then 516 then 513, where section
           5.2.1.4 says they MUST be. bgp4r reports the order through
           `Node_descriptors#ordered?` and refuses nothing, so the
           route parses and replays. So the only router available here
           breaks a rule bgp4r could check, on traffic it originates
           itself, **and** makes a check section 8.2.2 forbids. Both
           point one way: part 6 follows the RFC and not the router.
           One router agreeing is not a quorum, and this one disagrees
           with the document in both directions at once.
         * **FRR 8.4.4 has neither SAFI**, so its file measures an
           absence, which is `mcast_vpn_frr_test.rb`'s shape. One
           thing reads differently from that family and is asserted
           rather than assumed alike: for SAFI 5 FRR logged
           `afi/safi: IPv4/unknown`, naming the AFI, where AFI 16388
           is outside its table too, so it logs **`bad-value/unknown`**
           and can name neither half. A BGP-LS UPDATE sent anyway
           gets the MCAST-VPN answer: `Attribute MP_REACH_NLRI, parse
           error`, the whole UPDATE failed, the session reset with no
           NOTIFICATION, and FRR back within a second or two. So the
           two routers part company again, from a different starting
           point: there neither had the family, here one does.
         * **What the receive direction cannot check, measured by
           sabotage rather than argued.** GoBGP originates one NLRI
           per UPDATE, and the only NLRI in an attribute has nothing
           behind it to over-read into, so `Link_state.nlri_size`
           wrong by a constant leaves **every** receive case passing.
           That is RT-constrain's lesson arriving from the other side,
           and it is why the multi-NLRI cases in
           `test/functional/link_state_test.rb` must not be thinned
           out: they are the only cover the parse-side framing has.
           The send direction does catch it, because GoBGP reads the
           length and a wrong one sends the UPDATE to RFC 7606 rather
           than to its RIB.
         * **Ten sabotages, eight landing first time and two
           missing**, and both misses are #205's shape again. One
           inserted `def ordered? ; true ; end` at the top of the
           class, where the real method later in the same class
           overrode it, so nothing changed: patch the method body, not
           the class. The other dropped `Tlv::Unknown`'s octets and
           made the case **error** on a missing method rather than
           fail on its own claim, because the NLRI then failed
           `read_route`'s encode-matches rule and came back as a
           `Link_state::Unknown`; the case asserts the route type
           first now, so the failure names the claim. The eight:
           Protocol-ID 7 dropped from the table, `coerce` back to
           `pack('H*')` (which fails the node case against GoBGP's own
           rendering, so part 4's fix is now checked from outside),
           `Tlv.ordered?` stubbed true, the required-TLV case given a
           conformant descriptor, the panic case given a /8, the
           capability not offered to FRR, the FRR reset case sending
           SAFI 1, and the send-side Total NLRI Length one short.
         * `gobgp-families` is **399s** now, measured rather than
           added up, and 3.2 times the next group, where
           `test/lab_groups.rb` called splitting "the obvious next
           lever" at 291s. The rule stays the rule, so the file went
           in that group; the note there says the split is overdue and
           that the obvious cut is by direction.

Decisions taken before this starts, so they are not re-litigated:

* **No new family goes in a RIB.** `BGP::Rib::Route` keys on the prefix
  and the Path Identifier, and a flowspec rule or an EVPN route is not a
  prefix. This is the same decision already recorded for SAFI 4, 128 and
  129 in part 3 of RIB phase 2, and it holds for the same reason: it is a
  change to `Route`, the decision process and all three show commands, so
  it is its own piece of work. Breadth on the wire is what a protocol
  testing tool needs. A Loc-RIB of EVPN routes is a different product.
* **The measure of each phase is the wire, not the table.** A family is
  done when bgp4r can parse a capture in it, replay that capture byte for
  byte, and build one from field values that no RFC allows. Not when it
  can route it.
* **What breadth buys over what #116 already gives** is the thing to keep
  in view, because the octets already survive. It is meaning: reading an
  EVPN route type or a flowspec component as a value, building one from
  field values rather than from hex, and changing one field of a captured
  rule without hand editing octets. A phase that does not deliver that
  has not delivered anything, since `Attr::Raw` was already replaying the
  bytes.
* The 12 `to_hash` entries that `rake to_hash:pending` names are **not**
  part of this and are not a prerequisite. They are single field losses
  in a convenience form for test code, each with a reason recorded, and
  clearing the list to empty it is not worth a phase.

### routescope labs, a phase with no pull request yet

**`docs/routescope-labs.md` is the design**, written on 2026-11-01
against routescope `7eabde1` and ospfv2 `2dfc03a`, both read first hand.
Read it before any of this work. The short version, so the direction is
visible here:

* **routescope already speaks BGP**, and that is the finding that
  shapes the plan. Its FRR and BIRD drivers read sessions and the BGP
  table, node health counts an established session, and the front end
  has columns for both. So bgp4r is not filling a gap in its BGP
  support, and parity with FRR is not the goal.
* **bgp4r is two node kinds, not one.** `bgp4r`, a router whose Loc-RIB
  and decision a console can read, and `bgp4r-sim`, an injector and
  fault source driven by actions. The second is what no real router can
  substitute for, and routescope's own `docs/protocols.md` names the
  shape: "A BGP route injector would be one more."
* **The largest item is that the lab speaker becomes a router.**
  `lab/README.md` states the limit and `bgp/rib/` has the answer
  finished, tested and unwired: the speaker predates it. That one piece
  unblocks the best path, transit, route reflection, convergence and
  forwarding labs at once.
* **The highest-value item for a console is a JSON dump of the RIB**,
  which is already a decision recorded in this file and never
  implemented. The decision process already returns the winner, the
  step that decided it and why each other route lost, so only the
  serialisation is missing, and "why did this route win" is a question
  no other implementation in a lab can answer about itself.
* **Match ospfv2's capture contract rather than inventing one.**
  routescope runs `IMAGE capture -i IFACE` with the subcommand and the
  flag hard-coded and no filter passed, so a bgp4r image taking the
  same argv and writing the same newline-delimited JSON costs one
  environment variable instead of a change to shared code.
* Eight labs, phased, with phase 0 costing nothing: an unknown `kind`
  renders as `linux` in routescope, so a bgp4r container is useful
  there before either repository changes.
* **Section 8's porting subsection is the one part of the document that
  is not a design**, and it is where to start. The question it answers
  is which of the 23 files in `test/functional/lab/` want to become
  scenarios, and the answer is four, two of them in part, on top of
  three that already run a Compose topology. **A lab test that runs in
  CI in under a minute with no Docker is better than a scenario in every
  way a maintainer cares about**, so a port needs a reason: more than
  one receiver reading the same octets, an action after the session is
  up, or a degraded link while traffic flows. The worked example is
  `lab/topologies/add-path`, and what it cost is recorded there.
* **Section 9 is `bgp4r-sim` in detail**, which is the part to read
  before building anything: the three config files that bring a session
  up, the twelve actions, the four scenario conditions and three worked
  scenarios. Its shape is `Drivers::Sim`'s, an HTTP API on the
  container's loopback reached by `docker exec`, and **its action body
  keys are the node file's own keys**, so the injector's vocabulary is
  bgp4r's configuration vocabulary at runtime rather than a second
  language. Two decisions there carry the most weight: an injector
  **starts silent**, with no `announce:` block, because a baseline the
  config created is one no assertion can rest on; and if it ships
  without `fault` and `replay` it is a worse FRR, since those are the
  two things no real router can be told to do.
* **The injector is phase 5 and not phase 1**, which section 10 says
  plainly because section 2 calls it the thing that justifies the work.
  It needs the structured event stream or its pane shows nothing, the
  action API, which is the largest piece of new bgp4r surface in the
  document, and the router kind, because every scenario asserts against
  something that holds a RIB.

The document's section 12 says what it does not assert and when each
claim becomes assertable, because every fact in it about those two
repositories is a read at a commit and this suite cannot check one. It
also records one claim that was wrong in its first draft and corrected
in place, `partial_lsdb?`'s consumer, with the lesson: when reading
another repository, read the consumer and not the definition.

### Vendor style `to_s`, a phase with no pull request yet

Recorded on 2026-11-01 by the owner, who said it was the thing the
original plan missed: the plan's emphasis was on `initialize` and
`to_hash` and said nothing about `to_s`. The idea is that `to_s` should
be able to offer **several representations of one object**, so an
attribute, an NLRI or a whole UPDATE can print the way a Cisco router
shows it or the way a Junos router does.

**There is already a precedent and it is only half the job.**
`bgp/rib/show.rb` does exactly this for the Loc-RIB: `rib.show`,
`rib.show(:junos)` and `rib.show(:iosxr)`, three styles, with
`STYLES = %i[ios junos iosxr]`. What it does not do is objects. A
`Path_attribute`, an `Mp_reach`, an `Evpn` route type or an `Update`
each have one `to_s` and it is bgp4r's own wording. So the work is
taking show.rb's shape down a level, and the 185 `def to_s` in `bgp/`
are the scale of it.

**The design question to settle first, because it decides everything
after it.** `to_s` takes no argument today and 185 classes define one,
with tests asserting on many of them. Three shapes, and the choice is
not obvious:
* `to_s(style = nil)` on every class. Smallest to call, largest to
  write, and it changes a method signature the whole library and its
  tests already use.
* A second method, `to_vendor_s(style)` or similar, leaving `to_s`
  alone. Additive and safe, and it means two methods per class that
  mostly agree.
* A renderer object, `Show::Ios.new.render(obj)`, dispatching on class.
  One place per style rather than one method per class, which is how
  show.rb is already built, and it keeps vendor wording out of the
  protocol classes entirely. This is the one that matches the existing
  precedent, and it is the one to cost first.

**Three constraints that are already settled and must not be
reopened.**
* `to_shex` stays the canonical form for tests, `to_hash` stays the
  round trip, `to_s` stays the human form. A vendor style is a fourth
  job and is additive to the third, never a replacement for either of
  the first two. Nothing in a test should start asserting on vendor
  text where it asserts on hex today.
* show.rb's honesty rule carries down: these are **in the style of**
  those commands and not copies. Only strings traceable to a sample in
  a vendor's own documentation are quoted; everything invented prints
  bgp4r's own symbol in snake_case, so an invention cannot be read as a
  quote from a router. `:med` is deliberately not labelled "IGP
  metric" for that reason, and the same discipline applies to every
  field name a style would print.
* Nothing anywhere is diffed against a real device, so **no test may
  depend on this text byte for byte** beyond what a cited sample
  supports. That is already written on show.rb and it is the thing a
  reader of a new style will want to forget.

**Where the samples come from is the real cost**, not the code. Part 4
of RIB phase 4 records what that took for three styles of one command:
the IOS and Junos layouts came from samples in the vendors' own
documentation, the IOS-XR one waited a whole phase because the sample
could not be found, and when it was found three details differed from
IOS in ways only the sample could have told anyone. So this phase is
paced by how many commands can be sourced, and a style with no sample
behind it is not worth having: inventing a format while calling it
IOS-XR is worse than not having it.

**What it buys, so the phase has a measure.** A person reading a
capture in bgp4r sees what a router operator would see, which makes a
bgp4r session usable as a teaching and debugging tool rather than only
as an encoder. And a lab or console that renders bgp4r's state beside a
real router's output can put the two side by side, which is where this
meets the routescope work: see `docs/routescope-labs.md`.

## Known issues to work on

Found while fixing other bugs, not fixed yet. Verified against master on
2026-10-27, so each one reproduces. Reproductions are one liners with
`ruby -I. -e '...'`.

Smaller things:

* **Three families still default an octet buffer to `+''`, latent rather than broken.** `Mcast_vpn::Originating_router`, `Rt_constrain` and `Flow_spec::Component::Unknown` each do `@value = +''`, which is US-ASCII, and that is the shape that broke CI on Ruby 3.4 in #218. **None is reachable today**, measured on 2026-11-01: `Mcast_vpn::Originating_router.new.value.encoding` is UTF-8, and its `to_s` guards `when 4, 16` so an empty buffer never reaches `IPAddr`, nothing `<<` an Integer onto any of the three, and `encode` packs them so the octets are right either way. So this is a hazard and not a wrong answer, and it becomes one the day any of them grows a padding call or an `IPAddr` call. The fix is `String.new`, which Conventions explains; it is listed here rather than done because it is three other families and #218 was BGP-LS part 3.
* **The copy constructor loses an extended NLRI in four families.**
  `Klass.new(an_instance)` re-parses `an_instance.encode`, and `encode`
  writes the RFC 7911 section 3 Path Identifier in front of the NLRI
  where `parse` does not expect one, so those four octets are read as a
  type and a length and the copy is garbage. `Evpn`, `Mcast_vpn`,
  `Flow_spec` and `Rt_constrain` all have it; an unextended instance
  copies correctly in all four, which is why it went unnoticed.
  `ruby -I. -e 'require "bgp4r"; a = BGP::Mcast_vpn.new_ntop(["020c00000064000000c80001117f"].pack("H*"), 9); p [a.to_shex, BGP::Mcast_vpn.new(a).to_shex]'`
  prints the NLRI and then `"0000"`. Found while writing BGP-LS part 1,
  which takes the identifier off before the re-parse and has a test for
  it, so the fix shape is known and is two lines per family:
  `@path_id = args[0].path_id`, then `s.slice!(0, 4) if
  args[0].extended?` before parsing. Left alone there because it is
  four other families and its own topic. `bgp_ls_doc_test.rb` asserts
  the four still have it, so a fix fails that guard and says to strike
  the paragraph in `docs/bgp-ls.md` section 7.
* `Nsap.new` and `Nsap.new_nsap` disagree on the default prefix length, so the same address string gives two different prefixes depending on which constructor built it: `ruby -I. -e 'require "bgp/nlris/nsap"; p [BGP::Nsap.new("49.0102.0304.0506.0608.0910.1112.1314.1516.1718.ff").mlen, BGP::Nsap.new_nsap("49.0102.0304.0506.0608.0910.1112.1314.1516.1718.ff").mlen]'` prints `[160, 152]`. `Nsap#mlen` falls back to 160, the whole twenty octet address, where `new_nsap` writes `len ||= 152` and so masks the twentieth octet away and encodes nineteen. 160 is the one that matches the rest of the class, including `MAX_MLEN` and `prefix_mask_bits`. It was left alone when the clamp above it was fixed, because `test_new_nsap` and `test_nsap` both pin the 152 default and the fix moves them, which makes it a behaviour change of its own rather than part of that one. Found while raising the clamp from 152 to 160.

* **The `to_hash` round trips are not listed here, and their counts are not written down anywhere.** `test/unit/to_hash_catalog.rb` holds one entry per class and `rake to_hash:pending` prints the ones still to fix, each with what it loses and a reproduction; `rake to_hash:status` prints the lot. `test/unit/to_hash_round_trip_test.rb` measures every declared verdict against the library, so that list shortens only when a fix lands and its entry is struck, and it cannot go stale the way a written list does. **The root cause behind every entry on it is one sentence**: a hash is an argument to `initialize`, so what has to come back is the instance state, and a field that lives in an instance variable no key sets cannot survive a hash build however reasonable the hash looks. **No entry is wrong wholesale any more**: `Path_attribute` was the last, with three losses, and all three are closed. ATOMIC_AGGREGATE disappearing, the tail `parse_wire` keeps, and two attributes of one type collapsing into the last, which was recorded here as a shape decision and a won't fix and should not have been. **The reasoning that reached won't fix is worth keeping, because it was wrong in an ordinary way**: a Hash keyed by attribute type genuinely cannot hold two of a type, and the conclusion that nothing readable could be done did not follow from it. A hash is an argument to `initialize`, so what has to come back is the instance state, and `@attributes` holds a repeat perfectly well once the hash has somewhere to put it: `:duplicates`, a list of the occurrences after the first, which is what `:unknown` had always done for attributes with no key of their own, in the same constructor. What made a readable fix look impossible was taking byte-exact octets as the bar, where the order of two of a type is incidental and `Path_attribute#<=>` already says so by sorting each side before comparing. Two more things it corrected that had been recorded here as fact:
  * **"Widening `to_hash` changes the shape every caller and test sees" was not measured and was not so.** It was the stated reason for leaving `CAP::Add_path`, `CAP::Graceful_restart` and `CAP::Orf` alone. No test in the suite referenced any of those three hashes, and since each carried nothing but `{:code=>n}`, no caller could depend on their contents. **All three are fixed**, each with the hash build test it never had, and `Capability::LOSSY_HASH`, which refused two of them by name in `Capability.from_hash`, is gone with them. The shape argument does hold for the `:exp` key below, where the hash does carry the field and callers do pass it.
  * **The reproduction recorded here was wrong.** `CAP::Graceful_restart.new(60,[1,1,128])` puts the Array in the **restart time** field, so the object it builds cannot `encode` at all; it never demonstrated the hash problem. The working shape is `new(state, time)` and then `add(afi, safi, flags)`. A one liner nobody ran, in an entry about a bug, which is the same failure as a wrong RFC citation.

* Two smaller things in the same field, both found with the one above, and both still open after #161 fixed the reading. **Note on the names used here and in the code**: RFC 8277 section 2.2 calls the low bit the **S bit** and never uses the words "Bottom of Stack", which come from the MPLS shim header of RFC 3032. So `@bottom`, `:bottom` and the comments in `label.rb` take their name from the same place `exp` does, which is the complaint below. The bit's own behaviour is not in doubt and nothing needs renaming to fix a bug; it is recorded so an audit does not read "Bottom of Stack" as a quote from RFC 8277. `Label` calls the 3 bits above it `exp`, in `@exp` and in the `:exp` hash key, where RFC 8277 section 2.2 calls that field Rsrv: "This 3-bit field SHOULD be set to zero on transmission and MUST be ignored on reception". The name `exp` comes from the MPLS shim header, a different field, whose EXP bits RFC 5462 renamed Traffic Class; an earlier version of this entry carried that rename over to this field, which was wrong. Renaming the hash key breaks the hash build path for every caller, so it wants a deliberate decision rather than a patch. **That decision was put to the owner on 2026-10-29 and came back as no preference**, with three options offered: leave it and comment, write `:rsrv` while accepting both keys, or rename outright. Left as it is, because no preference is not a mandate to break every caller passing `:exp` over a naming problem. Do not re-ask without new reason; change it if a caller ever needs the correct name. And `Label_stack#to_hash` keeps only the label numbers, `{:label=>100}` or `{:labels=>[100,101]}`, so Rsrv and the Bottom of Stack bit are lost there even though `Label#to_hash` carries both: `Labeled#to_hash` merges that, so a labeled NLRI's hash cannot rebuild its own octets. Both are entries in `test/unit/to_hash_catalog.rb` now, both marked to fix so `rake to_hash:pending` names them, and the fix is the extra-key-only-when-unusual rule the library already has for `:tail` and `:bits`, which changes no ordinary hash and so is not the shape decision the naming is. `Labeled` turned out to lose more than Rsrv: the inventory measured it dropping the **Path Identifier** too, because `new` hands the prefix string alone to `Prefix.new`, and a one label stack hashes as `:label` where `Labeled` reads only `:labels`, so it builds an empty stack and `encode` dies on nil.

Lab and conformance:

* **The fault matrix dials the router, and that is where its time went.** Each fault needs a session of its own, because a reset leaves nothing to reuse, so the per case cost is however long it takes to get one. Waiting for the router to dial back in was 10 to 14s a case against GoBGP 3.23.0, which was 219s of the matrix's 257s where the 2s settle on 18 cases is 30s. `lab/fault_matrix.rb --dial PORT` reverses the direction, and both native tests pass it: the GoBGP matrix went from 265s to 123s and the FRR one from 46s to 23s, with every verdict unchanged. Listening stays the default because the header's reason holds, that it works with any implementation that can be told to peer with us, and the Compose test still exercises it.
  * **Two keys in the generated gobgpd config are no-ops, and their comment used to claim otherwise.** `connect-retry` and `idle-hold-time-after-reset` under `[neighbors.timers.config]`: asking for 30 instead of 2, and 30 instead of 0, changes nothing on 3.23.0. Measured on 2026-10-31 and reproduced with a bare `TCPServer`, so it is not the harness. They are kept, since they cost nothing and a later GoBGP may honour them.
  * **The floor is 5s and it is the router's.** GoBGP takes the TCP connection at once and will not finish the OPEN exchange until 5s after the previous session ended, which is its default `idle-hold-time-after-reset`, the key it ignores. So `DIAL_TIMEOUT` and `DIAL_RETRY` are measured to sit on that floor rather than picked: 1 and 0.25 give 5.02s, 3 and 0.5 give 7.01s, and 0.5 and 0.1 give 5.42s because polling harder overshoots. Do not tighten them without re-measuring.
  * Two theories died on the way, both recorded so they are not retried: a connection collision from GoBGP dialling us as well, which `passive-mode = true` disproved by changing nothing, and the idle hold being settable from the config.
  * **The CI job is split now, which was the other half.** It used to glob the directory into one serial suite, so the lab job was the sum of 15 files and set the whole workflow's clock: 12m42s on 95fe87b where no other job reached 50s. It is a matrix now, a job per group, so the cost is the slowest group. One group per runner and **not** parallel processes on one machine, because `LabHelper::Local.free_port` binds port 0 and closes it, so two processes can be handed the same port.
    * **The grouping is in `test/lab_groups.rb` and not in the workflow**, and that is the whole point. A list in the YAML would let a new lab test run in no job at all, and a job that runs nothing exits 0 and reads as a pass, which is the failure this file keeps meeting. `test/unit/lab_groups_test.rb` requires every file under `test/functional/lab` to be in exactly one group, every group to have a job in the matrix, and every matrix entry to declare a dependency. Three sabotages, each failing and naming what was wrong.
    * Each group's name is the rule for where a new file goes: `compose` needs Docker, `gobgp-matrix` is the fault matrix, `gobgp-families` is what GoBGP makes of a family bgp4r learned, `gobgp-router` is our export side and RFC 7911, `frr` is everything needing FRR's `bgpd`, and `local` needs no router binary. Measured on 2026-10-31: `gobgp-matrix` 123s, `gobgp-families` 139s, `gobgp-router` 74s, `frr` 87s, `local` 10s. `compose` is the one not measured, because Docker Hub is not reachable from that sandbox; it was about 2m36s of the serial job, so it is most likely the new floor.
    * **The port race that comment predicted happened, and not between
      processes.** `Local.free_port` binds port 0, reads the port and
      closes, so between the probe and the daemon's own bind anything
      may take it. CI failed on 2026-10-31 with `listen tcp
      127.0.0.2:37903: bind: address already in use`, in a flow spec
      case that had not changed, because #203 took the daemons in
      `gobgp-families` from 3 to 12 and one eventually lost. So the
      hazard is not only the parallel-processes one recorded above: a
      single process starting enough daemons hits it too.
      * **Two faults, and the second is the one that matters.** The
        probe bound 127.0.0.1 while gobgpd's API binds `@local`, which
        is 127.0.0.2, so it was answering a different question than its
        caller asked; `free_port` takes the host now. And the race
        cannot be removed at all, because the socket has to be closed
        before the port can go to a child, so `Gobgpd#up` **retries** a
        lost race with fresh ports, up to 3 attempts. Only a port
        conflict is retried: a config gobgpd rejected still raises with
        the log naming the key.
      * `Gobgpd#up` also **stops waiting the moment the daemon dies**
        rather than polling a dead process to the timeout. gobgpd exits
        at once on both failures, so this turned a 30s wait into 1s, and
        made the message true: "did not come up in 30s" was wrong about
        a daemon dead for 29 of them. Without it a retry would have cost
        90s.
      * **The retry's first draft called `down` to reap the child**,
        which removes `@dir` in its ensure, so the next attempt died
        with ENOENT on `gobgpd.conf`. Found by squatting on the port and
        watching it, which is the only way to meet this deterministically.
      * `test/unit/lab_helper_test.rb` pins the half that decides
        retry-or-report, from gobgpd's own two log shapes, and runs in
        the unit suite because `lab_helper.rb` loads on stdlib alone.
        **The obvious assertion for the host argument is a weak one**:
        asking for a port on 127.0.0.2 and binding it there passes
        against a hardcoded 127.0.0.1 too, since a port free on one
        loopback address is almost always free on the other. The test
        uses TEST-NET-1 instead, `free_port('192.0.2.1')`, which is not
        an address of the machine and so cannot pass by luck.
      * `Frr` picks a `@vty_port` the same way and has no retry. Not
        touched here, because nothing has lost that race yet and the
        `frr` group runs 4 daemons; if it starts failing, this is the
        shape of the fix.
    * **A lab test file that is pure ASCII is not a style preference.** `to_hash_round_trip_test.rb` reads every test file body and matches regexps against it, and one `\u2192` in a comment made it error with "invalid byte sequence in US-ASCII" from a file it does not own. It passed on its own and failed in the suite, which is the load order trap in Conventions arriving from a third direction. That fragility is `to_hash_round_trip_test.rb`'s and is filed below rather than fixed here.
* **GoBGP runs natively, so the fault matrix needs no Docker.** `gobgpd` from a release tarball peers with bgp4r on loopback, and `test/functional/lab/fault_matrix_native_test.rb` runs the whole matrix against it. Both sides get a port of their own, so neither needs root nor `net.ipv4.ip_unprivileged_port_start`: the generated config sets `[global.config] port` and `[neighbors.transport.config] remote-port`, both of which GoBGP 3 and 4 honour. `LabHelper::Gobgpd` writes that config and starts the daemon. This is the harness to reach for before assuming a conformance question is blocked. `docs/protocol-testing.md` has the recipe under "On a Linux VM": how to get a particular version from a release tarball, with its checksum, and the two config keys that keep both ends off port 179. **Check which version you have**, because it changes the answers: Ubuntu 24.04's `gobgpd` package is 3.23.0, and GoBGP publishes Linux builds only.
* The two GoBGP columns and the FRR one in `docs/protocol-testing.md` are asserted by the three fault matrix tests, so they are re-measured rather than recorded by hand. **The versions do not answer alike, and the column used to claim they did.** GoBGP 3.23.0 resets with subcode 5 on `attr_overrun` where RFC 7606 section 4 makes treat-as-withdraw a MUST; GoBGP 4.10.0 fixed it. So 4.10.0 agrees on 16 of the 18 rows, 3.23.0 on 15, and FRR 8.4.4 on 6. The expectations are per router and per version in `test/functional/lab/fault_matrix_scenario.rb`: the native GoBGP test asks the binary, the Compose test reads `GOBGP_IMAGE`, and the FRR test asserts against major 8 only, so keep those in step if a pin moves. **Only the BIRD column is still a hand measurement**, from 2.14, and only the session level outcomes there, since BIRD gives no usable RIB answer over a loopback session. Two rows of the FRR column were wrong when it was asserted in #159, both the hand measurement's fault; see phase 5 above.
* How that wrong row survived is the lesson, not the row. The table was measured by hand once and never re-run, because the only harness that could re-run it needed a Docker daemon that the sandbox did not have. A conformance claim nothing checks reads as verified, exactly like an unread RFC citation, and this one sat in the docs, in `CLAUDE.md` and in a test's comments at the same time.
* `lab/conformance/gobgpd.conf` and `lab/topologies/fault-matrix/gobgp.toml` are written in the 3.23 style and GoBGP 4 reads them unchanged. Every key is still in the 4.x config structs under the same `mapstructure` name, and 4.x registers `mapstructure.StringToNetIPAddrHookFunc` so the address fields still decode from TOML strings. No schema work is needed; an earlier version of this entry said otherwise and was wrong.
* `lab/topologies/fault-matrix` exits 1, and that is the right answer: GoBGP discards the malformed tunnel encapsulation attribute and installs the route where RFC 9012 section 13 asks for treat-as-withdraw. Both cases are asserted as a known divergence; see the comment on `TUNNEL_ENCAP` in `test/functional/lab/fault_matrix_scenario.rb`. It is not an old bug since fixed: 3.23.0 and 4.10.0 both do it, measured natively on each, so it is worth reporting upstream.
* **Add-path is exercised against a real router now**, in #153, as `test/functional/lab/add_path_gobgp_test.rb`: three cases, 15 assertions, about 30 seconds, no Docker. `LabHelper::Gobgpd.new(add_path: {receive: true, send_max: 8})` writes the `[neighbors.add-paths.config]` keys, and `Gobgpd#remote_add_path` reads what the router made of the field we sent.
  * The guard that was missing is GoBGP's own reading of the RFC 7911 section 4 Send/Receive field: we advertise `:send` and it must read "send", `:recv` and it must read "receive". Invert `_send_recv` and that fails with GoBGP reading our `:send` as "receive".
  * Be precise about what that adds, because #115 already pinned the direction inside bgp4r by writing the field value literally on one side: inverting `_send_recv` today also fails `test/functional/add_path_test.rb` and two unit files. What survived for years was the *behaviour*, where bgp4r against bgp4r cancels the error out. So the new part is a second implementation's reading of the field, plus the data path nothing had checked against anyone else: that GoBGP accepts a Path Identifier from us, holds two paths for one prefix because of it, and understands a withdrawal that names one of them.
  * **`Neighbor#capability :add_path` takes its arguments in the order `(send_recv, afi, safi)`**, which is what `CAP::Add_path#add` takes. This file used to give the example `capabilities: [{add_path: [1, 1, 3]}]`, which is SAFI 3, NSAP, and a Send/Receive of 1. For IPv4 unicast both ways it is `[3, 1, 1]`, or `[:send_and_receive, 1, 1]`, which says it better. The wrong example was never run.
  * A Compose topology on `lab/speaker.rb` is still possible and is two pieces, neither needed by the native test: an announce block has no way to give a prefix a Path Identifier, since `build_update` calls `Nlri.new` with plain prefix strings; and `Lab::Recorder#record_routes` keys received routes by prefix alone, so two paths for one prefix overwrite each other and the state file cannot show a Path Identifier arrived. Worth doing only if the lab speaker itself needs add-path.
* **EVPN interop lives in `docs/evpn.md` section 9**, measured and asserted rather than written down here. The short version: **both routers implement route types 1 to 5 and neither knows 6 to 11**, GoBGP logging `Unknown EVPN Route type: N` and FRR saying nothing at all; FRR answers a malformed NLRI with **3/9 and a reset**, which is what `validation.rb` reports for the same octets, where GoBGP keeps the session up. Three harness facts worth knowing before writing another EVPN lab test: GoBGP's config file and its client disagree about the family name again, `l2vpn-evpn` against `evpn`; FRR's EVPN JSON has **no `routes` key** and is keyed by Route Distinguisher, so `Frr#rib` answers `{}` for it however many routes are in it and `Frr#evpn_rib` exists for that; and FRR prints `gateway IP 2.0.0.0` for every non-zero route type 5 gateway, so GoBGP is the only check on those octets.
* **RT-constrain interop found two GoBGP 3.23.0 crashes**, asserted in `test/functional/lab/rt_constrain_gobgp_test.rb` and detailed in phase 4 part 1 above. The short version, because one of them matters more than any other divergence in this file: **the zero-length default route target followed by any second membership route GoBGP accepts panics the daemon**, a nil pointer dereference in `propagateUpdate`, and **both routes are entirely conformant** — RFC 4684 section 4 blesses the zero-length default and says it is what a route reflector's PE client sends. The second crash needs a malformed NLRI: a prefix length demanding more octets than the NLRI holds, 104 bits over 12 octets. Also measured: GoBGP drops a 32-bit or 64-bit partial prefix in silence, so the family's headline use does not work there; it reads the prefix as `mlen / 8` octets where the RFC rounds up, which is why that test cannot vouch for our length octet; and **the config and the client agree on `rtc`**, unlike VPN flow spec and EVPN. FRR 8.4.4 has no RT-constrain family at all, so this is the second family with one reference rather than two.
* **ATTR_SET interop is the one that runs a router in the middle.** Neither GoBGP 3.23.0 nor FRR 8.4.4 implements attribute 128, measured with `strings` before the test was written, so there is no FRR twin and the question became what a router that has never heard of it can still vouch for. The answer is the property the attribute exists for: RFC 6368 section 5 makes it optional transitive so a customer's attributes cross the provider network. `attr_set_gobgp_test.rb` puts a gobgpd between two bgp4r speakers through `LabHelper::Gobgpd`'s `peer2`, and GoBGP carries the attribute to the far side **byte for byte** with the nested 4-octet AGGREGATOR intact, storing the value base64 encoded meanwhile. **What it does not vouch for**: GoBGP never parses the attributes inside, so the meaning of the 4-octet AS rule is still bgp4r's own opinion and only another ATTR_SET implementation could change that. What it does vouch for is the framing, since a wrong length or wrong flags would send the UPDATE to RFC 7606 rather than the RIB. One measurement recorded and not filed: **GoBGP propagates it with the Partial bit clear**, flags 0xc0 rather than 0xe0, on an attribute it does not recognize; RFC 4271 section 9 would settle whether that is a divergence and this file records that both fetchable sources truncate before it, so nothing is claimed.
* **MCAST-VPN is the one family with no outside reference, and that absence is asserted rather than written down.** `mcast_vpn_gobgp_test.rb` and `mcast_vpn_frr_test.rb` are the only two lab tests here that measure an absence; `docs/mcast-vpn.md` section 9 has the table. Neither GoBGP 3.23.0 nor FRR 8.4.4 has SAFI 5: GoBGP's config parser refuses every plausible name (`mcast-vpn isn't a valid route family name`) and FRR's grammar has no such `address-family` command. **The two disagree about what to do with an MCAST-VPN UPDATE sent anyway**, which is the finding: GoBGP counts it under `Discarded`, logs `unknown route family. AFI: 1, SAFI: 5`, and keeps the session and an installed route; FRR calls it `Attribute MP_REACH_NLRI, parse error`, fails the whole UPDATE and **resets the session with no NOTIFICATION**, where RFC 4271 section 6 wants one. **Neither test vouches for anything about our octets**, because a router with no parser for the family never reads them, so this family's wire format is still bgp4r's own opinion against the field widths RFC 6514 and RFC 6515 state. Two harness facts: **`is_established?` cannot see FRR's reset**, since it reconnects within a second or two and the first measurement here read the new session and concluded nothing happened, so both tests watch `on_state_change`; and **GoBGP stops printing `UnknownFamily(65541)` once an UPDATE in the family arrives**, so the capability has to be read before sending.
* **BGP-LS is the only family measured in both directions, and `docs/bgp-ls.md` section 11 has it.** GoBGP 3.23.0 can originate a BGP-LS route, so its encoder feeds our decoder: `gobgp global rib add -a ls link` wants sixteen keyword and value pairs (`LINK_ARGS` in the test has them) and refuses `node` and `prefix`, so NLRI type 2 is the only one. What that bought: sub-TLV 516 kept and echoed on real traffic, the Protocol-ID table corrected because GoBGP originates with 7 and bgp4r said Unassigned, and the finding that decided part 6's scope, which is that **GoBGP's own node descriptors break section 5.2.1.4's ascending-order MUST** while GoBGP also enforces a mandatory-TLV check section 8.2.2 forbids. So part 6 follows the RFC and not the router. **Two GoBGP faults, recorded and not filed**: a node descriptor carrying only an Autonomous System is refused with "Required TLV missing" and costs the whole capability, and the client panics rendering an IP Reachability TLV whose prefix is more than one octet, which is why the send-side prefix case uses a /8. **What the receive direction cannot check**: GoBGP sends one NLRI per UPDATE, so `Link_state.nlri_size` wrong by a constant leaves every receive case passing; the multi-NLRI cases in `test/functional/link_state_test.rb` are the only cover the parse-side framing has. FRR 8.4.4 has neither SAFI and logs `afi/safi: bad-value/unknown`, naming neither half where for MCAST-VPN it named the AFI, then resets on a BGP-LS UPDATE as it does for SAFI 5. SAFI 72 has no reference at all.
* **Flow spec interop lives in `docs/flow-spec.md` section 12**, measured and asserted rather than written down here, the same way the fault matrix columns are. The short version: both routers accept a rule from bgp4r and read it back, and they disagree on every part of RFC 8955 section 4.2. Two harness facts worth knowing before writing another flow spec lab test: GoBGP's **config file and its client use different names for the VPN family**, `l3vpn-ipv4-flowspec` and `ipv4-l3vpn-flowspec`, each rejecting the other; and **FRR 8.4.4 has no VPN flow spec family**, refusing a session that offers SAFI 134 alone with 2/7 and silently discarding the rule when SAFI 133 is there too.
* **`to_hash_round_trip_test.rb` cannot read a test file that is not pure ASCII.** `test_every_working_round_trip_is_asserted_in_a_class_test_file` reads every test file body and matches regexps against it, and a single non-ASCII character in any of them makes it error with `ArgumentError: invalid byte sequence in US-ASCII`, pointing at its own line 190 and naming neither the file nor the character. Found on 2026-10-31 by putting one arrow in a comment in a new test file: that file passed on its own and the suite errored in a test it has nothing to do with. Every test file is ASCII today, so nothing is wrong now; what is wrong is the diagnosis the next person gets. The fix is an encoding on the read or a `scrub`, and it is one line in a file this change does not otherwise touch.
* Lowest coverage (unit suite): `neighbor/neighbor.rb` 91%, `messages/update.rb` 92%, `neighbor/add_path_cap.rb` 93%, `path_attributes/mp_unreach.rb` 93%, `path_attributes/ipv6_extended_communities.rb` 93%, `optional_parameters/graceful_restart.rb` 93%.

## Attribute work left

RFC sections deliberately not implemented, each noted in the pull
request that added the attribute:

* Tunnel Encapsulation (23): the five per tunnel type Encapsulation sub-TLV shapes, RFC 9012 sections 3.2.1 to 3.2.5, for VXLAN, NVGRE, L2TPv3, GRE and MPLS-in-GRE. The attribute keeps their octets, so a test can still build any of them by hand.
* Tunnel Encapsulation: the SR Policy sub-TLVs, types 12 to 15, 20 and 128 to 130, from RFC 9830, "Advertising Segment Routing Policies in BGP". RFC 9256 is the SR Policy architecture and defines no sub-TLV; IANA gives RFC 9830 as the reference for all eight code points. The Prefix-SID sub-TLV, type 11, is RFC 9012 section 3.7, so it is RFC 9012 work and not outside work like the rest of this entry.
* Prefix-SID (40): the SRv6 TLVs of RFC 9252, and the RFC 8669 section 4.1 rule for labeled unicast.
* No check for a missing well known mandatory attribute. That needs `Update`, not `Path_attribute`, because it depends on whether the message carries NLRI.
* The external peer rules for LOCAL_PREF, ORIGINATOR_ID and CLUSTER_LIST, and the RFC 7311 section 3.2 AIGP checks. bgp4r does not know whether a peer is external where the checks run.
* BGP-LS (29): every attribute TLV the **other** RFCs define, which that
  plan's measure deliberately excludes and which is most of the 139 assigned
  code points. The attribute and all three of RFC 9552's own tables are in,
  so all 25 of its attribute TLVs, and a TLV with no class is kept and
  echoed, which section 5.1 requires rather than permits: the lab meets one
  on real traffic, TLV 1101 from RFC 9085, which GoBGP originates.
  * The receive side is **not** on this list: the ten syntactic checks of
    RFC 9552 section 8.2.2 are in `validation.rb`. What is deliberately
    out is the four shapes of semantic check that section says not to
    make, which bgp4r does make for EVPN and MCAST-VPN;
    `docs/bgp-ls.md` section 8 names all four and
    `bgp_ls_doc_test.rb` asserts that none is reported.
* Not started: BGPsec_Path.
