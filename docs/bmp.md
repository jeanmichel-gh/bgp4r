# BMP: the BGP Monitoring Protocol

A monitored router sends a station what its BGP sessions carry: who it
is, each session that comes up or goes down, each peer's routes, and
counters (RFC 7854). RFC 9069 adds the router's own Loc-RIB as a peer
of its own. Nothing goes from the station to the router (RFC 7854
section 3.2).

This is P8's pull request 8 in `docs/design/bgp-operations.md`, in
three parts, all built and described here: 8a, the codec; 8b, a station
in Ruby (`bgp4r-bmp`) with its JSON lines; and 8c, BMP in bgp4rd.

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
`docs/protocol-testing.md` has the list, and what `bgp4r-bmp` does with
each.

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
  withdrawals. bgpd had no `soft-reconfiguration inbound`. Section 6
  sets it and measures again: the pre-policy routes come, and both
  views' AS_PATHs start with 65002.
- **No Termination** when the target was removed with `no bmp targets`.

## 5. The station, `bgp4r-bmp`

`bgp4r-bmp` listens for monitored routers, or dials one, and reads every
message. It writes one JSON line for each, and keeps each router's peers
and their routes for its HTTP API. Nothing goes back to a router
(section 3.2).

```
bgp4r-bmp --listen 0.0.0.0:5000 --api 0.0.0.0:8080 > bmp.jsonl
```

| Option | What |
|---|---|
| `--listen HOST:PORT` | where routers dial in; 0.0.0.0:5000 by default. RFC 7854 names no port and IANA has none, so 5000 is our choice |
| `--connect HOST:PORT` | dial a router that listens (FRR's `bmp listener`), again after each session, 30 s doubling to 720 s between (section 3.2); may repeat |
| `--no-listen` | dial only |
| `--api HOST:PORT` | the HTTP API, 127.0.0.1:8080 by default |
| `--lines FILE` | the JSON lines; standard output by default |
| `-l FILE` | the log; standard error by default |

It ships with bgp4r, beside `bgp4r-sim` and `bgp4r-rtr`, and so is in
the `lab-node` image.

**What it does with what comes.** Each message is checked
(`Bmp::Validation`, section 2) and read with bgp4r's codec, a Route
Monitoring with its peer's Peer Up (section 1). The findings go in the
message's line; a finding that is not to be ignored is an event too.

- **A Route Monitoring** goes in its peer's pre-policy view when L is
  clear, the post-policy view when L is set (RFC 7854 section 5), or the
  Loc-RIB when the peer type is 3 (RFC 9069). An UPDATE's NLRI and
  MP_REACH_NLRI add routes, its withdrawn routes and MP_UNREACH_NLRI
  remove them. A route is known by its AFI, SAFI and NLRI without its
  labels, since a withdrawal carries a Compatibility field where the
  label was. An empty UPDATE, or one with only an empty
  MP_UNREACH_NLRI, is that family's End-of-RIB (RFC 4724 section 2).
- **A Peer Up or a Peer Down** empties the peer's three views, and sets
  it up or down.
- **A Stats Report** keeps the last value of each stat, by type and
  family.
- **A message before the Initiation** is read, with a `no_initiation`
  finding (section 3.3: the router "MUST begin by sending an
  Initiation message").
- **A message the codec cannot read** is a line of type `undecoded`,
  with its octets in `hex` and a `decode` finding. The session goes on.
- **A Termination** closes the session, as section 4.5 says the station
  MUST.
- **A version other than 3, or a Message Length shorter than the header
  or past 1 MB**, closes the session after a line of type `undecoded`:
  section 4.1 defines the header for version 3 only, so nothing past it
  can be framed. The line keeps the first 256 octets.
- **When a session ends**, for whatever reason, its peers and routes go
  with it. The router sends them again in the next session's dump
  (section 3.3).

### The JSON lines

**These lines are a contract.** routescope will read them as a source
of routes (`docs/design/bgp-operations.md`, answer 8). A change to them
is additive only: a new key or a new type, never a key renamed,
removed or given another meaning. `test/unit/bmp/lines_doc_test.rb`
holds this section to the station's output: every example below is a
line the station writes for FRR's capture of section 4, and every key
a line has is in this table.

| Key | What |
|---|---|
| `seq` | the line's number, from 1, across every router |
| `time` | when the station read the message, ISO 8601 in UTC with milliseconds |
| `router` | the router's session, as its address and port: `192.0.2.1:40000`, `[2001:db8::1]:40000` |
| `sys_name` | the sysName of the session's Initiation, or `null` before one |
| `type` | the message's type: `route_monitoring`, `stats_report`, `peer_down`, `peer_up`, `initiation`, `termination`, `route_mirroring`, `unknown`; or `undecoded`; or the station's own `connected` and `closed` |
| `message` | the message as the codec's `to_hash` gives it, without its outer key; absent for `undecoded`, `connected` and `closed` |
| `findings` | each finding, `{"name": ..., "detail": ...}`; `[]` for none |
| `hex` | an `undecoded` message's octets |
| `reason` | why a `closed` session closed: `end of stream`, `termination`, `version 0`, `Message Length 3`, `station stopped`, or the socket's error |

The session begins:

```json
{
  "seq": 1,
  "time": "2026-11-27T10:00:00.000Z",
  "router": "192.0.2.1:40000",
  "sys_name": null,
  "type": "connected",
  "findings": []
}
```

The Initiation:

```json
{
  "seq": 2,
  "time": "2026-11-27T10:00:00.000Z",
  "router": "192.0.2.1:40000",
  "sys_name": "bgp4r-lab-frr",
  "type": "initiation",
  "message": {
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
  },
  "findings": []
}
```

A Loc-RIB Route Monitoring with the L flag, and its finding:

```json
{
  "seq": 6,
  "time": "2026-11-27T10:00:00.000Z",
  "router": "192.0.2.1:40000",
  "sys_name": "bgp4r-lab-frr",
  "type": "route_monitoring",
  "message": {
    "version": 3,
    "peer": {
      "peer_type": 3,
      "flags": 64,
      "distinguisher": "0000000000000000",
      "address": "0.0.0.0",
      "asn": 65002,
      "bgp_id": "10.0.0.2",
      "seconds": 1795774908,
      "microseconds": 960858
    },
    "update": {
      "path_attributes": {
        "origin": "igp",
        "as_path": {
          "sequence": [
            65002
          ]
        },
        "next_hop": "0.0.0.0",
        "med": 0
      },
      "nlris": [
        "203.0.113.0/24"
      ]
    }
  },
  "findings": [
    {
      "name": "reserved_flags",
      "detail": "Peer Flags 0x40 for peer type 3"
    }
  ]
}
```

A post-policy Route Monitoring of the sim's peer:

```json
{
  "seq": 17,
  "time": "2026-11-27T10:00:00.000Z",
  "router": "192.0.2.1:40000",
  "sys_name": "bgp4r-lab-frr",
  "type": "route_monitoring",
  "message": {
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
  },
  "findings": []
}
```

The sim's Peer Down:

```json
{
  "seq": 39,
  "time": "2026-11-27T10:00:00.000Z",
  "router": "192.0.2.1:40000",
  "sys_name": "bgp4r-lab-frr",
  "type": "peer_down",
  "message": {
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
  },
  "findings": []
}
```

The session's end:

```json
{
  "seq": 44,
  "time": "2026-11-27T10:00:00.000Z",
  "router": "192.0.2.1:40000",
  "sys_name": "bgp4r-lab-frr",
  "type": "closed",
  "findings": [],
  "reason": "end of stream"
}
```

### The HTTP API

`bgp4r-sim`'s server (`docs/daemon.md`), with these paths. Each is a
GET; a station takes no actions, so a POST is refused.

| Path | What |
|---|---|
| `/api/status` | the version, the listening port, how many routers, peers and lines |
| `/api/routers` | each open session: sysName, sysDescr, when it began, messages, peers, findings by name |
| `/api/peers` | each peer of each router: who it is, up or down, the last Peer Down's reason, its routes by view, its End-of-RIBs, its stats; `?router=` |
| `/api/routes` | each route; `?router=` (the session, or its sysName), `?peer=` (an address), `?view=` (`pre_policy`, `post_policy`, `loc_rib`) |
| `/api/lines` | the last 10,000 JSON lines; `?since=N` for those after line N |
| `/api/events` | bgp4r's events, kind `bmp`: `connected`, `closed`, `peer_up`, `peer_down`, `end_of_rib`, `findings`; `?since=N` |

`/api/routes?view=loc_rib` after FRR's capture:

```json
{
  "routes": [
    {
      "router": "192.0.2.1:40000",
      "sys_name": "bgp4r-lab-frr",
      "peer": {
        "peer_type": 3,
        "distinguisher": "0000000000000000",
        "address": "0.0.0.0",
        "asn": 65002,
        "bgp_id": "10.0.0.2"
      },
      "view": "loc_rib",
      "afi": 1,
      "safi": 1,
      "nlri": {
        "prefix": "203.0.113.0/24"
      },
      "next_hop": "0.0.0.0",
      "path_attributes": {
        "origin": "igp",
        "as_path": {
          "sequence": [
            65002
          ]
        },
        "next_hop": "0.0.0.0",
        "med": 0
      }
    },
    {
      "router": "192.0.2.1:40000",
      "sys_name": "bgp4r-lab-frr",
      "peer": {
        "peer_type": 3,
        "distinguisher": "0000000000000000",
        "address": "0.0.0.0",
        "asn": 65002,
        "bgp_id": "10.0.0.2"
      },
      "view": "loc_rib",
      "afi": 1,
      "safi": 1,
      "nlri": {
        "prefix": "192.0.2.0/24"
      },
      "next_hop": "192.0.2.9",
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
      }
    }
  ]
}
```

A route's `next_hop` is MP_REACH_NLRI's first next hop, or NEXT_HOP's.
`path_attributes` leaves out the two MP attributes, whose NLRI are the
routes themselves.

## 6. FRR 10.5.1 to `bgp4r-bmp`

`test/functional/lab/bmp_frr_test.rb`, in CI's `lab frr`: FRR 10.5.1's
bgpd dials `bgp4r-bmp` with pre-policy, post-policy and Loc-RIB
monitoring and `soft-reconfiguration inbound` on its one neighbor. A
bgp4r-sim peer announces two routes, withdraws one and goes. Measured,
and asserted there:

- **The three views follow.** The Loc-RIB holds what `show bgp ipv4
  unicast json` holds, before and after the withdrawal; the pre-policy
  and post-policy views hold the sim's routes, with its next hop, MED
  and community.
- **The AS_PATH starts with 65002** in both views, FRR's own AS, where
  the sim sent `65001 65010` and FRR's table shows `65001 65010`. RFC
  7854 section 2 defines the pre-policy view as the Adj-RIB-In, which
  "contains unprocessed routing information that has been advertised
  to the local BGP speaker by its peers".
- **The sim's Peer Down has reason 4**, "The remote system closed the
  session without a notification message", and the station empties the sim's two views.
- **No Loc-RIB withdrawal when the sim goes.** FRR's table drops
  192.0.2.0/24, and three seconds later no Route Monitoring has
  withdrawn it from the Loc-RIB, so the station still holds it. RFC 9069
  section 5.4 says Route Monitoring messages "are also used to convey
  incremental Loc-RIB changes".
- **No findings** but the two section 4 lists, `reserved_flags` and
  `unknown_stat`.

bgp4rd's half of the interop is section 7.

## 7. BMP in bgp4rd

With a `bmp:` key, bgp4rd is a monitored router: it dials each station
and reports each peer of its global table to it.

```yaml
bmp:
  stations: [{ address: 10.0.0.9, port: 5000 }]   # bgp4rd dials each
  monitor: [pre_policy]            # the only one so far
  stats_interval: 60               # seconds between Stats Reports
  sys_name: r1                     # the Initiation's sysName; the host name by default
  sys_descr: lab r1                # its sysDescr; "bgp4r VERSION" by default
```

A station may also have a `retry`, the first wait in seconds after a
failed dial or a session that ended, doubling to 720 s. It is 30 s
without one, as RFC 7854 section 3.2 suggests. A bad key stops bgp4rd
at start, as any bad key does.

**What a station gets** (section 3.3):

1. An Initiation with sysDescr and sysName.
2. For each Established peer, a Peer Up with both OPENs, bgp4rd's and
   the peer's, and the session's addresses and ports. Then that peer's
   Adj-RIB-In, one Route Monitoring per route, and an End-of-RIB for
   each family the session negotiated.
3. Each UPDATE the peer sends afterwards, as a Route Monitoring.
4. A Peer Down when a session ends, with its reason (section 4.9).
5. Every `stats_interval` seconds, a Stats Report for each peer with
   three stats: the routes kept (type 7), and the UPDATEs and prefixes
   treated as withdraw (types 11 and 12, RFC 7606).
6. A Termination, reason 0, "Session administratively closed", when
   bgp4rd stops.

A station that connects late gets the same start, so the dump is the
routes as they are then. Everything is queued in one order under one
lock, so an UPDATE that arrives during a dump comes after it.
Whatever a station sends back is read and dropped (section 3.2).

**The Adj-RIB-In is pre-policy, as received.** bgp4rd keeps its own
copy of each peer's routes, outside the RIB, so `bmp:` needs no `rib:`.
An UPDATE that RFC 7606 treats as withdraw withdraws its routes from
that copy. The per-peer header has the L flag clear, V for an IPv6
peer, and A when the session's AS_PATH is two octets wide. Post-policy,
the Loc-RIB (RFC 9069) and Route Mirroring come later. So do a VRF's CE
sessions, which are not reported.

**The Peer Down reasons**. 1, 3 and 4 are measured over loopback in
`test/functional/bmp_daemon_test.rb`, and 2 is tested on its own in
`test/unit/daemon/bmp_test.rb`:

| What ended the session | Reason | Data |
|---|---|---|
| a NOTIFICATION bgp4rd sent, `peer.clear`'s Cease among them | 1 | that NOTIFICATION |
| a NOTIFICATION the peer sent | 3 | that NOTIFICATION |
| the connection, with no NOTIFICATION | 4 | none |
| bgp4rd, with no NOTIFICATION | 2 | FSM event 10, HoldTimer_Expires, or 2, ManualStop |

Whichever NOTIFICATION came first is used, as `Neighbor#down_cause`
does. Both kinds reach the monitor as bgp4r's `notification` events,
which come before the session goes down.

**`show.bmp`** lists the stations: where, `up` or `connecting`, the
sessions so far, the messages sent, since when, and the last error.
Each station up and down, and each peer reported up and down, is a
`bmp` event.

```json
{
  "rows": [
    {
      "station": "127.0.0.1:41841",
      "state": "up",
      "sessions": 1,
      "messages": 4,
      "connected_at": "2026-11-27T21:47:19Z",
      "last_error": null
    }
  ],
  "total": 1,
  "offset": 0,
  "limit": 500,
  "next_offset": null
}
```

**Beside FRR.** In `test/functional/lab/bmp_bgp4rd_frr_test.rb` (CI's
`lab frr`), bgp4rd and FRR 10.5.1 peer with one bgp4r-sim and report
to one `bgp4r-bmp`. The station's two pre-policy views of the sim hold
the same routes, with the same next hop, MED and community, after the
announcement and after a withdrawal. Both views empty with a Peer Down,
reason 4, when the sim goes. The AS_PATH differs. bgp4rd sends it as
received, `65001 65010`, and FRR puts its own AS first (section 6).
