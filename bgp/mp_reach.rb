#--
# Copyright 2008, 2009 Jean-Michel Esnault.
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


require 'bgp/attribute'
require 'bgp/nlri'

module BGP

    class Mp_unreach < Attr

      attr_reader :safi, :nlris

      def initialize(*args)
        @safi, @nlris= 1, []
        @flags, @type = OPTIONAL, MP_UNREACH
        if args[0].is_a?(String) and args[0].is_packed?
          parse(args[0])
        elsif args[0].is_a?(self.class)
          parse(args[0].encode, *args[1..-1])
        elsif args[0].is_a?(Hash) and args.size==1
          set(*args)
        else
          raise ArgumentError, "invalid argument" 
        end
      end

      def afi
        @afi ||= @nlris[0].afi
      end

      def set(h)
        @safi = h[:safi]
        case @safi
        when 1,2
          @nlris = [h[:prefix]].flatten.collect { |p| p.is_a?(Prefix) ? p : Prefix.new(p) }
        when 4
          @nlris = [h[:nlri]].flatten.collect { |n|
            prefix = n[:prefix].is_a?(String) ? Prefix.new(n[:prefix]) : n[:prefix]
            Labeled.new(prefix, *n[:label]) 
          }
        when 128,129 ; @nlris = [h[:nlri]].flatten.collect { |n| 
          prefix = n[:prefix].is_a?(Prefix) ? n[:prefix] :  Prefix.new(n[:prefix]) 
          rd = n[:rd].is_a?(Rd) ?  n[:rd] : Rd.new(*n[:rd])
          Labeled.new(Vpn.new(prefix,rd), *n[:label]) }
        else
        end
      end

      def mp_unreach
        "\n    AFI #{IANA.afi(afi)} (#{afi}), SAFI #{IANA.safi(safi)} (#{safi})" +
        (['']+ @nlris.collect { |nlri| nlri.to_s }).join("\n      ")
      end

      def to_s(method=:default)
        super(mp_unreach, method)
      end

      def parse(s)
        @flags, @type, len, value = super(s)
        @afi, @safi = value.slice!(0,3).unpack('nC')
        while value.size>0
          blen = value.slice(0,1).unpack('C')[0]
          @nlris << Nlri.factory(value.slice!(0,(blen+7)/8+1), @afi, @safi)
        end
        raise RuntimeError, "leftover afer parsing: #{value.unpack('H*')}" if value.size>0
      end

      def encode
        super([afi, @safi, @nlris.collect { |n| n.encode }.join].pack('nCa*'))
      end
      
    end
    
    class Mp_reach < Attr
      
      attr_reader :safi, :nlris
      
      def initialize(*args)
        @safi, @nexthops, @nlris= 1, [], [] # default is ipv4/unicast
        @flags, @type = OPTIONAL, MP_REACH
        if args[0].is_a?(String) and args[0].is_packed?
          parse(args[0])
        elsif args[0].is_a?(self.class)
          parse(args[0].encode, *args[1..-1])
        elsif args[0].is_a?(Hash) and args.size==1
          set(*args)
        else
          raise ArgumentError, "invalid argument" 
        end
      end
      
      def afi
        @afi ||= @nexthops[0].afi
      end
      
      def set(h)
        @safi = h[:safi]
        case @safi
        when 1,2,4   ; @nexthops = [h[:nexthop]].flatten.collect { |nh| Prefix.new(nh) }
        when 128,129 ; @nexthops = [h[:nexthop]].flatten.collect { |nh| Vpn.new(nh) }
        else
        end
        case @safi
        when 1,2
          @nlris = [h[:prefix]].flatten.collect { |n| Prefix.new(n) }
        when 4
          @nlris = [h[:nlri]].flatten.collect { |n|
            prefix = n[:prefix].is_a?(String) ? Prefix.new(n[:prefix]) : n[:prefix]
            Labeled.new(prefix, *n[:label]) 
          }
        when 128,129 ; @nlris = [h[:nlri]].flatten.collect { |n| 
          prefix = n[:prefix].is_a?(Prefix) ? n[:prefix] :  Prefix.new(n[:prefix]) 
          rd = n[:rd].is_a?(Rd) ?  n[:rd] : Rd.new(*n[:rd])
          Labeled.new(Vpn.new(prefix,rd), *n[:label]) }
        else
        end
      end
      
      def nexthops
        @nexthops.collect { |nh| nh.nexthop }.join(", ")
      end
      
      def mp_reach
        "\n    AFI #{IANA.afi(afi)} (#{afi}), SAFI #{IANA.safi(safi)} (#{safi})" +
        "\n    nexthop: " + nexthops +
        (['']+ @nlris.collect { |nlri| nlri.to_s }).join("\n      ")
      end
      
      def to_s(method=:default)
        super(mp_reach, method)
      end
      
      def to_hash
      end
      
      
      def parse(s)
        @flags, @type, len, value = super(s)
        @afi, @safi, nh_len = value.slice!(0,4).unpack('nCC')
        parse_next_hops value.slice!(0,nh_len).is_packed
        value.slice!(0,1)
        while value.size>0
          blen = value.slice(0,1).unpack('C')[0]
          @nlris << Nlri.factory(value.slice!(0,(blen+7)/8+1), @afi, @safi)
        end
        raise RuntimeError, "leftover afer parsing: #{value.unpack('H*')}" if value.size>0
        
      end
      
      def parse_next_hops(s)
        while s.size>0
          case @safi
          when 1,2,4
            case @afi
            when 1
              @nexthops << Prefix.new([32,s.slice!(0,4)].pack('Ca*'),1)
            when 2
              @nexthops << Prefix.new([128,s.slice!(0,16)].pack('Ca*'),2)
            end
          when 128,129
            @nexthops << Vpn.new([64+32,s.slice!(0,12)].pack('Ca*'))
          else
            raise RuntimeError, "cannot parse nexthop for safi #{@safi}"
          end
        end
      end
      
      def encode(what=:mp_reach)
        case what
        when :mp_reach
          nexthops = @nexthops.collect { |nh| nh.encode(false) }.join
          super([afi, @safi, nexthops.size, nexthops, 0, @nlris.collect { |n| n.encode }.join].pack('nCCa*Ca*'))
        when :mp_unreach
          super([afi, @safi, @nlris.collect { |n| n.encode }.join].pack('nCa*'))
        end
      end
      
      def new_unreach
        s = encode(:mp_unreach)
        s[1]= [MP_UNREACH].pack('C')
        Mp_unreach.new(s)
      end
      
    end
      
end

load "../test/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
