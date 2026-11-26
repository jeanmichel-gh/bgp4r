# RPKI: the RTR protocol

A router learns which AS may originate which prefix from an RPKI
cache, over the RPKI to Router protocol, RTR (RFC 8210, version 1, and
RFC 6810, version 0). Each record is a Validated ROA Payload, a VRP:
a prefix, a maximum length and an origin AS. RFC 6811's origin
validation reads them.

This is P8's pull request 7 in `docs/design/bgp-operations.md`, in
three parts. 7a, the codec, is built and described here. 7b, a cache
in Ruby (`bgp4r-rtr`), and 7c, origin validation in bgp4rd, are not
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
order. `docs/protocol-testing.md` has the list. The cache that sends
them, and the matrix against bgp4rd and FRR, come with 7b and 7c.
