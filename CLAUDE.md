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
bgp/optional_parameters/ OPEN capabilities (4-byte AS, add-path, graceful restart...)
bgp/orfs/                outbound route filtering
bgp/neighbor/            the BGP finite state machine and TCP session (neighbor.rb)
bgp/rib/                 routes and the decision process (RFC 4271 section 9); require 'bgp/rib'
                         phase 1 of five; see "Where the work is going"
bgp/misc/                extras: route_generator.rb (many prefixes packed in UPDATEs), live_feed.rb (a client for an old public BGP feed)
docs/                    protocol-testing.md: using bgp4r to test a router
examples/                runnable scripts
test/unit/               unit tests, mirroring bgp/
test/functional/         tests that open real TCP sessions
test/helpers/            a small test BGP server
lab/                     speakers in containers: lab/speaker.rb and lab/topologies/ (see lab/README.md)
                         lab/fault_matrix.rb sends BGP::Fault::CATALOG to a router; lab/conformance/ has a config per router
                         lab/topologies/fault-matrix runs that matrix against GoBGP in one command, and in CI
test/functional/lab/     lab tests: loopback speaker test and one Compose test per topology
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

Lab tests (the Compose ones skip without Docker):
```
ruby test/run_lab.rb
```

Do not run `test/functional/live_feed_test.rb`. It connects to a public feed that no longer answers and hangs forever.

In Docker, on any Ruby version (the default is 3.4):
```
docker build --target test --build-arg RUBY_VERSION=4.0 -t bgp4r-test .
docker run --rm bgp4r-test
docker run --rm bgp4r-test ruby -I. test/functional/add_path_test.rb
```
The image runs as the non-root user `bgp`. It can still bind TCP 179, because Docker sets `net.ipv4.ip_unprivileged_port_start=0` in a container's own network namespace. With `--network host` the host's setting applies.

CI: `.github/workflows/test.yml` runs both suites on every push to master and every pull request, on Ruby 3.3, 3.4, 4.0 and head (head may fail), both on the runner and in the Docker image. A `lab` job runs the Compose topologies.

Baseline on 2026-10-27: 936 tests, 20151 assertions, all passing. Line coverage of `bgp/` from the unit suite: 97.0%.

There is no coverage gem in the `Gemfile`. To measure, use Ruby's built-in `Coverage`: start it, register the report with `at_exit` before requiring any test file so it runs after the suite, then require `test/unit/**/*_test.rb`.

## Conventions

* **Building and encoding are never validated, and that is a feature.** This library is used for negative testing: it has to put bytes on the wire that no RFC allows, so a real router can be watched handling them. Any attribute, any length, any combination, any flags. Never add a check to a constructor, to `encode`, or to `to_hash` that refuses something merely invalid. Removing that ability breaks the main reason the library exists.
  * Validation lives in exactly one place, `bgp/path_attributes/validation.rb`, and runs only when parsing what was received. It is reported through `Path_attribute#errors` and raised only under the `:strict` receive policy. Add a rule there, with its RFC section, never in the attribute.
  * `Path_attribute#errors` means what the peer got wrong, and nothing else. A valid attribute bgp4r cannot decode is bgp4r's coverage gap, not a protocol error: RFC 7606 section 7 says attribute by attribute what makes one malformed, and a reader's missing code is on none of those lists. Those go in `Path_attribute#undecoded` as `Attr::Gap`, which `:strict` never raises on. Do not put a fact about bgp4r in `errors`; a conformance tool that calls its own gap a protocol error gives a confident wrong verdict about a correct router.
  * A constructor may refuse an input it cannot represent at all, such as an Integer too large for the field it goes in, because the alternative is silently sending a different value. It must never refuse a combination that is simply wrong by the RFC. Where a constructor does refuse, the octet level routes stay open and must keep working: wire bytes, `Attr::Raw`, and the `BGP::Fault` helpers.
  * `lab/fault_matrix.rb` and `BGP::Fault::CATALOG` depend on all of this. `docs/protocol-testing.md` is the guide to it.
* When parsing cannot interpret trailing octets, keep them and write them back, so `encode` returns byte for byte what arrived. `prefix_sid.rb` keeps a `@tail`, `pmsi_tunnel.rb` keeps a value too short to read in its own `@tail`, and `communities.rb`, `cluster_list.rb`, `extended_communities.rb`, `large_communities.rb` and `ipv6_extended_communities.rb` all keep a tail. Report the fault in `validation.rb`; do not drop the octets.
  * The hash forms carry a kept tail as one `{:tail=>hex}` entry at the end of the value list, so `sort`, `sort!`, `uniq` and `to_hash` keep it as `encode` does. `Attr::TAIL_KEY`, `Attr#tail`, `Attr#tail_entry` and `Attr#take_tail` do it in one place; an attribute with no tail has no such entry, so its hash is the plain list it has always been.
  * `prefix_sid.rb` and `pmsi_tunnel.rb` hash under a nested hash rather than a value list, so they carry the tail as a `:tail` key inside that hash. `Attr#take_tail_key` reads it back. Same rule: no tail, no key.
* Every class can be built three ways: from field values, from a hash, and from its wire bytes (a binary String). Keep all three working when you change a class.
* `encode` returns wire bytes. `to_hash` returns a hash that round trips through `new`. `to_s` returns the human readable form.
* Tests check round trips: build, encode, parse back, compare. Use real hex captures from the RFCs or from Wireshark when possible.
* One test file per source file, same name with `_test.rb`, in the matching folder under `test/unit/`.
* Write `BGP::` names out in full in a test file. Three top level `include`s in `test/unit/neighbor/neighbor_test.rb` leak into every test file the suite loads after it, and `BGP::OPT_PARM::CAP` wins the names it shares with `BGP`, so a bare `Orf` is the ORF capability and a bare `Route_refresh` is the capability rather than the message. A test written that way passes on its own and fails in the suite. The entry under "Known issues to work on" has the detail and the fix.
* Two space indent. Match the style of the file you edit.
* Copyright headers. A new Ruby file or Dockerfile starts with the standard GPL header from `bgp/observable.rb`, with `Copyright <current year> Jean-Michel Esnault.` (a Dockerfile drops the `#--` and `#++` lines). When you change a file that has a header, add the current year to its years if it is missing: `2008, 2009` becomes `2008, 2009, 2026`. Do not add headers to files that never had one. YAML, Markdown and other config files get no header.
* Keep the library free of runtime gem dependencies. The one exception is `logger`: it ships with Ruby, but Ruby 4.0 made it a bundled gem, so `bgp4r.gemspec` and the `Gemfile` declare it.
* Before requiring a standard library, check that it is still a default gem. Ruby keeps moving libraries to bundled gems (`observer` in 3.4, `logger` in 4.0), and under Bundler those fail to load unless declared. Prefer a small built-in copy, as with `BGP::Observable`.
* Do not redefine methods of standard library classes. Newer versions may add the same method with different behavior (`IPAddr#+` in Ruby 4.0). Guard additions with `unless method_defined?`.
* Do not mutate string literals. CI runs the suite with `--enable-frozen-string-literal`. Use `String.new` or `+''` for a buffer.

## Rules for agents

* Work on a branch named `claude/<short-topic>`. Never push to master. The agent tooling may put its scratch worktrees in `.claude/worktrees/`, which `.gitignore` covers; they are whole checkouts, not bgp4r source, and must never be committed.
* If `gh pr create` fails with HTTP 403, GitHub's GraphQL API is blocked in that sandbox. Open the pull request with `gh api repos/{owner}/{repo}/pulls --method POST` instead.
* One topic per pull request. Small diffs.
* Run the full unit suite before opening a PR. All tests must pass.
* New behavior needs a test. Bug fixes need a test that failed before the fix.
* Cite the RFC section in a comment when you implement or fix wire format logic. Open the RFC and check the section number against its text; do not write one from memory. Six citations in this file and in the code were found wrong on 2026-10-27. One of them, "RFC 5291 section 5" for the ROUTE-REFRESH and ORF layout, is section 4, and it had been copied forward into two pull requests before anyone read the RFC. Another called 0x02 and 0x03 extended community types when they are sub-types. A wrong citation is worse than none, because it reads as verified and sends the next person to the wrong page.
* Do not delete or weaken existing tests to make a change pass.
* If you find a bug you are not fixing, list it in the PR description.
* A plan that spans more than one session goes under "Where the work is going" as phases with their status, before the work starts. A plan that lives only in a chat is lost the moment the context is: the RIB plan below had to be recovered from a transcript because nothing in this file recorded it, or recorded that phase 1 was finished.
* Keep this file true in the same pull request that makes it false. If your change fixes something under "Known issues to work on", delete that entry. If it adds or removes tests, update the baseline counts above. Nobody reconciles this file later, and a stale entry is worse than no entry: it sends the next reader after work that no longer exists. Both halves of this have already happened here, once to seven entries at once, and once to a fix that landed without removing its own entry.

## Where the work is going

A plan that spans more than one session lives here, as phases with their
status, so the next reader can see the direction without reconstructing it.
Update the status in the pull request that moves a phase.

### Phase 0, before the RIB work resumes. In progress

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
5. **RFC 9072 extended OPEN is half done.** The outer header is right; each
   inner optional parameter still uses a one octet length where section 2
   wants two. Self consistent, wrong on the wire. Nothing in the tree cites
   RFC 9072.

Then, cheap and worth doing while there: **the BGP Role capability, code 9**
(RFC 9234 section 4), about two hours. The OTC attribute already exists with
its length check, and section 4.2 says a peer that sends no capability falls
back to the local Role, so OTC is usable today; the capability buys the Role
Mismatch and strict mode tests. GoBGP does not implement Role, so no current
lab topology can exercise it.

Also in phase 0: the stale citations the audits found. **Done**, in #118,
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
2. **The peer adapter and `rib.attach`, with loopback tests. Not started**,
   about 2 PRs. `Neighbor#rcv_update` is still an empty hook, so nothing feeds
   the table from a live session. It has to cover NLRI, withdrawn routes,
   MP_REACH, MP_UNREACH and add-path, call `peer_down` when a session drops,
   and feed the table from one worker thread. `BGP::Rib::Table` is documented
   as not thread safe and phase 2 is where that is resolved.
3. **Adj-RIB-Out, the export rules and the speaker's router mode. Not
   started**, about 3 PRs, with route reflector and transit lab topologies.
   The rules: do not send an iBGP learned route to another iBGP peer unless we
   are a route reflector (RFC 4456); toward eBGP prepend our AS, set the next
   hop to ourselves, strip LOCAL_PREF and do not pass MED beyond the
   neighbouring AS; honour NO_EXPORT and NO_ADVERTISE (RFC 1997); pack
   prefixes sharing attributes into one UPDATE, which `route_generator.rb`
   already does.
4. **FIB adapters and the Linux lab test. Not started**, about 2 PRs. The FIB
   is the kernel routing table and is a separate, optional adapter: Linux
   only, so it runs in a container, with a dedicated routing table, routes
   marked `proto bgp`, removed on exit, and never with `--network host`. This
   phase also carries the show commands: IOS, IOS-XR and Junos style output
   for routes and the Loc-RIB. The decision result already holds what they
   need, including the Junos "Inactive reason" line.
5. **FRR as a reference in the lab. Not started.**

Decisions already taken that constrain the later phases:

* Loc-RIB and FIB are separate. The Loc-RIB runs anywhere; the FIB is an
  adapter and optional.
* No policy language. Import and export take a Ruby block.
* The MRAI timer (RFC 4271 section 9.2.1.1) is a setting, defaulting to 0 in
  tests. The "oldest route wins" tie break is skipped or optional, so tests do
  not depend on timing.
* A full table is about a million IPv4 prefixes, so share identical attribute
  sets keyed by their encoded bytes rather than one object per route. Measure
  with `routegen`, do not guess.
* Dump the RIB to JSON, as the lab speaker dumps its state, so a test and a
  person can both see why a route won.

### Deliberately not in phase 0

Breadth, because it is a month and phases 2 and 3 are worth more. Recorded so
the decision is not re-litigated from scratch:

* **MP_REACH and MP_UNREACH read and write only SAFIs 1, 2, 4, 128 and 129.**
  That one limit blocks EVPN, flowspec, BGP-LS, RT-constrain, MCAST-VPN, VPLS
  and SR Policy together, so it is the single lever if breadth is ever wanted.
  `Mp_reach.new(:afi=>25, :safi=>70, ...)` raises today.
* BGP-LS (attribute 29, AFI 16388, SAFI 71 and 72, RFC 9552), EVPN (SAFI 70,
  RFC 7432, plus 14 unnamed EVPN extended communities), flowspec NLRI (SAFI
  133 and 134, RFC 8955 and RFC 8956, where all five traffic filtering
  communities are implemented but the rule cannot be sent), ATTR_SET
  (attribute 128, RFC 6368), RT-constrain (SAFI 132), MCAST-VPN (SAFI 5).
* Coverage as measured: 22 of 34 live path attribute code points, 29 of 115
  extended community sub-type code points, 8 of 22 live capability code
  points. The attribute figure reads worse than it is: FRR's `bgpd.h` defines
  exactly bgp4r's 22 plus two.

## Known issues to work on

Found while fixing other bugs, not fixed yet. Verified against master on
2026-10-27, so each one reproduces. Reproductions are one liners with
`ruby -I. -e '...'`.

Smaller things:

* A truncated ORF does not round trip byte for byte. `Orf.factory` reads the three octet header of RFC 5291 section 4 and trusts the Length of ORF entries: fewer than three octets left has no length to read, and a length longer than the octets left is not checked. Either way the octets are kept rather than dropped, but `encode` writes the real length back, so one trailing octet comes out as three: `ruby -I. -e 'require "bgp4r"; s=["ff"*16+"0018"+"05"+"0001"+"00"+"01"+"01"+"41"].pack("H*"); puts BGP::Message.factory(s).to_shex'` prints a message of 0x1b octets, not the 0x18 that went in. There is no way to re-encode an octet that is not a whole ORF, so this needs a decision, not a patch: either `Orf::Unknown` keeps the raw octets beside the fields it parsed, or the leftover belongs to the message and not to an ORF at all. Found while making an unimplemented ORF Type keep its octets.
* `test/unit/neighbor/neighbor_test.rb` includes `BGP`, `BGP::OPT_PARM::CAP` and `BGP::TestHelpers` into `Object`, at the top level and not inside the test class. Every test file `test/run_unit.rb` loads after it sees those names, and `BGP::OPT_PARM::CAP` wins over `BGP` for the ones they share, so a bare `Orf` in a later file means the ORF capability and not `BGP::Orf`. `Route_refresh` and `Dynamic` are the same shape. A test passes on its own and fails in the suite, which is a long way to go to find a missing two words. `test/unit/orfs/orf_test.rb` writes `BGP::Orf` in full and says why. Moving the three includes inside `Neighbor_Test` is the fix.
* The hash form of four `Extended_community::Typed` shapes drops reserved octets that the wire form keeps. A Typed community parsed from the wire keeps its 6 value octets in `@raw`, so `encode` gives them back, but `hash_value` carries only the fields its RFC defines, so a build from the hash writes the reserved ones as 0: `ruby -I. -e 'require "bgp/path_attributes/extended_communities"; ec=BGP::Extended_community.factory(["030cffffffff0008"].pack("H*")); puts BGP::Extended_communities.new(ec.to_hash).communities[0].to_shex'` prints `030c000000000008`. `Encapsulation` loses its 4 reserved octets (RFC 9012 section 4.1), `Traffic_marking` the 42 bits above the DSCP (RFC 8955 section 7.5), `Mac_mobility` its reserved octet and the 7 flag bits above sticky (RFC 7432 section 7.7), and `Esi_label` its 2 reserved octets and the low 4 bits of the label field (RFC 7432 section 7.5). `Traffic_action` is the one that does not: it carries a `:bits` key whenever a bit outside S and T is set, which is the shape a fix wants. Found by the sweep in `test_every_wire_form_the_factory_knows_survives_its_own_hash`, which sets those fields to 0 for that reason.
* `IPAddr.create` truncates an Integer that does not fit four octets, instead of refusing it, so a path attribute built from one carries a different address. The Integer branch is `IPAddr.new_ntoh([arg].pack('N'))`, and `pack('N')` keeps the low 32 bits: `ruby -I. -e 'require "bgp4r"; puts BGP::Next_hop.new(2**32+1).to_s; puts BGP::Originator_id.new(-1).to_s'` prints `'0.0.0.1'` and `'255.255.255.255'`. `Next_hop`, `Originator_id`, `Cluster_list` and `Aggregator` all build their address this way, and an Integer is never an IPv6 address there either. Per the rule on inputs a field cannot hold, the constructor should refuse it rather than send another address. Found while giving `IPAddr#^` a floor and a ceiling; `^` no longer uses `IPAddr.create`.
* An NSAP prefix whose Length field says more than 152 bits does not round trip, because `Nsap.new_nsap` clamps any length above 152 to 152 and nothing keeps the one that arrived: `ruby -I. -e 'require "bgp/nlris/prefix"; p BGP::Prefix.new_ntop(["a04900000000000000000000000000000000000000"].pack("H*"),3).to_shex'` prints `"9849000000000000000000000000000000000000"`, 20 octets for the 21 it was given, with the length octet down from 160 to 152. The build path clamps the same way: `BGP::Prefix.new("49.0001/160").mlen` is 152. The field still reads on, since `new_ntop` consumes `1+(plen+7)/8` octets whatever the length says, and `Prefix#syntactically_correct?` answers true, because the overflow never reaches the IPv4 and IPv6 route that records it. An NSAP address is 20 octets, so 160 is the length that fits it and 152 looks like an off by one; `Nsap#mlen` defaults to 160 and `Nsap#encode` handles it, only `new_nsap` refuses. Found while making `new_ntop` consume an NSAP prefix.
* `CAP::Mbgp` names no address family when IANA has no name for the AFI or the SAFI. Both `to_s` and `to_s_brief` interpolate `IANA.afi?` and `IANA.safi?`, which return nil: `ruby -I. -e 'require "bgp4r"; p BGP::OPT_PARM::CAP::Mbgp.new(999,77).to_s_brief'` prints `"MBGP , "`, and `to_s` prints `AFI  (999), SAFI  (77)`. Building is never validated, so any AFI or SAFI can be sent, and a Capability message then shows a row that names nothing. The default `to_s_brief` on `Capability` and the `Add_path` and `Extended_nexthop` overrides fall back to the number instead; `Mbgp` was left as it stood, since its brief form is pinned by tests. Found while giving every capability a brief form.
* `Capability#add` drops anything that is not a `Capability::Revision`, with no error, so a typo is silently a Capability message with no revision in it: `ruby -I. -e 'require "bgp4r"; m=BGP::Capability.new; m << "not a revision"; p m.encode.size'` prints `19`, the header alone. Same shape as `Orf_route_refresh#add` above. `Capability::Revision` takes the other side of it: it accepts any object as its capability, so `BGP::Capability::Revision.advertise(10,"x").to_s` raises `NoMethodError` on `to_s_brief`, which is a capability method. `test_capability_revision_o1` builds revisions around a String for that reason and never prints them.

* A capability with no value is built from its code and not from its wire bytes, so value octets that arrive are dropped and only two of its three build paths work. `Capability.factory` hands `CAP::Route_refresh` and `CAP::Dynamic` the capability code rather than the octets, since neither capability has a value to read. A peer that sends one with a value gets no complaint and no record of it: `ruby -I. -e 'require "bgp4r"; p BGP::OPT_PARM::Capability.factory(["0203020141"].pack("H*")).to_shex'` prints `"02020200"`, losing the `41`. Handed the wire bytes directly, both classes put the String in `@code`, so `BGP::OPT_PARM::CAP::Route_refresh.new(["02020200"].pack("H*")).encode` raises `TypeError: no implicit conversion of String into Integer` and `CAP::Dynamic`'s `to_hash` carries `{:code=>"\x02\x02C\x00"}`. `CAP::Enhanced_route_refresh` is the same zero length shape done the other way, taking the wire bytes and keeping any value in a `@value` it writes back, and the factory hands it the octets; the fix is to give these two the same treatment. Found while adding capability 70.
* The NOTIFICATION subcode registries are still short of IANA in two places, both display only. Subcode 0 is named in every one of them and in none of them here: "Unspecific" for codes 1, 2 and 3 (RFC Errata 4493), "Unspecified Error" for code 5 (RFC 6608), "Reserved" for codes 6 and 7. And OPEN Message Error subcodes 8, 9 and 10 are Deprecated and 11 is "Role Mismatch", all RFC 9234; 11 belongs with the BGP Role capability, which is listed under "Attribute work left". `Notification.code_to_s` answers "Undefined" for each, which is honest but less than it knows. Note that `code_to_s(0)` for the code itself is pinned to "Undefined" by `test_1`, where IANA says Reserved. Found by the registry sweep that fixed code 7.

* The Compatibility field of a withdrawn labeled route is read as a label, and does not round trip. RFC 8277 section 2.4 replaces the Label field of a withdrawal with a Compatibility field, whose "value of this field is of no significance": it SHOULD be sent as 0x800000 and MUST be ignored on reception. `Label#parse` has no idea it is in a withdrawal, so it reads the octets as a label, and `Label#encode` then sets the Bottom of Stack bit the field did not have: `ruby -I. -e 'require "bgp/nlris/label"; l=BGP::Label.new(["800000"].pack("H*")); p l.to_hash; p l.encode.unpack1("H*")'` prints `{:label=>524288, :exp=>0}` and `"800001"`, so the three octets that arrived come back changed. Two separate things are wrong: the S bit is forced on, which breaks the round trip rule for any single label parsed with S clear, and 524288 is not a label at all here. The second needs withdrawal context, which `Label` does not have and `Labeled` does not pass, so it is a `Labeled`/`Withdrawn` change rather than a `Label` one; the first is `encode`'s default `bottom=1`, which `Label_stack#encode` also relies on. Also display only but adjacent: bgp4r calls the 3 bits above the S bit `exp`, where RFC 5462 renamed them Traffic Class and RFC 8277 section 2.2 calls the field Rsrv. Found while replacing the stale RFC 3107 text in `nlris/nlri.rb` with a note that RFC 8277 obsoletes it.
* A String administrator in the three argument form of `Rd.new` takes `encode` down. Types 0 and 2 pack the administrator as an Integer, so an address String reaches `pack` as it was given: `ruby -I. -e 'require "bgp/nlris/rd"; BGP::Rd.new("1.1.1.1",1,0).encode'` raises `TypeError: no implicit conversion of String into Integer`. The two argument form reads a String administrator as the type 1 form and never gets there, and a named type 1 builds an `IPAddr` first, so only a named type 0 or 2, or a type the RFC does not define, hits this. Either those branches read the String the way type 1 does, or the constructor says the administrator of that type is an Integer. Found while carrying the encoding type through the hash form.

Lab and conformance:

* The GoBGP column in `docs/protocol-testing.md` was measured on 3.23 by hand, and holds for 4.10 too: the containerized test asserts every one of the 18 rows and passes on both. `GOBGP_IMAGE` switches versions without an edit. The FRR and BIRD columns are still from 8.4.4 and 2.14 run natively, and only the session level outcomes there, since BIRD gives no usable RIB answer over a loopback session.
* `lab/conformance/gobgpd.conf` and `lab/topologies/fault-matrix/gobgp.toml` are written in the 3.23 style and GoBGP 4 reads them unchanged. Every key is still in the 4.x config structs under the same `mapstructure` name, and 4.x registers `mapstructure.StringToNetIPAddrHookFunc` so the address fields still decode from TOML strings. No schema work is needed; an earlier version of this entry said otherwise and was wrong.
* `lab/topologies/fault-matrix` exits 1, and that is the right answer: GoBGP discards the malformed tunnel encapsulation attribute and installs the route where RFC 9012 section 13 asks for treat-as-withdraw. Both cases are asserted as a known divergence in `test/functional/lab/fault_matrix_test.rb`; see the comment on `TUNNEL_ENCAP` there. It is not an old bug since fixed: 3.23 does it, and a CI run on 4.10 does it too, so it is worth reporting upstream.
* No lab topology exercises add-path against a real router, which is why the inverted Send/Receive field survived: `test/functional/add_path_test.rb` runs bgp4r against bgp4r, where an inverted field cancels. The fix now has tests that write the field value itself on one side, in `test/unit/optional_parameters/add_path_test.rb`, `test/unit/neighbor/add_path_cap_test.rb` and `test/functional/add_path_test.rb`, so the direction is pinned without a second implementation. A GoBGP topology is still worth having and is four pieces, none of which exists: `Neighbor#capability` takes no `:add_path` symbol, so `lab/speaker.rb`'s `add_capability` cannot name it; an announce block has no way to give a prefix a Path Identifier, since `build_update` calls `Nlri.new` with plain prefix strings; `Lab::Recorder#record_routes` keys received routes by prefix alone, so two paths for one prefix overwrite each other and the state file cannot show a Path Identifier arrived; and GoBGP needs `add-paths` with `send-max` in its config. Do it as its own pull request, with a `lab/topologies/add-path` and a Compose test beside the other three.
* Lowest coverage (unit suite): `neighbor/neighbor.rb` 89%, `path_attributes/origin.rb` 91%, `messages/update.rb` 92%, `optional_parameters/graceful_restart.rb` 92%, `path_attributes/mp_unreach.rb` 93%.

## Attribute work left

RFC sections deliberately not implemented, each noted in the pull
request that added the attribute:

* Tunnel Encapsulation (23): the five per tunnel type Encapsulation sub-TLV shapes, RFC 9012 sections 3.2.1 to 3.2.5, for VXLAN, NVGRE, L2TPv3, GRE and MPLS-in-GRE. The attribute keeps their octets, so a test can still build any of them by hand.
* Tunnel Encapsulation: the SR Policy sub-TLVs, types 12 to 15, 20 and 128 to 130, from RFC 9830, "Advertising Segment Routing Policies in BGP". RFC 9256 is the SR Policy architecture and defines no sub-TLV; IANA gives RFC 9830 as the reference for all eight code points. The Prefix-SID sub-TLV, type 11, is RFC 9012 section 3.7, so it is RFC 9012 work and not outside work like the rest of this entry.
* Prefix-SID (40): the SRv6 TLVs of RFC 9252, and the RFC 8669 section 4.1 rule for labeled unicast.
* RFC 9234 section 4: the BGP Role capability. Only the OTC attribute is implemented.
* No check for a missing well known mandatory attribute. That needs `Update`, not `Path_attribute`, because it depends on whether the message carries NLRI.
* The external peer rules for LOCAL_PREF, ORIGINATOR_ID and CLUSTER_LIST, and the RFC 7311 section 3.2 AIGP checks. bgp4r does not know whether a peer is external where the checks run.
* Not started: BGP-LS, ATTR_SET, BGPsec_Path.
