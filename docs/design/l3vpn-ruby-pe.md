# A PE of our own daemons: bgp4rd with isisd or ospfd

Status: draft, for the owner's review. No code yet. It goes with
`docs/design/l3vpn-pe.md`, the L3VPN PE in bgp4rd, and needs its pull
requests 1 to 3 (7 for a bgp4rd CE).

## The problem

`l3vpn-pe.md` builds a PE from bgp4rd and isisd, and checks it against
FRR as the other PE. We also want labs where every PE, P and CE runs
our own code: bgp4rd for the VPN routes, and our IGP for the core,
either isisd or ospfd.

```
  ce1 ---- pe1 ---------- p ---------- pe2 ---- ce2
           bgp4rd         isisd        bgp4rd
           + isisd        or ospfd     + isisd
           or ospfd                    or ospfd
```

The two IGPs differ in one thing that matters here: isisd gives MPLS
transport labels (SR-MPLS, isis `docs/design/sr-mpls.md`, built), and
ospfd gives none (SR in OSPF is routescope's P7, not started). So the
transport to the far PE has to come from somewhere else in an OSPF
core.

RFC 4364 section 5 allows it:

> "If the backbone does not support MPLS, the MPLS packet carrying only
> the VPN route label may be tunneled to the BGP Next Hop using the
> techniques of [MPLS-in-IP-GRE]."

[MPLS-in-IP-GRE] is RFC 4023.

## What exists

Measured on the lab VM, 2026-11-16 and 17.

- **A PE is two containers in one namespace.** In containerlab, a node
  with `network-mode: container:pe1` shares pe1's network namespace
  (`l3vpn-pe.md`, "What exists"). The bgp4r-lab, isis4r and ospfv2
  images all carry `ip`, so bgp4rd's commands run whichever IGP image
  it sits beside.
- **isisd puts its SR label on the route to the far PE.** `ip -j route
  get` shows it as `"encap":{"encap_type":"mpls","dst":"18004"}`
  (`l3vpn-pe.md`, decision 3).
- **ospfd installs plain IP routes.** In its own namespace, protocol
  `ospfv2` (89) (ospfv2 `docs/user-guide.md`). No labels.
- **The kernel carries the VPN label both ways.** Two labels across an
  SR core, and one label inside GRE across a core with no MPLS, both
  measured in network namespaces (`l3vpn-pe.md`, "What exists").

## The design

### The transport for each core

`l3vpn-pe.md`'s decision 3 gives bgp4rd two transports, chosen per
remote PE: `mpls`, the IGP's labels and then the VPN label, and `gre`,
the VPN label alone inside a GRE tunnel between the PEs' loopbacks.
Each lab here uses the one its core allows:

| Core | Transport | Why |
| --- | --- | --- |
| isisd | `mpls` | isisd puts its SR label on the route to the far PE |
| ospfd | `gre` | ospfd's routes carry no labels until SR in OSPF (P7) |

In the OSPF lab each PE has one GRE device toward the other, made by
the lab, with MPLS input on:

```yaml
l3vpn:
  labels: { start: 24000, size: 1000 }
  transport: gre                  # every remote PE over GRE here
  tunnels:
    10.255.0.2: { gre: gre-pe2 }
```

The tunnel's outer packets follow ospfd's routes between the loopbacks,
so a core reroute needs nothing from bgp4rd.

### The IGP's part

Nothing new in isisd or ospfd. Each PE's IGP advertises the PE's
loopback, the BGP next hop: isisd with its Node-SID, ospfd as a plain
/32. RFC 4364 section 5 asks the PEs to "insert /32 address prefixes
for themselves into the IGP routing tables of the backbone".

When ospfd gains SR (routescope P7), an OSPF core can switch to
`mpls`, and its lab keeps the same shape.

### The CEs

Each lab has two kinds, to show both:

- a Linux node with a default route to its PE;
- a bgp4rd over eBGP, with `l3vpn-pe.md`'s pull request 7, both sites
  in the private AS 65101, the PE overriding it.

## The labs

Two labs in bgp4r's `routescope/labs/`, one per IGP, the same shape:

```
  ce1a (Linux) --+                              +-- ce2a (Linux)
                 pe1 ----- p1 ----- pe2
  ce1b (bgp4rd) -+    \           /    +-- ce2b (bgp4rd)
                       --- p2 ---
```

- **`l3vpn-ruby-isis`**: pe1, p1, p2 and pe2 run isisd with SR, each
  with its own SRGB so a label from the wrong block would show. pe1 and
  pe2 add bgp4rd beside isisd. Transport `mpls`.
- **`l3vpn-ruby-ospf`**: the same with ospfd, and GRE between pe1 and
  pe2. Transport `gre`.
- VRF A joins the `a` CEs, VRF B the `b` CEs, on the same addresses,
  kept apart by RD and RT.
- p2 is the longer path, for the reroute.

## Pull requests

After `l3vpn-pe.md`'s pull requests 1 to 3, which bring both
transports:

1. **`l3vpn-ruby-isis`**, with Linux CEs, its ABOUT.md and a scenario.
2. **`l3vpn-ruby-ospf`**, the same, with its GRE tunnels.
3. **bgp4rd CEs** in both labs, after `l3vpn-pe.md`'s pull request 7.

## Tests

- Unit: none of its own; the transports' tests are in `l3vpn-pe.md`.
- Lab: the gate below, as each lab's scenario. The OSPF lab is the
  `gre` transport's gate.

## Gate

On each lab:

- ce1a pings ce2a. In `l3vpn-ruby-isis`, tcpdump on the pe1 to p1 link
  shows two labels: pe2's Node-SID in p1's block, and pe2's VPN label.
  In `l3vpn-ruby-ospf` it shows a GRE packet between the loopbacks,
  holding one label, pe2's VPN label, and the IP packet.
- ce1b and ce2b (bgp4rd) learn each other's prefixes over eBGP through
  their PEs, and ping on the same addresses as ce1a and ce2a, through
  VRF B. ce1a cannot reach ce2b.
- The p1 to pe2 link down: traffic moves to p2. In the IS-IS lab the
  transport label changes to p2's block; in the OSPF lab the GRE packets
  take the other path and the label stays the same. Link up: back.

## Out of scope

- LDP, as in `l3vpn-pe.md`.
- MPLS in UDP (RFC 7510), and GRE keys or checksums.
- bgp4rd making its own tunnels.
- One image holding both daemons.

## Open questions

1. **Two labs, or one with a choice of IGP?** The draft has two, so
   each is plain to read and its scenario fixed.
2. **MTU, and who makes the tunnels:** both are `l3vpn-pe.md`'s open
   questions now, since the `gre` transport is there.
