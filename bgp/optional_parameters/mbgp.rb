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
    
    class << self
      def method_missing(name, *args, &block)
        afi, *safi = name.to_s.split('_')
        _afi  = IANA.afi?(afi.to_sym)
        _safi = IANA.safi?((safi.join('_')).to_sym)
        if _afi and _safi
          new _afi,_safi
        else
          super
        end
      end
    end

    def initialize(afi,safi=nil)
      if safi.nil? and afi.is_a?(String) and afi.is_packed?
        parse(afi)
      else
        super(OPT_PARM::CAP_MBGP)
        self.safi, self.afi = safi, afi
      end
    end
    
    def afi=(arg)
      @afi = IANA.afi(arg)
    end
    def safi=(arg)
      @safi = IANA.safi(arg)
    end
    
    attr_reader :afi, :safi
    
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
