# The console: `bgp4r routegen --interact`

An irb prompt on a live BGP session, for playing with the library by
hand while developing and testing. This document explains what the
command does from the flags to the prompt, which defaults fill in what
the flags leave out, and what the router at the other end has to be
configured with. `docs/daemon.md`'s console section is the short form,
and `bgp/sim/console.rb` is the code.

`docs/console-examples.md` is six sessions to type, from a prompt with
no peer to a daemon lab, each with what comes back.

```sh
# in the VM
ruby -I. exe/bgp4r routegen --peer 10.0.0.2 --peer-as 65002 --interact
```

Those two flags do not describe a whole session. Everything else comes
from defaults, and the router at the far end has to match them.

## 1. The flags become a node file in memory

routegen does not read flags directly. It builds the same YAML node file
`bgp4r-sim` and `bgp4rd` read, then runs that. The command above
becomes:

```yaml
router_id: 10.0.0.1        # default, --id
as: 65001                  # default, --my-as
neighbors:
  - address: 10.0.0.2      # --peer
    as: 65002              # --peer-as
    connect: true          # always: routegen dials, it does not wait to be dialled
```

The keys it does not give take the Speaker's own defaults.
`test/unit/sim/console_test.rb` holds this table against the code.

| Setting | Default | How to change it |
|---|---|---|
| Our AS | 65001 | `--my-as` |
| Our router ID | 10.0.0.1 | `--id` |
| Peer TCP port | 179 | `--port` |
| Our source address | what the kernel picks for the route to the peer | `--local-address` |
| Hold time | 90 | node file, `hold_time` |
| Capabilities | as4_byte | node file, `capabilities` |
| Retry after a failed dial | 2 | node file, `retry` |
| Wait for Established | 30 | `--timeout` |

Hold time, retry and the wait are in seconds.

**No address family capability is sent by default.** RFC 4760 says a
session with none carries IPv4 unicast only, so that is what this
session carries.

## 2. What `--interact` changes before anything connects

* **irb is loaded first.** If it cannot be, the command says so and
  opens no session. Ruby 4.0 made irb a bundled gem, so under Bundler it
  loads only because the Gemfile names it, in its `console` group.
* **Nothing is sent on its own.** Without `--interact`, routegen sends
  one generated range, the single prefix 11.0.0.0/28 by default. With
  it, and no `--start` or `--count`, the session starts silent, which is
  the injector's own rule. A node file with no `announce` block is
  accepted too.
* **The log goes to a file**, `/tmp/bgp4r-routegen-PID.log`, and the path
  is printed. A session logs from its own threads, and every line would
  otherwise land in the middle of what you are typing. `-l FILE` picks
  another file.

## 3. The Injector brings the session up

routegen builds a `BGP::Sim::Injector` from the node file and starts it.
That is the object `bgp4r-sim` runs. The neighbor has `connect: true`,
so one thread per peer:

1. opens TCP to 10.0.0.2, port 179;
2. builds a fresh `BGP::Neighbor` with AS 65001, router ID 10.0.0.1,
   hold time 90 and the 4-octet AS capability;
3. sends OPEN and runs the FSM through OpenSent and OpenConfirm to
   Established;
4. on a failed dial or a session that drops, waits 2 seconds and tries
   again.

routegen waits up to 30 seconds for an established session. If none
comes up it prints each peer's state, stops, and exits with status 1.
You never get a prompt.

## 4. The prompt opens on the live session

Once a session is up, routegen prints `session to 10.0.0.2 up` and opens
irb with a `BGP::Sim::Console` as `self`. So a verb needs no receiver.

```ruby
verbs                                       # what to type
guide 6                                     # this document, section 6
peers                                       # every peer and its state
announce '10.1.0.0/24', med: 10, as_path: [90, 80]
withdraw '10.1.0.0/24'
specimen :large_communities, '10.2.0.0/24'  # specimens lists the names
fault :origin_value, '10.3.0.0/24'          # faults lists the names
watch                                       # print what arrives
received 20                                 # the last 20 messages in
received :all                               # keepalives too
received(:update).messages                  # the UPDATE objects
last.path_attribute                         # the last one, as an object
n.send_message Update.new(Path_attribute.new(Origin.new(0)), Nlri.new('10.4.0.0/24'))
notification 6, 2                           # a Cease, when wanted
exit
```

* **Every verb that sends goes through `Injector#act`**, the code
  `POST /api/announce` and the other actions run. So what you type is
  what a scenario sends, with the same rules and the same refusals.
* **This session is eBGP**, 65001 against 65002. So `announce` puts our
  AS in front of the AS_PATH you give, and sets NEXT_HOP to our own
  address on that socket. `as_path_literal: true` sends the AS_PATH as
  written.
* **`n` is the live `BGP::Neighbor`.** `n.send_message` puts any message
  you build on the wire, and `ship` does the same with a String of
  octets. Nothing checks either, which is the library's first rule.
* **A tap on the Neighbor records what the peer sends**, for `received`,
  `last` and `watch`. It goes on when the session reaches Established,
  so a message that arrives in that same instant can be missed.
* **`received` answers a list and `last` an object, and both leave
  keepalives out.** A peer sends one every holdtime/3 seconds, so
  without the filter they push the UPDATEs out of view and `last`
  answers a Keepalive. The list is an Array of rows, oldest first, that
  irb prints one line each. A row has `at`, `peer`, `kind` and
  `message`, also `msg`, and the list has `messages`, the objects:

  ```ruby
  received                         # the last 10, keepalives left out
  received 50, :all                # the last 50 of anything
  received :keepalive              # only the keepalives
  received :update, peer: '10.0.0.2'
  received.last.message            # the object
  received(:update).messages.collect { |m| m.nlri.to_ary }
  last :notification               # the last NOTIFICATION
  ```

  The kinds are `update`, `keepalive`, `notification`, `open`,
  `route_refresh`, `malformed` and `other`, and `:all` is every kind.
  A count and a kind go in either order. An unknown kind is refused
  with the list, rather than matching nothing.
* **Generated routes go through a spec**, the language of
  `docs/route-generation.md`, in any family:

  ```ruby
  s = { family: 'unicast', start: '10.100.0.0/24', count: 1000, per_update: 100 }
  plan spec: s                     # what it would send, and nothing sent
  announce spec: s                 # sends it, and answers when it is out
  announce spec: s, churn: { events: 20, seed: 3 }
  withdraw spec: s                 # the same routes, regenerated
  received(100, :update).prefixes  # how many prefixes arrived
  ```

  `plan` is `POST /api/plan`, with this session's rules applied, so a
  row has our AS in front over eBGP and our address as the next hop
  when the spec gives none. It shows 20 rows unless `limit:` says
  otherwise, `offset:` pages, and `total` is the whole count. With
  `churn:` it answers the routes held afterwards. Example 7 of
  `docs/console-examples.md` goes from the first route to the last
  withdrawal.
* **No verb is named after an irb command**, because irb's command wins
  over a method of the same name. That is why the list is `verbs` and
  not `help`. `ls` lists every method of the console.
* **`guide` prints this document** at the prompt, and `guide 6` or
  `guide 'router'` prints one section. On a terminal it is in colour
  and goes through `$PAGER`, or `less`. It reads this file, so what
  you see there is what is written here.

## 5. Leaving

`exit` returns from irb. routegen then stops the Injector and the TCP
connection closes. **No NOTIFICATION is sent**, because
`Neighbor#stop` sends none; that is an open item in CLAUDE.md. Type
`shutdown` first if the router should see a Cease with Administrative
Shutdown, or `notification 6, 2`, which is the same message.

## 6. What the router at the far end needs

The peer learns nothing from your command except what goes into the
OPEN. It has to be configured to accept exactly that:

* a neighbor whose address is our **source address**, with remote AS
  **65001**;
* its own AS **65002**, or it answers OPEN with Bad Peer AS;
* a router ID other than **10.0.0.1**, or the OPEN is refused as a
  collision; pass `--id` if it is;
* IPv4 unicast for that neighbor, the only family on offer.

For FRR, with 10.0.0.1 as our source address:

```
router bgp 65002
 no bgp ebgp-requires-policy
 neighbor 10.0.0.1 remote-as 65001
 address-family ipv4 unicast
  neighbor 10.0.0.1 activate
```

Without `no bgp ebgp-requires-policy`, or a route map in each direction,
FRR brings the eBGP session up and installs nothing. Every FRR config in
this repository carries that line for that reason.

## 7. When the defaults do not match your lab

Give the settings the flags cover:

```sh
# in the VM
ruby -I. exe/bgp4r routegen --peer 10.0.0.2 --peer-as 65002 \
  --my-as 65001 --id 192.0.2.1 --local-address 10.0.0.1 --interact
```

Anything the flags cannot say, such as the hold time, the capabilities,
add-path or IPv6, goes in a node file:

```yaml
# lab.yml
router_id: 192.0.2.1
as: 65001
local_address: 10.0.0.1
neighbors:
  - address: 10.0.0.2
    as: 65002
    connect: true
    hold_time: 30
    capabilities: [as4_byte, route_refresh, mbgp_ipv6_unicast]
```

```sh
# in the VM
ruby -I. exe/bgp4r routegen lab.yml --interact
```

## 8. How it is tested

* `test/unit/sim/console_test.rb` checks each verb's body against a fake
  injector, the received ring, the irb name clash, the routegen plan,
  and the defaults table above.
* `test/unit/sim/console_command_test.rb` checks `bgp4r console`'s
  flags and that its defaults are routegen's.
* `test/functional/console_test.rb` runs the verbs over a loopback
  session, then `connect`, `listen`, `shutdown` and `clear` against a
  real peer, with the Cease each sends read off the wire. Then it runs
  `bgp4r console` and `bgp4r routegen --interact` as programs with
  lines on their standard input, the way a person types them.

## 9. `bgp4r console`

The same prompt with the library loaded and no session until you ask
for one. Steps 2a, 2b and 2c are built. CLAUDE.md tracks the status
under "An irb console on a live session".

### Three ways to start

* `bgp4r console` opens irb with no session. Open one with `connect`
  or `listen`, or just build and parse objects: `Update.new(hex)`,
  `Specimen.build(:evpn)`, `Fault.wire(:origin_value)`. A verb that
  needs a session says so and names what opens one.
* `bgp4r console --peer ADDR --peer-as AS` is a `connect` done before
  the prompt opens. It goes through `Console#connect`, so the two cannot
  differ. It takes routegen's session flags: `--my-as`, `--id`,
  `--port`, `--local-address`, `--timeout`, `-l` and `-d`. It takes
  none of the flags that generate routes. If the session is not up
  after `--timeout`, the prompt opens anyway and the session goes on
  trying.
* `bgp4r console --back-to-back` is two bgp4r speakers in this one
  process, with `remote` the other side. It is below.

The log goes to a file in the temporary folder unless `-l` names one,
for the reason section 2 gives. `routegen --interact` keeps working,
through the same Console.

### Networking terms at the prompt

The session verbs use router words, and their keyword arguments use
the names routers use.

```ruby
connect '10.0.0.2', remote_as: 65002   # active: we dial
listen  '10.0.0.2', remote_as: 65002   # passive: the peer dials in
shutdown '10.0.0.2'                    # Cease 6/2, down, stays down
no_shutdown '10.0.0.2'                 # let it come back
clear '10.0.0.2'                       # Cease 6/4, reset, comes back
peers                                  # every peer and its state
```

* `connect` and `listen` take `local_as:`, `router_id:`, `port:`,
  `local_address:`, `hold_time:`, `capabilities:` and `wait:`. With
  nothing given they use the defaults in section 1.
* **`port:` and `local_address:` mean the far end for `connect` and
  our end for `listen`**, the way a router reads them. `connect`'s
  `port:` is the port we dial. `listen`'s is the port we listen on, 179
  by default, which needs root: pass `port: 1179` without it. Its
  `local_address:` is the address we listen on.
* `remote_as` and `local_as` are prompt names only. They become the
  node file's two `as` keys, so the node file vocabulary does not
  change.
* `connect` and `listen` answer the peer's row once the session is up,
  or after `wait:` seconds, 10 by default. The session goes on trying
  either way. `wait: 0` answers at once.
* `shutdown` and `clear` send a Cease before they close, with the RFC
  4486 section 4 subcode a router sends: 2, Administrative Shutdown,
  and 4, Administrative Reset. No Cease goes out when the session is not
  up, since there is nothing to send it on.
* `no_shutdown` is the one verb the design did not name. Without it a
  `shutdown` could not be undone at the prompt. It is `no neighbor ADDR
  shutdown`.
* `flap` stays as it was: the `session.flap` action, with `count:` and
  `interval:`. The design said it would become an alias of `clear`, and
  that would have taken `count:` away from what step 1 typed.
* One session per address, and one `listen` per port. A second one is
  refused in words, and so is a port that needs root.

### How `connect` works underneath

A Speaker reads its peer list once, at start. Taking a new peer at
runtime would change code that every session thread reads without a
lock. So each `connect` or `listen` builds its own Injector with one
peer, and the console keeps a list of them. A verb with `peer:` goes to
the matching one. A verb without it goes to the only session there is,
or the only one that is up, and otherwise asks for `peer:` and names the
peers. No library code changed. `exit` stops every session the prompt
opened.

### Back to back

```
bgp4r console --back-to-back
bgp4r console --back-to-back --my-as 65010 --peer-as 65010
bgp4r console --back-to-back --families ipv4
```

```ruby
fault :origin_value, '10.3.0.0/24'
remote.last.path_attribute.errors
remote.announce '10.9.0.0/24', med: 5
last.nlri
```

* **Both ends are on 127.0.0.1.** Our side listens on a free port and
  the remote side dials it. Each speaker has one peer, so neither needs
  a second loopback address. That also works on macOS, which has no
  127.0.0.2 by default. `--port` picks the port instead.
* **`self` is the near side, AS 65001. `remote` is a console on the
  other side, AS 65002.** Both are Injectors, so every verb works on
  both. `fault :origin_value, '10.3.0.0/24'` sends a malformed UPDATE,
  and `remote.last.path_attribute.errors` shows what `validation.rb`
  made of it. `remote.announce` sends the other way.
* **The remote side holds no RIB.** `remote.rib` waits for step 3,
  which brings a Console over `bgp4rd`.
* **eBGP by default.** If `--my-as` equals `--peer-as`, the session is
  iBGP. `--peer-as` is the remote side's AS here, 65002 by default, and
  needs no `--peer`.
* The remote side's router id is 10.0.0.2, or 10.0.0.1 when `--id`
  gives ours as 10.0.0.2, so the two never match.
* **Every family is offered on both sides**, so every specimen and
  every fault crosses with no node file. That is every family the build
  gate knows, with an IPv6 form beside the IPv4 one where the family
  has one, plus a 4-octet AS and ROUTE-REFRESH. RT-constrain is IPv4
  only, by RFC 4684 section 4. This is the main reason to use it over a
  router: neither GoBGP nor FRR has every family. The functional test
  sends every specimen and every fault across one session, and each
  arrives: the specimens with no finding and the faults with one.
* **A specimen crossing does not say its family was offered.** A bgp4r
  receiver reads a family it did not negotiate. Measured: with no MBGP
  capability at all, every specimen still crossed clean. So the test
  reads the OPEN each side received and asserts every family is in it.
* **`--families` narrows it**, with words separated by commas: `ipv4`,
  `ipv6`, or a name from `BGP::Specimen.families`, which takes that
  family on each AFI it has. `--families unicast,evpn` is three
  families.
* **Each side logs to its own file**, through the injected logger. The
  remote side's file is ours with `-remote` before the extension, and
  the console names it when it opens. With `-l -` both go to standard
  output and the remote lines start with `remote`.
* **`exit` stops both sides.**
* `--peer` and `--local-address` are refused with `--back-to-back`, in
  words, since both ends are 127.0.0.1.

### The pull requests

* **2a, done in #270**: an ORIGIN of any length is kept on receive, so
  every fault lands on a bgp4r receiver.
* **2b, done**: `bgp4r console`, with `connect`, `listen`, `shutdown`,
  `no_shutdown` and `clear`.
* **2c, done**: `--back-to-back` and `remote`.

## 10. Step 3, a prompt on the two programs

Designed with the owner on 2026-11-04. `bgp4r sim --interact` is
built, and so is `bgp4rd --interact` with its reading, acting and
sending verbs, the `mark` key, the `hand` list and Cease 6/2 on `exit`.
CLAUDE.md tracks the status under "An irb console on a live session". Two
commands gain `--interact`: `bgp4r sim`, the injector, and `bgp4rd`,
the daemon. They differ in kind, because an injector holds no Loc-RIB
and a daemon is a router.

### `bgp4r sim --interact`

The server builds its Injector and its HTTP API as it does today, then
opens the prompt on that Injector instead of waiting for a signal. Every
verb of section 9 works, and a scenario can still drive the same node
over HTTP while a person types. The log goes to a file, as `bgp4r
console` does, so the prompt stays readable. `exit` stops the injector,
the same as INT or TERM.

Built. Three things to know when using it:

* **The prompt opens before the session is up.** The server starts
  dialling and opens the prompt at once, where `bgp4r routegen
  --interact` waits for its session first. So `state` or `peers` before
  sending: a verb with no session up is refused and says so.
* **Leaving stops everything**: the injector, the API and any session
  opened at the prompt with `connect` or `listen`. A Python or curl
  client that was driving the API gets a refused connection after that.
* `-l FILE` names the log; without it the log is
  `bgp4r-sim-PID.log` in the temporary directory, and the path is
  printed before the prompt opens.

```
bgp4r sim examples/sim.yml --interact
```

### `bgp4rd --interact`, and why its verbs are the daemon's

A daemon keeps records: the Loc-RIB holds the routes it chose, and an
Adj-RIB-Out per peer holds what it sent. `show.rib`, `show.adj_out` and
`bgp4r-cli` read them. The injector verbs skip those records and put
octets on the wire, so on a daemon they would make its own answers
wrong. So the prompt's verbs are the daemon's own, and go through the
same methods the control socket answers, so the prompt and `bgp4r-cli`
cannot disagree:

* **Reading**: `peers`, `rib [STYLE]`, `why PREFIX`, `adj_in PEER`,
  `adj_out PEER`, `fib`. `rib` takes the three styles `show bgp`
  already has. `why` prints each path to one prefix, the one that won
  and each one that lost, with the step that decided it and the words
  `show.rib` already answers.
* **Acting**: `originate` and `withdraw`, which are `route.originate`
  and `route.withdraw`; `announce` is `originate` under another name.
  `clear`, `shutdown`, `no_shutdown` and `refresh` are the peer methods.
* **Sending by hand**: `specimen`, `fault`, `replay`, `ship` and
  `resend`, which the next section describes.
* **Watching**: `received`, `last`, `watch`, `quiet` and `n`, as in
  section 9.

Built, in bgp/daemon/console.rb. Four things to know when using it:

* **Each verb calls `Api#handle`**, the entry point the socket uses,
  and the answer goes through a JSON round trip. So a verb that returns
  data returns what `bgp4r-cli` would print, with String keys, and a
  refusal is the daemon's own message. `api 'show.fib'` reaches any
  method by name.
* **`clear` and `shutdown` send a Cease first**, 6/4 and 6/2, when the
  session is up, then call `peer.clear` and `peer.stop`. The socket
  methods still send none; that open item is theirs.
* **A verb with no peer** goes to the only one configured or the only
  one up, and otherwise names the peers rather than picking one.
* **`adj_in` and `adj_out` take the peer as the others do**: it may be
  left out when there is one peer, or one up.

```
bgp4rd -f rtr.yml -s /tmp/rtr.sock --interact
```

### Sending by hand on a daemon

`specimen`, `fault`, `replay` and `ship` are there too, because a
router carrying a full table that sends one bad UPDATE in the middle of
a session is a test a separate injector cannot run. **The Adj-RIB-Out
is never patched for them**, because after a fault the daemon cannot
know what the peer holds. A peer that treats the UPDATE as withdrawn,
as RFC 7606 asks for most fault cases, holds nothing for the prefix; a
peer that resets holds nothing from us at all; a peer that discards the
attribute holds a route we never chose. Instead:

* **Every prefix sent by hand is listed beside the Adj-RIB-Out rows**,
  as "sent by hand, state at peer unknown", per peer, with the verb and
  the time. In JSON it is a `hand` key beside `rows` in `show.adj_out`,
  the way `skipped` already is, and present only when there is
  something in it. A peer row in `show.peers` gains a count of them.
  So every answer looks as it does today until something is sent by
  hand.
* `replay` and `ship` flag the prefixes their octets touch, read back
  as an UPDATE. Octets that are not a readable UPDATE flag the whole
  peer, since the daemon cannot say what changed.
* **A flag clears three ways**: the daemon sends that prefix to that
  peer again the normal way, the session restarts and the Adj-RIB-Out
  is rebuilt, or `resend PEER`, which sends the daemon's own entry for
  each flagged prefix, the route if it has one and a withdrawal if it
  does not.

Built, in bgp/daemon/hand.rb for the list and `Control` for the sends.
What to know when using it:

* **The four sends are control socket methods**, `peer.specimen`,
  `peer.fault`, `peer.replay` and `peer.resend`, so `bgp4r-cli` sends by
  hand too. `ship` is the one that is not, since it takes an object;
  it goes through the same `Control#ship` the other three end in. With
  no `peer` they go to every session that is up, as `bgp4r-sim` does,
  and a named peer that is down is refused.
* **`resend` does not diff.** It sends the daemon's own answer for each
  listed prefix whatever the Adj-RIB-Out says the peer has, which is
  `Rib::Router#resend`, run on the table's worker thread. A daemon with
  no `export:` advertises nothing, so its answer is a withdrawal for
  every one.
* **Two kinds of row `resend` cannot answer**, so it keeps them and
  names them under `kept`: an NLRI of a family the daemon holds no
  table for, listed with a `family` key such as `16388/71`, and a whole
  peer row, a `null` prefix, from octets that do not read as a message.
  Both clear when the session ends, so `clear PEER` settles them.
* **A message that reads as something other than an UPDATE lists
  nothing.** A KEEPALIVE or a ROUTE-REFRESH changes no route, and a
  NOTIFICATION ends the session, which clears the list anyway.
* **The list clears when the session ends**, not when the next one
  comes up, since from that moment the peer holds nothing from us.
* **The time is UTC**, in the daemon's own format, so `at` reads like
  every other time `bgp4rd` answers: `2026-11-04T22:13:05.000Z`. The
  prompt prints the time of day from it.

### The marker community

A route made by hand can carry a community, so a router that receives
it can act on it, by logging it, matching it or refusing it. It is set
once, with the three keys an announce block already takes, and it is
off unless set:

```yaml
mark:
  large_communities: ['65000:1:1']
```

* It is added to routes originated at the prompt **and** through
  `bgp4r-cli route.originate`, since both are a person adding a route.
  An `originate:` block in the node file does not carry it.
* It is added to `specimen`, which is a valid UPDATE bgp4r builds.
* **It is never added to `fault`, `replay` or `ship`.** Those send a
  message exactly as given, and a community would change the message
  under test. For a fault the receiver would mostly never see it
  anyway, since a route treated as withdrawn never reaches its RIB.
* Nothing in the IANA registries means "made by hand", so the value is
  a convention. A large community (RFC 8092) in our own AS holds a
  4-octet AS, which a standard community cannot, and is ours to define.

The marker tells the receiver. The `hand` list tells the daemon and the
person at the prompt. They do different jobs, so both are needed.

### Leaving

`exit` stops the daemon: its sessions close and its socket is removed,
so one prompt is one process. Each peer is sent Cease 6/2,
Administrative Shutdown, on the way out, which closes the open "Cease
subcode per method" item for this path. Leaving the daemon running
after the prompt ends was the other choice, and it leaves a terminal
holding a process nobody can type into.

### The whole of it, by example

Every step below is what the design says happens. The `rib` and `why`
data were produced by the library from the same table, measured on
2026-11-04. Every step is built. The printed forms are close to what is
built, not exact: `originate` also answers `marked`, a send answers the
peers it reached, and the times are UTC.

**The lab.** One Linux machine, three terminals and no router binary.
All of 127/8 is loopback on Linux, so each speaker has an address of its
own; macOS needs `sudo ifconfig lo0 alias 127.0.0.2` and `127.0.0.3`
first.

| Name | Address | AS | What it is |
|------|---------|----|------------|
| `rtr` | 127.0.0.1 | 65000 | `bgp4rd --interact`, the router being driven |
| `up1` | 127.0.0.2 | 65010 | `bgp4r console`, an upstream that sends a route |
| `dn1` | 127.0.0.3 | 65020 | `bgp4r console`, the peer watching what `rtr` sends |

`rtr.yml`:

```yaml
router_id: 10.255.0.1
as: 65000
listen_address: 127.0.0.1
port: 1179                  # above 1023, so no root

neighbors:
  - address: 127.0.0.2
    as: 65010
    connect: false          # up1 dials us
    description: up1
  - address: 127.0.0.3
    as: 65020
    connect: false
    description: dn1

export: {}                  # advertise; the next hop is the session's own address

mark:                       # new: what a route made by hand carries
  large_communities: ['65000:1:1']
```

Each prompt is written `rtr>`, `up1>` or `dn1>` so the terminals can be
told apart; the real one is irb's. Verbs that print answer nil, and
irb's `=> nil` lines are left out.

#### Step 1: start the router

Terminal A:

```
$ bgp4rd -f rtr.yml -s /tmp/rtr.sock --interact
bgp4rd: logging to /tmp/bgp4rd-31337.log
bgp4rd: up, AS 65000, router id 10.255.0.1, listening on 127.0.0.1:1179
bgp4rd: socket /tmp/rtr.sock, so bgp4r-cli works beside this prompt
bgp4rd console: self is the daemon. 'verbs' lists what to type, exit stops the daemon.
rtr> peers
peer        as     state   uptime    rcvd  sent  best  hand
127.0.0.2   65010  active  -            0     0     0     0
127.0.0.3   65020  active  -            0     0     0     0
```

Both peers are listed though neither is up, because the daemon's peer
list is every configured neighbor.

#### Step 2: the upstream sends a route

Terminal B:

```
$ bgp4r console --peer 127.0.0.1 --peer-as 65000 --port 1179 \
                --local-address 127.0.0.2 --my-as 65010 --id 10.255.10.1
console: logging to /tmp/bgp4r-console-31400.log
console: session to 127.0.0.1 is established
up1> announce '10.10.0.0/24', med: 100
```

#### Step 3: the downstream joins, watches, and sends two routes

Terminal C:

```
$ bgp4r console --peer 127.0.0.1 --peer-as 65000 --port 1179 \
                --local-address 127.0.0.3 --my-as 65020 --id 10.255.20.1
console: session to 127.0.0.1 is established
dn1> watch
14:10:02.114 127.0.0.1 Update, 1 prefixes, 0 withdrawn
dn1> last.nlri.to_ary
=> ["10.10.0.0/24"]
dn1> last.path_attribute[:as_path].as_path
=> "65000 65010"
dn1> announce '10.10.0.0/24', as_path: [65021]
dn1> announce '10.20.0.0/24'
```

`rtr` passed up1's route on with its own AS in front, which is RFC 4271
section 5.1.2. dn1 now offers a second path to 10.10.0.0/24, whose
AS_PATH is `65020 65021` since dn1 puts its own AS in front, and a
route of its own to 10.20.0.0/24.

#### Step 4: ask the router what it has, and why

Terminal A:

```
rtr> peers
peer        as     state        uptime    rcvd  sent  best  hand
127.0.0.2   65010  established  00:01:12     1     1     1     0
127.0.0.3   65020  established  00:00:40     2     1     1     0

rtr> rib
BGP table version is 3, local router ID is 10.255.0.1
Status codes: s suppressed, d damped, h history, * valid, > best, i - internal,
              r RIB-failure, S Stale
Origin codes: i - IGP, e - EGP, ? - incomplete

   Network          Next Hop            Metric LocPrf Weight Path
*> 10.10.0.0/24     127.0.0.2              100             0 65010 i
*                   127.0.0.3                0             0 65020 65021 i
*> 10.20.0.0/24     127.0.0.3                0             0 65020 i

rtr> why '10.10.0.0/24'
10.10.0.0/24, 2 paths, decided at the as_path_length step
  best  from 127.0.0.2  as path 65010        best path, decided at the as_path_length step
  lost  from 127.0.0.3  as path 65020 65021  longer AS_PATH (as_path_length)
```

The counts follow from the export rules. up1 sent 1 route and was sent
10.20.0.0/24 only, since its own route does not go back to it. dn1 sent
2 and was sent 10.10.0.0/24 only, since its 10.20.0.0/24 does not go
back to it and its losing path is not advertised. The MED of 100 played
no part, because the two paths come from different neighboring ASes.

#### Step 5: originate a route by hand, with the marker

```
rtr> originate '10.255.1.0/24', communities: ['65000:100']
=> {"originated"=>["10.255.1.0/24"], "total"=>1, "changes"=>1, "rib"=>3}

rtr> adj_out '127.0.0.3'
prefix          next hop    as path      communities  large communities
10.10.0.0/24    127.0.0.1   65000 65010
10.255.1.0/24   127.0.0.1   65000        65000:100    65000:1:1
```

The answer is `route.originate`'s. The route went into the Loc-RIB,
through the export rules and into both Adj-RIB-Outs, with the community
given and the marker beside it. There is no `hand` entry, because the
records are true. Terminal C sees it arrive:

```
14:12:40.551 127.0.0.1 Update, 1 prefixes, 0 withdrawn
dn1> last.path_attribute[:large_communities].to_hash
=> {:large_communities=>["65000:1:1"]}
```

A router in dn1's place can act on the marker. In FRR a route map
refuses routes carrying it; these lines were checked against bgpd
8.4.4's own config parser, which refuses a misspelled copy of them:

```
bgp large-community-list standard HAND permit 65000:1:1
route-map FROM-RTR deny 10
 match large-community HAND
exit
route-map FROM-RTR permit 20
exit
router bgp 65020
 neighbor 127.0.0.1 remote-as 65000
 address-family ipv4 unicast
  neighbor 127.0.0.1 route-map FROM-RTR in
 exit-address-family
exit
```

#### Step 6: a specimen to one peer

```
rtr> specimen :large_communities, '10.30.0.0/24', peer: '127.0.0.3'
rtr> adj_out '127.0.0.3'
prefix          next hop    as path      communities  large communities
10.10.0.0/24    127.0.0.1   65000 65010
10.255.1.0/24   127.0.0.1   65000        65000:100    65000:1:1

sent by hand, state at peer unknown:
10.30.0.0/24    specimen large_communities at 14:13:05
```

`BGP::Specimen` built a valid UPDATE, the marker was added, and it went
to dn1 only. It never entered the Loc-RIB, so the rows are unchanged
and the list beside them says what went out. In JSON:

```json
"hand": { "total": 1,
          "rows": [ { "prefix": "10.30.0.0/24",
                      "verb": "specimen large_communities",
                      "at": "2026-11-04T22:13:05.000Z" } ] }
```

#### Step 7: a fault

```
rtr> fault :origin_value, '10.10.0.0/24', peer: '127.0.0.3'
```

The malformed UPDATE goes out exactly as the catalog builds it, with no
marker. dn1 is a bgp4r console, so it reports what it read:

```
14:14:21.007 127.0.0.1 Update, 1 prefixes, 0 withdrawn
dn1> last.path_attribute.errors.collect(&:reason)
=> ["undefined ORIGIN value 3 (RFC 7606 section 7.1)"]
```

A router would treat it as a withdrawal and drop 10.10.0.0/24. `rtr`
cannot know that:

```
rtr> adj_out '127.0.0.3'
prefix          next hop    as path      communities  large communities
10.10.0.0/24    127.0.0.1   65000 65010
10.255.1.0/24   127.0.0.1   65000        65000:100    65000:1:1

sent by hand, state at peer unknown:
10.30.0.0/24    specimen large_communities at 14:13:05
10.10.0.0/24    fault origin_value at 14:14:21

rtr> peers
peer        as     state        uptime    rcvd  sent  best  hand
127.0.0.2   65010  established  00:05:31     1     2     1     0
127.0.0.3   65020  established  00:04:59     2     2     1     2
```

The row for 10.10.0.0/24 still says what `rtr` last sent properly, and
the list says that may not be what dn1 holds. `rtr` does not repair
this by itself, because from its point of view nothing changed.

#### Step 8: put the peer back in line

```
rtr> resend '127.0.0.3'
=> {"peer"=>"127.0.0.3", "resent"=>["10.10.0.0/24"], "withdrawn"=>["10.30.0.0/24"], "hand"=>0}
```

10.10.0.0/24 has a row, so it goes out again with the real attributes.
10.30.0.0/24 has none, so it is withdrawn. Terminal C:

```
14:15:02.330 127.0.0.1 Update, 1 prefixes, 0 withdrawn
14:15:02.331 127.0.0.1 Update, 0 prefixes, 1 withdrawn
```

#### Step 9: ship a message by hand, then clear the session

```
rtr> ship Update.new(Path_attribute.new(Origin.new(0), As_path.new(65000), Next_hop.new('127.0.0.1')),
                     Nlri.new('10.40.0.0/24')), peer: '127.0.0.3'
rtr> adj_out '127.0.0.3'
...
sent by hand, state at peer unknown:
10.40.0.0/24    ship at 14:16:10

rtr> clear '127.0.0.3'
=> {"peer"=>"127.0.0.3", "cleared"=>true, "was"=>"established", "state"=>"idle"}
```

`ship` sent the message unchanged and the daemon read it back to find
10.40.0.0/24. `clear` sends Cease 6/4, Administrative Reset, and dn1
dials again by itself, being the active side. When the session is back,
`rtr` sends dn1 its Adj-RIB-Out rebuilt from the Loc-RIB. 10.40.0.0/24
is not in the Loc-RIB, so it is not sent, and the list is empty.

#### Step 10: withdraw

```
rtr> withdraw '10.255.1.0/24'
=> {"withdrawn"=>["10.255.1.0/24"], "not_held"=>[], "total"=>1, "changes"=>1, "rib"=>2}
rtr> withdraw '10.10.0.0/24'
=> {"withdrawn"=>[], "not_held"=>["10.10.0.0/24"], "total"=>1, "changes"=>0, "rib"=>2}
```

The second is `route.withdraw` saying the route is not ours. It came
from up1, and only up1 can take it back.

#### Step 11: exit

```
rtr> exit
bgp4rd: stopping, Cease 6/2 to 2 peers
$
```

The sessions close and the socket is removed. up1 and dn1 see the
Cease, go to `idle`, and keep trying to dial.

### What the example settles

* `announce` at the daemon prompt is `originate` under another name,
  and `withdraw` answers as `route.withdraw` does, `not_held` included.
* The marker comes from `mark`. It goes on routes originated at the
  prompt or through `route.originate`, and on specimens, and never on
  `fault`, `replay` or `ship`.
* Sending by hand is listed beside the Adj-RIB-Out rows and never
  written into them, and a listed prefix clears when the daemon sends
  it normally, when the session restarts, or on `resend`.
* `exit` sends Cease 6/2 and stops the daemon.
* The reading verbs are `peers`, `rib`, `why`, `adj_in`, `adj_out` and
  `fib`. None of them is an irb command.

### The pull requests

* **3a**: `bgp4r sim --interact`. Done.
* **3b-i**: the parts of the prompt both consoles share, moved into one
  module: loading irb, `verbs`, `guide`, `received`, `watch` and the tap
  on each Neighbor. No change in behavior. Done, as `BGP::Prompt` in
  bgp/prompt.rb, which loads without the injector.
* **3b-ii**: `bgp4rd --interact` with the reading and acting verbs, the
  `mark` key, and Cease 6/2 on `exit`. Done, in bgp/daemon/console.rb,
  with the mark read in `Control#route_originate`.
* **3b-iii**: sending by hand on the daemon: the four sends, the
  `hand` list in `show.adj_out` and `show.peers`, and `resend`. Done.
  **The design said an Injector over the daemon's own Speaker, and it
  is not one**: `Injector.new` builds a Speaker of its own and refuses
  the router keys, and what the daemon needs of it is two calls,
  `Specimen.update` and `Fault.update`. So `Control` makes those calls
  in the injector's envelope, and the daemon does not load the
  injector, which `console_test.rb` holds.
