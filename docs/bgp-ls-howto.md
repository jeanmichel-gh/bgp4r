# BGP-LS: how a BGP speaker learns an IS-IS LSDB

Questions and answers about the BGP-LS Producer: what it is, what it
reads, and what it sends. It describes the design in
`docs/design/bgp-ls-producer.md` and the isis4r method in isis's
`docs/design/bgp-ls-export.md`. Until both are built, this is how it
will work, not how it works.

For the wire format (NLRI types, TLVs, MP_REACH framing), read
`docs/bgp-ls.md`.

## How does a BGP speaker configured for BGP-LS learn the IS-IS LSDB?

Not through BGP. The IS-IS process in the same router hands it over,
locally. BGP then carries it to other speakers.

On commercial routers, this is one line on the IGP side and one address
family on the BGP side. On IOS-XR, for example, `distribute link-state`
under `router isis` gives the LSDB to BGP, and `address-family
link-state link-state` under `router bgp` carries it. Both protocols run
in one process space and share the data inside the box.

In our labs, isisd (isis4r) and bgp4rd (bgp4r) are two programs. The
hand-over goes over isisd's management socket, `/run/isis4r/isisd.sock`.
See [How does bgp4rd get the LSDB from isisd?](#how-does-bgp4rd-get-the-lsdb-from-isisd)

## Does the Producer read IS-IS routes or the LSDB?

The LSDB. Never the routes.

IS-IS holds two things:

| | LSDB (link-state database) | Routes (RIB, FIB) |
|---|---|---|
| What it is | Every router's LSP, as flooded | The result of SPF run on the LSDB |
| One entry says | "I am r1c1. My neighbors are r1c2 at metric 10, r2c1 at 10, s1 at 10. I advertise 10.200.0.1/32. Overload is off." | "10.200.0.4/32: cost 90, next hop 10.0.14.2, out eth3" |
| Holds the topology | Yes: every node and every link, with its metric | No: only where to send a packet next |
| Same on every router | Yes, within one area and level | No: each router has its own view |

A route has lost the topology. "Cost 90 via eth3" does not say which
links the path crosses. BGP-LS exists to carry the topology itself, so
it must start from the LSDB.

## What is a BGP-LS Producer?

RFC 9552 section 3 defines three roles.

- **Producer.** "A BGP Speaker that is originating link-state
  information into BGP." It does so "from their underlying link-state
  IGP protocols". It sits in a router that runs the IGP, so it has that
  router's LSDB.
- **Propagator.** A BGP speaker that passes BGP-LS on, after the BGP
  Decision Process. A route reflector, for example. It knows nothing of
  the IGP.
- **Consumer.** An application, not a BGP speaker: a controller, a PCE,
  or routescope. It only receives. Section 3: "a BGP-LS Consumer MUST
  NOT be able to send information to a BGP Speaker for origination into
  BGP-LS."

The point: a controller can see a whole IGP domain's topology without
running the IGP there, from anywhere BGP reaches.

## How does bgp4rd get the LSDB from isisd?

In the BGP-LS lab, bgp4rd (node p1) runs in r1's network namespace, so
it is the same router as r1 on the wire. It reads isisd's socket.

```
 r1 (network namespace shared with p1)
+-----------------------------------------------------------------+
|  isisd (isis4r)                        bgp4rd (bgp4r)           |
|  +----------+   1. "spf" event         +-------------------+    |
|  |  LSDB    | -----------------------> | Producer          |    |
|  |  (LSPs)  |   2. show.topology {1}   |  3. build NLRIs   |    |
|  |  SPF     | <----------------------- |  4. diff          |    |
|  +----------+   answer: nodes, links,  |  5. send          | ===+==> collector
|   /run/isis4r/isisd.sock  prefixes     +-------------------+    |   MP_REACH_NLRI
+-----------------------------------------------------------------+   MP_UNREACH_NLRI
```

1. isisd sends an `spf` event on its socket after each SPF run. SPF runs
   after every LSP change, so this event means "the LSDB may have
   changed". The event carries the IS-IS level.
2. bgp4rd asks for that level's LSDB with `show.topology`. The answer
   lists each node: its neighbors and metrics, its prefixes, its areas,
   its overload and attached bits, and whether SPF reached it.
   `show.database` cannot do this: it gives LSP headers only.
3. bgp4rd turns each node into BGP-LS routes.
   See [What BGP-LS routes come from one LSP?](#what-bgp-ls-routes-come-from-one-lsp)
4. It compares them with what it sent last time.
5. It sends what is new or changed in MP_REACH_NLRI, and what is gone in
   MP_UNREACH_NLRI. AFI 16388, SAFI 71. Only on sessions that negotiated
   that family.

When a session comes up, it gets the whole set.

## What BGP-LS routes come from one LSP?

Take r1c1's LSP, at Level 1, in the BGP-LS lab:

```
LSP 0000.0001.0101.00-00   (r1c1)
  TLV 137  hostname  r1c1
  TLV 1    area      49.0001
  TLV 22   neighbor  0000.0001.0102.00 (r1c2)  metric 10
  TLV 22   neighbor  0000.0001.0201.00 (r2c1)  metric 10
  TLV 22   neighbor  0000.0000.0009.00 (s1)    metric 10
  TLV 135  prefix    10.200.0.1/32             metric 0
  header   overload off
```

The Producer makes five routes. All carry Protocol-ID 1, IS-IS Level 1
(RFC 9552 section 5.2).

| NLRI | Descriptors: the key | BGP-LS Attribute: the data |
|---|---|---|
| Node | local node 0000.0001.0101 | Node Name (1026) `r1c1`, IS-IS Area (1027) `49.0001`, Node Flag Bits (1024), O clear |
| Link | local r1c1, remote r1c2 | IGP Metric (1095) 10 |
| Link | local r1c1, remote r2c1 | IGP Metric (1095) 10 |
| Link | local r1c1, remote s1 | IGP Metric (1095) 10 |
| Prefix | local r1c1, prefix 10.200.0.1/32 | Prefix Metric (1155) 0 |

- A node is named by the IGP Router-ID descriptor (515): the 6-octet
  system ID, or 7 octets with the pseudonode octet.
- The IGP Metric is 3 octets for a wide metric (TLV 22) and 1 for a
  narrow one (TLV 2). Section 5.3.2.4: "IS-IS wide metrics have a length
  of 3 octets."
- r1c2's LSP gives the same link the other way, r1c2 to r1c1. So each
  link is two Link NLRIs, one from each end, as in IS-IS.

Across all the nodes, the collector rebuilds the same graph as the
LSDB.

## What does a change in the IGP send in BGP?

| In the lab | The LSDB changes | BGP-LS sends |
|---|---|---|
| `link.down r1c1--r1c2` | r1c1 and r1c2 each drop the other from TLV 22 | MP_UNREACH_NLRI for both Link NLRIs |
| `link.metric r1c1--r1c2 100` | Both TLV 22 entries change metric | MP_REACH_NLRI for both Link NLRIs, metric 100 |
| `router.overload r2c2 on` | r2c2's LSP sets the overload bit | MP_REACH_NLRI for r2c2's Node NLRI, O set |
| `prefixes.withdraw r4c4 30.0.0.0/24` | r4c4's TLV 135 loses that prefix | MP_UNREACH_NLRI for that Prefix NLRI |

A refresh changes nothing that the Producer sends. It reads again after
the SPF run, finds the same set, and sends nothing.

## Why read after SPF? Why does it need "reachable"?

SPF is a clean signal that the LSDB has settled after a change.

SPF also says which nodes are still reachable. A node cut off from the
area can leave a stale LSP in the LSDB. RFC 9552 section 5.9:

> "A BGP-LS Producer SHOULD withdraw all link-state objects advertised by
> it in BGP when the node that originated its corresponding LSPs/LSAs is
> determined to have become unreachable in the IGP."

> "If the BGP-LS Producer does withdraw link-state objects associated
> with an IGP node based on the failure of reachability check for that
> node, then it MUST re-advertise those link-state objects after that
> node becomes reachable again in the IGP domain."

So `show.topology` marks each node `reachable` or not, and the Producer
sends routes for reachable nodes only. That is the only use it makes of
SPF. It never reads the routes.

## Where do the routes go after the Producer?

In phase 1, straight to a collector: a second bgp4rd that keeps them in
a table and shows them with `show.link_state`. routescope reads that
table, as the Consumer, and compares it with the LSDB.

bgp4rd's RIB does not hold BGP-LS today. It takes SAFI 1 and 2 only
(`bgp/rib/peer_adapter.rb:62`). So in phase 1, both the Producer and the
collector keep BGP-LS in a table of their own, outside the RIB. A
Propagator, which runs the Decision Process on BGP-LS and passes it on,
needs the RIB to carry SAFI 71. That is phase 2.
