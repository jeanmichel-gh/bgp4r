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

require 'bgp/rib/route'

module BGP
  module Rib

    # The BGP decision process: picks the best of the routes to one prefix.
    #
    #   d = Decision.new(local_as: 65001, router_id: '1.1.1.1')
    #   result = d.best(routes)
    #   result.best        # the winning Route, or nil
    #   result.reason      # the step that decided it, e.g. :local_pref
    #   result.eliminated  # { route => step that removed it }
    #
    # It follows RFC 4271 section 9.1.2: routes that may not be used are set
    # aside first, then the one with the highest degree of preference wins,
    # and ties go through the elimination steps of section 9.1.2.2, with the
    # route reflection changes of RFC 4456 section 9.
    #
    # Each step removes routes from the whole set at once, as the RFC
    # describes, so the result does not depend on the order of the routes.
    #
    # LOCAL_PREF received from an eBGP peer must be ignored (RFC 4271
    # section 5.1.5). That is the import step's job, before routes get here:
    # Decision uses whatever LOCAL_PREF a route carries.
    class Decision

      DEFAULT_LOCAL_PREF = 100
      MAX_MED = 2**32 - 1

      # The tie breaking steps, in order (RFC 4271 section 9.1.2.2, RFC 4456
      # section 9). :path_id is ours: it orders add-path routes from one peer.
      STEPS = %i[
        local_pref as_path_length origin med ebgp_over_ibgp igp_cost
        router_id cluster_list_length peer_address path_id
      ].freeze

      # Why a route may not take part at all.
      INELIGIBLE = %i[next_hop_unreachable as_loop originator_id_loop cluster_list_loop].freeze

      # best: the winning Route, or nil. reason: the step that left only
      # best, :only_route, or :no_usable_route. eliminated: every other
      # route, mapped to the step or INELIGIBLE reason that removed it.
      Result = Struct.new(:best, :reason, :eliminated)

      attr_reader :local_as, :router_id, :cluster_id

      # local_as, router_id: ours.
      # cluster_id: ours as a route reflector; defaults to router_id (RFC 4456 section 7).
      # resolver: next_hop -> IGP cost (an Integer), or nil if unreachable.
      #   The default says every next hop is reachable at cost 0.
      # always_compare_med: compare MED across neighboring ASes too.
      # missing_med_worst: a route without MED gets the highest MED, not 0.
      def initialize(local_as:, router_id:, cluster_id: nil, resolver: nil,
                     default_local_pref: DEFAULT_LOCAL_PREF,
                     always_compare_med: false, missing_med_worst: false)
        @local_as = Integer(local_as)
        @router_id = IPAddr.new(router_id.to_s).to_s
        @cluster_id = cluster_id ? IPAddr.new(cluster_id.to_s).to_s : @router_id
        @resolver = resolver || ->(_next_hop) { 0 }
        @default_local_pref = Integer(default_local_pref)
        @always_compare_med = always_compare_med
        @missing_med_worst = missing_med_worst
      end

      # Why route may not be used, or nil if it may.
      def ineligible_reason(route)
        # RFC 4271 section 9.1.2: an unresolvable NEXT_HOP, or an AS loop.
        return :next_hop_unreachable if route.next_hop.nil? || igp_cost(route).nil?
        return :as_loop if route.as_path_include?(@local_as)
        # RFC 4456 section 8: a reflected route that came back to us.
        return :originator_id_loop if route.originator_id == @router_id
        return :cluster_list_loop if route.cluster_list.include?(@cluster_id)
        nil
      end

      # The best of routes, all for the same prefix. See Result.
      def best(routes)
        eliminated = {}
        candidates = []
        Array(routes).each do |r|
          why = ineligible_reason(r)
          why ? eliminated[r] = why : candidates << r
        end
        return Result.new(nil, :no_usable_route, eliminated) if candidates.empty?
        return Result.new(candidates.first, :only_route, eliminated) if candidates.size == 1
        STEPS.each do |step|
          kept = send("keep_by_#{step}", candidates)
          (candidates - kept).each { |r| eliminated[r] = step }
          candidates = kept
          return Result.new(candidates.first, step, eliminated) if candidates.size == 1
        end
        # Only identical routes are left: the same peer sent the same path
        # twice. Keep one, so the answer is still the same every time.
        winner = candidates.min_by(&:to_s)
        (candidates - [winner]).each { |r| eliminated[r] = :duplicate }
        Result.new(winner, :duplicate, eliminated)
      end

      # The degree of preference of RFC 4271 section 9.1.1: LOCAL_PREF, or
      # the default when the route has none.
      def degree_of_preference(route)
        route.local_pref || @default_local_pref
      end

      def igp_cost(route)
        @resolver.call(route.next_hop)
      end

      def med(route)
        route.med || (@missing_med_worst ? MAX_MED : 0)
      end

      private

      def keep_min(routes)
        values = routes.map { |r| [r, yield(r)] }
        min = values.map(&:last).min
        values.select { |_, v| v == min }.map(&:first)
      end

      # RFC 4271 section 9.1.2: highest degree of preference.
      def keep_by_local_pref(routes)
        keep_min(routes) { |r| -degree_of_preference(r) }
      end

      # 9.1.2.2 a): fewest ASes in AS_PATH.
      def keep_by_as_path_length(routes)
        keep_min(routes, &:as_path_length)
      end

      # 9.1.2.2 b): lowest ORIGIN. A route without ORIGIN counts as INCOMPLETE.
      def keep_by_origin(routes)
        keep_min(routes) { |r| r.origin || 2 }
      end

      # 9.1.2.2 c): remove a route when another route from the same
      # neighboring AS has a lower MED. Routes from different neighboring
      # ASes are not compared, unless always_compare_med is set.
      def keep_by_med(routes)
        return keep_min(routes) { |r| med(r) } if @always_compare_med
        lowest = Hash.new(MAX_MED + 1)
        routes.each { |r| lowest[r.neighbor_as] = [lowest[r.neighbor_as], med(r)].min }
        routes.select { |r| med(r) == lowest[r.neighbor_as] }
      end

      # 9.1.2.2 d): if any route came from an eBGP peer, drop the iBGP ones.
      def keep_by_ebgp_over_ibgp(routes)
        ebgp = routes.select { |r| r.peer.ebgp? }
        ebgp.empty? ? routes : ebgp
      end

      # 9.1.2.2 e): lowest interior cost to the NEXT_HOP.
      def keep_by_igp_cost(routes)
        keep_min(routes) { |r| igp_cost(r) }
      end

      # 9.1.2.2 f): lowest BGP Identifier, or ORIGINATOR_ID (RFC 4456 section 9).
      def keep_by_router_id(routes)
        keep_min(routes) { |r| IPAddr.new(r.router_id).to_i }
      end

      # RFC 4456 section 9: between f) and g), the shorter CLUSTER_LIST.
      def keep_by_cluster_list_length(routes)
        keep_min(routes) { |r| r.cluster_list.size }
      end

      # 9.1.2.2 g): lowest peer address. IPv4 sorts before IPv6.
      def keep_by_peer_address(routes)
        keep_min(routes) do |r|
          ip = IPAddr.new(r.peer.address)
          [ip.ipv4? ? 4 : 6, ip.to_i]
        end
      end

      # Add-path routes from one peer: the lowest path ID.
      def keep_by_path_id(routes)
        keep_min(routes) { |r| r.path_id || -1 }
      end
    end

  end
end
