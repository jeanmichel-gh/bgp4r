# Running the tests

**Generated. Do not edit.** `test/features_doc.rb` writes it from
`test/features.rb`, and `test/unit/features_test.rb` fails the unit
suite when the two disagree:

```
ruby test/features_doc.rb > docs/running-tests.md
```

This is the map of what to run and how to see what happened.
`docs/protocol-testing.md` is the other half: how to build the
messages no RFC allows and what three routers do with them.

## The three tiers

Every test is in one of three tiers, and they cost very different
amounts. Measured 2026-11-03:

| Tier | What it needs | Files | Time | Command |
|---|---|---:|---|---|
| unit | Ruby | 155 | 21s | `ruby test/run_unit.rb` |
| functional | a loopback socket | 14 | 18s | one file at a time, below |
| lab | gobgpd, FRR, Docker or root | 29 | 10s to 400s per group | `ruby test/run_lab.rb GROUP` |

**The first two tiers together are under a minute and need nothing
installed.** That is worth knowing before reaching for a lab test.
The unit suite is 21s. Every functional test
together is 18s, on loopback, with no router
binary and no Docker.

```
ruby test/run_unit.rb                       # the whole unit suite
ruby -I. test/unit/path_attributes/origin_test.rb   # one unit file
ruby test/run_unit.rb && for f in test/functional/*_test.rb; do \
  [ "$f" = test/functional/live_feed_test.rb ] || ruby -I. "$f"; done
```

`-I.` is needed for a single file and not for `run_unit.rb`, which
sets the load path itself. **Run a file you changed both ways**, on
its own and in the suite: a missing `require` passes in the suite
and fails alone, and a top-level `include` does the opposite.

### The one file to never run

`test/functional/live_feed_test.rb` connects to a public feed that no longer answers and hangs forever.

`run_feature.rb` refuses it by name. Nothing stops `ruby -I.` on it.

## By feature

`test/features.rb` tags every test file with the BGP feature it
exercises, which is a second axis over the same files: the tree is
laid out by source file, and `test/lab_groups.rb` groups the lab
tests by the binary they need. Features are tags and they overlap,
because about a quarter of the files carry two or more.

```
ruby test/run_feature.rb                 # this table
ruby test/run_feature.rb FEATURE         # every tier of one feature
ruby test/run_feature.rb FEATURE --unit  # the tier that needs nothing
ruby test/run_feature.rb FEATURE --list  # the files, and what they need
ruby test/run_feature.rb --area families # every feature of one area
```

### families

What bgp4r can carry: one per NLRI family.

| Feature | unit | func | lab | What |
|---|---:|---:|---:|---|
| `unicast` | 4 | 0 | 0 | IPv4 and IPv6 unicast, SAFI 1 and 2, and the prefix encodings |
| `labelled` | 2 | 0 | 0 | Labelled unicast, SAFI 4, and the label stack |
| `vpn` | 2 | 0 | 0 | VPN-IPv4 and VPN-IPv6, SAFI 128 and 129, and the Route Distinguisher |
| `flow-spec` | 3 | 1 | 2 | Flow specification rules, SAFI 133 and 134 |
| `evpn` | 3 | 1 | 2 | EVPN, AFI 25 SAFI 70, all eleven route types |
| `rt-constrain` | 1 | 1 | 1 | Route Target membership, AFI 1 SAFI 132 |
| `mcast-vpn` | 3 | 1 | 2 | MCAST-VPN, SAFI 5, all seven route types |
| `bgp-ls` | 11 | 1 | 2 | BGP-LS, AFI 16388 SAFI 71 and 72, the NLRI and every attribute TLV |
| `add-path` | 2 | 1 | 2 | Several paths to one prefix, and the Path Identifier |

### attributes

What it can say about a route.

| Feature | unit | func | lab | What |
|---|---:|---:|---:|---|
| `path-attributes` | 15 | 0 | 0 | The attribute container, the registry, and the well-known set |
| `communities` | 5 | 0 | 0 | Communities, extended, IPv6 extended and large, and every sub-type |
| `mp-reach` | 3 | 0 | 0 | MP_REACH_NLRI and MP_UNREACH_NLRI, the gates every family goes through |
| `tunnel-encap` | 2 | 0 | 0 | Tunnel encapsulation and the PMSI tunnel |
| `segment-routing` | 1 | 0 | 0 | The BGP Prefix-SID |
| `attr-set` | 1 | 0 | 1 | ATTR_SET, a path attribute set inside a path attribute |

### session

Getting a session up and keeping it.

| Feature | unit | func | lab | What |
|---|---:|---:|---:|---|
| `open` | 12 | 0 | 1 | OPEN, the optional parameters, and every capability |
| `messages` | 5 | 0 | 0 | The common header, KEEPALIVE, UPDATE and NOTIFICATION |
| `route-refresh` | 6 | 0 | 0 | ROUTE-REFRESH and outbound route filtering |
| `fsm` | 3 | 0 | 0 | The finite state machine, the TCP session and the two IO threads |

### routing

Deciding and advertising routes.

| Feature | unit | func | lab | What |
|---|---:|---:|---:|---|
| `rib` | 7 | 1 | 0 | Adj-RIB-In, the decision process and the Loc-RIB |
| `export` | 5 | 1 | 3 | The export rules, Adj-RIB-Out, UPDATE building and the MRAI timer |
| `fib` | 3 | 0 | 1 | Putting the Loc-RIB in a forwarding table |
| `show` | 2 | 0 | 0 | The three vendor styles, and the same state as plain data |

### errors

What a receiver makes of something wrong.

| Feature | unit | func | lab | What |
|---|---:|---:|---:|---|
| `validation` | 1 | 0 | 3 | Receive-side error handling, and the matrix of what three routers do |
| `fault` | 2 | 0 | 0 | Building the UPDATEs no RFC allows, and the catalog of them |

### programs

The four executables.

| Feature | unit | func | lab | What |
|---|---:|---:|---:|---|
| `daemon` | 12 | 1 | 0 | bgp4rd and bgp4r-cli: the control socket, the views and the configuration |
| `injector` | 5 | 1 | 0 | bgp4r-sim: the ten actions, the HTTP API and what it sent |
| `routegen` | 2 | 1 | 3 | Generating many prefixes and packing them into UPDATEs |
| `console` | 2 | 1 | 0 | An irb prompt on bgp4r: bgp4r console, and routegen --interact |
| `gen` | 17 | 1 | 2 | bgp/gen: UPDATEs and withdrawals from a spec, and what they meant |
| `capture` | 4 | 0 | 0 | Reading BGP off a wire or a pcap file, and bgp4r lab new |
| `speaker` | 1 | 0 | 4 | lab/speaker.rb and the five topologies under lab/topologies |
| `events` | 2 | 0 | 0 | The structured event stream both programs serve |
| `logging` | 1 | 0 | 1 | The injected logger, the process log and the log level |
| `live-feed` | 1 | 0 | 0 | The client for an old public BGP feed, whose functional twin must never run |

### contracts

Guards over the library and the suite, not over BGP.

| Feature | unit | func | lab | What |
|---|---:|---:|---:|---|
| `contracts` | 8 | 0 | 0 | The object contract, the hash round trips and the suite-wide guards |

## What each feature covers

`ruby test/run_feature.rb FEATURE --list` prints the files, with
what each needs. These are the parts that are not in that list.

### `add-path`

Several paths to one prefix, and the Path Identifier.

- RFC 7911
- 2 unit files, 1 functional
- lab:
  - `add_path_gobgp_test`, needs gobgpd
  - `add_path_topology_test`

```
ruby test/run_feature.rb add-path
```

### `attr-set`

ATTR_SET, a path attribute set inside a path attribute.

- RFC 6368 section 5
- 1 unit file
- lab:
  - `attr_set_gobgp_test`, needs gobgpd

```
ruby test/run_feature.rb attr-set
```

### `bgp-ls`

BGP-LS, AFI 16388 SAFI 71 and 72, the NLRI and every attribute TLV.

- RFC 9552
- Read first: `docs/bgp-ls.md`
- 11 unit files, 1 functional
- lab:
  - `link_state_frr_test`, needs frr
  - `link_state_gobgp_test`, needs gobgpd

```
ruby test/run_feature.rb bgp-ls
```

### `capture`

Reading BGP off a wire or a pcap file, and bgp4r lab new.

- Read first: `docs/daemon.md`
- 4 unit files

```
ruby test/run_feature.rb capture
```

### `communities`

Communities, extended, IPv6 extended and large, and every sub-type.

- RFC 1997, RFC 4360, RFC 5701, RFC 8092
- 5 unit files

```
ruby test/run_feature.rb communities
```

### `console`

An irb prompt on bgp4r: bgp4r console, and routegen --interact.

- Read first: `docs/console.md`
- 2 unit files, 1 functional

```
ruby test/run_feature.rb console
```

### `contracts`

The object contract, the hash round trips and the suite-wide guards.

- Read first: `docs/building-objects.md`
- 8 unit files

```
ruby test/run_feature.rb contracts
```

### `daemon`

bgp4rd and bgp4r-cli: the control socket, the views and the configuration.

- Read first: `docs/daemon.md`
- 12 unit files, 1 functional

```
ruby test/run_feature.rb daemon
```

### `events`

The structured event stream both programs serve.

- 2 unit files

```
ruby test/run_feature.rb events
```

### `evpn`

EVPN, AFI 25 SAFI 70, all eleven route types.

- RFC 7432, RFC 9136, RFC 9251, RFC 9572
- Read first: `docs/evpn.md`
- 3 unit files, 1 functional
- lab:
  - `evpn_frr_test`, needs frr
  - `evpn_gobgp_test`, needs gobgpd

```
ruby test/run_feature.rb evpn
```

### `export`

The export rules, Adj-RIB-Out, UPDATE building and the MRAI timer.

- RFC 4271 sections 5.1 and 9.2.1.1, RFC 4456
- 5 unit files, 1 functional
- lab:
  - `rib_router_frr_test`, needs frr
  - `rib_router_gobgp_test`, needs gobgpd
  - `speaker_router_test`

```
ruby test/run_feature.rb export
```

### `fault`

Building the UPDATEs no RFC allows, and the catalog of them.

- RFC 7606
- Read first: `docs/protocol-testing.md`
- 2 unit files

```
ruby test/run_feature.rb fault
```

### `fib`

Putting the Loc-RIB in a forwarding table.

- 3 unit files
- lab:
  - `fib_test`, needs root

```
ruby test/run_feature.rb fib
```

### `flow-spec`

Flow specification rules, SAFI 133 and 134.

- RFC 8955, RFC 8956
- Read first: `docs/flow-spec.md`
- 3 unit files, 1 functional
- lab:
  - `flow_spec_frr_test`, needs frr
  - `flow_spec_gobgp_test`, needs gobgpd

```
ruby test/run_feature.rb flow-spec
```

### `fsm`

The finite state machine, the TCP session and the two IO threads.

- RFC 4271 section 8
- 3 unit files

```
ruby test/run_feature.rb fsm
```

### `gen`

bgp/gen: UPDATEs and withdrawals from a spec, and what they meant.

- Read first: `docs/route-generation.md`
- 17 unit files, 1 functional
- lab:
  - `gen_frr_test`, needs frr
  - `gen_gobgp_test`, needs gobgpd

```
ruby test/run_feature.rb gen
```

### `injector`

bgp4r-sim: the ten actions, the HTTP API and what it sent.

- Read first: `docs/daemon.md`
- 5 unit files, 1 functional

```
ruby test/run_feature.rb injector
```

### `labelled`

Labelled unicast, SAFI 4, and the label stack.

- RFC 8277
- 2 unit files

```
ruby test/run_feature.rb labelled
```

### `live-feed`

The client for an old public BGP feed, whose functional twin must never run.

- 1 unit file

```
ruby test/run_feature.rb live-feed
```

### `logging`

The injected logger, the process log and the log level.

- 1 unit file
- lab:
  - `log_level_test`

```
ruby test/run_feature.rb logging
```

### `mcast-vpn`

MCAST-VPN, SAFI 5, all seven route types.

- RFC 6514, RFC 6515, RFC 7441
- Read first: `docs/mcast-vpn.md`
- 3 unit files, 1 functional
- lab:
  - `mcast_vpn_frr_test`, needs frr
  - `mcast_vpn_gobgp_test`, needs gobgpd

```
ruby test/run_feature.rb mcast-vpn
```

### `messages`

The common header, KEEPALIVE, UPDATE and NOTIFICATION.

- RFC 4271 section 4
- 5 unit files

```
ruby test/run_feature.rb messages
```

### `mp-reach`

MP_REACH_NLRI and MP_UNREACH_NLRI, the gates every family goes through.

- RFC 4760 sections 3 and 4, RFC 8950
- 3 unit files

```
ruby test/run_feature.rb mp-reach
```

### `open`

OPEN, the optional parameters, and every capability.

- RFC 4271 section 4.2, RFC 5492, RFC 9072
- 12 unit files
- lab:
  - `capabilities_frr_test`, needs frr

```
ruby test/run_feature.rb open
```

### `path-attributes`

The attribute container, the registry, and the well-known set.

- RFC 4271 section 5
- Read first: `docs/building-objects.md`
- 15 unit files

```
ruby test/run_feature.rb path-attributes
```

### `rib`

Adj-RIB-In, the decision process and the Loc-RIB.

- RFC 4271 section 9
- 7 unit files, 1 functional

```
ruby test/run_feature.rb rib
```

### `route-refresh`

ROUTE-REFRESH and outbound route filtering.

- RFC 2918, RFC 7313, RFC 5291 section 4
- 6 unit files

```
ruby test/run_feature.rb route-refresh
```

### `routegen`

Generating many prefixes and packing them into UPDATEs.

- Read first: `docs/daemon.md`
- 2 unit files, 1 functional
- lab:
  - `generate_test`
  - `routegen_loopback_test`
  - `routegen_test`, needs docker

```
ruby test/run_feature.rb routegen
```

### `rt-constrain`

Route Target membership, AFI 1 SAFI 132.

- RFC 4684 section 4
- 1 unit file, 1 functional
- lab:
  - `rt_constrain_gobgp_test`, needs gobgpd

```
ruby test/run_feature.rb rt-constrain
```

### `segment-routing`

The BGP Prefix-SID.

- RFC 8669
- 1 unit file

```
ruby test/run_feature.rb segment-routing
```

### `show`

The three vendor styles, and the same state as plain data.

- 2 unit files

```
ruby test/run_feature.rb show
```

### `speaker`

lab/speaker.rb and the five topologies under lab/topologies.

- Read first: `docs/routescope-labs.md`
- 1 unit file
- lab:
  - `add_path_topology_test`
  - `bgp4r_lab_topology_test`
  - `speaker_test`
  - `two_speakers_test`, needs docker

```
ruby test/run_feature.rb speaker
```

### `tunnel-encap`

Tunnel encapsulation and the PMSI tunnel.

- RFC 9012, RFC 6514 section 5
- 2 unit files

```
ruby test/run_feature.rb tunnel-encap
```

### `unicast`

IPv4 and IPv6 unicast, SAFI 1 and 2, and the prefix encodings.

- RFC 4271 section 4.3, RFC 4760
- 4 unit files

```
ruby test/run_feature.rb unicast
```

### `validation`

Receive-side error handling, and the matrix of what three routers do.

- RFC 7606
- Read first: `docs/protocol-testing.md`
- 1 unit file
- lab:
  - `fault_matrix_frr_test`, needs frr
  - `fault_matrix_native_test`, needs gobgpd
  - `fault_matrix_test`, needs docker

```
ruby test/run_feature.rb validation
```

### `vpn`

VPN-IPv4 and VPN-IPv6, SAFI 128 and 129, and the Route Distinguisher.

- RFC 4364 section 4.2
- 2 unit files

```
ruby test/run_feature.rb vpn
```

## Turning logging on

### For a test run

`BGP4R_LOG` turns the library's log on for a test, on standard
error, so a failure can be read instead of bisected:

```
BGP4R_LOG=debug ruby test/run_unit.rb 2> /tmp/bgp4r.log
BGP4R_LOG=debug ruby test/run_feature.rb evpn
BGP4R_LOG=debug ruby test/run_lab.rb local
```

`debug`, `info` or `warn`, with `2` and `1` for the first two. An
unknown value warns and changes nothing.

**A single file needs `-rtest/log_on`**, because the three runners
are what install the switch and `ruby -I. <one file>` goes through
none of them:

```
BGP4R_LOG=debug ruby -I. -rtest/log_on test/functional/rib_router_test.rb
```

At `debug` that is about a thousand lines for one functional test,
each message decoded and in hex, which is the form a line can be
lifted out of and pasted into a test as a fixture.

**Two limits.** A test that silences the log itself wins, which
`test/functional/sim_test.rb` and `test/unit/daemon/candidate_test.rb`
do on purpose. And an object handed its own logger writes there
instead, which is what `bgp/logging.rb` is for.

### For the programs

**The flags are the same on every program that has them.** `-l` says
where, `-d` says how much:

| Flag | Means |
|---|---|
| `-l FILE`, `--log FILE` | write the log there |
| `-l -`, or no `-l` at all | write it to standard output |
| `-d`, `--debug` | log every message as well, which is level `debug` |

`bgp4rd`, `bgp4r-sim` and `bgp4r routegen` all take both. `bgp4r-cli`
and `bgp4r capture` take neither, on purpose: the client prints the
daemon's answer and `capture` prints one JSON object per message, so
in both the output *is* the product.

With no `-d` the level comes from the `log_level` key in the YAML,
which is `debug`, `info` or `warn` and defaults to `info`. There is
no `--log-level` flag.

```
ruby -I. exe/bgp4rd -f lab/routescope/bgp4r-lab/rtr/bgp4rd.yml \
  -s /tmp/d.sock -l - -d
ruby -I. exe/bgp4r-sim examples/sim.yml --api 127.0.0.1:8080 -l - -d
ruby -I. exe/bgp4r routegen --peer 10.0.0.2 --peer-as 65002 -l - -d
```

**There is no `examples/bgp4rd.yml`.** `bgp4r-sim` has
`examples/sim.yml` and the daemon has no minimal example at all, so
the only configuration to copy is the lab one above, which expects
three neighbours on addresses a laptop does not have. The daemon
starts and answers its socket regardless.

`LAB_LOG_LEVEL` overrides the YAML for every speaker, daemon and
injector in a run, which is how a lab is turned up without editing
a node file:

```
LAB_LOG_LEVEL=debug ruby test/run_lab.rb local
LAB_LOG_LEVEL=debug ruby -I. lab/speaker.rb lab/topologies/two-speakers/r1.yml
LAB_LOG_LEVEL=debug docker compose -f lab/topologies/two-speakers/compose.yml up
```

Three lab scenarios print both speakers' logs when a test fails, so
a failure in `routegen`, `speaker_router` or `two_speakers` needs no
flag at all to be readable.

### Reading a running daemon's log

`bgp4rd` keeps its last 2000 lines in front of the real destination,
so a console can ask for them without a file:

```
ruby -I. exe/bgp4r-cli -s /tmp/d.sock show.log
ruby -I. exe/bgp4r-cli -s /tmp/d.sock show.log '{"count":500}'
```

`count` defaults to 100 and is clamped to 2000. The level is a live
configuration key, so a running daemon can be turned up and down:

```
ruby -I. exe/bgp4r-cli -s /tmp/d.sock config.load '{"lines":["set log_level debug"]}'
ruby -I. exe/bgp4r-cli -s /tmp/d.sock config.commit
```

A log line is for a person. An event carries a kind and a data hash
a program switches on, and is a separate stream:

```
ruby -I. exe/bgp4r-cli -s /tmp/d.sock events.subscribe
ruby -I. exe/bgp4r-cli -s /tmp/d.sock events.subscribe '{"since":42}'
curl 127.0.0.1:8080/api/events?since=42
```

## Environment variables

The library and the four executables read none of these. Every one
is read by a test, a lab harness or a node file, so none of them
changes what goes on the wire.

| Variable | Default | What it does |
|---|---|---|
| `LAB_LOG_LEVEL` | the node file's `log_level`, else `info` | `debug`, `info` or `warn` for every speaker in a run |
| `BGP4R_LOG` | unset | `debug` or `info` turns logging on for a unit or functional run |
| `BGP4R_SOCKET` | `/run/bgp4r/bgp4rd.sock` | the control socket, for `bgp4rd` and `bgp4r-cli` |
| `BGP4R_SIM_API` | `127.0.0.1:8080` | where `bgp4r-sim`'s HTTP API listens |
| `RIB_MODEL_STEPS` | `400` | steps in the RIB model check in `rib/table_test` |
| `ROUTEGEN_COUNT` | the node file's `count` | overrides every `generate` block's prefix count |
| `ROUTEGEN_PER_UPDATE` | the node file's `per_update` | overrides prefixes per UPDATE |
| `FAULT_SETTLE` | `2` | seconds the fault matrix waits per case |
| `GOBGPD`, `GOBGP` | `gobgpd`, `gobgp` | where the GoBGP binaries are |
| `FRR_BGPD`, `VTYSH` | `/usr/lib/frr/bgpd`, `vtysh` | where FRR's binaries are |
| `GOBGP_IMAGE` | a 4.x image | the container image for the Compose fault matrix |
| `LAB_REQUIRE_DOCKER` | unset | `1` fails instead of omitting when Docker is missing |
| `LAB_REQUIRE_GOBGPD` | unset | `1` fails instead of omitting when `gobgpd` is missing |
| `LAB_REQUIRE_FRR` | unset | `1` fails instead of omitting when FRR is missing |
| `LAB_REQUIRE_NETNS` | unset | `1` fails instead of omitting without CAP_NET_ADMIN |

**The four `LAB_REQUIRE_*` are what CI sets**, so a job that was
meant to measure a router fails rather than passing with every case
omitted. Set them by hand when a run that printed no failures also
printed no assertions.

## Driving it by hand

The suite is one way in. These are the others, and each is the
shortest path to watching something happen.

### Send a router many routes

The oldest tool here, and still the quickest demonstration:

```
ruby -I. examples/routegen examples/routegen.yml
ROUTEGEN_LOG_LEVEL=debug ruby -I. examples/routegen examples/routegen.yml
```

The same thing through the modern path, which reads a node file and
takes the flags above:

```
ruby -I. exe/bgp4r routegen --peer 10.0.0.2 --peer-as 65002 \
  --count 200000 --per-update 127
```

### Drive a session from outside

`bgp4r-sim` starts silent on purpose: nothing is announced until the
API asks, so a baseline nobody configured is a baseline an assertion
can rest on.

```
ruby -I. exe/bgp4r-sim examples/sim.yml --api 127.0.0.1:8080 -l - &
curl 127.0.0.1:8080/api/status
curl -X POST -H 'X-BGP4R: routescope' \
     -d '{"prefixes":["10.1.0.0/24"],"med":100}' \
     127.0.0.1:8080/api/announce
curl -X POST -H 'X-BGP4R: routescope' \
     -d '{"case":"origin_value","prefixes":["10.3.1.0/24"]}' \
     127.0.0.1:8080/api/fault
curl 127.0.0.1:8080/api/sent
```

`/api/fault` takes any name from `BGP::Fault::CATALOG`. To see them:

```
ruby -I. -e 'require "bgp4r"; require "bgp/fault"; puts BGP::Fault.names'
```

### Run a router and ask it questions

```
ruby -I. exe/bgp4rd -f /etc/bgp4r/bgp4rd.yml -s /tmp/d.sock -l - &
ruby -I. exe/bgp4r-cli -s /tmp/d.sock -c 'show bgp summary'
ruby -I. exe/bgp4r-cli -s /tmp/d.sock -c 'show bgp' --style junos
ruby -I. exe/bgp4r-cli -s /tmp/d.sock show.rib --pretty
ruby -I. exe/bgp4r-cli -s /tmp/d.sock route.originate '{"prefixes":["10.255.0.0/24"]}'
```

### Read BGP off a wire

No interface and no root for a file:

```
ruby -I. exe/bgp4r capture -r a.pcap
tcpdump -U -n -s 0 -w - -i eth1 tcp port 179 | ruby -I. exe/bgp4r capture -r -
sudo ruby -I. exe/bgp4r capture -i eth1
```

### Start a lab of your own

```
ruby -I. exe/bgp4r lab new                  # the topologies it found
ruby -I. exe/bgp4r lab new /tmp/my-lab add-path
```

Every Compose topology here builds with `context: ../../..`, so a
copy cannot build its own image where it landed. Build it once in a
checkout and run the copy without `--build`.

### What the library knows

Four things answer for themselves, so nothing about them needs to be
written down:

```
ruby -I. -e 'require "bgp4r"; p BGP::Attr.registrations.size'
ruby -I. -e 'require "bgp4r"; p BGP::Extended_community::FACTORY.size'
ruby -I. test/unit/to_hash_status.rb
ruby -I. test/unit/to_hash_status.rb pending
ruby -I. test/coverage_matrix.rb
```

The last one is the other way of reading this document. **This one
says which tests exist, and that one says what they leave out**: per
path attribute, whether a case in `BGP::Fault::CATALOG` sends it and
whether any router has ever seen it; per address family, which ones
the build gate knows and what each router's lab tests vouch for.
Read its header before trusting a column, because `absence` means a
router does not have the family and so vouches for nothing about our
octets.

## The guard

`test/unit/features_test.rb` holds this document and the registry to
the tree. It fails the unit suite when a test file carries no
feature, when a feature names a file that is not there, and when
this document is not what `test/features_doc.rb` generates. So a new
test file has to be tagged before the suite is green again, which is
the same arrangement `test/unit/lab_groups_test.rb` has with the CI
matrix.

198 of 198 test files are tagged. The
remainder, if any, is what the guard names.
