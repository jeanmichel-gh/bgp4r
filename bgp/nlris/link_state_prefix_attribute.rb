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

  # **Table 10 of RFC 9552, the prefix attribute TLVs of section 5.3.3**,
  # 1152 to 1157, all six of them, which go in the BGP-LS Attribute
  # beside a Prefix NLRI of type 3 or 4. Section 5.3.3: "Prefixes are
  # learned from the IGP topology (IS-IS or OSPF) with a set of IGP
  # attributes (such as metric, route tags, etc.) that are advertised in
  # the BGP-LS Attribute with Prefix NLRI types 3 and 4."
  #
  # **Table 10 has a Length column**, unlike Table 4 and Table 8, so
  # five of the six widths are the RFC's own and the sixth is where the
  # table and the section disagree. See `Ospf_forwarding_address`.
  #
  # These are path attribute content and not NLRI content, so nothing
  # here goes through either NLRI dispatch gate: the attribute that
  # carries them is code 29 and reaches the library through
  # `Attr.register`, in `bgp/path_attributes/link_state_attribute.rb`.
  # They live here with the rest of the family because **one flat
  # registry means one class family**, which is IANA's doing: the
  # registry is "BGP-LS NLRI and Attribute TLVs", one space for TLVs and
  # sub-TLVs alike, so a number means the same thing wherever it
  # appears. `docs/bgp-ls.md` section 10c is the guide.
  class Link_state

    class Tlv

      # TLV 1152, section 5.3.3.1: "The IGP Flags TLV contains one octet
      # of IS-IS and OSPF flags and bits originally assigned to the
      # prefix."
      #
      # Figure 25 is `|D|N|L|P|       |`, so D is the most significant
      # bit and the low nibble is reserved, which is this family's own
      # numbering, as `Node_flag_bits` and `Mpls_protocol_mask` are, and
      # the opposite of TLV 1088's.
      #
      # **Table 11 names the four and gives no bit numbers**, where
      # Table 7 does for the node flags, so the figure is the only
      # statement of the placement there is. Worth saying because the
      # node flags needed erratum 7789 to settle a figure against a
      # table: here nothing cross-checks, and the two agree in order.
      # The names and references are Table 11's: D is the IS-IS Up/Down
      # Bit, RFC 5305; N the OSPF "no unicast" Bit, L the OSPF "local
      # address" Bit and P the OSPF "propagate NSSA" Bit, all RFC 5340.
      #
      # Section 5.3.3.1 asks for keep and echo outright: "The bits that
      # are not defined MUST be set to 0 by the originator and MUST be
      # ignored by the receiver."
      class Igp_flags < Tlv

        TYPE = 1152
        HASH_KEY = :igp_flags
        LABEL = 'IGP flags'

        WIDTH = 1
        MAX_VALUE = 0xff

        DOWN           = 0x80   # 'D', RFC 5305
        NO_UNICAST     = 0x40   # 'N', RFC 5340
        LOCAL_ADDRESS  = 0x20   # 'L', RFC 5340
        PROPAGATE_NSSA = 0x10   # 'P', RFC 5340

        BITS = { :down           => DOWN,
                 :no_unicast     => NO_UNICAST,
                 :local_address  => LOCAL_ADDRESS,
                 :propagate_nssa => PROPAGATE_NSSA }.freeze

        DEFINED_BITS = BITS.values.inject(0) { |a, b| a | b }

        BITS_KEY = :bits

        attr_reader :value

        def self.bits_entry?(h)
          h.is_a?(Hash) and h.has_key?(BITS_KEY)
        end

        # new, new(:down), new([:down, :no_unicast]), new(0xc0), this
        # class's own hash, the wire value octet, or another instance.
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

        def down? ; set?(:down) ; end
        def no_unicast? ; set?(:no_unicast) ; end
        def local_address? ; set?(:local_address) ; end
        def propagate_nssa? ; set?(:propagate_nssa) ; end

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
          s += format(', undefined bits %04b', undefined_bits) if
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
              raise ArgumentError, "unknown IGP flag #{arg.inspect}, " \
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
            "IGP Flags is one octet and #{v} does not fit it"
        end

      end
      register Igp_flags

      # TLV 1153, section 5.3.3.2: "The IGP Route Tag TLV carries
      # original IGP Tags (IS-IS [RFC5130] or OSPF) of the prefix", and
      # "The length is a multiple of 4. The Value field contains one or
      # more Route Tags as learned in the IGP topology." Table 10 gives
      # 4*n and cites RFC 5130.
      #
      # So it is `Int_list_tlv` with a 4-octet element, which is the
      # SRLG's shape and the reason that base sits with the framing.
      class Igp_route_tag < Int_list_tlv
        TYPE = 1153
        HASH_KEY = :igp_route_tag
        LABEL = 'IGP route tag'
        PACK = 'N*'
      end
      register Igp_route_tag

      # TLV 1154, section 5.3.3.3: "The IGP Extended Route Tag TLV
      # carries IS-IS Extended Route Tags of the prefix [RFC5130]", and
      # "The length is a multiple of 8. The Extended Route Tag field
      # contains one or more Extended Route Tags as learned in the IGP
      # topology." Table 10 gives 8*n and cites RFC 5130.
      #
      # **The only 64-bit field in the family**, so it is the one place
      # `'Q>*'` appears, which is `Int_list_tlv`'s whole reason for
      # taking the pack code from its subclass rather than fixing one.
      # Its elements are the 64-bit tags of RFC 5130 section 2, where
      # 1153's are the 32-bit tags of section 1; the section calls the
      # pair out as distinct TLVs and so does Table 10.
      class Igp_extended_route_tag < Int_list_tlv
        TYPE = 1154
        HASH_KEY = :igp_extended_route_tag
        LABEL = 'IGP extended route tag'
        PACK = 'Q>*'
      end
      register Igp_extended_route_tag

      # TLV 1155, section 5.3.3.4: "The Prefix Metric TLV is an optional
      # attribute and may only appear once. If present, it carries the
      # metric of the prefix as known in the IGP topology, as described
      # in Section 4 of [RFC5305] (and therefore represents the
      # reachability cost to the prefix). If not present, it means that
      # the prefix is advertised without any reachability." The section
      # states the width itself, "The length is 4", and Table 10 agrees.
      #
      # **An absent TLV means something here, which no other TLV in this
      # family does**, and it is the one thing to know before reading a
      # prefix attribute set: no Prefix Metric is not a missing field but
      # a prefix advertised with no reachability. Nothing in bgp4r acts
      # on that, since it never computes reachability, and section 8.2.2
      # forbids reporting a mandatory TLV absent in any case.
      #
      # The "may only appear once" is a sender's rule that bgp4r does
      # not enforce, per Conventions: the attribute's hash is a list, so
      # two of these build and encode.
      class Prefix_metric < Opaque32
        TYPE = 1155
        HASH_KEY = :prefix_metric
        LABEL = 'Prefix metric'
      end
      register Prefix_metric

      # TLV 1156, section 5.3.3.5: "The OSPF Forwarding Address TLV
      # [RFC2328] [RFC5340] carries the OSPF forwarding address as known
      # in the original OSPF advertisement. The forwarding address can
      # be either IPv4 or IPv6."
      #
      # **Table 10 says the length is 4 and section 5.3.3.5 says it is
      # "4 for an IPv4 forwarding address and 16 for an IPv6 forwarding
      # address", with Figure 29 printing "Forwarding Address
      # (variable)". So the prose and the figure agree with each other
      # against the table, and this follows them**: a 4-octet value is
      # an IPv4 address and a 16-octet one an IPv6 address. There is no
      # erratum on it, checked on 2026-11-01, where the two verified
      # ones are 7789 and 8766. Third self contradiction in this
      # document, after the Node Flag Bits figure and Table 8's missing
      # Length column.
      #
      # **It is `Addr_tlv`'s shape with a set of widths in place of one
      # number, and not a subclass of it.** Generalising `WIDTH` to a
      # set for one caller is the anticipation phase 1 of the breadth
      # plan warns against, and the two differ in more than the width
      # anyway: `Addr_tlv` with no arguments builds the all zeroes
      # address of its own width, which this class has no width to pick.
      # It is the fourth place in the library where a width alone says
      # which family a field is, after EVPN's IP Prefix route, EVPN
      # route type 2's optional Label2 and MCAST-VPN's Originating
      # Router.
      #
      # **A width that is neither 4 nor 16 is not one of these**, which
      # is `Addr_tlv`'s rule and right here for the same reason part 3
      # recorded there: the class is a claim about meaning. An
      # `Ospf_forwarding_address` holding eight octets and no readable
      # address would claim bgp4r read a forwarding address and found
      # none in it, which is a claim about something section 5.3.3.5
      # does not describe, where `Tlv::Unknown.new(1156, octets)` claims
      # only that these are the octets of TLV 1156. So `parse` refuses
      # it and `Tlv.factory` keeps it whole as a `Tlv::Unknown`, octets
      # and declared length intact.
      #
      # That is not the length check section 8.2.2 forbids. Nothing is
      # reported either way and no finding exists: the octets replay and
      # only the class differs, which is part 1's rule rather than a
      # verdict about the sender.
      class Ospf_forwarding_address < Tlv

        TYPE = 1156
        HASH_KEY = :ospf_forwarding_address
        LABEL = 'OSPF forwarding address'

        # The two widths section 5.3.3.5 gives, with the family each
        # one means.
        WIDTHS = { 4 => :ipv4, 16 => :ipv6 }.freeze

        attr_reader :address

        # new('10.0.0.1'), new('2001:db8::1'), new(an_IPAddr), the wire
        # value octets, this class's own hash, or another instance.
        #
        # **There is no empty form**, where `Addr_tlv` has one: with two
        # widths allowed there is no all zeroes address to default to
        # that would not be inventing a family the section leaves to the
        # value. `new('0.0.0.0')` is the explicit way to the zero IPv4
        # one, and `Tlv::Unknown.new(1156, '')` carries a zero-length
        # value, which section 5.1 permits outright.
        def initialize(*args)
          @address = nil
          if args.size == 1 and args[0].is_a?(String) and args[0].is_packed?
            parse(args[0])
          elsif args.size == 1 and args[0].is_a?(self.class)
            self.declared_len = args[0].declared_len
            @address = args[0].address
          elsif args.size == 1 and args[0].is_a?(Hash)
            from_hash(args[0])
          elsif args.size == 1
            @address = coerce(args[0])
          else
            raise ArgumentError, "invalid argument: #{args.inspect}, " \
                                 'expected an address, wire octets or a hash'
          end
          self
        end

        # **This width check is message-only, where `Addr_tlv`'s is load
        # bearing, and the difference is which widths each class
        # takes.** `IPAddr.new_ntoh` accepts exactly 4 octets and 16 and
        # answers `IPAddr::AddressFamilyError` for every other width,
        # measured on 2026-11-01, so for a class that takes both of
        # those there is no gap left to close: a sabotage removing this
        # check passed the whole suite, because IPAddr refuses the same
        # values one line later and `read_tlv` rescues either way.
        # `Addr_tlv` takes **one** of the two, so there IPAddr accepts a
        # width the class must not, which is the TLV 261 bug part 3
        # found.
        #
        # It stays for its message, which names both widths and the
        # `Tlv::Unknown` route where `AddressFamilyError` names neither
        # the TLV nor the widths wanted. A test reads the message, so
        # the check is not the dead kind part 5b-ii found twice.
        def parse(s)
          unless WIDTHS.has_key?(s.size)
            raise ArgumentError,
              "#{self.class} is #{WIDTHS.keys.join(' or ')} octets and " \
              "this value is #{s.size}"
          end
          @address = IPAddr.new_ntoh(s.slice!(0, s.size))
          self
        end

        def encode_value
          @address.hton
        end

        # :ipv4 or :ipv6, from the width, which is the only thing that
        # says which family section 5.3.3.5's value is.
        def family
          WIDTHS[@address.hton.size]
        end

        def value_hash
          @address.to_s
        end

        def to_s
          "#{LABEL} #{@address}"
        end

        private

        # An IPAddr or a presentation form, of either family, which is
        # the one way this differs from `Addr_tlv#coerce`: there one
        # family is refused because a 4-octet field cannot hold a
        # 16-octet address, and here the field holds both.
        #
        # **Its refusal cannot be reached and is kept anyway**, the way
        # `Fib`'s `:no_next_hop` branch and `Rt_constrain#origin_as`'s
        # length guard are: `IPAddr` has two families and `hton` answers
        # 4 octets or 16 for every value either constructor accepts, so
        # the width is one of this section's two by the time the check
        # runs. It stays because it is the sentence `Addr_tlv#coerce`
        # makes where it **is** reachable, and because a third family
        # in `IPAddr` would otherwise go in silently. `parse` is where
        # an off-width value really arrives, and it refuses there.
        def coerce(v)
          a = v.is_a?(IPAddr) ? v : IPAddr.new(v.to_s)
          unless WIDTHS.has_key?(a.hton.size)
            raise ArgumentError,
              "#{self.class} is #{WIDTHS.keys.join(' or ')} octets and " \
              "#{a} is #{a.hton.size}; for a value no RFC allows use " \
              "Link_state::Tlv::Unknown.new(#{self.class.type}, octets)"
          end
          a
        end

        def from_hash(h)
          read_declared_len(h)
          h = self.class.unwrap(h)
          @address = coerce(h)
        end

      end
      register Ospf_forwarding_address

      # TLV 1157, section 5.3.3.6, the Opaque Prefix Attribute, which is
      # section 5.3.1.5's and section 5.3.2.6's envelope one table over:
      # "an envelope that transparently carries optional Prefix
      # Attribute TLVs advertised by a router". Transparently, so
      # nothing here reads inside it, for the reason
      # `Opaque_node_attribute` records.
      #
      # Section 5.3.3.6 says more about what belongs inside it than its
      # two siblings do, and all of it binds an **originator**: with
      # OSPFv2 the TLV "MUST NOT be used to advertise information
      # carried using TLVs other than those in the OSPFv2 Extended
      # Prefix Opaque LSA [RFC7684]", and with OSPFv3 other than those
      # in four named LSAs of RFC 8362. Nothing here enforces either,
      # per Conventions, and neither is a receive side rule for part 6:
      # reading inside the envelope is what the section says not to do.
      class Opaque_prefix_attribute < Opaque_tlv
        TYPE = 1157
        HASH_KEY = :opaque_prefix_attribute
        LABEL = 'Opaque prefix attribute'
      end
      register Opaque_prefix_attribute

    end

  end

end
