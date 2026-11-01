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

module BGP

  # The fields the MCAST-VPN route types of RFC 6514 section 4 share,
  # with the `Route` base and `Mcast_vpn::Unknown` under them. The NLRI
  # that carries them is in `mcast_vpn.rb`, which requires this file and
  # reopens this class, the way `evpn.rb` does for `evpn_route.rb`.
  #
  # `docs/mcast-vpn.md` is the guide. Every section number here was read
  # in the RFC text on 2026-10-31. Nothing dispatches to this file yet.
  #
  # **Why these three primitives and not seven layouts.** Reading all
  # seven of section 4's layouts together rather than one subsection at
  # a time, three field shapes carry everything the route types are made
  # of beyond the Route Distinguisher that `BGP::Rd` already gives:
  #
  #   A **length prefixed address**, a length in bits then that many
  #   bits rounded up to octets. That is the Multicast Source and the
  #   Multicast Group of route types 3, 5, 6 and 7, so `Addr` serves
  #   eight fields across four layouts.
  #
  #   A **4-octet Source AS**, in route types 2, 6 and 7.
  #
  #   A **trailing address with no length field at all**, the
  #   Originating Router's IP Address of route types 1, 3 and 4.
  #
  # **The primitives are this family's own and not EVPN's**, which is a
  # decision with a cost and is recorded with its mechanism in
  # `docs/mcast-vpn.md` rather than left to look like an oversight.
  # `Addr` here and `Evpn::Addr` have the same shape, and the sharing is
  # by citation rather than coincidence, since EVPN route type 10 is
  # "identical to the S-PMSI A-D route as defined in [RFC7117]", which
  # carries this encoding. What is on the other side is #173's argument:
  # sharing removes no code today and bets on a third family.
  #
  # **Every length field in this family is in bits**, which is the
  # detail memory reverses, and RFC 6514 section 4.3 says it by value
  # rather than by the word: "If the Multicast Source field contains an
  # IPv4 address, then the value of the Multicast Source Length field is
  # 32", and 128 for IPv6, with the same pair of sentences for the
  # Multicast Group. 32 for four octets is a bit count.
  class Mcast_vpn

    # RFC 6514 section 4.1: "RD (8 octets)", and every route type but 4
    # starts with one.
    RD_SIZE = 8

    # The Multicast Source and Multicast Group fields of RFC 6514
    # sections 4.3, 4.5 and 4.6: a 1-octet length in bits, then that
    # many bits rounded up to octets.
    #
    #   +-----------------------------------+
    #   |  Multicast Source Length (1 octet)|
    #   +-----------------------------------+
    #   |  Multicast Source (variable)      |
    #   +-----------------------------------+
    #
    # **Any length is echoed rather than refused**, and the RFC asks for
    # that rather than merely allowing it: section 4.3 adds "Usage of
    # other values of the Multicast Source Length and Multicast Group
    # Length fields is outside the scope of this document", which is the
    # same "outside the scope is not an error" shape RFC 7432 section 14
    # uses for the EVPN MAC length. Outside the scope is not malformed,
    # so the octets are kept and written back.
    #
    # `Addr.new` with no argument is the absent field, a length of 0 and
    # no octets, which is what a (*,G) source is.
    class Addr

      attr_reader :bitlen, :value

      def self.hash_key
        :addr
      end

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
          # The absent field. Section 4.3 has no (*,G) sentence of its
          # own, where RFC 9251 section 9.1.1 does, but a zero length is
          # what a wildcard source is on the wire either way.
        else
          raise ArgumentError, "invalid argument: #{args.inspect}"
        end
        self
      end

      def self.octets_for(bitlen)
        (bitlen + 7) / 8
      end

      # **`.to_i` and not `unpack1('C')` alone.** A body can run out
      # exactly where a length octet should be, and `unpack1` answers
      # nil there, which raises `NoMethodError` out of `octets_for`.
      # Route types 6 and 7 read two of these in a row, so a length that
      # lies about its own width eats the field behind it and leaves
      # nothing, which is ordinary negative testing rather than a
      # malformed capture. That bug was found in `Evpn::Sized` by
      # probing a source length of 200 bits; it is not repeated here.
      def parse(s)
        @bitlen = s.slice!(0, 1).unpack1('C').to_i
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

      # The octets this field occupies, its length octet included.
      def size
        1 + @value.size
      end

      def empty?
        @bitlen.zero? and @value.empty?
      end

      # An IPv4 or IPv6 address, from the octets rather than the bit
      # count, since a length is allowed to lie about the family. nil
      # for anything that is not 4 or 16 octets.
      def address
        case @value.size
        when 4, 16 then IPAddr.new_ntoh(@value).to_s
        end
      end

      def to_hash
        { :bitlen => @bitlen, :value => @value.unpack1('H*') }
      end

      # The `*` of a wildcard, which is how section 4.3 writes an
      # absent source or group in its own prose.
      def to_s
        return '*' if empty?
        a = address
        a.nil? ? "#{@value.unpack1('H*')}/#{@bitlen}" : "#{a}/#{@bitlen}"
      end

      private

      def from_hash(h)
        h = h[self.class.hash_key] if h.has_key?(self.class.hash_key)
        return from_text(h) unless h.is_a?(Hash)
        @bitlen = h[:bitlen].to_i
        @value = [h[:value].to_s].pack('H*')
      end

      def from_text(t)
        return if t.nil?
        ip = IPAddr.new(t.to_s)
        @value = ip.hton
        @bitlen = ip.ipv4? ? 32 : 128
      end

    end

    # The Source AS field of RFC 6514 sections 4.2 and 4.6, "Source AS
    # (4 octets)". Four octets whatever the session negotiated, so
    # unlike AGGREGATOR this field never follows the 2-octet form: the
    # figure gives a width and the NLRI carries no capability.
    #
    # A class rather than an Integer on each route type, so the slicing
    # and the round trip live in one place for the three layouts that
    # carry one.
    class Source_as

      WIDTH = 4

      attr_reader :value

      def self.hash_key
        :source_as
      end

      # new, new(65000), the wire octets, this class's own hash, or
      # another instance.
      def initialize(*args)
        @value = 0
        if args.empty?
          # AS 0, which no RFC allows on the wire and which builds here
          # for the reason Conventions gives.
        elsif args.size == 1 and args[0].is_a?(String) and args[0].is_packed?
          parse(args[0])
        elsif args.size == 1 and args[0].is_a?(self.class)
          parse(args[0].encode.is_packed)
        elsif args.size == 1 and args[0].is_a?(Hash)
          h = args[0]
          h = h[Source_as.hash_key] if h.has_key?(Source_as.hash_key)
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
        @value = s.slice!(0, WIDTH).unpack1('N').to_i
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

      def to_hash
        { Source_as.hash_key => @value }
      end

      def to_s
        "AS #{@value}"
      end

      private

      # A representability refusal, which Conventions allows, and not a
      # judgement: the field is four octets and the alternative is
      # silently sending a different AS than the caller asked for.
      def refuse_a_value_the_field_cannot_hold(v)
        return if (0..0xffffffff).include?(v)
        raise ArgumentError, "Source AS #{v} does not fit in #{WIDTH} octets"
      end

    end

    # The Originating Router's IP Address field of RFC 6514 sections
    # 4.1, 4.3 and 4.4, which the figures label "Originating Router's IP
    # Addr".
    #
    # **This field has no length of its own and neither document states
    # its width.** RFC 6514 never says 4 or 16 and never derives it, and
    # neither does draft-ietf-bess-rfc6514bis-00, which obsoletes it:
    # both were read for it. The nearest sentence is section 8's, that
    # PE addresses "MUST be of the same address family as the
    # 'Originating Router's IP Address'", which implies a family and
    # gives no width.
    #
    # So the width is **what is left of the body**, which the section 4
    # Length field bounds, and the family comes from the field's own
    # size, 4 octets or 16. That is `Evpn::Ip_prefix_route`'s rule for
    # its GW IP Address and route type 2's rule for its optional Label2,
    # and it is sound for the same reason: the NLRI slices exactly
    # Length octets before any of this is read, so the remainder is
    # bounded rather than open ended.
    #
    # Any other width is kept and written back. A field of 5 octets is
    # not an address and is not an error here either; it makes the route
    # unable to reproduce its own body, which is what
    # `Mcast_vpn#read_route` catches.
    class Originating_router

      attr_reader :value

      def self.hash_key
        :originating_router
      end

      # new('10.0.0.1'), new('2001:db8::1'), the wire octets, this
      # class's own hash, or another instance. new with no argument is
      # the empty field, which no section describes and which builds.
      def initialize(*args)
        @value = +''
        if args.size == 1 and args[0].is_a?(String) and args[0].is_packed?
          parse(args[0])
        elsif args.size == 1 and args[0].is_a?(self.class)
          parse(args[0].encode.is_packed)
        elsif args.size == 1 and args[0].is_a?(Hash)
          from_hash(args[0])
        elsif args.size == 1
          from_text(args[0])
        elsif args.empty?
          # The empty field.
        else
          raise ArgumentError, "invalid argument: #{args.inspect}"
        end
        self
      end

      # **Takes everything it is handed**, because the field is last in
      # every layout that carries it and has no length to read. The
      # caller is the route type, which has already taken its own fields
      # off the front of a body the NLRI bounded.
      def parse(s)
        @value = s.slice!(0, s.size)
        self
      end

      def encode
        @value.dup
      end

      def to_shex
        encode.unpack1('H*')
      end

      def size
        @value.size
      end

      def empty?
        @value.empty?
      end

      # The address, from the octets, or nil for a width that is neither
      # family.
      def address
        case @value.size
        when 4, 16 then IPAddr.new_ntoh(@value).to_s
        end
      end

      # The address string in the ordinary case, and the octets when
      # they are not an address. Same extra-key-only-when-unusual rule
      # the library uses for `:tail` and `:bits`, so an ordinary route's
      # hash carries a plain address string.
      def to_hash
        a = address
        a.nil? ? { :octets => @value.unpack1('H*') } : a
      end

      def to_s
        return '(none)' if empty?
        address || "0x#{@value.unpack1('H*')}"
      end

      private

      def from_hash(h)
        h = h[self.class.hash_key] if h.is_a?(Hash) and
                                      h.has_key?(self.class.hash_key)
        return from_text(h) unless h.is_a?(Hash)
        @value = [h[:octets].to_s].pack('H*')
      end

      def from_text(t)
        return if t.nil?
        @value = IPAddr.new(t.to_s).hton
      end

    end

    # What every route type is: the Route Type specific field of RFC
    # 6514 section 4, without the two framing octets, which belong to
    # the NLRI in `mcast_vpn.rb`.
    class Route

      def self.type
        self::TYPE
      end

      # The key this route type takes in an Mcast_vpn hash, one per
      # class.
      def self.hash_key
        self::HASH_KEY
      end

      def type
        self.class.type
      end

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

      # **`Rd` does not consume the String it is handed, where the three
      # primitives above do.** Measured in the EVPN work and still true:
      # `Addr`, `Source_as` and `Originating_router` all read with
      # `slice!`, so a sequential parse walks forward by itself, and
      # `Rd#parse` leaves its octets where they were. Conventions
      # records that which classes consume is per class and has to be
      # checked. So the RD is sliced here and the rest read themselves.
      def read_rd(s)
        Rd.new(s.slice!(0, RD_SIZE).is_packed)
      end

      # Each field accepts either an instance of its own class or
      # whatever that class builds from, so a route reads as values
      # without the caller naming four classes.
      #
      # **An Array is splatted**, because that is the shape `Rd#to_hash`
      # answers with: `{:rd => [100, 200]}` against an `Rd.new(100,
      # 200)`. Without the splat the Array lands in the Administrator
      # field and `encode` dies on a nil Assigned Number.
      def coerce(klass, v)
        return v if v.is_a?(klass)
        v.is_a?(Array) ? klass.new(*v) : klass.new(v)
      end

      # The same, for a field that may be left out entirely.
      def coerce_or_default(klass, v)
        return klass.new if v.nil?
        coerce(klass, v)
      end

      # How an `Addr` field hashes: the address string when the octets
      # are a whole family and the bit count agrees with them, and the
      # `Addr` hash otherwise, which is the absent field and every
      # length that lies.
      def addr_hash(a)
        s = a.address
        return a.to_hash if s.nil?
        return a.to_hash unless a.bitlen == (a.value.size * 8)
        s
      end

    end

    # A Route Type bgp4r does not implement, kept whole and written back
    # so a capture replays byte for byte.
    #
    # **The reasoning is the one `Evpn::Unknown` and
    # `Flow_spec::Component::Unknown` both recorded, and it reaches the
    # same answer for the same reason.** What breadth buys over #116 is
    # meaning, since an `Attr::Raw` already replays the octets of an
    # MCAST-VPN UPDATE today, so raising here would give back exactly
    # what #116 gives while costing the known route types their meaning.
    # And the remainder is bounded, because section 4's Length field
    # says how long the body is, which is why this can keep it where a
    # generic `Nlri::Unknown` could not.
    #
    # **This is where the three mLDP route types land**, 0x43, 0x44 and
    # 0x47 of RFC 7441, which are deliberately out of scope: each
    # carries an mLDP FEC Element that RFC 7441 does not lay out,
    # pointing at RFC 6388 section 2.2 instead, so that field's extent
    # belongs to LDP and bgp4r has nothing of LDP. They replay from
    # here. See `docs/mcast-vpn.md`.
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

      # A copy, so building from an instance cannot empty the instance
      # it is copying: `parse` reads with `slice!`.
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

    # Route type 1, RFC 6514 section 4.1, the Intra-AS I-PMSI A-D route:
    #
    #   +-----------------------------------+
    #   |      RD   (8 octets)              |
    #   +-----------------------------------+
    #   | Originating Router's IP Addr      |
    #   +-----------------------------------+
    #
    # **The first layout in the library whose total length is not
    # stated anywhere.** Section 4.1 gives no width for the address and
    # no total, so the route is 12 octets with an IPv4 address and 24
    # with an IPv6 one, and those numbers are this reader's arithmetic
    # rather than the document's. `Originating_router` takes what is
    # left of the body, which the section 4 Length bounds.
    #
    # **12 octets is also route type 2's length**, exactly, so the two
    # are told apart by the Route Type octet alone and by nothing in
    # the body. That is not a problem the framing has to solve, since
    # the Route Type is read before the body, but a reader comparing
    # lengths across this family should know the collision is there.
    #
    # Section 4.1 says of the RD only that it "is encoded as described
    # in [RFC4364]", so `BGP::Rd` is exactly right and no value is
    # prescribed.
    class Intra_as_i_pmsi < Route

      TYPE     = 1
      HASH_KEY = :intra_as_i_pmsi

      attr_reader :rd, :originator

      # new([100, 200], '10.0.0.1')
      # new(BGP::Rd.new(100, 200), an Originating_router)
      # this class's own hash, its field hash, or the wire octets.
      #
      # **`:originator` holds a different class here than it does in
      # EVPN**, which is worth knowing before moving between the two
      # files. `Evpn`'s `:originator` is a length prefixed `Addr`, from
      # RFC 9251 and RFC 9572; this one has no length octet at all, so
      # it hashes as a plain address string in the ordinary case. The
      # key name is shared because the field is the same idea, and the
      # encoding is not.
      def initialize(*args)
        if args.size == 1 and args[0].is_a?(String) and args[0].is_packed?
          parse(args[0])
        elsif args.size == 1 and args[0].is_a?(self.class)
          parse(args[0].encode.is_packed)
        elsif args.size == 1 and args[0].is_a?(Hash)
          h = self.class.unwrap(args[0])
          @rd = coerce(Rd, h[:rd])
          @originator = coerce_or_default(Originating_router, h[:originator])
        else
          @rd = coerce(Rd, args[0])
          @originator = coerce_or_default(Originating_router, args[1])
        end
        self
      end

      def encode_value
        @rd.encode + @originator.encode
      end

      def value_hash
        { :rd => @rd.to_hash[:rd], :originator => @originator.to_hash }
      end

      def to_s
        "[1] Intra-AS I-PMSI A-D: #{@rd.to_s(false)}, " \
        "originating router #{@originator}"
      end

      private

      def parse(s)
        @rd = read_rd(s)
        @originator = Originating_router.new(s)
        self
      end

    end

    # Route type 2, RFC 6514 section 4.2, the Inter-AS I-PMSI A-D route:
    #
    #   +-----------------------------------+
    #   |      RD   (8 octets)              |
    #   +-----------------------------------+
    #   |   Source AS (4 octets)            |
    #   +-----------------------------------+
    #
    # The only fixed length layout in this family: 12 octets, always.
    #
    # Section 4.2 has the one sentence in the family that constrains a
    # field's value rather than its width: "Two-octet ASNs are encoded
    # in the two low-order octets of the Source AS field, with the two
    # high-order octets set to zero." `Source_as` writes a 32-bit
    # unsigned integer, so that holds by construction and needed no
    # code; a test asserts it rather than leaving it to be assumed.
    class Inter_as_i_pmsi < Route

      TYPE     = 2
      HASH_KEY = :inter_as_i_pmsi

      attr_reader :rd, :source_as

      # new([100, 200], 65000), this class's own hash, its field hash,
      # or the wire octets.
      def initialize(*args)
        if args.size == 1 and args[0].is_a?(String) and args[0].is_packed?
          parse(args[0])
        elsif args.size == 1 and args[0].is_a?(self.class)
          parse(args[0].encode.is_packed)
        elsif args.size == 1 and args[0].is_a?(Hash)
          h = self.class.unwrap(args[0])
          @rd = coerce(Rd, h[:rd])
          @source_as = coerce_or_default(Source_as, h[:source_as])
        else
          @rd = coerce(Rd, args[0])
          @source_as = coerce_or_default(Source_as, args[1])
        end
        self
      end

      def encode_value
        @rd.encode + @source_as.encode
      end

      # `Source_as#to_hash` merges flat, since `:source_as` collides
      # with no field of the route. That is the shape `BGP::Label` takes
      # in EVPN route type 1 for the same reason.
      def value_hash
        { :rd => @rd.to_hash[:rd] }.merge(@source_as.to_hash)
      end

      def to_s
        "[2] Inter-AS I-PMSI A-D: #{@rd.to_s(false)}, source #{@source_as}"
      end

      private

      def parse(s)
        @rd = read_rd(s)
        @source_as = Source_as.new(s)
        self
      end

    end

    # The Multicast Source and Multicast Group pair, which route types
    # 3, 5, 6 and 7 all carry in that order:
    #
    #   +-----------------------------------+
    #   |  Multicast Source Length (1 octet)|
    #   +-----------------------------------+
    #   |  Multicast Source (variable)      |
    #   +-----------------------------------+
    #   |  Multicast Group Length (1 octet) |
    #   +-----------------------------------+
    #   |  Multicast Group (variable)       |
    #   +-----------------------------------+
    #
    # Four of the seven layouts, so it is worth one place rather than
    # four copies. `Evpn::Multicast_fields` is the same move for the
    # EVPN address triple, and it was lifted there for the same reason.
    #
    # **A module and not a base class**, which is the EVPN lesson and
    # not a style choice: `test/unit/mcast_vpn_doc_test.rb` discovers
    # the route type table from the `Route` subclasses the library
    # defines, so an abstract `Multicast < Route` would read as a route
    # type with no row to put it in. A module is not a Class and that
    # guard does not count it.
    module Source_and_group

      attr_reader :source, :group

      private

      def coerce_source_and_group(src, grp)
        @source = coerce_or_default(Addr, src)
        @group  = coerce_or_default(Addr, grp)
      end

      # Each `Addr` reads its own length octet and consumes what it
      # takes, so the pair walks forward by itself.
      def read_source_and_group(s)
        @source = Addr.new(s)
        @group  = Addr.new(s)
      end

      def source_and_group_octets
        @source.encode + @group.encode
      end

      def source_and_group_hash
        { :source => addr_hash(@source), :group => addr_hash(@group) }
      end

    end

    # Route type 5, RFC 6514 section 4.5, the Source Active A-D route:
    #
    #   +-----------------------------------+
    #   |      RD   (8 octets)              |
    #   +-----------------------------------+
    #   |  Multicast Source Length (1 octet)|
    #   +-----------------------------------+
    #   |  Multicast Source (variable)      |
    #   +-----------------------------------+
    #   |  Multicast Group Length (1 octet) |
    #   +-----------------------------------+
    #   |  Multicast Group (variable)       |
    #   +-----------------------------------+
    #
    # 18 octets with two IPv4 addresses and 42 with two IPv6 ones, and
    # the two lengths are in bits, as RFC 6514 section 4.3 says by
    # value for the same two fields. Section 4.5 states no total.
    #
    # **Two of section 4.5's own rules are not encoding rules**, and
    # neither is implemented here. Both are recorded in
    # `docs/mcast-vpn.md` so a later part can decide rather than
    # rediscover.
    #
    #   "Use of the Source Active A-D routes with the Multicast Source
    #   Length field of 0 is outside the scope of this document", which
    #   is the third "outside the scope is not an error" sentence in
    #   this family. A wildcard source builds here, per Conventions.
    #
    #   A route whose group is in the Source Specific Multicast range
    #   "MUST NOT be advertised by a router and MUST be discarded if
    #   received". That is route filtering and not error handling: it
    #   needs the group's value against a range RFC 6514 does not
    #   number, deferring to RFC 4607 and letting a router extend it
    #   locally, and "discarded" is not one of the actions RFC 7606
    #   names. So bgp4r builds and reads such a route.
    class Source_active < Route

      include Source_and_group

      TYPE     = 5
      HASH_KEY = :source_active

      attr_reader :rd

      # new([100, 200], '192.0.2.1', '232.1.1.1'), this class's own
      # hash, its field hash, or the wire octets.
      def initialize(*args)
        if args.size == 1 and args[0].is_a?(String) and args[0].is_packed?
          parse(args[0])
        elsif args.size == 1 and args[0].is_a?(self.class)
          parse(args[0].encode.is_packed)
        elsif args.size == 1 and args[0].is_a?(Hash)
          h = self.class.unwrap(args[0])
          @rd = coerce(Rd, h[:rd])
          coerce_source_and_group(h[:source], h[:group])
        else
          @rd = coerce(Rd, args[0])
          coerce_source_and_group(args[1], args[2])
        end
        self
      end

      def encode_value
        @rd.encode + source_and_group_octets
      end

      def value_hash
        { :rd => @rd.to_hash[:rd] }.merge(source_and_group_hash)
      end

      def to_s
        "[5] Source Active A-D: #{@rd.to_s(false)}, " \
        "(#{@source}, #{@group})"
      end

      private

      def parse(s)
        @rd = read_rd(s)
        read_source_and_group(s)
        self
      end

    end

    # Route type 3, RFC 6514 section 4.3, the S-PMSI A-D route:
    #
    #   +-----------------------------------+
    #   |      RD   (8 octets)              |
    #   +-----------------------------------+
    #   |  Multicast Source Length (1 octet)|
    #   +-----------------------------------+
    #   |  Multicast Source (variable)      |
    #   +-----------------------------------+
    #   |  Multicast Group Length (1 octet) |
    #   +-----------------------------------+
    #   |  Multicast Group (variable)       |
    #   +-----------------------------------+
    #   | Originating Router's IP Addr      |
    #   +-----------------------------------+
    #
    # Route type 5 with the trailing address behind it, so it is the
    # first layout in this family with a variable field **after** a
    # variable field. 22 octets all IPv4 and 58 all IPv6, neither of
    # which the document states.
    #
    # **This is the section that says the two lengths are in bits**, by
    # value rather than by the word, and the four sentences are quoted
    # in `docs/mcast-vpn.md` section 4: "If the Multicast Source field
    # contains an IPv4 address, then the value of the Multicast Source
    # Length field is 32", 128 for IPv6, and the same pair for the
    # Multicast Group. Route types 5, 6 and 7 carry the same two fields
    # and say nothing about them, so this is where to look.
    #
    # **22 octets is also what route types 6 and 7 are with IPv4
    # addresses.** The second length collision in this family, after
    # route type 1 against route type 2, and harmless for the same
    # reason: the Route Type octet is read before the body.
    class S_pmsi < Route

      include Source_and_group

      TYPE     = 3
      HASH_KEY = :s_pmsi

      attr_reader :rd, :originator

      # new([100, 200], '192.0.2.1', '232.1.1.1', '10.0.0.1'), this
      # class's own hash, its field hash, or the wire octets.
      def initialize(*args)
        if args.size == 1 and args[0].is_a?(String) and args[0].is_packed?
          parse(args[0])
        elsif args.size == 1 and args[0].is_a?(self.class)
          parse(args[0].encode.is_packed)
        elsif args.size == 1 and args[0].is_a?(Hash)
          h = self.class.unwrap(args[0])
          @rd = coerce(Rd, h[:rd])
          coerce_source_and_group(h[:source], h[:group])
          @originator = coerce_or_default(Originating_router, h[:originator])
        else
          @rd = coerce(Rd, args[0])
          coerce_source_and_group(args[1], args[2])
          @originator = coerce_or_default(Originating_router, args[3])
        end
        self
      end

      def encode_value
        @rd.encode + source_and_group_octets + @originator.encode
      end

      def value_hash
        { :rd => @rd.to_hash[:rd] }
          .merge(source_and_group_hash)
          .merge(:originator => @originator.to_hash)
      end

      def to_s
        "[3] S-PMSI A-D: #{@rd.to_s(false)}, (#{@source}, #{@group}), " \
        "originating router #{@originator}"
      end

      private

      # **The order is what makes this layout readable at all.** The two
      # lengths are read first and each takes what it claims, so the
      # trailing address gets what is left and needs no arithmetic. A
      # source or group length that claims more than the body holds eats
      # the fields behind it, which leaves the address empty, and the
      # route then cannot reproduce its own body: `Mcast_vpn#read_route`
      # catches that and keeps the octets as an `Unknown`.
      def parse(s)
        @rd = read_rd(s)
        read_source_and_group(s)
        @originator = Originating_router.new(s)
        self
      end

    end

    # Route types 6 and 7, RFC 6514 section 4.6, the C-Multicast Route:
    #
    #   +-----------------------------------+
    #   |      RD   (8 octets)              |
    #   +-----------------------------------+
    #   |   Source AS (4 octets)            |
    #   +-----------------------------------+
    #   |  Multicast Source Length (1 octet)|
    #   +-----------------------------------+
    #   |  Multicast Source (variable)      |
    #   +-----------------------------------+
    #   |  Multicast Group Length (1 octet) |
    #   +-----------------------------------+
    #   |  Multicast Group (variable)       |
    #   +-----------------------------------+
    #
    # **One layout and two route type numbers.** Section 4.6 is titled
    # "C-Multicast Route" and covers both in one subsection, in one
    # sentence: "A Shared Tree Join route and a Source Tree Join Route
    # Type specific MCAST-VPN NLRI consists of the following". So the
    # whole layout is here and the two classes below are identity and
    # nothing else, which is the honest statement that they differ only
    # in their Route Type octet and the name a reader sees.
    #
    # 22 octets all IPv4 and 46 all IPv6. The 22 is route type 3's IPv4
    # length as well; see that class.
    #
    # A module rather than a base class, for the reason
    # `Source_and_group` gives: the doc test discovers `Route`
    # subclasses, so an abstract one would read as a route type with no
    # row.
    module C_multicast

      include Source_and_group

      attr_reader :rd, :source_as

      # new([100, 200], 65000, '192.0.2.1', '232.1.1.1'), the class's
      # own hash, its field hash, or the wire octets.
      def initialize(*args)
        if args.size == 1 and args[0].is_a?(String) and args[0].is_packed?
          parse(args[0])
        elsif args.size == 1 and args[0].is_a?(self.class)
          parse(args[0].encode.is_packed)
        elsif args.size == 1 and args[0].is_a?(Hash)
          h = self.class.unwrap(args[0])
          @rd = coerce(Rd, h[:rd])
          @source_as = coerce_or_default(Source_as, h[:source_as])
          coerce_source_and_group(h[:source], h[:group])
        else
          @rd = coerce(Rd, args[0])
          @source_as = coerce_or_default(Source_as, args[1])
          coerce_source_and_group(args[2], args[3])
        end
        self
      end

      def encode_value
        @rd.encode + @source_as.encode + source_and_group_octets
      end

      def value_hash
        { :rd => @rd.to_hash[:rd] }
          .merge(@source_as.to_hash)
          .merge(source_and_group_hash)
      end

      # The one thing that differs between the two, read off the class
      # rather than written twice.
      def to_s
        "[#{type}] #{self.class::NAME}: #{@rd.to_s(false)}, " \
        "#{@source_as}, (#{@source}, #{@group})"
      end

      private

      def parse(s)
        @rd = read_rd(s)
        @source_as = Source_as.new(s)
        read_source_and_group(s)
        self
      end

    end

    # Route type 6, RFC 6514 section 4.6, the Shared Tree Join route.
    # The layout is `C_multicast`.
    class Shared_tree_join < Route

      include C_multicast

      TYPE     = 6
      HASH_KEY = :shared_tree_join
      NAME     = 'Shared Tree Join'

    end

    # Route type 7, RFC 6514 section 4.6, the Source Tree Join route.
    # The same layout, and the same section defines both.
    class Source_tree_join < Route

      include C_multicast

      TYPE     = 7
      HASH_KEY = :source_tree_join
      NAME     = 'Source Tree Join'

    end

    # Route type 4, RFC 6514 section 4.4, the Leaf A-D route:
    #
    #   +-----------------------------------+
    #   |      Route Key (variable)         |
    #   +-----------------------------------+
    #   | Originating Router's IP Addr      |
    #   +-----------------------------------+
    #
    # **Two variable length fields in a row and no length for either, so
    # where one ends is not in the band.** This is the layout the
    # documents do not settle and the reason this route type came last.
    #
    # All section 4.4 says is that "the Route Key of the Leaf A-D route
    # is set to the NLRI of the received route", and
    # draft-ietf-bess-rfc6514bis-00, which obsoletes RFC 6514, repeats it
    # and adds nothing. Both were read for it.
    #
    # **So the reading here is a reading and not a rule.** The Route Key
    # is taken to be a whole nested MCAST-VPN NLRI, Route Type and Length
    # octets included, which makes it self delimiting and leaves the
    # address as what is behind it. EVPN route type 11 is the same shape
    # and RFC 9572 uses the same words, but **it needed its own
    # terminology section to say "entire NLRI"** before that was more
    # than a reading. RFC 6514 has no such sentence. I do not know
    # whether the authors meant the whole NLRI or only the Route Type
    # specific part, and nothing in either document answers it.
    #
    # **What the replay check does and does not catch here, stated
    # carefully, because the first draft of this comment overstated it.**
    # That draft said the body could be split anywhere and still replay.
    # It cannot: the split is **read from** the nested Length octet, so
    # it is determined by the octets, and two different splits of one
    # body are not reachable. The reading is injective and self
    # consistent, and the fields always reproduce the body.
    #
    # What follows is weaker and is the point. `Mcast_vpn#read_route`
    # accepts a route type only when its `encode` reproduces the body,
    # and here that is satisfied by construction, so it says nothing
    # about whether the reading is the one the sender meant. It catches
    # exactly two things: a body too short to frame a Route Key at all,
    # and a nested Length that overruns the body. A sender using another
    # rule, the Route Type specific part alone with a fixed width address
    # behind it, say, writes octets this reads into different fields, and
    # **nothing on the wire shows the disagreement**. So do not point at
    # the replay check as what makes the reading safe; it is what makes
    # the octets safe.
    #
    # The one signal available is the remainder's width: the Originating
    # Router's IP Address is an address, so `originator.address` answers
    # nil when what is left is neither 4 nor 16 octets, which is a reason
    # to doubt the split. It is **not** used to pick the split, because
    # choosing by it would be inventing a rule where the documents have
    # none. A caller that believes another reading can build it by
    # handing the Route Key its own octets, since nothing validates.
    #
    # **It reaches `Mcast_vpn` at call time and not at load time**, which
    # is what makes that legal: `Mcast_vpn` is the class around this one,
    # and `nlri_size` and the NLRI's `initialize` are added by
    # `bgp/nlris/mcast_vpn.rb`, which requires this file first. So this
    # class is the one place in the file that does not work against
    # `mcast_vpn_route.rb` alone, and its tests live in
    # `test/unit/nlris/mcast_vpn_test.rb` beside the framing they
    # exercise. `Evpn::Leaf_a_d` is its namesake and records the same
    # thing for the same reason.
    #
    # Nothing validates. Any Route Key, including one carrying a route
    # type bgp4r does not implement, which comes back as an
    # `Mcast_vpn::Unknown` inside the Route Key and replays; and a Leaf
    # A-D route inside a Leaf A-D route, which no RFC describes.
    class Leaf_a_d < Route

      TYPE     = 4
      HASH_KEY = :leaf_a_d

      attr_reader :route_key, :originator

      # new(route_key, originator), where the Route Key is an
      # `Mcast_vpn`, an `Mcast_vpn::Route` one is built around, or its
      # wire octets
      # new(:route_key => { :s_pmsi => { ... } },
      #     :originator => '10.0.0.1')
      # the wire bytes, or another instance.
      def initialize(*args)
        if args.size == 1 and args[0].is_a?(String) and args[0].is_packed?
          parse(args[0])
        elsif args.size == 1 and args[0].is_a?(self.class)
          parse(args[0].encode.is_packed)
        elsif args.size == 1 and args[0].is_a?(Hash)
          from_hash(args[0])
        elsif (1..2).include?(args.size)
          @route_key  = coerce_route_key(args[0])
          @originator = coerce_or_default(Originating_router, args[1])
        elsif args.empty?
          @route_key  = coerce_route_key(nil)
          @originator = Originating_router.new
        else
          raise ArgumentError, "invalid argument: #{args.inspect}"
        end
        self
      end

      # The nested NLRI's own Length octet is the only thing that says
      # where the Route Key ends, which is the reading above. A body too
      # short to frame one cannot be split at all, so it raises and
      # `Mcast_vpn#read_route` keeps the octets whole as an `Unknown`.
      # That is the one case the replay check does catch.
      def parse(s)
        n = Mcast_vpn.nlri_size(s)
        raise ArgumentError, 'Route Key too short to frame' if n.nil?
        if n > s.size
          raise ArgumentError, 'Route Key Length overruns the Leaf A-D body'
        end
        @route_key  = Mcast_vpn.new(s.slice!(0, n).is_packed)
        @originator = Originating_router.new(s)
        self
      end

      def encode_value
        @route_key.encode + @originator.encode
      end

      def value_hash
        { :route_key  => @route_key.to_hash,
          :originator => @originator.to_hash }
      end

      def to_s
        "[4] Leaf A-D: route key #{@route_key.route}, " \
        "originating router #{@originator}"
      end

      private

      # An `Mcast_vpn` passes through, an `Mcast_vpn::Route` is wrapped
      # in one, wire octets are parsed as one, and a Hash is handed to
      # `Mcast_vpn`, which reads one key per route type. Nothing is a
      # sensible default, so an absent Route Key is an
      # `Mcast_vpn::Unknown` of type 0 with no body, which is 2 octets
      # and replays. Type 0 is Reserved in the registry, so it names no
      # real route.
      def coerce_route_key(v)
        return v if v.is_a?(Mcast_vpn)
        return Mcast_vpn.new(v) if v.is_a?(Route) or v.is_a?(Hash)
        return Mcast_vpn.new(v) if v.is_a?(String) and v.is_packed?
        return Mcast_vpn.new(Unknown.new(0, +'')) if v.nil?
        raise ArgumentError, "#{v.inspect} is not a Route Key"
      end

      def from_hash(h)
        h = self.class.unwrap(h)
        @route_key  = coerce_route_key(h[:route_key])
        @originator = coerce_or_default(Originating_router, h[:originator])
      end

    end

  end

end

load "../../test/unit/nlris/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
