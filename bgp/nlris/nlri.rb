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
require 'bgp/iana'

module BGP

  class Base_nlri

    class Nlri_element < IPAddr
      def to_s
        [super, mlen].join('/')
      end
      def encode_next_hop
        hton
      end
      def nbyte
         (mlen+7)/8
      end
      def encode(len_included=true)
        nbyte = (mlen+7)/8
        if len_included
          [mlen, hton].pack("Ca#{nbyte}")
        else
          [hton].pack("a#{nbyte}")
        end
      end
      def parse4(arg)
        s = arg.dup
        s +=([0]*3).pack('C*')
        plen, *nlri = s.unpack('CC4')
        arg.slice!(0,1+(plen+7)/8) # trim arg accordingly
        ipaddr = nlri.collect { |n| n.to_s }.join('.') + "/" + plen .to_s
      end
      def parse6(arg)
        s = arg.dup
        s +=([0]*16).pack('C*')
        plen, *nlri = s.unpack('Cn8')
        arg.slice!(0,1+(plen+7)/8) # trim arg accordingly
        ipaddr = nlri.collect { |n| n.to_s(16) }.join(':') + "/" + plen .to_s
      end
    end

    class Ip4 < Nlri_element
      def initialize(arg)
        if arg.is_a?(String) and arg.packed?
          super(parse4(arg))
        elsif arg.is_a?(Ip4)
          super(arg.to_s)
        else
          super(arg)
        end
      end
    end

    class Ip6 < Nlri_element
      def initialize(arg)
        if arg.is_a?(String) and arg.packed?
          super(parse6(arg))
        elsif arg.is_a?(Ip6)
          super(arg.to_s)
        else
          super(arg)
        end
      end
    end

    attr_reader :nlris

    def initialize(*args)
      if args[0].is_a?(String) and args[0].is_packed?
        parse(args[0])
      else
        add(*args)
      end
    end
    def add(*args)
      @nlris ||=[]
      args.flatten.each { |arg| @nlris << Ip4.new(arg) }
    end
    alias << add

    def parse(s)
      @nlris ||=[]
      while s.size>0
        add(s)
      end
    end

    def encode(len_included=false)
      enc = @nlris.collect { |x| x.encode }.join
      if len_included
        [enc.size].pack('n') + enc
      else
        enc
      end
    end

    def to_s
      @nlris.join("\n")
    end
    
    def size
      @nlris.size
    end

  end

  class Nlri < Base_nlri
    def encode
      super
    end
  end
  class Withdrawn < Base_nlri
    def encode(len_included=true)
      super(len_included)
    end
  end

  class Nlri
    def self.factory(s, afi, safi)
      case safi
      when 1,2
        Prefix.new(s.is_packed, afi)
      when 4,128,129
        Labeled.new(s.is_packed, afi, safi)
      end
    end
  end

end

load "../../test/nlris/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
