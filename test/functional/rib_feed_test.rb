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
require 'bgp4r'
require 'bgp/rib'
require 'test/helpers/server'

# A table fed by a real session over loopback. The unit tests drive the
# adapter and the feed directly; this is the one that proves the whole path,
# socket included: a client sends UPDATEs, the server's Neighbor parses them,
# its PeerAdapter translates them on the event thread, and the feed's worker
# puts them in the table.
#
# BGP:: names are written out in full, see Conventions in CLAUDE.md.
class RibFeedTest < Test::Unit::TestCase
  include BGP::TestHelpers

  SERVER_AS = 100
  CLIENT_AS = 200

  def teardown
    @rib.feed.stop if @rib
    @c.close if @c
    stop_server
  end

  # Brings up a session with the table attached before it, so the table sees
  # it come up and go down. cap, when given, is advertised by both sides.
  # @s is the server side Neighbor the helper built.
  def session(cap = nil)
    @port = start_server(0, cap)
    @rib = BGP::Rib.new(:local_as => SERVER_AS, :router_id => '0.0.0.1')
    @changes = []
    @rib.on_change { |c| @changes << c }
    @adapter = @rib.attach(@s)
    @c = BGP::Neighbor.new(4, CLIENT_AS, 180, '0.0.0.2', '127.0.0.1', '127.0.0.1')
    @c.add_cap cap if cap
    @c.start :port => @port
    assert(wait_for { @s.is_established? }, 'the session came up')
  end

  def path_attribute(as = CLIENT_AS, local_pref: nil)
    attrs = [BGP::Origin.new(0), BGP::Next_hop.new('10.0.0.1'), BGP::As_path.new(as)]
    attrs << BGP::Local_pref.new(local_pref) if local_pref
    BGP::Path_attribute.new(*attrs)
  end

  # Waits for cond to hold, since the session and the worker both run on
  # their own threads. Returns true, or false after timeout seconds.
  def wait_for(timeout = 5)
    deadline = Time.now + timeout
    loop do
      return true if yield
      return false if Time.now > deadline
      sleep 0.02
    end
  end

  def test_updates_from_a_live_session_reach_the_table
    session
    @c.send_update BGP::Update.new(path_attribute,
                                   BGP::Nlri.new('10.1.0.0/16', '10.2.0.0/16'))
    assert(wait_for { @rib.drain && @rib.loc_rib.size == 2 }, "loc-rib: #{@rib.loc_rib.size}")

    peer = @adapter.peer
    assert_equal(CLIENT_AS, peer.remote_as, 'the peer AS came from the OPEN')
    assert_equal('0.0.0.2', peer.router_id, 'and so did its BGP Identifier')
    assert(peer.ebgp?, 'AS200 seen from AS100 is external')

    best = @rib.best('10.1.0.0/16')
    assert_equal('10.0.0.1', best.next_hop)
    assert_equal('200', best.as_path)
    assert_equal(peer, best.peer)
    assert_equal(%w[10.1.0.0/16 10.2.0.0/16], @changes.map(&:prefix).sort)
  end

  def test_a_withdrawal_from_a_live_session_reaches_the_table
    session
    @c.send_update BGP::Update.new(path_attribute, BGP::Nlri.new('10.1.0.0/16'))
    assert(wait_for { @rib.drain && @rib.loc_rib.size == 1 })

    @c.send_update BGP::Update.new(BGP::Withdrawn.new('10.1.0.0/16'))
    assert(wait_for { @rib.drain && @rib.loc_rib.empty? }, 'the route went')
    assert_equal([:added, :withdrawn], @changes.map(&:type))
  end

  # RFC 4271 section 5.1.5: LOCAL_PREF received from an external peer is
  # ignored. Table#import does it, and this is the first time a real eBGP
  # session has exercised it.
  def test_local_pref_from_this_ebgp_peer_is_dropped
    session
    @c.send_update BGP::Update.new(path_attribute(:local_pref => 300),
                                   BGP::Nlri.new('10.1.0.0/16'))
    assert(wait_for { @rib.drain && @rib.loc_rib.size == 1 })
    assert_nil(@rib.best('10.1.0.0/16').local_pref, 'dropped on import')
    assert_equal(300, @rib.adj_rib_in(@adapter.peer)['10.1.0.0/16'].local_pref,
                 'but the Adj-RIB-In keeps the route as it was received')
  end

  # RFC 4271 section 9.1.2: the routes a peer sent are gone once the session
  # is. The client just closes its socket, so the server learns of it the
  # way it would from any peer that went away: a connection reset, which
  # calls stop without notifying the message observers. That is the whole
  # reason Neighbor#on_state_change exists.
  def test_the_routes_go_when_the_session_drops
    session
    @c.send_update BGP::Update.new(path_attribute, BGP::Nlri.new('10.1.0.0/16', '10.2.0.0/16'))
    assert(wait_for { @rib.drain && @rib.loc_rib.size == 2 })

    @c.stop
    assert(wait_for { !@s.is_established? }, 'the server noticed')
    assert(wait_for { @rib.drain && @rib.loc_rib.empty? }, "loc-rib: #{@rib.loc_rib.size}")
    assert_equal([:withdrawn, :withdrawn], @changes.last(2).map(&:type))
    assert(@rib.adj_rib_in(@rib.peers.first).empty?, 'the Adj-RIB-In was emptied')
  end

  # IPv6 unicast over a real session, which travels in MP_REACH_NLRI and
  # MP_UNREACH_NLRI (RFC 4760 sections 3 and 4) rather than the RFC 4271
  # section 4.3 fields. The next hop comes out of the attribute.
  def test_ipv6_through_mp_reach_and_mp_unreach
    session
    pa = BGP::Path_attribute.new(BGP::Origin.new(0), BGP::As_path.new(CLIENT_AS),
                                 BGP::Mp_reach.new(:afi => 2, :safi => 1,
                                                   :nexthop => ['2011:1::1'],
                                                   :nlris => ['2011:1::/32', '2011:2::/32']))
    @c.send_update BGP::Update.new(pa)
    assert(wait_for { @rib.drain && @rib.loc_rib.size == 2 }, "loc-rib: #{@rib.loc_rib.size}")
    best = @rib.best('2011:1::/32')
    assert_equal('2011:1::1', best.next_hop)
    assert_equal(2, best.afi)
    assert_equal('200', best.as_path)

    unreach = BGP::Path_attribute.new(BGP::Mp_unreach.new(:afi => 2, :safi => 1,
                                                          :nlris => ['2011:1::/32']))
    @c.send_update BGP::Update.new(unreach)
    assert(wait_for { @rib.drain && @rib.loc_rib.size == 1 }, 'one went')
    assert_nil(@rib.best('2011:1::/32'))
    assert_not_nil(@rib.best('2011:2::/32'), 'the other stayed')
  end

  # Two paths to one prefix from one peer, which is what add-path is for
  # (RFC 7911). Until now nothing had carried a Path Identifier into a RIB
  # over a session: test/functional/add_path_test.rb only checks that the
  # capability negotiates. Both sides advertise send and receive here, so
  # the server parses the Path Identifier off the wire.
  def test_add_path_puts_two_paths_to_one_prefix_in_the_table
    cap = BGP::OPT_PARM::CAP::Add_path.new(:send_and_receive, 1, 1)
    session(cap)
    assert(@s.session_info.recv_inet_unicast?, 'the server can receive multiple paths')

    pa1 = BGP::Path_attribute.new(BGP::Origin.new(0), BGP::Next_hop.new('10.0.0.1'),
                                  BGP::As_path.new(CLIENT_AS))
    pa2 = BGP::Path_attribute.new(BGP::Origin.new(0), BGP::Next_hop.new('10.0.0.2'),
                                  BGP::As_path.new(CLIENT_AS, 65010))
    @c.send_update BGP::Update.new(pa1, BGP::Nlri.new(:path_id => 7, :nlri => '10.1.0.0/16'))
    @c.send_update BGP::Update.new(pa2, BGP::Nlri.new(:path_id => 9, :nlri => '10.1.0.0/16'))
    assert(wait_for { @rib.drain && @rib.candidates('10.1.0.0/16').size == 2 },
           "candidates: #{@rib.candidates('10.1.0.0/16').size}")

    peer = @adapter.peer
    assert_equal([7, 9], @rib.adj_rib_in(peer).paths('10.1.0.0/16').map(&:path_id).sort,
                 'both Path Identifiers arrived')
    assert_equal(1, @rib.loc_rib.size, 'one best route, as always')
    # The shorter AS_PATH wins (RFC 4271 section 9.1.2.2 a), which is path 7.
    assert_equal(7, @rib.best('10.1.0.0/16').path_id)

    # Withdrawing one path leaves the other, which is the whole point: a
    # withdrawal keyed on the prefix alone would take both.
    @c.send_update BGP::Update.new(BGP::Withdrawn.new(:path_id => 7, :nlri => '10.1.0.0/16'))
    assert(wait_for { @rib.drain && @rib.candidates('10.1.0.0/16').size == 1 },
           "candidates: #{@rib.candidates('10.1.0.0/16').size}")
    assert_equal(9, @rib.best('10.1.0.0/16').path_id, 'the other path took over')
  end

  # Router mode over a real session: the first time a bgp4r speaker has
  # advertised its own Loc-RIB to a peer. The client collects what arrives.
  class Catcher
    def updates ; @updates ||= [] ; end
    def update(m) ; updates << m if m.is_a?(BGP::Update) ; end
  end

  # A route learned from an internal peer, so the external client may have it.
  def internal_route(prefix = '10.1.0.0/16', attrs = nil)
    peer = BGP::Rib::Peer.new(:address => '10.9.9.9', :remote_as => SERVER_AS,
                              :router_id => '9.9.9.9', :local_as => SERVER_AS)
    attrs ||= [BGP::Origin.new(0), BGP::Next_hop.new('10.9.9.9'), BGP::Local_pref.new(300)]
    BGP::Rib::Route.new(prefix, BGP::Path_attribute.new(*attrs), peer)
  end

  def advertising_session
    @catcher = Catcher.new
    @port = start_server
    @rib = BGP::Rib.new(:local_as => SERVER_AS, :router_id => '0.0.0.1')
    @changes = []
    @rib.on_change { |c| @changes << c }
    @adapter = @rib.attach(@s)
    @router = @rib.advertise
    @c = BGP::Neighbor.new(4, CLIENT_AS, 180, '0.0.0.2', '127.0.0.1', '127.0.0.1')
    @c.add_observer @catcher
    @c.start :port => @port
    assert(wait_for { @s.is_established? }, 'the session came up')
    assert(wait_for { @rib.drain }, 'and the initial advertisement is flushed')
  end

  def test_a_speaker_advertises_its_loc_rib_over_a_real_session
    advertising_session
    @rib.announce(internal_route)
    assert(wait_for { @rib.drain && @catcher.updates.size == 1 },
           "the client got #{@catcher.updates.size}")

    u = @catcher.updates.first
    assert_equal(['10.1.0.0/16'], u.nlri.to_ary)
    # RFC 4271 section 5.1.2: our AS, prepended. The route came from inside
    # our AS with an empty AS_PATH, so this is the section's empty case.
    assert_equal(SERVER_AS.to_s, u.path_attribute[BGP::As_path].as_path)
    # Section 5.1.3: our address on the session, not the one it arrived with.
    assert_equal('127.0.0.1', u.path_attribute[BGP::Next_hop].next_hop)
    # Section 5.1.5: never to an external peer.
    assert(!u.path_attribute.has?(BGP::Local_pref))
    assert_equal(1, @router.sent)
    assert_equal([], @router.skipped)
  end

  def test_a_withdrawal_reaches_the_peer_over_a_real_session
    advertising_session
    @rib.announce(internal_route)
    assert(wait_for { @rib.drain && @catcher.updates.size == 1 })
    peer = BGP::Rib::Peer.new(:address => '10.9.9.9', :remote_as => SERVER_AS,
                              :router_id => '9.9.9.9', :local_as => SERVER_AS)
    @rib.withdraw(peer, '10.1.0.0/16')
    assert(wait_for { @rib.drain && @catcher.updates.size == 2 },
           "the client got #{@catcher.updates.size}")
    assert_equal(['10.1.0.0/16'], @catcher.updates.last.withdrawn.to_ary)
  end

  # Prefixes that share attributes travel in one UPDATE, which is what the
  # builder is for, and this is it happening on a socket.
  def test_prefixes_sharing_attributes_arrive_in_one_update
    advertising_session
    attrs = [BGP::Origin.new(0), BGP::Next_hop.new('10.9.9.9'), BGP::Local_pref.new(300)]
    @rib.synchronize do
      %w[10.1.0.0/16 10.2.0.0/16 10.3.0.0/16].each { |p| @rib.announce(internal_route(p, attrs)) }
    end
    wanted = %w[10.1.0.0/16 10.2.0.0/16 10.3.0.0/16]
    arrived = []
    assert(wait_for do
      @rib.drain
      arrived = @catcher.updates.flat_map { |u| u.nlri ? u.nlri.to_ary : [] }
      arrived.size == wanted.size
    end, "arrived: #{arrived.inspect}")
    assert_equal(wanted, arrived.sort)
    assert(@catcher.updates.size <= 3, 'and not more messages than prefixes')
  end

  # The Adj-RIB-Out is what stops the same thing going twice.
  def test_the_same_route_again_sends_nothing
    advertising_session
    @rib.announce(internal_route)
    assert(wait_for { @rib.drain && @catcher.updates.size == 1 })
    @rib.announce(internal_route)
    assert(@rib.drain)
    assert_equal(1, @router.sent, 'nothing changed for this peer')
  end

  # A route the client itself sent must not come back to it.
  def test_a_route_from_the_client_is_not_sent_back_to_it
    advertising_session
    @c.send_update BGP::Update.new(path_attribute, BGP::Nlri.new('10.7.0.0/16'))
    assert(wait_for { @rib.drain && @rib.loc_rib.size == 1 }, 'it reached the table')
    assert(@rib.drain)
    assert_equal(0, @router.sent)
    assert_equal([[:back_to_sender]], @router.skipped.map { |s| [s.last] })
  end
end
