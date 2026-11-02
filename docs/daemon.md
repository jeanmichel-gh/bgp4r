# bgp4rd and bgp4r-sim

Two programs built on the bgp4r library: a BGP daemon and a route
injector. Both ship in the gem and in the image, both run standalone, and
routescope drives them through the same APIs a person uses.

This document owns the programs: what they do, what they need, their
configuration, their command lines and the JSON they answer with.
`docs/routescope-labs.md` owns the integration: the drivers, the
inspector tables, the map and the labs. Neither repeats the other.

**Status: a design, with one command built.** Neither `bgp4rd` nor
`bgp4r-sim` exists. `bgp4r`, the umbrella, does: `bgp4r capture` and
`bgp4r version`, in `exe/bgp4r` over `bgp/capture/`, and the Capture
section at the end of this document is no longer a design. The other
three commands are not stubbed, deliberately, because an executable in a
released gem that answers nothing is worse than one that is not there.
What exists under all of it is the
library under them, which is most of the work: `bgp/neighbor/` for the
FSM and the session, `bgp/rib/` for the Adj-RIB-In, the decision process,
the Loc-RIB, the export rules, the UPDATE builder, MRAI pacing and the
FIB adapter, `bgp/misc/route_generator.rb` for the generator, and
`BGP::Fault::CATALOG` for the faults. `lab/speaker.rb` is a third of
`bgp4rd` already: it holds sessions, originates and records, and it does
not route.

## The one principle

**Neither program knows routescope exists.** A console is one more client
of an API a person can use by hand. So every design question here is
answered for the standalone case first, and routescope gets whatever that
produces.

The test of it: every number routescope shows must be reachable with one
command in a terminal, and every action it takes must be a command too.

## Two programs, not one

| | `bgp4rd` | `bgp4r-sim` |
|---|---|---|
| What | a BGP router | an injector and fault source |
| Answers | its sessions, its RIBs, its decision, its FIB | what it has sent, its sessions |
| Takes orders | reload, clear a peer, originate | announce, withdraw, generate, fault, replay, flap |
| Validates on send | never, per Conventions | never, and that is the point |
| Holds a Loc-RIB | yes | no |
| Control plane | a Unix socket, JSON lines | HTTP on the loopback |
| routescope kind | `bgp4r` | `bgp4r-sim` |

**Do not merge them.** A node that both answers and acts has state no
reader can trust mid-scenario, and bgp4r's rule against a global test
switch applies at the lab level for the same reason.

The control planes differ because the uses differ, and both follow
ospfv2. A daemon is operated from a shell, so it gets a socket and a
client, which is `vtysh` and `birdc` ergonomics. An injector is driven by
a page and by a scenario runner, so it gets HTTP, which `docker exec`
reaches with one Ruby line and no client installed.

## What ships

Four commands, matching ospfv2's `ospfv2`, `ospfd` and `ospf-cli`.

| Command | What it is | Status |
|---|---|---|
| `bgp4rd` | the daemon | a design |
| `bgp4r-cli` | its client, over the socket | a design |
| `bgp4r` | the umbrella: `sim`, `routegen`, `capture`, `lab new`, `version` | built, with `capture` and `version` |
| `bgp4r-sim` | an alias for `bgp4r sim`, so a container command reads plainly | a design |

The gemspec declares `bgp4r` and nothing else. A subcommand that does not
exist is named in the usage as not yet implemented, so a person asking
for one gets the list rather than a backtrace.

```sh
# in the VM
gem install bgp4r
bgp4rd -f /etc/bgp4r/bgp4rd.yml &
bgp4r-cli -c 'show bgp summary'
```

```sh
# in the VM
docker build -t bgp4r .
docker run --rm -v $PWD/sim.yml:/lab/sim.yml bgp4r sim /lab/sim.yml --api 0.0.0.0:8080
```

The gem declares `logger` and nothing else, which is the library's own
rule. The image adds `tcpdump` and `iproute2`, for `bgp4r capture` and
for the FIB, the way ospfv2's does.

# bgp4rd, the daemon

## Functions

1. **Sessions.** Passive and active, IPv4 and IPv6 transport, any
   capability the library implements. The FSM is `BGP::Neighbor`'s.
2. **Adj-RIB-In per peer**, fed by `rib.attach(neighbor)`, which already
   exists and is already tested over a socket.
3. **Decide.** RFC 4271 section 9.1.2.2 steps a to g, with the RFC 4456
   section 9 CLUSTER_LIST step between f and g. `Decision#best` returns
   the winner, the step that decided it and **why each other path lost**,
   which is the thing no other implementation in a lab can say about
   itself.
4. **Advertise.** The export rules of RFC 4271 section 5.1 and RFC 4456,
   the Adj-RIB-Out per peer, UPDATE packing, and MinRouteAdvertisement
   pacing. `rib.advertise`.
5. **Originate** prefixes from its configuration, and on command.
6. **Install**, optionally. `rib.install(table: N)` puts the Loc-RIB in a
   kernel table through iproute2 and takes it out again on exit.
7. **Answer** a control API, below.
8. **Log and emit events**, so a console has a timeline and a person has
   a reason for every refusal.
9. **Reload** its configuration without dropping sessions it need not
   drop.

Items 1 to 6 are wiring, not new protocol code. Items 7 to 9 are new.

## Requirements

**No root in the ordinary case.** It binds its own port, so a lab gives
each speaker one and nothing needs privilege. Port 179 works inside a
container because Docker sets `net.ipv4.ip_unprivileged_port_start=0` in
the container's own namespace. Installing routes needs `CAP_NET_ADMIN`
and is off unless asked for.

**One runtime gem.** `logger`. Nothing in the daemon may add a second,
which rules out a web framework, a JSON gem and an event-machine. The
socket server is `UNIXServer` and one thread per client, as ospfd's is.

**It must not validate what it sends.** Conventions is explicit and the
daemon does not get an exception. A deliberately wrong UPDATE is a test
override on one object, never a flag on the originator. Validation stays
in `validation.rb` and runs on receive only.

**The session thread must not block.** The decision process and the
export side run on the feed's worker thread, because stalling the event
dispatch thread stops KEEPALIVEs and the session dies on a holdtime
expiry. That is already how `bgp/rib/` is built; the daemon must not
undo it by doing work in an observer.

**Reads are consistent.** `Table#synchronize` is reentrant and public, so
a control-plane read sees one coherent snapshot rather than a RIB
mid-decision.

**Every refusal has a reason a person can read.** `Router#skipped` says
what was not advertised and to whom, `FibInstaller#failed` says what the
kernel refused. Both are already there and both must reach the API: a
route silently not advertised is the hardest thing to see from outside.

**A scale target.** A full table is about a million IPv4 prefixes. The
recorded decision is to share identical attribute sets by their encoded
bytes rather than hold one object per route, and to measure with
`routegen` rather than guess. The daemon inherits that and the API must
not defeat it: `show.rib` is paged, and no endpoint builds a
million-element array in memory.

## Configuration

One YAML file, extending `lab/speaker.rb`'s node file, which is already
documented in `lab/README.md` and already has the session half right.

```yaml
router_id: 10.255.0.1
as: 65000
socket: /run/bgp4r/bgp4rd.sock     # optional
state_file: /tmp/bgp4r-state.json  # optional, for a reader with no socket
log_level: info

neighbors:
  - address: 10.0.10.1
    as: 65010
    connect: true
    hold_time: 30
    description: inj1
    capabilities: [as4_byte, route_refresh, {add_path: [3, 1, 1]}]
    record: routes

originate:
  - prefixes: [10.255.0.0/24]
    med: 10
    communities: ['65000:1']

export:
  next_hops: { 1: 10.0.20.1 }      # ours, per AFI, toward external peers
  route_reflector: false
  clients: []                      # RFC 4456 section 6, when a reflector
  mrai: { ebgp: 0, ibgp: 0 }       # 0 is off, which stays the default

fib:
  table: 100                       # absent means compute and do not install
```

Three notes on it.

`capabilities` takes `add_path` as `(send_recv, afi, safi)`, matching
`CAP::Add_path#add`, so `[3, 1, 1]` is IPv4 unicast both ways. Three
comments in the repository gave `[1, 1, 3]` while meaning that, which is
SAFI 3, NSAP, receive only.

`mrai` defaults to off, which is the recorded decision: a script driving
a router through a sequence of UPDATEs wants each one on the wire when it
says so, and thirty seconds of silence reads as a bug in the device under
test. `Mrai.suggested` asks for RFC 4271 section 10's values instead.

`export.next_hops` is required for any address family the daemon
advertises to an external peer. `Export` will not invent our address, and
the alternative to refusing is sending a next hop that is not ours, which
is how a route becomes a black hole.

## The command line

```
bgp4rd -f FILE [--socket PATH] [--state FILE] [--log FILE] [-d]
```

`-d` adds the per-message trace. `--log -` is standard output, which is
what a container wants. With no `--socket` it uses
`/run/bgp4r/bgp4rd.sock`, or `$XDG_RUNTIME_DIR` when that is not
writable, so an unprivileged standalone run works with no arguments
beyond the file.

```
bgp4r-cli [--socket PATH] -c 'COMMAND' | METHOD [JSON]
```

Two forms on purpose. `-c` takes an operator command and prints text, so
a person types what they would type at a router:

```sh
# in the VM
bgp4r-cli -c 'show bgp summary'
bgp4r-cli -c 'show bgp 10.255.10.0/24'
bgp4r-cli -c 'clear bgp 10.0.10.1'
```

The method form takes an API method and prints JSON, so a script and a
driver read data rather than parse a table:

```sh
# in the VM
bgp4r-cli show.peers
bgp4r-cli show.rib '{"prefix":"10.255.10.0/24"}'
```

`show bgp` renders through `bgp/rib/show.rb`, which already prints the
Loc-RIB in three styles: `rib.show`, `rib.show(:junos)` and
`rib.show(:iosxr)`. So `-c 'show bgp'` is IOS style and `--style junos`
switches it. Those are **in the style of** those commands and not copies,
and no test may depend on the text byte for byte.

## The control API

A Unix socket, one JSON object per line, request and reply, as ospfd's
is. Dotted method names so a reader can guess them.

| Method | Answers |
|---|---|
| `show.status` | router id, AS, uptime, the peers, a summary |
| `show.peers` | one row per session |
| `show.routes` | the Loc-RIB, one row per prefix, its best path |
| `show.rib` | every candidate path per prefix, with the decision |
| `show.adj_in` | one peer's Adj-RIB-In |
| `show.adj_out` | what was sent to one peer, and what was skipped |
| `show.fib` | what the daemon believes is in the kernel table, and what failed |
| `show.log` | the last N lines |
| `api.info` | version, the method list, the event sequence |
| `events.subscribe` | a stream, one event per line |
| `config.load`, `config.commit`, `config.compare` | a candidate configuration |
| `peer.clear`, `peer.stop`, `peer.start` | one session |
| `peer.refresh` | a ROUTE-REFRESH, RFC 2918 and the RFC 7313 subtypes |
| `route.originate`, `route.withdraw` | our own prefixes |

Mutating methods are separate names rather than a flag, so a read-only
client is a list of methods and not a trust decision.

## The JSON

`show.status`, which is the shape routescope's `#bgp(container)` wants:

```json
{ "router_id": "10.255.0.1", "as": 65000, "uptime": 412,
  "peers": [
    { "address": "10.0.10.1", "router_id": "10.255.10.1", "remote_as": 65010,
      "state": "established", "description": "inj1", "uptime": 380,
      "received": 4, "sent": 2, "flaps": 0, "last_error": null,
      "capabilities": ["as4_byte", "route_refresh", "mbgp_ipv4_unicast"] } ],
  "summary": { "established": 1, "peers": 2, "rib": 7 } }
```

States are lowercase and are RFC 4271 section 8's: `idle`, `connect`,
`active`, `opensent`, `openconfirm`, `established`. `router_id` on a peer
is nil until the OPEN arrives, which is what lets a map draw a session
that has not come up.

`show.routes`, one row per prefix:

```json
[ { "prefix": "10.255.10.0/24", "next_hop": "10.0.10.1", "as_path": "65010",
    "origin": "igp", "med": 100, "local_pref": 100, "from": "10.0.10.1",
    "paths": 2, "best": true } ]
```

`show.rib`, which is the daemon's own answer and has no counterpart in
any router's output:

```json
[ { "prefix": "10.255.10.0/24",
    "paths": [
      { "from": "10.0.10.1", "next_hop": "10.0.10.1", "as_path": "65010",
        "local_pref": 100, "med": 100, "best": true, "lost_at": null, "reason": "med" },
      { "from": "10.0.11.1", "next_hop": "10.0.11.1", "as_path": "65010",
        "local_pref": 100, "med": 200, "best": false, "lost_at": "med",
        "reason": "higher MED from the same neighbouring AS" } ] } ]
```

`Decision::Result` is `Struct.new(:best, :reason, :eliminated)` with
`eliminated` a path to step map, so this is a serialisation and not a new
computation. `reason` is words for a person.

**The two paragraphs above are what `bgp/rib/view.rb` is built to, and
it departs from them in two places**, both measured against the library
in #230 and both corrected here rather than worked around.

The example gives the **best** path `"reason": "med"`, the step symbol,
where the prose says `reason` is words for a person. The view makes every
`reason` words and puts the step in `decided_by` on the prefix row, which
is where `Decision::Result` keeps it: one step per prefix rather than one
hidden in whichever path won. So a daemon answering `show.rib` from the
view answers `decided_by` beside `paths`, and the keys inside a path are
these.

And `show.status`'s peer row is mostly a **session** fact. A Table knows
a peer's address, remote AS, router ID and Adj-RIB-In size and nothing of
its state, uptime, flap count, last error or negotiated capabilities, so
the view answers the four it has, under these key names, and adds `type`,
`best` and, in router mode, `sent`. The daemon merges the session half
onto that. Same for `uptime` and `summary.established`, which are the
daemon's own.

`lost_at` is one of **fifteen** values the decision process already uses,
measured on 2026-11-01 rather than written from memory, and this said
fourteen until the fifteenth was measured in #230. Ten tie-break steps,
in `Decision::STEPS` order:

```
local_pref  as_path_length  origin  med  ebgp_over_ibgp  igp_cost
router_id  cluster_list_length  peer_address  path_id
```

Four that drop a path before any comparison, `Decision::INELIGIBLE`:

```
next_hop_unreachable  as_loop  originator_id_loop  cluster_list_loop
```

And `duplicate`, the fifteenth, which `Decision#best` files when only
identical routes are left after every step. **No Table can produce it**,
because an imported route is keyed by its peer and its Path Identifier
and a `Peer` is its address, so two candidates always differ at
`peer_address` or at `path_id`; `Decision#best` is public and pure, so a
caller can. A reader of this list wants it anyway, since the daemon will
answer it the day something else feeds the decision process.

Two things in that list are worth a reader's attention. `igp_cost` is
always 0 here unless a resolver is given, because the daemon has no IGP.
And `cluster_list_length` sits between `router_id` and `peer_address`,
which is RFC 4456 section 9 putting it between RFC 4271's steps f and g.

# bgp4r-sim, the injector, with routegen

## Functions

1. **Bring sessions up**, dialling or waiting, with any capability set,
   including ones that disagree with what it then sends.
2. **Announce and withdraw** on command: a prefix list, or a generated
   range, with any path attributes.
3. **Change an attribute** on something already announced, so a scenario
   can move one input and watch a router re-decide.
4. **Generate at scale.** This is routegen, below.
5. **Inject a fault** by name from `BGP::Fault::CATALOG`, which is the
   eighteen RFC 7606 cases the matrix already drives.
6. **Replay** a captured UPDATE byte for byte, which is what the
   keep-what-you-cannot-read work exists to make possible.
7. **Fault a session**: stop, start, flap on a count and an interval, or
   send a NOTIFICATION with any code and subcode, including ones RFC 4271
   does not define.
8. **Report** what it has sent, its rate and its sessions.

**It starts silent.** No announcement happens until asked, because a
baseline the configuration created is a baseline no assertion can rest
on. A scenario asserts the peer holds nothing, then announces, then
asserts again.

**It validates nothing, and that is the whole product.** Any attribute,
any length, any order, any repetition, a Path Identifier on a session
that negotiated none. The library's first Convention is what makes this
program possible and the injector must not grow a check.

## routegen

The generator exists: `BGP::RouteGenerator.new(start, count, per_update,
path_attribute, nexthop:, mp_reach:, path_id:)` with
`each_update(session_info) { |u| }`. It streams, so a million prefixes
never sit in memory. `examples/routegen` drives it from a YAML file today
and keeps working.

It becomes reachable three ways, one implementation behind all three.

**As an action**, which is what a scenario uses:

```json
POST /api/announce
{ "generate": { "start": "11.0.0.0/28", "count": 200000, "per_update": 127 },
  "med": 100, "communities": ["100:1"], "as_path": [90, 80] }
```

**As a subcommand**, for pointing at a real router with no container:

```sh
# in the VM
bgp4r routegen examples/routegen.yml
bgp4r routegen --peer 10.0.0.2 --peer-as 65002 --count 200000 --per-update 127
```

**As a configuration block**, for a lab that wants a feed at start-up,
which is the one case where the start-silent rule is waived and has to be
written down in the node file.

Two requirements the generator imposes on the injector, and both are
easy to get wrong:

**No Adj-RIB-Out for generated routes.** Recording a million prefixes to
know what was sent defeats the streaming and is the whole reason
`RouteGenerator` builds and sends one UPDATE at a time. So a generated
feed is fire and forget, and `withdraw` of a generated range regenerates
the same prefixes rather than reading a list back.

**The packing is arithmetic, not measurement.** RFC 4271 section 4 caps a
message at 4096 octets, which is `BGP::Message::MAX_SIZE`, and the prefix
cost is `1 + (len + 7) / 8`, four more with a Path Identifier.
Re-encoding per candidate prefix would be the difference between a second
and an hour. Every finished message is still measured once, so a slip
raises rather than reaching the wire.

What it reports, so a console can show a feed rather than a spinner:
`prefixes_sent`, `updates_sent`, `started_at`, `finished_at` and
`prefixes_per_second`. `lab/speaker.rb`'s recorder already computes those
for the receive side.

## Configuration

```yaml
router_id: 10.255.10.1
as: 65010
api: 127.0.0.1:8080
log_level: info

neighbors:
  - address: 10.0.10.2
    as: 65000
    connect: true
    hold_time: 30
    capabilities: [as4_byte, {add_path: [3, 1, 1]}]

# No announce block. An injector starts silent, on purpose.
```

`api:` is where it binds, and the loopback is the default for the reason
below.

## The HTTP API

`Drivers::Sim`'s shape, so routescope's driver is a copy with the paths
changed: HTTP on `127.0.0.1:8080`, GET for reads, POST for actions, and a
header on every POST.

**It binds the loopback by default.** An API on `0.0.0.0` is reachable
from every other node on the lab segment, which turns an injector into
something any container can drive and makes a scenario's record of what
happened incomplete. A lab reaches it with `docker exec`, which needs no
address.

**A POST carries `X-BGP4R: routescope`.** ospfv2 added the equivalent so
a cross-site form in a browser cannot flap a lab's links, and the same
reasoning holds for an action that tears a session down.

Reads:

| Path | Answers |
|---|---|
| `GET /api/status` | the same shape `bgp4rd` answers, so one driver reads both |
| `GET /api/peers` | one row per session |
| `GET /api/sent` | what it has announced, and the rate |
| `GET /api/topology` | what it is configured to be able to send |
| `GET /api/events?since=N` | its events, Sim's own shape |

Actions, as `action => [path, body keys]`, which is the table
`Drivers::Sim::ACTIONS` already is:

| Action | Path | Body |
|---|---|---|
| `announce` | `/api/announce` | `prefixes` or `generate`, `next_hop`, `as_path`, `med`, `local_pref`, `communities`, `path_id`, `peer` |
| `withdraw` | `/api/withdraw` | the same selectors |
| `attribute` | `/api/attribute` | a prefix set and the attributes to change |
| `fault` | `/api/fault` | `case` from `BGP::Fault::CATALOG`, `prefixes` |
| `replay` | `/api/replay` | `hex`, the octets to send unchanged |
| `notification` | `/api/notification` | `code`, `subcode`, `data` |
| `session.stop` | `/api/session/stop` | `peer` |
| `session.start` | `/api/session/start` | `peer` |
| `session.flap` | `/api/session/flap` | `peer`, `count`, `interval` |
| `refresh` | `/api/refresh` | `peer`, `afi`, `safi`, `subtype` |

**The body keys are the node file's own keys.** `prefixes`, `med`,
`as_path`, `communities`, `next_hop`, `local_pref`, `path_id` are what
`lab/README.md` already documents for an announce block. So the
injector's runtime vocabulary is bgp4r's configuration vocabulary, there
is one thing to learn, and `lab/README.md` is already its reference.

**`fault` and `replay` are the point.** An injector that ships without
them is a worse FRR, and the argument for building any of this is gone.

A refused action answers 4xx with `{"error": "..."}`, and the exit status
of the `docker exec` carries it, because `exit(code < 300 ? 0 : 1)` is
how a driver tells a refusal from a success when all it gets is an exit
status.

# Capture

**Built.** `bgp/capture/` holds it and `bgp4r capture` runs it.

`bgp4r capture -i IFACE` prints newline-delimited JSON, the same envelope
as ospfv2's so a console's decoder pane needs no second shape:

```
{"capture":{"interface":"eth1","file":null,"link":"ethernet","filter":"tcp port 179","unit":"message"}}
{"packet":{"seq":1,"time":"...","flow":"10.0.0.1:179 > 10.0.0.2:51234","length":29,"hex":"...","summary":"OPEN AS 65001 holdtime 30s id 10.0.0.1","fields":[...],"errors":[]}}
{"error":"..."}
```

An `error` line is the last line and the exit status is 1. Flags:
`-i IFACE` (default `eth0`), `-r FILE` for a pcap file with `-` for
standard input, `-f EXPR` for the filter and `-c N` to stop after N
messages. A file is read with no filter, since the filter is tcpdump's.

**Two keys differ from ospfv2's, and both follow from BGP being a byte
stream.** OSPF is one packet per datagram, so there a frame's octets and
a packet's octets are the same thing. BGP is not, so:

* **`unit` is `message`.** A `packet` line is one BGP message, `hex` is
  that message's own octets, `length` is their count, and every offset in
  `fields` is from the message's first octet. A consumer that read `hex`
  as a frame would be wrong about every offset, so the header says which
  it is rather than leaving it to be found out.
* **`flow` is the direction**, as `src:port > dst:port`. The frame
  headers are not octets of the message, so they are not byte offset
  fields; a reader that wants the transport gets it here.

**The framing is the work and `bgp/capture/stream.rb` is where it is.**
RFC 4271 section 4.1: 16 octets of Marker, a 2 octet Length that is "the
total length of the message, including the header", and a 1 octet Type. A
message can arrive in two segments and two can share one, so there is one
buffer per direction, appended to in arrival order, and messages are cut
off the front of it. A Length at or above 19 is honoured even when it is
wrong, because that is what the octets say and a receiving speaker reads
them the same way; a Length **below** 19 is the one case framing cannot
continue from, so the stream resynchronises to the next all ones Marker
and the octets skipped on the way are emitted rather than dropped.

**It is not a TCP stack and must not become one.** Each direction is read
in arrival order. A retransmission is trimmed by sequence number, because
that one artifact is common and cheap to spot. Reordered segments are
not: that needs held segments, timers and a reassembly queue, which is a
TCP implementation. A forward gap in the sequence number is a capture that
dropped a frame, and the octets that did arrive are appended rather than
the rest of the session lost.

**Nothing verifies a checksum, and the reason is worth recording** because
the obvious thing is to verify TCP's. A message is reassembled from
segments, so there is no single checksum over its octets; and a capture
taken on a host with checksum offload carries a wrong or zero TCP
checksum on every frame it sent, so verifying it would fill an ordinary
lab capture with false errors. RFC 4271 gives a message no checksum of
its own. The `check` key of ospfv2's field shape is carried and unused.

**Three kinds of entry land in the one `errors` list**, and the wording is
what tells them apart, since the envelope has one channel: a finding from
`validation.rb` says the sender got something wrong, and a decoder that
raised or an `Attr::Gap` says bgp4r could not read it. Conventions keep
those apart inside the library and a capture that called bgp4r's own
coverage a protocol error would give a confident wrong verdict about a
correct router.

**routescope runs the capture in its own container** with
`--network container:NAME`, and the image is
`ROUTESCOPE_CAPTURE_IMAGE`, default `ospfv2:latest`, which dissects IP
protocol 89 only. A BGP capture has to run the bgp4r image. That is a
routescope change and it is in `docs/routescope-labs.md`.

The `capture` stage of the Dockerfile is the image for it: its entrypoint
is the `bgp4r` command, so `IMAGE capture -i IFACE` works as routescope
writes it, and it adds `tcpdump`. **That stage has not been built**, since
no Docker daemon was reachable where it was written, and it is the only
part of this work nothing has run.

# What is not here

**No policy language.** Import and export take a Ruby block, which is
the recorded decision, so a daemon's configuration cannot express a route
map. A lab that needs one uses FRR for that node.

**No IGP.** The daemon does not resolve a BGP next hop recursively, so
the next hop reaches the kernel as it arrived and the kernel decides
whether it can be reached. Said in `bgp/rib/ip_route.rb` too, because a
reader will come looking.

**No ECMP and no multipath.** The Loc-RIB holds one best route per
prefix. Reading the whole candidate set into a FIB is its own piece of
work.

**No new address family in a RIB.** `BGP::Rib::Route` keys on the prefix
and the Path Identifier, and a flow spec rule or an EVPN route is not a
prefix. The daemon holds IPv4 and IPv6 unicast; every other family bgp4r
speaks is on the wire only. That is the recorded decision and the lab
labels say `bgp`, not the family.
