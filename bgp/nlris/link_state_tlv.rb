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
