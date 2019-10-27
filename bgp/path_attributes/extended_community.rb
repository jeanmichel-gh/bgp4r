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
require 'bgp/path_attributes/attribute'

module BGP

  module ATTR::XTENDED_COMMUNITY

    ROUTE_TARGET = 2
    ROUTE_ORIGIN = 3
    LINK_BANDWIDTH = 4
    OSPF_DOMAIN_ID = 5
    OSPF_ROUTER_ID = 7

    BGP_ORIGIN_VALIDATION_STATE = 0
    BGP_DATA_COLLECT = 8
    COLOR = 11
    ENCAPSULATION = 12

    IANA_AUTHORITY_BIT = 0x80
    TRANSITIVE = 0x0    
    NON_TRANSITIVE = 0x40    

    TWO_OCTET_AS = 0
    IPV4_ADDR = 1
    OPAQUE = 3
    FLOAT = -1
    
    DEFAULT_OPAQUE_ENCODING = 'H12'

    def encode
      [@type, @subtype, _encoded_value_].pack('CCa6')
    end
    
    def parse(s)
      @type, @subtype = s.slice!(0,2).unpack('CC')
      case community_structure
      when TWO_OCTET_AS ; @global, @local = s.unpack('nN')
      when IPV4_ADDR
        @global, @local = s.unpack('Nn')
      when OPAQUE
        case self
        when Color
          _,@global = s.unpack('nN')
        # when Encapsulation
          _,@global = s.unpack('Nn')
        when Origin_validation_state
          _,@global = s.unpack('nN')
        else
          @global = s.unpack('H12')
        end
      when FLOAT
        _, @global = s.unpack('ng')
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
    def to_s
      "#{name}: #{value}"
    end
    
    def to_hash
      { self.class.to_s.split('::').last.downcase.to_sym => value2 }
    end

    private

    def value
      case community_structure
      when TWO_OCTET_AS
        "#{@global}:#{@local}"
      when IPV4_ADDR
        "#{IPAddr.create(@global)}:#{@local}"
      when OPAQUE
        "#{@global}"
      when FLOAT
        "#{[@global].pack('g').unpack('g')[0]}"
      else
        raise RuntimeError, "bogus type: #{@type}"
      end
      
    end

    def value2
      case community_structure
      when FLOAT ; @global
      when IPV4_ADDR ;  ["#{IPAddr.create(@global)}",@local]
      else 
        [@global, @local]
      end
    end

    def community_structure
      cs = @type & 3
      cs = FLOAT if cs == TWO_OCTET_AS and @subtype == LINK_BANDWIDTH
      return cs
    end

    def _encoded_value_
      case community_structure
      when TWO_OCTET_AS
        [@global, @local].pack('nN')
      when IPV4_ADDR
        [@global, @local].pack('Nn')
      when OPAQUE
        case self
        when BGP::Color
          [0,@global].pack('nN')
        when BGP::Origin_validation_state
          [0,@global].pack('nN')
        # when BGP::Encapsulation
        #   [0,@global].pack('Nn')
        else
          [@global].pack('H12')
        end
      when FLOAT
        [0,@global].pack('ng')
      else
        raise RuntimeError, "bogus type: #{@type}"
      end
    end
    
  end
  

  class Extended_community
    include ATTR::XTENDED_COMMUNITY
    include Comparable

    def self.factory(_s)
      if _s.is_a?(Integer)
        s = [format("%16.16x",_s)].pack('H*')
      else
        s = _s
      end
      type, subtype, _ = s.unpack('CCa6')
      case subtype
      when ROUTE_TARGET     ; Route_target.new(s)
      when ROUTE_ORIGIN     ; Route_origin.new(s)
      when OSPF_DOMAIN_ID   ; Ospf_domain_id.new(s)
      when OSPF_ROUTER_ID   ; Ospf_router_id.new(s)
      when BGP_DATA_COLLECT ; Bgp_data_collect.new(s)
      when LINK_BANDWIDTH   ; Link_bandwidth.new(s)
      when COLOR            ; Color.new(s)
      when BGP_ORIGIN_VALIDATION_STATE ; Origin_validation_state.new(s)
      # when ENCAPSULATION    ; Encapsulation.new(s)
      else
        puts "too bad type #{type.to_s(16)}, subtype #{subtype.to_s(16)} : #{s.unpack('H*')}"
        raise
        Extended_community.new(s)
      end
    end

    def initialize(*args)
      @type=TWO_OCTET_AS
      if args.size==1 and args[0].is_a?(String) and args[0].is_packed?
        parse(args[0])
      elsif args.size==3
        @type, @subtype, value = args
        raise ArgumentError, "invalid argument #{args.inspect}"  unless is_a?(Opaque)
        @type |= OPAQUE
        @global, @local=value, nil
        
      elsif args.size==4
        raise  ArgumentError, "This is a base class and should not be instanciated"  if instance_of?(Extended_community)
        @type, @subtype, @global, @local = args
        if @global.is_a?(String) and @local.is_a?(Integer)
          @type |= IPV4_ADDR
          @global = IPAddr.new(@global).to_i
        end
      elsif args.size==1 and args[0].is_a?(Integer)
        parse([s].pack('H*'))
      elsif args.empty?
        @type, @subtype, @global, @local = 0,0,0,0
      else
        raise ArgumentError, "invalid arg #{args.inspect}"
      end
    end
  end

  class Route_target < Extended_community
    def initialize(*args)
      if args[0].is_a?(String) and args[0].is_packed?
        super(*args)
      else
        super(*[0, ROUTE_TARGET, *args].flatten)
      end
    end
  end

  class Route_origin < Extended_community
    def initialize(*args)
      if args[0].is_a?(String) and args[0].is_packed?
        super(*args)
      else
        super(*[0,ROUTE_ORIGIN,*args].flatten)
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
    def value2
      "#{IPAddr.create(@global)}"
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
    def value2
      "#{IPAddr.create(@global)}"
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
        super(*args)
      end
    end
  end
  
  class Link_bandwidth < Extended_community
    def initialize(*args)
      if args[0].is_a?(String) and args[0].is_packed?
        super(*args)
      else
        args += [0]
        super(NON_TRANSITIVE | TWO_OCTET_AS, LINK_BANDWIDTH, *args)
      end
    end
    def value2
      @global
    end
  end

  class Color < Opaque
    def initialize(*args)
      args = 0 if args.empty?
      if args[0].is_a?(String) and args[0].is_packed?
        super(*args)
      else        
        super(TRANSITIVE, COLOR, *args)
      end
    end
    def value2
      @global
    end
  end

  class Origin_validation_state < Opaque
    def initialize(*args)
      args = 0 if args.empty?
      if args[0].is_a?(String) and args[0].is_packed?
        super(*args)
      else
        raise  ArgumentError, "Too many arguments." if args.length>1
        value = 0
        case args[0]
        when :valid
          value=0
        when :not_found
          value=1
        when :invalid
          value=2
        else
          value=args[0]
        end
        super(NON_TRANSITIVE, BGP_ORIGIN_VALIDATION_STATE, value)
      end
    end
    def validation_state
      case value2
      when 0; :valid
      when 1; :not_found
      when 2; :invalid
      else
        raise RuntimeError("bogus validation state")
      end
    end
    def value2
      @global
    end

  end
  
  # class Encapsulation < Opaque
  #   def initialize(*args)
  #     args = 0 if args.empty?
  #     if args[0].is_a?(String) and args[0].is_packed?
  #       super(*args)
  #     else        
  #       case args[0]
  #       when :l2tpv3 ; tunnel_type = 1
  #       when :gre    ; tunnel_type = 2
  #       when :ipip   ; tunnel_type = 7
  #       else
  #         tunnel_type = *args
  #       end
  #       super(TRANSITIVE, ENCAPSULATION, tunnel_type)
  #     end
  #   end
  #   def value2
  #     case @global
  #     when 1 ; :l2tpv3
  #     when 2 ; :gre
  #     when 7 ; :ipip
  #     else 
  #       @global
  #     end
  #   end
  # end  
  
end



__END__


load "../../test/unit/path_attributes/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
