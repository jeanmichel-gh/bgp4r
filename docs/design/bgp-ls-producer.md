# BGP-LS Producer and collector in bgp4rd

Status: approved 2026-11-09, with option A (a table of its own).
Built in #315. Phase 3, the OSPFv2 source, is built too
(`docs/design/bgp-ls-ospf.md`). Phase 2, a Propagator, is not started.

Part of the BGP-LS lab. Two other specs go with it:
isis `docs/design/bgp-ls-export.md` and routescope
`docs/design/bgp-ls-lab.md`.

`docs/bgp-ls-howto.md` explains the design as questions and answers:
what a Producer is, why it reads the LSDB and not the routes, and what
one LSP becomes in BGP-LS.

## The problem

We want a lab that shows an IS-IS LSDB carried in BGP-LS (RFC 9552,
AFI 16388, SAFI 71). Phase 1 is one IGP domain:

```
s1 (isis4r-sim grid) --- r1 (isisd + bgp4rd Producer) ===eBGP=== col (bgp4rd collector)
                    \--- f1 (FRR IS-IS) ---/
```

bgp4rd has to do two new things:

1. **Produce**: read isisd's LSDB and originate BGP-LS routes.
2. **Collect**: receive BGP-LS routes, keep them, and show them through
   the API, so routescope can read them.

RFC 9552 section 3 names the roles:

> "BGP-LS Producer: The term BGP-LS Producer refers to a BGP Speaker that
> is originating link-state information into BGP."

> "BGP-LS Consumer: The term BGP-LS Consumer refers to a consumer
> application/process and not a BGP Speaker. [...] The communication of
> information MUST be unidirectional (i.e., from a BGP Speaker to the
> BGP-LS Consumer application), and a BGP-LS Consumer MUST NOT be able
> to send information to a BGP Speaker for origination into BGP-LS."

Section 3 has no errata. In this lab, col is the BGP speaker and
routescope is the Consumer. routescope only reads.

## What exists

Read on master at 8fb8edd.

- **The wire is complete.** Every NLRI type and every attribute TLV we
  need is coded and registered:
  - NLRI: `BGP::Link_state` (`bgp/nlris/link_state.rb:167`), with
    `Node`, `Link` and `Ipv4_prefix` (`bgp/nlris/link_state_nlri.rb:275,
    298, 362`).
  - Descriptors: `Local_node_descriptors` (256),
    `Remote_node_descriptors` (257), `Igp_router_id` (515),
    `Ip_reachability` (265).
  - Attribute `BGP::Link_state_attribute` (29) with `Node_flag_bits`
    (1024), `Node_name` (1026), `Isis_area_id` (1027), `Igp_metric`
    (1095) and `Prefix_metric` (1155).
- **Negotiation works by number.** `capabilities: [{mbgp: [16388, 71]}]`
  sends the right capability. The named form fails:
  `Mbgp.method_missing` splits on `_` (`bgp/optional_parameters/mbgp.rb:30-33`),
  and the family is `:bgp_ls`.
- **The RIB takes unicast and multicast only.**
  `PeerAdapter::MP_SAFIS = [UNICAST, MULTICAST]`
  (`bgp/rib/peer_adapter.rb:62`), and `each_mp_prefix` returns for any
  other SAFI (`:220`). A BGP-LS UPDATE reaches no table. `Route` keys on
  an IP prefix (`bgp/rib/route.rb:100-129`). The comment at
  `peer_adapter.rb:54-61` says another key "is a change to the decision
  process and to every show command".
- **`Speaker#on_established`** (`bgp/daemon/speaker.rb:804-831`) runs a
  block each time a session comes up. It is the hook for "anything a
  control plane announced". bgp4r-sim uses it.
- `bgp/gen/link_state_routes.rb` builds NLRIs for made-up topologies. Its
  `head`, `igp_router_id` and `prefix_key` helpers can be reused.

## Decision: where BGP-LS routes live (A chosen)

**A. A table of their own, outside the RIB (recommended for phase 1).**
The Producer keeps the routes it sends. The collector keeps the routes it
receives, per peer, keyed by the NLRI's octets. There is no decision
process and no re-advertising. The unicast RIB does not change.

**B. Make the RIB carry SAFI 71.** `Route` keyed by NLRI octets, the
decision process, `UpdateBuilder` and every show command. This is what a
Propagator needs: a speaker that runs the decision process on BGP-LS and
passes it on. It is the right base for phase 2, with GoBGP and a second
Producer.

Phase 1 has one Producer and one collector, so it does not need B. B is
large and touches the unicast path that every lab uses. I recommend A
now and B as its own spec for phase 2. The rest of this spec assumes A.

## The design

### Producer

A new node-file block:

```yaml
link_state:
  isisd: /run/isis4r/isisd.sock
  levels: [1]
  identifier: 0
  peers: [10.2.0.2]
```

- `levels`: which IS-IS levels to export. Level 1 is Protocol-ID 1,
  level 2 is Protocol-ID 2 (RFC 9552 section 5.2, the Protocol-ID
  table).
- `identifier`: the 64-bit Identifier of section 5.2. 0 by default.
- `peers`: the sessions that get BGP-LS. Each must have negotiated
  16388/71. Others get nothing.

`BGP::Daemon::LinkStateProducer`, a new class, runs one thread:

1. Subscribe to isisd's events.
2. Read `show.topology` for each level. Build the set of routes.
3. Compare with the set already sent. Send what is new or changed in
   MP_REACH_NLRI. Send what is gone in MP_UNREACH_NLRI.
4. Wait for an `spf` event of a configured level. Go to 2.

If the socket closes, it retries every 5 s and keeps its set. When it
reads again, the diff sends only what changed.

On each session that comes up (`on_established`), it sends the whole
set.

### Routes built from one node of `show.topology`

Each node gives:

- **One Node NLRI.** Local node descriptors: IGP Router-ID (515), the
  6-octet system ID, or 7 octets with the pseudonode octet when it is not
  zero. Attribute:
  - Node Flag Bits (1024): O when `overload`, A when `attached`.
  - Node Name (1026): `hostname`, when there is one.
  - IS-IS Area Identifier (1027): one per area in `areas`.
- **One Link NLRI per neighbor.** Local node descriptors: this node.
  Remote node descriptors: the neighbor. Attribute: IGP Metric (1095), 3
  octets for `wide`, 1 for `narrow`. Section 5.3.2.4: "IS-IS wide
  metrics have a length of 3 octets." Each node lists its own neighbors,
  so a link shows as two Link NLRIs, one from each end.
- **One Prefix NLRI per prefix.** Local node descriptors: this node.
  Prefix descriptor: IP Reachability Information (265). Attribute:
  Prefix Metric (1155).

On the A bit: RFC 9552 errata 7789, on section 5.3.1.1, changes the
figure's 'T' to 'A', to match the table. We follow the table: bit 1 is
the Attached Bit.

Nodes with `reachable: false` give no routes. Section 5.9:

> "A BGP-LS Producer SHOULD withdraw all link-state objects advertised by
> it in BGP when the node that originated its corresponding LSPs/LSAs is
> determined to have become unreachable in the IGP."

> "If the BGP-LS Producer does withdraw link-state objects associated
> with an IGP node based on the failure of reachability check for that
> node, then it MUST re-advertise those link-state objects after that
> node becomes reachable again in the IGP domain."

Section 5.9 has no errata. Both rules follow from building the set from
`reachable` nodes on each read. A setting `unreachable: keep` turns this
off. The section allows that with a "MAY".

Phase 1 leaves out: Link Local/Remote Identifiers (258), interface
addresses (259, 260), TE attributes, SR, IPv6 prefixes and the AS
sub-TLV. Two parallel links between one pair of nodes would collide.
This lab has none.

### Collector

When a session has negotiated 16388/71, `PeerAdapter` passes each BGP-LS
NLRI to a new `BGP::Daemon::LinkStateTable` instead of dropping it:

- Keyed by peer and NLRI octets. The value is the decoded NLRI, its
  BGP-LS attribute, and the time it came.
- MP_UNREACH removes the key. A session going down removes all its keys.
- No decision process, no re-advertising.

### The API

`show.link_state`, on both the Producer (what it sent) and the collector
(what it holds). One row per route:

```json
{"peer": "10.2.0.1", "type": "link", "protocol_id": 1, "identifier": 0,
 "local": "0000.0001.0101.00", "remote": "0000.0001.0102.00",
 "prefix": null, "name": null, "flags": [], "areas": [], "metric": 10,
 "since": "2026-11-09T10:00:00Z"}
```

`type` is `node`, `link` or `prefix`. On the Producer, `peer` is null.
`bgp4r-cli show link-state` prints it as a table.

### Small fixes on the way

- `{mbgp: bgp_ls}` as a named capability. Today only the numbers work.

## Pull request

One: bgp4r `claude/bgp-ls-producer`. This spec, then the Producer, the
collector table, the API method and the CLI, then `docs/bgp-ls.md` and
`docs/daemon.md`.

## Tests

- `LinkStateProducer`, with a fake isisd socket that plays
  `show.topology` answers and `spf` events from a fixture:
  - the first read sends every Node, Link and Prefix NLRI;
  - a metric change sends one Link NLRI in MP_REACH;
  - a link gone sends two withdrawals, one per direction;
  - overload on sends the Node NLRI with O set;
  - a prefix gone sends one withdrawal;
  - a node with `reachable: false` is withdrawn, then sent again when
    reachable;
  - the socket closing and coming back sends only the diff;
  - a session coming up gets the whole set.
- The encoded routes, checked byte for byte against hand-built
  `BGP::Link_state` objects: the 6- and 7-octet IGP Router-ID, metric
  widths 1 and 3, and node flags O and A.
- `LinkStateTable`: add, replace, withdraw, session down.
- Two bgp4rd speakers on loopback, Producer and collector, with the fake
  socket: the collector's `show.link_state` equals the Producer's.
- The full suite: `ruby test/run_unit.rb`.

## Gate

The full suite passes. The loopback test passes. The lab's gate is in
routescope's spec.
