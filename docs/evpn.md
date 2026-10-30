# EVPN on the wire

RFC 7432 and six more RFCs, as much as is needed to write the encoding
and decoding. Read this before touching `bgp/nlris/evpn.rb` or
`bgp/nlris/evpn_route.rb`, before changing how `mp_reach.rb` and
`mp_unreach.rb` frame an NLRI, and before adding a route type or one of
the EVPN extended communities.

Its load-bearing claims are asserted by `test/unit/evpn_doc_test.rb`,
because a claim nothing checks reads as verified. The route type table
in section 3 is **discovered** from the library rather than compared
against a list, so a route type class cannot join the library without
this document being told.

Every section number here was read in the RFC text. The eleven RFCs were
attached to the session on 2026-10-30 rather than fetched, because the
fetch tool caps quoted material and so will not give back a figure.

## 1. Where it sits

EVPN is AFI 25 (L2VPN) with SAFI 70, carried in MP_REACH_NLRI and
MP_UNREACH_NLRI (RFC 4760 sections 3 and 4). There is no RFC 4271
section 4.3 form: the family exists only inside those two attributes.

Seven RFCs matter for the octets:

| RFC | What it gives |
|---|---|
| 7432 | the NLRI framing, the ESI, route types 1 to 4, four extended communities |
| 9136 | route type 5, the IP Prefix route |
| 9251 | route types 6, 7 and 8, and the Multicast Flags community |
| 9572 | route types 9, 10 and 11 |
| 8214 | the EVPN layer 2 attributes community |
| 8584 | the DF Election community |
| 9135, 9047, 9722, 9785 | further communities and procedures |

## 2. The NLRI framing

RFC 7432 section 7:

```
+-----------------------------------+
|    Route Type (1 octet)           |
+-----------------------------------+
|     Length (1 octet)              |
+-----------------------------------+
| Route Type specific (variable)    |
+-----------------------------------+
```

The Length is **in octets** and counts the body alone, not itself and
not the Route Type octet. So one NLRI occupies `2 + Length` octets.

**One NLRI holds one route, not a list.** This is where the family
differs from flow spec, where one NLRI is a list of components under a
single length. Several EVPN NLRIs sit one after another in the
attribute, each framed by its own two octets.

**The NLRI owns its framing, and `Evpn.nlri_size` is how.** A prefix
family's length is in bits and one octet wide, so `Mp_reach#parse` has
always worked out how many octets to slice with `(blen+7)/8+1`. That
arithmetic is wrong here three times over: the length is in octets, it
excludes itself, and it sits behind a type octet. So the two parse loops
ask `MpReachCommon::ClassMethods#nlri_size`, which the flow spec wiring
added, and that defers to `Evpn.nlri_size` for SAFI 70. `nlri_size`
answers nil for octets too short to frame, so a loop can stop and let
the leftover raise, which is how an attribute bgp4r cannot read still
becomes an `Attr::Raw` with an `Attr::Gap`.

**It needs no AFI, where flow spec did.** RFC 8956 section 8.1.2 gives
flow spec component type 13 one meaning for IPv4 and another for IPv6,
so `Flow_spec` had to be told which family it was parsing. Nothing in
EVPN is ambiguous that way: route type 5's Length is 34 for IPv4 and 58
for IPv6, and every other variable width address is length prefixed. So
there is no `Flow_spec::COMPONENTS[afi]` counterpart here.

**The framing is recursive and still self delimiting.** RFC 9572 section
3.3 makes route type 11's Route Key "the NLRI of the route for which
this Leaf A-D route is generated", and its terminology section says a
Leaf A-D route "embeds the entire NLRI of the triggering PMSI A-D
route". Entire, so Route Type and Length included, so a Route Key is
read by the same class and its extent comes from its own Length octet.
No outer arithmetic is needed for the variable field that precedes a
length-prefixed address.

## 3. The eleven route types

RFC 9572 section 3 states the count from inside the RFC series rather
than from the registry: its Table 1 lists the eight already defined
across RFC 7432, RFC 9136 and RFC 9251, and its Table 2 adds three.

| Type | Name | Reference | In bgp4r |
|---|---|---|---|
| 1 | Ethernet Auto-discovery | RFC 7432 section 7.1 | yes |
| 2 | MAC/IP Advertisement | RFC 7432 section 7.2 | yes |
| 3 | Inclusive Multicast Ethernet Tag | RFC 7432 section 7.3 | yes |
| 4 | Ethernet Segment | RFC 7432 section 7.4 | yes |
| 5 | IP Prefix | RFC 9136 section 3.1 | yes |
| 6 | Selective Multicast Ethernet Tag | RFC 9251 section 9.1 | no |
| 7 | Multicast Membership Report Synch | RFC 9251 section 9.2 | no |
| 8 | Multicast Leave Synch | RFC 9251 section 9.3 | no |
| 9 | Per-Region I-PMSI A-D | RFC 9572 section 3.1 | no |
| 10 | S-PMSI A-D | RFC 9572 section 3.2 | no |
| 11 | Leaf A-D | RFC 9572 section 3.3 | no |

**Route types 1 to 5 are implemented, which is the core set every EVPN
implementation has; types 6 to 11 still read back as an `Evpn::Unknown`
that replays byte for byte.** The "In bgp4r" column is checked against
`Evpn::ROUTES` by the doc test, so it cannot drift.

### Types 1 and 4, the RD plus ESI pair

Both open with a Route Distinguisher and an Ethernet Segment Identifier,
which is why they were taken together.

Route type 1, section 7.1, is **fixed at 25 octets**: RD (8), ESI (10),
Ethernet Tag ID (4), MPLS Label (3).

Route type 4, section 7.4, is **23 octets with an IPv4 address and 35
with an IPv6 one**: RD (8), ESI (10), IP Address Length (1), Originating
Router's IP Address (4 or 16). Section 7.4 ends "The IP address length
is in bits", which is why that field is an `Addr`.

**`BGP::Label` is reused for the MPLS Label rather than reimplemented.**
Section 7.1 says only "MPLS Label (3 octets)" and describes no internal
layout. `Label` already writes a 20-bit label in the top 20 bits of
three octets, which is what GoBGP and FRR read back, and it keeps the
three bits below it and the low bit, so an unusual value replays. Its
hash keys `:label` and `:exp` are merged flat into the route's hash,
since neither collides with a field of the route.

**A route type is kept only if it can give its own octets back.** Both
layouts are fixed width, and nothing in the framing guarantees the
Length agrees with them, so a body is parsed on a copy and the result
accepted only when its `encode` matches what it was given. A body that
fails that falls back to `Evpn::Unknown`, which keeps the octets whole.
That means a route type number the library does implement can still read
back as Unknown, which looks odd and is the honest answer: the octets
cannot be represented as these fields, and keeping them beats inventing
the zeros a short body did not carry. `declared_len` still records the
Length that lied. This is the same rule `Flow_spec` applies to its
components, and for the same reason.

**Route key processing is not implemented and is not a gap here.**
Section 7.1 says the MPLS Label "is to be treated as a route attribute
as opposed to being part of the route", and section 7.4 names the three
fields that are part of its prefix. That distinction matters to a RIB,
and no EVPN route goes in a RIB by the recorded decision.

### Types 2 and 3

Route type 3, section 7.3, is **17 octets with an IPv4 address and 29
with an IPv6 one**: RD (8), Ethernet Tag ID (4), IP Address Length (1),
Originating Router's IP Address (4 or 16). It is **the only one of the
five with no Ethernet Segment Identifier**, which is worth saying because
every other RFC 7432 and RFC 9136 route type has one and a reader will
look for it.

Route type 2, section 7.2, is the largest layout in the family and the
only one variable in **two independent ways**: RD (8), ESI (10),
Ethernet Tag ID (4), MAC Address Length (1), MAC Address (6), IP Address
Length (1), IP Address (0, 4 or 16), MPLS Label1 (3), MPLS Label2 (0 or
3).

**The field rules for it are in section 14, not section 7.2.** That is
where to look, and all three matter:

* the MAC: "The MAC Address Length field is in bits, and it is set to
  48. MAC address length values other than 48 bits are outside the scope
  of this document." Outside the scope is **not** an error, which is
  exactly why `Mac_addr` echoes any length and still keeps its 6 octets.
* the IP: "The IP Address field is optional. By default, the IP Address
  Length field is set to 0, and the IP Address field is omitted from the
  route", and when present it "is set to 32 or 128 bits".
* Label2: "The MPLS Label2 field is an optional field. If it is present,
  then it is encoded as 3 octets, where the high-order 20 bits contain
  the label value."

**So six lengths are possible, and all six are distinct**: 33, 36, 37,
40, 49 and 52. That is what lets section 14 say "The Length field of the
EVPN NLRI ... is sufficient to determine whether an IP address is encoded
in this route and, if so, whether the encoded IP address is IPv4 or
IPv6."

bgp4r does **not** use the outer Length for it. The IP Address Length
field is the in-band discriminator and `Addr` reads it directly, which is
simpler and is what the octets themselves say. The two can only disagree
on a malformed route, and the encode-matches rule catches that by falling
back to `Unknown`.

**Label2 is decided by what is left**, which is sound because the body is
bounded: `Evpn` slices exactly Length octets and hands them to the route.
Fewer than three octets left is not a Label2, and not an error at that
level either; `encode` then fails to reproduce the body and the NLRI
falls back to `Unknown`.

**The two labels are named rather than merged flat, and that differs from
route type 1 on purpose.** One label can merge its own `:label` and
`:exp` keys into the route's hash because nothing collides, which is what
type 1 does. Two cannot, so each rides under `:label1` and `:label2`
holding `Label`'s own hash. `:label2` appears only when there is one.

## 4. The primitives

Four shapes carry every field in the eleven layouts that is not an `Rd`
or a `Label`. Reading all eleven together is what shows that; one RFC at
a time shows eleven layouts.

| Primitive | Width | Route types |
|---|---|---|
| `Esi` | 10 octets | 1, 2, 4, 7, 8 |
| `Ethernet_tag_id` | 4 octets | all but 4 and 11 |
| `Mac_addr` | length plus 6 octets | 2 |
| `Addr` | length plus 0, 4 or 16 octets | 2, 3, 4, 5, and the triple in 6, 7, 8, 10, 11 |

RFC 9251 calls the third member of its address triple "Originator
Router" and RFC 9572 calls it "Originator's Addr". They are one shape
under two names, so there is one class and not two.

### The ESI

RFC 7432 section 5: "An ESI is encoded as a 10-octet integer in line
format with the most significant octet sent first." The first octet is a
Type that "specifies the format of the remaining 9 octets (ESI Value)",
and six types are defined, 0x00 to 0x05.

Two values are reserved by that section: "ESI 0 denotes a single-homed
site", and "ESI {0xFF} (repeated 10 times) is known as MAX-ESI and is
reserved".

### Every length field in this family is in bits

This is the detail to get right, because it is the one memory reverses.

* RFC 7432 section 7.2: "Both the IP and MAC address lengths are in
  bits."
* RFC 7432 section 7.3 and section 7.4 each say "The IP address length
  is in bits" of their own field.
* RFC 9251 says it of all three lengths, in each of sections 9.1, 9.2
  and 9.3.
* RFC 9136 section 3.1: the IP Prefix Length "specifies the number of
  bits in the prefix", 0 to 32 for IPv4 and 0 to 128 for IPv6.

**RFC 9572 is the one that does not say**, and that is recorded rather
than guessed. It has no "in bits" sentence anywhere, and for route type
10 it says only that the route is "identical to the S-PMSI A-D route as
defined in [RFC7117]" apart from two added fields, so the units are
RFC 7117's. **That RFC has not been read here.** `Sized` takes the bit
count either way, so the question belongs to route types 10 and 11 and
is open until part 7 reads RFC 7117.

### The MAC and the IP disagree about what a length means

They sit on consecutive lines of the same figure and they are not the
same shape.

RFC 7432 section 7.2 gives the MAC Address as "(6 octets)" flat, and the
IP Address as "(0, 4, or 16 octets)". Both lengths are in bits. So:

* `Addr` takes `(bits + 7) / 8` octets. Its width follows its length,
  and a length of 0 is the absent field, which route type 2 needs for a
  MAC advertised with no IP.
* `Mac_addr` always takes 6. A length other than 48 is read and echoed
  and does not change the width, because the figure says the field is 6
  octets.

`Sized#parse` therefore does **not** infer its own width: it is told,
and `Mac_addr` overrides `octets_for`. A route type that wants either
rule asks for it.

## 5. Keep and echo

Conventions records the rule and the two existing instances,
`Traffic_action` and `Prefix_entry`. RFC 9251 brings two more, and
neither is new work in kind.

* Route types 6, 7 and 8 carry a Flags octet laid out
  `| reserved |IE|v3|v2|v1|`, so `DEFINED_BITS` is `0x0f` and the hash
  gains a `:bits` entry only when a reserved bit arrived set.
* Route type 8 additionally has a **4-octet Reserved field**, larger
  than any reserved field bgp4r keeps today.

Both arrive with part 6. Conventions' note that the keep-and-echo rule
is recent applies: these have simply not been reached yet.

### Type 5, the one fixed-length layout

RFC 9136 section 3.1 states it outright: "The Length field of the BGP
EVPN NLRI for an EVPN IP Prefix route MUST be either 34 (if IPv4
addresses are carried) or 58 (if IPv6 addresses are carried)."

**Two things make this layout unlike every other route type, and both
are easy to get wrong.**

First, the IP Prefix Length octet is a **prefix length and not a field
width**. Section 3.1: it "can be set to a value between 0 and 32 (bits)
for IPv4 and between 0 and 128 for IPv6, and it specifies the number of
bits in the prefix", while "The IP prefix is a 4- or 16-octet field". So
the prefix is **not** packed down to its length the way `Prefix` packs
one: 10.0.0.0/8 still occupies four whole octets. `Addr` is therefore
wrong here, because its width follows its length.

Second, the **GW IP Address has no length octet at all**. Section 3.1
calls it "a 4- or 16-octet field (IPv4 or IPv6)" and nothing precedes
it, so it is raw octets. It "MUST be all bytes zero if it is not used as
an Overlay Index", which is what `Ip_prefix_route.new` defaults to.

**So the family comes from the body's own size**, 34 or 58. That is the
same information the outer Length carries, available locally, and it is
the one place in the family where there is no in-band discriminator to
prefer instead. A body that is neither size is read as IPv4, will not
reproduce its octets, and falls back to `Unknown`.

**Three of RFC 9136's rules are receive-side and belong to part 9, not
here.** All three are stated as RFC 7606 treat-as-withdraw, so they are
error handling rather than policy, and none changes an octet:

* section 3.1: "If the received MPLS label value is zero, the route MUST
  contain an Overlay Index ... If the received label is zero and the
  route does not contain an Overlay Index, it MUST be 'treat as
  withdraw'".
* section 3.2: the ESI and the GW IP "MUST NOT both be non-zero at the
  same time. A route containing a non-zero GW IP and a non-zero ESI (at
  the same time) SHOULD be treat as withdraw".
* section 3.2: "A route where ESI, GW IP, MAC, and Label are all zero at
  the same time SHOULD be treat as withdraw."

Note the complication before part 9 starts on them: the third reads the
**EVPN Router's MAC Extended Community**, which is a different path
attribute, so it is not a check `validation.rb` can make from the
MP_REACH octets alone. Two of the three are SHOULD rather than MUST.

**Route key, for the record and not for implementing**: section 3.1 says
"The RD, Ethernet Tag ID, IP prefix length, and IP prefix are part of
the route key used by BGP to compare routes. The rest of the fields are
not part of the route key." That matters to a RIB, and no EVPN route
goes in one.

## 6. Route type 5 is the one fixed-length layout

RFC 9136 section 3.1 gives two figures and fixes the Length field:
"MUST be either 34 (if IPv4 addresses are carried) or 58 (if IPv6
addresses are carried)". The arithmetic agrees both ways:

* IPv4: 8 + 10 + 4 + 1 + 4 + 4 + 3 = 34
* IPv6: 8 + 10 + 4 + 1 + 16 + 16 + 3 = 58

So the Length alone says which family, which is why this family needs no
AFI input. Note that the IP Prefix field is **fixed width**, 4 or 16
octets, and is not truncated to the prefix length the way `Prefix`
packs its octets.

## 7. The extended communities

bgp4r needs **eleven** added, not ten, and the extra one is the reason
to count carefully.

Ten are EVPN sub-types under type 0x06, each with an RFC. Three more of
the fourteen in that registry cite only drafts and one is Reserved, so
those are out.

**The eleventh is not an EVPN sub-type at all.** RFC 7432 section 7.8
puts the Default Gateway community at **type 0x03 sub-type 0x0d**, a
Transitive Opaque community. It is invisible to anyone counting only the
0x06 registry, which is how the figure of fourteen in `CLAUDE.md` came
to be one short.

bgp4r registers four of the 0x06 sub-types today, 0x00 to 0x03, and
three Opaque ones, `[0x03, 0x00]` Origin Validation State,
`[0x03, 0x0b]` Color and `[0x03, 0x0c]` Encapsulation. Sub-type 0x0d is
not among them, so Default Gateway is the one missing and the Opaque
type itself is already reached. **An earlier draft of this document said
bgp4r registered no 0x03 sub-types at all, which was wrong**, and the
only reason it did not ship is that the doc test printed `FACTORY`'s
keys rather than taking the claim on trust. Same failure as a wrong RFC
citation: it would have read as verified.

These arrive with part 8.

## 8. Nothing validates on the way out

Per Conventions. Any route type number, any Length, any body, any ESI
type, any bit count against any number of octets, including a Length
that disagrees with the octets it came with. A Length that lies is kept
in `declared_len` and written back, so a malformed capture replays byte
for byte.

The receive side checks go in `bgp/path_attributes/validation.rb` and
nowhere else, and arrive with part 9. They will reuse `Evpn.nlri_size`
and `Evpn::ROUTES` rather than copying either, the way
`flow_spec_finding` reuses `Flow_spec.nlri_size` and
`Flow_spec::COMPONENTS`, so a route type class added to the library
stops being unknown to validation the same day.

The two constructor refusals that do exist are the one Conventions
allows: an `Esi` built from an Integer of 80 bits or more, and an
`Ethernet_tag_id` of more than 32 bits, because the alternative is
silently sending a different value. Both have an octet level route that
stays open.

## 9. Interoperability

Not measured yet. It arrives with part 10, against GoBGP and FRR, as the
twin of `flow_spec_gobgp_test.rb` and `flow_spec_frr_test.rb`. Nothing
should be written here until a test asserts it: the flow spec table in
`docs/flow-spec.md` section 12 names the test that asserts each row for
exactly that reason, and the hand-measured conformance table that
preceded it had two wrong rows that read as verified for months.

## 10. What the doc test asserts

`test/unit/evpn_doc_test.rb` keeps this document and the library in
step. It checks the framing constants, the primitive widths, the
bits-not-octets claims, the route type 5 arithmetic, the two refusals,
and the extended community counts.

The route type table in section 3 is **discovered**, not listed: the
test enumerates the `Evpn::Route` subclasses the library actually
defines, checks each has a row whose "In bgp4r" cell says yes, and
checks every other row says no. It also checks the discovered set agrees
with `Evpn::ROUTES`, so a class added to `evpn_route.rb` and forgotten
in the table, or added to the table and forgotten in `ROUTES`, fails the
suite either way.

That shape came from a sabotage on the flow spec guard: a fourteenth
component type was added and the first version of the guard passed,
because it compared the document against a list in the test rather than
against the library.
