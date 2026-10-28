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
    # Three things set it going. A session reaching Established gets the
    # whole Loc-RIB, which is the RFC 4271 section 9.2 initial advertisement
    # in the only form bgp4r has: everything we have, once. A Loc-RIB change
    # goes to every peer. A session leaving Established empties its
    # Adj-RIB-Out, because the peer keeps nothing across a session.
    #
    # Everything happens on the feed's one worker thread, never on the
    # table's lock and never on a neighbour's event dispatch thread: the
    # on_change listener only queues the change. A send that blocked inside
    # the listener would hold the table lock, and a send on the event thread
    # would stall the session that thread runs.
    #
    # Not here, and each is its own piece of work: the MinRouteAdvertisement
    # interval of RFC 4271 section 9.2.1.1, so a change goes out as soon as
    # it is decided; the route reflector client and non-client matrix of RFC
    # 4456 section 6, which needs per-peer configuration; and routes we
    # originate ourselves, since every Route is learned from a peer.
    class Router

      attr_reader :table, :export

      # table, feed: the Table and its PeerFeed.
      # export: an Export, or nil to build one from the table's own local AS
      #   and router ID.
      # next_hops: our address per address family, as { afi => address }, for
      #   a family whose next hop is not the session's own address. An IPv6
      #   route over an IPv4 session needs an IPv6 next hop (RFC 4760 section
      #   3), and nothing on the session says what ours is, so without one
      #   those routes are not advertised and skipped is why.
      def initialize(table, feed, export: nil, next_hops: {})
        @table = table
        @feed = feed
        @export = export || Export.new(:local_as => table.local_as, :router_id => table.router_id)
        @next_hops = {}
        next_hops.each { |afi, address| @next_hops[Integer(afi)] = address.to_s }
        @out = {}        # Peer => AdjRibOut
        @lock = Mutex.new
        @skipped = {}   # [prefix, peer] => the last reason it was not advertised
        @sent = 0
      end

      # Starts advertising to every peer the table is attached to, and to any
      # attached later. Idempotent.
      def start
        return self if @lock.synchronize { s = @started ; @started = true ; s }
        @table.on_change { |change| @feed << [:advertise, [change]] }
        @feed.adapters.each { |adapter| watch(adapter) }
        self
      end

      def started? ; @lock.synchronize { !!@started } ; end

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

      # The peer keeps nothing across a session, so neither do we.
      def session_down(adapter)
        peer = adapter.peer
        return unless peer
        @lock.synchronize { @out[peer] }&.flush
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
        announce = []
        withdraw = []
        changes.each do |change|
          route = change.new
          result = route ? export_for(route, peer, adapter) : nil
          if result.nil? || !result.advertise?
            # Either the prefix lost its best route, or export refused it.
            # Both mean the peer must not keep what it has.
            note_skip(change.prefix, peer, result && result.reason)
            withdraw << UpdateBuilder::Withdraw.new(change.prefix) if out.withdraw(change.prefix)
            next
          end
          next if out.advertise(change.prefix, result.path_attribute) == :same
          announce << UpdateBuilder::Announce.new(change.prefix, result.path_attribute,
                                                 result.next_hop)
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
    end

  end
end
