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
    # MCAST-VPN routes, SAFI 5, of one route type per spec. The seven
    # route types of RFC 6514 section 4, each with `start` as the field
    # that steps:
    #
    # * **1, Intra-AS I-PMSI A-D** (section 4.1): `start` is the
    #   Originating Router's IP Address, stepped by one, so a spec of N
    #   routes is N PEs.
    # * **2, Inter-AS I-PMSI A-D** (section 4.2): `start` is the Source
    #   AS as a decimal string, `"65001"`, stepped by one, so N routes
    #   are N ASes.
    # * **3, S-PMSI A-D** (section 4.3), **5, Source Active A-D**
    #   (section 4.5), and **6 and 7, Shared and Source Tree Join**
    #   (section 4.6): `start` is the Multicast Group, stepped by one.
    #   `source` is a fixed Multicast Source, or none, which writes a
    #   length of 0. 3 needs an `originator`, and 6 and 7 a `source_as`.
    # * **4, Leaf A-D** (section 4.4): its Route Key is a whole route
    #   type 3 NLRI, built as type 3 would build it, which RFC 6515
    #   section 2 item 4 confirms is self delimiting. `leaf` is the Leaf
    #   A-D route's own Originating Router's IP Address.
    #
    # Every route but type 4 has a Route Distinguisher, and type 4 has
    # one through its Route Key, so `rd` is required and `vrfs` gives
    # that many VPNs, each with its own RD and route target:
    # bgp/gen/per_vrf.rb, as for VPN and EVPN.
    #
    # **The AFI is the customer family and never the provider's.** RFC
    # 6515 section 1.1: AFI 1 means the Multicast Source and Group are
    # IPv4 and AFI 2 IPv6, and the family of a PE address "MUST NOT be
    # inferred from the AFI field". So a type that carries a Multicast
    # Group takes the AFI from the group, and types 1 and 2, which carry
    # none, take `afi` from the spec, 1 when it says nothing.
    #
    # **The next hop is the session's**, read by its length, RFC 6515
    # section 2 item 1, and under AFI 2 an IPv4 next hop stays 4 octets
    # rather than becoming an IPv4-mapped address (section 1.1).
    #
    # A withdrawal is the same NLRI in MP_UNREACH_NLRI.
    class Mcast_vpn_routes < Unicast
      include PerVrf

      SAFI = IANA::SAFI::MCAST_VPN

      TYPES = (1..7).to_a.freeze

      # The route types whose `start` is a Multicast Group.
      GROUP_START = [3, 4, 5, 6, 7].freeze

      # The keys that belong to some route types only.
      TYPE_KEYS = { 'source' => GROUP_START, 'originator' => [3, 4],
                    'leaf' => [4], 'source_as' => [6, 7] }.freeze

      # The keys a route type cannot do without.
      REQUIRED = { 'originator' => [3, 4], 'leaf' => [4], 'source_as' => [6, 7] }.freeze

      def initialize(spec, sender = nil)
        @type = spec['route_type']
        unless TYPES.include?(@type)
          raise SpecError, "an mcast_vpn spec needs a route_type, 1 to 7, not #{@type.inspect} (RFC 6514 section 4)"
        end
        TYPE_KEYS.each do |k, types|
          next if !spec.key?(k) || types.include?(@type)
          raise SpecError, "'#{k}' is for route type #{types.join(', ')} and not for #{@type}"
        end
        REQUIRED.each do |k, types|
          next if spec.key?(k) || !types.include?(@type)
          raise SpecError, "an mcast_vpn route type #{@type} spec needs #{k == 'originator' ? 'an' : 'a'} #{k}"
        end
        @spec_afi = spec['afi']
        @originator = spec['originator']
        @source = spec['source']
        @leaf = spec['leaf']
        @source_as = spec['source_as']
        read_vrfs(spec, 'mcast_vpn')
        super
      end

      attr_reader :type

      # Which of the `count` routes route i is, in every VPN.
      def slot(i) ; i % @count ; end

      # Route type 1's Originating Router's IP Address.
      def originator(i)
        @type == 1 ? IPAddr.new(@first + slot(i), @family).to_s : @originator
      end

      # Route type 2's Source AS.
      def source_as(i) ; @type == 2 ? @first + slot(i) : @source_as ; end

      # The Multicast Group of the types that carry one.
      def group(i) ; IPAddr.new(@first + slot(i), @family).to_s ; end

      def route(i)
        n = BGP::Mcast_vpn.new(route_type(i))
        n.path_id = path_id(i) if add_path?
        n
      end

      def route_type(i)
        m = BGP::Mcast_vpn
        rd = rd(vrf(i))
        case @type
        when 1 then m::Intra_as_i_pmsi.new(rd, originator(i))
        when 2 then m::Inter_as_i_pmsi.new(rd, source_as(i))
        when 3 then s_pmsi(rd, i)
        when 4 then m::Leaf_a_d.new(BGP::Mcast_vpn.new(s_pmsi(rd, i)), @leaf)
        when 5 then m::Source_active.new(rd, @source, group(i))
        when 6 then m::Shared_tree_join.new(rd, @source_as, @source, group(i))
        when 7 then m::Source_tree_join.new(rd, @source_as, @source, group(i))
        end
      end

      def route_len(r) ; r.encode.bytesize ; end

      def route_row(i)
        r = { 'route_type' => @type, 'rd' => @rd.text(vrf(i)) }
        case @type
        when 1 then r['originator'] = originator(i)
        when 2 then r['source_as'] = source_as(i)
        else
          r['source_as'] = @source_as if [6, 7].include?(@type)
          r['source'] = @source if @source
          r['group'] = group(i)
          r['originator'] = @originator if [3, 4].include?(@type)
          r['leaf'] = @leaf if @type == 4
        end
        r['path_id'] = path_id(i) if add_path?
        r
      end

      private

      def s_pmsi(rd, i)
        BGP::Mcast_vpn::S_pmsi.new(rd, @source, group(i), @originator)
      end

      def read_start(start)
        case @type
        when 1 then read_originator(start)
        when 2 then read_source_as(start)
        else read_group(start)
        end
      end

      # Route type 1: a PE address, stepped by one. Its family says
      # nothing about the AFI (RFC 6515 section 1.1).
      def read_originator(start)
        a = address(start, 'the Originating Router\'s IP Address')
        @first, @family = a.to_i, a.family
        check_range(a, start)
        @afi = @spec_afi || IANA::AFI::IPv4
      end

      # Route type 2: a 4-octet Source AS (section 4.2), stepped by one.
      def read_source_as(start)
        unless start =~ /\A\d+\z/
          raise SpecError, "a route type 2 start is a Source AS as a decimal string, \"65001\", not #{start.inspect}"
        end
        @first = start.to_i
        if @first + @count - 1 > Spec::U32
          raise SpecError, "#{@count} Source ASes from #{start} run past #{Spec::U32} (RFC 6514 section 4.2)"
        end
        @afi = @spec_afi || IANA::AFI::IPv4
      end

      # A Multicast Group, stepped by one, which decides the AFI, with a
      # Multicast Source of the same family.
      def read_group(start)
        a = address(start, 'a Multicast Group')
        @first, @family = a.to_i, a.family
        check_range(a, start)
        if @source && IPAddr.new(@source).ipv4? != a.ipv4?
          raise SpecError, "source #{@source} and the group #{start} are not of one family"
        end
        @afi = a.ipv4? ? IANA::AFI::IPv4 : IANA::AFI::IPv6
      end

      def address(start, what)
        if start.include?('/')
          raise SpecError, "a route type #{@type} start is #{what}, an address and not a prefix: #{start}"
        end
        IPAddr.new(start)
      rescue IPAddr::Error => e
        raise SpecError, "a route type #{@type} start is #{what}: #{e.message}"
      end

      def check_range(a, start)
        bits = a.ipv4? ? 32 : 128
        return if @first + @count - 1 <= 2**bits - 1
        raise SpecError, "#{@count} addresses from #{start} run past the end of the address space"
      end

      def mp_nlris(batch) ; batch ; end
    end
  end
end
