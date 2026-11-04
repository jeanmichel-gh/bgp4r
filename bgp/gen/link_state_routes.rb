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

module BGP
  class Gen
    # BGP-LS, AFI 16388 SAFI 71 and 72 (RFC 9552): a **topology** rather
    # than a range. `count` nodes, joined as a ring or a grid, each with
    # `prefixes` prefixes of its own. It is the one family where a spec
    # means a graph, and so the one where a router can be fed an IGP
    # that does not exist.
    #
    # Node n's router ID is `start`, an IPv4 address, with n added. It
    # goes in the IGP Router-ID sub-TLV of section 5.2.1.4, whose width
    # the Protocol-ID decides: 6 octets for IS-IS, an ISO system ID,
    # written here as two zero octets then the router ID, and 4 octets
    # for everything else. `autonomous_system` adds the optional sub-TLV
    # 512 to every node descriptor.
    #
    # The routes, in this order, once per VRF:
    #
    # * One **Node NLRI** per node, figure 7.
    # * Two **Link NLRIs** per link, figure 8, one per direction, since
    #   section 5.2.2 describes a link as seen from its local node. A
    #   link carries TLV 258, the Link Local/Remote Identifiers, with
    #   link number + 1 on both sides, so two links between one pair of
    #   nodes, which a grid of two columns can make, stay apart.
    # * `prefixes` **Prefix NLRIs** per node, figure 9, stepping from
    #   `prefix_start` as unicast steps from `start`. IPv4 or IPv6 by
    #   that prefix's family, NLRI type 3 or 4.
    #
    # A ring joins node i to node i + 1 and the last to the first, so it
    # has `count` links from 3 nodes on, one for 2 and none for 1. A grid
    # of `columns` joins each node to the one on its right and the one
    # below it.
    #
    # The BGP-LS Attribute, code 29 (section 5.3), carries what the spec
    # asks for and nothing else. Each value is a pattern:
    #
    # * on the **link number** for `igp_metric` (1095, 3 octets),
    #   `admin_group` (1088), `max_bandwidth` (1089, bytes per second)
    #   and `srlg` (1096, one value), so both halves of a link agree;
    # * on the **prefix number** for `prefix_metric` (1155);
    # * `node_name` is text, and node n is named it with n + 1 after it,
    #   so "r" names r1, r2 and so on (1026).
    #
    # A route with an attribute of its own is an attribute set of its
    # own, so a node name puts each Node NLRI in a message by itself.
    #
    # `bgp_ls_vpn`, SAFI 72, takes `rd`, `vrfs` and `route_target` as
    # VPN does: the whole topology once per VRF, with the VRF's RD in
    # front of each NLRI (section 5.2). The next hop is the session's;
    # `Mp_reach` prepends the one zero RD of section 5.5 itself.
    #
    # Nothing here validates, so a topology no IGP could have builds.
    class Link_state_routes < Unicast
      SAFI = IANA::SAFI::BGP_LS
      AFI = IANA::AFI::BGP_LS
      T = BGP::Link_state::Tlv

      TOPOLOGIES = %w[ring grid].freeze

      # The IS-IS Protocol-IDs of section 5.2's Table 2, whose IGP
      # Router-ID is a 6-octet system ID (section 5.2.1.4).
      ISIS = [1, 2].freeze

      def initialize(spec, sender = nil)
        @topology = spec['topology'] || 'ring'
        @columns = spec['columns']
        if @topology == 'grid' && @columns.nil?
          raise SpecError, 'a grid topology needs columns'
        end
        if @topology == 'ring' && @columns
          raise SpecError, 'columns is for a grid topology, not a ring'
        end
        @protocol_id = spec['protocol_id'] || 3
        @identifier = spec['identifier'] || 0
        @as = spec['autonomous_system']
        @prefixes = spec['prefixes'] || 0
        @node_name = spec['node_name']
        seed = spec['seed']
        @metric = compile(spec, 'igp_metric', Spec::LS_MAX['igp_metric'], seed)
        @group_bits = compile(spec, 'admin_group', Spec::U32, seed)
        @bandwidth = compile(spec, 'max_bandwidth', Spec::U32, seed)
        @srlg = compile(spec, 'srlg', Spec::U32, seed)
        @pmetric = compile(spec, 'prefix_metric', Spec::U32, seed)
        @count = spec['count']
        @edges = edges
        read_prefix_start(spec['prefix_start'])
        read_vrfs(spec)
        super
      end

      # The links, as [a, b] node numbers, a < b except the ring's last.
      attr_reader :edges

      # Routes in one copy of the topology.
      def size ; @count + 2 * @edges.size + @count * @prefixes ; end

      def total ; size * @vrfs ; end

      def vpn? ; safi == IANA::SAFI::BGP_LS_VPN ; end

      def vrf(i) ; i / size ; end

      # Route i as [kind, number]: [:node, n], [:link, half] or
      # [:prefix, p], where a half is 2 per link, its direction in the
      # low bit.
      def slot(i)
        t = i % size
        return [:node, t] if t < @count
        t -= @count
        return [:link, t] if t < 2 * @edges.size
        [:prefix, t - 2 * @edges.size]
      end

      # Node n's router ID as text.
      def router_id(n) ; IPAddr.new(@first_id + n, Socket::AF_INET).to_s ; end

      # Half h's [local, remote] node numbers and its link number.
      def half(h)
        a, b = @edges[h / 2]
        h.even? ? [a, b, h / 2] : [b, a, h / 2]
      end

      # Prefix p's node and the prefix itself.
      def owner(p) ; p / @prefixes ; end

      def prefix(p)
        "#{IPAddr.new(@prefix_first + p * @prefix_step, @prefix_family)}/#{@prefix_mlen}"
      end

      def route(i)
        kind, n = slot(i)
        h = case kind
            when :node
              { :node => head(local(n)) }
            when :link
              l, r, e = half(n)
              { :link => head(local(l), remote(r),
                              { :link_local_remote_identifiers => { :local => e + 1, :remote => e + 1 } }) }
            when :prefix
              { prefix_key => head(local(owner(n)), { :ip_reachability => prefix(n) }) }
            end
        h[:rd] = @rd.at(vrf(i)) if vpn?
        ls = BGP::Link_state.new(h)
        ls.path_id = path_id(i) if add_path?
        ls
      end

      def route_len(r) ; r.encode.bytesize ; end

      def route_row(i)
        kind, n = slot(i)
        r = case kind
            when :node then { 'nlri' => 'node', 'node' => router_id(n) }
            when :link
              l, rm, e = half(n)
              { 'nlri' => 'link', 'node' => router_id(l), 'remote' => router_id(rm), 'link' => e + 1 }
            when :prefix
              { 'nlri' => prefix_key.to_s, 'node' => router_id(owner(n)), 'prefix' => prefix(n) }
            end
        r['protocol_id'] = @protocol_id
        r['identifier'] = @identifier
        r['rd'] = @rd.text(vrf(i)) if vpn?
        r['path_id'] = path_id(i) if add_path?
        r
      end

      # The group number, the VRF, and what route i's BGP-LS Attribute
      # holds, since that is per route and not per group.
      def set_key(i) ; [i / @group, vpn? ? vrf(i) : 0, ls_values(i)] ; end

      def row_at(key)
        g, v, ls = key
        r = super(g)
        r = r.dup
        r['bgp_ls'] = ls unless ls.empty?
        if @rt
          r['extended_communities'] = Array(r['extended_communities']) + ["route_target:#{@rt.text(v)}"]
        end
        r
      end

      private

      def compile(spec, k, max, seed)
        spec[k] && Vary.compile(spec[k], k, :int, max: max, seed: seed)
      end

      # The BGP-LS Attribute values for route i, in the order they are
      # written, as plain data.
      def ls_values(i)
        kind, n = slot(i)
        h = {}
        case kind
        when :node
          h['node_name'] = "#{@node_name}#{n + 1}" if @node_name
        when :link
          e = n / 2
          h['admin_group'] = @group_bits.at(e) if @group_bits
          h['max_bandwidth'] = @bandwidth.at(e) if @bandwidth
          h['igp_metric'] = @metric.at(e) if @metric
          h['srlg'] = @srlg.at(e) if @srlg
        when :prefix
          h['prefix_metric'] = @pmetric.at(n) if @pmetric
        end
        h
      end

      def edges
        if @topology == 'ring'
          return [] if @count < 2
          e = (0...@count - 1).collect { |i| [i, i + 1] }
          e << [@count - 1, 0] if @count >= 3
          e
        else
          e = []
          @count.times do |i|
            e << [i, i + 1] if (i + 1) % @columns != 0 && i + 1 < @count
            e << [i, i + @columns] if i + @columns < @count
          end
          e
        end
      end

      def head(*tlvs)
        { :protocol_id => @protocol_id, :identifier => @identifier, :tlvs => tlvs }
      end

      def descriptors(n)
        d = []
        d << { :autonomous_system => @as } if @as
        d << { :igp_router_id => igp_router_id(n) }
        d
      end

      def local(n) ; { :local_node_descriptors => descriptors(n) } ; end
      def remote(n) ; { :remote_node_descriptors => descriptors(n) } ; end

      def igp_router_id(n)
        id = format('%08x', @first_id + n)
        ISIS.include?(@protocol_id) ? '0000' + id : id
      end

      def prefix_key
        @prefix_family == Socket::AF_INET6 ? :ipv6_prefix : :ipv4_prefix
      end

      def read_start(start)
        a = begin
          IPAddr.new(start)
        rescue IPAddr::Error => e
          raise SpecError, "start #{start.inspect} is not a router ID: #{e.message}"
        end
        if !a.ipv4? || start.include?('/')
          raise SpecError, "a bgp_ls start is the first node's router ID, an IPv4 address, not #{start.inspect}"
        end
        @first_id = a.to_i
        if @first_id + @count - 1 > Spec::U32
          raise SpecError, "#{@count} router IDs from #{start} run past 255.255.255.255"
        end
        @afi = AFI
      end

      def read_prefix_start(start)
        if @prefixes > 0 && start.nil?
          raise SpecError, 'prefixes per node need a prefix_start'
        end
        if @prefixes.zero? && start
          raise SpecError, 'prefix_start is for prefixes per node, and prefixes is 0'
        end
        return unless start
        a = begin
          IPAddr.new(start)
        rescue IPAddr::Error => e
          raise SpecError, "prefix_start #{start.inspect} is not a prefix: #{e.message}"
        end
        @prefix_mlen = a.prefix
        bits = a.ipv4? ? 32 : 128
        @prefix_family = a.ipv4? ? Socket::AF_INET : Socket::AF_INET6
        @prefix_first, @prefix_step = a.to_i, 2**(bits - @prefix_mlen)
        if @prefix_first + (@count * @prefixes - 1) * @prefix_step > 2**bits - 1
          raise SpecError, "#{@count * @prefixes} prefixes from #{start} run past the end of the address space"
        end
      end

      def read_vrfs(spec)
        @vrfs = spec['vrfs'] || 1
        @rd = spec['rd'] && Spec.distinguisher(spec['rd'], 'rd')
        @rt = spec['route_target'] && Spec.distinguisher(spec['route_target'], 'route_target')
        if vpn? && @rd.nil?
          raise SpecError, 'a bgp_ls_vpn spec needs an rd, ADMIN:N, stepped once per VRF (RFC 9552 section 5.2)'
        end
      end

      # The spec's attributes, then the BGP-LS Attribute when the route
      # has one.
      def build_attributes(a)
        pa = super
        ls = a['bgp_ls']
        pa.add(BGP::Link_state_attribute.new(*ls_tlvs(ls))) if ls
        pa
      end

      def ls_tlvs(ls)
        ls.collect do |k, v|
          case k
          when 'node_name' then T::Node_name.new(v)
          when 'admin_group' then T::Administrative_group.new(v)
          when 'max_bandwidth' then T::Maximum_link_bandwidth.new(v.to_f)
          when 'igp_metric' then T::Igp_metric.new(v)
          when 'srlg' then T::Srlg.new(v)
          when 'prefix_metric' then T::Prefix_metric.new(v)
          end
        end
      end

      def expected_attributes(a, pa)
        row = super
        row.merge!(a['bgp_ls']) if a['bgp_ls']
        row
      end

      def mp_nlris(batch) ; batch ; end
    end

    # SAFI 72, the same topology with an RD per VRF.
    class Link_state_vpn_routes < Link_state_routes
      SAFI = IANA::SAFI::BGP_LS_VPN
    end
  end
end
