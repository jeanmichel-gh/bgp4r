# rr-lab

Nine nodes and four BGP implementations, built to exercise route reflection, RFC 4456. `rr1`, a `bgp4rd` in AS 65100, reflects for cluster 1.1.1.1. Its clients are an FRR (`c1`), a BIRD (`c2`), a GoBGP (`c3`), a second `bgp4rd` (`dual`) and the injector `inj-c`. Its non-clients are the injector `inj-n` and `rr2`, an FRR reflecting for cluster 2.2.2.2 with `dual` as its client. `inj-e` in AS 65200 is its one external peer.

The three injectors start silent. Every route in the lab comes from a scenario.

It exercises:
- a client route reflected to every client and every non-client, with its next hop unchanged
- a non-client route reflected to clients only, and refused to the other non-client
- an external route sent to every internal peer, without ORIGINATOR_ID or CLUSTER_LIST
- the shorter CLUSTER_LIST winning once the ORIGINATOR_ID ties, and FRR reflecting into bgp4r
- a route carrying the reflector's own cluster ID dropped
- a route carrying the reflector's own router ID as ORIGINATOR_ID dropped
- a withdrawal reaching every reader
- a client flap, and the routes reflected again

The eight scenarios in `scenarios/` drive these. README.md has the addressing, the images and the commands to read each router by hand.
