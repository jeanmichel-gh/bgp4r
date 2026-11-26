# EVPN in bgp4rd over MPLS

Status: draft, 2026-11-26, for the owner's approval. Its questions are
at the end.

This is the second half of P5 in routescope's `docs/protocol-coverage.md`:
"EVPN in bgp4rd. MAC-VRF and an EVPN RIB, VXLAN first [...], then over
MPLS". The first half is `docs/design/evpn.md`, built (#382 to #397).
That spec put EVPN over MPLS out of scope, "the second half of P5".

## The problem

```
      h1                                        h2
       |                                         |
     pe1  isisd (SR), bgp4rd, vtep4rd          pe2  isisd (SR), bgp4rd, vtep4rd
   10.255.0.1         \                    /    10.255.0.2
                        p   isisd (SR), bgp4rd (route reflector)
                     10.255.0.9
```

h1 and h2 share one Ethernet segment across an SR-MPLS core. pe1 sends
h1's frame to pe2 under two labels: pe2's node SID, which the core
switches, and the EVPN label pe2 advertised for the MAC-VRF. pe2 pops
its own label, looks up the MAC and sends the frame to h2.

Today bgp4rd keeps such a route and does not install it. A type 2 or 3
route with no Encapsulation community naming VXLAN is `invalid`
`encapsulation` (`evpn.md`, Receiving, step 7). That rule stays for a
VXLAN MAC-VRF. This spec adds MAC-VRFs over MPLS.

## What exists

**The kernel switches an Ethernet payload under labels, and cannot end
it.** Measured on ospflab, 2026-11-26, kernel 7.0.0-43, in four network
namespaces: A sends a raw frame, P switches labels, B is the egress, C
is past it. The inner frame is an Ethernet header and 46 octets of
zero. The script is at the end of this document. Pull request 0 makes
it a test.

| Case | A sends | P's route | Seen at B | Past B's pop of 200 |
| --- | --- | --- | --- | --- |
| PHP | 100, 200, frame | `100 via inet 10.0.2.2` | 200, frame, intact | dropped |
| Swap | 101, 200, frame | `101 as 111 via inet 10.0.2.2` | 111, 200, frame, intact | dropped |
| MAC 46:00:… | 100, 200, frame | as PHP | 200, frame, intact | **sent to C as IPv4, with octets rewritten** |
| Pop to the frame at P | 100, frame | as PHP | nothing | |

So:

- A P router on the kernel carries EVPN traffic. isisd's SR label
  routes need no change.
- The egress PE's kernel must not pop the EVPN label. With a route, a
  frame is dropped, or worse: a destination MAC whose first nibble is 4
  is taken for IPv4, and its octets 8 to 11 rewritten as a TTL and a
  checksum (`3f00 c200` where `0200 0000` was sent).
- A packet socket on B saw every frame, those the kernel then dropped
  included (tcpdump on `bp`, with `net.mpls.conf.bp.input=1`). So a
  data plane in Ruby can read the EVPN label's frames raw while the
  kernel switches everything else.

**RFC 7432's data plane over MPLS.**

- Label1 of a type 2 route is "downstream assigned [...] associated
  with the MAC address being advertised". Its allocation "is purely
  local": per MAC-VRF, per MAC-VRF and Ethernet tag, per ESI and tag,
  or per MAC (section 9.2.1).
- A type 3 route with Ingress Replication "MUST carry a downstream
  assigned MPLS label", to "demultiplex the broadcast, multicast, or
  unknown unicast EVPN traffic" (section 11.2). "The PE that receives a
  packet with this particular MPLS label MUST treat the packet as a
  broadcast, multicast, or unknown unicast packet" (section 12.1).
- Toward a known MAC, the packet goes "in the EVPN MPLS label
  advertised by the remote PE, for that MAC address, and in the MPLS
  LSP label stack to reach the remote PE" (section 13.1).
- Section 18, frame ordering: a MAC whose first nibble is 4 or 6 "can
  be misinterpreted as an IPv4 or IPv6 packet by intermediate P nodes
  performing ECMP based on deep packet inspection". Then "the
  'Preferred PW MPLS Control Word' [RFC4385] SHOULD be used with the
  value 0", unless the network uses entropy labels.
- RFC 8365 section 5.1.3, quoted in `evpn.md`: without an
  Encapsulation community, "either MPLS encapsulation or a statically
  configured encapsulation is assumed".

**bgp4rd's L3VPN PE reaches a remote PE this way already**
(`l3vpn-pe.md`, "`mpls`"). It reads `ip -j route get NH` for the BGP
next hop: the `encap` labels, gateway and device. Its VRF route pushes
those labels and the VPN label below them. It allocates its labels
from `l3vpn: labels: { start: 24000, size: 1000 }`. The l3vpn-lab runs
it over isis4r SR (bgp4r `routescope/labs/l3vpn-lab`).

**vtep4rd is a bridge in Ruby.** Host ports are raw sockets through
datalink-socket (`vxlan/vtep/ports.rb`). The tunnel edge is a UDP
socket (`vxlan/vtep/tunnel.rb`). Bridge domains, the MAC table, the
`evpn` mode and its API (`mac.add`, `vni.flood.add`, events) are what
bgp4rd drives today.

**Who forwards EVPN over MPLS on Linux.** FRR's EVPN data plane is the
kernel's VXLAN and bridge, and the kernel cannot end the label (above).
So FRR is no data plane interop peer here; pull request 0 checks this
against FRR 10.7.1 rather than assume it. GoBGP has no data plane;
`test/functional/lab/evpn_gobgp_test.rb` already exchanges EVPN routes
with it. SR Linux is in routescope's labs; whether its release there
forwards EVPN over MPLS is question 4.

## Decisions

Each has the draft's choice. The owner may change any.

### 1. The data plane is vtep4rd, with an MPLS edge

vtep4rd gains a second edge beside the UDP one. Its bridge domains,
MAC table, ports, events and API stay. A bridge domain says its
encapsulation, `vxlan` or `mpls`. The kernel is no option (above). A
new daemon would copy vtep4rd's bridge.

### 2. The egress reads its labels raw; the kernel never sees a route for them

vtep4rd reads frames of EtherType 0x8847 on the core devices, keeps
those whose top label is one of its own, and leaves the rest to the
kernel. bgp4rd installs no kernel label route for an EVPN label, unlike
an L3VPN label. The kernel drops what it has no route for, and vtep4rd
has its copy (measured above).

### 3. The ingress pushes the stack itself and sends raw

For each remote PE, vtep4rd reads the transport as the L3VPN PE does,
`ip -j route get NH`: labels, gateway, device. It takes the gateway's
MAC from the neighbour table, `ip -j neigh`. It sends Ethernet to that
MAC, the transport labels, the EVPN label, the control word, the frame.
A remote PE with no labelled route is not reached, and `show.vnis`
says so.

### 4. Two labels per MAC-VRF

One for known unicast (Label1 of each type 2 route), one for BUM (the
PMSI label of the type 3 route), from a block of bgp4rd's own:
`evpn: labels: { start: 25000, size: 1000 }`. Per MAC-VRF is the
first of section 9.2.1's four, and the fewest labels. A frame under
the BUM label is flooded to the local ports, as section 12.1 asks; a
frame under the unicast label is looked up.

### 5. The control word, always

Sent as four octets of zero after the EVPN label, and expected on
receipt (section 18). Nothing in the routes signals it, so both PEs
must agree; ours always do. A setting to turn it off waits for an
interop peer that needs it.

### 6. No Encapsulation community on an MPLS route

A route of an MPLS MAC-VRF is sent without one, as RFC 8365 section
5.1.3 allows. On receipt, an MPLS MAC-VRF takes a route with none,
and a VXLAN MAC-VRF still refuses it.

## The design

### Configuration

```yaml
local_address: 10.255.0.1
evpn:
  labels: { start: 25000, size: 1000 }   # must not overlap l3vpn: labels or the SRGB
macvrfs:
  - vni: 100                             # the bridge domain's number in vtep4rd
    encapsulation: mpls                  # vxlan, the default, or mpls
    rd: 10.255.0.1:100
    import: [65000:100]
    export: [65000:100]
```

`vni:` stays the key of a MAC-VRF and of vtep4rd's bridge domain, so
the API and routescope's views keep one name. Over MPLS it is never on
the wire (question 2).

bgp4rd refuses at start a label block that overlaps `l3vpn: labels`.
It cannot see the SRGB, so the lab's files keep them apart.

### Receiving

`evpn.md`'s steps 4 to 8, with these changes for an MPLS MAC-VRF:

- Step 7, the encapsulation: a route with no Encapsulation community is
  taken. One naming VXLAN is `invalid` `encapsulation`.
- Step 6, the VNI: there is none to match. Label1 and the PMSI label
  are the remote PE's labels, taken whole as 20 bits.
- A type 3 route still needs Ingress Replication (`pmsi`).

### Exporting

As `evpn.md`'s, with Label1 the MAC-VRF's unicast label, the PMSI
label its BUM label, and no Encapsulation community. MAC Mobility, the
duplicates, the hold and the reflector are unchanged.

### vtep4rd's API

- `vni.add` takes `encap: mpls` and the two labels, `unicast` and
  `bum`. bgp4rd sets them with `vni.labels`, so a vtep4rd that
  restarts gets them back at the next sync.
- `mac.add` and `vni.flood.add` take a `label`: the remote PE's.
- `show.vnis` gains `encap` and the labels; `show.macs` the label;
  a new `show.transport` gives each remote PE's resolved stack,
  gateway, MAC and device, and since when.

### The MPLS edge in vtep4rd

- **Codec.** A label stack entry and the control word, built the four
  ways of `protocol-conventions.md`, with validation and faults: a
  missing bottom of stack, a control word not zero, a label not ours.
- **Receive.** A raw socket per core device, EtherType 0x8847. The top
  label is the EVPN label after PHP. With an explicit null on top, it
  is skipped (question 3).
- **Send.** The stack above, out of the device of the transport.
- **Resolution.** Each remote PE's transport is read again every second
  and when bgp4rd adds one. How fast a core failure moves traffic is
  measured in pull request 0 and recorded.

## Labs

**`evpn-mpls-ruby`, in routescope**, every node our code: l3vpn-lab's
SR core of isis4rd, with bgp4rd and vtep4rd on pe1 and pe2, bgp4rd on
p as the reflector, and two hosts. Its `ABOUT.md` says it is the main
lab. Scenarios: first ping, a remote MAC, a MAC move, a duplicate,
the core link down with traffic moving, each run twice with times.

**Interop:** control plane only, GoBGP's EVPN routes with MPLS labels
both ways (`evpn_gobgp_test.rb`). Data plane interop waits for a
released router that has it (question 4).

## Pull requests

0. **vtep4r: the MPLS edge.** In vtep4r's own rules: the codec, the
   edge, the API above, the measurements of this spec as tests in
   network namespaces, the resolution's timing, and the check of FRR.
1. **bgp4r: MPLS MAC-VRFs.** `encapsulation:`, the label block, the
   receiving and exporting changes, vtep4rd's orders with labels,
   `show.macvrfs` and `show.macvrf` with the labels.
2. **bgp4r: interop.** `evpn_gobgp_test.rb` with MPLS routes both ways;
   `coverage_matrix.rb` follows.
3. **routescope:** the labels in the EVPN views, and `evpn-mpls-ruby`
   with its CI lane.

## Tests

- Unit: the label allocator (a block used up, a MAC-VRF removed), the
  encapsulation rule both ways, Label1 and the PMSI label taken whole,
  the orders vtep4rd gets.
- Functional: two bgp4rd on loopback with a fake vtep4rd, as
  `evpn_daemon_test.rb`, over MPLS MAC-VRFs.
- vtep4r: the edge in network namespaces against the kernel's label
  switching, as measured above.
- Lab: the gate.

## Gate

On `evpn-mpls-ruby`:

- h1 pings h2. A capture on p shows pe2's node SID, the EVPN label,
  the control word and h1's frame.
- Each PE's vtep4rd floods to the other from the type 3 route alone.
- A MAC starting 46: crosses intact.
- p's link down with a second path: traffic moves, in a time recorded.
- `mac-move` and `duplicate`, as on `evpn-ruby`.

## Out of scope

- Multihoming, ARP suppression, type 5 and the rest of `evpn.md`'s list.
- P2MP LSPs for BUM (sections 11.2 and 16.2).
- Entropy labels (RFC 6790), and a control word turned off.
- Other label allocations than per MAC-VRF.
- EVPN over SRv6 (P6), and LDP or RSVP-TE transport.

## Questions for the owner

1. **vtep4rd as the MPLS data plane** (decision 1), rather than a new
   daemon. Its name says VXLAN.
2. **`vni:` as the MAC-VRF's key over MPLS**, though no VNI is on the
   wire, or a new key (`evi:`, `bd:`) with `vni:` kept for VXLAN.
3. **Explicit null.** isis4rd's SR uses PHP. Should vtep4rd also take
   label 0 on top, for a core that sends explicit null?
4. **SR Linux as a data plane interop peer**, if the release in
   routescope's labs forwards EVPN over MPLS. To be checked before the
   lab, or left out.
5. **The label block's default**, 25000 to 25999, beside L3VPN's 24000.

## The measurement's script

Run as root. `send.py`, beside it, sends one raw frame:

```python
import socket, sys, struct
# send.py IFACE DSTMAC LABELS(comma, last is BoS) INNER_DST_MAC
ifc, dst, labels, inner_dst = sys.argv[1], sys.argv[2], [int(x) for x in sys.argv[3].split(',')], sys.argv[4]
mac = lambda s: bytes(int(x, 16) for x in s.split(':'))
s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW)
s.bind((ifc, 0))
src = open(f'/sys/class/net/{ifc}/address').read().strip()
stack = b''.join(struct.pack('!I', (l << 12) | ((1 if i == len(labels) - 1 else 0) << 8) | 64) for i, l in enumerate(labels))
inner = mac(inner_dst) + mac('02:00:00:00:01:01') + b'\x08\x00' + bytes(46)
s.send(mac(dst) + mac(src) + b'\x88\x47' + stack + inner)
```

`run.sh`:

```sh
#!/bin/bash
# Kernel MPLS with an Ethernet payload: transit (pop non-BoS, swap) and egress (pop BoS).
set -u
D=$(dirname $0)
for n in a p b c; do ip netns del evm-$n 2>/dev/null; ip netns add evm-$n; done
ip link add ap netns evm-a type veth peer name pa netns evm-p
ip link add pb netns evm-p type veth peer name bp netns evm-b
ip link add bc netns evm-b type veth peer name cb netns evm-c
for x in "a ap" "p pa" "p pb" "b bp" "b bc" "c cb"; do set -- $x; ip -n evm-$1 link set $2 up; ip -n evm-$1 link set lo up; done
ip -n evm-p addr add 10.0.2.1/24 dev pb; ip -n evm-b addr add 10.0.2.2/24 dev bp
ip -n evm-b addr add 10.0.3.1/24 dev bc; ip -n evm-c addr add 10.0.3.2/24 dev cb
for n in p b; do ip netns exec evm-$n sysctl -qw net.mpls.platform_labels=1000; done
ip netns exec evm-p sysctl -qw net.mpls.conf.pa.input=1
ip netns exec evm-b sysctl -qw net.mpls.conf.bp.input=1
ip -n evm-p -f mpls route add 100 via inet 10.0.2.2 dev pb          # pop (PHP)
ip -n evm-p -f mpls route add 101 as 111 via inet 10.0.2.2 dev pb   # swap
ip -n evm-b -f mpls route add 200 via inet 10.0.3.2 dev bc          # egress pop to IPv4
ip -n evm-b -f mpls route add 201 via inet6 fe80::1 dev bc 2>/dev/null
ip netns exec evm-b tcpdump -l -i bp -e -nn -x 2>/dev/null > $D/bp.txt & T1=$!
ip netns exec evm-c tcpdump -l -i cb -e -nn -x 2>/dev/null > $D/cb.txt & T2=$!
sleep 2
PA=$(ip netns exec evm-p cat /sys/class/net/pa/address)
s() { ip netns exec evm-a python3 -I $D/send.py ap $PA "$1" "$2"; sleep 0.3; }
s 100,200 02:00:00:00:01:02     # 1 transit pop: 200+frame expected at B
s 101,200 02:00:00:00:01:02     # 2 transit swap: 111,200+frame at B
s 100,200 46:00:00:00:01:02     # 3 transit pop, inner MAC that looks like IPv4
s 100 02:00:00:00:01:02         # 4 PHP of BoS label at P, L2 payload
s 200 02:00:00:00:01:02         # 5 at P: no route for 200
sleep 1; kill $T1 $T2 2>/dev/null; wait 2>/dev/null
echo "== at B (bp)"; cat $D/bp.txt
echo "== at C (cb), after B's egress pop"; cat $D/cb.txt
echo "== P and B mpls stats"; ip netns exec evm-p cat /proc/net/dev | grep -E "pa|pb"; ip -n evm-p -s link show pa | sed -n 1,6p
for n in a p b c; do ip netns del evm-$n; done
```
