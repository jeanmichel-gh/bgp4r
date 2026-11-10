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

require 'bgp4r'
require 'bgp/rib/peer_adapter'

module BGP
  module Daemon

    # The BGP-LS routes a speaker received, per peer, outside the RIB.
    #
    # docs/design/bgp-ls-producer.md, option A. Keyed by peer and by the
    # NLRI's octets. The value is the decoded NLRI, its BGP-LS Attribute
    # and the time it came. There is no decision process and nothing is
    # sent on. RFC 9552 section 3 calls the reader of this table a
    # Consumer: "The communication of information MUST be unidirectional
    # (i.e., from a BGP Speaker to the BGP-LS Consumer application)".
    # `show.link_state` only reads it.
    #
    # It takes what a session sends only when that session negotiated
    # AFI 16388 / SAFI 71, both ways. `PeerAdapter.link_state_operations`
    # does the reading of the UPDATE.
    #
    # `LinkStateTable.row` is also how the Producer shows what it sent,
    # so the two sides of a session answer the same row for one route.
    class LinkStateTable

      Entry = Struct.new(:nlri, :attribute, :since)

      # The `type` of a row, and the order rows sort in.
      TYPES = %w[node link prefix].freeze

      def initialize
        @lock = Mutex.new
        @routes = {} # peer address => { NLRI octets => Entry }
      end

      # True when both OPENs of a session carried the Multiprotocol
      # capability for AFI 16388 / SAFI 71 (RFC 4760 section 8).
      def self.negotiated?(session_info)
        return false unless session_info
        [session_info.speaker, session_info.peer].all? { |open| bgp_ls?(open) }
      end

      def self.bgp_ls?(open)
        return false unless open
        Array(open.opt_parms).flat_map { |p|
          p.respond_to?(:capabilities) ? Array(p.capabilities) : [p]
        }.any? { |c|
          c.is_a?(BGP::OPT_PARM::CAP::Mbgp) && [c.afi, c.safi] == BGP::Rib::PeerAdapter::LINK_STATE
        }
      end
      private_class_method :bgp_ls?

      # One route as a `show.link_state` row. peer is the address it came
      # from, or nil for a route this speaker sent.
      def self.row(ls, attr, peer, since)
        n = ls.nlri
        { 'peer'        => peer,
          'type'        => type(n),
          'protocol_id' => n.respond_to?(:protocol_id) ? n.protocol_id : nil,
          'identifier'  => n.respond_to?(:identifier) ? n.identifier : nil,
          'local'       => n.respond_to?(:local_node_descriptors) ? node_id(n.local_node_descriptors) : nil,
          'remote'      => n.respond_to?(:remote_node_descriptors) ? node_id(n.remote_node_descriptors) : nil,
          'prefix'      => n.respond_to?(:prefix) ? n.prefix : nil,
          'name'        => (t = tlv(attr, 1026)) && t.name,
          'flags'       => flags(tlv(attr, 1024)),
          'areas'       => attr ? attr.tlvs.select { |t| t.type == 1027 }.collect { |t| area(t.value) } : [],
          'metric'      => metric(n, attr),
          'since'       => Recorder.iso(since) }
      end

      # `node`, `link` or `prefix`, the three NLRI types of RFC 9552
      # section 5.2 a Producer here sends, and `unknown` for a type the
      # library keeps whole without reading (`Link_state::Unknown`).
      def self.type(n)
        case n
        when BGP::Link_state::Node        then 'node'
        when BGP::Link_state::Link        then 'link'
        when BGP::Link_state::Prefix_nlri then 'prefix'
        else 'unknown'
        end
      end

      # A node as isisd names it, from the IGP Router-ID sub-TLV (RFC
      # 9552 section 5.2.1.4): an IS-IS system ID of 6 octets prints with
      # `.00` after it, and the 7-octet pseudonode form with its PSN
      # octet, so `0000.0001.0101.00` reads the same on both sides. A
      # 4-octet OSPF Router-ID prints as an address, and anything else as
      # hex.
      def self.node_id(descriptors)
        return nil unless descriptors
        rid = descriptors.sub_tlvs.find { |t| t.is_a?(BGP::Link_state::Tlv::Igp_router_id) }
        return nil unless rid
        v = rid.value
        case v.size
        when 6, 7
          h = v.unpack1('H*')
          "#{h[0, 4]}.#{h[4, 4]}.#{h[8, 4]}.#{v.size == 7 ? h[12, 2] : '00'}"
        when 4 then v.unpack('C4').join('.')
        else v.unpack1('H*')
        end
      end

      # The `areas` text isisd uses, `49.0001`: the first octet, then two
      # octets per group. RFC 9552 section 5.3.1.2 gives the value as
      # octets and nothing else; this is the lab's spelling.
      def self.area(octets)
        h = octets.unpack1('H*')
        return h if h.size <= 2
        ([h[0, 2]] + h[2..].scan(/.{1,4}/)).join('.')
      end

      # The other way: `49.0001` to its octets.
      def self.area_octets(text)
        [text.to_s.delete('.')].pack('H*')
      end

      def self.tlv(attr, type)
        attr && attr.tlv(type)
      end

      def self.flags(t)
        return [] unless t
        BGP::Link_state::Tlv::Node_flag_bits::BITS.keys.select { |k| t.set?(k) }.collect(&:to_s)
      end

      # IGP Metric (1095) on a link, Prefix Metric (1155) on a prefix.
      def self.metric(n, attr)
        case type(n)
        when 'link'   then (t = tlv(attr, 1095)) && t.metric
        when 'prefix' then (t = tlv(attr, 1155)) && t.value
        end
      end

      # Sorts rows by peer, type, then node, so two tables holding the
      # same routes answer the same list.
      def self.sort(rows)
        rows.sort_by do |r|
          [r['peer'].to_s, TYPES.index(r['type']) || TYPES.size, r['protocol_id'].to_i,
           r['identifier'].to_i, r['local'].to_s, r['remote'].to_s, r['prefix'].to_s]
        end
      end

      # Starts reading what neighbor receives. One Neighbor per session,
      # so one call per session. A session leaving Established removes
      # every route it sent: RFC 4271 section 6 clears the Adj-RIB-In of
      # a closed connection, and a BGP-LS table is one.
      def attach(neighbor)
        feed = Feed.new(self, neighbor)
        neighbor.add_observer(feed)
        neighbor.on_state_change do |now, was|
          peer_down(neighbor.remote_addr) if was == :Established && now != was
        end
        feed
      end

      def detach(neighbor, feed)
        neighbor.delete_observer(feed)
        self
      end

      # ops is what `PeerAdapter.link_state_operations` answers.
      def apply(peer, ops, at = Time.now)
        @lock.synchronize do
          ops.each do |op, ls, attr|
            case op
            when :withdraw then delete(peer, ls)
            when :announce then (@routes[peer] ||= {})[ls.encode] = Entry.new(ls, attr, at)
            end
          end
        end
        self
      end

      def announce(peer, ls, attr, at = Time.now) ; apply(peer, [[:announce, ls, attr]], at) ; end
      def withdraw(peer, ls) ; apply(peer, [[:withdraw, ls]]) ; end

      def peer_down(peer)
        @lock.synchronize { @routes.delete(peer) }
        self
      end

      def size(peer = nil)
        @lock.synchronize do
          peer ? (@routes[peer] || {}).size : @routes.values.sum(&:size)
        end
      end

      # The Entry for one route, or nil.
      def [](peer, ls)
        @lock.synchronize { (@routes[peer] || {})[ls.encode] }
      end

      def rows
        list = @lock.synchronize do
          @routes.flat_map { |peer, h| h.values.collect { |e| [peer, e] } }
        end
        LinkStateTable.sort(list.collect { |peer, e| LinkStateTable.row(e.nlri, e.attribute, peer, e.since) })
      end

      private

      def delete(peer, ls)
        h = @routes[peer]
        return unless h
        h.delete(ls.encode)
        @routes.delete(peer) if h.empty?
      end

      # The observer on one session. It runs on the session's dispatch
      # thread, as PeerAdapter does, so it does the least it can.
      class Feed
        def initialize(table, neighbor)
          @table, @neighbor = table, neighbor
        end

        def update(msg)
          return unless msg.is_a?(BGP::Update)
          return unless LinkStateTable.negotiated?(@neighbor.session_info)
          ops = BGP::Rib::PeerAdapter.link_state_operations(msg)
          @table.apply(@neighbor.remote_addr, ops) unless ops.empty?
        end
      end
    end

  end
end
