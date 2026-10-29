# bgp4r lab

Run bgp4r speakers in containers and test what they say to each other.

Each node runs the same program, `lab/speaker.rb`, driven by its own YAML file. A topology is a folder with a `compose.yml` and one YAML per node. To build a new topology, copy a folder and edit the YAML.

## Run a topology

From the repo root:

```
docker compose -f lab/topologies/two-speakers/compose.yml up -d --build
docker compose -f lab/topologies/two-speakers/compose.yml logs -f
docker compose -f lab/topologies/two-speakers/compose.yml exec r1 cat /tmp/bgp4r-state.json
docker compose -f lab/topologies/two-speakers/compose.yml down
```

### Logs

Each speaker logs every message it sends and receives, and every session state change, to `docker compose logs`. Pick the level on the command line:

```
LAB_LOG_LEVEL=debug docker compose -f lab/topologies/two-speakers/compose.yml up -d
docker compose -f lab/topologies/two-speakers/compose.yml logs -f
```

`info`, the default, shows message types and state changes, like `RecvOpen old state OpenSent new state OpenConfirm`. `debug` also prints every message decoded: OPEN capabilities, UPDATE path attributes and prefixes. Running `up -d` again with a new level recreates the containers, so the sessions restart.

`LAB_LOG_LEVEL` works for the lab tests too: `LAB_LOG_LEVEL=debug ruby test/run_lab.rb`. The logs are printed when a test fails.

### State

Each speaker keeps its state in `/tmp/bgp4r-state.json`: each session's state, the peer's AS and router ID, and every route received with its attributes. It rewrites the file twice a second. Tests read it, and so can you.

Each neighbor entry also has counters and times for the current session:

| Key | What it is |
|---|---|
| `prefixes_received` | prefixes announced minus prefixes withdrawn |
| `updates_received` | UPDATE messages received |
| `established_at` | when the session reached Established |
| `first_update_at`, `last_update_at` | when the first and the last UPDATE arrived |
| `seconds_to_last_update` | from Established to the last UPDATE |
| `prefixes_per_second` | `prefixes_received` divided by `seconds_to_last_update` |

Times are ISO 8601 in UTC with milliseconds. With `record: count` the entry has no `received` routes, and gets `first_prefix` and `last_prefix` instead.

The speakers run as the non-root user `bgp` and still listen on TCP 179. Docker allows that inside a container's own network namespace.

## Topologies

| Folder | What it shows |
|---|---|
| `two-speakers` | eBGP between AS 65001 and AS 65002 on one link. r2 connects, r1 waits. Routes cross both ways with AS_PATH, NEXT_HOP, MED and communities. |
| `routegen` | A dockerized routegen. gen (AS 65001, 10.20.0.1) connects and sends 10000 generated prefixes. sink (AS 65002, 10.20.0.2) waits, counts them and times them. |
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
                            # extended_nexthop, add_path, role, orf, dynamic,
                            # mbgp, and mbgp_<afi>_<safi> such as mbgp_ipv6_unicast.
                            # One key per capability that needs arguments:
                            #   capabilities: [{role: customer}, {add_path: [1, 1, 3]}]
    record: routes          # optional. routes keeps every route received.
                            # count keeps counters and times only.

announce:                   # each block is one UPDATE, sent to every neighbor
  - prefixes: [192.168.1.0/24, 192.168.11.0/24]
    med: 10                 # optional
    communities: ['65001:100']   # optional
    as_path: [64999]        # optional, put after our own AS over eBGP
    local_pref: 200         # optional, iBGP only, default 100
    next_hop: 10.10.0.9     # optional, default our address on that session
  - generate: { start: 11.0.0.0/28, count: 10000, per_update: 127 }
    med: 100                # same optional keys as above
    communities: ['100:1', '200:1', '300:1']
    as_path: [90, 80]
```

A `prefixes` block is one UPDATE. A `generate` block is many: `count` prefixes of the same length, starting at `start` itself (11.0.0.0/28, 11.0.0.16/28, and so on), `per_update` in each UPDATE. They all carry the block's path attributes. The speaker builds and sends them one at a time, so the routes never sit in memory. Two environment variables override every `generate` block when set:

* `ROUTEGEN_COUNT`: the number of prefixes.
* `ROUTEGEN_PER_UPDATE`: prefixes per UPDATE. A full UPDATE must fit in 4096 octets; 127 /28 prefixes with these attributes do.

Over eBGP the speaker puts its own AS first in AS_PATH and sets NEXT_HOP to itself (RFC 4271 section 5.1). Over iBGP it sends LOCAL_PREF.

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

* A speaker originates routes and records what it receives. It never passes routes on from one neighbor to another, so it is not a route reflector or a transit router yet.
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
