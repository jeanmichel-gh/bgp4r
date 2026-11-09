#--
# Copyright 2008, 2009, 2026 Jean-Michel Esnault.
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

    # Families named by one word, because both registries give the AFI
    # and the SAFI the same name. RFC 9552 section 5.2: "All non-VPN
    # link, node, and prefix information SHALL be encoded using AFI 16388
    # / SAFI 71. VPN link, node, and prefix information SHALL be encoded
    # using AFI 16388 / SAFI 72." The split on `_` below reads `bgp_ls`
    # as AFI `bgp` and SAFI `ls`, which name nothing, and
    # `Mbgp.new(:bgp_ls)` read it as an AFI with no SAFI. This table is
    # what makes `{mbgp: bgp_ls}` in a node file mean 16388/71.
    FAMILIES = {
      :bgp_ls     => [IANA::AFI::BGP_LS, IANA::SAFI::BGP_LS],
      :bgp_ls_vpn => [IANA::AFI::BGP_LS, IANA::SAFI::BGP_LS_VPN],
    }.freeze

    # The [afi, safi] of a one-word family name, or nil.
    def self.family(name)
      return nil unless name.is_a?(Symbol) or (name.is_a?(String) and !name.is_packed?)
      FAMILIES[name.to_sym]
    end

    class << self
      def method_missing(name, *args, &block)
        return new(*FAMILIES[name]) if FAMILIES.has_key?(name)
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

    # Three ways: an AFI and SAFI, a hash, or wire bytes. The hash path
    # was missing, so a Hash reached IANA.afi and raised TypeError. It
    # takes the hash to_hash produces, {:code=>1,
    # :capability=>{:afi=>1, :safi=>1}}, and the bare inner hash too.
    def initialize(afi,safi=nil)
      if safi.nil? and afi.is_a?(String) and afi.is_packed?
        parse(afi)
      elsif safi.nil? and Mbgp.family(afi)
        super(OPT_PARM::CAP_MBGP)
        self.afi, self.safi = Mbgp.family(afi)
      elsif safi.nil? and afi.is_a?(Hash)
        super(OPT_PARM::CAP_MBGP)
        h = afi[:capability] || afi
        self.safi, self.afi = h[:safi], h[:afi]
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
    
    def encode(extended: false)
      super([@afi,0,@safi].pack('nCC'), :extended => extended)
    end

    def parse(s)
      @afi, _, @safi = super(s).unpack('nCC')
    end

    def to_s
      super + "\n    Multiprotocol Extensions (#{CAP_MBGP}), length: 4" +
      "\n      AFI #{IANA.afi_s(@afi)}, SAFI #{IANA.safi_s(@safi)}"
    end
    
    def to_s_brief
      "MBGP #{IANA.afi_name(@afi)}, #{IANA.safi_name(@safi)}"
    end

    def to_hash
      super({:afi => @afi, :safi => @safi, })
    end
  end
end

load "../../test/unit/optional_parameters/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
