# RPKI: the RTR protocol

A router learns which AS may originate which prefix from an RPKI
cache, over the RPKI to Router protocol, RTR (RFC 8210, version 1, and
RFC 6810, version 0). Each record is a Validated ROA Payload, a VRP:
a prefix, a maximum length and an origin AS. RFC 6811's origin
validation reads them.

This is P8's pull request 7 in `docs/design/bgp-operations.md`, in
three parts. 7a, the codec, and 7b, a cache in Ruby (`bgp4r-rtr`), are
built and described here. 7c, origin validation in bgp4rd, is not
built yet.

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
| a version neither 0 nor 1 | 4, Unsupported Protocol Version | 7 |
| a version other than the one negotiated | 8, Unexpected Protocol Version | 7 |
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
(section 4). The matrix against bgp4rd comes with 7c.

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
| `rtr_bad_version` | Error Report 4 | Error Report 8 |
| `rtr_unexpected_version` | Error Report 8 | Error Report 8 |
| `rtr_withdraw_unknown` | Error Report 6 | Error Report 6 |
| `rtr_duplicate_announce` | Error Report 7 | Error Report 7 |
| `rtr_corrupt_length` | Error Report 0 | Error Report 0 |

FRR dropped the session each time, and kept the table it had. With a
Retry of 5 s it came back within 4 s after the first three. After
`rtr_withdraw_unknown` it had not come back after four minutes, and
`rpki reset` brought it back. Why is not known.

`rtr_bad_version` is sent after version 1 was agreed. Section 7 has a
version "neither 0 nor 1" answered "during this negotiation", and a
different version after it answered with code 8, so FRR's 8 is one
reading. Section 12's code 4, "The Protocol Version is not known by the
receiver", is the other. Which one bgp4rd answers is 7c's to decide.
