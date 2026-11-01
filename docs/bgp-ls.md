# BGP-LS on the wire

RFC 9552, "Distribution of Link-State and Traffic Engineering
Information Using BGP", as much of it as is needed to write the
encoding and decoding. Read this before touching
`bgp/nlris/link_state_tlv.rb` or `bgp/nlris/link_state.rb`, before
adding a TLV type or an NLRI type, before changing how `mp_reach.rb`
and `mp_unreach.rb` frame an NLRI or read a next hop, and before
putting a BGP-LS check in `validation.rb`.

Its load bearing claims are asserted by `test/unit/bgp_ls_doc_test.rb`,
whose NLRI type and TLV tables are **discovered** rather than listed,
so a class cannot join the library without this document being told.

Every section number here was read in the RFC text on 2026-10-31.

## 1. The documents, as a list, before the parts start

RFC 9552, December 2023. It **obsoletes RFC 7752 and RFC 9029**, the
second "by incorporating the updates that it made to RFC 7752", so
neither is a source for anything here.

**Nothing updates RFC 9552.** Checked as a list before any code was
written, rather than once in the middle, which is the rule MCAST-VPN
part 5 earned after RFC 6515 was missed by applying it only to route
types.

Two verified errata, and only one of them matters:

* **EID 7789**, section 5.3.1.1, the Node Flag Bits TLV: Figure 15
  prints `T` where Table 7 defines bit 1 as `A`, the Attached bit. The
  published text still shows the figure as it was, so the document
  disagrees with itself and the erratum settles it. That is the RFC 8956
  situation exactly, and `docs/flow-spec.md` records what it cost to
  explain such a thing with an invented mechanism instead of reading the
  errata. **Read the errata for any RFC whose own figure you are about
  to disbelieve**, at `https://www.rfc-editor.org/errata/rfc9552`.
  Applied in part 5a: `Node_flag_bits` names bit 1 Attached and has no
  T bit, and section 10a carries the mask table.
* **EID 8766**, section 5.2.2, is a stray "and" and is editorial.

**The whole RFC is readable now.** An earlier version of the plan
recorded sections 5.4 onward as unfetchable, measured across four
sources on 2026-10-31, all of which truncate in section 5.2 or 5.3.
The document was attached to the session instead, which is how section
9 of RFC 4271 was eventually read as well. So nothing here is second
hand, and two things the plan had marked as provisional are discharged:
section 5.4's normative keywords, which a PDF mirror had lost, and
section 8.2.2, which part 6 was gated on.

**RFC 9552 carries no worked example and no hex anywhere.** Measured:
the six occurrences of "0x" in the document are the OSPF route type
values of section 5.2.3.1. So this is the RFC 4684, RFC 6368 and RFC
6514 situation rather than the flow spec one, where five vectors in two
RFCs caught four wrong hand-written expectations. Those three families
cost eleven wrong hand-written expectations between them, the library
being right every time, and **part 1 added a twelfth within the hour**:
the first draft of `test_a_private_use_tlv_reads_its_enterprise_code`
asserted 77865 for `0x00013039`, which is 77881. So compute the vectors
with the library and paste the result, write the field breakdown in a
comment beside each one, and prefer a value that is checkable against
something outside this repository, which is why that case now uses
Enterprise Number 2636.

## 2. The TLV, section 5.1

One shape for the whole family:

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|              Type             |             Length            |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
//                        Value (variable)                     //
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

"Information in the Link-State NLRIs and the BGP-LS Attribute is
encoded in Type/Length/Value triplets. The TLV format is shown in
Figure 4 and applies to both the NLRI and the BGP-LS Attribute
encodings."

So a node descriptor, a link descriptor, a node descriptor sub-TLV and
an attribute TLV are all this shape. **That is what makes the framing
the cheapest of the five families this plan has done while the breadth
is the dearest**: one rule against EVPN's eleven layouts and
MCAST-VPN's seven, and 139 code points against their eighteen.

Two octets each, and the section says what the Length counts and what
it does not: "The Length field defines the length of the value portion
in octets (thus, a TLV with no value portion would have a length of
zero). The TLV is not padded to 4-octet alignment." Both halves are
easy to get wrong from memory, since the neighbouring IGP encodings do
pad.

`Link_state::Tlv` is the only place in the library that knows this. A
registered TLV class supplies `encode_value` and writes no framing of
its own, which is the layering Conventions calls deliberate for
`Orf#encode` and the capability classes.

### Keep and echo is mandated here, which inverts what flow spec taught

Section 5.1: "Unknown and unsupported types MUST be preserved and
propagated within both the NLRI and the BGP-LS Attribute", and "The
presence of unknown or unexpected TLVs MUST NOT result in the NLRI or
the BGP-LS Attribute being considered malformed."

**RFC 8955 section 4.2 says the opposite** for a flow spec component
type, in so many words, and `docs/flow-spec.md` records the cost of
that: a type IANA assigns tomorrow reads as malformed until bgp4r
implements it. Each rule is its own RFC's instruction and bgp4r follows
each. Do not carry one family's answer across.

Conventions' note that keep and echo is bgp4r's own ground still holds,
and here an RFC agrees with it outright, which is worth knowing before
anyone files the behaviour as over-engineering. RFC 9251 section 9.3.1
agreed about one reserved field; this agrees about a whole class of
them.

### The ordering rule is three levels and lives with the TLV

"To compare NLRIs with unknown TLVs, all TLVs within the NLRI MUST be
ordered in ascending order by TLV Type. If there are multiple TLVs of
the same type within a single NLRI, then the TLVs sharing the same type
MUST be first in ascending order based on the Length field followed by
ascending order based on the Value field. Comparison of the Value
fields is performed by treating the entire field as opaque binary data
and ordered lexicographically (i.e., treating each byte of binary data
as a symbol to compare, with the symbols ordered by their numerical
value). NLRIs having TLVs that do not follow the above ordering rules
MUST be considered as malformed by a BGP-LS Propagator."

`Link_state::Tlv.ordered?` is that, in one place, so part 6 asks rather
than reimplementing it. Three details that a readable implementation
gets wrong:

* **The second level is the Length field and not the value's real
  size.** A TLV whose declared Length lies sorts by the lie. An
  implementation using the real size passes every other ordering test.
* **The third level is bytewise and numerical**, which the section
  spells out rather than leaving to a reader. Ruby's `String#<=>` on two
  binary strings is exactly that, which is why every value here is
  forced to binary. The test pair is 0x7f against 0x80 on purpose.
* **The rule is the NLRI's.** The attribute's own is two sentences on
  and is a SHOULD whose breach is explicitly not malformed: "The TLVs
  within the BGP-LS Attribute SHOULD be ordered in ascending order by
  TLV type. The BGP-LS Attribute with unordered TLVs MUST NOT be
  considered malformed." So a caller has to say which it is asking
  about, and `ordered?` answers the question rather than the policy.

Note the scope qualifier in the NLRI sentence: malformed "by a BGP-LS
Propagator", not by every receiver. Nothing else in bgp4r's validation
has a role qualifier, so that is a decision for part 6 rather than a
patch.

### Five shared bases, which live with the framing

`link_state_tlv.rb` holds five value shapes that more than one of the
RFC's tables uses, so a TLV class in any of the family's files is
usually three constants on top of one of them:

| Base | Value | First used by |
|---|---|---|
| `Opaque32` | one 32-bit unsigned integer, 4 octets | Table 3's 512, 513 and 514 |
| `Addr_tlv` | one IP address of a fixed `WIDTH` | Table 4's four address TLVs |
| `Opaque_tlv` | opaque octets of no fixed width | Table 6's 1025 and 1027 |
| `Text_tlv` | a symbolic name in 7-bit ASCII | Table 6's 1026 |
| `Int_list_tlv` | a list of unsigned integers of one width, from `PACK` | Table 8's 1096 |

**Each was written where its first user was and the first four moved
here in part 5b-i**, once Table 8 turned out to want every one of them:
1088 and 1092 are `Opaque32`, 1030 and 1031 are `Addr_tlv`, 1097 is
`Opaque_tlv` and 1098 is `Text_tlv`. Leaving them put would have meant
three sideways requires and three file names that no longer described
what they held.

**`Int_list_tlv` came out of `Srlg` in part 5c for the same reason**,
once Table 10's two route tags turned out to be the same shape: 1153 is
a 4-octet element and 1154 an 8-octet one, so three subclasses across
two tables. **Its `PACK` is the only place each element width is
stated**, which is part 5b-ii's finding applied up front: the `WIDTH =
4` that `Srlg` used to carry beside its `'N*'` was a second statement of
one fact, and a sabotage changing it to 2 passed the whole suite because
nothing read it.

**The move changed no constant path**, because every file in this family
reopens `BGP::Link_state::Tlv`, which is also why it was cheap to defer
until a second table needed one. Phase 1 of the breadth plan in
`CLAUDE.md` is the same argument one level up: build the shared thing
when the second caller arrives, not before.

`Text_tlv` came out of `Node_name` in that move rather than being found
first, and the two sections it serves say why it is one shape: sections
5.3.1.3 and 5.3.2.7 are the same three paragraphs with "router node" and
"router link" swapped, down to the 7-bit ASCII rule and the 255 whose
scope neither settles.

## 3. The NLRI, section 5.2

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|            NLRI Type          |     Total NLRI Length         |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                 Route Distinguisher (8 octets)                |  SAFI 72 only
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
//                  Link-State NLRI (variable)                 //
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

Figures 5 and 6. "All non-VPN link, node, and prefix information SHALL
be encoded using AFI 16388 / SAFI 71. VPN link, node, and prefix
information SHALL be encoded using AFI 16388 / SAFI 72."

**The Length counts the RD**, which is the detail to get right: "The
Total NLRI Length field contains the cumulative length, in octets, of
the rest of the NLRI, not including the NLRI Type field or itself. For
VPN applications, it also includes the length of the Route
Distinguisher."

So `Link_state.nlri_size` is `4 + total` and **takes no SAFI**, which
is section 5.2's doing rather than a simplification: one arithmetic
frames both SAFIs and a VPN NLRI is simply eight octets longer. It is
the analogue of `Evpn.nlri_size` and `Mcast_vpn.nlri_size`, read by the
same `MpReachCommon::ClassMethods#nlri_size`, and part 4 is where the
two parse loops learn to ask it.

### The SAFI is a parse-time input, which is flow spec's situation

Nothing in the octets says whether an RD is there: figures 5 and 6
differ by eight octets and by nothing a reader can see. So a capture
has to be told which SAFI it arrived under, the same way a flow spec
rule has to be told its AFI, and `Flow_spec` is the precedent down to
`@safi` deciding whether there is an RD. The default is SAFI 71.

The same octets read as SAFI 71 put the RD inside the body, and **both
readings replay byte for byte**, which is what makes this a parse-time
input rather than a bug.

**No AFI input**, where MCAST-VPN had two AFIs to think about: section
5.2 fixes one, 16388, for both SAFIs. One AFI, two SAFIs, and it is the
SAFI that changes the octets. That is the opposite split from every
family before this one.

### The four NLRI types

Table 1, and all four are in. The "In bgp4r" column is
**discovered** by `test/unit/bgp_ls_doc_test.rb` from
`Link_state::TYPES` rather than compared against a list in the test, so
a row saying yes with no class behind it and a class with a row saying
no both fail the suite:

| Type | NLRI Type | Body, after Protocol-ID and Identifier | In bgp4r |
|---|---|---|---|
| 1 | Node NLRI | Local Node Descriptors | yes |
| 2 | Link NLRI | Local and Remote Node Descriptors, Link Descriptors | yes |
| 3 | IPv4 Topology Prefix NLRI | Local Node Descriptors, Prefix Descriptors | yes |
| 4 | IPv6 Topology Prefix NLRI | the same, IPv6 | yes |

Each body begins with a **Protocol-ID**, one octet, and an
**Identifier**, 8 octets, which is the BGP-LS Instance-ID. Figures 7 to
9. Types 3 and 4 "use the same format", so they differ by type number
and by the address family of what their descriptors carry.

**So NLRI types 3 and 4 are one layout and two type numbers**, the
third instance of that shape in this family after TLV 256 and 257 and
`Mcast_vpn`'s two section 4.6 types. `Link_state::Prefix_nlri` is the
layout and the two subclasses carry the one thing that differs, which
is the family. The shared base is **registered nowhere**, so it cannot
read as a fifth NLRI type; MCAST-VPN part 3 chose modules over base
classes for exactly that reason, and here the registry already settles
it, because discovery is from `Link_state::TYPES` and not from
subclasses.

**A Link NLRI is half a link**, which section 5.2.2 says outright and
which a reader will otherwise assume wrong: "A link described by the
Link Descriptor TLVs actually is a 'half-link', a unidirectional
representation of a logical link. To fully describe a single logical
link, two anchor routers advertise a half-link each, i.e., two Link
NLRIs are advertised for a given point-to-point link." So nothing in
bgp4r pairs two of them, and a single Link NLRI is not a link.

**So the three layouts share a head and differ only in what follows
it**, which is figures 7, 8 and 9 read together rather than one at a
time. `Link_state::Headed` carries the head, and each NLRI type is a
type number, a hash key and whatever it says about the TLVs it expects.
Table 2's Protocol-IDs are 1 IS-IS Level 1, 2 IS-IS Level 2, 3 OSPFv2,
4 Direct, 5 Static configuration and 6 OSPFv3, with 0 Reserved and 200
to 255 Private Use.

**The body after the head is a TLV list and not a set of named
fields**, which is section 5.1 rather than a shortcut: an unknown TLV
"MUST be preserved and propagated" and must not make the NLRI
malformed, and a layout of named fields would have nowhere to put one.
It also means a Node NLRI carrying no Local Node Descriptors builds and
parses, which is right twice over, since section 8.2.2 names "presence
of a mandatory TLV" among the semantic validations a BGP-LS Propagator
should **not** perform and building never validates in any case.

## 3b. The node descriptors, section 5.2.1

TLV 256 and TLV 257 are **one layout and two type numbers**. Section
5.2.1.2: the Local Node Descriptors TLV "contains Node Descriptors for
the node anchoring the local end of the link. This is a mandatory TLV
in all three types of NLRIs (node, link, and prefix). The Type is 256.
The length of this TLV is variable. The value contains one or more Node
Descriptor sub-TLVs defined in Section 5.2.1.4." Section 5.2.1.3 is the
same sentence with "remote end" and "mandatory TLV for Link NLRIs", and
figures 10 and 11 are identical. `Mcast_vpn::Shared_tree_join` and
`Source_tree_join` are the same shape for the same reason.

The four sub-TLVs, Table 3 of section 5.2.1.4. The "In bgp4r" column is
**discovered** from `Link_state::Tlv::REGISTRY`, so a row saying yes
with no class behind it and a class with a row saying no both fail the
suite:

| Code Point | Description | Length | In bgp4r |
|---|---|---|---|
| 256 | Local Node Descriptors | Variable | yes |
| 257 | Remote Node Descriptors | Variable | yes |
| 512 | Autonomous System | 4 | yes |
| 513 | BGP-LS Identifier (deprecated) | 4 | yes |
| 514 | OSPF Area-ID | 4 | yes |
| 515 | IGP Router-ID | Variable | yes |

**One flat registry covers TLVs and sub-TLVs alike, and that is IANA's
doing rather than a simplification.** The registry is "BGP-LS NLRI and
Attribute TLVs", one space for both, and Table 18 lists 256 and 257
beside 512 to 515 with no column saying which is which. So a sub-TLV
number means the same thing under every parent, which is the opposite
of the EVPN extended community sub-types and of the IS-IS sub-TLVs,
where the parent decides. That is why part 1's single
`Tlv::REGISTRY` needed nothing in part 2.

**513 is deprecated and implemented anyway.** Table 18 carries the row
and marks it deprecated, and section 5.2.1.4 says implementations
"SHOULD support the advertisement of this sub-TLV for backward
compatibility in deployments where there are BGP-LS Producer
implementations that conform to [RFC7752]", with "The default value of 0
is RECOMMENDED". A deprecated code point a peer still sends is exactly
what a protocol testing tool has to read.

### The IGP Router-ID has four widths and the width alone does not say which

Section 5.2.1.4 describes four, and the table is held against
`Igp_router_id::SHAPES` by the doc test so the two cannot drift:

| Width | Protocol-IDs | Node kind | What the octets are |
|---|---|---|---|
| 4 | 3, 6 | non_pseudonode | OSPFv2 or OSPFv3 Router-ID |
| 6 | 1, 2 | non_pseudonode | IS-IS ISO System-ID |
| 7 | 1, 2 | pseudonode | IS-IS DIS System-ID and PSN identifier |
| 8 | 3, 6 | pseudonode | OSPF DR Router-ID and interface |

In the section's own words: 7 octets is "the 6-octet ISO Node-ID of the
Designated Intermediate System (DIS) followed by a 1-octet, nonzero PSN
identifier", and 8 is "the 4-octet Router-ID of the DR followed by" an
IPv4 address for OSPFv2 or an interface identifier for OSPFv3.

Then the sentence that is the rule: "The TLV size in combination with
the protocol identifier enables the decoder to determine the type of
the node."

**Both halves, and they live one level apart.**
`Igp_router_id::SHAPES` is keyed by width and names which Protocol-IDs
each width belongs to; `Link_state::Node#node_type` does the combining,
because that is the one place that has the Protocol-ID as well.
Threading the Protocol-ID down into the sub-TLV would buy nothing,
since the octets replay without it, and a class that accepted it would
eventually use it.

`node_type` answers `:non_pseudonode` or `:pseudonode` only where the
two halves agree, and nil otherwise. **nil is an answer and not a
failure**: a 6-octet Router-ID under Protocol-ID 4, 'Direct', is
perfectly legal, because the section says that for 'Direct' or 'Static
configuration' the value "SHOULD be taken from an IPv4 or IPv6
address", so it describes no node kind there at all. Reporting one
would be inventing it.

Any other width parses and replays and answers no shape. Opaque is the
RFC's word for the field, and a width it does not describe is not an
error it names.

### The two rules of section 5.2.1.4, and why there are only two levels

"At most, there MUST be one instance of each sub-TLV type present in
any Node Descriptor. The sub-TLVs within a Node Descriptor MUST be
arranged in ascending order by sub-TLV type."

**That ordering rule is section 5.1's with its tiebreakers made
unnecessary**, and noticing why is worth more than the two sentences:
5.1 orders by type, then by Length, then by Value, because several TLVs
of one type can share an NLRI. Here the once-only rule means two
sub-TLVs never share a type, so there is nothing left to break a tie.
So `Node_descriptors#ordered?` asks `Tlv.ordered?` rather than keeping
a second comparison, and `#duplicate_types` reports the other rule.
Both report; neither refuses, because building never validates and part
6 is where a receive side check reads them.

## 3c. The link and prefix descriptors, sections 5.2.2 and 5.2.3

### Table 4 has no Length column and Table 5 has one

That is the first thing to know before writing either set, because it
decides where the widths come from. **Table 5 gives a Length for each
of its three rows**, so the OSPF Route Type being 1 octet and the IP
Reachability Information being variable are RFC 9552's own statements.
**Table 4 gives none**, so every link descriptor width here was read in
the document that defines the TLV, which is a different RFC per row:

The "In bgp4r" column here and in the next table is **discovered** from
`Link_state::Tlv::REGISTRY` by `test/unit/bgp_ls_doc_test.rb`, the same
way section 3b's is, so a row saying yes with no class behind it and a
class with a row saying no both fail the suite.

| Type | Link Descriptor | Width | Where the width is stated | In bgp4r |
|---|---|---|---|---|
| 258 | Link Local/Remote Identifiers | 8 | RFC 5307 section 1.1 | yes |
| 259 | IPv4 interface address | 4 | RFC 5305 section 3.2 | yes |
| 260 | IPv4 neighbor address | 4 | RFC 5305 section 3.3 | yes |
| 261 | IPv6 interface address | 16 | RFC 6119 section 4.2 | yes |
| 262 | IPv6 neighbor address | 16 | RFC 6119 section 4.3 | yes |
| 263 | Multi-Topology Identifier | 2*n | RFC 9552 section 5.2.2.1 | yes |

And Table 5's own three rows, whose Lengths are the RFC's:

| Type | Prefix Descriptor | Length | Where it is defined | In bgp4r |
|---|---|---|---|---|
| 263 | Multi-Topology Identifier | variable | section 5.2.2.1 | yes |
| 264 | OSPF Route Type | 1 | section 5.2.3.1 | yes |
| 265 | IP Reachability Information | variable | section 5.2.3.2 | yes |

TLV 258 is "4 octets of Link Local Identifier" then "4 octets of Link
Remote Identifier", local first, and RFC 5307 says the remote one is
"set to 0 if it is unknown". The four address TLVs are a single address
each, and section 5.2.2 adds a rule of its own about them: "IPv4/IPv6
link-local addresses MUST NOT be carried in the ... TLVs
(259/260/261/262) as descriptors of a link since they are not
considered unique." RFC 6119 says the same thing for its two.

**TLV 263 appears in both tables and is one class**, not two. Section
5.2.2.1 defines it and Table 5's third row is the same TLV used as a
prefix descriptor, so `Multi_topology_id` is registered once and the
two tables in this guide share it.

### Four of the link descriptors can repeat, which confirms section 5.1

Section 5.2.2 says of TLVs 259 to 262 "This sub-TLV can occur multiple
times". So two TLVs of one type in one NLRI is ordinary traffic here,
not a negative test, and **that is what section 5.1's Length and Value
tiebreakers are for**, read from the other end. The node descriptor
sub-TLVs are the opposite case, where the once-only rule of section
5.2.1.4 makes those same tiebreakers unreachable.

### The MT-ID is the family's first reserved field

Section 5.2.2.1: the value is 2*n octets, each word four R bits then a
12-bit Multi-Topology ID, and "the length of the TLV is 2*n, where n is
the number of MT-IDs carried in the TLV".

**The R bits mean two different things depending on where the TLV
sits**, in one sentence of the section: "In the case of the MT-ID TLV
being used as a descriptor of an IGP link or prefix, the Bits R are
reserved and MUST be set to 0 when originated and ignored on receipt",
where in a Node attribute they are "set as per Section 7.1 of
[RFC5120]". So this is the ordinary keep-and-echo rule rather than a
new one: `Multi_topology_id#reserved_set?` reports a nibble that
arrived set, the octets are echoed as they came, and the hash carries
the words rather than the bare IDs only when one is set. Part 5 is
where the attribute's reading of the same field lands.

### The IP Reachability TLV holds no family, the second cross-level read

Section 5.2.3.2 gives a Prefix Length in bits and then "the most
significant octets of the prefix, i.e., 1 octet for prefix length 1 up
to 8, 2 octets for prefix length 9 up to 16, 3 octets for prefix length
17 up to 24, 4 octets for prefix length 25 up to 32, etc." So the width
is `(bits + 7) / 8`, which is the arithmetic every prefix family in
this library already does, and the section spells the first four cases
out rather than leaving them to be derived. "Any trailing bits MUST be
set to 0."

**Nothing in the TLV says whether those octets are IPv4 or IPv6**: the
NLRI type does, 3 or 4. So `Tlv::Ip_reachability` holds the bit count
and the octets and `Prefix_nlri#prefix` combines them, which is the
same split as `Igp_router_id` and `Headed#node_type` one section
earlier, for the same reason: the octets replay without the family, and
a class that accepted one would eventually use it.

**A mis-typed Prefix NLRI is wrong without being malformed**, and that
is the sharpest way to put the split. 2001:db8::/32 packs down to the
same four octets as 32.1.13.184/32, so an IPv6 prefix in an NLRI of
type 3 reads back as a **different valid prefix** rather than as
nothing. Nothing in the octets can catch it, nothing here refuses it,
and section 8.2.2 names that shape of check among the semantic
validations a BGP-LS Propagator should not make anyway.

Trailing bits are **echoed rather than re-masked**, since the MUST
binds a sender and a peer that broke it sent something this library has
to be able to send back. `trailing_bits_set?` reports it.

### The OSPF Route Type names six values and no range

Section 5.2.3.1: "Intra-Area (0x1), Inter-Area (0x2), External 1
(0x3), External 2 (0x4), NSSA 1 (0x5), NSSA 2 (0x6)". So 0 and 7 to 255
are values it does not describe, and they build, parse and print as the
number. Route type 0 in particular is one a peer really sends: the
section says "the route type value 0" may be carried in the OSPFv2
Extended Prefix TLV and tells a producer to look at another LSA for it.

## 4. The code point registries

Read on 2026-10-31. **The registry is the index, not section 9**, which
is only "the global table of all TLVs/sub-TLVs defined in this
document": IANA maintains the live list and a summary in a 2023
document does not. Do not corroborate either from a third party mirror,
which is the codepoints.org lesson in Rules for agents.

| Registry | Defined | Private Use | Note |
|---|---|---|---|
| BGP-LS NLRI Types, Table 12 | 1 to 4 | 65000 to 65535 | 0 Reserved, 5 to 64999 unassigned, two octets wide |
| BGP-LS TLVs, Table 17 | see below | 65000 to 65535 | **0 to 255 is "Reserved (not to be allocated)"** |
| BGP-LS Protocol-IDs, Table 13 | 1 to 9 | 200 to 255 | 0 Reserved, 10 to 199 unassigned |

**The Protocol-ID row is the one place a table in this RFC is narrower
than its registry, and the lab found it the hard way.** Table 13 is RFC
9552's own request, 1 to 6; the registry, read on 2026-11-01, carries
three more: 7 BGP from RFC 9086, 8 RSVP-TE from
draft-ietf-idr-bgp-ls-te-path-01 and 9 Segment Routing from RFC 9857.
GoBGP originates with Protocol-ID 7, so bgp4r printed Unassigned for a
real router's traffic until `Headed::PROTOCOLS` was fixed in part 7.
Read the registry, not a table in the document that asked for it, which
is this file's own instruction one paragraph above.

**39 against 139.** RFC 9552's own Table 18 defines 39 TLV code points:
14 on the NLRI side (256 and 257 node descriptors, 258 to 263 link
descriptors, 264 and 265 prefix descriptors, 512 to 515 node descriptor
sub-TLVs) and 25 attribute TLVs (1024 to 1029 node, 1030 to 1031 and
1088 to 1098 link, 1152 to 1157 prefix; 263 is a node attribute too and
is counted on the NLRI side, and 1028 and 1029 are link attributes as
well as node attributes). **The ranges were written as "1024 to 1031
node" and that was wrong**: 1030 and 1031 are link only. The total was
right, and section 10 has the three tables row by row.
IANA's "BGP-LS NLRI and Attribute TLVs" registry
had **139** assigned, a minority of them this RFC's: the rest come from
RFC 9085, RFC 9086, RFC 9514, RFC 9294, RFC 8571, RFC 8814 and more.

**So the framing is a part and the code points are an open-ended
backlog.** Part 5 does RFC 9552's own attribute TLVs and no others, and
19 of its 25 are in; the rest come from RFC 9085, RFC 9086 and the
others above, and
the measure of the family deliberately does not require the other
hundred. The earlier plan's remark that "each of these is a class and a
registration" understated BGP-LS by about that much.

**513, BGP-LS Identifier, is marked deprecated in Table 18 itself**, so
it is a row to read and not one to implement for its meaning.

**A registry and not a `case`**, which departs from the four families
before this one. Flow spec, EVPN, RT-constrain and MCAST-VPN each added
one arm to each of two `case` statements, and phase 1 of the breadth
plan records why a lookup was not worth building for that. These
numbers are not those numbers, so `Link_state::Tlv.register` and
`Link_state.register` exist, which is `Attr.register`'s shape one and
two levels down. Both refuse a type or a hash key already taken, since
a second registration would shadow the first and nothing else would say
so.

## 5. Private use, section 5.4

Read first hand now, which discharges the plan's note that its
normative keywords had come through a PDF mirror:

"TLVs for Vendor Private Use are supported using the code point range
reserved as indicated in Section 7. For such TLV use in the NLRI or
BGP-LS Attribute, the format described in Section 5.1 is to be used and
a 4-octet field MUST be included as the first field in the value to
carry the Enterprise Code. For a private use NLRI type, a 4-octet field
MUST be included as the first field in the NLRI immediately following
the Total NLRI Length field of the Link-State NLRI format as described
in Section 5.2 to carry the Enterprise Code [ENTNUM]."

So two rules, and only one of them is unambiguous.

* **For a TLV it is settled**, so
  `Link_state::Tlv::Unknown#enterprise_code` reads it. A reader only:
  the octets are not reshaped and nothing is refused, so a private-use
  TLV too short to hold one still replays and the reader answers nil.
* **For an NLRI type it collides with the RD**, and nothing in the
  document settles which comes first. Figure 6 puts the Route
  Distinguisher "immediately following the Total NLRI Length" for SAFI
  72, and so does this sentence for a private-use type. So
  `Link_state::Unknown` has **no** such reader, deliberately, and the
  collision is recorded here for whoever implements a private-use NLRI
  type rather than guessed at.

"Multiple instances of private-use TLVs MAY appear in the BGP-LS
Attribute."

## 6. Two Unknowns, one per level

| Class | Keeps | Required by |
|---|---|---|
| `Link_state::Unknown` | an NLRI type, opaque octets | section 5.2, a MUST |
| `Link_state::Tlv::Unknown` | a TLV type, its value | section 5.1, a MUST |

That is the family of classes Conventions describes, one per level, and
this is the first family where **both** levels are required by the
document rather than decided by bgp4r.

Section 5.2 says so at length: "To allow the introduction of new
Link-State NLRI types seamlessly in the future without the need for
upgrading all BGP Speakers in the propagation path (e.g., a route
reflector), this document deviates from the default handling behavior
specified by Section 5.4 (paragraph 2) of [RFC7606] for Link-State
address family. An implementation MUST handle unknown Link-State NLRI
types as opaque objects and MUST preserve and propagate them."

**`Link_state::Unknown` keeps opaque octets and reads no TLVs out of
them**, which is the RFC's own word and not a shortcut. Nothing
establishes that an unknown type's body is a TLV list: the four types
section 5.2 does define start with a Protocol-ID octet and an 8-octet
Identifier before any TLV, so a reader that framed TLVs from the first
octet would invent structure and report fields that were never sent.

**This does not reverse the entry under phase 1 of the breadth plan**,
which says a *generic* `Nlri::Unknown` is unwritable because list
framing is per family. That stays true. This is family-local and
bounded by the Total NLRI Length, which is the same resolution
`Flow_spec::Component::Unknown` reached for the same reason.

**Mind the names.** A bare `Unknown` inside `Link_state` is the NLRI
one and inside `Link_state::Tlv` is the TLV one, so both are written in
full everywhere. That is the `const_defined?` lesson in Conventions
arriving from the lexical-scope side rather than the ancestor side.

## 7. What is in bgp4r today

Seven parts, and six are in: everything but validation. The plan is in
CLAUDE.md under "Breadth, the one SAFI lever".

| Part | What | Status |
|---|---|---|
| 1 | the TLV primitive and the NLRI framing, pure | **done** |
| 2 | the Node NLRI and the node descriptor sub-TLVs | **done** |
| 3 | the Link NLRI and the two Prefix NLRIs | **done** |
| 4 | wiring the NLRI to the dispatch sites | **done** |
| 5 | the BGP-LS Attribute, code 29, and RFC 9552's attribute TLVs | **done**, 5a, 5b and 5c |
| 6 | validation, from section 8.2.2 | to do |
| 7 | the lab, in both directions for SAFI 71 | **done** |

**Part 7 came before parts 5 and 6 on purpose**, because what a router
does decides which checks are worth writing, and it did: section 11 has
the finding that settled part 6's scope.

**Every NLRI type and every TLV RFC 9552 defines is in**: the whole of
sections 5.2.1, 5.2.2 and 5.2.3 for the descriptors, and the whole of
section 5.3 for the attribute, which is code 29 with all three of its
tables, 6, 8 and 10. Section 10 has them row by row. So what is left
unimplemented in this family is every attribute TLV the **other** RFCs
define, which the plan's measure deliberately excludes, and each of
those reads back as its level's `Unknown` and replays byte for byte: a
TLV type with no class as `Link_state::Tlv::Unknown` and an NLRI type
with no class as `Link_state::Unknown`. The lab meets one on real
traffic, TLV 1101 from RFC 9085; section 11 has it.

**The counts are discovered and not written here**, which is why the
two tables above carry the "In bgp4r" column rather than a sentence:
`ruby -I. -e 'require "bgp4r"; p BGP::Link_state::Tlv::REGISTRY.keys.sort'`
prints the TLV types and `BGP::Link_state::TYPES.keys.sort` the NLRI
types. A number in prose is a number that goes wrong.

**Part 1 chose test examples from the ranges parts 2 to 5 fill, and
part 2 paid for it.** Its TLV cases used types 256, 513 and 1024, which
are a node descriptor, a node descriptor sub-TLV and a node attribute,
so four of them broke the day the first descriptor landed and a fifth
would have broken in part 5; its NLRI cases used types 1, 2 and 5. Both
files now use a type that **cannot** acquire a class: Table 17 reserves
TLV code points 0 to 255 and says they are "not to be allocated", and
Table 12 reserves NLRI type 0. Each file names the choice in a constant
and asserts the range, so the examples cannot expire again. That is the
fifth expiring example in this plan after the four `docs/mcast-vpn.md`
records, and the lesson there was already written down.

**And a third shape of the load order trap, which cost the two guards
above their first firing.** `bgp_ls_doc_test.rb` discovers from
`Tlv::REGISTRY` and `Link_state::TYPES`, which are mutable and filled
by `register` calls spread across files. It required only part 1's two
files, so when part 2 landed its forward-looking guards **passed
standalone and failed in the suite**, where the registering file had
been loaded. The two traps Conventions records fail in opposite
directions and are about constants; this one is about global mutable
state, so the answer is not "run it both ways" but "require everything
that writes to what you read". The sibling doc tests do not have it,
because each discovers from a frozen hash literal in one file.

**All four dispatch sites are wired, so a BGP-LS UPDATE reads and
writes.** `MpReachCommon::ClassMethods#nlri_size` asks
`Link_state.nlri_size` for the framing, `Nlri.factory` and
`MpReachCommon#set` take one arm each, and `parse_next_hops` and
`nexthop_klass` read and write the section 5.5 next hop. That is the
EVPN and MCAST-VPN count, and the one site with a rule nothing in the
library had before is the next hop: section 9 below.

**The SAFI reaches the parse gate, which only flow spec also needs.**
Figures 5 and 6 differ by the 8-octet Route Distinguisher and by
nothing a reader can see, so the same capture is a valid NLRI read
either way and `Link_state.new_ntop(s, safi, path_id)` has to be told
which. EVPN, RT-constrain and MCAST-VPN each pass no parse-time input,
because each has one layout. `nlri_size` needs none of it: section 5.2
says the Total NLRI Length "also includes the length of the Route
Distinguisher", so one arithmetic frames both SAFIs.

**A hash says VPN by carrying an `:rd`, not by the attribute's SAFI**,
which is `Flow_spec`'s answer for SAFI 134 and is
`Link_state#from_hash`'s rule. So the two can disagree and both build,
because building never validates: `:safi => 71` with an `:rd` writes
the RD inside an attribute whose header says non-VPN, and the reverse
writes no RD. Both are negative tests a conformance script wants.

**Three tests moved off this family and cannot move again.**
`mp_reach_test.rb`'s
`test_an_unimplemented_safi_still_raises_so_the_octets_survive` and the
two behind `path_attribute_test.rb`'s `UNDECODABLE` each used BGP-LS as
their example of a family bgp4r cannot decode. They were EVPN until
#185 and BGP-LS until the wiring, and with the wiring there is **no
unimplemented family left to point at**. So the third choice is not a
family at all but a SAFI IANA has **Reserved**: the registry gives 255
as Reserved citing RFC 4760 and 241 to 254 as Reserved for Private Use
and "Not to be assigned", read on 2026-11-01. Nothing can be assigned
there, so bgp4r can never implement it and the example is permanent.
`UNDECODABLE_SAFI` names the choice and two tests assert the range,
which is what parts 1 to 3 paid four times to learn about examples that
expire. Every assertion in all three is unchanged across all three
moves.

* **One of them failed on the count rather than the family, and that is
  the sharper reading.** `test_an_attribute_that_is_both_undecodable_and_malformed`
  sends an MP_REACH whose next hop length overruns the attribute, so it
  is malformed and undecodable at once. Wired in, SAFI 71's next hop arm
  read the 4 octets that did arrive as an IPv4 address and raised
  nothing, so the `Attr::Gap` disappeared and only the `errors` entry
  was left. The test caught it as `1 expected but was 0`, which says the
  example had expired more precisely than a wrong family name would.

**One bug found and not fixed here**, because it is four other families
and its own topic: `Klass.new(an_extended_instance)` answers garbage
for `Evpn`, `Mcast_vpn`, `Flow_spec` and `Rt_constrain`. `encode`
writes the RFC 7911 section 3 Path Identifier in front of the NLRI and
`parse` does not expect one, so the copy constructor reads those four
octets as a type and a length. Measured on 2026-10-31; an unextended
instance copies correctly in all four. `Link_state` takes the
identifier off before the re-parse and has a test for it.

## 8. Error handling, section 8.2.2

**Not implemented.** Part 6, and the section is readable now, so it is
not gated on anything. What it says, so part 6 starts from the document
rather than from section 5.1 alone:

**Two MUST NOTs first.** Neither the Link-State NLRI nor the BGP-LS
Attribute "MUST NOT be considered malformed or invalid based on the
inclusion/exclusion of TLVs or contents of the TLV fields (i.e.,
semantic errors)". So every check here is **syntactic**, and a BGP-LS
check that reads a TLV's value for sense is outside what this section
allows.

**Seven syntactic NLRI checks**, which the section lists: that the sum
of all TLV lengths in the MP_REACH_NLRI "corresponds to the BGP
MP_REACH_NLRI length", the same for MP_UNREACH_NLRI, that the sum of
all TLV lengths in a Link-State NLRI "corresponds to the Total NLRI
Length field of all its descriptors", that "the length of the TLVs and,
when the TLV is recognized then, the length of its sub-TLVs in the NLRI
are valid", that "the syntactic correctness of the NLRI fields has been
verified as per [RFC7606]", that the section 5.1 ordering has been
followed, and that "For NLRIs carrying either a Local or Remote Node
Descriptor TLV, there is not more than one instance of a sub-TLV
present". Plus three attribute checks of the same shape.

**And a list of checks it says not to make**, which is the part that
narrows part 6 further than any other family's: "A BGP-LS Propagator,
even when it has a coexisting BGP-LS Consumer on the same node, should
not perform semantic validation", and the examples given are the
presence of a mandatory TLV, whether a fixed-length TLV's length is
correct or a variable-length one's is permissible, whether TLV field
values are permissible, and whether a TLV is valid with a particular
NLRI type. **bgp4r writes checks of all four shapes for EVPN and
MCAST-VPN**, so this is not a gap to fill here but an instruction not
to. What is permissible "can be used only by a BGP-LS Consumer for its
semantic validation", and bgp4r is not one.

**Four actions, chosen by what can be skipped**: `NLRI discard`, a MUST
for an NLRI that cannot be handled, with "processing similar to what is
described in Section 5.4 of [RFC7606]"; `AFI/SAFI disable`, a SHOULD
when another AFI/SAFI shares the session; `session reset`, a MUST on a
BGP-LS-only session; and `Attribute Discard`, a MUST for a skippable
attribute error, all or nothing by instruction.

Two of those are work bgp4r has not done before. **`NLRI discard` is an
action no part of the library implements**: `Attr::Finding` carries an
action and a subcode shaped around RFC 7606 section 3, and discarding
one NLRI out of a list is not among them. And **the choice between
`AFI/SAFI disable` and `session reset` depends on what else is up on
the session**, which `Attr::Check.attribute` cannot see, since it is
handed one attribute at a time. Both want a decision rather than a
patch, which is why part 6 is its own part and why taking part 7 first
may be the better order.

Two more things worth having before part 6 starts. An NLRI arriving
with no BGP-LS Attribute at all is explicitly **not** an error: it "is
most likely an indication that a BGP Speaker preceding it has performed
the 'Attribute Discard' fault handling", and an implementation "SHOULD
preserve and propagate the Link-State NLRIs". And "An implementation
SHOULD log a message for any errors found during syntax validation for
further analysis", which is the only place any of these RFCs asks for a
log line.

**Do not invent a subcode.** That is the trap flow spec part 4, EVPN
part 9 and MCAST-VPN part 6 each recorded, and this is the one family
whose own RFC names the actions outright, so there is less excuse here
than in any of them.

## 9. The next hop, section 5.5

Wired, and it is a **three-way** rule where EVPN's and
RT-constrain's are two-way: "The Length field of the next-hop address
will specify the next-hop address family. If the next-hop length is 4,
then the next hop is an IPv4 address; if the next-hop length is 16, then
it is a global IPv6 address; and if the next-hop length is 32, then
there is one global IPv6 address followed by an IPv6 link-local
address."

So 32 octets is RFC 2545's two-address form, read by `parse_next_hops`
turning its loop twice, which it already does for SAFI 1, 2 and 4 under
RFC 8950. **This is the first family to ask for it under an AFI other
than 1**, and `ipv6_nexthop_length?` could not have answered: it keys
on the SAFI, answers false for these two, and nothing claims RFC 8950
applies to BGP-LS.

**SAFI 72 prepends one Route Distinguisher to the whole next hop, not
one per address, and that differs from SAFI 128 and 129.** "For VPN
Subsequent Address Family Identifier (SAFI), as per custom, an 8-byte
Route Distinguisher set to all zero is prepended to the next hop."
Prepended to the next hop, singular. So the lengths are:

| SAFI 71 | SAFI 72 | What it is |
|---|---|---|
| 4 | 12 | IPv4 |
| 16 | 24 | global IPv6 |
| 32 | 40 | global IPv6 then link-local IPv6 |

Where RFC 8950 gives SAFI 128 and 129 lengths of 24 or 48, repeating
the RD per address, which is why `ipv6_nexthop_length?` lists 48 and
this family does not reuse it. **The 12, 24 and 40 column is this
reader's arithmetic from that one sentence and not a list section 5.5
gives**; the sentence itself is verbatim. RFC 7752 section 3.4, which
RFC 9552 obsoletes, carries the whole passage word for word, fetched on
2026-11-01, which is corroboration of the reading rather than a second
source for it. RFC 7752 adds one sentence RFC 9552 is not known here to
carry, so it is cited as RFC 7752's: "The link-local IPv6 address
should be used as described in [RFC2545]."

A `Vpn` writes its own zero RD in `encode_next_hop` and a `Prefix`
writes none, so one `Vpn` then one bare `Prefix` is what replays a
40-octet field byte for byte, and `nexthop_klass` makes the same split
on the build side. That is the one place in the library where a next
hop class depends on its **position**, so the index is passed down;
every other family ignores it. All six lengths were measured against
the table above, and each replays.

Two sabotages pin the VPN half and both fail **exactly the 40-octet
case**: repeating the RD per address on the build side, which is RFC
8950's rule, and reading one per address on the parse side. Nothing
else in `test/functional/link_state_test.rb` notices either, which is
what says that case is the only cover there is for the difference
between the two conventions.

Which family the session is does not decide it either: "BGP link-state
information for both IPv4 and IPv6 networks can be carried over either
an IPv4 BGP session or an IPv6 BGP session", and the next hop SHOULD
match the session rather than the networks it describes. So the length
is the only discriminator here as well, which is EVPN's and
RT-constrain's rule with one more case in it.

## 10. The attribute, section 5.3

Read first hand on 2026-11-01. "The BGP-LS Attribute (assigned value 29
by IANA) is an optional, non-transitive BGP Attribute that is used to
carry link, node, and prefix parameters and attributes. It is defined as
a set of Type/Length/Value (TLV) triplets, as described in the following
section."

So it is a path attribute and not an NLRI, and it reaches neither
dispatch gate: `BGP::Link_state_attribute` goes through `Attr.register`,
the registry Conventions calls the one that already works, and the TLVs
inside it are `Link_state::Tlv` unchanged.

**Optional non-transitive, which makes the ATTR_SET lab trick doubly
inapplicable**: such an attribute does not cross a router that does not
understand it, where RFC 6368's whole point was that an optional
transitive one does. Part 7 measures what GoBGP makes of what we send
and what we make of what it originates, not what survives transit.

**"This attribute SHOULD only be included with Link-State NLRIs. The
use of this attribute for other address families is outside the scope of
this document."** Outside the scope is not an error, which is the shape
RFC 7432 section 14 uses for an EVPN MAC length and RFC 6514 section 4.3
for a multicast source length. Nothing in bgp4r looks at the NLRIs
beside it, so the attribute can be sent next to an IPv4 unicast prefix.

**The ordering rule here is a SHOULD and a breach is explicitly not
malformed**, where the NLRI's is a MUST. Section 5.1 says both, two
sentences apart, which is why `Link_state::Tlv.ordered?` answers the
question and refuses nothing and why `Link_state_attribute#ordered?`
asks it rather than keeping a second comparison.

One sender-side rule in section 5.3 that is not a `validation.rb` rule
as it stands: a propagator whose UPDATE would exceed the maximum message
size because of another attribute "MUST consider the BGP-LS Attribute to
be malformed" and apply "Attribute Discard", and "MUST first discard the
BGP-LS Attribute to enable the detection and diagnosis of this error
condition". That is the only RFC 7606 action in the pre-8.2.2 text.

### The hash is a list, which is the one thing this attribute does differently

`{:link_state => [{...}, {...}]}`, in order, with a `{:tail => hex}`
entry when octets that could not frame a TLV were kept. A map keyed by
type would be wrong here and the RFC says why twice: section 5.3.1.2
makes the IS-IS Area Identifier repeat ("If multiple area addresses are
present, multiple TLVs are used to encode them") and section 5.3.1.4
makes each auxiliary Router-ID "a separate TLV". `Path_attribute` had to
bolt a `:duplicates` key onto a hash keyed by type for exactly this; a
list carries it for free.

### 10a. The node attribute TLVs, section 5.3.1

Table 6, with its own Length column. The "In bgp4r" column is
**discovered** from `Link_state::Tlv::REGISTRY`, so a row saying yes
with no class behind it and a class with a row saying no both fail the
suite.

| Code Point | Description | Length | Where the width is stated | In bgp4r |
|---|---|---|---|---|
| 263 | Multi-Topology Identifier | variable | section 5.2.2.1 | yes |
| 1024 | Node Flag Bits | 1 | section 5.3.1.1 | yes |
| 1025 | Opaque Node Attribute | variable | section 5.3.1.5 | yes |
| 1026 | Node Name | variable | section 5.3.1.3 | yes |
| 1027 | IS-IS Area Identifier | variable | section 5.3.1.2 | yes |
| 1028 | IPv4 Router-ID of Local Node | 4 | RFC 5305 section 4.3 | yes |
| 1029 | IPv6 Router-ID of Local Node | 16 | RFC 6119 section 4.1 | yes |

**Seven rows and six classes, because 263 is already in.** The
Multi-Topology Identifier is a link descriptor in Table 4 and a node
attribute here, one code point and one class, registered by part 3.
Section 5.3.1's row for it cites section 5.2.2.1, its own definition, so
the RFC says they are one TLV as plainly as IANA does. That is the flat
registry paying for itself rather than a shortcut.

**Erratum ID 7789 is in this section and the library follows the
erratum.** Figure 15 prints the Node Flag Bits as `|O|T|E|B|R|V|` where
Table 7 of the same section defines O Overload, **A Attached**, E
External, B ABR, R Router and V V6. The erratum, Technical and verified,
is that one letter: the figure's T should read A. Same shape as RFC
8956's wrong flow spec vector, and `docs/flow-spec.md` records what it
cost to explain such a thing some other way. The masks, high to low:

| Bit | Name | Mask | Reference |
|---|---|---|---|
| 0 | Overload | 0x80 | ISO 10589 |
| 1 | Attached | 0x40 | ISO 10589 |
| 2 | External | 0x20 | RFC 2328 |
| 3 | ABR | 0x10 | RFC 2328 |
| 4 | Router | 0x08 | RFC 5340 |
| 5 | V6 | 0x04 | RFC 5340 |

The low two bits are undefined, and the section asks for exactly the
keep-and-echo rule bgp4r already has: "The bits that are not defined
MUST be set to 0 by the originator and MUST be ignored by the receiver."
So `DEFINED_BITS` is 0xfc, a build from names writes those two as 0, and
the hash gains a `{:bits => n}` entry only when one arrived set.

**1026 is the one of the three variable rows whose value is text**, so
its field form and its hash form are the same String where 1025's and
1027's take raw octets and hash as hex. Two of its rules are deviated
from on purpose, per Conventions: "The Value field is encoded in 7-bit
ASCII", so `ascii?` reports a name that is not and nothing refuses it;
and "The maximum length of the Node Name TLV is 255 octets", which
**does not say whether the four framing octets are in that count**, so
255 of value and 251 of value are both readings of that sentence and
nothing enforces either.

**1027's dotted form is not parsed**, by decision. Section 5.3.1.2 gives
the value as "IS-IS Area Identifier (variable)" and nothing more, so a
presentation form for it would be bgp4r's invention and nothing could
check it. `['490001'].pack('H*')` is how an area address from a router
dump gets in.

### 10b. The link attribute TLVs, section 5.3.2

**Table 8 has no Length column**, which is Table 4's situation exactly:
where Table 6 and Table 10 each give a Length, Table 8 gives an "IS-IS
TLV/Sub-TLV" column instead, so not one of its fifteen rows carries a
width. Five of them have no width anywhere in RFC 9552, so each is a
citation to the document that gives it and that citation is the only
place it lives. Part 5b.

| Code Point | Description | Where the width is stated | In bgp4r |
|---|---|---|---|
| 1028 | IPv4 Router-ID of Local Node | RFC 5305 section 4.3 | yes |
| 1029 | IPv6 Router-ID of Local Node | RFC 6119 section 4.1 | yes |
| 1030 | IPv4 Router-ID of Remote Node | 4, RFC 5305 section 4.3 | yes |
| 1031 | IPv6 Router-ID of Remote Node | 16, RFC 6119 section 4.1 | yes |
| 1088 | Administrative group (color) | 4, RFC 5305 section 3.1 | yes |
| 1089 | Maximum link bandwidth | 4, RFC 5305 section 3.4 | yes |
| 1090 | Max. reservable link bandwidth | 4, RFC 5305 section 3.5 | yes |
| 1091 | Unreserved bandwidth | 32, RFC 5305 section 3.6 | yes |
| 1092 | TE Default Metric | 4, section 5.3.2.3 | yes |
| 1093 | Link Protection Type | 2, RFC 5307 section 1.2 | yes |
| 1094 | MPLS Protocol Mask | 1, section 5.3.2.2 | yes |
| 1095 | IGP Metric | 1, 2 or 3, section 5.3.2.4 | yes |
| 1096 | Shared Risk Link Group | 4*n, section 5.3.2.5 | yes |
| 1097 | Opaque Link Attribute | variable, section 5.3.2.6 | yes |
| 1098 | Link Name | variable, section 5.3.2.7 | yes |

The Width column here is this guide's and not the RFC's, since Table 8
has none, so each entry names the document the width was read in.
**1028 and 1029 are Table 6's rows again** and are in from part 5a,
since a local Router-ID is a node attribute and a link attribute both.
Table 8's own pair is 1030 and 1031, the **remote** ones, and section
5.3.2.1 describes all four in one paragraph.

**Two of the five external widths are not what memory gives**, which is
why they were fetched rather than recalled:

* **1091 is 32 octets, not 4.** RFC 5305 section 3.6: "this sub-TLV
  contains eight 32-bit IEEE floating point numbers", one per setup
  priority, "arranged in increasing order with priority 0 occurring at
  the start of the sub-TLV, and priority 7 at the end of the sub-TLV".
  Its three neighbours 1089, 1090 and 1092 are 4 each, so it is the odd
  one in a run of similar rows, which is how it gets written as 4.
* **1093 is 2 octets.** RFC 5307 section 1.2 is a protection capability
  bit vector then one octet it disposes of in a sentence: "The second
  octet SHOULD be set to zero by the sender, and SHOULD be ignored by
  the receiver."

**The units of 1089, 1090 and 1091 are bytes per second and not bits**,
which RFC 5305 puts as "The units are bytes (not bits!) per second" in
each of sections 3.4, 3.5 and 3.6. The same trap and the same
exclamation mark as RFC 10005 section 2 for the Link Bandwidth extended
community.

### The bitfields of Table 8, and one is numbered the other way up

| TLV | Field | Defined bits | Reserved |
|---|---|---|---|
| 1088 | Administrative group | all 32, **numbered from the bottom** | none |
| 1093 | Link Protection Type | 0x3f of octet 1 | 0xc0 of octet 1, all of octet 2 |
| 1094 | MPLS Protocol Mask | 0xc0 | 0x3f |
| 1095 | IGP Metric, 1-octet form | 0x3f | 0xc0 |

**TLV 1088 numbers its bits from the least significant and every other
bitfield in this family numbers from the most**, which RFC 5305 section
3.1 says outright: "By convention, the least significant bit is referred
to as 'group 0', and the most significant bit is referred to as 'group
31'." So the mask for group 0 is 0x00000001. Read the sentence rather
than carrying the family's convention across.

It is also the only one of the four with nothing reserved: all 32 bits
are administrative groups, so `Administrative_group` has no
`DEFINED_BITS` and its hash never gains a `:bits` entry. The other
three keep and echo what they do not define, which each section asks
for in so many words.

**1095's reserved bits belong to one of its three widths.** "IS-IS small
metrics are 6 bits in size but are encoded in a 1-octet field;
therefore, the two most significant bits of the field MUST be set to 0
by the originator and MUST be ignored by the receiver." The 2-octet and
3-octet forms reserve nothing, so `undefined_bits` answers 0 there
however the value's own high bits read.

**And the width of 1095 is a fact about the source IGP rather than about
the value**, so bgp4r carries it: a metric of 10 is legal at all three
widths and nothing in the section picks one. `Igp_metric.new(10)`
defaults to 3, the only width that holds any 24-bit metric, and the hash
carries `:width` beside `:metric`. Inferring the width from the
magnitude would be a rule the section does not have.

**TLV 1096 carries both address families in one TLV**, which section
5.3.2.5 says and IS-IS does not do: "In IS-IS, the SRLG information is
carried in two different TLVs: the GMPLS-SRLG TLV (for IPv4) (Type 138)
... and the IPv6 SRLG TLV (Type 139) ... Both IPv4 and IPv6 SRLG
information is carried in a single TLV." So there is one class and
nothing in it is per family.

**A NaN with a payload is the one value in this table that does not
replay as its own class.** `unpack1('g')` on `7fc00001` gives NaN and
packing that back gives `7fc00000`, so the value fails the
encode-matches rule and `Tlv::Unknown` keeps it whole instead. Measured
on 2026-11-01, where 0, -0, both infinities and the canonical NaN are
all exact. The octets come back either way; only the class differs.

### 10c. The prefix attribute TLVs, section 5.3.3

Table 10, which has a Length column, unlike Table 4 and Table 8. These
go in the attribute beside a Prefix NLRI of type 3 or 4: section 5.3.3
says prefixes are "learned from the IGP topology (IS-IS or OSPF) with a
set of IGP attributes (such as metric, route tags, etc.)". Part 5c.

| Code Point | Description | Length | Where the width is stated | In bgp4r |
|---|---|---|---|---|
| 1152 | IGP Flags | 1 | section 5.3.3.1 | yes |
| 1153 | IGP Route Tag | 4*n | section 5.3.3.2, RFC 5130 | yes |
| 1154 | IGP Extended Route Tag | 8*n | section 5.3.3.3, RFC 5130 | yes |
| 1155 | Prefix Metric | 4 | section 5.3.3.4, RFC 5305 | yes |
| 1156 | OSPF Forwarding Address | 4 or 16, see below | section 5.3.3.5 | yes |
| 1157 | Opaque Prefix Attribute | variable | section 5.3.3.6 | yes |

**Five of the six widths are stated twice**, by Table 10 and by the
section, and they agree. That is the opposite of Table 8, where not one
of fifteen rows carries a width at all, and it is why 5c needed no
outside document for a width: RFC 5130 and RFC 5305 are cited as the
origin of the fields rather than as the only statement of their size.

**The sixth is where the table and the section disagree, and no erratum
covers it.** Table 10 says 1156 is 4; section 5.3.3.5 says "The length
is 4 for an IPv4 forwarding address and 16 for an IPv6 forwarding
address" and its Figure 29 says "Forwarding Address (variable)". So the
prose and the figure agree with each other against the table, which is
the reading bgp4r follows. Checked against the errata on 2026-11-01: the
two verified ones are 7789 and 8766 and neither is this. **Third self
contradiction in this document**, after the Node Flag Bits figure and
Table 8's missing widths, which is worth knowing before trusting any
single table of it.

#### The bits of Table 11

| Bit | Name | Mask | Reference |
|---|---|---|---|
| 0 | IS-IS Up/Down | 0x80 | RFC 5305 |
| 1 | OSPF "no unicast" | 0x40 | RFC 5340 |
| 2 | OSPF "local address" | 0x20 | RFC 5340 |
| 3 | OSPF "propagate NSSA" | 0x10 | RFC 5340 |

**Table 11 names the four and gives no bit numbers**, where Table 7 does
for the node flags, so Figure 25's `|D|N|L|P|       |` is the only
statement of the placement there is. The masks above are this guide's
arithmetic from that figure, which is worth saying because the node
flags needed erratum 7789 to settle a figure against a table: here
nothing cross-checks, and the figure and the table list the four in the
same order. D is the most significant bit, so this numbers from the top
as every bitfield in the family but 1088 does.

`DEFINED_BITS` is 0xf0 and the low nibble is kept and echoed, which
section 5.3.3.1 asks for in the words 1024 and 1094 use: "The bits that
are not defined MUST be set to 0 by the originator and MUST be ignored
by the receiver."

#### Three things in this table that no other TLV in the family does

**An absent 1155 means something.** Section 5.3.3.4: "If not present, it
means that the prefix is advertised without any reachability." Every
other TLV in section 5.3 is absent or present and nothing more. Nothing
in bgp4r acts on it, since it never computes reachability, and section
8.2.2 forbids reporting a mandatory TLV absent in any case; it is
recorded because a reader of a prefix attribute set will want it. Its
"may only appear once" in the same sentence is a sender's rule that
bgp4r does not enforce, per Conventions, and the attribute's hash is a
list so there is somewhere to put the second.

**1154 is the only 64-bit field in the family**, so it is the one place
`'Q>*'` appears and the whole reason `Int_list_tlv` takes its pack code
from its subclass rather than fixing one. A reader carrying 1153's shape
across gets every element half the width it should be, and a tag below
2^32 encodes either way, so the test uses one above it.

**1156 is the fourth place in the library where a width alone says which
family a field is**, after EVPN's IP Prefix route, EVPN route type 2's
optional Label2 and MCAST-VPN's Originating Router. It is `Addr_tlv`'s
shape with a set of widths rather than one number, and not a subclass of
it: generalising `WIDTH` to a set for one caller is the anticipation
phase 1 of the breadth plan warns against, and the two differ in the
empty form as well, since with two widths allowed there is no all zeroes
address to default to that would not be inventing a family.

**A width that is neither 4 nor 16 is not one of these**, which is
`Addr_tlv`'s rule and right here for the reason part 3 recorded there:
the class is a claim about meaning. An `Ospf_forwarding_address` holding
eight octets and no readable address would claim bgp4r read a forwarding
address and found none in it, where `Tlv::Unknown.new(1156, octets)`
claims only that these are the octets of TLV 1156. So `parse` refuses it
and the octets are kept whole. **That is not the length check section
8.2.2 forbids**: nothing is reported either way and no finding exists,
so only the class differs, which is part 1's rule rather than a verdict
about the sender.

## 11. Interoperability

Measured on 2026-11-01 against GoBGP 3.23.0 and FRR 8.4.4, and
asserted by `test/functional/lab/link_state_gobgp_test.rb` and
`link_state_frr_test.rb` rather than written down here. Both omit
themselves on an unmeasured version, so `bgp_ls_doc_test.rb` holds the
two versions against the tests' own constants: a pin moved in one place
and not the other is how this table would go quietly wrong.

| | GoBGP 3.23.0 | FRR 8.4.4 |
|---|---|---|
| SAFI 71 | config name `ls`, negotiated | no grammar at all |
| SAFI 72 | no config name, `UnknownFamily(1074004040)` | no grammar at all |
| Can originate one | yes, NLRI type 2 only | no |
| A SAFI 71 UPDATE | parsed, installed, read back | fails the UPDATE, resets with no NOTIFICATION |
| A SAFI 72 UPDATE | discarded, session kept | the same reset |

**This is the first family here where the router encodes the family
under test, so its own octets feed bgp4r's decoder.** Every lab test
since flow spec sends only: it asserts a router's reading of what bgp4r
put on the wire and records in its own comments that the parse direction
is covered by the loopback functional test alone.

Be exact about the first, because `attr_set_gobgp_test.rb` is the
nearest precedent and is not this. There a gobgpd sits between two bgp4r
speakers and the far one parses an UPDATE GoBGP built, so its ORIGIN,
AS_PATH, next hop and NLRI are GoBGP's; but attribute 128, the thing
under test, is **copied verbatim** and never parsed by the router, so
those octets are still ours. Here GoBGP builds the NLRI itself.

**The client's grammar for it, since nothing documents it.** `gobgp
global rib add -a ls link` wants sixteen keyword and value pairs, and
`node` and `prefix` are refused outright with "invalid nlriType. expect
[link]", so NLRI type 2 is the only one GoBGP can be made to originate.
Every pair is read without a presence check, so leaving one out is an
error rather than a default. `LINK_ARGS` in the GoBGP test has the list.

**What the receive direction vouches for**, which nothing in
`test/unit/nlris/` can: the head of figure 8 with its Protocol-ID and
Identifier, both node descriptors of section 5.2.1, five of the six
link descriptors of section 5.2.2, and the 4-octet next hop of section
5.5, all read from octets this reader did not write. **Not the framing
arithmetic**, which it looks like it should and does not; the last part
of this section says why. It is also
where the keep-and-echo MUST of section 5.1 meets real traffic: GoBGP
sends sub-TLV **516**, the BGP Router Identifier of RFC 9086, which
part 2 left out because Table 3 is RFC 9552's, and the NLRI still
replays byte for byte with no protocol error and no coverage gap. The
BGP-LS Attribute arrives too, and part 5a gave it a class: it parses
into a `Link_state_attribute` carrying one TLV of type **1101**, the
Adjacency SID of RFC 9085, which is in no table of RFC 9552 and so
stays a `Tlv::Unknown` through parts 5b and 5c as well. Still neither
an error nor a gap, which is the claim part 6 has to keep.

**And the send direction**: GoBGP names our Autonomous System, BGP-LS
Identifier, IGP Router-ID, Protocol-ID, the two IPv4 link addresses,
the OSPF route type and the prefix back, each from its own field. The
IGP Router-ID is the one worth having, because part 4 found
`Igp_router_id#from_hash` packing the dotted form with `pack('H*')`,
which maps a separator by its low nibble: GoBGP printing
`1921.6800.1001` back is the only check on those six octets that is not
bgp4r's own arithmetic.

### What the measurement changed in bgp4r

**Protocol-ID 7 read as Unassigned.** GoBGP originates with Protocol-ID
7, which is RFC 9086's and not in Table 2 of section 5.2, and
`Headed::PROTOCOLS` carried Table 2 rather than the registry. Section 4
has the correction and the other two values it brought with it. Nothing
in the library turns on a Protocol-ID, so this was a wrong answer about
a correct router and nothing worse, which is still the thing this
repository most wants not to give.

### Two faults in GoBGP, recorded and not filed

Per the standing decision that the job here is bgp4r catching up. Both
are deterministic and both are asserted, because a lab test that
quietly sends only the shape that works is the unchecked claim this
repository keeps getting burned by.

* **It requires a sub-TLV RFC 9552 does not, and refusing it costs the
  whole family.** Every node descriptor must carry either an IGP
  Router-ID or both a BGP Router-ID and an Autonomous System, whatever
  the Protocol-ID; a descriptor holding only an Autonomous System is
  answered with "Required TLV missing" and `Capability was disabled`.
  Section 5.2.1.4 makes the IGP Router-ID "a mandatory TLV when
  originating information from IS-IS, OSPF, 'Direct', or 'Static
  configuration'", which binds an **originator** and names no receiver
  action, and makes the Autonomous System "an optional TLV". **Section
  8.2.2 names "presence of a mandatory TLV" among the semantic
  validations a BGP-LS Propagator should not perform.** So this is one
  implementation doing what this family's own RFC says not to.
* **Its client panics rendering an IP Reachability TLV whose prefix is
  more than one octet.** `index out of range [1] with length 1`, in
  `ToIPNet`. The daemon accepts and stores the route either way and a
  /8 renders, so it is the renderer and not the parser; /16, /24 and /32
  all panic. That is why the prefix in the send-direction case is a /8.

### What it means for part 6, which is the reason this part came first

**GoBGP's own node descriptors are not in ascending sub-TLV order**:
512, then 516, then 513, where section 5.2.1.4 says "The sub-TLVs within
a Node Descriptor MUST be arranged in ascending order by sub-TLV type".
bgp4r reports the order through `Node_descriptors#ordered?` and refuses
nothing, so the route parses and replays.

So the only router available here breaks a rule bgp4r could check, on
traffic it originates itself, and makes a check section 8.2.2 tells a
Propagator not to make. Both point the same way: **part 6 follows the
RFC and not the router**. One router agreeing is not a quorum, and
here it disagrees with the document in both directions at once.

### What is still not checked

SAFI 72 by anyone, so figure 6 and the 8-octet Route Distinguisher of
section 5.2 are bgp4r's own reading, as is the VPN next hop of section
5.5 with its one prepended zero Route Distinguisher. NLRI types 1, 3
and 4 in the receive direction, since GoBGP will not originate them.
**Every attribute TLV, in both directions, and that claim was written
wrong once.** Part 5a's version of this paragraph said GoBGP sends
Table 8's TLVs, so part 5b would give the measurement more to say. It
does not: measured again at part 5b-ii, the one TLV GoBGP puts in the
attribute is **1101**, the Adjacency SID of RFC 9085, which is in no
table of RFC 9552 and which no part of this plan implements. So
Table 8's thirteen classes landed and this measurement says exactly
what it said before. A claim about what a router sends is a measurement
like any other, and that one was an inference from the attribute being
present. And nothing in either test says anything about the TLVs bgp4r
does not implement beyond that they survive.

**And the framing, in the receive direction only, which sabotage
measured rather than argued.** GoBGP originates one NLRI per UPDATE,
and the only NLRI in an attribute has nothing behind it to over-read
into, so `Link_state.nlri_size` wrong by a constant leaves every
receive case passing. That is RT-constrain's lesson arriving from the
other side, and it is why the multi-NLRI cases in
`test/functional/link_state_test.rb` must not be thinned out: they are
the only cover the parse-side framing has. The send direction does
catch it, because GoBGP reads the length and a wrong one sends the
UPDATE to RFC 7606 rather than to its RIB.
