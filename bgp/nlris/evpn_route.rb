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
require 'bgp/nlris/rd'
require 'bgp/nlris/label'

module BGP

  # The primitives shared by the eleven EVPN route types, and the base
  # every route type is built on.
  #
  # `docs/evpn.md` is the guide, and every section number here was read
  # in the RFC text rather than recalled. This file opens `class Evpn`
  # and `evpn.rb` reopens it with the NLRI framing, which is how
  # `flow_spec_component.rb` and `flow_spec.rb` are split.
  #
  # Nothing dispatches to any of this yet. The route types come in the
  # parts after this one and the two gates after those, the way #175
  # landed the flow spec components and #156 the FIB planner before
  # anything called either.
  #
  # **Why these four primitives and not eleven layouts.** Reading all
  # eleven route types together rather than one RFC at a time, four
  # shapes carry every field that is not an `Rd` or a `Label`:
  #
  # * the Ethernet Segment Identifier, 10 octets, in route types 1, 2,
  #   4, 7 and 8
  # * the Ethernet Tag ID, 4 octets, in every type but 4 and 11
  # * a 6-octet MAC, route type 2 only
  # * a **length-prefixed address**, a 1-octet length then a variable
  #   address, which carries the IP in types 2, 3, 4 and 5 and the
  #   Multicast Source, Multicast Group and Originator Router triple in
  #   types 6, 7, 8, 10 and 11
  #
  # RFC 9251 calls the third of that triple "Originator Router" and
  # RFC 9572 "Originator's Addr". They are one shape under two names, so
  # there is one class for it here and not two.
  #
  # **Every length field in this family is in bits, not octets**, which
  # is the detail to get right because it is the one memory reverses.
  # RFC 7432 section 7.2: "Both the IP and MAC address lengths are in
  # bits." Section 7.3 and section 7.4 each say "The IP address length
  # is in bits" of their own field. RFC 9251 says it of all three
  # lengths in each of sections 9.1, 9.2 and 9.3. RFC 9136 section 3.1
  # says the IP Prefix Length "specifies the number of bits in the
  # prefix".
  #
  # **RFC 9572 is the one that does not say**, and that is recorded
  # rather than guessed: it has no "in bits" sentence anywhere, and for
  # route type 10 it says only that the route is "identical to the
  # S-PMSI A-D route as defined in [RFC7117]" apart from two added
  # fields, so the units are RFC 7117's. That RFC has not been read
  # here. `Sized` takes the bit count either way, so the question is the
  # route type's to answer and not this file's.
  class Evpn

    # RFC 4364 section 4.2, the Route Distinguisher every route type but
    # 11 opens with. `Rd` owns the encoding; this is how many octets to
    # slice, since it does not consume what it is handed.
    RD_SIZE = 8

    # A 1-octet length in bits followed by its value, the shape behind
    # every variable width field in the family.
    #
    # **It does not infer its own width on parse, and that is
    # deliberate**, because the two fields that use it disagree about
    # what a length other than the natural one means. RFC 7432 section
    # 7.2 gives the IP Address as "(0, 4, or 16 octets)", so its width
    # follows its length, while the MAC Address on the line above is
    # "(6 octets)" flat with a length that is nonetheless in bits. So
    # `parse` is told how many octets to take: `Addr` works it out from
    # the bit count, `Mac_addr` always takes 6. A route type that wants
    # either rule asks for it.
    #
    # Nothing validates, per Conventions. Any bit count with any number
    # of octets, including a count that disagrees with the octets it
    # came with, because a length that lies is a negative test.
    class Sized

      attr_reader :bitlen, :value

      # new('192.0.2.1'), new(32, "\xc0\x00\x02\x01"), the wire octets,
      # this class's own hash, or another instance.
      def initialize(*args)
        @bitlen, @value = 0, +''
        if args.size == 1 and args[0].is_a?(String) and args[0].is_packed?
          parse(args[0])
        elsif args.size == 1 and args[0].is_a?(self.class)
          parse(args[0].encode.is_packed)
        elsif args.size == 1 and args[0].is_a?(Hash)
          from_hash(args[0])
        elsif args.size == 2 and args[0].is_a?(Integer)
          @bitlen, @value = args[0], args[1].to_s.b
        elsif args.size == 1
          from_text(args[0])
        elsif args.empty?
          # The absent field: length 0 and no octets, which RFC 7432
          # section 7.2 allows for the IP Address.
        else
          raise ArgumentError, "invalid argument: #{args.inspect}"
        end
      end

      # How many octets the value occupies for a given bit count. The
      # prefix arithmetic, which is what `Addr` uses and `Mac_addr`
      # overrides.
      def self.octets_for(bitlen)
        (bitlen + 7) / 8
      end

      def parse(s)
        @bitlen = s.slice!(0, 1).unpack1('C')
        n = [self.class.octets_for(@bitlen), s.size].min
        @value = s.slice!(0, n)
        self
      end

      def encode
        [@bitlen, @value].pack('Ca*')
      end

      def to_shex
        encode.unpack1('H*')
      end

      # The number of octets this field occupies on the wire, its length
      # octet included.
      def size
        1 + @value.size
      end

      def empty?
        @bitlen.zero? and @value.empty?
      end

      def to_hash
        { :bitlen => @bitlen, :value => @value.unpack1('H*') }
      end

      def to_s
        return '(none)' if empty?
        "#{@value.unpack1('H*')}/#{@bitlen}"
      end

      private

      def from_hash(h)
        h = h[self.class.hash_key] if h.has_key?(self.class.hash_key)
        return from_text(h) unless h.is_a?(Hash)
        @bitlen = h[:bitlen].to_i
        @value = [h[:value].to_s].pack('H*')
      end

      def from_text(_)
        raise ArgumentError, "#{self.class} cannot be built from text"
      end

    end

    # The IP Address field of route types 2, 3, 4 and 5 and the address
    # triple of 6, 7, 8, 10 and 11: a length in bits whose value is that
    # many bits rounded up to octets.
    #
    # Built from an address string, which sets the bit count from the
    # family, 32 or 128. `Addr.new` with no argument is the absent
    # field, which route type 2 needs.
    class Addr < Sized

      def self.hash_key
        :addr
      end

      # An IPv4 or IPv6 address, from the octets rather than the bit
      # count, since a short length is allowed to lie about the family.
      # nil for anything that is not 4 or 16 octets.
      def address
        case @value.size
        when 4  then IPAddr.new_ntoh(@value).to_s
        when 16 then IPAddr.new_ntoh(@value).to_s
        end
      end

      def to_s
        return '(none)' if empty?
        a = address
        a.nil? ? super : "#{a}/#{@bitlen}"
      end

      private

      def from_text(t)
        ip = IPAddr.new(t.to_s)
        @value = ip.hton
        @bitlen = ip.ipv4? ? 32 : 128
      end

    end

    # The MAC Address field of route type 2. RFC 7432 section 7.2 gives
    # it as 6 octets with a length that is in bits, so 48 is the only
    # length the figure and the sentence agree on, and the field stays 6
    # octets wide whatever the length octet says.
    class Mac_addr < Sized

      WIDTH = 6
      BITS  = 48

      def self.hash_key
        :mac
      end

      # Always 6, per the figure. The length octet is read and echoed
      # and does not change the width.
      def self.octets_for(_bitlen)
        WIDTH
      end

      def to_s
        return '(none)' if empty?
        s = @value.unpack('C*').collect { |b| '%02x' % b }.join(':')
        @bitlen == BITS ? s : "#{s}/#{@bitlen}"
      end

      private

      def from_text(t)
        octets = t.to_s.split(/[:.-]/).collect { |b| b.to_i(16) }
        @value = octets.pack('C*')
        @bitlen = BITS
      end

    end

    # RFC 7432 section 5: "An ESI is encoded as a 10-octet integer in
    # line format with the most significant octet sent first", with the
    # first octet a Type that "specifies the format of the remaining 9
    # octets (ESI Value)" and six types defined, 0x00 to 0x05.
    #
    # Two values are reserved by that section: "ESI 0 denotes a
    # single-homed site" and "ESI {0xFF} (repeated 10 times) is known as
    # MAX-ESI and is reserved".
    #
    # Nothing validates. Any type octet, including the 250 the section
    # does not define, and any value.
    class Esi

      WIDTH = 10

      # Section 5's two reserved values.
      ZERO = ("\x00" * WIDTH).b.freeze
      MAX  = ("\xff" * WIDTH).b.freeze

      attr_reader :value

      def self.hash_key
        :esi
      end

      # new, the all-zero single-homed ESI of section 5
      # new('00:11:22:33:44:55:66:77:88:99')
      # new(0x00112233445566778899)
      # new(1, '0011223344556677 88')  type and 9 octets of value
      # the wire octets, this class's own hash, or another instance.
      def initialize(*args)
        @value = ZERO.dup
        if args.empty?
          # The single-homed ESI.
        elsif args.size == 1 and args[0].is_a?(String) and args[0].is_packed?
          parse(args[0])
        elsif args.size == 1 and args[0].is_a?(self.class)
          parse(args[0].encode.is_packed)
        elsif args.size == 1 and args[0].is_a?(Hash)
          from_hash(args[0])
        elsif args.size == 2 and args[0].is_a?(Integer)
          @value = ([args[0]].pack('C') + hex(args[1])).b
        elsif args.size == 1 and args[0].is_a?(Integer)
          refuse_a_value_the_field_cannot_hold(args[0])
          @value = int_to_octets(args[0])
        elsif args.size == 1
          @value = hex(args[0])
        else
          raise ArgumentError, "invalid argument: #{args.inspect}"
        end
        self
      end

      def parse(s)
        @value = s.slice!(0, WIDTH)
        self
      end

      # A copy, not `@value` itself. `parse` reads with `slice!`, which
      # Conventions records as consuming the String it is handed, so
      # handing out the instance variable makes
      # `Esi.new(esi.encode.is_packed)` empty the ESI it was copying.
      # Found by probing rather than by reading: the round trip came
      # back false while both sides printed the same hex, which is the
      # exact symptom that entry warns about. Every other class in the
      # library packs a fresh String here, so this is also the house
      # style.
      def encode
        @value.dup
      end

      def to_shex
        @value.unpack1('H*')
      end

      def size
        @value.size
      end

      # The Type octet of section 5, nil for an ESI that is not 10
      # octets, since then there is nothing to be sure of.
      def type
        @value.getbyte(0) if @value.size == WIDTH
      end

      def single_homed?
        @value == ZERO
      end

      def max?
        @value == MAX
      end

      def to_hash
        { Esi.hash_key => to_s }
      end

      def to_s
        @value.unpack('C*').collect { |b| '%02x' % b }.join(':')
      end

      private

      def from_hash(h)
        h = h[Esi.hash_key] if h.is_a?(Hash) and h.has_key?(Esi.hash_key)
        if h.is_a?(Hash)
          @value = ([h[:type].to_i].pack('C') + hex(h[:value])).b
        elsif h.is_a?(Integer)
          @value = int_to_octets(h)
        else
          @value = hex(h)
        end
      end

      # Separators optional, so the colon form `to_s` prints reads back.
      def hex(s)
        [s.to_s.gsub(/[^0-9a-fA-F]/, '')].pack('H*').b
      end

      # `pack`, not `String#<<` with an Integer. That appends a
      # **codepoint**, so on a UTF-8 String every octet from 0x80 up
      # becomes the two bytes of its UTF-8 encoding and `.b` afterwards
      # relabels the encoding without undoing the expansion. Found by
      # probing: an ESI of 0x00112233445566778899 came back 12 octets.
      def int_to_octets(i)
        Array.new(WIDTH) { |n| (i >> (8 * (WIDTH - 1 - n))) & 0xff }.pack('C*')
      end

      # The one refusal Conventions allows a constructor: an Integer too
      # large for the field it goes in, because the alternative is
      # silently sending a different value. Section 5 calls an ESI "a
      # 10-octet integer", so 80 bits is the field.
      def refuse_a_value_the_field_cannot_hold(v)
        return if v >= 0 and v < (1 << (8 * WIDTH))
        raise ArgumentError, "ESI #{v} does not fit in #{WIDTH} octets"
      end

    end

    # The Ethernet Tag ID, 4 octets, in every route type but 4 and 11.
    #
    # RFC 7432 section 7.1 and the sections after it carry it as an
    # opaque 4-octet identifier. Section 6 names one value: "the
    # Ethernet Tag ID MUST be set to the default Ethernet tag value of
    # 0" for a VLAN-based service interface, and the all-ones value is
    # MAX-ET.
    class Ethernet_tag_id

      WIDTH  = 4
      MAX_ET = 0xffffffff

      attr_reader :value

      def self.hash_key
        :ethernet_tag_id
      end

      # new, the default tag 0 of section 6
      # new(100)
      # the wire octets, this class's own hash, or another instance.
      def initialize(*args)
        @value = 0
        if args.empty?
          # The default Ethernet tag.
        elsif args.size == 1 and args[0].is_a?(String) and args[0].is_packed?
          parse(args[0])
        elsif args.size == 1 and args[0].is_a?(self.class)
          parse(args[0].encode.is_packed)
        elsif args.size == 1 and args[0].is_a?(Hash)
          h = args[0]
          h = h[Ethernet_tag_id.hash_key] if h.has_key?(Ethernet_tag_id.hash_key)
          @value = h.to_i
        elsif args.size == 1 and args[0].is_a?(Integer)
          refuse_a_value_the_field_cannot_hold(args[0])
          @value = args[0]
        else
          raise ArgumentError, "invalid argument: #{args.inspect}"
        end
        self
      end

      def parse(s)
        @value = s.slice!(0, WIDTH).unpack1('N')
        self
      end

      def encode
        [@value].pack('N')
      end

      def to_shex
        encode.unpack1('H*')
      end

      def size
        WIDTH
      end

      def max_et?
        @value == MAX_ET
      end

      def to_hash
        { Ethernet_tag_id.hash_key => @value }
      end

      def to_s
        max_et? ? 'MAX-ET' : @value.to_s
      end

      private

      # The one refusal Conventions allows a constructor: an Integer too
      # large for the field it goes in, because the alternative is
      # silently sending a different value. A value the RFC merely does
      # not describe still builds.
      def refuse_a_value_the_field_cannot_hold(v)
        return if v >= 0 and v <= MAX_ET
        raise ArgumentError,
              "Ethernet Tag ID #{v} does not fit in #{WIDTH} octets"
      end

    end

    # The base every route type is built on. A route owns its body and
    # its type number; the Route Type and Length octets of RFC 7432
    # section 7 are written by `Evpn`, which is the NLRI.
    class Route

      def self.type
        self::TYPE
      end

      # The key this route type takes in an Evpn hash, one per class.
      def self.hash_key
        self::HASH_KEY
      end

      def type
        self.class.type
      end

      # The Route Type specific field, without the two framing octets.
      def encode
        encode_value
      end

      def to_shex
        encode.unpack1('H*')
      end

      def to_hash
        { self.class.hash_key => value_hash }
      end

      # The one Hash a build may be handed that is this route's own
      # wrapped hash rather than its field hash.
      def self.unwrap(h)
        return h unless h.is_a?(Hash)
        h.has_key?(hash_key) ? h[hash_key] : h
      end

      private

      # **`Rd` does not consume the String it is handed, where the four
      # primitives in this file do.** Measured, not assumed: `Esi`,
      # `Addr`, `Mac_addr` and `Ethernet_tag_id` all read with `slice!`,
      # so a sequential parse walks forward by itself, and `Rd#parse`
      # leaves its octets where they were. Conventions records that
      # which classes consume is per class and has to be checked. So the
      # RD is sliced here and the rest read themselves.
      def read_rd(s)
        Rd.new(s.slice!(0, RD_SIZE).is_packed)
      end

      # Each field accepts either an instance of its own class or
      # whatever that class builds from, so a route reads as values
      # without the caller naming five classes.
      #
      # **An Array is splatted**, because that is the shape these
      # classes' own hashes use for a multi-argument field: `Rd#to_hash`
      # answers `{:rd => [100, 200]}` and `Rd.new` takes
      # `(100, 200)`, so without the splat the Array lands in the
      # Administrator field and `encode` dies on a nil Assigned Number.
      # It also makes `Esi`'s two argument form reachable as
      # `[1, '0011...']`.
      def coerce(klass, v)
        return v if v.is_a?(klass)
        v.is_a?(Array) ? klass.new(*v) : klass.new(v)
      end

      # The same, for a field that may be left out entirely.
      def coerce_or_default(klass, v)
        return klass.new if v.nil?
        coerce(klass, v)
      end

      # **`Label` is the one field that cannot default through
      # `coerce_or_default`**, because `BGP::Label.new` with no argument
      # leaves its label unset and `encode` then dies in `Label#encode`
      # with "undefined method `<<' for false". So a label left out
      # means label 0, written here once rather than in each route type.
      #
      # This is a bug #182 shipped: `Ethernet_ad.new(rd, esi, tag)` with
      # the label omitted raised `NoMethodError`, where the four
      # argument form and the no argument form both worked. Found while
      # writing route type 2, which has the same shape twice over.
      def coerce_label(v)
        return Label.new(0) if v.nil?
        coerce(Label, v)
      end

    end

    # A Route Type bgp4r does not implement, kept whole and written back
    # so a capture replays byte for byte.
    #
    # **The reasoning is the one `Flow_spec::Component::Unknown`
    # recorded, and it reaches the same answer for the same reason.**
    # What breadth buys over #116 is meaning, since an `Attr::Raw`
    # already replays the octets of an EVPN UPDATE today, so raising
    # here would give back exactly what #116 gives while costing the
    # known route types their meaning. And the remainder is bounded,
    # because section 7's Length field says how long the body is, which
    # is why this can keep it where a generic `Nlri::Unknown` could not.
    class Unknown < Route

      HASH_KEY = :unknown

      attr_reader :value

      def initialize(*args)
        @type, @value = 0, +''
        if args.size == 1 and args[0].is_a?(self.class)
          @type = args[0].type
          @value = args[0].value.dup
        elsif args.size == 1 and args[0].is_a?(Hash)
          h = self.class.unwrap(args[0])
          @type = h[:type].to_i
          @value = [h[:value].to_s].pack('H*')
        elsif (1..2).include?(args.size) and args[0].is_a?(Integer)
          @type = args[0]
          @value = args[1].to_s.b
        else
          raise ArgumentError, "invalid argument: #{args.inspect}, " \
                               'expected (type, value) or a hash'
        end
        self
      end

      # The type arrives from the framing rather than from the body, so
      # unlike every other route type this one carries its own.
      def type
        @type
      end

      # A copy, for the reason `Esi#encode` gives.
      def encode_value
        @value.dup
      end

      def value_hash
        { :type => @type, :value => @value.unpack1('H*') }
      end

      def to_s
        "Unknown route type #{@type}, #{@value.size} octets " \
        "[#{@value.unpack1('H*')}]"
      end

    end

    # Route type 1, RFC 7432 section 7.1, the Ethernet Auto-discovery
    # route. Fixed at 25 octets:
    #
    #   +---------------------------------------+
    #   |  Route Distinguisher (RD) (8 octets)  |
    #   +---------------------------------------+
    #   |Ethernet Segment Identifier (10 octets)|
    #   +---------------------------------------+
    #   |  Ethernet Tag ID (4 octets)           |
    #   +---------------------------------------+
    #   |  MPLS Label (3 octets)                |
    #   +---------------------------------------+
    #
    # **`BGP::Label` is reused rather than reimplemented.** Section 7.1
    # says only "MPLS Label (3 octets)" and describes no internal
    # layout, and `Label` already writes the 20-bit label in the top 20
    # bits of three octets, which is what GoBGP and FRR read back. It
    # also keeps the three bits below and the low bit, so an unusual
    # value replays. Section 7.1 adds that "The MPLS Label field is to
    # be treated as a route attribute as opposed to being part of the
    # route", which is BGP route key processing and matters to a RIB,
    # not to an encoder; no EVPN route goes in a RIB by the recorded
    # decision.
    class Ethernet_ad < Route

      TYPE, HASH_KEY = 1, :ethernet_ad

      SIZE = 25

      attr_reader :rd, :esi, :ethernet_tag_id, :label

      # new(rd, esi, ethernet_tag_id, label) in the figure's order, with
      # each field either an instance or whatever its class builds from
      # new(:rd => [100, 200], :esi => '00:11:...', :ethernet_tag_id =>
      #     100, :label => 500)
      # the wire bytes, or another instance.
      def initialize(*args)
        if args.size == 1 and args[0].is_a?(String) and args[0].is_packed?
          parse(args[0])
        elsif args.size == 1 and args[0].is_a?(self.class)
          parse(args[0].encode.is_packed)
        elsif args.size == 1 and args[0].is_a?(Hash)
          from_hash(args[0])
        elsif (1..4).include?(args.size)
          @rd              = coerce_or_default(Rd, args[0])
          @esi             = coerce_or_default(Esi, args[1])
          @ethernet_tag_id = coerce_or_default(Ethernet_tag_id, args[2])
          @label           = coerce_label(args[3])
        elsif args.empty?
          defaults
        else
          raise ArgumentError, "invalid argument: #{args.inspect}"
        end
        self
      end

      def parse(s)
        @rd              = read_rd(s)
        @esi             = Esi.new(s)
        @ethernet_tag_id = Ethernet_tag_id.new(s)
        @label           = Label.new(s)
        self
      end

      def encode_value
        [@rd.encode, @esi.encode, @ethernet_tag_id.encode,
         @label.encode].join
      end

      # The Label's own hash keys, :label and :exp, are merged flat
      # rather than nested, because neither collides with a field here
      # and `{:label => {:label => 500}}` reads worse than `:label =>
      # 500`. `:bottom` joins them only when the low bit arrived 0,
      # which is `Label#to_hash`'s own extra-key-only-when-unusual rule.
      def value_hash
        @rd.to_hash
           .merge(@esi.to_hash)
           .merge(@ethernet_tag_id.to_hash)
           .merge(@label.to_hash)
      end

      def to_s
        "[1] Ethernet A-D: #{@rd.to_s(false)}, ESI #{@esi}, " \
        "tag #{@ethernet_tag_id}, label #{@label.label}"
      end

      private

      def defaults
        @rd              = Rd.new
        @esi             = Esi.new
        @ethernet_tag_id = Ethernet_tag_id.new
        @label           = Label.new(0)
      end

      def from_hash(h)
        h = self.class.unwrap(h)
        @rd              = coerce_or_default(Rd, h[:rd])
        @esi             = coerce_or_default(Esi, h[:esi])
        @ethernet_tag_id = coerce_or_default(Ethernet_tag_id,
                                             h[:ethernet_tag_id])
        @label           = Label.new(h)
      end

    end

    # Route type 4, RFC 7432 section 7.4, the Ethernet Segment route.
    # 23 octets with an IPv4 address and 35 with an IPv6 one:
    #
    #   +---------------------------------------+
    #   |  RD (8 octets)                        |
    #   +---------------------------------------+
    #   |Ethernet Segment Identifier (10 octets)|
    #   +---------------------------------------+
    #   |  IP Address Length (1 octet)          |
    #   +---------------------------------------+
    #   |  Originating Router's IP Address      |
    #   |          (4 or 16 octets)             |
    #   +---------------------------------------+
    #
    # Section 7.4: "The IP address length is in bits", which is why the
    # address is an `Addr` and its width follows its length.
    class Ethernet_segment < Route

      TYPE, HASH_KEY = 4, :ethernet_segment

      # The two lengths the section's figure allows, which the Length
      # octet of the NLRI carries. Neither is enforced: nothing
      # validates on the way out.
      SIZE_V4 = 23
      SIZE_V6 = 35

      attr_reader :rd, :esi, :ip

      # new(rd, esi, ip), new(:rd => ..., :esi => ..., :ip =>
      # '192.0.2.1'), the wire bytes, or another instance.
      def initialize(*args)
        if args.size == 1 and args[0].is_a?(String) and args[0].is_packed?
          parse(args[0])
        elsif args.size == 1 and args[0].is_a?(self.class)
          parse(args[0].encode.is_packed)
        elsif args.size == 1 and args[0].is_a?(Hash)
          from_hash(args[0])
        elsif (1..3).include?(args.size)
          @rd  = coerce_or_default(Rd, args[0])
          @esi = coerce_or_default(Esi, args[1])
          @ip  = coerce_or_default(Addr, args[2])
        elsif args.empty?
          @rd, @esi, @ip = Rd.new, Esi.new, Addr.new
        else
          raise ArgumentError, "invalid argument: #{args.inspect}"
        end
        self
      end

      def parse(s)
        @rd  = read_rd(s)
        @esi = Esi.new(s)
        @ip  = Addr.new(s)
        self
      end

      def encode_value
        [@rd.encode, @esi.encode, @ip.encode].join
      end

      # The address under one `:ip` key. It is the address string when
      # the octets are a whole family and the bit count agrees, and the
      # `Addr` hash otherwise, so a length that lies still reads back.
      # Same spirit as the `:tail` and `:bits` rule: the plain form
      # unless something unusual arrived.
      def value_hash
        @rd.to_hash.merge(@esi.to_hash).merge(:ip => ip_hash)
      end

      def to_s
        "[4] Ethernet Segment: #{@rd.to_s(false)}, ESI #{@esi}, " \
        "originating router #{@ip}"
      end

      private

      def ip_hash
        a = @ip.address
        return @ip.to_hash if a.nil?
        return @ip.to_hash unless @ip.bitlen == (@ip.value.size * 8)
        a
      end

      def from_hash(h)
        h = self.class.unwrap(h)
        @rd  = coerce_or_default(Rd, h[:rd])
        @esi = coerce_or_default(Esi, h[:esi])
        @ip  = coerce_or_default(Addr, h[:ip])
      end

    end

    # Route type 2, RFC 7432 section 7.2, the MAC/IP Advertisement
    # route. The largest layout in the family, and the only one variable
    # in two independent ways:
    #
    #   +---------------------------------------+
    #   |  RD (8 octets)                        |
    #   +---------------------------------------+
    #   |Ethernet Segment Identifier (10 octets)|
    #   +---------------------------------------+
    #   |  Ethernet Tag ID (4 octets)           |
    #   +---------------------------------------+
    #   |  MAC Address Length (1 octet)         |
    #   +---------------------------------------+
    #   |  MAC Address (6 octets)               |
    #   +---------------------------------------+
    #   |  IP Address Length (1 octet)          |
    #   +---------------------------------------+
    #   |  IP Address (0, 4, or 16 octets)      |
    #   +---------------------------------------+
    #   |  MPLS Label1 (3 octets)               |
    #   +---------------------------------------+
    #   |  MPLS Label2 (0 or 3 octets)          |
    #   +---------------------------------------+
    #
    # **Section 14 is where the field rules are, not section 7.2.** The
    # MAC: "The MAC Address Length field is in bits, and it is set to
    # 48. MAC address length values other than 48 bits are outside the
    # scope of this document." Outside the scope is not an error, which
    # is why `Mac_addr` echoes any length and keeps its 6 octets. The
    # IP: "The IP Address field is optional. By default, the IP Address
    # Length field is set to 0, and the IP Address field is omitted from
    # the route", and when present it "is set to 32 or 128 bits". And
    # Label2: "The MPLS Label2 field is an optional field. If it is
    # present, then it is encoded as 3 octets, where the high-order 20
    # bits contain the label value."
    #
    # **So six lengths are possible and all six are distinct**: 33, 36,
    # 37, 40, 49 and 52. That is what lets section 14 say "The Length
    # field of the EVPN NLRI ... is sufficient to determine whether an
    # IP address is encoded in this route and, if so, whether the
    # encoded IP address is IPv4 or IPv6." bgp4r does not use the outer
    # Length for it: the IP Address Length field is the in-band
    # discriminator and `Addr` reads it directly. The two can only
    # disagree on a malformed route, and part 2's encode-matches rule
    # catches that by falling back to `Unknown`.
    #
    # **Label2 is decided by what is left**, which is sound because the
    # body is bounded: `Evpn` slices exactly Length octets and hands
    # them here. Fewer than 3 octets left is not a Label2 and not an
    # error here either; `encode` then will not reproduce the body and
    # the NLRI falls back to `Unknown`.
    class Mac_ip_advertisement < Route

      TYPE, HASH_KEY = 2, :mac_ip_advertisement

      # Section 14 again, for the two optional fields.
      LABEL_SIZE = 3

      attr_reader :rd, :esi, :ethernet_tag_id, :mac, :ip, :label1, :label2

      # new(rd, esi, tag, mac, ip, label1, label2) in the figure order,
      # with ip and label2 optional
      # new(:rd => [100, 200], :esi => '00:11:...', :ethernet_tag_id =>
      #     100, :mac => '00:11:22:33:44:55', :ip => '192.0.2.1',
      #     :label1 => 500, :label2 => 501)
      # the wire bytes, or another instance.
      def initialize(*args)
        if args.size == 1 and args[0].is_a?(String) and args[0].is_packed?
          parse(args[0])
        elsif args.size == 1 and args[0].is_a?(self.class)
          parse(args[0].encode.is_packed)
        elsif args.size == 1 and args[0].is_a?(Hash)
          from_hash(args[0])
        elsif (1..7).include?(args.size)
          @rd              = coerce_or_default(Rd, args[0])
          @esi             = coerce_or_default(Esi, args[1])
          @ethernet_tag_id = coerce_or_default(Ethernet_tag_id, args[2])
          @mac             = coerce_or_default(Mac_addr, args[3])
          @ip              = coerce_or_default(Addr, args[4])
          @label1          = coerce_label(args[5])
          @label2          = args[6].nil? ? nil : coerce(Label, args[6])
        elsif args.empty?
          defaults
        else
          raise ArgumentError, "invalid argument: #{args.inspect}"
        end
        self
      end

      def parse(s)
        @rd              = read_rd(s)
        @esi             = Esi.new(s)
        @ethernet_tag_id = Ethernet_tag_id.new(s)
        @mac             = Mac_addr.new(s)
        @ip              = Addr.new(s)
        @label1          = Label.new(s)
        @label2          = s.size >= LABEL_SIZE ? Label.new(s) : nil
        self
      end

      def encode_value
        [@rd.encode, @esi.encode, @ethernet_tag_id.encode, @mac.encode,
         @ip.encode, @label1.encode,
         @label2 ? @label2.encode : +''].join
      end

      # **The two labels are named rather than merged flat**, which is
      # where this differs from route type 1 and the reason is the
      # count: one label can merge its own `:label` and `:exp` keys into
      # the route's hash because nothing collides, and two cannot. So
      # each rides under its own key holding `Label`'s own hash.
      # `:label2` appears only when there is one, which is the
      # extra-key-only-when-present rule.
      def value_hash
        h = @rd.to_hash
                .merge(@esi.to_hash)
                .merge(@ethernet_tag_id.to_hash)
                .merge(:mac => mac_hash, :ip => ip_hash,
                       :label1 => @label1.to_hash)
        h = h.merge(:label2 => @label2.to_hash) if @label2
        h
      end

      def to_s
        s = "[2] MAC/IP: #{@rd.to_s(false)}, ESI #{@esi}, " \
            "tag #{@ethernet_tag_id}, MAC #{@mac}, IP #{@ip}, " \
            "label #{@label1.label}"
        s += ", label2 #{@label2.label}" if @label2
        s
      end

      private

      # **The MAC defaults to 48 zero bits and the IP to absent, and the
      # difference is the RFC's.** Section 14 makes the IP optional in
      # so many words, "By default, the IP Address Length field is set
      # to 0, and the IP Address field is omitted from the route", while
      # the MAC is 6 octets in the figure with a length that "is set to
      # 48". So an empty route type 2 is 33 octets, the shortest shape
      # the document describes, rather than the 27 a MAC defaulted to
      # absent would give. A MAC left out entirely still builds, since
      # nothing validates; it is just not the default.
      def defaults
        @rd              = Rd.new
        @esi             = Esi.new
        @ethernet_tag_id = Ethernet_tag_id.new
        @mac             = Mac_addr.new('00:00:00:00:00:00')
        @ip              = Addr.new
        @label1          = Label.new(0)
        @label2          = nil
      end

      # The MAC as its printed form when the length is the 48 section 14
      # names, and the `Sized` hash otherwise so a length outside the
      # scope of the document still reads back.
      def mac_hash
        @mac.bitlen == Mac_addr::BITS ? @mac.to_s : @mac.to_hash
      end

      # As route type 4 does: the address string when the octets are a
      # whole family and the bit count agrees, the `Addr` hash
      # otherwise, and nothing to say when the field is absent.
      def ip_hash
        return @ip.to_hash if @ip.empty?
        a = @ip.address
        return @ip.to_hash if a.nil?
        return @ip.to_hash unless @ip.bitlen == (@ip.value.size * 8)
        a
      end

      def from_hash(h)
        h = self.class.unwrap(h)
        @rd              = coerce_or_default(Rd, h[:rd])
        @esi             = coerce_or_default(Esi, h[:esi])
        @ethernet_tag_id = coerce_or_default(Ethernet_tag_id,
                                             h[:ethernet_tag_id])
        @mac             = coerce_or_default(Mac_addr, h[:mac])
        @ip              = coerce_or_default(Addr, h[:ip])
        @label1          = coerce_label(h[:label1])
        @label2          = h[:label2].nil? ? nil : coerce(Label, h[:label2])
      end

    end

    # Route type 3, RFC 7432 section 7.3, the Inclusive Multicast
    # Ethernet Tag route. 17 octets with an IPv4 address and 29 with an
    # IPv6 one:
    #
    #   +---------------------------------------+
    #   |  RD (8 octets)                        |
    #   +---------------------------------------+
    #   |  Ethernet Tag ID (4 octets)           |
    #   +---------------------------------------+
    #   |  IP Address Length (1 octet)          |
    #   +---------------------------------------+
    #   |  Originating Router's IP Address      |
    #   |          (4 or 16 octets)             |
    #   +---------------------------------------+
    #
    # **The only one of the five with no Ethernet Segment Identifier**,
    # which is worth knowing because every other RFC 7432 and RFC 9136
    # route type has one and a reader will look for it. Section 7.3 ends
    # "The IP address length is in bits", as 7.2 and 7.4 do.
    class Inclusive_multicast < Route

      TYPE, HASH_KEY = 3, :inclusive_multicast

      SIZE_V4 = 17
      SIZE_V6 = 29

      attr_reader :rd, :ethernet_tag_id, :ip

      # new(rd, ethernet_tag_id, ip), new(:rd => ..., :ethernet_tag_id
      # => ..., :ip => '192.0.2.1'), the wire bytes, or another instance.
      def initialize(*args)
        if args.size == 1 and args[0].is_a?(String) and args[0].is_packed?
          parse(args[0])
        elsif args.size == 1 and args[0].is_a?(self.class)
          parse(args[0].encode.is_packed)
        elsif args.size == 1 and args[0].is_a?(Hash)
          from_hash(args[0])
        elsif (1..3).include?(args.size)
          @rd              = coerce_or_default(Rd, args[0])
          @ethernet_tag_id = coerce_or_default(Ethernet_tag_id, args[1])
          @ip              = coerce_or_default(Addr, args[2])
        elsif args.empty?
          @rd, @ethernet_tag_id, @ip = Rd.new, Ethernet_tag_id.new, Addr.new
        else
          raise ArgumentError, "invalid argument: #{args.inspect}"
        end
        self
      end

      def parse(s)
        @rd              = read_rd(s)
        @ethernet_tag_id = Ethernet_tag_id.new(s)
        @ip              = Addr.new(s)
        self
      end

      def encode_value
        [@rd.encode, @ethernet_tag_id.encode, @ip.encode].join
      end

      def value_hash
        @rd.to_hash.merge(@ethernet_tag_id.to_hash).merge(:ip => ip_hash)
      end

      def to_s
        "[3] Inclusive Multicast: #{@rd.to_s(false)}, " \
        "tag #{@ethernet_tag_id}, originating router #{@ip}"
      end

      private

      def ip_hash
        a = @ip.address
        return @ip.to_hash if a.nil?
        return @ip.to_hash unless @ip.bitlen == (@ip.value.size * 8)
        a
      end

      def from_hash(h)
        h = self.class.unwrap(h)
        @rd              = coerce_or_default(Rd, h[:rd])
        @ethernet_tag_id = coerce_or_default(Ethernet_tag_id,
                                             h[:ethernet_tag_id])
        @ip              = coerce_or_default(Addr, h[:ip])
      end

    end

    # Route type 5, RFC 9136 section 3.1, the IP Prefix route. The one
    # fixed length layout in the family: **34 octets with IPv4
    # addresses and 58 with IPv6 ones**, which the section states
    # outright, "The Length field of the BGP EVPN NLRI for an EVPN IP
    # Prefix route MUST be either 34 (if IPv4 addresses are carried) or
    # 58 (if IPv6 addresses are carried)."
    #
    #   +---------------------------------------+
    #   |      RD (8 octets)                    |
    #   +---------------------------------------+
    #   |Ethernet Segment Identifier (10 octets)|
    #   +---------------------------------------+
    #   |  Ethernet Tag ID (4 octets)           |
    #   +---------------------------------------+
    #   |  IP Prefix Length (1 octet, 0 to 128) |
    #   +---------------------------------------+
    #   |  IP Prefix (4 or 16 octets)           |
    #   +---------------------------------------+
    #   |  GW IP Address (4 or 16 octets)       |
    #   +---------------------------------------+
    #   |  MPLS Label (3 octets)                |
    #   +---------------------------------------+
    #
    # **Two things make this layout unlike every other route type, and
    # both are easy to get wrong.**
    #
    # First, the IP Prefix Length octet is a **prefix length and not a
    # field width**. Section 3.1: it "can be set to a value between 0
    # and 32 (bits) for IPv4 and between 0 and 128 for IPv6, and it
    # specifies the number of bits in the prefix", while "The IP prefix
    # is a 4- or 16-octet field". So the prefix is **not** packed down
    # to its length the way `Prefix` packs one: 10.0.0.0/8 still
    # occupies four whole octets. `Addr` is therefore wrong here, since
    # its width follows its length.
    #
    # Second, the **GW IP Address has no length octet at all**. It is
    # "a 4- or 16-octet field (IPv4 or IPv6)" and nothing precedes it,
    # so it is raw octets.
    #
    # **So the family comes from the body's size**, 34 or 58, which is
    # the same information the outer Length carries and is available
    # locally. That keeps this class readable in its own right, the way
    # every other route type is, and it is the one place in the family
    # where there is no in-band discriminator to prefer instead.
    #
    # Nothing validates. A prefix length above 128, which section 3.1
    # says MUST NOT happen, still builds; so do a prefix and a gateway
    # of different families, which the same section says MUST NOT
    # happen; and so does a body that is neither 34 nor 58.
    class Ip_prefix_route < Route

      TYPE, HASH_KEY = 5, :ip_prefix_route

      # The two body lengths section 3.1 allows. These are the Route
      # Type specific field, so the NLRI on the wire is two octets
      # longer than each.
      SIZE_V4 = 34
      SIZE_V6 = 58

      V4_WIDTH = 4
      V6_WIDTH = 16

      attr_reader :rd, :esi, :ethernet_tag_id, :prefix_len, :label

      # The prefix and the gateway as raw octets, whatever width they
      # were given. The readers below put them in address form.
      attr_reader :prefix_octets, :gw_octets

      # new(rd, esi, ethernet_tag_id, '10.0.0.0/8', '10.0.0.1', label),
      # where the prefix string gives the length, the octets and the
      # family in one
      # new(:rd => [100, 200], :esi => ..., :ethernet_tag_id => 100,
      #     :ip_prefix => '10.0.0.0/8', :gateway => '10.0.0.1',
      #     :label => 500)
      # the wire bytes, or another instance.
      def initialize(*args)
        if args.size == 1 and args[0].is_a?(String) and args[0].is_packed?
          parse(args[0])
        elsif args.size == 1 and args[0].is_a?(self.class)
          parse(args[0].encode.is_packed)
        elsif args.size == 1 and args[0].is_a?(Hash)
          from_hash(args[0])
        elsif (1..6).include?(args.size)
          @rd              = coerce_or_default(Rd, args[0])
          @esi             = coerce_or_default(Esi, args[1])
          @ethernet_tag_id = coerce_or_default(Ethernet_tag_id, args[2])
          set_prefix(args[3])
          set_gateway(args[4])
          @label           = coerce_label(args[5])
        elsif args.empty?
          defaults
        else
          raise ArgumentError, "invalid argument: #{args.inspect}"
        end
        self
      end

      # The body's own size says which family, since nothing inside it
      # does. A body that is neither 34 nor 58 is read as IPv4 and will
      # not reproduce its octets, so `Evpn` falls back to `Unknown` and
      # the capture replays: the encode-matches rule from #182 carrying
      # the case this layout cannot represent.
      def parse(s)
        w = s.size >= SIZE_V6 ? V6_WIDTH : V4_WIDTH
        @rd              = read_rd(s)
        @esi             = Esi.new(s)
        @ethernet_tag_id = Ethernet_tag_id.new(s)
        @prefix_len      = s.slice!(0, 1).unpack1('C')
        @prefix_octets   = s.slice!(0, [w, s.size].min)
        @gw_octets       = s.slice!(0, [w, s.size].min)
        @label           = Label.new(s)
        self
      end

      def encode_value
        [@rd.encode, @esi.encode, @ethernet_tag_id.encode,
         [@prefix_len].pack('C'), @prefix_octets, @gw_octets,
         @label.encode].join
      end

      # True when the octets held are IPv6 wide. Read off the prefix,
      # since that is what section 3.1's two figures are keyed on.
      def v6?
        @prefix_octets.size == V6_WIDTH
      end

      # The prefix in address form, "10.0.0.0/8".
      #
      # **nil when the octets are neither 4 nor 16, and also when the
      # length does not fit the family those octets are.** The second
      # half was a bug found by probing: section 3.1 says the length
      # "MUST NOT be greater than 128", nothing validates so 200 builds,
      # and `"10.0.0.0/200"` is a string `IPAddr` refuses, so the hash
      # did not read back. An out-of-range length is part of the unusual
      # case and belongs in the `{:len, :octets}` form with it.
      def ip_prefix
        a = address(@prefix_octets)
        return nil if a.nil?
        return nil if @prefix_len > (v6? ? 128 : 32)
        "#{a}/#{@prefix_len}"
      end

      # Section 3.1: "The GW IP field MUST be all bytes zero if it is
      # not used as an Overlay Index."
      def gateway
        address(@gw_octets)
      end

      def gateway_zero?
        !@gw_octets.empty? and @gw_octets.each_byte.all?(&:zero?)
      end

      # One label, so its keys merge flat as route type 1's do. The
      # prefix and the gateway hash as address strings when the octets
      # are a whole family, and as hex otherwise, which is the
      # extra-detail-only-when-unusual rule the family already uses.
      def value_hash
        h = @rd.to_hash
                .merge(@esi.to_hash)
                .merge(@ethernet_tag_id.to_hash)
        h = h.merge(prefix_hash).merge(gateway_hash)
        h.merge(@label.to_hash)
      end

      def to_s
        "[5] IP Prefix: #{@rd.to_s(false)}, ESI #{@esi}, " \
        "tag #{@ethernet_tag_id}, prefix #{ip_prefix || prefix_hex}, " \
        "gateway #{gateway || gw_hex}, label #{@label.label}"
      end

      private

      def defaults
        @rd              = Rd.new
        @esi             = Esi.new
        @ethernet_tag_id = Ethernet_tag_id.new
        @prefix_len      = 0
        @prefix_octets   = ("\x00" * V4_WIDTH).b
        @gw_octets       = ("\x00" * V4_WIDTH).b
        @label           = Label.new(0)
      end

      # A prefix string sets the length, the octets and the width at
      # once. A Hash with :len and :octets is the way to write a pair
      # the RFC does not allow, which a negative test wants.
      def set_prefix(v)
        case v
        when nil
          @prefix_len, @prefix_octets = 0, ("\x00" * V4_WIDTH).b
        when Hash
          @prefix_len    = v[:len].to_i
          @prefix_octets = [v[:octets].to_s].pack('H*').b
        else
          ip = IPAddr.new(v.to_s)
          @prefix_len    = v.to_s.include?('/') ? ip.prefix : (ip.ipv4? ? 32 : 128)
          @prefix_octets = ip.hton
        end
      end

      def set_gateway(v)
        @gw_octets = case v
                     when nil  then ("\x00" * @prefix_octets.size).b
                     when Hash then [v[:octets].to_s].pack('H*').b
                     else IPAddr.new(v.to_s).hton
                     end
      end

      def address(octets)
        return nil unless [V4_WIDTH, V6_WIDTH].include?(octets.size)
        IPAddr.new_ntoh(octets).to_s
      end

      def prefix_hex
        "#{@prefix_octets.unpack1('H*')}/#{@prefix_len}"
      end

      def gw_hex
        @gw_octets.unpack1('H*')
      end

      def prefix_hash
        a = ip_prefix
        return { :ip_prefix => a } if a
        { :ip_prefix => { :len => @prefix_len,
                          :octets => @prefix_octets.unpack1('H*') } }
      end

      def gateway_hash
        a = gateway
        return { :gateway => a } if a
        { :gateway => { :octets => @gw_octets.unpack1('H*') } }
      end

      def from_hash(h)
        h = self.class.unwrap(h)
        @rd              = coerce_or_default(Rd, h[:rd])
        @esi             = coerce_or_default(Esi, h[:esi])
        @ethernet_tag_id = coerce_or_default(Ethernet_tag_id,
                                             h[:ethernet_tag_id])
        set_prefix(h[:ip_prefix])
        set_gateway(h[:gateway])
        @label           = coerce_label(h)
      end

    end

  end

end
