# RPKI: the RTR protocol

A router learns which AS may originate which prefix from an RPKI
cache, over the RPKI to Router protocol, RTR (RFC 8210, version 1, and
RFC 6810, version 0). Each record is a Validated ROA Payload, a VRP:
a prefix, a maximum length and an origin AS. RFC 6811's origin
validation reads them.

This is P8's pull request 7 in `docs/design/bgp-operations.md`, in
three parts. 7a, the codec, and 7b, a cache in Ruby (`bgp4r-rtr`), are
built and described here. 7c, origin validation in bgp4rd, is built in
parts: 7c1, the RTR client and each route's state, and 7c2, `invalid:
prefer_less` and `reject` and `mark_ibgp`, are described in section 5.
7c3, the fault matrix against bgp4rd and FRR and the interop test, is
section 6.

## 1. The PDUs

`require 'bgp/rtr'`, or `require 'bgp4r'`, which loads it. Each PDU of
RFC 8210 section 5 is a class in `BGP::Rtr`:

| Type | Class | Section | Fields |
|---|---|---|---|
| 0 | `Serial_notify` | 5.2 | `session_id`, `serial` |
| 1 | `Serial_query` | 5.3 | `session_id`, `serial` |
| 2 | `Reset_query` | 5.4 | none |
| 3 | `Cache_response` | 5.5 | `session_id` |
| 4 | `Ipv4_prefix` | 5.6 | `flags`, `prefix`, `max_length`, `asn` |
| 6 | `Ipv6_prefix` | 5.7 | the same |
| 7 | `End_of_data` | 5.8 | `session_id`, `serial`, `refresh`, `retry`, `expire` |
| 8 | `Cache_reset` | 5.9 | none |
| 9 | `Router_key` | 5.10 | `flags`, `ski`, `asn`, `spki` |
| 10 | `Error_report` | 5.11 | `code`, `pdu`, `text` |
| any other | `Unknown` | | the octets, kept whole |

Each is built four ways, and each way gives the same octets:

```ruby
v = Rtr::Ipv4_prefix.new('192.0.2.0/24', 28, 65001)   # prefix, max length, AS, announce = true
Rtr::Ipv4_prefix.new(v.encode)                         # from the wire
Rtr::Ipv4_prefix.new(v)                                # from another one
Rtr::Ipv4_prefix.new(v.to_hash)                        # from its own hash
v.to_shex
# "010400000000001401181c00c00002000000fde9"
```

Its hash:

```json
{
  "ipv4_prefix": {
    "version": 1,
    "flags": 1,
    "prefix": "192.0.2.0/24",
    "max_length": 28,
    "asn": 65001
  }
}
```

Flags bit 0 is 1 for an announcement and 0 for a withdrawal
(section 5.1). `announce?` reads it, and `key` gives the {Prefix, Len,
Max-Len, ASN} tuple a VRP is named by.

**Versions.** `version` is 1 unless set. Version 0's End of Data stops
at the Serial Number (RFC 6810 section 5.7), so it is 12 octets and has
no intervals. Version 1's carries section 6's three, which default to
its defaults:

```json
{
  "end_of_data": {
    "version": 1,
    "session_id": 4660,
    "serial": 7,
    "refresh": 3600,
    "retry": 600,
    "expire": 7200
  }
}
```

**Reading a stream.** `Rtr.pdus(buffer)` takes whole PDUs off the front
of a buffer and returns them with what is left, which waits for more
octets. `Rtr::Pdu.factory(octets)` reads one.

**Building never checks.** Any version, any length, a Max Length below
the Prefix Length: a test can build all of them.

## 2. What a receiver finds

`Rtr::Validation.check(octets, negotiated: 1)` reads one PDU and lists
what is wrong, each as the Error Code of section 12 a receiver answers
with:

```ruby
Rtr::Validation.check(Rtr::Ipv4_prefix.new('10.0.0.0/24', 16, 1).encode).collect(&:to_s)
# ["Corrupt Data (0): Max Length 16 is less than the Prefix Length 24"]
```

| Finding | Code | Section |
|---|---|---|
| before negotiation, a version neither 0 nor 1 | 4, Unsupported Protocol Version | 7 |
| after negotiation, any other version, 9 included | 8, Unexpected Protocol Version | 7 |
| a PDU Type not known | 5, Unsupported PDU Type | 12 |
| a Router Key in version 0 | 5 | 1.2 |
| a Length other than the PDU's, or other than its type's | 0, Corrupt Data | 5 |
| a Max Length below the Prefix Length, or either above the address's bits | 0 | 5.1 |
| an Error Report whose inner lengths overrun it | 0 | 5.11 |

A withdrawal of a VRP never announced (6) and a VRP announced twice (7)
need the session's VRP table, so the router finds those.
`Finding#fatal?` says whether section 12 drops the session for the
code: all but 2, No Data Available.

## 3. Faults

`BGP::Fault::RTR` holds what a cache can send that a router must
refuse. `Fault.rtr(name, session_id)` gives the octets of each PDU, in
order. `docs/protocol-testing.md` has the list. `bgp4r-rtr` sends them
(section 4). What bgp4rd and FRR answer to each is section 6.

## 4. The cache, `bgp4r-rtr`

`bgp4r-rtr` is an RTR cache. It serves the VRPs of a YAML file to the
routers that connect, in version 1 or version 0, and serves them again
with a new serial when the file changes. It is the cache of our labs,
and FRR's `bgpd_rpki` talks to it.

```sh
bgp4r-rtr /lab/rtr.yml
bgp4r-rtr /lab/rtr.yml --listen 0.0.0.0:3323 --api 0.0.0.0:8080
```

### The node file

```yaml
listen: 0.0.0.0:323       # where routers connect; the default
api: 127.0.0.1:8080       # the HTTP API; the default
session_id: 4660          # the default is the time, as section 5.1 suggests
refresh: 3600             # the End of Data's intervals, section 6's defaults
retry: 600
expire: 7200
notify_every: 60          # seconds between two Serial Notify, at least
history: 100              # serials kept to answer a Serial Query from
watch: 1                  # seconds between two looks at the file
vrps:
  - { prefix: 192.0.2.0/24, asn: 65001 }               # max_length: the prefix length
  - { prefix: 198.51.100.0/22, max_length: 24, asn: 65002 }
  - { prefix: 2001:db8::/32, max_length: 48, asn: 65003 }
```

Every key may be left out. A key not listed here is refused, and so is
a VRP whose Max Length is below its Prefix Length or above the
address's bits. Timers outside section 6's ranges are allowed, since a
lab may want a short Expire, and the log says so. So does a
`notify_every` under 60: section 8.2 says the cache "MUST rate-limit
Serial Notifies to no more frequently than one per minute".

When the file changes, its `vrps` become the table; the other keys are
read only at the start. A file that no longer reads, or holds a VRP
that is refused, keeps the table as it was, and the log says why.

### What it answers

| A router sends | The cache answers | Section |
|---|---|---|
| Reset Query | Cache Response, every VRP announced, End of Data | 5.4, 8.1 |
| Serial Query, a serial it keeps | Cache Response, the changes since, End of Data | 5.3, 8.2 |
| Serial Query, a serial it does not keep | Cache Reset | 5.3, 8.3 |
| Serial Query, another Session ID | Error Report 0, and it closes | 5.1 |
| a query in version 0 | the same, in version 0 | 7 |
| a version neither 0 nor 1 | Error Report 4, in version 1, and it closes | 7 |
| another version after one was agreed | Error Report 8, and it closes | 7 |
| any other PDU type | Error Report 3, or 5 for a type not known, and it closes | 7, 12 |
| an Error Report | nothing; it closes if the code is fatal or the report is wrong | 5.11 |

The changes since a serial are the smallest set (section 5.3): a VRP
added and then removed between the two is not sent, and withdrawals
come before announcements. Version 0 sessions get a Session ID of their
own, the next one, since section 5.1 says caches "SHOULD NOT use the
same Session ID across multiple protocol versions".

When the table changes, a Serial Notify goes to every router that has
agreed a version (section 7: not before), at most one each
`notify_every`. A notify that waits is sent when the time is up.

### The HTTP API

It is `bgp4r-sim`'s server (`bgp/sim/http.rb`) with these paths. A
POST needs `X-BGP4R: routescope`; a refusal is a 4xx with
`{"error": ...}`.

| Path | What it does |
|---|---|
| `GET /api/status` | Session IDs, serial, VRP count, routers, timers, the behaviour running |
| `GET /api/vrps` | the table |
| `GET /api/routers` | each router: address, version, the serial it was last sent, its last query |
| `GET /api/events?since=N` | what happened, as `BGP::Events` |
| `POST /api/vrps` | `{"vrps": [...]}` replaces the table; `{"announce": [...], "withdraw": [...]}` changes it |
| `POST /api/fault` | `{"name": ..., "router": "address:port"}`: one `BGP::Fault::RTR` case |
| `POST /api/behaviour` | `{"name": ..., "away": seconds}`: one behaviour |

A VRP from the API is lost when the file changes, since the file's
VRPs then become the table.

With the file's VRPs, `--listen 127.0.0.1:13340`, and one router
connected after its Reset Query,
`GET /api/status` and `GET /api/routers` answer:

```json
{
  "bgp4r": "0.0.19",
  "session_id": 4660,
  "session_id_v0": 4661,
  "serial": 1,
  "vrps": 3,
  "routers": 1,
  "refresh": 3600,
  "retry": 600,
  "expire": 7200,
  "notify_every": 60.0,
  "behaviour": null,
  "listen": 13340
}
```

```json
{
  "routers": [
    {
      "router": "127.0.0.1:52830",
      "version": 1,
      "connected_at": "2026-11-27T05:30:11Z",
      "serial": 1,
      "last_query": "reset",
      "reset_next": false,
      "fault": null
    }
  ]
}
```

`serial` is the serial the router was last sent. `reset_next` and
`fault` are what waits for its next query.

### Faults and behaviours

A fault is the answer to the router's next query, to every router that
agreed version 1, or to the one named. A Serial Notify goes out at once
to bring that query on. A router reads what comes while it has no
query open as it likes: FRR 10.7.1 dropped all six unread when they
were sent so.

| Behaviour | What the cache does | What RFC 8210 expects of the router |
|---|---|---|
| `rtr_no_data` | answers every query with Error Report 2, No Data Available | keep the session, query again (8.4) |
| `rtr_silent` | reads queries, answers none, sends no Serial Notify | use the data until Expire, then drop it (6) |
| `rtr_cache_reset` | answers each router's next Serial Query with Cache Reset, after a Serial Notify | send a Reset Query (8.3) |

`rtr_no_data` and `rtr_silent` run `away` seconds, 60 when not given.
A new one replaces the one running, and `away: 0` ends it.
`rtr_cache_reset` lasts until each router has had its Cache Reset.
`BGP::Fault::RTR_BEHAVIOURS` is the list.

### FRR 10.7.1 as the router

Measured on 2026-11-27, `quay.io/frrouting/frr:10.7.1` with `bgpd -M
rpki` and `rpki cache tcp 127.0.0.1 PORT preference 1`, against
`bgp4r-rtr` on the same host:

- It agreed version 1 and loaded the table: `show rpki prefix-table`
  listed the three VRPs of the file above.
- A change from the API reached it: a Serial Notify, its Serial Query,
  one withdrawal and one announcement.
- `rtr_cache_reset`: a Serial Query, the Cache Reset, then a Reset
  Query, as section 8.3 has it.
- `rtr_no_data`: it kept its table and the session.

Each fault, as the answer to a Serial Query, and its answer:

| Fault | RFC 8210 expects | FRR answered |
|---|---|---|
| `rtr_unknown_pdu` | Error Report 5 | Error Report 0, "length value in PDU is too small" |
| `rtr_bad_version` | Error Report 8 (4 until 7c) | Error Report 8 |
| `rtr_unexpected_version` | Error Report 8 | Error Report 8 |
| `rtr_withdraw_unknown` | Error Report 6 | Error Report 6 |
| `rtr_duplicate_announce` | Error Report 7 | Error Report 7 |
| `rtr_corrupt_length` | Error Report 0 | Error Report 0 |

FRR dropped the session each time, and kept the table it had. With a
Retry of 5 s it came back within 4 s after the first three. After
`rtr_withdraw_unknown` it had not come back after four minutes, and
`rpki reset` brought it back. Why is not known.

`rtr_bad_version` is sent after version 1 was agreed. Section 7 has a
version "neither 0 nor 1" answered "during this negotiation", and "a
PDU for a different Protocol Version once the above negotiation
completes" answered with code 8. 7b's catalog expected 4; FRR answered
8. 7c reads section 7 as FRR does: after negotiation, any other
version is 8, in `Rtr::Validation` and in the catalog.

## 5. Origin validation in bgp4rd

```yaml
rpki:
  caches:
    - { address: 10.0.0.9, port: 323, preference: 1, retry: 600 }
  invalid: accept      # accept | prefer_less | reject
  mark_ibgp: false
```

A cache entry takes `address`, `port` (323), `preference` (1, lower
is preferred) and `retry`, the seconds between two connections until
the cache gives its own Retry Interval (section 6's 600). A lab whose
cache may start after bgp4rd wants a short one. With `rpki:`, bgp4rd
has a RIB.

**The client.** One per cache, `Rtr::Client` in `bgp/rtr/client.rb`.
It sends a Reset Query, or a Serial Query when it has unexpired data
and a Session ID (8.1). An answer becomes the data only at its End of
Data, whole. It asks again at the Refresh Interval and after a Serial
Notify (8.2), sends a Reset Query after a Cache Reset (8.3), and keeps
the session on No Data Available, asking again at the Retry Interval
(8.4). Its data stays while it is down, and goes at the Expire
Interval (6). It speaks version 1, and takes a version 0 answer or a
version 0 Error Report 4 as a downgrade (7).

It refuses what section 12 names, with an Error Report: codes 0, 5 and
8 from `Rtr::Validation`, 6 for a withdrawal of a VRP it lacks, 7 for
one announced twice, and 0 for a prefix or an End of Data outside an
answer. Each ends the session and keeps the data until Expire. A
Session ID that differs, or Corrupt Data in answer to a Serial Query,
which is how a cache that restarted answers, flushes the data (5.1),
so the next connection sends a Reset Query.

**Which VRPs.** Those of the most preferred caches that have data: the
lowest `preference` among the caches synchronised and not expired, all
caches at that preference together (sections 4 and 10).

**Each route's state**, RFC 6811 section 2: NotFound when no VRP
Covers the prefix, Valid when one Matches it, else Invalid. The origin
AS is the rightmost AS of the final AS_SEQUENCE; our own AS for an
empty AS_PATH or a final confederation segment; none, which no VRP
Matches, for a final AS_SET. A VRP for AS 0 Matches nothing. Only IPv4
and IPv6 unicast routes are validated, received or originated. The
state is read from the VRPs each time it is asked for, so it follows
every change (6811 section 4).

**What shows.** `validation` on the rows of `show.routes`, `show.rib`
and `show.adj_in`. `show.vpn`, `show.vrf` and `show.evpn` rows say
`validation: notfound` and `validated: false`, as RFC 6811 section 2
has it for routes not validated. Without `rpki:` none of these keys is
there. With three routes from AS 65001 and the VRPs of `bgp4r-rtr`
below, `show.routes` (three keys of each row):

```json
[
  {
    "prefix": "192.0.2.0/24",
    "as_path": "65001",
    "validation": "valid"
  },
  {
    "prefix": "198.51.100.0/24",
    "as_path": "65001",
    "validation": "invalid"
  },
  {
    "prefix": "203.0.113.0/24",
    "as_path": "65001",
    "validation": "notfound"
  }
]
```

`show.rpki`, the caches:

```json
{
  "rows": [
    {
      "address": "127.0.0.1",
      "port": 3323,
      "mode": "tcp",
      "preference": 1,
      "state": "up",
      "version": 1,
      "session_id": 4660,
      "serial": 1,
      "vrps_v4": 2,
      "vrps_v6": 0,
      "refresh": 30,
      "retry": 5,
      "expire": 600,
      "since": "2026-11-27T06:27:55Z",
      "last_error": null
    }
  ],
  "total": 1,
  "offset": 0,
  "limit": 500,
  "next_offset": null
}
```

`state` is `idle`, `connected` (the query sent), `up` (an answer came)
or `down`. `show.rpki_vrps` lists the VRPs used, `prefix`,
`max_length` and `asn`, a page at a time:

```json
{
  "rows": [
    {
      "prefix": "192.0.2.0/24",
      "max_length": 24,
      "asn": 65001
    },
    {
      "prefix": "198.51.100.0/22",
      "max_length": 24,
      "asn": 65099
    }
  ],
  "total": 2,
  "offset": 0,
  "limit": 500,
  "next_offset": null
}
```

`show.status` gains `rpki`, here with `invalid: prefer_less` and
`mark_ibgp: true`:

```json
{
  "caches": 1,
  "synced": 1,
  "vrps_v4": 1,
  "vrps_v6": 0,
  "invalid": "prefer_less",
  "mark_ibgp": true
}
```

**What the state does**, `invalid`, one setting for the whole daemon,
for every unicast route, from any peer or originated:

- `accept`, the default: nothing. RFC 6811 section 2 keeps a route in
  the decision "unless explicitly configured to do so".
- `prefer_less`: an Invalid route loses to any Valid or NotFound one,
  at a step of its own, `rpki_invalid`, before LOCAL_PREF. Alone, or
  against other Invalid routes, it can still be best.
- `reject`: an Invalid route is not used, `rpki_reject`, as a route
  with a loop is not. It stays in the Adj-RIB-In, so `show.adj_in`
  shows it with its `validation`.

A VRP change decides again the prefixes whose routes it moved (RFC
6811 section 4), so a route `reject` removed comes back when a VRP
makes it Valid, or when the data expires and every route is NotFound.
With no cache synchronised yet every route is NotFound, and neither
setting changes anything.

With `prefer_less`, VRP 192.0.2.0/24 for AS 65001, and two paths to
it, `show.rib`'s paths (seven keys of each). The internal path's
LOCAL_PREF of 300 would win without RPKI:

```json
[
  {
    "from": "10.0.0.2",
    "as_path": "65001",
    "local_pref": null,
    "validation": "valid",
    "best": true,
    "lost_at": null,
    "reason": "best path, decided at the rpki_invalid step"
  },
  {
    "from": "10.0.0.4",
    "as_path": "65009",
    "local_pref": 300,
    "validation": "invalid",
    "best": false,
    "lost_at": "rpki_invalid",
    "reason": "RPKI Invalid, where another path is Valid or NotFound"
  }
]
```

**The community**, RFC 8097. With `mark_ibgp: true`, each unicast
route bgp4rd sends an internal peer carries one origin validation
state extended community (type 0x43, sub-type 0x00) with its state:
0 valid, 1 not found, 2 invalid. It replaces any the route came with.
When a VRP change moves the state of a best route that stays best,
that prefix goes again to each internal peer. With `rpki:` on, and
whatever `mark_ibgp` says, the community is dropped from a route an
external peer sent (section 2's "MUST drop") and is not sent to one
(its "SHOULD NOT"). bgp4rd does not derive a state from a community it
receives: with `rpki:` it has its own.

**Events**, of kind `rpki`, `data.event` one of: `connected`, `up`,
`down` (with the reason), `downgraded`, `synced` (a cache's serial and
counts), `expired` (a cache's data went), `error_sent`,
`error_received`, `vrps` (the VRPs used changed), and `routes`: how
many routes a VRP change moved, and the first ten, each with its
prefix, the peer, and the state it was and is:

```json
{
  "event": "routes",
  "changed": 1,
  "routes": [
    {
      "prefix": "192.0.2.0/24",
      "from": "10.0.0.2",
      "was": "notfound",
      "now": "invalid"
    }
  ]
}
```

## 6. Against FRR, and the matrix

**The interop test**, `test/functional/lab/rpki_frr_test.rb`, CI's
`lab frr`: one `Rtr::Cache` serves bgp4rd and FRR 10.5.1 the same
VRPs, one bgp4r-sim sends both the same seven routes, and the two must
give each route the same state. The routes are the cases of RFC 6811
section 2: Matched, Covered by a VRP for another AS, within and longer
than a Max Length, a VRP for AS 0, not Covered, and shorter than the
VRP. Then a VRP change, which both follow. FRR's state is
`rpkiValidationState` in `show bgp ipv4 unicast PREFIX json`, `valid`,
`invalid` or `not found`. They agreed on every route, measured on
2026-11-27.

bgpd needs `-M rpki`, which Ubuntu packages apart from FRR, in
`frr-rpki-rtrlib`. Its config is a block of its own:

```
rpki
 rpki retry_interval 5
 rpki cache tcp 127.0.0.1 PORT preference 1
exit
```

**The fault matrix**, each case of `BGP::Fault::RTR` and of the three
behaviours against bgp4rd (`test/functional/rtr_fault_matrix_test.rb`)
and against FRR 10.5.1 (`test/functional/lab/rtr_fault_frr_test.rb`).
The table is in `docs/protocol-testing.md`. bgp4rd answers what RFC
8210 expects. FRR answers `rtr_unknown_pdu` with code 0 where section
12 has 5, as 10.7.1 did, and after codes 6 and 7 it does not come back
by itself.

The matrix found one gap in bgp4rd, closed with it: bgp4rd's client and
`bgp4r-rtr` took a PDU longer than its type's Length, since each read
loop parsed the PDU and encoded it again before checking it. They now
check the octets as they came, `Rtr.slices`.
