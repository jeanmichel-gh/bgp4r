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
end
