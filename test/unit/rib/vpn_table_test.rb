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

# BGP:: names are written out in full here, see Conventions in CLAUDE.md.
class TestBgpRibVpnTable < Test::Unit::TestCase

  def setup
    @t = BGP::Rib::VpnTable.new(local_as: 65000, router_id: '10.255.0.1')
  end

  def peer(address, router_id = address)
    BGP::Rib::Peer.new(:address => address, :remote_as => 65000, :router_id => router_id, :local_as => 65000)
  end

  # One VPN route from address, as the session would have received it.
  def vpn(address, rd, prefix, label, local_pref: 100, rts: [[65000, 100]], soo: nil, attrs: [], afi: 1)
    ecs = rts.collect { |g, l| BGP::Route_target.new(g, l) }
    ecs << BGP::Route_origin.new(*soo) if soo
    nh = afi == 2 ? "::ffff:#{address}" : address
    pa = BGP::Path_attribute.new(
      BGP::Origin.new(0), BGP::As_path.new, BGP::Local_pref.new(local_pref),
      BGP::Mp_reach.new(:afi => afi, :safi => 128, :nexthop => [nh], :nlris => [{ :prefix => prefix, :rd => rd, :label => label }]),
      BGP::Extended_communities.new(*ecs), *attrs)
    u = BGP::Update.new(BGP::Update.new(pa).encode)
    BGP::Rib::PeerAdapter.vpn_operations(u, peer(address))
  end

  def withdraw(rd, prefix)
    [[:withdraw, rd, prefix, nil]]
  end

  def test_a_route_is_kept_and_is_the_best_of_one
    @t.apply('10.255.0.3', vpn('10.255.0.3', [65000, 1], '192.168.2.0/30', 24001))
    assert_equal(1, @t.size)
    r = @t.rows.first
    assert_equal(['65000:1', '192.168.2.0/30', '10.255.0.3', '10.255.0.3', [24001], ['65000:100']],
                 r.values_at('rd', 'prefix', 'peer', 'next_hop', 'labels', 'route_targets'))
    assert_equal([true, 'only_route'], r.values_at('best', 'reason'))
  end

  # A route that was never reflected has no ORIGINATOR_ID and an empty
  # CLUSTER_LIST, and no Site of Origin unless one was sent.
  def test_a_row_without_reflection_or_site_of_origin
    @t.apply('10.255.0.3', vpn('10.255.0.3', [65000, 1], '192.168.2.0/30', 24001))
    assert_equal([nil, [], nil], @t.rows.first.values_at('originator_id', 'cluster_list', 'soo'))
  end

  # RFC 4456 section 8, as a PE behind a reflector receives a route, and
  # RFC 4360 section 5's Route Origin, apart from the Route Targets.
  def test_a_reflected_route_shows_its_originator_cluster_list_and_site_of_origin
    attrs = [BGP::Originator_id.new('10.255.0.1'), BGP::Cluster_list.new('10.255.0.2')]
    @t.apply('10.255.0.2', vpn('10.255.0.2', [65000, 1], '172.16.1.0/24', 24000, soo: [65000, 11], attrs: attrs))
    r = @t.rows.first
    assert_equal(['10.255.0.1', ['10.255.0.2'], '65000:11', ['65000:100']],
                 r.values_at('originator_id', 'cluster_list', 'soo', 'route_targets'))
  end

  # Per peer and per family, for show.peers.
  def test_counts_are_per_peer_and_per_family
    @t.apply('10.255.0.3', vpn('10.255.0.3', [65000, 1], '192.168.2.0/30', 24001))
    @t.apply('10.255.0.3', vpn('10.255.0.3', [65000, 1], '172.16.2.0/24', 24001))
    @t.apply('10.255.0.3', vpn('10.255.0.3', [65000, 1], '2001:db8:2::/64', 24001, afi: 2))
    @t.apply('10.255.0.4', vpn('10.255.0.4', [65000, 2], '192.168.4.0/30', 24002))
    assert_equal({ 'vpn-ipv4' => 2, 'vpn-ipv6' => 1 }, @t.counts('10.255.0.3'))
    assert_equal({ 'vpn-ipv4' => 1 }, @t.counts('10.255.0.4'))
    assert_equal({}, @t.counts('10.255.0.9'))
  end

  # RFC 4364 section 4.1: one prefix under two RDs is two routes, never
  # compared, each the best of its own.
  def test_two_rds_are_two_routes_never_compared
    @t.apply('10.255.0.3', vpn('10.255.0.3', [65000, 1], '192.168.2.0/30', 24001))
    @t.apply('10.255.0.4', vpn('10.255.0.4', [65000, 2], '192.168.2.0/30', 24005))
    assert_equal(2, @t.size)
    assert_equal([true, true], @t.rows.collect { |r| r['best'] })
    assert_equal(['65000:1', '65000:2'], @t.rows.collect { |r| r['rd'] })
  end

  # Section 4.3.1: "the BGP rules for route preference are used to
  # choose which VPN-IPv4 route is installed by BGP."
  def test_one_rd_from_two_peers_is_decided_by_bgps_rules
    @t.apply('10.255.0.3', vpn('10.255.0.3', [65000, 1], '192.168.2.0/30', 24001, local_pref: 100))
    @t.apply('10.255.0.4', vpn('10.255.0.4', [65000, 1], '192.168.2.0/30', 24005, local_pref: 200))
    best = @t.best('65000:1', '192.168.2.0/30')
    assert_equal(['10.255.0.4', :local_pref], [best.best.peer.address, best.reason])
    rows = @t.rows.to_h { |r| [r['peer'], r.values_at('best', 'reason')] }
    assert_equal({ '10.255.0.3' => [false, 'local_pref'], '10.255.0.4' => [true, 'local_pref'] }, rows)
  end

  # Every route is kept, whatever its Route Targets: filtering is the
  # VRFs' job, in the next pull request.
  def test_every_route_is_kept_whatever_its_route_targets
    @t.apply('10.255.0.3', vpn('10.255.0.3', [65000, 9], '10.9.0.0/16', 24009, rts: [[65000, 999]]))
    assert_equal(1, @t.size)
  end

  def test_a_withdrawal_removes_the_route_and_decides_again
    @t.apply('10.255.0.3', vpn('10.255.0.3', [65000, 1], '192.168.2.0/30', 24001, local_pref: 100))
    @t.apply('10.255.0.4', vpn('10.255.0.4', [65000, 1], '192.168.2.0/30', 24005, local_pref: 200))
    @t.apply('10.255.0.4', withdraw('65000:1', '192.168.2.0/30'))
    assert_equal('10.255.0.3', @t.best('65000:1', '192.168.2.0/30').best.peer.address)
    @t.apply('10.255.0.3', withdraw('65000:1', '192.168.2.0/30'))
    assert_nil(@t.best('65000:1', '192.168.2.0/30'))
    assert_equal(0, @t.size)
  end

  # A new announcement of the same RD and prefix replaces the old one
  # (RFC 4271 section 3.1).
  def test_a_new_announcement_replaces_the_old_one
    @t.apply('10.255.0.3', vpn('10.255.0.3', [65000, 1], '192.168.2.0/30', 24001))
    @t.apply('10.255.0.3', vpn('10.255.0.3', [65000, 1], '192.168.2.0/30', 24077))
    assert_equal([[24077]], @t.rows.collect { |r| r['labels'] })
  end

  def test_a_peer_down_removes_what_it_sent_and_decides_again
    @t.apply('10.255.0.3', vpn('10.255.0.3', [65000, 1], '192.168.2.0/30', 24001, local_pref: 100))
    @t.apply('10.255.0.4', vpn('10.255.0.4', [65000, 1], '192.168.2.0/30', 24005, local_pref: 200))
    @t.peer_down('10.255.0.4')
    assert_equal(1, @t.size)
    assert_equal('10.255.0.3', @t.best('65000:1', '192.168.2.0/30').best.peer.address)
  end

  def test_rows_sort_by_rd_then_prefix_then_peer
    @t.apply('10.255.0.4', vpn('10.255.0.4', [65000, 2], '10.0.0.0/8', 24002))
    @t.apply('10.255.0.3', vpn('10.255.0.3', [65000, 1], '192.168.2.0/30', 24001))
    @t.apply('10.255.0.3', vpn('10.255.0.3', [65000, 1], '10.0.0.0/8', 24003))
    assert_equal([['65000:1', '10.0.0.0/8'], ['65000:1', '192.168.2.0/30'], ['65000:2', '10.0.0.0/8']],
                 @t.rows.collect { |r| r.values_at('rd', 'prefix') })
  end

  # --- the session ------------------------------------------------------

  def session_info(vpn_ours, vpn_theirs)
    cap = ->(on) { on ? BGP::OPT_PARM::CAP::Mbgp.new(1, 128) : BGP::OPT_PARM::CAP::Mbgp.new(1, 1) }
    BGP::Neighbor::Capabilities.new(BGP::Open.new(4, 65000, 180, '10.255.0.1', cap.call(vpn_ours)),
                                    BGP::Open.new(4, 65000, 180, '10.255.0.3', cap.call(vpn_theirs)))
  end

  # Section 4.3.4: both speakers "must use BGP Capabilities
  # Advertisement to ensure that they both are capable".
  def test_negotiated_needs_both_opens
    assert(BGP::Rib::VpnTable.negotiated?(session_info(true, true)))
    assert(!BGP::Rib::VpnTable.negotiated?(session_info(true, false)))
    assert(!BGP::Rib::VpnTable.negotiated?(session_info(false, true)))
    assert(!BGP::Rib::VpnTable.negotiated?(nil))
  end

  # RFC 4659 section 3.4: AFI 2 is negotiated on its own.
  def test_each_vpn_family_is_negotiated_on_its_own
    both = [BGP::OPT_PARM::CAP::Mbgp.new(1, 128), BGP::OPT_PARM::CAP::Mbgp.new(2, 128)]
    si = BGP::Neighbor::Capabilities.new(BGP::Open.new(4, 65000, 180, '10.255.0.1', *both),
                                         BGP::Open.new(4, 65000, 180, '10.255.0.3', both.last))
    assert_equal([[2, 128]], BGP::Rib::VpnTable.families(si))
    assert(!BGP::Rib::VpnTable.negotiated?(si))
    assert(BGP::Rib::VpnTable.negotiated?(si, BGP::Rib::PeerAdapter::VPN6))
  end

  # A Neighbor stand-in with what attach and its feed use.
  class FakeNeighbor
    attr_accessor :session_info
    attr_reader :observers
    def initialize(si) ; @session_info, @observers, @listeners = si, [], [] ; end
    def remote_addr ; '10.255.0.3' ; end
    def rmt_as ; 65000 ; end
    def rmt_bgp_id ; '10.255.0.3' ; end
    def my_as ; 65000 ; end
    def add_observer(o) ; @observers << o ; end
    def delete_observer(o) ; @observers.delete(o) ; end
    def on_state_change(&b) ; @listeners << b ; end
    def state(now, was) ; @listeners.each { |b| b.call(now, was) } ; end
    def receive(m) ; @observers.each { |o| o.update(m) } ; end
  end

  def update(rd, prefix, label)
    BGP::Update.new(BGP::Path_attribute.new(
      BGP::Origin.new(0), BGP::As_path.new, BGP::Local_pref.new(100),
      BGP::Mp_reach.new(:safi => 128, :nexthop => ['10.255.0.3'], :nlris => [{ :prefix => prefix, :rd => rd, :label => label }])))
  end

  def test_an_attached_session_feeds_the_table_and_its_end_empties_it
    n = FakeNeighbor.new(session_info(true, true))
    feed = @t.attach(n)
    n.receive(update([65000, 1], '192.168.2.0/30', 24001))
    assert_equal(1, @t.size('10.255.0.3'))
    assert_equal('10.255.0.3', @t.rows.first['peer'])
    n.state(:Established, :OpenConfirm)
    assert_equal(1, @t.size)
    n.state(:Idle, :Established)
    assert_equal(0, @t.size, "RFC 4271 section 6: the closed session's routes go")
    @t.detach(n, feed)
    assert_equal([], n.observers)
  end

  def test_a_session_that_did_not_negotiate_vpn_is_ignored
    n = FakeNeighbor.new(session_info(true, false))
    @t.attach(n)
    n.receive(update([65000, 1], '192.168.2.0/30', 24001))
    assert_equal(0, @t.size)
  end

  # RFC 7313 section 4 for VPN-IPv4 and VPN-IPv6: one AFI marked, the
  # row says so, an announcement clears it, and the EoRR removes the rest.
  def test_stale_routes
    @t.apply('10.255.0.3', vpn('10.255.0.3', [65000, 1], '192.168.2.0/30', 24001))
    @t.apply('10.255.0.3', vpn('10.255.0.3', [65000, 1], '192.168.3.0/30', 24001))
    @t.apply('10.255.0.3', vpn('10.255.0.3', [65000, 1], '2001:db8:2::/64', 24001, afi: 2))
    assert_equal(2, @t.mark_stale('10.255.0.3', 1))
    assert_equal(2, @t.stale_size('10.255.0.3'))
    assert_equal({ '192.168.2.0/30' => 'refresh', '192.168.3.0/30' => 'refresh', '2001:db8:2::/64' => nil },
                 @t.rows.to_h { |r| [r['prefix'], r['stale']] })
    assert_equal('refresh', @t.stale('10.255.0.3', '65000:1', '192.168.2.0/30'))
    assert_equal([nil, nil], [@t.stale('10.255.0.3', '65000:1', '2001:db8:2::/64'), @t.stale('10.255.0.3', '65000:9', '192.168.2.0/30')],
                 'another prefix, another RD')
    @t.apply('10.255.0.3', vpn('10.255.0.3', [65000, 1], '192.168.2.0/30', 24001))
    assert_equal(1, @t.purge_stale('10.255.0.3', 1))
    assert_equal(%w[192.168.2.0/30 2001:db8:2::/64], @t.rows.collect { |r| r['prefix'] })
    assert_nil(@t.best('65000:1', '192.168.3.0/30'), 'decided again')
  end

  def test_peer_down_keeps_a_family
    @t.apply('10.255.0.3', vpn('10.255.0.3', [65000, 1], '192.168.2.0/30', 24001))
    @t.apply('10.255.0.3', vpn('10.255.0.3', [65000, 1], '192.168.3.0/30', 24001))
    @t.apply('10.255.0.3', vpn('10.255.0.3', [65000, 1], '2001:db8:2::/64', 24001, afi: 2))
    @t.mark_stale('10.255.0.3', 1)
    @t.apply('10.255.0.3', vpn('10.255.0.3', [65000, 1], '192.168.2.0/30', 24001))
    @t.peer_down('10.255.0.3', [[1, 128]])
    assert_equal([['192.168.2.0/30', 'restart']], @t.rows.collect { |r| [r['prefix'], r['stale']] })
    assert_not_nil(@t.best('65000:1', '192.168.2.0/30'))
    assert_nil(@t.best('65000:1', '192.168.3.0/30'), 'decided again')
  end
end
