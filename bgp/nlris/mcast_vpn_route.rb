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

  end

end

load "../../test/unit/nlris/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
