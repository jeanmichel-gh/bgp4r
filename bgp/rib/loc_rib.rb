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

require 'bgp/rib/decision'

module BGP
  module Rib

    # The best route to each prefix (RFC 4271 section 3.2), with the
    # decision result that chose it.
    class LocRib

      # A change of best route. old or new is nil when a prefix appears or
      # goes away. reason is the decision step that chose new.
      Change = Struct.new(:prefix, :old, :new, :reason) do
        def type
          return :added if old.nil?
          return :withdrawn if new.nil?
          :replaced
        end
      end

      def initialize(decision)
        @decision = decision
        @results = {} # prefix => Decision::Result, only prefixes with a best route
      end

      # Runs the decision for prefix over candidates and stores the result.
      # Returns a Change, or nil when the best route is still the same path.
      def update(prefix, candidates)
        prefix = Route.normalize(prefix)
        old_result = @results[prefix]
        result = @decision.best(candidates)
        if result.best
          @results[prefix] = result
        else
          @results.delete(prefix)
        end
        old = old_result && old_result.best
        new = result.best
        return nil if old.nil? && new.nil?
        return nil if old && new && old.same_path?(new)
        Change.new(prefix, old, new, result.reason)
      end

      def best(prefix)
        r = @results[Route.normalize(prefix)]
        r && r.best
      end

      # The full Decision::Result for prefix, or nil when it has no best route.
      def result(prefix)
        @results[Route.normalize(prefix)]
      end

      def prefixes ; @results.keys ; end
      def routes ; @results.values.map(&:best) ; end
      def each ; @results.each { |prefix, r| yield prefix, r.best } ; end
      def size ; @results.size ; end
      def empty? ; @results.empty? ; end
    end

  end
end
