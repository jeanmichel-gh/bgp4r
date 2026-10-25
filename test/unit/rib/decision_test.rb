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

require 'test/unit'
require 'bgp/rib'

class TestBgpRibDecision < Test::Unit::TestCase
  include BGP
  include BGP::Rib

  LOCAL_AS = 65001

  def peer(addr, as, router_id=addr)
    Peer.new(address: addr, remote_as: as, router_id: router_id, local_as: LOCAL_AS)
  end

  EBGP_A = Peer.new(address: '10.0.0.2', remote_as: 65002, router_id: '2.2.2.2', local_as: LOCAL_AS)
  EBGP_B = Peer.new(address: '10.0.0.3', remote_as: 65003, router_id: '3.3.3.3', local_as: LOCAL_AS)

  # A route to 10.1.0.0/16 from p. Options override one attribute at a time.
  def route(p, local_pref: nil, as_path: [p.remote_as], origin: 0, med: nil, next_hop: p.address,
            originator_id: nil, cluster_list: nil, path_id: nil, as_set: nil)
    attrs = [Origin.new(origin)]
    attrs << Next_hop.new(next_hop) if next_hop
    segs = [As_path::Segment.new(:sequence, *as_path)]
    segs << As_path::Segment.new(:set, *as_set) if as_set
    attrs << (as_path.empty? && !as_set ? As_path.new : As_path.new(*segs))
    attrs << Local_pref.new(local_pref) if local_pref
    attrs << Multi_exit_disc.new(med) if med
    attrs << Originator_id.new(originator_id) if originator_id
    attrs << Cluster_list.new(*cluster_list) if cluster_list
    Route.new('10.1.0.0/16', Path_attribute.new(*attrs), p, path_id: path_id)
  end

  def decision(**opts)
    Decision.new(local_as: LOCAL_AS, router_id: '1.1.1.1', **opts)
  end

  # Asserts that winner beats loser, decided at step, in either order.
  def assert_wins(winner, loser, step, d=decision)
    [[winner, loser], [loser, winner]].each do |routes|
      res = d.best(routes)
      assert_same(winner, res.best, "winner at #{step}")
      assert_equal(step, res.reason)
      assert_equal({ loser => step }, res.eliminated)
    end
  end

  def test_no_routes
    res = decision.best([])
    assert_nil(res.best)
    assert_equal(:no_usable_route, res.reason)
    assert_equal({}, res.eliminated)
  end

  def test_only_route
    r = route(EBGP_A)
    res = decision.best([r])
    assert_same(r, res.best)
    assert_equal(:only_route, res.reason)
  end

  def test_highest_local_pref
    # RFC 4271 section 9.1.1 and 9.1.2.
    assert_wins(route(EBGP_B, local_pref: 200, as_path: [1, 2, 3]), route(EBGP_A, local_pref: 100), :local_pref)
  end

  def test_missing_local_pref_counts_as_the_default
    assert_wins(route(EBGP_B, local_pref: 101), route(EBGP_A), :local_pref)
    assert_wins(route(EBGP_A), route(EBGP_B, local_pref: 99), :local_pref)
    assert_wins(route(EBGP_B, local_pref: 99), route(EBGP_A), :local_pref, decision(default_local_pref: 50))
  end

  def test_shortest_as_path
    # RFC 4271 section 9.1.2.2 a).
    assert_wins(route(EBGP_B, as_path: [65003]), route(EBGP_A, as_path: [65002, 7]), :as_path_length)
  end

  def test_as_set_counts_as_one
    # 65003 {1, 2, 3} has length 2, so it beats 65002 7 8.
    assert_wins(route(EBGP_B, as_path: [65003], as_set: [1, 2, 3]), route(EBGP_A, as_path: [65002, 7, 8]), :as_path_length)
  end

  def test_lowest_origin
    # RFC 4271 section 9.1.2.2 b): IGP < EGP < INCOMPLETE.
    assert_wins(route(EBGP_B, origin: 0), route(EBGP_A, origin: 1), :origin)
    assert_wins(route(EBGP_B, origin: 1), route(EBGP_A, origin: 2), :origin)
  end

  def test_lowest_med_from_the_same_neighbor_as
    # RFC 4271 section 9.1.2.2 c). Same neighbor AS 65002, two peers.
    a2 = peer('10.0.0.9', 65002, '9.9.9.9')
    assert_wins(route(a2, med: 10), route(EBGP_A, med: 20), :med)
  end

  def test_med_is_not_compared_across_neighbor_ases
    # AS 65003 has the higher MED but MED does not compare across ASes,
    # so the router ID decides: 2.2.2.2 beats 3.3.3.3.
    assert_wins(route(EBGP_A, med: 50), route(EBGP_B, med: 10), :router_id)
  end

  def test_always_compare_med
    assert_wins(route(EBGP_B, med: 10), route(EBGP_A, med: 50), :med, decision(always_compare_med: true))
  end

  def test_missing_med
    a2 = peer('10.0.0.9', 65002, '9.9.9.9')
    # RFC 4271 section 9.1.2.2 c): a missing MED is the lowest possible.
    assert_wins(route(a2), route(EBGP_A, med: 1), :med)
    # Or the highest, when asked.
    assert_wins(route(EBGP_A, med: 1), route(a2), :med, decision(missing_med_worst: true))
  end

  def test_ebgp_over_ibgp
    # RFC 4271 section 9.1.2.2 d).
    ibgp = peer('10.0.0.1', LOCAL_AS, '0.0.0.1')
    assert_wins(route(EBGP_A, as_path: [65002]), route(ibgp, as_path: [65009]), :ebgp_over_ibgp)
  end

  def test_lowest_igp_cost
    # RFC 4271 section 9.1.2.2 e).
    costs = { '10.0.0.2' => 20, '10.0.0.3' => 10 }
    d = decision(resolver: ->(nh) { costs[nh] })
    assert_wins(route(EBGP_B), route(EBGP_A), :igp_cost, d)
  end

  def test_unreachable_next_hop_is_not_used
    # RFC 4271 section 9.1.2: a route whose NEXT_HOP cannot be resolved.
    d = decision(resolver: ->(nh) { nh == '10.0.0.2' ? nil : 5 })
    a, b = route(EBGP_A, local_pref: 500), route(EBGP_B)
    res = d.best([a, b])
    assert_same(b, res.best)
    assert_equal(:only_route, res.reason)
    assert_equal({ a => :next_hop_unreachable }, res.eliminated)
    assert_equal(:next_hop_unreachable, decision.best([route(EBGP_A, next_hop: nil)]).eliminated.values.first)
  end

  def test_lowest_router_id
    # RFC 4271 section 9.1.2.2 f).
    assert_wins(route(EBGP_A), route(EBGP_B), :router_id)
  end

  def test_originator_id_replaces_the_router_id
    # RFC 4456 section 9: ORIGINATOR_ID 4.4.4.4 now loses to 3.3.3.3.
    assert_wins(route(EBGP_B), route(EBGP_A, originator_id: '4.4.4.4'), :router_id)
  end

  def test_shortest_cluster_list
    # RFC 4456 section 9: after the router ID, before the peer address.
    rr1 = peer('10.0.0.5', LOCAL_AS, '5.5.5.5')
    rr2 = peer('10.0.0.6', LOCAL_AS, '6.6.6.6')
    a = route(rr1, as_path: [65009], originator_id: '7.7.7.7', cluster_list: ['8.8.8.8'])
    b = route(rr2, as_path: [65009], originator_id: '7.7.7.7', cluster_list: ['8.8.8.8', '9.9.9.9'])
    assert_wins(a, b, :cluster_list_length)
  end

  def test_lowest_peer_address
    # RFC 4271 section 9.1.2.2 g): same router ID and path, two sessions.
    p1 = peer('10.0.0.2', 65002, '2.2.2.2')
    p2 = peer('10.0.0.10', 65002, '2.2.2.2')
    assert_wins(route(p1), route(p2), :peer_address)
  end

  def test_add_path_routes_from_one_peer
    assert_wins(route(EBGP_A, path_id: 1), route(EBGP_A, path_id: 2), :path_id)
  end

  def test_identical_routes
    a, b = route(EBGP_A), route(EBGP_A)
    res = decision.best([a, b])
    assert_equal(:duplicate, res.reason)
    assert_equal(1, res.eliminated.size)
  end

  def test_loops_are_not_used
    # RFC 4271 section 9.1.2: our AS in the path.
    res = decision.best([route(EBGP_A, as_path: [65002, LOCAL_AS])])
    assert_nil(res.best)
    assert_equal([:as_loop], res.eliminated.values)
    # RFC 4456 section 8: our router ID as ORIGINATOR_ID, our cluster ID in CLUSTER_LIST.
    assert_equal([:originator_id_loop], decision.best([route(EBGP_A, originator_id: '1.1.1.1')]).eliminated.values)
    assert_equal([:cluster_list_loop], decision.best([route(EBGP_A, cluster_list: ['1.1.1.1'])]).eliminated.values)
    d = decision(cluster_id: '7.7.7.7')
    assert_equal([:cluster_list_loop], d.best([route(EBGP_A, cluster_list: ['7.7.7.7'])]).eliminated.values)
    assert_nil(d.best([route(EBGP_A, cluster_list: ['1.1.1.1'])]).eliminated.values.first)
  end

  def test_steps_come_in_rfc_order
    # LOCAL_PREF before AS_PATH, AS_PATH before ORIGIN, ORIGIN before MED.
    a2 = peer('10.0.0.9', 65002, '9.9.9.9')
    assert_wins(route(EBGP_A, local_pref: 200, as_path: [65002, 1, 2]), route(EBGP_B, as_path: [65003]), :local_pref)
    assert_wins(route(EBGP_A, as_path: [65002], origin: 2), route(EBGP_B, as_path: [65003, 1]), :as_path_length)
    assert_wins(route(a2, origin: 0, med: 99), route(EBGP_A, origin: 1, med: 1), :origin)
  end

  def test_the_result_does_not_depend_on_route_order
    a2 = peer('10.0.0.9', 65002, '9.9.9.9')
    ibgp = peer('10.0.0.1', LOCAL_AS, '0.0.0.1')
    routes = [route(EBGP_A, med: 30), route(a2, med: 10), route(EBGP_B, med: 5),
              route(ibgp, as_path: [65004]), route(EBGP_A, as_path: [65002, 9])]
    # By hand: the 2 hop path goes on AS_PATH, MED 30 goes because MED 10
    # shares its neighbor AS, the iBGP route goes on eBGP over iBGP, and
    # 3.3.3.3 beats 9.9.9.9 on router ID.
    results = routes.permutation.map { |rs| decision.best(rs) }
    assert_equal([routes[2]], results.map(&:best).uniq)
    assert_equal([:router_id], results.map(&:reason).uniq)
    assert_equal({ routes[4] => :as_path_length, routes[0] => :med, routes[3] => :ebgp_over_ibgp,
                   routes[1] => :router_id }, results.first.eliminated)
    assert_equal([results.first.eliminated], results.map(&:eliminated).uniq)
  end

  def test_med_cycle_from_rfc_3345
    # Compared two at a time these three form a cycle: B beats A on MED (same
    # AS), C beats B on IGP cost, A beats C on IGP cost. RFC 4271 removes
    # routes from the whole set, so A goes on MED first and C wins, in every
    # order.
    a = route(peer('10.0.0.11', 100, '11.11.11.11'), as_path: [100], med: 1)
    b = route(peer('10.0.0.12', 100, '12.12.12.12'), as_path: [100], med: 0)
    c = route(peer('10.0.0.13', 200, '13.13.13.13'), as_path: [200], med: 7)
    costs = { '10.0.0.11' => 10, '10.0.0.12' => 20, '10.0.0.13' => 15 }
    d = decision(resolver: ->(nh) { costs[nh] })
    [a, b, c].permutation.each do |rs|
      res = d.best(rs)
      assert_same(c, res.best)
      assert_equal(:igp_cost, res.reason)
      assert_equal({ a => :med, b => :igp_cost }, res.eliminated)
    end
  end

  def test_every_step_has_a_method
    Decision::STEPS.each { |s| assert Decision.private_method_defined?("keep_by_#{s}"), s.to_s }
  end
end
