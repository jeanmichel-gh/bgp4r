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
    # Route Target membership, AFI 1 SAFI 132 (RFC 4684): `count` routes,
    # the i-th for the route target `start` with i added to its number,
    # so `65000:100` and a count of 3 is 65000:100, 65000:101 and
    # 65000:102. The administrator says which of RFC 4360's and RFC
    # 5668's three layouts it is, as for an RD.
    #
    # * `origin_as` is required, a value or a pattern on the route
    #   number, since section 4 puts it in the NLRI.
    # * `prefix_length` is 96 by default, the whole route target. 64 is
    #   section 4's own example, "all route target extended communities
    #   assigned by a given Global Administrator" for a two-octet AS
    #   target, and 32 is the origin AS alone. Any length builds and is
    #   sent, since building never validates; a length that cuts into
    #   the stepped number makes routes that are the same on the wire.
    # * `default: true` puts the zero-length default route target in
    #   front of the range, section 4's "willingness to receive all VPN
    #   route advertisements". So the spec makes `count` + 1 routes.
    #   **GoBGP 3.23.0 panics on the default followed by a second route
    #   it accepts**, which rt_constrain_gobgp_test.rb asserts; this
    #   sends it anyway.
    #
    # The NLRI is a prefix (section 4), so a route is as long as its
    # prefix length makes it and is measured. The next hop is the
    # session's, 4 or 16 octets read by length. A withdrawal is the same
    # NLRI in MP_UNREACH_NLRI.
    class Rt_constrain_routes < Unicast
      SAFI = IANA::SAFI::ROUTE_TARGET_CONSTRAINTS

      # Section 4: "a prefix of 0 to 96 bits".
      FULL = Rt_constrain::MAX_MLEN

      def initialize(spec, sender = nil)
        unless spec['origin_as']
          raise SpecError, 'an rt_constrain spec needs an origin_as, a value or a pattern (RFC 4684 section 4)'
        end
        if spec['afi'] && spec['afi'] != IANA::AFI::IPv4
          raise SpecError, "afi #{spec['afi']}: RFC 4684 section 4 gives route target membership AFI 1"
        end
        @origin = Vary.compile(spec['origin_as'], 'origin_as', :int, max: Spec::U32, seed: spec['seed'])
        @mlen = spec['prefix_length'] || FULL
        @default = spec['default'] == true
        super
      end

      def total ; @count + (@default ? 1 : 0) ; end

      # True for the route that is section 4's default route target.
      def default_route?(i) ; @default && i.zero? ; end

      # Route i's number in the range from `start`, counting from 0.
      def slot(i) ; @default ? i - 1 : i ; end

      def origin_as(i) ; @origin.at(slot(i)) ; end

      # Route i's route target as ADMIN:N.
      def route_target(i) ; @rt.text(slot(i)) ; end

      def route(i)
        n = if default_route?(i)
              BGP::Rt_constrain.new
            else
              BGP::Rt_constrain.new(origin_as(i), @rt.at(slot(i)), @mlen)
            end
        n.path_id = path_id(i) if add_path?
        n
      end

      def route_len(r) ; r.encode.bytesize ; end

      def route_row(i)
        r = if default_route?(i)
              { 'default' => true }
            else
              { 'origin_as' => origin_as(i), 'route_target' => route_target(i), 'prefix_length' => @mlen }
            end
        r['path_id'] = path_id(i) if add_path?
        r
      end

      private

      def read_start(start)
        @rt = Spec.distinguisher(start, 'start')
        @rt.at(@count - 1)
        @afi = IANA::AFI::IPv4
      end

      def mp_nlris(batch) ; batch ; end
    end
  end
end
