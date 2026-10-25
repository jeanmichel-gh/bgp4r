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

The speakers run as the non-root user `bgp` and still listen on TCP 179. Docker allows that inside a container's own network namespace.

## Topologies

| Folder | What it shows |
|---|---|
| `two-speakers` | eBGP between AS 65001 and AS 65002 on one link. r2 connects, r1 waits. Routes cross both ways with AS_PATH, NEXT_HOP, MED and communities. |

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
                            # also mbgp_ipv4_unicast, mbgp_ipv6_unicast

announce:                   # each block is one UPDATE, sent to every neighbor
  - prefixes: [192.168.1.0/24, 192.168.11.0/24]
    med: 10                 # optional
    communities: ['65001:100']   # optional
    as_path: [64999]        # optional, put after our own AS over eBGP
    local_pref: 200         # optional, iBGP only, default 100
    next_hop: 10.10.0.9     # optional, default our address on that session
```

Over eBGP the speaker puts its own AS first in AS_PATH and sets NEXT_HOP to itself (RFC 4271 section 5.1). Over iBGP it sends LOCAL_PREF.

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
