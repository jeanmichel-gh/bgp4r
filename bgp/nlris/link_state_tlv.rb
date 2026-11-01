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

module BGP

  # The one TLV of RFC 9552, with its registry, its `Unknown`, the list
  # reader and the section 5.1 ordering rule. The NLRI that carries
  # them is in `link_state.rb`, which requires this file and reopens
  # this class, the way `evpn.rb` does for `evpn_route.rb`.
  #
  # `docs/bgp-ls.md` is the guide. Every section number here was read in
  # the RFC text on 2026-10-31. Nothing dispatches to this file yet.
  #
  # **One class for the whole family, because section 5.1 is one rule.**
  # "Information in the Link-State NLRIs and the BGP-LS Attribute is
  # encoded in Type/Length/Value triplets. The TLV format is shown in
  # Figure 4 and applies to both the NLRI and the BGP-LS Attribute
  # encodings." So a node descriptor, a link descriptor, a node
  # descriptor sub-TLV and an attribute TLV are all this shape, which is
  # what makes the framing the cheapest of the five families this plan
  # has done while the breadth is the dearest.
  #
  #    0                   1                   2                   3
  #    0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
  #   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  #   |              Type             |             Length            |
  #   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  #   //                        Value (variable)                     //
  #   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  #
  # Two octets each, and section 5.1 says what the Length counts and
  # what it does not: "The Length field defines the length of the value
  # portion in octets (thus, a TLV with no value portion would have a
  # length of zero). The TLV is not padded to 4-octet alignment." Both
  # halves of that are easy to get wrong from memory, since the
  # neighbouring IGP encodings do pad.
  #
  # **Keep and echo is mandated here, which inverts what flow spec
  # taught.** Section 5.1: "Unknown and unsupported types MUST be
  # preserved and propagated within both the NLRI and the BGP-LS
  # Attribute", and "The presence of unknown or unexpected TLVs MUST NOT
  # result in the NLRI or the BGP-LS Attribute being considered
  # malformed." RFC 8955 section 4.2 says the opposite for a flow spec
  # component type, in so many words. Each is its own RFC's instruction
  # and bgp4r follows each; do not carry one family's answer across.
  # Conventions' note that keep and echo is bgp4r's own ground still
  # holds, and here an RFC agrees with it outright.
  #
  # **Nothing validates.** Any type, any length, any value, in any
  # order, including a Length that disagrees with the octets that came
  # with it.
  class Link_state

    class Tlv

      # Section 5.1. Type and Length are two octets each, so the
      # framing is 4 and a value is at most 0xffff octets.
      FRAMING = 4
      MAX_LEN = 0xffff

      # The registry, type number to class. **Empty in part 1**, so
      # every TLV reads back as `Link_state::Tlv::Unknown` today, which
      # is the state `Mcast_vpn::ROUTES` and `Evpn::ROUTES` were each in
      # when their own first part landed.
      #
      # **A registry and not a `case`, which departs from the four
      # families before this one and is measured rather than assumed.**
      # Flow spec, EVPN, RT-constrain and MCAST-VPN each added one arm
      # to each of two `case` statements, and phase 1 of the breadth
      # plan records why a lookup was not worth building for that. The
      # numbers here are not those numbers: RFC 9552's own Table 18
      # defines **39** TLV code points, and IANA's "BGP-LS NLRI and
      # Attribute TLVs" registry had **139** assigned when it was read
      # on 2026-10-31, a minority of them this RFC's. This is
      # `Attr.register`'s shape one level down, which Conventions calls
      # the registry that already works.
      #
      # It is mutable on purpose: the TLV classes arrive in more than
      # one file, descriptors in parts 2 and 3 and attribute TLVs in
      # part 5, and a frozen literal here could not be extended by them
      # without editing this file every time.
      REGISTRY = {}

      # Hash key back to class, for the hash build path. `Unknown` is in
      # here and in no row of REGISTRY, which is the whole point of it:
      # no type number reaches it, and a hash that carries its key has
      # to build back. `Mcast_vpn::BY_KEY` records the same thing.
      BY_KEY = {}

      class << self

        def type
          self::TYPE
        end

        # The key this TLV takes in a hash, one per class.
        def hash_key
          self::HASH_KEY
        end

        # The one Hash a build may be handed that is this TLV's own
        # wrapped hash rather than its field hash. Here rather than in
        # each class because the EVPN work found what happens when one
        # of them forgets: `Multicast_flags` read the wrapped hash as a
        # field hash and built a community of zeros in silence.
        def unwrap(h)
          return h unless h.is_a?(Hash)
          h.has_key?(hash_key) ? h[hash_key] : h
        end

        # Add a TLV class to both lookups. Raises on a type or a key
        # already taken, because a second registration would shadow the
        # first and nothing else would say so.
        def register(klass)
          t, k = klass.type, klass.hash_key
          if REGISTRY.has_key?(t) and REGISTRY[t] != klass
            raise ArgumentError,
              "BGP-LS TLV type #{t} is already #{REGISTRY[t]}"
          end
          if BY_KEY.has_key?(k) and BY_KEY[k] != klass
            raise ArgumentError,
              "BGP-LS TLV hash key #{k.inspect} is already #{BY_KEY[k]}"
          end
          REGISTRY[t] = klass
          BY_KEY[k] = klass
          klass
        end

        # Read one TLV off the front of _s_, consuming exactly its own
        # octets, and answer nil for octets too short to frame one so a
        # list loop can stop rather than spin.
        #
        # A Length that overruns what is there takes what is there and
        # is kept, so `encode` gives the peer's own Length back rather
        # than correcting it. That is the `Evpn` and `Mcast_vpn` rule,
        # and it is what makes a malformed capture replayable.
        def factory(s)
          return nil if s.nil? or s.size < FRAMING
          t     = s.slice!(0, 2).unpack1('n')
          len   = s.slice!(0, 2).unpack1('n')
          value = s.slice!(0, [len, s.size].min)
          tlv = read_tlv(t, value) || Tlv::Unknown.new(t, value)
          tlv.declared_len = len if len != value.size
          tlv
        end

        # Every TLV in _s_, consuming them. Octets that cannot frame a
        # TLV are left in _s_ for the caller to keep as a tail, which is
        # the convention every list loop in the library follows.
        #
        # **The loop always makes progress**, two ways: a Length of 0
        # still consumes the four framing octets, and a Length that
        # overruns takes everything left so the next call sees nothing.
        # A reader that could stall on either is the hazard here, since
        # section 5.1 permits a TLV "with no value portion" outright.
        def parse_list(s)
          list = []
          loop do
            tlv = factory(s)
            break if tlv.nil?
            list << tlv
          end
          list
        end

        # One TLV from a hash, dispatching on the key. Raises rather
        # than quietly building a TLV of type 0 from a key nothing
        # knows, which is the `Multicast_flags` hazard Conventions
        # records: a class may refuse a hash, it may not accept one and
        # build something else.
        def from_hash(h)
          key = h.keys.find { |k| BY_KEY.has_key?(k) }
          raise ArgumentError, "no BGP-LS TLV in #{h.inspect}" if key.nil?
          BY_KEY[key].new(h)
        end

        # Section 5.1's ordering rule, in one place, so the validation
        # part asks rather than reimplementing it: "all TLVs within the
        # NLRI MUST be ordered in ascending order by TLV Type. If there
        # are multiple TLVs of the same type within a single NLRI, then
        # the TLVs sharing the same type MUST be first in ascending
        # order based on the Length field followed by ascending order
        # based on the Value field."
        #
        # **The rule is the NLRI's. The BGP-LS Attribute's is a SHOULD
        # whose breach is explicitly not malformed**, which is the same
        # paragraph two sentences on, so a caller has to say which it is
        # asking about rather than this answering for both.
        def ordered?(list)
          keys = list.collect { |t| t.sort_key }
          keys == keys.sort
        end

        private

        # **A TLV is kept as its registered class only if it can give
        # its own octets back**, which is the rule `Flow_spec`, `Evpn`
        # and `Mcast_vpn` each record: a layout parsed from a value that
        # does not fit it invents the fields it did not find, so it
        # would answer `encode` with octets the peer never sent.
        #
        # So the value is parsed on a **copy** and the result accepted
        # only when its own octets match. One that fails falls back to
        # `Tlv::Unknown`, which keeps the value whole and replays it.
        # The comparison is on the **value** and not on `encode`,
        # because the framing is this class's and only the value is the
        # registered class's to reproduce.
        def read_tlv(t, value)
          klass = REGISTRY[t]
          return nil if klass.nil?
          tlv = klass.new(value.dup.is_packed)
          tlv.encode_value == value ? tlv : nil
        rescue StandardError
          nil
        end

      end

      # The Length that arrived, when it was not the number of octets
      # that came with it, so `encode` writes back what the peer sent
      # rather than what is really there. nil on anything built from
      # values.
      #
      # The writer is public because `factory` sets it after the value
      # is read, and because a test wanting a TLV whose Length lies has
      # to reach it somehow. The hash carries it under `:length`.
      attr_accessor :declared_len

      def type
        self.class.type
      end

      # The Length octets this TLV writes: what arrived when that
      # disagreed with the value, and the value's own size otherwise.
      def length
        @declared_len || encode_value.size
      end

      # Section 5.1's triplet, and the only place in the library that
      # knows a BGP-LS TLV is type, length, value. A registered class
      # supplies `encode_value` and writes no framing of its own, which
      # is the shape Conventions calls deliberate for `Orf#encode` and
      # the capability layers.
      def encode
        v = encode_value
        n = @declared_len || v.size
        refuse_a_length_the_field_cannot_hold(n)
        [type.to_i, n, v].pack('nna*')
      end

      def to_shex
        encode.unpack1('H*')
      end

      # The octets this TLV occupies, its four framing octets included.
      def size
        encode.size
      end

      def to_hash
        h = { self.class.hash_key => value_hash }
        h = h.merge(:length => @declared_len) if @declared_len
        h
      end

      # Section 5.1's three-level ordering key.
      #
      # **The second element is the Length field and not the value's
      # real size**, which is what the sentence says and is a real
      # difference: a TLV whose declared Length lies sorts by the lie.
      # The third is the value compared as bytes, which the section
      # spells out rather than leaving to a reader: "Comparison of the
      # Value fields is performed by treating the entire field as
      # opaque binary data and ordered lexicographically (i.e.,
      # treating each byte of binary data as a symbol to compare, with
      # the symbols ordered by their numerical value)." Ruby's
      # `String#<=>` on two binary strings is exactly that, which is
      # why every value here is forced to binary.
      def sort_key
        [type.to_i, length, encode_value]
      end

      def ==(other)
        other.is_a?(Tlv) and other.encode == encode
      end

      # A TLV type bgp4r does not implement, kept whole and written
      # back so a capture replays byte for byte.
      #
      # **Section 5.1 requires this rather than permitting it**, which
      # is why there is no decision recorded here where
      # `Evpn::Unknown` and `Flow_spec::Component::Unknown` each needed
      # one: "Unknown and unsupported types MUST be preserved and
      # propagated within both the NLRI and the BGP-LS Attribute."
      #
      # **Mind the name.** `Link_state::Unknown` is a different class
      # one level up, an unknown NLRI **type**, and inside this file a
      # bare `Unknown` resolves here only because this class happens to
      # define it. Write both in full, which is the `const_defined?`
      # lesson in Conventions arriving from the lexical-scope side.
      class Unknown < Tlv

        HASH_KEY = :unknown

        # IANA's "BGP-LS TLVs Registration Process", Table 17 of RFC
        # 9552 section 7.1.7: 65000 to 65535 is Private Use.
        PRIVATE_USE = (65000..65535)

        # Table 17 again, and it is worth knowing: "0-255 | Reserved
        # (not to be allocated)". So a TLV type under 256 is one no
        # document will ever define, and it still parses and replays
        # from here.
        RESERVED = (0..255)

        attr_reader :value

        def initialize(*args)
          @type, @value = 0, String.new
          if args.size == 1 and args[0].is_a?(self.class)
            @type = args[0].type
            @value = args[0].value.dup
            self.declared_len = args[0].declared_len
          elsif args.size == 1 and args[0].is_a?(Hash)
            from_hash(args[0])
          elsif (1..2).include?(args.size) and args[0].is_a?(Integer)
            @type = args[0]
            @value = args[1].to_s.b
          else
            raise ArgumentError, "invalid argument: #{args.inspect}, " \
                                 'expected (type, value) or a hash'
          end
          self
        end

        # The type arrives from the framing rather than from the value,
        # so unlike a registered TLV this one carries its own.
        def type
          @type
        end

        # A copy, so building from an instance cannot empty the
        # instance it is copying: the list reader reads with `slice!`.
        def encode_value
          @value.dup
        end

        def private_use?
          PRIVATE_USE.include?(@type)
        end

        # The Enterprise Code of RFC 9552 section 5.4, for a type in
        # the private-use range: "For such TLV use in the NLRI or
        # BGP-LS Attribute, the format described in Section 5.1 is to
        # be used and a 4-octet field MUST be included as the first
        # field in the value to carry the Enterprise Code."
        #
        # A reader only. The octets are not reshaped and nothing is
        # refused, so a private-use TLV too short to hold one still
        # replays and this answers nil.
        def enterprise_code
          return nil unless private_use?
          return nil if @value.size < 4
          @value.unpack1('N')
        end

        def value_hash
          { :type => @type, :value => @value.unpack1('H*') }
        end

        def to_s
          s = private_use? ? 'Private use TLV' : 'Unknown TLV'
          s += " #{@type}, #{@value.size} octets"
          s += " [#{@value.unpack1('H*')}]" unless @value.empty?
          e = enterprise_code
          s += ", enterprise #{e}" if e
          s
        end

        private

        # **The `:length` key is read before the unwrap and that order
        # matters**, because `to_hash` puts it beside the class's own
        # key rather than inside it. Unwrapping first loses a Length
        # that lied, silently, which is the worst shape of hash bug.
        def from_hash(h)
          read_declared_len(h)
          h = self.class.unwrap(h)
          @type = h[:type].to_i
          @value = [h[:value].to_s].pack('H*')
        end

      end

      BY_KEY[Unknown::HASH_KEY] = Unknown

      # --- the shared bases ------------------------------------------
      #
      # **Four shapes that more than one of the RFC's tables uses, so
      # they live with the framing rather than with whichever table
      # reached for one first.** Each was written where its first user
      # was: `Opaque32` in `link_state_descriptor.rb` for Table 3,
      # `Addr_tlv` in `link_state_link_descriptor.rb` for Table 4, and
      # `Opaque_tlv` and `Text_tlv` in `link_state_node_attribute.rb`
      # for Table 6. Table 8 wants all four, so leaving them there
      # would mean three sideways requires and file names that stop
      # describing what they hold.
      #
      # **The move changed no constant path**, because every file in
      # this family reopens `BGP::Link_state::Tlv`, which is also why
      # it was cheap to defer until a second table needed one. Phase 1
      # of the breadth plan is the same argument one level up: build
      # the shared thing when a second caller arrives, not before.

      # A TLV whose whole value is one 32-bit unsigned integer, in a
      # 4 + 4 octet TLV. Its subclasses differ only in the type number,
      # the hash key and how each prints.
      #
      # Table 3's three node descriptor sub-TLVs are the shape's
      # origin, 512, 513 and 514, each "Opaque value (32-bit ...)" in
      # section 5.2.1.4. **Opaque is the RFC's word for those three**,
      # so none of them refuses a value or reads structure out of it,
      # and a subclass that does carry structure says so itself.
      #
      # A width other than 4 cannot be one of these: `Tlv.factory` then
      # finds the value does not reproduce itself and keeps the octets
      # as a `Tlv::Unknown`, which is the rule part 1 records.
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

      # A TLV whose whole value is one IP address of a fixed width, in
      # a 4 + WIDTH octet TLV. Its subclasses differ only in the type
      # number, the width, the family and how each prints. Four of
      # Table 4's six link descriptors are the shape's origin.
      #
      # A width other than WIDTH cannot be one of these: `Tlv.factory`
      # then finds the value does not reproduce itself and keeps the
      # octets as a `Tlv::Unknown`, which is part 1's rule.
      class Addr_tlv < Tlv

        attr_reader :address

        # new('10.0.0.1'), new(an_IPAddr), the wire value octets, this
        # class's own hash, or another instance.
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
          elsif args.empty?
            # The all zeroes address, which no RFC describes as a link
            # descriptor and which builds, per Conventions.
            @address = coerce(self.class.width == 4 ? '0.0.0.0' : '::')
          else
            raise ArgumentError, "invalid argument: #{args.inspect}"
          end
          self
        end

        def self.width
          self::WIDTH
        end

        def self.label
          self::LABEL
        end

        # **Exactly WIDTH octets, and refusing anything else is what
        # keeps the family honest.** `IPAddr.new_ntoh` reads 4 octets
        # as an IPv4 address and 16 as an IPv6 one, and `hton` gives
        # back whatever it was handed, so without this check a 4-octet
        # value in TLV 261 parsed into an `Ipv6_interface_address`
        # holding an IPv4 address and reproduced its own octets, which
        # is how it passed part 3's first run. Raising sends it to
        # `Tlv::Unknown` through `read_tlv`'s rescue, which keeps the
        # octets whole and claims nothing about them.
        def parse(s)
          w = self.class.width
          unless s.size == w
            raise ArgumentError,
              "#{self.class} is #{w} octets and this value is #{s.size}"
          end
          @address = IPAddr.new_ntoh(s.slice!(0, w))
          self
        end

        def encode_value
          @address.hton
        end

        def value_hash
          @address.to_s
        end

        def to_s
          "#{self.class.label} #{@address}"
        end

        private

        # **An address of the other family is refused, and that is the
        # one kind of refusal Conventions allows rather than a
        # judgement about validity**: a 4-octet field cannot represent
        # a 16-octet address, so the alternative is writing a 16-octet
        # value in a TLV whose class says 4 and calling it an IPv4
        # interface address.
        #
        # The octet level route stays open and is the one to use for a
        # value no RFC allows: `Tlv::Unknown.new(259, sixteen_octets)`
        # builds it, encodes it and replays it. The message says so.
        def coerce(v)
          a = v.is_a?(IPAddr) ? v : IPAddr.new(v.to_s)
          w = self.class.width
          unless a.hton.size == w
            raise ArgumentError,
              "#{self.class} is #{w} octets and #{a} is #{a.hton.size}; " \
              "for a value no RFC allows use " \
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

      # A TLV whose whole value is a symbolic name in text. Section
      # 5.3.1.3's Node Name and section 5.3.2.7's Link Name are one
      # shape and two type numbers: the two sections are the same three
      # paragraphs with "router node" and "router link" swapped, down
      # to the 7-bit ASCII rule and the 255.
      #
      # **The one class shape in this family whose field form and hash
      # form are the same String**, because the value is text where
      # `Opaque_tlv`'s is not. No `is_packed?` branch and no `parse`,
      # for the reason `Opaque_tlv`'s comment gives.
      #
      # Both sections' rules are deviated from on purpose, per
      # Conventions. "The Value field is encoded in 7-bit ASCII", so
      # `ascii?` reports a name that is not and nothing refuses it. And
      # "The maximum length of the ... TLV is 255 octets", which **does
      # not say whether the four framing octets are in that count**:
      # 255 of value and 251 of value are both readings of that
      # sentence and neither section settles it, so nothing enforces
      # either and a longer name builds.
      class Text_tlv < Tlv

        # Each section's own number, kept as the figure it gives rather
        # than as a check. Which of the two readings it means is open.
        MAX_LEN = 255

        attr_reader :name

        # new('router1'), this class's own hash, or another instance.
        def initialize(*args)
          @name = String.new
          if args.size == 1 and args[0].is_a?(self.class)
            self.declared_len = args[0].declared_len
            @name = args[0].name.dup
          elsif args.size == 1 and args[0].is_a?(Hash)
            from_hash(args[0])
          elsif args.size == 1 and args[0].is_a?(String)
            @name = args[0].dup.b
          elsif args.empty?
            # The empty name, which section 5.1's zero-length value
            # permits and which both sections call optional.
          else
            raise ArgumentError, "invalid argument: #{args.inspect}"
          end
          self
        end

        def self.label
          self::LABEL
        end

        def encode_value
          @name.dup
        end

        # True when every octet is in the 7-bit ASCII the sections ask
        # for. A reader only: nothing refuses a name that is not.
        def ascii?
          @name.each_byte.all? { |b| b < 0x80 }
        end

        # The name as text, for a reader. Binary on the wire, so the
        # encoding is forced rather than guessed, and a name that is not
        # ASCII still comes back whole.
        def value_hash
          @name.dup.force_encoding(Encoding::UTF_8)
        end

        def to_s
          "#{self.class.label} '#{@name}'"
        end

        private

        def from_hash(h)
          read_declared_len(h)
          h = self.class.unwrap(h)
          @name = h.to_s.dup.b
        end

      end

      # A TLV whose whole value is opaque octets of no fixed width.
      # Its subclasses differ only in the type number, the hash key and
      # how each prints. Table 6's 1025 and 1027 are the shape's
      # origin.
      #
      # **The field form takes raw octets and the hash form takes hex**,
      # which is `Tlv::Unknown`'s split and is kept here so the family
      # reads one way. Each path round trips through itself, and a
      # caller holding hex writes `['0102'].pack('H*')`, which is the
      # library's own idiom.
      #
      # **There is no `is_packed?` branch and no `parse` here, which is
      # the one place this family's constructor shape does not apply.**
      # For a fixed-width class that test tells a wire value from a
      # field value, because the wire branch slices its own octets and
      # leaves the rest. A variable-width value **is** the octets: both
      # branches would take everything and reach the same value, and
      # the only thing left for the test to decide is whether the
      # caller's String is consumed. Two branches differing in that and
      # in nothing else is a trap rather than a feature, especially
      # since `Array#pack` marks its result packed, so almost every
      # octet string a caller holds would take the consuming one
      # without the caller choosing it. So one branch, and it copies,
      # which is what `Tlv::Unknown` does with the same kind of
      # argument. Do not add a `parse` here without a caller for it.
      class Opaque_tlv < Tlv

        attr_reader :value

        # new, new(octets), this class's own hash, or another instance.
        # Wire octets are the `new(octets)` form, marked or not.
        def initialize(*args)
          @value = String.new
          if args.size == 1 and args[0].is_a?(self.class)
            self.declared_len = args[0].declared_len
            @value = args[0].value.dup
          elsif args.size == 1 and args[0].is_a?(Hash)
            from_hash(args[0])
          elsif args.size == 1 and args[0].is_a?(String)
            @value = args[0].dup.b
          elsif args.empty?
            # The empty value, which section 5.1 permits outright: "a
            # TLV with no value portion would have a length of zero".
          else
            raise ArgumentError, "invalid argument: #{args.inspect}"
          end
          self
        end

        # A copy, so building from an instance cannot empty the instance
        # it is copying: the list reader reads with `slice!`.
        def encode_value
          @value.dup
        end

        def value_hash
          @value.unpack1('H*')
        end

        def self.label
          self::LABEL
        end

        def to_s
          s = "#{self.class.label} #{@value.size} octets"
          s += " [#{@value.unpack1('H*')}]" unless @value.empty?
          s
        end

        private

        def from_hash(h)
          read_declared_len(h)
          h = self.class.unwrap(h)
          @value = [h.to_s].pack('H*')
        end

      end

      private

      # The one refusal this class makes, and it is the kind
      # Conventions allows: a length the two-octet field cannot hold
      # cannot be written at all, so packing it would put a different
      # length on the wire than the caller asked for. `Flow_spec`
      # refuses an RFC 8955 section 4.1 length over 4095 for the same
      # reason and in the same place.
      def refuse_a_length_the_field_cannot_hold(n)
        return if n <= MAX_LEN
        raise ArgumentError,
          "BGP-LS TLV length #{n} does not fit the 2-octet Length field " \
          "of RFC 9552 section 5.1, max #{MAX_LEN}"
      end

      # The `:length` key, read off a hash before it is unwrapped,
      # because `to_hash` puts it beside the class's own key and not
      # inside it. Here so every TLV class added later reads it the
      # same way; getting it wrong loses a Length that lied, silently.
      def read_declared_len(h)
        @declared_len = h[:length] if h.is_a?(Hash)
      end

    end

  end

end

load "../../test/unit/nlris/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
