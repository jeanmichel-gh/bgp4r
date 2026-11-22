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
    # Unreachability reports, docs/design/unreachability.md pull request
    # 4. `count` prefixes from `start`, as unicast steps them, each with
    # `reporters` Reporter TLVs:
    #
    # * `reporter`, an address, is the first reporter's Identifier; the
    #   r-th reporter of a route is that address plus r. 192.0.2.1 by
    #   default.
    # * `reporter_as`, `reason` and `timestamp` are a value or a pattern
    #   on the route number, the same for every reporter of a route.
    #   `reporter_as` is 64512 by default and `reason` 0. With no
    #   `timestamp` the Timestamp sub-TLV is left out, so the same spec
    #   gives the same octets every time; the drafts make it a SHOULD.
    # * ORIGIN is INCOMPLETE unless `attributes` says otherwise, which
    #   the drafts make a SHOULD for locally generated reports (SAFI
    #   section 4.6, EVPN section 4.10).
    #
    # `unreachability` is SAFI 81 (draft-tantsura-idr-unreachability-
    # safi-06), AFI 1 or 2 by `start`, with no next hop (Appendix B.1).
    # A withdrawal is the prefix alone (section 4.3.2).
    class Unreachability_routes < Unicast
      SAFI = IANA::SAFI::UNREACHABILITY_INFORMATION

      FIRST_REPORTER = '192.0.2.1'
      REPORTER_AS = 64_512

      # SAFI section 4.8's recommended limit.
      MAX_REPORTERS = BGP::Unreachability::MAX_REPORTERS

      def initialize(spec, sender = nil)
        @reporters = spec['reporters'] || 1
        if @reporters > max_reporters
          raise SpecError, "reporters #{@reporters}: at most #{max_reporters} (#{limit_reason})"
        end
        @first_reporter = begin
          IPAddr.new(spec['reporter'] || FIRST_REPORTER).to_i
        rescue IPAddr::Error
          raise SpecError, "reporter #{spec['reporter'].inspect} is not an IPv4 address, a BGP Identifier"
        end
        if @first_reporter + @reporters - 1 > Spec::U32
          raise SpecError, "#{@reporters} reporters from #{spec['reporter']} run past 255.255.255.255"
        end
        seed = spec['seed']
        @as = Vary.compile(spec.fetch('reporter_as', REPORTER_AS), 'reporter_as', :int, max: Spec::U32, seed: seed)
        @reason = Vary.compile(spec.fetch('reason', 0), 'reason', :int, max: 0xffff, seed: seed)
        @time = spec['timestamp'] && Vary.compile(spec['timestamp'], 'timestamp', :int, max: 2**64 - 1, seed: seed)
        super
      end

      def reporter_as(i) ; @as.at(slot(i)) ; end
      def reason(i) ; @reason.at(slot(i)) ; end
      def timestamp(i) ; @time && @time.at(slot(i)) ; end

      # The r-th reporter's Identifier, the same for every route.
      def reporter_id(r) ; IPAddr.new(@first_reporter + r, Socket::AF_INET).to_s ; end

      def reporter_tlvs(i)
        u = BGP::Unreachability
        Array.new(@reporters) do |r|
          subs = [reason_code_class.new(reason(i))]
          subs << u::Timestamp.new(timestamp(i)) if @time
          reporter_class.new(reporter_id(r), reporter_as(i), *subs)
        end
      end

      def route(i)
        n = BGP::Unreachability.new(prefix(i), *reporter_tlvs(i))
        n.path_id = path_id(i) if add_path?
        n
      end

      def route_len(r) ; r.encode.bytesize ; end

      def route_row(i)
        r = super.merge('reporters' => Array.new(@reporters) { |n| reporter_id(n) },
                        'reporter_as' => reporter_as(i), 'reason' => reason(i))
        r['timestamp'] = timestamp(i) if @time
        r
      end

      # **A withdrawal is shorter than the announcement**, since it
      # carries no reporters, so each item is the withdrawal NLRI itself
      # and is measured as one. Unicast's sizes every item by the
      # announcement, which is right for the families whose withdrawal
      # is the same NLRI.
      def withdrawals
        packer = withdraw_packer
        items = Enumerator.new do |y|
          total.times { |i| w = withdrawn(route(i)) ; y << [w, w.encode.bytesize] }
        end
        Enumerator.new do |out|
          first = true
          packer.each_batch(items) do |batch, octets|
            m = build_withdrawal(batch)
            measure(m, packer.size(octets)) if first
            first = false
            out << m
          end
        end
      end

      def withdrawal_for(i) ; build_withdrawal([withdrawn(route(i))]) ; end

      # The drafts' SHOULD, unless `attributes` sets an origin. SAFI 81
      # sends no next hop, so `expected` names none.
      def row(g)
        r = super
        r['origin'] = 2 unless @patterns.key?('origin')
        r.delete('next_hop') unless safi == IANA::SAFI::EVPN
        r
      end

      private

      def slot(i) ; i ; end

      def max_reporters ; MAX_REPORTERS ; end

      def limit_reason ; 'draft-tantsura-idr-unreachability-safi section 4.8' ; end

      def reporter_class ; BGP::Unreachability::Reporter ; end

      def reason_code_class ; BGP::Unreachability::Reason_code ; end

      def mp_nlris(batch) ; batch ; end

      # A withdrawal is the NLRI without its reporters (section 4.3.2).
      def withdrawn(n)
        w = BGP::Unreachability.new(n.prefix)
        w.path_id = n.path_id
        w
      end

      def mp_withdrawn_nlris(batch) ; batch ; end

      # SAFI 81 has no next hop, whatever the session's would be.
      def reach(_set, batch)
        BGP::Mp_reach.new(:afi => @afi, :safi => safi, :nlris => mp_nlris(batch))
      end
    end

    # The EVPN IP Prefix Unreachability route, type 254, provisional
    # (draft-tantsura-bess-evpn-unreachability-02): the same reports in
    # AFI 25 SAFI 70, under an `rd` stepped once per VRF as for `vpn`,
    # with `route_target` and `ethernet_tag` as `evpn` takes them. The
    # next hop is the session's, as the draft's Example 4 has one.
    #
    # The route's Length is one octet (RFC 7432 section 7), so the
    # reporters a route holds are what fit in 255 octets: 8 for IPv4 with
    # a Reason Code and a Timestamp, 7 for IPv6 (review note 3 in the
    # design).
    class Evpn_unreachability_routes < Unreachability_routes
      include PerVrf

      SAFI = IANA::SAFI::EVPN

      def initialize(spec, sender = nil)
        read_vrfs(spec, 'evpn_unreachability')
        @tag = spec['ethernet_tag'] && Vary.compile(spec['ethernet_tag'], 'ethernet_tag', :int,
                                                    max: 0xffffffff, seed: spec['seed'])
        @with_time = !spec['timestamp'].nil?
        @ipv6 = spec['start'].to_s.include?(':')
        super
      end

      def ethernet_tag(i) ; @tag ? @tag.at(slot(i)) : 0 ; end

      def route(i)
        r = BGP::Evpn::Ip_prefix_unreachability.new(rd(vrf(i)), nil, ethernet_tag(i), prefix(i),
                                                    reporter_tlvs(i))
        e = BGP::Evpn.new(r)
        e.path_id = path_id(i) if add_path?
        e
      end

      def route_row(i)
        super.merge('ethernet_tag' => ethernet_tag(i))
      end

      private

      def slot(i) ; i % @count ; end

      # 255 octets, less the fixed fields, over one reporter's size.
      def max_reporters
        fixed = BGP::Evpn::Ip_prefix_unreachability.fixed_size(@ipv6 ? 2 : 1)
        one = 3 + 8 + 5 + (@with_time ? 11 : 0)
        (BGP::Evpn::MAX_LEN - fixed) / one
      end

      def limit_reason ; "the one-octet EVPN Length, RFC 7432 section 7" ; end

      def reporter_class ; BGP::Unreachability::Evpn_reporter ; end

      def reason_code_class ; BGP::Unreachability::Evpn_reason_code ; end

      # The prefixes step as unicast's do; the family is L2VPN.
      def read_start(start)
        super
        @afi = IANA::AFI::L2VPN
      end

      # Section 4.5.2: the key fields without any Reporter TLVs.
      def withdrawn(e)
        r = e.route
        w = BGP::Evpn.new(BGP::Evpn::Ip_prefix_unreachability.new(r.rd, nil, r.ethernet_tag_id,
                                                                   r.ip_prefix))
        w.path_id = e.path_id
        w
      end

      def reach(set, batch)
        h = { :afi => @afi, :safi => safi, :nlris => mp_nlris(batch) }
        h[:nexthop] = [set.next_hop] if set.next_hop
        BGP::Mp_reach.new(h)
      end
    end
  end
end
