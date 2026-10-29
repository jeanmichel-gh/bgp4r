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
require 'socket'
require 'bgp4r'
require 'bgp/rib'

# Three speakers over loopback, so a route crosses a bgp4r router and comes
# out the other side with the export rules applied to it. This is the
# transit case and the route reflector case of RIB phase 3. The protocol
# behaviour is here, where it can be run with no router installed at all,
# and it asserts more than any interop test can, because it reads the
# UPDATE off the wire.
#
# What it cannot tell you is whether anybody else accepts what we send.
# test/functional/lab/rib_router_gobgp_test.rb does that half, with GoBGP
# as the far peer and no Docker. Keep the two in step: a rule added here
# is worth a line there if a real router's opinion of it would differ.
#
# One Table with two Neighbors is what makes a router: a Neighbor holds one
# session, so a speaker with two peers has two of them, both attached to the
# same table. test/helpers/server.rb starts a single listener, so this file
# starts its own.
#
# BGP:: names are written out in full, see Conventions in CLAUDE.md.
class RibRouterTest < Test::Unit::TestCase

  RR_AS = 100        # ours, the router in the middle
  LEFT_AS = 200
  RIGHT_AS = 300

  # Collects the UPDATEs a speaker receives.
  class Catcher
    def updates ; @updates ||= [] ; end
    def update(m) ; updates << m if m.is_a?(BGP::Update) ; end
  end

  def setup
    @listeners = []
    @clients = []
    @rib = nil
  end

  def teardown
    @rib.feed.stop if @rib
    @clients.each { |c| c.close }
    @listeners.each do |server, neighbor, thread|
      thread.kill if thread
      neighbor.close
      server.close unless server.closed?
    end
  end

  # A listening side of the router: its own Neighbor, its own port, attached
  # to the shared table. Returns [neighbor, port].
  #
  # remote_addr has to differ per peer. A BGP::Rib::Peer is identified by
  # its address, which is right, and PeerAdapter builds it from the
  # Neighbor's configured remote_addr rather than from the accepted socket.
  # Two listeners both configured 127.0.0.1 are therefore one Peer as far as
  # the table is concerned, which collapses the two Adj-RIB-Outs into one
  # and makes every route look like it is going back to its sender. On a
  # real network two peers have two addresses; over loopback they have to be
  # given them.
  def listener(id, remote_addr)
    server = TCPServer.new('127.0.0.1', 0)
    n = BGP::Neighbor.new(4, RR_AS, 180, id, remote_addr, '127.0.0.1')
    thread = Thread.new do
      begin
        while (session = server.accept)
          n.start_session(session)
        end
      rescue IOError, SystemCallError
      end
    end
    @listeners << [server, n, thread]
    [n, server.addr[1]]
  end

  # A peer that connects to one of those ports and keeps what it receives.
  def client(as, id, port)
    c = BGP::Neighbor.new(4, as, 180, id, '127.0.0.1', '127.0.0.1')
    catcher = Catcher.new
    c.add_observer catcher
    @clients << c
    c.start :port => port
    [c, catcher]
  end

  def wait_for(timeout = 5)
    deadline = Time.now + timeout
    loop do
      return true if yield
      return false if Time.now > deadline
      sleep 0.02
    end
  end

  def ebgp_update(as, prefix, next_hop)
    pa = BGP::Path_attribute.new(BGP::Origin.new(0), BGP::Next_hop.new(next_hop),
                                 BGP::As_path.new(as))
    BGP::Update.new(pa, BGP::Nlri.new(prefix))
  end

  # RFC 4271 section 5.1.2: a speaker originating a route and advertising it
  # to an internal peer "shall include an empty AS_PATH attribute". AS_PATH
  # is well known mandatory, so the attribute is there and carries no
  # segments, which is not the same as leaving it out. bgp4r never validates
  # what it builds and does not yet check for a missing well known mandatory
  # attribute on receipt either, so an UPDATE without one travels happily
  # and the far side sees no AS_PATH at all. My first version of this helper
  # left it out and the reflector test fell over on a nil.
  def ibgp_update(prefix, next_hop, local_pref = 300)
    pa = BGP::Path_attribute.new(BGP::Origin.new(0), BGP::Next_hop.new(next_hop),
                                 BGP::As_path.new, BGP::Local_pref.new(local_pref))
    BGP::Update.new(pa, BGP::Nlri.new(prefix))
  end

  # A route from one external peer, re-advertised to another: our AS goes on
  # the front of the AS_PATH (RFC 4271 section 5.1.2) and the next hop
  # becomes ours (section 5.1.3). This is what a transit AS does.
  def test_a_route_crosses_the_router_between_two_external_peers
    left_side, left_port = listener('0.0.0.1', '127.0.0.2')
    right_side, right_port = listener('0.0.0.1', '127.0.0.3')
    @rib = BGP::Rib.new(:local_as => RR_AS, :router_id => '0.0.0.1')
    @rib.attach(left_side)
    @rib.attach(right_side)
    router = @rib.advertise

    left, = client(LEFT_AS, '0.0.0.2', left_port)
    _right, right_heard = client(RIGHT_AS, '0.0.0.3', right_port)
    assert(wait_for { left_side.is_established? && right_side.is_established? })
    assert(wait_for { @rib.drain })

    left.send_update ebgp_update(LEFT_AS, '10.1.0.0/16', '10.9.9.9')
    assert(wait_for { @rib.drain && @rib.loc_rib.size == 1 }, 'the router took it')
    assert(wait_for { @rib.drain && right_heard.updates.size == 1 },
           "the far side got #{right_heard.updates.size}")

    u = right_heard.updates.first
    assert_equal(['10.1.0.0/16'], u.nlri.to_ary)
    assert_equal("#{RR_AS} #{LEFT_AS}", u.path_attribute[BGP::As_path].as_path,
                 'our AS in front of theirs')
    assert_equal('127.0.0.1', u.path_attribute[BGP::Next_hop].next_hop, 'ours, not 10.9.9.9')
    assert(!u.path_attribute.has?(BGP::Local_pref))
    assert_equal(1, router.sent)
    # And it did not go back where it came from.
    assert_equal([:back_to_sender], router.skipped.map(&:last))
  end

  # The base IBGP rule RFC 4456 section 4 describes: without reflection, a
  # route from an internal peer does not reach another internal peer.
  def test_an_ibgp_route_stops_at_a_router_that_is_not_a_reflector
    a_side, a_port = listener('0.0.0.1', '127.0.0.4')
    b_side, b_port = listener('0.0.0.1', '127.0.0.5')
    @rib = BGP::Rib.new(:local_as => RR_AS, :router_id => '0.0.0.1')
    @rib.attach(a_side)
    @rib.attach(b_side)
    router = @rib.advertise

    a, = client(RR_AS, '0.0.0.4', a_port)
    _b, b_heard = client(RR_AS, '0.0.0.5', b_port)
    assert(wait_for { a_side.is_established? && b_side.is_established? })
    assert(wait_for { @rib.drain })

    a.send_update ibgp_update('10.1.0.0/16', '10.4.4.4')
    assert(wait_for { @rib.drain && @rib.loc_rib.size == 1 }, 'the router took it')
    assert(@rib.drain)
    assert_equal([], b_heard.updates, 'and kept it to itself')
    assert(router.skipped.map(&:last).include?(:ibgp_to_ibgp))
    assert_equal(0, router.sent)
  end

  # RFC 4456: a reflector does pass it on, with the two attributes of
  # section 8 added, and the AS_PATH and NEXT_HOP left alone because the
  # peer is internal (RFC 4271 sections 5.1.2 and 5.1.3).
  def test_a_reflector_passes_an_ibgp_route_to_another_client
    a_side, a_port = listener('0.0.0.1', '127.0.0.4')
    b_side, b_port = listener('0.0.0.1', '127.0.0.5')
    @rib = BGP::Rib.new(:local_as => RR_AS, :router_id => '0.0.0.1')
    @rib.attach(a_side)
    @rib.attach(b_side)
    reflector = BGP::Rib::Export.new(:local_as => RR_AS, :router_id => '0.0.0.1',
                                     :route_reflector => true, :cluster_id => '7.7.7.7')
    router = @rib.advertise(:export => reflector)

    a, = client(RR_AS, '0.0.0.4', a_port)
    _b, b_heard = client(RR_AS, '0.0.0.5', b_port)
    assert(wait_for { a_side.is_established? && b_side.is_established? })
    assert(wait_for { @rib.drain })

    a.send_update ibgp_update('10.1.0.0/16', '10.4.4.4')
    assert(wait_for { @rib.drain && b_heard.updates.size == 1 },
           "the other client got #{b_heard.updates.size}")

    u = b_heard.updates.first
    assert_equal(['10.1.0.0/16'], u.nlri.to_ary)
    # Section 8: the originator's BGP Identifier in the local AS, which is
    # what client A put in its OPEN.
    assert_equal('0.0.0.4', u.path_attribute[BGP::Originator_id].originator_id)
    assert_equal(['7.7.7.7'], u.path_attribute[BGP::Cluster_list].cluster_ids)
    assert_equal('10.4.4.4', u.path_attribute[BGP::Next_hop].next_hop, 'unchanged')
    assert_equal('empty', u.path_attribute[BGP::As_path].as_path, 'unchanged')
    assert_equal(300, u.path_attribute[BGP::Local_pref].to_i, 'kept inside the AS')
    assert_equal(1, router.sent)
  end

  # RFC 4456 section 6: "A route from a Non-Client IBGP peer: Reflect to all
  # the Clients." Two internal peers that are neither of our clients get
  # nothing from each other, because other reflectors are fully meshed and
  # have the route already. The reflector test above names no clients, so
  # every internal peer is one; here the list names an address that is
  # neither of them.
  def test_a_reflector_sends_a_non_clients_route_to_no_other_non_client
    a_side, a_port = listener('0.0.0.1', '127.0.0.4')
    b_side, b_port = listener('0.0.0.1', '127.0.0.5')
    @rib = BGP::Rib::Table.new(:local_as => RR_AS, :router_id => '0.0.0.1')
    @rib.attach(a_side)
    @rib.attach(b_side)
    reflector = BGP::Rib::Export.new(:local_as => RR_AS, :router_id => '0.0.0.1',
                                     :route_reflector => true,
                                     :clients => ['127.0.0.9'])
    router = @rib.advertise(:export => reflector)

    a, = client(RR_AS, '0.0.0.4', a_port)
    _b, b_heard = client(RR_AS, '0.0.0.5', b_port)
    assert(wait_for { a_side.is_established? && b_side.is_established? })
    assert(wait_for { @rib.drain })

    a.send_update ibgp_update('10.1.0.0/16', '10.4.4.4')
    assert(wait_for { @rib.drain && @rib.loc_rib.size == 1 }, 'the reflector took it')
    assert(@rib.drain)
    assert_equal([], b_heard.updates, 'and sent it to no other non-client')
    assert(router.skipped.map(&:last).include?(:non_client_to_non_client))
    assert_equal(0, router.sent)
  end

  # A reflected route must not carry the reflection attributes out of the
  # AS: both are optional non-transitive and exist to avoid loops inside it.
  def test_the_reflection_attributes_do_not_leave_the_as
    a_side, a_port = listener('0.0.0.1', '127.0.0.4')
    out_side, out_port = listener('0.0.0.1', '127.0.0.3')
    @rib = BGP::Rib.new(:local_as => RR_AS, :router_id => '0.0.0.1')
    @rib.attach(a_side)
    @rib.attach(out_side)
    reflector = BGP::Rib::Export.new(:local_as => RR_AS, :router_id => '0.0.0.1',
                                     :route_reflector => true)
    @rib.advertise(:export => reflector)

    a, = client(RR_AS, '0.0.0.4', a_port)
    _out, out_heard = client(RIGHT_AS, '0.0.0.3', out_port)
    assert(wait_for { a_side.is_established? && out_side.is_established? })
    assert(wait_for { @rib.drain })

    a.send_update ibgp_update('10.1.0.0/16', '10.4.4.4')
    assert(wait_for { @rib.drain && out_heard.updates.size == 1 },
           "the external peer got #{out_heard.updates.size}")

    u = out_heard.updates.first
    assert(!u.path_attribute.has?(BGP::Originator_id))
    assert(!u.path_attribute.has?(BGP::Cluster_list))
    assert_equal(RR_AS.to_s, u.path_attribute[BGP::As_path].as_path, 'our AS, prepended')
    assert_equal('127.0.0.1', u.path_attribute[BGP::Next_hop].next_hop)
  end

  # A prefix of our own, advertised to both kinds of peer at once, which is
  # the only place the two AS_PATH rules of RFC 4271 section 5.1.2 can be
  # seen disagreeing on the same route: "its own AS number in a path
  # segment, of type AS_SEQUENCE" to an external peer, and "an empty AS_PATH
  # attribute" to an internal one.
  def test_a_prefix_we_originate_reaches_both_kinds_of_peer
    int_side, int_port = listener('0.0.0.1', '127.0.0.4')
    ext_side, ext_port = listener('0.0.0.1', '127.0.0.3')
    @rib = BGP::Rib::Table.new(:local_as => RR_AS, :router_id => '0.0.0.1')
    @rib.attach(int_side)
    @rib.attach(ext_side)
    router = @rib.advertise

    _int, int_heard = client(RR_AS, '0.0.0.4', int_port)
    _ext, ext_heard = client(RIGHT_AS, '0.0.0.3', ext_port)
    assert(wait_for { int_side.is_established? && ext_side.is_established? })
    assert(wait_for { @rib.drain })

    @rib.originate('10.1.0.0/16')
    assert(wait_for { @rib.drain && int_heard.updates.size == 1 && ext_heard.updates.size == 1 },
           "internal #{int_heard.updates.size}, external #{ext_heard.updates.size}")

    inside = int_heard.updates.first
    assert_equal(['10.1.0.0/16'], inside.nlri.to_ary)
    assert(inside.path_attribute[BGP::As_path].segments.empty?,
           'an empty AS_PATH to an internal peer')
    assert_equal('127.0.0.1', inside.path_attribute[BGP::Next_hop].next_hop,
                 'and our own address, section 5.1.3')
    assert_equal(100, inside.path_attribute[BGP::Local_pref].to_i)

    outside = ext_heard.updates.first
    assert_equal(['10.1.0.0/16'], outside.nlri.to_ary)
    segs = outside.path_attribute[BGP::As_path].segments
    assert_equal(1, segs.size)
    assert_equal([RR_AS], segs.first.as, 'our AS alone to an external peer')
    assert_equal('127.0.0.1', outside.path_attribute[BGP::Next_hop].next_hop)
    assert(!outside.path_attribute.has?(BGP::Local_pref))
    assert_equal(2, router.sent)
    assert_equal([], router.skipped)
  end

  def test_withdrawing_a_prefix_we_originated_reaches_the_peer
    ext_side, ext_port = listener('0.0.0.1', '127.0.0.3')
    @rib = BGP::Rib::Table.new(:local_as => RR_AS, :router_id => '0.0.0.1')
    @rib.attach(ext_side)
    @rib.advertise

    _ext, ext_heard = client(RIGHT_AS, '0.0.0.3', ext_port)
    assert(wait_for { ext_side.is_established? })
    assert(wait_for { @rib.drain })

    @rib.originate('10.1.0.0/16')
    assert(wait_for { @rib.drain && ext_heard.updates.size == 1 })
    @rib.withdraw(@rib.local_peer, '10.1.0.0/16')
    assert(wait_for { @rib.drain && ext_heard.updates.size == 2 },
           "the peer got #{ext_heard.updates.size}")
    assert_equal(['10.1.0.0/16'], ext_heard.updates.last.withdrawn.to_ary)
    assert_equal([], @rib.originated)
  end

  # A withdrawal crosses the router too, which is the half that is easy to
  # leave out: a peer that is told about a route and never told it went
  # holds it for ever.
  def test_a_withdrawal_crosses_the_router
    left_side, left_port = listener('0.0.0.1', '127.0.0.2')
    right_side, right_port = listener('0.0.0.1', '127.0.0.3')
    @rib = BGP::Rib.new(:local_as => RR_AS, :router_id => '0.0.0.1')
    @rib.attach(left_side)
    @rib.attach(right_side)
    @rib.advertise

    left, = client(LEFT_AS, '0.0.0.2', left_port)
    _right, right_heard = client(RIGHT_AS, '0.0.0.3', right_port)
    assert(wait_for { left_side.is_established? && right_side.is_established? })
    assert(wait_for { @rib.drain })

    left.send_update ebgp_update(LEFT_AS, '10.1.0.0/16', '10.9.9.9')
    assert(wait_for { @rib.drain && right_heard.updates.size == 1 })

    left.send_update BGP::Update.new(BGP::Withdrawn.new('10.1.0.0/16'))
    assert(wait_for { @rib.drain && right_heard.updates.size == 2 },
           "the far side got #{right_heard.updates.size}")
    assert_equal(['10.1.0.0/16'], right_heard.updates.last.withdrawn.to_ary)
    assert(@rib.loc_rib.empty?)
  end

  # The session going down takes the routes with it, and the far side is
  # told, which is the same hole one step further out.
  def test_a_session_dropping_withdraws_its_routes_from_the_other_peer
    left_side, left_port = listener('0.0.0.1', '127.0.0.2')
    right_side, right_port = listener('0.0.0.1', '127.0.0.3')
    @rib = BGP::Rib.new(:local_as => RR_AS, :router_id => '0.0.0.1')
    @rib.attach(left_side)
    @rib.attach(right_side)
    @rib.advertise

    left, = client(LEFT_AS, '0.0.0.2', left_port)
    _right, right_heard = client(RIGHT_AS, '0.0.0.3', right_port)
    assert(wait_for { left_side.is_established? && right_side.is_established? })
    assert(wait_for { @rib.drain })

    left.send_update ebgp_update(LEFT_AS, '10.1.0.0/16', '10.9.9.9')
    assert(wait_for { @rib.drain && right_heard.updates.size == 1 })

    left.stop
    assert(wait_for { !left_side.is_established? }, 'the router noticed')
    assert(wait_for { @rib.drain && right_heard.updates.size == 2 },
           "the far side got #{right_heard.updates.size}")
    assert_equal(['10.1.0.0/16'], right_heard.updates.last.withdrawn.to_ary)
    assert(@rib.loc_rib.empty?)
  end
end
