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

Baseline on 2026-10-27: 878 tests, 19388 assertions, all passing. Line coverage of `bgp/` from the unit suite: 96.9%.

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

* `Ospf_domain_id#value2` returns the global administrator as an address and drops the local administrator, so the 2 octet AS specific form of the OSPF domain ID loses octets in the hash form. RFC 4577 section 4.2.6 lists the types 0x0005, 0x0105 and 0x0205 for this community; `value2` is written for 0x0105, where the global administrator really is an address and the local one is 2 octets of nothing. Under 0x0005 the global administrator is a 2 octet AS and the local one is 4 octets, and both are lost: `ruby -I. -e 'require "bgp/path_attributes/extended_communities"; ec=BGP::Extended_community.factory(["0005000100000001"].pack("H*")); puts ec.to_s; puts ec.to_hash.inspect; puts BGP::Extended_communities.new(ec.to_hash).communities[0].to_shex'` prints `Ospf domain id: 1:1`, then `{:ospf_domain_id=>"0.0.0.1", :type=>0}`, then `0005000100000000`. The type octet comes back since `to_hash` carries it, the local administrator does not. Only `Ospf_domain_id.new` with an address, the 0x0105 form, is what bgp4r builds, and it round trips. `Ospf_router_id` has the same `value2`, but only 0x0107 is in `Extended_community::FACTORY`, so nothing reaches it there. 0x0205 is in neither. Found while making `to_hash` carry the type octet.
* `IPAddr.create` truncates an Integer that does not fit four octets, instead of refusing it, so a path attribute built from one carries a different address. The Integer branch is `IPAddr.new_ntoh([arg].pack('N'))`, and `pack('N')` keeps the low 32 bits: `ruby -I. -e 'require "bgp4r"; puts BGP::Next_hop.new(2**32+1).to_s; puts BGP::Originator_id.new(-1).to_s'` prints `'0.0.0.1'` and `'255.255.255.255'`. `Next_hop`, `Originator_id`, `Cluster_list` and `Aggregator` all build their address this way, and an Integer is never an IPv6 address there either. Per the rule on inputs a field cannot hold, the constructor should refuse it rather than send another address. Found while giving `IPAddr#^` a floor and a ceiling; `^` no longer uses `IPAddr.create`.
* `Prefix.new_ntop` does not consume the String it reads when the AFI is NSAP. The IPv4 and IPv6 branches end with `arg.slice!(0,1+(plen+7)/8)`; the NSAP branch has no `slice!` at all, so the caller's String comes back untouched: `ruby -I. -e 'require "bgp/nlris/prefix"; w=BGP::Prefix.new("49.0001.0001.0001.00").encode.dup; BGP::Prefix.new_ntop(w,3); p w.size'` prints `20`, not `0`. Anything that reads one prefix after another would read the same octets for ever, so `Base_nlri#parse` guards against no progress and gives up on the rest of the field, which drops every NSAP prefix but the first. `test_a_family_whose_prefix_is_not_consumed_stops_instead_of_looping` in `test/unit/nlris/nlri_test.rb` pins that, so a fix changes two assertions there. The encode side already agrees with `1+(plen+7)/8`, so that is the slice the NSAP branch wants.
* `Update#nlri=` raises `NameError` on anything it does not accept, instead of ignoring it the way `withdrawn=` and `path_attribute=` do. The test is `val.is_a?(Nlri) or val.is_a?(Ext_Nlri)`, and `BGP::Ext_Nlri` does not exist anywhere in the library: `ruby -I. -e 'require "bgp4r"; BGP::Update.new.nlri = "nope"'` raises `NameError: uninitialized constant BGP::Update::Ext_Nlri`. An `Nlri` short circuits the `or`, which is why nothing has hit it. Either drop the second test or define the class the add-path work meant to add.
* `Prefix.new_ntop` raises on a prefix length the family cannot hold, rather than keeping the octets. A length octet above 32 for IPv4 makes a prefix String that `IPAddr.new` refuses: `ruby -I. -e 'require "bgp/nlris/prefix"; BGP::Prefix.new_ntop(["21010203040506"].pack("H*"))'` raises `IPAddr::InvalidPrefixError`. So one bad length octet in an UPDATE's NLRI field (RFC 4271 section 4.3) takes down the parse of the whole message. Receiving is where validation belongs, but the fault should be reported, not raised, and the octets kept.
* bgp4r can send a Cisco style prefix ORF but cannot read its own message back. `Prefix_orf#cisco_prefix_entry_type` sets the ORF Type octet to 130, and `Orf.factory` only knows 64, so parsing raises. `ruby -I. -e 'require "bgp4r"; o=BGP::Prefix_orf.new(BGP::Prefix_entry.add_and_permit(10,"10.0.0.0/8")); o.cisco_prefix_entry_type; BGP::Orf_route_refresh.new(BGP::Orf_route_refresh.new(1,1,o).encode)'` raises `RuntimeError: orf type 130 not implemented`. `Prefix_orf#_parse_` reads type 130 fine, since it keeps whatever type octet it finds; only the factory refuses. `test_2` in `test/unit/orfs/prefix_orf_test.rb` round trips a type 130 ORF at the ORF level for that reason.
* `Orf_route_refresh#add` drops anything that is not an `Orf`, with no error. `ruby -I. -e 'require "bgp4r"; rr=BGP::Orf_route_refresh.new(1,1); rr << "not an orf"; p rr.orfs.size'` prints `0`. The constructor now hands its third and later arguments to `add`, so a typo there is silently a message with no ORF, which is the same silent wrong answer that `new(afi,safi,orf)` used to give. `test_add_keeps_only_orfs` in `test/unit/messages/route_refresh_test.rb` pins the current behavior, so a fix changes that test. `BGP::Orf#initialize` has the same shape and also calls a `parse` that `Orf` does not define; those two lines are the only uncovered ones in `orfs/orf.rb`.

* `Capability::Revision#to_s` only works when the capability is an MBGP one. It calls `@cap.to_s_brief`, and `to_s_brief` is defined on `CAP::Mbgp` and on `CAP::Unknown` and nowhere else, so printing a Dynamic Capability message that carries any other capability raises. `ruby -I. -e 'require "bgp4r"; puts BGP::Capability::Revision.advertise(10, BGP::OPT_PARM::DYN_CAP::As4.new(100)).to_s'` raises `NoMethodError: undefined method 'to_s_brief' for an instance of BGP::OPT_PARM::DYN_CAP::As4`. The same goes for `Route_refresh`, `Orf`, `Add_path`, `Graceful_restart`, `Extended_nexthop` and `Dynamic`. Either each capability gets a `to_s_brief`, or `Capability` gets a default one. Found while adding the unknown dynamic capability fallback.
* A String administrator in the three argument form of `Rd.new` takes `encode` down. Types 0 and 2 pack the administrator as an Integer, so an address String reaches `pack` as it was given: `ruby -I. -e 'require "bgp/nlris/rd"; BGP::Rd.new("1.1.1.1",1,0).encode'` raises `TypeError: no implicit conversion of String into Integer`. The two argument form reads a String administrator as the type 1 form and never gets there, and a named type 1 builds an `IPAddr` first, so only a named type 0 or 2, or a type the RFC does not define, hits this. Either those branches read the String the way type 1 does, or the constructor says the administrator of that type is an Integer. Found while carrying the encoding type through the hash form.

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
