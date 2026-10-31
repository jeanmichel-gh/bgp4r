# MCAST-VPN on the wire

RFC 6514, "BGP Encodings and Procedures for Multicast in MPLS/BGP IP
VPNs", and RFC 7441, which updates it. This is as much of both as is
needed to write the encoding and decoding, and nothing about the
procedures.

Read this before touching `bgp/nlris/mcast_vpn_route.rb` or
`bgp/nlris/mcast_vpn.rb`, before adding a route type, before changing
how `mp_reach.rb` and `mp_unreach.rb` frame an NLRI, and before putting
an MCAST-VPN check in `validation.rb`.

`test/unit/mcast_vpn_doc_test.rb` asserts the load bearing claims here
against the library, because a claim nothing checks reads as verified.
The route type table in section 3 is **discovered** rather than listed:
the test enumerates the `Route` subclasses the library defines and
cross-checks them against the table in both directions, so a route type
class cannot join the library without this document being told.

## 1. Where it sits, and what it is not

MCAST-VPN is SAFI 5. RFC 6514 section 4 never gives the number: it says
only "with an Address Family Identifier (AFI) of 1 or 2 and a Subsequent
AFI (SAFI) of MCAST-VPN", and so does
draft-ietf-bess-rfc6514bis-00, which obsoletes it. IANA's SAFI registry
is what assigns 5, referencing RFC 6514.

Two neighbours are easy to confuse with it and are not it.

SAFI 2 is ordinary multicast forwarding NLRI, RFC 4760, and bgp4r has
had it for years. SAFI 129 is "Multicast for BGP/MPLS IP VPNs",
referencing RFC 6513 and RFC 6514, and bgp4r reads it as a labelled VPN
family through `Labeled`. Neither carries the NLRI this document
describes.

**The AFI is 1 or 2, so this family has two where EVPN has one.** It
buys the NLRI parse nothing, for the reason section 4 below gives, and
the place it is expected to matter is the next hop.

## 2. The NLRI framing

Section 4, "MCAST-VPN NLRI":

```
                +-----------------------------------+
                |      Route Type (1 octet)         |
                +-----------------------------------+
                |     Length (1 octet)              |
                +-----------------------------------+
                | Route Type specific (variable)    |
                +-----------------------------------+
```

"The Length field indicates the length in octets of the Route Type
specific field of the MCAST-VPN NLRI."

So the Length counts the body alone, in octets, and sits behind a Route
Type octet. An NLRI occupies `2 + Length` octets. Both framing fields
are one octet, so a body is at most 255 octets.

This is the EVPN shape exactly, which is why that experience transfers
whole. `Mcast_vpn.nlri_size` answers how long the next NLRI is, so the
two parse loops in `mp_reach.rb` and `mp_unreach.rb` can ask rather than
calculate, as they already ask `Flow_spec.nlri_size` and
`Evpn.nlri_size`. It answers nil for octets too short to frame, so a
caller stops rather than loops.

A prefix family's length is in bits and those loops have always worked
out how many octets to slice with `(blen+7)/8+1`. That arithmetic is
wrong here three times over: the unit, the field it counts, and the
octet in front of it.

**Nothing validates.** Any route type, any length, any body, including a
Length that disagrees with the octets that came with it. A Length that
lied is kept in `declared_len` and written back, so a capture replays.

## 3. The route types

IANA's registry is named "BGP MCAST-VPN Route Types". Read on
2026-10-31, it has **ten** assigned values where RFC 6514 defines seven.
0x00 and 0x80 to 0xff are Reserved.

The three mLDP values are 0x43, 0x44 and 0x47, which are 67, 68 and 71
in decimal. The relationship to the base types is stated rather than
arithmetic. RFC 7441: the new types' "high-order two bits have the value
0x01, and (b) the low-order six bits have the same value as the
codepoints for the corresponding route types". So 0x40 to 0x7f is the
mLDP range, and `base + 0x40` is the result of that rule, not the rule.

| Type | Route type | Defined in | In bgp4r |
| --- | --- | --- | --- |
| 1 | Intra-AS I-PMSI A-D route | RFC 6514 section 4.1 | no |
| 2 | Inter-AS I-PMSI A-D route | RFC 6514 section 4.2 | no |
| 3 | S-PMSI A-D route | RFC 6514 section 4.3 | no |
| 4 | Leaf A-D route | RFC 6514 section 4.4 | no |
| 5 | Source Active A-D route | RFC 6514 section 4.5 | no |
| 6 | Shared Tree Join route | RFC 6514 section 4.6 | no |
| 7 | Source Tree Join route | RFC 6514 section 4.6 | no |
| 67 | S-PMSI A-D route for C-multicast mLDP | RFC 7441 | no |
| 68 | Leaf A-D route for C-multicast mLDP | RFC 7441 | no |
| 71 | Source Tree Join route for C-multicast mLDP | RFC 7441 | no |

Every row says no today, because this part lands the framing and the
primitives with nothing dispatching to them. A type with no class reads
back as an `Mcast_vpn::Unknown` that replays byte for byte.

Two notes on the table.

Types 6 and 7 share one layout. Section 4.6 is titled "C-Multicast
Route" and covers both in one subsection: "A Shared Tree Join route and
a Source Tree Join Route Type specific MCAST-VPN NLRI consists of the
following". So they are one class apart from the type number.

**The three mLDP rows are deliberately out of scope and will stay no.**
The reason is that they are not BGP. Each carries an mLDP FEC Element,
which RFC 7441 does not lay out at all: it points at the FEC Element
diagram in section 2.2 of RFC 6388, so the extent of that field belongs
to LDP and bgp4r has nothing of LDP. They replay from `Unknown`, which
is what #116 already gives one level up. Revisit only if someone wants
mLDP, and then it is an RFC 6388 reader first and three route types
second.

## 4. The primitives

Reading all seven layouts of section 4 together rather than one
subsection at a time, three field shapes carry everything beyond the
Route Distinguisher that `BGP::Rd` already gives.

| Field | Width | In route types |
| --- | --- | --- |
| RD | 8 octets | 1, 2, 3, 5, 6, 7 |
| Multicast Source, Multicast Group | 1 octet of length, then the value | 3, 5, 6, 7 |
| Source AS | 4 octets | 2, 6, 7 |
| Originating Router's IP Address | no length field | 1, 3, 4 |

That is three classes, `Addr`, `Source_as` and `Originating_router`, and
`Rd` which the library already has. Route type 4 carries neither an RD
nor any of the three except the trailing address, which section 7 below
is about.

**The lengths are in bits.** Section 4.3 says it by value rather than by
the word, four times over: "If the Multicast Source field contains an
IPv4 address, then the value of the Multicast Source Length field is
32", 128 for IPv6, and the same pair of sentences for the Multicast
Group. 32 for four octets is a bit count. This is the detail memory
reverses, so it is quoted here rather than recalled.

**Any other length is echoed rather than refused, and the RFC asks for
that.** Section 4.3: "Usage of other values of the Multicast Source
Length and Multicast Group Length fields is outside the scope of this
document". Outside the scope is not malformed, which is the same shape
RFC 7432 section 14 uses for the EVPN MAC length, so the octets are kept
and written back and the family comes from the field's own width rather
than from the length that claimed it.

A length of 0 with no octets is the absent field, which is a wildcard
source or group. Section 4.3 has no sentence of its own for it, where
RFC 9251 section 9.1.1 does for EVPN, so `to_s` prints `*` on the
strength of the prose rather than a quote.

## 5. The primitives are this family's own and not EVPN's

`Mcast_vpn::Addr` and `Evpn::Addr` have the same shape, and the sharing
would be by citation rather than coincidence: EVPN route type 10 is
"identical to the S-PMSI A-D route as defined in [RFC7117]", which
carries this encoding. So this is a decision and not an accident, and
the mechanism is recorded rather than the verdict.

What is on the other side is #173's argument. Sharing removes no code
today and bets on a third family arriving. The duplication is three
small classes and four private helpers on the `Route` base.

**One correction to the plan entry that recorded this.** It said sharing
means lifting `Sized`, `Addr`, `Route` and `Unknown` out of `class Evpn`,
a refactor across a 2426 line file, its test file and
`evpn_doc_test.rb`, which discovers `Evpn.constants`. There is a cheaper
shape than that: a module holding only `coerce`, `coerce_or_default`,
`read_rd` and `addr_hash`, included by both `Route` bases. It is
additive, it leaves `Evpn.constants` alone, and it leaves every subclass
working. So the sharing cost was overstated. It is still a second topic
in one pull request, which is why it was not done here.

Revisit when a third family needs these, or sooner if a reader prefers
the module.

## 6. Two things the documents do not say

Both were checked in RFC 6514 and in draft-ietf-bess-rfc6514bis-00,
which obsoletes it, rather than assumed.

**The Originating Router's IP Address has no width anywhere.** Neither
document states 4 or 16 and neither derives one. The nearest sentence is
section 8's, that PE addresses "MUST be of the same address family as
the 'Originating Router's IP Address'", which implies a family and gives
no width.

So the width is what is left of the body, which the section 4 Length
field bounds, and the family comes from the field's own size, 4 octets
or 16. That is `Evpn::Ip_prefix_route`'s rule for its GW IP Address and
EVPN route type 2's rule for its optional Label2, and it is sound for
the same reason: the NLRI slices exactly Length octets before any field
is read, so the remainder is bounded rather than open ended.

**The Leaf A-D route cannot be split from its own octets.** Section 7.

## 7. Route type 4, and the split that is not in the band

Section 4.4's body is a Route Key of no stated length followed by an
Originating Router's IP Address of no stated length. Two variable fields
in a row and no length for either, so where one ends is not readable
from the octets.

All section 4.4 says is that "the Route Key of the Leaf A-D route is set
to the NLRI of the received route". The bis draft repeats it and adds
nothing.

The readable reading is that the Route Key is a whole nested NLRI, Route
Type and Length octets included, which makes it self delimiting and
leaves the address as what is behind it. That is the same shape as EVPN
route type 11, whose RFC 9572 section 3.3 uses the same words, and
**RFC 9572 needed its own terminology section to say "entire NLRI"**
before that was more than a reading. RFC 6514 has no such sentence.

So bgp4r takes that reading and does not assert it. The nested read is
accepted only where the whole body replays byte for byte, which is the
rule `Mcast_vpn#read_route` already applies to every route type, and a
body that fails it is kept whole as an `Unknown`. Say in the code that
it is a reading and not a rule. "I do not know why this is like this" is
the honest line until an implementation or a later document answers it.

## 8. Error handling: there is none to implement

Measured by reading both documents. "Malformed" appears only for the
PMSI Tunnel attribute and the PE Distinguisher Labels attribute, and
neither document references RFC 7606 for an NLRI at all.

So what a receiver answers for a bad MCAST-VPN NLRI is not this RFC's to
give, and bgp4r does not invent one. That is the RFC 7432, RFC 9572 and
RFC 4684 situation, and not RFC 8955's, whose section 4.2 says in so
many words that an NLRI with an unknown component type "is considered
malformed".

An unknown route type is therefore reported nowhere. Types 8 to 66 and
72 onward are unassigned, so reporting one would make bgp4r call a
correct router malformed the day IANA assigns one.

## 9. No outside reference

**Neither router in the lab implements SAFI 5.** Measured with `strings`
before any of this was written, the way ATTR_SET's absence was.

GoBGP 3.23.0's address family list is `ipv4-unicast`, `ipv6-unicast`,
`ipv4-multicast`, `ipv4-labelled-unicast`, `l3vpn-ipv4-unicast`,
`l3vpn-ipv4-multicast`, `l3vpn-ipv6-multicast`, `l2vpn-vpls`,
`l2vpn-evpn`, the flow spec entries and the BGP-LS ones. Its
`l3vpn-ipv4-multicast` is SAFI 129, not this. FRR 8.4.4 carries five
`bgp_nlri_parse_` functions, for evpn, flowspec, ip, label and vpn, and
none for this.

So this is the first family in bgp4r with **no outside reference at
all**, and that is weaker than every family since flow spec. The wire
format here is bgp4r's own opinion checked against the field widths the
two documents state, and nothing else.

**The ATTR_SET trick does not transfer**, and it is worth saying why
before someone tries it. A router carries an optional transitive
attribute it has never heard of, which is what made a gobgpd between two
bgp4r speakers worth building. An NLRI in a family the router never
negotiated does not cross anything, so there is nothing in the middle to
measure.

**Do not read the loopback functional test as interoperability.** When
the wiring part adds it, what it proves is that the wiring sites agree
with each other, which is all `flow_spec_test.rb`, `evpn_test.rb` and
`rt_constrain_test.rb` have ever proved.

## 10. No worked example, so the vectors are arithmetic

RFC 6514 carries no hex and no worked example, and neither does RFC
7441. That is the RFC 4684 and RFC 6368 situation rather than the flow
spec one, where five worked examples across two RFCs are the test
vectors and caught four wrong hand written expectations.

Those two cost four wrong hand written length expectations in #204 and
two in #200, every one of them the library being right. So the vectors
in the test files are computed with the library and pasted, and the test
files say that they therefore check the library against this reader's
arithmetic and not against the document.

## 11. What is left

The seven parts are in CLAUDE.md under "Breadth, the one SAFI lever".
This part is the first: the framing, the primitives, `Unknown` and this
document. Nothing dispatches to any of it yet, so an MCAST-VPN UPDATE
still comes back as an `Attr::Raw` with an `Attr::Gap`, which is #116
working as designed.
