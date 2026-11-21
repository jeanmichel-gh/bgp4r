# BFD in bgp4rd

`bfd: true` on a neighbor gives that BGP session a BFD session beside it
(RFC 5880, RFC 5881), and resets the BGP session as soon as BFD says the
path failed, rather than after the hold time. routescope's
`docs/design/bfd-clients.md`, step 6d, is the design; this is the guide.

```yaml
neighbors:
  - address: 10.0.12.2
    as: 65002
    connect: true
    bfd: true
```

## Who runs the BFD session

Not bgp4rd. **bfdd4r** does, from bfd4r, the owner's BFD gem: one
daemon per network namespace, answering on the abstract socket
`@bfdd4r` (or `$BFD4R_SOCKET`), shared by every router in that
namespace. bgp4rd asks it for sessions through bfd4r's `BFD::Client`,
under the client name `bgp4rd`, and hears what they do.
`bgp/daemon/bfd.rb` is the whole of bgp4rd's half.

In the `lab-node` image the entrypoint is `with-bfdd4r`, which starts
bfdd4r in the background and then runs the node's command, so a
containerlab node has bfdd4r without asking. Anywhere else, start
`bfdd4r` yourself, or run bgp4rd under `with-bfdd4r`.

## What bgp4rd does

* **The session is wanted while the neighbor says `bfd: true`**,
  whatever BGP is doing. BFD comes up beside BGP and not after it, and
  BGP never waits for BFD: RFC 5882 section 4.1 says to hold an
  adjacency back only when both ends are known to be willing to run
  BFD, and BGP carries no signal that says so.
* **One hop only.** At start and on a commit, `ip -j route get ADDRESS`
  must answer with no `gateway`. Its `dev` and `prefsrc` are the
  session's interface and local address. Otherwise bgp4rd refuses:
  `neighbor X: bfd needs a neighbor one hop away`. Multihop BFD, RFC
  5883, is not here yet. **In containerlab this means bgp4rd has to
  start after its link addresses exist**, since `exec:` runs after the
  entrypoint; `routescope/labs/bfd-frr-lab` shows the wait.
* **A failure resets an Established session.** When an Up BFD session
  goes Down, and the BGP session is Established, bgp4rd sends a
  NOTIFICATION Cease, subcode 10, "BFD Down" (RFC 9384 section 3), and
  ends the session; an active neighbor dials again after its `retry`.
  RFC 5882 section 10.2: without Graceful Restart "the EBGP session
  should be torn down". The peer's `last_error` says `BFD Down` either
  way, as RFC 9384 section 4 asks, even when the NOTIFICATION could not
  get through. A session that is not Established has nothing to reset.
* **AdminDown never acts.** RFC 5882 section 4.2: on Up to AdminDown,
  or Up to Down because the remote end says AdminDown, "clients SHOULD
  NOT take any control protocol action". `BFD::Client` reports both as
  `:admin_down`.
* **bfdd4r away keeps every session.** If bfdd4r is not running, or
  dies, bgp4rd logs it once and keeps its BGP sessions: the local
  system then does not run BFD, which section 4.1 allows. When bfdd4r
  is back, `BFD::Client` asks for every session again.
* **bgp4rd stopping lets go of its sessions**, so bfdd4r takes the ones
  no other client holds to AdminDown, and the peer does not act.

## iBGP

Allowed. RFC 5882 section 10.2 says "it is generally unwise for IBGP
sessions to interact with BFD if the underlying IGP is already doing
so", which is advice about a network and not a rule bgp4rd enforces: an
iBGP neighbor one hop away with no IGP running BFD is a fair use.

## A commit

`bfd` is live in a commit: adding it asks for the session, removing it
lets go, and the BGP session is not touched either way. A commit that
sets `bfd: true` on a neighbor that is not one hop away, or `bfd` to
anything but true or false, is refused, as at start.

## What it shows

`show.peers` (and `show.status`'s peer rows) gain `bfd` on a neighbor
with `bfd: true`: `up`, `down`, `init` or `admin_down` as bfdd4r last
told it, or `unknown` before it has told one and while bfdd4r is away.
Other rows have no such key.

## Tests

* `test/unit/daemon/bfd_test.rb`: every rule above, with a fake
  `BFD::Client` (`test/helpers/fake_bfd_client.rb`) and a fake `ip`.
* `test/functional/bfd_test.rb`: the real client against two real
  bfdd4r on 127.0.0.1 and 127.0.0.2, with no root. It needs bfd4r on the
  load path, which `bundle exec` gives from `../bfd4r`.
* `routescope/labs/bfd-frr-lab`: the interop check against FRR's bfdd,
  deployed by CI. Measured on 2026-11-21: the BGP session reset 0.68 to
  0.90 s after the link began losing every packet, with 6/10 sent, where
  the hold time is 9 s; bgp4rd's own share is 2 to 7 ms after bfdd4r
  detects the failure, and the rest is BFD's 900 ms Detection Time.

## bfd4r as a dependency

bfd4r is not published, so it comes by path, as isis takes
datalink-socket: `bgp4r.gemspec` declares it, the `Gemfile` takes it
from `../bfd4r`, CI clones it there, and the Dockerfile's `lab-node`
stage takes it as a named build context:

```
docker build --target lab-node --build-context bfd4r=../bfd4r -t bgp4r-lab:latest .
```

The rest of the image does not bundle it, since Bundler would load its
gemspec, which runs `git`, and the image has none (`BFD4R_ON_RUBYLIB`).
`bgp/daemon/bfd.rb` requires `bfd/client` only when a neighbor asks for
BFD, so nothing else needs it.
