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
                         peer_adapter.rb turns a Neighbor's UPDATEs into table operations,
                         peer_feed.rb applies them on one worker thread; rib.attach(neighbor)
                         export.rb decides what goes to a peer and what its attributes become,
                         adj_rib_out.rb records what was sent, update_builder.rb packs
                         prefixes into UPDATEs, mrai.rb paces them per destination,
                         router.rb joins them and sends; rib.advertise; show.rb prints
                         the Loc-RIB the way a router would, rib.show;
                         see "Where the work is going"
bgp/misc/                extras: route_generator.rb (many prefixes packed in UPDATEs), live_feed.rb (a client for an old public BGP feed)
docs/                    protocol-testing.md: using bgp4r to test a router
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
                         native gobgpd, so a real router says what it makes of it
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

Lab tests (the Compose ones skip without Docker, the native fault matrix
without `gobgpd`):
```
ruby test/run_lab.rb
```

Against a real router, with no Docker at all. Both need `gobgpd` on
`PATH`, or `GOBGPD` and `GOBGP` naming the binaries, which is how one
machine answers for more than one GoBGP version. The fault matrix takes a
few minutes; the export side takes about 30 seconds:
```
ruby -I. test/functional/lab/fault_matrix_native_test.rb
ruby -I. test/functional/lab/rib_router_gobgp_test.rb
```

Do not run `test/functional/live_feed_test.rb`. It connects to a public feed that no longer answers and hangs forever.

In Docker, on any Ruby version (the default is 3.4):
```
docker build --target test --build-arg RUBY_VERSION=4.0 -t bgp4r-test .
docker run --rm bgp4r-test
docker run --rm bgp4r-test ruby -I. test/functional/add_path_test.rb
```
The image runs as the non-root user `bgp`. It can still bind TCP 179, because Docker sets `net.ipv4.ip_unprivileged_port_start=0` in a container's own network namespace. With `--network host` the host's setting applies.

CI: `.github/workflows/test.yml` runs both suites on every push to master and every pull request, on Ruby 3.3, 3.4, 4.0 and head (head may fail), both on the runner and in the Docker image. A `lab` job runs the Compose topologies, and installs a `gobgpd` release so the native fault matrix runs there too; it pins 3.23.0, where the Compose topology pins a 4.x image, so CI measures both.

Baseline on 2026-10-28: 1257 tests, 21751 assertions, all passing. Line coverage of `bgp/` from the unit suite: 97.5%.

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
  * A reserved field inside a fixed layout value is the same rule one level down. An `Extended_community::Typed` parsed from the wire keeps its 6 value octets, so `encode` gives them back, and its hash carries a `:bits` entry, all 48 bits of the value, when a bit outside the fields its own RFC defines is set. `DEFINED_BITS` on the class says which bits it reads, with the RFC text beside it, and `Typed#value_bits`, `#undefined_bits?`, `#keep_bits` and `#with_bits` do the rest in one place. Same rule as a tail: no reserved bit set, no `:bits` entry, so the hash stays the value or the list it has always been. `Traffic_action` is where the shape came from. A build from field values still writes the reserved fields as 0, which is what those RFCs ask an encoder for.
* Every class can be built three ways: from field values, from a hash, and from its wire bytes (a binary String). Keep all three working when you change a class.
* `encode` returns wire bytes. `to_hash` returns a hash that round trips through `new`. `to_s` returns the human readable form.
* Tests check round trips: build, encode, parse back, compare. Use real hex captures from the RFCs or from Wireshark when possible.
* One test file per source file, same name with `_test.rb`, in the matching folder under `test/unit/`.
* Write `BGP::` names out in full in a test file, and `include` into the test class, never at the top level. A top level `include` goes into `Object`, so every test file the suite loads after it sees those names, and `BGP::OPT_PARM::CAP` wins the ones it shares with `BGP`: a bare `Orf` then means the ORF capability and not `BGP::Orf`, and a bare `Route_refresh` the capability and not the message. A test written that way passes on its own and fails in the suite. `test/unit/neighbor/neighbor_test.rb` did this until it was fixed, and `test_no_test_file_leaks_bgp_names_into_object` there now guards it for the whole suite, since `run_unit.rb` requires every file before any test runs.
  * A nested class does **not** see the `include` in the class around it, because constant lookup goes up the lexical scope and then the ancestors of the innermost class, not the ancestors of the enclosing one. `TestBgpNeighbor::UpdateCatcher` resolved `Update` only through that top level leak. Write the full name in a nested class.
  * A `NameError` in an observer is invisible: `Neighbor` logs an exception from an observer rather than raising it, deliberately, so nothing outside can kill the FSM. A test observer with a wrong constant therefore fails as "nothing was received" and says nothing about the name. That is how the leak stayed load bearing.
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
GoBGP's opinion of it. Phase 4's show commands are done for IOS and Junos;
what is left of that phase is the FIB adapter, which needs a container.

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
4. **FIB adapters, and the show commands. In progress.**
   1. **The show commands. Done for IOS and Junos**, in #132.
      `bgp/rib/show.rb`, reached as `rib.show`, `rib.show(:junos)` and
      `rib.show(:junos, prefix)`. The decision result already held what
      they needed, including the Junos "Inactive reason" line.
      * **These are in the style of those commands, not copies.** Two
        things are reproduced from samples in the vendors' own
        documentation: the IOS header, legend and column layout, and the
        Junos detail shape with its Preference, State and Inactive reason
        lines. Nothing here has been diffed against a real device, so no
        test anywhere should depend on this text byte for byte.
      * **IOS-XR is not done**, and that is the honest gap: no sample of
        its `show bgp` output could be found to check against, and
        inventing a format while calling it IOS-XR is worse than not
        having it. The plan named three styles; two are real.
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
   2. **The FIB adapter and the Linux lab test. Not started**, about 2 PRs.
      This one does want a container, and not for the reason part 7 of
      phase 3 was thought to: the FIB is the kernel routing table, so the
      test needs a network namespace of its own, with a dedicated routing
      table, routes marked `proto bgp`, removed on exit, and never with
      `--network host`. A native run would write to the machine's own
      routing table, which is why a daemonless sandbox does not help here
      the way it does for a BGP peer. There is no Docker daemon in the
      sandbox this was written in.
5. **FRR as a reference in the lab. Not started.**

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

* A prefix ORF entry drops the 5 reserved bits of its first octet, so it does not round trip byte for byte. RFC 5291 section 4 encodes the common part of an ORF entry in that octet: "Action is a two-bit field", "Match is a one-bit field" and "Reserved is a 5-bit field". `Prefix_entry#_parse_` reads only Action and Match, and `_first_octet_` writes the rest as 0: `ruby -I. -e 'require "bgp4r"; o=BGP::Orf.factory(["40000b1f00000001182018c0a801"].pack("H*").is_packed); puts o.to_shex'` prints `40000b0000000001182018c0a801`, where `1f` came in and `00` goes out. The RFC asks an encoder for 0 and a decoder to ignore them, so this is right by the RFC and wrong by bgp4r's own rule that octets which arrived come back: a capture of a router that sets them cannot be sent again. The fix has a precedent, the `:bits` entry #145 gave `Extended_community::Typed`: keep all 8 bits, hash them only when one outside Action and Match is set, and let a build from values keep writing 0. Found while making a truncated ORF round trip.
* `Nsap.new` and `Nsap.new_nsap` disagree on the default prefix length, so the same address string gives two different prefixes depending on which constructor built it: `ruby -I. -e 'require "bgp/nlris/nsap"; p [BGP::Nsap.new("49.0102.0304.0506.0608.0910.1112.1314.1516.1718.ff").mlen, BGP::Nsap.new_nsap("49.0102.0304.0506.0608.0910.1112.1314.1516.1718.ff").mlen]'` prints `[160, 152]`. `Nsap#mlen` falls back to 160, the whole twenty octet address, where `new_nsap` writes `len ||= 152` and so masks the twentieth octet away and encodes nineteen. 160 is the one that matches the rest of the class, including `MAX_MLEN` and `prefix_mask_bits`. It was left alone when the clamp above it was fixed, because `test_new_nsap` and `test_nsap` both pin the 152 default and the fix moves them, which makes it a behaviour change of its own rather than part of that one. Found while raising the clamp from 152 to 160.

* An optional parameter bgp4r cannot read takes down the parse of the whole OPEN, where an unimplemented ORF type has kept its octets since #101. Two shapes. A Parameter Type other than 2 raises: `ruby -I. -e 'require "bgp4r"; BGP::Message.factory(["ff"*16+"0020"+"01"+"04"+"0064"+"00b4"+"0a000001"+"04"+"01020000"].pack("H*"))'` raises `RuntimeError: Optional parameter type '1' not implemented`, and the IANA "BGP OPEN Optional Parameter Types" registry has 1 as Authentication, Deprecated, referencing RFC 4271 and RFC 5492, so a peer may well send one; 3 to 254 are unassigned and a negative test wants to send those too. And a Parameter Length longer than the octets behind it loses them: type 2 length 9 with nothing after it comes back as an Optional Parameters Length of 0 with no parameters, because `Optional_parameter.factory` slices what is there and `capabilities` finds no whole capability in it. Both want the same thing, an `Optional_parameter::Unknown` beside `Orf::Unknown`: keep the type, the declared length and the value octets, and write them back. Three build paths and a `:value` hash key, the way that class has them. Found while making a truncated parameter header round trip, which fixed only the message level half.
* `Open#to_hash` does not round trip through `new`, because `Open` has no hash build path at all: `ruby -I. -e 'require "bgp4r"; o=BGP::Open.new(4,100,180,"10.0.0.1",BGP::OPT_PARM::CAP::Route_refresh.new); BGP::Open.new(o.to_hash)'` raises `IPAddr::AddressFamilyError: address family must be specified`, since the hash falls into the positional branch and becomes the version. Every other class in bgp4r builds three ways and this one builds two, so the convention's third path is missing for the message a session starts with. A fix needs a Hash branch in `initialize` that reads `:version`, `:my_as`, `:holdtime`, `:bgp_id` and rebuilds each capability from `:capabilities`, which `Orf.from_hash` is the shape for, and it should read the `:tail` and `:opt_parm_len` keys `to_hash` now writes. Found while adding those two keys.

* The Compatibility field of a withdrawn labeled route is read as a label, and where the prefix is three octets or more it swallows the prefix too. RFC 8277 section 2.4 replaces the label of a withdrawn route with a Compatibility field that "SHOULD be set to 0x800000", whose Bottom of Stack bit is 0, and section 2.2 says that bit "MUST be set to one on transmission" precisely so a reader can find the end of the stack. With it clear the octets are ambiguous, and `Label_stack#parse` has only the bit to go on: `ruby -I. -e 'require "bgp4r"; puts BGP::Labeled.new(["308000000a0000"].pack("H*").is_packed,1,4).to_s'` prints `Label Stack=524288,40960 (bottom) 0.0.0.0/0` for a withdrawal of 10.0.0.0/24, reading the Compatibility field as a label and the prefix as a second one. The octets come back byte for byte since #150, so nothing is corrupted on the way out and a capture can be sent again, but the reading is wrong. The only fix is to know the NLRI came from MP_UNREACH_NLRI, which is where section 2.4 says a withdrawal travels: so this is an `Mp_unreach` change that passes the fact down through `Labeled` to `Label_stack`, **not** a `Withdrawn` change as this entry said before #150. The RFC 4271 section 4.3 Withdrawn Routes field carries no labels, since a labeled route needs a SAFI. A withdrawal whose prefix is shorter than three octets reads correctly today, because the walk runs out of octets first.
* Two smaller things in the same field, both found with the one above. `Label` calls the 3 bits above the Bottom of Stack bit `exp`, in `@exp` and in the `:exp` hash key, where RFC 8277 section 2.2 calls that field Rsrv: "This 3-bit field SHOULD be set to zero on transmission and MUST be ignored on reception". The name `exp` comes from the MPLS shim header, a different field, whose EXP bits RFC 5462 renamed Traffic Class; an earlier version of this entry carried that rename over to this field, which was wrong. Renaming the hash key breaks the hash build path for every caller, so it wants a deliberate decision rather than a patch. And `Label_stack#to_hash` keeps only the label numbers, `{:label=>100}` or `{:labels=>[100,101]}`, so Rsrv and the Bottom of Stack bit are lost there even though `Label#to_hash` carries both: `Labeled#to_hash` merges that, so a labeled NLRI's hash cannot rebuild its own octets. Widening it changes the shape of `Labeled#to_hash` for every caller and test, which is the same decision.

Lab and conformance:

* **GoBGP runs natively, so the fault matrix needs no Docker.** `gobgpd` from a release tarball peers with bgp4r on loopback, and `test/functional/lab/fault_matrix_native_test.rb` runs the whole matrix against it. Both sides get a port of their own, so neither needs root nor `net.ipv4.ip_unprivileged_port_start`: the generated config sets `[global.config] port` and `[neighbors.transport.config] remote-port`, both of which GoBGP 3 and 4 honour. `LabHelper::Gobgpd` writes that config and starts the daemon. This is the harness to reach for before assuming a conformance question is blocked. `docs/protocol-testing.md` has the recipe under "On a Linux VM": how to get a particular version from a release tarball, with its checksum, and the two config keys that keep both ends off port 179. **Check which version you have**, because it changes the answers: Ubuntu 24.04's `gobgpd` package is 3.23.0, and GoBGP publishes Linux builds only.
* The two GoBGP columns in `docs/protocol-testing.md` are asserted by the two fault matrix tests, so they are re-measured rather than recorded by hand. **The versions do not answer alike, and the column used to claim they did.** GoBGP 3.23.0 resets with subcode 5 on `attr_overrun` where RFC 7606 section 4 makes treat-as-withdraw a MUST; GoBGP 4.10.0 fixed it. So 4.10.0 agrees on 16 of the 18 rows and 3.23.0 on 15. The expectations are per version in `test/functional/lab/fault_matrix_scenario.rb`: the native test asks the binary, and the Compose test reads `GOBGP_IMAGE`, so keep those in step if the pin moves. The FRR and BIRD columns are still from 8.4.4 and 2.14 run natively and measured by hand, and only the session level outcomes there, since BIRD gives no usable RIB answer over a loopback session.
* How that wrong row survived is the lesson, not the row. The table was measured by hand once and never re-run, because the only harness that could re-run it needed a Docker daemon that the sandbox did not have. A conformance claim nothing checks reads as verified, exactly like an unread RFC citation, and this one sat in the docs, in `CLAUDE.md` and in a test's comments at the same time.
* `lab/conformance/gobgpd.conf` and `lab/topologies/fault-matrix/gobgp.toml` are written in the 3.23 style and GoBGP 4 reads them unchanged. Every key is still in the 4.x config structs under the same `mapstructure` name, and 4.x registers `mapstructure.StringToNetIPAddrHookFunc` so the address fields still decode from TOML strings. No schema work is needed; an earlier version of this entry said otherwise and was wrong.
* `lab/topologies/fault-matrix` exits 1, and that is the right answer: GoBGP discards the malformed tunnel encapsulation attribute and installs the route where RFC 9012 section 13 asks for treat-as-withdraw. Both cases are asserted as a known divergence; see the comment on `TUNNEL_ENCAP` in `test/functional/lab/fault_matrix_scenario.rb`. It is not an old bug since fixed: 3.23.0 and 4.10.0 both do it, measured natively on each, so it is worth reporting upstream.
* No lab topology exercises add-path against a real router, which is why the inverted Send/Receive field survived: `test/functional/add_path_test.rb` runs bgp4r against bgp4r, where an inverted field cancels. The fix now has tests that write the field value itself on one side, in `test/unit/optional_parameters/add_path_test.rb`, `test/unit/neighbor/add_path_cap_test.rb` and `test/functional/add_path_test.rb`, so the direction is pinned without a second implementation. #124 added the other half that was missing, `test_add_path_puts_two_paths_to_one_prefix_in_the_table` in `test/functional/rib_feed_test.rb`: a loopback session that negotiates the capability, carries two paths to one prefix into a RIB with their Path Identifiers, and withdraws one of them by Identifier. That is still bgp4r against bgp4r. A GoBGP topology is still worth having and is four pieces, of which one exists: `Neighbor#capability` takes `:add_path` since #144, and a topology can ask for it with its arguments, `capabilities: [{add_path: [1, 1, 3]}]`. The other three: an announce block has no way to give a prefix a Path Identifier, since `build_update` calls `Nlri.new` with plain prefix strings; `Lab::Recorder#record_routes` keys received routes by prefix alone, so two paths for one prefix overwrite each other and the state file cannot show a Path Identifier arrived; and GoBGP needs `add-paths` with `send-max` in its config. Do it as its own pull request. A Compose topology is one way; the cheaper one now is a native test on the `LabHelper::Gobgpd` shape, since that needs no daemon, and `Gobgpd#config` would take the `add-paths` and `send-max` keys.
* Lowest coverage (unit suite): `path_attributes/origin.rb` 91%, `neighbor/neighbor.rb` 91%, `messages/update.rb` 92%, `optional_parameters/graceful_restart.rb` 92%, `path_attributes/mp_unreach.rb` 92%.

## Attribute work left

RFC sections deliberately not implemented, each noted in the pull
request that added the attribute:

* Tunnel Encapsulation (23): the five per tunnel type Encapsulation sub-TLV shapes, RFC 9012 sections 3.2.1 to 3.2.5, for VXLAN, NVGRE, L2TPv3, GRE and MPLS-in-GRE. The attribute keeps their octets, so a test can still build any of them by hand.
* Tunnel Encapsulation: the SR Policy sub-TLVs, types 12 to 15, 20 and 128 to 130, from RFC 9830, "Advertising Segment Routing Policies in BGP". RFC 9256 is the SR Policy architecture and defines no sub-TLV; IANA gives RFC 9830 as the reference for all eight code points. The Prefix-SID sub-TLV, type 11, is RFC 9012 section 3.7, so it is RFC 9012 work and not outside work like the rest of this entry.
* Prefix-SID (40): the SRv6 TLVs of RFC 9252, and the RFC 8669 section 4.1 rule for labeled unicast.
* No check for a missing well known mandatory attribute. That needs `Update`, not `Path_attribute`, because it depends on whether the message carries NLRI.
* The external peer rules for LOCAL_PREF, ORIGINATOR_ID and CLUSTER_LIST, and the RFC 7311 section 3.2 AIGP checks. bgp4r does not know whether a peer is external where the checks run.
* Not started: BGP-LS, ATTR_SET, BGPsec_Path.
