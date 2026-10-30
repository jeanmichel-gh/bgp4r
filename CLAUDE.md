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
                         RFC 8956 section 3 flow spec components, pure; nothing
                         dispatches to them yet, see "Breadth, the one SAFI lever"
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
                         before touching flow_spec_component.rb, before adding a
                         flow spec family to mp_reach.rb, or before adding one of
                         the missing action communities. Its load bearing claims
                         are asserted by test/unit/flow_spec_doc_test.rb
                         building-objects.md: the three ways into every class and how
                         initialize dispatches between them; read it before changing a
                         constructor or chasing an object that does not come back.
                         Its load-bearing claims are asserted by
                         test/unit/building_objects_test.rb
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
                         and rib_router_frr_test.rb points our export side at it
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

Against a real router, with no Docker at all. These need `gobgpd` on
`PATH`, or `GOBGPD` and `GOBGP` naming the binaries, which is how one
machine answers for more than one GoBGP version. The fault matrix takes a
few minutes; the other two take about 30 seconds each:
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
run of this. A few minutes:
```
ruby -I. test/functional/lab/fault_matrix_frr_test.rb
```

And bgp4r's export side against FRR, the twin of the GoBGP one, about a
minute:
```
ruby -I. test/functional/lab/rib_router_frr_test.rb
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

CI: `.github/workflows/test.yml` runs both suites on every push to master and every pull request, on Ruby 3.3, 3.4, 4.0 and head (head may fail), both on the runner and in the Docker image. A `lab` job runs the Compose topologies, and installs a `gobgpd` release so the native fault matrix runs there too; it pins 3.23.0, where the Compose topology pins a 4.x image, so CI measures both.

Baseline on 2026-10-30: 1455 tests, 23022 assertions, all passing. Line coverage of `bgp/` from the unit suite: 97.7%.

There is no coverage gem in the `Gemfile`. To measure, use Ruby's built-in `Coverage`: start it, register the report with `at_exit` before requiring any test file so it runs after the suite, then require `test/unit/**/*_test.rb`.

## Conventions

* **Building and encoding are never validated, and that is a feature.** This library is used for negative testing: it has to put bytes on the wire that no RFC allows, so a real router can be watched handling them. Any attribute, any length, any combination, any flags. Never add a check to a constructor, to `encode`, or to `to_hash` that refuses something merely invalid. Removing that ability breaks the main reason the library exists.
  * Validation lives in exactly one place, `bgp/path_attributes/validation.rb`, and runs only when parsing what was received. It is reported through `Path_attribute#errors` and raised only under the `:strict` receive policy. Add a rule there, with its RFC section, never in the attribute.
  * `Path_attribute#errors` means what the peer got wrong, and nothing else. A valid attribute bgp4r cannot decode is bgp4r's coverage gap, not a protocol error: RFC 7606 section 7 says attribute by attribute what makes one malformed, and a reader's missing code is on none of those lists. Those go in `Path_attribute#undecoded` as `Attr::Gap`, which `:strict` never raises on. Do not put a fact about bgp4r in `errors`; a conformance tool that calls its own gap a protocol error gives a confident wrong verdict about a correct router.
  * A constructor may refuse an input it cannot represent at all, such as an Integer too large for the field it goes in, because the alternative is silently sending a different value. It must never refuse a combination that is simply wrong by the RFC. Where a constructor does refuse, the octet level routes stay open and must keep working: wire bytes, `Attr::Raw`, and the `BGP::Fault` helpers.
  * **The message header Length is computed, not configurable, and that is deliberate.** `Message#encode` writes `message.size + 19`, and `Message#parse` unpacks the field into `_` and discards it. A tool for testing the protocol needs the header arithmetic right every time or every other result it produces is in doubt, so `encode` takes no length argument and **should not grow one**: that plumbing belongs in the test, not in the library. A test that wants a wrong Length overrides `encode` at runtime on the one object it is lying with, and `bgp/io.rb` writes `obj.encode` at send time, so the override reaches the wire through the ordinary `send_message` path while the class stays untouched: `u.define_singleton_method(:encode) { |*a| s = super(*a) ; s[16,2] = [9999].pack('n') ; s }`. Patching the encoded String and passing that to `send_message`, which takes a String and queues it unchanged, is the other route. Checked against GoBGP, which took the octets as written and waited for the rest of the length it had been promised. An earlier version of this file filed this as a bug, calling the Length the one field that cannot be made to lie. That was wrong twice over.
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
* **A test method after `private` in a test file never runs, and nothing says so.** `test/unit/path_attributes/mp_unreach_test.rb` keeps an `attr_len` helper under a `private`, and two tests appended after it in #161 left the file reporting 7 tests where 9 were defined: test-unit collects public methods only, so both were skipped in silence and the file passed. It was the regression check that caught it, not the run, because proving a new test fails against the unfixed code is the one thing a skipped test cannot do. Add tests above any `private`, and if a count looks low, compare it against `grep -c 'def test_'`.
* Two space indent. Match the style of the file you edit.
* Copyright headers. A new Ruby file or Dockerfile starts with the standard GPL header from `bgp/observable.rb`, with `Copyright <current year> Jean-Michel Esnault.` (a Dockerfile drops the `#--` and `#++` lines). When you change a file that has a header, add the current year to its years if it is missing: `2008, 2009` becomes `2008, 2009, 2026`. Do not add headers to files that never had one. YAML, Markdown and other config files get no header.
* Keep the library free of runtime gem dependencies. The one exception is `logger`: it ships with Ruby, but Ruby 4.0 made it a bundled gem, so `bgp4r.gemspec` and the `Gemfile` declare it.
* Before requiring a standard library, check that it is still a default gem. Ruby keeps moving libraries to bundled gems (`observer` in 3.4, `logger` in 4.0), and under Bundler those fail to load unless declared. Prefer a small built-in copy, as with `BGP::Observable`.
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

## Rules for agents

* Work on a branch named `claude/<short-topic>`. Never push to master. The agent tooling may put its scratch worktrees in `.claude/worktrees/`, which `.gitignore` covers; they are whole checkouts, not bgp4r source, and must never be committed.
* If `gh pr create` fails with HTTP 403, GitHub's GraphQL API is blocked in that sandbox. Open the pull request with `gh api repos/{owner}/{repo}/pulls --method POST` instead.
* **Do not stack a pull request on another one's branch.** Merging the parent deletes its branch, and GitHub then **closes** the child rather than retargeting it, and a closed pull request can be neither reopened nor rebased onto master through the API: "The pull request cannot be reopened" and "Cannot change the base branch of a closed pull request". The work is not lost, since the branch is still there, but the review history is, and a new pull request has to be opened. That happened to #163, stacked on #162. If a change really does depend on an unmerged one, branch from master anyway and say in the description which pull request to merge first, or wait.
* One topic per pull request. Small diffs.
* Run the full unit suite before opening a PR. All tests must pass.
* New behavior needs a test. Bug fixes need a test that failed before the fix.
  * **Check that the proof proved something.** Two "this test catches the regression" runs in one session proved nothing: the first patched a marker string that did not match, so the library was unchanged and the test passed for the obvious reason, and the second made a change the constructor was lenient enough to absorb, so the round trip still worked and the test was right to pass. A sabotage run that passes means the sabotage missed, not that the test is weak. Assert on the thing you changed before you believe the result, and prefer breaking the code the way it would really break, which is usually deleting a line rather than mutating a value.
* **A claim nothing checks reads as verified, in a document as much as in a comment.** The lesson came twice. Once from the conformance table, measured by hand and never re-run. Once from `docs/to-hash-round-trips.md`, since **retired**, where the tables stayed true across four pull requests because `to_hash_round_trip_test.rb` compares them against the catalog row by row, while the prose beside them drifted into ranking work that two of those pull requests had already finished. The enforced half held and the unenforced half did not, in one file, with nobody noticing. That is what retiring it was for: what a person reads is printed from the catalog now, by `rake to_hash:status`, so there is no unenforced half left to drift. So when a document makes claims a test could make, assert the load-bearing ones: `test/unit/building_objects_test.rb` is what that looks like, and writing it corrected two claims in the document it guards within the hour.
* **Work out what the code and the tests were built to do before concluding that any of it is wrong.** bgp4r is behind on BGP features and it is not behind on robustness: encoding and decoding have held up for years because the test coverage around them is extensive and deliberate. So a shape that looks odd is far more likely to be a decision whose reason is not written down than a defect, and the burden is on the reader to find the reason first. This was said on 2026-10-29 after two claims in one afternoon that failed the same way.
  * **The two NLRI dispatch points.** Recorded as drifted apart, because parse groups SAFI 4 with 128 and 129 and build does not. `Labeled#parse` branches on the SAFI itself: parse is one entry point dispatching internally, build dispatches externally because the caller must supply an RD for the VPN families and not for SAFI 4. A difference in the work, read as a defect in the code. It cost a closed pull request, #173.
  * **The `#TODO class Error.....` in `Nlri.factory`.** Recorded as asking for the wrong thing. It asks for a typed exception where there is a bare `RuntimeError`, which is both modest and right. Four words were read as the opposite of what the surrounding code does.
  * What would have caught both in a minute each: read the method the branch calls before calling the branching wrong, and read what a TODO's own words ask for rather than what a plan needs them to ask for. **Say "I do not know why this is like this" rather than "this is wrong"** until the first has been answered; the file is full of entries that exist because somebody wrote the second.
* **A "won't fix" has to record the mechanism, not the verdict.** One was written in this session and reversed an hour later by a single question from the owner: "order should not matter when you recreate an object from a hash, care to explain the concern?" The premise was true, that a Hash keyed by attribute type cannot hold two of a type or say which came first. The conclusion, that nothing readable could be done, did not follow from it, and the prose had carried the premise's authority over to the conclusion. Two things would have caught it. State the premise and the conclusion as separate sentences and check the second follows from the first. And name the bar you are measuring against, because the real mistake was taking byte-exact octets as the bar for a hash whose job is to rebuild instance state.
* Cite the RFC section in a comment when you implement or fix wire format logic. Open the RFC and check the section number against its text; do not write one from memory. Six citations in this file and in the code were found wrong on 2026-10-27. One of them, "RFC 5291 section 5" for the ROUTE-REFRESH and ORF layout, is section 4, and it had been copied forward into two pull requests before anyone read the RFC. **Both numbers are live in that RFC and mean different things**, which is how the mix up happened and how it could happen again: section 4 is the ORF entry inside a ROUTE-REFRESH, whose Reserved is 5 bits of one octet and is "set to 0 on transmit and ignored on receipt", and section 5 is the Outbound Route Filtering Capability, whose Reserved is a whole octet that the section labels in Figure 3 and never describes. Do not quote section 4's sentence about the capability's octet. Figure 3 also says "Number of ORFs" where section 5's own text says "Number of ORF Types"; they are one field. Another called 0x02 and 0x03 extended community types when they are sub-types. A wrong citation is worse than none, because it reads as verified and sends the next person to the wrong page.
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

* **MP_REACH and MP_UNREACH read and write only SAFIs 1, 2, 4, 128 and 129.**
  That one limit blocks EVPN, flowspec, BGP-LS, RT-constrain, MCAST-VPN, VPLS
  and SR Policy together, so it is the single lever if breadth is ever wanted.
  `Mp_reach.new(:afi=>25, :safi=>70, ...)` raises today.
* BGP-LS (attribute 29, AFI 16388, SAFI 71 and 72, RFC 9552), EVPN (SAFI 70,
  RFC 7432, plus 14 unnamed EVPN extended communities), flowspec NLRI (SAFI
  133 and 134, RFC 8955 and RFC 8956, where every traffic filtering
  action of RFC 8955 section 7 is implemented, seven type and sub-type
  combinations for five action kinds, but the rule cannot be sent), ATTR_SET
  (attribute 128, RFC 6368), RT-constrain (SAFI 132), MCAST-VPN (SAFI 5).
* Coverage as measured: 22 of 34 live path attribute code points, 29 of 115
  extended community sub-type code points, 8 of 22 live capability code
  points. The attribute figure reads worse than it is: FRR's `bgpd.h` defines
  exactly bgp4r's 22 plus two.

### Breadth, the one SAFI lever. Phase 2 under way

The section above deferred breadth and named the single limit. This is the
plan for lifting it, recorded before the work starts.

**Where the limit actually is**, read in the code rather than recalled.
Two dispatch points, both a hard coded `case safi`, and no registry:

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
2. **Flowspec, SAFI 133 and 134, RFC 8955 and RFC 8956. Part 1 of 3
   done.** First of the real families, for three reasons. bgp4r is
   already half built here, since every traffic filtering action of RFC
   8955 section 7 is implemented and the rule they filter cannot be
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
   2. **The NLRI, and wiring it to the two dispatch points. Not
      started.** `Flow_spec` itself: the section 4.1 length framing, the
      component list, and the section 8 Route Distinguisher for SAFI 134.
      Four facts to build it on, all read in the text:
      * **The prefix assumption is in `Mp_reach#parse` and
        `Mp_unreach#parse`, not in the NLRI classes.** Both loops compute
        the slice length themselves, `value.slice!(0,(blen+7)/8+1)`, and
        hand that slice to the NLRI class. For flowspec that is wrong
        twice: section 4.1's length is in **octets**, not bits, and it is
        1 or 2 octets wide. So those two loops have to ask the family how
        long the next NLRI is rather than working it out. That is the
        real structural work in this phase, and it is a third loop in
        `Mp_reach#parse` for AFI 3 that flowspec does not reach.
      * Section 4.1: a length below 240 is one octet, otherwise two with
        the top nibble 0xf, the highest value 4095. The RFC's own
        examples: "the length value of 239 is encoded as 0xef (single
        octet), while 240 is encoded as 0xf0f0 (2 octets)".
      * Section 4: "When advertising Flow Specifications, the Length of
        the Next-Hop Network Address MUST be set to 0. The Network
        Address of the Next-Hop field MUST be ignored." So `Mp_reach`
        writes no next hop for these, which nothing in it does today.
      * Section 8, SAFI 134: "a fixed-length Route Distinguisher field (8
        octets) followed by the Flow Specification NLRI value", and "The
        NLRI length field shall include both the 8 octets of the Route
        Distinguisher as well as the subsequent Flow Specification NLRI
        value."
      * Validation goes in `validation.rb` and nowhere else, per
        Conventions. **Be exact about whose rule that is, because an
        earlier version of this entry called it a receive side rule and
        it is not.** Section 4.2: "Components MUST follow strict type
        ordering by increasing numerical order. A given component type
        MAY (exactly once) be present in the Flow Specification." That
        MUST binds a **sender** as much as a receiver, so bgp4r
        building a rule out of order is a deliberate deviation from a
        MUST and not merely an unenforced receive check. Conventions is
        why, and the deviation is the feature: a test has to be able to
        put an out of order or repeated component on the wire and watch
        a router decide. Say that rather than implying the RFC only
        constrains readers.
      * **A Flow_spec hash is one key per component type, so it has the
        same two problems `Path_attribute#to_hash` had**, and #169 is the
        answer to both: a repeated component type needs a `:duplicates`
        list, and the order of two of a type is incidental. Do not
        re-derive this.
      * **Parsing must stay bounded by the enclosing NLRI and must not
        guess a component boundary.** The section 4.1 length gives that
        bound, and it is the only one there is: a component carries no
        length of its own, so an operator list ends at its end-of-list
        bit and nowhere else. Two consequences for part 2. The bound has
        to be enforced by handing a component exactly that NLRI's value
        octets, since `Op_component#parse` otherwise reads to the end of
        whatever String it is given. And **a missing end-of-list bit is
        not always detectable**: the octets that follow are read on as
        further pairs, and where they happen to form a valid operator
        sequence nothing distinguishes that from what the sender meant.
        So keep the octets and report what is reportable; do not try to
        recover the sender's intent.
   3. **The lab. Not started.** **Probe before recording anything about
      it.** Three Docker blocks in this file came apart on being tried.
      Whether GoBGP and FRR accept a flowspec rule from us, and whether
      either gives a RIB answer a test can read, is a measurement. If
      they do, the lab test is the twin of `rib_router_gobgp_test.rb`; if
      one does not, that is a recorded fact and not a blocked phase.
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
3. **EVPN, SAFI 70, RFC 7432. Not started.** The big one. Five route
   types, each with its own NLRI layout, plus the 14 EVPN extended
   community sub-types `extended_community.rb` currently leaves unnamed.
   One or two route types per PR, 3 or 4 of them.
4. **The rest, as appetite allows. Not started.** BGP-LS (attribute 29,
   AFI 16388, SAFI 71 and 72, RFC 9552), RT-constrain (SAFI 132),
   MCAST-VPN (SAFI 5), ATTR_SET (attribute 128, RFC 6368). Once phase 1
   is in, each of these is a class and a registration.

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

## Known issues to work on

Found while fixing other bugs, not fixed yet. Verified against master on
2026-10-27, so each one reproduces. Reproductions are one liners with
`ruby -I. -e '...'`.

Smaller things:

* `Nsap.new` and `Nsap.new_nsap` disagree on the default prefix length, so the same address string gives two different prefixes depending on which constructor built it: `ruby -I. -e 'require "bgp/nlris/nsap"; p [BGP::Nsap.new("49.0102.0304.0506.0608.0910.1112.1314.1516.1718.ff").mlen, BGP::Nsap.new_nsap("49.0102.0304.0506.0608.0910.1112.1314.1516.1718.ff").mlen]'` prints `[160, 152]`. `Nsap#mlen` falls back to 160, the whole twenty octet address, where `new_nsap` writes `len ||= 152` and so masks the twentieth octet away and encodes nineteen. 160 is the one that matches the rest of the class, including `MAX_MLEN` and `prefix_mask_bits`. It was left alone when the clamp above it was fixed, because `test_new_nsap` and `test_nsap` both pin the 152 default and the fix moves them, which makes it a behaviour change of its own rather than part of that one. Found while raising the clamp from 152 to 160.

* **The `to_hash` round trips are not listed here, and their counts are not written down anywhere.** `test/unit/to_hash_catalog.rb` holds one entry per class and `rake to_hash:pending` prints the ones still to fix, each with what it loses and a reproduction; `rake to_hash:status` prints the lot. `test/unit/to_hash_round_trip_test.rb` measures every declared verdict against the library, so that list shortens only when a fix lands and its entry is struck, and it cannot go stale the way a written list does. **The root cause behind every entry on it is one sentence**: a hash is an argument to `initialize`, so what has to come back is the instance state, and a field that lives in an instance variable no key sets cannot survive a hash build however reasonable the hash looks. **No entry is wrong wholesale any more**: `Path_attribute` was the last, with three losses, and all three are closed. ATOMIC_AGGREGATE disappearing, the tail `parse_wire` keeps, and two attributes of one type collapsing into the last, which was recorded here as a shape decision and a won't fix and should not have been. **The reasoning that reached won't fix is worth keeping, because it was wrong in an ordinary way**: a Hash keyed by attribute type genuinely cannot hold two of a type, and the conclusion that nothing readable could be done did not follow from it. A hash is an argument to `initialize`, so what has to come back is the instance state, and `@attributes` holds a repeat perfectly well once the hash has somewhere to put it: `:duplicates`, a list of the occurrences after the first, which is what `:unknown` had always done for attributes with no key of their own, in the same constructor. What made a readable fix look impossible was taking byte-exact octets as the bar, where the order of two of a type is incidental and `Path_attribute#<=>` already says so by sorting each side before comparing. Two more things it corrected that had been recorded here as fact:
  * **"Widening `to_hash` changes the shape every caller and test sees" was not measured and was not so.** It was the stated reason for leaving `CAP::Add_path`, `CAP::Graceful_restart` and `CAP::Orf` alone. No test in the suite referenced any of those three hashes, and since each carried nothing but `{:code=>n}`, no caller could depend on their contents. **All three are fixed**, each with the hash build test it never had, and `Capability::LOSSY_HASH`, which refused two of them by name in `Capability.from_hash`, is gone with them. The shape argument does hold for the `:exp` key below, where the hash does carry the field and callers do pass it.
  * **The reproduction recorded here was wrong.** `CAP::Graceful_restart.new(60,[1,1,128])` puts the Array in the **restart time** field, so the object it builds cannot `encode` at all; it never demonstrated the hash problem. The working shape is `new(state, time)` and then `add(afi, safi, flags)`. A one liner nobody ran, in an entry about a bug, which is the same failure as a wrong RFC citation.

* Two smaller things in the same field, both found with the one above, and both still open after #161 fixed the reading. **Note on the names used here and in the code**: RFC 8277 section 2.2 calls the low bit the **S bit** and never uses the words "Bottom of Stack", which come from the MPLS shim header of RFC 3032. So `@bottom`, `:bottom` and the comments in `label.rb` take their name from the same place `exp` does, which is the complaint below. The bit's own behaviour is not in doubt and nothing needs renaming to fix a bug; it is recorded so an audit does not read "Bottom of Stack" as a quote from RFC 8277. `Label` calls the 3 bits above it `exp`, in `@exp` and in the `:exp` hash key, where RFC 8277 section 2.2 calls that field Rsrv: "This 3-bit field SHOULD be set to zero on transmission and MUST be ignored on reception". The name `exp` comes from the MPLS shim header, a different field, whose EXP bits RFC 5462 renamed Traffic Class; an earlier version of this entry carried that rename over to this field, which was wrong. Renaming the hash key breaks the hash build path for every caller, so it wants a deliberate decision rather than a patch. **That decision was put to the owner on 2026-10-29 and came back as no preference**, with three options offered: leave it and comment, write `:rsrv` while accepting both keys, or rename outright. Left as it is, because no preference is not a mandate to break every caller passing `:exp` over a naming problem. Do not re-ask without new reason; change it if a caller ever needs the correct name. And `Label_stack#to_hash` keeps only the label numbers, `{:label=>100}` or `{:labels=>[100,101]}`, so Rsrv and the Bottom of Stack bit are lost there even though `Label#to_hash` carries both: `Labeled#to_hash` merges that, so a labeled NLRI's hash cannot rebuild its own octets. Both are entries in `test/unit/to_hash_catalog.rb` now, both marked to fix so `rake to_hash:pending` names them, and the fix is the extra-key-only-when-unusual rule the library already has for `:tail` and `:bits`, which changes no ordinary hash and so is not the shape decision the naming is. `Labeled` turned out to lose more than Rsrv: the inventory measured it dropping the **Path Identifier** too, because `new` hands the prefix string alone to `Prefix.new`, and a one label stack hashes as `:label` where `Labeled` reads only `:labels`, so it builds an empty stack and `encode` dies on nil.

Lab and conformance:

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
* Lowest coverage (unit suite): `neighbor/neighbor.rb` 91%, `messages/update.rb` 92%, `optional_parameters/graceful_restart.rb` 92%, `neighbor/add_path_cap.rb` 93%, `path_attributes/mp_unreach.rb` 93%.

## Attribute work left

RFC sections deliberately not implemented, each noted in the pull
request that added the attribute:

* Tunnel Encapsulation (23): the five per tunnel type Encapsulation sub-TLV shapes, RFC 9012 sections 3.2.1 to 3.2.5, for VXLAN, NVGRE, L2TPv3, GRE and MPLS-in-GRE. The attribute keeps their octets, so a test can still build any of them by hand.
* Tunnel Encapsulation: the SR Policy sub-TLVs, types 12 to 15, 20 and 128 to 130, from RFC 9830, "Advertising Segment Routing Policies in BGP". RFC 9256 is the SR Policy architecture and defines no sub-TLV; IANA gives RFC 9830 as the reference for all eight code points. The Prefix-SID sub-TLV, type 11, is RFC 9012 section 3.7, so it is RFC 9012 work and not outside work like the rest of this entry.
* Prefix-SID (40): the SRv6 TLVs of RFC 9252, and the RFC 8669 section 4.1 rule for labeled unicast.
* No check for a missing well known mandatory attribute. That needs `Update`, not `Path_attribute`, because it depends on whether the message carries NLRI.
* The external peer rules for LOCAL_PREF, ORIGINATOR_ID and CLUSTER_LIST, and the RFC 7311 section 3.2 AIGP checks. bgp4r does not know whether a peer is external where the checks run.
* Not started: BGP-LS, ATTR_SET, BGPsec_Path.
