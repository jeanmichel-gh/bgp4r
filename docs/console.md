# The console: `bgp4r routegen --interact`

An irb prompt on a live BGP session, for playing with the library by
hand while developing and testing. This document explains what the
command does from the flags to the prompt, which defaults fill in what
the flags leave out, and what the router at the other end has to be
configured with. `docs/daemon.md`'s console section is the short form,
and `bgp/sim/console.rb` is the code.

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
`notification 6, 2` first if the router should see a Cease with
Administrative Shutdown.

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
* `test/functional/console_test.rb` runs the verbs over a loopback
  session, then runs `bgp4r routegen --interact` as a program with
  lines on its standard input, the way a person types them.
