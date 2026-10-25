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

require 'bgp/rib/adj_rib_in'
require 'bgp/rib/loc_rib'

module BGP
  module Rib

    # The routing information bases of one BGP speaker, tied together:
    # an Adj-RIB-In per peer, import, the decision process and the Loc-RIB.
    #
    #   rib = BGP::Rib.new(local_as: 65001, router_id: '1.1.1.1')
    #   rib.on_change { |c| puts "#{c.type} #{c.prefix}" }
    #   rib.announce(route)
    #   rib.withdraw(peer, '192.168.1.0/24')
    #   rib.peer_down(peer)
    #
    # Every change returns the Loc-RIB changes it caused, and also hands them
    # to the on_change blocks. Only the prefixes a change touches are decided
    # again.
    #
    # A Table is not thread safe. Feed it from one thread.
    class Table
      attr_reader :decision, :loc_rib

      # import: a block that takes a Route and returns the Route to use, a
      #   changed copy, or nil to reject it. It runs after the built in rules.
      # Other options go to Decision.new: resolver, default_local_pref,
      #   always_compare_med, missing_med_worst, cluster_id.
      def initialize(local_as:, router_id:, import: nil, **decision_options)
        @decision = Decision.new(local_as: local_as, router_id: router_id, **decision_options)
        @loc_rib = LocRib.new(@decision)
        @import = import
        @adj_in = {}     # peer => AdjRibIn
        @imported = {}   # prefix => { [peer, path_id] => imported route }
        @listeners = []
      end

      def local_as ; @decision.local_as ; end
      def router_id ; @decision.router_id ; end

      def on_change(&block)
        @listeners << block
        self
      end

      # The Adj-RIB-In of peer, created on first use.
      def adj_rib_in(peer)
        @adj_in[peer] ||= AdjRibIn.new(peer)
      end

      def peers ; @adj_in.keys ; end

      # Stores route in its peer's Adj-RIB-In, imports it, and decides its
      # prefix again. Returns the Loc-RIB changes, an empty Array or one.
      def announce(route)
        adj_rib_in(route.peer).announce(route)
        set_imported(route.prefix, route.peer, route.path_id, import(route))
        decide(route.prefix)
      end

      # Removes a route peer sent. Returns the Loc-RIB changes.
      def withdraw(peer, prefix, path_id=nil)
        old = adj_rib_in(peer).withdraw(prefix, path_id)
        return [] unless old
        set_imported(old.prefix, peer, old.path_id, nil)
        decide(old.prefix)
      end

      # Removes every route from peer, as when its session goes down
      # (RFC 4271 section 9.1.2). Returns the Loc-RIB changes.
      def peer_down(peer)
        ribin = @adj_in[peer] or return []
        removed = ribin.flush
        removed.each { |r| set_imported(r.prefix, peer, r.path_id, nil) }
        removed.map(&:prefix).uniq.flat_map { |prefix| decide(prefix) }
      end

      # Runs import and the decision again for every route, for example
      # after the import block or the resolver changed what it returns.
      def refresh
        @imported.clear
        @adj_in.each_value do |ribin|
          ribin.each { |r| set_imported(r.prefix, r.peer, r.path_id, import(r)) }
        end
        (@loc_rib.prefixes | @imported.keys).flat_map { |prefix| decide(prefix) }
      end

      # The imported routes to prefix that the decision chooses from.
      def candidates(prefix)
        (@imported[Route.normalize(prefix)] || {}).values
      end

      def best(prefix) ; @loc_rib.best(prefix) ; end
      def result(prefix) ; @loc_rib.result(prefix) ; end

      private

      # RFC 4271 section 5.1.5: LOCAL_PREF received from an eBGP peer must be
      # ignored. Then the import block, if any.
      def import(route)
        if route.peer.ebgp? && route.path_attribute.has?(Local_pref)
          pa = Path_attribute.new(route.path_attribute.encode(true), true)
          pa.delete(Local_pref)
          route = route.with_path_attribute(pa)
        end
        @import ? @import.call(route) : route
      end

      def set_imported(prefix, peer, path_id, route)
        paths = (@imported[prefix] ||= {})
        if route
          paths[[peer, path_id]] = route
        else
          paths.delete([peer, path_id])
          @imported.delete(prefix) if paths.empty?
        end
      end

      def decide(prefix)
        change = @loc_rib.update(prefix, candidates(prefix))
        return [] unless change
        @listeners.each { |l| l.call(change) }
        [change]
      end
    end

    # Shortcut for Table.new.
    def self.new(**options)
      Table.new(**options)
    end

  end
end
