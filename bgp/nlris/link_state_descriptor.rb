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

module BGP

  # The Node Descriptor TLVs of RFC 9552 section 5.2.1 and the four
  # sub-TLVs of section 5.2.1.4, registered with
  # `Link_state::Tlv.register` so both parse and the hash build path
  # find them.
  #
  # `docs/bgp-ls.md` is the guide. Every section number here was read in
  # the RFC text on 2026-11-01. Nothing dispatches to this file yet: the
  # NLRI gates are part 4.
  #
  # **One flat registry covers TLVs and sub-TLVs alike, and that is
  # IANA's doing rather than a simplification.** The registry is "BGP-LS
  # NLRI and Attribute TLVs", one space for both, and RFC 9552's own
  # Table 18 lists 256 and 257 beside 512 to 515 with no column saying
  # which is which. So a sub-TLV number means the same thing under every
  # parent, which is the opposite of the EVPN extended community
  # sub-types and of the IS-IS sub-TLVs, where the parent decides. That
  # is why part 1's single `Tlv::REGISTRY` needed nothing here.
  class Link_state

    class Tlv

      # The three fixed-width node descriptor sub-TLVs: 512, 513 and
      # 514 are each "Opaque value (32-bit ...)" in a 4-octet TLV, per
      # Table 3 of section 5.2.1.4. A base rather than three copies,
      # since the only thing that differs is the type number, the hash
      # key and how each prints.
      #
      # **Opaque is the RFC's word for all three**, so none of them
      # refuses a value and none reads structure out of it. A width
      # other than 4 cannot be one of these: `Tlv.factory` then finds
      # the value does not reproduce itself and keeps the octets as a
      # `Tlv::Unknown`, which is the rule part 1 records.
      class Opaque32 < Tlv

        WIDTH = 4

        attr_reader :value

        # new(65000), the wire value octets, this class's own hash, or
        # another instance.
        def initialize(*args)
          @value = 0
          if args.size == 1 and args[0].is_a?(String) and args[0].is_packed?
            parse(args[0])
          elsif args.size == 1 and args[0].is_a?(self.class)
            self.declared_len = args[0].declared_len
            @value = args[0].value
          elsif args.size == 1 and args[0].is_a?(Hash)
            from_hash(args[0])
          elsif args.size == 1
            @value = coerce(args[0])
          elsif args.empty?
            # Zero, which is what section 5.2.1.4 recommends a BGP-LS
            # Producer send for 513 and which no RFC blesses for the
            # other two. It builds, per Conventions.
          else
            raise ArgumentError, "invalid argument: #{args.inspect}"
          end
          self
        end

        def parse(s)
          @value = s.slice!(0, WIDTH).unpack1('N').to_i
          self
        end

        def encode_value
          [@value].pack('N')
        end

        def value_hash
          @value
        end

        def to_s
          "#{self.class.label} #{@value}"
        end

        # How this sub-TLV names itself in a dump. The registry's own
        # Description column, so a reader can find the row.
        def self.label
          self::LABEL
        end

        private

        # An Integer as it stands. A subclass that takes another form
        # overrides this.
        def coerce(v)
          v.to_i
        end

        def from_hash(h)
          read_declared_len(h)
          h = self.class.unwrap(h)
          # The hash value is the bare number, so a Hash here is the
          # field hash of a class that has none: nothing to read.
          @value = h.is_a?(Hash) ? 0 : coerce(h)
        end

      end

      # Sub-TLV 512, section 5.2.1.4: "Autonomous System: Opaque value
      # (32-bit AS Number). This is an optional TLV. The value SHOULD be
      # set to the AS Number associated with the BGP process originating
      # the link-state information."
      #
      # 32 bits flat, so a 2-octet AS sits in the low half and the field
      # never follows what the session negotiated. Same shape as
      # `Mcast_vpn::Source_as` and for the same reason: the table gives
      # a width and the NLRI carries no capability.
      class Autonomous_system < Opaque32
        TYPE = 512
        HASH_KEY = :autonomous_system
        LABEL = 'AS'
      end
      register Autonomous_system

      # Sub-TLV 513, section 5.2.1.4: "BGP-LS Identifier: Opaque value
      # (32-bit ID). This is an optional TLV that has been deprecated by
      # this document".
      #
      # **Deprecated and implemented anyway**, which is deliberate:
      # Table 18 of section 9 carries the row and marks it deprecated,
      # and the section says implementations "SHOULD support the
      # advertisement of this sub-TLV for backward compatibility in
      # deployments where there are BGP-LS Producer implementations that
      # conform to [RFC7752]". A deprecated code point a peer still
      # sends is exactly what a protocol testing tool has to read.
      # "The default value of 0 is RECOMMENDED", which is what
      # `Bgp_ls_identifier.new` with no argument writes.
      class Bgp_ls_identifier < Opaque32
        TYPE = 513
        HASH_KEY = :bgp_ls_identifier
        LABEL = 'BGP-LS ID'
      end
      register Bgp_ls_identifier

      # Sub-TLV 514, section 5.2.1.4: "OSPF Area-ID: Used to identify
      # the 32-bit area to which the information advertised in the NLRI
      # belongs. This is a mandatory TLV when originating information
      # from OSPF that is derived from area-scope LSAs."
      #
      # **The dotted quad is a convention and not the RFC's**, which
      # says only "32-bit area". OSPF itself and every router print an
      # Area-ID that way, and the whole value of a presentation form is
      # that a line out of a router dump can be pasted back in, so this
      # takes either form: `Ospf_area_id.new(1)` and
      # `Ospf_area_id.new('0.0.0.1')` are the same four octets. Said
      # here so an audit does not go looking for a clause behind the
      # dots.
      class Ospf_area_id < Opaque32

        TYPE = 514
        HASH_KEY = :ospf_area_id
        LABEL = 'Area'

        # The dotted quad, which is how a router prints it.
        def area
          IPAddr.new(@value, Socket::AF_INET).to_s
        end

        def to_s
          "#{self.class.label} #{area}"
        end

        private

        # An Integer as it stands, and anything else through IPAddr, so
        # the dotted quad a dump prints reads back.
        def coerce(v)
          return v.to_i if v.is_a?(Integer)
          IPAddr.new(v.to_s).to_i
        end

      end
      register Ospf_area_id

      # Sub-TLV 515, section 5.2.1.4: "IGP Router-ID: Opaque value."
      # The one node descriptor sub-TLV of variable length, and Table 3
      # says so in that column.
      #
      # **Four widths are described and the width alone does not say
      # which**: section 5.2.1.4 gives 6 octets for an IS-IS
      # non-pseudonode ISO System-ID, 7 for an IS-IS pseudonode, which
      # is "the 6-octet ISO Node-ID of the Designated Intermediate
      # System (DIS) followed by a 1-octet, nonzero PSN identifier", 4
      # for an OSPFv2 or OSPFv3 non-pseudonode Router-ID, and 8 for
      # either OSPF pseudonode, "the 4-octet Router-ID of the DR
      # followed by" an address or an interface identifier.
      #
      # So the section's own sentence is the rule: "The TLV size in
      # combination with the protocol identifier enables the decoder to
      # determine the type of the node." **Both halves, and this class
      # holds only one of them.** `SHAPES` is keyed by width and names
      # which Protocol-IDs each width belongs to; `Link_state::Node`
      # does the combining, because that is the one place that has the
      # Protocol-ID as well. Threading the Protocol-ID down here would
      # buy nothing, since the octets replay without it, and a class
      # that accepted it would eventually use it.
      #
      # Any other width still parses and replays. Opaque is the RFC's
      # word and a width it does not describe is not an error it names.
      class Igp_router_id < Tlv

        TYPE = 515
        HASH_KEY = :igp_router_id

        # width => [the Protocol-IDs it belongs to, the node kind, what
        # the octets are]. Read out of section 5.2.1.4's own prose; the
        # Protocol-ID numbers are Table 2's.
        SHAPES = {
          4 => [[3, 6], :non_pseudonode, 'OSPF Router-ID'],
          6 => [[1, 2], :non_pseudonode, 'IS-IS ISO System-ID'],
          7 => [[1, 2], :pseudonode,
                'IS-IS DIS System-ID and PSN identifier'],
          8 => [[3, 6], :pseudonode, 'OSPF DR Router-ID and interface'],
        }.freeze

        attr_reader :value

        # new('1921.6800.1001'), new(octets_as_hex_string) through the
        # hash, the wire value octets, this class's own hash, or another
        # instance.
        def initialize(*args)
          @value = String.new
          if args.size == 1 and args[0].is_a?(String) and args[0].is_packed?
            @value = args[0].slice!(0, args[0].size)
          elsif args.size == 1 and args[0].is_a?(self.class)
            self.declared_len = args[0].declared_len
            @value = args[0].value.dup
          elsif args.size == 1 and args[0].is_a?(Hash)
            from_hash(args[0])
          elsif args.size == 1
            @value = coerce(args[0])
          elsif args.empty?
            # The empty value, which Table 3's "Variable" does not
            # forbid and which no RFC describes. It builds, per
            # Conventions.
          else
            raise ArgumentError, "invalid argument: #{args.inspect}"
          end
          self
        end

        def encode_value
          @value.dup
        end

        # The `SHAPES` row for this width, or nil for a width section
        # 5.2.1.4 does not describe. Half of the section's rule; the
        # other half is the Protocol-ID, which `Link_state::Node` has.
        def shape
          SHAPES[@value.size]
        end

        # The IS-IS pseudonode PSN identifier, section 5.2.1.4's
        # "1-octet, nonzero PSN identifier", for the one width that has
        # one. nil elsewhere, and 0 where it arrived as 0, which the
        # section calls nonzero and nothing here refuses.
        def psn
          @value.size == 7 ? @value.getbyte(6) : nil
        end

        def value_hash
          @value.unpack1('H*')
        end

        # Hex and the width, and then what the width allows. Not a
        # verdict: the Protocol-ID is what settles it and this class
        # does not have one.
        def to_s
          s = "Router-ID #{@value.unpack1('H*')} (#{@value.size} octets"
          r = shape
          s += ", #{r[2]}" if r
          s + ')'
        end

        private

        # **A String is hex**, because the value is opaque octets and
        # hex is the only reading they have; it is also what
        # `value_hash` answers, so a hash and a field build take the
        # same form. Separators are stripped, which means the dotted
        # form a router prints an ISO System-ID in,
        # `1921.6800.1001`, reads back as its six octets. That works
        # because the form is hex groups and not because this class
        # knows anything about IS-IS, which it must not: the width and
        # the Protocol-ID together are what name a node, and the
        # Protocol-ID is `Link_state::Node`'s.
        #
        # An odd count of hex digits is not refused: `pack('H*')` pads
        # the last nibble, which is a value no RFC describes and so is
        # a thing this library sends rather than a thing it rejects.
        #
        # An Integer is refused, which is the kind Conventions allows:
        # opaque octets from a number have no width, so the alternative
        # is guessing one and sending a different field than the caller
        # asked for.
        def coerce(v)
          unless v.is_a?(String)
            raise ArgumentError,
              "an IGP Router-ID is opaque octets, so #{v.inspect} has no " \
              'width; pass hex, such as "1921.6800.1001" or "0a000001"'
          end
          [v.gsub(/[^0-9a-fA-F]/, '')].pack('H*')
        end

        # **`coerce` and not `pack('H*')`, because the two disagreed and
        # one of them mangled its input in silence.** `coerce` strips
        # every non-hex character first, so it reads a dotted System ID
        # as well as bare hex; `pack('H*')` does not, and on a String
        # carrying separators it maps each one by its low nibble rather
        # than skipping it. So `{:igp_router_id => '1921.6800.1001.02'}`
        # built **nine** octets, `1921e6800e1001e020`, where the field
        # value form built the right seven: a `.` became 0xe and shifted
        # everything after it. Found in #219 by a functional test
        # asserting `node_type`, which answered nil because no shape has
        # a width of 9. Part 2's tests used '0a000001', pure hex with no
        # separators, which both paths read alike, so nothing caught it.
        # One method for both forms now, which is why they cannot
        # disagree again.
        def from_hash(h)
          read_declared_len(h)
          h = self.class.unwrap(h)
          @value = coerce(h.to_s)
        end

      end
      register Igp_router_id

      # What TLV 256 and TLV 257 both are: a list of node descriptor
      # sub-TLVs and nothing else.
      #
      # Section 5.2.1.2 for 256, "The Local Node Descriptors TLV
      # contains Node Descriptors for the node anchoring the local end
      # of the link. This is a mandatory TLV in all three types of
      # NLRIs (node, link, and prefix). The Type is 256. The length of
      # this TLV is variable. The value contains one or more Node
      # Descriptor sub-TLVs defined in Section 5.2.1.4." Section 5.2.1.3
      # for 257 is the same sentence with "remote end" and "mandatory
      # TLV for Link NLRIs", and figures 10 and 11 are identical.
      #
      # **So one base and two names, which is the honest statement of
      # what the two sections say.** `Mcast_vpn::Shared_tree_join` and
      # `Source_tree_join` are the same shape for the same reason.
      #
      # "Mandatory" is not this class's business and not the encoder's:
      # section 8.2.2 names "presence of a mandatory TLV" among the
      # semantic validations a BGP-LS Propagator should **not** perform,
      # so an NLRI with neither TLV builds and parses here.
      class Node_descriptors < Tlv

        attr_reader :sub_tlvs

        # Octets after the last whole sub-TLV, which cannot frame one.
        # Kept so `encode` gives back what arrived.
        attr_reader :tail

        # new(a_sub_tlv, another), the wire value octets, this class's
        # own hash, or another instance.
        def initialize(*args)
          @sub_tlvs, @tail = [], String.new
          if args.size == 1 and args[0].is_a?(String) and args[0].is_packed?
            parse(args[0])
          elsif args.size == 1 and args[0].is_a?(self.class)
            self.declared_len = args[0].declared_len
            parse(args[0].encode_value.is_packed)
          elsif args.size == 1 and args[0].is_a?(Hash)
            from_hash(args[0])
          else
            args.each { |a| @sub_tlvs << coerce(a) }
          end
          self
        end

        def parse(s)
          @sub_tlvs = Tlv.parse_list(s)
          @tail = s.slice!(0, s.size)
          self
        end

        def encode_value
          @sub_tlvs.collect { |t| t.encode }.join + @tail
        end

        def <<(t)
          @sub_tlvs << coerce(t)
          self
        end

        # Section 5.2.1.4: "At most, there MUST be one instance of each
        # sub-TLV type present in any Node Descriptor." Reported rather
        # than refused, because building never validates; part 6 is
        # where a receive side check reads this.
        def duplicate_types
          seen = {}
          @sub_tlvs.each { |t| seen[t.type] = seen.fetch(t.type, 0) + 1 }
          seen.select { |_, n| n > 1 }.keys
        end

        # Section 5.2.1.4: "The sub-TLVs within a Node Descriptor MUST
        # be arranged in ascending order by sub-TLV type."
        #
        # **That is section 5.1's rule with its tiebreakers made
        # unnecessary**, and noticing why is worth more than the two
        # sentences: 5.1 orders by type, then by Length, then by Value,
        # because several TLVs of one type can share an NLRI. Here the
        # once-only rule above means two sub-TLVs never share a type, so
        # there is nothing left to break a tie. `Tlv.ordered?` answers
        # the same for any list that obeys the once-only rule, so this
        # asks it rather than keeping a second comparison.
        def ordered?
          Tlv.ordered?(@sub_tlvs)
        end

        def value_hash
          @sub_tlvs.collect { |t| t.to_hash }
        end

        def to_hash
          h = super
          h = h.merge(:tail => @tail.unpack1('H*')) unless @tail.empty?
          h
        end

        def to_s
          s = "#{self.class.label}: "
          s += @sub_tlvs.empty? ? '(none)' :
               @sub_tlvs.collect { |t| t.to_s }.join(', ')
          s += " tail [#{@tail.unpack1('H*')}]" unless @tail.empty?
          s
        end

        def self.label
          self::LABEL
        end

        private

        def coerce(a)
          a.is_a?(Tlv) ? a : Tlv.from_hash(a)
        end

        def from_hash(h)
          read_declared_len(h)
          t = h[:tail] if h.is_a?(Hash)
          h = self.class.unwrap(h)
          @tail = [t.to_s].pack('H*') if t
          [h].flatten(1).each { |e| @sub_tlvs << coerce(e) if e.is_a?(Hash) }
        end

      end

      class Local_node_descriptors < Node_descriptors
        TYPE = 256
        HASH_KEY = :local_node_descriptors
        LABEL = 'Local node'
      end
      register Local_node_descriptors

      class Remote_node_descriptors < Node_descriptors
        TYPE = 257
        HASH_KEY = :remote_node_descriptors
        LABEL = 'Remote node'
      end
      register Remote_node_descriptors

    end

  end

end

load "../../test/unit/nlris/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
