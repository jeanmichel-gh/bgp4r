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
  to disbelieve**, at `https://www.rfc-editor.org/errata/rfc9552`. This
  one is part 5's to apply.
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
| BGP-LS Protocol-IDs, Table 13 | 1 to 6 | 200 to 255 | 0 Reserved |

**39 against 139.** RFC 9552's own Table 18 defines 39 TLV code points:
14 on the NLRI side (256 and 257 node descriptors, 258 to 263 link
descriptors, 264 and 265 prefix descriptors, 512 to 515 node descriptor
sub-TLVs) and 25 attribute TLVs (1024 to 1031 node, 1088 to 1098 link,
1152 to 1157 prefix). IANA's "BGP-LS NLRI and Attribute TLVs" registry
had **139** assigned, a minority of them this RFC's: the rest come from
RFC 9085, RFC 9086, RFC 9514, RFC 9294, RFC 8571, RFC 8814 and more.

**So the framing is a part and the code points are an open-ended
backlog.** Part 5 does RFC 9552's own attribute TLVs and no others, and
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

Seven parts, and parts 1, 2 and 3 are in. The plan is in CLAUDE.md
under "Breadth, the one SAFI lever".

| Part | What | Status |
|---|---|---|
| 1 | the TLV primitive and the NLRI framing, pure | **done** |
| 2 | the Node NLRI and the node descriptor sub-TLVs | **done** |
| 3 | the Link NLRI and the two Prefix NLRIs | **done** |
| 4 | wiring the NLRI to the dispatch sites | to do |
| 5 | the BGP-LS Attribute, code 29, and RFC 9552's attribute TLVs | to do |
| 6 | validation, from section 8.2.2 | to do |
| 7 | the lab, in both directions for SAFI 71 | to do |

**Every NLRI type and every descriptor TLV RFC 9552 defines is in**,
which is the whole of sections 5.2.1, 5.2.2 and 5.2.3. What is left is
the attribute, part 5.
Everything unimplemented reads back as its level's `Unknown` and
replays byte for byte: a TLV type with no class as
`Link_state::Tlv::Unknown` and an NLRI type with no class as
`Link_state::Unknown`.

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

**Nothing dispatches to either file.** `Nlri.factory` and
`MpReachCommon#set` know nothing of SAFI 71 or 72, so a BGP-LS UPDATE
still comes back as an `Attr::Raw` with an `Attr::Gap`, which is #116
working as designed one level up. Part 4 is where that changes, and
**part 4 is also where three tests have to move**:
`mp_reach_test.rb`'s `test_an_unimplemented_safi_still_raises_so_the_octets_survive`
and the two behind `path_attribute_test.rb`'s `UNDECODABLE` all use
BGP-LS as their example of a family bgp4r cannot decode. They were
re-pointed once already, from EVPN in #185, and BGP-LS is the last
unimplemented family, so there is nowhere left to point them: they will
need a SAFI IANA has not assigned. Re-point them as #185 and #191 did;
the assertions are about #116 and are right.

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

Part 4's, and it is a **three-way** rule where EVPN's and
RT-constrain's are two-way: "The Length field of the next-hop address
will specify the next-hop address family. If the next-hop length is 4,
then the next hop is an IPv4 address; if the next-hop length is 16, then
it is a global IPv6 address; and if the next-hop length is 32, then
there is one global IPv6 address followed by an IPv6 link-local
address."

So 32 octets is RFC 2545's two-address form, which bgp4r already reads
for AFI 2, and this is the first family to ask for it under another AFI.
"For VPN Subsequent Address Family Identifier (SAFI), as per custom, an
8-byte Route Distinguisher set to all zero is prepended to the next
hop", so SAFI 72's next hop is 12, 24 or 40 octets. None of that is
written yet; it is recorded here so part 4 starts from the section.

Which family the session is does not decide it either: "BGP link-state
information for both IPv4 and IPv6 networks can be carried over either
an IPv4 BGP session or an IPv6 BGP session", and the next hop SHOULD
match the session rather than the networks it describes. So the length
is the only discriminator here as well, which is EVPN's and
RT-constrain's rule with one more case in it.

## 10. The attribute is optional non-transitive

Section 5.3, code 29. **So the ATTR_SET lab trick is doubly
inapplicable**: a non-transitive attribute does not cross a router that
does not understand it, where RFC 6368's whole point was that an
optional transitive one does. Part 7 measures what GoBGP makes of what
we send and what we make of what it originates, not what survives
transit.

One sender-side rule in section 5.3 that is not a `validation.rb` rule
as it stands: a propagator whose UPDATE would exceed the maximum message
size because of another attribute "MUST consider the BGP-LS Attribute to
be malformed" and apply "Attribute Discard", and "MUST first discard the
BGP-LS Attribute to enable the detection and diagnosis of this error
condition". That is the only RFC 7606 action in the pre-8.2.2 text.

## 11. Interoperability

**Not measured yet.** Part 7. What the probe on 2026-10-31 found,
before planning rather than after, which is the
probe-before-recording-a-block lesson that has now paid five times in
this file's neighbourhood:

* **GoBGP 3.23.0 has BGP-LS and FRR 8.4.4 does not.** GoBGP's config
  name is `ls` and a live session negotiates AFI 16388 SAFI 71. FRR's
  `bgp_nlri_parse_` functions are evpn, flowspec, ip, label and vpn,
  with none for this. So this family gets **one** outside reference,
  like RT-constrain and VPN flow spec, and is not the MCAST-VPN case of
  none.
* **SAFI 72 has no reference, inside a family whose SAFI 71 does.**
  GoBGP has no `ls-vpn`: the config refuses that name and a live session
  reads SAFI 72 back as `UnknownFamily(1074004040)`, which is its
  `afi << 16 | safi` packing for 16388 and 72. That is the VPN flow spec
  shape again, one SAFI of a pair checkable and the other not.
* **The third config-and-client naming divergence, and the first of its
  shape.** The config accepts only `ls`; the **client** accepts `ls` and
  `linkstate`. So `CLIENT_FAMILY` in `lab_helper.rb` needs no entry,
  where VPN flow spec and EVPN each cost a mapping. Recorded all the
  same, so a reader meeting `linkstate` in client output does not take
  it for a second family.
* **GoBGP can originate a BGP-LS route**, so the parse direction is
  checkable against a router for the first time since flow spec.
  `gobgp global rib add -a ls link ...` builds a Link NLRI and wants at
  least 26 tokens after `link`, while `node` and `prefix` are refused
  outright with "invalid nlriType. expect [link]". Every lab test since
  flow spec sends only and records that caveat; here GoBGP's encoder can
  feed our decoder for NLRI type 2. Finding the exact invocation is part
  7's first step.

Until part 7 lands, this family's wire format is bgp4r's own opinion
against the field widths RFC 9552 states, and nothing in
`test/unit/nlris/` says otherwise.
