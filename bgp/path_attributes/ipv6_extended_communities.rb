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

  # IPv6 Address Specific Extended Community, attribute 25, RFC 5701: an
  # optional transitive attribute holding 20-octet values.
  #
  #   Ipv6_extended_communities.new([:route_target, '2001:db8::1', 100])
  #   Ipv6_extended_communities.new(
  #     Ipv6_extended_communities::Ipv6_extended_community.new(:route_origin, '2001:db8::2', 7))
  #   Ipv6_extended_communities.new(wire_bytes)
  #   Path_attribute.new(:ipv6_extended_communities =>
  #     [{:subtype=>:route_target, :global_admin=>'2001:db8::1', :local_admin=>100}])
  #
  # Values keep their order and duplicates. Every 20-octet value maps to
  # its four fields, so unknown sub-types round trip too.
  class Ipv6_extended_communities < Attr

    # One 20-octet value (RFC 5701 section 2): Type high octet, Sub-Type,
    # a 16-octet IPv6 Global Administrator, a 2-octet Local Administrator.
    class Ipv6_extended_community
      include Comparable

      TRANSITIVE     = 0x00
      NON_TRANSITIVE = 0x40

      # RFC 5701 section 3. The sub-types are the IPv4 address specific ones.
      ROUTE_TARGET = 0x02
      ROUTE_ORIGIN = 0x03
      NAMES = { ROUTE_TARGET => :route_target, ROUTE_ORIGIN => :route_origin }
      LABELS = { ROUTE_TARGET => 'Route target', ROUTE_ORIGIN => 'Route origin' }

      attr_reader :type, :subtype, :global_admin, :local_admin

      # new(subtype, ipv6_address, local) where subtype is :route_target,
      # :route_origin or 0 to 255; options transitive: false (type 0x40)
      # or type: any octet. Also new(hash) and new(20 octets).
      def initialize(*args, transitive: true, type: nil)
        if args.size == 1 and args[0].is_a?(String) and args[0].bytesize == 20
          parse(args[0])
        elsif args.size == 1 and args[0].is_a?(Hash)
          h = args[0]
          set(h[:type] || TRANSITIVE, h[:subtype], h[:global_admin], h[:local_admin])
        elsif args.size == 3
          set(type || (transitive ? TRANSITIVE : NON_TRANSITIVE), *args)
        else
          raise ArgumentError, "invalid IPv6 extended community #{args.inspect}, expected (subtype, ipv6, local), a hash or 20 octets"
        end
      end

      def transitive?
        (@type & NON_TRANSITIVE) == 0
      end

      # :route_target, :route_origin, or nil for other sub-types.
      def name
        NAMES[@subtype]
      end

      def encode
        [@type, @subtype].pack('CC') + IPAddr.new(@global_admin).hton + [@local_admin].pack('n')
      end

      def to_a
        [@type, @subtype, @global_admin, @local_admin]
      end

      def to_s
        what = LABELS[@subtype] || format('Sub-type 0x%02x', @subtype)
        s = "#{what}: [#{@global_admin}]:#{@local_admin}"
        s += format(' (type 0x%02x)', @type) unless @type == TRANSITIVE
        s
      end

      def to_hash
        { :type => @type, :subtype => name || @subtype, :global_admin => @global_admin, :local_admin => @local_admin }
      end

      def <=>(other)
        encode <=> other.encode
      end

      def eql?(other)
        other.is_a?(Ipv6_extended_community) and encode == other.encode
      end

      def hash
        encode.hash
      end

      private

      def set(type, subtype, global, local)
        subtype = NAMES.key(subtype) if subtype.is_a?(Symbol)
        unless type.is_a?(Integer) and (0..255).include?(type)
          raise ArgumentError, "invalid type #{type.inspect}, expected 0 to 255"
        end
        unless subtype.is_a?(Integer) and (0..255).include?(subtype)
          raise ArgumentError, "invalid sub-type #{subtype.inspect}, expected :route_target, :route_origin or 0 to 255"
        end
        addr = begin
          IPAddr.new(global.to_s)
        rescue IPAddr::Error
          nil
        end
        raise ArgumentError, "invalid IPv6 Global Administrator #{global.inspect}" unless addr and addr.ipv6?
        unless local.is_a?(Integer) and (0..0xffff).include?(local)
          raise ArgumentError, "invalid Local Administrator #{local.inspect}, expected 0 to 65535"
        end
        @type, @subtype, @global_admin, @local_admin = type, subtype, addr.to_s, local
      end

      # RFC 5701 section 2.
      def parse(s)
        @type, @subtype = s.unpack('CC')
        @global_admin = IPAddr.new_ntoh(s.byteslice(2, 16)).to_s
        @local_admin = s.byteslice(18, 2).unpack1('n')
      end
    end

    def initialize(*args)
      @flags, @type = OPTIONAL_TRANSITIVE, IPV6_EXTENDED_COMMUNITY
      @communities = []
      if args[0].is_a?(String) and args[0].is_packed?
        parse(args[0])
      elsif args[0].is_a?(self.class)
        parse(args[0].encode)
      elsif args.size == 1 and args[0].is_a?(Hash) and args[0].key?(:ipv6_extended_communities)
        add(*args[0][:ipv6_extended_communities])
      else
        add(*args)
      end
    end

    # Adds values: Ipv6_extended_community objects, [subtype, ipv6, local]
    # arrays, or hashes as to_hash gives them. Returns self.
    def add(*args)
      take_tail(args).each do |arg|
        if arg.is_a?(Array) and not (arg.size == 3 and (arg[0].is_a?(Symbol) or arg[0].is_a?(Integer)))
          add(*arg)      # a list of values
          next
        end
        @communities << case arg
        when Ipv6_extended_community ; arg
        when Array                   ; Ipv6_extended_community.new(*arg)
        when Hash                    ; Ipv6_extended_community.new(arg)
        else
          raise ArgumentError, "invalid IPv6 extended community #{arg.inspect}"
        end
      end
      self
    end
    alias << add

    def communities
      @communities.dup
    end

    def size
      @communities.size
    end

    def has?(arg)
      c = arg.is_a?(Ipv6_extended_community) ? arg : Ipv6_extended_community.new(*arg)
      @communities.include?(c)
    end

    def to_s(method=:default)
      super(@communities.collect(&:to_s).join(', '), method)
    end

    # The values, plus a {:tail=>hex} entry when octets were kept
    # (Attr::TAIL_KEY), so the hash of a malformed attribute round trips
    # byte for byte through new.
    def to_hash
      { :ipv6_extended_communities => @communities.collect(&:to_hash) + [tail_entry].compact }
    end

    def encode
      super(@communities.collect(&:encode).join + (@tail || ''))
    end

    private

    # Octets past the last whole value are kept, so encode gives back what
    # was received. RFC 7606 section 7.15 makes such an attribute
    # malformed; Path_attribute#errors reports it.
    def parse(s)
      @flags, @type, _, value = super(s)
      whole = value.size / 20 * 20
      (0...whole).step(20) { |i| @communities << Ipv6_extended_community.new(value.byteslice(i, 20)) }
      @tail = value.byteslice(whole, value.size - whole).b if value.size > whole
    end

  end

  Attr.register(ATTR::IPV6_EXTENDED_COMMUNITY, Ipv6_extended_communities, :ipv6_extended_communities)

end

load "../../test/unit/path_attributes/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
