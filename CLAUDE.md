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

Baseline on 2026-10-27: 906 tests, 19939 assertions, all passing. Line coverage of `bgp/` from the unit suite: 97.0%.

There is no coverage gem in the `Gemfile`. To measure, use Ruby's built-in `Coverage`: start it, register the report with `at_exit` before requiring any test file so it runs after the suite, then require `test/unit/**/*_test.rb`.

## Conventions

* **Building and encoding are never validated, and that is a feature.** This library is used for negative testing: it has to put bytes on the wire that no RFC allows, so a real router can be watched handling them. Any attribute, any length, any combination, any flags. Never add a check to a constructor, to `encode`, or to `to_hash` that refuses something merely invalid. Removing that ability breaks the main reason the library exists.
  * Validation lives in exactly one place, `bgp/path_attributes/validation.rb`, and runs only when parsing what was received. It is reported through `Path_attribute#errors` and raised only under the `:strict` receive policy. Add a rule there, with its RFC section, never in the attribute.
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
* Keep this file true in the same pull request that makes it false. If your change fixes something under "Known issues to work on", delete that entry. If it adds or removes tests, update the baseline counts above. Nobody reconciles this file later, and a stale entry is worse than no entry: it sends the next reader after work that no longer exists. Both halves of this have already happened here, once to seven entries at once, and once to a fix that landed without removing its own entry.

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

* A String administrator in the three argument form of `Rd.new` takes `encode` down. Types 0 and 2 pack the administrator as an Integer, so an address String reaches `pack` as it was given: `ruby -I. -e 'require "bgp/nlris/rd"; BGP::Rd.new("1.1.1.1",1,0).encode'` raises `TypeError: no implicit conversion of String into Integer`. The two argument form reads a String administrator as the type 1 form and never gets there, and a named type 1 builds an `IPAddr` first, so only a named type 0 or 2, or a type the RFC does not define, hits this. Either those branches read the String the way type 1 does, or the constructor says the administrator of that type is an Integer. Found while carrying the encoding type through the hash form.

Lab and conformance:

* The GoBGP column in `docs/protocol-testing.md` was measured on 3.23 by hand, and holds for 4.10 too: the containerized test asserts every one of the 18 rows and passes on both. `GOBGP_IMAGE` switches versions without an edit. The FRR and BIRD columns are still from 8.4.4 and 2.14 run natively, and only the session level outcomes there, since BIRD gives no usable RIB answer over a loopback session.
* `lab/conformance/gobgpd.conf` and `lab/topologies/fault-matrix/gobgp.toml` are written in the 3.23 style and GoBGP 4 reads them unchanged. Every key is still in the 4.x config structs under the same `mapstructure` name, and 4.x registers `mapstructure.StringToNetIPAddrHookFunc` so the address fields still decode from TOML strings. No schema work is needed; an earlier version of this entry said otherwise and was wrong.
* `lab/topologies/fault-matrix` exits 1, and that is the right answer: GoBGP discards the malformed tunnel encapsulation attribute and installs the route where RFC 9012 section 13 asks for treat-as-withdraw. Both cases are asserted as a known divergence in `test/functional/lab/fault_matrix_test.rb`; see the comment on `TUNNEL_ENCAP` there. It is not an old bug since fixed: 3.23 does it, and a CI run on 4.10 does it too, so it is worth reporting upstream.
* Lowest coverage (unit suite): `neighbor/neighbor.rb` 89%, `path_attributes/origin.rb` 91%, `messages/update.rb` 92%, `optional_parameters/graceful_restart.rb` 92%, `path_attributes/mp_unreach.rb` 93%.

## Attribute work left

RFC sections deliberately not implemented, each noted in the pull
request that added the attribute:

* Tunnel Encapsulation (23): the eight per tunnel type Encapsulation sub-TLV shapes, RFC 9012 sections 3.1.1 to 3.1.8. The attribute keeps their octets, so a test can still build any of them by hand.
* Tunnel Encapsulation: the SR Policy sub-TLVs, types 12 to 15, 20 and 128 to 130, from RFC 9256, and the Prefix-SID sub-TLV, type 11.
* Prefix-SID (40): the SRv6 TLVs of RFC 9252, and the RFC 8669 section 4.1 rule for labeled unicast.
* RFC 9234 section 4: the BGP Role capability. Only the OTC attribute is implemented.
* No check for a missing well known mandatory attribute. That needs `Update`, not `Path_attribute`, because it depends on whether the message carries NLRI.
* The external peer rules for LOCAL_PREF, ORIGINATOR_ID and CLUSTER_LIST, and the RFC 7311 section 3.2 AIGP checks. bgp4r does not know whether a peer is external where the checks run.
* Not started: BGP-LS, ATTR_SET, BGPsec_Path.
