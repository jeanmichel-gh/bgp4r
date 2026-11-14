#--
# Copyright 2026 Jean-Michel Esnault.
# All rights reserved.
# See LICENSE.txt for permissions.
#
#
# This file is part of BGP4R.
#
# BGP4R is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# BGP4R is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with BGP4R.  If not, see <http://www.gnu.org/licenses/>.
#++

# What routescope reads, **copied** from routescope, so the containerlab
# labs under routescope/labs/ can be held to it with no routescope here.
# Three topology tests read it: bgp4r_lab_topology_test.rb,
# rr_lab_topology_test.rb and fwd_lab_topology_test.rb. One copy, so they
# cannot drift apart.
#
# docs/routescope-labs.md section 12 is why this is a copy: every fact in
# this repository about that one is a read at a commit, and this suite
# cannot assert one. Not named *_test.rb, so run_lab.rb does not load it
# as a test.
module RoutescopeVocabulary

  # `Lab::KINDS`, read at routescope b8e2704 on 2026-11-03.
  # `Drivers.for` is `BY_KIND.fetch(node.kind, Linux)`, so an unknown
  # kind is a plain Linux node that answers nothing about BGP.
  KINDS = %w[ospfd frr ospfv2-sim bird srlinux
             bgp4r bgp4r-sim linux].freeze

  # The scenario language: `Scenario::BGP_ACTIONS`, `Scenario::BGP_KEYS`,
  # `Scenario::CONDITIONS` and `Scenario::COMMON`, read at routescope
  # 7eabde1 on its `claude/bgp4r-driver` branch on 2026-11-02, and then
  # from its `claude/bgp-panes` branch on 2026-11-03, which added
  # `extended_communities` and `large_communities` to the body keys,
  # `bgp_drained` and the `community` key of `bgp_prefix`. `spec`,
  # `churn`, `mp_reach`, `mp_unreach`, `specimen` and `as_path_literal`
  # are routescope #53, claude/injector-spec at 9966920, read on
  # 2026-11-05; until it merges a scenario with `spec` is refused there.
  # `link_state.unreachable` and its key `unreachable` are routescope
  # #126, read at its main 675d1ef on 2026-11-13: a scenario switches a
  # bgp4rd Producer to keep or withdraw (this repo's #325).
  BGP_ACTIONS = %w[announce attribute fault link_state.unreachable notification peer.clear peer.refresh
                   peer.start peer.stop refresh replay route.originate
                   route.withdraw session.flap session.start session.stop
                   withdraw].freeze
  BGP_KEYS = %w[afi as_path as_path_literal case churn code communities count data
                extended_communities generate hex interval large_communities
                local_pref med mp_reach mp_unreach next_hop node origin path_id peer
                prefix prefixes safi spec specimen subcode subtype unreachable].freeze
  CONDITIONS = { 'bgp_session' => %w[node peer state],
                 'bgp_routes' => %w[node count],
                 'bgp_prefix' => %w[node prefix present next_hop med as_path local_pref community],
                 'bgp_best' => %w[node prefix reason],
                 'bgp_drained' => %w[node],
                 # `ping` and `traceroute` check forwarding from inside a
                 # node, read at routescope claude/ping-traceroute on
                 # 2026-11-06. Until that merges, a scenario using either
                 # is refused there, which is fwd-lab's four.
                 'ping' => %w[node to from count reachable],
                 'traceroute' => %w[node to from hops through] }.freeze
  COMMON = %w[name continue].freeze

  # What a `pause:` step takes beside its text, `Scenario#step`'s `when
  # 'pause'` arm, read at routescope main 2026-11-06. A run with nobody
  # to press Resume skips it, so a pause costs a CI run nothing.
  PAUSE_KEYS = %w[for].freeze

  # What an `interface:` step takes beside its NODE:IFACE value,
  # `Scenario#step`'s `when 'interface'` arm, read at routescope main
  # 9615aa0 on 2026-11-06. The state is up or down, and the runner sets
  # it on the containerlab link with `Links#set`.
  INTERFACE_KEYS = %w[state].freeze

  # What routescope reads from bgp4rd's API: each method its Bgp4rd
  # driver calls, and the keys it reads from the answer, as paths: "a.b"
  # a key under a key, "[]" every element of an array. A method with none
  # is one whose answer goes to the page whole, or whose success is all
  # that is read. routescope's docs/design/api-contract.md, part 3.
  #
  # Written by `rake vocabulary` in routescope at be270f3 (its #129) on
  # 2026-11-14, which notes what the driver reads while routescope's unit
  # tests run, and copied here unchanged: the "bgp4rd" section of its
  # tmp/vocabulary.json. To refresh, run that in routescope and copy the
  # section again; do not edit by hand.
  #
  # One change to routescope's recorder went with it, made in that run
  # and asked of #129: it notes a key only when the answer has it. As
  # be270f3 has it, it also noted keys the driver reads that bgp4rd never
  # sends, because one reader serves several answers (`paths` and `best`
  # on adj_out rows, `summary.announced`, which is bgp4r-sim's) or
  # because the driver merged them in itself (`prefix` and `paths` on a
  # rib path). This test found those: bgp4rd answered every other key.
  #
  # show.link_state has keys in two shapes, a page (rows[]) and a bare
  # array ([]), because routescope reads both: a bgp4rd from before
  # show.link_state was paged answered an array. routescope_api_test.rb
  # checks the shape this bgp4rd answers.
  BGP4RD = {
    "events.subscribe" => [].freeze,
    "link_state.unreachable" => [].freeze,
    "peer.clear" => [].freeze,
    "peer.refresh" => [].freeze,
    "peer.start" => [].freeze,
    "peer.stop" => [].freeze,
    "route.originate" => [].freeze,
    "route.withdraw" => [].freeze,
    "show.adj_in" => [
      "next_offset", "rows", "rows[].as_path", "rows[].best",
      "rows[].communities", "rows[].extended_communities", "rows[].from", "rows[].large_communities",
      "rows[].local", "rows[].local_pref", "rows[].med", "rows[].next_hop",
      "rows[].origin", "rows[].prefix", "total"
    ].freeze,
    "show.adj_out" => [
      "next_offset", "rows", "rows[].as_path", "rows[].communities",
      "rows[].extended_communities", "rows[].large_communities", "rows[].local_pref", "rows[].med",
      "rows[].next_hop", "rows[].origin", "rows[].prefix", "total"
    ].freeze,
    "show.fib" => [
      "fib", "fib.backend", "fib.configured", "fib.failed",
      "fib.failed[].error", "fib.failed[].prefix", "fib.skipped", "fib.skipped[].prefix",
      "fib.skipped[].reason", "fib.total", "next_offset", "rows",
      "rows[].next_hop", "rows[].prefix", "total"
    ].freeze,
    "show.link_state" => [
      "[].areas", "[].flags", "[].identifier", "[].local",
      "[].metric", "[].name", "[].peer", "[].prefix",
      "[].protocol_id", "[].remote", "[].since", "[].type",
      "next_offset", "rows", "rows[].area", "rows[].areas",
      "rows[].flags", "rows[].forwarding", "rows[].identifier", "rows[].local",
      "rows[].metric", "rows[].name", "rows[].peer", "rows[].prefix",
      "rows[].protocol_id", "rows[].remote", "rows[].route_type", "rows[].since",
      "rows[].type", "total"
    ].freeze,
    "show.peers" => [
      "[].address", "[].description", "[].flaps", "[].held",
      "[].inq", "[].outq", "[].received", "[].remote_as",
      "[].router_id", "[].sent", "[].state", "[].type",
      "[].uptime"
    ].freeze,
    "show.rib" => [
      "rows", "rows[].decided_by", "rows[].paths", "rows[].paths[].as_path",
      "rows[].paths[].best", "rows[].paths[].communities", "rows[].paths[].extended_communities", "rows[].paths[].from",
      "rows[].paths[].large_communities", "rows[].paths[].local", "rows[].paths[].local_pref", "rows[].paths[].lost_at",
      "rows[].paths[].med", "rows[].paths[].next_hop", "rows[].paths[].origin", "rows[].paths[].reason",
      "rows[].prefix"
    ].freeze,
    "show.routes" => [
      "next_offset", "rows", "rows[].as_path", "rows[].best",
      "rows[].communities", "rows[].extended_communities", "rows[].from", "rows[].large_communities",
      "rows[].local", "rows[].local_pref", "rows[].med", "rows[].next_hop",
      "rows[].origin", "rows[].paths", "rows[].prefix", "total"
    ].freeze,
    "show.status" => [
      "as", "peers", "peers[].address", "peers[].description",
      "peers[].flaps", "peers[].held", "peers[].inq", "peers[].outq",
      "peers[].received", "peers[].remote_as", "peers[].router_id", "peers[].sent",
      "peers[].state", "peers[].uptime", "router_id", "summary",
      "summary.established", "summary.peers", "summary.rib"
    ].freeze
  }.freeze
end
