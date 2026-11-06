# bgp4r-cli in a lab node's shell

What to type in the shell of a `bgp4rd` node, such as `rr1` or `dual` in
rr-lab or `rtr` in bgp4r-lab, and what each command answers.
`docs/daemon.md` is the design behind it. This is the user's guide.

`test/unit/daemon/cli_doc_test.rb` holds this file to the program: every
method the daemon answers is in the tables below, every table row is a
method it answers, and every operator command is listed.

## Where you are

The Shell button in routescope runs `docker exec` into the node's
container. You are root, in `/app`, which holds bgp4r's code. The node
runs one program, `bgp4rd`, so there is no `vtysh` and no router prompt.
You talk to the daemon with its client, `bgp4r-cli`, over a Unix socket
at `/run/bgp4r/bgp4rd.sock`.

The lab image puts these on the PATH:

| Command | What it is |
|---|---|
| `bgp4r-cli` | the client: everything in this guide |
| `cli` | the same program, a shorter name |
| `bgp4rd` | the daemon, already running as the node's main process |
| `bgp4r`, `bgp4r-sim` | the umbrella command and the injector |

`BGP4R_SOCKET` is set to the socket, so `cli` needs no `-s`. An image
built before this guide has neither the names nor the variable. Then
type this once per shell:

```
cli() { ruby -I/app /app/exe/bgp4r-cli -s /run/bgp4r/bgp4rd.sock "$@"; }
```

`cli --help` prints the options.

## Two forms

```
cli -c 'show bgp'                       an operator command: text for a person
cli show.routes                         a method: JSON, one object
cli show.rib '{"prefix":"10.30.0.0/24"}' --pretty   a method with parameters
```

An operator command is quoted as one argument. A method takes its
parameters as one JSON object, in single quotes. `--pretty` indents the
JSON. A name the daemon does not answer gets the list of the ones it
does.

## Operator commands

| Command | Prints |
|---|---|
| `show bgp summary` | router ID, AS, and one line per neighbor: state, up time, prefixes received and sent |
| `show bgp` | the Loc-RIB as a table, one line per route |
| `show bgp PREFIX` | the same, for one prefix |
| `show configuration` | the running configuration, as set lines |
| `show configuration candidate` | the candidate configuration, as set lines |
| `clear bgp PEER` | resets the session with PEER, an address |

`--style junos` or `--style iosxr` prints `show bgp` in those styles.
`--style ios` is the default. The styles follow those routers' layout and
are not copies of their output.

## Methods that read

Every page of rows is an envelope: `rows`, `total`, `offset`, `limit`
and `next_offset`. A page holds 500 rows unless `limit` says fewer.
`next_offset` is null on the last page. Pass `offset` to read the next
one. `prefix` reads one prefix instead of a page.

| Method | Answers | Parameters |
|---|---|---|
| `api.info` | the API version, every method name, the event sequence | none |
| `show.status` | router ID, AS, uptime, reflector role, the peers, a summary | none |
| `show.peers` | one row per configured neighbor: state, flaps, last error, prefixes, queues | none |
| `show.routes` | the Loc-RIB, one row per prefix, with its best path | `prefix`, `offset`, `limit` |
| `show.rib` | every path per prefix, and for each one that lost, the step and why | `prefix`, `offset`, `limit` |
| `show.adj_in` | what one peer sent, as received | `peer` (required), `prefix`, `offset`, `limit` |
| `show.adj_out` | what went to one peer, and under `skipped` what did not and why | `peer` (required), `prefix`, `offset`, `limit` |
| `show.fib` | what the daemon put in the kernel table, and what the kernel refused | `prefix`, `offset`, `limit` |
| `show.log` | the daemon's last log lines, oldest first | `count`, default 100 |
| `show.text` | what `-c 'show bgp'` prints, as one JSON string | `style`, `prefix` |
| `show.configuration` | the configuration as set lines | `candidate`, `format` |

```
cli show.peers --pretty
cli show.rib '{"prefix":"10.33.231.0/24"}' --pretty
cli show.adj_in '{"peer":"10.100.14.1","limit":20}' --pretty
cli show.adj_out '{"peer":"10.100.21.1"}' --pretty
cli show.log '{"count":30}' --pretty
```

### One line per route

`cli -c 'show bgp'` is already one line per route. For JSON fields on one
line each, read the rows with Ruby, which every node has:

```
cli show.routes | ruby -rjson -e 'JSON.parse($stdin.read)["rows"].each { |r|
  puts r.values_at("prefix", "next_hop", "as_path", "med", "decided_by").join("  ") }'
```

One line per path, with the step each loser lost at:

```
cli show.rib | ruby -rjson -e 'JSON.parse($stdin.read)["rows"].each { |r| r["paths"].each { |p|
  puts [r["prefix"], p["from"], p["next_hop"], p["best"] ? "best" : "lost at #{p["lost_at"]}"].join("  ") } }'
```

Both read one page. Add `'{"limit":5000}'` after the method name for more.

## Methods that change something

| Method | Does | Parameters |
|---|---|---|
| `peer.clear` | resets one session | `peer` |
| `peer.stop` | ends one session, and keeps it down | `peer` |
| `peer.start` | lets a stopped session come back | `peer` |
| `peer.refresh` | sends a ROUTE-REFRESH, RFC 2918, with the RFC 7313 subtypes | `peer`, `afi`, `safi`, `subtype` |
| `route.originate` | announces prefixes of our own | `prefix` or `prefixes`, `origin`, `as_path`, `med`, `local_pref`, `communities`, `extended_communities`, `large_communities`, `path_id` |
| `route.withdraw` | withdraws prefixes we announced | `prefix` or `prefixes`, `path_id` |
| `peer.specimen` | sends one valid UPDATE by hand, from `BGP::Specimen` | `peer`, `name`, `prefix` or `prefixes`, `next_hop` |
| `peer.fault` | sends one malformed UPDATE by hand, from `BGP::Fault` | `peer`, `case`, `prefix` or `prefixes`, `next_hop` |
| `peer.replay` | sends octets as given, in hex | `peer`, `hex` |
| `peer.resend` | sends the daemon's own answer for every prefix sent by hand | `peer` |

```
cli route.originate '{"prefixes":["10.255.0.0/24"],"med":50}'
cli route.withdraw '{"prefixes":["10.255.0.0/24"]}'
cli peer.refresh '{"peer":"10.100.14.1"}'
cli peer.fault '{"peer":"10.100.14.1","case":"origin_value","prefixes":["10.255.1.0/24"]}'
```

A send by hand is not written into the Adj-RIB-Out, since after it the
daemon cannot know what the peer holds. `show.adj_out` lists those
prefixes under `hand` until the daemon sends them again or `peer.resend`
does.

## The candidate configuration

Changes go into a candidate first, as set lines, and a commit applies
them. Some keys apply live, some bounce a session, and some are refused
because they need a restart. The commit says which.

| Method | Does | Parameters |
|---|---|---|
| `config.load` | adds set lines to the candidate | `lines` |
| `config.replace` | makes the candidate exactly these lines | `lines` |
| `config.changed` | answers whether the candidate differs, true or false | none |
| `config.compare` | the lines the candidate changes | none |
| `config.commit` | checks it, with `check`, or applies it | `check`, `comment` |
| `config.discard` | sets the candidate back to the running one | none |
| `config.history` | the commits, newest first | none |
| `config.rollback` | an older commit as the candidate | `number` |

```
cli -c 'show configuration'
cli config.load '{"lines":["set neighbors 10.100.14.1 hold_time 60"]}'
cli config.compare
cli config.commit '{"check":true}'
cli config.commit '{"comment":"hold time 60"}'
```

## Events

| Method | Does | Parameters |
|---|---|---|
| `events.subscribe` | streams events, one JSON line each, until Ctrl-C | `kinds`, `since` |
| `events.unsubscribe` | ends the stream and keeps the connection | none |

```
cli events.subscribe
cli events.subscribe '{"kinds":["session"]}'
```

## The FIB

A node puts routes in the kernel only when its node file has a `fib:`
block. The node file is the YAML the topology binds into the node, such
as `rr-lab/dual/bgp4rd.yml`, which the node reads at
`/etc/bgp4r/bgp4rd.yml`:

```yaml
rib: true
fib:
  table: 100
```

`table` is required. Routes go into that kernel table, marked `proto
bgp`, and leave it when the daemon stops. Its other keys are `netns`,
`dev` and `proto`. A change to `fib:` needs a restart: stop and start the
lab, or the node.

Two ways to look, which answer different questions:

```
cli show.fib --pretty         what the daemon believes it installed, and what failed
ip route show table 100       what the kernel holds
```

`show.fib` with no `fib:` block answers `"configured": false` and no
rows.

**The kernel refuses a next hop it cannot reach directly.** A reflected
route keeps its NEXT_HOP, so in rr-lab most routes `dual` learns name a
next hop such as 10.100.1.1, which is on no link of `dual`. The kernel
answers `Nexthop has invalid gateway`, and `show.fib` lists each such
prefix under `failed`. The FRR and BIRD nodes avoid this with one static
route for 10.100.0.0/16. A bgp4rd node has no IGP and no static routes,
so it installs only routes whose next hop is on one of its links.

**A prefix the node originates is not installed.** Its NEXT_HOP is the
node's router ID, a placeholder each session replaces with the address
it is sent from, so there is no gateway to install it via. What forwards
to it is the kernel's own route, such as the connected route of an
address on `lo` or a link. `show.fib` lists it under `skipped` with the
reason `originated`.

## More

- `docs/daemon.md`: the control API, the JSON of every answer, and the
  configuration keys.
- `lab/README.md`: the node file keys.
