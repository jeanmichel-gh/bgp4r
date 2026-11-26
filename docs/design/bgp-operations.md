# BGP operations in bgp4rd

Status: approved by the owner, 2026-11-25, with the answers to its
eight questions in "Questions, answered" at the end. The sections below
are written to them. "Pull requests" says which are built.

This is P8 in routescope's `docs/protocol-coverage.md`: "BGP operations.
Graceful restart and long-lived GR, answering route refresh, RPKI, BMP,
MD5 or TCP-AO, GTSM. FRR has `bgpd_bmp` and `bgpd_rpki` to test
against". Its rows are RFC 2918, 4724, 9494, 6811, 7854, 2385 and 5082,
with 8538 added on 2026-11-25. P8 comes last in that document's order
(P5, P9, P6, P7, P8). The owner asked for its spec now.

P8 is seven features. This document orders them, splits them into pull
requests, and gives each one a section: what exists, what to build, its
tests, its fault-catalog entries, and what routescope shows. routescope's
side is a spec of its own.

Every fact about bgp4r below was read from master at bcc6243
(2026-11-25). Every fact about Linux, Ruby and FRR was measured on
ospflab that day; the commands are in "Measurements". Every RFC section
quoted was read, from `specs/rfc` (not committed).

## Summary

| # | Feature | RFC | Today | Pull requests |
| --- | --- | --- | --- | --- |
| 1 | End-of-RIB | 4724 section 2 | a builder, never sent | 1 |
| 2 | Route refresh, answered | 2918, 7313 | sent by `peer.refresh`, never answered | 1 |
| 3 | Graceful restart, helper | 4724, 8538 | the capability's codec | 1 |
| 4 | Long-lived graceful restart, helper | 9494 | the capability's codec, the two communities | 1 |
| 5 | GTSM | 5082 | none | 1 |
| 6 | TCP MD5 and TCP-AO | 2385, 5925 | none | 2 |
| 7 | RPKI origin validation | 8210, 6811 | the RFC 8097 extended community's codec | 3 |
| 8 | BMP | 7854, 9069 | none | 3 |
| – | Graceful restart, restarting speaker | 4724 section 4.1 | none | not built (answer 2) |

Thirteen pull requests and one for the labs. Each is small and stands
alone once the ones it needs are in. The section numbers name the
features; the build order is below.

## The order, and why

The order, as answer 1 set it:

```
5 GTSM, 6a MD5          first: a day each, and every later lab uses them
        │
1 EoR ──► 2 refresh ──► 3 GR helper ──► 7 RPKI ──► 8 BMP ──► 4 LLGR helper
                │                        │          │
                │                        7a codec ► 7b cache ► 7c ROV ► (ASPA, later)
                │                                   8a codec ► 8b station ► 8c bgp4rd
                └─ stale marks in the Adj-RIB-In, used by 2, 3 and 4

6b TCP-AO               any time after 6a
```

- **End-of-RIB comes first.** Graceful restart needs it both ways (RFC
  4724 section 4). BMP needs it after each peer's dump (RFC 7854
  section 5). RFC 4724 section 2 recommends it to everyone, GR or not.
  bgp4rd does not send it today.
- **Route refresh comes before graceful restart.** RFC 7313 section 4
  makes the receiver mark a family's routes stale on a BoRR and drop
  what is still stale on the EoRR. That is the same stale mark GR
  needs, on a smaller case: one family, no timer but a local bound, no
  session loss. It is built once, in pull request 2, and GR uses it.
- **LLGR after GR, and last of all.** RFC 9494 section 4 says "the
  procedures specified in [RFC4724] continue to apply unless explicitly
  revised by this document", and section 4.1 that the LLGR capability
  is disregarded without the GR one. LLGR is the least deployed feature
  in P8, used mostly by VPN providers, where origin validation is
  widely deployed. routescope's priorities follow "first what the
  industry prefers", so RPKI and BMP come before it.
- **GTSM and MD5 first.** They touch only the socket, need nothing
  above, and nothing needs them. Each is about a day. Built first,
  every lab after them can run its sessions with them. TCP-AO follows
  MD5 at any time, since it reuses its code.
- **RPKI and BMP each need a codec and a program at the other end.**
  The VM has no RPKI cache and no BMP station (measured: no image of
  either). So each starts with its codec, then a small Ruby program for
  the other end, which is also the injector for negative tests. Then
  bgp4rd's side.

## What exists

Read from the code, not recalled.

- **Receiving a refresh.** `Neighbor#rcv_route_refresh`
  (`bgp/neighbor/neighbor.rb:971`) is empty. The message reaches the
  observers, and no observer acts on it: `Recorder#update`
  (`bgp/daemon/speaker.rb:129`) matches Open, Keepalive, Update and
  Notification only.
- **Sending a refresh.** `Peer#refresh` (`bgp/daemon/speaker.rb:522`)
  and `peer.refresh` (`bgp/daemon/control.rb:168`) send a ROUTE-REFRESH
  with any AFI, SAFI and subtype. They do not check that the peer
  advertised capability 2, on purpose (the comment there gives the
  reason: a test tool must be able to).
- **Sending the table.** `Router#session_up` (`bgp/rib/router.rb:320`)
  sends the whole Loc-RIB once, through the export rules, when a
  session reaches Established. `Router#resend` sends chosen prefixes
  again. Nothing sends an End-of-RIB after the first table.
  `Update.end_of_rib_marker` (`bgp/messages/markers.rb`) builds one and
  nothing in `bgp/` calls it.
- **Other tables send for themselves.** `VpnExporter`, `VpnReflector`,
  `LinkStateProducer` and the unreachability originator each keep what
  they sent and send the difference. A refresh or an End-of-RIB for
  their families goes through them, not through `Router`.
- **A session that ends.** `PeerAdapter#state_change`
  (`bgp/rib/peer_adapter.rb:259`) queues `[:peer_down, peer]` when a
  session leaves Established. `Table#peer_down` flushes that peer's
  Adj-RIB-In and runs the decision. There is no stale state.
- **Its own routes on exit.** `Speaker#stop_rib`
  (`bgp/daemon/speaker.rb:1054`) takes bgp4rd's routes out of the
  kernel table on a clean stop: "Takes our routes back out of the
  forwarding table". So while bgp4rd is down, it forwards nothing it
  learned by BGP.
- **A second connection.** `Peer#accept` (`bgp/daemon/speaker.rb:448`)
  closes a new connection while a session is busy: "one session per
  peer; keep the one we have". RFC 4724 section 4.2 asks the opposite
  of a GR helper.
- **Capabilities.** A neighbor's `capabilities:` list advertises any
  capability by name (`Neighbor::CAPABILITIES`), `graceful_restart` and
  `long_lived_graceful_restart` included, with any values. Nothing
  behaves differently for them. That stays: a list entry is an
  advertisement, which a test may make without the behaviour. The one
  exception is route refresh (section 2). A `graceful_restart` entry
  in the list does not make bgp4rd a helper; the `graceful_restart` key
  does.
- **Codecs that exist.** `CAP::Graceful_restart` (Restart Flags as
  `restart_state`, a 4-bit field, so the N bit is `0x4`),
  `CAP::Long_lived_graceful_restart`, `CAP::Enhanced_route_refresh`,
  `Route_refresh` with its subtype, the Cease subcode 9 "Hard Reset"
  name (`bgp/messages/notification.rb:129`), error code 7 and its
  subcode 1, the `LLGR_STALE` and `NO_LLGR` communities
  (`bgp/path_attributes/communities.rb:36`), the RFC 8097
  `Origin_validation_state` extended community, and `CAP::Role` (RFC
  9234).
- **Sockets.** `Socket.tcp` for an active peer, `TCPServer` for the
  listener, and a socket bound with `SO_BINDTODEVICE` for a VRF. No
  other socket option is set.
- **The fault catalog.** `BGP::Fault::CATALOG`, 20 entries, and
  `BGP::Fault::UNREACHABILITY`, 8 (measured with `ruby -I.`). All are
  UPDATE attribute cases. bgp4r has no behaviours yet (routescope's
  `protocol-conventions.md`, part 3). P8 adds the first ones.
- **The decision.** `Decision#ineligible_reason` knows four reasons:
  next hop unreachable, AS loop, originator ID loop, cluster list loop.
  There is no "least preferred" step.
- **Events.** `BGP::Events::KINDS` is `session`, `notification`, `log`
  and `overflow`, and layers add theirs with `register_kind`.

## Rules every pull request keeps

- **Off until configured** (answer 6). A node file without the new keys
  runs as today, byte for byte on the wire. Each feature has its own
  key. An unknown key is still refused by name (`Peer.check_keys`).
  One case has no key: answering a refresh is configured by listing
  `route_refresh` or `enhanced_route_refresh` in `capabilities`, since
  advertising the capability is what lets a peer ask (section 2).
  Every other entry in that list stays an advertisement only.
- **The library never refuses to build.** Each new codec builds any
  field value, keeps what it cannot read as `Unknown` and sends it back
  unchanged. Validation is on receipt only, in one place, as
  `bgp/path_attributes/validation.rb` does for attributes.
- **New timers run on an injected clock.** routescope's
  `protocol-conventions.md`, part 8: "The rule binds new code." The
  restart timer, the stale timer, the long-lived stale timer, the RTR
  timers and the BMP backoff are all tested on a manual clock, without
  `sleep`.
- **A test tool may still lie.** `peer.refresh` keeps sending what it
  is told. The injector keeps sending a GR capability without the
  behaviour, a BoRR without a refresh, an RTR PDU of any version.
- **Each catalog entry and behaviour names the RFC section** and what
  the RFC expects of the receiver, as `BGP::Fault::CATALOG` does.
- **Interop runs only against a released router** (the owner's rule).
  On ospflab that is FRR 10.7.1.

## 1. End-of-RIB

RFC 4724 section 2:

> "An UPDATE message with no reachable Network Layer Reachability
> Information (NLRI) and empty withdrawn NLRI is specified as the
> End-of-RIB marker [...] For any other address family, it is an UPDATE
> message that contains only the MP_UNREACH_NLRI attribute [BGP-MP]
> with no withdrawn routes for that <AFI, SAFI>."

and, of its use outside GR:

> "the generation of such a marker upon completion of the initial
> update would be useful for routing convergence in general, and thus
> the practice is recommended."

### What to build

- After `Router#session_up` has sent a session's first table, send one
  End-of-RIB per family the session negotiated. The VPN, BGP-LS and
  unreachability exporters do the same for theirs, after their first
  send to that session.
- On by default? No: the wire changes, so it is off until configured,
  with a neighbor key `end_of_rib: true`. `graceful_restart` (section
  3) turns it on too, since RFC 4724 section 4 makes it a MUST there.
- On receipt, recognise the marker per family and publish it: a
  `session` event with `data: {end_of_rib: {afi, safi}}`, and the
  families seen in the peer's snapshot (`end_of_rib_received`). The
  marker already reaches `PeerAdapter#unreachable?` as an empty UPDATE;
  this names it.

### Tests

- Unit: the marker for IPv4 unicast is the 23-octet UPDATE; for
  another family, an UPDATE with one empty MP_UNREACH_NLRI.
- Functional, over loopback: two bgp4rd, `end_of_rib: true` on one;
  the other sees one marker per negotiated family, after the last
  route of the first table and before any later change.
- The same with nothing to send: the marker still goes (RFC 4724
  section 4, "including the case when there is no update to send").

### As built (pull request 1)

- `Update#end_of_rib` (`bgp/messages/markers.rb`) answers [afi, safi]
  for the two shapes above and nil for anything else, an empty
  MP_UNREACH_NLRI beside another attribute included.
- `BGP::Neighbor#rcv_update` publishes the `session` event, so the
  library has it too. The daemon's Recorder keeps
  `end_of_rib_received`, reset with the session, and the peer row in
  `show.peers` and `show.status` carries it once one has come.
- `Speaker#send_end_of_rib` runs on the session's thread after
  `announce` and every `on_established` block. Two senders run behind
  on threads of their own, so it waits for each: it drains the RIB
  feed, which queued the session's `[:session_up]` first, and
  `VpnReflector#drain`, new, which waits for a refresh. The BGP-LS,
  unreachability, VPN and CE exporters send inside their
  `on_established` blocks. Each wait is capped at 30 s, with a warning.
  So the markers come from one place, not from each exporter as the
  first bullet above said: a family nothing sends gets its marker too,
  and no exporter needs to know about the others.
- Negotiated families: both OPENs list the Multiprotocol capability,
  RFC 4760 section 8; an OPEN with none is IPv4 unicast.
- `end_of_rib` is bounce class in a commit, and a value other than
  true or false is refused at start and in a commit.
- **Measured against FRR 10.5.1**, 2026-11-25: FRR sends End-of-RIB for
  IPv4 unicast with no graceful restart negotiated, and bgp4rd records
  it. FRR tracks a received one only under graceful restart
  (`gracefulRestartInfo.endOfRibRecv` stays empty without it), so ours
  shows as one more UPDATE in its `messageStats.updatesRecv`: 2 for one
  route with `end_of_rib`, 1 without.
- Tests: `test/unit/messages/markers_test.rb` (both shapes, and five
  UPDATEs that are not markers), `test/unit/daemon/end_of_rib_test.rb`
  (families, check, Recorder and row), the commit's bounce and refusal
  in `candidate_test.rb`, `VpnReflector#drain` in
  `vpn_reflector_test.rb`, `test/functional/end_of_rib_test.rb` (order
  after the first table, nothing to send, negotiated families only, the
  control, receipt as event and row), and
  `test/functional/lab/end_of_rib_frr_test.rb` (both ways, with its
  control). Over loopback the Router always wins the race to the wire,
  so the order test holds the Router's `session_up` back a second;
  without the drain the markers then come first, which was checked.

### Fault catalog

None of its own: an End-of-RIB is a valid UPDATE. Section 3 uses it.

### routescope shows

The families whose End-of-RIB was received, on the peer row.

## 2. Route refresh, answered

### The RFCs

RFC 2918 section 4:

> "If a BGP speaker receives from its peer a ROUTE-REFRESH message with
> the <AFI, SAFI> that the speaker didn't advertise to the peer at the
> session establishment time via capability advertisement, the speaker
> shall ignore such a message. Otherwise, the BGP speaker shall
> re-advertise to that peer the Adj-RIB-Out of the <AFI, SAFI> carried
> in the message, based on its outbound route filtering policy."

RFC 7313 section 4, when the peer sent the Enhanced Route Refresh
capability (70):

> "Before the speaker starts a route refresh that is either initiated
> locally, or in response to a "normal route refresh request" from the
> peer, the speaker MUST send a BoRR message. After the speaker
> completes the re-advertisement of the entire Adj-RIB-Out to the peer,
> it MUST send an EoRR message."

and on receipt:

> "When a BGP speaker receives a BoRR message from a peer, it MUST mark
> all the routes with the given [...] <AFI, SAFI> [...] from that peer
> as stale. [...] When a BGP speaker receives an EoRR message from a
> peer, it MUST immediately remove any routes from the peer that are
> still marked as stale for that <AFI, SAFI>."

It allows a local upper bound on stale routes, and ignoring an EoRR
with no BoRR before it. With GR, a speaker "MUST NOT send a BoRR for an
<AFI, SAFI> to a neighbor before it sends the EoR", and "MUST ignore
any BoRRs [...] from the neighbor before the speaker receives the EoR".

Section 5: a BoRR or EoRR whose length after the header is not 4 gets a
NOTIFICATION, code 7 "ROUTE-REFRESH Message Error", subcode 1 "Invalid
Message Length", whose data is the whole ROUTE-REFRESH. A subtype other
than 0, 1 or 2 is ignored and logged.

### What to build

- **Answer.** `Neighbor#rcv_route_refresh` hands the message to the
  speaker. If we advertised the family in our OPEN, the family's
  owner re-sends its Adj-RIB-Out for that peer: `Router` for unicast
  (as `resend` does, every prefix in the peer's Adj-RIB-Out), the VPN,
  BGP-LS and unreachability exporters for theirs. Otherwise, ignore and
  log.
- **Enhanced.** If the peer advertised capability 70, wrap the answer
  in BoRR and EoRR. A refresh we start ourselves stays `peer.refresh`,
  unchanged.
- **Receive BoRR and EoRR.** A BoRR marks the peer's routes of that
  family stale in its Adj-RIB-In. A route received again clears its
  mark. The EoRR removes what is still stale and runs the decision. A
  neighbor key bounds the wait, `refresh_stale_time` (seconds, default
  180, RFC 8538's stale timer reused; answer 6), after which what is
  still stale goes.
- **What turns answering on.** Listing `route_refresh` (capability 2)
  or `enhanced_route_refresh` (70) in `capabilities`, which bgp4rd
  already advertises today. RFC 2918 section 4 makes answering a
  "shall" once the capability went out, so a separate key would only
  let bgp4rd advertise what it then refuses. A refresh from a peer
  to which we did not advertise capability 2 is ignored and logged,
  as today: a peer that follows RFC 2918 section 4 sends none, and a
  node file without the entry sees nothing new on the wire.
- **The stale mark.** A flag on a route in the Adj-RIB-In, with the
  reason (`refresh`, `restart`, `long_lived`). The decision does not
  look at it (RFC 4724 section 4.2: "MUST NOT differentiate between
  stale and other routing information during forwarding"); LLGR's
  least-preferred step, section 4, is separate.
- **Errors.** A BoRR or EoRR of the wrong length gets the 7/1
  NOTIFICATION with the message as data. A subtype outside 0 to 2 is
  ignored and logged.
- **ORF is not in P8.** A ROUTE-REFRESH carrying ORF entries (RFC 5291)
  is logged and not answered, as today.
- **The control API.** `show.peer` gains `refresh: {received, answered,
  stale}`. `peer.refresh` is unchanged.

### Tests

- Unit: the stale mark, set, cleared by a new route, purged by EoRR, by
  the local bound on a manual clock.
- Functional: bgp4rd A answers bgp4r's `Neighbor` B, which records the
  answer: every route of the family once, nothing of another family.
  With capability 70 on both: BoRR first, EoRR last.
- Functional: a refresh for a family we did not advertise is ignored.
- Functional, receive side: B sends BoRR, half the routes, EoRR; A
  keeps that half and drops the rest.
- Interop: `clear bgp X soft in` on FRR 10.7.1 toward bgp4rd, and
  `peer.refresh` from bgp4rd toward FRR, with and without capability
  70. FRR's `show bgp neighbor` counts refreshes; bgp4rd's must match.

### Built in three parts

Pull request 2 is built as three, each its own review, since the whole
touches every family's sender, the RIB and the fault catalog at once:

- **2a, answering**: the answer for every family, BoRR and EoRR around
  it, the counts on the peer row and the `refresh` events. Built.
- **2b, receiving BoRR and EoRR**: the stale mark, `refresh_stale_time`,
  the 7/1 NOTIFICATION for a wrong length, an unknown subtype ignored,
  `stale` on the route rows. Built.
- **2c, the fault catalog**: `BGP::Fault::REFRESH` and `bgp4r-sim`
  sending its cases. Built.

### As built (2a)

- `bgp/daemon/refresh.rb`: one `Refresh` per peer, an observer of its
  session. A normal request is answered on a thread of its own, since
  the answer waits on the RIB's worker and the observer runs on the
  session's receive thread; a second request waits for the first
  answer's EoRR.
- **What is answered** (`Refresh.refusal`): our OPEN carried capability
  2 (or the pre-standard 128) or 70, and the family. Anything else is
  ignored, logged, counted and published.
- **Who answers** (`Speaker#resend_family`): the `announce` blocks of
  that family (`Peer#resend_announcements`); for unicast the Router,
  through a new `[:readvertise]` item on the RIB feed
  (`Router#readvertise`, `Table#readvertise`, every prefix of that AFI
  in the peer's Adj-RIB-Out; `Table#refresh` was taken, by the re-run of
  import and the decision),
  or a CE's VRF exporter; for VPN `VpnExporter#resend` and
  `VpnReflector#resend`, then the reflector's `drain`; BGP-LS the
  Producer's `session_up`; the unreachability families
  `UnreachOriginator#resend`. Each returns once it has sent, so the
  EoRR comes after the routes.
- **Counts**: every ROUTE-REFRESH message both ways by subtype
  (`normal`, `borr`, `eorr`, `other`), and requests answered and
  ignored, on the peer row as `refresh`, reset with the session.
  routescope asked for messages as well as requests, to compare with
  FRR, which counts messages.
- **Events**: a new kind, `refresh`, registered by the daemon
  (`Events.register_kind`), for each message both ways and each answer
  or refusal. `peer.refresh` goes through the same counter.
- **Measured against FRR 10.5.1**, 2026-11-25: `clear bgp X soft in` is
  one request, and FRR advertises 70, so bgp4rd answers with BoRR, the
  routes and EoRR whatever bgp4rd advertised. `peer.refresh` gets FRR's
  answer between BoRR and EoRR only when bgp4rd advertised 70. FRR's
  `messageStats.routeRefreshSent` and `routeRefreshRecv` count every
  subtype together and agree with bgp4rd's counts both ways.
- Tests: `test/unit/daemon/refresh_test.rb` (what is answered, 70 from
  the peer, an UPDATE's family, counts and row), `Router#readvertise` in
  `router_test.rb`, each exporter's one-family resend in
  `vpn_reflector_test.rb`, `vpn_exporter_test.rb` and
  `unreachability_test.rb`, `test/functional/route_refresh_test.rb` (a
  family's routes and no other, BoRR first and EoRR last, an
  unadvertised family, no capability, counts that start again with a
  session, the events), and
  `test/functional/lab/route_refresh_frr_test.rb` (both ways, with and
  without 70 on our side, counts agreeing with FRR's).

### As built (2b)

- **Where the mark lives.** Each table that holds a peer's routes keeps
  it, since each holds a family RFC 7313 names: the RIB's Adj-RIB-In
  (`AdjRibIn#mark_stale`, `#purge_stale`, `Table#mark_stale`,
  `#purge_stale` by AFI, IPv4 and IPv6 told apart by the prefix), the
  CE table in a VRF, the VPN table by AFI, the EVPN table, the BGP-LS
  table and the unreachability table by family. L2VPN EVPN is two
  tables: types 2 and 3 in the EVPN table, type 254 in the
  unreachability table. The mark is a reason, `refresh` here, so GR's
  `restart` and `long_lived` use the same one. An announcement replaces
  the entry and with it the mark; a withdrawal and a closed session
  take it.
- **In order with the UPDATEs.** `Refresh#update` runs on the session's
  receive thread, so a BoRR comes after every UPDATE before it. The
  tables that apply on that thread are marked at once; the RIB, whose
  worker runs behind, gets a `[:stale]` item on its feed, in its place
  among the UPDATEs (`Speaker#stale_family`, beside 2a's
  `resend_family`). The worker calls back with the count, for the event.
- **Not for SAFI 2.** The RIB keys a route by its prefix and holds
  unicast and multicast together, so a BoRR for multicast would mark
  unicast routes too. A BoRR for a family no table holds is published
  with nothing marked.
- **The bound** is `refresh_stale_time`, a live neighbor key, 180 s by
  default. Each family waiting has a deadline on a monotonic clock; a
  thread, alive only while one waits, purges what ran out once a second
  (`Refresh#expire`, which a test calls on its own clock).
- **The length error** is found in `Message.factory`, since neither
  message class can hold a wrong-length BoRR: one octet more reads as
  an ORF message, whose encode writes the subtype as 0, and one less as
  a Route_refresh with no SAFI. It raises `Malformed_route_refresh`,
  carrying the octets; `Neighbor` sends 7/1 with them and stops, when
  the peer advertised 70, and logs and drops it otherwise.
- **GR's rule is left for GR**: a BoRR before the End-of-RIB is not yet
  ignored, since bgp4rd negotiates no GR before pull request 3.
- **Rows.** `stale` on the route rows of `show.rib` (each path),
  `show.adj_in`, `show.vpn`, `show.vrf`, `show.evpn`, `show.link_state`
  and `show.unreachability`, absent when fresh. `show.vrf`'s rows are
  built when the VRFs sync and a mark changes no decision, so the mark
  is read as the rows are asked for. The peer row's `refresh` gains
  `stale`, the routes stale now, and `waiting`, the families between
  BoRR and EoRR.
- Tests: the mark in each table's unit test, `Refresh` on a manual
  clock and the dispatch per family in `refresh_test.rb`, the length in
  `message_test.rb`, the key in `candidate_test.rb`, and
  `test/functional/refresh_stale_test.rb` through a real bgp4rd: BoRR,
  half the routes, EoRR; the bound; a peer without 70; an EoRR alone;
  subtype 3; a long BoRR with and without 70.
- **Measured against FRR 10.5.1**, 2026-11-25: FRR's answer to
  `peer.refresh` is a BoRR, every route of the family, and an EoRR.
  Its routes include ours sent back, AS_PATH "65002 65001", which the
  Adj-RIB-In keeps; bgp4rd marks all three, all three come again, and
  the EoRR removes none (`route_refresh_frr_test.rb`).

### Fault catalog

New entries in a `BGP::Fault::REFRESH` list, each sent by `bgp4r-sim`
as a whole message:

| Name | What is sent | RFC expects of the receiver | Section |
| --- | --- | --- | --- |
| `refresh_unadvertised_family` | a refresh for a family the receiver did not advertise | ignore | 2918 4 |
| `refresh_subtype_unknown` | subtype 3 (and 255) | ignore, log | 7313 5 |
| `refresh_borr_length` | a BoRR with one octet more | NOTIFICATION 7/1, data the whole message | 7313 5 |
| `refresh_eorr_length` | an EoRR with one octet less | NOTIFICATION 7/1 | 7313 5 |
| `refresh_eorr_without_borr` | an EoRR alone | may ignore | 7313 4 |
| `refresh_borr_before_eor` | a BoRR before the End-of-RIB, GR negotiated | must ignore, should log | 7313 4 |

One behaviour: `borr_without_eorr`, a BoRR and then silence. The
receiver may drop the stale routes after its local bound (7313 4).

### As built (2c)

- **`BGP::Fault::REFRESH`** in `bgp/fault.rb`, beside `CATALOG`: each
  entry is the name, what is sent, what the RFC expects (`:ignore`,
  `:may_ignore` or `:notification`), the section, and a block taking
  `afi` and `safi` that returns each message's octets. A list of its
  own, since its cases are whole messages and `CATALOG`'s are
  attributes. `refresh_borr_before_eor` carries `:gr`, as two of
  `CATALOG`'s carry `:ibgp`. `Fault.message_length` makes the two
  length cases.
- **`BGP::Fault::BEHAVIOURS`**, the first behaviours list, with
  `borr_without_eorr`. GR's join it.
- **bgp4r-sim.** `fault` takes a REFRESH case with `afi` and `safi`,
  and refuses `prefixes` or `next_hop` for one, and `afi` or `safi` for
  an UPDATE case. A new action, `behaviour`, at `POST /api/behaviour`,
  the eleventh; the first ten are routescope's `Drivers::Sim::ACTIONS`,
  which does not send it yet. `/api/topology` gains `refresh_faults`
  and `behaviours`.
- **The matrix** runs as two tests, each case on a session of its own:
  against bgp4rd (`test/functional/refresh_fault_matrix_test.rb`) and
  against FRR (`test/functional/lab/route_refresh_fault_frr_test.rb`,
  CI's `lab frr`). The table is in `docs/protocol-testing.md`.
- **Measured against FRR 10.5.1**, 2026-11-26. FRR answers subtypes 3
  and 255 as requests, where RFC 7313 section 5 says ignore. Its 7/1
  for a long BoRR carries no data. It answers a short EoRR with 1/2, the
  header check of RFC 4271 section 6.1. On a BoRR with no EoRR it marks
  the routes stale and starts a timer that `bgp graceful-restart
  stalepath-time` sets, 360 s by default; when it runs out it keeps the
  routes, still stale. It ignores a BoRR before the End-of-RIB from a
  GR peer.
- **bgp4rd's one gap**: it marks stale on a BoRR before the End-of-RIB
  from a GR peer, since it reads GR as an advertisement only until
  pull request 3. The bgp4rd matrix records it as known.

### routescope shows

Refreshes received and answered per peer; stale route counts; the
stale flag on a route in the RIB views; a `refresh` event for each
BoRR, EoRR and answer.

## 3. Graceful restart, the helper side (RFC 4724, RFC 8538)

### The RFCs

RFC 4724 section 4.2, the Receiving Speaker. When the TCP session ends
with a peer that advertised GR, it "MUST retain the routes received
from the peer for all the address families that were previously
received in the Graceful Restart Capability and MUST mark them as
stale". "If the session does not get re-established within the
"Restart Time" that the peer advertised previously, the Receiving
Speaker MUST delete all the stale routes". On the new session, a family
without the F bit, or missing, or a session with no GR capability at
all, has its stale routes removed at once. The End-of-RIB removes what
is still stale. A new connection while the old session still looks
Established ends the old one, with no NOTIFICATION. Section 5 gives the
FSM changes. Section 4 also says "the normal BGP procedures MUST be
followed when the TCP session terminates due to the sending or
receiving of a BGP NOTIFICATION message".

RFC 8538 changes the last rule when both sides set the N bit, the
second bit of the Restart Flags. Section 4: on a NOTIFICATION other
than a Hard Reset, both sides follow the Receiving Speaker rules. A
Hard Reset, Cease subcode 9, carries the real code and subcode in its
data (section 3.1), and ends the session the RFC 4271 way (section
3.2). A hold time expiry follows the Receiving Speaker rules too. Its
section 4.1 makes the stale timer a MUST, "suggested default value [...]
is 180 seconds", and keeps routes already stale across consecutive
restarts when N was exchanged. Its section 5.1 suggests which Cease
subcodes are hard: 1, 2, 3 and 9 hard, 4 "Provide user control", 5 to
8 graceful.

### What to build

A neighbor key, off by default (answer 6):

```yaml
neighbors:
  - address: 10.0.0.2
    as: 65002
    graceful_restart:
      restart_time: 0        # what we advertise, 0 to 4095; 0 is the default
      stale_time: 180        # RFC 8538 4.1's stale timer, for the peer's routes
      notification: true     # the N bit
```

- bgp4rd is a helper only (answer 2). It advertises the GR capability
  with R always clear and **no families**. RFC 4724 section 4 asks
  exactly this of a speaker that cannot preserve its forwarding state:
  "it is still recommended that the speaker advertise the Graceful
  Restart Capability to its peer (as mentioned before this is done by
  not including any <AFI, SAFI> in the advertised capability)", to say
  it sends End-of-RIB and helps a peer that restarts. It turns
  `end_of_rib` on.
- **The Restart Time we advertise defaults to 0**, and that follows
  from answer 2. A peer that helps us keeps our routes for that time
  after our session drops (4724 4.2), and forwards to us meanwhile. A
  clean stop of bgp4rd takes its routes out of the kernel
  (`Speaker#stop_rib`), so those packets would be lost. With no
  families listed the peer has nothing to keep anyway; 0 says the same
  to a peer that reads the time alone. A node file may set more, for a
  test of a peer's helper.
- **Without the key**, a peer that advertises GR to bgp4rd gets what it
  gets today: RFC 4271. Its routes are flushed when the session drops,
  a second connection is refused while one is up, no End-of-RIB is
  sent. Nothing about GR is shown.
- **When a session drops** (TCP failure, hold time with N, or a
  NOTIFICATION other than a Hard Reset with N) and the peer advertised
  GR for a family, `Table#peer_down` marks that family's routes stale
  instead of flushing them. Other families flush as today. Without N,
  routes already stale go (4724 4.2).
- **The restart timer**, the peer's Restart Time, starts. If no session
  comes back before it ends, the stale routes go.
- **The new session.** Families without F, or missing, flush at once.
  The others stay stale until the peer's End-of-RIB for that family,
  or the stale timer, whichever is first.
- **A connection during Established.** When the peer advertised GR,
  `Peer#accept` and `run_active` close the old session without a
  NOTIFICATION and keep the new one (4724 4.2 and 5). Without GR, as
  today.
- **Sending a Hard Reset.** `peer.stop` and `peer.clear` take `hard:
  true`, which wraps the Cease in subcode 9 as RFC 8538 section 3.1
  encodes it. With N exchanged, the default follows section 5.1's
  table: `peer.stop` (Administrative Shutdown, 2) is hard; `peer.clear`
  (Administrative Reset, 4) is graceful unless `hard: true`. A Cease
  for BFD Down (6/10) is graceful.
- **Receiving a Hard Reset.** Flush, as RFC 4271.
- **Events.** `gr` events: helper started, stale marked, restart timer
  expired, End-of-RIB purged N routes, Hard Reset sent or received.

### When bgp4rd itself restarts: helper only

RFC 4724 section 4.1 is the other side: the speaker that restarts
"MUST retain, if possible, the forwarding state", sets R in its next
OPEN, defers its decision until every GR peer's End-of-RIB or the
Selection_Deferral_Timer, then sends End-of-RIB. bgp4rd does none of
this (answer 2). What follows, so it is written down:

- bgp4rd never sets R, never sets F, and never defers its decision. A
  restarted bgp4rd decides on routes as they arrive, as today.
- Its kernel routes go at a clean stop and come back as its sessions
  do. A peer that helps it, with the default Restart Time 0 and no
  families, flushes bgp4rd's routes at once, as RFC 4271.
- A node file that advertises a Restart Time above 0 makes a helping
  peer keep and forward to bgp4rd's routes while bgp4rd is down. That
  is a test of the peer, and it drops traffic; `docs/daemon.md` says so
  beside the key.
- The restarting side is tested the other way round: `bgp4r-sim` plays
  the restarting peer, with the R and F bits its codec already builds,
  and FRR 10.7.1 restarts its own bgpd in `gr-lab`.

Building it later means keeping the kernel routes across a restart,
reading them back at start, marking them stale, and holding the
decision. It is not in P8's pull requests.

### Tests

- Unit, on a manual clock: each timer, each F bit case, consecutive
  restarts with and without N, End-of-RIB per family.
- Unit: the Hard Reset's encoding, and that a received one flushes.
- Functional: bgp4rd with `graceful_restart` and `bgp4r-sim` as the
  peer, running each behaviour below. A third session, a plain
  `Neighbor`, watches what bgp4rd advertises: nothing is withdrawn
  while routes are stale and kept.
- Interop: FRR 10.7.1 with `bgp graceful-restart` (its bgpd has
  `restart-time`, `stalepath-time`, `select-defer-time` and
  `bgp_graceful_restart_notification`, measured). FRR restarts its bgpd
  (the container's `frr` service), bgpd keeps the routes and forwards.
  Then bgpd as the helper, with bgp4r-sim as the restarting peer.

### Behaviours

GR is about time and sessions, not a malformed message, so its cases
are behaviours (routescope's `protocol-conventions.md`, part 3), run by
`bgp4r-sim` as `POST /api/behaviour {name, peer, ...}`:

| Name | What the sim does | RFC expects of the receiver | Section |
| --- | --- | --- | --- |
| `gr_restart` | drops TCP, comes back with R and F set, resends, End-of-RIB | keep stale, replace, purge the rest at End-of-RIB | 4724 4.2 |
| `gr_restart_no_f` | the same with F clear | remove stale routes of that family at once | 4724 4.2 |
| `gr_restart_family_missing` | comes back without a family | remove that family's stale routes at once | 4724 4.2 |
| `gr_never_back` | drops TCP and stays away | remove stale routes at the Restart Time | 4724 4.2 |
| `gr_no_eor` | comes back, never sends End-of-RIB | remove what is stale at the stale timer | 8538 4.1 |
| `gr_new_connection` | opens a second connection, old session still up | close the old one, no NOTIFICATION, keep the new | 4724 4.2, 5 |
| `gr_consecutive` | restarts twice, no N | routes stale from the first restart are deleted | 4724 4.2 |
| `gr_consecutive_n` | restarts twice, N exchanged | they are kept | 8538 4.1 |
| `gr_graceful_cease` | N exchanged, sends Cease 6/6 | Receiving Speaker rules: keep, stale | 8538 4 |
| `gr_hard_reset` | N exchanged, sends Cease 6/9 wrapping 6/2 | flush, RFC 4271 | 8538 3.2 |
| `gr_notification_no_n` | no N, sends Cease 6/6 | flush, RFC 4271 | 4724 4 |

Fault-catalog entries, one message each, in `BGP::Fault::GR`:

| Name | What is sent | RFC expects | Section |
| --- | --- | --- | --- |
| `hard_reset_empty` | Cease 6/9 with no data | terminate the session as RFC 4271 | 8538 3.2 |
| `hard_reset_unknown_inner` | Cease 6/9 wrapping 99/99 | terminate the session as RFC 4271 | 8538 3.2 |

### routescope shows

The peer row's GR state (`helper`, `restarting peer`, the restart and
stale timers left), stale counts per family, the stale flag on routes,
and `gr` events in the timeline.

## 4. Long-lived graceful restart, the helper side (RFC 9494)

### The RFC

Section 4.2: after the Restart Time, "the LLGR period is said to have
begun". For each family with a non-zero Long-Lived Stale Time (LLST),
start that timer, delete the family's stale routes when it ends,
attach LLGR_STALE to what is kept, and remove routes carrying NO_LLGR.
The routes are re-advertised, since their community changed. Section
4.3: a route with LLGR_STALE is "the least preferred in route
selection", "SHOULD NOT be advertised to any neighbor from which the
Long-Lived Graceful Restart Capability has not been received", and
keeps its LLGR_STALE when sent on. Section 4.4: least preferred loses
to anything that is not. Section 4.5: an LLGR capability without a GR
one is ignored. Section 4.6 is an optional partial deployment
(NO_EXPORT, LOCAL_PREF 0, to internal peers).

### What to build

```yaml
    graceful_restart: {}
    long_lived_graceful_restart:
      families: [ipv4_unicast, vpnv4_unicast]   # listed with LLST 0 and F clear
      max_stale_time: 86400                      # 4.2: "MAY be reduced by local configuration"
```

- Advertise the LLGR capability, which needs `graceful_restart` too
  (4.1). The key is refused without it.
- **The families are listed with a Long-Lived Stale Time of 0 and F
  clear**, for the reason the Restart Time is 0 in section 3: bgp4rd is
  a helper only and keeps no routes in the kernel across its own
  restart, so a peer must not keep ours. Section 4.2: "if the Long-Lived
  Stale Time is zero and the Restart Time is nonzero, only the
  procedures of GR would apply", and with both 0 "only those of the base
  BGP specification". The families are still listed: a peer decides by
  the capability it received whether to send us LLGR_STALE routes
  (4.3), and the families say which. `max_stale_time` caps the LLST a
  peer advertises to us.
- After the restart timer, start the LLST per family, attach
  LLGR_STALE, drop NO_LLGR routes, run the decision.
- The decision gains a first step: a route carrying LLGR_STALE loses
  to any route without it (4.4). This is a new elimination in
  `Decision#best`, named `llgr_stale`, beside the four reasons it has.
- Export: a route with LLGR_STALE is never sent to a peer that did not
  advertise LLGR to us (4.3), internal or external. The section 4.6
  exception, NO_EXPORT and LOCAL_PREF 0 toward internal peers, is not
  built (answer 5). What such a peer sees:
  - when the LLGR period begins, a withdrawal of each route that went
    stale, unless another route, not stale, is best for that prefix;
  - when the restarting peer comes back and re-sends a route, the
    route again, without LLGR_STALE;
  - a route that arrived with LLGR_STALE from another LLGR peer, never.
- A route received with LLGR_STALE is least preferred too (4.3).
- **The peer that decides is the one we received a capability from.**
  A `long_lived_graceful_restart` entry in our own `capabilities` list
  does not make a peer LLGR-capable in our eyes.
- On the new session, the LLST timer runs on until that family's
  End-of-RIB (4.2: "The timer is neither stopped nor updated until the
  EoR marker is received").

### Tests

- Unit, manual clock: the two periods in series; Restart Time 0 (only
  LLGR); LLST 0 (only GR); NO_LLGR removed; LLGR without GR ignored.
- Unit: the decision with one LLGR_STALE route and one without.
- Functional: three bgp4rd, A helper, B restarting (by the sim), C a
  peer without LLGR. C sees the route withdrawn when the LLGR period
  begins, and an internal C too; a peer D with LLGR sees it again with
  LLGR_STALE.
- Unit: no route leaves with NO_EXPORT added or LOCAL_PREF set to 0 by
  LLGR, since section 4.6 is not built.
- Interop: FRR 10.7.1 has `bgp long-lived-graceful-restart stale-time`
  and `bgp_attr_add_llgr_community` (measured), so FRR is the other
  helper, and the restarting peer.

### Behaviours and catalog

| Name | Kind | RFC expects | Section |
| --- | --- | --- | --- |
| `llgr_long_restart` | behaviour: away past the Restart Time, back before the LLST | LLGR_STALE attached, least preferred, back to normal at End-of-RIB | 9494 4.2 to 4.4 |
| `llgr_never_back` | behaviour: away past Restart Time plus LLST | routes deleted at the LLST | 9494 4.2 |
| `llgr_no_llgr_route` | behaviour: one route carried NO_LLGR | removed when the LLGR period begins | 9494 4.2 |
| `llgr_without_gr` | catalog: OPEN with LLGR and no GR | ignore the LLGR capability | 9494 4.5 |
| `llgr_reserved_flags` | catalog: LLGR flags with reserved bits set | ignore them | 9494 3.1 |

### routescope shows

The LLGR period on the peer row, the LLST left per family, and an
LLGR_STALE badge on routes.

## 5. GTSM (RFC 5082)

### The RFC

Section 3: GTSM for BGP "SHOULD NOT be enabled by default". When it is,
packets are sent with TTL 255, and on receipt packets of the session
whose TTL is outside the expected range are "Dangerous" and "MAY" be
dropped.

### Measured

Ruby 3.3.8 on ospflab, and Ruby 3.4.13 in `bgp4r-lab:latest`, over
loopback, as uid 1000 and as root in the container:

- `Socket::IP_MINTTL` is defined (21). `IPV6_MINHOPCOUNT` is not; Linux's
  value is 73 (`/usr/include/linux/in6.h`).
- With `IP_MINTTL` 255 on the **listening** socket and the client's
  `IP_TTL` 255, the session comes up. With the client at 254, the
  connect times out. The same for IPv6 with 73 and
  `IPV6_UNICAST_HOPS`.
- `/proc/net/netstat` has `TCPMinTTLDrop`.

Measured again while building it, the same way:

- An accepted socket starts with its listener's minimum, and a minimum
  set on it after `accept` holds: with the listener at 253, a client at
  254 completes the handshake, and its data is dropped once the
  accepted socket is set to 255.
- The SYN-ACK goes out with the **listener's** TTL. A client whose own
  minimum is 255 connects only when the listener sends at 255.
- `IP_MINTTL` on a dual-stack IPv6 listener drops IPv4 clients below it.
- `IP_TTL` and `IPV6_UNICAST_HOPS` set to -1 read back as 64, the
  kernel's default.

### What to build

```yaml
    ttl_security: 1     # hops; 1 = directly connected, minimum TTL 255
```

- The minimum is 256 minus the hops. Set `IP_TTL` (or
  `IPV6_UNICAST_HOPS`) to 255 and `IP_MINTTL` (or `IPV6_MINHOPCOUNT`)
  to the minimum on the dialling socket before `connect`.
- **One listener for all peers** (answer 7). It sends at 255 when any
  of its peers has `ttl_security`, since its SYN-ACK goes with its own
  TTL. It drops a SYN below a minimum only when **every** passive peer
  on it has `ttl_security`, and then at the loosest: with
  `ttl_security: 1` on one peer and 3 on another, it takes 253. A
  single peer without `ttl_security` means no minimum on the listener,
  since that peer's SYN arrives at its sender's default TTL (64 on
  Linux) and a minimum would drop it. As soon as a connection is
  accepted and matched to its peer, bgp4rd sets that socket's minimum to
  the peer's own, and its TTL to 255, before it reads the OPEN. A
  non-GTSM peer's socket gets no minimum and the default TTL back.
  (The first draft of this section took the GTSM peers' minimum alone,
  which would have dropped every SYN from a passive peer without GTSM.
  Building it found that.)
- What that means, written down in `docs/daemon.md`:
  - The handshake (SYN and the ACK that completes it) is checked at the
    listener's looser minimum, or not at all on a listener with a
    non-GTSM peer. Every segment after the accept is checked at the
    peer's own.
  - A peer with `ttl_security: 1` whose packets arrive with TTL 254 or
    253 can complete the handshake when another peer allows 3 hops.
    Its first data segment is dropped (`TCPMinTTLDrop` grows) and no
    OPEN arrives, so the session never reaches Established. Measured,
    and held by `test/functional/gtsm_test.rb`.
  - When every GTSM peer has the same hops, which is every lab today
    (`ttl_security: 1`), the listener and the peer's socket agree and
    nothing passes that should not.
  - The VRF listener is its own listener, with its own minimum from its
    own peers.
- That a minimum set after `accept` holds is measured, above.

### Tests

- Functional, loopback: the measurement above as a test. It needs no
  privilege. Built as `test/functional/gtsm_test.rb`: a peer at 255
  comes up, one at 254 is never heard, the listener answers at 255 (and
  at the default without GTSM, the control), the shared listener at 1
  and 3 hops, a non-GTSM peer beside a GTSM one, and an active peer
  dialling at 255 (and at the default without GTSM).
- Interop: FRR 10.7.1's `neighbor X ttl-security hops 1` (measured in
  its bgpd), bgpd and bgp4rd on a veth pair in a lab.
- A lab check that a peer two hops away with `ttl_security: 1` does
  not come up, and `TCPMinTTLDrop` grows.

### Behaviours

GTSM came first in the build order (answer 1), before `bgp4r-sim` has
its `/api/behaviour` path, which pull request 3 adds. Until then each
case below is a functional test over loopback; pull request 3 makes
them behaviours too.

| Name | What the sim does | Expect | Section |
| --- | --- | --- | --- |
| `gtsm_low_ttl` | dials with TTL 254 | no session | 5082 3 |
| `gtsm_ok` | dials with TTL 255 | session | 5082 3 |
| `gtsm_shared_listener` | toward a bgp4rd with peers at 1 and 3 hops, dials as the 1-hop peer with TTL 254 | handshake completes, no OPEN read, no session, `TCPMinTTLDrop` grows | 5082 3 |

### routescope shows

`ttl_security` on the peer row, and the namespace's `TCPMinTTLDrop`.

## 6. TCP MD5 (RFC 2385) and TCP-AO (RFC 5925)

### The RFCs

RFC 2385 section 2: each segment carries an MD5 digest over the
pseudo-header, header, data and a key; "A failing comparison must
result in the segment being dropped and must not produce any response
back to the sender". RFC 5925 obsoletes it (section 8): "TCP
implementations that support TCP MD5 MUST support TCP-AO", and "A TCP
implementation MUST NOT use both TCP-AO and TCP MD5 for a particular
TCP connection". A TCP-AO key is a Master Key Tuple (section 3.1): a
connection identifier, an option flag, a SendID and a RecvID, a master
key, and algorithms. Section 5.1 names the MAC algorithms through RFC
5926, which I have not read.

### Measured

The same two Rubies, loopback, IPv4 and IPv6. The script is in
"Measurements".

- `Socket::TCP_MD5SIG` is defined (14). `TCP_MD5SIG_EXT` (32) and the
  `TCP_AO_*` options (`TCP_AO_ADD_KEY` 38, `TCP_AO_DEL_KEY` 39,
  `TCP_AO_INFO` 40) are not, and are taken from
  `/usr/include/linux/tcp.h`.
- The kernel, 7.0.0-43-generic, has `CONFIG_TCP_MD5SIG=y` and
  `CONFIG_TCP_AO=y`. `/proc/crypto` lists `hmac(sha1)` and `cmac(aes)`.
- `struct tcp_md5sig` packed from Ruby is 216 octets: a 128-octet
  sockaddr storage, flags, prefix length, key length, ifindex, an
  80-octet key. Set on the listener for the peer's address, and on the
  dialling socket before `connect`.
- `struct tcp_ao_add` is 288 octets. With `set_current` and `set_rnext`
  both set on both sockets, `setsockopt` gave `EINVAL`. With both clear
  it worked. Which of the two sockets refused is not yet measured.
- Results, MD5 and TCP-AO alike: both keys equal, the session carries
  data; a key on the listener only, or two different keys, the connect
  times out; no keys, it connects. A TCP-AO listener and an MD5 client
  never connect. TCP-AO worked with `hmac(sha1)` and `cmac(aes128)`,
  MAC length 12.
- No privilege is needed: it worked as uid 1000.
- `/proc/net/netstat` has `TCPMD5NotFound`, `TCPMD5Unexpected`,
  `TCPMD5Failure`, `TCPAOGood`, `TCPAOBad`, `TCPAOKeyNotFound` and
  `TCPAORequired`.
- FRR 10.7.1's bgpd has `neighbor %s password %s` and
  `bgp_md5_set_password`. It has no TCP-AO command: no string with
  `tcp-ao` or `TCP_AO` in its bgpd.

So a Ruby daemon can set both, with `setsockopt` and `pack`, and no gem.

Measured again while building 6a, 2026-11-25, the same kernel, through
`bgp/daemon/tcp_auth.rb`:

- Which counter grows tells why a session is down. Our key, the peer
  sends no digest: `TCPMD5NotFound`. The peer sends a digest, we have
  no key for it: `TCPMD5Unexpected`. Two keys: `TCPMD5Failure`.
- A listener holds keys per address. A peer without a key connects to a
  listener that has another peer's.
- A dual-stack IPv6 listener refuses an IPv4 address for a key
  (`EINVAL`). Under the IPv4-mapped address, `::ffff:a.b.c.d`, it takes
  it and checks it.
- An 80-octet key works; 81 gives `EINVAL`.
- **A VRF needs no ifindex.** In a network namespace with a VRF device,
  a listener and a client both bound to it with `SO_BINDTODEVICE`, and
  keys set with plain `TCP_MD5SIG`: the same key connects, no key or
  another key does not. This was run as root, since making a VRF needs
  it. So `TCP_MD5SIG_EXT` is not needed for a CE session.

### What to build

```yaml
    password: s3cret                # TCP MD5
    # or
    tcp_ao:
      keys:
        - { send_id: 1, recv_id: 1, key: s3cret, algorithm: hmac(sha1), mac_length: 12 }
```

- Pull request 6a, MD5: the `password` key. `bgp/daemon/tcp_auth.rb`
  packs the struct and sets it on the listener (per peer) and the
  dialling socket. `password` and `tcp_ao` together are refused (RFC
  5925 section 8).
- Pull request 6b, TCP-AO: the `tcp_ao` key, one or more keys, the
  first current. Key rollover (`TCP_AO_INFO`'s current and rnext) is a
  later step, not in 6b.
- A VRF socket, bound with `SO_BINDTODEVICE`, needs no ifindex for
  MD5: measured in 6a, above. TCP-AO's `TCP_AO_KEYF_IFINDEX` is 6b's to
  measure.
- The key is never shown in an answer about the session: the peer row
  says `auth: md5` or `auth: tcp-ao`, never the key, and a refused key's
  error gives its length, not the key.
- **`show.configuration` carries the key, as the file does.** This
  changed while building 6a. Rendering it as `*` would break
  `config.replace`: a configuration read and sent back would set the
  key to `*`. ospfd answers its keys in clear for the same reason, and
  routescope's driver masks them (`Drivers::Ospfd::SECRETS`). The set
  line `set neighbors ADDRESS password KEY` has the whitespace such a
  mask wants. So routescope's `Drivers::Bgp4rd` must mask `password`
  before a lab uses it; it does not yet.
- A key cannot change in a commit: restart class, since the listener
  holds the passive peers' keys from when bgp4rd starts. Changing a key
  live is a later step, with TCP-AO's rollover.

As built, 6a: `bgp/daemon/tcp_auth.rb` (`TcpAuth.check`, `md5sig`,
`md5`), `password` on `Peer`, keys on each listener for its passive
peers, the key on `dial_socket` before connect, `auth` on the peer row,
and the restart reason in `candidate.rb`.
- **The same code serves the RTR client** (section 7): RFC 8210
  section 9 lists TCP-AO as the SHOULD and MD5 as a MAY for RTR.

### Tests

- Functional, loopback, no privilege: the measured matrix as tests.
  Built as `test/functional/tcp_auth_test.rb`: the same key comes up;
  no key, another key, and a digest where we have none are each never
  heard, each with its counter; a peer without a key shares the
  listener; an IPv4 peer of a dual-stack listener is keyed; an active
  peer signs its SYN (and does not without `password`, the control).
- Interop: MD5 against FRR's `neighbor X password`, both directions.
  Built as `test/functional/lab/md5_frr_test.rb`, in the `frr` lab
  group, run against 10.5.1 on ospflab: FRR dials, bgp4rd dials, and
  two keys stay down. Without FRR's key both directions fail, which was
  checked. TCP-AO between two bgp4rd only, since FRR 10.7.1 has none.
- Found while building, not fixed here: on a dual-stack listener
  (`listen_address: '::'`) an IPv4 neighbor's session never comes up,
  key or none. The listener matches by `remote_address`, which there is
  `::ffff:127.0.0.1`, and no neighbor has that address.

### Behaviours

As with GTSM, these are functional tests until pull request 3 gives
`bgp4r-sim` its behaviours.

| Name | What the sim does | Expect | Section |
| --- | --- | --- | --- |
| `md5_wrong_key` | dials with another key | no session, no reply, `TCPMD5Failure` grows | 2385 2 |
| `md5_missing` | dials without a key | no session, `TCPMD5NotFound` grows | 2385 2 |
| `md5_unexpected` | dials with a key toward a neighbor with no `password` | no session, `TCPMD5Unexpected` grows | 2385 2 |
| `ao_wrong_key` | another TCP-AO key | no session, `TCPAOBad` grows | 5925 7.5 |
| `ao_md5_mix` | MD5 toward a TCP-AO peer | no session | 5925 8 |

### routescope shows

The peer's `auth` kind, and the kernel counters for the namespace. A
session that never comes up because of a key shows why, from the
counters.

## 7. RPKI: RTR and origin validation (RFC 8210, RFC 6811)

### The RFCs

RFC 6811 section 2 defines a VRP (prefix, length, max length, origin
AS), Covered and Matched, and three states: "NotFound: No VRP Covers
the Route Prefix. Valid: At least one VRP Matches the Route Prefix.
Invalid: At least one VRP Covers the Route Prefix, but no VRP Matches
it." The origin AS is the last AS of a final AS_SEQUENCE, our own AS
for a confederation segment or an empty path, and "NONE" otherwise.
"An implementation MUST NOT exclude a route from the Adj-RIB-In or from
consideration in the decision process as a side effect of its
validation state, unless explicitly configured to do so." Section 3:
policy MUST be able to match and set the state. Section 4: when a VRP
is added or removed, the affected prefixes MUST be validated again.

RFC 8210 is RTR version 1: PDUs (section 5: Serial Notify, Serial
Query, Reset Query, Cache Response, IPv4 Prefix, IPv6 Prefix, End of
Data, Cache Reset, Router Key, Error Report), the timers in End of Data
(section 6: Refresh, default 3600 s; Retry, 600 s; Expire, 7200 s; the
router "MUST NOT retain the data past" Expire), version negotiation
(section 7), and error codes 0 to 8 (section 12), most fatal. Section
9: routers "MUST implement unprotected transport over TCP using a
port, rpki-rtr (323)", and SHOULD use TCP-AO when they can.

### Measured

- No RPKI cache image is on ospflab (`docker images`: no routinator,
  stayrtr, gortr or rpki-client).
- FRR 10.7.1 has `bgpd_rpki.so`, linked to `librtr.so.0.8.0`, with
  `rpki cache tcp`, `rpki cache ssh` and `match rpki
  <valid|invalid|notfound>`. Neither `bgpd_rpki.so`
  nor librtr 0.8.0 has the string `aspa`.

### What to build

- **7a, the RTR codec**, `bgp/rtr/`: every PDU of RFC 8210 section 5,
  versions 0 and 1, built four ways, `Unknown` for a PDU type it does
  not know, the `to_hash` catalog entries, a `validation.rb` of RTR
  findings (wrong length, unknown type, unexpected version), and
  `BGP::Fault::RTR` (below).
- **7b, an RTR cache in Ruby**, `bgp4r-rtr`: serves VRPs from a YAML
  file on port 323 (or another), answers Reset and Serial Queries,
  sends Serial Notify when the file changes, and takes `POST
  /api/fault` and `/api/behaviour` as the injector. It is the cache in
  our labs and the cache FRR's `bgpd_rpki` talks to. It lives in bgp4r
  (answer 3); "Where the two programs live" below says what follows.
- **7c, origin validation in bgp4rd**:

  ```yaml
  rpki:
    caches: [{ address: 10.0.0.9, port: 323, preference: 1 }]
    invalid: accept      # accept | prefer_less | reject
    mark_ibgp: false     # RFC 8097 extended community toward internal peers
  ```

  An RTR client per cache, a VRP table, and a validation state on each
  route of IPv4 and IPv6 unicast, computed on receipt and again for
  the affected prefixes when a VRP changes (6811 4). `mark_ibgp`
  attaches the RFC 8097 community, whose codec exists.

  **`invalid` is one setting for the whole daemon** (answer 4). bgp4rd
  has no route policy language, and a per-neighbor setting would be the
  start of one, which needs a spec of its own. What follows:

  - `accept`, the default: the state is computed and shown, and nothing
    else changes. RFC 6811 section 2: a route is not excluded "as a
    side effect of its validation state, unless explicitly configured
    to do so".
  - `prefer_less`: a new elimination in `Decision#best`, `rpki_invalid`,
    before LOCAL_PREF: an Invalid route loses to any route that is
    Valid or NotFound. LLGR's `llgr_stale` (section 4) comes first, so a
    fresh Invalid route still beats an LLGR_STALE Valid one.
  - `reject`: Invalid is ineligible, a fifth reason in
    `Decision#ineligible_reason`. The route stays in the Adj-RIB-In, so
    a VRP change can bring it back (6811 4).
  - The setting applies to every unicast route bgp4rd validates:
    received from any peer, internal or external, reflected or not, and
    routes bgp4rd originates (6811 2: the lookup "SHOULD also be
    applied to routes that are redistributed into BGP"). No neighbor
    can be left out.
  - Other families (VPN, EVPN, BGP-LS, labeled) are not validated. RFC
    6811 section 2 says such a route's state "SHOULD" be NotFound. The
    view shows them as NotFound with `validated: false`, so a reader
    can tell "no VRP covers it" from "never looked".
  - With `rpki` configured and no cache synchronised yet, every route is
    NotFound, so `reject` rejects nothing until the first End of Data.
  - When the data expires (8210 6, the Expire Interval), the VRPs go,
    every route becomes NotFound, and routes `reject` had removed come
    back into the decision. An event says so.
  - Without the `rpki` key, no state is computed or shown, as today.
- **ASPA, later.** The draft `draft-ietf-sidrops-aspa-verification-31`
  (17 November 2026) checks the AS_PATH against provider sets. It
  applies to IPv4 and IPv6 unicast on eBGP only (its section 6.2),
  recommends BGP Role (RFC 9234, section 6.3), whose capability bgp4r
  has, and makes an Invalid path ineligible but kept in the Adj-RIB-In
  (section 5.7). Its data reaches the router by a later RTR version,
  which is not in RFC 8210 and which I have not read. It fits as a
  second validator beside ROV, on the same RTR client and table, after
  RTR's next version is an RFC. FRR 10.7.1 cannot be its interop peer
  (no `aspa` in its RPKI code). It is not in P8's pull requests.

### Tests

- Unit: each PDU against RFC 8210's diagrams; the validation of RFC
  6811 section 2, each case of the origin AS (AS_SEQUENCE, AS_SET last,
  confederation, empty path), max length, AS 0.
- Unit, manual clock: Refresh, Retry and Expire; data dropped at
  Expire.
- Functional: `bgp4r-rtr` and bgp4rd over loopback, a VRP added and
  removed, the route's state following.
- Interop: `bgp4r-rtr` as FRR 10.7.1's cache. FRR and bgp4rd receive
  the same routes and the same VRPs; their states must agree, route by
  route.

### Fault catalog

`BGP::Fault::RTR`, sent by `bgp4r-rtr` to a router:

| Name | What is sent | RFC expects of the router | Section |
| --- | --- | --- | --- |
| `rtr_unknown_pdu` | PDU type 99 | Error Report 5, drop the session | 8210 12 |
| `rtr_bad_version` | version 9 | Error Report 4, drop | 8210 12 |
| `rtr_unexpected_version` | version 0 after 1 was negotiated | Error Report 8, drop | 8210 12 |
| `rtr_withdraw_unknown` | a withdrawal of a prefix never announced | Error Report 6, drop | 8210 12 |
| `rtr_duplicate_announce` | the same prefix announced twice | Error Report 7, drop | 8210 12 |
| `rtr_corrupt_length` | a Length that overruns | Error Report 0, drop | 8210 12 |

Behaviours: `rtr_no_data` (Error Report 2, "No Data Available": not
fatal, retry), `rtr_silent` (the cache stops answering: the data is
used until Expire, then dropped, 8210 6), `rtr_cache_reset` (Cache
Reset: the router sends a Reset Query, 8210 5.9).

### routescope shows

Each cache's session, serial and VRP count; a Validation column on
every unicast route; events on VRP changes and on routes that changed
state. The column is the one FRR fills too, so a route compares across
both.

## 8. BMP (RFC 7854, RFC 9069)

### The RFCs

RFC 7854 section 3.1 lists seven messages: Route Monitoring, Peer
Down, Stats Reports, Peer Up, Initiation, Termination, Route
Mirroring. Section 3.2: "No BMP message is ever sent from the
monitoring station to the monitored router"; which side dials is
configuration, and retries back off, "a default initial backoff of 30
seconds and a maximum of 720 seconds is suggested". Section 3.3: the
router "MUST begin by sending an Initiation message", then a Peer Up
for each Established peer, the Adj-RIBs-In, and "Once it has sent all
the routes for a given peer, it MUST send an End-of-RIB message for
that peer". Section 4.1: version 3, and "A BMP implementation MUST
ignore unrecognized message types upon receipt". Section 5: pre-policy
routes have the L flag clear, post-policy routes set. Section 4.9 gives
Peer Down's five reasons. RFC 9069 adds the Loc-RIB as peer type 3.

### Measured

- No BMP station image is on ospflab.
- FRR 10.7.1 has `bgpd_bmp.so` with `bmp targets`, `bmp connect HOSTNAME
  port (1-65535)`, `bmp listener`, `bmp monitor <ipv4|ipv6|l2vpn>
  <unicast|multicast|evpn|vpn> <pre-policy|post-policy|loc-rib>`, `bmp
  stats interval` and `bmp mirror`. So FRR is a monitored router that
  dials a station. It is not a station.

### What to build

- **8a, the BMP codec**, `bgp/bmp/`: the common header, the per-peer
  header with its flags and the Loc-RIB peer type, the seven messages,
  the Information and Termination TLVs, the stats types. Four ways in,
  `Unknown` for a type it does not know, BGP PDUs inside parsed with
  bgp4r's own classes.
- **8b, a BMP station in Ruby**, `bgp4r-bmp`: listens (or dials),
  decodes every message, and writes JSON lines, one per message, with
  the inner BGP message's `to_hash`. It is how we read FRR's
  `bgpd_bmp`, and how we check bgp4rd's. Its HTTP API serves what it
  received (`/api/peers`, `/api/routes`, `/api/events`). It lives in
  bgp4r (answer 3).
- **Its JSON lines are a contract.** routescope will read them as a
  source of routes (answer 8), so `docs/bmp.md` documents the format
  from pull request 8b, a test holds the document to the output, and a
  change to it is additive only, as routescope's other inputs are.
- **8c, BMP in bgp4rd**, the monitored router:

  ```yaml
  bmp:
    stations: [{ address: 10.0.0.9, port: 5000 }]   # bgp4rd dials
    monitor: [pre_policy]                             # later: post_policy, loc_rib
    stats_interval: 60
  ```

  Initiation (sysName, sysDescr); a Peer Up per Established peer with
  both OPENs; each Adj-RIB-In as Route Monitoring, pre-policy, then an
  End-of-RIB per peer; each later UPDATE as Route Monitoring; Peer Down
  with its reason (1 with our NOTIFICATION, 2 with the FSM event, 3
  with theirs, 4 for a dropped connection); a few stats (prefixes in
  the Adj-RIB-In, updates treated as withdraw); Termination on stop.
  Backoff 30 s to 720 s. Data from the station is read and dropped.
  Post-policy, the Loc-RIB (RFC 9069) and Route Mirroring come after,
  each a small pull request.

### Tests

- Unit: each message against the RFC's diagrams; a capture from FRR's
  `bgpd_bmp` parsed and written back byte for byte.
- Functional: bgp4rd to `bgp4r-bmp` over loopback: Initiation first,
  Peer Up per peer, the dump with End-of-RIB, a withdrawal, Peer Down
  with each reason.
- Interop: FRR 10.7.1 with `bmp connect` toward `bgp4r-bmp`; FRR and
  bgp4rd peer with the same `bgp4r-sim`; the station's two views of
  that peer must hold the same routes.

### Fault catalog

`BGP::Fault::BMP`, sent to a station (ours, or another we have later):

| Name | What is sent | RFC expects of the station | Section |
| --- | --- | --- | --- |
| `bmp_unknown_type` | message type 99 | ignore it, keep the session | 7854 4.1 |
| `bmp_version_0` | version 0 | not to be sent; record what the station does | 7854 4.1 |
| `bmp_no_initiation` | Peer Up before Initiation | record what the station does | 7854 3.3 |

The last two are "MUST" on the router, not rules for the station, so
the matrix records what each station does rather than asserting it.

### routescope shows

The stations bgp4rd sends to and their state. Later, in routescope's
own spec and after pull request 8b (answer 8): `bgp4r-bmp`'s view of
any router that speaks BMP, FRR included, as a source for the RIB pane,
with no driver of its own for that router. Nothing in P8 waits for it.

## Where the two programs live

`bgp4r-rtr` and `bgp4r-bmp` live in bgp4r, beside `bgp4r-sim` (answer
3). BMP carries BGP messages, so the station parses them with bgp4r's
own classes, and RTR serves BGP only. bfd4r has a repository of its own
because three routers share it; these two have one user. What follows:

- The code is `bgp/rtr/` and `bgp/bmp/`, the programs `exe/bgp4r-rtr`
  and `exe/bgp4r-bmp`, added to the gemspec's `executables` beside the
  four there today. They ship and are versioned with bgp4r.
- No runtime gem is added. Both use the standard library, as the rest
  of bgp4r does.
- Both are in the `lab-node` image, so a lab node runs either by its
  command, as it runs `bgp4rd` or `bgp4r-sim` today. No new image.
- Their HTTP API follows `bgp4r-sim`'s (`bgp/sim/http.rb`): port 8080
  by default, a POST refused without `X-BGP4R: routescope`, a refusal
  as a 4xx with `{"error": ...}`. Each runs in its own container, so
  the ports do not collide.
- Their tests are in bgp4r's tiers and run in its CI.
- If another repository ever needs RTR or BMP, the code moves to a gem
  of its own then, as bfd4r's did.

## Timer defaults

Answer 6: the RFC's values, not FRR's.

| Timer | Default | From |
| --- | --- | --- |
| Restart Time we advertise | 0 | helper only (section 3) |
| Stale timer, for a peer's routes after it restarts | 180 s | RFC 8538 section 4.1 |
| Refresh stale bound, BoRR without EoRR | 180 s | the stale timer's value reused; RFC 7313 gives none |
| Long-Lived Stale Time we advertise | 0 | helper only (section 4) |
| RTR Refresh, Retry, Expire before the first End of Data | 3600, 600, 7200 s | RFC 8210 section 6 |
| BMP reconnect backoff | 30 s, doubling to 720 s | RFC 7854 section 3.2 |

`gr-lab` measures FRR 10.7.1's defaults for the same timers (`show bgp
neighbor` and `show running-config` with defaults) and writes them in
its `ABOUT.md`, beside ours, so a reader sees why the two differ. They
are not copied.

## Pull requests

In build order (answer 1). Each is one topic, with its tests, its
catalog entries or behaviours, `docs/daemon.md`'s new keys and methods,
and `CLAUDE.md`'s table.

| Order | # | Pull request | Needs |
| --- | --- | --- | --- |
| 1 | 5 | GTSM, `ttl_security`; built | – |
| 2 | 6a | TCP MD5, `password`; built | – |
| 3 | 1 | End-of-RIB sent and received, `end_of_rib`; built | – |
| 4 | 2 | Route refresh answered, enhanced refresh, the stale mark, `BGP::Fault::REFRESH`: in three parts, all built | 1 |
| 5 | 3 | GR helper, RFC 8538, Hard Reset, `BGP::Fault::GR`, the first behaviours in `bgp4r-sim`, GTSM's among them | 2 |
| 6 | 7a | RTR codec, `BGP::Fault::RTR` | – |
| 7 | 7b | `bgp4r-rtr`, the cache and injector | 7a |
| 8 | 7c | Origin validation in bgp4rd, `rpki` | 7b |
| 9 | 8a | BMP codec | – |
| 10 | 8b | `bgp4r-bmp`, the station, `docs/bmp.md` | 8a |
| 11 | 8c | BMP in bgp4rd, `bmp`, pre-policy | 1, 8b |
| 12 | 4 | LLGR helper, the `llgr_stale` decision step | 3 |
| any | 6b | TCP-AO, `tcp_ao` | 6a |
| with each | 9 | The labs (below), each with its feature's last pull request | each feature's |

The order is the order of merging. Pull requests with no "Needs" in
common may be written side by side, as 7a and 8a beside 1 to 3.

## Labs

Under the owner's rule (routescope `CLAUDE.md`, "Our own Ruby code
first"), each lab's main router is bgp4rd. FRR 10.7.1 is the interop
check, said so in each `ABOUT.md`. All in `routescope/labs/`.

| Lab | Nodes | It shows |
| --- | --- | --- |
| `gr-lab` | bgp4rd `r1` (helper), FRR `r2`, `bgp4r-sim` `s1`, bgp4rd `r3` watching | GR and LLGR: FRR restarts its bgpd, `s1` runs each behaviour; `r3` sees no withdrawal while routes are stale, and LLGR_STALE after the Restart Time |
| `rpki-lab` | `bgp4r-rtr` `c1`, bgp4rd `r1`, FRR `r2`, `bgp4r-sim` `s1` | `s1` announces a Valid, an Invalid and a NotFound prefix to both; `r1` and `r2` must agree; a VRP change flips one |
| `bmp-lab` | `bgp4r-bmp` `m1`, bgp4rd `r1`, FRR `r2`, `bgp4r-sim` `s1` | both routers report `s1` to `m1`; the two reports must match |

GTSM, MD5 and TCP-AO need no lab of their own: each lab above runs one
of its sessions with them (`r1` to `r2` with `password` and
`ttl_security`, `r1` to `r3` with `tcp_ao`). Route refresh is a scenario
in `gr-lab` (`clear bgp soft in` on FRR, `peer.refresh` on bgp4rd).

Each lab gets scenarios and a gate, and runs in routescope's CI lane
when touched, as the other bgp4r labs do. Before routescope adopts
them, they run on ospflab under the "Sharing ospflab" rules: branch
images as `NAME:SHORTSHA` through `vm-build`, an entry in
`~/vm-changes.md`, the lock for a gate.

## Measurements

On ospflab, 2026-11-25, kernel 7.0.0-43-generic, aarch64.

```sh
ruby -v                     # ruby 3.3.8
grep -E 'CONFIG_TCP_MD5SIG|CONFIG_TCP_AO' /boot/config-$(uname -r)
ruby -rsocket -e 'p %i[TCP_MD5SIG TCP_AO_ADD_KEY IP_MINTTL IPV6_MINHOPCOUNT].map { |c| [c, (Socket.const_get(c) rescue nil)] }'
ruby sockopts.rb            # natively, uid 1000
docker run --rm --network none -v $PWD/sockopts.rb:/s.rb:ro --entrypoint ruby bgp4r-lab:latest /s.rb
docker run --rm --entrypoint sh quay.io/frrouting/frr:10.7.1 -c 'ls /usr/lib/frr/modules; /usr/lib/frr/bgpd --version'
docker run --rm --entrypoint sh quay.io/frrouting/frr:10.7.1 -c 'strings /usr/lib/frr/modules/bgpd_bmp.so | grep "bmp "'
awk 'NR%2==1' /proc/net/netstat | tr ' ' '\n' | grep -E 'MD5|TCPAO|MinTTL'
```

`sockopts.rb` opens a listener and a client over loopback, sets the
options on each, and reports whether the session carries five octets.
Its result, the same in both Rubies:

```
md5 both keys 127.0.0.1: connected, data "hello"
md5 server only 127.0.0.1: no connection (connect timed out)
md5 wrong key 127.0.0.1: no connection (connect timed out)
md5 none 127.0.0.1: connected, data "hello"
ao hmac(sha1) both 127.0.0.1: connected, data "hello"
ao cmac(aes128) both 127.0.0.1: connected, data "hello"
ao server only 127.0.0.1: no connection (connect timed out)
ao wrong key 127.0.0.1: no connection (connect timed out)
ao and md5 127.0.0.1: no connection (connect timed out)
gtsm min 255, sent 255 127.0.0.1: connected, data "hello"
gtsm min 255, sent 254 127.0.0.1: no connection (connect timed out)
```

and the same lines for `::1`. It becomes the functional test of pull
requests 5, 6a and 6b.

FRR 10.7.1's modules: `bgpd_bmp.so`, `bgpd_rpki.so`,
`dplane_fpm_nl.so`, `pathd_pcep.so`, `zebra_cumulus_mlag.so`; FRR
10.2.1 has the same five.

MD5 in a VRF, for 6a. A namespace with a VRF and a dummy device
holding both addresses, then a listener and a client bound to `blue`
with `SO_BINDTODEVICE`, keyed by `TcpAuth.md5`, the listener on
10.9.0.1 for 10.9.0.2:

```sh
sudo ip netns add md5vrf
sudo ip -n md5vrf link set lo up
sudo ip -n md5vrf link add blue type vrf table 10
sudo ip -n md5vrf link set blue up
sudo ip -n md5vrf link add d0 type dummy
sudo ip -n md5vrf link set d0 master blue
sudo ip -n md5vrf addr add 10.9.0.1/24 dev d0
sudo ip -n md5vrf addr add 10.9.0.2/24 dev d0
sudo ip -n md5vrf link set d0 up
sudo ip netns exec md5vrf ruby -I. md5_vrf.rb
sudo ip netns del md5vrf
```

```
vrf "s3"/"s3": connected
vrf "s3"/nil: no connection
vrf "s3"/"xx": no connection
vrf nil/nil: connected
```

## Out of scope

- ORF (RFC 5291) on receipt.
- The GR restarting speaker (answer 2).
- RFC 9494 section 4.6, partial deployment (answer 5), and section 4.7,
  PE to CE.
- A route policy language, and RPKI settings per neighbor (answer 4).
- routescope reading `bgp4r-bmp` (answer 8): routescope's own spec.
- BGPsec (RFC 8205) and the RTR Router Key's use.
- ASPA, until RTR's next version is an RFC (section 7).
- BMP Adj-RIB-Out (RFC 8671) and Route Mirroring, after 8c.
- TCP-AO key rollover, after 6b.

## Questions, answered

The owner answered all eight on 2026-11-25. Each answer, why, and where
the spec says what it implies.

1. **The order.** End-of-RIB, refresh, GR, then RPKI, BMP, and LLGR
   last; GTSM and MD5 first, TCP-AO any time after MD5. LLGR is the
   least deployed of the set; origin validation is widely deployed,
   and routescope's priorities put first what the industry prefers.
   GTSM and MD5 are a day each, and every later lab uses them. See
   "The order, and why" and "Pull requests".
2. **Helper only.** bgp4rd does not restart gracefully itself. Labs
   test the helper; the restarting side needs the kernel routes kept
   across a restart and a held decision, for a case no lab needs.
   `bgp4r-sim` plays the restarting peer, and FRR restarts its bgpd.
   Implied: R and F never set, no families listed, a Restart Time and
   Long-Lived Stale Time of 0 by default, so no peer keeps forwarding
   to a bgp4rd that is down. See section 3, "When bgp4rd itself
   restarts", and section 4.
3. **In bgp4r.** BMP carries BGP messages and RTR serves BGP only; one
   user each, where bfd4r has three. Implied: two more executables in
   the gem and the `lab-node` image, `bgp4r-sim`'s HTTP conventions, no
   new gem. See "Where the two programs live".
4. **One RPKI setting for the whole daemon, `accept` by default.** RFC
   6811 section 2 forbids dropping a route for its state unless
   configured; a per-neighbor setting starts a policy language, which
   needs its own spec. Implied: every validated route is treated alike,
   from any peer and our own; other families NotFound with `validated:
   false`; nothing rejected before the first data or after it expires.
   See section 7, 7c.
5. **No partial deployment; withdraw only.** Section 4.6 is an optional
   workaround, and setting LOCAL_PREF 0 is a risk RFC 9494 section 5.2
   discusses; our labs control every router. Implied: a peer without
   LLGR, internal or external, sees a withdrawal when the LLGR period
   begins and never an LLGR_STALE route. See section 4.
6. **Off until configured; the RFC's timers.** A key that changes the
   wire stays off, by bgp4r's additive rule; an RFC value is easier to
   defend than another router's. Implied: a GR peer of a bgp4rd without
   the key gets RFC 4271; answering a refresh is turned on by the
   capability entry, the one case without a key; FRR's defaults are
   measured in `gr-lab` and written beside ours, not copied. See "Rules
   every pull request keeps", section 3 and "Timer defaults".
7. **One shared listener, documented.** Each accepted socket gets its
   peer's own minimum before the OPEN is read, so only the handshake
   passes at the looser value, and labs use one hop everywhere.
   Implied: the case is written down, a behaviour tests it, and the
   minimum set after `accept` is measured first. See section 5.
8. **Yes, later, in routescope's own spec.** Any router that speaks
   BMP, FRR included, would show in routescope's RIB pane without a
   driver of its own. Implied: `bgp4r-bmp`'s JSON lines are a
   documented, additive contract from pull request 8b. See section 8.
