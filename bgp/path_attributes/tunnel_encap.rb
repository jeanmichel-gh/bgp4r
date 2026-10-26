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

require 'bgp/path_attributes/attribute'

module BGP

  # Tunnel Encapsulation, attribute 23, RFC 9012: an optional transitive
  # attribute with one TLV per tunnel, each TLV holding sub-TLVs.
  #
  #   Tunnel_encap.new(Tunnel_encap::Tunnel.new(:vxlan,
  #                      Tunnel_encap::Egress_endpoint.new('10.0.0.1'),
  #                      Tunnel_encap::Color.new(100)))
  #   Tunnel_encap.new(:tunnel_type => :vxlan, :egress_endpoint => '10.0.0.1')
  #   Tunnel_encap.new(wire_bytes)
  #
  # TLVs and sub-TLVs keep their order, and ones bgp4r has no shape for
  # keep their octets: RFC 9012 section 13 says an unrecognized tunnel
  # type or sub-TLV is passed on unchanged. Nothing is checked when
  # building, so a test can send any type, length or combination.
  class Tunnel_encap < Attr

    # The IANA BGP Tunnel Encapsulation Attribute Tunnel Types. The five
    # deprecated ones have no name here; pass their number to send them.
    TUNNEL_TYPES = {
      :l2tpv3                 => 1,
      :gre                    => 2,
      :ip_in_ip               => 7,
      :vxlan                  => 8,
      :nvgre                  => 9,
      :mpls                   => 10,
      :mpls_in_gre            => 11,
      :vxlan_gpe              => 12,
      :mpls_in_udp            => 13,
      :ipv6                   => 14,
      :sr_policy              => 15,
      :bare                   => 16,
      :cloud_security         => 18,
      :geneve                 => 19,
      :any_encapsulation      => 20,
      :gtp                    => 21,
      :dps_tunnel             => 22,
      :originating_pe         => 23,
      :dps_policy             => 24,
      :sdwan_hybrid           => 25,
      :x_over_udp             => 26,
      :des                    => 27,
      :esp_protected_payload  => 28,
    }

    # A sub-TLV bgp4r has no shape for, kept byte for byte. The named
    # subclasses below take field values; each also takes the wire value
    # octets as value:, which is how parsing builds them.
    class Sub_tlv

      # The IANA BGP Tunnel Encapsulation Attribute Sub-TLVs that bgp4r
      # has a shape for.
      ENCAPSULATION           = 1
      PROTOCOL_TYPE           = 2
      COLOR                   = 4
      EGRESS_ENDPOINT         = 6
      DS_FIELD                = 7
      UDP_DEST_PORT           = 8
      EMBEDDED_LABEL_HANDLING = 9
      MPLS_LABEL_STACK        = 10

      attr_reader :type, :value

      def initialize(type, value = ''.b)
        @type, @value = type, value.to_s.b
      end

      # RFC 9012 section 2: a sub-TLV of type 0 to 127 has a one octet
      # length, one of type 128 to 255 a two octet length.
      def self.long_length?(type)
        type >= 128
      end

      # The octets a sub-TLV header takes for this type.
      def self.header_size(type)
        long_length?(type) ? 3 : 2
      end

      # RFC 9012 section 2: type (1 octet), length (1 or 2 octets), value.
      def encode
        if self.class.long_length?(@type)
          [@type, @value.size].pack('Cn') + @value
        else
          [@type, @value.size].pack('CC') + @value
        end
      end

      def to_s
        format('sub-TLV type %d: %s', @type, @value.unpack1('H*'))
      end

      def to_hash
        { :type => @type, :value => @value.unpack1('H*') }
      end

      def ==(other)
        other.class == self.class and other.type == @type and other.value == @value
      end

      # The named class for these octets, or a plain Sub_tlv when bgp4r
      # has no shape for the type or the octets are not shaped the way
      # the RFC gives. Either way the octets are kept: RFC 9012 section
      # 13 says a malformed sub-TLV is treated as unrecognized, so it is
      # still passed on.
      #
      # Only the shape picks the class, never a field's value. A UDP
      # destination port of zero and an embedded label handling other
      # than 1 or 2 are malformed (section 13) but well shaped, so they
      # come back as their own class, where the accessor shows the bad
      # value.
      def self.factory(type, value)
        n = value.size
        case type
        when ENCAPSULATION           then Encapsulation.new(:value => value)
        when PROTOCOL_TYPE           then n == 2 ? Protocol_type.new(:value => value) : new(type, value)
        when COLOR                   then Color.shaped?(value) ? Color.new(:value => value) : new(type, value)
        when EGRESS_ENDPOINT         then [6, 10, 22].include?(n) ? Egress_endpoint.new(:value => value) : new(type, value)
        when DS_FIELD                then n == 1 ? Ds_field.new(:value => value) : new(type, value)
        when UDP_DEST_PORT           then n == 2 ? Udp_dest_port.new(:value => value) : new(type, value)
        when EMBEDDED_LABEL_HANDLING then n == 1 ? Embedded_label_handling.new(:value => value) : new(type, value)
        when MPLS_LABEL_STACK        then (n > 0 and n % 4 == 0) ? Mpls_label_stack.new(:value => value) : new(type, value)
        else                              new(type, value)
        end
      end

      # One sub-TLV from a hash: {:type => 9, :value => '01'} for any
      # type, or one named key, as {:color => 100}.
      def self.from_hash(h)
        return new(h[:type], [h[:value].to_s].pack('H*')) if h.key?(:type)
        key, v = h.first
        case key
        when :encapsulation           then Encapsulation.new([v.to_s].pack('H*'))
        when :protocol_type           then Protocol_type.new(v)
        when :color                   then Color.new(v)
        when :egress_endpoint         then Egress_endpoint.new(v)
        when :ds_field                then Ds_field.new(v)
        when :udp_dest_port           then Udp_dest_port.new(v)
        when :embedded_label_handling then Embedded_label_handling.new(v)
        when :mpls_label_stack        then Mpls_label_stack.new(v)
        else raise ArgumentError, "unknown sub-TLV #{key.inspect}"
        end
      end

      # The named keys from_hash takes, in sub-TLV type order, which is
      # the order a tunnel hash writes them whatever order it lists
      # them in. Pass :sub_tlvs to choose the order instead.
      KEYS = [:encapsulation, :protocol_type, :color, :egress_endpoint,
              :ds_field, :udp_dest_port, :embedded_label_handling,
              :mpls_label_stack].freeze

    end

    # RFC 9012 section 3.1: the Encapsulation sub-TLV, whose shape
    # depends on the tunnel type of its TLV. bgp4r keeps the octets and
    # does not read the fields, so any tunnel type can be built.
    class Encapsulation < Sub_tlv
      def initialize(octets = ''.b, value: nil)
        super(ENCAPSULATION, value || octets)
      end

      def to_s
        "Encapsulation #{@value.unpack1('H*')}"
      end

      def to_hash
        { :encapsulation => @value.unpack1('H*') }
      end
    end

    # A sub-TLV that is one unsigned integer of a fixed size. Subclasses
    # set TYPE, SIZE and NAME.
    class Int_sub_tlv < Sub_tlv
      def initialize(n = 0, value: nil)
        if value
          super(self.class::TYPE, value)
        else
          super(self.class::TYPE, [n.to_i].pack(self.class::SIZE == 1 ? 'C' : 'n'))
        end
      end

      # The integer, or nil when the octets are not the size the RFC
      # gives (parsing keeps such a sub-TLV as a plain Sub_tlv, so this
      # only happens for one built by hand).
      def to_i
        return nil unless @value.size == self.class::SIZE
        self.class::SIZE == 1 ? @value.getbyte(0) : @value.unpack1('n')
      end

      def to_s
        "#{self.class::NAME} #{to_i}"
      end

      def to_hash
        { self.class::KEY => to_i }
      end
    end

    # RFC 9012 section 3.4.1: a 2 octet Ethernet protocol type.
    class Protocol_type < Int_sub_tlv
      TYPE, SIZE, NAME, KEY = PROTOCOL_TYPE, 2, 'Protocol type', :protocol_type
      alias protocol_type to_i
    end

    # RFC 9012 section 3.4.4: the one octet DS field of the outer header.
    class Ds_field < Int_sub_tlv
      TYPE, SIZE, NAME, KEY = DS_FIELD, 1, 'DS field', :ds_field
      alias ds_field to_i
    end

    # RFC 9012 section 3.4.5: the 2 octet outer UDP destination port.
    # Section 13 makes a zero port malformed; building allows it.
    class Udp_dest_port < Int_sub_tlv
      TYPE, SIZE, NAME, KEY = UDP_DEST_PORT, 2, 'UDP destination port', :udp_dest_port
      alias port to_i
    end

    # RFC 9012 section 3.4.2: one octet, 1 or 2. Section 13 makes any
    # other value malformed; building allows it.
    class Embedded_label_handling < Int_sub_tlv
      TYPE, SIZE, NAME, KEY = EMBEDDED_LABEL_HANDLING, 1, 'Embedded label handling', :embedded_label_handling
      alias handling to_i
    end

    # RFC 9012 section 3.4.3: a Color Extended Community, 8 octets. The
    # first two are 0x030b, then 2 octets of flags, then the 4 octet
    # colour value.
    class Color < Sub_tlv
      HEADER = 0x030b

      attr_reader :color_flags

      # RFC 9012 section 3.4.3: a Color sub-TLV that is not 8 octets, or
      # whose first two octets are not 0x030b, is treated as
      # unrecognized, so bgp4r keeps it as a plain Sub_tlv.
      def self.shaped?(value)
        value.size == 8 and value.unpack1('n') == HEADER
      end

      def initialize(colour = 0, flags: 0, value: nil)
        if value
          @color_flags = value.byteslice(2, 2).to_s.unpack1('n')
          super(COLOR, value)
        else
          @color_flags = flags
          super(COLOR, [HEADER, flags, colour.to_i].pack('nnN'))
        end
      end

      # The colour, or nil when the octets are not 8 long.
      def color
        @value.size == 8 ? @value.unpack1('xxxxN') : nil
      end

      def to_s
        "Color #{color}"
      end

      def to_hash
        { :color => color }
      end
    end

    # RFC 9012 section 3.2: reserved (4 octets), address family
    # (2 octets), then the address. The length is 6 with family 0, where
    # the egress endpoint is the next hop, 10 for IPv4 and 22 for IPv6.
    class Egress_endpoint < Sub_tlv
      IPV4, IPV6 = 1, 2

      attr_reader :address, :address_family, :reserved

      # new('10.0.0.1'), new('2001:db8::1'), or new(nil) for family 0.
      def initialize(address = nil, family: nil, reserved: 0, value: nil)
        if value
          @reserved, @address_family = value.unpack('Nn')
          rest = value.byteslice(6, value.size - 6).to_s
          @address = rest.empty? ? nil : IPAddr.new_ntoh(rest).to_s
          super(EGRESS_ENDPOINT, value)
        elsif address.nil?
          @reserved, @address_family, @address = reserved, family || 0, nil
          super(EGRESS_ENDPOINT, [@reserved, @address_family].pack('Nn'))
        else
          ip = IPAddr.new(address.to_s)
          @reserved = reserved
          @address_family = family || (ip.ipv4? ? IPV4 : IPV6)
          @address = ip.to_s
          super(EGRESS_ENDPOINT, [@reserved, @address_family].pack('Nn') + ip.hton)
        end
      end

      def to_s
        "Egress endpoint #{@address || 'the next hop'}"
      end

      def to_hash
        { :egress_endpoint => @address }
      end
    end

    # RFC 9012 section 3.3: a stack of 4 octet MPLS label stack entries
    # (RFC 3032 section 2.1), so the length is a multiple of 4. Building
    # from label values sets the Bottom of Stack bit on the last entry
    # and leaves TC and TTL zero; pass value: to write other octets.
    class Mpls_label_stack < Sub_tlv
      BOTTOM_OF_STACK = 0x100

      attr_reader :labels

      # new(100, 200), new([100, 200]) or new(value: octets).
      def initialize(*args, value: nil)
        if value
          @labels = []
          i = 0
          while i + 4 <= value.size
            @labels << (value.byteslice(i, 4).unpack1('N') >> 12)
            i += 4
          end
          super(MPLS_LABEL_STACK, value)
        else
          @labels = args.flatten.compact.collect(&:to_i)
          last = @labels.size - 1
          packed = @labels.each_with_index.collect { |l, n|
            [(l << 12) | (n == last ? BOTTOM_OF_STACK : 0)].pack('N')
          }.join
          super(MPLS_LABEL_STACK, packed)
        end
      end

      def to_s
        "MPLS label stack #{@labels.join(', ')}"
      end

      def to_hash
        { :mpls_label_stack => @labels }
      end
    end

    # One tunnel: a tunnel type and its sub-TLVs (RFC 9012 section 2).
    class Tunnel

      attr_reader :tunnel_type, :sub_tlvs

      # Tunnel.new(:vxlan, Egress_endpoint.new('10.0.0.1'))
      # Tunnel.new(:tunnel_type => :vxlan, :egress_endpoint => '10.0.0.1')
      # Tunnel.new(:tunnel_type => 8, :sub_tlvs => [{:color => 100}])
      def initialize(*args)
        @sub_tlvs = []
        if args.size == 1 and args[0].is_a?(Hash)
          h = args[0]
          set_type(h[:tunnel_type])
          [h[:sub_tlvs]].flatten.compact.each { |s| @sub_tlvs << Sub_tlv.from_hash(s) }
          Sub_tlv::KEYS.each { |k| @sub_tlvs << Sub_tlv.from_hash(k => h[k]) if h.key?(k) }
          length!(h[:length]) if h[:length]
        else
          set_type(args.shift)
          add(*args)
        end
      end

      # A tunnel from a type and the TLV value octets.
      def self.from_value(tunnel_type, body)
        t = new(tunnel_type)
        t.send(:parse_sub_tlvs, body)
        t
      end

      def add(*args)
        args.each do |arg|
          raise ArgumentError, "invalid sub-TLV #{arg.inspect}" unless arg.is_a?(Sub_tlv)
          @sub_tlvs << arg
        end
        self
      end
      alias << add

      # Writes len as the TLV length instead of the real one, so a test
      # can send the RFC 9012 section 13 malformed case: a TLV whose
      # last octet is not the last octet of its last sub-TLV. A nil
      # removes the override. Returns self.
      def length!(len)
        @length = len
        self
      end

      def tunnel_name
        TUNNEL_TYPES.key(@tunnel_type)
      end

      # The first sub-TLV of a class, or nil.
      def [](klass)
        @sub_tlvs.find { |s| s.is_a?(klass) }
      end

      def egress_endpoint
        s = self[Egress_endpoint]
        s && s.address
      end

      def color
        s = self[Color]
        s && s.color
      end

      # RFC 9012 section 2: tunnel type (2 octets), length (2 octets),
      # then the sub-TLVs.
      def encode
        body = @sub_tlvs.collect(&:encode).join + (@tail || '')
        [@tunnel_type, @length || body.size].pack('nn') + body
      end

      def to_s
        "#{tunnel_name || "type #{@tunnel_type}"}: " +
          (@sub_tlvs.empty? ? 'no sub-TLVs' : @sub_tlvs.collect(&:to_s).join(', '))
      end

      def to_hash
        h = { :tunnel_type => tunnel_name || @tunnel_type }
        h[:sub_tlvs] = @sub_tlvs.collect(&:to_hash) unless @sub_tlvs.empty?
        h[:length] = @length if @length
        h
      end

      def ==(other)
        other.is_a?(Tunnel) and other.encode == encode
      end

      private

      def set_type(type)
        @tunnel_type = type.is_a?(Symbol) ? TUNNEL_TYPES[type] : type
        raise ArgumentError, "unknown tunnel type #{type.inspect}" if @tunnel_type.nil?
        unless @tunnel_type.is_a?(Integer) and (0..0xffff).include?(@tunnel_type)
          raise ArgumentError, "invalid tunnel type #{type.inspect}, expected 0 to 65535"
        end
      end

      # RFC 9012 section 2. A sub-TLV header too short to read, or one
      # that runs past the end of the TLV, is kept as trailing octets so
      # encode gives back what was received.
      def parse_sub_tlvs(body)
        i = 0
        while i < body.size
          hdr = Sub_tlv.header_size(body.getbyte(i))
          if body.size - i < hdr
            @tail = body.byteslice(i, body.size - i).b
            break
          end
          len = hdr == 3 ? body.byteslice(i + 1, 2).unpack1('n') : body.getbyte(i + 1)
          if i + hdr + len > body.size
            @tail = body.byteslice(i, body.size - i).b
            break
          end
          @sub_tlvs << Sub_tlv.factory(body.getbyte(i), body.byteslice(i + hdr, len))
          i += hdr + len
        end
      end

    end

    attr_reader :tunnels

    def initialize(*args)
      @flags, @type = OPTIONAL_TRANSITIVE, TUNNEL_ENCAP
      @tunnels = []
      if args[0].is_a?(String) and args[0].is_packed?
        parse(args[0])
      elsif args[0].is_a?(self.class)
        parse(args[0].encode)
      elsif args.size == 1 and args[0].is_a?(Array)
        args[0].each { |t| add Tunnel.new(t) }
      elsif args.size == 1 and args[0].is_a?(Hash)
        add Tunnel.new(args[0])
      else
        add(*args)
      end
    end

    def add(*args)
      args.each do |arg|
        raise ArgumentError, "invalid tunnel #{arg.inspect}" unless arg.is_a?(Tunnel)
        @tunnels << arg
      end
      self
    end
    alias << add

    # The first tunnel of a type, or nil. Takes a name or a number.
    def [](type)
      n = type.is_a?(Symbol) ? TUNNEL_TYPES[type] : type
      @tunnels.find { |t| t.tunnel_type == n }
    end

    def to_s(method=:default)
      super(@tunnels.collect(&:to_s).join('; '), method)
    end

    def to_hash
      { :tunnel_encap => @tunnels.collect(&:to_hash) }
    end

    def encode
      super(@tunnels.collect(&:encode).join + (@tail || ''))
    end

    private

    # RFC 9012 section 2: each TLV is a 2 octet tunnel type, a 2 octet
    # length, then the sub-TLVs. A header too short to read, or a length
    # that runs past the end of the attribute, is kept as trailing
    # octets so encode gives back what was received. Section 13 makes
    # such an attribute malformed; Path_attribute#errors reports it.
    def parse(s)
      @flags, @type, _, value = super(s)
      i = 0
      while i < value.size
        if value.size - i < 4
          @tail = value.byteslice(i, value.size - i).b
          break
        end
        type = value.byteslice(i, 2).unpack1('n')
        len  = value.byteslice(i + 2, 2).unpack1('n')
        if i + 4 + len > value.size
          @tail = value.byteslice(i, value.size - i).b
          break
        end
        @tunnels << Tunnel.from_value(type, value.byteslice(i + 4, len))
        i += 4 + len
      end
    end

  end

  Attr.register(ATTR::TUNNEL_ENCAP, Tunnel_encap, :tunnel_encap) { |v| Tunnel_encap.new(v) }

end

load "../../test/unit/path_attributes/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
