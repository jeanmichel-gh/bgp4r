# bgp4r lab

Run bgp4r speakers in containers and test what they say to each other.

Each node runs the same program, `lab/speaker.rb`, driven by its own YAML file. A topology is a folder with a `compose.yml` and one YAML per node. To build a new topology, copy a folder and edit the YAML.

**One topology is containerlab rather than Compose and runs the two programs instead of `lab/speaker.rb`**: `bgp4r-lab`, which is the lab `docs/routescope-labs.md` designs for the routescope console. Compose is right for the four that this test suite drives and wrong for that one, because routescope's `Links#ends` resolves both ends of a link from the lab's own `links`, which a Compose file does not declare, so on Compose only one end of a link fault is acted on. The four here stay Compose; a new topology for a lab test should too.

The machinery behind that program is in the library, as `BGP::Daemon::Speaker` in `bgp/daemon/speaker.rb`, because `bgp4rd` needs the same sessions, the same configuration and the same recording and `lab/` is not on an installed gem's load path. `lab/speaker.rb` is its command line, its state file writer and three constants pointing at it, so `Lab::Speaker`, `Lab::Peer` and `Lab::Recorder` mean what they always did. That file's header has the decision and the two options it rejected, and `docs/daemon.md` is the daemon.

**Three programs read this node file now**, which is why its keys are worth knowing: `lab/speaker.rb`, `bgp4rd` with `rib` on by default and a `socket` key, and `bgp4r-sim`, which adds `api` and refuses the four router keys because an injector holds no Loc-RIB. The announce block below is the injector's runtime vocabulary as well: `prefixes`, `generate`, `med`, `as_path`, `as_path_literal`, `communities`, `extended_communities`, `large_communities`, `next_hop`, `local_pref`, `path_id` and `origin` are what `POST /api/announce` takes, so there is one thing to learn. `docs/daemon.md` has both programs and `examples/sim.yml` is a node file for the injector.

## Run a topology

From the repo root:

```
docker compose -f lab/topologies/two-speakers/compose.yml up -d --build
docker compose -f lab/topologies/two-speakers/compose.yml logs -f
docker compose -f lab/topologies/two-speakers/compose.yml exec r1 cat /tmp/bgp4r-state.json
docker compose -f lab/topologies/two-speakers/compose.yml down
```

### A copy of your own

`bgp4r lab new DIR [NAME]` copies one of these folders somewhere you can
edit it and makes the copy a git repository, so your edits have history.
`NAME` is any folder here, defaulting to `two-speakers`; with no `DIR`
it prints the ones it found. `--no-git` skips the repository. What a
folder's `.gitignore` lists is left out of the copy, which is how
`bgp4r-lab` keeps containerlab's own `clab-*/` working directory out of
a new lab made from a template somebody deployed in place.

```
ruby -I. exe/bgp4r lab new ~/labs/my-lab two-speakers
ruby -I. exe/bgp4r lab new ~/labs/bgp4r-lab bgp4r-lab
```

The message after the copy says how to start that topology, which for
`bgp4r-lab` is `containerlab deploy` and for the rest is `docker
compose up`.

**A Compose copy cannot build its own image.** Every `compose.yml` here builds
with `context: ../../..`, the repo root, which a copy three directories
somewhere else does not have. The image is named, though, and `docker
compose up` builds only when the named image is missing, so build it
once here and run the copy without `--build`:

```
docker compose -f lab/topologies/two-speakers/compose.yml build
cd ~/labs/my-lab && docker compose up -d
```

`lab new` names the image for the topology you asked for, since
`fault-matrix` builds `bgp4r-conformance` where the other Compose
topologies build `bgp4r-speaker`.

### Logs

Each speaker logs every message it sends and receives, and every session state change, to `docker compose logs`. Pick the level on the command line:

```
LAB_LOG_LEVEL=debug docker compose -f lab/topologies/two-speakers/compose.yml up -d
docker compose -f lab/topologies/two-speakers/compose.yml logs -f
```

`info`, the default, shows message types and state changes, like `RecvOpen old state OpenSent new state OpenConfirm`. `debug` also prints every message decoded: OPEN capabilities, UPDATE path attributes and prefixes. Running `up -d` again with a new level recreates the containers, so the sessions restart.

`LAB_LOG_LEVEL` works for the lab tests too: `LAB_LOG_LEVEL=debug ruby test/run_lab.rb`. The logs are printed when a test fails.

### State

Each speaker keeps its state in `/tmp/bgp4r-state.json`: each session's state, the peer's AS and router ID, what the peer's OPEN advertised, and every route received with its attributes. It rewrites the file twice a second. Tests read it, and so can you.

`peer_capabilities` is each capability of the peer's OPEN as data, from the capability's own `to_hash`, with its class name added. So an ADD-PATH capability reads:

```json
{ "name": "Add_path", "code": 69,
  "capability": { "families": [ { "afi": 1, "safi": 1, "send_recv": 2 } ] } }
```

`send_recv` is RFC 7911 section 4's field value, 1 able to receive, 2 able to send, 3 both, and the values say what the **sender** of the capability can do. So reading the peer's 2 is how a test checks the peer means to send us several paths, which is the half bgp4r cannot tell itself: against another bgp4r both ends invert the field together and the error cancels, which is how an inverted `_send_recv` lived here for years.

Each neighbor entry also has counters and times for the current session:

| Key | What it is |
|---|---|
| `prefixes_received` | prefixes announced minus prefixes withdrawn |
| `updates_received` | UPDATE messages received |
| `established_at` | when the session reached Established |
| `first_update_at`, `last_update_at` | when the first and the last UPDATE arrived |
| `seconds_to_last_update` | from Established to the last UPDATE |
| `prefixes_per_second` | `prefixes_received` divided by `seconds_to_last_update` |
| `established_count` | sessions that reached Established, over the speaker's life |
| `flaps` | sessions that reached Established and then went down |

`flaps` is not `established_count` minus one, and the two differ whenever a session is up: three establishments with the third still up is two flaps, and three with the third already gone is three. It is counted rather than derived for that reason.

Times are ISO 8601 in UTC with milliseconds. With `record: count` the entry has no `received` routes, and gets `first_prefix` and `last_prefix` instead.

The speakers run as the non-root user `bgp` and still listen on TCP 179. Docker allows that inside a container's own network namespace.

## Topologies

| Folder | What it shows |
|---|---|
| `two-speakers` | eBGP between AS 65001 and AS 65002 on one link. r2 connects, r1 waits. Routes cross both ways with AS_PATH, NEXT_HOP, MED and communities. |
| `routegen` | A dockerized routegen. gen (AS 65001, 10.20.0.1) connects and sends 10000 generated prefixes. sink (AS 65002, 10.20.0.2) waits, counts them and times them. |
| `add-path` | ADD-PATH, RFC 7911: one prefix, two paths, three nodes. sim (AS 65001, 10.40.0.1) sends identifiers 7 and 9 and dials both receivers. gobgp (AS 65002, 10.40.0.2) reports how many paths it holds; peer (AS 65003, 10.40.0.3) reports which identifiers arrived. Two receivers because neither answers both questions: GoBGP's `global rib -j` has no identifier key for a received path. It is the port of `test/functional/lab/add_path_gobgp_test.rb` and the first topology with a `scenarios/` folder, which nothing reads yet. Its own README says what ported and what did not. |
| `bgp4r-lab` | **The one containerlab topology**, and the only one written for the routescope console rather than for this test suite: six nodes and three implementations, two `bgp4r-sim` injectors in AS 65010 feeding a `bgp4rd` in AS 65000 that feeds an FRR and BIRD AS 65001. It is `docs/routescope-labs.md` section 8's "lab to build first", and its `scenarios/` folder covers that section's points 2 to 5: a prefix injected on command, the decision naming the step that chose it, one action flipping the winner, and a withdraw reaching BIRD. It wants the Dockerfile's `lab-node` stage rather than `speaker`. **It has never been deployed**; `test/functional/lab/bgp4r_lab_topology_test.rb` reads its files and holds them to its own README with no Docker. |
| `fault-matrix` | Every `BGP::Fault::CATALOG` case sent to GoBGP. matrix (AS 65001, 10.30.0.1) listens, router (AS 65002, 10.30.0.2) connects. It reads the router's RIB with the `gobgp` client, so it scores routes as well as sessions. The matrix runs once and exits, non-zero on any disagreement, which against either GoBGP version measured means 1. `test/functional/lab/fault_matrix_native_test.rb` runs the same matrix against a `gobgpd` on loopback, with no container at all. |

## Node file

```yaml
router_id: 10.10.0.1        # BGP identifier
as: 65001                   # local AS
listen_address: 0.0.0.0     # optional, where passive peers connect
port: 179                   # optional, listen port
log_level: info             # optional: debug, info, warn. LAB_LOG_LEVEL overrides it.
state_file: /tmp/bgp4r-state.json   # optional

neighbors:
  - address: 10.10.0.2      # peer address
    as: 65002               # peer AS; differs from ours, so this is eBGP
    connect: true           # we connect. Without it, we wait for the peer.
    port: 179               # optional, peer port when we connect
    hold_time: 30           # optional, default 90
    retry: 2                # optional, seconds between connect attempts
    capabilities: [as4_byte, route_refresh]   # optional, default [as4_byte]
                            # any name Neighbor#capability takes: route_refresh,
                            # enhanced_route_refresh, as4_byte, graceful_restart,
                            # llgr,
                            # extended_nexthop, extended_message, add_path,
                            # role, orf, dynamic,
                            # mbgp, and mbgp_<afi>_<safi> such as mbgp_ipv6_unicast.
                            # One key per capability that needs arguments:
                            #   capabilities: [{role: customer}, {add_path: [3, 1, 1]}]
                            # add_path takes (send_recv, afi, safi), which is
                            # what CAP::Add_path#add takes, so [3, 1, 1] is
                            # IPv4 unicast both ways. [1, 1, 3] is SAFI 3,
                            # NSAP, receive only: this line said that until
                            # it was measured.
    record: routes          # optional. routes keeps every route received.
                            # count keeps counters and times only.

announce:                   # each block is one UPDATE, sent to every neighbor
  - prefixes: [192.168.1.0/24, 192.168.11.0/24]
    med: 10                 # optional
    communities: ['65001:100']   # optional
    extended_communities: ['route_target:65001:7']   # optional, KIND:VALUE...,
                            # KIND a key of Extended_communities#to_hash:
                            # route_target, route_origin, ...
    large_communities: ['65001:1:1']   # optional, RFC 8092
    as_path: [64999]        # optional, put after our own AS over eBGP
    as_path_literal: true   # optional, send as_path exactly as written,
                            # with no AS of ours in front, even over eBGP.
                            # Only true turns the prepend off.
    local_pref: 200         # optional, iBGP only, default 100
    next_hop: 10.10.0.9     # optional, default our address on that session
    path_id: 7              # optional, RFC 7911 section 3. Every prefix in
                            # the block carries it, so two blocks naming one
                            # prefix with two identifiers are two paths to
                            # it. Needs add_path with send_recv 2 or 3 on
                            # that neighbor, and nothing checks that: a Path
                            # Identifier on a session that did not negotiate
                            # one is a test worth being able to run.
  - generate: { start: 11.0.0.0/28, count: 10000, per_update: 127 }
    med: 100                # same optional keys as above
    communities: ['100:1', '200:1', '300:1']
    as_path: [90, 80]
```

A `prefixes` block is one UPDATE. A `generate` block is many: `count` prefixes of the same length, starting at `start` itself (11.0.0.0/28, 11.0.0.16/28, and so on), `per_update` in each UPDATE. They all carry the block's path attributes. The speaker builds and sends them one at a time, so the routes never sit in memory. Two environment variables override every `generate` block when set:

* `ROUTEGEN_COUNT`: the number of prefixes.
* `ROUTEGEN_PER_UPDATE`: prefixes per UPDATE. A full UPDATE must fit in 4096 octets; 127 /28 prefixes with these attributes do.

Over eBGP the speaker puts its own AS first in AS_PATH, unless `as_path_literal: true`, and sets NEXT_HOP to itself (RFC 4271 section 5.1). Over iBGP it sends LOCAL_PREF.

## Router mode

An `announce` block goes straight onto each session, which makes a speaker an origin and a sink. Four more keys make it a router: the tables of `bgp/rib/` are wired in behind them, so a route learned from one neighbor is decided and passed on to another with the export rules of RFC 4271 section 5.1 and RFC 4456 applied.

```yaml
rib: true                   # optional. Build a Loc-RIB from what the
                            # peers send, and advertise nothing. The three
                            # keys below each need a table, so each implies
                            # this one; on its own it is a speaker watching
                            # its peers rather than routing between them.

originate:                  # our own prefixes, through the Loc-RIB
  - prefixes: [10.255.0.0/24]
    med: 10                 # optional
    local_pref: 200         # optional
    origin: 0               # optional, default 0 IGP
    communities: ['65000:1']   # optional
    as_path: [64999]        # optional, and nothing an RFC asks for

export:                     # present at all turns router mode on
  next_hops: { 1: 10.0.20.1 }   # ours, per AFI, toward external peers
  route_reflector: false    # RFC 4456
  clients: []               # RFC 4456 section 6, when a reflector
  cluster_id: 7.7.7.7       # RFC 4456 section 7, default our router ID
  default_local_pref: 100   # RFC 4271 section 5.1.5
  mrai: { ebgp: 0, ibgp: 0 }    # RFC 4271 section 9.2.1.1. 0 is off,
                                # which is the default.

fib:                        # absent means compute and do not install
  table: 100                # required, and with no default
  netns: lab                # optional
  dev: eth0                 # optional
  proto: bgp                # optional
```

Those are `docs/daemon.md`'s key names, because that daemon's configuration is this node file with more in it and the two must not drift.

`export: {}` is enough for a transit router. With no `next_hops` an IPv4 route takes our own address on each session, which is what RFC 4271 section 5.1.3 asks for, and the speaker fills that in from the socket so a container with one address needs no `local_address`. `next_hops` is **required** for any other address family going to an external peer: `Export` will not invent our address, and the alternative to refusing is sending a next hop that is not ours, which is how a route becomes a black hole. A family with none is not advertised, and the state file says so under `skipped`.

An `originate` block is not an `announce` block, and two of the differences are RFC 4271 section 5.1's. Its AS_PATH starts **empty**, because section 5.1.2 wants an empty one toward an internal peer and ours alone toward an external one, and both fall out of prepending onto an empty attribute in the export step. There is **no `next_hop` key**, because section 5.1.3 makes the next hop ours on each session and the export step would overwrite anything written here. There is no `path_id` key either: the Loc-RIB keeps one best route per prefix, so nothing an Identifier could tell apart reaches the export side, and `announce` with `path_id` is still how a topology sends several paths.

`med` is worth knowing about: it reaches the Loc-RIB and everything downstream of it, and **not an external peer**. `Export` deletes MULTI_EXIT_DISC for every external peer alike, which is RFC 4271 section 5.1.4 read strictly, so a MED of our own toward one of them is a policy block's business rather than a node file key.

`mrai` is off by default and stays off. A script driving a router through a sequence of UPDATEs wants each one on the wire when it says so, and thirty seconds of silence reads as a bug in the device under test. RFC 4271 section 10's suggested values are `{ ebgp: 30, ibgp: 5 }`.

`fib` needs CAP_NET_ADMIN, and the speaker runs as the non-root user `bgp`, so a container that cannot write a routing table is an ordinary thing to meet. It says why rather than dying: the reason is in the state file under `fib`, with a row per prefix the command failed for. `uninstall` runs on the way out, so a speaker takes its own routes out of the table it was given.

### What router mode adds to the state file

```json
{ "loc_rib": [
    { "prefix": "10.1.0.0/16", "next_hop": "10.0.10.1", "as_path": "65010",
      "origin": "igp", "med": null, "local_pref": 100,
      "from": "10.0.10.1", "paths": 2, "best": true } ],
  "router": { "advertising": true, "updates_sent": 3, "held": 0 },
  "fib": { "table": "100", "installed": 1, "error": null, "failed": [] },
  "neighbors": {
    "10.0.10.1": { "advertised": 1,
                   "skipped": [ { "prefix": "10.1.0.0/16",
                                  "reason": "back_to_sender" } ] } } }
```

`loc_rib` is one row per prefix, the best route and the attributes it carries, with `paths` the number of routes that were decided between and `from` the address of the peer it came from. A prefix we originated reads `from` as our own router ID. `best` is always true in these rows, because a Loc-RIB holds the winner and nothing else.

It is **data and not the text of a show command**. `rib.show` has three vendor styles and none of them has been diffed against a real device, so nothing should depend on that text byte for byte; a state file a program parses would be exactly such a dependency. `as_path` is a string because that is the form a router prints and a reader compares, and an empty AS_PATH is `""`.

`skipped` per neighbor is what was not advertised to it and why. A route silently not advertised is the hardest kind of bug to see from outside, which is the whole reason it is in the file: `back_to_sender`, `ibgp_to_ibgp`, `non_client_to_non_client`, `no_advertise`, `no_export`, `next_hop_is_the_peers_address`, `no_next_hop_for_family`, `policy`.

## Dockerized routegen

`lab/topologies/routegen` runs a route generator and a sink, with no router needed. Use it to see how fast bgp4r sends and takes routes, or to try a feed before you point it at a real router.

```
docker compose -f lab/topologies/routegen/compose.yml up -d --build
docker compose -f lab/topologies/routegen/compose.yml exec sink cat /tmp/bgp4r-state.json
docker compose -f lab/topologies/routegen/compose.yml down
```

Pick the size on the command line. The defaults are 10000 and 127:

```
ROUTEGEN_COUNT=200000 ROUTEGEN_PER_UPDATE=127 docker compose -f lab/topologies/routegen/compose.yml up -d
```

Read the sink's entry for gen, under `neighbors` and `10.20.0.1`. When `prefixes_received` equals the count, all routes are in. `seconds_to_last_update` and `prefixes_per_second` give the time and the rate. `first_prefix` and `last_prefix` show the range: 10000 /28 prefixes from 11.0.0.0/28 end at 11.2.112.240/28.

`examples/routegen` stays the native tool for loading a real router: one session, one YAML file, no Docker. Both share `BGP::RouteGenerator` in `bgp/misc/route_generator.rb`, so they send the same prefixes in the same UPDATEs.

## Add a topology

1. Copy `lab/topologies/two-speakers` to a new folder.
2. In `compose.yml`, change `name:`, the services, the networks and the addresses. Use one network per link when routers should not all share one segment. Keep each network's gateway off the router addresses.
3. Write one node file per service.
4. Add `test/functional/lab/<folder>_test.rb`. Start from `two_speakers_test.rb`. The helpers in `lab_helper.rb` wait for sessions and routes and print the container logs when a test fails.

Run the lab tests with `ruby test/run_lab.rb`. Without Docker, the Compose tests are skipped, and the loopback test still runs the speaker as local processes. CI runs everything.

## Limits

* A speaker is a router only when its node file asks for one. With none of `rib`, `originate`, `export` or `fib` it builds no table, originates routes and records what it receives, and passes nothing on. See [Router mode](#router-mode).
* IPv4 unicast in plain NLRI only, for now.
* One session per neighbor. If both sides connect at once, the second connection is closed.

## Fault matrix

`lab/fault_matrix.rb` sends every `BGP::Fault::CATALOG` case to a router
and reports what it did with each one. bgp4r listens and the router
connects, so it works with any implementation that can be told to peer
with us.

```
ruby lab/fault_matrix.rb --peer 127.0.0.2 --peer-as 65002
ruby lab/fault_matrix.rb --peer 127.0.0.2 --peer-as 65002 \
  --rib-command 'gobgp global rib' --json gobgp.json
```

Each fault gets a session of its own, because a reset leaves nothing to
reuse. From one session the harness can see two things:

| Outcome | What it means |
|---|---|
| `reset` | the router sent a NOTIFICATION, or dropped the session |
| `kept` | the session stayed up |

RFC 7606 treat-as-withdraw and attribute-discard both keep the session
up. To tell those apart the router has to say whether it installed the
route, so `--rib-command` runs a shell command that prints its RIB and
the harness looks for the prefix in the output.

The exit status is 0 when every router answer agrees with the RFC 7606
action the catalog expects, 1 otherwise.

The peer must negotiate every address family the catalog uses, IPv6
unicast included: the duplicate MP_REACH_NLRI case carries IPv6 NLRI,
and a router that never agreed to IPv6 resets over the address family
instead of the duplicate.

### In containers

`lab/topologies/fault-matrix` runs the whole catalog against GoBGP in one
command. The matrix runs once and exits, so run it in the foreground and
take its exit status:

```
docker compose -f lab/topologies/fault-matrix/compose.yml up --build \
  --abort-on-container-exit --exit-code-from matrix
docker compose -f lab/topologies/fault-matrix/compose.yml cp \
  matrix:/tmp/fault-matrix.json .
docker compose -f lab/topologies/fault-matrix/compose.yml down
```

The exit status is 1, which is the expected result and not a failure.
The matrix exits non-zero on any disagreement with the catalog, and two
cases disagree on both GoBGP versions measured: both tunnel
encapsulation cases. RFC 9012 section 13 is a MUST and asks for
treat-as-withdraw, while GoBGP discards the malformed attribute and
installs the route. bgp4r is right there and the router is not, so the
catalog is left alone and the divergence is asserted as such.

GoBGP 3.23 disagrees on a third case, `attr_overrun`, which it resets on
where RFC 7606 section 4 makes treat-as-withdraw a MUST; GoBGP 4 fixed
that. The expectations are per version, in
`test/functional/lab/fault_matrix_scenario.rb`, which is also what the
native test above reads.

Two variables are optional. `GOBGP_IMAGE` pins the router image or swaps
the router, and it feeds the matrix image too, so the client and the
router stay the same version. `FAULT_SETTLE` is the wait after each
fault, 2 seconds by default; raise it if a slower machine reports faults
with no session.

The topology reads the router's RIB, with
`--rib-command 'gobgp -u 10.30.0.2 global rib'`. The client comes from
the Dockerfile's `conformance` stage, the `speaker` stage plus
`/usr/local/bin/gobgp` copied out of the router image, so nothing is
downloaded and no Docker socket is mounted.

`test/functional/lab/fault_matrix_test.rb` runs the same topology and
asserts both layers. The session level answers: the two cases that must
reset do reset, with NOTIFICATION subcodes 2 and 1, and no other case
resets. That half of RFC 7606 needs no look at the RIB, so it holds for
any conformant router. Then the route level answers: every
treat-as-withdraw case dropped the route and every attribute-discard
case kept it, taken from each catalog entry's own action, with the two
tunnel encapsulation cases asserted as the known divergence.
`docs/protocol-testing.md` has the detail.

### Running it without containers, on Linux

This route needs Linux. The three routers are Linux daemons, and it also
relies on all of 127.0.0.0/8 being local, which is true on Linux and not
on macOS. On a Mac use the topology above instead.

FRR, BIRD and GoBGP are all packaged by Ubuntu, so they can run as plain
processes on loopback addresses, which is how the results below were
produced:

```
apt-get install -y frr bird2 gobgpd
gobgpd -f gobgpd.conf &                                   # 127.0.0.2
/usr/lib/frr/bgpd -f /etc/frr/bgpd.conf -l 127.0.0.3 -Z & # 127.0.0.3
```

FRR drops privileges to the `frr` user, so its config file has to be
readable by that user. A next hop of 127.0.0.1 is martian to FRR; use
an ordinary address such as 10.0.0.1.

### Router configs and results

`lab/conformance/` holds a working config for each router, all three on
loopback addresses so they can run side by side:

| Router | Address | AS | bgp4r listens on |
|---|---|---|---|
| GoBGP | 127.0.0.2 | 65002 | 127.0.0.1:179 |
| FRR | 127.0.0.3 | 65003 | 127.0.0.1:179 |
| BIRD | 127.0.0.4 | 65004 | 127.0.0.1:1179 |

```
gobgpd -f lab/conformance/gobgpd.conf &
install -o frr -g frr -m 644 lab/conformance/frr-bgpd.conf /etc/frr/bgpd.conf
/usr/lib/frr/bgpd -f /etc/frr/bgpd.conf -l 127.0.0.3 -Z --log stdout &
bird -c lab/conformance/bird.conf -s /run/bird.ctl -f &

ruby lab/fault_matrix.rb --peer 127.0.0.2 --peer-as 65002 --rib-command 'gobgp global rib'
ruby lab/fault_matrix.rb --peer 127.0.0.3 --peer-as 65003 --rib-command 'vtysh -c "show bgp ipv4 unicast"'
ruby lab/fault_matrix.rb --peer 127.0.0.4 --peer-as 65004 --port 1179 --rib-command 'birdc -s /run/bird.ctl show route'
```

BIRD takes a port of its own because it wants the wildcard `0.0.0.0:179`
for its listening socket. `strict bind` keeps it on its own address, and
it dials bgp4r on 1179 so the two listeners do not collide.

BIRD also needs a short `error wait time`. Each fault gets a session of
its own, so a router that waits minutes before reconnecting, which is
BIRD's default after a closed connection, never comes back in time.

### Reading the results

`session only` means the router kept the session, which is right for
both treat-as-withdraw and attribute-discard, but the RIB said nothing,
so the two cannot be told apart. BIRD in this setup rejects even a plain
route, because the next hop does not resolve over a loopback multihop
session, so every BIRD row reads that way.

IPv6 unicast is negotiated by default, because the duplicate
MP_REACH_NLRI case carries IPv6 NLRI: without it the router resets over
an address family it never agreed to, which is not the rule under test.
`--no-ipv6` turns it off for a router that cannot do IPv6 at all.
