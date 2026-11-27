# BMP: the BGP Monitoring Protocol

A monitored router sends a station what its BGP sessions carry: who it
is, each session that comes up or goes down, each peer's routes, and
counters (RFC 7854). RFC 9069 adds the router's own Loc-RIB as a peer
of its own. Nothing goes from the station to the router (RFC 7854
section 3.2).

This is P8's pull request 8 in `docs/design/bgp-operations.md`, in
three parts. 8a, the codec, is built and described here. 8b, a station
in Ruby (`bgp4r-bmp`) with its JSON lines, and 8c, BMP in bgp4rd, are
not built yet.

## 1. The messages

`require 'bgp/bmp'`, or `require 'bgp4r'`, which loads it. Each message
of RFC 7854 section 4 is a class in `BGP::Bmp`:

| Type | Class | Section | Body |
|---|---|---|---|
| 0 | `Route_monitoring` | 4.6, 5 | a per-peer header, a BGP UPDATE |
| 1 | `Stats_report` | 4.8, 7 | a per-peer header, a count, the stats |
| 2 | `Peer_down` | 4.9 | a per-peer header, a reason and its data |
| 3 | `Peer_up` | 4.10 | a per-peer header, the local address and both ports, both OPENs, Information TLVs |
| 4 | `Initiation` | 4.3 | Information TLVs |
| 5 | `Termination` | 4.5 | Information TLVs, the Reason among them |
| 6 | `Route_mirroring` | 4.7, 6 | a per-peer header, a BGP message and an Information code, as TLVs |

A type it does not know is an `Unknown`, kept whole: section 4.1, "A
BMP implementation MUST ignore unrecognized message types upon
receipt". Each is built four ways, as every codec in bgp4r is:

```ruby
BGP::Bmp::Initiation.new({ :type => 1, :string => 'FRRouting 10.5.1' }, { :type => 2, :string => 'r1' })
BGP::Bmp::Initiation.new(octets)          # from the wire
BGP::Bmp::Initiation.new(other)           # from another instance
BGP::Bmp::Initiation.new(msg.to_hash)     # from its own hash
```

`Bmp::Message.factory(octets)` picks the class from the Message Type.
`Bmp.slices(buffer)` takes whole messages off a stream, as octets, and
`Bmp.messages(buffer)` the same, parsed.

**The per-peer header**, `Bmp::Per_peer` (section 4.2): the peer type
(0 Global, 1 RD, 2 Local, 3 Loc-RIB), the flags, the Peer
Distinguisher as 16 hex digits, the address, the AS, the BGP ID and the
timestamp. `ipv6?`, `post_policy?` and `as2?` read V, L and A; for a
Loc-RIB peer, `filtered?` reads RFC 9069's F.

**The BGP messages inside are bgp4r's own**: a Route Monitoring's
`update` is a `BGP::Update`, a Peer Up's `sent_open` and
`received_open` are `BGP::Open`, a Peer Down's `notification` a
`BGP::Notification`. A Route Mirroring keeps its BGP message as octets,
since an errored one is what it is for, and `message` parses it.

**An UPDATE is read with the session it came on.** Its AS_PATH is two
or four octets wide, and add-path puts a Path Identifier before each
prefix (RFC 7911), and only the session says which. With nothing given,
the A flag says the width. A station gives a Route Monitoring the
session of that peer's Peer Up:

```ruby
up = BGP::Bmp::Message.factory(peer_up_octets)
rm = BGP::Bmp::Message.factory(route_monitoring_octets, up.session_info)
```

`Peer_up#session_info` is `BGP::Neighbor::Capabilities` of the two
OPENs, seen from the router: it sent one and received the other.

**Information TLVs**, as hashes: a String type as `:string`, the
Termination Reason as `:code`, anything else as `:hex`. **Stats**:
types 0 to 6 and 11 to 13 are 32-bit counters, 7 and 8 64-bit gauges,
9 and 10 an AFI, a SAFI and a gauge. A type it does not know, or data
of another length, is kept as `:hex` (section 4.8: "MUST ignore
unrecognized stat types ... and likewise MUST ignore unexpected data").

## 2. What a station finds

`Bmp::Validation.check(octets)` gives the findings of one message, each
a name and a detail. BMP has no error codes and nothing goes back to
the router, so a station logs or counts them:

| Name | What | Section |
|---|---|---|
| `short` | fewer octets than the header, the per-peer header or the fields need | 4.1, 4.2 |
| `version` | a version that is not 3; "Version 0 is reserved and MUST NOT be sent" | 4.1 |
| `length` | a Message Length, a TLV length or a Stat Len that does not fit | 4.1, 4.4, 4.8 |
| `unknown_type` | a Message Type it does not know; to be ignored | 4.1 |
| `peer_type` | a Peer Type it does not know | 4.2, RFC 9069 4.1 |
| `reserved_flags` | a reserved flag set; they "MUST be transmitted as 0" | 4.2, RFC 9069 4.2 |
| `loc_rib_address` | a Loc-RIB peer with a Peer Address, which is "Zero-filled" | RFC 9069 5.1 |
| `bgp` | the BGP message inside: its marker, its Length, its type | 4.6, 4.9, 4.10 |
| `no_stats`, `count` | no stats, or a Stats Count that is not the number of stats | 4.8 |
| `unknown_stat` | a stat type it does not know, or data of another length; to be ignored | 4.8 |
| `reason` | a Peer Down reason it does not know | 4.9 |
| `missing` | an Initiation without sysDescr or sysName, a Termination without a Reason | 4.3, 4.5 |
| `order` | a Route Mirroring's BGP Message TLV before the last | 4.7 |

`Finding#ignore?` is true for the two that sections 4.1 and 4.8 say to
pass over.

## 3. Faults

`BGP::Fault::BMP` holds what a router could send that a station has to
cope with. `Fault.bmp(name)` gives each message's octets, in order.
`docs/protocol-testing.md` has the list. The station that runs them
comes with 8b.

## 4. FRR 10.5.1's bgpd_bmp, read

Recorded on 2026-11-27 on ospflab: FRR 10.5.1's bgpd from Ubuntu's
package with `-M bmp`, dialing a Ruby listener that kept every octet,
with a bgp4r-sim peer that announced two routes, withdrew one and went
down. Its config, inside `router bgp`:

```
bmp targets t1
 bmp connect 127.0.0.1 port PORT min-retry 100 max-retry 1000
 bmp monitor ipv4 unicast pre-policy
 bmp monitor ipv4 unicast post-policy
 bmp monitor ipv4 unicast loc-rib
 bmp stats interval 1000
 bmp mirror
exit
```

The capture is `test/fixtures/bmp/frr-10.5.1.bin`, 42 messages: an
Initiation, two Peer Ups (the Loc-RIB's and the sim's), two Peer Downs,
eleven Route Monitorings, four Route Mirrorings and twenty-two
Statistics Reports. Each is read and written back byte for byte
(`test/unit/bmp/messages_test.rb`). The Initiation:

```json
{
  "initiation": {
    "version": 3,
    "information": [
      {
        "type": 1,
        "string": "FRRouting 10.5.1"
      },
      {
        "type": 2,
        "string": "bgp4r-lab-frr"
      }
    ]
  }
}
```

A post-policy Route Monitoring of the sim's peer (flags 64, L):

```json
{
  "route_monitoring": {
    "version": 3,
    "peer": {
      "peer_type": 0,
      "flags": 64,
      "distinguisher": "0000000000000000",
      "address": "127.0.0.1",
      "asn": 65001,
      "bgp_id": "10.0.0.1",
      "seconds": 1795774912,
      "microseconds": 960859
    },
    "update": {
      "path_attributes": {
        "origin": "igp",
        "as_path": {
          "sequence": [
            65002,
            65001,
            65010
          ]
        },
        "next_hop": "192.0.2.9",
        "med": 10,
        "communities": [
          "65001:1"
        ]
      },
      "nlris": [
        "192.0.2.0/24"
      ]
    }
  }
}
```

The Peer Down when the sim went, reason 4, no data:

```json
{
  "peer_down": {
    "version": 3,
    "peer": {
      "peer_type": 0,
      "flags": 0,
      "distinguisher": "0000000000000000",
      "address": "127.0.0.1",
      "asn": 65001,
      "bgp_id": "10.0.0.1",
      "seconds": 1795774918,
      "microseconds": 960859
    },
    "reason": 4
  }
}
```

What the capture shows, for 8b's station and interop to measure, not
read further here:

- **FRR sets Extended Length on a short AS_PATH.** RFC 4271 section
  4.3 allows it. bgp4r used to clear the bit when it encoded an
  attribute again, so FRR's UPDATEs did not come back byte for byte. An
  attribute read off the wire now keeps the length it came with; one
  built keeps the one its length needs.
- **A Loc-RIB Route Monitoring with the L flag set** (flags 0x40),
  where RFC 9069 section 4.2 defines only F for that peer type:
  `reserved_flags`.
- **Stat Type 65531**, from the experimental range, kept as `:hex`:
  `unknown_stat`.
- **A Peer Down for the sim before any Peer Up**, reason 2, FSM event
  0, as bgpd first saw the peer.
- **The post-policy AS_PATH starts with 65002**, bgpd's own AS, and
  the pre-policy Route Monitorings of the two announced routes are
  withdrawals. bgpd had no `soft-reconfiguration inbound`, which may be
  why. 8b's interop sets it and measures again.
- **No Termination** when the target was removed with `no bmp targets`.
