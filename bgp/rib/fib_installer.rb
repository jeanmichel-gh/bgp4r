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

require 'bgp/rib/fib'

module BGP
  module Rib

    # Puts the Loc-RIB in a forwarding table and keeps it there.
    #
    # The only part of the FIB side that is not pure, and all it does is
    # join the pure ones, the way Router joins Export, UpdateBuilder and
    # AdjRibOut: a Loc-RIB change goes to Fib#plan, what comes back goes to
    # the backend as a command, and Fib#commit records it afterwards.
    #
    #   rib.install(table: 100)        # and rib.fib to read it back
    #   rib.uninstall                  # takes its routes out again
    #
    # Two things it shares with Router, for the same reasons.
    #
    # Everything runs on the feed's one worker thread. The on_change
    # listener only queues the change, because running a command inside the
    # listener would hold the table's lock for as long as a process takes
    # to start, and the listener may be running on a neighbour's event
    # dispatch thread, which also runs that session (RFC 4271 section 4.4:
    # stall it and the peer stops getting KEEPALIVEs).
    #
    # And a route that never reached the table has to say so, which is
    # #failed, keyed by prefix. A forwarding entry that silently did not
    # happen is the hardest kind of bug to see from outside, which is what
    # Router#skipped is for on the export side.
    class FibInstaller

      attr_reader :table, :fib, :backend

      def initialize(table, feed, backend:)
        @table = table
        @feed = feed
        @backend = backend
        @fib = Fib.new
        @failed = {}
        @lock = Mutex.new
      end

      # The Proc it registers is kept, because it is the handle stop hands
      # back to Table#off_change, and keeping it is also what says this is
      # registered: there is no second flag for that, as there was before
      # stop could take a listener off.
      def start
        listener = @lock.synchronize do
          return self if @started
          @started = true
          @listener = proc { |change| @feed << [:fib, [change]] }
        end
        # The worker would otherwise start on the first attach, and a FIB
        # fed only by rib.originate never attaches anything. See
        # PeerFeed#start.
        @feed.start
        @table.on_change(&listener)
        sync_all
        self
      end

      def started? ; @lock.synchronize { !!@started } ; end

      # Everything the Loc-RIB already holds, queued as changes, so turning
      # this on part way through a session installs what is there and not
      # only what changes next. Router#session_up does the same thing for a
      # peer that has just come up.
      def sync_all
        changes = @table.synchronize do
          @table.loc_rib.prefixes.map do |prefix|
            LocRib::Change.new(prefix, nil, @table.loc_rib.best(prefix), :sync)
          end
        end
        @feed << [:fib, changes] unless changes.empty?
        self
      end

      # Called on the worker thread, by PeerFeed#apply.
      #
      # A stopped installer runs nothing. What stops being called is the
      # listener, which stop takes off the table; **what this guard is for
      # is the one case that gets past it, which is stop's drain timing
      # out.** The drain is bounded, so a worker that cannot be reached in
      # time leaves work queued with the flush already run, and that work
      # would arrive here and put the route back into the forwarding table
      # the uninstall had just flushed. Which is the bug this whole change
      # is about, since before stop could take a listener off at all,
      # every Loc-RIB change after an uninstall did exactly that.
      #
      # Nothing else reaches it, measured by sabotage: with the listener
      # off, and with PeerFeed#apply reaching this through
      # Table#fib_installer, work queued for an installer that has since
      # been replaced goes to the replacement and not to this.
      def run_changes(changes)
        return unless started?
        changes.each { |change| apply(@fib.plan(change)) }
      end

      # One operation: run it, then record it.
      #
      # An install is recorded only if the command worked, because the whole
      # point of planning before committing is not to claim a route the
      # kernel refused.
      #
      # A removal is recorded either way, and that asymmetry is deliberate.
      # `ip route del` exits 2 for a route the table does not have, so the
      # commonest way a removal fails is that the route was already gone,
      # which is the outcome it wanted. Either the kernel removed it or it
      # was not there, and in both cases this must stop believing it is
      # installed or it will never try again. The failure is still recorded.
      def apply(op)
        return nil if op.nil?
        result = @backend.run(op)
        if result.ok?
          @lock.synchronize { @failed.delete(op.prefix) }
          @fib.commit(op)
        else
          @lock.synchronize { @failed[op.prefix] = result }
          @fib.commit(op) if op.remove?
          Log.error "#{self.class}: #{result}"
        end
        result
      end

      # Takes out every route in the table that carries this backend's
      # proto, and forgets them. What a FIB owes the machine on the way
      # out, since nothing else will tidy a routing table up.
      #
      # Both families, because a flush names one and a table can hold both.
      # A table that does not exist yet makes `ip route flush` exit 2, and
      # that is not a failure here: there is nothing to flush, which is the
      # outcome asked for.
      def withdraw_all
        results = [@backend.flush, @backend.flush(:ipv6 => true)]
        @fib.flush
        results
      end

      # Takes the listener off the table, runs what it had already queued,
      # and then flushes. **The order is the same as Router#stop's and for
      # the same reason**, which that method's comment argues: off_change
      # takes the lock decide runs the listeners under, so once it has
      # returned nothing more can be queued; what was queued is ahead of
      # the drain's own work item in one FIFO queue, so it runs through
      # the installer that queued it; and @started goes false after that,
      # so nothing reaches the backend once the flush has run.
      #
      # The flag was cleared first here before, which read as the same
      # thing and was not: run_changes did not look at it, so the drained
      # work installed and only withdraw_all's flush took it out again.
      def stop(timeout = 1)
        listener = @lock.synchronize { l = @listener ; @listener = nil ; l }
        if listener
          @table.off_change(listener)
          @table.drain(timeout)
        end
        @lock.synchronize { @started = false }
        withdraw_all
      end

      # Why a prefix is not in the forwarding table, keyed by prefix, as the
      # Result the command came back with.
      def failed ; @lock.synchronize { @failed.dup } ; end
      def clear_failed ; @lock.synchronize { @failed.clear } ; self ; end

      def to_s
        "FIB installer: #{@fib}, #{@backend}"
      end

    end

  end
end
