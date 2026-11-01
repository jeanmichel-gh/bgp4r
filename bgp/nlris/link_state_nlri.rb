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

require 'bgp/common'
require 'bgp/iana'
require 'bgp/nlris/link_state'
require 'bgp/nlris/link_state_descriptor'
require 'bgp/nlris/link_state_link_descriptor'
require 'bgp/nlris/link_state_prefix_descriptor'

module BGP

  # The Link-State NLRI types of RFC 9552 section 5.2, registered with
  # `Link_state.register` so both parse and the hash build path find
  # them. The framing around them, the NLRI Type and Total NLRI Length
  # and the SAFI 72 Route Distinguisher, is `link_state.rb`'s.
  #
  # `docs/bgp-ls.md` is the guide. Every section number here was read in
  # the RFC text on 2026-11-01. Nothing dispatches to this file yet: the
  # NLRI gates are part 4.
  #
  # **The three layouts share a head and differ only in what follows
  # it**, which is figures 7, 8 and 9 read together: a Protocol-ID
  # octet, an 8-octet Identifier, and then a set of descriptor TLVs. So
  # `Headed` carries the head and the TLV list, and each NLRI type is a
  # type number, a hash key and whatever it says about the TLVs it
  # expects. All four of Table 1 are here: the Node NLRI came with part
  # 2 and part 3 put the Link NLRI and the two Prefix NLRIs on the same
  # base, which is what that base was for.
  class Link_state

    # What every Link-State NLRI type of section 5.2 begins with.
    #
    #   +-+-+-+-+-+-+-+-+
    #   |  Protocol-ID  |
    #   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    #   |                           Identifier                          |
    #   +                           (8 octets)                          +
    #   |                                                               |
    #   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    #   //                   Descriptor TLVs (variable)                //
    #   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    #
    # **The body after the head is a TLV list and not a set of named
    # fields**, which is section 5.1 rather than a shortcut: "Unknown
    # and unsupported types MUST be preserved and propagated within
    # both the NLRI and the BGP-LS Attribute", and "The presence of
    # unknown or unexpected TLVs MUST NOT result in the NLRI or the
    # BGP-LS Attribute being considered malformed." A layout of named
    # fields would have nowhere to put a TLV this library does not
    # know, and figure 7's one named TLV would then be the only thing
    # that could arrive.
    #
    # It also means a Node NLRI carrying no Local Node Descriptors at
    # all builds and parses, which is right twice over: section 8.2.2
    # names "presence of a mandatory TLV" among the semantic
    # validations a BGP-LS Propagator should **not** perform, and
    # building never validates in any case.
    class Headed < Type

      # Section 5.2, figures 7 to 9.
      HEAD = 9
      ID_WIDTH = 8

      # Table 2 of section 5.2, "Protocol Identifiers", with the IANA
      # registry's ranges around it: 0 is Reserved, 1 to 6 are these,
      # and 200 to 255 is Private Use. Read on 2026-10-31.
      PROTOCOLS = {
        1 => 'IS-IS Level 1',
        2 => 'IS-IS Level 2',
        3 => 'OSPFv2',
        4 => 'Direct',
        5 => 'Static configuration',
        6 => 'OSPFv3',
      }.freeze

      PRIVATE_USE = (200..255)

      attr_reader :protocol_id, :identifier, :tlvs

      # Octets after the last whole TLV, which cannot frame one. Kept so
      # `encode` gives back what arrived.
      attr_reader :tail

      # new(protocol_id, identifier, a_tlv, another), the wire value
      # octets, this class's own hash, or another instance.
      def initialize(*args)
        @protocol_id, @identifier, @tlvs, @tail = 0, 0, [], String.new
        if args.size == 1 and args[0].is_a?(String) and args[0].is_packed?
          parse(args[0])
        elsif args.size == 1 and args[0].is_a?(self.class)
          parse(args[0].encode_value.is_packed)
        elsif args.size == 1 and args[0].is_a?(Hash)
          from_hash(args[0])
        elsif args.size >= 2
          @protocol_id = coerce_protocol(args[0])
          @identifier = args[1].to_i
          args[2..].each { |a| @tlvs << coerce(a) }
        else
          raise ArgumentError, "invalid argument: #{args.inspect}, expected " \
                               '(protocol_id, identifier, *tlvs), a hash, ' \
                               'wire bytes or another instance'
        end
        self
      end

      # Protocol-ID, Identifier, then whatever TLVs the rest frames.
      #
      # A body too short for the head takes what it can and keeps
      # nothing else, which cannot reproduce itself: `Link_state` then
      # falls back to `Link_state::Unknown` and the octets replay from
      # there. That is the encode-matches rule part 1 records, and it is
      # why nothing here has to refuse a short body.
      def parse(s)
        @protocol_id = s.slice!(0, 1).unpack1('C').to_i
        @identifier = s.slice!(0, ID_WIDTH).unpack1('Q>').to_i
        @tlvs = Tlv.parse_list(s)
        @tail = s.slice!(0, s.size)
        self
      end

      def encode_value
        [@protocol_id, @identifier].pack('CQ>') +
          @tlvs.collect { |t| t.encode }.join + @tail
      end

      def <<(t)
        @tlvs << coerce(t)
        self
      end

      # Table 2's name for this Protocol-ID, or what the registry's
      # ranges call the value.
      def protocol
        PROTOCOLS[@protocol_id] ||
          (PRIVATE_USE.include?(@protocol_id) ? 'Private use' :
           @protocol_id.zero? ? 'Reserved' : 'Unassigned')
      end

      # The first TLV of a type, which is how a reader asks for a
      # descriptor. nil when there is none, and the **first** when a
      # peer sent two, since section 5.1 orders TLVs and says nothing
      # that makes a repeat impossible at this level.
      def tlv(type)
        @tlvs.find { |t| t.type == type }
      end

      def local_node_descriptors
        tlv(Tlv::Local_node_descriptors.type)
      end

      # Section 5.2.1.4's rule, which needs both halves and so lives
      # here: "The TLV size in combination with the protocol identifier
      # enables the decoder to determine the type of the node."
      #
      # `Igp_router_id::SHAPES` holds the width half, keyed by width
      # with the Protocol-IDs each width belongs to. This answers
      # `:non_pseudonode` or `:pseudonode` only where the two agree, and
      # nil otherwise, which covers a width the section does not
      # describe, a Protocol-ID that does not match the width, a
      # Protocol-ID outside Table 2, and no IGP Router-ID at all.
      #
      # **nil is an answer and not a failure.** A 6-octet Router-ID
      # under Protocol-ID 4, 'Direct', is perfectly legal: the section
      # says that for 'Direct' or 'Static configuration' the value
      # "SHOULD be taken from an IPv4 or IPv6 address", so it describes
      # no node kind there at all. Reporting one would be inventing it.
      def node_type
        d = local_node_descriptors
        return nil if d.nil?
        r = d.sub_tlvs.find { |t| t.is_a?(Tlv::Igp_router_id) }
        return nil if r.nil?
        shape = r.shape
        return nil if shape.nil?
        shape[0].include?(@protocol_id) ? shape[1] : nil
      end

      def value_hash
        h = { :protocol_id => @protocol_id, :identifier => @identifier,
              :tlvs => @tlvs.collect { |t| t.to_hash } }
        h = h.merge(:tail => @tail.unpack1('H*')) unless @tail.empty?
        h
      end

      def to_s
        s = "#{self.class.label} [#{protocol}, instance #{@identifier}]"
        s += ' ' + @tlvs.collect { |t| t.to_s }.join(' ') unless @tlvs.empty?
        s += " tail [#{@tail.unpack1('H*')}]" unless @tail.empty?
        n = node_type
        s += " (#{n})" if n
        s
      end

      def self.label
        self::LABEL
      end

      private

      # A name from Table 2 as readily as a number, since a test reads
      # better for it and the table is small.
      def coerce_protocol(v)
        return v.to_i if v.is_a?(Integer)
        k = PROTOCOLS.key(v.to_s)
        return k if k
        sym = v.to_s.downcase.gsub(/[^a-z0-9]/, '')
        found = PROTOCOLS.find { |_, n| n.downcase.gsub(/[^a-z0-9]/, '') == sym }
        return found[0] if found
        raise ArgumentError,
          "unknown Protocol-ID #{v.inspect}; Table 2 has " \
          "#{PROTOCOLS.values.join(', ')}, or pass a number"
      end

      def coerce(a)
        a.is_a?(Tlv) ? a : Tlv.from_hash(a)
      end

      def from_hash(h)
        h = self.class.unwrap(h)
        @protocol_id = coerce_protocol(h[:protocol_id] || 0)
        @identifier = h[:identifier].to_i
        @tail = [h[:tail].to_s].pack('H*') if h[:tail]
        [h[:tlvs]].flatten(1).each { |e| @tlvs << coerce(e) if e }
      end

    end

    # NLRI Type 1, section 5.2 figure 7, the Node NLRI: the head and
    # the Local Node Descriptors TLV.
    #
    # Table 1 names it and section 5.2.1.2 says its one expected TLV is
    # "a mandatory TLV in all three types of NLRIs", so there is
    # nothing here the base does not already do. The class exists for
    # the type number, the hash key and the name.
    class Node < Headed
      TYPE = 1
      HASH_KEY = :node
      LABEL = 'Node'
    end
    register Node

    # NLRI Type 2, section 5.2 figure 8, the Link NLRI: the head, the
    # Local and Remote Node Descriptors TLVs, and the Link Descriptor
    # TLVs of section 5.2.2.
    #
    # **What a Link NLRI describes is half a link**, which section
    # 5.2.2 says outright and which a reader will otherwise assume
    # wrong: "A link described by the Link Descriptor TLVs actually is
    # a 'half-link', a unidirectional representation of a logical
    # link. To fully describe a single logical link, two anchor routers
    # advertise a half-link each, i.e., two Link NLRIs are advertised
    # for a given point-to-point link." So nothing here pairs two of
    # them, and a single Link NLRI is not a link.
    #
    # Nothing in the layout differs from the base, so the only thing
    # this class adds beyond identity is the `remote_node_descriptors`
    # reader.
    class Link < Headed

      TYPE = 2
      HASH_KEY = :link
      LABEL = 'Link'

      def remote_node_descriptors
        tlv(Tlv::Remote_node_descriptors.type)
      end

    end
    register Link

    # NLRI Types 3 and 4, section 5.2 figure 9: "The IPv4 and IPv6
    # Prefix NLRIs (NLRI Type = 3 and Type = 4) use the same format".
    #
    # So one base and two names, which is the honest statement of what
    # the figure says, and the two subclasses carry the one thing that
    # differs: which family their descriptors are in.
    #
    # **That family is not in any octet below this class**, which is
    # the second cross-level read in the family after the node type
    # rule. `Tlv::Ip_reachability` holds a Prefix Length in bits and
    # the octets and cannot say whether 24 bits are IPv4 or IPv6; the
    # NLRI type is what says it, so `#prefix` here combines them. Same
    # shape as `Headed#node_type`, same reason.
    class Prefix_nlri < Headed

      def self.afi
        self::AFI
      end

      def afi
        self.class.afi
      end

      # The section 5.2.3.2 TLV, which that section calls "a mandatory
      # TLV for IPv4 & IPv6 Prefix NLRI types" and which an NLRI may
      # still arrive without.
      def ip_reachability
        tlv(Tlv::Ip_reachability.type)
      end

      # The prefix as a person writes it, read with this NLRI type's
      # own family. nil when there is no IP Reachability Information
      # TLV, and nil when its fields cannot make an address of this
      # family, which `Ip_reachability#prefix` decides.
      def prefix
        r = ip_reachability
        r && r.prefix(afi)
      end

      # The TLV prints its own octets and a bit count, because it has
      # no family to read them with; this adds the prefix those octets
      # make under this NLRI type's family, which is the only place
      # the two can be put together.
      def to_s
        p = prefix
        s = super
        p ? s + " as #{p}" : s
      end

    end

    class Ipv4_prefix < Prefix_nlri
      TYPE = 3
      HASH_KEY = :ipv4_prefix
      LABEL = 'IPv4 prefix'
      AFI = IANA::AFI::IPv4
    end
    register Ipv4_prefix

    class Ipv6_prefix < Prefix_nlri
      TYPE = 4
      HASH_KEY = :ipv6_prefix
      LABEL = 'IPv6 prefix'
      AFI = IANA::AFI::IPv6
    end
    register Ipv6_prefix

  end

end

load "../../test/unit/nlris/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
