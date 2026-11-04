#--
# Copyright 2026 Jean-Michel Esnault.
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

require 'bgp/gen/labelled'
require 'bgp/gen/per_vrf'

module BGP
  class Gen
    # Labeled VPN routes, SAFI 128 (RFC 4364 for IPv4, RFC 4659 for
    # IPv6): labelled unicast with a Route Distinguisher in front of each
    # prefix, RFC 4364 section 4.3.4 and RFC 8277 section 2.
    #
    # **Every VRF carries the same prefixes**, `count` of them, so
    # `vrfs: N` sends N times `count` routes, VRF by VRF. The RD, the
    # route target and how they step are bgp/gen/per_vrf.rb, which VPN
    # flow spec shares.
    #
    # The label runs on the route number across all the VRFs, as
    # `path_id` does, since it is part of the NLRI. A withdrawal names
    # the RD and the prefix and carries the Compatibility field, which
    # RFC 8277 section 2.4 asks for in any "SAFI-x UPDATE", so SAFI 128
    # as much as SAFI 4.
    #
    # **An IPv4 next hop under AFI 2 goes out IPv4-mapped**, RFC 4659
    # section 3.2.1.2: a VPN-IPv6 address with an RD of zero whose
    # address is the mapped one, 24 octets. `Mp_reach` maps it for SAFI
    # 1, 2 and 4 and not for SAFI 128, where it writes 12 octets as
    # handed an IPv4 address, so the mapping is done here. `expected`
    # keeps the address as given, as phase 3's plan does for unicast.
    class Vpn < Labelled
      include PerVrf

      SAFI = IANA::SAFI::MPLS_VPN_UNICAST

      def initialize(spec, sender = nil)
        read_vrfs(spec, family_name)
        super
      end

      def route(i) ; [prefix(i), path_id(i), label(i), rd(vrf(i))] ; end

      # Eight more octets than labelled, the RD, RFC 4364 section 4.3.4.
      def route_octets ; super + 8 ; end

      private

      def family_name ; 'vpn' ; end

      def mp_nlris(batch)
        batch.collect do |p, id, l, rd|
          h = { :prefix => p, :label => l, :rd => rd }
          h[:path_id] = id if id
          h
        end
      end

      def mp_withdrawn_nlris(batch)
        batch.collect do |p, id, _l, rd|
          h = { :prefix => p, :rd => rd, :compatibility => COMPATIBILITY }
          h[:path_id] = id if id
          h
        end
      end

      def wire_next_hop(nh)
        return nh unless @afi == IANA::AFI::IPv6 && IPAddr.new(nh).ipv4?
        "::ffff:#{nh}"
      end
    end

    # The same NLRI under SAFI 129, Labeled VPN Multicast, which RFC 6513
    # and RFC 6514 use for multicast reverse path routes. The encoding is
    # SAFI 128's, which is why bgp4r reads and writes the two in one arm.
    class Vpn_multicast < Vpn
      SAFI = IANA::SAFI::MPLS_VPN_Multicast

      private

      def family_name ; 'vpn_multicast' ; end
    end
  end
end
