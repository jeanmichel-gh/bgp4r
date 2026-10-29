# What `#to_hash` round trips, and what it does not

Every class in bgp4r is meant to build three ways: from field values,
from a Hash, and from its wire bytes. The Hash form is the one this
document is about.

It exists so a test can be written and read as values rather than as
hex. That is the whole of its job. It is a convenience for the people
reading test code, not something the protocol needs, and nothing inside
the library depends on it.

So the promise in Conventions, that `to_hash` answers a hash that round
trips through `new`, is kept by most classes and broken by some. Until
this document there was no list, and the broken ones were found one at a
time by whoever next tried to use one.

## The rule

**A gap may stay a gap. A round trip that works must not stop working.**

That asymmetry is the point. A class whose hash never read back is a
disappointment. A class whose hash used to read back and no longer does
breaks test code other people have already written. The first is a
missing feature, the second is a regression.

`test/unit/to_hash_round_trip_test.rb` enforces exactly that. It
measures every class listed below and compares the answer against
`test/unit/to_hash_catalog.rb`, which declares what each one is supposed
to do. Breaking a working round trip fails the suite. Closing a gap
fails it too, so the gap is struck off the record rather than left
behind reading as verified.

## The requirement that follows from it

**If an object can be rebuilt from its own `to_hash`, a test must prove
it.** A working round trip is a feature and needs a test like any other
feature. Where `Klass.new(obj.to_hash)` reproduces the original's wire
bytes, something has to assert it, in both of these places:

* The class's own test file, which is where a reader looks. Build the
  object, feed its own hash back to `new`, compare `encode` with the
  original, and exercise every field the object carries.
* Its entry in `test/unit/to_hash_catalog.rb`, which is what makes the
  guarantee hold across the library rather than one class at a time.

The converse is not required, and the asymmetry is the point. The hash
form is a convenience, not part of the protocol, so a class whose hash
does not read back is allowed; it gets a row below with what it loses and
a decision. What is not allowed is a round trip that works with nothing
saying so, because an untested round trip is a claim rather than a
feature, and the next person to change the class has nothing to tell them
they broke it.

Both halves are enforced rather than asked for.
`test_the_round_trips_that_work_still_work` covers the catalog half, and
`test_every_working_round_trip_is_asserted_in_a_class_test_file` covers
the other, so a working round trip that nothing asserts fails the suite.
All 34 are covered at both levels, which is a measurement and not a
promise.

The catalog is also why this list cannot go stale. A class that answers
`to_hash` and appears in neither the catalog nor the exclusions fails
the suite, so a new class has to be measured and decided rather than
quietly joining the library. This document is checked against the
catalog by the same test, column by column.

## Where these shapes come from

Worth knowing before reading the table, because it explains almost every
row in it and it is not something the code says anywhere.

These classes were written in this order: first the test that builds the
object **from a hash**, then `initialize` until that test passed, and
then, once the object was right, `to_hash` written to answer the hash the
test had used in the first place.

So the contract was never `Klass.new(Klass#to_hash)`. It was two separate
things:

* `Klass.new(bare_hash)`, the hash the test wrote. `Aggregator.new(:address
  => ..., :asn => ...)`, `Mp_reach.new(:afi => ..., :safi => ..., :nexthop
  => ..., :nlris => ...)`. No outer key.
* `Parent.new(wrapped_hash)`, where the outer key exists only because
  `Path_attribute#to_hash` merges one key per attribute into one hash, and
  `Extended_communities` does the same for its list.

**That is the whole of the "by another route" column.** `to_hash` answers
the wrapped form because its caller needs the key; `new` reads the bare
form because that is what its test wrote. Both halves work. 38 of the 97
rows are this, and none of them is a defect, which is why nearly all of
them are left alone.

It also explains the rows that do lose information, and more usefully
than the danger ranking above. Each one is a field that entered the
object **after** the hash shape was settled, so there was never a
construction hash for `to_hash` to match:

* the reserved bits and kept tails, which only exist because of the later
  keep-what-you-cannot-read work;
* `Mpls_label_stack`'s TC and TTL and `Label_stack`'s Rsrv, which only
  arrive by parsing;
* `Labeled`'s Path Identifier, which is RFC 7911 and later than the class;
* `Capability::Unknown`'s value octets, kept for the same reason as a tail.

And the three capabilities whose hash was a bare `{:code=>n}` were the
clean confirmation: `CAP::Add_path`, `CAP::Graceful_restart` and
`CAP::Orf` had **no hash-construction test at all**, so no `to_hash` was
ever written for them and they inherited `Capability`'s, where every
capability that did round trip had such a test. All three are fixed now,
and each got the test it never had.

## What the verdicts mean

There are two routes a hash can come back by, and a class can fail on
one and be fine on the other, in both directions.

Its own `new` is one. The other is whatever actually reads these hashes,
which for most of the library is not the class itself:
`Path_attribute.new` for a path attribute, `Extended_communities.new`
for an extended community, `Sub_tlv.from_hash` for a tunnel sub-TLV,
`As_path.new` for a segment, the same list splatted back for an NLRI
collection. For a few classes nothing reads the hash at all, and there
the second route is the fields taken back out by hand, which proves the
hash is complete even though no door exists.

| Verdict | Meaning |
|---|---|
| **yes** | Its own `new` rebuilds the same wire bytes. |
| **by another route** | Its own `new` does not, the other route does. The hash carries everything, and for most of these the other route is the one that was designed, as the section above explains. |
| **not in its attribute** | Its own `new` does, the other route does not. Worse than it sounds: a hash key inherited from a parent class is the cause, and the attribute then rebuilds a different attribute without saying so. No row reads this today; `As4_path` did until it was fixed. |
| **no** | No route gives the octets back. Information is gone. |

Of the 97 classes measured: **47 round trip through their own `new`**,
**38 by another route**, and **12 lose information**. Whether a failing route raises or quietly answers
something else is in the table rather than in the verdict, because a
verdict is meant to say what a person gets. The quiet ones are the
dangerous half and each one says so.

## How the recipes were built

Each row was measured from one instance built to carry every field the
class has, because a thinner instance passes for the wrong reason.
Three did while this was being written:

* `Label_stack.new(100, 101)` round trips cleanly and tells you nothing.
  The class also carries a 3-bit Rsrv field per label, which the hash
  drops, and that instance never set it.
* `CAP::Orf.new(1, 1, [64, 3])` passed because those arguments quietly
  build a capability with no ORF entries in it at all. The instance was
  empty, so there was nothing for the hash to lose.
* `Mpls_label_stack.new(100, 200)` passed by both routes, while the same
  stack parsed off the wire with TC and TTL set loses both.

Where a field can only arrive by parsing, such as a kept tail of
unreadable octets or a reserved bit that was set on the wire, the recipe
parses wire bytes. The recipes are in `test/unit/to_hash_catalog.rb`,
taken from each class's own unit test wherever one builds the class
already, so the octets are the ones the suite has always used.

## The decisions

**37 are left as they are.** Nearly all of them are the same situation:
the class's own `new` will not take its own hash, but the attribute that
owns it will, and the hash carries everything. That covers 19 of the 21
extended communities, the four AS_PATH segment classes, five tunnel
sub-TLVs, `Mp_reach`, `Mp_unreach`, `Aggregator`, `Originator_id` and
the two NLRI collections. These are not defects. As the section above explains, `new` reads the
bare hash a test writes and `to_hash` answers the wrapped hash its
attribute needs, and both halves do their job. Adding a Hash branch for
the wrapped form would be a lot of code to make a round trip work that
was never the contract, and a test builds an `Extended_communities` or a
`Path_attribute` rather than a lone community anyway. The two that are
not that: `Extended_community` is the partial base class,
so a subclass is what a test builds, and `OPT_PARM::Capability` is
likewise the base.

**13 are to be fixed**, in this order. Sixteen were, and what they were
is under "What has been fixed" below.

First, the last one that is wrong wholesale rather than by a field:
`Path_attribute` collapses two attributes of one type into the last one,
and loses the tail `parse_wire` keeps. Both silently.

The field losses below are quiet too, each dropping one field without
raising, but each is one field rather than a different object, which is
why they rank after it.

Second, the cheap ones, where the hash is already complete and only a
constructor branch is missing: `Notification` and `Vpn`.

Third, the real losses, each a field with no key in any hash. These
follow a pattern the library already has for exactly this, the
extra-key-only-when-unusual rule behind `:tail` and `:bits`, so none of
them has to change the shape of an ordinary hash: `Tunnel_encap::Color`
flags, `Tunnel_encap::Egress_endpoint` reserved,
`Tunnel_encap::Mpls_label_stack` TC and TTL, `Tunnel_encap::Tunnel` and
`Tunnel_encap` tails, `Prefix_sid::Label_index` reserved and flags,
`Pmsi_tunnel` flags, `Label_stack` Rsrv, `Labeled` Path Identifier,
`Opaque` type and sub-type, `Capability::Unknown` value octets, and the
three capabilities whose hash is a bare `{:code=>n}`: `Add_path`,
`Graceful_restart` and `Orf`.

Those last three were recorded in CLAUDE.md as too expensive to widen,
on the grounds that it would change the shape every caller and test
sees. That was measured and is not so. No test in the suite references
any of the three hashes, and since they carry nothing today, no caller
can depend on their contents.

## What has been fixed

Sixteen, all of which rebuilt different octets without raising, or could
not be read back at all. `Path_attribute` is the only one still wrong
wholesale rather than by a field.

* **`CAP::Add_path`** and **`CAP::Graceful_restart`**, the last two of
  the three bare `{:code=>n}` capabilities. Add_path lost every RFC 7911
  section 4 `<AFI, SAFI, Send/Receive>` triple, and Graceful_restart lost
  the restart state, the restart time and every family together. A Hash
  fell to a bare `raise` in one and to `parse`, which called `slice!` on
  it, in the other. Both carry their payload under the `:capability` key
  now, and `Capability.from_hash`, which refused both codes by name,
  builds them.

* **`CAP::Orf`** and **`CAP::Orf::Entry`.** The capability inherited
  `Capability`'s bare `{:code=>3}`, so every entry was lost, and a Hash
  fell through to the bare `super` and built a capability with no entries
  at all: 26 octets became 4. `Capability.from_hash` routes code 3
  straight back there, so that route answered an empty capability too.
  `Entry` had no `to_hash` for anything to read and an empty Hash branch,
  so every field stayed nil and `encode` raised.
* The same change found a **wire** bug beside the hash one. RFC 5291
  section 5 Figure 3 gives the capability a Reserved octet and never says
  what to do with it, and `parse` unpacked it into a throwaway while
  `encode` wrote 0, so a captured capability could not be sent again:
  `0001ff0101` came back as `0001000101`. The octet is kept now, and the
  hash carries it only when it is not 0. **Section 4's "Reserved is a
  5-bit field. It is set to 0 on transmit and ignored on receipt" is a
  different field**, in the ORF entry of a ROUTE-REFRESH, and is not a
  rule about this octet.

* **`Traffic_action`.** Its own `new` read `:sample`, `:terminal` and
  `:bits` off the outer hash, found all three nil, and built a clean
  looking community encoding `8007000000000000`, losing all 48 value
  bits. It was the one extended community that was quiet where the others
  raise, because its field defaults pass their own check.
* **`Tunnel_encap::Encapsulation`.** Its own `new` took the hash as the
  value octets and called `to_s` on it, so the sub-TLV value became the
  28 octets of `{:encapsulation=>"01020304"}` as Ruby inspects it, on the
  wire. `Sub_tlv.from_hash` read the same hash correctly all along, which
  is why nothing caught it.
* **`Prefix_sid`.** Its `new` read only the inner hash, so given its own
  `to_hash` it found no key it knew and built an empty attribute,
  `c02800`.
* **`Prefix_sid::Label_index`** and **`Prefix_sid::Originator_srgb`.**
  The reserved octet of RFC 8669 section 3.1 and the flags of sections
  3.1 and 3.2 had no key at all, so a TLV read off the wire came back
  zeroed, and `Originator_srgb`'s own `new` read its hash as one range
  and built `[0, 0]`. The fields go **in the value** rather than beside
  it, because `Prefix_sid#to_hash` merges the known TLVs into one hash
  where two `:flags` keys would collide. An ordinary TLV hashes exactly
  as it did: `{:label_index => 100}`, `{:srgb => [[16000, 1000]]}`.
* **`Prefix_sid::Tlv`.** Nothing read its hash: `new` took it as the
  type and `pack` raised.

And the first six, each a round trip that gave back a different
attribute. Each has a test in its own file, and the attribute set as a
whole has `test_a_round_tripped_attribute_set_is_the_same_set` in
`path_attribute_test.rb`, which is the assertion that matters: the same
attributes come back, with the same type codes and the same octets.

* **`Origin`.** Its Hash branch assigned the value raw, skipping the
  Symbol translation the same method already had, so `@origin` held a
  Symbol and `encode` raised in `pack`. One line. Two things came with
  it: an ORIGIN the RFC does not define now hashes as its code rather
  than as `:undefined`, which no route could read back, and `new` takes
  any octet, where it refused above 2. Conventions is explicit that a
  constructor must not refuse a value that is merely wrong by the RFC,
  and the refusal also blocked the round trip for a value read off the
  wire.
* **`Atomic_aggregate`.** Its hash was `{}`, which adds no key when
  `Path_attribute#to_hash` merges it, so the attribute vanished from a
  round tripped attribute set. It writes `:atomic_aggregate` now, the key
  the registry had taken all along.
* **`As4_aggregator`** and **`As4_path`.** Both inherited their parent's
  hash key, so `Path_attribute` rebuilt the 2 octet `AGGREGATOR` and
  `AS_PATH` from them and cut the AS numbers: 4200000001 came back as
  59905. Both write their own key now, and both were already in the
  registry. `segments_from_hash` already read `:as4_path`, so a build
  straight from the hash went on working, which is how this stayed
  hidden.
* **`Attr::Raw`** and **`Attr::Unknown`.** `new` read `:flags`, `:type`
  and `:value` off the outer hash, where `to_hash` had put them one level
  down in a one element `:unknown` list, so all three were nil and
  `80c802ff00` came back as `000000`. The existing round trip test had
  unwrapped the list by hand, which is how it passed.

## The table

### Path attributes

| Class | Round trips | What the hash loses, or what stands in the way | Decision |
|---|---|---|---|
| `Aggregator` | by another route | nothing. The fields nest under :aggregator and new reads the inner hash, so Path_attribute is the door. | won't fix |
| `Aigp` | yes | -- | -- |
| `As4_aggregator` | by another route | nothing. Its own new reads the bare hash Aggregator takes, :asn and :address, so the wrapped form is the attribute set's to read, as with Aggregator itself. | won't fix |
| `As4_path` | yes | -- | -- |
| `As_path` | yes | -- | -- |
| `As_path::Confed_sequence` | by another route | nothing. None of the four segment classes has a Hash branch, so the hash is stored as the one AS number and encode packs a Hash. As_path.segment_from_hash reads it correctly. | won't fix |
| `As_path::Confed_set` | by another route | nothing. None of the four segment classes has a Hash branch, so the hash is stored as the one AS number and encode packs a Hash. As_path.segment_from_hash reads it correctly. | won't fix |
| `As_path::Sequence` | by another route | nothing. None of the four segment classes has a Hash branch, so the hash is stored as the one AS number and encode packs a Hash. As_path.segment_from_hash reads it correctly. | won't fix |
| `As_path::Set` | by another route | nothing. None of the four segment classes has a Hash branch, so the hash is stored as the one AS number and encode packs a Hash. As_path.segment_from_hash reads it correctly. | won't fix |
| `Atomic_aggregate` | by another route | nothing. The attribute carries no value, so there is no bare hash for its own new to read and the attribute set is the only route. That route works now; it used to drop the attribute in silence. | won't fix |
| `Attr::Raw` | yes | -- | -- |
| `Attr::Unknown` | yes | -- | -- |
| `Cluster_list` | yes | -- | -- |
| `Communities` | yes | -- | -- |
| `Large_communities` | yes | -- | -- |
| `Local_pref` | yes | -- | -- |
| `Mp_reach` | by another route | nothing. Everything nests under :mp_reach and set reads the inner hash. The unwrapped hash rebuilds all of it, next hop, RDs, labels and Path Identifiers included. | won't fix |
| `Mp_unreach` | by another route | nothing. The same :mp_unreach wrapper as Mp_reach. | won't fix |
| `Multi_exit_disc` | yes | -- | -- |
| `Next_hop` | yes | -- | -- |
| `Origin` | yes | -- | -- |
| `Originator_id` | by another route | nothing. new has no Hash branch at all, so the hash reaches IPAddr.create. The class has a new_hash that reads it. | won't fix |
| `Otc` | yes | -- | -- |
| `Path_attribute` | no | two things. A second attribute of a type already present, because the hash is one key per type, so two Communities collapse into the last one. And the tail parse_wire keeps after the last whole attribute, which has no key. Both silently. | fix |

### Extended communities

| Class | Round trips | What the hash loses, or what stands in the way | Decision |
|---|---|---|---|
| `Bgp_data_collect` | by another route | nothing. No individual extended community class has a Hash branch; these hashes are read by Extended_communities through HASH_BUILDERS, which rebuilds this one byte for byte. | won't fix |
| `Color` | by another route | nothing. No individual extended community class has a Hash branch; these hashes are read by Extended_communities through HASH_BUILDERS, which rebuilds this one byte for byte. | won't fix |
| `Encapsulation` | by another route | nothing. No individual extended community class has a Hash branch; these hashes are read by Extended_communities through HASH_BUILDERS, which rebuilds this one byte for byte. | won't fix |
| `Es_import` | by another route | nothing. No individual extended community class has a Hash branch; these hashes are read by Extended_communities through HASH_BUILDERS, which rebuilds this one byte for byte. | won't fix |
| `Esi_label` | by another route | nothing. No individual extended community class has a Hash branch; these hashes are read by Extended_communities through HASH_BUILDERS, which rebuilds this one byte for byte. | won't fix |
| `Extended_communities` | yes | -- | -- |
| `Extended_community` | no | the type octet and the sub-type: the hash is {:extended_community => [10, 20]} and that key is not in HASH_BUILDERS. This is the partial base class; a subclass is what a test builds. | won't fix |
| `Extended_community::Unknown` | by another route | nothing. Its own new refuses {:unknown=>hex}, though it takes the bare hex string. The collection reads the hash. | won't fix |
| `Ipv6_extended_communities` | yes | -- | -- |
| `Ipv6_extended_communities::Ipv6_extended_community` | yes | -- | -- |
| `Link_bandwidth` | by another route | nothing. No individual extended community class has a Hash branch; these hashes are read by Extended_communities through HASH_BUILDERS, which rebuilds this one byte for byte. | won't fix |
| `Mac_mobility` | by another route | nothing. No individual extended community class has a Hash branch; these hashes are read by Extended_communities through HASH_BUILDERS, which rebuilds this one byte for byte. | won't fix |
| `Opaque` | no | the type octet and the sub-type. :opaque is not in HASH_BUILDERS either, so nothing reads this hash, and its value ['0a0000010064', nil] cannot be fed back to a new that wants type, sub-type and value. | fix |
| `Origin_validation_state` | by another route | nothing. No individual extended community class has a Hash branch; these hashes are read by Extended_communities through HASH_BUILDERS, which rebuilds this one byte for byte. | won't fix |
| `Ospf_domain_id` | by another route | nothing. No individual extended community class has a Hash branch; these hashes are read by Extended_communities through HASH_BUILDERS, which rebuilds this one byte for byte. | won't fix |
| `Ospf_router_id` | by another route | nothing. No individual extended community class has a Hash branch; these hashes are read by Extended_communities through HASH_BUILDERS, which rebuilds this one byte for byte. | won't fix |
| `Redirect` | by another route | nothing. No individual extended community class has a Hash branch; these hashes are read by Extended_communities through HASH_BUILDERS, which rebuilds this one byte for byte. | won't fix |
| `Route_origin` | by another route | nothing. No individual extended community class has a Hash branch; these hashes are read by Extended_communities through HASH_BUILDERS, which rebuilds this one byte for byte. | won't fix |
| `Route_target` | by another route | nothing. No individual extended community class has a Hash branch; these hashes are read by Extended_communities through HASH_BUILDERS, which rebuilds this one byte for byte. | won't fix |
| `Router_mac` | by another route | nothing. No individual extended community class has a Hash branch; these hashes are read by Extended_communities through HASH_BUILDERS, which rebuilds this one byte for byte. | won't fix |
| `Traffic_action` | yes | -- | -- |
| `Traffic_marking` | by another route | nothing. No individual extended community class has a Hash branch; these hashes are read by Extended_communities through HASH_BUILDERS, which rebuilds this one byte for byte. | won't fix |
| `Traffic_rate_bytes` | by another route | nothing. No individual extended community class has a Hash branch; these hashes are read by Extended_communities through HASH_BUILDERS, which rebuilds this one byte for byte. | won't fix |
| `Traffic_rate_packets` | by another route | nothing. No individual extended community class has a Hash branch; these hashes are read by Extended_communities through HASH_BUILDERS, which rebuilds this one byte for byte. | won't fix |

### Tunnel encapsulation, prefix SID and PMSI tunnel

| Class | Round trips | What the hash loses, or what stands in the way | Decision |
|---|---|---|---|
| `Pmsi_tunnel` | no | the other seven bits of the flags octet. to_hash writes :flags only when no leaf bit is set, so flags 0x41 hash as :leaf_info_required=>true alone and the RFC 7902 Extension bit is gone: 41 comes back as 01. | fix |
| `Prefix_sid` | yes | -- | -- |
| `Prefix_sid::Label_index` | yes | -- | -- |
| `Prefix_sid::Originator_srgb` | yes | -- | -- |
| `Prefix_sid::Tlv` | yes | -- | -- |
| `Tunnel_encap` | no | both tails, the attribute level one and the per tunnel one, plus the Egress_endpoint reserved field and the Color flags underneath. 29 value octets rebuild as 26. | fix |
| `Tunnel_encap::Color` | no | the flags field. color_flags has no key in the hash, so flags 0x1234 come back as 0000 even through Sub_tlv.from_hash. | fix |
| `Tunnel_encap::Ds_field` | by another route | nothing. Its own new takes the hash where a field value belongs. Sub_tlv.from_hash is the reader and rebuilds it. | won't fix |
| `Tunnel_encap::Egress_endpoint` | no | the reserved field of RFC 9012 section 3.1. It has no key, so 11223344 comes back as 00000000 by either route. | fix |
| `Tunnel_encap::Embedded_label_handling` | by another route | nothing. Its own new takes the hash where a field value belongs. Sub_tlv.from_hash is the reader and rebuilds it. | won't fix |
| `Tunnel_encap::Encapsulation` | yes | -- | -- |
| `Tunnel_encap::Mpls_label_stack` | no | the TC and TTL octets. The hash is the label numbers only, so a stack read off the wire with TC 5 and TTL 64 comes back with both zeroed: 064a40 becomes 064000. | fix |
| `Tunnel_encap::Protocol_type` | by another route | nothing. Its own new takes the hash where a field value belongs. Sub_tlv.from_hash is the reader and rebuilds it. | won't fix |
| `Tunnel_encap::Sub_tlv` | by another route | nothing. Its own new takes the hash where a field value belongs. Sub_tlv.from_hash is the reader and rebuilds it. | won't fix |
| `Tunnel_encap::Tunnel` | no | the tail of a cut sub-TLV header. :tunnel_type, :sub_tlvs and the :length override all survive; @tail has no key. The Egress_endpoint reserved field goes with it, through the sub-TLV hash. | fix |
| `Tunnel_encap::Udp_dest_port` | by another route | nothing. Its own new takes the hash where a field value belongs. Sub_tlv.from_hash is the reader and rebuilds it. | won't fix |

### Outbound route filtering

| Class | Round trips | What the hash loses, or what stands in the way | Decision |
|---|---|---|---|
| `Orf::Unknown` | yes | -- | -- |
| `Prefix_entry` | yes | -- | -- |
| `Prefix_orf` | yes | -- | -- |

### NLRI encodings

| Class | Round trips | What the hash loses, or what stands in the way | Decision |
|---|---|---|---|
| `Inet_multicast` | yes | -- | -- |
| `Inet_unicast` | yes | -- | -- |
| `Label` | yes | -- | -- |
| `Label_stack` | no | the 3 bit Rsrv field RFC 8277 section 2.2 puts above each label, which bgp4r calls exp. 000642000653 comes back as 000640000651. The Bottom of Stack bit goes the same way, though encode writes 0 for every entry above the bottom anyway. The @compatibility form is the one shape that does round trip. | fix |
| `Labeled` | no | the Path Identifier, and the label exp field with it. Label_stack writes :label for a one label stack where Labeled reads only :labels, so a single label stack builds empty and encode dies on nil; with two labels it builds and drops the Path Identifier, because new passes the prefix string alone to Prefix.new. | fix |
| `Nlri` | by another route | nothing. The list has to be splatted: Nlri.new(*h[:nlris]) rebuilds it, where Nlri.new(h) sends the Hash to add, which has no :path_id key and hits a bare raise. | won't fix |
| `Prefix` | yes | -- | -- |
| `Rd` | yes | -- | -- |
| `Vpn` | by another route | nothing. The hash carries :rd and :prefix, and both rebuild it, but new matches only String, Prefix and Rd so a Hash matches nothing and encode dies on @rd. The route here is the two fields handed back by hand, which is what proves the hash is complete. | fix |
| `Withdrawn` | by another route | nothing. The same splat as Nlri, under the :withdrawns key. | won't fix |

### Messages

| Class | Round trips | What the hash loses, or what stands in the way | Decision |
|---|---|---|---|
| `Notification` | by another route | nothing. :code, :subcode and :data are all there and all rebuild it, but new has no Hash branch, so the hash becomes @code and encode raises in pack. The route here is the three fields handed back by hand, which is what proves the hash is complete. | fix |
| `Open` | yes | -- | -- |
| `Orf_route_refresh` | yes | -- | -- |
| `Route_refresh` | yes | -- | -- |
| `Update` | yes | -- | -- |

### OPEN capabilities

| Class | Round trips | What the hash loses, or what stands in the way | Decision |
|---|---|---|---|
| `OPT_PARM::CAP::Add_path` | yes | -- | -- |
| `OPT_PARM::CAP::As4` | yes | -- | -- |
| `OPT_PARM::CAP::Dynamic` | yes | -- | -- |
| `OPT_PARM::CAP::Enhanced_route_refresh` | yes | -- | -- |
| `OPT_PARM::CAP::Extended_nexthop` | yes | -- | -- |
| `OPT_PARM::CAP::Graceful_restart` | yes | -- | -- |
| `OPT_PARM::CAP::Mbgp` | yes | -- | -- |
| `OPT_PARM::CAP::Orf` | yes | -- | -- |
| `OPT_PARM::CAP::Orf::Entry` | yes | -- | -- |
| `OPT_PARM::CAP::Role` | yes | -- | -- |
| `OPT_PARM::CAP::Route_refresh` | yes | -- | -- |
| `OPT_PARM::CAP::Unknown` | yes | -- | -- |
| `OPT_PARM::Capability` | by another route | nothing. One field, :code, and it rebuilds the capability, but new makes the Hash the code and encode raises. The route here is that field handed back by hand. | won't fix |
| `OPT_PARM::Capability::Unknown` | no | its value octets. It inherits Capability#to_hash, so the hash is {:code=>100} and the five octets it kept are gone. CAP::Unknown, the sibling one namespace down, has its own to_hash with :value and does round trip. | fix |
| `OPT_PARM::Optional_parameter::Unknown` | yes | -- | -- |

## Two classes with no recipe

Both are abstract bases with no sensible instance, so there is nothing
to measure. They are listed in `NO_RECIPE` in the catalog, with the
reason, because the completeness guard counts them as accounted for.

* `Extended_community::Typed`. All three build paths fail inside it:
  `TYPE` and `SUBTYPE` are supplied only by subclasses, so a field or
  hash build raises `NameError`, and a wire build raises
  `NoMethodError` on `parse_value`. Its subclasses are measured instead.
* `Tunnel_encap::Int_sub_tlv`. Its `initialize` and `to_hash` read
  `self.class::TYPE`, `SIZE`, `NAME` and `KEY`, and it defines none of
  them, so `new(5)` raises `NameError`. Its four concrete subclasses are
  measured instead.

## The DYN_CAP classes

`capabilities.rb` generates one bare subclass of each `CAP` class into
`OPT_PARM::DYN_CAP`, overriding nothing, so each one's hash behaviour is
its parent's by construction. They are not in the table. The test
asserts that construction instead, which is why eleven more rows saying
the same thing are not needed, and which would catch a `DYN_CAP` class
that grew a `to_hash` of its own.

## Changing something here

The catalog and this document are checked against each other, so a
change has to touch both in the same pull request. Fixing a round trip
means moving its row and its catalog entry together; the test will say
so if only one of them moves. Adding a class that answers `to_hash`
means adding a row, a recipe and a decision, and the test will fail
until all three are there.
