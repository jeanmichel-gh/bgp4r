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


module IANA
    def self.afi?(arg)
    @h_afis ||= AFI.set_h_afis
    @h_afis[arg]
  end
  def self.safi?(arg)
    @h_safis ||= SAFI.set_h_safis
    @h_safis[arg]
  end
  def self.safi(safi)
    case safi
    when SAFI::UNICAST_NLRI       ; 'Unicast'
    when SAFI::MULTICAST_NLRI     ; 'Multicast'
    when SAFI::LABEL_NLRI         ; 'Labeled NLRI'
    when SAFI::MCAST_VPN          ; 'Multicast VPN'
    when SAFI::MPLS_VPN_UNICAST   ; 'Labeled VPN Unicast'
    when SAFI::MPLS_VPN_Multicast ; 'Labeled VPN Multicast'
    else
      ''
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
        h_afis.store(c.downcase.to_sym, const_get(c))
        h_afis.store(const_get(c), c.split('_').collect { |w| w }.join(' '))
        # h_afis.store(const_get(c), c.downcase.to_sym)
      end
      h_afis
    end
  end
  module SAFI
    def self.set_h_safis
      h_safis = Hash.new
      constants.each do |c|
        h_safis.store(c.downcase.to_sym, const_get(c))
        h_safis.store(const_get(c), c.split('_').collect { |w| w }.join(' '))
      end
      h_safis
    end
    UNICAST_NLRI = 1
    MULTICAST_NLRI = 2
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

__END__

http://www.iana.org/assignments/address-family-numbers/



Registry:
Number       Description                                                       Reference
----------   ----------------------------------------------------------------  -----------------
0            Reserved
1            IP (IP version 4)
2            IP6 (IP version 6)
3            NSAP
4            HDLC (8-bit multidrop)
5            BBN 1822
6            802 (includes all 802 media plus Ethernet "canonical format")
7            E.163
8            E.164 (SMDS, Frame Relay, ATM)
9            F.69 (Telex)
10           X.121 (X.25, Frame Relay)
11           IPX
12           Appletalk
13           Decnet IV
14           Banyan Vines
15           E.164 with NSAP format subaddress                                 [UNI-3.1][Malis]
16           DNS (Domain Name System)
17           Distinguished Name                                                [Lynn]
18           AS Number                                                         [Lynn]
19           XTP over IP version 4                                             [Saul] 
20           XTP over IP version 6                                             [Saul]
21           XTP native mode XTP                                               [Saul]
22           Fibre Channel World-Wide Port Name                                [Bakke]
23           Fibre Channel World-Wide Node Name                                [Bakke]
24           GWID                                                              [Hegde]
25           AFI for L2VPN information                                         [RFC4761]
26-16383     Unassigned
16384        EIGRP Common Service Family                                       [Savage]
16385        EIGRP IPv4 Service Family                                         [Savage]
16386        EIGRP IPv6 Service Family                                         [Savage]
16387-32767  Unassigned
32768-65534  Unassigned
65535        Reserved


http://www.iana.org/assignments/safi-namespace


Registries included below
- SAFI Values


Registry Name: SAFI Values
Reference: [RFC4760]
Range      Registration Procedures                              Note
---------  ---------------------------------------------------  --------------------
1-63       Standards Action or Early Allocation policy
64-127     First Come First Served
128-240    Some recognized assignments below, others Reserved 
241-254    Reserved for Private Use                             Not to be assigned

Registry:
Value    Description                                     Reference
-------  ----------------------------------------------  ---------
0        Reserved                                        [RFC4760]

1        Network Layer Reachability Information used     [RFC4760]
         for unicast forwarding	

2        Network Layer Reachability Information used     [RFC4760] 
         for multicast forwarding
	
3        Reserved                                        [RFC4760]

4        Network Layer Reachability Information (NLRI)   [RFC3107]
         with MPLS Labels

5        MCAST-VPN                                       [draft-ietf-l3vpn-2547bis-mcast-bgp]
         (TEMPORARY - Expires 2009-06-19)

6        Network Layer Reachability Information used     [draft-ietf-pwe3-dynamic-ms-pw]
         for Dynamic Placement of Multi-Segment
         Pseudowires
         (TEMPORARY - Expires 2009-08-23)

7        Encapsulation SAFI                              [RFC-ietf-softwire-encaps-safi-05.txt]

8-63     Unassigned

64       Tunnel SAFI                                     [Nalawade]

65       Virtual Private LAN Service (VPLS)              [RFC4761]

66       BGP MDT SAFI                                    [Nalawade]

67       BGP 4over6 SAFI                                 [Cui]

68       BGP 6over4 SAFI                                 [Cui]

69       Layer-1 VPN auto-discovery information          [RFC-ietf-l1vpn-bgp-auto-discovery-05.txt]

70-127   Unassigned 

128      MPLS-labeled VPN address                        [RFC4364]

129      Multicast for BGP/MPLS IP Virtual Private       [RFC2547]
         Networks (VPNs)

130-131  Reserved                                        [RFC4760]

132      Route Target constrains                         [RFC4684]

133      Dissemination of flow specification rules       [draft-marques-idr-flow-spec]

134      Dissemination of flow specification rules       [draft-marques-idr-flow-spec]

135-139  Reserved                                        [RFC4760]

140      VPN auto-discovery                              [draft-ietf-l3vpn-bgpvpn-auto]

141-240  Reserved                                        [RFC4760]

241-254  Private Use                                     [RFC4760]

255      Reserved                                        [RFC4760]


References
----------
[RFC2547]  E. Rosen and Y. Rekhter, "BGP/MPLS VPNs", RFC 2547, March 1999.

[RFC3107]  Y. Rekhter and E. Rosen, "Carrying Label Information in 
           BGP-4", RFC 3107, May 2001.

[RFC4364]  E. Rosen and Y. Rekhter, "BGP/MPLS IP VPNs", RFC 4364, February 2006.

[RFC4684]  P. Marques, R. Bonica, L. Fang, L. Martini, R. Raszuk, K. Patel
           and J. Guichard, "Constrained VPN Route Distribution", RFC 4684,
           November 2006.

[RFC4760]  T. Bates, R. Chandra, D. Katz and Y. Rekhter, "Multiprotocol 
           Extensions for BGP-4", RFC 4760, January 2007.

[RFC4761]  K. Kompella and Y. Rekhter, "Virtual Private LAN Service 
           (VPLS) Using BGP for Auto-discovery and Signaling", RFC 4761,
           January 2007.

[RFC-ietf-l1vpn-bgp-auto-discovery-05.txt] 
           H. Brahim, D. Fedyk, Y. Rekhter, "BGP-based Auto-Discovery for 
           Layer-1 VPNs", RFC XXXX, Month Year.
           
[draft-ietf-l3vpn-bgpvpn-auto]  Work in progress

[draft-ietf-pwe3-dynamic-ms-pw] Work in progress

[draft-marques-idr-flow-spec]   Work in progress

[draft-ietf-l3vpn-2547bis-mcast-bgp] Work in progress

[RFC-ietf-softwire-encaps-safi-05.txt]
           P. Mohapatra, E. Rosen, "BGP Encapsulation SAFI and BGP Tunnel 
           Encapsulation Attribute", RFC XXXX, Month Year.

People
------
[Bates] Tony Bates, <tbates&cisco.com>, July 2000. 

[Cui]  Yong Cui, <cuiyong&tsinghua.edu.cn>, 15 August 2006, 20 September 2006.

[Nalawade]  Gargi Nalawade, <gargi&cisco.com>, January 2004. 
           (draft-nalawade-kapoor-tunnel-safi-01.txt)  
           (draft-nalawade-idr-mdt-safi-00.txt), February 2004.

(created 2000-07)

[] 

