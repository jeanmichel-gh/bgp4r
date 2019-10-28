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

module BGP

  class Aggregator < Attr

    def initialize(*args)
      @flags, @type, @as4byte =OPTIONAL_TRANSITIVE, AGGREGATOR, false
      if args[0].is_a?(String) and args[0].is_packed?
        parse(*args)
      elsif args.size==2 and
        args[0].is_a?(String) and args[1].is_a?(Integer)
        @ip_address = IPAddr.create(args[0])
        self.asn = args[1]
      elsif args[0].is_a?(self.class)
        parse(args[0].encode, *args[1..-1])
      elsif args[0].is_a?(Hash)
        @ip_address = IPAddr.create(args[0][:address])
        self.asn = args[0][:asn]
      else
        raise ArgumentError, "invalid argument, #{args.inspect}"
      end
    end
    
    def asn=(arg)
      raise unless arg.is_a?(Integer)
      @as=arg
    end
    

    def address=(val)
      @ip_address=IPAddr.create(val)
    end

    def address
      @ip_address.to_s
    end
    
    def asn
      @as
    end

    def as(sep='')
      case sep
      when '.'
        has = @as >> 16
        las = @as & 0xffff
        [has,las].join('.')
      else
        @as
      end
    end
    
    def aggregator(as4byte=@as4byte)
      "#{address}, #{as(as4byte ? '.':'')}"
    end
    
    def to_s(method=:default)
      super(aggregator, method)
    end
    
    def parse(s,as4byte=false)
      @flags, @type, _, @as, addr = super(s, as4byte ? 'NN' : 'nN')
      self.address = addr
    end
    
    def encode(as4byte=@as4byte)
      f = as4byte ? 'N' : 'n'
      super([@as].pack(f) + @ip_address.hton)
    end
    
    def to_hash
      {:aggregator=> {:asn=> asn, :address=> address}}
    end
    
  end

  class As4_aggregator < Aggregator
    def initialize(*args)
      super(*args)
      @flags, @type, @as4byte =OPTIONAL_TRANSITIVE, AS4_AGGREGATOR, true
    end
    def parse(s,as4byte=@as4byte)
      super(s,true)
    end
    def encode(as4byte=@as4byte)
      f = as4byte ? 'N' : 'n'
      super([@as].pack(f) + @ip_address.hton)
    end

    def aggregator(as4byte=@as4byte)
      super(true)
    end

  end
  
  class Aggregator
    class << self
      def new_hash(arg={})
        new arg[:address], arg[:as]
      end
    end    
  end

end

load "../../test/unit/path_attributes/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0