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
require 'bgp/nlris/link_state_tlv'

module BGP

  # One Link-State NLRI: the format of RFC 9552 section 5.2, carried
  # over AFI 16388 with SAFI 71 or SAFI 72.
  #
  #    0                   1                   2                   3
  #    0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
  #   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  #   |            NLRI Type          |     Total NLRI Length         |
  #   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  #   |                 Route Distinguisher (8 octets)                |  SAFI 72 only
  #   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  #   //                  Link-State NLRI (variable)                 //
  #   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  #
  # `docs/bgp-ls.md` is the guide. Every section number here was read in
  # the RFC text on 2026-10-31. Nothing dispatches to this class yet.
  #
  # **The Length counts the RD, which is the detail to get right.**
  # Section 5.2: "The Total NLRI Length field contains the cumulative
  # length, in octets, of the rest of the NLRI, not including the NLRI
  # Type field or itself. For VPN applications, it also includes the
  # length of the Route Distinguisher." So `Link_state.nlri_size` is
  # `4 + total` for both SAFIs and needs no SAFI of its own, where the
  # body parse does.
  #
  # **The SAFI is a parse-time input, and that is flow spec's situation
  # rather than EVPN's.** Nothing in the octets says whether an RD is
  # there: figures 5 and 6 differ by eight octets and by nothing a
  # reader can see. So a capture has to be told, the same way a flow
  # spec rule has to be told its AFI, and `Flow_spec` is the precedent
  # down to `@safi` deciding `has_rd?`. The default is SAFI 71.
  #
  # **No AFI input, where MCAST-VPN had two AFIs to think about.**
  # Section 5.2 fixes one: "All non-VPN link, node, and prefix
  # information SHALL be encoded using AFI 16388 / SAFI 71. VPN link,
  # node, and prefix information SHALL be encoded using AFI 16388 /
  # SAFI 72." One AFI, two SAFIs, and it is the SAFI that changes the
  # octets.
  #
  # **Nothing validates.** Any NLRI type, any length, any body,
  # including a Length that disagrees with the octets that came with it
  # and an RD on a SAFI 71 NLRI if a caller asks for one.
  class Link_state

    # Section 5.2, figure 5. NLRI Type and Total NLRI Length are two
    # octets each, so the framing is 4 and a body is at most 0xffff
    # octets, the RD included for SAFI 72.
    FRAMING = 4
    MAX_LEN = 0xffff

    # Section 5.2, figure 6: "Route Distinguisher (8 octets)".
    RD_SIZE = 8

    # The NLRI type registry, as IANA's "BGP-LS NLRI Types" gives it in
    # Table 12 of RFC 9552 section 7.1.1, read on 2026-10-31: 0
    # Reserved, 1 Node, 2 Link, 3 IPv4 Topology Prefix, 4 IPv6 Topology
    # Prefix, 65000 to 65535 Private Use, and everything between 5 and
    # 64999 unassigned. The code points are two octets wide.
    #
    # **Empty in part 1**, so every NLRI type reads back as
    # `Link_state::Unknown` today, which is the state `Evpn::ROUTES` and
    # `Mcast_vpn::ROUTES` were each in when their own first part landed.
    # Parts 2 and 3 fill rows 1, 2, 3 and 4.
    #
    # `test/unit/bgp_ls_doc_test.rb` **discovers** this table rather
    # than listing it, so an NLRI type class cannot join the library
    # without `docs/bgp-ls.md` being told, and a class registered here
    # with no row, or a row with no class, fails either way.
    TYPES = {}

    # Hash key back to class, for the hash build path. `Unknown` is in
    # here and in no row of TYPES, which is the whole point of it: no
    # type number reaches it, and a hash that carries its key has to
    # build back.
    BY_KEY = {}

    class << self

      # Add an NLRI type class to both lookups, the way
      # `Link_state::Tlv.register` does one level down. Raises on a type
      # or a key already taken, because a second registration would
      # shadow the first and nothing else would say so.
      def register(klass)
        t, k = klass.type, klass.hash_key
        if TYPES.has_key?(t) and TYPES[t] != klass
          raise ArgumentError, "BGP-LS NLRI type #{t} is already #{TYPES[t]}"
        end
        if BY_KEY.has_key?(k) and BY_KEY[k] != klass
          raise ArgumentError,
            "BGP-LS NLRI hash key #{k.inspect} is already #{BY_KEY[k]}"
        end
        TYPES[t] = klass
        BY_KEY[k] = klass
        klass
      end

      # How many octets the next Link-State NLRI occupies, its four
      # framing octets included. This is what `Mp_reach#parse` and
      # `Mp_unreach#parse` need in place of the prefix families'
      # `(blen+7)/8+1`, and it lives here so the family owns its
      # framing, the same as `Evpn.nlri_size` and `Mcast_vpn.nlri_size`.
      #
      # **It takes no SAFI, and that is section 5.2's doing rather than
      # a simplification.** The Total NLRI Length covers the RD for a
      # VPN NLRI, so the same arithmetic frames both SAFIs and a VPN
      # NLRI is simply eight octets longer. Only the body parse needs to
      # know which it is.
      #
      # Answers nil for octets too short to frame, so a caller can stop
      # rather than loop.
      def nlri_size(s)
        return nil if s.nil? or s.size < FRAMING
        FRAMING + s[2, 2].unpack1('n')
      end

      def new_ntop(s, safi = IANA::SAFI::BGP_LS, path_id = nil)
        ls = new(s.is_packed, safi)
        ls.path_id = path_id if path_id
        ls
      end

    end

    attr_reader :nlri, :rd, :safi, :path_id

    # The Length that arrived, when it was not the number of octets that
    # came with it, so encode writes back what the peer sent rather than
    # what is really there. nil on anything built from values.
    attr_reader :declared_len

    attr_writer :path_id

    # Four ways in, as Conventions asks:
    #
    #   Link_state.new(Link_state::Unknown.new(1, octets))
    #   Link_state.new(:unknown => { :type => 1, :value => '0011' })
    #   Link_state.new(wire_bytes, safi)
    #   Link_state.new(another_link_state)
    def initialize(*args)
      @nlri, @rd, @path_id, @declared_len = nil, nil, nil, nil
      @safi = IANA::SAFI::BGP_LS
      if args[0].is_a?(String) and args[0].is_packed?
        @safi = args[1] || IANA::SAFI::BGP_LS
        parse(args[0])
      elsif args.size == 1 and args[0].is_a?(Link_state)
        # **The Path Identifier is taken off before the re-parse, and
        # the four families before this one all get that wrong.**
        # `encode` writes the RFC 7911 section 3 identifier in front of
        # the NLRI and `parse` does not expect one, so copying an
        # extended NLRI through `encode` alone reads those four octets
        # as a Type and a Length. Measured on 2026-10-31: `Evpn`,
        # `Mcast_vpn`, `Flow_spec` and `Rt_constrain` each answer
        # garbage for `Klass.new(an_extended_instance)` and are right
        # for an unextended one. Reported rather than fixed here, since
        # that is four families and its own topic.
        @safi, @path_id = args[0].safi, args[0].path_id
        s = args[0].encode.is_packed
        s.slice!(0, 4) if args[0].extended?
        parse(s)
      elsif args.size == 1 and args[0].is_a?(Type)
        @nlri = args[0]
      elsif args.size == 1 and args[0].is_a?(Hash)
        from_hash(args[0])
      else
        raise ArgumentError, "invalid argument: #{args.inspect}, expected " \
                             'a Link_state NLRI type, a hash, wire bytes ' \
                             'or a Link_state'
      end
      self
    end

    # RFC 7911 section 3 prepends a Path Identifier to the NLRI, so an
    # extended one is four octets longer. Named as Prefix names it.
    def extended?
      !@path_id.nil?
    end

    # Section 5.2: an RD is there for SAFI 72 and not for SAFI 71.
    def vpn?
      @safi == IANA::SAFI::BGP_LS_VPN
    end

    def type
      @nlri && @nlri.type
    end

    # Everything the Total NLRI Length counts: the RD when there is one,
    # then the type-specific body.
    def value
      (@rd ? @rd.encode : +'') + (@nlri ? @nlri.encode : +'')
    end

    # The Length octets this NLRI writes: what arrived when that
    # disagreed with the body, and the body's own size otherwise.
    def length
      @declared_len || value.size
    end

    def encode
      v = value
      n = @declared_len || v.size
      refuse_a_length_the_field_cannot_hold(n)
      s = [type.to_i, n, v].pack('nna*')
      s = [@path_id].pack('N') + s if extended?
      s
    end

    def to_shex
      encode.unpack1('H*')
    end

    def size
      encode.size
    end

    def to_hash
      h = @nlri ? @nlri.to_hash : {}
      h = h.merge(@rd.to_hash) if @rd
      h = h.merge(:length => @declared_len) if @declared_len
      h = h.merge(:path_id => @path_id) if extended?
      h
    end

    def to_s
      s = @nlri ? @nlri.to_s : '(empty)'
      s = "#{@rd.to_s(false)} " + s if @rd
      s = "[#{@path_id}] " + s if extended?
      s
    end

    def ==(other)
      other.is_a?(Link_state) and other.encode == encode
    end

    # What every NLRI type is: the Link-State NLRI field of RFC 9552
    # section 5.2, without the framing octets and without the RD, both
    # of which belong to this class.
    class Type

      def self.type
        self::TYPE
      end

      # The key this NLRI type takes in a Link_state hash, one per
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

      # The one Hash a build may be handed that is this type's own
      # wrapped hash rather than its field hash.
      def self.unwrap(h)
        return h unless h.is_a?(Hash)
        h.has_key?(hash_key) ? h[hash_key] : h
      end

    end

    # An NLRI type bgp4r does not implement, kept whole and written back
    # so a capture replays byte for byte.
    #
    # **Section 5.2 requires this and says so at length**, which is why
    # there is no decision recorded here: "To allow the introduction of
    # new Link-State NLRI types seamlessly in the future without the
    # need for upgrading all BGP Speakers in the propagation path (e.g.,
    # a route reflector), this document deviates from the default
    # handling behavior specified by Section 5.4 (paragraph 2) of
    # [RFC7606] for Link-State address family. An implementation MUST
    # handle unknown Link-State NLRI types as opaque objects and MUST
    # preserve and propagate them."
    #
    # **It keeps opaque octets and does not read TLVs out of them**,
    # which is the RFC's own word and not a shortcut. Nothing
    # establishes that an unknown type's body is a TLV list: the four
    # types section 5.2 does define start with a Protocol-ID octet and
    # an 8-octet Identifier before any TLV, so a reader that framed TLVs
    # from the first octet would invent structure and report fields that
    # were never sent.
    #
    # **This does not reverse the entry under phase 1 of the breadth
    # plan**, which says a *generic* `Nlri::Unknown` is unwritable
    # because list framing is per family. That stays true. This is
    # family-local and bounded by the Total NLRI Length, which is the
    # same resolution `Flow_spec::Component::Unknown` reached for the
    # same reason.
    class Unknown < Type

      HASH_KEY = :unknown

      # Table 12 of RFC 9552 section 7.1.1: 65000 to 65535 is Private
      # Use. Section 5.4 puts a 4-octet Enterprise Code "as the first
      # field in the NLRI immediately following the Total NLRI Length
      # field" for such a type.
      #
      # **No reader for it here, deliberately.** For SAFI 72 that
      # sentence and figure 6 both claim the octets immediately after
      # the Total NLRI Length, and nothing in the document settles which
      # comes first. `Link_state::Tlv::Unknown#enterprise_code` has no
      # such collision and does read it. See `docs/bgp-ls.md`.
      PRIVATE_USE = (65000..65535)

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
      # unlike every other NLRI type this one carries its own.
      def type
        @type
      end

      # A copy, so building from an instance cannot empty the instance
      # it is copying: `parse` reads with `slice!`.
      def encode_value
        @value.dup
      end

      def private_use?
        PRIVATE_USE.include?(@type)
      end

      def value_hash
        { :type => @type, :value => @value.unpack1('H*') }
      end

      def to_s
        s = private_use? ? 'Private use NLRI type' : 'Unknown NLRI type'
        s += " #{@type}, #{@value.size} octets"
        s += " [#{@value.unpack1('H*')}]" unless @value.empty?
        s
      end

    end

    BY_KEY[Unknown::HASH_KEY] = Unknown

    private

    # NLRI Type, Total NLRI Length, then exactly Length octets, which
    # hold the RD for SAFI 72 and the type-specific body after it. A
    # Length that overruns what is there takes what is there and is
    # kept, so encode gives the peer's own Length back rather than
    # correcting it.
    def parse(s)
      t    = s.slice!(0, 2).unpack1('n')
      len  = s.slice!(0, 2).unpack1('n')
      body = s.slice!(0, [len, s.size].min)
      @declared_len = len if len != body.size
      # **`Rd` does not consume the String it is handed**, where the TLV
      # list reader does, so the eight octets are sliced here. Measured
      # in the MCAST-VPN work and recorded in Conventions: which classes
      # consume is per class and has to be checked.
      #
      # A VPN body too short to hold a whole RD keeps every octet it has
      # and gets no RD at all, so it still replays. That is ordinary
      # negative testing rather than a malformed capture.
      @rd = Rd.new(body.slice!(0, RD_SIZE).is_packed) if vpn? and
            body.size >= RD_SIZE
      @nlri = read_nlri(t, body) || Unknown.new(t, body)
      self
    end

    # **An NLRI type is kept only if it can give its own octets back**,
    # the rule `Flow_spec`, `Evpn` and `Mcast_vpn` each record: a layout
    # parsed from a body that does not fit it invents the fields it did
    # not find, so it would answer `encode` with octets the peer never
    # sent. A body that fails falls back to `Unknown`, which keeps the
    # octets whole and replays them.
    def read_nlri(t, body)
      klass = TYPES[t]
      return nil if klass.nil?
      n = klass.new(body.dup.is_packed)
      n.encode == body ? n : nil
    rescue StandardError
      nil
    end

    def from_hash(h)
      h = h.dup
      @declared_len = h.delete(:length)
      @path_id      = h.delete(:path_id)
      rd = h.delete(:rd)
      if rd
        # An Array is splatted, because that is the shape `Rd#to_hash`
        # answers with: `{:rd => [100, 200]}` against an `Rd.new(100,
        # 200)`. `Mcast_vpn::Route#coerce` records the same thing.
        @rd = rd.is_a?(Rd) ? rd : Rd.new(*[rd].flatten(1))
        # A hash carrying an RD is a VPN NLRI, which is how `Flow_spec`
        # answers the same question for SAFI 134: the key is the signal,
        # since a hash has nowhere else to put the SAFI.
        @safi = IANA::SAFI::BGP_LS_VPN
      end
      key = h.keys.find { |k| BY_KEY.has_key?(k) }
      raise ArgumentError, "no BGP-LS NLRI type in #{h.inspect}" if key.nil?
      @nlri = BY_KEY[key].new(h)
    end

    # The one refusal this class makes, and it is the kind Conventions
    # allows: a length the two-octet field cannot hold cannot be written
    # at all, so packing it would put a different length on the wire
    # than the caller asked for.
    def refuse_a_length_the_field_cannot_hold(n)
      return if n <= MAX_LEN
      raise ArgumentError,
        "BGP-LS Total NLRI Length #{n} does not fit the 2-octet field of " \
        "RFC 9552 section 5.2, max #{MAX_LEN}"
    end

  end

end

load "../../test/unit/nlris/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
