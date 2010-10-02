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

  class Prefix < Nlri::Nlri_element
    def initialize(*args)
      if args[0].is_a?(String) and args[0].packed?
        afi = args[1] ||=1
        case afi
        when :ip4,1 ; super(parse4(args[0]))
        when :ip6,2 ; super(parse6(args[0]))
        end
      elsif args[0].is_a?(Nlri::Ip4) or args[0].is_a?(Nlri::Ip6) or args[0].is_a?(Prefix)
        super(args[0].to_s)
      else
        super(*args)
      end
    end
    def afi
      if ipv4?
        IANA::AFI::IP
      elsif ipv6?
        IANA::AFI::IP6
      end
    end
    alias bit_length mlen
    
    def nexthop
      to_s.split('/')[0]
    end
    
  end

  class Inet_unicast < Prefix
    def safi
      IANA::SAFI::UNICAST_NLRI
    end
  end

  class Inet_multicast < Prefix
    def safi
      IANA::SAFI::MULTICAST_NLRI
    end
  end

end

require 'bgp/rd'

module BGP
  class Vpn
    attr_reader :prefix, :rd
    def initialize(*args)
      if args.size>0 and args[0].is_a?(String) and args[0].is_packed?
        parse(*args)
      else
        prefix, *rd = args
        self.prefix=(prefix)
        self.rd=rd
      end      
    end
    def prefix=(arg)
      if arg.is_a?(Prefix)
        @prefix=arg
      else
        @prefix=Prefix.new(arg)
      end
    end
    def rd=(args)
      args.flatten!
      if args.empty?
        @rd=Rd.new
      elsif args.size==1 and args[0].is_a?(BGP::Rd)
        @rd=args[0]
      else
        @rd=Rd.new(*args)
      end
    end
    # len_included arg is used by labeled encode()
    def encode_next_hop
      Rd.new.encode + @prefix.encode(false)
    end
    def encode(len_included=true)
      if len_included
        [bit_length, @rd.encode, @prefix.encode(false)].pack('Ca*a*')
      else
        @rd.encode + @prefix.encode(false)
      end
    end
    def bit_length
      @rd.bit_length + @prefix.mlen
    end
    def ipv4?
      @prefix.ipv4?
    end
    def afi
      @prefix.afi
    end  
    def ipv6?
      @prefix.ipv6?
    end
    def parse(s, afi=1)
      nbits = s.slice!(0,1).unpack('C')[0]
      rd,vpn = s.slice!(0,(7+nbits)/8).unpack("a8a*")
      @rd = Rd.new(rd.is_packed)
      @prefix= Prefix.new([nbits-64,vpn].pack('Ca*'), afi)
    end
    def nexthop
      @prefix.nexthop
    end
    def to_s
       #Label Stack=5806 (bottom) RD=3215:317720610, IPv4=10.45.142.64/32
      "#{@rd.to_s(false)}, #{@prefix.ipv4? ? 'IPv4' : 'IPv6'}=#{@prefix.to_s}"
    end
  end
end

require 'bgp/nlris/label'
module BGP
  class Labeled
    def initialize(*args)
      if args.size>0 and args[0].is_a?(String) and args[0].is_packed?
        parse(*args)
      else
        @prefix, *labels = args
        @labels = Label_stack.new(*labels)
      end
    end
    def bit_length
      @labels.bit_length+@prefix.bit_length
    end
    def encode
      [bit_length, @labels.encode, @prefix.encode(false)].pack('Ca*a*')
    end
    def to_s
      "#{@labels} #{@prefix}"
    end
    def afi
      @prefix.afi
    end  
    def parse(s, afi=1, safi=1)
      bitlen = s.slice!(0,1).unpack('C')[0]
      @labels = Label_stack.new(s)
      mlen = bitlen - (24*@labels.size)
      prefix = [mlen,s.slice!(0,(mlen+7)/8)].pack("Ca*")
      case safi
      when 128,129
        @prefix = Vpn.new(prefix)
      else
        @prefix = Prefix.new(prefix, afi)
      end
    end
  end
end

load "../test/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
