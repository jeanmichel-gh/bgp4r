# Flow Specification on the wire

RFC 8955 for IPv4 and RFC 8956 for IPv6, as much as is needed to write
the encoding and decoding and no more.

Read this before touching `bgp/nlris/flow_spec_component.rb`, before
adding a flow spec family to `mp_reach.rb`, or before adding one of the
missing action communities. **Its load bearing claims are asserted by
`test/unit/flow_spec_doc_test.rb`**, because a claim nothing checks
reads as verified, and `docs/to-hash-round-trips.md` was retired for
being half enforced and half prose with nobody noticing which was which.
If you change a number here, that test tells you whether you changed a
fact or broke one.

Every section number below was read in the RFC text. Where this document
says something the RFCs do not, it says so.

## 1. There is no new path attribute

Flow spec defines **no new path attribute type code**. A rule is a match
part and an action part, and each rides in an attribute that already
exists:

| part | attribute |
|---|---|
| the match, the rule itself | MP_REACH_NLRI (14) and MP_UNREACH_NLRI (15), RFC 4760 |
| the actions | Extended Communities (16), and for IPv6 Address Specific ones, attribute 25 |

So the work splits in two. The NLRI encoding is `bgp/nlris/`, and the
actions are extended community sub-types in
`bgp/path_attributes/extended_community.rb` and
`bgp/path_attributes/ipv6_extended_communities.rb`.

## 2. Where it rides

| AFI | SAFI | What |
|---|---|---|
| 1 | 133 | IPv4 flow spec, RFC 8955 section 4 |
| 1 | 134 | VPNv4 flow spec, RFC 8955 section 8 |
| 2 | 133 | IPv6 flow spec, RFC 8956 section 2 |
| 2 | 134 | L3VPN IPv6 flow spec, RFC 8956 section 2 |

Both ends MUST advertise the Multiprotocol Extension capability, code 1,
for the pair they want to use.

**The next hop rule is two MUSTs, one per direction.** RFC 8955 section
4: "When advertising Flow Specifications, the Length of the Next-Hop
Network Address MUST be set to 0. The Network Address of the Next-Hop
field MUST be ignored." The first binds a sender, the second a receiver,
and bgp4r needed nothing for the first and a line for the second.

**Sending.** `Mp_reach#encode` writes `@nexthops.size` as that length,
and a caller who passes no `:nexthop` has an empty list, so the field is
0 with no code anywhere deciding it should be. An earlier version of
this document said nothing wrote a zero length next hop today, which was
wrong when it was written and not merely stale: the rule holds by
construction. Measured on 2026-10-30.

**Receiving, which is where the work was.** A sender keeping the first
MUST never puts a next hop here, so the only way one arrives is a sender
breaking it, and `parse_next_hops` used to raise on that: the whole
attribute came back as an `Attr::Raw` with an `Attr::Gap` and the rule
inside was never read. So "ignored" cannot mean "refused", and it does
not mean "discarded" either. The field is read as an address, the same
way SAFI 1 and 2 read theirs, for the reason the library keeps and
echoes a reserved field: `encode` stays byte for byte and the hash can
still rebuild it. Nothing there claims RFC 8950 applies to flowspec, so
a length no address fits behaves as it does for every other SAFI.

A caller who does pass a next hop for this family gets one on the wire,
because building never validates and sending a field the RFC forbids is
a negative test. All three are asserted:
`test_the_flow_spec_next_hop_length_is_zero_without_one` and
`test_a_flow_spec_next_hop_is_read_rather_than_refused` in
`test/unit/path_attributes/mp_reach_test.rb`.

## 3. The NLRI framing

RFC 8955 section 4, Figure 1. The NLRI field of MP_REACH_NLRI and
MP_UNREACH_NLRI is one or more of these:

```
+-------------------------------+
|    length (0xnn or 0xfnnn)    |
+-------------------------------+
|    NLRI value   (variable)    |
+-------------------------------+
```

Section 4.1, the length encoding:

* The length is in **octets**, not bits.
* It counts the value only, never itself.
* Below 240 it is one octet.
* From 240 up it is two octets whose most significant nibble is 0xf,
  giving 12 bits of length and a maximum of 4095.
* The RFC's own examples: "the length value of 239 is encoded as 0xef
  (single octet), while 240 is encoded as 0xf0f0 (2 octets)".

That is unambiguous because a one octet length never exceeds 239, so its
top nibble is never 0xf:

```ruby
b = s.getbyte(0)
if (b & 0xf0) == 0xf0
  len = ((b & 0x0f) << 8) | s.getbyte(1) ; s.slice!(0, 2)
else
  len = b                                ; s.slice!(0, 1)
end
```

**This is the one place the framing is not shared.** The prefix
families give a length in **bits**, in one octet, RFC 4271 section 4.3,
so an NLRI is `1+(length+7)/8` octets, and `Mp_reach#parse` and
`Mp_unreach#parse` used to work that out inline and hand the slice down.
Neither half of it holds for flow spec: octets rather than bits, in one
or two octets rather than always one.

So the loops ask instead of calculating. `MpReachCommon::ClassMethods`
has `nlri_size(s, afi, safi)`, which answers the prefix arithmetic for
every other family and defers to `Flow_spec.nlri_size` for SAFI 133 and
134. `Flow_spec.encode_length` writes the field on the way out.

That is also the answer to the registry question the plan in `CLAUDE.md`
left open. The need turned out to be one more arm on one `case`, read by
both loops, because the framing belongs to the family and the family can
own it. One arm is not a registry.

`nlri_size` answers **nil** for octets too short to hold a length field,
so a loop stops rather than spinning. The loops then leave the octets
and raise on the leftover, which is how an attribute bgp4r cannot read
becomes an `Attr::Raw` with an `Attr::Gap` and keeps its bytes.

## 4. The NLRI value

RFC 8955 section 4.2. The value is `<[component]+>` and a packet matches
the AND of every component present.

Each component is a type octet then a variable parameter. **A component
carries no length of its own and there is no end marker.** You know where
one ends only because you decoded it: a prefix component from its length
octet, an operator component from the end-of-list bit on its last pair.
Three consequences for the code:

* Parsing must be **bounded by the section 4.1 length**, since that is
  the only bound there is. Hand a component exactly one NLRI's value
  octets.
* A **missing end-of-list bit is not always detectable.** The octets
  after it are read on as further pairs, and where they happen to form a
  valid operator sequence nothing distinguishes that from what the
  sender meant. Keep the octets, report what is reportable, and do not
  try to recover intent.
* Never guess a component boundary.

Section 4.2 also says: "Components MUST follow strict type ordering by
increasing numerical order. A given component type MAY (exactly once) be
present in the Flow Specification."

**That MUST binds a sender as much as a reader.** bgp4r builds out of
order and repeated components anyway, because negative testing is the
point, so this is a deliberate deviation from a MUST and not an
unenforced receive check. See Conventions in `CLAUDE.md`. The receive
side check belongs in `validation.rb`.

An unknown component type makes the whole NLRI malformed, per section
4.2, with error handling under section 10, meaning RFC 7606 and RFC
4760. Note what that costs and that the RFC asks for it anyway: types 14
to 254 are Unassigned in RFC 8956 section 8.1.2, so a type IANA assigns
in future reads as malformed until the code implements it.

## 5. The two operator octets

RFC 8955 section 4.2.1. Both are one octet and share the top nibble. Bit
0 is the most significant, as both figures number them.

### numeric_op, section 4.2.1.1, Figure 2

```
  0   1   2   3   4   5   6   7
+---+---+---+---+---+---+---+---+
| e | a |  len  | 0 |lt |gt |eq |
+---+---+---+---+---+---+---+---+
```

| field | mask | meaning |
|---|---|---|
| e | 0x80 | end-of-list. Set on the last pair in the list |
| a | 0x40 | AND with the previous pair, else OR. MUST be unset in the first octet of a sequence and MUST be treated as unset on decode. AND binds tighter than OR |
| len | 0x30 | the value width is `1 << len`, so 1, 2, 4 or 8 octets |
| 0 | 0x08 | MUST be 0 on encode, MUST be ignored on decode |
| lt gt eq | 0x07 | the comparison, below |

Section 4.2.1.1, Table 1, the low three bits read together:

| lt gt eq | operation |
|---|---|
| 000 | false, whatever the value |
| 001 | == |
| 010 | > |
| 011 | >= |
| 100 | < |
| 101 | <= |
| 110 | != |
| 111 | true, whatever the value |

### bitmask_op, section 4.2.1.2, Figure 3

```
  0   1   2   3   4   5   6   7
+---+---+---+---+---+---+---+---+
| e | a |  len  | 0 | 0 |not| m |
+---+---+---+---+---+---+---+---+
```

`e`, `a` and `len` are identical to numeric_op, which the section says
outright. Bits 4 and 5, mask 0x0c, MUST be 0 and are ignored on decode.

| field | mask | meaning |
|---|---|---|
| not | 0x02 | logical negation of the operation |
| m | 0x01 | set: `(data AND value) == value`. Unset: true if any bit in the value mask is set in the data |

### Reading a pair list

The width in the operator applies to the value that **follows** it. So:
read the operator octet, compute `1 << len`, read that many octets big
endian, repeat until a pair carries the end-of-list bit.

bgp4r names the four bitmask readings `:any` for m unset, `:match` for m
set, and `:not_any` and `:not_match` for those negated. **Those names are
bgp4r's and not the RFC's**, which names no symbols.

## 6. The components

RFC 8955 section 4.2.2 and RFC 8956 section 3. The type numbers are one
registry covering both families, RFC 8956 section 8.1.2.

| Type | IPv4 name | IPv6 name | Parameter | Width |
|---|---|---|---|---|
| 1 | Destination Prefix | Destination IPv6 Prefix | prefix, see below | n/a |
| 2 | Source Prefix | Source IPv6 Prefix | prefix, see below | n/a |
| 3 | IP Protocol | Upper-Layer Protocol | numeric | SHOULD 1 |
| 4 | Port | Port | numeric | SHOULD 1 or 2 |
| 5 | Destination Port | Destination Port | numeric | SHOULD 1 or 2 |
| 6 | Source Port | Source Port | numeric | SHOULD 1 or 2 |
| 7 | ICMP Type | ICMPv6 Type | numeric | SHOULD 1 |
| 8 | ICMP Code | ICMPv6 Code | numeric | SHOULD 1 |
| 9 | TCP Flags | TCP Flags | bitmask | MUST 1 or 2 |
| 10 | Packet Length | Packet Length | numeric | SHOULD 1 or 2 |
| 11 | DSCP | DSCP | numeric | MUST 1 |
| 12 | Fragment | Fragment | bitmask | MUST 1 |
| 13 | Unassigned | Flow Label | numeric | SHOULD 4 |

Type 0 and type 255 are Reserved. Types 14 to 254 are Unassigned.

**Read those widths as the RFC writes them.** A SHOULD is not a MUST, so
a decoder has to read whatever `len` says whichever row it is on, and an
encoder may write any width. Only the default differs. The Flow Label is
the one row whose recommended width is wider than its values need, four
octets for a 20 bit field, so a label of 6 defaults to `0d a1 00000006`
while a port of 6 defaults to `04 81 06`. A one octet flow label,
`0d 81 06`, is not prohibited and bgp4r builds and parses it.

Three details that are easy to get wrong:

* **Type 9, TCP Flags.** One octet matches TCP header octet 14, the
  control bits. Two octets match octets 13 and 14 with the data offset,
  the leftmost 4 bits, always treated as 0.
* **Type 11, DSCP.** "The six least significant bits contain the DSCP
  value. All other bits SHOULD be treated as 0."
* **Type 3 for IPv6** matches the first Next Header value octet that is
  not an extension header, RFC 8956 section 3.3, not every Next Header
  in the chain.

### Types 1 and 2 for IPv4

RFC 8955 sections 4.2.2.1 and 4.2.2.2:

```
<type (1 octet), length (1 octet), prefix (variable)>
```

"The length and prefix fields are encoded as in BGP UPDATE messages
[RFC4271]." That is exactly what `BGP::Prefix#encode` already produces,
so those two delegate. Verified on 2026-10-30:
`Prefix.new('192.0.2.0/24').encode` is `18c00002`.

### Types 1 and 2 for IPv6

RFC 8956 sections 3.1 and 3.2. This is the only genuinely new layout in
either document:

```
<type (1 octet), length (1 octet), offset (1 octet),
 pattern (variable), padding (variable)>
```

* `length` is "the N-th most significant bit in the address where
  bitwise pattern matching stops".
* `offset` is "the number of most significant address bits to skip
  before bitwise pattern matching starts".
* `pattern` carries `length - offset` bits.
* `padding` fills to an octet boundary and "MUST be 0 on encoding and
  MUST be ignored on decoding".
* If length and offset are both 0 the component matches every address.
  Otherwise `offset < length < 129` or the component is malformed.

The arithmetic, which reproduces both of section 3.8's examples:

```ruby
bits   = length - offset
v      = (IPAddr.new(addr).to_i >> (128 - length)) & ((1 << bits) - 1)
v    <<= (-bits) % 8                  # left align, pad with zeros
octets = (bits + 7) / 8
```

Decoding is the inverse, and the address you recover is the pattern
shifted right by `offset`. Section 3.1's own note gives the reading back:
the component "can be represented by the notation ipv6address/length if
offset is 0 or ipv6address/offset-length". bgp4r accepts and prints both
forms.

### The fragment bitmask

RFC 8955 section 4.2.2.12, Figure 4, for IPv4:

```
  0   1   2   3   4   5   6   7
+---+---+---+---+---+---+---+---+
| 0 | 0 | 0 | 0 |LF |FF |IsF|DF |
+---+---+---+---+---+---+---+---+
```

RFC 8956 section 3.6, Figure 1, for IPv6, where DF has no meaning:

```
  0   1   2   3   4   5   6   7
+---+---+---+---+---+---+---+---+
| 0 | 0 | 0 | 0 |LF |FF |IsF| 0 |
+---+---+---+---+---+---+---+---+
```

| bit | mask | IPv4 | IPv6 |
|---|---|---|---|
| DF | 0x01 | Don't Fragment set | reserved, MUST be 0 |
| IsF | 0x02 | a fragment other than the first | same |
| FF | 0x04 | first fragment | same |
| LF | 0x08 | last fragment | same |

The high nibble MUST be 0 on encode and is ignored on decode in both.

## 7. The worked examples

RFC 8955 section 4.3 and RFC 8956 section 3.8. These are the test
vectors in `test/unit/nlris/flow_spec_component_test.rb`. What they buy
is independence from whoever read the RFC. That is narrower than
immunity, and the fifth row below is why.

| Where | Rule | Length | Components |
|---|---|---|---|
| 8955 4.3.1 | to 192.0.2.0/24, TCP, port 25 | `0b` | `0118c00002` `038106` `048119` |
| 8955 4.3.2 | to 192.0.2.0/24 from 203.0.113.0/24, port in [137,139] or 8080 | `12` | `0118c00002` `0218cb0071` `040389458b911f90` |
| 8955 4.3.3 | to 192.0.2.1/32, fragment DF or FF | `09` | `0120c0000201` `0c8005` |
| 8956 3.8.1 | to 2001:db8::/32 from ::1234:5678:9a00:0/64-104, tcp | `12` | `01200020010db8` `026840123456789a` `038106` |
| 8956 3.8.2 | to 2001:db8::/32 from ::1234:5678:9a00:0/65-104 | `0f` | `01200020010db8` `0268412468acf134` |

Read 4.3.2's three port operators, which the document decodes for you:
`03` is `>=` with a one octet value, `45` is AND `<=`, and `91` is
end-of-list with a two octet value and `==`.

**The 8956 3.8.1 destination above is the corrected value, not what the
RFC prints.** RFC 8956 errata ID 7571, Technical, Verified by John
Scudder on 2024-01-12: section 3.8.1 Table 1 prints
`01 20 00 20 01 0d bb` where it should read `01 20 00 20 01 0d b8`.
Table 2 of the same section decodes that octet as 0xb8 and the prose
says 2001:db8::/32, so the document disagrees with itself. Do not
"correct" this table or the test to match Table 1.

**Read the errata for any RFC whose own example you are about to
disbelieve**, at `https://www.rfc-editor.org/errata/rfcNNNN`. When this
discrepancy was first found the right conclusion was reached for an
invented reason, that an HTML to text conversion had mangled the table,
which would have left the next reader nothing to check.

## 8. The actions

RFC 8955 section 7, Table 8, written `0xttss` where `tt` is the type and
`ss` the sub-type. All of them are transitive.

**Count these carefully.** There are **seven type and sub-type
combinations** representing **five action kinds**, because rt-redirect
has three encodings for the three Route Target forms. Saying either
number alone has caused confusion here.

| 0xttss | Action | Section | Encoding |
|---|---|---|---|
| 0x8006 | traffic-rate-bytes | 7.1 | 2 octet id, 4 octet IEEE float, bytes per second |
| 0x800c | traffic-rate-packets | 7.2 | the same, packets per second |
| 0x8007 | traffic-action | 7.3 | 6 octet bitmask |
| 0x8008 | rt-redirect, AS 2 octet | 7.4 | 2 octet AS, 4 octet value |
| 0x8108 | rt-redirect, IPv4 | 7.4 | 4 octet IPv4 address, 2 octet value |
| 0x8208 | rt-redirect, AS 4 octet | 7.4 | 4 octet AS, 2 octet value |
| 0x8009 | traffic-marking | 7.5 | reserved, then a 6 bit DSCP |

The three rt-redirect encodings are the Route Target forms of RFC 4360
sections 3.1 and 3.2 and RFC 5668 section 2, with the sub-type always
0x08.

### The traffic-action T bit reads backwards

RFC 8955 section 7.3 defines two bits in six octets. Bit 47 of a 48 bit
value is the least significant, so the masks are `T = 0x01` and
`S = 0x02`.

**T does not mean stop.** Section 7.3, verbatim: "T Terminal Action (bit
47): When this bit is set, the traffic filtering engine will evaluate any
subsequent Flow Specifications (as defined by the ordering procedure
Section 5.1). If not set, the evaluation of the traffic filters stops
when this Flow Specification is evaluated."

So set means carry on to the next rule and clear means stop at this one,
which is the reverse of what the name suggests. In bgp4r that is
`terminal: true` and `terminal: false` respectively. Everything above
those two bits MUST be 0 on encode and ignored on decode.

### Traffic rate

The 2 octet id "can be assigned from a 2-octet AS number", is "purely
informational" and "SHOULD NOT be interpreted by the implementation".
The rate is an IEEE float. A rate of 0 means discard everything. On
encode it MUST NOT be negative, and on decode a negative value MUST be
treated as zero, which is also discard everything.

### The IPv6 action, RFC 8956 section 6.1

`rt-redirect-ipv6`, **type 0x000d**, "the same encoding as the
IPv6-Address-Specific Route-Target Extended Community (Section 2 of
[RFC5701])".

That community is **20 octets**, not the 8 of RFC 4360: two type octets,
sixteen address octets, two Local Administrator octets. Verified on
2026-10-30 against `Ipv6_extended_community`, which encodes
`0002` then the address then `0064` for a route target. So this belongs
in `ipv6_extended_communities.rb`, which carries attribute **25**.

## 9. VPN, SAFI 134

RFC 8955 section 8, Figure 7:

```
+--------------------------------+
| length (0xnn or 0xfnnn)        |
+--------------------------------+
| Route Distinguisher (8 octets) |
+--------------------------------+
|    NLRI value  (variable)      |
+--------------------------------+
```

"The NLRI length field shall include both the 8 octets of the Route
Distinguisher as well as the subsequent Flow Specification NLRI value."
Everything else is the same as the non-VPN form.

Two behavioural differences that are not encoding. Propagation is
controlled by Route Target import policy as in RFC 4364. And "Contrary
to the behavior specified for the non-VPN NLRI, Flow Specifications are
accepted by default, when received from remote PE routers."

## 10. What is not encoding or decoding

Three things in these documents change no octet. Do not read either RFC
as a pure wire format spec, and do not put any of this in an encoder.

* **Rule ordering.** RFC 8955 section 5.1 orders rules for a forwarding
  engine, by component type then by a type specific comparison, so that
  the order "does not depend on the arrival order of the Flow
  Specification via BGP". RFC 8956 section 4 reuses it "with new
  consideration for the IPv6 prefix offset": equal offsets compare as
  before, and "If the offsets are not equal, the lowest offset has
  precedence". Both RFCs print Python for it in their appendices.
* **Validation against unicast routing.** RFC 8955 section 6: a flow
  spec over SAFI 133 is validated against routes over SAFI 1, and over
  SAFI 134 against SAFI 128, with three conditions a, b and c on the
  destination prefix and the originator. RFC 8956 section 5 changes item
  (a) to read "A destination prefix component with offset=0 is embedded
  in the Flow Specification".
* **Error handling.** RFC 8955 section 10 defers to RFC 7606 and RFC
  4760, and adds that a malformed action community, in the sense of RFC
  7606 section 7.14, is one "that cannot be decoded according to Section
  7 of this document".

## 11. Where bgp4r stands

Measured on 2026-10-30. `CLAUDE.md` under "Breadth, the one SAFI lever"
has the plan and the current status; this is only the shape.

| Piece | State |
|---|---|
| the twelve IPv4 components, the seven IPv6 ones, and an unknown type | done, `bgp/nlris/flow_spec_component.rb` |
| the two operator octets | done, with the reserved bits kept |
| the NLRI itself, the length framing, the RD for SAFI 134 | done, `bgp/nlris/flow_spec.rb` |
| the framing in `mp_reach.rb` and `mp_unreach.rb`, and the two gates | done, so a flow spec UPDATE reads and writes |
| a zero length next hop on encode | nothing to do: `Mp_reach#encode` writes `@nexthops.size`, which is 0 with no `:nexthop` |
| ignoring a next hop on receive | done: it used to raise, so the rule inside was never read |
| the receive side checks in `validation.rb` | not started |
| the seven RFC 8955 section 7 actions | already there, predating this work |
| `rt-redirect-ipv6`, type 0x000d | missing |
| the two redirect-to-IP communities of `draft-ietf-idr-flowspec-redirect-ip` | missing |
| any flow spec family in a RIB | deliberately out of scope, see `CLAUDE.md` |

## 12. How this document is kept true

`test/unit/flow_spec_doc_test.rb` asserts the claims here that a test
can reach: every component type number, every operator mask, the
fragment bits, the traffic-action masks, the action code points, the
20 octet IPv6 community, every vector in section 7 above, the section
4.1 length encoding including the 239 and 240 examples, and the
erratum citation. It also checks that `CLAUDE.md` still points here,
and that the two claims pointing into the source are still true: that
the parse loops slice with the prefix rule, and that
`rt-redirect-ipv6` is still missing.

What it cannot assert is the prose. That is the half that drifted in
`docs/to-hash-round-trips.md`, so keep the prose to what the RFCs say
and attribute anything else. Every quotation above is verbatim from the
document it names.
