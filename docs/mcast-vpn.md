# MCAST-VPN on the wire

RFC 6514, "BGP Encodings and Procedures for Multicast in MPLS/BGP IP
VPNs", and the two RFCs that update it: **RFC 6515**, "IPv4 and IPv6
Infrastructure Addresses in BGP Updates for Multicast VPN", February
2012, and RFC 7441. This is as much of all three as is needed to write
the encoding and decoding, and nothing about the procedures.

**RFC 6515 was missed by the plan for this family and found at the
wiring part**, by the rule EVPN part 8b earned: read every RFC that
lists itself as updating the one you are implementing. Both its header
and RFC 7441's say `Updates: 6514` in so many words, and RFC 7441 was
found that way before any code was written while this one was not,
because the search that found RFC 7441 was for route types. So the rule
is not satisfied by applying it once. Section 6 below records what RFC
6515 settles, which includes two things this document had recorded as
unknown.

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

**The AFI is 1 or 2, so this family has two where EVPN has one, and
what the choice decides is stated rather than left open.** RFC 6515
section 1.1: "When the SAFI field of an MP_REACH_NLRI/MP_UNREACH_NLRI
attribute has the "MCAST-VPN" value", the AFI "has two defined values: 1
and 2", and the value says whether the **customer** multicast addresses
are IPv4 or IPv6. The bis draft's section 4 says the same of the
Multicast Source and Group fields of the S-PMSI, Source Active and
C-multicast routes.

**It still buys the NLRI parse nothing**, which is a different claim and
the one this library rests on: those fields carry their own length in
bits, 32 or 128 by section 4.3, so the octets already say which family
they are and the AFI only repeats it. Preferring the in-band field over
the outer one is the house rule, the same as EVPN route type 2's IP
Address Length against the NLRI's own Length. So a capture reads back
the same way under either AFI, and `Nlri.factory` passes no AFI down.

**An earlier version of this section said "nothing inside the NLRI reads
differently per family", which is too strong and is corrected here.**
The AFI does decide what those addresses are; it is just redundant with
a field that is already in the octets.

Where the AFI genuinely must not be used is the next hop, and that is
section 6.

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
| 1 | Intra-AS I-PMSI A-D route | RFC 6514 section 4.1 | yes |
| 2 | Inter-AS I-PMSI A-D route | RFC 6514 section 4.2 | yes |
| 3 | S-PMSI A-D route | RFC 6514 section 4.3 | yes |
| 4 | Leaf A-D route | RFC 6514 section 4.4 | yes |
| 5 | Source Active A-D route | RFC 6514 section 4.5 | yes |
| 6 | Shared Tree Join route | RFC 6514 section 4.6 | yes |
| 7 | Source Tree Join route | RFC 6514 section 4.6 | yes |
| 67 | S-PMSI A-D route for C-multicast mLDP | RFC 7441 | no |
| 68 | Leaf A-D route for C-multicast mLDP | RFC 7441 | no |
| 71 | Source Tree Join route for C-multicast mLDP | RFC 7441 | no |

**All seven of RFC 6514 section 4 are in.** A type outside them reads
back as an `Mcast_vpn::Unknown` that replays byte for byte, which is
where RFC 7441's three mLDP types land by decision.

### The layouts that are in

| Type | Body | Octets |
| --- | --- | --- |
| 1 | RD, Originating Router's IP Address | 12 or 24 |
| 2 | RD, Source AS | 12, always |
| 3 | RD, source, group, Originating Router's IP Address | 22 or 58 |
| 4 | Route Key, Originating Router's IP Address | neither is stated |
| 5 | RD, source, group | 18 or 42 |
| 6 and 7 | RD, Source AS, source, group | 22 or 46 |

**None of those octet counts is in the document.** Section 4 gives a
Length field and no section gives a total, so each is this reader's
arithmetic from the figure, computed with the library and pasted. See
section 10.

Three things fall out of them and are worth knowing.

**Two pairs collide on length.** Route type 1 with an IPv4 address and
route type 2 are both 12 octets, and route type 3 with IPv4 addresses
and the type 6 and 7 layout with IPv4 addresses are both 22. So nothing
in either body of either pair tells them apart and the Route Type octet
is the only discriminator. That is not a problem the framing has to
solve, since the type is read before the body, but a reader comparing
lengths across this family should know both collisions are there.

**The Multicast Source and Multicast Group pair is in four of the seven
layouts**, types 3, 5, 6 and 7, always in that order and always as a
length in bits then that many bits of value. `Mcast_vpn::Source_and_group`
is that pair in one place, which `Evpn::Multicast_fields` is for the
EVPN address triple. It is a **module and not a base class**, and that
is the EVPN lesson rather than a style choice: the doc test discovers
the route type table from the `Route` subclasses the library defines, so
an abstract `Multicast < Route` would read as a route type with no row
to put it in.

**Route type 3 is the first layout with a variable field after a
variable field.** The two lengths are read first and each takes what it
claims, so the trailing address gets what is left and needs no
arithmetic. The cost is that a length claiming more than the body holds
eats the fields behind it and leaves the address empty, which is
ordinary negative testing: the route then cannot reproduce its own body
and `Mcast_vpn#read_route` keeps the octets as an `Unknown`.

**Route type 2 is the only fixed length layout in the family**, and it
carries the one sentence in section 4 that constrains a field's value
rather than its width: "Two-octet ASNs are encoded in the two
low-order octets of the Source AS field, with the two high-order octets
set to zero." `Source_as` writes a 32-bit unsigned integer, so that
holds by construction and needed no code. A test asserts it rather than
leaving it assumed.

### Two notes on the table.

Types 6 and 7 share one layout. Section 4.6 is titled "C-Multicast
Route" and covers both in one subsection: "A Shared Tree Join route and
a Source Tree Join Route Type specific MCAST-VPN NLRI consists of the
following". So `Mcast_vpn::C_multicast` holds the whole layout and the
two classes are **identity and nothing else**, a `TYPE`, a `HASH_KEY`
and a `NAME`. That is the honest statement of what section 4.6 says:
they differ in their Route Type octet and in the name a reader sees, and
in nothing on the wire. A test asserts they encode identically.

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

## 6. RFC 6515, which settles two things this document called unknown

**This section used to be titled "Two things the documents do not say",
and both are said, in a document the plan for this family had missed.**
RFC 6515, February 2012, header `Updates: 6514`, four pages. It exists
because an MVPN route carries both customer and provider addresses and
only the customer ones have an AFI field to describe them.

Its answer, from the abstract: "the distinction between IPv4 and IPv6 is
signaled solely by the length of the address field". Section 1.1 is
blunter about the half that matters here: the PE address family "MUST
NOT be inferred from the AFI field".

Section 2 lists the four places a provider address appears in an
MCAST-VPN route, and bgp4r's reading of all four turns out to be what it
asks for. That is worth saying plainly: the widths below were derived
here without this document, so RFC 6515 corroborates them rather than
having guided them, the way FRR corroborated EVPN part 9's subcode.

**Item 1, the next hop.** "it is always clear whether the address is an
IPv4 address (length is 4) or an IPv6 address (length is 16)." So SAFI 5
joins the length-only next hop arm EVPN and RT-constrain share, and with
the strongest of the three citations: RFC 7432 section 14 and RFC 4684
section 4 each say to read the length, where this one forbids using the
AFI. Item 1 also carries the one receive side rule any document in this
family has: a length that is neither 4 nor 16 makes the MP_REACH_NLRI
"incorrect", handled per section 7 of RFC 4760. See section 8.

Section 1.1 also rules out the alternative by name. RFC 4659 and RFC
4798 required an IPv4 PE address to be written as an IPv4-mapped IPv6
address in a route carrying IPv6 customer addresses, and of that
approach section 1.1 says: "This document does not use that approach."
So an MCAST-VPN next hop under AFI 2 is a plain 4-octet IPv4 address
when that is what the PE has, and `nexthop_klass` answers a plain
`Prefix` with no `Ipv4_mapped` branch for a cited reason rather than by
analogy with EVPN.

**Items 2, 3 and 4, the Originating Router's IP Address.** Neither RFC
6514 nor the bis draft states a width for it, which is what this section
used to record; the nearest sentence is section 8's, that PE addresses
"MUST be of the same address family as the 'Originating Router's IP
Address'", which implies a family and gives no width. RFC 6515 supplies
the derivation, one item per route type that carries the field. For the
Intra-AS I-PMSI route: "The length of this field (4 octets for IPv4 or
16 octets for IPv6) can thus be inferred from the NLRI length field
(which will be either 12 or 24, respectively)." Items 3 and 4 do the
same for the S-PMSI and Leaf A-D routes through their variable-length
fields.

So the width is what is left of the body, which the section 4 Length
field bounds, and the family comes from the field's own size, 4 octets
or 16. That is `Evpn::Ip_prefix_route`'s rule for its GW IP Address and
EVPN route type 2's rule for its optional Label2, and it is sound for
the same reason: the NLRI slices exactly Length octets before any field
is read, so the remainder is bounded rather than open ended.

**That 12-or-24 is the only octet count any document in this family
states**, and section 3's table had it from arithmetic. Section 10
records what that changes and what it does not.

**Item 4 settles route type 4's split**, which section 7 recorded as not
being in the band: "The Route Key has its own length field." Section 7
says what that does and does not change.

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

So bgp4r takes that reading and says in the code that it is a reading.
"I do not know why this is like this" is the honest line until an
implementation or a later document answers it.

### A later document answered it, and the answer is the reading

**RFC 6515 section 2 item 4: "The Route Key has its own length field."**
It goes on: "the "NLRI length" field is following by a variable-length"
"route key", which is followed by the "Originating Router's IP"
address, and "From the NLRI length and the route key length, one can
compute the length" of that address.

So the split **is** in the band after all, and the reading above is what
the standards track says. Three things follow, and the third is the one
worth keeping.

It was found at the wiring part, after route type 4 shipped, so the code
and the part 4 entry in CLAUDE.md were written against RFC 6514 and the
bis draft alone. Both are corrected rather than left reading as open.

The code did not change. The nested read already took its extent from
the Route Key's own Length octet, which is what item 4 describes, so
there was nothing to fix: this turned a reading into a citation.

**The rule that would have found it earlier is one this repository
already had written down.** EVPN part 8b earned it after RFC 9785 was
missed: read every RFC that lists itself as updating the one you are
implementing. RFC 7441 was found that way before any MCAST-VPN code was
written. RFC 6515 was not, because the search that found RFC 7441 was
about route types and nothing was searched again when the question
changed to addresses. So applying the rule once per family is not
applying it: the registry of updating RFCs has to be read for its own
sake, not as a side effect of whatever is being looked up.

### What the replay check buys here, which is less than this section claimed

Until route type 4 was written, this section said the nested read "is
accepted only where the whole body replays byte for byte", pointing at
the rule `Mcast_vpn#read_route` applies to every route type. That is
true and it is not the safeguard it reads as. An earlier draft of the
class comment went further and said the body could be split anywhere and
still replay, which is simply wrong. Both are corrected here.

**The split is read from the nested Length octet, so it is injective on
the octets.** Two different field pairs cannot encode to one body,
because the Length that decides the split is one of the octets. Take two
Leaf A-D routes of the same total size: `0101ff` plus a 4-octet address
is `0101ff0a000001`, and `0104ff0a0000` plus a 1-octet remainder is
`0104ff0a000001`. Same length, different second octet. So the reading is
self consistent and the fields always reproduce the body.

**That is exactly why the replay check says nothing about the reading.**
It is satisfied by construction. What it catches is two things and
neither is the one that matters: a body too short to frame a Route Key at
all, and a nested Length that overruns the body. Both raise out of the
route type, and `read_route` keeps the octets whole as an `Unknown`.

**A sender using another rule is undetectable.** If the authors meant
the Route Type specific part alone with a fixed width address behind it,
their octets read into different fields here and nothing on the wire
shows the disagreement. So do not point at the replay check as what
makes the reading safe. It is what makes the octets safe.

**A reader using another rule is undetectable too**, which is the
sharper version of the same point and was measured rather than argued.
Reading the Route Key two octets short leaves a route type 3 that is
still a route type 3, with a shorter Originating Router inside it, and
the outer body still replays byte for byte, because the nested Length
that lied is echoed. So neither the replay check nor an assertion on the
class catches it. `test_the_split_is_pinned_by_the_field_values_and_nothing_else`
in `test/unit/nlris/mcast_vpn_test.rb` is what does, and it is the only
guard on the split there can be.

### Leaf_a_d is the one class that does not work against its own file

`Leaf_a_d` reaches `Mcast_vpn` at call time and not at load time, which
is what lets a route type in `mcast_vpn_route.rb` hold an NLRI from
`mcast_vpn.rb`: `Mcast_vpn` is the class around every route type, and
the NLRI's own methods are added by the file that requires this one. So
it is the only route type here that needs `mcast_vpn.rb` loaded, and
**its tests live in `test/unit/nlris/mcast_vpn_test.rb`** beside the
framing they exercise. `mcast_vpn_route_test.rb` requires the route
file alone, which is what proves the other six need no NLRI.

The one signal available is the remainder's width. The Originating
Router's IP Address is an address, so `originator.address` answers nil
when what is left is neither 4 nor 16 octets, which is a reason to doubt
the split. bgp4r does **not** use it to pick the split: choosing by it
would be inventing a rule where the documents have none. A caller who
believes another reading can build it by handing the Route Key its own
octets, since nothing validates.

## 8. Error handling: four checks, and RFC 6515 is where all four come from

**This section has now said three different things and the history is
the point.** Part 1 said there is no error handling text, measured by
reading RFC 6514 and the bis draft. Part 5 found RFC 6515 and corrected
that to one rule. Part 6 read RFC 6515's section 2 properly and the
answer is **four**, one per item, because the rule it states is repeated
for each of the four places a provider address appears in an MCAST-VPN
route. An absence recorded as measured is the kind of claim that stops
the next reader looking, which is exactly what happened twice here.

What every item says, in its own words for item 2: "If the inferred
length of the 'Originating Router's IP Address' field is neither 4 nor
16, the MP_REACH_NLRI attribute MUST be considered to be 'incorrect',
and MUST be handled as specified in Section 7 of [BGP-MP]." Item 1 says
the same of the next hop, where the length is a field of its own rather
than inferred.

| what | where | action |
| --- | --- | --- |
| a next hop length that is neither 4 nor 16 | item 1 | session reset |
| route type 1's Originating Router neither 4 nor 16 | item 2 | session reset |
| route type 3's Originating Router neither 4 nor 16 | item 3 | session reset |
| route type 4's Originating Router neither 4 nor 16 | item 4 | session reset |

Plus the framing, which every family gets and no MCAST-VPN RFC asks for:
octets too few to hold a Route Type and Length, and a Length that
overruns the attribute. Those take the action below for the reason below.

### Where the subcode and the action come from, which is not a derivation

Part 5 left this as the open question: RFC 6515 points at RFC 4760
section 7 and names no subcode, and RFC 4760 predates RFC 7606, so what
"incorrect" means now had to be answered rather than assumed.

It is answered by the document that already governs this, and the
answer is that **bgp4r's existing finding is the same rule**. RFC 7606's
header says `Updates: 4760`, and its section 7.11 states RFC 6515's
sentence generally:

> If the Length of Next Hop Network Address field of the MP_REACH
> attribute is inconsistent with that which was expected, the attribute
> is considered malformed.

and, on the action, that because "the next hop precedes the NLRI field
in the attribute" the NLRI cannot be reliably located, so "the 'session
reset' or 'AFI/SAFI disable' approach MUST be used".

Section 7.11 then leaves the expectation to the family, and its worked
example is RFC 6515's sentence from the other end: "'That which was
expected', while somewhat vague, is intended to encompass the next hop
specified for the Address Family Identifier and Subsequent Address
Family Identifier fields and is potentially modified by any extensions
in use. For example, if [RFC5549] is in use, then the next hop would
have to have a length of 4 or 16."

So this is not a new rule and needs no new subcode. It is 7.11's own
clause with one family's expectation filled in, and bgp4r already
reports 7.11 as subcode 9 with a session reset for a next hop that does
not fit. **Inventing a subcode was the trap here**, the one flow spec
part 4 and EVPN part 9 each recorded, and the way out was reading the
RFC that updates the one being pointed at.

### Only this family's next hop is checked, and the reason is the RFCs

Three families share the length-only next hop arm in `mp_reach.rb`:
EVPN, RT-constrain and MCAST-VPN. Only MCAST-VPN's length is checked,
and the difference is **which RFC names the error**, not which has an
expectation.

- RFC 7432 section 14: an EVPN next hop "MUST be set to the IPv4 or IPv6
  address of the advertising PE". That binds a sender and names no
  receiver action.
- RFC 4684 section 4: the field "shall be interpreted as an IPv4 address
  whenever the length of NextHop address is 4 octets". That tells a
  reader how to read it and says nothing about other lengths.
- RFC 6515 section 2 item 1 states the error and the handling.

Extending the check to the other two would be deriving from 7.11 alone.
That is legitimate, since 7.11's rule is general, but it is a decision
rather than an implementation and so is **the obvious next piece of work
here**, with the citations already in hand.

### MP_UNREACH is not checked, and that is the RFC's choice

All four of section 2's items name the MP_REACH_NLRI attribute and none
mentions MP_UNREACH_NLRI, measured by reading them. So the four checks
above run on an MP_REACH only, which is the `reach` argument EVPN's
checks already use, reached here by the RFC saying so rather than by
reasoning about the route key the way EVPN's two did. An MP_UNREACH
carries no next hop at all, so item 1 could not apply there anyway.

The framing findings do run on both, because octets that cannot be split
are not a question about which attribute holds them.

### What is still not checked

"Malformed" appears nowhere in RFC 6514 or the bis draft but for the
PMSI Tunnel attribute and the PE Distinguisher Labels attribute, and
neither document references RFC 7606 for an NLRI at all. So everything
about a bad MCAST-VPN NLRI beyond the four above is not these RFCs' to
give, and bgp4r does not invent it. That is the RFC 7432, RFC 9572 and
RFC 4684 situation, and not RFC 8955's, whose section 4.2 says in so
many words that an NLRI with an unknown component type "is considered
malformed".

An unknown route type is therefore reported nowhere. Types 8 to 66 and
72 onward are unassigned, so reporting one would make bgp4r call a
correct router malformed the day IANA assigns one. **RFC 7441's three
mLDP types land here too**, and that makes the decision sharper rather
than softer: they are assigned and out of scope by decision, so
reporting an unknown type would call a conformant mLDP speaker
malformed.

### Two receive-side rules that are not error handling

Found while writing route type 5, and recorded here rather than left
for part 6 to rediscover. Both are in section 4.5 and neither belongs
in `validation.rb` on today's reading. Say why, not just which.

"Use of the Source Active A-D routes with the Multicast Source Length
field of 0 is outside the scope of this document." That is the third
"outside the scope is not an error" sentence in this family, after the
two in section 4.3, so a wildcard source builds and reads here.

A route whose Multicast Group is in the Source Specific Multicast range
"MUST NOT be advertised by a router and MUST be discarded if received".
That one is a real MUST on a receiver and it is still not a
`validation.rb` rule, for two reasons. It needs the group's **value**
against a range RFC 6514 does not number, deferring to RFC 4607 and
letting a router extend it locally, so bgp4r would be asserting a range
no document here states. And "discarded" is not one of the actions RFC
7606 names, so there is no subcode and no action to report it as:
nothing about the octets is wrong. This is the RFC 9117 situation that
`docs/flow-spec.md` records, route feasibility rather than encoding.

## 9. No outside reference

**Neither router in the lab implements SAFI 5.** First measured with
`strings` before any of this was written, the way ATTR_SET's absence
was, and **asserted** since, by `mcast_vpn_gobgp_test.rb` and
`mcast_vpn_frr_test.rb` under `test/functional/lab`. Those two are the
only lab tests here that measure an absence, and they exist because this
absence is load bearing: the scope of section 8 and the weakness of the
loopback test both rest on it, and a fact nothing checks reads as
verified. If a later release grows the family, they fail and say to come
back.

GoBGP 3.23.0's address family list is `ipv4-unicast`, `ipv6-unicast`,
`ipv4-multicast`, `ipv4-labelled-unicast`, `l3vpn-ipv4-unicast`,
`l3vpn-ipv4-multicast`, `l3vpn-ipv6-multicast`, `l2vpn-vpls`,
`l2vpn-evpn`, the flow spec entries and the BGP-LS ones. Its
`l3vpn-ipv4-multicast` is SAFI 129, not this. FRR 8.4.4 carries five
`bgp_nlri_parse_` functions, for evpn, flowspec, ip, label and vpn, and
none for this, and its `address-family` grammar offers `ipv4
[<unicast|multicast|vpn|labeled-unicast|flowspec>]`, the ipv6 twin and
`l2vpn evpn`.

So this is the first family in bgp4r with **no outside reference at
all**, and that is weaker than every family since flow spec. The wire
format here is bgp4r's own opinion checked against the field widths the
documents state, and nothing else. **The two lab tests do not change
that**, which has to be said plainly because a lab test for a family
usually means the opposite: a router with no parser for SAFI 5 never
reads our octets, so neither test says anything about whether the
encoding is right.

### How each router says it does not have the family

Three readings each, because no one of them says it alone, and the
config half is the cheapest and strongest: the family is not in the
router's vocabulary, so there is nothing to negotiate.

| | GoBGP 3.23.0 | FRR 8.4.4 |
|---|---|---|
| its config | `gobgpd` refuses the file and exits: `mcast-vpn isn't a valid route family name` | `bgpd` logs `No such command on config line N:  address-family ipv4 mcast-vpn` and comes up without it |
| the capability we offer | records it as `UnknownFamily(65541): received`, which is afi << 16 \| safi | logs `MultiProtocol Extensions capability for afi/safi: IPv4/unknown`, and negotiates nothing: one key in its capability list, not two |
| an MCAST-VPN UPDATE sent anyway | **discards the message, keeps the session** | **tears the session down, with no NOTIFICATION** |

**The last row is the finding.** Two routers with the same gap answer
differently, so neither behaviour is bgp4r's to copy, which is the
flow spec section 4.2 situation again. GoBGP counts the message under
`Discarded` rather than `Updates`, logs `unknown route family. AFI: 1,
SAFI: 5`, and leaves the session and an already installed route alone.
FRR calls it `Attribute MP_REACH_NLRI, parse error`, then `BGP UPDATE
receipt failed for peer`, then `BGP_Stop (Established->Clearing)`. RFC
4271 section 6 wants a NOTIFICATION before a close and FRR's path here
sends none. Recorded and not filed.

**`is_established?` cannot see FRR's reset**, and that is the trap these
two tests were written through rather than a note for the reader. FRR
dials back in within a second or two, so a read a few seconds after the
send finds a session established and concludes nothing happened. The
first measurement taken here said exactly that, and it was wrong about
the verdict and not just the detail. Both tests watch
`Neighbor#on_state_change`, which is what phase 2 of the RIB work added
it for: a message observer cannot see a drop, and here there is not even
a NOTIFICATION to observe.

Two more things each test needs, both measured:

* **Read GoBGP's capability before sending anything in the family.** It
  stops printing `UnknownFamily(65541)` once an MCAST-VPN UPDATE
  arrives, logging `Capability was disabled`. A test reading it
  afterwards would find nothing and could conclude the capability was
  never received. Be exact about that log line, because EVPN section 9
  records it overstating what GoBGP did: there a route type 3 still
  installed on the same session after it. Here the family really is
  dropped from the neighbor output. What it never means either way is
  that the session is over.
* **The control route is an MP_REACH_NLRI for SAFI 1, not an RFC 4271
  section 4.3 UPDATE.** That holds the attribute, the next hop and the
  AS_PATH constant and varies only the SAFI, so a discard or a reset
  cannot be the router objecting to MP_REACH or to our encoding of it.
  Measured: both routers install it. FRR's needs a non-loopback next
  hop, `Frr::NEXT_HOP`, for the reason `rib_router_frr_test.rb`
  records.

**RFC 6515 narrowed that gap without closing it**, which is the one
qualification worth adding. Reading it turned the next hop rule and the
Originating Router's width from bgp4r's reading into citations, and
confirmed route type 4's split, so three of the places where this family
was bgp4r's opinion alone are now a document's. What no document can
give is agreement about what is on the wire, and that still has no
second implementation behind it.

**The ATTR_SET trick does not transfer**, and it is worth saying why
before someone tries it. A router carries an optional transitive
attribute it has never heard of, which is what made a gobgpd between two
bgp4r speakers worth building. An NLRI in a family the router never
negotiated does not cross anything, so there is nothing in the middle to
measure.

**Do not read the loopback functional test as interoperability.**
`test/functional/mcast_vpn_test.rb` exists now, and what it proves is
that the wiring sites agree with each other, which is all
`flow_spec_test.rb`, `evpn_test.rb` and `rt_constrain_test.rb` have ever
proved. For every other family that is one check among two or three;
here it is the only one there is.

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

**It kept costing: three more hand written expectations were wrong in
the functional test and the library was right all three times.** Two
were API shape, `Rd#to_s(false)` keeping its `RD=` prefix and
`Source_as` having `value` rather than `to_i`; the third was a claim
about behaviour, that an NLRI Length disagreeing with its body makes the
route read back as an `Unknown`. It does not, and the reason is worth
keeping: `read_route`'s rule is that a route type must reproduce **its
body**, and a Length that lies sits outside the body, so a good route
type 1 in a 12-octet body stays a route type 1 while `declared_len`
echoes the Length that lied. Only a body a type cannot reproduce falls
back.

**One octet count is in a document after all**, found with RFC 6515 and
recorded in section 6: item 2 gives the Intra-AS I-PMSI route's NLRI
length as "either 12 or 24, respectively", and both agree with section
3's table. So two of the six counts there are now the document's and
four are still arithmetic. That does not change the rule above, since
RFC 6515 states no hex either, but it does mean "no octet count is in
any document" was true only of the two documents that had been read.

## 11. What is left

The seven parts are in CLAUDE.md under "Breadth, the one SAFI lever".
Six are done: the framing and the primitives, then route types 1, 2 and
5, then 3, 6 and 7, then 4, then the wiring, then validation. Only the
lab is left.

**Both dispatch gates know SAFI 5 now**, so an MCAST-VPN UPDATE reads
and writes over a real session: `Nlri.factory` and `MpReachCommon#set`
each have an arm, the two parse loops ask `Mcast_vpn.nlri_size` how long
an NLRI is, and `parse_next_hops` and `nexthop_klass` read the next hop
by its length per RFC 6515. It is no longer an `Attr::Raw` with an
`Attr::Gap`.

**And a malformed route is reported on receive**, four checks, all of
them RFC 6515 section 2's: section 8 has them with where each comes
from. So by this plan's own measure the family is finished on the wire
in both directions.

What is left is one lab measurement, which for this family is not a test
of bgp4r at all: it asserts that neither router negotiates SAFI 5, since
that absence is what the whole scope of section 8 and the weakness of
section 9 rest on, and a fact nothing checks reads as verified.
