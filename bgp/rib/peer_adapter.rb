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

    # Turns what one BGP::Neighbor receives into table operations.
    #
    # The adapter is a translator and nothing else: it holds no table and
    # touches no RIB. operations takes an Update and returns what to do with
    # it, so the whole translation can be tested without a session, a table
    # or a thread. PeerFeed is what applies the result.
    #
    #   adapter = PeerAdapter.new(neighbor, feed)
    #   adapter.operations(update)
    #   # => [[:withdraw, peer, '10.0.0.0/8', nil],
    #   #     [:announce, #<Route 192.168.1.0/24 ...>]]
    #
    # Four fields carry reachability and all four are read: the NLRI and
    # Withdrawn Routes fields of RFC 4271 section 4.3, which are IPv4
    # unicast, and the MP_REACH_NLRI and MP_UNREACH_NLRI attributes of RFC
    # 4760 sections 3 and 4, which name their own address family.
    #
    # Of the families bgp4r can parse, two go in a table: see MP_SAFIS.
    # An UPDATE carrying one of the others yields no operations and is
    # reported by unreachable?, so the gap says so rather than looking like
    # an UPDATE that carried nothing.
    class PeerAdapter

      # The SAFIs read out of MP_REACH_NLRI and MP_UNREACH_NLRI: the ones
      # whose NLRI is a bare prefix, IANA SAFI 1 unicast and 2 multicast.
      #
      # The other three bgp4r parses are left out because the prefix is not
      # the whole key. SAFI 4 carries a label with it (RFC 8277 section 2),
      # and SAFI 128 and 129 a Route Distinguisher (RFC 4364 section 4.2),
      # so two routes that differ only in their label or RD would collide:
      # BGP::Rib::Route keys on the prefix and the add-path Path Identifier
      # and has nowhere to put either. Carrying them needs a Route that
      # does, which is a change to the decision process and to every show
      # command, not a change here.
      MP_SAFIS = [IANA::SAFI::UNICAST, IANA::SAFI::MULTICAST].freeze

      attr_reader :neighbor, :sink

      # neighbor: a BGP::Neighbor.
      # sink: anything answering << with one work item, normally a PeerFeed.
      def initialize(neighbor, sink)
        @neighbor = neighbor
        @sink = sink
        @peer = nil
        @lock = Mutex.new
        neighbor.add_observer(self)
        neighbor.on_state_change { |now, was| state_change(now, was) }
      end

      # The observer callback BGP::Neighbor calls for every message it
      # receives. Anything that is not an UPDATE is ignored here: the peer's
      # OPEN is read through the neighbor's own readers instead, because
      # notify_observers is not the only path an OPEN takes.
      #
      # This runs on the neighbor's event dispatch thread, which also runs
      # the session, so it does the least it can: translate, hand the result
      # to the sink, return. The decision process runs on the sink's thread.
      def update(msg)
        return unless msg.is_a?(BGP::Update)
        ops = operations(msg)
        @sink << [:ops, ops] unless ops.empty?
      end

      # The Peer this session learned from its peer's OPEN, or nil before one
      # arrived. Built once per session and dropped when the session goes
      # down, since the peer may come back with another BGP Identifier.
      def peer
        @lock.synchronize { @peer ||= build_peer }
      end

      # What one UPDATE asks the table to do, in the order to apply it.
      #
      # Withdrawals come before announcements. Nothing in RFC 4271 that I
      # could check says a receiver must take them in that order, so this is
      # bgp4r's choice, and it is the safe one: a prefix in both fields ends
      # up announced rather than withdrawn, which matches what the sender of
      # such an UPDATE can only have meant. Two announcements of one prefix
      # need no ordering rule, because the second implicitly withdraws the
      # first (RFC 4271 section 3.1) and AdjRibIn#announce already does that.
      # Both withdrawal fields come before both announcement fields, for the
      # reason above. An UPDATE may carry the section 4.3 fields and the MP
      # attributes at once, and they are different address families, so the
      # order between the two withdrawal fields cannot matter.
      def operations(update, peer = self.peer)
        return [] unless peer
        ops = []
        each_prefix(update.withdrawn) do |prefix, path_id|
          ops << [:withdraw, peer, prefix, path_id]
        end
        each_mp_prefix(update, BGP::Mp_unreach) do |prefix, path_id|
          ops << [:withdraw, peer, prefix, path_id]
        end
        each_prefix(update.nlri) do |prefix, path_id|
          ops << announce(prefix, path_id, update, peer)
        end
        each_mp_prefix(update, BGP::Mp_reach) do |prefix, path_id|
          ops << announce(prefix, path_id, update, peer)
        end
        ops
      end

      # True when this UPDATE carries reachability in an address family that
      # does not go in a table, which means an MP_REACH_NLRI or
      # MP_UNREACH_NLRI whose SAFI is not in MP_SAFIS. operations returns
      # nothing for it; this is how a caller can tell that apart from an
      # UPDATE that genuinely carried nothing, such as the End-of-RIB marker
      # of RFC 4724 section 2.
      def unreachable?(update)
        [BGP::Mp_reach, BGP::Mp_unreach].any? do |klass|
          mp = mp_attribute(update, klass)
          mp and !MP_SAFIS.include?(mp.safi)
        end
      end

      # The AFI and SAFI pairs this UPDATE carried that are not read, as
      # [afi, safi], for a caller that wants to log what it is missing.
      def unread_families(update)
        [BGP::Mp_reach, BGP::Mp_unreach].filter_map do |klass|
          mp = mp_attribute(update, klass)
          [mp.afi, mp.safi] if mp and !MP_SAFIS.include?(mp.safi)
        end.uniq
      end

      # RFC 4271 section 9.1.2: the routes a peer sent are no longer
      # available once the session is not Established. Asks the sink to
      # remove them and forgets the Peer, so the next session builds a new
      # one from the next OPEN.
      def state_change(now, was)
        return if now == was
        return unless was == :Established
        gone = @lock.synchronize do
          p = @peer
          @peer = nil
          p
        end
        @sink << [:peer_down, gone] if gone
      end

      # Stops feeding: the neighbor no longer reports to this adapter.
      def detach
        @neighbor.delete_observer(self)
        self
      end

      def to_s ; "feed from #{@peer || @neighbor.remote_addr}" ; end

      private

      # The peer's OPEN names it (RFC 4271 section 4.2). Before one arrives
      # there is no remote AS and no BGP Identifier, so there is no Peer to
      # build: an UPDATE cannot precede the OPEN on a real session, and on a
      # hand fed one the caller gets nothing rather than a made up peer.
      def build_peer
        as, id = @neighbor.rmt_as, @neighbor.rmt_bgp_id
        return nil unless as and id
        Peer.new(:address => @neighbor.remote_addr, :remote_as => as,
                 :router_id => id, :local_as => @neighbor.my_as)
      end

      def present?(field)
        field && !field.nlris.nil? && !field.nlris.empty?
      end

      # Yields each prefix of an Nlri or Withdrawn field as a String and its
      # add-path Path Identifier (RFC 7911 section 3), which is nil unless
      # the session negotiated add-path and the field carried one.
      def each_prefix(field)
        return unless present?(field)
        field.nlris.each { |p| yield p.to_hash[:prefix], p.path_id }
      end

      def announce(prefix, path_id, update, peer)
        [:announce, Route.new(prefix, update.path_attribute, peer, :path_id => path_id)]
      end

      # The MP_REACH_NLRI or MP_UNREACH_NLRI attribute of this UPDATE, or nil.
      def mp_attribute(update, klass)
        pa = update.path_attribute
        return nil unless pa and pa.has?(klass)
        pa[klass]
      end

      # Yields each prefix of one MP attribute, when its SAFI is one that
      # goes in a table. The Path Identifier is in the hash rather than on
      # the object for a prefix built from a hash, so read it from there,
      # the way each_prefix reads the prefix itself.
      def each_mp_prefix(update, klass)
        mp = mp_attribute(update, klass)
        return unless mp and MP_SAFIS.include?(mp.safi)
        nlris = mp.nlris
        return unless nlris
        Array(nlris).each do |p|
          h = p.to_hash
          yield h[:prefix], h[:path_id]
        end
      end
    end

  end
end
