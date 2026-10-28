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

require 'bgp/rib/route'

module BGP
  module Rib

    # MinRouteAdvertisementIntervalTimer, RFC 4271 section 9.2.1.1: the
    # minimum time between two UPDATEs to one peer that touch the same
    # destination.
    #
    # This is pure, like Export and UpdateBuilder. It holds no thread and
    # sends nothing: it answers whether a destination may go to a peer now,
    # keeps the one item that is waiting if it may not, and says when to
    # come back. Router owns the thread that acts on those answers. The
    # clock is injectable, so every rule below is tested without sleeping.
    #
    #   mrai = Mrai.new(:ebgp => 30, :ibgp => 5)
    #   mrai.hold?(peer, '10.0.0.0/8')   # false the first time
    #   mrai.sent(peer, '10.0.0.0/8')    # arms the window
    #   mrai.hold?(peer, '10.0.0.0/8')   # true until it expires
    #
    # == What the section asks for
    #
    # "The parameter MinRouteAdvertisementIntervalTimer determines the
    # minimum amount of time that must elapse between an advertisement
    # and/or withdrawal of routes to a particular destination by a BGP
    # speaker to a peer. This rate limiting procedure applies on a per-
    # destination basis, although the value of
    # MinRouteAdvertisementIntervalTimer is set on a per BGP peer basis."
    #
    # So the value is per peer and the window is per destination, which is
    # why ready_at is keyed by both. Withdrawals are paced too, because the
    # sentence says "an advertisement and/or withdrawal".
    #
    # The section then says keeping a timer per destination "would be
    # unwarranted overhead", and allows any technique that keeps the
    # interval at or above the value "and will also ensure that a constant
    # upper bound on the interval is acceptable". This keeps one deadline
    # per destination that is inside its window and one timer per Router.
    # The upper bound is the interval itself: an item held at the start of a
    # window goes out when that window ends, so a change is delayed by less
    # than one interval and never by two.
    #
    # "This procedure does not limit the rate of route selection, but only
    # the rate of route advertisement. If new routes are selected multiple
    # times while awaiting the expiration of
    # MinRouteAdvertisementIntervalTimer, the last route selected SHALL be
    # advertised at the end of MinRouteAdvertisementIntervalTimer." That is
    # why hold keeps one item per destination and the later one replaces
    # the earlier: an announcement overwrites an announcement, and a
    # withdrawal overwrites an announcement that never went out.
    #
    # == Internal peers
    #
    # The section gives a choice: either "(a) the
    # MinRouteAdvertisementIntervalTimer used for internal peers SHOULD be
    # shorter than the MinRouteAdvertisementIntervalTimer used for external
    # peers, or (b) the procedure describe in this section SHOULD NOT apply
    # to routes sent to internal peers". Both are reachable here, since the
    # two values are separate: ibgp: 5 with ebgp: 30 is (a), and ibgp: 0 is
    # (b), because an interval of 0 never holds anything.
    #
    # == Defaults, and why bgp4r's is not the RFC's
    #
    # Section 10 suggests 30 seconds on eBGP connections and 5 on iBGP, and
    # those are EBGP_DEFAULT and IBGP_DEFAULT here. bgp4r defaults to 0,
    # which is off, and Mrai.suggested is the one line that asks for the
    # RFC's values.
    #
    # Off is the default because of what this library is for. A script
    # driving a router through a sequence of UPDATEs wants each one on the
    # wire when it says so, and 30 seconds of silence reads as a bug in the
    # device under test. Every test in the tree would have to wait, too.
    # Section 10 makes these timers "suggested default" values and says an
    # implementation "MAY allow the other timers to be configurable", so a
    # configured 0 is within the document.
    class Mrai

      # The suggested default values of RFC 4271 section 10: "The suggested
      # default value for the MinRouteAdvertisementIntervalTimer on EBGP
      # connections is 30 seconds" and "on IBGP connections is 5 seconds".
      EBGP_DEFAULT = 30
      IBGP_DEFAULT = 5

      # RFC 4271 section 10: "The suggested default amount of jitter SHALL
      # be determined by multiplying the base value of the appropriate
      # timer by a random factor, which is uniformly distributed in the
      # range from 0.75 to 1.0. A new random value SHOULD be picked each
      # time the timer is set. The range of the jitter's random value MAY
      # be configurable."
      JITTER_MIN = 0.75
      JITTER_MAX = 1.0

      attr_reader :ebgp, :ibgp, :jitter

      # ebgp, ibgp: the interval in seconds for an external and an internal
      #   peer. 0 is off and holds nothing.
      # jitter: true applies the section 10 factor, a fresh one each time a
      #   window is armed. A Range gives another one, since section 10 says
      #   the range MAY be configurable. False is no jitter, which is what
      #   a test wants.
      # clock: something answering call and returning seconds, monotonic.
      #   Injected by the tests; Router uses the default.
      # random: something answering rand(Range), for a repeatable jitter in
      #   a test.
      def initialize(ebgp: 0, ibgp: 0, jitter: false, clock: nil, random: nil)
        @ebgp = Float(ebgp)
        @ibgp = Float(ibgp)
        raise ArgumentError, 'a negative interval is not a delay' if @ebgp < 0 || @ibgp < 0
        @jitter = case jitter
                  when true  then (JITTER_MIN..JITTER_MAX)
                  when false, nil then nil
                  when Range then jitter
                  else raise ArgumentError, "jitter wants true, false or a Range, not #{jitter.inspect}"
                  end
        @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
        @random = random || Random.new
        @ready_at = {}   # [peer, prefix] => the time its window ends
        @pending = {}    # [peer, prefix] => the one item waiting for it
      end

      # The RFC's suggested values, section 10, with its jitter.
      def self.suggested(**options)
        new(:ebgp => EBGP_DEFAULT, :ibgp => IBGP_DEFAULT, :jitter => true, **options)
      end

      def now ; @clock.call ; end

      # True when no peer is paced, so Router can skip its timer thread
      # entirely and behave exactly as it did before this existed.
      def off? ; @ebgp.zero? && @ibgp.zero? ; end

      # The interval for peer, by the per peer rule of section 9.2.1.1.
      def interval(peer)
        peer.ebgp? ? @ebgp : @ibgp
      end

      # True when an UPDATE touching prefix went to peer too recently, so
      # this one must wait. False when the interval is 0, which is how
      # option (b) of section 9.2.1.1 is reached for internal peers.
      def hold?(peer, prefix, at = now)
        return false if interval(peer).zero?
        ends = @ready_at[key(peer, prefix)]
        !ends.nil? && at < ends
      end

      # Records that an UPDATE for prefix went to peer, which arms the
      # destination's window. Jitter, where asked for, is picked here, so a
      # new random value is used each time the timer is set.
      def sent(peer, prefix, at = now)
        span = interval(peer)
        return self if span.zero?
        @ready_at[key(peer, prefix)] = at + jittered(span)
        self
      end

      # Keeps item as the one thing waiting to go to peer for prefix. A
      # later call replaces an earlier one, which is section 9.2.1.1's "the
      # last route selected SHALL be advertised". Returns what it displaced,
      # or nil, so a caller can count what it suppressed.
      def hold(peer, prefix, item)
        k = key(peer, prefix)
        was = @pending[k]
        @pending[k] = item
        was
      end

      # The waiting item for peer and prefix, without removing it.
      def pending(peer, prefix) ; @pending[key(peer, prefix)] ; end

      # Forgets whatever was waiting for peer and prefix, because that
      # destination has just been dealt with another way. Returns it, or
      # nil. Every decision about a destination must end in a hold, a sent
      # or a drop, or a held item outlives the route it was about: an
      # announcement held inside its window, for a prefix that is then
      # withdrawn before the window ends, would otherwise go out after the
      # route was gone.
      def drop(peer, prefix) ; @pending.delete(key(peer, prefix)) ; end

      def pending_count ; @pending.size ; end

      # Every destination with something waiting, as [peer, prefix].
      def pending_keys ; @pending.keys.map { |k| k.dup } ; end

      # Everything whose window has ended, as [peer, prefix, item], and no
      # longer waiting afterwards. Expired windows with nothing waiting are
      # dropped in the same pass, which is what keeps ready_at the size of
      # the recent churn rather than the size of the table.
      def due(at = now)
        ready = []
        @pending.delete_if do |(peer, prefix), item|
          next false if hold?(peer, prefix, at)
          ready << [peer, prefix, item]
          true
        end
        @ready_at.delete_if { |_, ends| ends <= at }
        ready
      end

      # Seconds until the earliest window with something waiting for it
      # ends, 0 when something is already due, or nil when nothing is
      # waiting and there is no reason to wake up.
      def next_deadline(at = now)
        soonest = nil
        @pending.each_key do |(peer, prefix)|
          ends = @ready_at[key(peer, prefix)]
          return 0 if ends.nil? || ends <= at
          soonest = ends if soonest.nil? || ends < soonest
        end
        soonest && soonest - at
      end

      # Forgets peer, as when its session goes down. The peer keeps nothing
      # across a session, so a window from the old one must not delay the
      # first UPDATE of the new one.
      def forget(peer)
        @ready_at.delete_if { |(p, _), _| p == peer }
        @pending.delete_if { |(p, _), _| p == peer }
        self
      end

      def to_s
        return 'MRAI off' if off?
        format('MRAI ebgp %gs ibgp %gs%s, %d waiting',
               @ebgp, @ibgp, @jitter ? ' jittered' : '', @pending.size)
      end

      private

      def key(peer, prefix) ; [peer, Route.normalize(prefix)] ; end

      def jittered(span)
        return span unless @jitter
        span * @random.rand(@jitter)
      end
    end

  end
end
