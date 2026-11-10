# OSPFv2 as a BGP-LS Producer source

Status: draft, for approval.

Two other specs go with this one: ospfv2 `docs/design/ospf-topology.md`
(ospfd's `show.topology` and its `topology` event) and routescope
`docs/design/bgp-ls-ospf.md` (the lab, phase 3 of BGP-LS).

## The problem

bgp4rd's Producer (`docs/design/bgp-ls-producer.md`) reads isisd and
sends an IS-IS domain as BGP-LS (RFC 9552). Phase 3 adds an OSPFv2
domain. ospfd will answer `show.topology` per area and for the AS, in
the same spirit as isisd's. The Producer must read it and build the
NLRIs RFC 9552 gives OSPF, which differ from IS-IS's in their
Protocol-ID, descriptors, pseudonode, metric width and prefixes.

The collector must show what arrives: today its row has no OSPF Area-ID
and no route type, and an 8-octet pseudonode prints as hex.

## What exists

Read on master at 4ca0753.

- **The codec has every TLV needed**:
  - 514 `Ospf_area_id` (`bgp/nlris/link_state_descriptor.rb:99`);
  - 515 `Igp_router_id` with 4- and 8-octet OSPF shapes (`:151-165`);
  - 259 and 260 (`link_state_link_descriptor.rb:64`, `:78`);
  - 264 `Ospf_route_type` (`link_state_prefix_descriptor.rb:61`);
  - 1024 with E and B (`link_state_node_attribute.rb:100-105`);
  - 1095 at 2 octets (`link_state_link_attribute.rb:698-705`);
  - 1155 and 1156 (`link_state_prefix_attribute.rb:258`, `:307`).
  - Protocol-ID 3 is named, and `node_type` reads 4 and 8 octets for it
    (`link_state_nlri.rb:105-115`, `208-216`).
- **The Producer is IS-IS only** (`bgp/daemon/link_state_producer.rb`):
  - `KEYS = %w[isisd levels identifier peers unreachable]` (56);
  - the Protocol-ID is the topology's `level` (121);
  - it waits for isisd's `spf` event of a configured level (368-387);
  - `router_id` parses a system ID. A dotted quad gives wrong octets:
    `'10.0.0.1'` becomes 3 octets (230-233);
  - nodes get O and A flags, 1026 and 1027; links a 1- or 3-octet 1095;
    prefixes 1155 only (196-221).
- **The collector's row** (`bgp/daemon/link_state_table.rb:76-136`):
  `areas` reads only 1027; a 4-octet node prints as a dotted quad, an
  8-octet one as bare hex; no route type. The CLI's column "L" prints
  the Protocol-ID (`bgp/daemon/cli.rb:303-321`).

## The design

### Configuration

```yaml
link_state:
  ospfd: /run/ospfv2/ospfd.sock    # in place of isisd:
  areas: [0.0.0.0, 0.0.0.1]        # in place of levels:
  external: true                   # Type 5 LSAs too; the default
  identifier: 1
  peers: [10.2.0.10]
  unreachable: withdraw
```

- A block names `isisd` or `ospfd`, not both, and not neither. An
  absent source still means `isisd` at its default path, so every
  phase 1 and 2 file reads as before.
- `areas` only with `ospfd`, `levels` only with `isisd`. Each area is a
  dotted quad or a number. Default `[0.0.0.0]`.
- `external` only with `ospfd`. Default true.
- `identifier`, `peers`, `unreachable` as today.

One source per Producer. Two domains on one box are two bgp4rd
processes. The Producer stays one socket, one thread, one `@sent`.

### Reading ospfd

- Connect to `ospfd`, `events.subscribe { kinds: ["topology"] }`, then
  read `show.topology` for each configured area, and `{ scope: "as" }`
  when `external`.
- Re-read after a `topology` event whose area is configured, or whose
  scope is `as` when `external`. Keep reading 0.1 s more, as for isisd,
  so a run over several areas gives one read.
- The same retry, diff and send as today. The source is a small object
  with `subscribe`, `read` and `changed?(event)`; isisd's becomes the
  first one, with no change in what it sends.

### Routes built from one OSPF area

Protocol-ID 3 on every NLRI. Identifier from the config.

- **A Node NLRI per reachable node.**
  - Local Node Descriptors: OSPF Area-ID (514), the area; IGP Router-ID
    (515), the 4-octet Router-ID, or for a network node the 8 octets of
    the DR's Router-ID and its interface address (RFC 9552 5.2.1.4).
    In ascending order, 514 then 515 (5.2.1.4: "MUST be arranged in
    ascending order").
  - Attribute: Node Flag Bits (1024), B when `abr`, E when `asbr`. No
    Node Name: ospfd has no hostname (routescope's spec, decision 1).
- **A Link NLRI per neighbor of a reachable node.**
  - Local and Remote Node Descriptors as above, both with the area.
  - Link Descriptors: for a p2p neighbor with `address` and
    `remote_address`, IPv4 interface address (259) and IPv4 neighbor
    address (260). Section 5.2.2: "If interface and neighbor addresses
    ... are present, then the interface/neighbor address TLVs MUST be
    included". Without `remote_address`, none: "it is valid to
    advertise a BGP-LS Link NLRI without any of these identifiers".
    Transit links, to and from a network node, have none.
  - Attribute: IGP Metric (1095), 2 octets. Section 5.3.2.4: "OSPF link
    metrics have a length of 2 octets." A network node's links carry 0.
- **A Prefix NLRI per prefix of a reachable node.**
  - Local Node Descriptors: the node, with the area.
  - Prefix Descriptors: OSPF Route Type (264), from `route_type`; IP
    Reachability Information (265). Section 5.2.3.1: the route type
    "MUST be included in the advertisement when the type is either
    being signaled explicitly in the underlying LSA or can be
    determined via another LSA".
  - Attribute: Prefix Metric (1155).

### Routes built from the AS scope

For each reachable ASBR in `scope: "as"`:

- A Prefix NLRI per external prefix. Local Node Descriptors: IGP
  Router-ID (515) only, no Area-ID: it "is not used for NLRIs when
  carrying information that is derived from AS-scope LSAs" (5.2.1.4).
  Route type External 1 or 2. Attribute: Prefix Metric (1155), and OSPF
  Forwarding Address (1156) when it is not 0.0.0.0.
- No Node NLRI: the ASBR's Node NLRI comes from its area, with its area.

### Unreachable

A node with `reachable: false` gives nothing, as for IS-IS (section
5.9), with `unreachable: keep` to turn that off. An ASBR not reachable
gives no external prefixes.

### The collector's row and CLI

Additive fields in `show.link_state`'s row:

- `area`: the OSPF Area-ID (514) of the local node, as a dotted quad,
  or nil. `areas` keeps IS-IS's 1027.
- `route_type`: 264's name (`intra`, `inter`, `external_1`,
  `external_2`, `nssa_1`, `nssa_2`), or nil.
- `forwarding`: 1156, or nil.
- `local` and `remote`: an 8-octet OSPF node prints as `DR:address`,
  two dotted quads, in place of hex.

`bgp4r-cli -c 'show link-state'`: the column "L" becomes "Proto", with
`L1`, `L2` or `OSPF`; a column "Area" after it; the route type in the
"Node" column for a prefix. The layout is bgp4r's own, as
`docs/daemon.md` says, so this is not an API change.

### What it does not change

- What the Producer sends for IS-IS, byte for byte. The tests that
  check it stay as they are.
- `show.link_state`'s existing fields.

## Pull request

One: bgp4r `claude/bgp-ls-ospf`. This spec first. Then:

- the source object, isisd's, then ospfd's;
- the OSPF mapping;
- the row's new fields and the CLI's columns;
- `docs/daemon.md` (the `link_state` block), `docs/bgp-ls.md` section
  12, and CLAUDE.md's "The BGP-LS lab" with phase 3.

## Tests

- **Config**: `ospfd` with `areas` and `external`; both sources, an
  area under `isisd`, a level under `ospfd`, a bad area: refused.
- **A fake ospfd**, `test/helpers/fake_ospfd.rb`, as `fake_isisd.rb`:
  `show.topology` by area and AS, and `topology` events.
- **Mapping, byte for byte**:
  - a Node NLRI with 514 then 515, 4 octets, B and E;
  - a network node's 8-octet 515;
  - a p2p Link NLRI with 259 and 260, 2-octet 1095; one without
    `remote_address`, with neither;
  - router to network, network to router at 0;
  - an intra-area prefix with 264 and 1155;
  - an external with no 514, External 2, 1156.
- **Behaviour**: first read; a metric change; a router unreachable,
  withdrawn, and back; an area not configured, not read; a `topology`
  event for another area, ignored; the AS scope off with `external:
  false`.
- **IS-IS unchanged**: the existing Producer tests pass as they are.
- **Collector**: `area`, `route_type`, `forwarding` and the 8-octet
  `DR:address` in the row; the CLI's new columns.
- **Loopback**: Producer to collector with the fake ospfd, as
  `test/functional/link_state_daemon_test.rb` does for isisd.
- The full unit suite: `ruby test/run_unit.rb`.

## Gate

routescope's phase 3 lab: col's table matches o2's `show.topology` for
both areas and the AS, through routescope's comparison.

## Open questions

- NSSA (Type 7) is in the mapping but not in the lab. Tested by unit
  tests only.
- An ABR's Node NLRI appears once per area, each with its area. That is
  what 514 in the Node Descriptor means ("different NLRIs of the same
  router to be differentiated on a per-area basis", 5.2.1.4). A
  consumer joins them by Router-ID.
