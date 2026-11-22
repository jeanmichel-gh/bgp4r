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
      #
      # The SR keys of RFC 9085 and RFC 9086 (`sr_keys`) are in a row only
      # when its attribute carries those TLVs, as isisd's `show.topology`
      # gives them only when the LSPs do.
      def self.row(ls, attr, peer, since)
        n = ls.nlri
        base_row(n, attr, peer, since).merge(sr_keys(n, attr))
      end

      def self.base_row(n, attr, peer, since)
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
          'area'        => ospf_area(n),
          'route_type'  => route_type(n),
          'forwarding'  => (t = tlv(attr, 1156)) ? t.address.to_s : nil,
          'since'       => Recorder.iso(since) }
      end

      private_class_method :base_row

      # RFC 8667's flag letters, the first the most significant bit, as
      # its figures draw them: SR-Capabilities `|I|V|` (section 3.1),
      # Adj-SID and LAN-Adj-SID `|F|B|V|L|S|P|` (2.2.1, 2.2.2), Prefix-SID
      # `|R|N|P|E|V|L|` (2.1). RFC 9085 says the NLRI's Protocol-ID decides
      # how to read the flags (sections 2.2.1 and 2.3.1), so the letters
      # are for IS-IS only. RFC 9086's Peering SIDs have their own,
      # `|V|L|B|P|` (section 5, Figure 3).
      SR_CAPABILITY_FLAGS = %w[I V].freeze
      ADJ_SID_FLAGS       = %w[F B V L S P].freeze
      PREFIX_SID_FLAGS    = %w[R N P E V L].freeze
      PEER_SID_FLAGS      = %w[V L B P].freeze

      # RFC 9552 section 5.2, Table 2: IS-IS Level 1 and Level 2.
      ISIS = [1, 2].freeze

      # The octet from letters, and the bits no letter names. An unknown
      # letter is an ArgumentError naming the ones there are.
      def self.flag_octet(letters, names, reserved = 0)
        Array(letters).sum(0) do |l|
          i = names.index(l.to_s.upcase) or
            raise ArgumentError, "no #{l.inspect} flag in #{names.join}"
          0x80 >> i
        end | (Integer(reserved) & 0xff)
      end

      # The letters set in octet, in the RFC's order.
      def self.flag_letters(octet, names)
        names.each_with_index.select { |_, i| octet & (0x80 >> i) != 0 }.collect(&:first)
      end

      # The bits of octet no letter names.
      def self.unnamed_bits(octet, names)
        octet & ~names.each_index.sum { |i| 0x80 >> i } & 0xff
      end

      # The SR keys of one row, by isisd's spelling (isis docs/isisd.md,
      # `show.topology`), so a collector's row and isisd's node read the
      # same:
      #
      # * `sr` on a node: `srgb` from SR Capabilities (1034), `flags`, its
      #   letters, `srlb` from SR Local Block (1036), `algorithms` from SR
      #   Algorithm (1035). Each key only when its TLV is there.
      # * `adj_sids` and `lan_adj_sids` on a link, from 1099 and 1100.
      # * `prefix_sid` on a prefix, from the first 1158.
      # * `peer_sids` on a link, from RFC 9086's 1101 to 1103, each with a
      #   `type`: `node`, `adj` or `set`.
      #
      # A SID is `{flags, weight, label | index}` as isisd's hash is:
      # `flags` the letters set, omitted when none, and `reserved` the
      # bits no letter names, when any; `weight` when not 0; `label` the
      # 20 bits, with `label_high` the 4 above them when not 0. Off IS-IS
      # the flags are the octet as a number.
      def self.sr_keys(n, attr)
        return {} unless attr
        pid = n.respond_to?(:protocol_id) ? n.protocol_id : nil
        isis = ISIS.include?(pid)
        out = {}
        case type(n)
        when 'node'
          sr = sr_view(attr, isis)
          out['sr'] = sr if sr
        when 'link'
          adj = attr.tlvs.grep(BGP::Link_state::Tlv::Adjacency_sid)
          lan = attr.tlvs.grep(BGP::Link_state::Tlv::Lan_adjacency_sid)
          peer = attr.tlvs.grep(BGP::Link_state::Tlv::Peer_sid)
          out['adj_sids'] = adj.collect { |t| sid_view(t, isis ? ADJ_SID_FLAGS : nil) } unless adj.empty?
          out['lan_adj_sids'] = lan.collect { |t| { 'neighbor' => t.neighbor }.merge(sid_view(t, isis ? ADJ_SID_FLAGS : nil)) } unless lan.empty?
          out['peer_sids'] = peer.collect { |t| { 'type' => PEER_TYPES[t.type] }.merge(sid_view(t, PEER_SID_FLAGS)) } unless peer.empty?
        when 'prefix'
          t = attr.tlvs.grep(BGP::Link_state::Tlv::Prefix_sid).first
          if t
            v = sid_view(t, isis ? PREFIX_SID_FLAGS : nil)
            out['prefix_sid'] = v.merge('algorithm' => t.algorithm)
          end
        end
        out
      end

      # RFC 9086 section 5's three, by GoBGP's client words.
      PEER_TYPES = { 1101 => 'node', 1102 => 'adj', 1103 => 'set' }.freeze

      def self.sr_view(attr, isis)
        cap  = attr.tlvs.grep(BGP::Link_state::Tlv::Sr_capabilities).first
        srlb = attr.tlvs.grep(BGP::Link_state::Tlv::Sr_local_block).first
        algo = attr.tlvs.grep(BGP::Link_state::Tlv::Sr_algorithm).first
        return nil unless cap || srlb || algo
        h = {}
        if cap
          h['srgb'] = blocks(cap)
          h['flags'] = isis ? flag_letters(cap.flags, SR_CAPABILITY_FLAGS) : cap.flags
        end
        h['srlb'] = blocks(srlb) if srlb
        h['algorithms'] = algo.values if algo
        h
      end

      # A range TLV's ranges as [{start, size}], in the order sent. start
      # is the first label, or the index when the sub-TLV is one, which
      # RFC 9085 section 2.1.2 does not allow and a consumer may meet.
      def self.blocks(t)
        t.ranges.collect do |size, sub|
          first = sub.respond_to?(:label?) ? (sub.label? ? sub.label : sub.index) : nil
          { 'start' => first, 'size' => size }
        end
      end

      def self.sid_view(t, names)
        h = {}
        if names
          letters = flag_letters(t.flags, names)
          h['flags'] = letters unless letters.empty?
          rest = unnamed_bits(t.flags, names)
          h['reserved'] = rest unless rest.zero?
        else
          h['flags'] = t.flags
        end
        h['weight'] = t.weight if t.respond_to?(:weight) && !t.weight.zero?
        if t.label?
          h['label'] = t.label
          h['label_high'] = t.label_high_bits unless t.label_high_bits.zero?
        else
          h['index'] = t.index
        end
        h
      end
      private_class_method :sr_view, :blocks, :sid_view

      # Section 5.2.3.1's six names, in ospfd's spelling.
      ROUTE_TYPES = { 1 => 'intra', 2 => 'inter', 3 => 'external_1', 4 => 'external_2',
                      5 => 'nssa_1', 6 => 'nssa_2' }.freeze

      # The OSPF Area-ID (514) of the local node, as a dotted quad, or
      # nil: IS-IS has none, and an AS-scope OSPF object carries none.
      def self.ospf_area(n)
        d = n.respond_to?(:local_node_descriptors) && n.local_node_descriptors
        t = d && d.sub_tlvs.find { |x| x.is_a?(BGP::Link_state::Tlv::Ospf_area_id) }
        t && t.area
      end

      # The OSPF Route Type (264) of a prefix, by name; a value section
      # 5.2.3.1 does not name stays a number.
      def self.route_type(n)
        t = n.respond_to?(:tlv) && n.tlv(264)
        t && ROUTE_TYPES.fetch(t.route_type, t.route_type)
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
      # 4-octet OSPF Router-ID prints as an address, an 8-octet OSPF
      # pseudonode as `DR:address` the way ospfd names it, and anything
      # else as hex.
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
        when 8 then "#{v[0, 4].unpack('C4').join('.')}:#{v[4, 4].unpack('C4').join('.')}"
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
           r['identifier'].to_i, r['area'].to_s, r['local'].to_s, r['remote'].to_s, r['prefix'].to_s,
           r['route_type'].to_s]
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
