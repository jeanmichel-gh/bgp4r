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

require 'bgp/gen/unicast'
require 'bgp/gen/per_vrf'

module BGP
  class Gen
    # EVPN routes, AFI 25 SAFI 70, of one route type per spec. Three types
    # so far, the three a router sends most:
    #
    # * **2, MAC/IP Advertisement** (RFC 7432 section 7.2): `start` is a
    #   MAC, `00:11:22:00:00:00`, stepped by one per route. `ip` is an
    #   optional first IP, stepped with it, IPv4 or IPv6. `esi` is fixed
    #   and `label` is the MPLS Label1, a value or a pattern.
    # * **3, Inclusive Multicast Ethernet Tag** (section 7.3): `start` is
    #   the Originating Router's IP Address, stepped by one, so a spec of
    #   N routes is N PEs. `pmsi_label` adds the PMSI Tunnel attribute.
    # * **5, IP Prefix** (RFC 9136 section 3.1): `start` is a prefix,
    #   stepped as unicast steps it. `gateway` is a fixed GW IP Address of
    #   the same family, `esi` is fixed and `label` as for type 2.
    #
    # `ethernet_tag` is a value or a pattern for all three. Every route
    # has a Route Distinguisher, so `rd` is required and `vrfs` gives
    # that many EVIs, each carrying the same routes with its own RD and
    # route target: bgp/gen/per_vrf.rb, as for VPN.
    #
    # **The fields in the NLRI run on the route number**, as `path_id`
    # does, and the attributes on the group number. Two attributes are
    # this family's own: `mac_mobility`, the sequence number of the MAC
    # Mobility extended community (RFC 7432 section 7.7), which is how a
    # MAC move is sent, with its sticky flag clear; and `router_mac`, the
    # EVPN Router's MAC extended community (RFC 9135 section 8.1).
    #
    # **A PMSI Tunnel attribute makes every type 3 route a message of its
    # own.** RFC 7432 section 11.2 asks for Ingress Replication with "the
    # Tunnel Identifier set to a routable address of the PE", and this
    # generator's PE is the route's own originator. So no two routes
    # share the attribute set. That is what N PEs would send.
    #
    # **The next hop is the session's**, RFC 7432 section 14, read by its
    # length since the AFI is 25 for IPv4 and IPv6 alike.
    #
    # A withdrawal is the same NLRI in MP_UNREACH_NLRI. A receiver
    # matches it by the route key only, which RFC 7432 section 7.2 and
    # RFC 9136 section 3.1 say leaves out the ESI, the labels and the
    # gateway, so sending them as announced costs nothing.
    #
    # The other eight route types are to do. `mp_reach` sends any of
    # them.
    class Evpn_routes < Unicast
      include PerVrf

      SAFI = IANA::SAFI::EVPN
      AFI = IANA::AFI::L2VPN

      TYPES = [2, 3, 5].freeze

      # The keys that belong to some route types only.
      TYPE_KEYS = { 'ip' => [2], 'mac_mobility' => [2], 'esi' => [2, 5],
                    'label' => [2, 5], 'router_mac' => [2, 5],
                    'gateway' => [5], 'pmsi_label' => [3] }.freeze

      MAC_MAX = 2**48 - 1

      # RFC 7432 section 5: an ESI of all zeros is a single-homed site.
      ZERO_ESI = (['00'] * 10).join(':').freeze

      def initialize(spec, sender = nil)
        @type = spec['route_type']
        unless TYPES.include?(@type)
          raise SpecError, "an evpn spec needs a route_type, #{TYPES.join(', ')} so far, " \
                           "not #{@type.inspect}; mp_reach sends any of the eleven"
        end
        TYPE_KEYS.each do |k, types|
          next if !spec.key?(k) || types.include?(@type)
          raise SpecError, "'#{k}' is for route type #{types.join(' and ')} and not for #{@type}"
        end
        if spec['afi'] && spec['afi'] != AFI
          raise SpecError, "afi #{spec['afi']}: EVPN is AFI #{AFI} whatever its addresses are (RFC 7432 section 7)"
        end
        if @type != 3 && !spec['label']
          raise SpecError, "an evpn route type #{@type} spec needs a label, a value or a pattern " \
                           "from 0 to #{Spec::LABEL_MAX}"
        end
        seed = spec['seed']
        @label = compile(spec, 'label', Spec::LABEL_MAX, seed)
        @tag = compile(spec, 'ethernet_tag', Spec::U32, seed)
        @pmsi = compile(spec, 'pmsi_label', Spec::LABEL_MAX, seed)
        @mobility = compile(spec, 'mac_mobility', Spec::U32, seed)
        @esi = BGP::Evpn::Esi.new(spec['esi'] || ZERO_ESI).to_s
        @router_mac = spec['router_mac'] && spec['router_mac'].delete(':').scan(/../).join(':').downcase
        @gateway = spec['gateway']
        @ip = spec['ip'] && IPAddr.new(spec['ip'])
        read_vrfs(spec, 'evpn')
        super
      end

      attr_reader :type

      # Which of the `count` routes route i is, in every EVI.
      def slot(i) ; i % @count ; end

      def label(i) ; @label.at(i) ; end
      def ethernet_tag(i) ; @tag ? @tag.at(i) : 0 ; end

      # Route type 2's MAC, as "00:11:22:33:44:55".
      def mac(i)
        format('%012x', @first_mac + slot(i)).scan(/../).join(':')
      end

      # Route type 2's IP, or nil when the spec has none.
      def ip(i)
        @ip && IPAddr.new(@ip.to_i + slot(i), @ip.family).to_s
      end

      # Route type 3's Originating Router's IP Address.
      def originator(i) ; prefix(i).split('/').first ; end

      # Route type 5's GW IP Address: the spec's, or zero of the prefix's
      # family, which RFC 9136 section 3.1 writes when there is none.
      def gateway
        @gateway || (@ip_afi == IANA::AFI::IPv4 ? '0.0.0.0' : '::')
      end

      def route(i)
        r = case @type
            when 2
              BGP::Evpn::Mac_ip_advertisement.new(rd(vrf(i)), @esi, ethernet_tag(i), mac(i), ip(i), label(i))
            when 3
              BGP::Evpn::Inclusive_multicast.new(rd(vrf(i)), ethernet_tag(i), originator(i))
            when 5
              BGP::Evpn::Ip_prefix_route.new(rd(vrf(i)), @esi, ethernet_tag(i), prefix(i), gateway, label(i))
            end
        n = BGP::Evpn.new(r)
        n.path_id = path_id(i) if add_path?
        n
      end

      # Each NLRI measured, since an IP or not and its family change the
      # length, and the Path Identifier is in the octets.
      def route_len(r) ; r.encode.bytesize ; end

      def route_row(i)
        r = { 'route_type' => @type, 'rd' => @rd.text(vrf(i)) }
        case @type
        when 2
          r['mac'] = mac(i)
          r['ip'] = ip(i) if @ip
          r['esi'] = @esi
          r['label'] = label(i)
        when 3
          r['originator'] = originator(i)
        when 5
          r['prefix'] = prefix(i)
          r['gateway'] = gateway
          r['esi'] = @esi
          r['label'] = label(i)
        end
        r['ethernet_tag'] = ethernet_tag(i)
        r['path_id'] = path_id(i) if add_path?
        r
      end

      # With a PMSI Tunnel the route number is part of the key, since the
      # attribute names the route's own originator.
      def set_key(i) ; @pmsi ? [super, i] : super ; end

      def row_at(key)
        k, i = @pmsi ? key : [key, nil]
        r = super(k).dup
        g = k[0]
        r['mac_mobility'] = @mobility.at(g) if @mobility
        r['router_mac'] = @router_mac if @router_mac
        if @pmsi
          r['pmsi'] = { 'tunnel_type' => 'ingress_replication', 'label' => @pmsi.at(i),
                        'identifier' => originator(i) }
        end
        r
      end

      private

      def compile(spec, k, max, seed)
        spec[k] && Vary.compile(spec[k], k, :int, max: max, seed: seed)
      end

      def read_start(start)
        if @type == 2
          unless start =~ /\A\h\h(:\h\h){5}\z/
            raise SpecError, "a route type 2 start is a MAC, 00:11:22:33:44:55, not #{start.inspect}"
          end
          @first_mac = start.delete(':').to_i(16)
          if @first_mac + @count - 1 > MAC_MAX
            raise SpecError, "#{@count} MACs from #{start} run past ff:ff:ff:ff:ff:ff"
          end
          check_ip
        else
          if @type == 3 && start.include?('/')
            raise SpecError, "a route type 3 start is the originator's address, not a prefix: #{start}"
          end
          super
          @ip_afi = @afi
          check_gateway if @type == 5
        end
        @afi = AFI
      end

      def check_ip
        return unless @ip
        bits = @ip.ipv4? ? 32 : 128
        return if @ip.to_i + @count - 1 <= 2**bits - 1
        raise SpecError, "#{@count} addresses from ip #{@ip} run past the end of the address space"
      end

      def check_gateway
        return unless @gateway
        return if IPAddr.new(@gateway).ipv4? == (@ip_afi == IANA::AFI::IPv4)
        raise SpecError, "gateway #{@gateway} and start are not of one family (RFC 9136 section 3.1)"
      end

      # The two EVPN communities join the spec's own extended communities,
      # and the EVI's route target, in one attribute; the PMSI Tunnel is
      # an attribute of its own (RFC 6514 section 5).
      def build_attributes(a)
        extra = []
        extra << { :mac_mobility => [a['mac_mobility'], false] } if a['mac_mobility']
        extra << { :router_mac => a['router_mac'] } if a['router_mac']
        pa = if extra.empty?
               super
             else
               list = Array(a['extended_communities']).collect { |t| Daemon::CommunityKeys.extended_community_hash(t) }
               super(a.reject { |k, _| k == 'extended_communities' })
                 .add(BGP::Extended_communities.new(:extended_communities => list + extra))
             end
        if (t = a['pmsi'])
          pa.add(BGP::Pmsi_tunnel.new(:ingress_replication, t['identifier'], :label => t['label']))
        end
        pa
      end

      def expected_attributes(a, pa)
        row = super
        row['pmsi'] = a['pmsi'] if a['pmsi']
        row
      end

      def mp_nlris(batch) ; batch ; end
    end
  end
end
