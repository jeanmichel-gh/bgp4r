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

module BGP
  module Bmp

    # An UPDATE as routes, and a route as an UPDATE: what a station keeps
    # of a Route Monitoring (bgp/bmp/station.rb), and what bgp4rd keeps of
    # each peer's Adj-RIB-In to send a station its dump
    # (bgp/daemon/bmp.rb).
    module Routes

      module_function

      # A route without its labels: a withdrawal carries a Compatibility
      # field where the label was (RFC 8277 section 2.4, as
      # bgp/nlris/labeled.rb reads it), and withdraws the route all the
      # same.
      def key(afi, safi, nlri) ; [afi, safi, nlri.to_hash.reject { |k, _| %i[label labels compatibility].include?(k) }] ; end

      def nlris(field) ; field ? field.nlris : [] ; end

      def mp(update, klass)
        pa = update.path_attribute
        pa && pa.has?(klass) ? pa[klass] : nil
      end

      # [afi, safi, nlri] for each route the UPDATE withdraws.
      def withdrawn(u)
        list = nlris(u.withdrawn).collect { |n| [1, 1, n] }
        un = mp(u, Mp_unreach)
        list += Array(un.nlris).collect { |n| [un.afi, un.safi, n] } if un
        list
      end

      # [afi, safi, nlri, next hop or nil] for each route it announces.
      def announced(u)
        list = nlris(u.nlri).collect { |n| [1, 1, n, nil] }
        re = mp(u, Mp_reach)
        list += Array(re.nlris).collect { |n| [re.afi, re.safi, n, Array(re.nexthops).first&.to_s] } if re
        list
      end

      # RFC 4724 section 2: an UPDATE with nothing in it is IPv4
      # unicast's End-of-RIB, and one with only an empty MP_UNREACH_NLRI
      # is that family's. [afi, safi], or nil.
      def end_of_rib(u)
        pa = u.path_attribute
        attrs = pa ? pa.to_hash : {}
        return [1, 1] if attrs.empty? && nlris(u.nlri).empty? && nlris(u.withdrawn).empty?
        un = mp(u, Mp_unreach)
        return [un.afi, un.safi] if un && attrs.keys == [:mp_unreach] && Array(un.nlris).empty? && nlris(u.nlri).empty?
      end

      # The path attributes of an UPDATE without the two MP attributes,
      # whose NLRI are the routes themselves.
      def attributes(u)
        pa = u.path_attribute
        return nil unless pa
        Path_attribute.new(*pa.attributes.reject { |a| a.is_a?(Mp_reach) || a.is_a?(Mp_unreach) })
      end

      # One route as an UPDATE of its own: its attributes, and its NLRI
      # in the NLRI field for IPv4 unicast, or in an MP_REACH_NLRI with
      # the next hops it came with. mp is that MP_REACH_NLRI's hash.
      def update(afi, safi, nlri, attrs, mp = nil)
        if [afi, safi] == [1, 1] && mp.nil?
          h = nlri.to_hash
          return Update.new(attrs, Nlri.new(h[:path_id] ? { :path_id => h[:path_id], :nlri => h[:prefix] } : h[:prefix]))
        end
        reach = Mp_reach.new(mp.merge(:nlris => [nlri.to_hash]))
        Update.new(Path_attribute.new(*attrs.attributes, reach))
      end
    end
  end
end
