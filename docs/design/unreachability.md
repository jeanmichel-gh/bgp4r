# Unreachability Information: SAFI 81 and EVPN route type 254

Status: **approved by the owner, 2026-11-22.** Not built yet.

## The problem

Two Internet-Drafts let a BGP speaker say "this prefix is unreachable"
without touching anyone's RIB or FIB. The owner asked on 2026-11-22 for
bgp4r to support both:

* `draft-tantsura-idr-unreachability-safi-06` (IDR, June 2026, expires
  17 December 2026). A new SAFI, 81, for AFI 1 and AFI 2.
* `draft-tantsura-bess-evpn-unreachability-02` (BESS, 15 May 2026,
  expired 16 November 2026). A new EVPN route type. The draft says
  "TBD1". The owner was told on 2026-11-21 that the on-wire value is
  254, provisional, IANA assignment pending.

Both were read in full for this spec on 2026-11-22. Section numbers
below are theirs.

## What the drafts say

### Common to both

* A route is information only. A receiver keeps it in a separate
  Unreachability Information RIB, the UI-RIB, and MUST NOT install or
  remove anything in the Loc-RIB or the FIB because of it.
* The NLRI key is the prefix (and, for EVPN, the RD, Ethernet Tag ID and
  Address Family). After the key come one or more **Reporter TLVs**,
  which are not part of the key.
* A Reporter TLV: Type 1 (1 octet), Length (2 octets), Reporter
  Identifier (4 octets, a BGP Identifier), Reporter AS (4 octets), then
  sub-TLVs. Its Length is at least 8.
* Sub-TLVs: Type (1 octet), Length (2 octets), Value. Type 1 is the
  Reason Code (2 octets), type 2 a Timestamp (8 octets, Unix seconds).
  EVPN adds type 3, EVI (4 octets). Unknown sub-TLVs are ignored. A
  missing Reason Code means 0, Unspecified.
* Reason codes 0 to 9 are the same in both: Unspecified, Policy
  Blocked, Security Filtered, RPKI Invalid, No Export Policy, Martian
  Address, Bogon Prefix, Maintenance, Local Administrative Action, Local
  Link Down. EVPN adds 10 MAC Mobility Limit Exceeded, 11 Tenant
  Isolation Violation, 12 VTEP Unreachable. 64536 to 65535 are private.
* A withdrawal carries the key alone, no Reporter TLVs.
* **Aggregation.** A speaker that does it runs the normal decision
  process, takes the Reporter TLVs of the best path first, then adds
  those of the other feasible paths, one per (Identifier, AS), keeping
  the newer Timestamp. The first Reporter TLV is always the best path's.
  RECOMMENDED limit: 50 Reporter TLVs. To withdraw one reporter, the
  speaker re-advertises the NLRI without it, so it must remember which
  neighbour gave each Reporter TLV.
* Graceful restart as usual, with the F bit meaningless.
* Error handling (SAFI section 5, EVPN section 4.11), in order:
  structural errors are "session reset" or "AFI/SAFI disable"; a
  missing Reporter TLV is "treat-as-withdraw"; a bad Reporter TLV is
  discarded and the rest are kept; an unknown Reporter TLV type is
  skipped; a duplicate reporter or sub-TLV keeps the first; a bad
  sub-TLV is discarded and the rest are kept.

### SAFI 81

* The NLRI (sections 3.2 and 3.3): **NLRI Length (2 octets)**, Prefix
  Length (1 octet), Prefix (as RFC 4271, the octets the length needs),
  Reporter TLVs. The NLRI Length counts what follows it. With ADD-PATH
  the Path Identifier comes before it.
* Capability: the usual Multiprotocol capability for AFI 1 or 2, SAFI
  81. A second capability, "Enhanced Unreachability Information"
  (code TBD2, one octet, bit A for aggregation), is not assigned yet.
* No next hop: Appendix B.1's UPDATE has Next Hop Length 0.
* ORIGIN SHOULD be INCOMPLETE for locally made information (4.6).

### EVPN route type 254

* AFI 25, SAFI 70. The route type (section 3.3) is route type 5's
  fields with one octet added: Route Type, Length (1 octet), RD (8),
  ESI (10, MUST be zero), Ethernet Tag ID (4), **Address Family** (1:
  1 for IPv4, 2 for IPv6), IP Prefix Length (1), IP Prefix (4 or 16),
  GW IP Address Length (1, MUST be 0), MPLS Label (3, MUST be 0), then
  Reporter TLVs.
* The fixed part is 32 octets for IPv4 and 44 for IPv6.
* RFC 9136's rules that treat a zero-label route type 5 as withdrawn do
  not apply (3.4).
* Non-zero ESI, GW IP Address Length or label is "treat-as-withdraw"
  (4.11.2). An Address Family other than 1 or 2 is "session reset"
  (4.11.1).
* No capability. A speaker that does not aggregate, re-advertising,
  MUST send only the first Reporter TLV (4.4).

## Review notes on the drafts

Checked by hand and with a short script against the drafts' own
examples, on draft-tantsura-idr-unreachability-safi-06 and
draft-tantsura-bess-evpn-unreachability-02. Kept here for later, to
send to the authors or to check against the next revisions (the
owner's decision, 2026-11-22). When a new revision comes out, check
each point again and note here what it changed.

1. **SAFI, sections 5.1 and 5.2 contradict.** 5.1's minimum NLRI Length
   in MP_REACH includes "at least 11 octets for one Reporter TLV", and
   5.1 is checked first, with "session reset". So an NLRI with no
   Reporter TLV is a session reset, and 5.2's "MP_REACH_NLRI containing
   no Reporter TLVs: treat-as-withdraw" can never apply. I will follow
   5.2, the gentler action, and log the finding as 5.2's. Question 5.
2. **EVPN Example 1's hex is one octet too long.** It has 51 octets
   where 2 + Length (48) is 50: fifteen zero octets for the ESI and
   Ethernet Tag where there should be fourteen. Examples 2 and 3 are
   right. Our tests use Example 1 with the octet removed, and say so.
3. **EVPN's one-octet Length caps the Reporter TLVs far below 50.** A
   Reporter TLV with a Reason and a Timestamp is 27 octets. 255 octets
   hold 8 of them after IPv4's 32 fixed octets, and 7 after IPv6's 44.
   Appendix B says the Length bounds the count. Sections 4.4 and 4.7
   still recommend 50. bgp4r's limit for EVPN is what fits.
4. **EVPN's cross references are off by one section.** Sections 3.3
   and 4.3 send error handling to 4.10.1; it is 4.11.1. Section 4.11
   names "4.10.1 through 4.10.4"; they are 4.11.1 to 4.11.4. 4.11.3
   puts the Reporter TLV limit in 4.6, which is graceful restart; the
   limit is in 4.4 and 4.7.
5. **EVPN does not give 4.11.1's minimum Length.** By section 3.3 it is
   32 + 11 = 43 for IPv4 and 44 + 11 = 55 for IPv6 in MP_REACH, and 32
   and 44 in MP_UNREACH. bgp4r uses those.
6. **The EVPN draft expired on 16 November 2026**, and 254 is in no
   revision of it.

## What exists

In bgp4r (master `bb3408b`):

* No SAFI 81 anywhere: `IANA::SAFI` stops at the values in
  `bgp/iana.rb`, and `Nlri.factory` raises on a SAFI it does not know.
* EVPN: `Evpn::ROUTES` holds types 1 to 11 (`bgp/nlris/evpn.rb`). A
  type 254 route reads back as `Evpn::Unknown` and is sent back byte for
  byte (`bgp/nlris/evpn_route.rb`).
* `MpReachCommon::ClassMethods#nlri_size` asks each family how long one
  NLRI is. Flow spec, EVPN, MCAST-VPN and BGP-LS each have an arm.
* BGP-LS routes live outside the RIB, in `LinkStateTable`, per peer and
  keyed by the NLRI's octets, read by `show.link_state`
  (`docs/design/bgp-ls-producer.md`, option A). That is the shape a
  UI-RIB needs first.
* EVPN routes are not in bgp4rd's RIB either. bgp4r sends and reads
  them; bgp4rd does not select or reflect them.
* `bgp/path_attributes/validation.rb` holds the attribute findings;
  `bgp/fault.rb` the fault catalog, 20 entries.

Elsewhere (measured 2026-11-22):

* **FRR implements SAFI 81 on master**, merged 2026-06-30 as
  FRRouting/frr#21451 (`bgpd/bgp_unreach.c`, written to draft -06). It
  is in no release: `bgpd/bgp_unreach.c` is missing from the tags
  `frr-10.7.0` and `frr-10.7.1`. It does not aggregate and has no
  ADD-PATH. It takes one Reporter TLV, sends Next Hop Length 0, and
  has `show bgp [ipv4|ipv6] unreachability` and a hidden `bgp inject
  unreachability`. Its parser returns an error on a Reporter TLV type
  other than 1, where the draft says to skip it; what that does to the
  session is to be measured.
* **No implementation of the EVPN route type** found in FRR (code and
  pull requests searched for it). None in GoBGP for either draft.

## Decisions

### Where the routes live: a table of their own (as BGP-LS's option A)

The drafts require a UI-RIB apart from the Loc-RIB. bgp4rd gets an
`UnreachTable`, beside `LinkStateTable`: per peer, keyed by AFI and
NLRI key, holding the decoded NLRI, the path attributes and the time.
It never touches `LocRib` or the FIB. That is the drafts' first MUST,
and a test checks it.

First version: bgp4rd is a **reporter** (it originates) and a
**collector** (it keeps what it receives). It does not propagate. That
is FRR's level less propagation, and enough for a lab against FRR.

Propagation, with the decision process, aggregation and per-reporter
withdrawal, is a second phase with its own spec, as BGP-LS's Propagator
is. It needs the same thing: a RIB that carries a family keyed by
octets.

### The codec

Built to `docs/building-objects.md`: four ways in, `encode`, `parse`,
`to_hash`, `to_s`, `to_shex`, a `to_hash` catalog entry each, building
never validates.

* `IANA::SAFI::UNREACHABILITY_INFORMATION = 81`, with the draft and the
  IANA entry quoted beside it.
* `bgp/nlris/unreachability.rb`: the shared parts.
  * `Unreachability::Reporter`, the Reporter TLV.
  * Its sub-TLVs, through a registry: `Reason_code`, `Timestamp`,
    `Evi`, and `Unknown` kept with its octets. The registries differ:
    under SAFI 81, sub-TLV 3 is unassigned and reads as `Unknown`.
  * An unknown Reporter TLV type is kept as `Unknown` too, and sent
    back unchanged.
  * Reason codes by name, both tables, private codes printed as numbers.
* `Unreachability::Nlri`, the SAFI 81 NLRI. `nlri_size` gets an arm:
  2 + NLRI Length. `Nlri.factory` gets an arm and passes the AFI, which
  decides the prefix's family. A withdrawal is the same class with no
  reporters.
* `Evpn::Ip_prefix_unreachability`, registered in `Evpn::ROUTES` under
  `TYPE = 254`, with a comment that 254 is provisional (question 1). It
  reads the Address Family octet before the prefix, as 3.3 says. EVPN's
  existing `nlri_size` arm already frames it: 2 + Length.
* The drafts' examples are unit tests, octet for octet: SAFI 3.6.1,
  3.6.2, B.1 and B.3; EVPN Examples 1 (corrected), 2, 3, 4 and 6.
* `bgp4r-capture` and the dissector print both.

### Validation

Findings in `validation.rb`, each with its draft section and action.
`:lenient` lists them; `:strict` raises on one. Proposed names:

| Finding | Draft | Action |
| --- | --- | --- |
| `unreach_nlri_length` | SAFI 5.1 | session reset |
| `unreach_prefix_length` | SAFI 5.1 | session reset |
| `unreach_no_reporter` | SAFI 5.2, EVPN 4.11.2 | treat-as-withdraw |
| `unreach_reporter_in_withdraw` | SAFI 5.2 | treat-as-withdraw |
| `unreach_reporter_malformed` | SAFI 5.3, EVPN 4.11.3 | discard the TLV |
| `unreach_reporter_duplicate` | SAFI 3.4, EVPN 3.5 | keep the first |
| `unreach_reporter_over_limit` | SAFI 5.3, EVPN 4.11.3 | discard the excess |
| `unreach_subtlv_malformed` | SAFI 5.4, EVPN 4.11.4 | discard the sub-TLV |
| `unreach_subtlv_duplicate` | SAFI 3.5 | keep the first |
| `unreach_reporter_as_not_in_path` | SAFI 7 item 5, EVPN 7 item 4 | log only |
| `evpn_unreach_address_family` | EVPN 4.11.1 | session reset |
| `evpn_unreach_nonzero_field` | EVPN 4.11.2 | treat-as-withdraw |

bgp4rd applies "AFI/SAFI disable" rather than "session reset" where
RFC 7606 section 7 allows it, so a bad report never drops unicast.

### Fault catalog

One entry per finding above that a sender can cause, built from the
drafts' examples: a short NLRI Length, a prefix length of 33, no
reporter, a reporter in a withdrawal, a Reporter Length of 7, two
reporters with one Identifier and AS, a Sub-Length past the TLV, 51
reporters, an EVPN Address Family of 3, an EVPN label of 1. A unit test
checks the catalog and the findings agree. `bgp4r-sim`'s `/api/fault`
sends them.

### bgp4rd

* Capabilities: `mbgp_ipv4_unreachability` and
  `mbgp_ipv6_unreachability`, in the style of `mbgp_ipv6_unicast`.
  EVPN needs nothing new. TBD2 is not sent (question 3).
* Configuration, an `unreachability:` block: the reports bgp4rd
  originates, each a prefix with a reason and, optionally, a timestamp.
  For EVPN, an RD, route targets and Ethernet Tag as well. The Reporter
  Identifier and AS are bgp4rd's own (SAFI 4.1). ORIGIN is INCOMPLETE.
* API: `unreach.report` and `unreach.clear` for one prefix, as a commit
  of that key, the way `link_state.unreachable` is.
  `show.unreachability` lists the table: prefix, family, peer, and each
  reporter with its Identifier, AS, reason and time, in the order
  received.
* Shell: `show bgp ipv4 unreachability [PREFIX]`, FRR's syntax.
* Events: one when a report arrives and one when it goes, for
  routescope's timeline.
* Graceful restart: entries from a restarting peer marked stale and
  removed on End-of-RIB or the restart time, as for other families.

### Route generation and the injector

* `bgp/gen`: an `unreachability` spec, N prefixes with M reporters
  each, reasons and timestamps varied, for SAFI 81 or EVPN.
* `bgp4r-sim`: the same, from `/api/send` and the console.

### Interop and the lab

* SAFI 81 against **FRR built from master**, since no release has it
  (question 2). A lab, `routescope/labs/unreach-frr-lab`: bgp4rd and
  FRR, both ways, IPv4 and IPv6. The gate: each shows the other's
  reports with the same reporter, reason and time; a clear withdraws;
  neither's RIB or FIB changes. Its `ABOUT.md` says it is the interop
  check. The main lab is two bgp4rd, by the house rule (Ruby first).
* EVPN type 254 has no peer to test against. Two checks instead: the
  draft's examples, and what FRR 10.5.1 does with a type 254 route it
  does not know (measured, and written down in the lab's `ABOUT.md`).

## Pull requests

1. The SAFI 81 codec, its findings, faults and catalog entries, and the
   draft's examples as tests.
2. The EVPN type 254 codec, the same.
3. bgp4rd: `UnreachTable`, the capabilities, the `unreachability:`
   block, `unreach.*`, `show.unreachability`, the shell and events.
4. `bgp/gen` and `bgp4r-sim`.
5. The lab against FRR master, with its gate; `docs/unreachability.md`;
   the README line.

Phase 2, propagation and aggregation, starts with its own spec.
routescope's views are a spec in routescope.

### As built

Pull request 1, the SAFI 81 codec (2026-11-22). What changed from the
design above:

* **The findings have no names.** bgp4r's `Attr::Finding` is a subcode,
  an action and a reason in words; the table's names are not in the
  code. Each reason names its draft section instead. A Reporter TLV or
  sub-TLV the draft has the receiver discard, while it keeps the rest,
  is a finding with no action.
* **`unreach_reporter_as_not_in_path` is not built here.** It needs the
  AS_PATH, which a check of one attribute does not see. It moves to
  pull request 3, with the daemon.
* **The faults are a list of their own, `Fault::UNREACHABILITY`**, not
  in `Fault::CATALOG`. `lab/fault_matrix.rb` sends every CATALOG case
  to FRR and GoBGP and checks each against a measured table, and
  neither router has been measured on SAFI 81. They join CATALOG in
  pull request 5. `Fault.build` and `Fault.wire` take their names.
* **Five faults, not ten.** The NLRI-level ones: a Length past the
  attribute, a /33, no reporter, a reporter in a withdrawal, the one
  reporter too short. The discards that keep the route are tested in
  `validation_test.rb` and are not faults, since a router answers them
  with nothing a test can see on the session.

Pull request 2, the EVPN route type 254 codec (2026-11-22):

* **`Evpn::Ip_prefix_unreachability`** in
  `bgp/nlris/evpn_unreachability.rb`, registered in `Evpn::ROUTES` under
  254. An Address Family other than 1 or 2 cannot be read as this
  route, so `Evpn` keeps it as an `Evpn::Unknown`, which replays it.
* **Two reporter classes, not one with a parameter.**
  `Unreachability::Evpn_reporter` is `Reporter` reading against the
  EVPN sub-TLV registry (`Evi` added), and `Evpn_reason_code` is
  `Reason_code` with the EVPN names for 10 to 12. Same octets; only
  the registry and the names differ.
* **`Evpn#encode` refuses a body past 255 octets.** It wrote the low
  octet of the Length and said nothing. Review note 3 is how far that
  is: 21 bare reporters after IPv4's 32 octets.
* The findings: 4.11.1's resets, 4.11.2's treat-as-withdraw for a
  non-zero ESI, GW IP Address Length, GW IP Address or label and for
  no reporter in an announcement, and the Reporter walk SAFI 81 uses,
  with the EVPN draft's sections and the EVI's size. No Reporter TLV
  limit: the one-octet Length is the limit.
* Three faults joined `Fault::UNREACHABILITY`: an Address Family of 3,
  a label of 16, no reporter.
* `docs/evpn.md` gains a row for 254 in section 3's table.

Pull request 3, bgp4rd (2026-11-22). In `bgp/daemon/unreachability.rb`:

* **`UnreachTable`** keeps what each peer sent, keyed by the drafts' NLRI
  key, and drops a peer's reports when its session leaves Established.
  It reads an UPDATE's own findings first: a session reset or AFI/SAFI
  disable finding takes nothing from that UPDATE, and treat-as-withdraw
  turns its announcements into withdrawals. Of the Reporter TLVs it
  keeps type 1 only, the first of each (Identifier, AS), and at most 50
  for SAFI 81.
* **`UnreachOriginator`** sends the `unreachability:` block: ORIGIN
  INCOMPLETE, our AS prepended toward an external peer, no next hop for
  SAFI 81, ours and the Route Targets for EVPN.
* **The reporter AS check is here**, moved from pull request 1. A row
  names, in `reporter_as_not_in_path`, any reporter AS missing from the
  UPDATE's AS_PATH (AS4_PATH preferred), and bgp4rd logs a warning. An
  empty AS_PATH, an internal peer's, is not checked.
* **`unreachability` is an ordinal list** in `Config`, as `announce` and
  `originate` are: no one field keys an entry, since one prefix may be
  reported in two RDs.
* **A report with no timestamp keeps the one it was first sent with**,
  while nothing else about it changes, so a commit of another key does
  not send every report again. `unreach.report` writes now into the
  configuration, so a rollback puts the report back as it was sent.
* The event kind `unreachability`: `received` and `withdrawn` for what
  arrives, `reported` and `cleared` for what this speaker sends.
* The shell takes `show ip bgp ...` for each `show bgp ...` form, as it
  does for every other command.

Pull request 4, route generation and the simulator (2026-11-22):

* **Two families, not one with a switch**: `unreachability` (SAFI 81)
  and `evpn_unreachability` (EVPN 254), in
  `bgp/gen/unreachability_routes.rb`, so `rd`, `vrfs` and
  `route_target` belong to the EVPN one alone, as the spec checker
  already arranges keys by family.
* The keys: `reporters`, `reporter` (the first Identifier), and
  `reporter_as`, `reason` and `timestamp` as values or patterns on the
  route number. **No `timestamp` leaves the sub-TLV out**, so the same
  spec gives the same octets, which bgp/gen promises.
* **A withdrawal is sized by its own NLRI**, not the announcement's;
  the generator's first-message measure caught it.
* Two Specimen entries, `unreachability` and `evpn_unreachability`,
  since BGP::Gen takes its family names from BGP::Specimen. MP_REACH
  now takes and reads a next hop under SAFI 81, as under flow spec, so
  the build gate knows the family; none is sent.
* `bgp4r-sim` needed nothing of its own: the injector reads
  `BGP::Gen::GENERATORS`. The console's `--families` offers
  `unreachability` by both AFIs, one capability per AFI and SAFI.

Not built, and the design said otherwise (pull request 3):

* **Graceful Restart's stale marking.** The design said "as for other
  families"; bgp4rd marks nothing stale for any family yet, so a report
  goes when its session does.
* **AFI/SAFI disable.** bgp4rd ignores the reports of an UPDATE with a
  structural error and keeps the session, under its default lenient
  policy, rather than disabling the family for the rest of the session.

## Tests

* Unit: every class four ways; the drafts' examples; the `to_hash`
  catalog; every finding from its fault; the catalog against
  `validation.rb`; that a report never reaches `LocRib` or the FIB.
* Functional: two bgp4rd on loopback, report, show, clear, for both
  families and EVPN.
* Interop: the lab above.

## The owner's answers, 2026-11-22

The owner approved the spec as written. The recommendations stand:

1. EVPN type 254 is a constant, with a comment that it is provisional.
2. FRR from master: still open. Decide before pull request 5.
3. The TBD2 capability is neither sent nor read until IANA assigns it.
4. The review notes stay in this document for later.
5. An NLRI with no reporter is treat-as-withdraw, as SAFI 5.2 says.

The questions as they were asked:

1. **EVPN type 254.** A constant, 254, with a comment that it is
   provisional, changed when IANA assigns one. Or a setting, so a
   capture with another value can be read. I recommend the constant.
2. **FRR from master.** Our FRR is 10.5.1. The lab needs an image built
   from FRR master at or after `928a5e0`. Build it in the lab, or wait
   for a release that carries it?
3. **The TBD2 capability.** Neither send nor read it until IANA assigns
   a code; a received one stays `Capability::Unknown`. I recommend
   that.
4. **The findings above.** Send them to the drafts' authors? They are
   six short points.
5. **SAFI 5.1 against 5.2.** Follow 5.2 (treat-as-withdraw) for an NLRI
   with no reporter, as I propose, or 5.1 (session reset) as the order
   of checks says?
