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

  # MP_REACH_NLRI and MP_UNREACH_NLRI are path attributes (RFC 4760 section
  # 3) and are not read yet. unreachable? is how a caller tells that apart
  # from an UPDATE that genuinely carried nothing.
  def test_mp_reach_is_not_read_yet_but_is_reported
    peer_opened
    pa = BGP::Path_attribute.new(BGP::Origin.new(0),
                                 BGP::Mp_reach.new(:afi => 2, :safi => 1,
                                                   :nexthop => ['2011:1::1'],
                                                   :nlris => ['2011:1::/32']))
    u = BGP::Update.new(pa)
    assert_equal([], @adapter.operations(u))
    assert(@adapter.unreachable?(u), 'the reachability is in an attribute bgp4r does not read here')
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

  # RFC 4271 section 9.1.2: a session that is no longer Established has no
  # routes. The adapter asks for peer_down once, and forgets the Peer, so
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
