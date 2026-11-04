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
    # Flow specification rules, SAFI 133 (RFC 8955 for IPv4, RFC 8956 for
    # IPv6): `count` rules, the i-th matching the i-th destination prefix
    # from `start`, so a rule set N wide is one spec. The other match
    # components are optional and the same shape for every rule:
    #
    # * `source`, one prefix, fixed;
    # * `protocol`, the IP protocol or, for IPv6, the upper layer
    #   protocol, a value or a pattern on the route number;
    # * `destination_port`, a value or a pattern on the route number.
    #
    # Each is one `eq` match. A range of ports, and every component of
    # RFC 8955 section 4.2.2 past these four, is what `mp_reach` is for,
    # since nothing here reads it yet.
    #
    # **The components run on the route number, as `path_id` does**,
    # because a component is part of the NLRI and not of the attributes.
    # Their order in the rule is the type order RFC 8955 section 4.2
    # asks for.
    #
    # **The actions are attributes**, so they run on the group number:
    # `rate`, in bytes per second, is traffic-rate-bytes (RFC 8955
    # section 7.1) with its AS field written 0; `redirect`, `ADMIN:N`, is
    # rt-redirect (section 7.4) in the layout its administrator says;
    # `marking`, a DSCP, is traffic-marking (section 7.5). They join the
    # spec's own extended communities in one attribute.
    #
    # **No next hop.** RFC 8955 section 4: "the Length of the Next-Hop
    # Network Address MUST be set to 0". So the session's address a
    # Sender would fill in is dropped. A `next_hop` the spec gives
    # itself is sent, since building never validates.
    #
    # **A rule is as long as its components make it**, a port of 80 one
    # octet and 8080 two, so each rule is measured on its own rather
    # than by one length for the whole range. A withdrawal is the same
    # rule in MP_UNREACH_NLRI.
    class Flow_rules < Unicast
      SAFI = IANA::SAFI::FLOW_SPEC_RULES_1

      # What the AS field of a traffic-rate community holds.
      RATE_AS = 0

      def initialize(spec, sender = nil)
        seed = spec['seed']
        @protocol = compile(spec, 'protocol', seed)
        @port = compile(spec, 'destination_port', seed)
        @rate = compile(spec, 'rate', seed)
        @marking = compile(spec, 'marking', seed)
        @redirect = spec['redirect'] && Spec.distinguisher(spec['redirect'], 'redirect').at(0)
        @source = spec['source']
        @own_next_hop = spec['attributes'].key?('next_hop')
        check_source(spec)
        super
      end

      # The i-th rule's protocol and port, or nil when the spec has none.
      def protocol(i) ; @protocol && @protocol.at(i) ; end
      def destination_port(i) ; @port && @port.at(i) ; end

      # The i-th rule as the Hash `BGP::Flow_spec.new` reads.
      def rule(i)
        h = {}
        h[:path_id] = path_id(i) if add_path?
        if ipv4?
          h[:destination_prefix] = prefix(i)
          h[:source_prefix] = @source if @source
          h[:ip_protocol] = [[:eq, protocol(i)]] if @protocol
        else
          h[:destination_ipv6_prefix] = { :prefix => prefix(i) }
          h[:source_ipv6_prefix] = { :prefix => @source } if @source
          h[:upper_layer_protocol] = [[:eq, protocol(i)]] if @protocol
        end
        h[:destination_port] = [[:eq, destination_port(i)]] if @port
        h
      end

      def route(i) ; BGP::Flow_spec.new(rule(i)) ; end

      # The octets the rule takes in a message, its own length field and
      # Path Identifier included.
      def route_len(r) ; r.encode.bytesize ; end

      def route_row(i)
        r = { 'destination' => prefix(i) }
        r['source'] = @source if @source
        r['protocol'] = protocol(i) if @protocol
        r['destination_port'] = destination_port(i) if @port
        r['path_id'] = path_id(i) if add_path?
        r
      end

      def row_at(key)
        r = super
        r.delete('next_hop') unless @own_next_hop
        r['rate'] = @rate.at(key) if @rate
        r['redirect'] = @redirect if @redirect
        r['marking'] = @marking.at(key) if @marking
        r
      end

      private

      def compile(spec, k, seed)
        spec[k] && Vary.compile(spec[k], k, :int, max: Spec::FLOW_MAX[k], seed: seed)
      end

      def check_source(spec)
        return unless @source
        s, d = IPAddr.new(@source), (IPAddr.new(spec['start']) rescue nil)
        return if d.nil? || s.ipv4? == d.ipv4?
        raise SpecError, "source #{@source} and start #{spec['start']} are not of one family"
      end

      # The three actions join the spec's own extended communities, and
      # the route target a VPN rule's VRF adds, in one attribute.
      def build_attributes(a)
        acts = []
        acts << { :traffic_rate_bytes => [RATE_AS, a['rate']] } if a['rate']
        acts << { :redirect => a['redirect'] } if a['redirect']
        acts << { :traffic_marking => a['marking'] } if a['marking']
        return super if acts.empty?
        pa = super(a.reject { |k, _| k == 'extended_communities' })
        list = Array(a['extended_communities']).collect { |t| Daemon::CommunityKeys.extended_community_hash(t) }
        pa.add(BGP::Extended_communities.new(:extended_communities => list + acts))
      end

      def mp_nlris(batch) ; batch ; end
    end

    # The same rules under SAFI 134, each with a Route Distinguisher in
    # front (RFC 8955 section 8), stepped per VRF as VPN steps its RD.
    class Flow_rules_vpn < Flow_rules
      include PerVrf

      SAFI = IANA::SAFI::FLOW_SPEC_RULES_2

      def initialize(spec, sender = nil)
        read_vrfs(spec, 'flow_spec_vpn')
        super
      end

      def rule(i) ; super.merge(:rd => rd(vrf(i))) ; end
    end
  end
end
