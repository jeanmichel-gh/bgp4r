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
class TestBgpRibPeerAdapter < Test::Unit::TestCase

  # Collects what the adapter would hand a PeerFeed.
  class Sink
    attr_reader :work
    def initialize ; @work = [] ; end
    def <<(w) ; @work << w ; self ; end
  end

  def setup
    @n = BGP::Neighbor.new(:my_as => 65001, :remote_addr => '10.0.0.2',
                           :local_addr => '10.0.0.1', :id => '1.1.1.1')
    @sink = Sink.new
    @adapter = BGP::Rib::PeerAdapter.new(@n, @sink)
  end

  def teardown
    @n.close if @n
  end

  # What rcv_open learns from the peer's OPEN (RFC 4271 section 4.2).
  def peer_opened(as = 65002, id = '2.2.2.2')
    @n.instance_variable_set(:@rmt_as, as)
    @n.instance_variable_set(:@rmt_bgp_id, id)
  end

  def path_attribute(as = 65002)
    BGP::Path_attribute.new(BGP::Origin.new(0), BGP::Next_hop.new('10.0.0.2'),
                            BGP::As_path.new(as))
  end

  def test_no_peer_before_the_open_arrives
    assert_nil(@adapter.peer, 'nothing names the peer yet')
    u = BGP::Update.new(path_attribute, BGP::Nlri.new('10.0.0.0/8'))
    assert_equal([], @adapter.operations(u), 'and so there is nothing to do with an UPDATE')
    @adapter.update(u)
    assert_equal([], @sink.work)
  end

  def test_the_peer_comes_from_the_open_and_our_own_config
    peer_opened
    peer = @adapter.peer
    assert_equal('10.0.0.2', peer.address)
    assert_equal(65002, peer.remote_as)
    assert_equal('2.2.2.2', peer.router_id)
    assert_equal(65001, peer.local_as)
    assert(peer.ebgp?, 'RFC 4271 section 1.1: another AS is an external peer')
    assert_same(peer, @adapter.peer, 'built once per session')
  end

  def test_an_ibgp_peer_is_one_in_our_own_as
    peer_opened(65001, '2.2.2.2')
    assert(@adapter.peer.ibgp?)
  end

  def test_nlri_becomes_announcements
    peer_opened
    pa = path_attribute
    u = BGP::Update.new(pa, BGP::Nlri.new('192.168.1.0/24', '10.0.0.0/8'))
    ops = @adapter.operations(u)
    assert_equal([:announce, :announce], ops.map(&:first))
    assert_equal(%w[192.168.1.0/24 10.0.0.0/8], ops.map { |o| o[1].prefix })
    assert_equal(@adapter.peer, ops[0][1].peer)
    assert_equal(pa.encode(true), ops[0][1].path_attribute.encode(true),
                 'the message attributes travel with every prefix it carries')
    assert_nil(ops[0][1].path_id, 'no add-path, no Path Identifier')
  end

  def test_withdrawn_routes_become_withdrawals
    peer_opened
    u = BGP::Update.new(BGP::Withdrawn.new('10.0.0.0/8'))
    assert_equal([[:withdraw, @adapter.peer, '10.0.0.0/8', nil]], @adapter.operations(u))
  end

  # A host route and the default route are the two prefix lengths that read
  # specially in RFC 4271 section 4.3: a /0 takes its length octet and no
  # prefix octet.
  def test_the_default_route_and_a_host_route
    peer_opened
    u = BGP::Update.new(path_attribute, BGP::Nlri.new('0.0.0.0/0', '10.1.2.3/32'))
    assert_equal(%w[0.0.0.0/0 10.1.2.3/32], @adapter.operations(u).map { |o| o[1].prefix })
  end

  # Withdrawals are applied before announcements, so a prefix in both fields
  # of one UPDATE ends up announced. bgp4r's choice, see PeerAdapter#operations.
  def test_withdrawals_come_before_announcements
    peer_opened
    u = BGP::Update.new(BGP::Withdrawn.new('10.0.0.0/8'), path_attribute,
                        BGP::Nlri.new('10.0.0.0/8'))
    ops = @adapter.operations(u)
    assert_equal([:withdraw, :announce], ops.map(&:first))
  end

  # RFC 4724 section 2: the End-of-RIB marker is an UPDATE with no
  # reachability and no attributes. There is nothing to do with it.
  def test_end_of_rib_marker_asks_for_nothing
    peer_opened
    u = BGP::Update.new
    assert_equal([], @adapter.operations(u))
    assert(!@adapter.unreachable?(u), 'and it is not an unread address family either')
    @adapter.update(u)
    assert_equal([], @sink.work, 'nothing is queued for an empty UPDATE')
  end

  # MP_REACH_NLRI and MP_UNREACH_NLRI, RFC 4760 sections 3 and 4. The two
  # SAFIs whose NLRI is a bare prefix are read; the rest are reported. See
  # PeerAdapter::MP_SAFIS for why the others are not.

  def mp_reach(afi, safi, nexthop, *nlris)
    BGP::Path_attribute.new(BGP::Origin.new(0), BGP::As_path.new(65002),
                            BGP::Mp_reach.new(:afi => afi, :safi => safi,
                                              :nexthop => [nexthop], :nlris => nlris))
  end

  def test_mp_reach_ipv6_unicast_becomes_announcements
    peer_opened
    u = BGP::Update.new(mp_reach(2, 1, '2011:1::1', '2011:1::/32', '2011:2::/32'))
    ops = @adapter.operations(u)
    assert_equal([:announce, :announce], ops.map(&:first))
    assert_equal(%w[2011:1::/32 2011:2::/32], ops.map { |o| o[1].prefix })
    assert_equal('2011:1::1', ops[0][1].next_hop, 'the next hop comes from MP_REACH')
    assert_equal(2, ops[0][1].afi)
    assert(!@adapter.unreachable?(u))
    assert_equal([], @adapter.unread_families(u))
  end

  def test_mp_unreach_becomes_withdrawals
    peer_opened
    pa = BGP::Path_attribute.new(BGP::Mp_unreach.new(:afi => 2, :safi => 1,
                                                     :nlris => ['2011:1::/32']))
    assert_equal([[:withdraw, @adapter.peer, '2011:1::/32', nil]],
                 @adapter.operations(BGP::Update.new(pa)))
  end

  # IANA SAFI 2. Its NLRI is a bare prefix too, so it reads the same way.
  def test_mp_reach_multicast_is_read
    peer_opened
    u = BGP::Update.new(mp_reach(1, 2, '10.0.0.1', '10.1.0.0/16'))
    assert_equal(['10.1.0.0/16'], @adapter.operations(u).map { |o| o[1].prefix })
  end

  # IPv4 unicast can arrive either way. Both are read.
  def test_ipv4_unicast_through_mp_reach_is_read
    peer_opened
    u = BGP::Update.new(mp_reach(1, 1, '10.0.0.1', '10.1.0.0/16'))
    assert_equal(['10.1.0.0/16'], @adapter.operations(u).map { |o| o[1].prefix })
  end

  # SAFI 4 carries a label with the prefix (RFC 8277 section 2) and 128 a
  # Route Distinguisher (RFC 4364 section 4.2). A Route keys on the prefix
  # and the Path Identifier, so two routes differing only in label or RD
  # would collide. Reported, not half read.
  def test_a_labeled_family_is_reported_rather_than_half_read
    peer_opened
    pa = BGP::Path_attribute.new(BGP::Origin.new(0),
                                 BGP::Mp_reach.new(:afi => 1, :safi => 4,
                                                   :nexthop => ['10.0.0.1'],
                                                   :nlris => [{ :prefix => '10.1.0.0/16', :label => 101 }]))
    u = BGP::Update.new(pa)
    assert_equal([], @adapter.operations(u), 'nothing is invented for it')
    assert(@adapter.unreachable?(u), 'and the gap reports itself')
    assert_equal([[1, 4]], @adapter.unread_families(u))
  end

  def test_an_unread_family_in_mp_unreach_is_reported_too
    peer_opened
    pa = BGP::Path_attribute.new(
           BGP::Mp_unreach.new(:afi => 1, :safi => 128,
                               :nlris => [{ :rd => [100, 200], :prefix => '10.1.0.0/16', :label => 101 }]))
    u = BGP::Update.new(pa)
    assert_equal([], @adapter.operations(u))
    assert(@adapter.unreachable?(u))
    assert_equal([[1, 128]], @adapter.unread_families(u))
  end

  # Both withdrawal fields before both announcement fields. The two families
  # are different, so the order between the withdrawals cannot matter.
  def test_all_four_reachability_fields_in_one_update
    peer_opened
    pa = BGP::Path_attribute.new(BGP::Origin.new(0), BGP::Next_hop.new('10.0.0.2'),
                                 BGP::As_path.new(65002),
                                 BGP::Mp_reach.new(:afi => 2, :safi => 1,
                                                   :nexthop => ['2011:1::1'],
                                                   :nlris => ['2011:1::/32']),
                                 BGP::Mp_unreach.new(:afi => 2, :safi => 1,
                                                     :nlris => ['2011:9::/32']))
    u = BGP::Update.new(BGP::Withdrawn.new('10.9.0.0/16'), pa, BGP::Nlri.new('10.1.0.0/16'))
    ops = @adapter.operations(u)
    assert_equal([:withdraw, :withdraw, :announce, :announce], ops.map(&:first))
    assert_equal(%w[10.9.0.0/16 2011:9::/32], ops[0, 2].map { |o| o[2] })
    assert_equal(%w[10.1.0.0/16 2011:1::/32], ops[2, 2].map { |o| o[1].prefix })
  end

  # The add-path Path Identifier of RFC 7911 section 3 travels into the
  # Route, which is what lets one peer hold several paths to one prefix.
  def test_path_identifiers_travel_into_the_route
    peer_opened
    u = BGP::Update.new(path_attribute,
                        BGP::Nlri.new({ :path_id => 7, :nlri => '10.1.0.0/16' },
                                      { :path_id => 9, :nlri => '10.1.0.0/16' }))
    ops = @adapter.operations(u)
    assert_equal([7, 9], ops.map { |o| o[1].path_id })
    assert_equal([['10.1.0.0/16', 7], ['10.1.0.0/16', 9]], ops.map { |o| o[1].key },
                 'the same prefix, two paths')
  end

  def test_path_identifiers_travel_through_mp_reach_too
    peer_opened
    pa = BGP::Path_attribute.new(
           BGP::Origin.new(0), BGP::As_path.new(65002),
           BGP::Mp_reach.new(:afi => 2, :safi => 1, :path_id => true,
                             :nexthop => ['2011:1::1'],
                             :nlris => [{ :path_id => 7, :prefix => '2011:1::/32' }]))
    ops = @adapter.operations(BGP::Update.new(pa))
    assert_equal([7], ops.map { |o| o[1].path_id })
  end

  def test_a_path_identifier_in_mp_unreach
    peer_opened
    pa = BGP::Path_attribute.new(
           BGP::Mp_unreach.new(:afi => 2, :safi => 1, :path_id => true,
                               :nlris => [{ :path_id => 7, :prefix => '2011:1::/32' }]))
    assert_equal([[:withdraw, @adapter.peer, '2011:1::/32', 7]],
                 @adapter.operations(BGP::Update.new(pa)))
  end

  # The real path: an UPDATE built, encoded, and parsed back from its octets,
  # since that is the only form a session ever hands the adapter.
  def test_an_update_parsed_from_its_own_wire_bytes
    peer_opened
    info = BGP::Update::Info.new(true)
    sent = BGP::Update.new(mp_reach(2, 1, '2011:1::1', '2011:1::/32'))
    back = BGP::Message.factory(sent.encode(info), info)
    assert_kind_of(BGP::Update, back)
    ops = @adapter.operations(back)
    assert_equal(['2011:1::/32'], ops.map { |o| o[1].prefix })
    assert_equal('2011:1::1', ops[0][1].next_hop)
  end

  def test_an_update_reaches_the_sink
    peer_opened
    @adapter.update(BGP::Update.new(path_attribute, BGP::Nlri.new('10.0.0.0/8')))
    assert_equal(1, @sink.work.size)
    kind, ops = @sink.work.first
    assert_equal(:ops, kind)
    assert_equal([:announce], ops.map(&:first))
  end

  def test_anything_that_is_not_an_update_is_ignored
    peer_opened
    [BGP::Message.keepalive, BGP::Message.route_refresh(1, 1),
     BGP::Notification.new(6, 2)].each { |m| @adapter.update(m) }
    assert_equal([], @sink.work)
  end

  # RFC 4271 section 8.2.2: every event that leaves Established "deletes
  # all routes associated with this connection", so a session that is no
  # longer Established has no routes. The adapter asks for peer_down once,
  # and forgets the Peer, so
  # the next session builds a new one from the next OPEN.
  def test_leaving_established_asks_for_peer_down
    peer_opened
    peer = @adapter.peer
    @adapter.state_change(:Idle, :Established)
    assert_equal([[:peer_down, peer]], @sink.work)
    @adapter.state_change(:Idle, :Idle)
    assert_equal(1, @sink.work.size, 'not again while it stays down')
  end

  def test_a_state_change_that_never_reached_established_asks_for_nothing
    peer_opened
    @adapter.state_change(:Idle, :OpenSent)
    assert_equal([], @sink.work)
  end

  # The peer may come back with another BGP Identifier, which is the last
  # tie break of the decision process (RFC 4271 section 9.1.2.2 f), so a
  # stale Peer would decide the wrong winner.
  def test_the_peer_is_rebuilt_after_a_session_drops
    peer_opened(65002, '2.2.2.2')
    first = @adapter.peer
    @adapter.state_change(:Idle, :Established)
    peer_opened(65002, '9.9.9.9')
    second = @adapter.peer
    assert_not_same(first, second)
    assert_equal('9.9.9.9', second.router_id)
  end

  # The real signal, through BGP::Neighbor#new_state rather than by calling
  # state_change directly, since that wiring is the part that can rot.
  def test_the_neighbor_state_change_signal_is_wired_up
    peer_opened
    peer = @adapter.peer
    @n.instance_variable_set(:@state, :Established)
    @n.send(:new_state, :Idle, 'test')
    assert_equal([[:peer_down, peer]], @sink.work)
  end

  def test_detach_stops_the_neighbor_reporting
    peer_opened
    assert_equal(1, @n.count_observers)
    @adapter.detach
    assert_equal(0, @n.count_observers)
  end
end
