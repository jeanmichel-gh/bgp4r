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

require 'bgp/path_attributes/attribute'
require 'bgp/nlris/nlris'

module BGP

  class Nsap
    def self.new_ntoh(s)
      puts "in new_ntoh: #{s.unpack('H*')}"
      sbin = s.dup
      _, o1, r = s.unpack('CH2H*')
      new [o1, r.scan(/..../).collect { |x| r.slice!(0,4)}, r].flatten.join('.').chomp('.')
    end
    def initialize(arg)
      # '49.0001.0002.0003.0004.0005.0006.0007.0008 0009'
      @nsap = arg
    end
    def to_s
      @nsap
    end
    def encode
      nsap = '49.0001.0002.0003.0004.0005.0006.0007.0008 0009'
      nsap = [@nsap.gsub(/\./,'')].pack('H*')
      len = nsap.size*8
      s = [len, nsap].pack('Ca*')
      # p " encode nsap:  #{s.unpack('H*')}"
      s
    end
  end
  
  class Iso_ip_mapped < Prefix
    def encode(*args)
      case afi
      when 1
        ['47000601'].pack('H*')+super
      when 2
        ['350000'].pack('H*')+super
      end
    end
  end

  class Mp_reach < Attr

    attr_reader :safi, :nlris, :path_id

    def initialize(*args)
      @safi, @nexthops, @nlris, @path_id= 1, [], [], nil # default is ipv4/unicast
      @flags, @type = OPTIONAL, MP_REACH
      if args[0].is_a?(String) and args[0].is_packed?
        parse(*args)
      elsif args[0].is_a?(self.class)
        s = args.shift.encode
        parse(s, *args)
      elsif args[0].is_a?(Hash) and args.size==1
        set(*args)
      else
        raise ArgumentError, "invalid argument" 
      end
    end

    def afi
      @afi ||= @nexthops[0].afi
    end

    def mapped_nexthop(nexthop)
      nh = IPAddr.new(nexthop)
    end

    def set(h)
      @safi = h[:safi]
      @path_id = path_id = h[:path_id]


      if h[:afi]==3
          @afi = 3
          # mpr1 =  Mp_reach.new(:afi=>3, :safi=>1, :nexthop=> ['10.0.0.1'], :nlris=> '49.0001.0002.0003.0004.0005.0006' )
          @nlris = [h[:nlris]].flatten.collect do |n|
            nlri = Nsap.new(n)
          end
        case @safi
        when 1
          @nexthops = [h[:nexthop]].flatten.collect { |nh| Iso_ip_mapped.new(nh) }
        else
          raise
        end

      else

        case @safi
        when 1,2,4   ; @nexthops = [h[:nexthop]].flatten.collect { |nh| Prefix.new(nh) }
        when 128,129 ; @nexthops = [h[:nexthop]].flatten.collect { |nh| Vpn.new(nh) }
        else
        end

        case @safi
        when 1
          @nlris = [h[:nlris]].flatten.collect do |n|
            case n
            when String
              nlri = Inet_unicast.new(n)
              path_id ? Ext_Nlri.new(path_id, nlri) : nlri
            when Hash
              path_id = n[:path_id] if n[:path_id]
              nlri = Inet_unicast.new(n[:prefix])
              path_id ? Ext_Nlri.new(path_id, nlri) : nlri
            else
              raise ArgumentError, "Invalid: #{n.inspect}"
            end
          end
        when 2
          @nlris = [h[:nlris]].flatten.collect do |n|
            case n
            when String
              nlri = Inet_multicast.new(n)
              path_id ? Ext_Nlri.new(path_id, nlri) : nlri
            when Hash
              path_id = n[:path_id] if n[:path_id]
              nlri = Inet_multicast.new(n[:prefix])
              path_id ? Ext_Nlri.new(path_id, nlri) : nlri
            else
              raise ArgumentError, "Invalid: #{n.inspect}"
            end
          end
        when 4
          @nlris = [h[:nlris]].flatten.collect do |n|
            path_id = n[:path_id] || @path_id
            prefix = n[:prefix].is_a?(String) ? Prefix.new(n[:prefix]) : n[:prefix]
            nlri = Labeled.new(prefix, *n[:label]) 
            path_id ? Ext_Nlri.new(path_id, nlri) : nlri
          end
        when 128,129
          @nlris = [h[:nlris]].flatten.collect do |n|
            path_id = n[:path_id] || @path_id
            prefix = n[:prefix].is_a?(Prefix) ? n[:prefix] :  Prefix.new(n[:prefix]) 
            rd = n[:rd].is_a?(Rd) ?  n[:rd] : Rd.new(*n[:rd])
            nlri = Labeled.new(Vpn.new(prefix,rd), *n[:label]) 
            path_id ? Ext_Nlri.new(path_id, nlri) : nlri
          end
        else
        end
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

    def parse(s,arg=false)

      @flags, @type, len, value = super(s)
      @afi, @safi, nh_len = value.slice!(0,4).unpack('nCC')

      case @afi
      when 3

        parse_iso_mapped_next_hops value.slice!(0,nh_len).is_packed
        value.slice!(0,1)

        if arg.respond_to?(:path_id?)
          path_id_flag = arg.path_id? :recv, @afi, @safi
        else
          path_id_flag = arg
        end

        while value.size>0
          path_id = value.slice!(0,4).unpack('N')[0]  if path_id_flag
          blen = value.slice(0,1).unpack('C')[0]
          nlri = Nsap.new_ntoh(value.slice!(0,(blen+7)/8+1))
          @nlris << nlri
        end

      else

        parse_next_hops value.slice!(0,nh_len).is_packed
        value.slice!(0,1)

        if arg.respond_to?(:path_id?)
          path_id_flag = arg.path_id? :recv, @afi, @safi
        else
          path_id_flag = arg
        end

        while value.size>0
          path_id = value.slice!(0,4).unpack('N')[0]  if path_id_flag
          blen = value.slice(0,1).unpack('C')[0]
          nlri = Nlri.factory(value.slice!(0,(blen+7)/8+1), @afi, @safi)
          if path_id_flag
            @nlris << Ext_Nlri.new(path_id, nlri)
          else
            @nlris << nlri
          end
        end
      end
      raise RuntimeError, "leftover afer parsing: #{value.unpack('H*')}" if value.size>0
    end

    def parse_iso_mapped_next_hops(s)
      while s.size>0
        case s.slice(0,1).unpack('C')[0]
        when 0x47
          s.slice!(0,4)
          @nexthops << Iso_ip_mapped.new(Prefix.new([32,s.slice!(0,4)].pack('Ca*'),1).to_s)
        when 0x35
          s.slice!(0,3)
          @nexthops << Iso_ip_mapped.new(Prefix.new([128,s.slice!(0,16)].pack('Ca*'),2).to_s)
        else
          raise
        end
      end
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
        nlris =  @nlris.collect { |n| n.encode }.join
        super([afi, @safi, nexthops.size, nexthops, 0, nlris ].pack('nCCa*Ca*'))
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

load "../../test/unit/path_attributes/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
