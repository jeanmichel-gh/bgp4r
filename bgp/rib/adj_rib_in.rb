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

    # The routes one peer has sent us, as received, before import policy
    # (RFC 4271 section 3.2). A route is keyed by prefix and path ID, so with
    # add-path (RFC 7911) one prefix can hold several paths.
    class AdjRibIn
      attr_reader :peer

      def initialize(peer)
        @peer = peer
        @routes = {} # prefix => { path_id => route }
        @size = 0
        @stale = {}  # [prefix, path_id] => reason, for the routes marked stale
      end

      # Stores route. A route already there with the same key is replaced:
      # an announcement implicitly withdraws the previous one (RFC 4271
      # section 3.1). Returns the replaced route, or nil.
      def announce(route)
        raise ArgumentError, "route from #{route.peer} given to the Adj-RIB-In of #{@peer}" unless route.peer == @peer
        paths = (@routes[route.prefix] ||= {})
        old = paths[route.path_id]
        @size += 1 unless old
        paths[route.path_id] = route
        @stale.delete([route.prefix, route.path_id])
        old
      end

      # Removes the route for prefix and path_id. Returns it, or nil if there
      # was none: withdrawing an unknown route is not an error.
      def withdraw(prefix, path_id=nil)
        prefix = Route.normalize(prefix)
        paths = @routes[prefix] or return nil
        path_id = path_id.nil? ? nil : Integer(path_id)
        old = paths.delete(path_id)
        @stale.delete([prefix, path_id])
        @routes.delete(prefix) if paths.empty?
        @size -= 1 if old
        old
      end

      # Removes every route, as when the session goes down. Returns them.
      def flush
        all = routes
        @routes.clear
        @stale.clear
        @size = 0
        all
      end

      # Marks stale every route the block chooses, with reason: 'refresh'
      # after a BoRR (RFC 7313 section 4), 'restart' and 'long_lived' for
      # Graceful Restart later. A route announced again, or withdrawn, loses
      # its mark. Returns how many were marked.
      def mark_stale(reason)
        n = 0
        each do |r|
          next unless yield(r)
          @stale[[r.prefix, r.path_id]] = reason
          n += 1
        end
        n
      end

      # Removes every route still marked stale that the block chooses, as
      # an EoRR asks (RFC 7313 section 4). Returns them.
      def purge_stale
        gone = @stale.keys.filter_map { |prefix, path_id| self[prefix, path_id] }.select { |r| yield(r) }
        gone.each { |r| withdraw(r.prefix, r.path_id) }
        gone
      end

      # Every route marked stale, with its reason.
      def stale_routes ; @stale.filter_map { |(prefix, path_id), why| (r = self[prefix, path_id]) && [r, why] } ; end

      # Marks one route stored here, with reason.
      def mark(route, reason) ; @stale[[route.prefix, route.path_id]] = reason if self[route.prefix, route.path_id] ; end

      # The reason route is marked stale, or nil when it is fresh.
      def stale(prefix, path_id=nil)
        @stale[[Route.normalize(prefix), path_id.nil? ? nil : Integer(path_id)]]
      end

      def stale_size ; @stale.size ; end

      def [](prefix, path_id=nil)
        paths = @routes[Route.normalize(prefix)]
        paths && paths[path_id.nil? ? nil : Integer(path_id)]
      end

      # Every path this peer sent for prefix.
      def paths(prefix)
        (@routes[Route.normalize(prefix)] || {}).values
      end

      def prefixes ; @routes.keys ; end
      def routes ; @routes.values.flat_map(&:values) ; end
      def each(&block) ; routes.each(&block) ; end
      def size ; @size ; end
      def empty? ; @size == 0 ; end
    end

  end
end
