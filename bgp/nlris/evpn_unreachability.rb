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
require 'bgp/nlris/evpn_route'
require 'bgp/nlris/unreachability'

module BGP

  class Unreachability

    # draft-tantsura-bess-evpn-unreachability-02 section 3.6.3: the EVI
    # sub-TLV, 4 octets. EVPN's only; under SAFI 81 type 3 is unassigned
    # and reads as an Unknown.
    class Evi < Tlv

      TYPE = 3
      HASH_KEY = :evi

      attr_reader :evi

      def initialize(*args)
        @evi = 0
        arg = args[0]
        if args.size == 1 and arg.is_a?(String) and arg.is_packed?
          raise ArgumentError, "an EVI is 4 octets, not #{arg.size}" if arg.size != 4
          @evi = arg.unpack1('N')
        elsif args.size == 1 and arg.is_a?(self.class)
          @evi = arg.evi
          @declared_len = arg.declared_len
        elsif args.size == 1 and arg.is_a?(Hash)
          @evi = self.class.unwrap(arg).to_i
          length_from(arg)
        elsif args.size == 1 and arg.is_a?(Integer)
          @evi = arg
        else
          raise ArgumentError, "invalid argument: #{args.inspect}"
        end
        raise ArgumentError, "an EVI of #{@evi} does not fit in 4 octets" unless (0..0xffff_ffff).include?(@evi)
        self
      end

      def encode_value
        [@evi].pack('N')
      end

      def value_hash
        @evi
      end

      def to_s
        "EVI #{@evi}"
      end

    end

    # The EVPN draft's reason codes: section 3.6.1, codes 0 to 9 as SAFI
    # 81's, then three of its own.
    EVPN_REASONS = REASONS.merge(
      10 => 'MAC Mobility Limit Exceeded',
      11 => 'Tenant Isolation Violation',
      12 => 'VTEP Unreachable',
    ).freeze

    # The Reason Code sub-TLV as the EVPN draft names its codes. The
    # same octets as SAFI 81's; only the names differ, since 10 to 12
    # are EVPN's and unassigned under SAFI 81.
    class Evpn_reason_code < Reason_code
      def name
        EVPN_REASONS[@code] || Unreachability.reason_name(@code)
      end
    end

    # Section 8.3 of the EVPN draft: the sub-TLV registry, types 1 to 3.
    EVPN_SUB_TLVS = Tlv::Registry.new('EVPN Unreachability sub-TLV')
    EVPN_SUB_TLVS.register(Evpn_reason_code)
    EVPN_SUB_TLVS.register(Timestamp)
    EVPN_SUB_TLVS.register(Evi)

    # The Reporter TLV of the EVPN draft, section 3.5. The same octets as
    # SAFI 81's; it reads its sub-TLVs against EVPN_SUB_TLVS.
    class Evpn_reporter < Reporter

      def self.sub_registry
        EVPN_SUB_TLVS
      end

      # The first EVI's value, or nil.
      def evi
        e = @sub_tlvs.find { |s| s.is_a?(Evi) }
        e && e.evi
      end

    end

    # Section 8.2 of the EVPN draft: the Reporter TLV registry, type 1.
    EVPN_REPORTER_TLVS = Tlv::Registry.new('EVPN Unreachability Reporter TLV')
    EVPN_REPORTER_TLVS.register(Evpn_reporter)

  end

  class Evpn

    # The IP Prefix Unreachability route of
    # draft-tantsura-bess-evpn-unreachability-02, section 3.3:
    #
    #   Route Type (1 octet), Length (1 octet), then
    #   Route Distinguisher (8), Ethernet Segment Identifier (10),
    #   Ethernet Tag ID (4), Address Family (1), IP Prefix Length (1),
    #   IP Prefix (4 or 16), GW IP Address Length (1) = 0,
    #   MPLS Label (3) = 0, Reporter TLVs (variable)
    #
    # **TYPE is 254, and 254 is provisional.** The draft says "TBD1". The
    # owner was told on 2026-11-21 that 254 is the on-wire value, IANA
    # assignment pending, and chose a constant (docs/design/
    # unreachability.md, question 1). Change it here when IANA assigns
    # one.
    #
    # The Address Family octet, 1 or 2, decides the width of the IP
    # Prefix, as section 3.3 says a receiver "MUST use this field". Any
    # other value cannot be read as this route, so `Evpn` keeps it as an
    # `Evpn::Unknown`, which replays it.
    #
    # The GW IP Address is read for as many octets as its Length says,
    # though section 3.3 says it MUST be 0, so a route that breaks the
    # rule still replays. **Nothing validates**: a non-zero ESI, gateway
    # or label, no reporter, an IP Prefix Length past the family, each
    # builds and encodes. What a receiver does with them is
    # `Attr::Check#evpn_unreachability_finding`.
    class Ip_prefix_unreachability < Route

      TYPE, HASH_KEY = 254, :ip_prefix_unreachability

      # The address family octet's two values, and the prefix width each
      # gives.
      WIDTHS = { 1 => 4, 2 => 16 }.freeze
      MAX_MLEN = { 1 => 32, 2 => 128 }.freeze

      # From the Route Distinguisher to the MPLS Label: 8 + 10 + 4 + 1 +
      # 1 + 1 + 3, plus the prefix. 32 for IPv4 and 44 for IPv6, which
      # section 3.3's Examples 1 and 3 add up to.
      def self.fixed_size(address_family)
        w = WIDTHS[address_family]
        w && 8 + 10 + 4 + 1 + 1 + w + 1 + 3
      end

      attr_reader :rd, :esi, :ethernet_tag_id, :address_family, :prefix_len,
                  :prefix_octets, :gw_octets, :mpls_label, :reporters, :tail

      # Ip_prefix_unreachability.new(rd, esi, ethernet_tag_id, ip_prefix, reporters)
      # Ip_prefix_unreachability.new(:rd=>..., :ip_prefix=>'192.0.2.0/24', :reporters=>[...])
      # Ip_prefix_unreachability.new(octets)
      def initialize(*args)
        defaults
        if args.size == 1 and args[0].is_a?(String) and args[0].is_packed?
          parse(args[0])
        elsif args.size == 1 and args[0].is_a?(self.class)
          parse(args[0].encode.is_packed)
        elsif args.size == 1 and args[0].is_a?(Hash)
          from_hash(args[0])
        elsif (1..5).include?(args.size)
          @rd              = coerce_or_default(Rd, args[0])
          @esi             = coerce_or_default(Esi, args[1])
          @ethernet_tag_id = coerce_or_default(Ethernet_tag_id, args[2])
          set_prefix(args[3])
          @reporters       = build_reporters(args[4])
        elsif args.empty?
        else
          raise ArgumentError, "invalid argument: #{args.inspect}"
        end
        refuse_what_cannot_be_held
        self
      end

      def parse(s)
        @rd              = read_rd(s)
        @esi             = Esi.new(s)
        @ethernet_tag_id = Ethernet_tag_id.new(s)
        raise ArgumentError, 'no Address Family octet' if s.empty?
        @address_family  = s.slice!(0, 1).unpack1('C')
        w = WIDTHS[@address_family]
        raise ArgumentError, "Address Family #{@address_family}, not 1 or 2" if w.nil?
        raise ArgumentError, 'route cut in the IP Prefix' if s.size < 1 + w + 1
        @prefix_len      = s.slice!(0, 1).unpack1('C')
        @prefix_octets   = s.slice!(0, w)
        gw_len           = s.slice!(0, 1).unpack1('C')
        raise ArgumentError, 'route cut in the GW IP Address' if s.size < gw_len + 3
        @gw_octets       = s.slice!(0, gw_len)
        @mpls_label      = ("\x00" + s.slice!(0, 3)).unpack1('N')
        @reporters       = Unreachability::EVPN_REPORTER_TLVS.parse_list(s)
        @tail            = s.to_s.b
        self
      end

      def encode_value
        [@rd.encode, @esi.encode, @ethernet_tag_id.encode,
         [@address_family, @prefix_len].pack('CC'), @prefix_octets,
         [@gw_octets.size].pack('C'), @gw_octets,
         [@mpls_label].pack('N')[1, 3],
         @reporters.collect(&:encode).join, @tail].join
      end

      def ipv6?
        @address_family == 2
      end

      # The prefix as text, when the family is 1 or 2, the width is the
      # family's and the length fits it. nil otherwise.
      def ip_prefix
        return nil unless natural_prefix?
        "#{IPAddr.new_ntoh(@prefix_octets).mask(@prefix_len)}/#{@prefix_len}"
      end

      # Only the Reporter TLVs of type 1 that read as one.
      def reporter_tlvs
        @reporters.select { |r| r.is_a?(Unreachability::Reporter) }
      end

      # Section 4.5.2: a withdrawal carries the key fields without any
      # Reporter TLVs.
      def withdrawal?
        @reporters.empty? and @tail.empty?
      end

      def value_hash
        h = @rd.to_hash.merge(@esi.to_hash).merge(@ethernet_tag_id.to_hash)
        h = h.merge(prefix_hash)
        h[:gateway] = @gw_octets.unpack1('H*') unless @gw_octets.empty?
        h[:mpls_label] = @mpls_label unless @mpls_label.zero?
        h[:reporters] = @reporters.collect(&:to_hash) unless @reporters.empty?
        h[:tail] = @tail.unpack1('H*') unless @tail.empty?
        h
      end

      def to_s
        s = +"[254] IP Prefix Unreachability: #{@rd.to_s(false)}, ESI #{@esi}, " \
             "tag #{@ethernet_tag_id}, prefix #{ip_prefix || prefix_hex}"
        s << ", gateway #{@gw_octets.unpack1('H*')}" unless @gw_octets.empty?
        s << ", label #{@mpls_label}" unless @mpls_label.zero?
        @reporters.each { |r| s << "\n      #{r}" }
        s << "\n      tail #{@tail.unpack1('H*')}" unless @tail.empty?
        s
      end

      private

      def defaults
        @rd              = Rd.new
        @esi             = Esi.new
        @ethernet_tag_id = Ethernet_tag_id.new
        @address_family  = 1
        @prefix_len      = 0
        @prefix_octets   = ("\x00" * 4).b
        @gw_octets       = +''.b
        @mpls_label      = 0
        @reporters       = []
        @tail            = +''.b
      end

      def natural_prefix?
        w = WIDTHS[@address_family]
        w and @prefix_octets.size == w and @prefix_len <= MAX_MLEN[@address_family]
      end

      def prefix_hex
        "#{@prefix_octets.unpack1('H*')}/#{@prefix_len}"
      end

      def prefix_hash
        a = ip_prefix
        return { :ip_prefix => a } if a and
          IPAddr.new(a).hton == @prefix_octets
        { :ip_prefix => { :address_family => @address_family, :len => @prefix_len,
                          :octets => @prefix_octets.unpack1('H*') } }
      end

      # A prefix string, or the hash prefix_hash answers for one that is
      # not natural: a family other than 1 or 2, a length past it, or bits
      # set past the length.
      def set_prefix(v)
        case v
        when nil
        when Hash
          @address_family = (v[:address_family] || 1).to_i
          @prefix_len     = v[:len].to_i
          @prefix_octets  = [v[:octets].to_s].pack('H*').b
        else
          ip = IPAddr.new(v.to_s)
          @address_family = ip.ipv6? ? 2 : 1
          @prefix_len     = v.to_s.include?('/') ? v.to_s.split('/').last.to_i : (ip.ipv6? ? 128 : 32)
          @prefix_octets  = ip.hton
        end
      end

      def build_reporters(list)
        [list].flatten.compact.collect { |r| Unreachability::EVPN_REPORTER_TLVS.build(r) }
      end

      def from_hash(h)
        h = self.class.unwrap(h)
        @rd              = coerce_or_default(Rd, h[:rd])
        @esi             = coerce_or_default(Esi, h[:esi])
        @ethernet_tag_id = coerce_or_default(Ethernet_tag_id, h[:ethernet_tag_id])
        set_prefix(h[:ip_prefix])
        @gw_octets       = [h[:gateway].to_s].pack('H*').b if h[:gateway]
        @mpls_label      = h[:mpls_label].to_i if h[:mpls_label]
        @reporters       = build_reporters(h[:reporters])
        @tail            = [h[:tail].to_s].pack('H*').b if h[:tail]
      end

      def refuse_what_cannot_be_held
        raise ArgumentError, "an Address Family of #{@address_family} does not fit in 1 octet" unless (0..255).include?(@address_family)
        raise ArgumentError, "a GW IP Address of #{@gw_octets.size} octets does not fit a 1-octet length" if @gw_octets.size > 255
        raise ArgumentError, "an MPLS Label field of #{@mpls_label} does not fit in 3 octets" unless (0..0xffffff).include?(@mpls_label)
      end

    end

  end

end
