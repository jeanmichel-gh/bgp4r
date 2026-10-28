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

require 'bgp/rib/export'
require 'bgp/rib/adj_rib_out'
require 'bgp/rib/update_builder'
require 'bgp/rib/mrai'

module BGP
  module Rib

    # Router mode: advertises the Loc-RIB to the peers the table is attached
    # to. This is the only piece of the export side that is not pure, and all
    # it does is join the pure ones:
    #
    #   Loc-RIB change -> Export#for -> AdjRibOut diff -> UpdateBuilder -> send
    #
    #   rib = BGP::Rib.new(local_as: 65001, router_id: '1.1.1.1')
    #   rib.attach(neighbor)      # receive from it
    #   rib.advertise             # and advertise to it
    #
    # One attach, both directions. Turning this on makes a bgp4r speaker a
    # router rather than a listener, so it is off until asked for.
    #
    # Three things set it going, and they are the three Phase 3 events of
    # RFC 4271 section 9.1.3. A session reaching Established gets the whole
    # Loc-RIB, which is event c), "when a new BGP speaker connection has
    # been established", in the only form bgp4r has: everything we have,
    # once. A Loc-RIB change goes to every peer, which is a) for a learned
    # route and b) for one Table#originate announced. The sending itself is
    # section 9.2. A session leaving Established empties its Adj-RIB-Out,
    # because the peer keeps nothing across a session.
    #
    # Everything happens on the feed's one worker thread, never on the
    # table's lock and never on a neighbour's event dispatch thread: the
    # on_change listener only queues the change. A send that blocked inside
    # the listener would hold the table lock, and a send on the event thread
    # would stall the session that thread runs.
    #
    # Rate limiting is the MinRouteAdvertisementIntervalTimer of RFC 4271
    # section 9.2.1.1, and it is off unless asked for:
    #
    #   rib.advertise(mrai: BGP::Rib::Mrai.suggested)   # the RFC's 30s and 5s
    #   rib.advertise(mrai: { ebgp: 10, ibgp: 0 })      # or your own
    #
    # Mrai holds the rules and the arithmetic. What lives here is the one
    # thread that acts on them: it sleeps until the earliest window with
    # something waiting for it ends, then hands the work to the feed, so
    # the held UPDATEs are built and sent on the same worker thread as
    # every other UPDATE. With no interval set there is no such thread and
    # nothing is ever held, which is the behaviour this class had before
    # the timer existed.
    #
    # Not here, and its own piece of work: MinASOriginationIntervalTimer,
    # RFC 4271 section 9.2.1.2, which paces UPDATEs "that report changes
    # within the advertising BGP speaker's own autonomous systems" and so
    # applies to what Table#originate announces rather than per
    # destination. Section 10 suggests 15 seconds for it.
    class Router

      attr_reader :table, :export, :mrai

      # table, feed: the Table and its PeerFeed.
      # export: an Export, or nil to build one from the table's own local AS
      #   and router ID.
      # next_hops: our address per address family, as { afi => address }, for
      #   a family whose next hop is not the session's own address. An IPv6
      #   route over an IPv4 session needs an IPv6 next hop (RFC 4760 section
      #   3), and nothing on the session says what ours is, so without one
      #   those routes are not advertised and skipped is why.
      # mrai: an Mrai, or a Hash of its options, for the rate limiting of
      #   RFC 4271 section 9.2.1.1. The default holds nothing.
      def initialize(table, feed, export: nil, next_hops: {}, mrai: nil)
        @table = table
        @feed = feed
        @export = export || Export.new(:local_as => table.local_as, :router_id => table.router_id)
        @next_hops = {}
        next_hops.each { |afi, address| @next_hops[Integer(afi)] = address.to_s }
        @mrai = case mrai
                when nil   then Mrai.new
                when Hash  then Mrai.new(**mrai)
                else mrai
                end
        @out = {}        # Peer => AdjRibOut
        @lock = Mutex.new
        @skipped = {}   # [prefix, peer] => the last reason it was not advertised
        @sent = 0
        @held = 0
        @flush_requests = 0
        # Its own lock, not @lock: Mrai takes none of its own and is read by
        # the pacer thread while the worker thread changes it. Keeping it
        # off @lock means neither thread can nest the two.
        @mrai_lock = Mutex.new
        @wake = ConditionVariable.new
      end

      # Starts advertising to every peer the table is attached to, and to any
      # attached later. Idempotent.
      def start
        return self if @lock.synchronize { s = @started ; @started = true ; s }
        @table.on_change { |change| @feed << [:advertise, [change]] }
        @feed.adapters.each { |adapter| watch(adapter) }
        start_pacer unless @mrai.off?
        self
      end

      def started? ; @lock.synchronize { !!@started } ; end

      # Stops the pacer thread. Called by PeerFeed#stop, and by a test that
      # wants no thread left behind. Anything still held is dropped unsent,
      # which is what stopping means.
      def stop(timeout = 1)
        thread = @lock.synchronize { t = @pacer ; @pacer = nil ; t }
        return self unless thread
        # The flag is set under the lock the pacer waits on, and in the same
        # critical section as the broadcast. Setting it anywhere else races:
        # a thread that had not reached its wait yet would miss the
        # broadcast, wait with no deadline, and have to be killed.
        @mrai_lock.synchronize { @stopping = true ; @wake.broadcast }
        thread.join(timeout) or thread.kill
        self
      end

      def pacing? ; !!@lock.synchronize { @pacer } ; end

      # How many UPDATEs the interval of section 9.2.1.1 has suppressed:
      # each time a change replaced one already waiting for the same
      # destination, which is the "last route selected" rule saving a
      # message.
      def held ; @mrai_lock.synchronize { @held } ; end

      # How many flushes the pacer thread has asked the worker for. At most
      # one is ever outstanding, so this grows with the number of windows
      # that ended and not with the number of turns of the pacer's loop.
      def flush_requests ; @mrai_lock.synchronize { @flush_requests } ; end

      # What is waiting for its window to end, as [peer, prefix].
      def waiting
        @mrai_lock.synchronize { @mrai.pending_keys }
      end

      # Watches one adapter's session, so the peer gets the table when it
      # comes up and loses its Adj-RIB-Out when it goes down. Called by start
      # and by PeerFeed#attach for anything attached after.
      def watch(adapter)
        return if @lock.synchronize { @watched ||= {} ; w = @watched[adapter] ; @watched[adapter] = true ; w }
        adapter.neighbor.on_state_change do |now, was|
          if now == :Established
            @feed << [:session_up, adapter]
          elsif was == :Established
            @feed << [:session_down, adapter]
          end
        end
        # Already up when router mode started: it will get nothing otherwise,
        # since the state change has been and gone.
        @feed << [:session_up, adapter] if adapter.neighbor.is_established?
      end

      # The Adj-RIB-Out for peer, created on first use.
      def adj_rib_out(peer)
        @lock.synchronize { @out[peer] ||= AdjRibOut.new(peer) }
      end

      def peers ; @lock.synchronize { @out.keys } ; end

      # How many UPDATEs this has sent.
      def sent ; @lock.synchronize { @sent } ; end

      # The routes this could not advertise, as [prefix, peer, reason], with
      # the last reason per prefix and peer. A route silently not advertised
      # is the hardest kind of bug to see from outside, and the initial
      # advertisement can look at a prefix the same moment a change to it
      # does, so this is keyed rather than a log: the same refusal twice is
      # one entry.
      def skipped
        @lock.synchronize { @skipped.map { |(prefix, peer), reason| [prefix, peer, reason] } }
      end

      # Forgets the skipped routes, for a long running speaker.
      def clear_skipped ; @lock.synchronize { @skipped.clear } ; self ; end

      # The whole Loc-RIB to one peer. Called when a session comes up.
      def session_up(adapter)
        changes = @table.synchronize do
          @table.loc_rib.prefixes.map { |p| LocRib::Change.new(p, nil, @table.best(p), :session_up) }
        end
        run_changes(changes, :only => adapter)
      end

      # The peer keeps nothing across a session, so neither do we. That
      # includes its intervals: a window armed by the old session must not
      # delay the first UPDATE of the new one, and an item waiting for one
      # is about a session that is gone.
      def session_down(adapter)
        peer = adapter.peer
        return unless peer
        @lock.synchronize { @out[peer] }&.flush
        @mrai_lock.synchronize { @mrai.forget(peer) }
      end

      # Sends what the interval of RFC 4271 section 9.2.1.1 was holding and
      # whose window has now ended. Called on the feed's worker thread,
      # which the pacer thread asks to do it.
      def flush_mrai
        due = @mrai_lock.synchronize do
          # The flush the pacer asked for is being done now, so it may ask
          # again. Signalling lets it work out its next deadline from what
          # is left rather than from what was there when it asked.
          @flush_pending = false
          @wake.signal
          @mrai.due
        end
        return if due.empty?
        by_peer = {}
        due.each { |(peer, _prefix, item)| (by_peer[peer] ||= []) << item }
        by_peer.each do |peer, items|
          adapter = @feed.adapters.find { |a| a.peer == peer }
          # The session went away while these waited. Its Adj-RIB-Out has
          # been flushed already, so dropping them is right.
          next unless adapter && adapter.neighbor.is_established?
          announce, withdraw = commit(adj_rib_out(peer), peer, items)
          next if announce.empty? && withdraw.empty?
          send_messages(adapter, announce, withdraw)
        end
      end

      # Runs the export side for these Loc-RIB changes. only: one adapter,
      # for the initial advertisement; otherwise every attached peer.
      def run_changes(changes, only: nil)
        adapters = only ? [only] : @feed.adapters
        adapters.each do |adapter|
          peer = adapter.peer
          next unless peer                       # no OPEN yet, so no peer
          next unless adapter.neighbor.is_established?
          announce, withdraw = plan(changes, adapter, peer)
          next if announce.empty? && withdraw.empty?
          send_messages(adapter, announce, withdraw)
        end
      end

      private

      # What to send this peer for these changes, as the builder's tuples.
      # The Adj-RIB-Out is what makes this a diff rather than a broadcast:
      # :same means the peer already has it and nothing is sent.
      # No Path Identifier is ever sent, whatever the route carried.
      #
      # A Path Identifier is the sender's to allocate (RFC 7911 section 3),
      # not the receiver's to pass on, and it may only be sent on a session
      # that negotiated add-path in that direction. This advertises the one
      # best route per prefix, so there is nothing for an Identifier to tell
      # apart. Forwarding the one a route arrived with would put an octet
      # the peer is not expecting in front of every prefix, which is a
      # corrupt UPDATE rather than a wrong route. Sending several paths per
      # prefix is its own piece of work, and it starts at the Loc-RIB, which
      # keeps one best route.
      def plan(changes, adapter, peer)
        out = adj_rib_out(peer)
        ready = []
        changes.each do |change|
          item = item_for(change, adapter, peer, out)
          # Nothing to send for this destination, so nothing may be left
          # waiting for it either. See Mrai#drop.
          next drop(peer, change.prefix) if item.nil?
          next ready << item unless hold?(peer, change.prefix)
          hold(peer, change.prefix, item)
        end
        commit(out, peer, ready)
      end

      # What this peer should be sent for one Loc-RIB change, as one of the
      # builder's tuples, or nil when the answer is nothing. It reads the
      # Adj-RIB-Out and does not write it, because the write records what
      # went out and this may still be held.
      def item_for(change, adapter, peer, out)
        route = change.new
        result = route ? export_for(route, peer, adapter) : nil
        if result.nil? || !result.advertise?
          # Either the prefix lost its best route, or export refused it.
          # Both mean the peer must not keep what it has, and for the
          # refusal that is a MUST: RFC 4271 section 9.1.3, "If a route in
          # Loc-RIB is excluded from a particular Adj-RIB-Out, the
          # previously advertised route in that Adj-RIB-Out MUST be
          # withdrawn from service by means of an UPDATE message".
          note_skip(change.prefix, peer, result && result.reason)
          return nil unless out[change.prefix]
          return UpdateBuilder::Withdraw.new(change.prefix)
        end
        # RFC 4271 section 9.2: "A BGP speaker SHOULD NOT advertise a given
        # feasible BGP route from its Adj-RIB-Out if it would produce an
        # UPDATE message containing the same BGP route as was previously
        # advertised."
        return nil if out.current?(change.prefix, result.path_attribute)
        UpdateBuilder::Announce.new(change.prefix, result.path_attribute, result.next_hop)
      end

      # Records these items as sent and splits them for the builder. This is
      # the one place the Adj-RIB-Out is written and the one place a
      # destination's interval is armed, so an item takes the same path
      # whether it went out at once or waited for its window.
      def commit(out, peer, items)
        announce = []
        withdraw = []
        items.each do |item|
          case item
          when UpdateBuilder::Withdraw
            out.withdraw(item.prefix)
            withdraw << item
          else
            out.advertise(item.prefix, item.path_attribute)
            announce << item
          end
          arm(peer, item.prefix)
        end
        [announce, withdraw]
      end

      # Export refuses to guess our address on a session, so a family with
      # no next hop of ours is skipped here rather than raising out of the
      # worker thread.
      def export_for(route, peer, adapter)
        hop = next_hop_for(route, adapter)
        # A route we originated needs one whichever kind of peer it goes to
        # (RFC 4271 section 5.1.3), so the family check covers it too.
        if hop.nil? && (peer.ebgp? || route.local?)
          return Export::Result.new(nil, nil, :no_next_hop_for_family)
        end
        @export.for(route, peer, :next_hop => hop)
      end

      # RFC 4271 section 5.1.3 wants our address on the session for an
      # external peer, which is the session's local address. A family that
      # does not travel in NEXT_HOP needs one configured, since the session
      # address is the wrong family.
      def next_hop_for(route, adapter)
        afi = route.ipv4? ? IANA::AFI::IPv4 : IANA::AFI::IPv6
        return @next_hops[afi] if @next_hops.key?(afi)
        return adapter.neighbor.local_addr if afi == IANA::AFI::IPv4
        nil
      end

      def send_messages(adapter, announce, withdraw)
        builder = UpdateBuilder.new(:session_info => adapter.neighbor.session_info)
        msgs = builder.build(:announce => announce, :withdraw => withdraw)
        msgs.each { |m| adapter.neighbor.send_update(m) }
        @lock.synchronize { @sent += msgs.size }
      rescue StandardError => e
        # A session that went away between the check and the send, or a
        # message that cannot be built. Neither is worth losing the worker
        # thread, which serves every other peer.
        Log.error "#{self.class}: #{e.class}: #{e.message}"
        @lock.synchronize { @skipped[[nil, adapter.peer]] = e.class.name.to_sym }
      end

      def note_skip(prefix, peer, reason)
        return unless reason
        @lock.synchronize { @skipped[[prefix, peer]] = reason }
      end

      # The Mrai calls, each under its own lock. Short on purpose: the
      # pacer thread reads the same object.
      def hold?(peer, prefix) ; @mrai_lock.synchronize { @mrai.hold?(peer, prefix) } ; end

      def hold(peer, prefix, item)
        @mrai_lock.synchronize do
          @held += 1 if @mrai.hold(peer, prefix, item)
          @wake.signal
        end
      end

      # Arms this destination's window, and forgets anything that was
      # waiting for it, since this is what that item was waiting to be.
      def arm(peer, prefix)
        @mrai_lock.synchronize { @mrai.drop(peer, prefix) ; @mrai.sent(peer, prefix) }
      end

      def drop(peer, prefix) ; @mrai_lock.synchronize { @mrai.drop(peer, prefix) } ; end

      # Called holding @lock.
      def start_pacer
        return if @pacer
        @pacer = Thread.new { pace }
        @pacer['name'] = 'BGP RIB MRAI'
        @pacer
      end

      # Sleeps until the earliest window with something waiting for it
      # ends, then asks the feed to flush. It does not send anything
      # itself: the UPDATEs are built and written on the feed's worker
      # thread, like every other UPDATE, so there is still only one thread
      # talking to the sessions.
      # At most one flush is in flight at a time. Without that this spins:
      # the work is done by the worker thread, so from the moment a window
      # ends until the moment the worker gets to it, the deadline is still
      # in the past and every turn of this loop would queue another flush.
      # That is a hot loop and a queue filling faster than the worker can
      # empty it, which starves every other work item behind it.
      def pace
        loop do
          due = @mrai_lock.synchronize do
            next false if @stopping
            delay = @mrai.next_deadline
            if delay && delay <= 0 && !@flush_pending
              @flush_requests += 1
              next (@flush_pending = true)
            end
            # Nothing is due, or a flush is already on its way. A deadline
            # in the future is how long to sleep; nil means nothing is
            # waiting at all, so sleep until a hold or a flush signals.
            @wake.wait(@mrai_lock, delay && delay > 0 ? delay : nil)
            false
          end
          break if @mrai_lock.synchronize { @stopping }
          # Only a real deadline reaches the feed. A hold wakes this thread
          # so it can shorten its sleep, not so it can flush: without that
          # every held change would cost a round trip through the worker to
          # find nothing due.
          @feed << [:mrai] if due
        end
      end
    end

  end
end
