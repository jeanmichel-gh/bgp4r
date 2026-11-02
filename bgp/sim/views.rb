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

require 'bgp/daemon/views'
require 'bgp/sim/injector'

module BGP
  module Sim

    # What `bgp4r-sim` answers, as plain data with Symbol keys, ready
    # for JSON. One method per GET path of docs/daemon.md's read table.
    #
    # **`status` and `peers` are `bgp4rd`'s, inherited and not
    # rewritten**, which is the read table's own requirement: "the same
    # shape `bgp4rd` answers, so one driver reads both". So this is a
    # subclass of `BGP::Daemon::Views` and the two programs cannot
    # answer differently shaped peer rows. That works because the
    # daemon's view already copes with a Speaker that has no table: with
    # no Loc-RIB there is no `rib.view` to merge, every peer row is the
    # session half alone, and the summary is the two counts it can make.
    # Nothing was changed there to make this fit.
    #
    # What this adds is the three reads an injector has that a daemon
    # does not: what it has sent, what it is configured to be able to
    # send, and its events.
    class Views < Daemon::Views

      # `PAGE_LIMIT` and `MAX_LIMIT` are the superclass's and are not
      # restated here: the same two numbers `bgp4rd` pages its RIB with,
      # for the same reason, and a second copy of a number is the shape
      # #223 found as a constant nothing read. A generated range is not
      # rows at all, so the only thing paged here is what a scenario
      # announced by name.
      attr_reader :injector

      def initialize(injector)
        @injector = injector
        super(injector.speaker)
      end

      # The router, its sessions and a summary.
      #
      # **`summary.rib` is 0 and that is the honest number**, which is
      # worth saying because it looks like a stub. routescope's state
      # contract is `summary: { established:, peers:, rib: }`, and an
      # injector holds no Loc-RIB: zero routes in a table it does not
      # have is true, where leaving the key out would make a console show
      # a blank and putting the announced count there would call a list
      # of what it sent a RIB. What it sent is `announced` beside it and
      # `/api/sent` in full.
      def status(_params = {})
        base = super()
        base.merge(:api     => :http,
                   :summary => base[:summary].merge(
                     :rib       => 0,
                     :announced => @injector.announced.size,
                     :sent      => @injector.sent.summary[:prefixes_sent]))
      end

      def peers(_params = {})
        super()
      end

      # What it has sent: the counters, the feeds, and one row per
      # prefix announced by name.
      #
      # The rows are in routescope's `bgp_routes` shape, which
      # docs/routescope-labs.md section 9.2 says an injector answers with
      # what it has announced, and they are paged in `bgp4rd`'s page
      # envelope so a caller walks them the same way.
      def sent(params = {})
        rows = @injector.announced
        offset, limit = window(params)
        page = rows[offset, limit].to_a
        nxt = offset + limit
        { :summary => @injector.sent.summary,
          :feeds   => @injector.sent.feeds,
          :routes  => { :rows => page, :total => rows.size, :offset => offset,
                        :limit => limit,
                        :next_offset => nxt < rows.size ? nxt : nil } }
      end

      # What it is configured to be able to send, which is the Injector's
      # own answer: the sessions, the actions with their body keys, and
      # the fault catalog.
      def topology(_params = {})
        @injector.topology
      end

      # Its events, from `since` on.
      #
      # **In `bgp/events.rb`'s own shape and not ospfv2's**, which is a
      # correction to docs/daemon.md's read table: it said "Sim's own
      # shape", and ospfv2's simulator answers `{seq, time, kind, text}`
      # with a clock time, so `Drivers::Sim`'s own event script has to
      # invent a level, an interface and an empty data hash, and carries
      # a lambda that rebuilds a date from a time of day and subtracts a
      # day when the result is in the future. `Event#to_h` already
      # carries `seq`, `time`, `level`, `kind`, `peer`, `message` and
      # `data`, with a full ISO 8601 time, so answering that shape loses
      # nothing, invents nothing, and leaves a driver with one rename to
      # do. Measured against routescope at `7eabde1`.
      #
      # `seq` beside the events is where a reader resumes from, and an
      # `:overflow` event with no `seq` is how the stream says a number
      # asked for has already rolled off the backlog.
      def events(params = {})
        since = params['since'] || params[:since]
        n = since.nil? ? nil : integer_param(since)
        { :seq    => speaker.events.seq,
          :kinds  => BGP::Events::KINDS.collect { |k| k.to_s },
          :events => speaker.events.since(n).collect { |e| e.to_h } }
      end

      private

      # `offset` and `limit` from a query string, where every value is a
      # String, clamped the way the daemon's are. `Daemon::Views#window`
      # does the same job for the socket's JSON params and reads them
      # under both spellings, which a query string does not have.
      def window(params)
        offset = integer_param(params['offset'] || params[:offset] || 0, 'offset')
        limit  = integer_param(params['limit'] || params[:limit] || PAGE_LIMIT, 'limit')
        [offset.negative? ? 0 : offset, limit.clamp(1, MAX_LIMIT)]
      end

      def integer_param(value, name = 'since')
        Integer(value)
      rescue ArgumentError, TypeError
        raise ArgumentError, "#{name} must be an integer, got #{value.inspect}"
      end

    end

  end
end
