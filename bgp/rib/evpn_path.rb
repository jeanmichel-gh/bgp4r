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

require 'bgp4r'
require 'bgp/rib/route'

module BGP
  module Rib

    # The path attributes and peer of one EVPN route, for the decision
    # process. An EVPN route has no IP prefix, so this keeps its key, as
    # text, where a Route keeps the prefix. Decision reads the attributes
    # and the peer, never the prefix. docs/design/evpn.md, decision 1.
    class EvpnPath < Route
      def initialize(key, path_attribute, peer, path_id: nil)
        raise ArgumentError, "peer must be a BGP::Rib::Peer, got #{peer.class}" unless peer.is_a?(Peer)
        @prefix = key.to_s.dup.freeze
        @path_attribute = path_attribute || Path_attribute.new
        @peer = peer
        @path_id = path_id.nil? ? nil : Integer(path_id)
        freeze
      end

      def ipv4? ; nil ; end
      def afi ; IANA::AFI::L2VPN ; end

      def with_path_attribute(path_attribute)
        EvpnPath.new(@prefix, path_attribute, @peer, path_id: @path_id)
      end
    end

    # One received EVPN route of type 2 or 3, the two docs/design/evpn.md
    # keeps (RFC 8365 section 7.1). nlri is the BGP::Evpn; route the
    # EvpnPath with its attributes and peer.
    #
    # EVPN_ENCAPS names the Encapsulation tunnel types RFC 8365 section 12
    # registers, as FRR and routescope print them.
    EVPN_ENCAPS = { 8 => 'VXLAN', 9 => 'NVGRE', 10 => 'MPLS', 11 => 'MPLS-in-GRE' }.freeze

    EvpnRoute = Struct.new(:nlri, :route) do

      # The route's key, RFC 7432 section 7.2 for type 2: "only the
      # Ethernet Tag ID, MAC Address Length, MAC Address, IP Address
      # Length, and IP Address fields are considered to be part of the
      # prefix"; section 7.3 for type 3: "only the Ethernet Tag ID, IP
      # Address Length, and Originating Router's IP Address fields". With
      # the RD, since the RD keeps routes of two MAC-VRFs apart, and the
      # Path Identifier.
      def self.key_of(nlri)
        r = nlri.route
        h = r.to_hash.values.first
        rd = Array(h[:rd]).join(':')
        case r
        when BGP::Evpn::Mac_ip_advertisement then [rd, 2, h[:ethernet_tag_id], r.mac.to_s.downcase, r.ip.address]
        when BGP::Evpn::Inclusive_multicast then [rd, 3, h[:ethernet_tag_id], r.ip.address]
        end
      end

      # Both are read for every route on each table decision and each
      # reflector refresh, and key_of builds the NLRI's whole hash, so
      # they are worked out once. Nothing sets nlri after it is built
      # (PeerAdapter.evpn_operations).
      def key ; @key ||= [*decision_key, path_id].freeze ; end
      def decision_key ; @decision_key ||= EvpnRoute.key_of(nlri).freeze ; end
      def rd ; decision_key[0] ; end
      def route_type ; decision_key[1] ; end
      def eth_tag ; decision_key[2] ; end
      def mac ; route_type == 2 ? decision_key[3] : nil ; end
      # Type 2's IP, nil when the route carries none (RFC 7432 section
      # 9.2.1: "By default, the IP Address Length field is set to 0").
      def ip ; route_type == 2 ? decision_key[4] : nil ; end
      def path_id ; route.path_id ; end
      def peer ; route.peer ; end

      # Type 3's Originating Router's IP Address (RFC 7432 section 7.3).
      # For type 2, the route does not carry one, so the ORIGINATOR_ID a
      # reflector added or the router ID of the peer it came from.
      def originator
        route_type == 3 ? decision_key[3] : route.router_id
      end

      def esi
        route_type == 2 ? nlri.route.to_hash.values.first[:esi] : nil
      end

      # The VNI, RFC 8365 section 5.1.3: "the entire 24-bit field is used
      # to encode the VNI value", type 2's MPLS Label1 and the PMSI Tunnel
      # attribute's label for type 3.
      def vni
        if route_type == 2
          # The three octets as they were received: Label#to_hash leaves
          # the bottom of stack bit out when it is 1.
          nlri.route.label1.encode.unpack1('H6').to_i(16)
        else
          pmsi&.label_bits
        end
      end

      def pmsi
        pa = route.path_attribute
        pa.has?(BGP::Pmsi_tunnel) ? pa[BGP::Pmsi_tunnel] : nil
      end

      # The PMSI Tunnel attribute as { 'type' => 'ingress_replication',
      # 'id' => '10.255.0.12' }, or nil.
      def pmsi_row
        p = pmsi or return nil
        h = p.to_hash[:pmsi_tunnel]
        { 'type' => h[:tunnel_type].to_s, 'id' => h[:identifier] }
      end

      def route_targets
        communities(BGP::Route_target).collect { |rt| Array(rt.to_hash[:route_target]).join(':') }
      end

      # The Encapsulation community's tunnel type as text, or nil.
      def encap
        e = communities(BGP::Encapsulation).first or return nil
        EVPN_ENCAPS[e.tunnel_type] || "ET:#{e.tunnel_type}"
      end

      # The MAC Mobility sequence number and sticky flag (RFC 7432 section
      # 7.7), or nil when the route carries no such community.
      def mobility
        m = communities(BGP::Mac_mobility).first or return nil
        [m.sequence, m.sticky?]
      end

      private

      def communities(klass)
        pa = route.path_attribute
        return [] unless pa.has?(BGP::Extended_communities)
        pa[BGP::Extended_communities].find_all(klass)
      end
    end

  end
end
