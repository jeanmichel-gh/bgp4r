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

Baseline on 2026-10-27: 817 tests, 18712 assertions, all passing. Line coverage of `bgp/` from the unit suite: 96.6%.

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
* Two space indent. Match the style of the file you edit.
* Copyright headers. A new Ruby file or Dockerfile starts with the standard GPL header from `bgp/observable.rb`, with `Copyright <current year> Jean-Michel Esnault.` (a Dockerfile drops the `#--` and `#++` lines). When you change a file that has a header, add the current year to its years if it is missing: `2008, 2009` becomes `2008, 2009, 2026`. Do not add headers to files that never had one. YAML, Markdown and other config files get no header.
* Keep the library free of runtime gem dependencies. The one exception is `logger`: it ships with Ruby, but Ruby 4.0 made it a bundled gem, so `bgp4r.gemspec` and the `Gemfile` declare it.
* Before requiring a standard library, check that it is still a default gem. Ruby keeps moving libraries to bundled gems (`observer` in 3.4, `logger` in 4.0), and under Bundler those fail to load unless declared. Prefer a small built-in copy, as with `BGP::Observable`.
* Do not redefine methods of standard library classes. Newer versions may add the same method with different behavior (`IPAddr#+` in Ruby 4.0). Guard additions with `unless method_defined?`.
* Do not mutate string literals. CI runs the suite with `--enable-frozen-string-literal`. Use `String.new` or `+''` for a buffer.

## Rules for agents

* Work on a branch named `claude/<short-topic>`. Never push to master.
* One topic per pull request. Small diffs.
* Run the full unit suite before opening a PR. All tests must pass.
* New behavior needs a test. Bug fixes need a test that failed before the fix.
* Cite the RFC section in a comment when you implement or fix wire format logic.
* Do not delete or weaken existing tests to make a change pass.
* If you find a bug you are not fixing, list it in the PR description.
* Keep this file true in the same pull request that makes it false. If your change fixes something under "Known issues to work on", delete that entry. If it adds or removes tests, update the baseline counts above. Nobody reconciles this file later, and a stale entry is worse than no entry: it sends the next reader after work that no longer exists. Both halves of this have already happened here, once to seven entries at once, and once to a fix that landed without removing its own entry.

## Known issues to work on

Found while fixing other bugs, not fixed yet. Verified against master on
2026-10-27, so each one reproduces. Reproductions are one liners with
`ruby -I. -e '...'`.

Smaller things:

* An extended community's `to_hash` carries its values but not its type octet, so a community whose type the values cannot reproduce comes back as a different one. Two cases. A 4 octet AS specific route target or route origin (RFC 5668 section 2, types 0x02 and 0x03) whose AS fits in 2 octets rebuilds as the 2 octet AS form, because `four_octet_as_specific?` only picks the 4 octet type for an AS above 65535: `ruby -I. -e 'require "bgp/path_attributes/extended_communities"; w=["0202000000640001"].pack("H*"); ec=BGP::Extended_community.factory(w); puts ec.to_shex; puts BGP::Extended_communities.new(ec.to_hash).to_shex'` prints `0202000000640001` then `c010080002006400000001`. And an origin validation state received with the transitive bit clear (type 0x03, where RFC 8097 section 2 asks for 0x43) rebuilds as 0x43, since the constructor always sets `NON_TRANSITIVE`: the same one liner on `0300000000000001` prints `0300000000000001` then `c010084300000000000001`. The wire form round trips either way; only the hash form loses the octet. `test_the_collection_loop_still_reads_whole_communities` in `test/unit/path_attributes/extended_communities_test.rb` pins the wire halves of both and says so in a comment. Found while fixing the String slicing in `Extended_community#parse`.
* `IPAddr#mlen` never returns for a /0 prefix. `_mlen_` in `bgp/common.rb` shifts the mask right until it finds a set bit, and an all zero mask has none, so the loop spins forever. A default route is ordinary in BGP, so this hangs anything that builds one: `ruby -I. -e 'require "bgp/common"; p IPAddr.new("0.0.0.0/0").mlen'` never finishes, and neither does `::/0`. The loop needs a floor at length 0. It also blocks the wild card ORF entry of RFC 5292 section 2, which is a prefix of length 0. Found while writing coverage tests for `common.rb`, which is why none of them use a /0.
* `Base_nlri#parse` has never worked, so `Nlri.new(wire)` and `Withdrawn.new(wire)` raise instead of parsing. `parse` loops `add(s)` over the whole packed String, and `add`'s String branch hands that String to `Prefix.new`, which gives it to `IPAddr.new`. `ruby -I. -e 'require "bgp/nlris/nlris"; BGP::Nlri.new(["086508660867"].pack("H*"))'` raises `IPAddr::InvalidAddressError`. `new_ntop` is the route that works, and it consumes the String one prefix at a time. Only a zero length field gets through `parse`, which is why `test/unit/nlris/nlri_test.rb` reaches every line of it but the loop body.
* Dead code in `bgp/common.rb`. `IPAddr#netmask` sits under `unless method_defined?(:netmask)` and ipaddr has had a compatible `netmask` since Ruby 2.5, so those lines never run on any Ruby bgp4r supports; `test_netmask_comes_from_the_standard_library` asserts the standard library is the one answering. The `else` branch of the `RUBY_VERSION.split('.').join[0,2] > "18"` test in `String#hexlify` is for Ruby 1.8 and cannot run either. Both are the only uncovered lines left in the file.

* `Capability.dynamic_factory` cannot build a capability code it does not implement. It falls back to `Capability::Unknown`, which reads the two octet optional parameter header, while a dynamic capability has a one octet code and a two octet length (RFC 5291 section 3). `@code` comes out nil and `parse` raises, so a Dynamic Capability message carrying an unimplemented code raises instead of keeping the octets. `ruby -I. -e 'require "bgp4r"; BGP::OPT_PARM::Capability.dynamic_factory(["64000576616c7565"].pack("H*"))'` raises `TypeError: no implicit conversion from nil to integer`. `DYN_CAP` is built from `BGP::OPT_PARM::CAP.constants` and `Unknown` is a constant of `Capability`, so there is no `DYN_CAP::Unknown` to fall back to. The same `case` also has `when CAP_ADD_PATH` twice, and the second arm is dead code.
* `Rd#to_s` prints the assigned number where the administrator belongs, for encoding type 0 only. Types 1 and 2 pass `@admin` then `@assign` to `format`; type 0 passes `@assign` twice. `ruby -I. -e 'require "bgp/nlris/rd"; puts BGP::Rd.new(7,9).to_s'` prints `RD=7:9 (0x09 0x0009)` where the hex should read `0x07 0x0009`. The terse form, `to_s(false)`, is right.
* `Rd.new(admin, '1.1.1.1')` builds an encoding type 2 RD, whose assigned number field is 2 octets (RFC 4364 section 4.2), and keeps the whole 32 bit value in memory. `encode` truncates it, so the object disagrees with its own wire bytes. `ruby -I. -e 'require "bgp/nlris/rd"; rd = BGP::Rd.new(1,"1.1.1.1"); puts rd.to_s(false); puts BGP::Rd.new(rd).to_s(false)'` prints `RD=1:16843009` then `RD=1:257`. Either the String should be read as a 2 octet value or the constructor should refuse it, per the rule on inputs a field cannot hold. `test/unit/nlris/rd_test.rb` pins the current output in `test_1`, so a fix changes two assertions there.

Outbound route filtering (RFC 5291 and RFC 5292):

* `Orf_route_refresh` never encodes the When-to-refresh octet that RFC 5291 section 5 puts between the SAFI and the first ORF. `ruby -I. -e 'require "bgp4r"; rr=BGP::Orf_route_refresh.new(1,1); rr << BGP::Prefix_orf.new(BGP::Prefix_entry.add_and_permit(10,"10.0.0.0/8")); puts rr.to_shex[38..-1]'` prints `00010001400009...`: the `40` a router reads as When-to-refresh is the ORF type. `@when` is never assigned either, there is no writer and `parse` reads no such field, so `when_to_s` is dead code that answers `bogus ()`. Fixing it means the octet in `encode` and `parse`, a `when=` setter, and the four `when_to_s` lines become reachable.
* `Orf_route_refresh.new(afi, safi, orf)` silently drops the ORF. The constructor's last branch is `@afi, @safi=args`, so a third argument is discarded and the message encodes as a plain ROUTE-REFRESH with no ORF at all. `ruby -I. -e 'require "bgp4r"; orf=BGP::Prefix_orf.new(BGP::Prefix_entry.add_and_permit(10,"10.0.0.0/8")); p BGP::Orf_route_refresh.new(1,1,orf).orfs.size'` prints `0`, where `new(1,1)` followed by `<< orf` gives `1`. A silent wrong answer rather than an error, so a caller gets a message a router accepts and ignores.
* `Prefix_entry.remove_all` always raises. It calls `Prefix_entry.new(2,0)`, and two arguments match no branch of the constructor. `ruby -I. -e 'require "bgp4r"; p BGP::Prefix_entry.remove_all'` raises `ArgumentError: invalid argument: [2, 0]`. A REMOVE-ALL entry carries no type specific part by RFC 5291 section 5, so `encode` needs to know about it too; it writes Sequence, Minlen, Maxlen and the prefix whatever the action is.
* `Prefix_entry#action=` silently ignores a value it does not recognise, leaving `@action` nil, and `encode` then dies in `_first_octet_`. Action is two bits, so 3 arrives on the wire and `_parse_` keeps it, but the field and hash forms cannot set it. `ruby -I. -e 'require "bgp4r"; p BGP::Prefix_entry.new(:action=>3, :prefix=>"10.0.0.0/8").to_shex'` raises `NoMethodError: undefined method '<<' for nil`. `match=` raises instead, with a bare `raise`, so a RuntimeError with no message. While in there: `Prefix_entry#set` writes its defaults back into the caller's hash with `||=`, so the hash passed to `new` comes back with six keys added.
* `Prefix_orf#_parse_` builds each entry with `BGP::Prefix_entry.new(entries.is_packed)`, with no AFI, and `Prefix_entry#_parse_` defaults to AFI 1. The octets survive but an IPv6 ORF reads back as IPv4. `ruby -I. -e 'require "bgp4r"; e=BGP::Prefix_entry.new(0,0,10,0,0,"2011:1::/32"); p BGP::Prefix_orf.new(BGP::Prefix_orf.new(e).encode).to_s'` prints `32.17.0.1/32`. The AFI is in the ROUTE-REFRESH message, so `Orf_route_refresh#parse`, `Orf.factory` and `Prefix_orf#_parse_` all have to pass it down.
* `Orf_route_refresh#communities` reads `@communities`, which nothing in the class ever assigns, so it always raises `NoMethodError`. Dead code to delete. `Orf_route_refresh#to_hash` returns only the AFI and the SAFI, so it does not round trip through `new` once the message carries an ORF.

Lab and conformance:

* The GoBGP column in `docs/protocol-testing.md` was measured on 3.23 by hand, and holds for 4.10 too: the containerized test asserts every one of the 18 rows and passes on both. `GOBGP_IMAGE` switches versions without an edit. The FRR and BIRD columns are still from 8.4.4 and 2.14 run natively, and only the session level outcomes there, since BIRD gives no usable RIB answer over a loopback session.
* `lab/conformance/gobgpd.conf` and `lab/topologies/fault-matrix/gobgp.toml` are written in the 3.23 style and GoBGP 4 reads them unchanged. Every key is still in the 4.x config structs under the same `mapstructure` name, and 4.x registers `mapstructure.StringToNetIPAddrHookFunc` so the address fields still decode from TOML strings. No schema work is needed; an earlier version of this entry said otherwise and was wrong.
* `lab/topologies/fault-matrix` exits 1, and that is the right answer: GoBGP discards the malformed tunnel encapsulation attribute and installs the route where RFC 9012 section 13 asks for treat-as-withdraw. Both cases are asserted as a known divergence in `test/functional/lab/fault_matrix_test.rb`; see the comment on `TUNNEL_ENCAP` there. It is not an old bug since fixed: 3.23 does it, and a CI run on 4.10 does it too, so it is worth reporting upstream.
* Lowest coverage (unit suite): `neighbor/neighbor.rb` 89%, `path_attributes/origin.rb` 91%, `orfs/orf.rb` 92%, `optional_parameters/orf.rb` 92%, `optional_parameters/graceful_restart.rb` 92%.

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
