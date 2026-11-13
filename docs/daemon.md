# bgp4rd and bgp4r-sim

Two programs built on the bgp4r library: a BGP daemon and a route
injector. Both ship in the gem and in the image, both run standalone, and
routescope drives them through the same APIs a person uses.

This document owns the programs: what they do, what they need, their
configuration, their command lines and the JSON they answer with.
`docs/routescope-labs.md` owns the integration: the drivers, the
inspector tables, the map and the labs. Neither repeats the other.

**Status: all four commands built, every subcommand with them, and
nothing in the method table is a design any more.** `bgp4r`, the
umbrella, has `capture`, `sim`, `routegen`, `lab new` and `version`, in
`exe/bgp4r` over `bgp/capture/` and
`bgp/sim/`, so the Capture section at the end of this document is no
longer a design. **`bgp4rd` and `bgp4r-cli` exist**, in `exe/` over
`bgp/daemon/`: the process, the configuration file, the control socket,
the request envelope, every `show.` method, the event stream, the
`peer.` and `route.` methods that change something, and **the candidate
configuration**, in `bgp/daemon/config.rb` and
`bgp/daemon/candidate.rb`. **`bgp4r-sim` exists too**, in `exe/` over
`bgp/sim/`, with every read and every action of its HTTP API and with
routegen folded into it three ways, so everything from the
`bgp4r-sim, the injector` heading on is built rather than designed.

**`config.*` was the last design and the table named three of its
methods where a console calls nine.** The nine were read in
routescope's `Drivers::Ospfd` at commit `7eabde1`, the same commit the
request envelope and the page envelope below were read at, and they are
corrected in the method table and written out under "The candidate
configuration". `config.load` is a tenth that no driver calls and a
person does.

**`lab new` was the umbrella's one unimplemented subcommand and it is
built**, in `BGP::Capture::CLI#lab`, with its own section below. So
nothing in this document describes something that does not run.

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
| `bgp4rd` | the daemon | built, with every API method |
| `bgp4r-cli` | its client, over the socket | built |
| `bgp4r` | the umbrella: `sim`, `routegen`, `capture`, `lab new`, `version`, and `console` from docs/console.md | built, all six |
| `bgp4r-sim` | an alias for `bgp4r sim`, so a container command reads plainly | built |

The gemspec declares all four. A subcommand or a method that does not
exist is named in the usage, or in the refusal, as not yet implemented,
so a person asking for one gets the list rather than a backtrace.
**Nothing is left**, so the umbrella's usage names no missing
subcommand; the rule stands for whatever is added next.

```sh
# in the VM
gem install bgp4r
bgp4rd -f /etc/bgp4r/bgp4rd.yml &
bgp4r-cli -c 'show bgp summary'
```

```sh
# in the VM
docker build --target speaker -t bgp4r-speaker .
docker run --rm -v $PWD/sim.yml:/lab/sim.yml bgp4r-speaker \
  exe/bgp4r-sim /lab/sim.yml --api 0.0.0.0:8080
```

The `speaker` stage of the Dockerfile runs any program in the tree, so
it is the injector and the daemon as well and neither has a stage of its
own: a stage whose only difference is a default command is a stage that
can go stale. The Dockerfile says so where that stage is. **No Docker
daemon was reachable where this was written**, so nothing here has been
run in a container; the capture stage carries the same caveat.

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
   drop. SIGHUP and `config.commit` are the same code path, and the
   table under "The candidate configuration" says which keys a reload
   can apply, which it applies by bouncing one session, and which it
   refuses.

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
bgp/daemon/config.rb     the configuration as set lines, one per leaf:
                         the text show.configuration, config.replace,
                         config.load and config.compare speak. Its
                         header has the decision and the one it rejected
bgp/daemon/candidate.rb  the candidate configuration: what a commit can
                         change live, what it changes by bouncing a
                         session, and what it refuses. A file of its own
                         rather than more methods on control.rb because
                         it holds state and that one does not
bgp/daemon/log_ring.rb   the last lines logged, so show.log can answer
                         them. Its header has the decision and the three
                         things it rejected
bgp/daemon/api.rb        the socket server and the method registry
bgp/daemon/client.rb     the other half of the socket
bgp/daemon/cli.rb        bgp4r-cli, the two forms
bgp/daemon/shell.rb      its operator commands and its prompt
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
  - address: 10.0.30.1
    as: 65000
    route_reflector_client: true   # RFC 4456 section 6; see below

originate:
  - prefixes: [10.255.0.0/24]
    med: 10
    communities: ['65000:1']
    extended_communities: ['route_target:65000:7']   # KIND:VALUE..., KIND a to_hash key
    large_communities: ['65000:1:1']

export:
  next_hops: { 1: 10.0.20.1 }      # ours, per AFI, toward external peers
  route_reflector: false
  clients: []                      # RFC 4456 section 6, when a reflector
  cluster_id: 7.7.7.7              # RFC 4456 section 7, default router_id
  mrai: { ebgp: 0, ibgp: 0 }       # 0 is off, which stays the default

fib:
  table: 100                       # absent means compute and do not install

link_state:                        # a BGP-LS Producer; see below
  isisd: /run/isis4r/isisd.sock    # the default source
  levels: [1]                      # IS-IS levels, the default; Protocol-ID 1 and 2
  # or, for OSPFv2, in place of isisd and levels:
  # ospfd: /run/ospfv2/ospfd.sock  # Protocol-ID 3
  # areas: [0.0.0.0]               # dotted quads or numbers; the default
  # external: true                 # type 5 LSAs too; the default
  identifier: 0                    # RFC 9552 section 5.2, the default
  peers: [10.0.10.1]               # who gets BGP-LS; default none
  unreachable: withdraw            # or keep; the default is withdraw

mark:                              # added to routes made by hand; see route.originate
  large_communities: ['65000:1:1']
```

Seven notes on it.

`capabilities` takes `add_path` as `(send_recv, afi, safi)`, matching
`CAP::Add_path#add`, so `[3, 1, 1]` is IPv4 unicast both ways. Three
comments in the repository gave `[1, 1, 3]` while meaning that, which is
SAFI 3, NSAP, receive only.

A neighbor block takes only the keys it is read for, listed in
`Peer::KEYS`, and any other key is refused at start-up and in a commit,
naming it. A typo used to be ignored, so `hold_tme: 30` ran the session
with the default hold time and said nothing.

`route_reflector_client: true` on a neighbor makes it a client of this
reflector, as IOS's `neighbor X route-reflector-client` does. It turns
reflection on by itself, with no `export` block needed, and the flagged
neighbors become `Export`'s client list. Four things are refused:

* a value that is not true or false;
* the flag on an external neighbor, since RFC 4456 section 6 makes a
  client an internal peer;
* the flag beside `export.clients`, even `clients: []`, since the two
  lists could disagree;
* the flag beside `export.route_reflector: false`.

Like every `export` key, it cannot change in a commit, because a
replacement Router starts with an empty Adj-RIB-Out per peer.
`bgp4r-sim` refuses it, since an injector holds no Loc-RIB.

`cluster_id` and `default_local_pref` are written under `export` and
read by the decision process too. The first is the ID a reflector
prepends to a CLUSTER_LIST and the one whose presence makes a route
unusable here, RFC 4456 section 8. The second is what an internal peer
is sent for a route with no LOCAL_PREF and what that route is ranked
at. Each is one value with two readers, so `Speaker` hands both to the
`Rib::Table` it builds. It did not before 2026-11-05, and a reflector
with its own cluster ID loop checked its router ID instead.

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

**`link_state` makes this bgp4rd a BGP-LS Producer** (RFC 9552,
AFI 16388 / SAFI 71). It reads isisd's `show.topology` on the `isisd`
socket after each `spf` event of a configured level, or ospfd's on the
`ospfd` socket after each `topology` event of a configured area or of
the AS scope, and sends Node, Link and Prefix NLRIs to each address in
`peers`. A block names `isisd` or `ospfd`, not both: two IGP domains on
one box are two bgp4rd. With neither, it is isisd at its default path.
`areas` and `external` go with `ospfd` only, `levels` with `isisd`
only. Each of those must be
a configured neighbor, and its session must negotiate 16388/71, which a
neighbor asks for with `capabilities: [as4_byte, {mbgp: bgp_ls}]`.
Other sessions get nothing. A node the IGP marks unreachable is withdrawn,
unless `unreachable: keep`. `unreachable` is the one `link_state` key that
changes while bgp4rd runs: a commit of `set link_state unreachable keep`,
a SIGHUP, or `link_state.unreachable '{"unreachable":"keep"}'`, which is
that commit of that one key. The Producer rebuilds at once from the
topology it last read, so switching back to `withdraw` withdraws at once
and not at the next SPF. Every other `link_state` key is refused in a
commit, since the Producer is built once. If the socket closes, it tries again every
5 seconds. Any other key is refused at start-up. Every bgp4rd also keeps
the BGP-LS routes it receives, in a table of their own outside the RIB.
`show.link_state` lists both. `docs/bgp-ls.md` section 12 has what is
sent, and `docs/bgp-ls-howto.md` explains why.

**A table is always on, which `lab/speaker.rb` differs from.** `rib`
defaults to true here, because a daemon is a router by definition and
`show.routes` has to answer; in the lab speaker a table has to be asked
for, or every topology written before #231 would start deciding routes.
A file saying `rib: false` turns it off deliberately, and then the two
RIB views answer an empty page rather than failing.

## The command line

```
bgp4rd -f FILE [--socket PATH] [--state FILE] [--log FILE] [--interact] [-d] [-v] [-h]
```

`--interact` opens an irb prompt on the daemon, whose verbs are the
control socket's methods; the socket still answers beside it, and `exit`
sends Cease 6/2 to each peer and stops the daemon. docs/console.md
section 10 is the guide.

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

**`SIGHUP` is a reload**, through `config.replace` and `config.commit`;
see the SIGHUP heading under "The candidate configuration" for what it
can and cannot apply. `INT` and `TERM` stop.

```
bgp4r-cli [--socket PATH] [--style NAME] [--pretty] -c 'COMMAND' | COMMAND... | METHOD [JSON | KEY=VALUE...]
```

With no command and no method, on a terminal, it opens a prompt where
the operator commands are typed without quotes, shortened, and listed
with `?` or `help`. docs/bgp4r-cli.md says how to use it, and
docs/design/bgp4r-cli-shell.md is the design.

Two forms on purpose. `-c` takes an operator command and prints text, so
a person types what they would type at a router:

```sh
# in the VM
bgp4r-cli -c 'show bgp summary'
bgp4r-cli -c 'show bgp 10.255.10.0/24'
bgp4r-cli -c 'show fib'
bgp4r-cli -c 'show link-state'
bgp4r-cli -c 'show configuration'
bgp4r-cli -c 'show configuration candidate'
bgp4r-cli -c 'clear bgp 10.0.10.1'
```

`show configuration` asks for the **set lines**, where the method form
with no `format` answers YAML: a person typing an operator command wants
the form a driver diffs, one leaf per line, and `bgp4r-cli
show.configuration` gives them the file.

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
are `bgp/daemon/cli.rb`'s own and no test depends on them. `show fib`
is rendered there too, for the same reason: no style in `Show` has a
forwarding table, and its layout is bgp4r's own. `show link-state` is
rendered there too: BGP-LS is not in `Show`, and its layout is bgp4r's
own.

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
`show.adj_out` carries a third, `hand`, in the same shape and **only
when there is something in it**: what was sent to that peer by hand,
below.

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
| `show.link_state` | BGP-LS routes: sent as a Producer, and received per peer | built |
| `show.log` | the last N lines | built |
| `events.subscribe`, `events.unsubscribe` | a stream, one event per line | built |
| `peer.clear`, `peer.stop`, `peer.start` | one session | built |
| `peer.refresh` | a ROUTE-REFRESH, RFC 2918 and the RFC 7313 subtypes | built |
| `peer.specimen`, `peer.fault`, `peer.replay` | one message sent by hand, listed and never written into the Adj-RIB-Out | built |
| `peer.resend` | the daemon's own answer for each prefix a peer was sent by hand | built |
| `route.originate`, `route.withdraw` | our own prefixes | built |
| `link_state.unreachable` | the BGP-LS Producer's `unreachable`, `keep` or `withdraw`, as one commit | built |
| `show.configuration` | the running configuration, or the candidate | built |
| `config.changed` | whether the candidate differs, as a **boolean** | built |
| `config.compare` | what the candidate changes, as **lines** | built |
| `config.replace` | the candidate, from lines | built |
| `config.load` | lines on top of the candidate | built |
| `config.commit` | check it, or do it | built |
| `config.discard` | the candidate back to the running one | built |
| `config.history` | the commits, newest first | built |
| `config.rollback` | an older configuration as the candidate | built |

**This table said `config.load`, `config.commit` and `config.compare`
and that was wrong twice over.** It named three methods where
routescope's Config pane calls **nine**, and one of the three it named,
`config.load`, is the one the driver never calls. Read in
`Drivers::Ospfd` at `7eabde1`: `running_config` calls
`show.configuration` with `format: 'set'`, again with `candidate: true`
when the candidate differs, and `config.changed`; `load_candidate`
calls `config.replace`; `candidate` calls `config.compare` and
`config.commit` with `check: true`; `commit_candidate` calls
`config.commit` with `comment:`; `discard_candidate` calls
`config.discard`; `rollbacks` calls `config.history`; and
`load_rollback` calls `config.rollback`. **A driver needs all nine, not
the subset the pane's main view uses**: `Config#with_candidate` in
routescope refuses the whole pane unless the driver answers `candidate?`
true, and `discard_candidate`, `rollbacks` and `load_rollback` are each
a route in its `app.rb` and a button in `ConfigPanel.tsx`.

**`config.load` is kept even though no driver calls it**, which is a
decision rather than an oversight. ospfv2 has it, and it is the method
that makes the API usable by hand: changing one key through
`config.replace` means sending the whole configuration back, and this
document's one principle is that every action a console takes must be a
command a person can type. `config.load` is that command.

Mutating methods are separate names rather than a flag, so a read-only
client is a list of methods and not a trust decision. The reads go
through `bgp/daemon/views.rb` and the writes through
`bgp/daemon/control.rb`, which is the same split one layer down, and
`bgp/daemon/api.rb`'s own test asserts that every method is named
`show.`, `api.`, `peer.` or `route.` and that the `peer.` and `route.`
ones are exactly the write side.

An unknown method answers an error naming the methods that exist, which
is the shape `Events#publish` already answers an unknown kind with, and
is what makes a typo self correcting. A method answering nothing reads
as a feature that is broken, which is why `config.*` was left out of the
registry entirely while it was a design rather than stubbed.

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

**`show.link_state` answers BGP-LS routes, one row per route, in the
page envelope.** First the routes this daemon sent as a Producer, with
`peer` null, then the routes it received, per peer. The row is the same
on both sides, so a collector and its Producer answer the same rows
apart from `peer` and `since`. It takes `offset` and `limit` and no
`prefix`, since a BGP-LS route is not keyed by one. The table is
outside the RIB, so this view does not take the RIB's lock.
`docs/bgp-ls.md` section 12 has the row.

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

**`peer.specimen`, `peer.fault` and `peer.replay` send by hand**, and
`bgp4rd --interact` adds `ship` for a message object. A `BGP::Specimen`
by `name`, a `BGP::Fault` by `case`, octets by `hex`, each with an
optional `peer`, and the first two with `prefix` or `prefixes` and
`next_hop`. They build what `bgp4r-sim` builds for the same name, so
one name is one set of octets for both programs. **The Adj-RIB-Out is
never written for them**, because after one the daemon cannot know what
the peer holds; each prefix they touch is listed under `hand` in
`show.adj_out` and counted as `hand` on the peer's `show.peers` row,
both present only when the list is not empty. A row clears when the
daemon sends the prefix the normal way, when the session ends, or on
`peer.resend`, which sends the route where export has one and a
withdrawal where it does not, whatever the Adj-RIB-Out says. **The
configuration's `mark` goes on a specimen and never on a fault or a
replay**, since those are the message under test. docs/console.md
section 10 has the decision and bgp/daemon/hand.rb the list.

**`route.originate` takes the `originate:` block's own keys**, so the
runtime vocabulary is the configuration vocabulary and a prefix
originated here carries the same attributes, built by the same method, as
one originated at start-up. Two of them are deliberately not settable:
AS_PATH starts empty, because RFC 4271 section 5.1.2 wants it empty
toward an internal peer and our AS alone toward an external one, and
NEXT_HOP is a placeholder, because section 5.1.3 makes it ours on each
session. It validates nothing, so an ORIGIN no RFC defines goes in.

**It adds the configuration's `mark`**, a mapping of the three community
keys, to each route it makes, and `marked` in the answer says whether it
did. A route made through this method or at the `bgp4rd --interact`
prompt is one a person made by hand, and the mark lets a router that
receives it act on that. An `originate:` block in the file is not
marked. The mark is read from the running configuration on each call, so
it is a live key in a commit. A key it does not read, or a community it
cannot parse, is refused when the file is read and by a commit, naming
`mark`. docs/console.md section 10 has the decision.

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

## The candidate configuration

A second copy of the running configuration that can be edited, compared,
checked, committed, discarded and rolled back. `bgp/daemon/candidate.rb`
holds it and `bgp/daemon/config.rb` is the text it speaks.

```sh
# in the VM
bgp4r-cli -c 'show configuration'
bgp4r-cli config.load '{"lines":["set neighbors 10.0.10.1 hold_time 60"]}'
bgp4r-cli config.compare
bgp4r-cli config.commit '{"check":true}'
bgp4r-cli config.commit '{"comment":"hold time"}'
```

### Set lines, and why not YAML

bgp4rd's configuration is a YAML file and this is a second rendering of
it, one line per leaf, which is a cost worth stating a reason for.
Answering YAML text would satisfy the driver, which only normalizes and
diffs text, and it was rejected on three grounds:

* **A `config.compare` line has to mean something on its own**, because
  the pane lists those lines as the change list. `set neighbors
  10.0.10.1 hold_time 60` names its whole leaf path. The YAML diff of
  the same edit is `- hold_time: 30` and `+ hold_time: 60`, which does
  not say which neighbor, and a list of those cannot tell two neighbors
  apart.
* **`config.replace` takes lines, and YAML's lines are not
  independent.** A set line carries its own path, so their order does not
  matter and each is complete. A YAML line means what its indentation
  and the lines above it make it mean, so a caller that reflowed the file
  gets a different tree or a parse error.
* **A commit has to classify what changed**, and that is per leaf path,
  which the set-line comparison already yields.

The fourth argument is the one a reader expects and it is weaker in
fact: `Drivers::Ospfd::SECRETS` is
`/\b(key|simple-password)(\s+)(...)/`, which wants whitespace after the
key name, so it matches `set ... key hunter2` and does **not** match
YAML's `key: hunter2`, where the colon is where the `\s+` has to be. A
driver copying that regexp would leak a YAML secret. **It leaks nothing
today**, measured rather than assumed: no key of this configuration is a
secret, so nothing is masked in either rendering.

The grammar, with the four kinds of list a YAML file needs a key for,
and the two empty tokens, is in `bgp/daemon/config.rb`'s own header.
`{}` and `[]` are both there, and the second is not symmetry: `clients:
[]` and no `clients` key mean **opposite** things, measured in
`bgp/rib/export.rb`, where `Export#clients?` answers true for every
internal peer given no list and false given an empty one.

### What a commit does to a running speaker

A key is one of three things, and the commit says which rather than
hoping:

| Effect | Keys | What a commit does |
|---|---|---|
| live | `log_level`, `originate`, `mark`, `link_state unreachable`, a neighbor's `description` | applies it, and nothing on the wire stops |
| bounce | a neighbor's `as`, `hold_time`, `capabilities`, `connect`, `port`, `retry` | ends that session and lets it come back |
| bounce all | `announce` | ends every session and lets them come back |
| restart | everything else | **refuses the commit**, naming the key |

**A restart-class change is refused, and that is the honest answer of
three possible ones.** A commit could apply `router_id`, which it
cannot; record it in the running configuration and warn, which makes
`show.configuration` describe a speaker that does not exist; or refuse.
The second is the one to avoid, because this document's own rule is that
a commit must not claim to apply a key it ignored, and a running
configuration that disagrees with the running speaker is that claim in
the one place a reader goes to check it. So it is refused, in `errors`,
with the mechanism in the message, and the running configuration goes on
being true.

**Each group is refused for a measured reason**, and the reasons worth
reading are `export`'s and `fib`'s, because both moved once already.
They used to be refused together, because `Table#on_change` appended to
a list of listeners and there was no way to take one off, so a stopped
`Router` went on advertising. That is fixed: `Table#off_change` exists
and `Router#stop` and `FibInstaller#stop` use it. **The two reasons now
differ.** `fib` is held up by the daemon alone: `@fib` is set in
`Speaker#initialize` and `install_fib` runs once in
`Speaker#start_rib`, and `Speaker#reconfigure` reads neither, so there
is nothing to apply the change to. The library would take it, because
stopping a `FibInstaller` flushes and a new one installs the whole
Loc-RIB. `export` is held up by the library as well, and by something
sharper: **a replacement `Router` starts with empty Adj-RIB-Outs**, so a
route the new rules refuse is never withdrawn from a peer that holds it,
since `Router#item_for` only withdraws a prefix its own Adj-RIB-Out has.
Measured by replacing a reflecting `Router` with a non-reflecting one:
the new one records `:ibgp_to_ibgp` in `skipped`, sends no withdrawal,
and the peer keeps the route. A neighbor added or taken away
is refused because `@peers` is built in `Speaker#initialize` and read
from every session thread with no lock, and whether anything listens for
a passive peer is decided once in `Speaker#start`. A neighbor's `record`
is refused because its `Recorder` counts `established_count` and `flaps`
**across** sessions, so a bounce deliberately leaves those alone and
replacing it would reset them.

**`warnings` is where a bounce is reported**, because a bounce is
something that happened to the session rather than something that went
wrong: `"the session with 10.0.10.1 was bounced to pick up hold_time"`.
A `check` says it in the future tense, so a person sees what a commit
would cost before paying it, and a passive peer is named as one, since
`config.commit` can end its session and not bring it back: only the peer
can dial.

**It refuses a configuration it cannot act on, and nothing else.**
Nothing here validates what goes on the wire, per Conventions. What
`config.commit` does refuse, besides a restart-class change, is a
neighbor a session cannot be built from at all, and that check is **a
dry run of `Peer#new_neighbor`** rather than a list of rules: the method
a bounce is about to call is the one that says whether it can be called,
so a bad capability name comes back with `Neighbor#capability`'s own
message, which names every name there is. It opens no socket.

### SIGHUP

**SIGHUP is a reload**, and it is `config.replace` followed by
`config.commit` so that it cannot drift from the methods a console
calls. A key that needs a restart is refused by the commit, so the
reason goes in the log and the running configuration stays true; that is
function 9 above, "reload its configuration without dropping sessions it
need not drop", and the sessions it need not drop are the ones whose keys
did not change.

**A reload builds its configuration the same way start-up does**,
through `Server.with_defaults`. Without that the reloaded file lacks
`rib: true`, which `with_defaults` adds, so every reload of an ordinary
file compared as `delete rib` and was refused as restart class. Found by
the test rather than by reading.

## The JSON

`show.status`, which is the shape routescope's `#bgp(container)` wants:

```json
{ "router_id": "10.255.0.1", "as": 65000, "route_reflector": false,
  "cluster_id": null, "uptime": 412,
  "peers": [
    { "address": "10.0.10.1", "router_id": "10.255.10.1", "remote_as": 65010,
      "state": "established", "description": "inj1", "uptime": 380,
      "received": 4, "sent": 2, "best": 2, "type": "ebgp",
      "flaps": 0, "inq": 0, "outq": 0, "held": 0,
      "last_error": null, "updates": 6,
      "capabilities": [ { "name": "As4", "code": 65, "capability": { "as": 65010 } } ] } ],
  "summary": { "established": 1, "peers": 2, "rib": 7, "paths": 9, "originated": 1 } }
```

States are lowercase and are RFC 4271 section 8's: `idle`, `connect`,
`active`, `opensent`, `openconfirm`, `established`. `router_id` on a peer
is nil until the OPEN arrives, which is what lets a map draw a session
that has not come up.

**A route reflector says so**, RFC 4456. `route_reflector` is true
when the export rules reflect, from `export.route_reflector` or a
neighbor's `route_reflector_client` flag, and `cluster_id` is then the
ID it prepends to a CLUSTER_LIST: `export.cluster_id`, or the router ID
by default. Both are false and null otherwise. A peer row gains
`route_reflector_client` only on a reflector, true or false, from
`Export#client?`, so it says what the export rules decide. With
`route_reflector: true` and no client list that is every internal
peer, which is the single cluster case of section 6.

**Every path row of every view carries `originator_id` and
`cluster_list`**, RFC 4456 section 8, as it carries the three community
lists: null and an empty list for a route that was never reflected. In
`show.adj_out` they are what the peer was sent, so a reflector's own
ORIGINATOR_ID and cluster ID show there and not in the Loc-RIB.

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

**`inq`, `outq` and `held` say whether this speaker is done with its
work**, which is what routescope's `bgp_drained` asks. BGP does not
converge the way a link state protocol does: what matters for one
speaker is that its sessions are up, it has sent what it has to send,
and it has processed what it received. So:

* `inq` is what was received and is not in the table yet: events the
  session has not dispatched, plus its UPDATEs the RIB worker has not
  applied (`Rib::PeerFeed#unapplied`).
* `outq` is what is not on the wire yet: the session's output queue,
  plus the RIB worker's items that send something
  (`Rib::PeerFeed#unsent`). Those belong to no one peer, since one
  Loc-RIB change goes to every peer, so they count against each.
* `held` is what the MinRouteAdvertisementInterval holds back for this
  peer (RFC 4271 section 9.2.1.1). It still has to go, so a speaker
  holding one is not done. nil with no router.

nil means not reported, never 0: a session with no Neighbor yet has no
queues to read.

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
      "med": null, "communities": ["65000:1"],
      "extended_communities": [], "large_communities": [],
      "originator_id": null, "cluster_list": [] } ],
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

`skipped` names a prefix the FIB chose not to install, with a reason.
`originated` is a prefix this daemon originates: its NEXT_HOP is the
router ID until the export step replaces it per session, so the kernel's
own route for it, connected or static, is what forwards to it.
`no_next_hop` is a route with no NEXT_HOP, which a live table never
decides as best.

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
route.originate {"originated":["10.255.0.0/24"],"total":1,"changes":1,"rib":7,"marked":false}
route.withdraw  {"withdrawn":["10.255.0.0/24"],"not_held":[],"total":1,"changes":1,"rib":6}
```

Sending by hand, measured against the library, then what `show.adj_out`
answers under `hand` and the `resend` that follows. The replayed octets
are not a message, so their row is the whole peer and `resend` keeps it,
since only the session ending can settle it:

```json
peer.specimen {"specimen":"large_communities","prefixes":["10.30.0.0/24"],"marked":false,"sent":[{"peer":"10.0.10.1","prefixes":["10.30.0.0/24"]}]}
peer.fault    {"case":"origin_value","prefixes":["10.10.0.0/24"],"sent":[{"peer":"10.0.10.1","prefixes":["10.10.0.0/24"]}]}
peer.replay   {"octets":2,"sent":[{"peer":"10.0.10.1","prefixes":[null]}]}
"hand": {"total":3,"rows":[{"prefix":"10.30.0.0/24","verb":"specimen large_communities","at":"2026-11-05T01:42:52.161Z"},
                           {"prefix":"10.10.0.0/24","verb":"fault origin_value","at":"2026-11-05T01:42:52.161Z"},
                           {"prefix":null,"verb":"replay","at":"2026-11-05T01:42:52.161Z"}]}
peer.resend   {"peer":"10.0.10.1","resent":[],"withdrawn":["10.30.0.0/24","10.10.0.0/24"],"hand":1,
               "kept":[{"prefix":null,"verb":"replay","at":"2026-11-05T01:42:52.161Z"}]}
```

`resent` is empty there because that daemon has no `export:`, so its
answer for every prefix is a withdrawal.

`changes` is how many Loc-RIB changes it caused, which is not always the
same as `total`: see `route.withdraw` above.

The configuration methods. `show.configuration` answers **text** and the
rest answer what their own name says:

```json
show.configuration  "set router_id 10.255.0.1\nset as 65000\n..."
config.changed      true
config.compare      ["set neighbors 10.0.10.1 hold_time 60"]
config.replace      {"errors":[]}
config.load         {"errors":[]}
config.commit       {"ok":true,"errors":[],"warnings":["the session with 10.0.10.1 was bounced to pick up hold_time"],"changes":["set neighbors 10.0.10.1 hold_time 60"]}
config.discard      {"discarded":true,"changed":false}
config.history      [{"time":"2026-11-02T03:18:31.004Z","comment":"hold time","changes":1}]
config.rollback     {"rollback":1,"changed":true}
```

**Four of those shapes are not bgp4r's to choose**, and a mismatch is a
wrong answer rather than a missing one. `config.changed` is a **bare
boolean**, which `Drivers::Ospfd#running_config` uses as one directly.
`config.compare` is a **bare Array of lines**, which the driver maps over
to mask. `config.replace` answers a Hash with an `errors` key, which the
driver reads and treats as success when it is empty. And
`config.commit`'s four keys are read one by one: `ok` to decide whether
to raise, `errors` and `changes` through the mask, `warnings` as they
are.

**`show.configuration` answers YAML unless asked for `set`**, which is
the other way round from ospfd's curly braces: this configuration **is**
a YAML file, so the form a person recognises is the one they get with no
argument, and the driver passes `format: 'set'` already. `candidate:
true` answers the candidate instead of the running one.

**`config.history` row `i` describes rollback `i`**, which is what
`Drivers::Ospfd#rollbacks` relies on when it labels each row with its
own index: rollback 0 is the running configuration, rollback 1 is what
was running before the newest commit. The oldest kept configuration is
the file as it was read and has no history row of its own.
`Candidate::ROLLBACKS` bounds both.

# bgp4r-sim, the injector, with routegen

**Built**, in `bgp/sim/` over `exe/bgp4r-sim`, with `bgp4r sim` and
`bgp4r routegen` on the umbrella. Everything in this part of the
document describes what runs; where the implementation found this design
wrong it is corrected in place and says so.

```
bgp/sim.rb               requires the rest; not loaded by bgp4r.rb
bgp/sim/sent.rb          what it has sent: the counters and the feeds,
                         which is BGP::Daemon::Recorder's five keys for
                         the send side
bgp/sim/injector.rb      the ten actions, over a BGP::Daemon::Speaker's
                         sessions
bgp/sim/views.rb         the five reads; a subclass of
                         bgp/daemon/views.rb, so `status` and `peers`
                         are the daemon's own shape and cannot drift
bgp/sim/http.rb          the HTTP server and the two path tables
bgp/sim/server.rb        bgp4r-sim itself
bgp/sim/routegen.rb      bgp4r routegen
exe/bgp4r-sim
```

One test file each under `test/unit/sim/`, and
`test/functional/sim_test.rb` over the real HTTP API and a real session,
which is the only test that can say an HTTP request reaching the process
puts the octets another speaker reads.

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

Three things the building of it added to that list, each because leaving
it out was a wrong answer rather than a missing one:

* **`session.stop` keeps a session down.** `Neighbor#stop` does not:
  the active side dials again every `retry` seconds for as long as the
  speaker runs, so an injector that only stopped would watch the session
  come back two seconds later having reported that it stopped it. So a
  Peer has an administrative flag, checked in both directions in, and
  `session.start` clears it. For a **passive** peer `session.start` is a
  permission and not a dial, because nothing here can make the other
  side connect; the answer says which peers that applies to.
* **What was announced goes again when a session comes back.** A node
  file's `announce` block gets that for free, since the Speaker replays
  it on every establishment, and an action did not: without it a
  `session.flap` loses for good everything a scenario had announced and
  the scenario reads as a convergence failure. `Speaker#on_established`
  is the seam. A **generated** feed is not replayed, which is the fire
  and forget rule: there is no list of its prefixes and rebuilding one
  would be the Adj-RIB-Out the generator exists to avoid.
* **A program that sends and then stops has to drain first.**
  `send_message` queues and `BGP::IO::Output#exit` closes the queue
  rather than draining it, so `bgp4r routegen` lost the last UPDATE of
  every range it sent until `Injector#drain` was there: 15 prefixes of
  20 arrived and the report said 20. `Neighbor#pending` is new and is
  what a caller waits on.

**It starts silent.** No announcement happens until asked, because a
baseline the configuration created is a baseline no assertion can rest
on. A scenario asserts the peer holds nothing, then announces, then
asserts again.

**It validates nothing, and that is the whole product.** Any attribute,
any length, any order, any repetition, a Path Identifier on a session
that negotiated none. The library's first Convention is what makes this
program possible and the injector must not grow a check.
`test_nothing_validates` in `test/unit/sim/injector_test.rb` pins five
specific things no RFC allows, and every one of them goes out.

**What it does refuse is a request it cannot carry out, never one it
disapproves of.** An unknown body key, a fault name the catalog does not
have, a prefix that was never announced, an address that is not a
configured peer, hex that is not an even number of digits, no session to
send on. Each is a 4xx with a reason, which is the difference between a
scenario that fails and a scenario that passes having done nothing. An
unknown key is refused rather than ignored for the reason
`Speaker#export_options` already refuses one in a node file: a typo that
silently changes nothing is worse than both an error and a wrong value.

**`path_id` on a `generate` block goes in front of every prefix of the
range**, for an announce and a withdrawal alike (RFC 7911 section 3).
It used to be refused, because `Speaker#each_update` handed
`RouteGenerator` no Path Identifier and the key would have been dropped
in silence; phase 0 of `docs/route-generation.md` carried it through. A
value that is not an integer or does not fit in 4 octets is refused
before the feed starts.

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
bgp4r routegen examples/sim.yml
bgp4r routegen --peer 10.0.0.2 --peer-as 65002 --count 200000 --per-update 127
```

**The file is a node file and this said `examples/routegen.yml`**, which
is a different format: that one has `neighbor:` and `routes:` sections
with loosely matched key names and its own loader in
`examples/routegen`, which keeps working for whoever has the old file.
Reading both would mean two loaders for one subcommand, where the whole
argument for folding routegen in is that there is one vocabulary.
`examples/sim.yml` is the node file version of it.

**Its `announce` blocks are moved out of the config and sent as
actions**, which is what makes this the same implementation rather than
a second one: left in the config the Speaker would send each block by
itself on establishment, so each would go twice and the report would
count one of them.

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
`prefixes_per_second`. `bgp/daemon/speaker.rb`'s Recorder already
computes those for the receive side, and `bgp/sim/sent.rb` is the send
side of it: the timestamp format is `Recorder.iso`, which is now a class
method so there is one of it rather than two copies of a format string.

**`finished_at` is nil while a feed runs and that is what makes a feed a
feed rather than a spinner**: a reader polling `/api/sent` sees
`prefixes_sent` climbing with no `finished_at` and no rate, so it cannot
take a total off something that is still going. A `generate` action
answers at once with the feed's record and streams on a thread of its
own, which is also what keeps a 200000 prefix range out of an HTTP
request; `bgp4r routegen` runs the same action inline, which is the one
difference between the two.

## The console, `bgp4r routegen --interact`

An irb prompt on a live session, for playing with the library by hand
while developing and testing. The session comes up, then irb opens with
a `BGP::Sim::Console` as `self`, so a verb needs no receiver.
**`docs/console.md` is the full guide**: what the flags become, every
default they leave to the Speaker, and what the router at the far end
needs to match them.

```sh
# in the VM
bgp4r routegen --peer 10.0.0.2 --peer-as 65002 --interact
```

```ruby
verbs                                       # what to type
announce '10.1.0.0/24', med: 10, as_path: [90, 80]
withdraw '10.1.0.0/24'
specimen :large_communities, '10.2.0.0/24'  # specimens lists the names
fault :origin_value, '10.3.0.0/24'          # faults lists the names
watch                                       # print what arrives
received 20                                 # the last 20 messages in
last.path_attribute                         # the last one, as an object
n.send_message Update.new(Path_attribute.new(Origin.new(0)), Nlri.new('10.4.0.0/24'))
ship(['ff' * 16].pack('H*') + "\x00\x13\x04")   # a KEEPALIVE by hand
notification 6, 2                           # a Cease first, when wanted
exit                                        # closes the session, no NOTIFICATION
```

**Every verb that sends goes through `Injector#act`**, inline, which is
the path `POST /api/...` takes. So what a person types is what a
scenario sends, with the same eBGP rules and the same refusals. `ship`
and `n` are the way past that: any message or String goes out as it is.

**It starts silent**, as the injector does, unless `--start` or
`--count` asks for a range. A node file with no `announce` block is
accepted with `--interact` and refused without it.

**The log goes to a file** in the temporary directory unless `-l` names
one, because a session logs from its own threads and every line would
land in the middle of what the person is typing. The path is printed.

**No verb is named after an irb command**, which wins over a method of
the same name. That is why the list is `verbs` and not `help`, and
`test/unit/sim/console_test.rb` asks irb for its command names.

**Ruby 4.0 made irb a bundled gem**, so under Bundler it loads only
because the `Gemfile` names it. A program run without the Gemfile's
gems and without irb is told so before any session starts.

`bgp4r sim --interact` and `bgp4rd --interact` are built, the second as
a Console of its own whose verbs are the daemon's control methods rather
than the injector's actions; docs/console.md section 10 has both. A
remote prompt over a socket is not planned: it would be arbitrary code
execution reachable from a lab network.

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
below. It is written `HOST:PORT`, or `[IPV6]:PORT`, or a bare `PORT`; an
IPv6 address needs the brackets because the last colon of `::1:8080` is
part of the address as readily as it is the separator. `--api` on the
command line wins over the key.

`examples/sim.yml` is this file with an `announce` block in it, which is
the waiver above, and the command line is
`bgp4r-sim FILE [--api HOST:PORT] [--log FILE] [--interact] [-d] [-v] [-h]`,
with `-f FILE` accepted too. `--interact` opens an irb prompt on the
injector while the API serves; docs/console.md section 10 has it.

**The keys are the Speaker's, which is the node file `lab/README.md`
documents, plus `api`, and the four that would build a Loc-RIB are
refused by name.** `rib`, `originate`, `export` and `fib` are
`bgp4rd`'s: an injector quietly deciding routes would make it a worse
daemon and void every assertion a scenario makes about what it sent. A
key no injector reads is refused as well, naming the ones it does.

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

**The header name is matched case insensitively and that is not
tidiness.** Measured on 2026-11-02 by reading what `Net::HTTP` puts on a
socket: it capitalises a header name per word, so the `X-BGP4R` a driver
writes arrives as **`X-Bgp4r`**. A case sensitive match refuses every
POST routescope makes, with a 403 and nothing anywhere saying why; 13 of
the 23 cases in `test/functional/sim_test.rb` fail when the downcasing
is taken out, which is how that is kept true.

**There is no web framework and no `webrick`.** The library has one
runtime gem and means to keep it, and `webrick` left the standard
library: `Gem::Specification.find_by_name('webrick')` raises
`Gem::MissingSpecError` on the Ruby this was written on, which is the
check Conventions requires before requiring any standard library. So
`bgp/sim/http.rb` is HTTP/1.1 over `TCPServer`, which for ten paths on a
loopback is a few hundred lines. What it does not do is written in that
file: one connection at a time, no keep-alive, no chunked request body,
no compression, no TLS, no authentication beyond the header.

Reads:

| Path | Answers |
|---|---|
| `GET /api/status` | the same shape `bgp4rd` answers, so one driver reads both |
| `GET /api/peers` | one row per configured neighbor |
| `GET /api/sent` | what it has announced, the feeds, and the rate |
| `GET /api/topology` | what it is configured to be able to send |
| `GET /api/events?since=N` | its events, in `bgp/events.rb`'s own shape |
| `GET /` | the paths, so `curl` needs no document |

**`/api/events` answers `Event#to_h` and this document said "Sim's own
shape"**, which is a correction worth the sentence. ospfv2's simulator
answers `{seq, time, kind, text}` with a clock time, so `Drivers::Sim`'s
event script has to invent a level, an interface and an empty data hash,
and carries a lambda that rebuilds a date from a time of day and
subtracts a day when the result lands in the future. `bgp/events.rb`
already carries `seq`, `time`, `level`, `kind`, `peer`, `message` and
`data` with a full ISO 8601 time, so answering that shape loses nothing,
invents nothing, and leaves a driver with one rename to do, `peer` to
its own interface column. Read against routescope at `7eabde1`.

**`summary.rib` is 0 and `announced` is beside it.** routescope's state
contract is `summary: { established:, peers:, rib: }` and an injector
holds no Loc-RIB: zero routes in a table it does not have is true, where
leaving the key out would show a console a blank and putting the
announced count there would call a list of what it sent a RIB.

**`/api/sent`'s rows are what it announced by name**, in routescope's
`bgp_routes` shape with `best` nil rather than false, since an injector
runs no decision process and false would claim a comparison it never
made. They are paged in the same envelope `show.routes` uses. A
generated range is **not** rows: it is one `feeds` record with its range
and its counts, because listing a million prefixes to say what was sent
is what the streaming generator exists to avoid.

Actions, as `action => [path, body keys]`, which is the table
`Drivers::Sim::ACTIONS` already is:

| Action | Path | Body |
|---|---|---|
| `announce` | `/api/announce` | `prefixes` or `generate`, `next_hop`, `as_path`, `as_path_literal`, `med`, `local_pref`, `communities`, `extended_communities`, `large_communities`, `path_id`, `peer`; or one of `spec` (with `churn`), `mp_reach`, `specimen` |
| `withdraw` | `/api/withdraw` | the same selectors, or `spec` or `mp_unreach` |
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

**`as_path_literal: true` sends `as_path` exactly as written.** Over eBGP
the speaker puts its own AS in front of `as_path` by default, which is
right for a node file and leaves no way to send an AS_PATH whose leftmost
AS is not the sender's, a receive check RFC 4271 section 6.3 asks a
router to make. The key is a JSON boolean and anything else is refused,
because a string `"true"` would prepend in silence. `attribute` takes it
too, so a scenario can flip one announced prefix to a literal path. It
changes nothing over iBGP, where nothing is prepended.

**Three selectors are not an announce block, and each refuses the
announce keys that do not go with it**, since a `med` beside a `spec`
would change nothing in silence. Phase 3 of `docs/route-generation.md`
added them:

* **`spec`** is a `BGP::Gen` spec, that document's section 4, handed to
  the library unchanged under its own key. The injector adds the
  session: our AS in front of the path over eBGP unless
  `as_path_literal`, our address as next hop when the spec gives none,
  and LOCAL_PREF to an internal peer only, 100 by default. Those are
  `Speaker#path_attribute`'s rules for an announce block, applied in
  `bgp/gen/sender.rb`. A spec is a feed, like `generate`: one record
  in `/api/sent`, counted and not listed, and not resent after a flap.
  **`churn` beside it sends that spec's churn instead**, section 8 of
  the same document: one UPDATE per event, paced at its `rate`, to
  routes the spec already announced. The answer carries the churn's
  `summary`. **A String `spec` is a name** looked up in the node file's
  `specs` block, so a lab defines its traffic beside the node and a
  scenario sends `spec: feed`. `withdraw` and `POST /api/plan` take the
  name too. Naming a spec sends nothing, so the node still starts
  silent. Each spec is read by `BGP::Gen` at start-up, so one it cannot
  read stops the node, and an unknown name is refused with the names
  there are. `GET /api/topology` lists them under `specs`.
* **`mp_reach` and `mp_unreach`** take the Hash `Mp_reach.new` and
  `Mp_unreach.new` read, so one message in any family the library
  builds. JSON keys are Strings and the constructors read Symbols, at
  every depth, which the injector converts.
* **`specimen`** names a `BGP::Specimen` entry and sends it in the
  envelope `Fault.update` uses, so the valid catalog and the faulty one
  reach a wire the same way. `prefixes` is its NLRI; a family specimen
  carries its own and takes none.

**`POST /api/plan` is a dry run**: the same `spec`, `peer` and
`as_path_literal`, and `offset` and `limit` for a page. With a `churn`
the rows are what the peer holds after it, and each plan carries the
churn's summary under `churn`. It sends
nothing and answers `{"plans": [{"peer", "rows", "total", "offset",
"limit", "next_offset"}]}`, one entry per target, where the rows are
`BGP::Gen#expected` with that session's rules. **Per peer, because the
answer differs per peer**: the prepend and LOCAL_PREF are the
session's. It takes the action header, so a driver writes every POST
one way. This is what lets routescope assert a router's RIB against a
spec without loading bgp4r.

**`fault` and `replay` are the point.** An injector that ships without
them is a worse FRR, and the argument for building any of this is gone.

Three things about those two, found in the building:

* **`fault` injects onto the session it has, where
  `lab/fault_matrix.rb` gives every case a session of its own**,
  because for the matrix a case the router answers with a reset leaves
  nothing to reuse and waiting for the next session is its whole per
  case cost. An injector is long lived: a case that resets takes that
  session down, the active side reconnects on its own `retry` timer, and
  what was announced goes again when it comes back. Nothing waits for
  any of that, which is why a scenario asserting the session survived
  reads the session state afterwards, as section 9.4's scenario C does.
* **One catalog name is one set of octets for both programs.**
  `BGP::Fault.update` is new in `bgp/fault.rb` and the matrix calls it,
  so "which attributes does a plain UPDATE need" has one answer; two
  copies of it is how two programs come to disagree about a case with no
  way to tell which was right. The move was checked rather than assumed:
  all 18 cases build byte for byte what the matrix built before it.
* **`replay` needed no new path.** `Neighbor#send_message` queues a
  String and `BGP::IO::Output` writes it, measured rather than assumed.
  The one thing refused is a string that is not an even number of hex
  digits, because that is not octets at all; the Marker, the Length and
  the Type are not looked at, which is the point.

A refused action answers 4xx with `{"error": "..."}`, and the exit status
of the `docker exec` carries it, because `exit(code < 300 ? 0 : 1)` is
how a driver tells a refusal from a success when all it gets is an exit
status. **Two codes, told apart by class and not by wording**: 400 for a
request the caller can fix and **409 for a session that is not there**,
which is the commonest thing to meet because the session is still coming
up. Both are 4xx, so a driver treats them alike, and a person reading the
body can tell "you asked for something odd" from "it is not up yet".

**`session.flap` answers before it has finished.** Three flaps at five
seconds is thirty seconds and a POST that blocked for it would sit
inside a driver's HTTP timeout for no gain, so it runs behind and a
scenario waits on a condition with `within:`.

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

# bgp4r lab new

**Built.** `BGP::Capture::CLI#lab` is it, and
`docs/routescope-labs.md` section 6 is the design: it copies a topology
folder and git-inits it, because a lab somebody edits in place is a lab
whose history is the repository's, and the git init is what makes a
saved configuration diffable.

```
bgp4r lab new DIR [NAME] [--no-git]
```

`DIR` must not exist, or must be empty. `NAME` is a folder under
`lab/topologies/`, defaulting to `two-speakers`, which is the only one
that needs nothing but bgp4r. `--no-git` copies and stops there.

**The routescope labs, in `routescope/labs/`, are made with
routescope's `routescope-labs install bgp4r/<lab>` now.** `lab new`
still copies them for one release, so scripts keep working, and prints
one line on standard error naming that command. The Compose topologies
in `lab/topologies/` are this repository's test suite and get no such
line.

**The topologies are discovered and not listed, and that is the one
deliberate difference from `ospfv2 lab new`.** That command keeps a
`CLAB_LABS` table beside its templates, so a template added to the
repository is invisible until somebody edits the table too. Here a
folder under `lab/topologies/` is offered the day it lands, and the
usage and the refusal for an unknown name both print what was found
rather than a list written down anywhere. That is also why the design's
`--routescope` flag is not here: a flag per topology is one more flag,
one more arm of a `fetch` and one more table row each time, where a
positional name against the discovered folders is none of them.

**How to start it comes from the folder's own files too.** A
`*.clab.yml` makes it a containerlab topology, which is containerlab's
own convention and what every routescope lab is; a `compose.yml` makes
it a Compose one. So a topology added later says which it is by what is
in it rather than by a second table, and that was not a hypothetical
for long: `bgp4r-lab` landed the same day and took the containerlab arm
with no change to `cli.rb`. A `README.md` in the folder is named when
there is one, which `add-path` and `bgp4r-lab` have and the other three
do not.

**What a `.gitignore` in the folder leaves out is read in three shapes**:
a trailing slash is a directory and takes everything under it, a
pattern holding a slash is matched against the relative path, and
anything else matches a basename at any depth. `bgp4r-lab`'s own file
is why: it carries `recordings/` and `clab-*/`, so a basename-only
match, which is what ospfv2's `copy_lab` does, would have copied
containerlab's working directory into every lab made from a template
somebody had deployed in place. `!` negation is not read; that one is
in CLAUDE.md under "Known issues to work on".

**A copied Compose topology cannot be built where it landed, and that is
a real limit rather than a caveat.** Every Compose topology here has
`build.context: ../../..`, the repository root, so the copy resolves
that context three directories above wherever it went. The image is
named, though, and `docker compose up` builds only when the named image
is missing, so the message says to build it once in a checkout and then
run the copy without `--build`. The image to name is read out of the
compose file, because `fault-matrix` builds `bgp4r-conformance` where
the other Compose topologies build `bgp4r-speaker`. `bgp4r-lab` is
containerlab and has none of this.

**Everything that can go wrong is a message, and only two of them are a
non-zero status.** A destination that is not empty, an unknown name, a
missing `lab/topologies/`, a folder that cannot be made and an unknown
flag each print why and exit 1. A git that is not installed, or a commit
that fails, prints a line and exits **0**: the copy is what was asked
for and it happened, and a lab with no history is still a lab.

**The topologies ship.** The gemspec's `s.files` is `git ls-files` and
its `require_paths` is `["."]`, so `lab/topologies/` sits beside `bgp/`
in an installed gem. Measured on 2026-11-02 by building the gem,
installing it into a throwaway `GEM_HOME` and running `bgp4r lab new`
from it. No packaging change was needed. Where the folder is absent
anyway, the command names the path it looked in.

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
