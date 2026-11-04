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

module BGP
  class Gen
    # Labeled VPN routes, SAFI 128 (RFC 4364 for IPv4, RFC 4659 for
    # IPv6): labelled unicast with a Route Distinguisher in front of each
    # prefix, RFC 4364 section 4.3.4 and RFC 8277 section 2.
    #
    # **Every VRF carries the same prefixes**, `count` of them, because
    # overlapping address space is what an RD is for (RFC 4364 section
    # 4.1). So `vrfs: N` sends N times `count` routes, VRF by VRF, and
    # the i-th VRF's RD is `rd` with i added to its assigned number. A
    # route target, when given, steps the same way and joins that VRF's
    # extended communities, so **each VRF is an attribute set of its
    # own** and a message never mixes two VRFs that have one.
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
      SAFI = IANA::SAFI::MPLS_VPN_UNICAST

      def initialize(spec, sender = nil)
        unless spec['rd']
          raise SpecError, "a #{family_name} spec needs an rd, ADMIN:N, stepped once per VRF (RFC 4364 section 4.2)"
        end
        @vrfs = spec['vrfs'] || 1
        @rd = Spec.distinguisher(spec['rd'], 'rd')
        @rt = spec['route_target'] && Spec.distinguisher(spec['route_target'], 'route_target')
        super
      end

      attr_reader :vrfs

      def total ; @count * @vrfs ; end

      # Which VRF route i is in, from 0.
      def vrf(i) ; i / @count ; end

      # The same range in every VRF.
      def prefix(i) ; super(i % @count) ; end

      # VRF v's RD, as the [admin, assigned] pair Rd.new takes.
      def rd(v) ; @rd.at(v) ; end

      def route(i) ; [prefix(i), path_id(i), label(i), rd(vrf(i))] ; end

      def route_row(i) ; super.merge('rd' => @rd.text(vrf(i))) ; end

      # Eight more octets than labelled, the RD, RFC 4364 section 4.3.4.
      def route_octets ; super + 8 ; end

      def set_key(i) ; [i / @group, vrf(i)] ; end

      def row_at(key)
        g, v = key
        r = row(g)
        return r unless @rt
        r = r.dup
        r['extended_communities'] = Array(r['extended_communities']) + ["route_target:#{@rt.text(v)}"]
        r
      end

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
