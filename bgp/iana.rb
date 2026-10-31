#--
# Copyright 2008-2009, 2011, 2026 Jean-Michel Esnault.
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
  # For display, where afi? and safi? answer nil. An AFI or a SAFI the
  # registries below do not name used to print as nothing at all, so
  # "AFI 999, SAFI 77" came out "AFI  (999), SAFI  (77)" and the brief
  # form of the Multiprotocol capability came out "MBGP , ". Building is
  # never validated, so any AFI and any SAFI can be sent, which makes an
  # unnamed one ordinary rather than a corner case: IANA has over 16000
  # AFI code points unassigned and bgp4r names 25.
  #
  # afi_name and safi_name give the name there is, or the number itself,
  # which is the brief form. afi_s and safi_s add the number in
  # parentheses, which is the long form every capability and message
  # prints, and leave the parentheses out where the name would be the
  # number again. Every named family prints exactly as it did.
  def self.afi_name(arg)
    afi?(arg) || arg
  end
  def self.safi_name(arg)
    safi?(arg) || arg
  end
  def self.afi_s(arg)
    name_with_number(afi?(arg), arg)
  end
  def self.safi_s(arg)
    name_with_number(safi?(arg), arg)
  end
  def self.name_with_number(name, number)
    name ? "#{name} (#{number})" : number.to_s
  end
  private_class_method :name_with_number

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
    # IANA calls SAFI 7 "Encapsulation SAFI (OBSOLETE)", referencing
    # RFC 9012, which obsoleted RFC 5512 and with it the Encapsulation
    # SAFI. ENCASPSULATION_SAFI is a typo kept for callers that already
    # name it; ENCAPSULATION_SAFI is the spelling to use. Both are 7, and
    # set_h_safis stores a symbol for each, so IANA.safi?(:encapsulation_safi)
    # and the old :encaspsulation_safi both answer 7. Defining the correct
    # spelling second makes it the name IANA.safi?(7) prints.
    ENCASPSULATION_SAFI = 7
    ENCAPSULATION_SAFI = 7
    TUNNEL = 64
    VPLS = 65
    BGP_MDT = 66
    BGP4over6 = 67
    BGP6over4 = 68
    L1_VPN_AUTO_DISCOVERY = 69
    # RFC 7432 section 11: "IANA has assigned BGP EVPNs a SAFI value of
    # 70." Carried with AFI 25, L2VPN, which section 7 names in the same
    # breath: "an AFI of 25 (L2VPN) and a SAFI of 70 (EVPN)".
    EVPN = 70
    MPLS_VPN_UNICAST = 128
    MPLS_VPN_Multicast = 129
    ROUTE_TARGET_CONSTRAINTS = 132
    FLOW_SPEC_RULES_1 = 133
    FLOW_SPEC_RULES_2 = 134
    VPN_AUTO_DISCOVERY = 140
  end
end
