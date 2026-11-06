# bgp4r-lab

Seven nodes and four BGP implementations. Two bgp4r injectors, `inj1` and `inj2`, both in AS 65010, feed `rtr`, a `bgp4rd` router in AS 65000. `rtr` passes its best paths to an FRR and BIRD AS, 65001, and to a GoBGP of its own, `g1` in AS 65002.

The injectors start silent. Every route in the lab comes from a scenario, so what you see is what a scenario put there.

It exercises:
- seven sessions across bgp4r, FRR, BIRD and GoBGP: four eBGP, and an iBGP full mesh of `r1`, `r2` and `r3`
- a prefix injected on command crossing `rtr` to FRR, BIRD and GoBGP, with `rtr`'s AS prepended and `rtr` as the next hop
- one UPDATE out of `rtr` read by FRR and by GoBGP at once
- `rtr`'s decision process saying why a path won, down to the MED step, and one action flipping the winner
- a withdrawal reaching BIRD at the far end of the chain
- a standard, an extended and a large community crossing intact
- a session flap counted, and every speaker done with its work afterwards

The six scenarios in `scenarios/` drive these, and each opens by waiting for the sessions. README.md has the addressing, the images and the commands to read each router by hand.
