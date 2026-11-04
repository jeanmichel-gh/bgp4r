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

require 'bgp/gen/spec'

module BGP
  class Gen
    # What a family with a Route Distinguisher shares: `vrfs` copies of
    # the range, one RD per VRF, and a route target per VRF that joins
    # that VRF's extended communities. VPN (SAFI 128 and 129) and VPN
    # flow spec (SAFI 134) include it.
    #
    # **Every VRF carries the same `count` routes**, because overlapping
    # address space is what an RD is for (RFC 4364 section 4.1). VRF i's
    # RD is `rd` with i added to its assigned number, and so is its
    # route target. A route target makes **each VRF an attribute set of
    # its own**, so a message never mixes two VRFs that have one.
    #
    # It sits between a generator and the class it inherits, so every
    # method here reaches the family's own through `super`.
    module PerVrf
      attr_reader :vrfs

      def total ; @count * @vrfs ; end

      # Which VRF route i is in, from 0.
      def vrf(i) ; i / @count ; end

      # The same range in every VRF.
      def prefix(i) ; super(i % @count) ; end

      # VRF v's RD, as the [admin, assigned] pair Rd.new takes.
      def rd(v) ; @rd.at(v) ; end

      def route_row(i) ; super.merge('rd' => @rd.text(vrf(i))) ; end

      def set_key(i) ; [i / @group, vrf(i)] ; end

      def row_at(key)
        g, v = key
        r = super(g)
        return r unless @rt
        r = r.dup
        r['extended_communities'] = Array(r['extended_communities']) + ["route_target:#{@rt.text(v)}"]
        r
      end

      private

      # Read before the generator's own initialize, which builds the
      # first set and so already needs them.
      def read_vrfs(spec, name)
        unless spec['rd']
          raise SpecError, "a #{name} spec needs an rd, ADMIN:N, stepped once per VRF (RFC 4364 section 4.2)"
        end
        @vrfs = spec['vrfs'] || 1
        @rd = Spec.distinguisher(spec['rd'], 'rd')
        @rt = spec['route_target'] && Spec.distinguisher(spec['route_target'], 'route_target')
      end
    end
  end
end
