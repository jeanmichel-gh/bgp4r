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

  def setup
    @port = start_server
    # The table is attached before the session, so it sees it come up and
    # go down. @s is the server side Neighbor the helper built.
    @rib = BGP::Rib.new(:local_as => SERVER_AS, :router_id => '0.0.0.1')
    @changes = []
    @rib.on_change { |c| @changes << c }
    @adapter = @rib.attach(@s)
    @c = BGP::Neighbor.new(4, CLIENT_AS, 180, '0.0.0.2', '127.0.0.1', '127.0.0.1')
  end

  def teardown
    @rib.feed.stop if @rib
    @c.close if @c
    stop_server
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
    @c.start :port => @port
    assert(wait_for { @s.is_established? }, 'the session came up')

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
    @c.start :port => @port
    assert(wait_for { @s.is_established? })
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
    @c.start :port => @port
    assert(wait_for { @s.is_established? })
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
    @c.start :port => @port
    assert(wait_for { @s.is_established? })
    @c.send_update BGP::Update.new(path_attribute, BGP::Nlri.new('10.1.0.0/16', '10.2.0.0/16'))
    assert(wait_for { @rib.drain && @rib.loc_rib.size == 2 })

    @c.stop
    assert(wait_for { !@s.is_established? }, 'the server noticed')
    assert(wait_for { @rib.drain && @rib.loc_rib.empty? }, "loc-rib: #{@rib.loc_rib.size}")
    assert_equal([:withdrawn, :withdrawn], @changes.last(2).map(&:type))
    assert(@rib.adj_rib_in(@rib.peers.first).empty?, 'the Adj-RIB-In was emptied')
  end
end
