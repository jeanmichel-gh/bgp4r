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
require 'bgp/nlris/prefix'

module BGP

  # The components of a Flow Specification NLRI value.
  #
  # RFC 8955 section 4.2, "NLRI Value Encoding": "The Flow Specification
  # NLRI value consists of a list of optional components", encoded as
  # "<[component]+>". Section 4.2.2 says each one "begins with a type
  # field (1 octet) followed by a variable length parameter".
  #
  # This file is the components only. The NLRI that carries them, with
  # the section 4.1 length framing and the section 8 Route Distinguisher,
  # is Flow_spec itself and nothing dispatches to any of this yet. That
  # order is deliberate and is the house pattern: #125 landed the export
  # rules before anything sent them and #156 landed the FIB planner
  # before anything ran it, so the pure part can be tested with no
  # session, no attribute and no framing.
  #
  # IPv6 components are RFC 8956. Where a type number means a different
  # layout there (types 1 and 2 gain an offset octet) it gets a class of
  # its own; where it means the same octets under another name (types 3,
  # 7, 8 and 12) it is a bare subclass, the way Traffic_rate_packets
  # subclasses Traffic_rate_bytes in extended_community.rb.
  #
  # **Nothing here validates.** Any type, any operator, any value, any
  # length, any order, any repetition, per Conventions in CLAUDE.md: the
  # library exists to put bytes on the wire that no RFC allows. RFC 8955
  # section 4.2 does constrain a *receiver* ("Components MUST follow
  # strict type ordering by increasing numerical order. A given component
  # type MAY (exactly once) be present"), and that belongs in
  # validation.rb, which runs on what arrived.
  class Flow_spec

    # One {op, value} pair.
    #
    # RFC 8955 section 4.2.2.3 and the components after it are each "a
    # list of {numeric_op, value} pairs" or of {bitmask_op, bitmask}
    # pairs. The operator is one octet (section 4.2.1) and the value is
    # as many octets as that octet's len field says.
    class Pair

      # RFC 8955 section 4.2.1.1, Figure 2, and section 4.2.1.2, Figure
      # 3, whose e, a and len are "Most significant nibble; defined in
      # the Numeric Operator format in Section 4.2.1.1". Bit 0 is the
      # most significant bit, as both figures number them.
      EOL      = 0x80   # e, bit 0
      AND      = 0x40   # a, bit 1
      LEN_MASK = 0x30   # len, bits 2 and 3
      LEN_SHIFT = 4

      attr_reader :op, :value, :len, :eol, :and_bit

      # (op, value), or a Hash naming any of the fields. The Hash form is
      # what a negative test wants, since it reaches len and eol, which
      # the Array form infers.
      #
      #   Numeric_pair.new(:ge, 137)
      #   Numeric_pair.new(:and_le, 139)
      #   Numeric_pair.new(:op=>:eq, :value=>25, :len=>3, :eol=>false)
      #
      # An `and_` prefix on the operator sets the AND bit. RFC 8955
      # section 4.2.1.1 on that bit: "If unset, the result of the
      # previous {op, value} pair is logically ORed with the current one.
      # If set, the operation is a logical AND."
      def initialize(*args)
        @eol, @and_bit = nil, false
        if args.size == 1 and args[0].is_a?(Hash)
          h = args[0]
          @value = h[:value].to_i
          @len = h[:len]
          @eol = h[:eol]
          @and_bit = !!h[:and] if h.has_key?(:and)
          set_op(h[:op])
        else
          set_op(args[0])
          @value = args[1].to_i
        end
        @len ||= self.class.len_for(@value, self.class.default_len)
      end

      # The len field for a value, as the smallest field that holds it,
      # but never below what the component's own RFC asks an encoder for.
      # RFC 8955 section 4.2.1.1: "The length of the value field for this
      # operator given as (1 << len). This encodes 1 (len=00), 2
      # (len=01), 4 (len=10), and 8 (len=11) octets."
      #
      # So a value is written in the fewest octets by default and the
      # recommended width when a component names one, which is how the
      # RFC's own examples encode: 25 as one octet, 8080 as two.
      def self.len_for(value, floor = 0)
        raise ArgumentError, "value #{value} does not fit in 8 octets" if value.abs >= (1 << 64)
        needed = [0, 1, 2, 3].find { |l| value.abs < (1 << (8 * (1 << l))) }
        [needed, floor].max
      end

      # What a component's RFC asks an encoder for, as a len field.
      # Overridden by the components that name a width; 0 is one octet.
      def self.default_len
        0
      end

      # The octets of the value field, (1 << len) wide, big endian.
      PACK = { 0 => 'C', 1 => 'n', 2 => 'N', 3 => 'Q>' }.freeze

      def value_size
        1 << @len
      end

      # eol defaults to false here and the component sets it on the last
      # pair, so a pair built on its own writes what it was given.
      def encode(eol = @eol)
        octet = (eol ? EOL : 0) | (@and_bit ? AND : 0) |
                ((@len & 0x3) << LEN_SHIFT) | low_nibble
        [octet, @value].pack("C#{PACK[@len & 0x3]}")
      end

      # [:ge, 137] when len and eol are what a build from values would
      # have chosen anyway, and the Hash form when either is unusual, so
      # an ordinary pair reads as the pair it was written as. Same rule
      # as a kept tail: nothing unusual, nothing extra.
      def to_a(eol_expected = nil)
        sym = @and_bit ? :"and_#{@op}" : @op
        plain = @len == self.class.len_for(@value, self.class.default_len)
        plain &&= (@eol.nil? || @eol == eol_expected)
        return [sym, @value] if plain
        h = { :op => sym, :value => @value, :len => @len }
        h[:eol] = !!@eol unless @eol.nil? || @eol == eol_expected
        h
      end

      def to_s
        "#{@and_bit ? '&& ' : ''}#{@op} #{@value}"
      end

      private

      def set_op(sym)
        s = sym.to_s
        if s.start_with?('and_')
          @and_bit = true
          s = s.sub(/\Aand_/, '')
        end
        @op = s.to_sym
        raise ArgumentError, "unknown operator #{sym.inspect}, one of " \
                             "#{self.class.ops.values.inspect}" unless
          self.class.ops.value?(@op)
      end

      def low_nibble
        self.class.ops.key(@op)
      end

    end

    # RFC 8955 section 4.2.1.1, "Numeric Operator (numeric_op)", Figure
    # 2: | e | a | len | 0 | lt | gt | eq |. Bit 4 "MUST be set to 0 on
    # NLRI encoding and MUST be ignored during decoding", so it is kept
    # when it arrives set, the way a reserved field is everywhere else
    # here, and written as 0 on a build from values.
    class Numeric_pair < Pair

      # RFC 8955 section 4.2.1.1, Table 1, "Comparison Operation
      # Combinations", read as the three bits lt, gt and eq together.
      # The two that depend on no value are the RFC's own words: 000 is
      # "false (independent of the value)" and 111 is "true".
      OPS = {
        0 => :false, 1 => :eq, 2 => :gt, 3 => :ge,
        4 => :lt,    5 => :le, 6 => :ne, 7 => :true,
      }.freeze

      # Bit 4 of the operator octet, which section 4.2.1.1 says is 0.
      RESERVED = 0x08

      def self.ops
        OPS
      end

      # The reserved bit as it arrived, so encode gives it back. nil on a
      # pair built from values, which writes 0.
      attr_reader :reserved

      def initialize(*args)
        super
        @reserved = args[0].is_a?(Hash) ? args[0][:reserved] : nil
      end

      def encode(eol = @eol)
        s = super
        s.setbyte(0, s.getbyte(0) | RESERVED) if @reserved.to_i != 0
        s
      end

      def to_a(eol_expected = nil)
        a = super
        return a if @reserved.to_i.zero?
        h = a.is_a?(Hash) ? a : { :op => a[0], :value => a[1], :len => @len }
        h.merge(:reserved => @reserved)
      end

    end

    # RFC 8955 section 4.2.1.2, "Bitmask Operator (bitmask_op)", Figure
    # 3: | e | a | len | 0 | 0 | not | m |.
    class Bitmask_pair < Pair

      # The two low bits as (not << 1) | m. RFC 8955 section 4.2.1.2 on
      # each: "not (NOT bit): If set, logical negation of operation" and
      # "m (Match bit): If set, this is a bitwise match operation defined
      # as "(data AND value) == value"; if unset, (data AND value)
      # evaluates to TRUE if any of the bits in the value mask are set in
      # the data."
      #
      # So :any is m unset, :match is m set, and the not_ pair are those
      # two negated. The RFC names no symbols; these are bgp4r's.
      OPS = {
        0 => :any,     1 => :match,
        2 => :not_any, 3 => :not_match,
      }.freeze

      # Bits 4 and 5, which section 4.2.1.2 says are 0: "0 (all 0 bits):
      # MUST be set to 0 on NLRI encoding and MUST be ignored during
      # decoding".
      RESERVED = 0x0c

      def self.ops
        OPS
      end

      attr_reader :reserved

      def initialize(*args)
        super
        @reserved = args[0].is_a?(Hash) ? args[0][:reserved] : nil
      end

      def encode(eol = @eol)
        s = super
        s.setbyte(0, s.getbyte(0) | (@reserved.to_i & RESERVED)) if @reserved.to_i != 0
        s
      end

      def to_a(eol_expected = nil)
        a = super
        return a if @reserved.to_i.zero?
        h = a.is_a?(Hash) ? a : { :op => a[0], :value => a[1], :len => @len }
        h.merge(:reserved => @reserved)
      end

    end

    # A component: a type octet and a variable length parameter, RFC 8955
    # section 4.2.2.
    class Component

      def self.type
        self::TYPE
      end

      # The key this component takes in a Flow_spec hash, one per class.
      def self.hash_key
        self::HASH_KEY
      end

      def type
        self.class.type
      end

      def encode
        [type, encode_value].pack('Ca*')
      end

      def to_shex
        encode.unpack1('H*')
      end

      def to_hash
        { self.class.hash_key => value_hash }
      end

      # The one Hash a build may be handed that is this component's own
      # hash rather than one {op, value} pair. Pairs carry :op or :value,
      # so a Hash holding neither and holding this class's key is the
      # wrapped form.
      def self.unwrap(h)
        return h unless h.is_a?(Hash)
        return h if h.has_key?(:op) || h.has_key?(:value)
        h.has_key?(hash_key) ? h[hash_key] : h
      end

    end

    # A component whose parameter is a list of {op, value} pairs, which is
    # every component except types 1 and 2.
    class Op_component < Component

      attr_reader :pairs

      # The octets of a pair this class could not read whole, kept so
      # encode returns byte for byte what arrived. nil on anything built
      # from values and on a list that ended with its end-of-list bit.
      attr_reader :tail

      # new(:eq, 25), new([:ge, 137], [:and_le, 139], [:eq, 8080]), the
      # wire octets, this component's own hash, or another instance.
      def initialize(*args)
        @pairs, @tail = [], nil
        if args.size == 1 and args[0].is_a?(String) and args[0].is_packed?
          parse(args[0])
        elsif args.size == 1 and args[0].is_a?(self.class)
          parse(args[0].encode_value.is_packed)
        else
          args = [self.class.unwrap(args[0])] if args.size == 1 && args[0].is_a?(Hash)
          # One list of pairs, written [[..],[..]] or, where a field had
          # to be named, [{..},{..}]. Either way the list is the args.
          args = args[0] if args.size == 1 && args[0].is_a?(Array) &&
                            (args[0][0].is_a?(Array) || args[0][0].is_a?(Hash))
          raise ArgumentError, "no {op, value} pair given" if args.empty?
          # new(:eq, 25) is one pair unwrapped; anything else is a list.
          args = [args] unless args[0].is_a?(Array) || args[0].is_a?(Hash)
          # A kept tail rides as one {:tail=>hex} entry at the end of the
          # list, which is what Attr#take_tail does for a path attribute.
          @tail = [args.pop[:tail].to_s].pack('H*') if
            args[-1].is_a?(Hash) && args[-1].keys == [:tail]
          raise ArgumentError, "no {op, value} pair given" if args.empty? && @tail.nil?
          args.each { |a| @pairs << self.class.pair_klass.new(*[a].flatten(1)) }
        end
      end

      def self.pair_klass
        raise NotImplementedError
      end

      # RFC 8955 section 4.2.1.1: "e (end-of-list bit): Set in the last
      # {op, value} pair in the list". So the last pair gets it unless the
      # caller said otherwise, and a pair that arrived without it keeps
      # what arrived, since that is the one thing encode must replay.
      def encode_value
        s = +''
        @pairs.each_with_index do |p, i|
          s << p.encode(p.eol.nil? ? i == @pairs.size - 1 : p.eol)
        end
        s << @tail if @tail
        s
      end

      # Reads pairs until one carries the end-of-list bit or the octets
      # run out. A pair whose value field overruns what is left cannot be
      # read, so its operator octet and the remainder are kept whole.
      def parse(s)
        @pairs, @tail = [], nil
        until s.empty?
          octet = s.getbyte(0)
          len = (octet & Pair::LEN_MASK) >> Pair::LEN_SHIFT
          if s.size < 1 + (1 << len)
            @tail = s.slice!(0, s.size)
            break
          end
          s.slice!(0, 1)
          value = s.slice!(0, 1 << len).unpack1(Pair::PACK[len])
          pair = self.class.pair_klass.new(
            :op => self.class.pair_klass.ops[octet & low_nibble_mask],
            :value => value, :len => len,
            :and => (octet & Pair::AND) != 0,
            :eol => (octet & Pair::EOL) != 0,
            :reserved => octet & self.class.pair_klass::RESERVED)
          @pairs << pair
          break if (octet & Pair::EOL) != 0
        end
        self
      end

      def low_nibble_mask
        self.class.pair_klass <= Numeric_pair ? 0x07 : 0x03
      end

      # The pairs, each as the Array it was written as, with the Hash form
      # only where a field is not what a build would have chosen. A kept
      # tail rides as one {:tail=>hex} entry at the end, which is the rule
      # Attr::TAIL_KEY follows for the path attributes.
      def value_hash
        last = @pairs.size - 1
        a = @pairs.each_with_index.collect { |p, i| p.to_a(i == last) }
        a << { :tail => @tail.unpack1('H*') } if @tail
        a
      end

      def to_s
        "#{self.class.name.split('::').last}: #{@pairs.collect(&:to_s).join(' ')}" +
          (@tail ? " tail [#{@tail.unpack1('H*')}]" : '')
      end

    end

    class Numeric_component < Op_component
      def self.pair_klass
        Numeric_pair
      end
    end

    class Bitmask_component < Op_component
      def self.pair_klass
        Bitmask_pair
      end
    end

    # RFC 8955 section 4.2.2.1, "Type 1 - Destination Prefix", and
    # section 4.2.2.2 for type 2: "<type (1 octet), length (1 octet),
    # prefix (variable)>", where "The length and prefix fields are
    # encoded as in BGP UPDATE messages [RFC4271]". That is exactly what
    # Prefix encodes, so this delegates rather than repeating it.
    class Prefix_component < Component

      attr_reader :prefix

      def initialize(*args)
        if args.size == 1 and args[0].is_a?(String) and args[0].is_packed?
          parse(args[0])
        elsif args.size == 1 and args[0].is_a?(self.class)
          parse(args[0].encode_value.is_packed)
        else
          arg = self.class.unwrap(args[0])
          arg = arg[:prefix] if arg.is_a?(Hash)
          @prefix = arg.is_a?(Prefix) ? arg : Prefix.new(arg)
        end
      end

      def parse(s)
        @prefix = Prefix.new_ntop(s, self.class::AFI)
        self
      end

      def encode_value
        @prefix.encode
      end

      def value_hash
        @prefix.to_s
      end

      def to_s
        "#{self.class.name.split('::').last}: #{@prefix}"
      end

    end

    # RFC 8956 section 3.1, "Type 1 - Destination IPv6 Prefix", and
    # section 3.2 for type 2: "<type (1 octet), length (1 octet), offset
    # (1 octet), pattern (variable), padding (variable) >".
    #
    # length "indicates the N-th most significant bit in the address
    # where bitwise pattern matching stops", offset "indicates the number
    # of most significant address bits to skip before bitwise pattern
    # matching starts", and the pattern "contains enough octets for the
    # bits used in matching (length minus offset bits)" with padding that
    # "MUST be 0 on encoding and MUST be ignored on decoding".
    #
    # Section 3.1's own note gives the reading back: the component "can
    # be represented by the notation ipv6address/length if offset is 0 or
    # ipv6address/offset-length. The ipv6address in this notation is the
    # textual IPv6 representation of the pattern shifted to the right by
    # the number of offset bits." So #prefix is that address and #offset
    # the offset, and both encodings in section 3.8 reproduce from them.
    class Ipv6_prefix_component < Component

      attr_reader :offset

      # The padding bits as they arrived, so encode gives them back on a
      # capture whose sender did not zero them. nil on anything built
      # from values, which writes 0 as section 3.1 asks.
      attr_reader :padding

      # new('2001:db8::/32'), new('::1234:5678:9a00:0/104', 65), the wire
      # octets, this component's own hash, or another instance. The
      # section 3.1 notation ipv6address/offset-length is accepted too,
      # so a capture prints as something that builds again.
      def initialize(*args)
        @offset, @padding = 0, nil
        if args.size == 1 and args[0].is_a?(String) and args[0].is_packed?
          parse(args[0])
        elsif args.size == 1 and args[0].is_a?(self.class)
          parse(args[0].encode_value.is_packed)
        else
          arg = self.class.unwrap(args[0])
          if arg.is_a?(Hash)
            @offset = arg[:offset].to_i
            @padding = arg[:padding]
            arg = arg[:prefix]
          else
            @offset = args[1].to_i if args.size > 1
          end
          set_prefix(arg)
        end
      end

      # 0/0 is section 3.1's match-everything component: "If length = 0
      # and offset = 0, this component matches every address". Any other
      # pair is written as given, including one the section calls
      # malformed, because building never validates.
      def length
        @length
      end

      def encode_value
        bits = @length - @offset
        bits = 0 if bits < 0
        v = (IPAddr.new(@addr).to_i >> (128 - @length)) & ((1 << bits) - 1) if bits > 0
        v = 0 if bits.zero?
        pad = (-bits) % 8
        v = (v << pad) | (@padding.to_i & ((1 << pad) - 1))
        octets = (bits + 7) / 8
        [@length, @offset].pack('CC') +
          (octets.zero? ? +'' : [v.to_s(16).rjust(octets * 2, '0')].pack('H*'))
      end

      def parse(s)
        @length, @offset = s.slice!(0, 2).unpack('CC')
        bits = @length - @offset
        bits = 0 if bits < 0
        octets = (bits + 7) / 8
        raw = s.slice!(0, octets).to_s
        v = raw.empty? ? 0 : raw.unpack1('H*').to_i(16)
        pad = (-bits) % 8
        @padding = pad.zero? ? nil : v & ((1 << pad) - 1)
        @padding = nil if @padding == 0
        n = @length.zero? ? 0 : (v >> pad) << (128 - @length)
        @addr = IPAddr.new_ntoh([n.to_s(16).rjust(32, '0')].pack('H*')).to_s
        self
      end

      def prefix
        "#{@addr}/#{@offset.zero? ? @length : "#{@offset}-#{@length}"}"
      end

      def value_hash
        h = { :prefix => prefix }
        h[:padding] = @padding if @padding
        h
      end

      def to_s
        "#{self.class.name.split('::').last}: #{prefix}"
      end

      private

      # Takes ipv6address/length or ipv6address/offset-length, the two
      # forms section 3.1's note gives, and an offset passed separately.
      def set_prefix(arg)
        addr, len = arg.to_s.split('/')
        if len.to_s.include?('-')
          off, len = len.split('-')
          @offset = off.to_i
        end
        @addr = IPAddr.new(addr.to_s).to_s
        @length = len.nil? ? 128 : len.to_i
      end

    end

    # A component type bgp4r does not implement.
    #
    # RFC 8955 section 4.2: "An NLRI value not encoded as specified here,
    # including an NLRI that contains an unknown component type, is
    # considered malformed and error handling according to Section 10 is
    # performed." So this is a protocol error by the RFC's own words and
    # not a bgp4r coverage gap, which is why it belongs in
    # Path_attribute#errors through validation.rb and not in #undecoded.
    # Note what that costs and that the RFC asks for it anyway: types 14
    # to 254 are Unassigned in RFC 8956 section 8.1.2, so a type IANA
    # assigns tomorrow will read as malformed here until bgp4r
    # implements it.
    #
    # The octets are kept all the same, so a capture can be sent again.
    # That is the keep-what-you-cannot-read rule in Conventions, and this
    # is the fifth class to follow it. What it keeps is the type octet
    # and **all that was left of this NLRI value**, because an unknown
    # type's parameter length cannot be known, so nothing after it can be
    # read either.
    #
    # That bound is also why there is no generic Nlri::Unknown one level
    # up and there is one here, which an earlier plan got backwards: NLRI
    # list framing is per family and cannot be split without knowing the
    # family, but inside one Flow Specification NLRI the extent is known
    # from the section 4.1 length field, so the remainder is bounded.
    #
    # All three build paths, and the wire one reads the type octet too,
    # since no class constant can supply it:
    #   Unknown.new(99, 'octets')
    #   Unknown.new(wire_bytes)
    #   Unknown.new(:type=>99, :value=>'6f6374657473')
    class Unknown < Component

      HASH_KEY = :unknown

      attr_reader :value

      def initialize(*args)
        @value = +''
        if args.size == 1 and args[0].is_a?(String) and args[0].is_packed?
          parse(args[0])
        elsif args.size == 1 and args[0].is_a?(self.class)
          parse(args[0].encode.is_packed)
        elsif args.size == 1 and args[0].is_a?(Hash)
          h = self.class.unwrap(args[0])
          @type = h[:type].to_i
          @value = [h[:value].to_s].pack('H*')
        elsif (1..2).include?(args.size) and args[0].is_a?(Integer)
          @type = args[0]
          @value = args[1].to_s.b
        else
          raise ArgumentError, "invalid argument: #{args.inspect}, " \
                               "expected (type, value), wire bytes or a hash"
        end
      end

      # The type octet and everything after it, which is the whole point.
      def parse(s)
        @type = s.slice!(0, 1).unpack1('C')
        @value = s.slice!(0, s.size)
        self
      end

      def type
        @type
      end

      def encode
        [@type, @value].pack('Ca*')
      end

      def value_hash
        { :type => @type, :value => @value.unpack1('H*') }
      end

      def to_s
        "Unknown: type #{@type}, #{@value.size} octets [#{@value.unpack1('H*')}]"
      end

    end

    # RFC 8955 section 4.2.2, and RFC 8956 section 8.1.2's registry,
    # which holds "both IPv4 and IPv6 Flow Specification component type
    # numbers in a single registry".

    class Destination_prefix < Prefix_component
      TYPE, AFI, HASH_KEY = 1, IANA::AFI::IPv4, :destination_prefix
    end

    class Source_prefix < Prefix_component
      TYPE, AFI, HASH_KEY = 2, IANA::AFI::IPv4, :source_prefix
    end

    class Destination_ipv6_prefix < Ipv6_prefix_component
      TYPE, HASH_KEY = 1, :destination_ipv6_prefix
    end

    class Source_ipv6_prefix < Ipv6_prefix_component
      TYPE, HASH_KEY = 2, :source_ipv6_prefix
    end

    # RFC 8955 section 4.2.2.3: matches "the IP protocol value octet in
    # IP packet header". "Type 3 component values SHOULD be encoded as
    # single octet (numeric_op len=00)."
    class Ip_protocol < Numeric_component
      TYPE, HASH_KEY = 3, :ip_protocol
    end

    # RFC 8956 section 3.3, the same type number and the same octets
    # under another name: it matches "the first Next Header value octet
    # in IPv6 packets that is not an extension header".
    class Upper_layer_protocol < Ip_protocol
      HASH_KEY = :upper_layer_protocol
    end

    # RFC 8955 section 4.2.2.4: pairs "that match source OR destination
    # TCP/UDP ports". "SHOULD be encoded as 1- or 2-octet quantities."
    class Port < Numeric_component
      TYPE, HASH_KEY = 4, :port
    end

    # RFC 8955 section 4.2.2.5.
    class Destination_port < Numeric_component
      TYPE, HASH_KEY = 5, :destination_port
    end

    # RFC 8955 section 4.2.2.6.
    class Source_port < Numeric_component
      TYPE, HASH_KEY = 6, :source_port
    end

    # RFC 8955 section 4.2.2.7: matches "the type field of an ICMP
    # packet". "SHOULD be encoded as single octet."
    class Icmp_type < Numeric_component
      TYPE, HASH_KEY = 7, :icmp_type
    end

    # RFC 8956 section 3.4, ICMPv6 Type: the same octets, and section
    # 3.4's extra condition is a matching rule and not an encoding.
    class Icmpv6_type < Icmp_type
      HASH_KEY = :icmpv6_type
    end

    # RFC 8955 section 4.2.2.8.
    class Icmp_code < Numeric_component
      TYPE, HASH_KEY = 8, :icmp_code
    end

    # RFC 8956 section 3.5.
    class Icmpv6_code < Icmp_code
      HASH_KEY = :icmpv6_code
    end

    # RFC 8955 section 4.2.2.9: matches "TCP control bits". "Type 9
    # component bitmasks MUST be encoded as 1- or 2-octet bitmask
    # (bitmask_op len=00 or len=01)." A single octet "matches octet 14 of
    # the TCP header"; two octets match "octets 13 and 14 of the TCP
    # header with the data offset (leftmost 4 bits) always treated as 0".
    class Tcp_flags < Bitmask_component
      TYPE, HASH_KEY = 9, :tcp_flags
    end

    # RFC 8955 section 4.2.2.10: matches "the total IP packet length
    # (excluding Layer 2 but including IP header)".
    class Packet_length < Numeric_component
      TYPE, HASH_KEY = 10, :packet_length
    end

    # RFC 8955 section 4.2.2.11: matches "the 6-bit DSCP field". "Type 11
    # component values MUST be encoded as single octet", and "The six
    # least significant bits contain the DSCP value. All other bits
    # SHOULD be treated as 0."
    class Dscp < Numeric_component
      TYPE, HASH_KEY = 11, :dscp
    end

    # RFC 8955 section 4.2.2.12, Figure 4, "Fragment Bitmask Operand":
    # | 0 | 0 | 0 | 0 |LF |FF |IsF|DF |, so the four flags are the low
    # nibble and the high nibble "MUST be set to 0 on NLRI encoding and
    # MUST be ignored during decoding". "The Type 12 component bitmask
    # MUST be encoded as single octet bitmask (bitmask_op len=00)."
    class Fragment < Bitmask_component
      TYPE, HASH_KEY = 12, :fragment

      # From Figure 4 read with bit 7 as the least significant, which
      # section 4.3.3's own example confirms: it encodes "DF or FF" as
      # 0x05.
      DF  = 0x01  # "match if IP Header Flags Bit-1 (DF) is 1"
      ISF = 0x02  # "Is a fragment other than the first"
      FF  = 0x04  # "First Fragment"
      LF  = 0x08  # "Last Fragment"

      # Which bits this class reads, so the rest can be reported as set
      # without being named. Same shape as Extended_community::Typed.
      DEFINED_BITS = DF | ISF | FF | LF
    end

    # RFC 8956 section 3.6, Figure 1: | 0 | 0 | 0 | 0 |LF |FF |IsF| 0 |.
    # The same octet, with the bit IPv4 gives to DF reserved instead,
    # because IPv6 has no Don't Fragment flag.
    class Ipv6_fragment < Fragment
      HASH_KEY = :ipv6_fragment
      DEFINED_BITS = ISF | FF | LF
    end

    # RFC 8956 section 3.7, "Type 13 - Flow Label (new)": pairs "used to
    # match the 20-bit Flow Label IPv6 header field". "Type 13 component
    # values SHOULD be encoded as 4-octet quantities (numeric_op
    # len=10)", which is why this is the one component with a default
    # width wider than its values need.
    class Flow_label_pair < Numeric_pair
      def self.default_len
        2   # (1 << 2) is 4 octets
      end
    end

    class Flow_label < Numeric_component
      TYPE, HASH_KEY = 13, :flow_label

      def self.pair_klass
        Flow_label_pair
      end
    end

  end

end
