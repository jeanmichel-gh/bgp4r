# bgp4r-lab

Seven nodes, four implementations, one containerlab topology: two bgp4r
injectors feeding a bgp4r router that feeds an FRR and BIRD AS and a
GoBGP of its own.

This is `docs/routescope-labs.md` section 8's "lab to build first,
concretely", built. It is the first topology in this repository that is
**containerlab** rather than Compose, and the first written for the
routescope console rather than for bgp4r's own test suite.

```
AS 65010                    AS 65000       AS 65001 (iBGP full mesh)

inj1 .10.1 --eBGP--\
 (bgp4r-sim)         >-- rtr --eBGP-- r1 ------- r2
inj2 .11.1 --eBGP--/  (bgp4rd)  |   (FRR) \     / (FRR)
 (bgp4r-sim)                    |          r3 (BIRD)
                                |
                              eBGP           AS 65002
                                |
                               g1 (GoBGP)
```

## The nodes

| Node | Kind | AS | Router ID | Addresses | What it is |
|---|---|---|---|---|---|
| `inj1` | `bgp4r-sim` | 65010 | 10.255.10.1 | eth1 10.0.10.1/30 | Injector. Starts silent; driven over its HTTP API. |
| `inj2` | `bgp4r-sim` | 65010 | 10.255.10.2 | eth1 10.0.11.1/30 | The same, on its own link. |
| `rtr` | `bgp4r` | 65000 | 10.255.0.1 | eth1 10.0.10.2/30, eth2 10.0.11.2/30, eth3 10.0.20.1/30, eth4 10.0.21.1/30 | The daemon. Decides between the two injectors and passes the winner on. |
| `r1` | `frr` | 65001 | 10.255.1.1 | eth1 10.0.20.2/30, eth2 10.1.12.1/30, eth3 10.1.13.1/30 | The only AS 65001 node with a session outside it. |
| `r2` | `frr` | 65001 | 10.255.1.2 | eth1 10.1.12.2/30, eth2 10.1.23.1/30 | Interior. |
| `r3` | `bird` | 65001 | 10.255.1.3 | eth1 10.1.13.2/30, eth2 10.1.23.2/30 | The far end of the chain. Imports; advertises nothing. |
| `g1` | `gobgp` | 65002 | 10.255.2.1 | eth1 10.0.21.2/30 | The second reader of `rtr`'s export side. Receives; originates nothing. |

Seven links, seven sessions: `inj1-rtr`, `inj2-rtr`, `rtr-r1` and
`rtr-g1` are eBGP, and `r1-r2`, `r1-r3` and `r2-r3` are the iBGP mesh.

**What `g1` adds is a second reader and not a fourth opinion.**
`docs/routescope-labs.md` section 8 gives three reasons a lab test earns
a scenario, and the first is more than one receiver reading the same
octets. Before `g1`, one UPDATE out of `rtr` had one reader, `r1`, with
FRR's chain behind it. Now two implementations read it at once. That is
the one thing no bgp4r test can say: `rib_router_gobgp_test.rb` and
`rib_router_frr_test.rb` each point the export side at one router, and
neither can show the two answering the same octets together.

Nothing about `export` is per peer, which is the point. One Loc-RIB
change goes through one `Export#for` per peer under the same rules, so
`r1` and `g1` are handed the same decision rendered by the same encoder.

**It receives and does not originate**, deliberately. A third AS
announcing the prefix the injectors announce would be compared before
the MED step, and `med-decides.yml` would stop meaning anything. See
`g1/gobgpd.toml`.

**routescope has no `gobgp` kind yet, so today this node renders as a
plain Linux box.** Read at routescope `b8e2704`: `Lab::KINDS` is
`ospfd frr ospfv2-sim bird srlinux bgp4r bgp4r-sim linux`, and
`grep -rln gobgp` across its Ruby, Markdown, TSX and YAML finds nothing
at all. `Drivers.for` is `BY_KIND.fetch(node.kind, Linux)`, so an
unknown kind answers nothing about BGP. The label here says `gobgp`
anyway, so the node is right the day a driver lands and this file needs
no edit then.

The read side such a driver needs is already written and tested, in
`LabHelper::Gobgpd`: `neighbors`, `neighbor(address)`, `rib`,
`path(prefix)` and `rib_family(family)`, all out of `gobgp ... -j`,
exercised by ten lab test files against GoBGP 3.23.0 and 4.10.0. For
scale, routescope's existing drivers are 114 lines for `Bgp4rd`, 203 for
`Sim`, 240 for `Bird` and 300 for `Frr`; a GoBGP one sits near the low
end, because its client answers JSON where BIRD needs a text parser.

**Both injectors are in one AS on purpose.** MULTI_EXIT_DISC is compared
only between paths from the same neighbouring AS (RFC 4271 section
9.1.2.2 c), so one AS for both is what makes `rtr`'s decision reach the
MED step at all, and what lets one action flip which path wins. In two
ASes the two paths would be decided at AS_PATH length and no MED a
scenario set would change anything.

**`rtr` routes rather than originates what the injectors send.** A
prefix a scenario injects arrives from `inj1` or `inj2`, is decided, and
leaves for `r1` with `rtr`'s AS prepended (RFC 4271 section 5.1.2) and
`rtr`'s address on that session as the next hop (section 5.1.3). Its own
`originate` block holds one prefix of its own, `10.255.0.0/24`, and no
scenario injects that one: if it did, the chain the lab demonstrates
would be origination and the injectors would be decoration.

## What it proves

The five points of `docs/routescope-labs.md` section 8, in its order.

| | What | Where |
|---|---|---|
| 1 | Seven sessions across four implementations | every scenario's opening steps |
| 2 | A prefix injected on command reaching r2, r3 and g1 with `rtr`'s AS prepended and `rtr` as the next hop | `scenarios/inject-and-cross.yml` |
| 2b | One UPDATE out of `rtr` read by FRR and by GoBGP at once, same AS_PATH, different next hop | the same file |
| 3 | `rtr`'s decision answering **why**, the loser naming `med` | `scenarios/med-decides.yml` |
| 4 | One action flipping the winner | `scenarios/flip-the-winner.yml` |
| 5 | A withdraw removing it from BIRD | `scenarios/withdraw-reaches-bird.yml` |

Point 3 is the one no other node here can answer about itself. `show bgp`
and `birdc show route` give the winner; `rtr` gives the RFC 4271 section
9.1.2.2 step that chose it and, per path, the step that eliminated it.
That is `bgp/rib/view.rb`'s `decided_by` and `lost_at`, which
routescope's `bgp_best` condition reads.

## What it needs first

Four images.

```
docker build --target lab-node -t bgp4r-lab:latest .
docker build -f lab/topologies/bgp4r-lab/Dockerfile.bird \
             -t bgp4r-bird:latest lab/topologies/bgp4r-lab
docker build -f lab/topologies/bgp4r-lab/Dockerfile.gobgp \
             -t bgp4r-gobgp:latest lab/topologies/bgp4r-lab
docker pull quay.io/frrouting/frr:10.2.1
```

**`lab-node` and not `speaker`, and the reason is not cosmetic.** The
stage the four Compose topologies use runs as the non-root user `bgp` and
carries no iproute2, so a containerlab node built from it has no `ip` for
its `exec:` address lines and `bgp4rd` cannot create `/run/bgp4r` for its
control socket. `lab-node` is that stage plus iproute2, as root; the
Dockerfile's comment on it has the detail and the four Compose
topologies are untouched.

`Dockerfile.bird` is ospfv2's `docker/bird/Dockerfile`, read at ospfv2
`2dfc03a`, copied rather than referenced so a bgp4r lab does not need an
ospfv2 checkout to deploy. Any image with `bird2` and `iproute2` does
instead, `ospfv2-bird:latest` included.

**`Dockerfile.gobgp` is a wrapper over the GoBGP image this repository
already uses**, and it exists for the same one reason: iproute2 for the
`exec:` lines. The two Compose topologies point at
`jauderho/gobgp:v4.10.0` directly and that works there, because Docker
gives each service its address from the network definition and nothing
has to run `ip`. A containerlab node sets its own, so it needs `ip`.

Whether that base image already has `ip` could not be verified where
this was written, since no container registry was reachable from it. One
command settles it, and if it does the wrapper is dead weight and `g1`
can point straight at `${GOBGP_IMAGE}`:

```
docker run --rm --entrypoint sh jauderho/gobgp:v4.10.0 \
           -c 'command -v ip || echo no-iproute2'
```

Its `GOBGP_IMAGE` default is the same as the two Compose topologies' and
the root Dockerfile's, so one value moves all four, and the topology
test asserts that rather than asking you to keep them in step.

## Run it

```
sudo containerlab deploy -t lab/topologies/bgp4r-lab/bgp4r-lab.clab.yml
LAB=$PWD/lab/topologies/bgp4r-lab docker compose -f ~/routescope/compose.yml up -d
sudo containerlab destroy -t lab/topologies/bgp4r-lab/bgp4r-lab.clab.yml
```

By hand, without routescope:

```
docker exec clab-bgp4r-lab-rtr ruby -I/app exe/bgp4r-cli \
  -s /run/bgp4r/bgp4rd.sock -c 'show bgp'
docker exec clab-bgp4r-lab-inj1 \
  curl -sS -X POST -H 'X-BGP4R: routescope' \
  -d '{"prefixes":["10.1.0.0/24"],"med":100}' 127.0.0.1:8080/api/announce
docker exec clab-bgp4r-lab-r1 vtysh -c 'show bgp ipv4 unicast'
docker exec clab-bgp4r-lab-r3 birdc show route all where source = RTS_BGP
docker exec clab-bgp4r-lab-g1 gobgp -j global rib
docker exec clab-bgp4r-lab-g1 gobgp -j neighbor
```

The two reads worth putting side by side are the last three: `r1`, `r3`
and `g1` on one prefix, which is the whole reason `g1` is on this
topology. `gobgp` needs no `-u` or `-p` here, because
`Dockerfile.gobgp`'s entrypoint puts the API on `127.0.0.1:50051`, which
is the client's own default. **That flag is not decoration**: GoBGP's
`cmd/gobgpd/main.go` gives `--api-hosts` a default of `:50051`, every
interface, so without it the gRPC API would be reachable from every
other node on the lab segment. The injectors' HTTP API is on the
loopback for the same reason.

`curl` is not in the `lab-node` image either; `ruby -rnet/http` is what
routescope's driver uses and is what is there.

## The scenarios

Four files, one per point 2 to 5, in the language
`docs/routescope-labs.md` section 9.3 designs: a `bgp:` step key with
its own action list, and the four `bgp_` conditions.

| Scenario | Point | Actions it uses |
|---|---|---|
| `inject-and-cross.yml` | 2 | `announce` |
| `med-decides.yml` | 3 | `announce` |
| `flip-the-winner.yml` | 4 | `announce`, `attribute` |
| `withdraw-reaches-bird.yml` | 5 | `announce`, `withdraw` |

Point 2b is in that first file and not a fifth scenario, which is why
the table has four rows and the points column one digit: a scenario of
its own would inject again and prove two UPDATEs, where the claim is
that **one** UPDATE has two readers.

**Nothing in bgp4r reads them**, which is also true of
`lab/topologies/add-path/scenarios/`. They are held to the vocabulary and
to this README by `test/functional/lab/bgp4r_lab_topology_test.rb`, with
no Docker.

**Unlike add-path's, none of them is waiting on bgp4r.** That folder's
table records two of its three scenarios as needing the injector, which
did not exist when it was written; `bgp4r-sim` is built now, so every
action these four use is one the injector answers today. What they are
waiting on is being run, which needs a Docker daemon.

## What has not been run, and what could not be verified

**The topology has not been deployed.** No Docker daemon was reachable
where it was written, so nothing in this folder is a measurement: the
addresses, the sessions and the five points above are read out of these
files and out of the RFC sections they cite. routescope's own
`examples/containerlab/bgp4r-inject` records the same of itself, and so
does this repository's Dockerfile of its capture stage.

Specifically unverified, each worth knowing before a first deploy:

* **Neither new image has been built.** `lab-node` and
  `bgp4r-bird:latest` are both Dockerfiles nothing has run.
* **Whether `exec: ip addr add` runs as root in a containerlab node.**
  containerlab runs these through `docker exec` and the image's own user
  is what decides; `lab-node` is root so that it can, but that is a
  reading of the Dockerfile rather than a measurement.
* **The three router configs parse, which is less than being accepted
  by the pinned versions.** Measured on 2026-11-02 with the binaries
  this sandbox turned out to have: `bird -p -c r3/bird.conf` is clean
  under BIRD **2.14**, and `bgpd -C -f` accepts every BGP line of both
  FRR configs under bgpd **8.4.4**. The only lines it rejects are `no
  ipv6 forwarding` and `service integrated-vtysh-config`, which are
  zebra and vtysh lines a standalone `bgpd` does not own and which the
  bound `daemons` file routes to zebra and staticd. **This lab pins FRR
  10.2.1**, so an older bgpd accepting these commands says they are not
  10.x-only and says nothing about 10.2.1 itself, and a parse is not a
  session. Their shapes are ospfv2's `examples/bgp-lab`, read at ospfv2
  `2dfc03a`, and each file says so; what is bgp4r's own in them is the
  eBGP session to `rtr`, the timers matching `hold_time: 30`, the
  deliberate absence of `next-hop-self` on `r1` and the static routes
  that absence needs on `r2` and `r3`. None of those four is checked by
  a parse.
* **Whether `rtr` can write routing table 100.** `fib:` needs
  CAP_NET_ADMIN as well as `ip`. Where it cannot, bgp4r says so rather
  than dying: the reason lands under `fib` in the state file, with a row
  per prefix whose command failed.
* **Everything this folder says about routescope.** The kinds, the
  driver method shapes, the `bgp:` step key and the four `bgp_`
  conditions are a read of routescope at `7eabde1`, on its
  `claude/bgp4r-driver` branch, on 2026-11-02. This repository's suite
  cannot assert any of it; `docs/routescope-labs.md` section 12 says
  what that costs.

## Two things found while writing this, and not fixed here

* **The `socket:` key in a `bgp4rd.yml` does nothing.**
  `docs/daemon.md`'s Configuration section documents it and
  `BGP::Daemon::Candidate::RESTART_REASONS` classifies it, but
  `Server#build` reads `opts[:socket] || Client.default_socket` and never
  `config['socket']`. So `rtr/bgp4rd.yml` does not carry the key and the
  clab file passes `-s` instead. Reproduced by reading rather than by
  running.
* **A LOCAL_PREF flip cannot be driven from an external injector**,
  which is what `docs/routescope-labs.md` section 9.4 scenario B sketches.
  `Table#import` drops LOCAL_PREF from an external peer (RFC 4271 section
  5.1.5), so both paths carry the same default and the step is never
  reached. `scenarios/flip-the-winner.yml` flips on MED and its header
  records the correction.
