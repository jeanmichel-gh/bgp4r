# Protocol testing with bgp4r

bgp4r lets a Ruby script act as a BGP peer that says exactly what you
tell it, including things no router would ever send. That makes it a
tool for testing how a router handles both good and bad input.

Every example here was run against the current tree.

## Why bgp4r

A real router is a poor test peer. It validates and normalizes what it
sends, so it cannot produce a bad message on purpose. bgp4r does the
opposite.

* **Every byte is yours.** Any flag, type, length or order can be set.
  Building a message never refuses, and `encode` never checks anything.
* **Three levels of control.** Normal objects for valid messages, header
  overrides for wrong fields, `Attr::Raw` for anything at all.
* **A real session.** `Neighbor` runs the state machine, OPEN,
  capabilities and keepalives, so the router sees a normal peer until the
  bad message arrives.
* **Scripted checks.** Replies come back as decoded Ruby objects.
* **A catalog and a runner.** `BGP::Fault::CATALOG` names the RFC 7606
  cases and `lab/fault_matrix.rb` sends them all to a router.

## Setup

You need Ruby 3.3 or later, the repo, and a router to test.

```
git clone https://github.com/jeanmichel-gh/bgp4r
cd bgp4r
ruby test/run_unit.rb
```

Then you need a router. How you get one depends on your machine, so the
rest of this section splits in two. Everything after it is the same
either way.

### On a Mac with Docker

FRR, BIRD and GoBGP are Linux daemons, so on macOS they run in
containers. The quickest route is the ready made topology, which runs
the whole fault catalog against GoBGP in one command:

```
docker compose -f lab/topologies/fault-matrix/compose.yml up --build \
  --abort-on-container-exit --exit-code-from matrix
```

The annex at the end of this document covers that run in full. To drive
a router by hand instead, start it in a container and point bgp4r at its
address.

One macOS difference worth knowing before you copy a command from the
Linux path below. `lo0` has only 127.0.0.1 on it, so the extra loopback
addresses the Linux examples use do not exist until you add them:

```
sudo ifconfig lo0 alias 127.0.0.2 up     # remove with -alias
```

That is per address and does not survive a reboot, which is the main
reason containers are easier here.

### On a Linux VM

FRR, BIRD and GoBGP are all packaged by Ubuntu and run fine as plain
processes:

```
apt-get install -y frr bird2 gobgpd
```

All of 127.0.0.0/8 is local on Linux, so several routers can run side by
side on 127.0.0.2, 127.0.0.3 and 127.0.0.4 with no setup. That is how
the results later in this document were produced.

`lab/conformance/` has a working config for each, and `lab/README.md`
explains how to run them side by side. The container topology works here
too, if Docker is installed.

## Building messages

Every message and attribute builds three ways: from field values, from a
hash, or from wire bytes.

```ruby
require 'bgp4r'
include BGP

u = Update.new(
  Path_attribute.new(
    Origin.new(:igp),
    As_path.new(100, 200),
    Next_hop.new('192.0.2.2'),
    Communities.new('100:1', :no_export),
    Large_communities.new('64496:1:2')
  ),
  Nlri.new('10.1.0.0/16'))

puts u                              # decoded, with a hex dump per attribute
u.encode.unpack1('H*')              # the exact octets
Update.new(u.to_hash).encode == u.encode
```

Write well known communities as symbols, `:no_export`, or as names in a
string. A string that is neither a name nor `asn:value` raises.

## Crafting bad messages

Three techniques, lowest first.

| Technique | Use it for |
|---|---|
| Leave out or repeat | missing attribute, duplicate, odd order |
| Header overrides | any flags, type code or length |
| `Attr::Raw` | any value octets at all |

### Leave out or repeat

`Path_attribute` keeps attributes in the order given and never removes
duplicates.

```ruby
Path_attribute.new(Origin.new(0), As_path.new(100))              # no NEXT_HOP
Path_attribute.new(Origin.new(0), Origin.new(2), As_path.new(100))
```

### Header overrides

Every attribute takes `flags:`, `type:` and `length:`, either when built
or afterwards with `override`. A length override changes the header
only; the value octets stay as they are. Nothing is checked.

```ruby
Origin.new(:igp, length: 2).to_shex                              # "40010200"
Origin.new(:igp, flags: ATTR::OPTIONAL_TRANSITIVE).to_shex       # "c0010100"
Next_hop.new('10.0.0.1').override(length: 3).to_shex             # "4003030a000001"
```

Flag bits: `ATTR::OPTIONAL` 0x8, `TRANSITIVE` 0x4, `PARTIAL` 0x2,
`EXTENDED_LENGTH` 0x1, as the high nibble of the first octet.

### Attr::Raw

Any flags, type and value octets, including a type bgp4r knows.

```ruby
Attr::Raw.new(ATTR::OPTIONAL_TRANSITIVE, 250, 'hi').to_shex      # "c0fa026869"
Attr::Raw.new(wire_bytes)
Attr::Raw.new(:flags => 0xc, :type => 250, :value => '6869')
```

`partial!` sets the Partial bit on an optional transitive attribute
(RFC 4271 section 5).

### BGP::Fault

The shapes RFC 7606 covers, built from a good attribute. Each returns an
`Attr::Raw`, so it goes out exactly as built.

```ruby
Fault.truncate(Origin.new(0))                 # "400100", value cut to 0 octets
Fault.pad(Multi_exit_disc.new(10))            # "8004050000000a00", one octet too many
Fault.length(Origin.new(0), 20)               # "40011400", header lies
Fault.flags(Origin.new(0), ATTR::OPTIONAL_TRANSITIVE)
Fault.retype(Origin.new(0), 250)
Fault.value(Origin.new(0), 'dead')
Fault.duplicate(Origin.new(0))                # a Path_attribute, the attribute twice
```

## The catalog

`BGP::Fault::CATALOG` holds 18 named cases, each with the RFC 7606
action a receiver should take and the UPDATE error subcode.

```ruby
Fault.catalog.first
# {:name=>:origin_length, :description=>"ORIGIN length not 1",
#  :action=>:treat_as_withdraw, :subcode=>5, :rfc=>"RFC 7606 7.1", :build=>#<Proc>}

Fault.build(:origin_length)        # the attribute, or a Path_attribute
Fault.wire(:origin_length)         # its octets either way
```

| Name | Fault | Expected |
|---|---|---|
| `origin_length` | ORIGIN length not 1 | treat as withdraw |
| `origin_value` | ORIGIN value undefined | treat as withdraw |
| `origin_flags` | ORIGIN flags conflict | treat as withdraw |
| `next_hop_length` | NEXT_HOP length not 4 | treat as withdraw |
| `med_length` | MULTI_EXIT_DISC length not 4 | treat as withdraw |
| `as_path_segment` | AS_PATH segment overruns | treat as withdraw |
| `atomic_length` | ATOMIC_AGGREGATE length not 0 | attribute discard |
| `aggregator_length` | AGGREGATOR length wrong | attribute discard |
| `community_length` | COMMUNITIES length not a multiple of 4 | treat as withdraw |
| `unknown_wellknown` | unrecognized well known type | session reset |
| `attr_overrun` | length past the attribute list | treat as withdraw |
| `duplicate_attr` | attribute sent twice | attribute discard |
| `duplicate_mp_reach` | MP_REACH_NLRI sent twice | session reset |

The last five are attributes that carry their own TLVs, where the
framing is what a receiver gets wrong. Each cuts the nesting at a
different level.

| Name | Fault | Expected |
|---|---|---|
| `prefix_sid_tlv` | Prefix-SID TLV overruns the attribute | attribute discard |
| `prefix_sid_label_index` | Label-Index TLV length not 7 | attribute discard |
| `pmsi_length` | PMSI_TUNNEL shorter than its 5 octet fixed part | treat as withdraw |
| `tunnel_encap_tlv` | tunnel TLV overruns the attribute | treat as withdraw |
| `tunnel_encap_sub_tlv` | sub-TLV overruns its TLV | treat as withdraw |

The last one is worth a closer look, because it is the only case where
the fault is one level down. RFC 9012 section 13 says the final octet
of a TLV must also be the final octet of its final sub-TLV, so a TLV
length of 4 in front of a 12 octet sub-TLV is malformed:

```ruby
Tunnel_encap.new(Tunnel_encap::Tunnel.new(:vxlan,
  Tunnel_encap::Egress_endpoint.new('10.0.0.1')).length!(4))
# c0171000080004060a0000000000010a000001
```

`Tunnel#length!` writes a TLV length that is not the real one. Nothing
else in the catalog needs it, because every other fault lives in the
attribute header or its value.

## Receiving: policies and findings

Parsing checks what it reads, against RFC 7606. The policy says what
happens then. Building and encoding are never checked, whatever the
policy.

| Policy | What it does |
|---|---|
| `:lenient` | the default: decode as before, list problems in `errors` |
| `:strict` | raise `Malformed_attribute` with the strongest finding |
| `:raw` | decode headers only, so `encode` gives back what arrived |

```ruby
pa = Path_attribute.new(wire_bytes, :as4byte => true)
pa.errors                 # [#<Attr::Finding type=1 subcode=4 action=:treat_as_withdraw ...>]
pa.action                 # :treat_as_withdraw, the strongest (RFC 7606 section 3 (h))

f = pa.errors.first
f.type                    # 1
f.subcode                 # 4, the UPDATE error subcode (RFC 4271 section 6.3)
f.reason                  # "flags 0xc0, the Optional and Transitive bits must be 0x40 ..."
f.notification            # a Notification, code 3, ready to send
```

`errors` means what the peer got wrong. An attribute bgp4r itself
cannot decode, such as a correct MP_REACH for an address family it has
no code for, is not one of those: it is kept as an `Attr::Raw`, its
octets round trip, and it is reported in `undecoded` instead. RFC 7606
section 7 says attribute by attribute what makes one malformed, and a
reader's missing code is on none of those lists, so `:strict` never
raises on one.

```ruby
pa = Path_attribute.new(evpn_mp_reach, :policy => :strict)   # does not raise
pa.errors                 # []
g = pa.undecoded.first    # an Attr::Gap
g.type                    # 14
g.reason                  # "cannot parse nexthop for safi 70"
g.error                   # the exception class the decoder raised
g.attribute               # the Attr::Raw holding the octets
```

An attribute can be in both lists. The decoder raising does not say
whether the attribute is bgp4r's gap or the peer's fault, so bgp4r does
not guess: the checks run on the octets either way, and anything really
wrong with them is a finding in `errors`.

Strict mode raises after the whole list is parsed, so the error carries
every finding:

```ruby
begin
  Path_attribute.new(wire_bytes, :as4byte => true, :policy => :strict)
rescue Malformed_attribute => e
  e.action                # :session_reset
  e.subcode               # 2
  e.findings              # all of them
end
```

`validate` runs the same checks on a message you built, without raising.
It also reports an AS number above 65535 in a 2 octet encoding.

```ruby
Path_attribute.new(Origin.new(:igp, length: 2)).validate
# [#<Attr::Finding type=1 subcode=5 action=:treat_as_withdraw ...>]
```

A `Neighbor` takes the policy for the session:

```ruby
peer = Neighbor.new(:my_as => 65001, :policy => :strict, ...)
```

With `:strict`, a received UPDATE carrying a malformed attribute is not
passed on. Observers get the `Malformed_attribute` instead, and if its
action is a session reset, bgp4r sends the NOTIFICATION and stops.

## Sending to a router

bgp4r listens and the router connects, which works with any
implementation that can be told to peer with us.

```ruby
require 'timeout'

class Inbox
  def initialize; @q = Queue.new; end
  def update(msg); @q << msg; end
  def wait_for(klass, secs = 5)
    Timeout.timeout(secs) { loop { m = @q.pop; return m if m.is_a?(klass) } }
  rescue Timeout::Error
    nil
  end
end

server = TCPServer.new('127.0.0.1', 179)
peer = Neighbor.new(4, 65001, 180, '10.0.0.1', '127.0.0.2', '127.0.0.1')
peer.capability :as4_byte
peer.capability :mbgp, :ipv4, :unicast
inbox = Inbox.new
peer.add_observer inbox
Thread.new { loop { peer.start_session(server.accept) } }

peer.wait_for_state(:Established, 40)
peer.send_message Update.new(
  Path_attribute.new(Fault.build(:origin_length), As_path.new(65001),
                     Next_hop.new('10.0.0.1')),
  Nlri.new('203.0.113.0/24'))

notification = inbox.wait_for(Notification, 4)
peer.is_established?
```

Three outcomes to tell apart:

| RFC 7606 action | What you see |
|---|---|
| session reset | a NOTIFICATION, then the session goes Idle |
| treat as withdraw | session stays up, the route is not installed |
| attribute discard | session stays up, the route is installed without it |

The first is visible from one session. The other two need the router to
say whether it installed the route, since both keep the session up.

## The fault matrix

`lab/fault_matrix.rb` does all of the above for every catalog case and
prints a table.

```
ruby lab/fault_matrix.rb --peer 127.0.0.2 --peer-as 65002 \
  --rib-command 'gobgp global rib' --json gobgp.json
```

```
FAULT               EXPECTED (RFC 7606)     WHAT IT DID         ROUTE       VERDICT
origin_length       treat_as_withdraw       kept the session    dropped     agrees
...
unknown_wellknown   session_reset           reset 3/2           -           agrees
duplicate_mp_reach  session_reset           reset 3/1           -           agrees
```

`--rib-command` is what tells treat as withdraw from attribute discard.
The runner sends a clean route first and checks the router installed it;
if it did not, those rows read `session only` rather than being scored
against a probe that cannot answer.

Exit status is 0 when every answer agrees with the catalog.

## What three implementations do

Run as native processes on loopback, all three at once. The GoBGP column
was measured on 3.23.0, and 4.10.0 gives the same 18 answers: the
containerized run asserts every row and passes on both.

| | GoBGP 3.23.0 and 4.10.0 | FRR 8.4.4 | BIRD 2.14 |
|---|---|---|---|
| treat as withdraw cases | agrees | resets, 3/10 | keeps the session |
| attribute discard cases | agrees | agrees | keeps the session |
| unrecognized well known | reset 3/2 | reset 3/10 | keeps the session |
| duplicate MP_REACH | reset 3/1 | reset 3/1 | reset 3/1 |
| Prefix-SID TLV overruns | agrees | agrees | keeps the session |
| Label-Index length not 7 | no check | agrees | keeps the session |
| PMSI_TUNNEL too short | agrees | resets, 3/10 | keeps the session |
| tunnel TLV overruns | installs the route | installs the route | keeps the session |
| sub-TLV overruns its TLV | discards the attribute | installs the route | keeps the session |

GoBGP agrees on 16 of the 18.

FRR identifies each malformed attribute and says "treating as
withdrawal" in its log, then its withdraw path fails to parse the NLRI
and it resets with Invalid Network Field. The two attribute discard
cases keep both session and route, so it parses our NLRI correctly on
the normal path. This is the Ubuntu 24.04 build; current FRR is 10.x, so
check a current build before reporting it anywhere.

### The TLV carrying attributes

These five cases are the interesting ones, and they need the router's
own log, not just the verdict column.

Both GoBGP and FRR see the malformed tunnel TLV and then do something
weaker than RFC 9012 section 13 asks. The section is a MUST: the final
octet of a TLV must also be the final octet of its final sub-TLV, and a
TLV that breaks that is malformed, treat as withdraw. GoBGP logs "Not
all TunnelEncapSubTLV bytes available" and discards the attribute. FRR
logs `bgp_attr_encap: tlv_length(4) != length(12)` and keeps the route.
Neither withdraws. Two independent stacks landing in the same place is
worth knowing before reading it as a bug in either.

On the Prefix-SID Label-Index length they split. FRR logs "Prefix SID
label index length is 6 instead of 7". GoBGP logs nothing and installs
the route, so it never checks the length RFC 8669 section 3.1 fixes at
7. The verdict column scores GoBGP as agreeing here, which is the trap
below: for an attribute discard case, an installed route looks the same
whether the router discarded a bad attribute or never looked at it.

The PMSI result is confounded. FRR logs both "Bad PMSI tunnel attribute
length 4" and that the attribute is not one it knows how to handle,
because the fault rides an IPv4 unicast route and PMSI_TUNNEL belongs
to the MVPN SAFIs. Either reason alone would produce the withdraw.
Carry that fault on an MVPN route to separate them.

BIRD keeps the session on an unrecognized well known attribute, where
RFC 4271 section 6.3 asks for a reset. That may be deliberate
robustness. Its rows cannot distinguish withdraw from discard here,
because it rejects any route whose next hop does not resolve, and
nothing resolves over a loopback session.

Two things worth knowing when reading any of these results:

* A verdict can be right for the wrong reason. The duplicate MP_REACH
  case counts as agreeing whenever the session resets, so a router that
  rejects the address family rather than the duplicate still scores a
  pass. An attribute discard case counts as agreeing whenever the route
  is installed, so a router that never validated the attribute scores a
  pass too. Read the router's own log when a result matters.
* Run one router at a time, or make sure the harness is talking to the
  one you think. Several routers on a host all dial the same port.

## Writing a test

```ruby
require 'test/unit'
require 'bgp4r'

class OriginLengthTest < Test::Unit::TestCase
  include BGP

  # RFC 7606 section 7.1: ORIGIN with a length other than 1 is
  # treat-as-withdraw, so the session must stay up.
  def test_origin_length_keeps_the_session
    # ... establish, as above ...
    @peer.send_message Update.new(
      Path_attribute.new(Fault.build(:origin_length), As_path.new(65001),
                         Next_hop.new('10.0.0.1')),
      Nlri.new('198.51.100.0/24'))

    notification = @inbox.wait_for(Notification, 3)
    assert_nil notification, "router reset: #{notification && notification.to_string}"
    assert @peer.is_established?
  end
end
```

`examples/unit-testing/` has working two peer tests that predate the
fault layer and still show the shape.

## Annex: running the fault matrix in containers

Everything above runs the matrix by hand against a router you started
yourself. `lab/topologies/fault-matrix` does the same run in one
command, with GoBGP as the router, so it can go in CI.

```
docker compose -f lab/topologies/fault-matrix/compose.yml up --build \
  --abort-on-container-exit --exit-code-from matrix
echo "exit: $?"
```

The matrix runs once and exits, which is why the run is in the
foreground with `--abort-on-container-exit`. To read the results as
JSON, copy them out after the run and take the topology down:

```
docker compose -f lab/topologies/fault-matrix/compose.yml cp \
  matrix:/tmp/fault-matrix.json .
docker compose -f lab/topologies/fault-matrix/compose.yml down
```

The exit status is 1, and the run is still correct. The matrix exits
non-zero on any disagreement with the catalog, and against GoBGP two
cases disagree: see the divergence below. Read the table, or the JSON,
rather than the status.

The addresses are fixed, because `lab/fault_matrix.rb` only listens and
hangs up on any peer but the one given to `--peer`. The matrix is AS
65001 on 10.30.0.1 and the router is AS 65002 on 10.30.0.2.

The matrix reads the router's RIB, so it tells treat-as-withdraw from
attribute-discard here as well as by hand. It passes

```
--rib-command 'gobgp -u 10.30.0.2 global rib'
```

and the client comes from the Dockerfile's `conformance` stage, which is
the `speaker` stage plus `/usr/local/bin/gobgp` copied straight out of
the router image. Nothing is downloaded, and the client is always the
same version as the router it queries, because the topology passes its
own `GOBGP_IMAGE` to the build. The client talks gRPC on port 50051 to
whatever host `-u` names, so there is no Docker socket to mount and no
shell needed in the router.

Two variables are optional:

| Variable | What it does |
|---|---|
| `GOBGP_IMAGE` | the router image, to pin a version or swap the router |
| `FAULT_SETTLE` | seconds to wait after each fault, 2 by default |

The default router image is community built and has a native
`linux/arm64` build, so it runs on an Apple Silicon Mac without
emulation. The `osrg/gobgp` image on Docker Hub is amd64 only and years
stale, so avoid it there. The image reads `/config/gobgp.toml` and
carries both the daemon and the `gobgp` client, which is why the
topology mounts its folder at `/config` and does not override the
command.

The pin is 4.10.0. It was 3.23.0 for a while, because `gobgp.toml` was
written against 3.23 and the router was pinned to match the config. That
turned out to be unnecessary, and the reason it looked necessary is
worth knowing, because it was a bug in bgp4r rather than in either the
config or the router.

GoBGP 4 reads the config unchanged. Every key is still in the 4.x config
structs under the same `mapstructure` name, and 4.x registers
`mapstructure.StringToNetIPAddrHookFunc`, so the address fields still
decode from TOML strings even though their Go type is now `netip.Addr`.

What did break on 4.10 was that bgp4r read only the first capability out
of a Capabilities optional parameter. RFC 5492 section 4 allows several,
and GoBGP packs them that way, so bgp4r missed the 4-octet AS
capability, kept the 2-octet default, and sent an AS_PATH that GoBGP
rejected with `seg length is short`. Every UPDATE became a withdraw
before the attribute under test was ever read, so the run measured that
bug rather than the router. It is fixed, and the lesson is in the shape
of the failure: a fault matrix that cannot establish a correct session
first will produce a full table of confident nonsense.

Going back to 3.23, or forward to another tag, needs no edit:

```
GOBGP_IMAGE=jauderho/gobgp:v3.23.0 docker compose \
  -f lab/topologies/fault-matrix/compose.yml up --build \
  --abort-on-container-exit --exit-code-from matrix
```

To check that a tag has an arm64 build before pulling it:

```
docker buildx imagetools inspect jauderho/gobgp:v4.10.0
```

`manifest unknown` means the tag is not there. Changing the version moves
the client with the router, since one variable feeds both. Both 3.23 and
4.10 give the same 18 answers, so the results in the next section hold
for either. The two session reset cases follow from RFC 4271 section 6.3
and should hold on any conformant version, while the route level
verdicts can move between releases, which is what the test is there to
notice.

A full run is roughly two to four minutes at the default settle. Raise
`FAULT_SETTLE` if a slower machine reports faults with no session.

### The test

```
LAB_REQUIRE_DOCKER=1 ruby -I. test/functional/lab/fault_matrix_test.rb
```

`test/functional/lab/fault_matrix_test.rb` runs the topology and asserts
two layers.

The session level answers first: the two cases that must reset do reset,
with NOTIFICATION subcodes 2 and 1, and no other case resets. It also
fails if any fault got no session at all, because that means the harness
lost the router rather than that the router answered. This layer is the
router agnostic one. It follows from RFC 4271 section 6.3 and RFC 7606,
it holds for any router that implements them, and no assertion in it
names a router specific command.

Then the route level answers, which are the part the RIB adds: every
treat-as-withdraw case dropped the route, and every attribute-discard
case kept it. The expectation comes from each catalog entry's own
`action`, not from a list in the test, so a case added to the catalog is
covered the day it lands. One assertion comes first: that the RIB
answered at all. The matrix sends a plain route of its own before the
first fault and scores routes only after seeing the router install it,
so a failed baseline makes every route column meaningless, and the test
says that instead of reading them.

Without Docker the test is omitted, unless `LAB_REQUIRE_DOCKER=1` is
set, as in CI.

### The GoBGP tunnel encapsulation divergence

The run exits 1, and both the topology and the test expect that. Two
cases disagree with the catalog, `tunnel_encap_tlv` and
`tunnel_encap_sub_tlv`, and the test asserts the disagreement is exactly
those two.

RFC 9012 section 13 is a MUST: the final octet of a tunnel TLV must also
be the final octet of its last sub-TLV, and a TLV that breaks that is
malformed, treat as withdraw. GoBGP sees the malformed TLV, logs "Not
all TunnelEncapSubTLV bytes available", discards the attribute and
installs the route. bgp4r is right here and the router is not, so the
catalog keeps asking for treat-as-withdraw and the test records what the
router actually does, naming it as a divergence where it asserts it.

This is not an old bug since fixed. 3.23 does it, and so does 4.10, so
it is present in the current release and worth reporting upstream. It is
reproducible in one command.

That is why the test asserts per route outcomes rather than the exit
status. If either case ever reports the route dropped, the router
improved: take the name out of `TUNNEL_ENCAP` in the test, so it is
derived with the other treat-as-withdraw cases, and update the GoBGP
rows above.

### Two things worth knowing

The matrix binds TCP 179 as a non-root user. That works because Docker
sets `net.ipv4.ip_unprivileged_port_start=0` in a container's own
network namespace. With `--network host` the host setting applies
instead, and the bind fails.

The results are copied out of a container that has already exited.
`docker compose cp` resolves the service to its container either way, so
it does not matter that the matrix finished.
