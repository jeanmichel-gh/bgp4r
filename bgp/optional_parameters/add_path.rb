#--
# Copyright 2010, 2026 Jean-Michel Esnault.
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

require 'bgp/optional_parameters/capability'

module BGP::OPT_PARM::CAP

  class Add_path < BGP::OPT_PARM::Capability 

    class << self
      def new_array(arg)
        o = new
        arg.each { |t| o.add(*t) }
        o
      end
    end
    
    def initialize(*args)
      @af={}
      if args.size>1
        super(OPT_PARM::CAP_ADD_PATH)
        add(*args)
      elsif args.size==1 and args[0].is_a?(String)
        parse(*args)
      elsif args.empty?
        super(OPT_PARM::CAP_ADD_PATH)
      else
        raise
      end
    end
    
    # sr is what *we* can do for this family: :recv, :send or
    # :send_and_recv. The symbols say what the sender of the capability can
    # do, which is how RFC 7911 section 4 defines the field, and _send_recv
    # turns them into the field's values.
    def add(sr, _afi,_safi)
      @af[[afi(_afi), safi(_safi)]] = _send_recv(sr)
    end

    def parse(s)
      families = super(s)
      while families.size>0
        afi, safi, sr = families.slice!(0,4).unpack('nCC')
        @af[[afi,safi]]=sr
      end
    end
    
    # 0001 01 01   IPv4 unicast, the sender can receive multiple paths
    # 0002 80 02   VPN IPv6, the sender can send multiple paths
    # 0002 01 03   IPv6 unicast, the sender can do both

    # Can the sender of this capability send multiple paths for the family?
    def send? afi, safi
      has? :send, afi, safi
    end

    # Can the sender of this capability receive multiple paths for it?
    def recv? afi, safi
      has? :recv, afi, safi
    end

    # RFC 7911 section 4: the Send/Receive field says whether the sender of
    # the capability is "able to receive multiple paths from its peer (value
    # 1)", "able to send multiple paths to its peer (value 2), or (c) both
    # (value 3)". So 1 and 3 answer recv?, and 2 and 3 answer send?.
    #
    # Any other value is simply not this capability: section 4 says the
    # receiver SHOULD treat it as not understood and ignore it, so both
    # questions answer false and nothing refuses to build or encode it.
    def has?(sr, afi, safi)
      case sr
      when :recv, :receive
        @af.has_key?([afi,safi]) && (@af[[afi,safi]] == 1 or @af[[afi,safi]] == 3)
      when :send
        @af.has_key?([afi,safi]) && (2..3) === @af[[afi,safi]]
      end
    end

    def encode
      s = []
      s << @af.to_a.sort.collect { |e|  e.flatten.pack('nCC')  }
      super s.join
    end

    def to_s
      s = []
      s <<  "\n    Add-path Extension (#{CAP_ADD_PATH}), length: #{encode.size}"
      s = s.join("\n  ")
      super + (s + (['']+@af.to_a.collect { |e| address_family_to_s(*e)}).join("\n        "))
    end

    # Which address families, and which direction. That is what a peer
    # acts on, and the capability's name alone does not say it.
    def to_s_brief
      families = @af.to_a.sort.collect { |af, sr|
        afi, safi = af
        "#{IANA.afi?(afi) || afi}, #{IANA.safi?(safi) || safi} #{send_recv_to_s(sr)}"
      }
      families.empty? ? 'Add-path' : "Add-path #{families.join('; ')}"
    end

    private

    def address_family_to_s(af, sr)
      afi, safi = af
      "AFI #{IANA.afi?(afi)} (#{afi}), SAFI #{IANA.safi?(safi)} (#{safi}), #{send_recv_to_s(sr)}"
    end

    # RFC 7911 section 4: value 1 is "able to receive multiple paths from its
    # peer", value 2 is "able to send multiple paths to its peer", value 3 is
    # both. An Integer goes through untouched, so any value, 0 or 4 or 255,
    # still builds and encodes.
    def _send_recv(val)
      case val
      when :recv, :receive                                ; 1
      when :send                                          ; 2
      when :send_and_recv, :send_recv, :send_and_receive  ; 3
      else
        val
      end
    end

    def send_recv_to_s(val)
      case val
      when 1 ; 'RECV (1)'
      when 2 ; 'SEND (2)'
      when 3 ; 'SEND_AND_RECV (3)'
      else
        'bogus'
      end
    end
    
    def afi(arg)
      IANA.afi(arg)
    end
    def safi(arg)
      IANA.safi(arg)
    end
    
  end
end

load "../../test/unit/optional_parameters/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
