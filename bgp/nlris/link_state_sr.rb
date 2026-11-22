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

require 'bgp/nlris/link_state'

module BGP

  # The Segment Routing TLVs of the BGP-LS Attribute: RFC 9085's node,
  # link and prefix TLVs, and RFC 9086's three BGP Peering SIDs. RFC
  # 9086's two node descriptors, 516 and 517, are in
  # `link_state_descriptor.rb` with the other node descriptors.
  #
  # `docs/bgp-ls.md` section 13 is the guide. Each section number here
  # was read in the RFC text on 2026-11-22.
  #
  # **Nothing validates.** Any flags, any Reserved, a label where an
  # index is expected and the other way round. RFC 9085 section 4 and
  # RFC 9086 section 7 leave "the semantic or content checking" of these
  # TLVs to the consumer, as RFC 9552 section 8.2.2 does. What a reader
  # checks is in `validation.rb`.
  #
  # **A value of a width the class cannot read is not one of these.**
  # The class raises in `parse`, and `Tlv.factory` keeps the octets as a
  # `Tlv::Unknown`. That is part 1's rule: the class is a claim about
  # what the octets mean, and nothing is reported either way.
  class Link_state

    class Tlv

      # The SID/Label/Index field these TLVs end with. Three octets is a
      # label, four is an index or a SID, and the length alone says which
      # (RFC 9085 sections 2.1.1, 2.2.1 and 2.3.1, RFC 9086 section 5).
      #
      # The three-octet form is kept whole: RFC 9085 section 2.1.1 says
      # "the 20 rightmost bits represent a label ... and the 4 leftmost
      # bits are set to 0", so `label` reads the 20 bits and `sid` keeps
      # all 24, which is what `encode` writes back.
      #
      # The hash says which form by its key, `:label` or `:index`.
      module Sid_field

        LABEL_WIDTH = 3
        INDEX_WIDTH = 4
        LABEL_MASK = 0xfffff

        # The field as it arrived: 24 bits for a label, 32 for an index.
        attr_reader :sid

        def sid_width
          @sid_width
        end

        def label?
          @sid_width == LABEL_WIDTH
        end

        # The 20-bit label, or nil for the index form.
        def label
          label? ? @sid & LABEL_MASK : nil
        end

        # The 32-bit index or SID, or nil for the label form.
        def index
          label? ? nil : @sid
        end

        # The 4 high bits of a 3-octet label, which section 2.1.1 says are
        # 0. A reader only.
        def label_high_bits
          label? ? @sid >> 20 : 0
        end

        private

        def encode_sid
          v = [@sid].pack('N')
          label? ? v.byteslice(1, 3) : v
        end

        def parse_sid(s)
          case s.size
          when LABEL_WIDTH then @sid = ("\0".b + s).unpack1('N')
          when INDEX_WIDTH then @sid = s.unpack1('N')
          else
            raise ArgumentError, "a SID/Label/Index is 3 or 4 octets, " \
                                 "this one is #{s.size}"
          end
          @sid_width = s.size
        end

        def sid_hash
          label? ? { :label => @sid } : { :index => @sid }
        end

        def sid_to_s
          label? ? "label #{label}" : "index #{@sid}"
        end

        # The kind of refusal Conventions allows: a value the field
        # cannot hold cannot be written at all.
        def set_sid(v, width)
          unless [LABEL_WIDTH, INDEX_WIDTH].include?(width)
            raise ArgumentError, "a SID/Label/Index is 3 or 4 octets, not #{width}"
          end
          max = width == LABEL_WIDTH ? 0xffffff : 0xffffffff
          unless v.is_a?(Integer) and v >= 0 and v <= max
            raise ArgumentError,
              "#{v.inspect} does not fit a #{width}-octet SID/Label/Index"
          end
          @sid, @sid_width = v, width
        end

        def sid_from_hash(h)
          if h.has_key?(:label)
            set_sid(h[:label].to_i, LABEL_WIDTH)
          elsif h.has_key?(:index)
            set_sid(h[:index].to_i, INDEX_WIDTH)
          else
            raise ArgumentError, "no :label or :index in #{h.inspect}"
          end
        end

      end

      # TLV 1161, RFC 9085 section 2.1.1, the SID/Label TLV. It is a
      # sub-TLV of SR Capabilities and SR Local Block. "Length: Variable.
      # Either 3 or 4 octets depending on whether the value is encoded as
      # a label or as an index/SID."
      #
      # new(16000) is a label, new(5, 4) a 4-octet SID. Also the wire
      # value octets, this class's own hash, or another instance.
      class Sid_label < Tlv

        include Sid_field

        TYPE = 1161
        HASH_KEY = :sid_label

        def initialize(*args)
          set_sid(0, LABEL_WIDTH)
          if args.size == 1 and args[0].is_a?(String) and args[0].is_packed?
            parse(args[0])
          elsif args.size == 1 and args[0].is_a?(self.class)
            self.declared_len = args[0].declared_len
            set_sid(args[0].sid, args[0].sid_width)
          elsif args.size == 1 and args[0].is_a?(Hash)
            from_hash(args[0])
          elsif (1..2).include?(args.size) and args[0].is_a?(Integer)
            set_sid(args[0], args[1] || LABEL_WIDTH)
          elsif args.empty?
            # Label 0, which builds, per Conventions.
          else
            raise ArgumentError, "invalid argument: #{args.inspect}"
          end
          self
        end

        def parse(s)
          parse_sid(s.slice!(0, s.size))
          self
        end

        def encode_value
          encode_sid
        end

        def value_hash
          sid_hash
        end

        def to_s
          "SID/Label #{sid_to_s}"
        end

        private

        def from_hash(h)
          read_declared_len(h)
          sid_from_hash(self.class.unwrap(h))
        end

      end
      register Sid_label

      # What TLV 1034, SR Capabilities, and TLV 1036, SR Local Block,
      # both are: a Flags octet, a Reserved octet, then one or more
      # ranges. RFC 9085 section 2.1.2 and section 2.1.4 give the same
      # figure. Each range is "Range Size: 3 octets" then "SID/Label TLV
      # (as defined in Section 2.1.1) used as a sub-TLV, which encodes
      # the first label in the range."
      #
      # The sub-TLV is read with `Tlv.factory`, so it is a `Sid_label`
      # when it is one and a `Tlv::Unknown` when it is not. Its Length is
      # kept when it lies, which is what lets a malformed capture replay.
      #
      # The flags are IS-IS's (RFC 8667 section 3.1 and 3.3) and none for
      # OSPF, so they stay a number. Reserved is kept and written back,
      # and the hash carries it only when it is not 0.
      #
      # new(flags, [[size, label], ...]), where a label is an Integer or a
      # sub-TLV instance. Also the wire value octets, this class's own
      # hash, or another instance.
      class Sr_range_tlv < Tlv

        # Flags and Reserved.
        HEAD = 2
        # Range Size.
        SIZE_WIDTH = 3

        attr_reader :flags, :reserved, :ranges

        def self.label
          self::LABEL
        end

        def initialize(*args)
          @flags, @reserved, @ranges = 0, 0, []
          if args.size == 1 and args[0].is_a?(String) and args[0].is_packed?
            parse(args[0])
          elsif args.size == 1 and args[0].is_a?(self.class)
            parse(args[0].encode_value.is_packed)
            self.declared_len = args[0].declared_len
          elsif args.size == 1 and args[0].is_a?(Hash)
            from_hash(args[0])
          elsif (1..2).include?(args.size) and args[0].is_a?(Integer)
            @flags = byte(args[0])
            @ranges = (args[1] || []).collect { |r| range(*r) }
          else
            raise ArgumentError, "invalid argument: #{args.inspect}, " \
                                 'expected (flags, [[size, label], ...]) or a hash'
          end
          self
        end

        # Octets that cannot frame one more range raise, so the whole
        # value is kept as a `Tlv::Unknown` rather than losing them.
        def parse(s)
          raise ArgumentError, "#{s.size} octets, too few for Flags and Reserved" if
            s.size < HEAD
          @flags, @reserved = s.slice!(0, HEAD).unpack('CC')
          @ranges = []
          while s.size > 0
            if s.size < SIZE_WIDTH + FRAMING
              raise ArgumentError, "#{s.size} octets left, too few for a range"
            end
            size = ("\0".b + s.slice!(0, SIZE_WIDTH)).unpack1('N')
            @ranges << [size, Tlv.factory(s)]
          end
          self
        end

        def encode_value
          v = [@flags, @reserved].pack('CC')
          @ranges.each do |size, tlv|
            v += [size].pack('N').byteslice(1, 3) + tlv.encode
          end
          v
        end

        # True when the Reserved octet is not 0. "Reserved: 1 octet that
        # MUST be set to 0 and ignored on receipt." A reader only.
        def reserved?
          @reserved != 0
        end

        # True when every range's sub-TLV is a 3-octet SID/Label. "Only
        # label encoding is valid under" this TLV, sections 2.1.2 and
        # 2.1.4 say. A reader only.
        def labels?
          @ranges.all? { |_, t| t.is_a?(Sid_label) and t.label? }
        end

        def value_hash
          h = { :flags => @flags }
          h[:reserved] = @reserved if reserved?
          h[:ranges] = @ranges.collect { |size, t| { :size => size }.merge(t.to_hash) }
          h
        end

        def to_s
          s = format('%s flags 0x%02x', self.class.label, @flags)
          s += format(', reserved 0x%02x', @reserved) if reserved?
          @ranges.each do |size, t|
            first = t.is_a?(Sid_label) ? t.send(:sid_to_s) : t.to_s
            s += ", range #{size} from #{first}"
          end
          s
        end

        private

        def byte(v)
          unless v.is_a?(Integer) and v >= 0 and v <= 0xff
            raise ArgumentError, "#{v.inspect} does not fit one octet"
          end
          v
        end

        def range(size, sub)
          unless size.is_a?(Integer) and size >= 0 and size <= 0xffffff
            raise ArgumentError, "range size #{size.inspect} does not fit 3 octets"
          end
          [size, sub.is_a?(Tlv) ? sub : Sid_label.new(sub)]
        end

        def from_hash(h)
          read_declared_len(h)
          h = self.class.unwrap(h)
          @flags = byte(h[:flags].to_i)
          @reserved = byte(h[:reserved].to_i)
          @ranges = (h[:ranges] || []).collect do |r|
            range(r[:size].to_i, Tlv.from_hash(r.reject { |k, _| k == :size }))
          end
        end

      end

      # TLV 1034, RFC 9085 section 2.1.2, SR Capabilities: the SRGB.
      # "Flags: 1 octet of flags as defined in Section 3.1 of [RFC8667]
      # for IS-IS", which are I (0x80, MPLS IPv4) and V (0x40, MPLS IPv6).
      class Sr_capabilities < Sr_range_tlv
        TYPE = 1034
        HASH_KEY = :sr_capabilities
        LABEL = 'SR Capabilities'
      end
      register Sr_capabilities

      # TLV 1036, RFC 9085 section 2.1.4, SR Local Block: "the range(s)
      # of labels the node has reserved for local SIDs".
      class Sr_local_block < Sr_range_tlv
        TYPE = 1036
        HASH_KEY = :sr_local_block
        LABEL = 'SR Local Block'
      end
      register Sr_local_block

      # TLV 1035, RFC 9085 section 2.1.3, SR-Algorithm: "One or more
      # fields of 1 octet each that identifies the algorithm." "The
      # minimum length is 1 octet and the maximum can be 256", which is
      # not checked: none and 300 both build and parse.
      class Sr_algorithm < Int_list_tlv
        TYPE = 1035
        HASH_KEY = :sr_algorithm
        LABEL = 'SR Algorithms'
        PACK = 'C*'
      end
      register Sr_algorithm

      # What the Adjacency SID, the Prefix-SID and the three BGP Peering
      # SIDs share: Flags, one octet whose meaning is the TLV's, two
      # Reserved octets, then the SID/Label/Index. Figure 7 and Figure 10
      # of RFC 9085 and Figure 2 of RFC 9086 are this layout. Length 7
      # for a label and 8 for an index.
      #
      # The second octet is the Weight for an adjacency or a peer and the
      # Algorithm for a prefix. `SECOND` names it, for the hash and for
      # `to_s`.
      #
      # The flags stay a number. RFC 9085 says the Protocol-ID of the
      # NLRI decides how to read them (sections 2.2.1 and 2.3.1, last
      # paragraph), and a TLV does not know its NLRI.
      #
      # new(flags, second, sid), a label, or new(flags, second, sid, 4),
      # an index. Also the wire value octets, this class's own hash, or
      # another instance.
      class Sid_tlv < Tlv

        include Sid_field

        # Flags, the second octet and Reserved.
        HEAD = 4

        attr_reader :flags, :reserved

        def self.label
          self::LABEL
        end

        def self.second
          self::SECOND
        end

        def initialize(*args)
          @flags, @second, @reserved = 0, 0, 0
          set_sid(0, LABEL_WIDTH)
          if args.size == 1 and args[0].is_a?(String) and args[0].is_packed?
            parse(args[0])
          elsif args.size == 1 and args[0].is_a?(self.class)
            parse(args[0].encode_value.is_packed)
            self.declared_len = args[0].declared_len
          elsif args.size == 1 and args[0].is_a?(Hash)
            from_hash(args[0])
          elsif (3..4).include?(args.size) and args.all? { |a| a.is_a?(Integer) }
            @flags, @second = byte(args[0]), byte(args[1])
            set_sid(args[2], args[3] || LABEL_WIDTH)
          elsif args.empty?
            # Flags 0, label 0, which builds, per Conventions.
          else
            raise ArgumentError, "invalid argument: #{args.inspect}, " \
                                 "expected (flags, #{self.class.second}, sid[, width]) or a hash"
          end
          self
        end

        def parse(s)
          raise ArgumentError, "#{s.size} octets, too few for #{self.class}" if
            s.size < HEAD
          @flags, @second, @reserved = s.slice!(0, HEAD).unpack('CCn')
          parse_sid(s.slice!(0, s.size))
          self
        end

        def encode_value
          [@flags, @second, @reserved].pack('CCn') + encode_sid
        end

        # True when the two Reserved octets are not 0. They "MUST be set
        # to 0 and ignored on receipt". A reader only.
        def reserved?
          @reserved != 0
        end

        def value_hash
          h = { :flags => @flags, self.class.second => @second }
          h[:reserved] = @reserved if reserved?
          h.merge(sid_hash)
        end

        def to_s
          s = format('%s flags 0x%02x %s %d', self.class.label, @flags,
                     self.class.second, @second)
          s += format(' reserved 0x%04x', @reserved) if reserved?
          "#{s} #{sid_to_s}"
        end

        private

        def byte(v)
          unless v.is_a?(Integer) and v >= 0 and v <= 0xff
            raise ArgumentError, "#{v.inspect} does not fit one octet"
          end
          v
        end

        def from_hash(h)
          read_declared_len(h)
          h = self.class.unwrap(h)
          @flags = byte(h[:flags].to_i)
          @second = byte(h[self.class.second].to_i)
          @reserved = h[:reserved].to_i
          unless @reserved >= 0 and @reserved <= 0xffff
            raise ArgumentError, "reserved #{@reserved} does not fit two octets"
          end
          sid_from_hash(h)
        end

      end

      # TLV 1099, RFC 9085 section 2.2.1, Adjacency SID. "Weight: 1 octet
      # carrying the weight used for load-balancing purposes."
      class Adjacency_sid < Sid_tlv
        TYPE = 1099
        HASH_KEY = :adjacency_sid
        LABEL = 'Adjacency SID'
        SECOND = :weight

        def weight
          @second
        end
      end
      register Adjacency_sid

      # TLV 1158, RFC 9085 section 2.3.1, Prefix-SID. "Algorithm: 1-octet
      # value identifies the algorithm."
      class Prefix_sid < Sid_tlv
        TYPE = 1158
        HASH_KEY = :prefix_sid
        LABEL = 'Prefix-SID'
        SECOND = :algorithm

        def algorithm
          @second
        end
      end
      register Prefix_sid

      # What RFC 9086's three BGP Peering SIDs share. Section 5: "PeerNode
      # SID, PeerAdj SID, and PeerSet SID all have the same format", the
      # `Sid_tlv` layout with a Weight. These flags are BGP's own, so they
      # have names: `|V|L|B|P| Rsvd  |` (Figure 3). The four low bits
      # "MUST be zero when originated and ignored when received", and are
      # kept and written back like any other.
      class Peer_sid < Sid_tlv

        SECOND = :weight

        VALUE      = 0x80   # V
        LOCAL      = 0x40   # L
        BACKUP     = 0x20   # B
        PERSISTENT = 0x10   # P

        BITS = {
          :value      => VALUE,
          :local      => LOCAL,
          :backup     => BACKUP,
          :persistent => PERSISTENT,
        }.freeze

        DEFINED_BITS = 0xf0

        def weight
          @second
        end

        def value?      ; !(@flags & VALUE).zero?      ; end
        def local?      ; !(@flags & LOCAL).zero?      ; end
        def backup?     ; !(@flags & BACKUP).zero?     ; end
        def persistent? ; !(@flags & PERSISTENT).zero? ; end

        def names
          BITS.keys.select { |n| !(@flags & BITS[n]).zero? }
        end

        def undefined_bits
          @flags & ~DEFINED_BITS & 0xff
        end

      end

      # TLV 1101, RFC 9086 section 5, PeerNode SID. GoBGP sends it on
      # every Link NLRI it originates (docs/bgp-ls.md, section 11).
      class Peer_node_sid < Peer_sid
        TYPE = 1101
        HASH_KEY = :peer_node_sid
        LABEL = 'PeerNode SID'
      end
      register Peer_node_sid

      # TLV 1102, RFC 9086 section 5, PeerAdj SID.
      class Peer_adj_sid < Peer_sid
        TYPE = 1102
        HASH_KEY = :peer_adj_sid
        LABEL = 'PeerAdj SID'
      end
      register Peer_adj_sid

      # TLV 1103, RFC 9086 section 5, PeerSet SID.
      class Peer_set_sid < Peer_sid
        TYPE = 1103
        HASH_KEY = :peer_set_sid
        LABEL = 'PeerSet SID'
      end
      register Peer_set_sid

      # TLV 1100, RFC 9085 section 2.2.2, LAN Adjacency SID. The
      # `Sid_tlv` head, then the neighbor, then the SID/Label/Index.
      # "Neighbor ID: 6 octets for IS-IS for the System ID, and 4 octets
      # for OSPF for the OSPF Router-ID of the neighbor."
      #
      # So "For IS-IS, it would be 13 or 14 octets ... For OSPF, it would
      # be 11 or 12 octets", and each of the four lengths has one reading:
      # 11 is an OSPF neighbor and a label, 12 an OSPF neighbor and an
      # index, 13 a system ID and a label, 14 a system ID and an index.
      # The length alone says which, as the Protocol-ID would.
      #
      # The neighbor is written `0000.0000.0002` for a system ID, as
      # IS-IS prints one, and as a dotted quad for an OSPF Router-ID.
      #
      # new(flags, weight, neighbor, sid[, width]), the wire value octets,
      # this class's own hash, or another instance.
      class Lan_adjacency_sid < Sid_tlv

        TYPE = 1100
        HASH_KEY = :lan_adjacency_sid
        LABEL = 'LAN Adjacency SID'
        SECOND = :weight

        SYSTEM_ID = /\A\h{4}\.\h{4}\.\h{4}\z/

        # Value length to [neighbor octets, SID octets].
        WIDTHS = {
          11 => [4, 3],
          12 => [4, 4],
          13 => [6, 3],
          14 => [6, 4],
        }.freeze

        def initialize(*args)
          @neighbor = "\0".b * 6
          if (4..5).include?(args.size) and args[2].is_a?(String)
            @flags, @second, @reserved = byte(args[0]), byte(args[1]), 0
            @neighbor = neighbor_octets(args[2])
            set_sid(args[3], args[4] || LABEL_WIDTH)
          else
            super
          end
          self
        end

        def weight
          @second
        end

        # The neighbor as it prints: a system ID or a dotted quad.
        def neighbor
          if @neighbor.size == 6
            @neighbor.unpack1('H*').scan(/.{4}/).join('.')
          else
            IPAddr.new_ntoh(@neighbor).to_s
          end
        end

        def system_id?
          @neighbor.size == 6
        end

        def parse(s)
          widths = WIDTHS[s.size]
          if widths.nil?
            raise ArgumentError, "a LAN Adjacency SID is 11 to 14 octets, " \
                                 "this one is #{s.size}"
          end
          @flags, @second, @reserved = s.slice!(0, HEAD).unpack('CCn')
          @neighbor = s.slice!(0, widths[0])
          parse_sid(s.slice!(0, s.size))
          self
        end

        def encode_value
          [@flags, @second, @reserved].pack('CCn') + @neighbor + encode_sid
        end

        def value_hash
          h = { :flags => @flags, :weight => @second }
          h[:reserved] = @reserved if reserved?
          h[:neighbor] = neighbor
          h.merge(sid_hash)
        end

        def to_s
          s = format('%s flags 0x%02x weight %d', self.class.label, @flags, @second)
          s += format(' reserved 0x%04x', @reserved) if reserved?
          "#{s} neighbor #{neighbor} #{sid_to_s}"
        end

        private

        def neighbor_octets(v)
          s = v.to_s
          return [s.delete('.')].pack('H*') if s =~ SYSTEM_ID
          a = IPAddr.new(s)
          unless a.ipv4?
            raise ArgumentError, "neighbor #{s} is neither a system ID " \
                                 'nor an IPv4 Router-ID'
          end
          a.hton
        end

        def from_hash(h)
          super
          @neighbor = neighbor_octets(self.class.unwrap(h)[:neighbor])
        end

      end
      register Lan_adjacency_sid

    end

  end

end

load "../../test/unit/nlris/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
