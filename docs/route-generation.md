# Generating UPDATE and withdraw messages

This is the design for generating BGP traffic in bulk, in every address
family bgp4r can build, with path attributes that vary from route to
route. Nothing here is built yet. It records the design and the plan,
so the work can be picked up in any session. The plan is at the end,
with the status of each phase.

Written on 2026-11-03.

## 1. Why

`bgp4r-sim` can send generated routes today, but only a narrow kind.

* `generate` is `BGP::RouteGenerator`. It does IPv4 and IPv6 unicast and
  nothing else.
* A whole generated range shares one set of path attributes.
* `withdraw` of a range regenerates the prefixes. It never reads a list
  back, which is how a million routes stay cheap.
* The other families can be built by the library but cannot be sent
  through the injector at all.

So a lab cannot ask for ten thousand EVPN MAC routes, or a BGP-LS
topology, or a range where every tenth route has a longer AS_PATH. And
each test in this repository writes its own UPDATEs by hand.

## 2. Principles

1. **One engine, in the library.** `require 'bgp/gen'`, a pure module
   that depends only on bgp4r. No socket, no thread, no clock. It has
   the shape of `Export` and `UpdateBuilder`: it reads a spec and
   returns objects.
2. **One spec format, plain JSON types.** Strings, numbers, booleans,
   lists and hashes, nothing else. The same spec is an HTTP body, a YAML
   block in a node file, a Hash in a test and a routescope scenario
   step.
3. **Three questions per spec.** `updates`, `withdrawals` and
   `expected`. `expected` is what the spec meant to send, as data.
4. **Deterministic.** Every random choice takes a seed. The same spec
   and seed give the same octets on every run and every Ruby.
5. **Nothing validates.** This is the first rule of Conventions in
   CLAUDE.md. A spec may ask for a route no RFC allows. The engine
   refuses only a spec it cannot read: an unknown key, a family it has
   no generator for, a value of the wrong type.
6. **The packing stays arithmetic.** As in `RouteGenerator`, prefixes
   are packed by computing sizes, and the first message of a feed is
   measured once so a slip in our arithmetic raises before it reaches
   the wire.

## 3. Who uses it

| Consumer | How |
|---|---|
| bgp4r unit tests | `BGP::Gen.new(spec)`, then inspect the UPDATE objects. |
| bgp4r functional and lab tests | Send the same UPDATEs over a `Neighbor`, then compare a RIB with `expected`. |
| `bgp4r-sim` | `announce` and `withdraw` hand the JSON body to `BGP::Gen` unchanged. |
| `bgp4r routegen` | Goes through `Injector#act`, so it gets the engine for free. |
| routescope | Sends the spec as JSON to an injector. It does not load bgp4r. |

**routescope talks HTTP and does not require the gem.** That keeps its
image free of bgp4r and avoids a version mismatch with the injector in
the lab. To get `expected` without sending, the injector adds a dry run,
`POST /api/plan`, which answers the spec's expected routes and sends
nothing. A scenario can then assert a router's RIB against it.

## 4. The spec

One spec describes one stream of routes in one family.

```json
{
  "family": "unicast",
  "afi": 1,
  "count": 10000,
  "per_update": 100,
  "start": "10.0.0.0/24",
  "seed": 7,
  "group": 10,
  "attributes": {
    "origin": 0,
    "next_hop": "192.0.2.1",
    "as_path": [65010],
    "med": { "cycle": [10, 20, 30] },
    "local_pref": { "step": { "start": 100, "by": 10, "wrap": 200 } },
    "communities": { "count": { "start": 1, "by": 1, "wrap": 16 }, "base": "65010:1" }
  }
}
```

* **`family`** is a name from `BGP::Specimen.families`, so there is one
  vocabulary in the library: `unicast`, `multicast`, `labelled`, `vpn`,
  `vpn_multicast`, `flow_spec`, `flow_spec_vpn`, `evpn`,
  `rt_constrain`, `mcast_vpn`, `bgp_ls`, `bgp_ls_vpn`. **`afi`** picks
  IPv4 or IPv6 where a family has both.
* **`count`** routes, packed **`per_update`** to a message, at most.
* **The family's own keys** say where the NLRI starts and how it steps.
  They differ per family. Section 6 lists them.
* **`attributes`** take the announce block keys bgp4r already uses:
  `origin`, `next_hop`, `as_path`, `med`, `local_pref`, `communities`,
  `extended_communities`, `large_communities`. A plain value is fixed.
  A hash is a pattern from section 5.
* **`group`** keeps N routes on one attribute set. Section 5 says why it
  matters.
* **`path_id`** is a value or a pattern, for RFC 7911.
* **`seed`** is required whenever a pattern is random.

The existing `generate: {start, count, per_update}` block keeps working.
It is a spec with `family: unicast` and fixed attributes.

## 5. Varying the attributes

A pattern gives the value for route number i.

| Pattern | Meaning |
|---|---|
| `fixed` or a plain value | The same value every time. |
| `cycle: [a, b, c]` | Walk the list and start again. |
| `step: {start, by, wrap}` | Add `by` each route, back to `start` at `wrap`. |
| `random: {min, max}` | Pick from a range, using the spec's seed. |
| `every: {n, values}` | Change the value every n routes. |

Some attributes need a pattern on a property rather than on the value:

* `as_path`: a prepend count, or a length with ASNs picked from a range.
* `communities`, `extended_communities`, `large_communities`: how many a
  route carries, built from a `base` value.
* `next_hop`: a step over addresses.

**Variation decides how many messages go out.** Prefixes travel in one
UPDATE only when their attributes are identical. A spec that changes the
MED on every route sends one route per message, whatever `per_update`
says. `group: N` holds an attribute set for N routes, so variation and
packing can be traded against each other on purpose.

## 6. Families

What steps in the NLRI, what is worth varying beyond section 5, and how
a route is withdrawn. Every family except IPv4 unicast goes in
MP_REACH_NLRI and is withdrawn in MP_UNREACH_NLRI, which needs only the
route key.

| Family | NLRI keys that step | Attributes specific to it | Withdraw |
|---|---|---|---|
| `unicast` (AFI 1, 2) | `start` prefix and length, `path_id` | none | IPv4 in Withdrawn Routes, IPv6 in MP_UNREACH. |
| `multicast` (SAFI 2) | as unicast | none | MP_UNREACH. |
| `labelled` (SAFI 4) | prefix, `label` fixed or per route | none | The label field on withdraw: RFC 8277 section 2.4 says 0x800000, and bgp4r writes 800001, a known issue. |
| `vpn`, `vpn_multicast` (128, 129) | `rd` of type 0, 1 or 2 stepped per VRF, `label`, prefix | route targets per VRF, so each VRF has its own attribute set | RD plus prefix. |
| `flow_spec`, `flow_spec_vpn` (133, 134) | destination prefix, port ranges, protocol, so a rule set N wide | traffic rate, redirect, marking; next hop length 0 | The same rule in MP_UNREACH. |
| `rt_constrain` (132) | origin AS, route target, the zero length default | none | GoBGP 3.23.0 panics on the default plus a second route. |
| `evpn` (25, 70) | type 2: MAC, IP, ESI, label; type 3: originator; type 5: prefix and GW IP | MAC Mobility sequence number (a MAC move), ESI label, Router's MAC, PMSI tunnel for type 3 | The route key only; Flags and GW IP are not in it. |
| `mcast_vpn` (5) | type 1 originator, type 5 (S,G), types 6 and 7 per Source AS | route targets | No lab router has the family. |
| `bgp_ls`, `bgp_ls_vpn` (71, 72) | a **topology**: N nodes, links as a ring or a grid, prefixes per node | attribute 29 TLVs per link: IGP metric, bandwidths, SRLG, admin group, node name | By NLRI. The VPN next hop is 12, 24 or 40 octets. |

BGP-LS is the one family where a generator means a graph rather than a
range. It is also where generation is most useful: a router can be fed
a large IGP topology that does not exist.

## 7. Ways to withdraw

Routers treat these differently, so each is a choice in the spec or a
separate action.

* An explicit list of route keys.
* The spec's own range, regenerated rather than read back.
* By `path_id` only, leaving the other paths of a prefix.
* Implicit: announce the same key again with new attributes.
* A session reset, which RFC 4271 section 6 makes a withdrawal of
  everything.
* End-of-RIB, an empty MP_UNREACH per family (RFC 4724 section 2).

## 8. Churn

A churn spec acts on routes already announced: a rate, a share of
explicit withdrawals against implicit ones, a duration and a seed. It
is what tests a receiver's decision process and its MRAI handling.

## 9. Other inputs that stay

* **`mp_reach` and `mp_unreach` keys** take the hash `Mp_reach.new`
  already reads. One message, any family, no generator needed.
* **`specimen`** sends `BGP::Specimen.build(name)` by name.
* **`fault`** and **`replay`** stay as they are. They are the negative
  half and already work in every family.

## 10. Testing

Every phase in section 12 ships with all three tiers that apply to it.

**Unit** (no socket):

* Every UPDATE is at most 4096 octets and the packing fills each one.
* Every message round trips: encode, parse, encode, same octets.
* `validation.rb` reports nothing on valid generated traffic. A spec
  combined with one fault case gives exactly one finding.
* `withdrawals` cover exactly the keys `updates` announced.
* `expected` has `count` rows and their attributes match the patterns.
* Each property is run over many seeds, as `table_test.rb` does for the
  RIB. A failure prints the spec and the seed so it can be replayed.

**Functional** (loopback, no Docker):

* A bgp4r sender and a bgp4r receiver with `rib.attach`. The Adj-RIB-In
  equals `expected`, and it is empty after the withdraw.
* The same spec through `bgp4r-sim`'s HTTP API, so the API path and
  the library path are shown to agree.

**Interop** (native routers, the lab groups):

* `LabHelper::Gobgpd` and `Frr` take a spec. Assert the router's route
  count and compare a sample of its paths with `expected`.
* A family a router lacks uses the same spec in its absence test.
* `test/coverage_matrix.rb` can then report which families have a
  generator and which have been sent to a router by one.

**The caveat.** `expected` comes from the same code that sends, so
comparing against it proves consistency and not correctness: a bug in
both halves passes. The RFC vectors and the real routers are still what
check the encoding. What `expected` removes is hand written
expectations, which CLAUDE.md records being wrong many times.

## 11. Decisions still open

* **The eBGP `as_path` prepend.** `Speaker#path_attribute` always puts
  our AS in front of an explicit `as_path` on an eBGP session. A
  generator that wants an exact AS_PATH needs either a change to that
  default, which changes what existing node files send, or a new key
  that means "send it as written". Phase 0 decides.
* **`RouteGenerator`'s future.** Either it stays as it is, or it becomes
  a thin wrapper over `BGP::Gen` for unicast. Its API and its tests must
  keep working either way.
* **Where pattern state lives.** Each generator is an Enumerator, so a
  pattern is a function of the route number and the seed, not of
  anything mutable. That is the intent; phase 2 confirms it is enough
  for `every`.

## 12. The plan

One pull request per step, each with its unit, functional and, where a
router exists, interop tests, each sabotaged once to show its tests
can fail. Update this table in the pull request that moves a step.

| Phase | Step | Status |
|---|---|---|
| 0 | Fix the two gaps: `path_id` dropped on a `generate` block, and decide the `as_path` prepend. | To do |
| 1 | `bgp/gen`: spec reader that refuses unknown keys, unicast generator for IPv4 and IPv6, the packer, `updates`, `withdrawals`, `expected`. | To do |
| 2 | `Vary`: the five patterns, `group`, the property patterns for AS_PATH and communities. | To do |
| 3 | Injector wiring: `announce` and `withdraw` read a spec, `POST /api/plan`, the `mp_reach`, `mp_unreach` and `specimen` keys. | To do |
| 4a | Multicast and labelled. | To do |
| 4b | VPN, both SAFIs. | To do |
| 4c | Flow spec, both SAFIs. | To do |
| 4d | EVPN types 2, 3 and 5, then the rest. | To do |
| 4e | RT-constrain. | To do |
| 4f | MCAST-VPN. | To do |
| 4g | BGP-LS topologies. | To do |
| 5 | Churn. | To do |
| 6 | `LabHelper` takes a spec, and the coverage matrix reports generators. | To do |
| 7 | routescope scenarios send specs and read `/api/plan`. This is routescope's column. | To do |

Phase 1 is the foundation and the rest depend on it. Phases 4a to 4g
are independent of each other once 3 is in, and can be taken in any
order. A done step means its tests are in the suite, the full unit suite
passes, CLAUDE.md's baseline is re-measured, and this table says Done.
