# fwd-lab

Forwarding through bgp4rd. Four `bgp4rd` routers, each in its own AS,
peering eBGP. Each announces its loopback, routes what it learns, and
installs the result in the kernel's main table. So a ping from `a` to
`d` crosses `b` and either the direct link or `c`, depending on what
BGP decided.

`ABOUT.md` is the short version, the one routescope shows.

```
   AS 65001     AS 65002     AS 65003     AS 65004
      a  -------  b  -------  c  -------  d
                  |                       |
                  +-----------------------+
```

## The nodes

| Node | AS | Loopback | Addresses | Role |
|---|---|---|---|---|
| `a` | 65001 | 10.255.0.1/32 | eth1 10.200.1.1/30 | Where the pings start. |
| `b` | 65002 | 10.255.0.2/32 | eth1 10.200.1.2/30, eth2 10.200.2.1/30, eth3 10.200.4.1/30 | The router that chooses. |
| `c` | 65003 | 10.255.0.3/32 | eth1 10.200.2.2/30, eth2 10.200.3.1/30 | The backup path. |
| `d` | 65004 | 10.255.0.4/32 | eth1 10.200.3.2/30, eth2 10.200.4.2/30 | Where the pings end. |

Four links, four sessions, all eBGP, hold time 9 seconds.

## Why it is shaped this way

**`b` hears `d`'s loopback twice.** From `d` with AS_PATH `65004`, and
from `c` with `65003 65004`. The shorter AS_PATH wins (RFC 4271 section
9.1.2.2 a), so the direct link carries the traffic. When the B to D
session ends, that path is withdrawn and the one through `c` is best.
`d`'s choice for `a`'s loopback is the same in reverse, so both
directions move together.

**Every next hop is on a shared link.** An eBGP route's next hop is the
neighbor's address on the link it came over, so the kernel takes every
route bgp4rd installs. bgp4rd does not resolve a next hop recursively,
and here it has no need to. rr-lab's `dual` cannot do this, because a
reflected route keeps a next hop that is not on its links.

**`fib: {table: 254}` is the main table**, the one the kernel forwards
from. A table of its own would hold the same routes and forward nothing,
since no `ip rule` points at it. Each node's own loopback is not
installed: the kernel already has it, and `show.fib` lists it under
`skipped` as `originated`.

**A link that goes down sends no NOTIFICATION**, so `b` keeps the
session until its hold timer runs out. The kernel drops `b`'s route
through eth3 the moment the link is down, so traffic to `d` is lost for
up to 9 seconds. Stopping the session by hand ends it at once, which is
the comparison two of the scenarios make.

**Which way the packets went is read from a counter.** Every packet
through `c` arrives on its eth1, so 50 pings through `c` add at least 50
to `/sys/class/net/eth1/statistics/rx_packets` there, and 50 over the
direct link add almost nothing. traceroute shows the same thing for a
person.

## What was measured

In network namespaces, with the lab's own files, on 2026-11-06:

| Event | Time to the new path |
|---|---|
| B to D link down | 9.0 seconds, the hold time |
| B to D link up | 0.6 seconds |
| B to D session stopped | under 0.2 seconds |
| `d` cut off, withdrawn at `a` | 9.2 seconds |

`test/functional/lab/fwd_lab_netns_test.rb` runs the same sequence on
every pull request, and CI's Capture job runs `capture.sh` on the
deployed lab.

## Scenarios

| Scenario | What |
|---|---|
| `direct-link-wins.yml` | Every loopback everywhere, `b` on the direct link, decided by `as_path_length`. |
| `link-down-moves-to-c.yml` | `b:eth3` down, `b` through `c` after the hold time, then back. |
| `session-stop-moves-to-c.yml` | `peer.stop` on `b`, through `c` at once, then `peer.start`. |
| `d-cut-off.yml` | Both of `d`'s links down, `d` withdrawn, then back. |

None has been run in routescope yet. Each starts and ends with the lab
whole, so they run in any order.

## By hand

Make a copy, deploy it, and open a shell on a node:

```
# in the VM
bgp4r lab new ~/labs/fwd-lab fwd-lab
cd ~/labs/fwd-lab
sudo containerlab deploy -t fwd-lab.clab.yml
docker exec -it clab-fwd-lab-a bash
```

In `a`'s shell:

```
ping -I 10.255.0.1 10.255.0.4
traceroute -n -s 10.255.0.1 10.255.0.4
ip route
cli show.fib --pretty
cli -c 'show bgp'
```

In `b`'s shell, take the direct link down and watch the route move:

```
ip link set eth3 down
ip route get 10.255.0.4
ip link set eth3 up
```

`docs/bgp4r-cli.md` lists everything `cli` answers.

The whole check, from the host:

```
# in the VM
LAB=fwd-lab ~/labs/fwd-lab/capture.sh
```
