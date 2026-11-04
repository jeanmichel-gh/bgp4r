# Generating UPDATE and withdraw messages

This is the design for generating BGP traffic in bulk, in every address
family bgp4r can build, with path attributes that vary from route to
route. It records the design and the plan, so the work can be picked
up in any session. Phases 1 and 2 are built; section 13 says what
they do.
The plan is at the end, with the status of each phase.

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
| `bgp4r-sim` | `announce` and `withdraw` hand the body's `spec` key to `BGP::Gen` unchanged, with the session's rules. |
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
    "communities": { "count": { "base": "65010:1", "n": { "step": { "start": 1, "by": 1, "wrap": 16 } } } }
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

A pattern gives the value for route number i, or for group number
i / N when the spec has `group: N`. It is a function of that number
and the seed and of nothing else, so withdrawals regenerate what was
announced and a value never depends on how many came before it.
`bgp/gen/vary.rb` is the code.

| Pattern | Meaning |
|---|---|
| `fixed` or a plain value | The same value every time. |
| `cycle: [a, b, c]` | Walk the list and start again. |
| `step: {start, by, wrap}` | Add `by` each route, back to `start` at `wrap`. |
| `random: {min, max}` | Pick from a range, using the spec's seed. |
| `every: {n, values}` | Change the value every n routes. |

`origin`, `med`, `local_pref` and `path_id` are integers and take all
five. `next_hop` is an address and takes all five too: `step` and
`random` work on the address as a number, and every address in one
pattern has to be of one family. `as_path` and the three community
lists are lists, so they take `fixed`, `cycle` and `every` over whole
lists, and a pattern of their own on a property:

| Value | Pattern | Meaning |
|---|---|---|
| `as_path` | `prepend: {as, count, path}` | `as` repeated `count` times in front of `path`. |
| `as_path` | `length: {count, min, max}` | `count` AS numbers picked from `min` to `max`, using the seed. |
| a community list | `count: {base, n}` | `n` communities counting up from `base`: `65000:1`, `65000:2`, ... |

`count` and `n` are themselves integer patterns, so a prepend can cycle
and a community list can grow. A community count of 0 sends no
attribute at all rather than an empty one, which `BGP::Fault` already
sends.

**Random is a fresh generator per value per route**, seeded from the
spec's seed, the value's name and the route number through FNV-1a 64.
So adding a random MED to a spec does not move its random LOCAL_PREF,
and the same seed gives the same octets on every Ruby CI runs, which a
test pins with the values themselves. A spec with a
random pattern and no `seed` is refused.

**The Path Identifier runs on the route number even with a group**,
because it belongs to the route and not to its attribute set, so it
never splits a message.

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
| `multicast` (SAFI 2) | as unicast | none | MP_UNREACH, IPv4 too. |
| `labelled` (SAFI 4) | prefix, `label` fixed or per route, required | none | The 3-octet Compatibility field of RFC 8277 section 2.4, written as 0x800000. |
| `vpn`, `vpn_multicast` (128, 129) | `rd` of type 0, 1 or 2 stepped per VRF, `label`, prefix, the range once per VRF (`vrfs`) | `route_target` stepped per VRF, so each VRF has its own attribute set | RD plus prefix, with the Compatibility field. |
| `flow_spec`, `flow_spec_vpn` (133, 134) | destination prefix from `start`, `source`, `protocol` and `destination_port`, each one `eq` match, so a rule set N wide; for 134 `rd`, `vrfs` and `route_target` as VPN | `rate`, `redirect` and `marking`, the actions of RFC 8955 section 7; no next hop | The same rule in MP_UNREACH. |
| `rt_constrain` (132) | origin AS, route target, the zero length default | none | GoBGP 3.23.0 panics on the default plus a second route. |
| `evpn` (25, 70) | `route_type`; type 2: MAC from `start`, `ip`, `esi`, `label`; type 3: originator from `start`; type 5: prefix from `start`, `gateway`, `esi`, `label`; `ethernet_tag`; `rd`, `vrfs` and `route_target` as VPN | `mac_mobility` (a MAC move), `router_mac`, `pmsi_label` for type 3; the ESI label goes with type 1 | The same NLRI; a receiver matches the route key, which leaves out the ESI, the labels and the gateway. |
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

* **The eBGP `as_path` prepend. Decided in phase 0b**: a new key,
  `as_path_literal: true`, sends `as_path` exactly as written, and the
  prepend stays the default. Changing the default would have changed
  what every existing node file sends, and
  `lab/routescope/bgp4r-lab/scenarios/med-decides.yml` relies on it. A
  generator that wants an exact AS_PATH sets the key.
* **`RouteGenerator`'s future.** Either it stays as it is, or it becomes
  a thin wrapper over `BGP::Gen` for unicast. Its API and its tests must
  keep working either way.
* **Where pattern state lives. Decided in phase 2**: nowhere. A
  pattern is a function of the route or group number and the seed, and
  `every` is a division, so it needed no state either. Random draws use
  a fresh generator per value per route rather than one stream, which
  costs a `Random` per draw and is what keeps one value independent of
  another.

## 12. The plan

One pull request per step, each with its unit, functional and, where a
router exists, interop tests, each sabotaged once to show its tests
can fail. Update this table in the pull request that moves a step.

| Phase | Step | Status |
|---|---|---|
| 0a | `path_id` on a `generate` block reaches every prefix, announce and withdraw. | Done |
| 0b | `as_path_literal: true` sends `as_path` as written over eBGP; the prepend stays the default (section 11). | Done |
| 1 | `bgp/gen`: spec reader that refuses unknown keys, unicast generator for IPv4 and IPv6, the packer, `updates`, `withdrawals`, `expected`. | Done |
| 2 | `Vary`: the five patterns, `group`, the property patterns for AS_PATH and communities. | Done |
| 3 | Injector wiring: `announce` and `withdraw` read a spec, `POST /api/plan`, the `mp_reach`, `mp_unreach` and `specimen` keys. | Done |
| 4a | Multicast and labelled. | Done |
| 4b | VPN, both SAFIs. | Done |
| 4c | Flow spec, both SAFIs. | Done |
| 4d | EVPN types 2, 3 and 5. | Done |
| 4d2 | EVPN types 1, 4 and 6 to 11, and the ESI label community. | To do |
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

## 13. What is built

**Phase 1.** `require 'bgp/gen'`, then `BGP::Gen.new(spec)` for
`family: unicast`, IPv4 or IPv6, with fixed attributes and a fixed
`path_id`. Every other family name from `BGP::Specimen.families` is
refused as having no generator yet. Phase 1 refused `seed`, `group`
and patterns by name rather than ignoring them; phase 2 reads all three.

* `updates`, `withdrawals` and `expected` are Enumerators, so a million
  routes are built one message or one row at a time.
* **Attributes are sent as written.** The library knows no session, so
  it prepends no AS and fills in no next hop. ORIGIN and AS_PATH are
  always there, IGP and empty by default. The injector adds the session
  half, which phase 3 does.
* **`expected` holds for a 4-octet AS session.** On a 2-octet session a
  4-octet AS in `as_path` goes out as AS_TRANS, 23456, and bgp4r adds no
  AS4_PATH. The functional test asserts that difference.
* Communities in `expected` are spelled the way the attribute reads
  back, so `no_export` is `65535:65281`, which is what a RIB shows.
* **The packing is checked against itself.** The first message of each
  feed is measured, and a difference from the packer's arithmetic
  raises `Gen::PackingError`. A spec whose attributes leave no room for
  one route is refused at `new`, not mid feed.

Tests: `test/unit/gen_test.rb` runs the section 10 properties over
random specs (`GEN_SEEDS=500` for a longer sweep),
`test/functional/gen_test.rb` compares a receiver's Adj-RIB-In with
`expected`, and `test/functional/lab/gen_gobgp_test.rb` does the same
against gobgpd 3.23.0. GoBGP's JSON prints no Path Identifier, so that
test vouches for where the identifiers sit and not for their value.

**Phase 2.** Every attribute and the Path Identifier take the patterns
of section 5, and `seed` and `group` are read.

* **A message ends when the attribute set changes**, as well as when it
  is full, since RFC 4271 section 4.3 gives one UPDATE one set of
  attributes. Each distinct set has its own packer, and the first
  message of each set is measured. Sets are cached, up to 1024, and the
  cache is cleared when it fills, so a feed whose every route differs
  costs that much memory and no more.
* **Only the first set is checked for room at `new`.** A pattern can
  make a later set too large for one route, a community count that
  grows say, and finding the largest would mean building every set up
  front. So such a spec can stop with `Gen::Unpackable` after messages
  have gone. A test pins that.
* **The property sweep found a bug in its own test and not in the
  code.** At 200 seeds, the check that every message but the last is
  full read two IPv6 messages with different next hops as one set,
  because it compared the attributes without MP_REACH_NLRI and the next
  hop lives there. `GEN_SEEDS=500` passes now.
* GoBGP reads the patterns too: ten rows spread across each feed are
  compared with `expected`, and a sabotage that let two sets share a
  message failed both lab cases, where bgp4r's own first message check
  could not see it.


**Phase 3.** `bgp4r-sim` takes a spec, a dry run answers what it
means, and three keys send one message by hand.

* **A spec rides under its own `spec` key**, not as the whole body.
  The action body keys are the node file's, and a spec has keys of its
  own, so keeping them apart means neither vocabulary bleeds into the
  other. Any announce key beside `spec` is refused except
  `as_path_literal`, which is the session's and not the spec's.
* **The session's rules are in the library, in `bgp/gen/sender.rb`**,
  as a second argument to `BGP::Gen.new`. Over eBGP our AS goes in
  front unless `as_path_literal`; our address is the next hop when the
  spec gives none; LOCAL_PREF goes to an internal peer only, 100 by
  default. They run on the row of plain values, so `updates` and
  `expected` read the same row and the dry run cannot disagree with the
  send. Those are `Speaker#path_attribute`'s rules, so a spec and an
  announce block sent by one injector agree.
* **`POST /api/plan` answers per peer and is paged.** The prepend and
  LOCAL_PREF depend on the session, so one spec has as many answers as
  targets. The page is `Daemon::Views`' envelope and limits.
* **An IPv6 spec on an IPv4 session gets an IPv4-mapped next hop**,
  which `Mp_reach` writes on its own. GoBGP 3.23.0 prints it back as
  the IPv4 address. Measured.
* **`mp_reach`, `mp_unreach` and `specimen`** send one message in any
  family. `Specimen.update` exists now, the twin `bgp/specimen.rb` held
  back until a caller came: it and `Fault.update` both go through
  `Fault.wrap`, so the two catalogs share one envelope.
* **A set too large halfway now sends what fit first.** `Packer.batches`
  checked a route for room before yielding the batch of the set before
  it, so the injector's first test of a spec that stops halfway found
  nothing sent where one message should have gone. The check runs after
  that yield now.

Tests: `test/unit/gen/sender_test.rb` reads each rule off the octets
and off `expected`; `test/unit/sim/injector_test.rb` and
`test/unit/sim/http_test.rb` cover the keys, the refusals and the
route; `test/functional/sim_test.rb` asks for the plan over HTTP, sends
the spec over HTTP, and compares what a bgp4r peer read route by route;
and `test/functional/lab/gen_gobgp_test.rb` does the same against
gobgpd 3.23.0 through an in-process injector, IPv4 and IPv6.

**Phase 4a.** Multicast, SAFI 2, and labelled unicast, SAFI 4, both
AFIs. Each is a subclass of the unicast generator, so the packer, the
patterns and the sender are shared.

* **Only IPv4 unicast uses RFC 4271's own fields.** `classic?` asks
  that, where phases 1 to 3 asked `ipv4?`. So IPv4 multicast goes in
  MP_REACH_NLRI with its next hop inside it, and is withdrawn in
  MP_UNREACH_NLRI.
* **A label is required for `labelled` and refused anywhere else.**
  `Spec::FAMILY_KEYS` holds which keys belong to which family, and
  `Gen.new` refuses a key on the wrong one. It is 20 bits, RFC 3032
  section 2.1, and a value or a pattern.
* **The label runs on the route number, not the group.** A label is
  part of the NLRI, like the Path Identifier, so grouping the
  attributes does not hold it. One label per route; RFC 8277 section
  2.2 allows a stack and nothing here asks for one.
* **A withdrawal writes 0x800000 where the label was**, the
  Compatibility field of RFC 8277 section 2.4. `Mp_unreach` already
  took a `:compatibility` key, so this needed no library change.
* **What `expected` cannot catch.** A label read off the group number
  instead of the route number passes the property test, the functional
  test and the lab, because `expected` comes from the same method that
  sends. Only `labelled_test.rb`, which states the labels by hand,
  fails. That is the caveat in section 2, met for real.

Measured against gobgpd 3.23.0 on 2026-11-03:

* **Labelled**: the config names are `ipv4-labelled-unicast` and
  `ipv6-labelled-unicast`, the client names `ipv4-mpls` and
  `ipv6-mpls`. `CLIENT_FAMILY` maps them. GoBGP reads every label back
  and drops every route on withdrawal.
* **Multicast is filed in GoBGP's unicast table.** The session
  negotiates `ipv4-multicast` and `ipv6-multicast`, but the client
  answers `unsupported address family` for both, and a multicast route
  shows in the unicast table with next hop `fictitious` and no
  attributes. It replaces a unicast route of the same prefix, and its
  withdrawal removes that route. No reset. Asserted as measured, not
  filed.

Tests: `test/unit/gen/multicast_test.rb` and
`test/unit/gen/labelled_test.rb`; `test/unit/gen_test.rb`'s property
test draws all three families; `test/functional/gen_test.rb` sends both
families over loopback and reads the SAFI off the octets, since a table
cannot tell SAFI 2 from SAFI 1; `test/functional/lab/gen_gobgp_test.rb`
reads the labels back from GoBGP and asserts the multicast fault.

**Phase 4b.** Labeled VPN, SAFI 128, and Labeled VPN Multicast, SAFI
129, both AFIs. `Vpn` is a subclass of `Labelled` and `Vpn_multicast`
of `Vpn`, so the label rules carry over whole.

* **Three keys, for these two families only**: `rd`, `vrfs` and
  `route_target`. `rd` is required, as `ADMIN:N`, and the administrator
  picks RFC 4364 section 4.2's type: an AS that fits two octets is type
  0, an IPv4 address type 1, a larger AS type 2. A route target reads
  the same way. A 4-octet AS below 65536 cannot be asked for, since it
  reads as type 0.
* **Every VRF carries the same `count` prefixes**, because overlapping
  address space is what an RD is for (RFC 4364 section 4.1). So
  `vrfs: N` makes N times `count` routes, VRF by VRF, and VRF n's RD is
  `rd` with n added to its assigned number. A number stepped past its
  field is refused, since it would be written as a different one.
* **A route target makes each VRF an attribute set of its own.** VRF
  n's target steps like its RD and joins the extended communities, so
  a message never mixes two VRFs. Without one, the VRFs share a set and
  pack together. `Unicast` grew `set_key` and `row_at` for this: a set
  is keyed by the group and, for VPN, the VRF.
* **The label runs across the VRFs**, on the route number, as for
  `labelled`. A withdrawal names the RD and the prefix and carries
  0x800000, which RFC 8277 section 2.4 asks of any "SAFI-x UPDATE".
* **An IPv4 next hop for IPv6 VPN routes goes out IPv4-mapped**, 24
  octets, RFC 4659 section 3.2.1.2. `Mp_reach` maps it for SAFI 1, 2
  and 4 and not for SAFI 128, so the generator does. `expected` keeps
  the address as given.
* **A library bug this found**: under AFI 2 SAFI 128 or 129,
  `Mp_reach` read a 24-octet next hop as two 12-octet VPN-IPv4
  addresses, so 2001:db8::1 came back as "32.1.13.184, 0.0.0.1". The
  octets replayed, so no round trip test saw it. It reads one VPN-IPv6
  address now, and `mp_reach_test.rb` pins all three lengths.
* **The injector's plan total read `spec['count']`**, which is one VRF
  of a VPN spec, so paging would have stopped a VRF early. `Gen#total`
  answers the whole count now.
* **What `expected` cannot catch, again.** A route target taken from
  the first VRF for all of them, and SAFI 128 sent as 129, both passed
  every comparison with `expected`. The functional and lab tests now
  state the route target per VRF and the SAFI by hand.

Measured against gobgpd 3.23.0 on 2026-11-04:

* **SAFI 128 works in both AFIs.** The config names are
  `l3vpn-ipv4-unicast` and `l3vpn-ipv6-unicast`; the client names are
  `vpnv4` and `vpnv6`. GoBGP reads the RD type, administrator and
  assigned number, the label, the route target and the attributes, and
  holds the same prefix once per RD. Its table key prints a type 2 RD in
  asdot, so the test reads the NLRI's own `rd` object.
* **GoBGP cannot check the RFC 4659 mapping.** It accepts the 12-octet
  VPN-IPv4 next hop under AFI 2 as well, and prints 192.0.2.1 for both
  forms. Measured by sabotage. The unit and functional tests are what
  check the 24 octets.
* **SAFI 129 is negotiated and then refused.** The session lists
  `l3vpn-ipv4-multicast` as advertised and received, and the first
  UPDATE in it is logged as "unknown route family. AFI: 1, SAFI: 129"
  with "Capability was disabled". The session stays up and a SAFI 128
  feed after it installs. The client has no name for the family.
  Asserted, not filed. So nothing outside bgp4r reads our SAFI 129
  octets.
* FRR is not installed in the sandbox this was written in, so there is
  no FRR case, as in phase 4a.

Tests: `test/unit/gen/vpn_test.rb`; `test/unit/gen_test.rb`'s property
test draws both families, with up to four VRFs and all three RD types;
`test/functional/gen_test.rb` sends both families over loopback;
`test/unit/sim/injector_test.rb` pins the plan total;
`test/functional/lab/gen_gobgp_test.rb` reads the VPN routes back from
GoBGP and asserts the SAFI 129 refusal.

**Phase 4c.** Flow specification rules, SAFI 133 and 134, both AFIs.
`Flow_rules` is a subclass of `Unicast` and `Flow_rules_vpn` of
`Flow_rules`, so the packer, the patterns and the sender are shared.

* **One rule per destination prefix.** `start` and `count` give the
  destination, so a rule set N wide is one spec. `source`, one prefix,
  `protocol` and `destination_port` are optional, each one `eq` match,
  and the last two are values or patterns. A port range, and the other
  components of RFC 8955 section 4.2.2, are not read yet; `mp_reach`
  sends any rule by hand.
* **Components run on the route number and actions on the group.** A
  component is part of the NLRI, as a label or a Path Identifier is. An
  action is an extended community and so an attribute: `rate`
  (section 7.1, AS field 0), `redirect` as `ADMIN:N` in the layout its
  administrator picks (section 7.4), and `marking`, a DSCP (section
  7.5). They join the spec's own extended communities in one attribute.
* **No next hop.** RFC 8955 section 4: "the Length of the Next-Hop
  Network Address MUST be set to 0". The Sender's address is dropped
  for these families. A `next_hop` the spec gives itself is sent.
* **A rule is as long as its components.** Port 80 is one octet and
  8080 two, so each rule is measured on its own. `Unicast` grew
  `route_len` for this, the octets of one route, which is the same
  number for every route in the other families.
* **`PerVrf` holds what VPN and VPN flow spec share**: `rd`, `vrfs`,
  `route_target`, one VRF per copy of the range. It came out of
  `Vpn`, whose tests pass unchanged.
* **A gap in the receive checks this found.** validation.rb walks a
  flow spec rule without knowing add-path was negotiated, so a rule
  with a Path Identifier is reported as a rule with no component, or
  an RD of 0 octets for SAFI 134. The rule decodes, and the generator
  writes the identifier where RFC 7911 section 3 puts it. The property
  test gives flow spec feeds no Path Identifier for that reason, and
  `test_the_receive_checks_do_not_know_add_path_yet` pins the gap. The
  other NLRI walks in validation.rb, EVPN, MCAST-VPN and BGP-LS, have
  the same shape and were not measured here.
* **What `expected` cannot catch, a third time.** A component read off
  the group number, a rate taken from the next group, a route target
  from the first VRF, and SAFI 134 sent as 133 each pass a comparison
  with `expected`. The unit, functional and lab tests state each by
  hand.

**Phase 4d.** EVPN route types 2, 3 and 5, AFI 25 SAFI 70.
`Evpn_routes` is a subclass of `Unicast` that includes `PerVrf`, so
one spec is one route type and `vrfs` copies of it, one per EVI.

* **`route_type` is required, and `start` means what steps in it.**
  Type 2's is a MAC, `00:11:22:00:00:00`, with an optional `ip` that
  steps beside it. Type 3's is the Originating Router's IP Address, so
  N routes are N PEs. Type 5's is a prefix, stepped as unicast steps it,
  with a fixed `gateway`. A key that belongs to another route type is
  refused by name, as a family key on another family is.
* **`label` is required for types 2 and 5**, as for labelled. It is
  MPLS Label1 of type 2 and the label of type 5, and runs on the route
  number. `ethernet_tag` does too. `esi` is fixed, 10 octets of hex,
  and defaults to zero, the single-homed ESI of RFC 7432 section 5.
* **Two attributes are the family's own.** `mac_mobility` is the
  sequence number of RFC 7432 section 7.7, with the sticky flag clear,
  on the group number, so a MAC move is a new value. `router_mac` is
  RFC 9135 section 8.1's community, for types 2 and 5. Both join the
  spec's own extended communities and the EVI's route target in one
  attribute.
* **`pmsi_label` gives each type 3 route a PMSI Tunnel**, Ingress
  Replication, with the route's own originator as the Tunnel
  Identifier. RFC 7432 section 11.2 asks for "a routable address of the
  PE", and each route is a PE here. So no two routes share an attribute
  set and each is a message of its own.
* **The next hop is the session's**, RFC 7432 section 14, a real
  address read by its length. The Sender fills it in as for unicast.
* **A withdrawal is the same NLRI in MP_UNREACH_NLRI.** The receiver
  matches the route key, which leaves out the ESI, the labels and the
  gateway, so sending them as announced costs nothing.
* **The add-path gap of phase 4c holds for EVPN, measured.**
  validation.rb reads the Path Identifier's four octets as a Route Type
  and a Length. The property test gives EVPN feeds no Path Identifier,
  and `evpn_routes_test.rb` pins the gap.
* **A test this phase wrote sent a route RFC 9136 section 3.2 forbids**,
  a non-zero ESI and a non-zero gateway on one type 5 route, and the
  strict read refused it. The test sends them one at a time now, and
  `test_nothing_validates` sends both on purpose.
* **What `expected` cannot catch, a fourth time.** A route target from
  the first EVI, a PMSI Tunnel naming the first PE, and a MAC that does
  not restart in each EVI each pass a comparison with `expected`. The
  unit, functional and lab tests state each by hand.
* **GoBGP 3.23.0 reads all three types back**, labels as the whole
  three-octet field, 16 as 257, and the PMSI Tunnel's label with no
  bottom of stack bit, 10 as 160. FRR was not run here.

Measured against gobgpd 3.23.0 on 2026-11-04:

* **Both SAFIs and both AFIs install.** GoBGP reads every component by
  its type number with the operator octet whole, 0x81 for a one octet
  value and 0x91 for a two octet port, the RD of section 8, and all
  three actions with the rate per group.
* **GoBGP prints a next hop of length 0 as its family's unspecified
  address**, 0.0.0.0 under AFI 1 and :: under AFI 2.
* FRR is not installed in the sandbox this was written in, so there is
  no FRR case. FRR 8.4.4 has SAFI 133 and not SAFI 134
  (docs/flow-spec.md section 12).

Tests: `test/unit/gen/flow_rules_test.rb`; `test/unit/gen_test.rb`'s
property test draws both families, dealt out in turn so every family
gets three feeds; `test/functional/gen_test.rb` sends three feeds over
loopback; `test/unit/sim/injector_test.rb` sends one through the
injector over eBGP; `test/functional/lab/gen_gobgp_test.rb` reads all
three back from GoBGP.
