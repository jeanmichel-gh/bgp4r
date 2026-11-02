# bgp4rd and bgp4r-sim

Two programs built on the bgp4r library: a BGP daemon and a route
injector. Both ship in the gem and in the image, both run standalone, and
routescope drives them through the same APIs a person uses.

This document owns the programs: what they do, what they need, their
configuration, their command lines and the JSON they answer with.
`docs/routescope-labs.md` owns the integration: the drivers, the
inspector tables, the map and the labs. Neither repeats the other.

**Status: three commands of four built, and `bgp4rd` answers everything
but `config.*`.** `bgp4r`, the umbrella, has `capture` and `version`, in
`exe/bgp4r` over `bgp/capture/`, so the Capture section at the end of
this document is no longer a design. **`bgp4rd` and `bgp4r-cli` exist**,
in `exe/` over `bgp/daemon/`: the process, the configuration file, the
control socket, the request envelope, every `show.` method, the event
stream, and the `peer.` and `route.` methods that change something. The
only design left in the method table is **`config.*`**, the candidate
configuration, which is its own piece of work and is **not stubbed**,
because an unknown method naming the ones that exist reads better than a
method that answers nothing. `bgp4r-sim` does not exist and is not
declared in the gemspec, for the same reason.

What exists under all of it is the
library under them, which is most of the work: `bgp/neighbor/` for the
FSM and the session, `bgp/rib/` for the Adj-RIB-In, the decision process,
the Loc-RIB, the export rules, the UPDATE builder, MRAI pacing and the
FIB adapter, `bgp/rib/view.rb` for that state as plain data,
`bgp/events.rb` for the event stream, `bgp/misc/route_generator.rb` for
the generator, and `BGP::Fault::CATALOG` for the faults. **The session
and configuration machinery `lab/speaker.rb` held is in the library
now**, as `bgp/daemon/speaker.rb`, and both programs use it: that file's
header has the decision and the two options it rejected.

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
| `bgp4rd` | the daemon | built, with every API method but `config.*` |
| `bgp4r-cli` | its client, over the socket | built |
| `bgp4r` | the umbrella: `sim`, `routegen`, `capture`, `lab new`, `version` | built, with `capture` and `version` |
| `bgp4r-sim` | an alias for `bgp4r sim`, so a container command reads plainly | a design |

The gemspec declares `bgp4r`, `bgp4rd` and `bgp4r-cli`. A subcommand or a
method that does not exist is named in the usage, or in the refusal, as
not yet implemented, so a person asking for one gets the list rather
than a backtrace.

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
not defeat it: `show.routes` and `show.rib` are paged, and no endpoint
builds a million-element array in memory. The page envelope is below.

## Where it is

```
bgp/daemon.rb            requires the rest; not loaded by bgp4r.rb
bgp/daemon/speaker.rb    the sessions, the configuration, the recording,
                         shared with lab/speaker.rb; its header has the
                         decision and the two options it rejected
bgp/daemon/views.rb      what the API answers, as plain data: it merges
                         bgp/rib/view.rb with the session facts a Table
                         has none of
bgp/daemon/control.rb    what it can be told to do: the peer. and route.
                         methods. A file of its own because views.rb says
                         nothing in it validates or decides
bgp/daemon/log_ring.rb   the last lines logged, so show.log can answer
                         them. Its header has the decision and the three
                         things it rejected
bgp/daemon/api.rb        the socket server and the method registry
bgp/daemon/client.rb     the other half of the socket
bgp/daemon/cli.rb        bgp4r-cli, the two forms
bgp/daemon/server.rb     bgp4rd itself
exe/bgp4rd exe/bgp4r-cli
```

One test file each under `test/unit/daemon/`, and
`test/functional/daemon_test.rb` over the real socket, which is the only
test that can say the two halves of a line agree: every unit test on the
server side reads a request a test wrote and every one on the client
side reads an answer a fake wrote. That is the argument
`test/functional/flow_spec_test.rb` makes for the four NLRI wiring
sites, one layer up.

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

**`originate`'s `med: 10` above does not reach an external peer**, and
the example is kept with the caveat rather than changed, because the key
is right about where it does reach. `Export` deletes MULTI_EXIT_DISC
toward every external peer alike (RFC 4271 section 5.1.4), so a MED set
here reaches the Loc-RIB, the decision process, `show.routes`,
`show.rib` and every internal peer, and is dropped on the way out to an
external one. Setting one toward an external peer is the export policy
block's business and `Export`'s own comment says so. Measured in #231,
where the first lab test asserted the opposite before the library
corrected it, and `lab/README.md` carries the same caveat.

**A table is always on, which `lab/speaker.rb` differs from.** `rib`
defaults to true here, because a daemon is a router by definition and
`show.routes` has to answer; in the lab speaker a table has to be asked
for, or every topology written before #231 would start deciding routes.
A file saying `rib: false` turns it off deliberately, and then the two
RIB views answer an empty page rather than failing.

## The command line

```
bgp4rd -f FILE [--socket PATH] [--state FILE] [--log FILE] [-d] [-v] [-h]
```

`-d` logs at debug. `--log -` is standard output, which is what a
container wants, and is the default. `--state FILE` wins over
`state_file` in the configuration.

**The socket path, which both programs work out the same way** so that
neither has to be told, in `BGP::Daemon::Client.default_socket`:
`$BGP4R_SOCKET` if it is set, else the first of `/run/bgp4r`,
`$XDG_RUNTIME_DIR/bgp4r` and `$TMPDIR/bgp4r` whose parent this process
can write, with `/run/bgp4r/bgp4rd.sock` when none of them is, since a
path that cannot be created still names the place to look. The
fallbacks are the recorded requirement that there is no root in the
ordinary case: `/run` needs root, so an unprivileged standalone run
works with no arguments beyond the file.

**`SIGHUP` is not a reload.** It logs that reloading is not implemented
yet and changes nothing, because `config.*` is a later piece of work and
a signal that silently did nothing would read as a reload that worked.
`INT` and `TERM` stop.

```
bgp4r-cli [--socket PATH] [--style NAME] [--pretty] -c 'COMMAND' | METHOD [JSON]
```

Two forms on purpose. `-c` takes an operator command and prints text, so
a person types what they would type at a router:

```sh
# in the VM
bgp4r-cli -c 'show bgp summary'
bgp4r-cli -c 'show bgp 10.255.10.0/24'
bgp4r-cli -c 'clear bgp 10.0.10.1'
```

`clear bgp PEER` is the one operator command that changes something, and
it is there because the line above is an example a person types. The rest
of the write side is the method form: `peer.stop` and `route.originate`
take parameters a one line command grammar would have to invent a syntax
for, and `bgp/daemon/cli.rb` is a string match against a short list and
not a parser.

The method form takes an API method and prints JSON, so a script and a
driver read data rather than parse a table:

```sh
# in the VM
bgp4r-cli show.peers
bgp4r-cli show.rib '{"prefix":"10.255.10.0/24"}'
bgp4r-cli show.adj_in '{"peer":"10.0.10.1"}'
bgp4r-cli peer.stop '{"peer":"10.0.10.1"}'
bgp4r-cli route.originate '{"prefixes":["10.255.0.0/24"],"med":10}'
```

**`events.subscribe` prints every line as it arrives** rather than one
reply and nothing, which is the whole point of a stream, so there is no
`--pretty` for it: a line a reader pipes into `jq` has to be one line.
`Ctrl-C` ends it with `events.unsubscribe`, so the daemon is not left
with a subscriber behind:

```sh
# in the VM
bgp4r-cli events.subscribe
bgp4r-cli events.subscribe '{"kinds":["session"],"since":0}'
```

`show bgp` renders through `bgp/rib/show.rb`, which already prints the
Loc-RIB in three styles: `rib.show`, `rib.show(:junos)` and
`rib.show(:iosxr)`. So `-c 'show bgp'` is IOS style and `--style junos`
switches it. Those are **in the style of** those commands and not copies,
and no test may depend on the text byte for byte.

**The daemon renders it and the client asks for the text, which is one
method beyond the read list and is a departure from ospfv2.**
`ospf-cli` renders every view client side from the data, and copying
that here would mean a second IOS, Junos and IOS-XR renderer in
`bgp/daemon/cli.rb` beside `bgp/rib/show.rb`, which has samples behind
its three styles and a column test per style. Two renderers of one
format is the shape CLAUDE.md records drifting three times, and `Show`
takes a `Rib::Table` which lives in the daemon. So `show.text` exists
and is `rib.show(style, prefix)` and nothing else. A driver still reads
`show.routes` and `show.rib`, which is what `bgp/rib/view.rb` is for; a
console must not parse this text.

**`show bgp summary` is the exception and the client renders it**,
because `Show` has **no** summary form: no vendor sample was found
behind one, so adding a fourth thing to those three styles would be
inventing a format inside the file that says it never does. Its columns
are `bgp/daemon/cli.rb`'s own and no test depends on them.

**`show.text` is not paged**, which is honest rather than tidy: a
vendor's `show bgp` prints the table and this prints the table. A
million prefixes of it is a million prefixes of it, which is what
`| head` is for, and a paged vendor style would be a format no router
has. The paged methods are the five named under the page envelope.

## The control API

A Unix socket, one JSON object per line, request and reply, as ospfd's
is. Dotted method names so a reader can guess them.

### The envelope

**Exact, because routescope's client is one line and a mismatch is a
wrong answer rather than a missing one.** `Drivers::Ospfd::CLIENT`, read
in routescope at commit **`7eabde1`**, opens the socket, writes one line
and reads one line:

```ruby
s.write(JSON.generate(id: 1, method: ARGV[0], params: JSON.parse(ARGV[1])) + "\n")
r = JSON.parse(s.gets || abort("ospfd closed the connection"))
r["error"] ? abort(r["error"]) : puts(JSON.generate(r["result"]))
```

The bgp4r driver will be that line with the paths changed. So:

```
-> {"id":1,"method":"show.status","params":{}}
<- {"id":1,"result":{...}}
<- {"id":1,"error":"unknown method \"show.foo\"; this bgp4rd answers ..."}
```

One JSON object per line in each direction, the reply carrying the id it
was asked with. `params` is optional and anything that is not an object
is read as none, since every read method answers something with none. A
line that is not JSON, a line that is JSON but not an object, and a line
longer than 1 MiB each get an error line of their own with no `id`, and
the daemon goes on answering: **a daemon a console can kill by accident
is worse than one with no API.** The socket is born mode 0660, so access
is by file permission.

### The page envelope

**Five methods are paged and nothing else is**: `show.routes`,
`show.rib`, `show.adj_in`, `show.adj_out` and `show.fib`. A full table is
about a million prefixes and the recorded requirement is that no endpoint
builds a million element array, and an Adj-RIB-In, an Adj-RIB-Out and a
FIB are each as large as the table; a peer list is bounded by the
configuration file and a log by its ring. All five answer one shape, from
one builder in `bgp/daemon/views.rb`, because a second envelope would be
a second set of rules about what `next_offset` nil means:

```json
{ "rows": [ ... ], "total": 7, "offset": 0, "limit": 500, "next_offset": null }
```

`offset` and `limit` are params, `limit` defaults to 500 and is clamped
to 1 to 10000, and the answer carries the limit it used so a caller can
see what it got. **`next_offset` is the cursor and nil is what says the
walk is over**, which is why the envelope exists at all: a caller handed
a short list cannot tell the end of the table from a truncated answer,
and `total` beside it says which. A `prefix` param answers that one
prefix and ignores `offset`, since a caller naming a prefix is asking a
question with one answer.

The whole page is built inside one `Table#synchronize`, so it is a
coherent snapshot rather than N reads of a RIB that is deciding in
between; the lock is reentrant and public for exactly that. What is
still materialised is the sorted key list, because that is where
`View#prefixes` and its three siblings sort, and it is read **inside**
the lock rather than handed in from outside it. The rows, which are the
expensive part, are built for one page only.

**Two of the five carry one key beside the envelope**, which is additive:
`show.adj_out` carries `skipped` and `show.fib` carries `fib`. Both hold
facts that are not keyed by the prefixes the page walks, since a skipped
prefix is by definition not in the Adj-RIB-Out, and `configured` and
`table` are not per prefix at all. A reader keyed on `rows`, `total` and
`next_offset` is unaffected. `skipped` carries its own total and is
capped at the same limit, so a caller can see there is more than it got.

### The methods

| Method | Answers | Status |
|---|---|---|
| `api.info` | version, the method list, the event sequence | built |
| `show.status` | router id, AS, uptime, the peers, a summary | built |
| `show.peers` | one row per configured neighbor | built |
| `show.routes` | the Loc-RIB, one row per prefix, its best path | built |
| `show.rib` | every candidate path per prefix, with the decision | built |
| `show.text` | the Loc-RIB as a router prints it, for `bgp4r-cli -c` | built |
| `show.adj_in` | one peer's Adj-RIB-In, as received | built |
| `show.adj_out` | what was sent to one peer, and what was skipped | built |
| `show.fib` | what the daemon believes is in the kernel table, and what failed | built |
| `show.log` | the last N lines | built |
| `events.subscribe`, `events.unsubscribe` | a stream, one event per line | built |
| `peer.clear`, `peer.stop`, `peer.start` | one session | built |
| `peer.refresh` | a ROUTE-REFRESH, RFC 2918 and the RFC 7313 subtypes | built |
| `route.originate`, `route.withdraw` | our own prefixes | built |
| `config.load`, `config.commit`, `config.compare` | a candidate configuration | a design |

Mutating methods are separate names rather than a flag, so a read-only
client is a list of methods and not a trust decision. The reads go
through `bgp/daemon/views.rb` and the writes through
`bgp/daemon/control.rb`, which is the same split one layer down, and
`bgp/daemon/api.rb`'s own test asserts that every method is named
`show.`, `api.`, `peer.` or `route.` and that the `peer.` and `route.`
ones are exactly the write side.

**`config.*` is not stubbed.** An unknown method answers an error naming
the methods that exist, which is the shape `Events#publish` already
answers an unknown kind with, and is what makes a typo self correcting.
A method answering nothing reads as a feature that is broken.

`api.info` carries `event_seq` beside the stream, and it is still worth
having: it is the number a reader resumes from, so a console can watch
the stream advance and know how far behind it is without subscribing at
all. `api.info`'s `methods` lists the two stream methods with the rest,
because a reader guessing a name wants every name.

**`events.subscribe` is the one method `handle` cannot answer**, since a
stream is many lines and `handle` returns one response. So the two event
methods are registered apart, in `Api::STREAM_METHODS`, and the loop that
owns the connection dispatches them. Asked through `handle` rather than
over a socket, `events.subscribe` is an unknown method, and a unit test
pins that.

### The event stream

**Exact, because routescope's driver reads these lines**, read in its
`Drivers::Ospfd::STREAM` and in ospfv2's own `lib/ospfv2/daemon/api.rb`.
The subscriber writes the ordinary request line and then reads:

```
-> {"id":2,"method":"events.subscribe","params":{"kinds":["session"],"since":120}}
<- {"id":2,"result":{"seq":131,"replayed":11,"kinds":["session"]}}
<- {"event":{"seq":121,"time":"...","level":"info","kind":"session","peer":"10.0.0.2",...}}
<- {"keepalive":"2026-11-02T03:18:31.004Z","seq":131}
-> {"id":3,"method":"events.unsubscribe"}
<- {"id":3,"result":{"unsubscribed":true}}
```

One JSON object per line, the `result` line first, then one `event` line
each as they happen. `since` replays whatever is kept above it and
`replayed` says how many lines came back that way, which is what a
reader resuming from a sequence number needs: a short answer and a quiet
stream are otherwise the same thing, and a synthetic `overflow` event
among the replayed lines is how the answer says something was lost.
`kinds` is echoed, and null when none was named. `seq` is **where the
stream has got to** and not the `since` it was asked with, so it is the
number to resume from next time.

**`peer` is bgp4r's own key where ospfv2 has `interface`**, and a console
maps it onto its own column. Interface is OSPF's word for a circuit, BGP
has none, and a peer is named by its address; naming it `interface` here
would be borrowing another protocol's vocabulary for a thing BGP does
not have. `bgp/events.rb` carries the same note.

**The keepalive line is not decoration.** With nothing written, a reader
cannot tell a quiet lab from a socket that died, which is the
gap-against-quiet failure `bgp/events.rb` already publishes a synthetic
overflow event for one step further on. So after `Api::KEEPALIVE`
seconds of silence one line goes out carrying the time and the sequence
the stream has reached.

**`events.unsubscribe` ends the stream and the connection takes requests
again**, so a console does not need a second socket to stop watching.
The subscription is closed **before** that reply is written, not after,
so a caller that read the reply can go on to assert that the subscriber
is gone; closing it afterwards left a window a test found about one run
in five. Any other request on a streaming connection is refused with a
line of its own and the stream goes on: a request answered mid stream
would interleave with the event lines, and dropping the stream over a
stray line would lose the events the caller asked for.

**One thread per connection and no extra thread.** The connection's own
thread polls three things in turn: a line arriving, an event waiting and
the keepalive deadline, so `MAX_CLIENTS` bounds the subscribers as it
bounds everything else.

### What each new method answers, and the decisions in them

**`show.adj_in` and `show.adj_out` take a required `peer`**, the address
of one configured neighbor, and an unknown one is refused naming the ones
there are. A per peer view has no sensible default: the first configured
neighbor would be an answer about a peer nobody asked about, and every
peer at once is what the page envelope exists to prevent.

**`show.adj_in` is the routes as received**, before import policy, which
is the thing no other view answers: RFC 4271 section 5.1.5 says a
LOCAL_PREF from an external peer must be ignored and `Table#import` drops
it, so the value the peer sent is in these rows and nowhere else. Each
row carries `best`, which says whether that path is the one that won.

**`show.adj_out` is the attributes that went out and not the Loc-RIB's.**
The export rules rewrite AS_PATH, NEXT_HOP, LOCAL_PREF and MED per peer,
so a row here is what the peer was really told. It holds a
`Path_attribute` and not a `Route`, so there is no `from` and no `local`:
a key with a made up value would be worse than no key.

**`show.fib` is what the daemon believes is installed and not what the
kernel holds.** `Fib` records what a command that exited 0 did, so these
rows are bgp4r's own account; `ip route show` is the other question and a
person asks it with `ip`. `fib.configured` is what tells a daemon with no
`fib:` in its configuration from one whose table happens to be empty,
since both answer no rows.

**`show.log` answers text, and that is where it parts company with
ospfv2's `show.log`, which answers its event list.** It can, because in
ospfv2 every non-debug log line is published as an event. bgp4r is not
built that way: `bgp/events.rb` is published from two places, a session's
state changes and a NOTIFICATION, and every other line goes straight to
`Log` from wherever it happened, so the same implementation here would
answer three entries where the log holds three hundred and call that the
log. So a ring of formatted lines sits in front of the real log
destination and sees every line the library writes;
`bgp/daemon/log_ring.rb` has the decision and the two other things it
rejected, which were reading the `--log` file back and publishing each
line as a `:log` event. A program that wants structure reads
`events.subscribe`; the log is for a person.

**`peer.clear` resets a session and `peer.stop` takes the peer
administratively down**, which is the whole difference: without the
shutdown flag the reconnect loop dials again after the retry interval and
a `peer.stop` reads as a session that flapped. A shut down passive peer
refuses the connection the listener hands it, because a passive peer
cannot be stopped by not dialling. Both are idempotent.

**Neither sends a NOTIFICATION, and that is a gap recorded rather than a
choice.** A router answers `clear bgp NEIGHBOR` with Cease and RFC 4486
section 4's Administrative Reset, subcode 4, or Administrative Shutdown,
subcode 2. `Neighbor#stop` closes the output queue and the socket in one
breath, so a NOTIFICATION queued just before it is one the writer thread
may never get on the wire, and a method reporting that it sent one would
be claiming something it cannot verify. Sending it properly means
draining the output before the socket closes, which is a change to
`bgp/io.rb` and its own piece of work.

**`peer.refresh` is RFC 2918 section 3's message with RFC 7313 section
3.2's Message Subtype**, which that RFC redefines out of RFC 2918's
Reserved octet: 0 a normal request, 1 the beginning of a route refresh
operation, 2 its end, 255 Reserved. `subtype` takes those numbers or the
three names `BGP::Route_refresh` answers to, `normal`, `borr` and `eorr`,
and any octet value encodes, so a router can be watched handling one the
RFC does not define. **Nothing checks that the peer advertised capability
2**, which is Conventions rather than an omission: a tool for testing the
protocol has to be able to send a refresh to a speaker that never asked
for one. What is refused is a session that is not Established, because
there is no connection to write to.

**`route.originate` takes the `originate:` block's own keys**, so the
runtime vocabulary is the configuration vocabulary and a prefix
originated here carries the same attributes, built by the same method, as
one originated at start-up. Two of them are deliberately not settable:
AS_PATH starts empty, because RFC 4271 section 5.1.2 wants it empty
toward an internal peer and our AS alone toward an external one, and
NEXT_HOP is a placeholder, because section 5.1.3 makes it ours on each
session. It validates nothing, so an ORIGIN no RFC defines goes in.

**`route.withdraw` answers `not_held` rather than refusing it.**
Withdrawing a route nobody has is not an error, and a caller walking a
list wants to know which ones did nothing. Membership is read before the
withdrawal and not inferred from the change list, which is ambiguous: a
prefix another peer also advertises can be withdrawn by us and leave the
Loc-RIB unchanged, because that peer's route then wins.

**An unknown parameter name is refused by every write method**, naming
what it does take. An ignored body key is a wrong answer and not a
missing one, which is the rule `Speaker#export_options` already applies
to a node file: a typo that silently drops the MED is the worst of both.

## The JSON

`show.status`, which is the shape routescope's `#bgp(container)` wants:

```json
{ "router_id": "10.255.0.1", "as": 65000, "uptime": 412,
  "peers": [
    { "address": "10.0.10.1", "router_id": "10.255.10.1", "remote_as": 65010,
      "state": "established", "description": "inj1", "uptime": 380,
      "received": 4, "sent": 2, "best": 2, "type": "ebgp",
      "flaps": 0, "last_error": null, "updates": 6,
      "capabilities": [ { "name": "As4", "code": 65, "capability": { "as": 65010 } } ] } ],
  "summary": { "established": 1, "peers": 2, "rib": 7, "paths": 9, "originated": 1 } }
```

States are lowercase and are RFC 4271 section 8's: `idle`, `connect`,
`active`, `opensent`, `openconfirm`, `established`. `router_id` on a peer
is nil until the OPEN arrives, which is what lets a map draw a session
that has not come up.

**Measured on 2026-11-02 rather than assumed: every state bgp4r's FSM
reaches is in that list once downcased.** The ones it sets are `:Idle`,
`:Active`, `:OpenSent`, `:OpenConfirm` and `:Established`. It never
enters `:Connect`, going straight to `:Active` when it opens the socket,
and `:OpenRecv` is in `Neighbor`'s `is_*?` helpers and is never set.
That matters because routescope validates against the closed list and
**drops** a value outside it, so a wrong case or a stray name shows as
an empty peer list rather than an error.

**`capabilities` is the structured form and not a list of names**, which
is a correction to the example this document carried. A name like
`as4_byte` is what a script *asks* for, and `Neighbor::CAPABILITIES` maps
six such spellings onto `CAP::As4` alone, so there is no reverse mapping
to answer with. What is here is each capability's class name and its own
`to_hash`, which is what the lab state file already carries and is
strictly more information than a name. #228's entry in `lab/README.md`
has the shape.

**Which keys are whose, because a Table has no session state.** The view
in `bgp/rib/view.rb` answers `address`, `remote_as`, `router_id`,
`type`, `received`, `best` and, in router mode, `sent`. The daemon adds
`state`, `description`, `uptime`, `flaps`, `last_error`, `updates` and
`capabilities`, which come from the sessions, and `uptime` and
`summary.established` of its own.

Two more things the daemon does rather than the view, each because the
view answers a different question:

* **The peer list is every configured neighbor**, where the view lists
  the peers the table has seen. A neighbor that has never come up has no
  Adj-RIB-In and no Adj-RIB-Out, so the view does not list it at all,
  and a peer table that hides the peers that are down hides the
  interesting ones. Such a peer still answers `received`, `sent` and
  `best` as 0, which is the view's own rule that a key with a value is
  an answer: a peer with no session holds no routes.
* **`summary.peers` is the configured count**, for the same reason.

`show.routes`, one row per prefix, inside the page envelope above:

```json
{ "rows": [
    { "prefix": "10.255.10.0/24", "next_hop": "10.0.10.1", "as_path": "65010",
      "origin": "igp", "med": 100, "local_pref": 100, "from": "10.0.10.1",
      "path_id": null, "local": false, "paths": 2, "best": true,
      "decided_by": "med" } ],
  "total": 7, "offset": 0, "limit": 500, "next_offset": null }
```

`show.rib`, which is the daemon's own answer and has no counterpart in
any router's output:

```json
{ "rows": [
    { "prefix": "10.255.10.0/24", "decided_by": "med",
      "paths": [
        { "from": "10.0.10.1", "next_hop": "10.0.10.1", "as_path": "65010",
          "local_pref": 100, "med": 100, "best": true, "usable": true,
          "lost_at": null, "reason": "best path, decided at the med step" },
        { "from": "10.0.11.1", "next_hop": "10.0.11.1", "as_path": "65010",
          "local_pref": 100, "med": 200, "best": false, "usable": true,
          "lost_at": "med",
          "reason": "higher MED from the same neighbouring AS" } ] } ],
  "total": 7, "offset": 0, "limit": 500, "next_offset": null }
```

`Decision::Result` is `Struct.new(:best, :reason, :eliminated)` with
`eliminated` a path to step map, so this is a serialisation and not a new
computation. `reason` is words for a person.

**Both examples above are what the library answers**, measured against
it rather than written from the design. Two things in the shapes this
document first gave were wrong and are corrected in them, both found in
#230:

* The `show.rib` example gave the **best** path `"reason": "med"`, the
  step symbol, where the prose says `reason` is words for a person. The
  view makes every `reason` words and puts the step in `decided_by` on
  the prefix row, which is where `Decision::Result` keeps it: one step
  per prefix rather than one hidden in whichever path won.
* `show.status`'s peer row is mostly a **session** fact, and the split is
  written out above the `show.routes` example.

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

`show.adj_in`, one row per path the peer sent, inside the page envelope:

```json
{ "rows": [
    { "prefix": "10.255.10.0/24", "from": "10.0.10.1", "next_hop": "10.0.10.1",
      "as_path": "65010", "origin": "igp", "local_pref": 120, "med": 100,
      "path_id": null, "local": false, "best": true } ],
  "total": 4, "offset": 0, "limit": 500, "next_offset": null }
```

**That `local_pref` is the point of the view.** An external peer sent it,
so RFC 4271 section 5.1.5 says to ignore it and `Table#import` drops it;
`show.routes` for the same prefix answers null. The Adj-RIB-In is what
the peer sent, so it is here.

`show.adj_out`, one row per prefix and Path Identifier, with `skipped`
beside the page:

```json
{ "rows": [
    { "prefix": "10.255.10.0/24", "path_id": null, "next_hop": "10.0.20.1",
      "as_path": "65000 65010", "origin": "igp", "local_pref": null,
      "med": null, "communities": "65000:1" } ],
  "total": 1, "offset": 0, "limit": 500, "next_offset": null,
  "skipped": { "total": 1,
               "rows": [ { "prefix": "10.255.11.0/24",
                           "reason": "back_to_sender" } ] } }
```

**The three examples above were measured against the library** rather
than written from this design, which is the rule #230 earned when two of
the shapes here turned out wrong. `med` and `local_pref` are null in the
`adj_out` row because MULTI_EXIT_DISC does not cross into another AS (RFC
4271 section 5.1.4) and LOCAL_PREF never goes to an external peer
(section 5.1.5): those two nulls are the export rules showing through,
not missing data.

`show.fib`, with the facts that are not per prefix beside the page:

```json
{ "rows": [ { "prefix": "10.255.10.0/24", "next_hop": "10.0.10.1" } ],
  "total": 1, "offset": 0, "limit": 500, "next_offset": null,
  "fib": { "configured": true, "backend": "ip route, table 100, proto bgp",
           "total": 1,
           "failed": [ { "prefix": "10.255.11.0/24",
                         "error": "Error: Nexthop has invalid gateway." } ],
           "skipped": [] } }
```

`show.log`, the last lines, oldest first:

```json
{ "lines": ["02:13 INFO -- : bgp4rd 0.5.0 up, AS 65000, ..."],
  "kept": 1, "keeps": 2000 }
```

`keeps` 0 says nothing is kept at all, which is a daemon that set up no
logging rather than one whose log is empty.

The write methods, each answering what it did, so a caller can assert on
it rather than reading a view back:

```json
peer.clear    {"peer":"10.0.10.1","cleared":true,"was":"established","state":"idle","shutdown":false}
peer.stop     {"peer":"10.0.10.1","was":"established","state":"idle","shutdown":true}
peer.start    {"peer":"10.0.10.1","state":"idle","shutdown":false,"connect":true}
peer.refresh  {"peer":"10.0.10.1","afi":1,"safi":1,"subtype":0,"sent":true}
route.originate {"originated":["10.255.0.0/24"],"total":1,"changes":1,"rib":7}
route.withdraw  {"withdrawn":["10.255.0.0/24"],"not_held":[],"total":1,"changes":1,"rib":6}
```

`changes` is how many Loc-RIB changes it caused, which is not always the
same as `total`: see `route.withdraw` above.

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
