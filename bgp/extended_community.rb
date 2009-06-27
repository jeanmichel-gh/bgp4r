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


require 'bgp/common'
require 'bgp/attribute'

module BGP

  module ATTR::XTENDED_COMMUNITY

    ROUTE_TARGET = 2
    ROUTE_ORIGIN = 3
    OSPF_DOMAIN_ID = 5
    OSPF_ROUTER_ID = 7
    BGP_DATA_COLLECT = 8

    IANA_AUTHORITY_BIT = 0x8
    NON_TRANSITIVE = 0x4    

    TWO_OCTET_AS = 0
    IPV4_ADDR = 1
    OPAQUE = 3

    def _encoded_value_
      case @type & 3
      when TWO_OCTET_AS
        [@global, @local].pack('nN')
      when IPV4_ADDR
        [@global, @local].pack('Nn')
      when OPAQUE
        [@global].pack('H12')
      else
        raise RuntimeError, "bogus type: #{@type}"
      end
    end
    
    def encode
      [@type, @subtype, _encoded_value_].pack('CCa6')
    end
    
    def parse(s)
      @type, @subtype = s.slice!(0,2).unpack('CC')
      case @type & 3
      when TWO_OCTET_AS ; @global, @local = s.unpack('nN')
      when IPV4_ADDR
        @global, @local = s.unpack('Nn')
      when OPAQUE
        @global = s.unpack('H12')
      end
    end
    
    def is_opaque?
      @type & OPAQUE > 0
    end
    
    def is_ipv4_addr?
      @type & IPV4_ADDR > 0
    end
    
    def is_two_octet_asn?
      @type & 3 == TWO_OCTET_AS
    end  
    
    def two_octet
      @type &= ~3
    end
    
    def ipv4_addr
      @type &= ~3
      @type |= 1
    end
    
    def opaque
      @type |= 3
    end
    
    def non_transitive
      @type |= 0x40
    end
    
    def transitive
      @type &= ~0x40
    end
    
    def is_transitive? 
      @type & 0x40 == 0
    end
    
    def non_transitive? 
      not is_transitive?
    end
    
    def to_i
      encode.unpack('H*')[0].to_i(16)
    end
    
    def <=>(other)
      to_i <=> other.to_i
    end
    
    def name
      self.class.to_s.split('::').last.gsub('_',' ')
    end
    
  end
  

  class Extended_community
    include ATTR::XTENDED_COMMUNITY
    include Comparable

    def self.factory(_s)
      if _s.is_a?(Bignum) or _s.is_a?(Fixnum)
        s = [format("%16.16x",_s)].pack('H*')
      else
        s = _s
      end
      type, subtype, value = s.unpack('CCa6')
      case subtype
      when ROUTE_TARGET     ; Route_target.new(s)
      when ROUTE_ORIGIN     ; Route_origin.new(s)
      when OSPF_DOMAIN_ID   ; Ospf_domain_id.new(s)
      when OSPF_ROUTER_ID   ; Ospf_router_id.new(s)
      when BGP_DATA_COLLECT ; Bgp_data_collect.new(s)
      else
        puts "too bad type #{type}, subtype #{subtype} : #{s.unpack('H*')}"
        Extended_community.new(s)
      end
    end

    def initialize(*args)
      @type=TWO_OCTET_AS
      if args.size==1 and args[0].is_a?(String) and args[0].is_packed?
        parse(args[0])
      elsif args.size==3
        @type, @subtype, value = args
        raise ArgumentError, "invalid argument #{args.inspect}"  unless instance_of?(Opaque)
        @type |= OPAQUE
        @global, @local=value, nil
      elsif args.size==4
        raise  ArgumentError, "This is a base class and should not be instanciated"  if instance_of?(Extended_community)
        @type, @subtype, @global, @local = args
        if @global.is_a?(String) and @local.is_a?(Fixnum)
          @type |= IPV4_ADDR
          @global = IPAddr.new(@global).to_i
        end
      elsif args.size==1 and args[0].is_a?(Bignum)
        parse([s].pack('H*'))
      elsif args.empty?
        @type, @subtype, @global, @local = 0,0,0,0
      else
        raise ArgumentError, "invalid arg #{args.inspect}"
      end
    end

    def to_s
      case @type & 3
      when TWO_OCTET_AS
        "#{name}: #{@global}:#{@local}"
      when IPV4_ADDR
        "#{name}: #{IPAddr.create(@global)}:#{@local}"
      when OPAQUE
        "#{name}: #{@global}"
      else
        raise RuntimeError, "bogus type: #{@type}"
      end
    end

  end

  class Route_target < Extended_community
    def initialize(*args)
      if args[0].is_a?(String) and args[0].is_packed?
        super(*args)
      else
        super(0, ROUTE_TARGET, *args)
      end
    end
  end

  class Route_origin < Extended_community
    def initialize(*args)
      if args[0].is_a?(String) and args[0].is_packed?
        super(*args)
      else
        super(0,ROUTE_ORIGIN,*args)
      end
    end
  end

  class Ospf_domain_id < Extended_community
    def initialize(*args)
      if args[0].is_a?(String) and args[0].is_packed?
        super(*args)
      else
        args += [0]
        super(1,OSPF_DOMAIN_ID,*args)
      end
    end
  end

  class Ospf_router_id < Extended_community
    def initialize(*args)
      if args[0].is_a?(String) and args[0].is_packed?
        super(*args)
      else
        args += [0]
        super(1,OSPF_ROUTER_ID,*args)
      end
    end
  end

  class Bgp_data_collect < Extended_community
    def initialize(*args)
      if args[0].is_a?(String) and args[0].is_packed?
        super(*args)
      else
        super(0,BGP_DATA_COLLECT,*args)
      end
    end
  end

  class Opaque < Extended_community
    def initialize(*args)
      if args[0].is_a?(String) and args[0].is_packed?
        super(*args)
      else
        raise ArgumentError, "not an opaque extended community" if [2,3,5,7,8].include?(args[0])
        super(0,*args)
      end
    end
  end

end
