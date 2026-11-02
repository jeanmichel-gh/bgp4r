# add-path

ADD-PATH, RFC 7911: one prefix, two paths, and what three
implementations make of it.

This folder is the port of `test/functional/lab/add_path_gobgp_test.rb`
to a lab plus scenarios. The test stays: it runs in CI, in 35 seconds,
with no Docker. What the lab adds is the part that needs more than one
receiver and the part that needs an action after the session is up.

## Why this feature

bgp4r's own history. The ADD-PATH Send and Receive fields were
**inverted for years**, and what let them survive was behaviour: every
add-path test ran bgp4r against bgp4r, where both ends invert the field
and the error cancels, so the session came up and the paths arrived
either way. It was found by asking a real router what it read.

So this is the feature where a second implementation is not a
nice-to-have, and a console that shows both halves of a negotiated
capability side by side is that check made visible rather than
remembered.

## The nodes

| Node | AS | Address | What it is |
|---|---|---|---|
| `sim` | 65001 | 10.40.0.1 | bgp4r. Sends two paths for `198.51.100.0/24`, identifiers 7 and 9. Dials both receivers. |
| `gobgp` | 65002 | 10.40.0.2 | GoBGP. Reports how many paths it holds and which is best. |
| `peer` | 65003 | 10.40.0.3 | bgp4r. Reports which Path Identifiers arrived. |

**Two receivers, and the reason is measured.** GoBGP's `global rib -j`
has no identifier key at all for a received path: its `nlri` is
`{"prefix": "198.51.100.0/24"}` and nothing else. It keeps the two paths
apart internally and reports only their attributes. So GoBGP answers
"how many paths" and bgp4r answers "which identifiers", and neither
answers both. A lab with one receiver can assert half of RFC 7911.

Measured against gobgpd 3.23.0 on 2026-11-01.

## Run it

```
docker compose -f lab/topologies/add-path/compose.yml up -d --build
docker compose -f lab/topologies/add-path/compose.yml exec gobgp gobgp global rib -j
docker compose -f lab/topologies/add-path/compose.yml exec peer cat /tmp/bgp4r-state.json
docker compose -f lab/topologies/add-path/compose.yml down
```

`LAB_LOG_LEVEL=debug` prints every message decoded, which for this
topology is where the Path Identifiers are visible on the wire.

What GoBGP should say: two paths for `198.51.100.0/24`, next hops
`10.40.0.7` and `10.40.0.9`, the first `best` because RFC 4271 section
9.1.2.2 a) prefers the shorter AS_PATH.

What `peer` should say, under `neighbors` then `10.40.0.1`:

```json
"received": { "ID=7, 198.51.100.0/24": { "next_hop": "10.40.0.7", "as_path": "65001 65010" },
              "ID=9, 198.51.100.0/24": { "next_hop": "10.40.0.9", "as_path": "65001 65011 65012" } },
"peer_capabilities": [ { "name": "Add_path", "code": 69,
                         "capability": { "families": [ { "afi": 1, "safi": 1, "send_recv": 3 } ] } } ]
```

`send_recv` 3 is RFC 7911 section 4's field value, and the values say
what the **sender** of the capability can do. So reading 3 from `sim` is
how `peer` says `sim` means to send several paths, which is the half
bgp4r could not tell itself.

## The scenarios

Three, and only one of them runs on what exists today. That split is the
most useful thing this port produced.

| Scenario | Ported from | Runs today |
|---|---|---|
| `two-paths.yml` | `test_gobgp_holds_both_paths_we_send_for_one_prefix` | yes, once routescope has a `bgp4r` driver |
| `withdraw-one-path.yml` | `test_withdrawing_one_path_by_its_identifier_leaves_the_other` | no, needs the injector |
| `unnegotiated-path-id.yml` | nothing: the lab's own case | no, needs the injector |

The first needs nothing of bgp4r that is not here: the two paths come
out of `sim.yml`, so the scenario only waits and reads. Verified against
gobgpd 3.23.0 driven by `lab/speaker.rb` from a node file.

The other two need an action taken after the session is up, and
`lab/speaker.rb` has none: its announce blocks are sent once at
Established and there is nothing afterwards. So they need the
`bgp4r-sim` node kind of `docs/routescope-labs.md` section 9.

**The third one is the argument for the lab.** A Path Identifier on a
session that negotiated none is a corrupt UPDATE, and the two
implementations disagree about the same octets:

| | What it does with the same octets |
|---|---|
| gobgpd 3.23.0 | logs `network bytes is short`, sends NOTIFICATION 3/1, resets |
| bgp4r | reports nothing, reads one prefix as five: `0.0.0.0/0` three times, `24.0.0.0/7`, `51.100.0.0/198` |

Both bgp4r readings are gaps and both are under "Known issues to work
on" in `CLAUDE.md` rather than fixed here, because `validation.rb` has
no NLRI field checks at all and picking a subcode is a decision rather
than a patch.

## What is not here

**A Compose test**, which `lab/README.md` asks every topology for.
Docker is not usable where this was written, so one would have been an
unrun claim, and CLAUDE.md's rule is that a claim nothing checks reads
as verified. What exists instead is
`test/functional/lab/add_path_topology_test.rb`, which reads these files
and holds them to this README with no Docker, no router and no socket.

Writing the Compose test needs one addition to `LabHelper::Compose`: a
public way to run a command inside a service that is not a bgp4r
speaker, since `state(node)` reads the state file and `compose` is
private, and the GoBGP half of this topology is answered by
`gobgp global rib -j` inside the router's container.

## What this did not port, and why

The third case of that test file is
`test_gobgp_reads_our_send_receive_field_the_way_we_meant_it`, which
runs **three sessions**, one per Send/Receive value, and asserts GoBGP's
reading of each. A lab config is fixed, so a scenario can assert only
the pair its node files set. `two-paths.yml` asserts two of the three
rows, the symmetric `3` and the asymmetric `1`, because `peer.yml`
advertises receive-only on purpose.

The third row, our `2` against a peer's `1`, needs the capability
changed on a live lab, which is `bgp: session.capability` in
`unnegotiated-path-id.yml`. So the matrix in that test is a matrix
because it is a test, and a lab reaches it only through the injector.
That is not a loss: the test already covers it in 35 seconds and should
keep covering it.
