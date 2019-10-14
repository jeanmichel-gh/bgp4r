#--
# Copyright 2008-2009, 2011 Jean-Michel Esnault.
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

# 
# http://www.iana.org/assignments/address-family-numbers/
# 
module IANA
  def self.afi?(arg)
    afis[arg]
  end
  def self.afi(arg)
    arg.is_a?(Integer) ? arg : afis[arg]
  end
  def self.safi(arg)
    arg.is_a?(Integer) ? arg : safis[arg]
  end
  def self.safis
    @h_safis ||= SAFI.set_h_safis
  end
  def self.afis
    @h_afis ||= AFI.set_h_afis
  end
  def self.safi?(arg)
    case arg
    when SAFI::UNICAST            ; 'Unicast'
    when SAFI::MULTICAST          ; 'Multicast'
    when SAFI::LABEL_NLRI         ; 'Labeled NLRI'
    when SAFI::MCAST_VPN          ; 'Multicast VPN'
    when SAFI::MPLS_VPN_UNICAST   ; 'Labeled VPN Unicast'
    when SAFI::MPLS_VPN_Multicast ; 'Labeled VPN Multicast'
    else
      safis[arg]
    end
  end
  module AFI
    IPv4 = 1
    IPv6 = 2
    NSAP = 3
    HDLC = 4
    BBN = 5
    IEEE_802 = 6
    E163 = 7
    E164 = 8
    F69 = 9
    X121 = 10
    IPX = 11
    Appletalk = 12
    Decnet_IV = 13
    Banyan_Vines = 14
    E164_NSAP = 15
    DNS = 16
    Distinguished_Name = 17
    AS_Number = 18
    XTPv4 = 19
    XTPv6 = 20
    XTP = 21
    FCWWPN = 22
    FCWWNN = 23
    GWID = 24
    L2VPN = 25
    def self.set_h_afis
      h_afis = Hash.new
      constants.each do |c|
        h_afis.store(c.to_s.downcase.to_sym, const_get(c))
        h_afis.store(const_get(c), c.to_s.split('_').collect { |w| w }.join(' '))
      end
      h_afis
    end
  end
  module SAFI
    def self.set_h_safis
      h_safis = Hash.new
      constants.each do |c|
        h_safis.store(c.to_s.downcase.to_sym, const_get(c))
        h_safis.store(const_get(c), c.to_s.split('_').collect { |w| w }.join(' '))
      end
      h_safis
    end
    UNICAST = 1
    MULTICAST = 2
    LABEL_NLRI = 4
    MCAST_VPN = 5
    MULTI_SEGMENT_PW_NLRI = 6
    ENCASPSULATION_SAFI = 7
    TUNNEL = 64
    VPLS = 65
    BGP_MDT = 66
    BGP4over6 = 67
    BGP6over4 = 68
    L1_VPN_AUTO_DISCOVERY = 69
    MPLS_VPN_UNICAST = 128
    MPLS_VPN_Multicast = 129
    ROUTE_TARGET_CONSTRAINTS = 132
    FLOW_SPEC_RULES_1 = 133
    FLOW_SPEC_RULES_2 = 134
    VPN_AUTO_DISCOVERY = 140
  end
end
