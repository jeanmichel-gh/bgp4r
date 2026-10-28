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
class TestBgpRibRouter < Test::Unit::TestCase

  LOCAL_AS = 65001

  # A Neighbor that keeps what it was asked to send instead of writing it to
  # a socket, so the router can be driven with no session. The functional
  # test drives the real one.
  class Recording < BGP::Neighbor
    def sent ; @sent ||= [] ; end
    def send_update(u) ; sent << u ; end
  end

  def setup
    @rib = BGP::Rib.new(:local_as => LOCAL_AS, :router_id => '1.1.1.1')
    @neighbors = []
  end

  def teardown
    @rib.feed.stop if @rib
    @neighbors.each { |n| n.close }
  end

  # A Neighbor that has read its peer's OPEN and reached Established.
  def neighbor(last_octet = 2, as = 65002, established: true)
    n = Recording.new(:my_as => LOCAL_AS, :remote_addr => "10.0.0.#{last_octet}",
                      :local_addr => '10.0.0.1', :id => '1.1.1.1')
    n.instance_variable_set(:@rmt_as, as)
    n.instance_variable_set(:@rmt_bgp_id, "#{last_octet}.#{last_octet}.#{last_octet}.#{last_octet}")
    n.instance_variable_set(:@state, :Established) if established
    @neighbors << n
    n
  end

  # A peer the routes come from, which is not any of the attached ones.
  def source(as = LOCAL_AS)
    BGP::Rib::Peer.new(:address => '10.9.9.9', :remote_as => as,
                       :router_id => '9.9.9.9', :local_as => LOCAL_AS)
  end

  def route(prefix = '10.1.0.0/16', peer = source, attrs = nil)
    attrs ||= [BGP::Origin.new(0), BGP::Next_hop.new(peer.address), BGP::Local_pref.new(100)]
    BGP::Rib::Route.new(prefix, BGP::Path_attribute.new(*attrs), peer)
  end

  def v6_route(prefix = '2011:1::/32', peer = source)
    attrs = [BGP::Origin.new(0), BGP::Local_pref.new(100),
             BGP::Mp_reach.new(:afi => 2, :safi => 1, :nexthop => ['2011:9::1'],
                               :nlris => [prefix])]
    BGP::Rib::Route.new(prefix, BGP::Path_attribute.new(*attrs), peer)
  end

  def test_router_mode_is_off_until_asked_for
    assert_nil(@rib.router)
    r = @rib.advertise
    assert_kind_of(BGP::Rib::Router, r)
    assert(r.started?)
    assert_same(r, @rib.router)
    assert_same(r, @rib.advertise, 'asking twice is the same router')
  end

  def test_a_loc_rib_change_is_advertised
    n = neighbor
    @rib.attach(n)
    @rib.advertise
    assert(@rib.drain, 'the initial advertisement is flushed first')
    @rib.announce(route)
    assert(@rib.drain)
    assert_equal(1, n.sent.size)
    u = n.sent.first
    assert_equal(['10.1.0.0/16'], u.nlri.to_ary)
    assert_equal('65001', u.path_attribute[BGP::As_path].as_path, 'our AS was prepended')
    assert_equal('10.0.0.1', u.path_attribute[BGP::Next_hop].next_hop, 'our address on the session')
    assert(!u.path_attribute.has?(BGP::Local_pref), 'never to an external peer')
  end

  # RFC 4271 section 9.2: a session that comes up gets what we have.
  def test_a_session_coming_up_gets_the_whole_loc_rib
    @rib.announce(route('10.1.0.0/16'))
    @rib.announce(route('10.2.0.0/16'))
    n = neighbor
    @rib.attach(n)
    @rib.advertise
    assert(@rib.drain)
    assert_equal(1, n.sent.size, 'both prefixes share attributes, so one message')
    assert_equal(%w[10.1.0.0/16 10.2.0.0/16], n.sent.first.nlri.to_ary.sort)
  end

  def test_a_session_that_is_not_established_gets_nothing
    n = neighbor(2, 65002, :established => false)
    @rib.attach(n)
    @rib.advertise
    assert(@rib.drain, 'the initial advertisement is flushed first')
    @rib.announce(route)
    assert(@rib.drain)
    assert_equal([], n.sent)
  end

  # The Adj-RIB-Out is what makes this a diff. The same route again is not
  # resent, which is the whole reason to keep one.
  def test_the_same_route_again_is_not_resent
    n = neighbor
    @rib.attach(n)
    @rib.advertise
    assert(@rib.drain, 'the initial advertisement is flushed first')
    @rib.announce(route)
    assert(@rib.drain)
    assert_equal(1, n.sent.size)
    @rib.announce(route)
    assert(@rib.drain)
    assert_equal(1, n.sent.size, 'nothing changed, so nothing was sent')
  end

  def test_a_changed_route_is_resent
    n = neighbor
    @rib.attach(n)
    @rib.advertise
    assert(@rib.drain, 'the initial advertisement is flushed first')
    @rib.announce(route)
    assert(@rib.drain)
    other = [BGP::Origin.new(0), BGP::Next_hop.new('10.9.9.9'), BGP::Local_pref.new(100),
             BGP::Communities.new('65001:7')]
    @rib.announce(route('10.1.0.0/16', source, other))
    assert(@rib.drain)
    assert_equal(2, n.sent.size)
    assert_equal('65001:7', n.sent.last.path_attribute[BGP::Communities].communities)
  end

  # A change the peer cannot see is not sent to it. MED does not cross into
  # another AS (RFC 4271 section 5.1.4), so export strips it and the
  # attributes this peer would get are the same as before: the Adj-RIB-Out
  # says so and no UPDATE goes out. My first version of the test above used
  # a MED change and was surprised by this.
  def test_a_change_the_peer_cannot_see_is_not_sent
    n = neighbor
    @rib.attach(n)
    @rib.advertise
    assert(@rib.drain, 'the initial advertisement is flushed first')
    @rib.announce(route)
    assert(@rib.drain)
    assert_equal(1, n.sent.size)
    med = [BGP::Origin.new(0), BGP::Next_hop.new('10.9.9.9'), BGP::Local_pref.new(100),
           BGP::Multi_exit_disc.new(7)]
    @rib.announce(route('10.1.0.0/16', source, med))
    assert(@rib.drain)
    assert_equal(1, n.sent.size, 'MED never reaches this peer, so nothing changed for it')
    assert_equal(7, @rib.best('10.1.0.0/16').med, 'though the table took the change')
  end

  def test_a_prefix_losing_its_best_route_is_withdrawn
    n = neighbor
    @rib.attach(n)
    @rib.advertise
    assert(@rib.drain, 'the initial advertisement is flushed first')
    @rib.announce(route)
    assert(@rib.drain)
    @rib.withdraw(source, '10.1.0.0/16')
    assert(@rib.drain)
    assert_equal(2, n.sent.size)
    assert_equal(['10.1.0.0/16'], n.sent.last.withdrawn.to_ary)
    assert(@rib.router.adj_rib_out(@rib.router.peers.first).empty?)
  end

  # Nothing was advertised, so nothing is withdrawn: a withdrawal for a
  # prefix the peer never had would be noise on the wire.
  def test_a_prefix_the_peer_never_had_is_not_withdrawn
    n = neighbor
    @rib.attach(n)
    @rib.advertise
    assert(@rib.drain)
    @rib.withdraw(source, '10.1.0.0/16')
    assert(@rib.drain)
    assert_equal([], n.sent)
  end

  # A route is not sent back to the peer it came from, and the refusal is
  # recorded rather than silent.
  def test_a_route_is_not_sent_back_to_its_sender
    n = neighbor
    @rib.attach(n)
    @rib.advertise
    # The route's peer is the attached neighbor's own peer.
    peer = BGP::Rib::Peer.new(:address => '10.0.0.2', :remote_as => 65002,
                              :router_id => '2.2.2.2', :local_as => LOCAL_AS)
    @rib.announce(route('10.1.0.0/16', peer,
                        [BGP::Origin.new(0), BGP::Next_hop.new('10.0.0.2'),
                         BGP::As_path.new(65002)]))
    assert(@rib.drain)
    assert_equal([], n.sent)
    assert_equal([['10.1.0.0/16', peer, :back_to_sender]], @rib.router.skipped)
  end

  def test_an_export_refusal_is_recorded
    n = neighbor
    @rib.attach(n)
    @rib.advertise
    assert(@rib.drain, 'the initial advertisement is flushed first')
    attrs = [BGP::Origin.new(0), BGP::Next_hop.new('10.9.9.9'),
             BGP::Communities.new(:no_advertise)]
    @rib.announce(route('10.1.0.0/16', source, attrs))
    assert(@rib.drain)
    assert_equal([], n.sent)
    assert_equal([:no_advertise], @rib.router.skipped.map(&:last))
  end

  # A Path Identifier is the sender's to allocate (RFC 7911 section 3) and
  # may only be sent on a session that negotiated add-path. This advertises
  # one best route per prefix, so none is ever sent, whatever arrived.
  def test_no_path_identifier_is_ever_sent
    n = neighbor
    @rib.attach(n)
    @rib.advertise
    assert(@rib.drain, 'the initial advertisement is flushed first')
    r = BGP::Rib::Route.new('10.1.0.0/16',
                            BGP::Path_attribute.new(BGP::Origin.new(0),
                                                    BGP::Next_hop.new('10.9.9.9')),
                            source, :path_id => 7)
    @rib.announce(r)
    assert(@rib.drain)
    assert_equal(['10.1.0.0/16'], n.sent.first.nlri.to_ary,
                 'no "ID=7, " in front of it')
  end

  # RFC 4760 section 3: an IPv6 route needs an IPv6 next hop of ours, and
  # nothing on an IPv4 session says what that is. Skipped, with a reason,
  # rather than raising out of the worker thread or sending a bad next hop.
  def test_an_ipv6_route_with_no_next_hop_of_ours_is_skipped
    n = neighbor
    @rib.attach(n)
    @rib.advertise
    assert(@rib.drain, 'the initial advertisement is flushed first')
    @rib.announce(v6_route)
    assert(@rib.drain)
    assert_equal([], n.sent)
    assert_equal([['2011:1::/32', @rib.router.peers.first, :no_next_hop_for_family]],
                 @rib.router.skipped)
  end

  def test_an_ipv6_route_goes_out_when_a_next_hop_is_configured
    n = neighbor
    @rib.attach(n)
    @rib.advertise(:next_hops => { 2 => '2011:aa::1' })
    assert(@rib.drain, 'the initial advertisement is flushed first')
    @rib.announce(v6_route)
    assert(@rib.drain)
    assert_equal(1, n.sent.size)
    mp = n.sent.first.path_attribute[BGP::Mp_reach]
    assert_equal('2011:aa::1', mp.nexthops, 'ours, not the one it arrived with')
    assert(!n.sent.first.path_attribute.has?(BGP::Next_hop))
    assert_equal([], @rib.router.skipped)
  end

  # The peer keeps nothing across a session, so neither do we: the next
  # session has to be told everything again.
  def test_a_session_going_down_empties_its_adj_rib_out
    n = neighbor
    @rib.attach(n)
    @rib.advertise
    assert(@rib.drain, 'the initial advertisement is flushed first')
    @rib.announce(route)
    assert(@rib.drain)
    out = @rib.router.adj_rib_out(@rib.router.peers.first)
    assert_equal(1, out.size)
    n.send(:new_state, :Idle, 'test')
    assert(@rib.drain)
    assert(out.empty?, 'the Adj-RIB-Out went with the session')
  end

  def test_two_peers_each_get_their_own_message
    a = neighbor(2, 65002)
    b = neighbor(3, 65003)
    @rib.attach(a)
    @rib.attach(b)
    @rib.advertise
    assert(@rib.drain, 'the initial advertisement is flushed first')
    @rib.announce(route)
    assert(@rib.drain)
    assert_equal(1, a.sent.size)
    assert_equal(1, b.sent.size)
    assert_equal(2, @rib.router.peers.size)
  end

  # An internal peer gets the route unchanged, with a LOCAL_PREF, and no
  # route reflection unless the router is a reflector.
  def test_an_internal_peer_sees_the_internal_rules
    n = neighbor(4, LOCAL_AS)
    @rib.attach(n)
    @rib.advertise
    assert(@rib.drain, 'the initial advertisement is flushed first')
    # From an external peer, so it may go to an internal one.
    ext = BGP::Rib::Peer.new(:address => '10.8.8.8', :remote_as => 65008,
                             :router_id => '8.8.8.8', :local_as => LOCAL_AS)
    @rib.announce(route('10.1.0.0/16', ext,
                        [BGP::Origin.new(0), BGP::Next_hop.new('10.8.8.8'),
                         BGP::As_path.new(65008)]))
    assert(@rib.drain)
    u = n.sent.first
    assert_equal('65008', u.path_attribute[BGP::As_path].as_path, 'unchanged')
    assert_equal('10.8.8.8', u.path_attribute[BGP::Next_hop].next_hop, 'unchanged')
    assert_equal(BGP::Rib::Decision::DEFAULT_LOCAL_PREF,
                 u.path_attribute[BGP::Local_pref].to_i)
  end

  def test_an_ibgp_route_does_not_reach_an_internal_peer
    n = neighbor(4, LOCAL_AS)
    @rib.attach(n)
    @rib.advertise
    assert(@rib.drain, 'the initial advertisement is flushed first')
    @rib.announce(route)
    assert(@rib.drain)
    assert_equal([], n.sent)
    assert_equal([:ibgp_to_ibgp], @rib.router.skipped.map(&:last))
  end

  def test_a_reflector_may_send_it
    n = neighbor(4, LOCAL_AS)
    @rib.attach(n)
    rr = BGP::Rib::Export.new(:local_as => LOCAL_AS, :router_id => '1.1.1.1',
                              :route_reflector => true)
    @rib.advertise(:export => rr)
    @rib.announce(route)
    assert(@rib.drain)
    assert_equal(1, n.sent.size)
    assert_equal('9.9.9.9', n.sent.first.path_attribute[BGP::Originator_id].originator_id)
    assert_equal(['1.1.1.1'], n.sent.first.path_attribute[BGP::Cluster_list].cluster_ids)
  end

  def test_the_count_of_messages_sent
    n = neighbor
    @rib.attach(n)
    @rib.advertise
    assert(@rib.drain, 'the initial advertisement is flushed first')
    @rib.announce(route('10.1.0.0/16'))
    @rib.announce(route('10.2.0.0/16'))
    assert(@rib.drain)
    assert_equal(2, @rib.router.sent)
  end

  # Attaching after router mode started still advertises to the new peer.
  def test_a_peer_attached_later_is_advertised_to
    @rib.advertise
    @rib.announce(route)
    assert(@rib.drain)
    n = neighbor
    @rib.attach(n)
    assert(@rib.drain)
    assert_equal(1, n.sent.size, 'it got the table on attach')
  end

  # ---- MinRouteAdvertisementIntervalTimer, RFC 4271 section 9.2.1.1 ----
  #
  # The interval itself is tested in mrai_test.rb, with an injected clock
  # and no threads. These drive the whole export side through it: a change
  # that is held sends nothing, and the flush the pacer asks for sends what
  # was waiting. The clock is injected here too, so the flush is triggered
  # by hand rather than by sleeping.

  class Clock
    attr_accessor :t
    def initialize ; @t = 1000.0 ; end
    def call ; @t ; end
    def advance(n) ; @t += n ; self ; end
  end

  # Moves time on and runs the flush on the feed's worker thread, which is
  # what the pacer thread asks for when a window ends.
  def flush(seconds = 0)
    @clock.advance(seconds)
    @rib.feed << [:mrai]
    assert(@rib.drain)
  end

  def paced(**options)
    @clock = Clock.new
    @rib.advertise(:mrai => BGP::Rib::Mrai.new(:clock => @clock, **options))
  end

  def test_the_timer_is_off_by_default
    r = @rib.advertise
    assert(r.mrai.off?)
    assert(!r.pacing?, 'and so there is no thread for it')
  end

  def test_asking_for_an_interval_starts_the_pacer_thread
    r = paced(:ebgp => 30)
    assert(!r.mrai.off?)
    assert(r.pacing?)
    r.stop
    assert(!r.pacing?)
  end

  # The first UPDATE for a destination is never held: there is no earlier
  # one for it to be too close to.
  def test_the_first_update_for_a_destination_goes_out_at_once
    n = neighbor
    @rib.attach(n)
    paced(:ebgp => 30)
    @rib.announce(route('10.1.0.0/16'))
    assert(@rib.drain)
    assert_equal(1, n.sent.size)
    assert_equal(['10.1.0.0/16'], n.sent.first.nlri.to_ary)
  end

  # Section 9.2.1.1: two UPDATEs to one peer touching the same destination
  # "MUST be separated by at least MinRouteAdvertisementIntervalTimer".
  def test_a_second_change_to_one_destination_is_held
    n = neighbor
    @rib.attach(n)
    r = paced(:ebgp => 30)
    @rib.announce(route('10.1.0.0/16'))
    assert(@rib.drain)
    assert_equal(1, n.sent.size)

    @rib.announce(route('10.1.0.0/16', source, [BGP::Origin.new(1),
                                                BGP::Next_hop.new('10.9.9.9')]))
    assert(@rib.drain)
    assert_equal(1, n.sent.size, 'nothing more went out')
    assert_equal([[r.peers.first, '10.1.0.0/16']], r.waiting)

    flush(30)
    assert_equal(2, n.sent.size, 'it went out when the window ended')
    assert_equal(1, n.sent.last.path_attribute[BGP::Origin].to_i, 'the later route')
    assert_equal([], r.waiting)
  end

  # Section 9.2.1.1: "This rate limiting procedure applies on a per-
  # destination basis". Another prefix is not held by the first one's
  # window.
  def test_another_destination_is_not_held
    n = neighbor
    @rib.attach(n)
    paced(:ebgp => 30)
    @rib.announce(route('10.1.0.0/16'))
    assert(@rib.drain)
    @rib.announce(route('10.2.0.0/16'))
    assert(@rib.drain)
    assert_equal(2, n.sent.size)
    assert_equal(['10.2.0.0/16'], n.sent.last.nlri.to_ary)
  end

  # Section 9.2.1.1: "If new routes are selected multiple times while
  # awaiting the expiration of MinRouteAdvertisementIntervalTimer, the last
  # route selected SHALL be advertised at the end of
  # MinRouteAdvertisementIntervalTimer."
  def test_only_the_last_route_selected_is_advertised
    n = neighbor
    @rib.attach(n)
    r = paced(:ebgp => 30)
    @rib.announce(route('10.1.0.0/16'))
    assert(@rib.drain)

    (1..2).each do |origin|
      @rib.announce(route('10.1.0.0/16', source,
                          [BGP::Origin.new(origin), BGP::Next_hop.new('10.9.9.9')]))
      assert(@rib.drain)
    end
    assert_equal(1, n.sent.size, 'both were held')
    assert_equal(1, r.held, 'the second displaced the first')

    flush(30)
    assert_equal(2, n.sent.size, 'two changes, one UPDATE')
    assert_equal(2, n.sent.last.path_attribute[BGP::Origin].to_i, 'the last one selected')
  end

  # Section 9.2.1.1 paces "an advertisement and/or withdrawal of routes to
  # a particular destination", so a withdrawal waits too.
  def test_a_withdrawal_is_held_and_then_sent
    n = neighbor
    @rib.attach(n)
    @rib.announce(route('10.1.0.0/16'))
    paced(:ebgp => 30)
    assert(@rib.drain)
    assert_equal(1, n.sent.size)

    @rib.withdraw(source, '10.1.0.0/16')
    assert(@rib.drain)
    assert_equal(1, n.sent.size, 'the withdrawal is waiting')

    flush(30)
    assert_equal(2, n.sent.size)
    assert_equal(['10.1.0.0/16'], n.sent.last.withdrawn.to_ary)
  end

  # A prefix withdrawn while a change to it is still waiting: the
  # withdrawal replaces what was waiting, and is itself paced, because
  # section 9.2.1.1 covers "an advertisement and/or withdrawal of routes to
  # a particular destination". What must never happen is the stale
  # announcement going out after the route is gone.
  def test_a_withdrawal_replaces_what_was_waiting_for_the_same_destination
    n = neighbor
    @rib.attach(n)
    r = paced(:ebgp => 30)
    @rib.announce(route('10.1.0.0/16'))
    assert(@rib.drain)
    assert_equal(1, n.sent.size)

    # A change to the same prefix, held because of the first UPDATE. It has
    # to be one this peer can see: a LOCAL_PREF change would be stripped on
    # the way out (RFC 4271 section 5.1.5) and so suppressed rather than
    # held, which is what the first draft of this test got wrong.
    @rib.announce(route('10.1.0.0/16', source, [BGP::Origin.new(1),
                                                BGP::Next_hop.new('10.9.9.9')]))
    assert(@rib.drain)
    assert_equal(1, r.waiting.size, 'waiting for the window')

    # The route goes, so the prefix has no best route at all.
    @rib.peer_down(source)
    assert(@rib.drain)
    assert_equal(1, r.waiting.size, 'the withdrawal waits in its place')
    assert_equal(1, n.sent.size, 'and is paced like an advertisement')

    flush(30)
    assert_equal(2, n.sent.size)
    assert_equal(['10.1.0.0/16'], n.sent.last.withdrawn.to_ary,
                 'a withdrawal, not the announcement that was waiting')
    flush(30)
    assert_equal(2, n.sent.size, 'and nothing followed it')
  end

  # A change that puts the attributes back to what the peer already has
  # must drop what was waiting. Otherwise the waiting UPDATE goes out at
  # the end of the window and leaves the peer holding something the
  # Adj-RIB-Out says it does not have. This is why every decision about a
  # destination ends in a hold, an arm or a drop.
  def test_a_change_back_to_what_the_peer_has_drops_what_was_waiting
    n = neighbor
    @rib.attach(n)
    r = paced(:ebgp => 30)
    first = [BGP::Origin.new(0), BGP::Next_hop.new('10.9.9.9')]
    @rib.announce(route('10.1.0.0/16', source, first))
    assert(@rib.drain)
    assert_equal(1, n.sent.size)

    @rib.announce(route('10.1.0.0/16', source, [BGP::Origin.new(1),
                                                BGP::Next_hop.new('10.9.9.9')]))
    assert(@rib.drain)
    assert_equal(1, r.waiting.size)

    @rib.announce(route('10.1.0.0/16', source, first))
    assert(@rib.drain)
    assert_equal([], r.waiting, 'nothing is waiting for a destination with nothing to send')

    flush(30)
    assert_equal(1, n.sent.size, 'the peer still has what it had')
    assert_equal(0, n.sent.last.path_attribute[BGP::Origin].to_i)
  end

  # Sending a destination clears what was waiting for it, since that is
  # what the waiting item was waiting to be. Without that the item stays
  # and goes out again when the window ends.
  def test_sending_a_destination_clears_what_was_waiting_for_it
    n = neighbor
    @rib.attach(n)
    r = paced(:ebgp => 30)
    @rib.announce(route('10.1.0.0/16'))
    assert(@rib.drain)

    @rib.announce(route('10.1.0.0/16', source, [BGP::Origin.new(1),
                                                BGP::Next_hop.new('10.9.9.9')]))
    assert(@rib.drain)
    assert_equal(1, r.waiting.size)

    # The window ends, and a further change arrives before the pacer runs,
    # so this one is sent at once rather than held.
    @clock.advance(30)
    @rib.announce(route('10.1.0.0/16', source, [BGP::Origin.new(2),
                                                BGP::Next_hop.new('10.9.9.9')]))
    assert(@rib.drain)
    assert_equal(2, n.sent.size)
    assert_equal(2, n.sent.last.path_attribute[BGP::Origin].to_i)
    assert_equal([], r.waiting, 'the older item went with it')

    flush(30)
    assert_equal(2, n.sent.size, 'no stale UPDATE at the end of the new window')
  end

  # Section 9.2.1.1 gives a choice for internal peers: "(a) the
  # MinRouteAdvertisementIntervalTimer used for internal peers SHOULD be
  # shorter than the MinRouteAdvertisementIntervalTimer used for external
  # peers, or (b) the procedure describe in this section SHOULD NOT apply
  # to routes sent to internal peers". An interval of 0 is (b).
  def test_an_internal_peer_can_be_left_unpaced
    n = neighbor(3, LOCAL_AS)
    @rib.attach(n)
    paced(:ebgp => 30, :ibgp => 0)
    @rib.announce(route('10.1.0.0/16', source(65002)))
    assert(@rib.drain)
    assert_equal(1, n.sent.size)
    @rib.announce(route('10.1.0.0/16', source(65002),
                        [BGP::Origin.new(1), BGP::Next_hop.new('10.9.9.9')]))
    assert(@rib.drain)
    assert_equal(2, n.sent.size, 'an internal peer with 0 is never held')
  end

  # And (a): the two values are separate, so the same change reaches an
  # internal peer while an external one is still waiting.
  def test_the_interval_differs_by_peer_kind
    ext = neighbor(2, 65002)
    int = neighbor(3, LOCAL_AS)
    [ext, int].each { |x| @rib.attach(x) }
    paced(:ebgp => 30, :ibgp => 5)
    @rib.announce(route('10.1.0.0/16', source(65003)))
    assert(@rib.drain)
    assert_equal(1, ext.sent.size)
    assert_equal(1, int.sent.size)

    @rib.announce(route('10.1.0.0/16', source(65003),
                        [BGP::Origin.new(1), BGP::Next_hop.new('10.9.9.9')]))
    assert(@rib.drain)
    flush(5)
    assert_equal(2, int.sent.size, 'the 5 second window has ended')
    assert_equal(1, ext.sent.size, 'the 30 second one has not')
    flush(25)
    assert_equal(2, ext.sent.size)
  end

  # A change the peer cannot see is suppressed before the interval is
  # consulted, so it neither sends nor arms anything. MED does not cross
  # into another AS (RFC 4271 section 5.1.4).
  def test_a_change_the_peer_cannot_see_is_not_held_either
    n = neighbor
    @rib.attach(n)
    r = paced(:ebgp => 30)
    @rib.announce(route('10.1.0.0/16', source, [BGP::Origin.new(0),
                                                BGP::Next_hop.new('10.9.9.9'),
                                                BGP::Multi_exit_disc.new(10)]))
    assert(@rib.drain)
    assert_equal(1, n.sent.size)
    @rib.announce(route('10.1.0.0/16', source, [BGP::Origin.new(0),
                                                BGP::Next_hop.new('10.9.9.9'),
                                                BGP::Multi_exit_disc.new(20)]))
    assert(@rib.drain)
    assert_equal([], r.waiting, 'identical for this peer, so there is nothing to hold')
    flush(30)
    assert_equal(1, n.sent.size)
  end

  # The peer keeps nothing across a session, so a window armed by the old
  # one must not delay the first UPDATE of the new one.
  def test_a_session_going_down_forgets_its_windows
    n = neighbor
    adapter = @rib.attach(n)
    r = paced(:ebgp => 30)
    @rib.announce(route('10.1.0.0/16'))
    assert(@rib.drain)
    assert_equal(1, n.sent.size)

    r.session_down(adapter)
    assert_equal([], r.waiting)
    # The Adj-RIB-Out was flushed too, so this is a first advertisement.
    @rib.announce(route('10.2.0.0/16'))
    assert(@rib.drain)
    assert_equal(2, n.sent.size, 'not held by the old session\'s window')
  end

  def test_a_flush_with_nothing_due_sends_nothing
    n = neighbor
    @rib.attach(n)
    paced(:ebgp => 30)
    @rib.announce(route('10.1.0.0/16'))
    assert(@rib.drain)
    flush(0)
    flush(0)
    assert_equal(1, n.sent.size)
  end

  # Everything above moves a fake clock and calls the flush by hand, which
  # tests the rules but never the thread. This one uses a real interval and
  # waits for it, so the pacer thread, the feed and the flush are proved to
  # be joined up. It is the only test here that sleeps, which is why the
  # interval is short and the wait is bounded.
  def test_the_pacer_thread_sends_a_held_update_on_its_own
    n = neighbor
    @rib.attach(n)
    r = @rib.advertise(:mrai => BGP::Rib::Mrai.new(:ebgp => 0.15))
    assert(r.pacing?)
    @rib.announce(route('10.1.0.0/16'))
    assert(@rib.drain)
    assert_equal(1, n.sent.size)

    @rib.announce(route('10.1.0.0/16', source, [BGP::Origin.new(1),
                                                BGP::Next_hop.new('10.9.9.9')]))
    assert(@rib.drain)
    assert_equal(1, n.sent.size, 'held, and nobody has called the flush')

    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    sleep(0.02) while n.sent.size < 2 &&
                      Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
    assert_equal(2, n.sent.size, 'the pacer thread sent it when the window ended')
    assert_equal(1, n.sent.last.path_attribute[BGP::Origin].to_i)
    assert_equal([], r.waiting)
  end

  # At most one flush is outstanding at a time. The work happens on the
  # worker thread, so from the moment a window ends until the worker gets
  # through it the deadline is still in the past: without that guard the
  # pacer queues another flush on every turn of its loop, which is a hot
  # loop and a queue the worker cannot keep up with. It showed up first as
  # a drain timing out behind the backlog, not as a wrong route.
  #
  # This one uses a real interval, like the thread test above and unlike
  # the rest of this section, because advancing a fake clock cannot wake a
  # thread that is asleep on a real condition variable.
  def test_the_pacer_asks_for_one_flush_per_window_not_one_per_loop
    n = neighbor
    @rib.attach(n)
    r = @rib.advertise(:mrai => BGP::Rib::Mrai.new(:ebgp => 1))
    100.times { |i| @rib.announce(route("10.#{i}.0.0/16")) }
    assert(@rib.drain)
    100.times do |i|
      @rib.announce(route("10.#{i}.0.0/16", source,
                          [BGP::Origin.new(1), BGP::Next_hop.new('10.9.9.9')]))
    end
    assert(@rib.drain)
    assert_equal(100, r.waiting.size, 'all held inside the one second window')

    # The worker armed the hundred windows a few milliseconds apart as it
    # sent the first batch, so they end in groups rather than together, and
    # a flush per group is right. What is not right is a flush per turn of
    # the pacer's loop: while the worker exports and sends a hundred
    # destinations the deadline stays in the past, which is where it spun.
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    sleep(0.02) while r.waiting.any? &&
                      Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
    assert_equal([], r.waiting, 'the pacer flushed them on its own')
    assert(r.flush_requests <= 20,
           "a flush per group of deadlines, not per loop: #{r.flush_requests} asked for")
    assert(@rib.drain, 'and the worker is not buried under queued flushes')
  end
end
