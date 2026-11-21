---
title: bgp4rd and FRR with BFD, the interop check
tags: [bgp, bfd]
role: interop
---
# bfd-frr-lab

The interop check of bgp4rd's `bfd: true`. `bgp`, a `bgp4rd` in AS 65001 with `bfdd4r` beside it, peers eBGP with `frr`, FRR 10.2.1 in AS 65002 with `bfdd`, over one link, and each end runs a BFD session to the other.

```
bgp (AS 65001) eth1 10.0.12.1 ---- 10.0.12.2 eth1 frr (AS 65002)
```

It exercises:
- a BFD session between bfdd4r and FRR's bfdd, Up on both ends, beside an Established BGP session
- the link losing every packet, and bgp4rd resetting the BGP session in under a second with a NOTIFICATION Cease 6/10, BFD Down (RFC 9384), where the 9 second hold time would take nine
- the link coming back, and BFD and BGP coming back on their own

`gate.sh` is the check, and CI runs it (`.github/workflows/capture.yml`). The header of `bfd-frr-lab.clab.yml` has the commands.

Measured on 2026-11-21, four runs: the reset came 0.81 to 0.90 s after the loss began, which is the 900 ms Detection Time of 300 ms and a multiplier of 3 at both ends.

One thing FRR 10.2.1 does that is not a fault here: the first time BGP comes up after a deploy, FRR recreates its own BFD session, signals Down, and resets BGP with a 6/10 of its own. bgp4rd does nothing, since its session is not Established yet, and both come back within two seconds. A later reset of the BGP session does not do it again.
