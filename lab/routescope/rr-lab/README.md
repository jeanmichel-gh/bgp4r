# rr-lab

Route reflection, RFC 4456, with a bgp4rd as the reflector and FRR,
BIRD, GoBGP and a second bgp4rd as its clients. Nine nodes, four
implementations, one containerlab topology. Three bgp4r injectors make
the routes to reflect.

`ABOUT.md` is the short version, the one routescope shows.

```
                        AS 65100 (iBGP, two clusters)

inj-c (bgp4r-sim) --client-----\
inj-n (bgp4r-sim) --non-client--\        /--client-- c1 (FRR)
                                 rr1 ----+--client-- c2 (BIRD)
AS 65200                        (bgp4rd) +--client-- c3 (GoBGP)
inj-e (bgp4r-sim) --eBGP--------/ 1.1.1.1 \--client-- dual (bgp4rd)
                                    |                   |
                                non-client            client
                                    |                   |
                                   rr2 (FRR) -----------/
                                   cluster 2.2.2.2
```

## The nodes

| Node | Kind | AS | Router ID | Addresses | Role |
|---|---|---|---|---|---|
| `inj-c` | `bgp4r-sim` | 65100 | 10.100.255.11 | eth1 10.100.1.1/30 | Injector, a client of `rr1`. |
| `inj-n` | `bgp4r-sim` | 65100 | 10.100.255.12 | eth1 10.100.2.1/30 | Injector, a non-client of `rr1`. |
| `inj-e` | `bgp4r-sim` | 65200 | 10.200.255.13 | eth1 10.100.3.1/30 | Injector, `rr1`'s external peer. |
| `rr1` | `bgp4r` | 65100 | 10.100.255.2 | eth1 to eth8, 10.100.1.2 to 10.100.20.1 | The reflector under test, cluster 1.1.1.1. |
| `rr2` | `frr` | 65100 | 10.100.255.1 | eth1 10.100.20.2/30, eth2 10.100.21.1/30 | A second reflector, cluster 2.2.2.2, a non-client of `rr1`. |
| `c1` | `frr` | 65100 | 10.100.255.21 | eth1 10.100.11.2/30 | A client of `rr1`. |
| `c2` | `bird` | 65100 | 10.100.255.22 | eth1 10.100.12.2/30 | A client of `rr1`. |
| `c3` | `gobgp` | 65100 | 10.100.255.23 | eth1 10.100.13.2/30 | A client of `rr1`. |
| `dual` | `bgp4r` | 65100 | 10.100.255.30 | eth1 10.100.14.2/30, eth2 10.100.21.2/30 | A client of both reflectors. Says why a path won. |

Nine links, nine sessions. `rr1-inj-e` is eBGP; the other eight are
iBGP. `rr1`'s eth addresses are in the topology file's table.

## Why it is shaped this way

**One reflector under test, and three readers of it in three
implementations.** A client route out of `rr1` is read by FRR, BIRD and
GoBGP at once, each with its own parser for ORIGINATOR_ID and
CLUSTER_LIST. Two bgp4r speakers agreeing proves only that they agree.

**A second reflector, FRR, so bgp4r reads someone else's reflection.**
`rr2` hears a client route from `rr1` as a non-client and reflects it to
`dual` with its own cluster ID in front: CLUSTER_LIST 2.2.2.2 1.1.1.1.
That is FRR's encoding, read by bgp4r.

**`dual` is a client of both, so it sees one route twice.** From `rr1`
with CLUSTER_LIST 1.1.1.1, and through `rr2` with 2.2.2.2 1.1.1.1. Both
copies carry the same ORIGINATOR_ID, so the router ID step ties (RFC
4456 section 9) and the shorter CLUSTER_LIST wins. `dual` is a bgp4rd,
so `show.rib` names the step: `cluster_list_length`.

**`rr2`'s router ID is lower than `rr1`'s on purpose.** A decision that
compared the peers' BGP Identifiers instead of the ORIGINATOR_ID would
pick `rr2`'s copy at the router ID step. So the step name is what tells
a correct implementation from that mistake.

**`inj-n` and `rr2` are not meshed.** Non-clients normally are, and then
`rr2` would hold `inj-n`'s route from `inj-n` itself. Without that
session, `rr2` can only hear it from `rr1`, and `rr1` must refuse. The
absence at `rr2` is the rule and nothing else.

**One static route per FRR and BIRD node.** Reflection leaves NEXT_HOP
alone, so a client sees the injector's own address, which is not on its
link. There is no IGP here, so `10.100.0.0/16` points at the next node
toward `rr1`. `c2` also needs `gateway recursive`, which bgp4r-lab's
`r3` found the hard way. GoBGP without a zebra treats every next hop as
reachable and needs nothing.

## Feature by feature

| RFC 4456 | What | Scenario | capture.sh |
|---|---|---|---|
| 6 | client to client, next hop unchanged | `client-reflects-to-everyone.yml` | ORIGINATOR_ID and CLUSTER_LIST at `c1`, `c2`, `c3` |
| 6 | client to non-client | the same file, at `rr2` | CLUSTER_LIST at `rr2` |
| 6 | non-client to clients only | `non-client-reaches-clients-only.yml` | absent at `rr2`, and `rr1`'s `skipped` row |
| 6, App. B | external route to every internal peer, unreflected | `ebgp-reaches-every-internal-peer.yml` | no ORIGINATOR_ID at `c1` |
| 9 | shorter CLUSTER_LIST wins after ORIGINATOR_ID ties | `shorter-cluster-list-wins.yml` | `dual`'s `show.rib` |
| 8 | FRR's reflection read by bgp4r | the same file | CLUSTER_LIST 2.2.2.2 1.1.1.1 at `dual` |
| 8 | cluster loop dropped | `cluster-loop-is-dropped.yml` | in `rr1`'s Adj-RIB-In, not its Loc-RIB |
| 8 | originator loop dropped | `originator-loop-is-dropped.yml` | the same |
| | withdrawal reflected | `withdraw-reaches-every-reader.yml` | |
| | client flap, reflected again | `flap-and-reflect-again.yml` | `c2` holds it after a flap |

**The scenario language has no key for ORIGINATOR_ID or CLUSTER_LIST.**
Read at routescope `7eabde1` and its `claude/bgp-panes` branch,
`bgp_prefix` takes `node prefix present next_hop med as_path local_pref
community`. So a scenario can say where a route went and which step
decided, and not which reflection attributes it carried. `capture.sh`
checks those on every implementation and fails the CI job when one is
wrong. Two keys on `bgp_prefix`, `originator_id` and `cluster_list`,
would move that into the scenarios; that is routescope's column.

**The loops are replayed as octets.** No announce body key sets a
CLUSTER_LIST or an ORIGINATOR_ID, so the two looped UPDATEs go out
through `replay`. Their hex was built with the library, and
`test/functional/lab/rr_lab_topology_test.rb` decodes it and checks it
carries `rr1`'s cluster ID and router ID, and that `capture.sh` and the
scenarios replay the same octets.

**`rr1`'s reflector role is in `show.status`** as `route_reflector` and
`cluster_id`, and each peer row carries `route_reflector_client`.
`capture.sh` checks the first.

## What it needs first

The same four images as `../bgp4r-lab`, built the same way. routescope
builds the three local ones when it starts the lab, from the
`routescope.build` label on each node. The three Dockerfiles here are
copies of that lab's, held to the same instructions by the topology
test. By hand, from a bgp4r checkout:

```
docker build --target lab-node -t bgp4r-lab:latest .
docker build -f lab/routescope/rr-lab/Dockerfile.bird \
             -t bgp4r-bird:latest lab/routescope/rr-lab
docker build -f lab/routescope/rr-lab/Dockerfile.gobgp \
             -t bgp4r-gobgp:latest lab/routescope/rr-lab
docker pull quay.io/frrouting/frr:10.2.1
```

## Run it

```
sudo containerlab deploy -t lab/routescope/rr-lab/rr-lab.clab.yml
LAB=$PWD/lab/routescope/rr-lab docker compose -f ~/routescope/compose.yml up -d
sudo containerlab destroy -t lab/routescope/rr-lab/rr-lab.clab.yml
```

By hand, without routescope:

```
docker exec clab-rr-lab-inj-c ruby -rnet/http -e \
  'puts Net::HTTP.post(URI("http://127.0.0.1:8080/api/announce"),
   %q({"prefixes":["10.10.1.0/24"]}), "X-BGP4R" => "routescope").body'
docker exec clab-rr-lab-rr1 ruby -I/app exe/bgp4r-cli \
  -s /run/bgp4r/bgp4rd.sock show.status
docker exec clab-rr-lab-c1 vtysh -c 'show bgp ipv4 unicast 10.10.1.0/24'
docker exec clab-rr-lab-c2 birdc show route all for 10.10.1.0/24
docker exec clab-rr-lab-c3 gobgp global rib 10.10.1.0/24 -j
docker exec clab-rr-lab-dual ruby -I/app exe/bgp4r-cli \
  -s /run/bgp4r/bgp4rd.sock -c 'show bgp 10.10.1.0/24'
```

`capture.sh` announces from the three injectors, replays the two loops,
prints what every router answers, checks the RFC 4456 facts above, then
flaps `inj-c`. It changes the running lab, so run it on a lab you can
redeploy.

```
bash lab/routescope/rr-lab/capture.sh > capture.log
```

## What has been run, and what has not

**CI deploys it** in `.github/workflows/capture.yml`, beside
bgp4r-lab, and runs `capture.sh`. The first green run, 2026-11-06,
against FRR 10.2.1, BIRD 2.0.12 and GoBGP 4.10.0, passed all 20 checks:

* all nine sessions came up across the four implementations;
* a client route reached `c1`, `c2` and `c3` with ORIGINATOR_ID
  10.100.255.11 and CLUSTER_LIST 1.1.1.1, and its next hop unchanged, so
  FRR, BIRD and GoBGP each read bgp4r's two attributes the same way;
* it reached `rr2`, a non-client, and `inj-n`'s route did not, with
  `rr1`'s `show.adj_out` naming `non_client_to_non_client`;
* the external route reached every internal peer with neither attribute;
* `dual` held the client route twice, one copy with CLUSTER_LIST 1.1.1.1
  and FRR's with 2.2.2.2 1.1.1.1, and chose `rr1`'s on
  `cluster_list_length`. It did the same for the external route, whose
  copy through `rr2` carries `rr1`'s router ID as ORIGINATOR_ID;
* both looped routes reached `rr1`'s Adj-RIB-In, not its Loc-RIB and
  not a client, and the session stayed up;
* after a flap of `inj-c`, `c2` held the client route again.

**The first deploy found one thing**, and it is BIRD's. BIRD 2 counts
IPv4 unicast as negotiated without the Multiprotocol capability only
when the peer sends no capabilities at all. `rr1` sent As4 and Route
Refresh and no Multiprotocol, so BIRD had no channel and refused the
OPEN with 2/7, "Required capability missing". `rr1` now offers
`mbgp_ipv4_unicast` to `c2`, and the topology test holds it.

One more thing the run shows and nothing asserts: FRR reflected the
external route to `dual` with MED 0, where `rr1` sent none. bgp4r reads
a missing MED as 0, so the two copies still tie at the MED step.

**The scenarios have not been run.** Nothing in this repository runs
them; routescope does. `test/functional/lab/rr_lab_topology_test.rb`
holds them to routescope's vocabulary and to this README with no
Docker.
