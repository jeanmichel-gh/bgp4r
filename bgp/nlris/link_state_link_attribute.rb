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

  # The Link Attribute TLVs of RFC 9552 section 5.3.2, Table 8,
  # registered with `Link_state::Tlv.register`.
  #
  # `docs/bgp-ls.md` is the guide. Every RFC 9552 section number here was
  # read in the RFC text on 2026-11-01, and so was every width below in
  # the document that gives it.
  #
  # **Table 8 has no Length column, which is Table 4's situation
  # exactly.** Where Table 6 and Table 10 each give a Length, Table 8
  # gives an "IS-IS TLV/Sub-TLV" column instead, so not one of its
  # fifteen rows carries a width. Section 5.3.2 says where to look:
  # "The format and semantics of the Value fields in some Link Attribute
  # TLVs correspond to the format and semantics of the Value fields in
  # IS-IS Extended IS Reachability sub-TLVs, which are defined in
  # [RFC5305] and [RFC5307]." **Five of them have no width anywhere in
  # RFC 9552**, so each of those five names the document it came from,
  # and that citation is the only place the width lives.
  #
  # **Two of the five are not what memory gives**, which is why they
  # were fetched rather than recalled. TLV 1091 is **32 octets**, eight
  # IEEE floats one per setup priority, not the 4 that its three
  # neighbours have. TLV 1093 is **2**, a capability octet and a
  # reserved one.
  #
  # **Thirteen new classes and two of Table 8's fifteen rows already
  # in.** 1028 and 1029 are the local Router-IDs, which are Table 6's
  # rows too and landed with part 5a, since section 5.3.2.1 covers the
  # local and the remote pair together: "All auxiliary Router-IDs of
  # both the local and the remote node MUST be included in the link
  # attribute of each Link NLRI."
  #
  # **Which TLVs may appear is not this file's business**, the same as
  # the node attributes: section 8.2.2 names "whether a TLV is valid
  # with a given NLRI type" among the semantic validations a BGP-LS
  # Propagator should not perform. So a link attribute TLV in a node
  # attribute set builds and encodes, and section 5.3.2.2's "The MPLS
  # Protocol Mask TLV MUST NOT be included in NLRIs with the other
  # Protocol-IDs listed in Table 2" is a sender's rule that nothing here
  # enforces.
  #
  # **`Float32_tlv` stays here rather than joining the four shared bases
  # in `link_state_tlv.rb`**, and the line part 5b-i drew is what
  # decides it: shared means more than one of the RFC's tables, not
  # merely more than one class. Only Table 8 has floats. Move it if
  # Table 10 or another document's TLVs ever want one.
  #
  # **Nothing validates.** Any width, any flag bit, any value.
  class Link_state

    class Tlv

      # A TLV whose whole value is one 32-bit IEEE floating point
      # number, in a 4 + 4 octet TLV. Table 8 has two, 1089 and 1090,
      # and TLV 1091 is eight of them in a row.
      #
      # **The units are bytes per second and not bits**, which RFC 5305
      # puts as "The units are bytes (not bits!) per second" in each of
      # sections 3.4, 3.5 and 3.6. The same trap and the same
      # exclamation mark as RFC 10005 section 2 for the Link Bandwidth
      # extended community, which `extended_community.rb` records.
      #
      # Ruby's `pack('g')` is big-endian single precision, which is what
      # "32 bits in IEEE floating point format" asks for.
      #
      # **A NaN with a payload does not survive the round trip**, and
      # that is Ruby rather than this class: `unpack1('g')` on
      # `7fc00001` gives NaN and packing that back gives `7fc00000`.
      # Measured on 2026-11-01, where 0, -0, both infinities and the
      # canonical NaN are all exact. So such a value fails
      # `Tlv.factory`'s encode-matches rule and is kept as a
      # `Tlv::Unknown`, which replays it. That is the rule working
      # rather than a loss: the octets come back either way.
      class Float32_tlv < Tlv

        WIDTH = 4

        attr_reader :value

        # new(1_250_000.0), new(1_250_000), the wire value octets, this
        # class's own hash, or another instance.
        def initialize(*args)
          @value = 0.0
          if args.size == 1 and args[0].is_a?(String) and args[0].is_packed?
            parse(args[0])
          elsif args.size == 1 and args[0].is_a?(self.class)
            self.declared_len = args[0].declared_len
            @value = args[0].value
          elsif args.size == 1 and args[0].is_a?(Hash)
            from_hash(args[0])
          elsif args.size == 1 and args[0].is_a?(Numeric)
            @value = args[0].to_f
          elsif args.empty?
            # Zero, which no section blesses and which builds.
          else
            raise ArgumentError, "invalid argument: #{args.inspect}"
          end
          self
        end

        def parse(s)
          @value = s.slice!(0, WIDTH).unpack1('g')
          self
        end

        def encode_value
          [@value].pack('g')
        end

        def self.label
          self::LABEL
        end

        def value_hash
          @value
        end

        def to_s
          "#{self.class.label} #{@value} Bps"
        end

        private

        def from_hash(h)
          read_declared_len(h)
          h = self.class.unwrap(h)
          @value = h.is_a?(Hash) ? 0.0 : h.to_f
        end

      end

      # TLV 1030 and 1031, section 5.3.2.1, the **remote** auxiliary
      # Router-IDs. Table 8 cites RFC 5305 section 4.3 for the IPv4 one
      # and RFC 6119 section 4.1 for the IPv6 one, which are the same
      # two citations Table 6 gives for 1028 and 1029, so the widths are
      # 4 and 16.
      #
      # "If there is more than one auxiliary Router-ID of a given type,
      # then multiple TLVs are used to encode them", so these repeat and
      # section 5.1's Length and Value tiebreakers order them.
      class Ipv4_remote_router_id < Addr_tlv
        TYPE = 1030
        HASH_KEY = :ipv4_remote_router_id
        WIDTH = 4
        LABEL = 'Remote IPv4 Router-ID'
      end
      register Ipv4_remote_router_id

      class Ipv6_remote_router_id < Addr_tlv
        TYPE = 1031
        HASH_KEY = :ipv6_remote_router_id
        WIDTH = 16
        LABEL = 'Remote IPv6 Router-ID'
      end
      register Ipv6_remote_router_id

      # TLV 1088, the Administrative group, which Table 8 cites to RFC
      # 5305 **section 3.1**. That section gives the width and the bit
      # numbering and nothing else: "The administrative group sub-TLV
      # contains a 4-octet bit mask assigned by the network
      # administrator. Each set bit corresponds to one administrative
      # group assigned to the interface. By convention, the least
      # significant bit is referred to as 'group 0', and the most
      # significant bit is referred to as 'group 31'."
      #
      # **So group N is bit N counting from the bottom**, which is the
      # reverse of how every other bitfield in this family numbers its
      # bits, where bit 0 is the most significant. Read the sentence
      # rather than carrying the convention across: the mask for group 0
      # is 0x00000001.
      #
      # It is a bit mask and not a number, so `groups` reads it, and no
      # bit is reserved: all 32 are administrative groups. The value is
      # still an Integer, so `Opaque32` is the shape.
      class Administrative_group < Opaque32

        TYPE = 1088
        HASH_KEY = :administrative_group
        LABEL = 'Admin group'

        GROUPS = (0..31)

        # The group numbers whose bits are set, lowest first.
        def groups
          GROUPS.select { |n| !(@value & (1 << n)).zero? }
        end

        def group?(n)
          !(@value & (1 << n)).zero?
        end

        def to_s
          g = groups
          s = "#{LABEL} "
          s + (g.empty? ? 'none' : g.join(','))
        end

      end
      register Administrative_group

      # TLV 1089, Maximum link bandwidth, RFC 5305 section 3.4: "This
      # sub-TLV contains the maximum bandwidth that can be used on this
      # link in this direction (from the system originating the LSP to
      # its neighbors)." One IEEE float, 4 octets.
      class Maximum_link_bandwidth < Float32_tlv
        TYPE = 1089
        HASH_KEY = :maximum_link_bandwidth
        LABEL = 'Max bandwidth'
      end
      register Maximum_link_bandwidth

      # TLV 1090, Maximum reservable link bandwidth, RFC 5305 section
      # 3.5. One IEEE float, 4 octets, and the section notes it may
      # exceed the link's own bandwidth: "Note that for oversubscription
      # purposes, this can be greater than the bandwidth of the link."
      class Max_reservable_link_bandwidth < Float32_tlv
        TYPE = 1090
        HASH_KEY = :max_reservable_link_bandwidth
        LABEL = 'Max reservable bandwidth'
      end
      register Max_reservable_link_bandwidth

      # TLV 1091, Unreserved bandwidth, RFC 5305 section 3.6, and **the
      # one width in Table 8 that memory gets wrong**: it is 32 octets
      # and not 4. "Because of the need for priority and preemption,
      # each head end needs to know the amount of reserved bandwidth at
      # each priority level. Thus, this sub-TLV contains eight 32-bit
      # IEEE floating point numbers."
      #
      # The order is stated rather than left to a reader: "The values
      # correspond to the bandwidth that can be reserved with a setup
      # priority of 0 through 7, arranged in increasing order with
      # priority 0 occurring at the start of the sub-TLV, and priority 7
      # at the end of the sub-TLV."
      #
      # **A list of other than eight builds and replays**, which is both
      # what Conventions asks for and what section 8.2.2 asks for from
      # the other side: it names "whether the length of a fixed-length
      # TLV is correct" among the semantic validations not to perform.
      # So a 28-octet value parses as seven priorities and encodes back
      # to 28 octets rather than being kept as a `Tlv::Unknown`.
      class Unreserved_bandwidth < Tlv

        TYPE = 1091
        HASH_KEY = :unreserved_bandwidth
        LABEL = 'Unreserved bandwidth'

        # Section 3.6's eight, read by `full?` so the number is not a
        # constant nothing checks. **There is no WIDTH beside it**: the
        # 4 octets of an element are what `pack('g*')` is, and a
        # constant repeating that is a second statement of one fact.
        # Sabotage found both: changing a `WIDTH = 4` here to 2 passed
        # the whole suite, because nothing read it.
        PRIORITIES = 8

        attr_reader :values

        # new(1.0, 2.0, ...) or new([1.0, 2.0, ...]), the wire value
        # octets, this class's own hash, or another instance.
        def initialize(*args)
          @values = []
          args = args[0] if args.size == 1 and args[0].is_a?(Array)
          if args.size == 1 and args[0].is_a?(String) and args[0].is_packed?
            parse(args[0])
          elsif args.size == 1 and args[0].is_a?(self.class)
            self.declared_len = args[0].declared_len
            @values = args[0].values.dup
          elsif args.size == 1 and args[0].is_a?(Hash)
            from_hash(args[0])
          elsif args.all? { |a| a.is_a?(Numeric) }
            # An empty list lands here, which is a zero-length value,
            # and section 5.1 permits one.
            @values = args.collect { |a| a.to_f }
          else
            raise ArgumentError, "invalid argument: #{args.inspect}, " \
                                 'expected bandwidths, a list or a hash'
          end
          self
        end

        # Each whole group, which `unpack('g*')` takes and which leaves
        # a trailing partial one behind. So a value that is not a
        # multiple of 4 loses the remainder, which then fails the
        # encode-matches rule and is kept as a `Tlv::Unknown`.
        def parse(s)
          @values = s.slice!(0, s.size).unpack('g*')
          self
        end

        def encode_value
          @values.pack('g*')
        end

        # The bandwidth reservable at one setup priority, 0 to 7, or nil
        # where the value is too short to carry it.
        def at(priority)
          @values[priority]
        end

        # True for the eight RFC 5305 section 3.6 describes. False is
        # not an error: section 8.2.2 says not to check whether a
        # fixed-length TLV's length is correct.
        def full?
          @values.size == PRIORITIES
        end

        def value_hash
          @values
        end

        def to_s
          "#{LABEL} #{@values.join(',')} Bps"
        end

        private

        def from_hash(h)
          read_declared_len(h)
          h = self.class.unwrap(h)
          @values = h.is_a?(Hash) ? [] : [*h].collect { |a| a.to_f }
        end

      end
      register Unreserved_bandwidth

      # TLV 1092, section 5.3.2.3, one of the six rows whose width RFC
      # 9552 does give in its own text: "The TE Default Metric TLV
      # carries the Traffic Engineering metric for this link. The length
      # of this TLV is fixed at 4 octets. If a source protocol uses a
      # metric width of fewer than 32 bits, then the high-order bits of
      # this field MUST be padded with zero."
      #
      # So the padding rule is the encoder's and costs no code: a
      # 32-bit unsigned integer written big-endian has its high-order
      # bits zero whenever the value is small. **Do not read it as a
      # reserved field**: every bit is the metric, there is nothing to
      # keep and echo, and a test asserts the padding rather than
      # leaving a rule that holds by accident of implementation.
      class Te_default_metric < Opaque32
        TYPE = 1092
        HASH_KEY = :te_default_metric
        LABEL = 'TE metric'
      end
      register Te_default_metric

      # TLV 1093, Link Protection Type, which Table 8 cites to RFC 5307
      # section 1.2. **Two octets**, which is the other width memory
      # gets wrong here: a protection capability bit vector then one
      # octet the section disposes of in a sentence, "The second octet
      # SHOULD be set to zero by the sender, and SHOULD be ignored by
      # the receiver."
      #
      # That is the keep-and-echo rule Conventions records, so the
      # second octet is kept and written back, and so are the two bits
      # of the first octet that RFC 5307's own list names only as
      # "Reserved". `DEFINED_BITS` is 0x3f for that reason and the hash
      # carries `{:bits => n}`, both octets, only when something outside
      # the six named bits arrived set.
      #
      # One rule of the section is a receiver's and is not here: "The
      # Link Protection Type sub-TLV MUST NOT occur more than once
      # within the extended IS reachability TLV", where a receiver
      # "SHOULD ignore all these sub-TLVs". Nothing refuses a repeat,
      # and whether that reaches `validation.rb` is part 6's question,
      # narrowed by section 8.2.2.
      class Link_protection_type < Tlv

        TYPE = 1093
        HASH_KEY = :link_protection_type
        LABEL = 'Link protection'

        WIDTH = 2

        # RFC 5307 section 1.2, the first octet's bit vector. Its own
        # hex values, so a reader can check the list against the
        # section.
        EXTRA_TRAFFIC   = 0x01
        UNPROTECTED     = 0x02
        SHARED          = 0x04
        DEDICATED_1_1   = 0x08
        DEDICATED_1_PLUS_1 = 0x10
        ENHANCED        = 0x20

        # High to low, so a dump reads as the section's list does.
        BITS = {
          :enhanced => ENHANCED,
          :dedicated_1_plus_1 => DEDICATED_1_PLUS_1,
          :dedicated_1_1 => DEDICATED_1_1,
          :shared => SHARED,
          :unprotected => UNPROTECTED,
          :extra_traffic => EXTRA_TRAFFIC,
        }.freeze

        DEFINED_BITS = BITS.values.inject(0) { |a, b| a | b }

        BITS_KEY = :bits

        attr_reader :flags, :reserved

        def self.bits_entry?(h)
          h.is_a?(Hash) and h.has_key?(BITS_KEY)
        end

        # new, new(:shared), new([:shared, :enhanced]), new(0x24) for
        # the capability octet alone, new([:shared, {:bits => 0x24ff}])
        # for this class's own hash, the wire value octets, or another
        # instance.
        def initialize(*args)
          @flags, @reserved = 0, 0
          args = args[0] if args.size == 1 and args[0].is_a?(Array)
          if args.size == 1 and args[0].is_a?(String) and args[0].is_packed?
            parse(args[0])
          elsif args.size == 1 and args[0].is_a?(self.class)
            self.declared_len = args[0].declared_len
            @flags, @reserved = args[0].flags, args[0].reserved
          elsif args.size == 1 and args[0].is_a?(Hash) and
                !self.class.bits_entry?(args[0])
            from_hash(args[0])
          elsif args.size == 1 and args[0].is_a?(Integer)
            refuse_a_value_the_field_cannot_hold(args[0], 0xff)
            @flags = args[0]
          elsif args.all? { |a| a.is_a?(Symbol) or self.class.bits_entry?(a) }
            args.each { |a| set_one(a) }
          else
            raise ArgumentError, "invalid argument: #{args.inspect}, " \
                                 'expected bit names, an octet or a hash'
          end
          self
        end

        def parse(s)
          unless s.size == WIDTH
            raise ArgumentError,
              "#{self.class} is #{WIDTH} octets and this value is #{s.size}"
          end
          @flags, @reserved = s.slice!(0, WIDTH).unpack('CC')
          self
        end

        def encode_value
          [@flags, @reserved].pack('CC')
        end

        def set?(name)
          !(@flags & BITS.fetch(name)).zero?
        end

        def names
          BITS.keys.select { |n| set?(n) }.reverse
        end

        # The whole two octets, which is what the hash carries when
        # anything outside the six named bits is set.
        def bits
          (@flags << 8) | @reserved
        end

        # The bits of the first octet outside RFC 5307's six, and the
        # whole second octet, which the section reserves entirely.
        def undefined_bits
          bits & ~(DEFINED_BITS << 8) & 0xffff
        end

        def undefined_bits?
          !undefined_bits.zero?
        end

        def value_hash
          h = names
          h += [{ BITS_KEY => bits }] if undefined_bits?
          h
        end

        def to_s
          s = "#{LABEL} "
          s += names.empty? ? 'none' : names.join(',')
          s += format(', undefined bits 0x%04x', undefined_bits) if
            undefined_bits?
          s
        end

        private

        def set_one(arg)
          if self.class.bits_entry?(arg)
            v = arg[BITS_KEY].to_i
            refuse_a_value_the_field_cannot_hold(v, 0xffff)
            @flags, @reserved = v >> 8, v & 0xff
          else
            @flags |= BITS.fetch(arg) do
              raise ArgumentError, "unknown protection type #{arg.inspect}, " \
                                   "have #{BITS.keys.join(', ')}"
            end
          end
        end

        def from_hash(h)
          read_declared_len(h)
          h = self.class.unwrap(h)
          [*h].each { |a| set_one(a) }
        end

        def refuse_a_value_the_field_cannot_hold(v, max)
          return if v >= 0 and v <= max
          raise ArgumentError,
            "#{self.class} cannot hold #{v}, max #{max}"
        end

      end
      register Link_protection_type

      # TLV 1094, section 5.3.2.2: "The MPLS Protocol Mask TLV carries a
      # bitmask describing which MPLS signaling protocols are enabled.
      # The length of this TLV is 1. The value is a bit array of 8
      # flags, where each bit represents an MPLS Protocol capability."
      #
      # Figure 19 is `|L|R|  Reserved |`, so L is the most significant
      # bit and the low six are reserved, which is this family's own
      # numbering and the opposite of TLV 1088's. Table 9 names the two:
      # L is LDP, RFC 5036, and R is RSVP-TE, RFC 3209.
      #
      # The section states the keep-and-echo rule twice over, once as
      # "the reserved bits MUST be set to zero and SHOULD be ignored on
      # receipt" and once as "The bits that are not defined MUST be set
      # to 0 by the originator and MUST be ignored by the receiver".
      class Mpls_protocol_mask < Tlv

        TYPE = 1094
        HASH_KEY = :mpls_protocol_mask
        LABEL = 'MPLS protocols'

        WIDTH = 1
        MAX_VALUE = 0xff

        LDP     = 0x80   # 'L', RFC 5036
        RSVP_TE = 0x40   # 'R', RFC 3209

        BITS = { :ldp => LDP, :rsvp_te => RSVP_TE }.freeze

        DEFINED_BITS = BITS.values.inject(0) { |a, b| a | b }

        BITS_KEY = :bits

        attr_reader :value

        def self.bits_entry?(h)
          h.is_a?(Hash) and h.has_key?(BITS_KEY)
        end

        # new, new(:ldp), new([:ldp, :rsvp_te]), new(0xc0), this class's
        # own hash, the wire value octet, or another instance.
        def initialize(*args)
          @value = 0
          args = args[0] if args.size == 1 and args[0].is_a?(Array)
          if args.size == 1 and args[0].is_a?(String) and args[0].is_packed?
            parse(args[0])
          elsif args.size == 1 and args[0].is_a?(self.class)
            self.declared_len = args[0].declared_len
            @value = args[0].value
          elsif args.size == 1 and args[0].is_a?(Hash) and
                !self.class.bits_entry?(args[0])
            from_hash(args[0])
          elsif args.size == 1 and args[0].is_a?(Integer)
            refuse_a_value_the_octet_cannot_hold(args[0])
            @value = args[0]
          elsif args.all? { |a| a.is_a?(Symbol) or self.class.bits_entry?(a) }
            args.each { |a| set_one(a) }
          else
            raise ArgumentError, "invalid argument: #{args.inspect}, " \
                                 'expected bit names, an octet or a hash'
          end
          self
        end

        def parse(s)
          unless s.size == WIDTH
            raise ArgumentError,
              "#{self.class} is #{WIDTH} octet and this value is #{s.size}"
          end
          @value = s.slice!(0, WIDTH).unpack1('C').to_i
          self
        end

        def encode_value
          [@value].pack('C')
        end

        def set?(name)
          !(@value & BITS.fetch(name)).zero?
        end

        def ldp? ; set?(:ldp) ; end
        def rsvp_te? ; set?(:rsvp_te) ; end

        def names
          BITS.keys.select { |n| set?(n) }
        end

        def undefined_bits
          @value & ~DEFINED_BITS & 0xff
        end

        def undefined_bits?
          !undefined_bits.zero?
        end

        def value_hash
          h = names
          h += [{ BITS_KEY => @value }] if undefined_bits?
          h
        end

        def to_s
          s = "#{LABEL} "
          s += names.empty? ? 'none' : names.join(',')
          s += format(', undefined bits %06b', undefined_bits) if
            undefined_bits?
          s
        end

        private

        def set_one(arg)
          if self.class.bits_entry?(arg)
            v = arg[BITS_KEY].to_i
            refuse_a_value_the_octet_cannot_hold(v)
            @value = v
          else
            @value |= BITS.fetch(arg) do
              raise ArgumentError, "unknown MPLS protocol #{arg.inspect}, " \
                                   "have #{BITS.keys.join(', ')}"
            end
          end
        end

        def from_hash(h)
          read_declared_len(h)
          h = self.class.unwrap(h)
          [*h].each { |a| set_one(a) }
        end

        def refuse_a_value_the_octet_cannot_hold(v)
          return if v >= 0 and v <= MAX_VALUE
          raise ArgumentError,
            "MPLS Protocol Mask is one octet and #{v} does not fit it"
        end

      end
      register Mpls_protocol_mask

      # TLV 1095, section 5.3.2.4, and **the only variable-width TLV in
      # this family whose widths are an enumeration rather than a
      # multiple**: "The length of this TLV is variable, depending on
      # the metric width of the underlying protocol. IS-IS small metrics
      # are 6 bits in size but are encoded in a 1-octet field;
      # therefore, the two most significant bits of the field MUST be
      # set to 0 by the originator and MUST be ignored by the receiver.
      # OSPF link metrics have a length of 2 octets. IS-IS wide metrics
      # have a length of 3 octets."
      #
      # So 1, 2 and 3 are the widths, and **the width is a fact about
      # the source IGP rather than about the value**: a metric of 10 is
      # legal in all three. So it is carried, and the field value form
      # takes it. `new(10)` defaults to 3, the only width that can hold
      # any 24-bit metric, and a caller wanting the small or OSPF form
      # says which. Inferring the width from the magnitude would be
      # inventing a rule the section does not have.
      #
      # **The 1-octet form has two reserved bits and the others have
      # none**, so `undefined_bits` answers 0 above width 1 however the
      # value's own high bits read. `DEFINED_BITS` is 0x3f and applies
      # to that form alone.
      class Igp_metric < Tlv

        TYPE = 1095
        HASH_KEY = :igp_metric
        LABEL = 'IGP metric'

        WIDTHS = [1, 2, 3].freeze
        DEFAULT_WIDTH = 3

        # The 1-octet form only: "IS-IS small metrics are 6 bits in
        # size but are encoded in a 1-octet field".
        DEFINED_BITS = 0x3f

        BITS_KEY = :bits

        attr_reader :metric, :width

        # new(10), new(10, 1), this class's own hash, the wire value
        # octets, or another instance.
        def initialize(*args)
          @metric, @width = 0, DEFAULT_WIDTH
          if args.size == 1 and args[0].is_a?(String) and args[0].is_packed?
            parse(args[0])
          elsif args.size == 1 and args[0].is_a?(self.class)
            self.declared_len = args[0].declared_len
            @metric, @width = args[0].metric, args[0].width
          elsif args.size == 1 and args[0].is_a?(Hash)
            from_hash(args[0])
          elsif (1..2).include?(args.size) and args[0].is_a?(Integer)
            @metric = args[0]
            @width = args[1].to_i if args.size == 2
            refuse_a_metric_the_field_cannot_hold
          elsif args.empty?
            # Metric 0 at the default width, which builds.
          else
            raise ArgumentError, "invalid argument: #{args.inspect}, " \
                                 'expected (metric), (metric, width) or a hash'
          end
          self
        end

        # **The width comes from the octets and is kept**, so a value of
        # a width the section does not list still parses, replays and
        # says what it was. Only a value of no octets at all cannot be
        # read, and it is refused so `Tlv.factory` keeps it whole.
        def parse(s)
          if s.empty?
            raise ArgumentError, "#{self.class} needs at least one octet"
          end
          @width = s.size
          @metric = s.slice!(0, @width).unpack1('H*').to_i(16)
          self
        end

        def encode_value
          [format('%0*x', @width * 2, @metric)].pack('H*')
        end

        # True for a width the section lists.
        def known_width?
          WIDTHS.include?(@width)
        end

        # The two reserved bits of the 1-octet form, and 0 at any other
        # width, where the section reserves nothing.
        def undefined_bits
          return 0 unless @width == 1
          @metric & ~DEFINED_BITS & 0xff
        end

        def undefined_bits?
          !undefined_bits.zero?
        end

        # The metric and its width, and the whole octet behind them only
        # when a reserved bit of the 1-octet form arrived set.
        def value_hash
          h = { :metric => @metric, :width => @width }
          h = h.merge(BITS_KEY => @metric) if undefined_bits?
          h
        end

        def to_s
          s = "#{LABEL} #{@metric} (#{@width} octet"
          s += 's' unless @width == 1
          s += ')'
          s += format(', undefined bits %02b', undefined_bits >> 6) if
            undefined_bits?
          s
        end

        private

        def from_hash(h)
          read_declared_len(h)
          h = self.class.unwrap(h)
          return unless h.is_a?(Hash)
          @width = h[:width].to_i if h[:width]
          @metric = (h[BITS_KEY] || h[:metric]).to_i
          refuse_a_metric_the_field_cannot_hold
        end

        # The kind of refusal Conventions allows: a metric too wide for
        # the width asked for cannot be written at all. The width itself
        # is not checked against WIDTHS, because a width the section
        # does not list is a value no RFC describes and the library has
        # to be able to send one.
        def refuse_a_metric_the_field_cannot_hold
          if @width < 1
            raise ArgumentError, "#{self.class} width #{@width} is not a width"
          end
          max = (1 << (@width * 8)) - 1
          return if @metric >= 0 and @metric <= max
          raise ArgumentError,
            "IGP Metric #{@metric} does not fit #{@width} octets, max #{max}"
        end

      end
      register Igp_metric

      # TLV 1096, section 5.3.2.5: "The Shared Risk Link Group (SRLG)
      # TLV carries the Shared Risk Link Group information (see Section
      # 2.3 ("Shared Risk Link Group Information") of [RFC4202]). It
      # contains a data structure consisting of a (variable) list of
      # SRLG values, where each element in the list has 4 octets ... The
      # length of this TLV is 4 * (number of SRLG values)."
      #
      # **One TLV carries both families**, which the section says
      # outright and which is worth knowing because IS-IS does not: "In
      # IS-IS, the SRLG information is carried in two different TLVs:
      # the GMPLS-SRLG TLV (for IPv4) (Type 138) defined in [RFC5307]
      # and the IPv6 SRLG TLV (Type 139) defined in [RFC6119]. Both IPv4
      # and IPv6 SRLG information is carried in a single TLV." So
      # nothing here is per family and there is no second class.
      class Srlg < Tlv

        TYPE = 1096
        HASH_KEY = :srlg
        LABEL = 'SRLG'

        # **No WIDTH constant**, for the reason `Unreserved_bandwidth`
        # records: section 5.3.2.5's "each element in the list has 4
        # octets" is what `pack('N*')` is, and a constant beside it is
        # a second statement of one fact that a sabotage proved nothing
        # read.
        attr_reader :values

        # new(100, 200) or new([100, 200]), the wire value octets, this
        # class's own hash, or another instance.
        def initialize(*args)
          @values = []
          args = args[0] if args.size == 1 and args[0].is_a?(Array)
          if args.size == 1 and args[0].is_a?(String) and args[0].is_packed?
            parse(args[0])
          elsif args.size == 1 and args[0].is_a?(self.class)
            self.declared_len = args[0].declared_len
            @values = args[0].values.dup
          elsif args.size == 1 and args[0].is_a?(Hash)
            from_hash(args[0])
          elsif args.all? { |a| a.is_a?(Integer) }
            # An empty list lands here, which is the zero-length value
            # the section's own arithmetic produces for no SRLGs.
            @values = args
          else
            raise ArgumentError, "invalid argument: #{args.inspect}, " \
                                 'expected SRLG values, a list or a hash'
          end
          self
        end

        # `unpack('N*')` takes each whole 4-octet group and leaves a
        # trailing partial one, so a value that is not a multiple of 4
        # cannot reproduce itself and is kept as a `Tlv::Unknown`.
        def parse(s)
          @values = s.slice!(0, s.size).unpack('N*')
          self
        end

        def encode_value
          @values.pack('N*')
        end

        def value_hash
          @values
        end

        def to_s
          "#{LABEL} #{@values.empty? ? 'none' : @values.join(',')}"
        end

        private

        def from_hash(h)
          read_declared_len(h)
          h = self.class.unwrap(h)
          @values = h.is_a?(Hash) ? [] : [*h].collect { |a| a.to_i }
        end

      end
      register Srlg

      # TLV 1097, section 5.3.2.6, the Opaque Link Attribute, which is
      # section 5.3.1.5's envelope one table over: "an envelope that
      # transparently carries optional Link Attribute TLVs advertised by
      # a router". Transparently, so nothing here reads inside it, for
      # the reason `Opaque_node_attribute` records.
      class Opaque_link_attribute < Opaque_tlv
        TYPE = 1097
        HASH_KEY = :opaque_link_attribute
        LABEL = 'Opaque link attribute'
      end
      register Opaque_link_attribute

      # TLV 1098, section 5.3.2.7, the Link Name, which is section
      # 5.3.1.3's Node Name one table over: the same three paragraphs
      # with "router link" for "router node", down to the 7-bit ASCII
      # rule and the 255 whose scope neither section settles. So it is
      # `Text_tlv` and nothing else, which is what part 5b-i lifted that
      # base out of `Node_name` for.
      #
      # One sentence is its own: "How a router derives and injects link
      # names is outside of the scope of this document."
      class Link_name < Text_tlv
        TYPE = 1098
        HASH_KEY = :link_name
        LABEL = 'Link name'
      end
      register Link_name

    end

  end

end

load "../../test/unit/nlris/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
