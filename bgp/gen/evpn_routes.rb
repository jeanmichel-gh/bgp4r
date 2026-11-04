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
    # EVPN routes, AFI 25 SAFI 70, of one route type per spec. All eleven
    # route types, each with `start` as the field that steps:
    #
    # * **1, Ethernet Auto-discovery** (RFC 7432 section 7.1): `start` is
    #   an ESI, `00:00:00:00:00:00:00:00:00:01`, its 80 bits stepped by
    #   one per route. `label` is the MPLS Label. `esi_label` adds the ESI
    #   Label extended community of section 7.5, single-active flag clear,
    #   which section 8.2.1 carries on the per-ES route.
    # * **2, MAC/IP Advertisement** (section 7.2): `start` is a MAC,
    #   `00:11:22:00:00:00`, stepped by one per route. `ip` is an optional
    #   first IP, stepped with it, IPv4 or IPv6. `esi` is fixed and
    #   `label` is the MPLS Label1, a value or a pattern.
    # * **3, Inclusive Multicast Ethernet Tag** (section 7.3): `start` is
    #   the Originating Router's IP Address, stepped by one, so a spec of
    #   N routes is N PEs. `pmsi_label` adds the PMSI Tunnel attribute.
    # * **4, Ethernet Segment** (section 7.4): `start` is an ESI, stepped
    #   as for type 1, and `originator` the Originating Router's IP
    #   Address. `es_import: true` adds each route's ES-Import Route
    #   Target, which section 7.6 derives from "the high-order six bytes
    #   of the 9-byte ESI Value".
    # * **5, IP Prefix** (RFC 9136 section 3.1): `start` is a prefix,
    #   stepped as unicast steps it. `gateway` is a fixed GW IP Address of
    #   the same family, `esi` is fixed and `label` as for type 2.
    # * **6, 7 and 8**, Selective Multicast, Membership Report Synch and
    #   Leave Synch (RFC 9251 sections 9.1 to 9.3): `start` is the
    #   Multicast Group, stepped by one, `source` a fixed Multicast Source
    #   or none for (*,G), `originator` the Originator Router's address,
    #   and `igmp_flags` a list of v1, v2, v3 and ie, v2 by default since
    #   section 4.1 makes a route with no version flag one to withdraw.
    #   7 and 8 take `esi`, and 8 `max_response_time`.
    # * **9, Per-Region I-PMSI A-D** (RFC 9572 section 3.1): `start` is
    #   the 8-octet Region ID in hex, stepped as a 64-bit number.
    # * **10, S-PMSI A-D** (RFC 9572 section 3.2): as 6, with no flags.
    # * **11, Leaf A-D** (RFC 9572 section 3.3): its Route Key is a whole
    #   route type 10 NLRI, built as type 10 would build it, and `leaf` is
    #   the Leaf A-D route's own Originator's Addr.
    #
    # `ethernet_tag` is a value or a pattern for every type but 4 and 11,
    # which have no Ethernet Tag ID. Every route has a Route
    # Distinguisher, a type 11 through its Route Key, so `rd` is required
    # and `vrfs` gives that many EVIs, each carrying the same routes with
    # its own RD and route target: bgp/gen/per_vrf.rb, as for VPN.
    #
    # **The fields in the NLRI run on the route number**, as `path_id`
    # does, and the attributes on the group number. The EVPN extended
    # communities are this family's own: `mac_mobility`, the sequence
    # number of the MAC Mobility community (RFC 7432 section 7.7), which
    # is how a MAC move is sent, with its sticky flag clear;
    # `router_mac`, the EVPN Router's MAC (RFC 9135 section 8.1); and
    # `esi_label` and `es_import` above.
    #
    # **A PMSI Tunnel attribute makes every type 3 route a message of its
    # own.** RFC 7432 section 11.2 asks for Ingress Replication with "the
    # Tunnel Identifier set to a routable address of the PE", and this
    # generator's PE is the route's own originator. So no two routes
    # share the attribute set. That is what N PEs would send. An
    # ES-Import Route Target does the same for type 4, since each route's
    # comes from its own ESI.
    #
    # **The next hop is the session's**, RFC 7432 section 14, read by its
    # length since the AFI is 25 for IPv4 and IPv6 alike.
    #
    # A withdrawal is the same NLRI in MP_UNREACH_NLRI. A receiver
    # matches it by the route key only, which RFC 7432 section 7.2 and
    # RFC 9136 section 3.1 say leaves out the ESI, the labels and the
    # gateway, so sending them as announced costs nothing.
    class Evpn_routes < Unicast
      include PerVrf

      SAFI = IANA::SAFI::EVPN
      AFI = IANA::AFI::L2VPN

      TYPES = (1..11).to_a.freeze

      # The route types whose `start` is an ESI, a Multicast Group, a
      # Region ID.
      ESI_START = [1, 4].freeze
      GROUP_START = [6, 7, 8, 10, 11].freeze

      # The keys that belong to some route types only.
      TYPE_KEYS = { 'ip' => [2], 'mac_mobility' => [2], 'esi' => [2, 5, 7, 8],
                    'label' => [1, 2, 5], 'router_mac' => [2, 5],
                    'gateway' => [5], 'pmsi_label' => [3],
                    'ethernet_tag' => TYPES - [4, 11],
                    'originator' => [4] + GROUP_START, 'source' => GROUP_START,
                    'igmp_flags' => [6, 7, 8], 'max_response_time' => [8],
                    'leaf' => [11], 'es_import' => [4], 'esi_label' => [1] }.freeze

      # The keys a route type cannot do without.
      REQUIRED = { 'label' => [1, 2, 5], 'originator' => [4] + GROUP_START,
                   'leaf' => [11] }.freeze

      MAC_MAX = 2**48 - 1
      ESI_MAX = 2**80 - 1
      REGION_MAX = 2**64 - 1

      # RFC 7432 section 5: an ESI of all zeros is a single-homed site.
      ZERO_ESI = (['00'] * 10).join(':').freeze

      # RFC 9251 section 4.1: a route with no IGMP version flag is one to
      # withdraw, so the default is the one version everybody has.
      IGMP_FLAGS = %w[v2].freeze

      def initialize(spec, sender = nil)
        @type = spec['route_type']
        unless TYPES.include?(@type)
          raise SpecError, "an evpn spec needs a route_type, 1 to 11, not #{@type.inspect}"
        end
        TYPE_KEYS.each do |k, types|
          next if !spec.key?(k) || types.include?(@type)
          raise SpecError, "'#{k}' is for route type #{types.join(', ')} and not for #{@type}"
        end
        REQUIRED.each do |k, types|
          next if spec.key?(k) || !types.include?(@type)
          raise SpecError, "an evpn route type #{@type} spec needs #{k == 'label' ? 'a label, a value or a pattern ' \
                           "from 0 to #{Spec::LABEL_MAX}" : "#{k == 'leaf' ? 'a leaf' : 'an originator'}, an address"}"
        end
        if spec['afi'] && spec['afi'] != AFI
          raise SpecError, "afi #{spec['afi']}: EVPN is AFI #{AFI} whatever its addresses are (RFC 7432 section 7)"
        end
        seed = spec['seed']
        @label = compile(spec, 'label', Spec::LABEL_MAX, seed)
        @tag = compile(spec, 'ethernet_tag', Spec::U32, seed)
        @pmsi = compile(spec, 'pmsi_label', Spec::LABEL_MAX, seed)
        @mobility = compile(spec, 'mac_mobility', Spec::U32, seed)
        @esi_label = compile(spec, 'esi_label', Spec::LABEL_MAX, seed)
        @es_import = spec['es_import'] == true
        @esi = BGP::Evpn::Esi.new(spec['esi'] || ZERO_ESI).to_s
        @router_mac = spec['router_mac'] && spec['router_mac'].delete(':').scan(/../).join(':').downcase
        @gateway = spec['gateway']
        @ip = spec['ip'] && IPAddr.new(spec['ip'])
        @originator = spec['originator']
        @source = spec['source']
        @leaf = spec['leaf']
        @flags = (spec['igmp_flags'] || IGMP_FLAGS).collect(&:to_sym)
        @response = spec['max_response_time'] || 0
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
      def originator(i)
        @type == 3 ? prefix(i).split('/').first : @originator
      end

      # Route types 1 and 4's ESI, as ten octets of hex with colons.
      def esi(i)
        ESI_START.include?(@type) ? format('%020x', @first_esi + slot(i)).scan(/../).join(':') : @esi
      end

      # Route types 6, 7, 8, 10 and 11's Multicast Group.
      def group(i) ; IPAddr.new(@first_group + slot(i), @group_family).to_s ; end

      # Route type 9's Region ID, as 16 hex digits.
      def region(i) ; format('%016x', @first_region + slot(i)) ; end

      # The ES-Import Route Target of section 7.6: the high-order six of
      # the ESI Value's nine octets, which follow its Type octet.
      def es_import(i) ; esi(i).split(':')[1, 6].join(':') ; end

      # Route type 5's GW IP Address: the spec's, or zero of the prefix's
      # family, which RFC 9136 section 3.1 writes when there is none.
      def gateway
        @gateway || (@ip_afi == IANA::AFI::IPv4 ? '0.0.0.0' : '::')
      end

      def route(i)
        n = BGP::Evpn.new(route_type(i))
        n.path_id = path_id(i) if add_path?
        n
      end

      def route_type(i)
        e = BGP::Evpn
        rd = rd(vrf(i))
        tag = ethernet_tag(i)
        case @type
        when 1 then e::Ethernet_ad.new(rd, esi(i), tag, label(i))
        when 2 then e::Mac_ip_advertisement.new(rd, @esi, tag, mac(i), ip(i), label(i))
        when 3 then e::Inclusive_multicast.new(rd, tag, originator(i))
        when 4 then e::Ethernet_segment.new(rd, esi(i), @originator)
        when 5 then e::Ip_prefix_route.new(rd, @esi, tag, prefix(i), gateway, label(i))
        when 6 then e::Selective_multicast.new(rd, tag, @source, group(i), @originator, @flags)
        when 7 then e::Membership_report_synch.new(rd, @esi, tag, @source, group(i), @originator, @flags)
        when 8 then e::Leave_synch.new(rd, @esi, tag, @source, group(i), @originator, @response, @flags)
        when 9 then e::Per_region_i_pmsi.new(rd, tag, region(i))
        when 10 then e::S_pmsi.new(rd, tag, @source, group(i), @originator)
        when 11 then e::Leaf_a_d.new(BGP::Evpn.new(e::S_pmsi.new(rd, 0, @source, group(i), @originator)), @leaf)
        end
      end

      # Each NLRI measured, since an IP or not and its family change the
      # length, and the Path Identifier is in the octets.
      def route_len(r) ; r.encode.bytesize ; end

      def route_row(i)
        r = { 'route_type' => @type, 'rd' => @rd.text(vrf(i)) }
        case @type
        when 1
          r['esi'] = esi(i)
          r['label'] = label(i)
        when 2
          r['mac'] = mac(i)
          r['ip'] = ip(i) if @ip
          r['esi'] = @esi
          r['label'] = label(i)
        when 3
          r['originator'] = originator(i)
        when 4
          r['esi'] = esi(i)
          r['originator'] = @originator
        when 5
          r['prefix'] = prefix(i)
          r['gateway'] = gateway
          r['esi'] = @esi
          r['label'] = label(i)
        when 6, 7, 8, 10, 11
          r['esi'] = @esi if [7, 8].include?(@type)
          r['source'] = @source if @source
          r['group'] = group(i)
          r['originator'] = @originator
          r['igmp_flags'] = @flags.collect(&:to_s).sort if [6, 7, 8].include?(@type)
          r['max_response_time'] = @response if @type == 8
          r['leaf'] = @leaf if @type == 11
        when 9
          r['region_id'] = region(i)
        end
        r['ethernet_tag'] = ethernet_tag(i) unless [4, 11].include?(@type)
        r['path_id'] = path_id(i) if add_path?
        r
      end

      # With a PMSI Tunnel or an ES-Import Route Target the route number
      # is part of the key, since the attribute is the route's own.
      def set_key(i) ; per_route? ? [super, i] : super ; end

      def row_at(key)
        k, i = per_route? ? key : [key, nil]
        r = super(k).dup
        g = k[0]
        r['mac_mobility'] = @mobility.at(g) if @mobility
        r['router_mac'] = @router_mac if @router_mac
        r['esi_label'] = @esi_label.at(g) if @esi_label
        r['es_import'] = es_import(i) if @es_import
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

      def per_route? ; @pmsi || @es_import ; end

      def read_start(start)
        if ESI_START.include?(@type)
          unless start =~ /\A\h\h(:\h\h){9}\z/
            raise SpecError, "a route type #{@type} start is an ESI, ten octets, " \
                             "00:00:00:00:00:00:00:00:00:01, not #{start.inspect} (RFC 7432 section 5)"
          end
          @first_esi = start.delete(':').to_i(16)
          if @first_esi + @count - 1 > ESI_MAX
            raise SpecError, "#{@count} ESIs from #{start} run past ff:ff:ff:ff:ff:ff:ff:ff:ff:ff"
          end
        elsif GROUP_START.include?(@type)
          read_group(start)
        elsif @type == 9
          unless start =~ /\A\h{16}\z/
            raise SpecError, "a route type 9 start is a Region ID, 8 octets of hex, not #{start.inspect} " \
                             '(RFC 9572 section 3.1)'
          end
          @first_region = start.to_i(16)
          if @first_region + @count - 1 > REGION_MAX
            raise SpecError, "#{@count} Region IDs from #{start} run past ffffffffffffffff"
          end
        elsif @type == 2
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

      # A Multicast Group, stepped by one, with a Multicast Source of the
      # same family, which RFC 9251 section 9.1.1 assumes.
      def read_group(start)
        a = begin
          IPAddr.new(start)
        rescue IPAddr::Error => e
          raise SpecError, "a route type #{@type} start is a Multicast Group: #{e.message}"
        end
        if start.include?('/')
          raise SpecError, "a route type #{@type} start is a Multicast Group address, not a prefix: #{start}"
        end
        @first_group, @group_family = a.to_i, a.family
        bits = a.ipv4? ? 32 : 128
        if @first_group + @count - 1 > 2**bits - 1
          raise SpecError, "#{@count} groups from #{start} run past the end of the address space"
        end
        if @source && IPAddr.new(@source).ipv4? != a.ipv4?
          raise SpecError, "source #{@source} and the group #{start} are not of one family"
        end
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

      # The EVPN communities join the spec's own extended communities,
      # and the EVI's route target, in one attribute; the PMSI Tunnel is
      # an attribute of its own (RFC 6514 section 5).
      def build_attributes(a)
        extra = []
        extra << { :mac_mobility => [a['mac_mobility'], false] } if a['mac_mobility']
        extra << { :router_mac => a['router_mac'] } if a['router_mac']
        extra << { :esi_label => [a['esi_label'], false] } if a['esi_label']
        extra << { :es_import => a['es_import'] } if a['es_import']
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
