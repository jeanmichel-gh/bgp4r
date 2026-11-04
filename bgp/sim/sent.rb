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

require 'bgp/daemon/speaker'

module BGP
  module Sim

    # What `bgp4r-sim` has put on the wire: the counters, and one record
    # per generated feed.
    #
    # **It is the send side of `BGP::Daemon::Recorder` and answers the
    # same five keys**, which docs/daemon.md names: `prefixes_sent`,
    # `updates_sent`, `started_at`, `finished_at` and
    # `prefixes_per_second`. The Recorder computes those for what
    # arrived, from Established to the last UPDATE; this computes them
    # for what left, from the first send to the last. The timestamp
    # format is **the Recorder's own**, `Recorder.iso`, rather than a
    # second copy of a format string: two timestamps in one console that
    # disagree about their format is the drift this repository records
    # three times.
    #
    # **`finished_at` is nil while a feed is running, and that is what
    # lets a console show a feed rather than a spinner.** A generated
    # range of 200000 prefixes is 1575 UPDATEs; a reader polling
    # `/api/sent` sees `prefixes_sent` climbing with no `finished_at`,
    # and the feed's own record carries its range and its rate.
    #
    # It is pure: no socket, no session and no thread of its own. The
    # Injector calls it from whatever thread did the sending, and a
    # generated feed is a thread of the Injector's, so every public
    # method here takes the one lock.
    #
    # **One lock, and a Feed has none of its own.** The feeds are
    # mutated only through the methods here, so there is one lock to
    # take and no pair of locks to take in the wrong order. That is the
    # arrangement `BGP::Rib::Table` has for the objects it holds, and
    # the reason is the one `bgp/events.rb` records: two locks and an
    # order between them is a deadlock a later tidy-up reintroduces.
    class Sent

      # One generated feed, streaming or finished.
      #
      # **A feed is counted and not listed**, which is the requirement
      # docs/daemon.md states for the generator: recording a million
      # prefixes to know what was sent defeats the streaming that is the
      # whole reason `RouteGenerator` builds and sends one UPDATE at a
      # time. So a feed keeps its range and its counts, and a withdrawal
      # of a generated range regenerates the same prefixes rather than
      # reading a list back.
      #
      # It carries no lock: see the class comment above.
      class Feed

        attr_reader :id, :action, :peer, :range, :prefixes, :updates,
                    :started_at, :finished_at, :error

        def initialize(id, action, range, peer = nil, now = Time.now)
          @id, @action, @range, @peer = id, action.to_s, range, peer
          @prefixes, @updates = 0, 0
          @started_at = now
          @finished_at = nil
          @error = nil
        end

        # One UPDATE of this feed went out. Called under Sent's lock.
        def add(prefixes, updates = 1)
          @prefixes += prefixes
          @updates += updates
          self
        end

        # The feed ended, with the reason when it ended badly. A feed
        # that failed keeps its counts, because how far it got is the
        # interesting part. Called under Sent's lock.
        def finish(error = nil, now = Time.now)
          @finished_at ||= now
          @error ||= error && error.to_s
          self
        end

        def running?
          @finished_at.nil?
        end

        # Prefixes a second over this feed's life, or nil while it is
        # running or when it took no measurable time.
        def prefixes_per_second
          Sent.rate(@prefixes, @started_at, @finished_at)
        end

        def to_h
          { :id                  => @id,
            :action              => @action,
            :peer                => @peer,
            :range               => @range,
            :prefixes_sent       => @prefixes,
            :updates_sent        => @updates,
            :started_at          => Daemon::Recorder.iso(@started_at),
            :finished_at         => Daemon::Recorder.iso(@finished_at),
            :prefixes_per_second => prefixes_per_second,
            :running             => running?,
            :error               => @error }
        end
      end

      # The actions whose messages carry prefixes and so count as
      # UPDATEs of a feed or a block. A NOTIFICATION, a ROUTE-REFRESH and
      # a replayed capture are messages and are counted as such, but
      # none of them is an UPDATE of ours, so none of them moves
      # `updates_sent`.
      UPDATE_ACTIONS = %w[announce withdraw attribute fault].freeze

      # prefixes over the seconds between two times, rounded, or nil when
      # there is no second time or no time passed. nil is an answer and
      # means the rate is not known yet, which is what a reader of a
      # running feed wants rather than a zero.
      def self.rate(prefixes, from, to)
        return nil unless from && to
        secs = to - from
        return nil unless secs > 0
        (prefixes / secs).round(1)
      end

      def initialize
        @lock = Mutex.new
        @prefixes, @withdrawn, @updates, @messages = 0, 0, 0, 0
        @started_at, @finished_at = nil, nil
        @feeds = []
        @next_feed = 0
      end

      # A send that is not part of a feed: one UPDATE, a fault, a replay,
      # a NOTIFICATION. `prefixes` is how many prefixes the message
      # carried, which is 0 for a message that carries none.
      def count(action, prefixes = 0, messages = 1, now = Time.now)
        @lock.synchronize { tally(action, prefixes, messages, now) }
        self
      end

      # Starts a feed and returns it. The caller ticks it per UPDATE and
      # finishes it, which is why it is handed back rather than wrapped
      # in a block: a feed runs on a thread of its own so that the HTTP
      # request which asked for it can answer at once.
      def start_feed(action, range, peer = nil, now = Time.now)
        @lock.synchronize do
          @started_at ||= now
          @next_feed += 1
          feed = Feed.new(@next_feed, action, range, peer, now)
          @feeds << feed
          feed
        end
      end

      # A feed's UPDATE, counted in the feed and in the totals. `as` is
      # the action the totals count it under when that is not the
      # feed's own, which is a churn's: its feed mixes withdrawals and
      # announcements, and each goes to its own total.
      def tick(feed, prefixes, messages = 1, now = Time.now, as: nil)
        @lock.synchronize do
          feed.add(prefixes, messages)
          tally(as || feed.action, prefixes, messages, now)
        end
        self
      end

      def finish_feed(feed, error = nil, now = Time.now)
        @lock.synchronize { feed.finish(error, now) }
        self
      end

      # The feeds, as data. Hashes rather than the Feed objects, because
      # a Feed is mutated under the lock this just released.
      def feeds
        @lock.synchronize { @feeds.collect { |f| f.to_h } }
      end

      def running?
        @lock.synchronize { @feeds.any? { |f| f.running? } }
      end

      # The five keys docs/daemon.md names, plus the counts that separate
      # a withdrawal from an announcement.
      #
      # **`finished_at` is nil while any feed runs**, so a reader cannot
      # take a rate off a feed that is still going: the pair says either
      # "still sending" or "this is what it came to".
      def summary
        @lock.synchronize do
          done = @feeds.any? { |f| f.running? } ? nil : @finished_at
          { :prefixes_sent       => @prefixes,
            :prefixes_withdrawn  => @withdrawn,
            :updates_sent        => @updates,
            :messages_sent       => @messages,
            :started_at          => Daemon::Recorder.iso(@started_at),
            :finished_at         => Daemon::Recorder.iso(done),
            :prefixes_per_second => Sent.rate(@prefixes, @started_at, done),
            :feeds               => @feeds.size,
            :feeds_running       => @feeds.count { |f| f.running? } }
        end
      end

      def to_h
        { :summary => summary, :feeds => feeds }
      end

      private

      # The totals. Called with the lock held, by every path above, so
      # the counters and the two times cannot disagree with each other.
      def tally(action, prefixes, messages, now)
        @started_at ||= now
        @finished_at = now
        @messages += messages
        if action.to_s == 'withdraw'
          @withdrawn += prefixes
        else
          @prefixes += prefixes
        end
        @updates += messages if UPDATE_ACTIONS.include?(action.to_s)
      end

    end

  end
end
