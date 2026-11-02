# bgp4r in routescope

How bgp4r becomes a node routescope can drive, and the labs worth
building once it is. A design, not a record of work done: nothing in
sections 6 to 10 exists yet.

Written 2026-11-01 against routescope `7eabde1` and ospfv2 `2dfc03a`,
both read first hand. Where a claim is about one of those repositories
it is cited by file and construct, because this document cannot assert
them: see section 12 for what that costs and what fixes it.

**`docs/daemon.md` owns the two programs**: `bgp4rd` the daemon and
`bgp4r-sim` the injector, their functions, requirements, configuration,
command lines and the JSON they answer with. This document owns the
integration: the drivers, the inspector tables, the map, the labs and
the phasing. Neither repeats the other. Read that one first if the
question is what the programs do; read this one if the question is how
routescope sees them.

Section 9 is the injector as routescope drives it, which is the half of
`docs/daemon.md`'s design that is routescope's business. Read sections 3
and 4 first: it meets those contracts and then adds to them.

**Corrected 2026-11-01**, after reading `routescope/docs/protocols.md`,
which is the file that says how a protocol is added and which the first
draft of this document did not read. Three things it got wrong:

* The lab model. These labs are **containerlab** topologies in
  `~/labs/<name>`, as all three of ospfv2's BGP labs are. The first
  draft leaned on `lab.yml`, which routescope does read for a Compose
  lab, and left out the two labels that matter.
* How a node gets a driver. It is the **`routescope.kind` label**, else
  the image, and the protocols a node is asked about are the
  **`routescope.protocols` label**. Section 4 has both.
* The capture image. routescope runs captures in a container of its own
  from `ROUTESCOPE_CAPTURE_IMAGE`, default `ospfv2:latest`, so a BGP
  capture needs a routescope change. Section 7 has it.

## 1. What routescope is, in one paragraph

A Ruby backend (`lib/routescope/app.rb`, about 55 HTTP routes and four
WebSocket routes) and a React front end (`web/src/`). It **does not
build labs**. It reads a lab folder that docker compose or containerlab
brought up, reaches into each node with `docker exec`, and renders what
one driver per node kind reports. A lab is a folder holding `lab.yml`,
or one `*.clab.yml`, or a `lab.yml` naming a `containerlab:` file whose
nodes it then overrides. Configuration is all environment variables.
There is **no plugin mechanism**: every protocol is hard-coded in frozen
constants and `case` statements, and `docs/protocols.md` names the three
places to edit.

## 2. The finding that shapes the whole design

**routescope already speaks BGP, and it is not a stub.**

`Drivers::Frr#bgp` reads `show bgp summary json` and `show bgp neighbors
json`; `Frr#bgp_routes_table` parses `show bgp ipv4 unicast json` and
picks the path with `bestpath`. `Drivers::Bird#bgp` reads `birdc 'show
protocols all'` and `BirdText.bgp_routes` scrapes `show route all where
source = RTS_BGP`. Node health already counts it: `nodes.rb` makes a
node up on "OSPF two-way or full, an IS-IS adjacency up, a BGP session
established". The front end has `BgpPeer` in `api.ts`, a peer list on
the node card, `bgpState` in `maplayout.ts`, and columns for
`bgp_peers` and `bgp_routes` in `tables.ts`. There is an end-to-end test
(`test/e2e/bgp_test.rb`) against an FRR-and-BIRD lab, and unit tests
with recorded fixtures under `test/fixtures/bgp/`.

So **bgp4r is not filling a gap in routescope's BGP support.** If the
goal were "see BGP in a console", FRR already does it.

What that changes: the question is not how to teach routescope BGP. It
is what bgp4r offers that FRR and BIRD cannot, and the answer is the
first bullet of bgp4r's own Conventions. bgp4r can put octets on the
wire that no RFC allows, and it can replay a capture byte for byte.
Neither router can do either. So the design below is built around that
and not around parity.

routescope's own documentation names the shape: `docs/protocols.md`
ends "**A simulator** is a node kind with its own driver, like
`ospfv2-sim`: the driver gives its pane what to draw and the actions it
takes. **A BGP route injector would be one more.**"

## 3. The two roles, and they are two node kinds

| Kind | Program | What it is for | FRR could do it |
|---|---|---|---|
| `bgp4r` | `bgp4rd` | peering with real routers, showing a decision, transit, route reflection | yes |
| `bgp4r-sim` | `bgp4r sim` | sending what no RFC allows, replaying a capture, flapping on command, scripting the fault matrix | **no** |

The programs are designed in `docs/daemon.md`. The daemon is named
`bgp4rd` and not `bgpd` because FRR's binary is `bgpd` and a lab
container can have both on its `PATH`: bgp4r's own conformance image
already copies GoBGP's client in beside its own code.

Both are worth having and they are not the same program wearing two
hats. The first answers questions; the second takes orders. The second
is the one that justifies the work, and the first is what makes its
answers legible, because a lab needs something whose RIB you can read
next to the router you are testing.

**Do not merge them.** A node that both answers and acts is a node
whose state you cannot trust while a scenario is running, and bgp4r's
own rule against a global test switch applies at the lab level for the
same reason: once one program does both, every reader has to ask which
mode it was in.

## 4. The contracts bgp4r has to meet

These are routescope's, verbatim, and they are the specification for
the driver. Quoted from `lib/routescope/drivers.rb`.

**The two table row shapes**, documented at `drivers.rb:146-147`:

```
bgp_peers   address remote_as state description uptime received sent
bgp_routes  prefix next_hop as_path origin med local_pref from paths best
```

**The state method.** `Base#bgp(container)` raises by default; a driver
overrides it to return

```ruby
{ router_id:, as:, peers: [...],
  summary: { established:, peers:, rib: } }
```

**The state vocabulary is lowercase and closed**:

```ruby
BGP_STATES = %w[idle connect active opensent openconfirm established]
```

bgp4r's FSM says `:Established`, so the driver downcases. `frr_peers`
validates against this list, and a value outside it is dropped, so
getting the case wrong shows as an empty peer list rather than an
error.

**A driver declares BGP by answering, not by saying so.** `Base#bgp?`
is true only when the node's protocols include it **and** the driver
`respond_to?(:bgp_peers_table)`. Tables are found the same way:
`Base#table` is `send("#{name}_table", container)`. So the whole
contract is three method names and two row shapes.

**Reaching the node.** `Transport::Docker#exec(container, argv)` runs a
command and returns its output. Containers are found by compose or
containerlab labels, never by name alone.

**The open seam, and it is the one to lean on.** `Lab::Node`
(`lab.rb:19`) is `Struct.new(:name, :kind, :service, :address, :config,
:profiles, :options, keyword_init: true)` and **every key a lab file
does not name falls into `options`**. So `socket:`, `state_file:`,
`capture_interface:` and anything else reach a driver with no change to
routescope's schema.

**How a node gets its driver, which the first draft of this document
left out.** `Containerlab#node` (`containerlab.rb:64`) reads
`labels['routescope.kind']` first and falls back to `kind_of(n)`, which
matches the image against `IMAGES` (`containerlab.rb:29`):

```ruby
[%r{frrouting/frr|(\A|/)frr:}, 'frr'], [/bird/, 'bird'], [/ospfv2/, :ospfv2]
```

and for ospfv2 then splits by command, `ospfd` against the simulator. An
unknown kind is kept as a plain Linux node with a shell, a log and a
capture, and routescope says so in `Lab#warnings`. So a bgp4r container
is useful in a lab **before either repository changes**, and that is
phase 0.

Two rows for bgp4r, by the same two-step: `[/bgp4r/, :bgp4r]`, then the
command decides, `sim` for the injector and `bgp4rd` for the daemon. Add
the labels in the topology anyway, because an explicit label survives an
image rename.

**Which protocols a node is asked about** is the
`routescope.protocols` label in a containerlab topology, `protocols:`
on the node in a `lab.yml`, else the driver's `default_protocols`
(`drivers.rb:50`). Both bgp4r kinds default to `%w[bgp]`, and a lab that
says `routescope.protocols: bgp` on every node is saying it explicitly,
which all three of ospfv2's BGP labs do.

**Where a node's startup file is** comes from `CONFIG_IN`
(`containerlab.rb:20`), a kind to in-container path map, read against the
topology's `binds`. Two rows: `/etc/bgp4r/bgp4rd.yml` and `/lab/sim.yml`.
Without them routescope cannot show or save a node's configuration.

**Health.** `Nodes` (`nodes.rb:88`) counts `established` peers and a node
is up once one of them is. Nothing else in the BGP path decides health.

**Capture is the one contract bgp4r must match exactly to get for
free.** `Transport::Docker#capture_command` (`transport.rb:78`)
hard-codes the argv:

```ruby
[@docker, 'run', '--rm', '--name', name, '--network', "container:#{container.name}",
 '--cap-add', 'NET_RAW', '--cap-add', 'NET_ADMIN', image, 'capture', '-i', interface]
```

The image is `ROUTESCOPE_CAPTURE_IMAGE`, default `ospfv2:latest`. The
subcommand `capture` and the flag `-i` are not configurable. **No
filter is passed**: routescope has no dissector of its own and chooses
no filter; the ospfv2 image applies `ip proto 89` itself and reports the
string it used, which routescope only displays. So a `bgp4r` image
whose entrypoint takes `capture -i IFACE` and writes ospfv2's line
format drops into this path with one environment variable changed and
no routescope code at all. That is a strong reason to copy the format
rather than invent one.

**The local transport is harder-coded still**, which is worth knowing
before anyone counts on the environment variable alone:
`Transport::Local#capture_command` (`transport.rb:154`) is

```ruby
def capture_command(_container, interface:, **) = [['ospfv2', 'capture', '-i', interface], nil]
```

with the program name `ospfv2` written in and no `image:` seam at all.
So the Docker path is swappable by configuration and the local path is
not, which is why section 7 calls capture a modification rather than an
environment change.

The format, from ospfv2's `lib/ospfv2/dissect.rb` and `pcap.rb`:
newline-delimited JSON on stdout, a `{"capture": {...}}` header then one
`{"packet": {seq, time, length, hex, summary, fields, errors}}` per
frame, where a field is

```ruby
Field = Struct.new(:name, :offset, :length, :value, :show, :mask, :children, :check, :lsa)
```

Every byte belongs to a field, reserved bits included, and `check`
carries a verified checksum. routescope's decoder pane is generic over
that shape (`web/src/decoder.ts`); the only OSPF-specific parts are the
LSA key and "follow an LSA".

## 5. How a driver reads each program

**Each kind gets the control plane ospfv2 gives the same role**, so each
driver is a copy of an existing one rather than a new shape.

| Kind | Control plane | Driver copies | ospfv2's precedent |
|---|---|---|---|
| `bgp4r` | a Unix socket, JSON lines, dotted methods | `Drivers::Ospfd` | `ospfd` and `ospf-cli` |
| `bgp4r-sim` | HTTP on the container's loopback | `Drivers::Sim` | `ospfv2 run --web` |

`Drivers::Ospfd` already carries the client as a Ruby one-liner
(`drivers.rb:215`) that opens the socket, writes one request and reads
one line, with the socket path from `node.options['socket']` and a
default. Both halves of that are what `docs/daemon.md` designs for
`bgp4rd`, so the bgp4r driver is that method list with the paths
changed. `Drivers::Sim` is the same story for the injector, including
the POST header and `exit(code < 300 ? 0 : 1)` to carry a refusal out
through an exit status.

**A state file stays, and it is not the driver's road.**
`lab/speaker.rb` writes `/tmp/bgp4r-state.json` at 2 Hz with an atomic
rename, and #228 added the peer's negotiated capabilities to it. That is
worth keeping for a reader with no socket, for the lab test scripts, and
because routescope's `Lab::Node` carries `state_file` through `options`
with no schema change. But a driver should ask a question rather than
read a snapshot bgp4r chose to write, which is what `Frr` and `Bird`
both do.

**The thing to get right in A, because B and C inherit it.** The state
has to be the *data* under `rib/show.rb`, not its text. bgp4r's own
CLAUDE.md says of those three styles that "nothing here has been diffed
against a real device, so no test anywhere should depend on this text
byte for byte", and a driver parsing that text would be exactly such a
test. ospfv2 separates the two in one file, `lib/ospfv2/daemon/views.rb`,
"operational state as plain data, ready for JSON", with formatting
elsewhere; one shape there serves its Junos output, its IOS output and
its JSON. bgp4r wants the same split, and getting it buys the vendor
style phase recorded in CLAUDE.md as well.

## 6. What bgp4r must build, in dependency order

Measured against ospfv2, which ships all of it. Each item says what it
unblocks, so the order is not arbitrary.

1. **Executables, which bgp4r has none of.** No `bin/`, no `exe/`, and
   the gemspec declares none; `lab/speaker.rb` is run as `ruby -I.
   lab/speaker.rb FILE`. `docs/daemon.md` names the four: `bgp4rd`,
   `bgp4r-cli`, `bgp4r` with `sim`, `routegen`, `capture` and `lab new`,
   and `bgp4r-sim` as an alias so a container command reads plainly.
   Unblocks everything, and the capture contract in section 4 forces the
   shape of one of them.
2. **The speaker becomes a router.** This is the largest item and the
   most valuable. `lab/README.md` states the limit outright: "A speaker
   originates routes and records what it receives. It never passes
   routes on from one neighbor to another, so it is not a route
   reflector or a transit router yet." Meanwhile `bgp/rib/` has
   `rib.attach`, `rib.advertise`, `rib.originate`, `rib.show` and
   `rib.install`, all finished and all tested over loopback, and
   **none of it is wired into the lab speaker**, which predates it. Wire
   it behind node-file keys. Unblocks `bgp_routes_table` meaning
   anything at all, since that row wants a best path, a `paths` count
   and a `best` flag, which only a Loc-RIB has, and unblocks labs B, C,
   F and H in section 8.
3. **A view layer: state as plain data.** Section 5. Feeds the state
   file, the CLI and later the socket from one shape.
4. **A JSON dump of the RIB.** Already a recorded decision in CLAUDE.md
   that was never implemented: "Dump the RIB to JSON, as the lab speaker
   dumps its state, so a test and a person can both see why a route
   won." Measured on 2026-11-01: there is no JSON anywhere in
   `bgp/rib/`. The decision process already returns the winner, the
   step that decided it and why each other route lost, so the data
   exists and only the serialisation is missing. This is the single
   highest-value item for a console, because "why did this route win"
   is the question a RIB pane exists to answer and no other
   implementation in the lab can answer it about itself.
5. **`bgp4r capture -i IFACE`.** Section 4 gives the exact contract. A
   BGP dissector differs from OSPF's in three ways and no more: the
   filter is `tcp port 179`, messages are a stream rather than one per
   frame so a reader must reassemble across segments, and the checksum
   to verify is TCP's rather than the protocol's. bgp4r already parses
   every message from octets and already answers `to_shex`, so the work
   is offsets and masks, not decoding.
6. **A structured event stream.** bgp4r has `Neighbor#on_state_change`
   and `Table#on_change`, which are the hooks; it has no sequence
   numbers, no kinds, no backlog and no `since:` replay. ospfv2's shape
   is worth copying whole: an `Event` struct carrying `kind` and `data`
   "so a program need not parse `message`", a bounded list, a sequenced
   publish side, and a synthetic `overflow` event so a console can tell
   a gap from quiet. Unblocks the timeline pane and scenario `measure:`.
7. **An injected logger.** bgp4r's `Log` in `bgp/common.rb` is a
   **global class-variable singleton** with `private_class_method :new`.
   One process per container makes that survivable, but it means no
   per-node logger, and `Log.level` and `Log.filename` are process-wide.
   ospfv2 injects a plain callable `->(level, message)` like its clock.
   Lower priority than 6, since a console reads events and not log text.
8. **Actions, for `bgp4r-sim` only.** A way for routescope to tell a
   node to do something. The table is in `docs/daemon.md`: announce,
   withdraw, attribute, fault, replay, notification, the three session
   actions and refresh, on an HTTP API on `127.0.0.1:8080` with a header
   requirement so a cross-site form cannot flap a lab. Two of them are
   why the node kind exists at all: `fault`, which drives the eighteen
   cases of `BGP::Fault::CATALOG`, and `replay`, which sends a capture
   byte for byte. An injector without those two is a worse FRR.
9. **Containerlab topologies and a privilege story.** bgp4r's Dockerfile
   runs as the non-root user `bgp` and relies on a container's own
   `net.ipv4.ip_unprivileged_port_start=0` to bind 179. That is fine for
   compose. Link faults are the reason to care: routescope's `Links`
   does `ip link set` and `tc qdisc` through a netns sidecar and
   `Links#ends` resolves **both** ends from `lab.links`, which a compose
   lab does not declare, so on compose only one end is acted on. So
   every lab that injects link faults wants containerlab.

**Two things this list used to call unnecessary and no longer does**,
because the design asked for them by name:

* **`bgp4r lab new DIR`**, which copies a topology folder and git-inits
  it, as `ospfv2 lab new` does from `CLAB_LABS` (`cli.rb:187`). A lab
  somebody edits in place is a lab whose history is the repository's,
  and the git init is what makes a saved configuration diffable.
* **A candidate configuration with `load`, `compare` and `commit`**,
  which is in `docs/daemon.md`'s method list. routescope's Config pane
  reads `running_config`, `candidate?` and `save_running`
  (`drivers.rb:64-78`), so without a candidate model the daemon's node
  shows a configuration it cannot change.

Still deliberately not on this list: an HTTP server on the daemon for
browsing its own state, and a command grammar with completion.
`bgp4r-cli -c 'show bgp summary'` is a string match against a short
list, not a parser.

## 7. What routescope must gain

Additive unless marked. Columns are the file and the construct.

| Need | Where | Nature |
|---|---|---|
| the two node kinds | `Lab::KINDS` (`lab.rb:28`), `Drivers::BY_KIND` (`drivers.rb:1251`) | additive, two frozen constants, kept in step by hand |
| the router driver | `class Bgp4r < Drivers::Base` with `bgp`, `bgp_peers_table`, `bgp_routes_table` | additive |
| the injector driver | `class Bgp4rSim < Drivers::Base` with `act(c, action, params)`, modelled on `Drivers::Sim` | additive |
| image sniffing, so a clab topology needs no label | `Containerlab::IMAGES`, `CONFIG_IN` | additive |
| scenario conditions `bgp_session`, `bgp_prefix` | `Scenario::CONDITIONS` (`scenario.rb:22`) | additive |
| evaluating them | `ScenarioRunner#check`'s `case c.kind` (`scenario_runner.rb:341`) | **modification** of one method |
| scenario actions for the injector | `Scenario::ACTIONS` and `SIM_ACTIONS` | additive |
| BGP panes | `web/src/protocols.ts`, panels in `App.tsx` | additive; `docs/protocols.md` pre-names `bgp-rib` and `bgp-peers` |
| a RIB compare across nodes | `lib/routescope/compare.rb`, today OSPF only | **modification** |
| the `bgp_decision` table | `Drivers::Base#tables`, overridden as `super + %w[bgp_decision]`; one entry in `web/src/tables.ts` | additive, and FRR and BIRD are untouched because `BGP_TABLES` does not move |
| a capture that is not OSPF's | `Transport::Docker#capture_command` (`transport.rb:78`) and `Transport::Local#capture_command` (`:154`) | **modification**: the Docker image is an env var but a global one, the subcommand and the missing filter argument are hard-coded, and the local path names `ospfv2` outright |
| lab lifecycle not assuming ospfv2 | `lib/routescope/lifecycle.rb`, `ROUTESCOPE_OSPFV2`, `PROJECT = 'ospfv2'` | **modification**, or sidestep it with containerlab |

**The capture image is the one row with a shape to propose rather than
just a cost.** `ROUTESCOPE_CAPTURE_IMAGE` is one value for a whole lab,
and a lab with FRR, BIRD and bgp4r in it needs the OSPF dissector next
to one node and the BGP dissector next to another. One image cannot be
both: ospfv2's filters `ip proto 89` and bgp4r's would filter `tcp port
179`.

So the driver should answer its own capture image, defaulting to the
environment variable, and the bgp4r drivers answer `bgp4r:latest`. One
method on `Drivers::Base`, read by both transports. That also gives
`Transport::Local` the seam it has none of today.

**Nothing needs a plugin mechanism, because there is none.** Four of
the eleven rows are modifications of a `case` or a constant, and those
are the ones to raise with routescope early, since they touch code
every protocol shares.

**One thing costs nothing at all.** An unknown `kind` in routescope is a
warning and the node renders as `linux`, with shell, log and capture.
So a bgp4r container can be put in a routescope lab **today** and be
useful before either repository changes. That is the zeroth phase.

## 8. The lab catalogue

Eight labs, ordered so each one is runnable when its prerequisites are.
"Needs" cites section 6 and 7 items. Every lab is a folder under
`lab/topologies/`, the convention bgp4r already uses.

**Containerlab, not Compose, and that is a correction.** All three of
ospfv2's BGP labs are `*.clab.yml` and routescope's own labs all are. The
reason that matters beyond consistency: `Links#ends` resolves both ends
of a link from `lab.links`, which a Compose lab does not declare, so on
Compose only one end of a link fault is acted on. bgp4r's existing
`lab/topologies/` are Compose and stay that way, because they drive
`lab/speaker.rb` for bgp4r's own test suite and routescope never sees
them.

### The lab to build first, concretely

`bgp4r-lab`, six nodes, three implementations, one containerlab
topology.

```
AS 65010                        AS 65000            AS 65001 (iBGP full mesh)

inj1 (bgp4r-sim) --eBGP--\
                          >-- rtr (bgp4rd) --eBGP-- r1 (FRR) ---- r2 (FRR)
inj2 (bgp4r-sim) --eBGP--/                               \        /
                                                          r3 (BIRD)
```

**Both injectors are in one AS on purpose.** MED only compares paths
from the same neighbouring AS, so that is what makes `rtr`'s decision
answer MED rather than skip it, and what lets one action flip which path
wins. Two injectors in two ASes would compare on AS_PATH length and the
MED step would never be reached.

Labels: `routescope.kind: bgp4r-sim` on the injectors, `bgp4r` on `rtr`,
and `routescope.protocols: bgp` on all six, which is what all three of
ospfv2's BGP labs do rather than leaning on a default.

What it exercises that no existing lab does, in order of what it proves:

1. Six sessions across three implementations, which the node cards and
   the map show.
2. A prefix injected on command reaching r2 and r3 with `rtr`'s AS
   prepended and `rtr` as the next hop, which is `rtr` routing rather
   than originating and so needs item 2 of section 6.
3. `rtr`'s decision answering **why**, with two paths to one prefix and
   the losing one naming `med`. That is the `bgp_decision` table and the
   one thing no other node in the lab can say about itself.
4. One action flipping the winner, which is a scenario rather than a
   screenshot.
5. A withdraw removing it from BIRD, which is the far end of the chain.

`bgp4r lab new ~/labs/bgp4r-lab --routescope` copies it and git-inits
it, as `ospfv2 lab new` does.

### A. Two speakers, one link

bgp4r against bgp4r, eBGP, the `two-speakers` topology that exists.
**Needs: a driver (7) and the daemon's `show.status` (6).** Validates
that the whole path works: the lab comes up, the driver asks, the console
shows two peers established and routes with their attributes.

Worth doing first precisely because it tests the plumbing and not the
protocol. If it cannot show two bgp4r speakers it will not show
anything.

### B. Capability negotiation matrix

One bgp4r speaker, one real router, one session per capability.
**Needs: 1, 5(A).** Validates 4-byte AS (and the AS_TRANS and AS4_PATH
path through a 2-byte peer), add-path in each direction, route refresh
and enhanced route refresh, graceful restart, ORF, BGP Role, and RFC
9072 extended OPEN.

Why a lab and not a unit test: bgp4r's own history. CLAUDE.md records
that the ADD-PATH Send and Receive fields were **inverted for years**
because two bgp4r speakers cancelled the error out, and that it was
found only by asking a real router what it read. A console that shows
the negotiated capabilities of every session side by side is that check
made visible and repeatable.

**The add-path row of this lab exists**, as `lab/topologies/add-path`,
and `lab/speaker.rb` records each capability of the peer's OPEN as data
so a driver can read it. Read the porting subsection below before
building the rest of the matrix: the one thing that did not port is the
part of the test that opens a session per capability value, because a
lab config is fixed and changing a capability on a live lab is an
injector action.

### C. Best path, one decision step at a time

Several paths to one prefix arrive at a bgp4r router; each case changes
exactly one tie-break input. **Needs: 2, 4.** Validates the RFC 4271
section 9.1.2.2 steps a) to g) in order, plus the RFC 4456 section 9
CLUSTER_LIST step that sits between f) and g).

This is the lab where bgp4r is better than the alternative, and item 4
is why. The decision process already returns the winner, the step that
decided it, and why each other route lost. No router in the lab can tell
you that about itself: `show bgp` gives you the winner. A RIB pane that
prints the losing reason per path is a teaching tool and a debugging
tool at once, and `rib.show(:junos, prefix)` already prints the
"Inactive reason" line that the console would render.

### D. Transit and route reflection

Three or more nodes with a bgp4r router in the middle. **Needs: 2.**
Validates AS_PATH prepending in all four RFC 4271 section 5.1.2 cases,
NEXT_HOP per 5.1.3, LOCAL_PREF per 5.1.5, MED not crossing into another
AS per 5.1.4, the RFC 1997 communities, and the RFC 4456 section 8
ORIGINATOR_ID and CLUSTER_LIST with the section 6 client matrix.

`test/functional/rib_router_test.rb` already runs three speakers over
loopback and asserts all of it. The lab adds real addresses, which
matters: that test's six cases all failed first because two listeners on
127.0.0.1 collapsed into one `Peer`, and a real topology is where that
class of mistake cannot happen.

### E. The fault matrix, made visible

`lab/fault_matrix.rb` against each router in turn. **Needs: 1, 8 for
the scripted form.** Validates the 18 RFC 7606 cases.

This already works and already has a per-router, per-version
expectation table in `test/functional/lab/fault_matrix_scenario.rb`.
What a console adds is three things. The catalog's entry shape is
`[name, description, expected action, subcode, RFC section, block]`,
which renders as a table with a verdict per row and needs no new data.
The per-version split becomes visible rather than living in a test
file: GoBGP 4.10.0 agrees on 16 of 18, 3.23.0 on 15, FRR 8.4.4 on 6.
And **a fault case can be run while a link is degraded**, which no
current test can do.

Worth saying plainly: this is the artefact ospfv2 does not have. Its
divergences are recorded as prose comments beside the assertion that
pins them. bgp4r's are a catalog and a matrix.

### F. Convergence and failure

A link goes down, the hold timer expires, routes are withdrawn,
forwarding changes. **Needs: 2, 6, 9.** Validates the RFC 4271 section
4.4 hold time, withdrawal propagation, the MinRouteAdvertisement
interval pacing UPDATEs, and graceful restart.

This is the lab routescope's fault injection exists for, and it is also
where bgp4r has something to show: `bgp/rib/mrai.rb` paces per
destination with an injected clock, and the recorded suggested values
are 30 seconds eBGP and 5 iBGP with 0.75 to 1.0 jitter. A timeline that
shows UPDATEs arriving in those windows is the only way anyone will
believe the pacer works, and item 6's sequenced events are what the
timeline reads.

Note the honest caveat: `Links#ends` acts on one end only when the lab
declares no links, so this lab wants containerlab.

### G. Scale

The `routegen` topology, which exists: 10,000 prefixes from a generator
into a sink, timed. **Needs: nothing for the current form; 2 and 4 to
take a full table into a RIB.** Validates the UPDATE packing arithmetic,
and then the decision process and the FIB at a million prefixes, which
CLAUDE.md's own decision says to measure with `routegen` rather than
guess.

The speaker already records `prefixes_per_second`, `established_at` and
`seconds_to_last_update`, so the timing data is there today.

### H. Forwarding

bgp4r computes a Loc-RIB and installs it, and hosts ping through.
**Needs: 2, 9.** Validates `rib.install`, that a link failure changes
forwarding, and that nothing stale is left behind.

`test/functional/lab/fib_test.rb` already does this against a real
kernel in a network namespace and needs root. A container is a
namespace with a filesystem, so the lab form is the same test with the
namespace supplied by the lab, which is also what makes it watchable:
routescope can show the route table next to the Loc-RIB that produced
it.

### What is deliberately not a lab

**Per-family breadth.** Flow spec, EVPN, RT-constrain, MCAST-VPN and
BGP-LS each already have a lab test asserting what GoBGP and FRR make of
what bgp4r sends, and `docs/*.md` section 9 or 11 records the
measurements. A console would re-render those and add nothing, because
the finding in each case is a value in a router's RIB and not a
topology. Revisit if a family's lab test ever needs more than two nodes.

**A compare pane across implementations.** Tempting and wrong for now:
`compare.rb` is OSPF-only and widening it is a modification, and the
thing worth comparing in BGP is a best-path decision, which only bgp4r
can explain about itself. Lab C does the useful half with one node.

### Porting the lab tests that already exist

The catalogue above is written as eight new labs, which understates what
is in hand: `test/functional/lab/` holds **23** test files, and most of
them already set up a topology, drive it and assert an outcome. Three of
them already run a Compose topology, so labs A, E and G exist in all but
the console. So the first question for any of these labs is not "what do
we build" but "which existing test does this already do, and what would
a scenario add".

That 23 was 16 in the first draft of this section, from memory, and the
difference is the rule this document already states twice: measure
rather than recall. `ls test/functional/lab/*_test.rb | wc -l`.

**The answer is usually nothing, and that is the finding.** A lab test
that runs in CI in under a minute, with no Docker, asserting a value in
a router's RIB, is better than a scenario in every way a maintainer
cares about: it is cheaper, it fails in CI, and it needs no console
open. Porting one for symmetry trades a guard for a demonstration.

**So the test decides, by one question: does the assertion need
something a single test process cannot have?** Three things qualify.

| Needs | Why a test cannot | Which tests have it |
|---|---|---|
| more than one receiver reading the same octets | a test asserts against one router and moves on | add-path, and nothing else today |
| an action taken after the session is up | a test can send, but a topology's config cannot | add-path, the fault matrix |
| a degraded or broken link while traffic flows | no test here touches a link at all | the fault matrix, convergence, forwarding |

Everything else stays a test. All 23, grouped:

| Files | Port it |
|---|---|
| `two_speakers_test`, `routegen_test`, `fault_matrix_test` | **already a Compose lab.** These are labs A, G and E, and what they want is a driver and a console, not a port |
| `add_path_gobgp_test` | **yes**, and it is done: `lab/topologies/add-path` |
| `fault_matrix_native_test`, `fault_matrix_frr_test` | **yes**, into lab E, and only for what they cannot do: a fault case while the link is degraded |
| `fib_test` | **yes**, lab H, because a container supplies the namespace it needs root for |
| `rib_router_gobgp_test`, `rib_router_frr_test` | **partly**, lab D. What the lab adds is real addresses: `test/functional/rib_router_test.rb`, which is not in this folder, runs three speakers on loopback and all six of its cases failed first because two listeners on 127.0.0.1 collapsed into one `Peer` |
| `attr_set_gobgp_test` | **no**, and it is the closest call: it already runs a router in the middle, so its topology exists inside the test |
| `evpn_*`, `flow_spec_*`, `link_state_*`, `mcast_vpn_*`, `rt_constrain_gobgp_test` (9 files) | **no**, which is what "per-family breadth" above already says |
| `generate_test`, `log_level_test`, `speaker_test`, `routegen_loopback_test` | **no**, and not interop at all: these test the harness and the speaker in process |

So four files to port, two of them in part, on top of three labs that
exist already. A plan that assumed every lab test wanted to be a lab
would have been five times the size and mostly re-rendering.

**The worked example is add-path**, in `lab/topologies/add-path`, and
what it cost is the useful record. Its README has the detail; the shape
of it:

* **Of three test cases, one ported whole, one needed an action after
  Established, and one did not port at all.** The one that did not is
  the capability matrix: that test opens three sessions, one per
  Send/Receive value, and a lab config is fixed, so a scenario asserts
  only the pair its node files set. That is not a loss. The test covers
  all three rows in 35 seconds and should keep covering them.
* **Two changes to `lab/speaker.rb`, both small, both found by trying.**
  An announce block could not carry a Path Identifier, and the state
  file did not say what the peer's OPEN advertised. Each is a few lines.
  Expect this for any port: the speaker was written to originate and
  record, so anything a scenario wants to *read* is usually one field
  away and anything it wants to *do* is the injector.
* **One claim in CLAUDE.md about this was wrong**, and finding out cost
  one measurement. It said the recorder keyed routes by prefix alone so
  two paths would overwrite each other. It keys by `Nlri#to_ary`, which
  carries the identifier. The lesson is the one section 12 already
  records from the other direction: measure the thing, do not port from
  the note about it.
* **The lab's own best case is not in the test file at all.** A Path
  Identifier on a session that negotiated none: gobgpd 3.23.0 sends
  NOTIFICATION 3/1 and resets, where bgp4r reports nothing and reads one
  prefix as five, `51.100.0.0/198` among them. Two implementations, the
  same octets, opposite outcomes. That is a thing to look at rather than
  count, and it is the clearest argument in this document for building
  any of this.
* **It also found two gaps in bgp4r**, both receive side and both
  recorded rather than fixed: `validation.rb` has no NLRI field checks
  at all, and a malformed NLRI does not replay. Neither is an add-path
  bug. Porting a test is a second reader of code the test already
  covered, which is worth something on its own.

**And one limit that shapes every later port**: `lab/speaker.rb`'s
announce blocks are per-speaker, not per-neighbor, so every block goes
to every neighbor. A config cannot aim one UPDATE at one of several
sessions. That is why the negative case above needs the injector even
though nothing about it needs an action in principle.

## 9. bgp4r-sim in detail

Section 3 says bgp4r is two node kinds and that the injector is the one
no real router can substitute for. This is its design: how a session
comes up, what a scenario can tell it to do, and what routescope has to
gain for it. Read section 4 first for the contracts, because the
injector meets all of them and then adds to them.

### 9.1 The programs are designed elsewhere

The injector's shape, its configuration, its HTTP API, its action table
and the route generator folded into it are all in **`docs/daemon.md`**.
They are facts about a program a person runs, not about routescope, so
they live with the program. What follows is only what routescope has to
do about them.

Three of those facts bear on everything below, so they are repeated here
and nowhere else:

* It is **HTTP on `127.0.0.1:8080`**, reached by `docker exec` with a
  Ruby one-liner, which is `Drivers::Sim`'s shape exactly. A POST
  carries `X-BGP4R: routescope` and answers an exit status, so a driver
  tells a refusal from a success without reading the body.
* It **starts silent**. No announcement until asked, because a baseline
  the configuration created is a baseline no assertion can rest on.
* Its **action body keys are the node file's own keys**, the ones
  `lab/README.md` already documents for an announce block. So the
  scenario vocabulary below is bgp4r's configuration vocabulary and
  there is one thing to learn.

### 9.2 What the driver answers

The three contract methods of section 4, plus the injector's own.

```ruby
class Bgp4rSim < Drivers::Base
  def default_protocols = %w[bgp]
  def bgp(c)                       # from GET /api/status
  def bgp_peers_table(c)           # its sessions
  def bgp_routes_table(c)          # what it has announced
  def partial_rib? = true          # it holds no Loc-RIB
  def act(c, action, params)       # docs/daemon.md's action table
end
```

**`partial_rib?` is this family's `partial_lsdb?`**, and the precedent is
narrower than it looks. `Drivers::Base#partial_lsdb?` (`drivers.rb:68`)
exists so a reader knows the simulator holds only the LSAs it
originates, and its **only consumer is `Compare`** (`compare.rb:24`),
which is OSPF only. So adding `partial_rib?` buys nothing until
something reads it, and the thing that would read it is a BGP compare
pane, which section 7 marks a modification. Add the method with the
driver and expect it to be unread for a while.

**What it cannot answer, and the honest shape of saying so.** An
injector runs no decision process, so it has no best path and no
`bgp_decision` table. `bgp_routes_table` for it is what it has
announced, with `best` nil rather than false, because false would claim
a comparison it never made.

**Events are the one dependency it cannot be built without.** A console
driving an injector with no event stream shows a spinner and a state
file. The kinds a BGP scenario is about: a session state change, an
UPDATE sent with its prefix count, a withdrawal, a NOTIFICATION sent or
received, and a fault case injected with its catalog name. That is item
6 of section 6.

### 9.3 The scenario language

**A `bgp:` step key rather than widening `sim:`**, and that is a
smaller change rather than a larger one. `ScenarioRunner#do_sim` hard
codes its kind, `node_of(s.args['node'], 'ospfv2-sim')`
(`scenario_runner.rb:251`), and `Scenario::SIM_ACTIONS` is a flat
validated list, so reusing `sim:` would mean widening the kind check
**and** mixing two action vocabularies in one list, where `link.down`
would validate against a node that cannot do it. A `bgp:` key with its
own `BGP_ACTIONS` list leaves `do_sim` untouched.

```
bgp: announce
node: sim          # optional when the lab has one bgp4r-sim
prefixes: [10.1.0.0/24]
med: 100
```

**One modification is unavoidable and it is worth proposing as an
improvement.** `do_sim` slices the step's arguments against a hard
coded allowlist, `s.args.slice('count', 'interval', 'on')`, and then
`act` slices again against the action's own declared keys. The second
slice is the real one, so the first is a duplicate allowlist that has
to grow every time any action gains a body key. `do_bgp` should pass
everything except the runner's own reserved keys (`node`, `name`,
`continue`, `within`, `measure`) and let `act` do the per-action
slicing it already does. Proposing the same for `do_sim` is a strict
improvement for ospfv2 too, and a separate conversation.

The audit line needs the same widening: `@audit.record(user,
"sim.#{action}", ... .slice('link', 'count', 'interval', 'on',
'metric'))` (`app.rb:190`) records only those five keys, so a `bgp.`
action's prefix would not appear in the audit. One line.

**Conditions.** Three of the four are answerable by **any** driver that
implements the section 4 contract, so FRR and BIRD get them free and
the names are the ones `docs/protocols.md` already pre-names:

| Condition | Holds when | Needs |
|---|---|---|
| `bgp_session: { node, peer, state }` | that session is in that state | any BGP driver |
| `bgp_routes: { node, count }` | the node holds N BGP routes | any BGP driver |
| `bgp_prefix: { node, prefix, present, next_hop, med, as_path, local_pref }` | that prefix is there, or not, with those attributes | any BGP driver |
| `bgp_best: { node, prefix, reason }` | that prefix's best path was chosen at that decision step | **bgp4r only** |

`state` takes the values of `Drivers::BGP_STATES`, lowercase. `count`
takes an exact value or a `{min:, max:}` range, like every other
numeric condition.

**`bgp_best` is the one worth the work.** It reads the RIB JSON dump of
section 6 item 4 and asserts which RFC 4271 section 9.1.2.2 step
decided a prefix, so a scenario can say `reason: local_pref` and fail
if the winner changed for a different reason than the step intended.
No other implementation in a lab can answer that about itself:
`show bgp` gives the winner, not the step. It applies only to the
`bgp4r` router kind, not to the injector, which runs no decision
process.

### 9.4 Three scenarios

**Where these files go is routescope's answer, not ours.** A scenario is
a YAML file under `scenarios/` in the lab folder, kept in the lab's git
beside the node configurations, so a scenario and the lab version it ran
on travel together (`docs/scenarios.md`). Its report is `report.json` in
the run's folder under `recordings/`, which git ignores. So the three
below are files in the lab repository and not in this one, which is also
why section 12 can assert nothing about them.

**A. The session comes up and a route crosses.** The one to write
first, because it tests the plumbing and not the protocol.

```yaml
name: A route crosses to FRR
capture: [sim]
timeout: 90

steps:
  - expect: { bgp_session: { node: sim, peer: 10.99.1.20, state: established } }
    within: 60
    measure: session_up
  - expect: { bgp_routes: { node: frr, count: 0 } }
    name: FRR starts with nothing from us, since the sim is silent

  - bgp: announce
    prefixes: [10.1.0.0/24]
    med: 100
    communities: ['65001:7']
  - expect: { bgp_prefix: { node: frr, prefix: 10.1.0.0/24, present: true,
                            as_path: '65001', med: 100 } }
    within: 10
    measure: announce_to_rib

  - bgp: withdraw
    prefixes: [10.1.0.0/24]
  - expect: { bgp_prefix: { node: frr, prefix: 10.1.0.0/24, present: false } }
    within: 10
```

Note what the second step buys: it asserts the baseline is empty before
anything is announced, so the fourth step cannot pass on a route the
config created.

**B. One attribute at a time.** This is lab C of section 8, and it
needs a `bgp4r` router node in the middle as well as the injector, so
the sim announces the same prefix twice from two sessions and the
router picks.

```yaml
name: MED decides, then local preference overrides it
timeout: 120

steps:
  - expect: { bgp_session: { node: rtr, peer: 10.99.1.10, state: established } }
    within: 60
  - expect: { bgp_session: { node: rtr, peer: 10.99.1.11, state: established } }
    within: 60

  - bgp: announce
    node: sim-a
    prefixes: [10.2.0.0/24]
    med: 100
  - bgp: announce
    node: sim-b
    prefixes: [10.2.0.0/24]
    med: 200
  - expect: { bgp_prefix: { node: rtr, prefix: 10.2.0.0/24, next_hop: 10.99.1.10 } }
    within: 10
  - expect: { bgp_best: { node: rtr, prefix: 10.2.0.0/24, reason: med } }
    name: the lower MED won, and for that reason

  - bgp: attribute
    node: sim-b
    prefixes: [10.2.0.0/24]
    local_pref: 200
  - expect: { bgp_prefix: { node: rtr, prefix: 10.2.0.0/24, next_hop: 10.99.1.11 } }
    within: 10
  - expect: { bgp_best: { node: rtr, prefix: 10.2.0.0/24, reason: local_pref } }
    name: local preference is earlier in section 9.1.2.2, so it decides instead
```

The two `bgp_best` steps are what makes this a test of the decision
process rather than of its outcome. Without them the scenario passes
whenever the right route wins, including when it wins for the wrong
reason, which is the commonest way a decision implementation is subtly
wrong.

**C. A fault case, and the same case over a degraded link.** The
scripted form of lab E.

```yaml
name: RFC 7606 treat-as-withdraw, clean and then with loss
capture: [sim, frr]
timeout: 180

steps:
  - expect: { bgp_session: { node: sim, peer: 10.99.1.20, state: established } }
    within: 60
  - bgp: announce
    prefixes: [10.3.0.0/24]
  - expect: { bgp_prefix: { node: frr, prefix: 10.3.0.0/24, present: true } }
    within: 10
    name: the baseline route, so a later absence means something

  - mark: the ORIGIN length case
  - bgp: fault
    case: origin_length
    prefixes: [10.3.1.0/24]
  - expect: { bgp_prefix: { node: frr, prefix: 10.3.1.0/24, present: false } }
    within: 10
    name: treat-as-withdraw, so the prefix never arrives
  - expect: { bgp_session: { node: sim, peer: 10.99.1.20, state: established } }
    name: and the session survives, which is what makes it not a reset

  - netem: frr:eth1
    loss: 5%
  - bgp: fault
    case: attr_overrun
    prefixes: [10.3.2.0/24]
  - expect: { bgp_prefix: { node: frr, prefix: 10.3.2.0/24, present: false } }
    within: 30
  - netem: frr:eth1
    clear: true

  - bgp: session.flap
    count: 3
    interval: 5
  - expect: { bgp_prefix: { node: frr, prefix: 10.3.0.0/24, present: true } }
    within: 60
    measure: reconverge
```

**This is the scenario that could not be written any other way.** The
fault cases need an injector, the loss needs routescope's `Links`, and
the assertion that the session survived needs the session state read
after the fact. `lab/fault_matrix.rb` does the first and third today
and cannot do the second at all.

Note the `netem:` step requires containerlab, for the reason section 6
item 9 records: `Links#ends` resolves both ends from `lab.links`, which
a compose lab does not declare.

### 9.5 What this costs routescope

Beyond section 7's table, the injector specifically needs:

| Need | Where | Nature |
|---|---|---|
| the `bgp4r-sim` kind | `Lab::KINDS`, `Drivers::BY_KIND` | additive |
| the driver | `class Bgp4rSim < Base` with `act` | additive |
| `partial_rib?` | `Drivers::Base` | additive, mirrors `partial_lsdb?`, but see 9.2: nothing reads it yet |
| the `bgp:` step and its actions | `Scenario::ACTIONS`, a new `BGP_ACTIONS` | additive |
| `do_bgp` | `ScenarioRunner` | additive, a new method |
| the four conditions | `Scenario::CONDITIONS` | additive |
| evaluating them | `ScenarioRunner#check`'s `case` | **modification** of one method |
| the argument allowlist | `do_sim`'s `slice`, or leave it and write `do_bgp` without one | additive if only `do_bgp` changes |
| the audit keys | `app.rb:190`'s `slice` | **modification**, one line |
| the action route's kind check | `app.rb:184`'s `area` route | **modification**: the path segment is named `area`, which is OSPF's word |

**That last row is the one to raise with routescope first.** The
mutating route is `POST /api/labs/:lab/nodes/:node/area/:action`, and
`area` is a word with no meaning in BGP. `docs/protocols.md` prescribes
per-protocol routes, `/api/labs/:lab/nodes/:node/bgp/...`, so the
honest shape is a second route under the protocol's name reaching the
same `driver.act`. Additive if a new route is added; a rename of the
existing one is a breaking change to a published API and is not worth
asking for.

### 9.6 Decisions, so they are not re-litigated

* **One HTTP API on the container's loopback, reached by `docker
  exec`**, not a socket and not a port on the lab network. Section 9.1.
  It is `Drivers::Sim`'s pattern, it needs no addressing, and it stays
  driveable by hand.
* **The action body keys are the node file's keys.** `docs/daemon.md`. The
  injector's vocabulary is bgp4r's own configuration vocabulary at
  runtime, so there is one thing to learn and `lab/README.md` already
  documents it.
* **An injector starts silent.** Section 9.1. A baseline the config
  created is a baseline no assertion can rest on.
* **The sim dials.** `connect: true`, so the lab comes up without
  depending on which side won the race.
* **A `bgp:` step key, not a wider `sim:`.** Section 9.3. Two action
  vocabularies in one validated list is worse than one more key.
* **No link actions and no AS or router-ID actions.** `docs/daemon.md`.
  Links belong to routescope; OPEN fields belong to the config.
* **`fault` and `replay` are the point.** If the injector ships without
  them it is a worse FRR, and section 2's whole argument is gone.

## 10. Phasing

| Phase | bgp4r | routescope | Lab |
|---|---|---|---|
| 0 | nothing | nothing | a bgp4r container as `kind: linux`: shell, log, capture |
| 1 | 1, 3, 5(A) | kinds, router driver | A |
| 2 | 2, 4 | BGP panes | C, D |
| 3 | 5 | capture modification | B, and a decoder pane for BGP |
| 4 | 6, 9 | scenario conditions, `do_bgp` | F, H, and section 9.4's scenario A |
| 5 | 8 | injector driver and its kind | section 9.4's B and C, and E scripted |

**The injector is phase 5 and not phase 1, which is worth saying since
section 2 calls it the thing that justifies the work.** It needs item 6
of section 6, the structured event stream, or its pane shows nothing;
item 8, the action API, which is the largest single piece of new bgp4r
surface in this document; and item 2, the router kind, because every
scenario in section 9.4 asserts against something that holds a RIB.
Ordering it first would mean a node that can act and a lab that cannot
say what the action did.

Phase 0 is not a joke. It costs nothing, it proves the container runs
under routescope's transport, and it is where every assumption in this
document gets its first test.

**Part of phase 0 is done.** `lab/topologies/add-path` is a topology
with a `scenarios/` folder, and the two changes to
`lab/speaker.rb` that the port needed are in: a `path_id` on an announce
block and the peer's capabilities as data in the state file. It carried
a `lab.yml` too and that file is gone, which is the lab model
correction in this document's header arriving as a deletion: it was
written as a routescope manifest from the wrong model, two of its keys
were invented, and a Compose topology for bgp4r's own tests has no
reason to carry one when the routescope lab is containerlab. Nothing in
routescope reads the scenarios yet, which is exactly what phase 0 is, and
the topology is useful on its own today as three containers with a log
and a state file. The lesson from doing it is in section 8's porting
subsection, and the one worth carrying into phase 1 is that what a
scenario wants to **read** is usually one field away in the speaker,
while what it wants to **do** is the injector.

## 11. Decisions taken, so they are not re-litigated

* **Two node kinds, not one.** Section 3. A node that both answers and
  acts has state no reader can trust mid-scenario.
* **Copy ospfv2's capture line format rather than invent one.** Section
  4. It is the difference between one environment variable and a
  modification to shared code, and routescope's decoder pane is already
  generic over that shape.
* **The driver reads data, never rendered text.** Section 5. bgp4r's own
  rule forbids depending on `rib/show.rb`'s wording byte for byte, and a
  driver parsing it would be exactly that dependency.
* **State file first, CLI second, socket only for actions.** Section 5.
* **The lab speaker becomes a router rather than a second program being
  written.** `bgp/rib/` is finished and tested and unused by the lab;
  the gap is wiring, not design.
* **Containerlab for any lab that injects link faults**, compose for the
  rest. `Links#ends` is the reason and it is measured, not assumed.
* **No per-family lab.** Section 8. The existing lab tests already
  measure what a console would re-render.
* **The injector's own decisions** are in section 9.6, because
  they only make sense next to its design. The one that carries the
  most: if it ships without `fault` and `replay` it is a worse FRR.

## 12. What this document does not assert, and when it could

bgp4r's own rule is that a claim nothing checks reads as verified, and
that a guide's load-bearing claims get a test. This document breaks that
rule knowingly, in two ways, and both are worth stating rather than
leaving for a reader to discover.

**Every claim about routescope and ospfv2 is a read of another
repository at a named commit.** `7eabde1` and `2dfc03a`. Nothing here
can assert them, and both repositories move. The claims most likely to
go stale first are the exact row shapes in section 4 and the file and
line references in sections 7 and 9, because they are the ones a
refactor touches. Re-read `drivers.rb:136-160` and `docs/protocols.md`
before trusting either.

**One claim in section 9 was wrong in its first draft and the
correction is recorded in place**, which is the only honest way to
carry a read of someone else's code: `partial_lsdb?` is read by
`Compare` and not by the inspector table, so the precedent it sets for
`partial_rib?` is narrower than it first appeared. Expect one or two
more of that kind, and prefer reading the consumer over reading the
definition.

**One part of this document is no longer a design, and it is the one
with a test.** Section 8's porting subsection has a worked example that
exists: `lab/topologies/add-path`, with
`test/functional/lab/add_path_topology_test.rb` holding its node files,
its scenarios and its manifest to the folder's own README, with no
Docker and no router. So the claims in that subsection about **what the
port cost** are checked, and its claims about routescope are not,
because the scenario language in those files is still a proposal.
The port also corrected a claim in CLAUDE.md, which is the second
instance of this document's own lesson: the note about the code was
wrong and one measurement settled it.

**Sections 6 to 10 describe work that does not exist**, so there is
nothing else to assert yet. What becomes assertable, and when:

* The moment item 1 lands, `exe/bgp4r capture -i IFACE` can be tested
  against the format in section 4 by a test in this repository, since
  the format is a string contract and not a routescope API.
* The moment item 4 lands, the state schema can be asserted against the
  two row shapes in section 4, field by field, by a test here. That is
  the one guard worth writing early, because a driver in another
  repository will depend on it and nothing else will tell us we broke
  it.
* Lab A's existence is assertable the way `test/lab_groups.rb` asserts
  the others: a lab folder present, in a CI group, with a test. The
  add-path lab is that guard working already, and it went further than
  this bullet expected: a test can read a topology's node files and hold
  them to its own README, so a wrong address or a mis-spelled capability
  fails the unit suite rather than a container log nobody is watching.
  Write that test for every topology this plan adds.
* **The injector's action table is assertable here the day item 8
  lands, and it is the best guard in this document.** `docs/daemon.md`'s
  table is a list of paths and body keys, and the API is bgp4r's own
  code, so a test can read the table out of this document and require
  that every action it names is a route the API serves and every body
  key is one the node file's schema already has. That is the shape
  `evpn_doc_test.rb` and `bgp_ls_doc_test.rb` use, discovered rather
  than listed, and it would catch the thing most likely to go wrong:
  an action added to the API with no row, or a row naming a key
  `lab/README.md` does not document.
* Section 9.4's scenarios are assertable only once a lab exists to run
  them in, which is phase 5. Until then they are worked examples of the
  language, and a reader should treat the YAML as illustrative: the
  step keys and condition names are proposals to routescope, not an
  interface either repository has today.

Until then this is a design, and the status line for it lives in
CLAUDE.md under "Where the work is going".
