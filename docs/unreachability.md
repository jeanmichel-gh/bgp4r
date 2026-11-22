# Unreachability Information

bgp4r carries two drafts that let a BGP speaker report a prefix as
unreachable, without changing any RIB or FIB:

| Draft | Family | Status in IANA |
|---|---|---|
| `draft-tantsura-idr-unreachability-safi-06` | AFI 1 or 2, SAFI 81 | SAFI 81 assigned |
| `draft-tantsura-bess-evpn-unreachability-02` | AFI 25, SAFI 70, route type 254 | none; 254 is provisional, the draft says TBD1 |

The design, with its decisions and review notes on both drafts, is
`docs/design/unreachability.md`.

## On the wire

A SAFI 81 NLRI is a 2-octet NLRI Length, a prefix as RFC 4271 encodes
one, then one or more Reporter TLVs. A withdrawal is the prefix alone.
There is no next hop.

The EVPN route is route type 5's fields with an Address Family octet
after the Ethernet Tag ID, then the same Reporter TLVs. ESI, gateway
and label are zero. Its Length is one octet, so a route holds at most
8 reporters with a reason and a timestamp under IPv4, and 7 under IPv6.

A Reporter TLV is a type of 1, a 2-octet Length, the reporter's BGP
Identifier and 4-octet AS, then sub-TLVs: a Reason Code (type 1), a
Timestamp in Unix seconds (type 2), and for EVPN an EVI (type 3).

```ruby
require 'bgp4r'
include BGP

u = Unreachability.new('192.0.2.0/24',
      Unreachability::Reporter.new('198.51.100.1', 65001,
        Unreachability::Reason_code.new(3), Unreachability::Timestamp.new(1733789400)))
u.to_shex  # => "001f18c00002010018c63364010000fde9010002000302000800000000675786d8"
Mp_reach.new(:safi => 81, :nlris => [u])
```

That hex is the draft's section 3.6.1 example. The classes build four
ways, as every class here does (`docs/building-objects.md`), and nothing
validates on the way out: a /33, no reporter, or a Length that lies all
build and replay.

## What a receiver checks

`Attr::Check` applies section 5 of the SAFI draft and section 4.11 of
the EVPN draft, in their order:

| What | Action |
|---|---|
| an NLRI Length past the attribute, a prefix length past its family, an EVPN Address Family not 1 or 2 | session reset |
| an announcement with no Reporter TLV, a withdrawal with one, a non-zero EVPN ESI, gateway or label | treat-as-withdraw |
| a malformed or duplicate Reporter TLV or sub-TLV, more than 50 reporters | the TLV is discarded and the route kept; a finding with no action |

An announcement with no reporter is treat-as-withdraw, as the SAFI
draft's section 5.2 says, though its section 5.1 would make it a reset.

## bgp4rd

A session carries reports when both sides offer the family:

```yaml
capabilities: [as4_byte, mbgp_ipv4_unreachability_information,
               mbgp_ipv6_unreachability_information, mbgp_l2vpn_evpn]
```

What this speaker reports is its `unreachability:` block, with its own
router ID and AS as the one reporter:

```yaml
unreachability:
  - prefix: 192.0.2.0/24
    reason: rpki_invalid
  - prefix: 198.51.100.0/24
    reason: vtep_unreachable
    evpn: { rd: '10.255.0.1:100', route_targets: ['65000:100'] }
```

The block is live. `unreach.report` and `unreach.clear` change one
entry as a commit:

```
cli unreach.report '{"prefix":"192.0.2.0/24","reason":"rpki_invalid"}'
cli unreach.clear '{"prefix":"192.0.2.0/24"}'
```

What it receives is kept per peer, outside the RIB, and goes when the
session does. A reporter AS that is not in the UPDATE's AS_PATH is
named in the row and logged. `show.unreachability` lists both sides;
the shell prints them in FRR's words:

```
show bgp ipv4 unreachability
show bgp ipv6 unreachability 2001:db8::/32
show bgp l2vpn evpn unreachability
```

Each report that arrives, goes, is sent or is cleared is an event of
kind `unreachability`.

## Generating reports

`bgp/gen` and `bgp4r-sim` take the families `unreachability` and
`evpn_unreachability` (`docs/route-generation.md` section 6):

```ruby
BGP::Gen.new('family' => 'unreachability', 'start' => '10.0.0.0/24', 'count' => 1000,
             'reporters' => 3, 'reason' => { 'cycle' => [3, 9] }, 'timestamp' => 1733789400)
```

## Not built

* **Passing a report on.** bgp4rd reports and collects. Propagation,
  with the decision process and aggregation of reporters, needs its own
  spec.
* **Graceful Restart's stale marking**, which bgp4rd has for no family.
* **AFI/SAFI disable.** An UPDATE with a structural error is ignored
  and the session kept.
* **The Enhanced Unreachability Information capability** (code TBD2),
  until IANA assigns it.

## Interoperability

**None is tested, by the owner's decision (2026-11-22): no router in a
release has either family, and a lab is not built against an
unreleased one.** FRR has SAFI 81 on its master branch only
(FRRouting/frr#21451, merged 2026-06-30), and nothing implements the
EVPN route type. Measured on 2026-11-22: neither file is in FRR
10.7.0 or 10.7.1, and no GoBGP pull request names either. When a release carries SAFI
81, the lab of the design's pull request 5 is the next step, and the
faults in `Fault::UNREACHABILITY` join `Fault::CATALOG` once that lab
has measured them.

The tests are the drafts' own examples, octet for octet, and two bgp4rd
on loopback: `ruby test/run_feature.rb unreachability`.
