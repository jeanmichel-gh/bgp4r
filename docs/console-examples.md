# Console examples

Seven sessions to type in the VM, from the smallest to a whole lab,
and then generated routes.
Each one says what to start, what to type, and what comes back.
`docs/console.md` explains the commands and the defaults behind them;
this document is the practice.

Run everything from a checkout, so `ruby -I.` finds the library.
Every example uses loopback addresses and port 1179, so nothing needs
root. Logs go to files under `/tmp`, so each prompt stays readable.

The lines after `# =>` are what the prompt answers. Three of the
seven, 1, 2 and 7, are run from this document by
`test/functional/console_examples_test.rb`, which types each block
into the program and compares every `# =>` with what came back. The
other four need several terminals, so
`test/unit/console_examples_doc_test.rb` checks their verbs, flags and
node files instead. Change a line here and one of those two fails.

## 1. No session

The library at a prompt, with no peer at all. Good for building
messages and reading what a fault case does.

```sh
ruby -I. exe/bgp4r console -l /tmp/console.log
```

<!-- example: no-session -->
```ruby
specimens.include?(:large_communities)   # => true
faults.include?(:origin_value)           # => true
Specimen.build(:large_communities).class # => BGP::Large_communities
pa = Path_attribute.new(Fault.wire(:origin_value))
pa.errors.collect(&:reason)              # => ["undefined ORIGIN value 3 (RFC 7606 section 7.1)"]
u = Fault.update(:origin_value, my_as: 65001, next_hop: '10.0.0.1', prefixes: ['10.3.0.0/24'])
i = Update::Info.new(true, :lenient)
Update.new(u.encode(i).is_packed, i).path_attribute.errors.size # => 1
exit
```

`Fault.wire` is the attribute alone, so it is read with
`Path_attribute.new`. `Fault.update` is a whole UPDATE; encode and read
it with the same `Update::Info`, or the AS width disagrees and the
AS_PATH reports a second error that is not the fault's.

## 2. Back to back

Two bgp4r speakers in one process, over loopback. Our side is AS
65001, `remote` is the console of the other side, AS 65002.

```sh
ruby -I. exe/bgp4r console --back-to-back -l /tmp/b2b.log
```

<!-- example: back-to-back -->
```ruby
announce '10.9.0.0/24', med: 5, communities: ['65001:100']
remote.last.nlri.to_ary                       # => ["10.9.0.0/24"]
remote.last.path_attribute[:med].to_i         # => 5
specimen :large_communities, '10.30.0.0/24'
remote.last.path_attribute.errors.size        # => 0
fault :origin_value, '10.3.0.0/24'
remote.last.path_attribute.errors.collect(&:reason) # => ["undefined ORIGIN value 3 (RFC 7606 section 7.1)"]
remote.announce '10.50.0.0/24', med: 7
last.nlri.to_ary                              # => ["10.50.0.0/24"]
withdraw '10.9.0.0/24'
remote.last.withdrawn.to_ary                  # => ["10.9.0.0/24"]
sent
remote.received 3
remote.received(:update).size                 # => 4
remote.received(:update).messages.last.withdrawn.to_ary # => ["10.9.0.0/24"]
exit
```

`received` answers a list, oldest first, with keepalives left out, so
the four UPDATEs our side sent are the four rows. `received :all`
puts the keepalives back. `exit` stops both sides. The remote side logs to `/tmp/b2b-remote.log`.

## 3. Two consoles

Two prompts, two terminals, one session between them. Terminal A
listens and terminal B dials.

```sh
ruby -I. exe/bgp4r console -l /tmp/a.log     # terminal A
ruby -I. exe/bgp4r console -l /tmp/b.log     # terminal B
```

In A:

<!-- example: two-consoles-a -->
```ruby
listen '127.0.0.2', remote_as: 65002, port: 1179, local_address: '127.0.0.1'
```

In B, before A's `listen` times out:

<!-- example: two-consoles-b -->
```ruby
connect '127.0.0.1', remote_as: 65001, local_as: 65002, router_id: '10.0.0.2', port: 1179, local_address: '127.0.0.2'
announce '10.20.0.0/24', as_path: [65099]
```

Back in A:

<!-- example: two-consoles-a2 -->
```ruby
received
last.path_attribute[:as_path].as_path        # => "65002 65099"
received :all
received :keepalive
received 1, :update
received peer: '127.0.0.2'
last :all
shutdown
peers
no_shutdown
clear
```

Back in B, after the `clear`:

<!-- example: two-consoles-b2 -->
```ruby
received :notification
last(:notification).to_s
```

For `listen`, `port:` and `local_address:` are our own. For `connect`
they are the far end's. `shutdown` sends Cease 6/2 and the session
stays down; `no_shutdown` lets it come back; `clear` sends Cease 6/4
and it comes back on its own.

`received` leaves keepalives out. `received :all` puts them back, and a
kind such as `:keepalive` or `:notification` shows only that kind. A
count and a kind go in either order. `peer:` keeps one peer's rows.
`last` takes a kind the same way, so `last :all` can answer a
keepalive and `last` alone cannot. B's `received :notification` holds
the 6/2 from `shutdown` and the 6/4 from `clear`, and `last` reads the
6/4.

## 4. The injector with a prompt

`bgp4r sim` with its HTTP API and a prompt on the same Injector.

Save this as `/tmp/inj.yml`:

<!-- node: sim -->
```yaml
router_id: 10.255.10.1
as: 65010
local_address: 127.0.0.2
api: 127.0.0.1:8080
neighbors:
  - address: 127.0.0.1
    as: 65000
    port: 1179
    connect: true
    retry: 1
```

Terminal A is a console that listens for it:

<!-- example: sim-a -->
```ruby
listen '127.0.0.2', remote_as: 65010, local_as: 65000, port: 1179, local_address: '127.0.0.1'
```

Terminal B is the injector:

```sh
ruby -I. exe/bgp4r sim /tmp/inj.yml --interact -l /tmp/sim.log
```

<!-- example: sim-b -->
```ruby
peers
announce '10.1.0.0/24', med: 100
fault :med_length, '10.3.0.0/24'
```

Terminal C reads and drives the same injector over HTTP. A POST needs
the header `X-BGP4R: routescope`; any other value is refused.

```sh
curl 127.0.0.1:8080/api/status
curl -X POST -H 'X-BGP4R: routescope' -d '{"prefixes":["10.2.0.0/24"]}' 127.0.0.1:8080/api/announce
curl 127.0.0.1:8080/api/sent
```

## 5. routegen with a prompt

A generated range, then more at the prompt. Terminal A listens as in
example 4. Terminal B:

```sh
ruby -I. exe/bgp4r routegen --peer 127.0.0.1 --peer-as 65000 --port 1179 --local-address 127.0.0.2 --my-as 65010 --count 1000 --per-update 100 --interact
```

<!-- example: routegen -->
```ruby
act 'announce', 'generate' => {'start' => '12.0.0.0/24', 'count' => 5000, 'per_update' => 200}
sent
act 'withdraw', 'generate' => {'start' => '12.0.0.0/24', 'count' => 5000, 'per_update' => 200}
sent
```

`sent` counts a generated range rather than listing it, so a withdrawal
regenerates the prefixes instead of reading a list back.

## 6. A daemon lab

`bgp4rd` as a router between two consoles: `up1` in AS 65010 sends a
route, `rtr` in AS 65000 passes it on to `dn1` in AS 65020.

Save this as `/tmp/rtr.yml`:

<!-- node: daemon -->
```yaml
router_id: 10.255.0.1
as: 65000
listen_address: 127.0.0.1
port: 1179
neighbors:
  - address: 127.0.0.2
    as: 65010
    connect: false
    description: up1
  - address: 127.0.0.3
    as: 65020
    connect: false
    description: dn1
export: {}
mark:
  large_communities: ['65000:1:1']
```

Terminal A is the daemon:

```sh
ruby -I. exe/bgp4rd -f /tmp/rtr.yml -s /tmp/rtr.sock -l /tmp/rtr.log --interact
```

Terminal B is `up1`, and it announces once it is up:

```sh
ruby -I. exe/bgp4r console --peer 127.0.0.1 --peer-as 65000 --port 1179 --local-address 127.0.0.2 --my-as 65010 --id 10.255.10.1 -l /tmp/up1.log
```

<!-- example: daemon-up1 -->
```ruby
announce '10.10.0.0/24'
```

Terminal C is `dn1`:

```sh
ruby -I. exe/bgp4r console --peer 127.0.0.1 --peer-as 65000 --port 1179 --local-address 127.0.0.3 --my-as 65020 --id 10.255.20.1 -l /tmp/dn1.log
```

Back in A, read the table and make a route by hand:

<!-- example: daemon-rtr -->
```ruby
peers
why '10.10.0.0/24'
rib
originate '10.255.0.0/24', communities: ['65000:7']
adj_out '127.0.0.3'
specimen :large_communities, '10.30.0.0/24', peer: '127.0.0.3'
fault :origin_value, '10.10.0.0/24', peer: '127.0.0.3'
```

In C, the fault arrived as a fault:

<!-- example: daemon-dn1 -->
```ruby
last.path_attribute.errors.collect(&:reason) # => ["undefined ORIGIN value 3 (RFC 7606 section 7.1)"]
```

In A again. `adj_out` now lists what was sent by hand, under "sent by
hand, state at peer unknown:", and `peers` counts it. `resend` puts the
daemon's own answer back: 10.10.0.0/24 is sent again and 10.30.0.0/24,
which the daemon never held, is withdrawn.

<!-- example: daemon-rtr2 -->
```ruby
adj_out '127.0.0.3'
peers
resend '127.0.0.3'
ship Update.new(Path_attribute.new(Origin.new(0), As_path.new(65000), Next_hop.new('127.0.0.1')), Nlri.new('10.40.0.0/24')), peer: '127.0.0.3'
adj_out '127.0.0.3'
clear '127.0.0.3'
peers
withdraw '10.255.0.0/24'
withdraw '10.255.0.0/24'
```

The second `withdraw` answers `not_held`. A cleared session also
clears the list of what was sent by hand.

Terminal D asks the same daemon from outside, with the client:

```sh
ruby -I. exe/bgp4r-cli -s /tmp/rtr.sock -c 'show bgp summary'
ruby -I. exe/bgp4r-cli -s /tmp/rtr.sock show.adj_out '{"peer":"127.0.0.3"}' --pretty
ruby -I. exe/bgp4r-cli -s /tmp/rtr.sock peer.fault '{"peer":"127.0.0.3","case":"origin_value","prefixes":["10.10.0.0/24"]}'
ruby -I. exe/bgp4r-cli -s /tmp/rtr.sock show.peers --pretty
ruby -I. exe/bgp4r-cli -s /tmp/rtr.sock peer.resend '{"peer":"127.0.0.3"}'
```

`exit` in A sends Cease 6/2 to each peer and stops the daemon.

## 7. Generated routes

A `BGP::Gen` spec at the prompt, back to back, from the first route to
the last withdrawal. `docs/route-generation.md` is the spec language.
`plan` says what a spec would send and sends nothing. `announce spec:`
sends it, and `remote.received` is what arrived.

```sh
ruby -I. exe/bgp4r console --back-to-back -l /tmp/gen.log
```

<!-- example: generated -->
```ruby
s = { family: 'unicast', start: '10.100.0.0/24', count: 1000, per_update: 100, group: 100, attributes: { med: { cycle: [10, 20] } } }
pl = plan spec: s, limit: 3
pl.total                                          # => 1000
pl.first['as_path']                               # => [65001]
pl.first['next_hop']                              # => "127.0.0.1"
plan(spec: s, offset: 999, limit: 1).first['med'] # => 20
announce spec: s
remote.received(100, :update).size                # => 10
remote.received(100, :update).prefixes            # => 1000
remote.last.path_attribute[:med].to_i             # => 20
c = { events: 20, withdraw: 0.25, seed: 3, attributes: { med: { step: { start: 100, by: 1 } } } }
plan(spec: s, churn: c).total                     # => 992
announce spec: s, churn: c
remote.received(100, :update).size                # => 30
remote.received(20, :update).withdrawn            # => 8
withdraw spec: s
remote.received(10, :update).withdrawn            # => 1000
v = { family: 'vpn', start: '10.200.0.0/24', count: 4, vrfs: 2, rd: '65001:1', label: 100, route_target: '65001:1' }
plan spec: v
announce spec: v
remote.received(2, :update).prefixes              # => 8
remote.last.path_attribute[:mp_reach].nlris.size  # => 4
sent
exit
```

What each step shows:

* **The spec.** 1000 routes, 100 to a message. `group: 100` keeps 100
  routes on one attribute set, and the MED cycles per group: 10, 20, 10,
  and so on. A MED that changed on every route would send 1000
  messages, since an UPDATE holds one attribute set.
* **`plan`.** It prints the total and then one line per row. It shows
  20 rows unless `limit:` says otherwise, and `offset:` pages through
  the rest. The rows have this session's rules in them: our AS in front
  of the AS_PATH, since the session is eBGP, and our address as the next
  hop, since the spec gives none. Route 1000 is in the tenth group, so
  its MED is 20.
* **`announce spec:`.** It answers once the feed has gone out. The far
  side got 10 UPDATEs carrying 1000 prefixes, and the last one carries
  MED 20, as the plan said.
* **The churn.** 20 changes to routes the spec announced, one UPDATE
  each. A quarter are withdrawals, and the rest announce a route again
  with the MED counting up from 100. With `churn:`, `plan` answers the
  routes held afterwards, 992. With seed 3, 8 of the 20 events are
  withdrawals. Change the seed and the picks change. Keep it and they
  do not.
* **`withdraw spec:`.** It regenerates the 1000 prefixes and withdraws
  them all, 100 to a message. That includes the 8 the churn already
  withdrew, which is harmless.
* **A second family.** A VPN spec of 4 prefixes in each of 2 VRFs. Each
  VRF has its own Route Distinguisher and route target, so its own
  attribute set, so its own message. `plan` lists all 8 rows.
* **`sent`.** The injector's count of everything that went out.

`received` keeps the last 200 messages, so check a large feed with
`sent` or with the router's own count, and use a small one at the
prompt. `plan` answers what `POST /api/plan` answers on `bgp4r sim`,
with the same spec in JSON:

```sh
curl -X POST -H 'X-BGP4R: routescope' -d '{"spec":{"family":"unicast","start":"10.100.0.0/24","count":1000}}' 127.0.0.1:8080/api/plan
```

Any family in `docs/route-generation.md` section 6 works the same way.
Both sides of `--back-to-back` offer every family the library has.
