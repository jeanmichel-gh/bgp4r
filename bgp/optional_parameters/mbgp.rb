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

require 'bgp/optional_parameters/capability'

module BGP::OPT_PARM::CAP
  
  class Mbgp < BGP::OPT_PARM::Capability 

    def self.ipv4_unicast
      Mbgp.new(1,1)
    end

    def self.ipv4_multicast
      Mbgp.new(1,2)
    end

    def self.ipv6_unicast
      Mbgp.new(2,2)
    end

    def self.ipv6_multicast
      Mbgp.new(2,2)
    end

    def initialize(afi,safi=nil)
      if safi.nil? and afi.is_a?(String) and afi.is_packed?
        parse(afi)
      else
        super(OPT_PARM::CAP_MBGP)
        self.safi, self.afi = safi, afi
      end
    end

    def afi=(val)
      @afi = if val.is_a?(Fixnum)
        val
      elsif val == :ipv4
        1
      elsif val == :ipv6
        2
      end
    end

    def safi=(val)
      @safi = if val.is_a?(Fixnum)
        val
      elsif val == :unicast
        1
      elsif val == :multicast
        2
      end
    end

    def encode
      super([@afi,0,@safi].pack('nCC'))
    end

    def parse(s)
      @afi, ignore, @safi = super(s).unpack('nCC')
    end

    def to_s
      super + "\n    Multiprotocol Extensions (#{CAP_MBGP}), length: 4" +
      "\n      AFI #{IANA.afi?(@afi)} (#{@afi}), SAFI #{IANA.safi?(@safi)} (#{@safi})"
    end
    
    def to_s_brief
      "MBGP #{IANA.afi?(@afi)}, #{IANA.safi?(@safi)}"
    end

    def to_hash
      super({:afi => @afi, :safi => @safi, })
    end
  end
end

load "../../test/unit/optional_parameters/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
