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
form because that is what its test wrote. Both halves work. 42 of the 96
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

And the three capabilities whose hash is a bare `{:code=>n}` are the
clean confirmation: `CAP::Add_path`, `CAP::Graceful_restart` and
`CAP::Orf` have **no hash-construction test at all**, so no `to_hash` was
ever written for them and they inherit `Capability`'s. Every capability
that does round trip has one.

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
| **not in its attribute** | Its own `new` does, the other route does not. Worse than it sounds: a hash key inherited from a parent class is the cause, and the attribute then rebuilds a different attribute without saying so. |
| **no** | No route gives the octets back. Information is gone. |

Of the 96 classes measured: **33 round trip through their own `new`**,
**42 by another route**, **1 only outside its attribute**, and **20 lose
information**. Whether a failing route raises or quietly answers
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

**35 are left as they are.** Nearly all of them are the same situation:
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

**28 are to be fixed**, in this order.

First, the ones that are quietly wrong, because a confident wrong answer
is worse than a refusal and these are the only ones that can put bad
octets on the wire without saying so:

1. `Tunnel_encap::Encapsulation` writes the 28 octets of a Ruby `inspect`
   string as the sub-TLV value.
2. `Attr::Raw` and `Attr::Unknown` turn into `000000`, a different
   attribute entirely.
3. `As4_aggregator` and `As4_path` come back as their 2-octet
   namesakes, cutting the AS number, because both inherit the parent's
   hash key.
4. `Atomic_aggregate` disappears from a round-tripped `Path_attribute`,
   because its hash is `{}`.
5. `Traffic_action`, `Prefix_sid`, `Prefix_sid::Originator_srgb` and
   `CAP::Orf` each build a clean looking empty or zeroed object.
6. `Path_attribute` drops `ATOMIC_AGGREGATE`, collapses two attributes
   of one type into one, and loses its tail.

Second, the cheap ones, where the hash is already complete and only a
constructor branch is missing: `Origin` (one line, and the translation
it needs is already three lines above), `Notification`, `Vpn`,
`Prefix_sid::Tlv`.

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

## The table

### Path attributes

| Class | Round trips | What the hash loses, or what stands in the way | Decision |
|---|---|---|---|
| `Aggregator` | by another route | nothing. The fields nest under :aggregator and new reads the inner hash, so Path_attribute is the door. | won't fix |
| `Aigp` | yes | -- | -- |
| `As4_aggregator` | no | that it is AS4_AGGREGATOR at all. It inherits Aggregator#to_hash, so its key is :aggregator, and Path_attribute rebuilds a 2 octet AGGREGATOR and cuts AS 4200000001 to 59905. Silently. | fix |
| `As4_path` | not in its attribute | that it is AS4_PATH, once it goes through an attribute set. The key :as_path is inherited, so Path_attribute rebuilds a type 2 AS_PATH in the 2 octet form and cuts the AS. Silently. | fix |
| `As_path` | yes | -- | -- |
| `As_path::Confed_sequence` | by another route | nothing. None of the four segment classes has a Hash branch, so the hash is stored as the one AS number and encode packs a Hash. As_path.segment_from_hash reads it correctly. | won't fix |
| `As_path::Confed_set` | by another route | nothing. None of the four segment classes has a Hash branch, so the hash is stored as the one AS number and encode packs a Hash. As_path.segment_from_hash reads it correctly. | won't fix |
| `As_path::Sequence` | by another route | nothing. None of the four segment classes has a Hash branch, so the hash is stored as the one AS number and encode packs a Hash. As_path.segment_from_hash reads it correctly. | won't fix |
| `As_path::Set` | by another route | nothing. None of the four segment classes has a Hash branch, so the hash is stored as the one AS number and encode packs a Hash. As_path.segment_from_hash reads it correctly. | won't fix |
| `Atomic_aggregate` | no | itself. to_hash is {}, so a round tripped Path_attribute comes back without ATOMIC_AGGREGATE in it. Silently. The registry has a working :atomic_aggregate key that to_hash never writes. | fix |
| `Attr::Raw` | by another route | nothing through an attribute set. Its own new reads :flags, :type and :value off the outer hash, where to_hash put them one level down in a one element :unknown list, so all three are nil and 80c802ff00 comes back as 000000. Silently. | fix |
| `Attr::Unknown` | by another route | nothing through an attribute set. It inherits both to_hash and the Hash branch from Attr::Raw, so c0630178 comes back as 000000 the same silent way. | fix |
| `Cluster_list` | yes | -- | -- |
| `Communities` | yes | -- | -- |
| `Large_communities` | yes | -- | -- |
| `Local_pref` | yes | -- | -- |
| `Mp_reach` | by another route | nothing. Everything nests under :mp_reach and set reads the inner hash. The unwrapped hash rebuilds all of it, next hop, RDs, labels and Path Identifiers included. | won't fix |
| `Mp_unreach` | by another route | nothing. The same :mp_unreach wrapper as Mp_reach. | won't fix |
| `Multi_exit_disc` | yes | -- | -- |
| `Next_hop` | yes | -- | -- |
| `Origin` | by another route | nothing. to_hash stores the word, {:origin=>:incomplete}, and the Hash branch of new assigns it raw, skipping the Symbol translation new already has three lines above. One line. | fix |
| `Originator_id` | by another route | nothing. new has no Hash branch at all, so the hash reaches IPAddr.create. The class has a new_hash that reads it. | won't fix |
| `Otc` | yes | -- | -- |
| `Path_attribute` | no | three things. ATOMIC_AGGREGATE, because its hash is {}. A second attribute of a type already present, because the hash is one key per type, so two Communities collapse into one. And the tail parse_wire keeps after the last whole attribute, which has no key. | fix |

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
| `Traffic_action` | by another route | nothing through the collection. Its own new reads :sample, :terminal and :bits off the outer hash, finds all three nil, and builds a clean looking community encoding 8007000000000000 instead of 8007ffffffffffff. Silently, where the other Typed classes raise because their field defaults fail a check. | fix |
| `Traffic_marking` | by another route | nothing. No individual extended community class has a Hash branch; these hashes are read by Extended_communities through HASH_BUILDERS, which rebuilds this one byte for byte. | won't fix |
| `Traffic_rate_bytes` | by another route | nothing. No individual extended community class has a Hash branch; these hashes are read by Extended_communities through HASH_BUILDERS, which rebuilds this one byte for byte. | won't fix |
| `Traffic_rate_packets` | by another route | nothing. No individual extended community class has a Hash branch; these hashes are read by Extended_communities through HASH_BUILDERS, which rebuilds this one byte for byte. | won't fix |

### Tunnel encapsulation, prefix SID and PMSI tunnel

| Class | Round trips | What the hash loses, or what stands in the way | Decision |
|---|---|---|---|
| `Pmsi_tunnel` | no | the other seven bits of the flags octet. to_hash writes :flags only when no leaf bit is set, so flags 0x41 hash as :leaf_info_required=>true alone and the RFC 7902 Extension bit is gone: 41 comes back as 01. | fix |
| `Prefix_sid` | no | the sub-TLVs' reserved and flags fields, as above. Its own new is quiet about it too: given its own full hash it finds no key it knows and builds an empty attribute, c02800. | fix |
| `Prefix_sid::Label_index` | no | the reserved octet and the flags of RFC 8669 section 3.1. Neither has a key, so 0a c000 comes back as 00 0000. | fix |
| `Prefix_sid::Originator_srgb` | no | the flags of RFC 8669 section 3.2. And its own new does not recognise its own hash: it reads the hash as one range, so hash[0].to_i is 0 and it builds the range [0, 0]. Silently. | fix |
| `Prefix_sid::Tlv` | by another route | nothing. The hash is {:type, :value} and carries both, but nothing reads it: new(type, value) takes the hash as the type. The other route here is the two fields handed back by hand, which is what proves the hash is complete. | fix |
| `Tunnel_encap` | no | both tails, the attribute level one and the per tunnel one, plus the Egress_endpoint reserved field and the Color flags underneath. 29 value octets rebuild as 26. | fix |
| `Tunnel_encap::Color` | no | the flags field. color_flags has no key in the hash, so flags 0x1234 come back as 0000 even through Sub_tlv.from_hash. | fix |
| `Tunnel_encap::Ds_field` | by another route | nothing. Its own new takes the hash where a field value belongs. Sub_tlv.from_hash is the reader and rebuilds it. | won't fix |
| `Tunnel_encap::Egress_endpoint` | no | the reserved field of RFC 9012 section 3.1. It has no key, so 11223344 comes back as 00000000 by either route. | fix |
| `Tunnel_encap::Embedded_label_handling` | by another route | nothing. Its own new takes the hash where a field value belongs. Sub_tlv.from_hash is the reader and rebuilds it. | won't fix |
| `Tunnel_encap::Encapsulation` | by another route | nothing through Sub_tlv.from_hash. Its own new takes the hash as the value octets and calls to_s on it, so the sub-TLV value becomes the 28 octets of {:encapsulation=>"01020304"} as Ruby inspects it. Silently, and on the wire. | fix |
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
| `OPT_PARM::CAP::Add_path` | no | every RFC 7911 section 4 <AFI, SAFI, Send/Receive> tuple. The hash is {:code=>69} whatever the capability holds. | fix |
| `OPT_PARM::CAP::As4` | yes | -- | -- |
| `OPT_PARM::CAP::Dynamic` | yes | -- | -- |
| `OPT_PARM::CAP::Enhanced_route_refresh` | yes | -- | -- |
| `OPT_PARM::CAP::Extended_nexthop` | yes | -- | -- |
| `OPT_PARM::CAP::Graceful_restart` | no | the restart state, the restart time and every address family tuple. The hash is {:code=>64} whatever the capability holds. | fix |
| `OPT_PARM::CAP::Mbgp` | yes | -- | -- |
| `OPT_PARM::CAP::Orf` | no | every ORF Entry. The hash is {:code=>3}, and new with a Hash quietly builds an empty capability, so 26 octets become 4. Orf::Entry has no to_hash at all and its own new has an empty Hash branch. | fix |
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
