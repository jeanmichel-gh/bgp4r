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
#
# Nothing in this file sleeps. The clock is injected, so each rule of RFC
# 4271 section 9.2.1.1 is checked by moving time rather than waiting for it.
class TestBgpRibMrai < Test::Unit::TestCase

  LOCAL_AS = 65001

  # A clock the test moves by hand.
  class Clock
    attr_accessor :t
    def initialize ; @t = 1000.0 ; end
    def call ; @t ; end
    def advance(n) ; @t += n ; self ; end
  end

  def setup
    @clock = Clock.new
  end

  def mrai(**options)
    BGP::Rib::Mrai.new(:clock => @clock, **options)
  end

  def ebgp(last_octet = 2)
    BGP::Rib::Peer.new(:address => "10.0.0.#{last_octet}", :remote_as => 65002,
                       :router_id => '2.2.2.2', :local_as => LOCAL_AS)
  end

  def ibgp(last_octet = 3)
    BGP::Rib::Peer.new(:address => "10.0.0.#{last_octet}", :remote_as => LOCAL_AS,
                       :router_id => '3.3.3.3', :local_as => LOCAL_AS)
  end

  def test_the_default_is_off
    m = mrai
    assert(m.off?)
    assert_equal('MRAI off', m.to_s)
    assert_equal(0.0, m.interval(ebgp))
    assert_equal(0.0, m.interval(ibgp))
  end

  # An interval of 0 holds nothing, however many times a destination is
  # sent. That is the behaviour the Router had before this existed.
  def test_an_interval_of_zero_never_holds
    m = mrai
    3.times do
      assert(!m.hold?(ebgp, '10.0.0.0/8'))
      m.sent(ebgp, '10.0.0.0/8')
    end
    assert_equal(0, m.pending_count)
  end

  # RFC 4271 section 10: "The suggested default value for the
  # MinRouteAdvertisementIntervalTimer on EBGP connections is 30 seconds"
  # and "on IBGP connections is 5 seconds".
  def test_the_suggested_values_are_the_ones_in_section_10
    assert_equal(30, BGP::Rib::Mrai::EBGP_DEFAULT)
    assert_equal(5, BGP::Rib::Mrai::IBGP_DEFAULT)
    m = BGP::Rib::Mrai.suggested(:clock => @clock)
    assert_equal(30.0, m.interval(ebgp))
    assert_equal(5.0, m.interval(ibgp))
    assert(!m.off?)
  end

  # Section 9.2.1.1: "the value of MinRouteAdvertisementIntervalTimer is
  # set on a per BGP peer basis."
  def test_the_value_is_per_peer_kind
    m = mrai(:ebgp => 30, :ibgp => 5)
    assert_equal(30.0, m.interval(ebgp))
    assert_equal(5.0, m.interval(ibgp))
    m.sent(ebgp, '10.0.0.0/8')
    m.sent(ibgp, '10.0.0.0/8')
    @clock.advance(6)
    assert(m.hold?(ebgp, '10.0.0.0/8'), 'still inside the 30 second window')
    assert(!m.hold?(ibgp, '10.0.0.0/8'), 'past the 5 second one')
  end

  # Section 9.2.1.1: "This rate limiting procedure applies on a per-
  # destination basis". One destination's window says nothing about
  # another's.
  def test_the_window_is_per_destination
    m = mrai(:ebgp => 30)
    m.sent(ebgp, '10.1.0.0/16')
    assert(m.hold?(ebgp, '10.1.0.0/16'))
    assert(!m.hold?(ebgp, '10.2.0.0/16'), 'a different destination is free')
  end

  # And the same destination to two peers is two windows, since the value
  # is per peer and the window is armed by sending to one of them.
  def test_one_destination_to_two_peers_is_two_windows
    m = mrai(:ebgp => 30)
    a, b = ebgp(2), ebgp(4)
    m.sent(a, '10.1.0.0/16')
    assert(m.hold?(a, '10.1.0.0/16'))
    assert(!m.hold?(b, '10.1.0.0/16'))
  end

  def test_a_window_ends_after_the_interval
    m = mrai(:ebgp => 30)
    m.sent(ebgp, '10.0.0.0/8')
    @clock.advance(29.9)
    assert(m.hold?(ebgp, '10.0.0.0/8'))
    @clock.advance(0.1)
    assert(!m.hold?(ebgp, '10.0.0.0/8'), 'exactly at the interval it is free')
  end

  # Section 9.2.1.1: "If new routes are selected multiple times while
  # awaiting the expiration of MinRouteAdvertisementIntervalTimer, the last
  # route selected SHALL be advertised at the end of
  # MinRouteAdvertisementIntervalTimer."
  def test_the_last_item_held_is_the_one_that_goes_out
    m = mrai(:ebgp => 30)
    m.sent(ebgp, '10.0.0.0/8')
    assert_nil(m.hold(ebgp, '10.0.0.0/8', :first), 'nothing was waiting yet')
    assert_equal(:first, m.hold(ebgp, '10.0.0.0/8', :second), 'it displaced the first')
    assert_equal(:third, (m.hold(ebgp, '10.0.0.0/8', :third) ; m.pending(ebgp, '10.0.0.0/8')))
    assert_equal(1, m.pending_count, 'three changes, one item waiting')
    @clock.advance(30)
    assert_equal([[ebgp, '10.0.0.0/8', :third]], m.due)
  end

  def test_nothing_is_due_before_its_window_ends
    m = mrai(:ebgp => 30)
    m.sent(ebgp, '10.0.0.0/8')
    m.hold(ebgp, '10.0.0.0/8', :item)
    @clock.advance(29)
    assert_equal([], m.due)
    assert_equal(1, m.pending_count, 'still waiting')
    @clock.advance(1)
    assert_equal(1, m.due.size)
    assert_equal(0, m.pending_count, 'due takes it')
  end

  def test_due_returns_each_waiting_destination_once
    m = mrai(:ebgp => 30, :ibgp => 5)
    e, i = ebgp, ibgp
    [[e, '10.1.0.0/16'], [e, '10.2.0.0/16'], [i, '10.3.0.0/16']].each do |peer, prefix|
      m.sent(peer, prefix)
      m.hold(peer, prefix, prefix)
    end
    @clock.advance(5)
    due = m.due
    assert_equal([[i, '10.3.0.0/16', '10.3.0.0/16']], due, 'only the iBGP one has expired')
    @clock.advance(25)
    assert_equal(2, m.due.size)
    assert_equal(0, m.pending_count)
  end

  # Section 9.2.1.1 allows any technique that keeps the interval at or
  # above the value and "will also ensure that a constant upper bound on
  # the interval". The bound here is the interval itself: an item held the
  # moment a window opened waits exactly that long and no longer.
  def test_the_delay_is_bounded_by_one_interval
    m = mrai(:ebgp => 30)
    m.sent(ebgp, '10.0.0.0/8')
    m.hold(ebgp, '10.0.0.0/8', :item)
    assert_equal(30.0, m.next_deadline)
    @clock.advance(10)
    assert_equal(20.0, m.next_deadline, 'the deadline does not move when an item is replaced')
    m.hold(ebgp, '10.0.0.0/8', :later)
    assert_equal(20.0, m.next_deadline)
  end

  def test_next_deadline_is_the_earliest_one_waiting
    m = mrai(:ebgp => 30, :ibgp => 5)
    m.sent(ebgp, '10.1.0.0/16')
    m.hold(ebgp, '10.1.0.0/16', :a)
    assert_equal(30.0, m.next_deadline)
    m.sent(ibgp, '10.2.0.0/16')
    m.hold(ibgp, '10.2.0.0/16', :b)
    assert_equal(5.0, m.next_deadline, 'the iBGP window ends first')
  end

  def test_next_deadline_is_nil_with_nothing_waiting
    m = mrai(:ebgp => 30)
    assert_nil(m.next_deadline)
    m.sent(ebgp, '10.0.0.0/8')
    assert_nil(m.next_deadline, 'an armed window with nothing waiting needs no wake up')
  end

  def test_next_deadline_is_zero_when_something_is_already_due
    m = mrai(:ebgp => 30)
    m.hold(ebgp, '10.0.0.0/8', :item)
    assert_equal(0, m.next_deadline, 'held with no window armed at all')
    m2 = mrai(:ebgp => 30)
    m2.sent(ebgp, '10.0.0.0/8')
    m2.hold(ebgp, '10.0.0.0/8', :item)
    @clock.advance(30)
    assert_equal(0, m2.next_deadline)
  end

  # A destination dealt with another way must not leave an item behind. An
  # announcement held inside its window, for a prefix withdrawn before the
  # window ends, would otherwise be advertised after the route was gone.
  def test_drop_forgets_what_was_waiting
    m = mrai(:ebgp => 30)
    m.sent(ebgp, '10.0.0.0/8')
    m.hold(ebgp, '10.0.0.0/8', :announce)
    assert_equal(:announce, m.drop(ebgp, '10.0.0.0/8'))
    assert_equal(0, m.pending_count)
    assert_nil(m.drop(ebgp, '10.0.0.0/8'), 'dropping twice is harmless')
    @clock.advance(30)
    assert_equal([], m.due, 'nothing goes out when the window ends')
  end

  # A peer keeps nothing across a session, so a window armed by the old one
  # must not delay the first UPDATE of the new one.
  def test_forget_clears_a_peer
    m = mrai(:ebgp => 30)
    a, b = ebgp(2), ebgp(4)
    [a, b].each { |p| m.sent(p, '10.0.0.0/8') ; m.hold(p, '10.0.0.0/8', :item) }
    m.forget(a)
    assert(!m.hold?(a, '10.0.0.0/8'), 'its window is gone')
    assert_nil(m.pending(a, '10.0.0.0/8'))
    assert(m.hold?(b, '10.0.0.0/8'), 'the other peer is untouched')
    assert_equal(:item, m.pending(b, '10.0.0.0/8'))
  end

  # An expired window with nothing waiting for it is dropped when due
  # runs, so the map holds the recent churn rather than the whole table.
  def test_due_prunes_expired_windows
    m = mrai(:ebgp => 30)
     10.times { |i| m.sent(ebgp, "10.#{i}.0.0/16") }
    @clock.advance(30)
    m.due
    # Nothing is holding them open any more, so each one may be sent at
    # once and the next window is armed fresh.
    10.times { |i| assert(!m.hold?(ebgp, "10.#{i}.0.0/16")) }
    assert_nil(m.next_deadline)
  end

  # RFC 4271 section 10: "The suggested default amount of jitter SHALL be
  # determined by multiplying the base value of the appropriate timer by a
  # random factor, which is uniformly distributed in the range from 0.75 to
  # 1.0."
  def test_the_jitter_range_is_the_one_in_section_10
    assert_equal(0.75, BGP::Rib::Mrai::JITTER_MIN)
    assert_equal(1.0, BGP::Rib::Mrai::JITTER_MAX)
    assert_equal((0.75..1.0), mrai(:ebgp => 30, :jitter => true).jitter)
    assert_nil(mrai(:ebgp => 30).jitter, 'off unless asked for')
  end

  def test_jitter_shortens_the_window_within_the_range
    100.times do
      clock = Clock.new
      m = BGP::Rib::Mrai.new(:ebgp => 30, :jitter => true, :clock => clock)
      m.sent(ebgp, '10.0.0.0/8')
      m.hold(ebgp, '10.0.0.0/8', :item)
      delay = m.next_deadline
      assert(delay >= 30 * 0.75, "#{delay} is below the 0.75 factor")
      assert(delay <= 30 * 1.0, "#{delay} is above the 1.0 factor")
    end
  end

  # Section 10: "A new random value SHOULD be picked each time the timer is
  # set." A fixed factor would make every window the same length.
  def test_a_fresh_factor_is_picked_each_time_a_window_is_armed
    m = mrai(:ebgp => 30, :jitter => true)
    spans = []
    20.times do |i|
      m.sent(ebgp, "10.#{i}.0.0/16")
      m.hold(ebgp, "10.#{i}.0.0/16", :item)
      spans << m.next_deadline
      m.drop(ebgp, "10.#{i}.0.0/16")
    end
    assert(spans.uniq.size > 1, 'the same factor every time is not a fresh one')
  end

  # Section 10: "The range of the jitter's random value MAY be
  # configurable."
  def test_the_jitter_range_can_be_given
    m = mrai(:ebgp => 100, :jitter => (0.5..0.5))
    m.sent(ebgp, '10.0.0.0/8')
    m.hold(ebgp, '10.0.0.0/8', :item)
    assert_equal(50.0, m.next_deadline)
  end

  def test_a_repeatable_random_can_be_given
    args = { :ebgp => 100, :jitter => true, :clock => @clock }
    a = BGP::Rib::Mrai.new(:random => Random.new(42), **args)
    b = BGP::Rib::Mrai.new(:random => Random.new(42), **args)
    [a, b].each { |m| m.sent(ebgp, '10.0.0.0/8') ; m.hold(ebgp, '10.0.0.0/8', :item) }
    assert_equal(a.next_deadline, b.next_deadline)
  end

  def test_a_negative_interval_is_refused
    assert_raise(ArgumentError) { mrai(:ebgp => -1) }
    assert_raise(ArgumentError) { mrai(:ibgp => -0.5) }
  end

  def test_a_jitter_that_is_not_a_range_is_refused
    assert_raise(ArgumentError) { mrai(:ebgp => 30, :jitter => 0.9) }
  end

  # The prefix is normalized the way every other RIB key is, through
  # Route.normalize, so the same destination written two ways is one window
  # and not two. Host bits are masked off and an IPv6 prefix is compressed.
  #
  # Route.normalize does not do this for an IPAddr, which it turns into a
  # /32, so nothing here passes one. That is a bug in Route and is filed
  # under "Known issues to work on" rather than worked around here.
  def test_a_prefix_is_normalized
    m = mrai(:ebgp => 30)
    m.sent(ebgp, '10.0.0.0/8')
    assert(m.hold?(ebgp, '10.1.2.3/8'), 'the host bits are not part of the destination')
    m.hold(ebgp, '10.1.2.3/8', :item)
    assert_equal(1, m.pending_count)
    assert_equal(:item, m.pending(ebgp, '10.0.0.0/8'))

    m.sent(ebgp, '2011:0001::/32')
    assert(m.hold?(ebgp, '2011:1::/32'), 'one IPv6 destination written two ways')
  end

  def test_to_s_says_what_it_is_doing
    m = mrai(:ebgp => 30, :ibgp => 5)
    assert_equal('MRAI ebgp 30s ibgp 5s, 0 waiting', m.to_s)
    m.sent(ebgp, '10.0.0.0/8')
    m.hold(ebgp, '10.0.0.0/8', :item)
    assert_equal('MRAI ebgp 30s ibgp 5s, 1 waiting', m.to_s)
    assert_equal('MRAI ebgp 30s ibgp 5s jittered, 0 waiting',
                 mrai(:ebgp => 30, :ibgp => 5, :jitter => true).to_s)
  end
end
