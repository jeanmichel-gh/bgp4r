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

require 'bgp4r'
require 'bgp/rib/route'

module BGP
  module Rib

    # One received VPN route. rd is the RD as text, "65000:1" or
    # "10.255.0.3:7"; labels the label stack, top first; route the
    # Rib::Route for the IPv4 prefix, its path attributes and its peer.
    VpnRoute = Struct.new(:rd, :labels, :route) do
      def prefix ; route.prefix ; end
      def path_id ; route.path_id ; end
      def peer ; route.peer ; end
      def key ; [rd, route.prefix, route.path_id] ; end

      # The Route Targets the route carries (RFC 4360 section 4), as
      # text, "65000:100", in the order received.
      def route_targets
        pa = route.path_attribute
        return [] unless pa.has?(BGP::Extended_communities)
        pa[BGP::Extended_communities].find_all(BGP::Route_target).collect { |rt|
          Array(rt.to_hash[:route_target]).join(':')
        }
      end

      # The Site of Origin, the first Route Origin extended community (RFC
      # 4364 section 7, RFC 4360 section 5), as "65000:11", or nil.
      def soo
        pa = route.path_attribute
        return nil unless pa.has?(BGP::Extended_communities)
        ro = pa[BGP::Extended_communities].find_all(BGP::Route_origin).first or return nil
        Array(ro.to_hash[:route_origin]).join(':')
      end
    end

  end
end
