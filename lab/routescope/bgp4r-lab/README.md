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

The five points of `docs/routescope-labs.md` section 8, in its order,
then two for routescope's BGP panes (its `docs/bgp.md`): communities
for the RIB pane, and a flap for the Peers pane.

| | What | Where |
|---|---|---|
| 1 | Seven sessions across four implementations | every scenario's opening steps |
| 2 | A prefix injected on command reaching r2, r3 and g1 with `rtr`'s AS prepended and `rtr` as the next hop | `scenarios/inject-and-cross.yml` |
| 2b | One UPDATE out of `rtr` read by FRR and by GoBGP at once, same AS_PATH, different next hop | the same file |
| 3 | `rtr`'s decision answering **why**, the loser naming `med` | `scenarios/med-decides.yml` |
| 4 | One action flipping the winner | `scenarios/flip-the-winner.yml` |
| 5 | A withdraw removing it from BIRD | `scenarios/withdraw-reaches-bird.yml` |
| 6 | A standard, an extended and a large community reaching BIRD intact | `scenarios/communities-cross.yml` |
| 7 | A flap counted, and every speaker done with its work afterwards | `scenarios/flap-and-drain.yml` |

Point 3 is the one no other node here can answer about itself. `show bgp`
and `birdc show route` give the winner; `rtr` gives the RFC 4271 section
9.1.2.2 step that chose it and, per path, the step that eliminated it.
That is `bgp/rib/view.rb`'s `decided_by` and `lost_at`, which
routescope's `bgp_best` condition reads.

## What it needs first

Four images.

```
docker build --target lab-node -t bgp4r-lab:latest .
docker build -f lab/routescope/bgp4r-lab/Dockerfile.bird \
             -t bgp4r-bird:latest lab/routescope/bgp4r-lab
docker build -f lab/routescope/bgp4r-lab/Dockerfile.gobgp \
             -t bgp4r-gobgp:latest lab/routescope/bgp4r-lab
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
sudo containerlab deploy -t lab/routescope/bgp4r-lab/bgp4r-lab.clab.yml
LAB=$PWD/lab/routescope/bgp4r-lab docker compose -f ~/routescope/compose.yml up -d
sudo containerlab destroy -t lab/routescope/bgp4r-lab/bgp4r-lab.clab.yml
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

The three reads worth putting side by side are the last three: `r1`,
`r3` and `g1` on one prefix, which is the whole reason `g1` is on this
topology. `gobgp` needs no `-u` or `-p` here, because
`Dockerfile.gobgp`'s entrypoint puts the API on `127.0.0.1:50051`, which
is the client's own default. **That flag is not decoration**: GoBGP's
`cmd/gobgpd/main.go` gives `--api-hosts` a default of `:50051`, every
interface, so without it the gRPC API would be reachable from every
other node on the lab segment. The injectors' HTTP API is on the
loopback for the same reason.

`curl` is not in the `lab-node` image either; `ruby -rnet/http` is what
routescope's driver uses and is what is there.

`capture.sh` prints what every router answers to the commands
routescope's BGP drivers send, for routescope's unit test fixtures. It
changes the running lab first (two paths, all three community kinds,
soft reconfiguration on r1, a prefix originated by both r2 and r3, then
a flap), so run it on a lab you can redeploy. CI runs it on every push
that changes this folder, in `.github/workflows/capture.yml`, which is
also the one place this lab is deployed. It is a copy of ospfv2's own
capture job, adapted, so neither repository depends on the other.

```
bash lab/routescope/bgp4r-lab/capture.sh > capture.log
```

## What each node does with the kernel, which is three answers and a fourth that is none

Every read above is a BGP table. The kernel is a separate question and
the four implementations answer it four ways, so comparing one node's
`ip route` against another's compares different things:

| node | what programs the kernel | where |
|---|---|---|
| `rtr` | `bgp4rd`, through iproute2, from its `fib:` key | table 100 |
| `r1` | FRR's zebra, `zebra=yes` in its daemons file | main |
| `r2` | the same | main |
| `r3` | BIRD's `protocol kernel`, exporting `source = RTS_BGP` | main |
| `g1` | nothing | nowhere |

`rtr` is table 100 and not the main table on purpose: a route in the
main table changes where the container sends its own traffic, which is
`bgp/rib/ip_route.rb`'s own reason for giving `table:` no default.

**`g1` programs nothing, and that is GoBGP rather than this config being
short of a key.** GoBGP's own `docs/sources/zebra.md` routes FIB
programming through an external zebra over ZAPI, as a `[zebra]` block
naming its socket. There is no such block here and no zebra in that
container, so GoBGP learns, selects, advertises and withdraws in BGP and
leaves the kernel alone. `NET_ADMIN` on the container would not change
it. That is also why `g1` is read with `gobgp global rib`: it answers in
full what rtr sent and what a withdrawal took away, which is the one
thing this node is on the topology for.

To watch a kernel install rather than a BGP table, run `ip monitor
route` in the node that programs one while a scenario announces and
withdraws:

```
docker exec clab-bgp4r-lab-r1 ip monitor route &
docker exec clab-bgp4r-lab-rtr ip -4 route show table 100
docker exec clab-bgp4r-lab-r3 ip -4 route show
```

**None of this is measured, even though the lab is deployed now.** CI
deploys it and runs `capture.sh`, and `capture.sh` reads BGP tables: its
one `ip route` is a static route configured into `r2`'s FRR, not a
kernel table read anywhere. So the table above is read out of the four
config files, and the three `ip` commands here are what a person runs
to check it.

## The scenarios

Six files, one per point 2 to 7, in the language
`docs/routescope-labs.md` section 9.3 designs: a `bgp:` step key with
its own action list, and the `bgp_` conditions. Points 6 and 7 use the
two that routescope's BGP panes work added, `bgp_drained` and the
`community` key of `bgp_prefix`.

| Scenario | Point | Actions it uses |
|---|---|---|
| `inject-and-cross.yml` | 2 | `announce` |
| `med-decides.yml` | 3 | `announce` |
| `flip-the-winner.yml` | 4 | `announce`, `attribute` |
| `withdraw-reaches-bird.yml` | 5 | `announce`, `withdraw` |
| `communities-cross.yml` | 6 | `announce` |
| `flap-and-drain.yml` | 7 | `announce`, `session.flap` |

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
action these six use is one the injector answers today. What they are
waiting on is being run, by routescope's `bgp4r-lab` job.

## What has been run, and what has not

**The topology is deployed by CI**, in `.github/workflows/capture.yml`,
first on 2026-11-03, against FRR 10.2.1 and BIRD 2.0.12. That run is
what `capture.sh` prints, and it measured:

* both images build, `exec: ip addr add` runs, and all six sessions come
  up across the three implementations;
* point 2's chain: 10.2.0.0/24 from inj1 reaches r1, r2 and r3 with
  AS_PATH 65000 65010 and rtr as the next hop;
* point 3: rtr holds two paths to 10.1.0.0/24 and `show.rib` says MED
  decided, for inj2's MED 50 over inj1's 100;
* point 6: all three kinds of community reach BIRD intact;
* point 7: a flap is counted by FRR (`connectionsDropped`), by bgp4rd
  and by the injector.

**`g1` came after that run, so the list above is of six sessions and
three implementations.** Two more runs followed, the same day, and the
first of the two **failed the whole deploy over this one node**.
gobgpd was told to bind its listener to 10.0.21.2, and containerlab
runs `exec:` **after** a node's entrypoint, so that address did not
exist yet: `bind: cannot assign requested address`, then `node "g1"
deploy: namespace path not available`, which cancelled r1, r2 and rtr's
own `exec:` with it. `g1/gobgpd.toml` has the fix and the two GoBGP
source files behind it. A **dial** to a specific address is fine, since
it retries; a start-up **bind** is not.

**The run after the fix is the one that measures the node:**

* `bgp4r-gobgp:latest` builds, `exec: ip addr add` runs in it, and all
  seven nodes reach `running`, so the lab is four implementations now;
* the g1 session is established with 0 flaps, and `rtr` reports `sent`
  6 to it and `received` 0, which is what the node is configured for:
  it reads and originates nothing;
* the capabilities GoBGP 4.10.0 offers, which `show.peers` prints, and
  which are a bgp4r gap. Below.

**That gap is a capability one, and it is the first prioritised list of
them anybody here has.** bgp4r read two of g1's six capabilities as
`Unknown`, codes 6 and 73, and four of r1's ten the same way, codes 6,
71, 73 and 76. Named from the IANA Capability Codes registry, read
2026-11-03: **6 is BGP Extended Message, RFC 8654**, and **71 is
Long-Lived Graceful Restart, RFC 9494**; 73 (FQDN) and 76
(PATHS-LIMIT) are drafts. So two routers between them offer **four**
code points bgp4r does not name, and two of the four have an RFC.
Nothing is broken by it, since an unknown capability round trips, but
it says which capability to implement next, and it came from routers
rather than from the registry.

Count that list rather than reasoning about it. The first version of
this paragraph said five, by including code 5, Extended Next Hop
Encoding, which bgp4r **does** name: `show.peers` prints it as
`Extended_nexthop` with `{afi 1, safi 1, nexthop_afi 2}`. g1 offers
it, rtr does not offer it back, and `gobgp neighbor` labels it
`advertised` rather than `advertised and received`, which is the
distinction a reader of only the JSON form would miss.

**The run after that is the one that read g1's RIB**, the `### GoBGP`
block, and it settles the two things this node is on the topology for:

* **all three kinds of community reach GoBGP intact**, which the first
  run proved only at BIRD. On 10.2.0.0/24 g1 holds attribute 8 as
  65010:100 and 65010:200, attribute 16 as route target 65010:7 and
  attribute 32 as 65010:1:1. So two independent implementations read
  rtr's export of all three the same way;
* **the second-reader claim is measured and not only guarded.** g1
  holds 10.1.0.0/24 with AS_PATH 65000 65010 and next hop 10.0.21.1
  where r1 holds it with the same AS_PATH and next hop 10.0.20.1: the
  same decision from the same encoder, and a next hop each because a
  next hop is per session. That is what `inject-and-cross.yml` claims
  and what `test_one_scenario_asserts_both_readers_of_one_update`
  holds it to.

It also found that **`gobgp neighbor -j` prints capabilities readably
on 4.10.0**, as `{"Cap":{"ExtendedMessage":{}}}`, where
`LabHelper::Gobgpd#remote_add_path` records the JSON form wrapping each
one in a protobuf Any with a base64 value. That helper runs against
3.23.0 too, which is where its own claim was measured, so this is a
version difference and not an error in it.

**`Dockerfile.gobgp`'s own open question is still open**: the wrapper
works, which says nothing about whether `${GOBGP_IMAGE}` already has
`ip` and the wrapper could go. The one command that settles it is in
that file.

**It found one bug, which a parse could not.** On a `direct` iBGP
session BIRD wants the next hop on one of its own links. 10.0.20.1 is
not, so BIRD logged "Invalid NEXT_HOP attribute - address 10.0.20.1 not
directly reachable" and dropped every route from rtr while r1 and r2
held them. `r3/bird.conf` now has `gateway recursive`, which resolves
the next hop through the static route it already had for this.

**The scenarios have not been run.** Nothing in this repository runs
them; routescope does, in a job of its own, which has not run either.
What is left unverified:

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
