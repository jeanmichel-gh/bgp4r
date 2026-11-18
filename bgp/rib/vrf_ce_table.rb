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
require 'bgp/rib/decision'
require 'bgp/rib/peer_adapter'

module BGP
  module Rib

    # The routes a PE learned from its CEs by eBGP, one table per VRF:
    # docs/design/l3vpn-pe.md, pull request 7, "The design", step 2.
    #
    # RFC 4364 section 7 has the PE learn a site's routes by eBGP, and
    # they belong to the site's VRF, not to the speaker's global table. A
    # PeerAdapter reads the CE's UPDATEs, as it does any session's, and
    # this table is its sink: per VRF, per CE, the routes it sent, and one
    # decision per prefix across that VRF's CEs. A route holding our AS
    # in its AS_PATH is passed over (`as_loop`). A CE's routes go when its
    # session leaves Established (RFC 4271 section 6).
    class VrfCeTable

      # One CE route that won its prefix in its VRF. route is a Rib::Route;
      # soo the Site of Origin of the neighbor it came from, or nil.
      Best = Struct.new(:vrf, :prefix, :route, :soo) do
        def peer ; route.peer.address ; end
      end

      def initialize(local_as:, router_id:)
        @decision = Decision.new(local_as: local_as, router_id: router_id)
        @lock = Mutex.new
        @in = Hash.new { |h, k| h[k] = {} }   # vrf => { ce address => { [prefix, path_id] => Route } }
        @soo = {}                             # ce address => Site of Origin text, or nil
        @listeners = []
      end

      # Calls block, with no argument, after every change, outside the lock.
      def on_change(&block)
        @lock.synchronize { @listeners << block }
        self
      end

      # Starts reading a CE session into vrf. soo: the neighbor's Site of
      # Origin, "65000:11", or nil. Answers the PeerAdapter to detach.
      def attach(neighbor, vrf, soo: nil)
        site(neighbor.remote_addr, soo)
        PeerAdapter.new(neighbor, Sink.new(self, vrf))
      end

      # The Site of Origin of the CE at address, "65000:11", or nil.
      def site(address, soo)
        @lock.synchronize { @soo[address] = soo }
        self
      end

      def detach(adapter)
        adapter.detach
        self
      end

      # ops is what PeerAdapter#operations answers, from CE address.
      def apply(vrf, address, ops)
        @lock.synchronize do
          h = @in[vrf][address] ||= {}
          ops.each do |op, *args|
            case op
            when :withdraw
              _peer, prefix, path_id = args
              h.delete([Route.normalize(prefix), path_id])
            when :announce
              r = args.first
              h[[r.prefix, r.path_id]] = r
            end
          end
        end
        changed
        self
      end

      # RFC 4271 section 6: that CE's session is gone, and so is what it
      # sent.
      def peer_down(vrf, address)
        gone = @lock.synchronize { @in[vrf].delete(address) }
        changed if gone
        self
      end

      # The best CE route of each prefix in vrf, as Best, sorted by prefix.
      # A prefix whose every route is passed over has none.
      def best(vrf)
        @lock.synchronize do
          by_prefix = @in[vrf].values.flat_map(&:values).group_by(&:prefix)
          by_prefix.filter_map do |prefix, routes|
            r = @decision.best(routes).best or next
            Best.new(vrf, prefix, r, @soo[r.peer.address])
          end.sort_by { |b| prefix_order(b.prefix) }
        end
      end

      def size(vrf = nil)
        @lock.synchronize do
          (vrf ? [@in[vrf]] : @in.values).sum { |by_ce| by_ce.values.sum(&:size) }
        end
      end

      # A route's AS numbers, nearest first, from its AS_PATH text: "65101
      # 65102" is [65101, 65102], "empty" is []. An AS_SET's braces are
      # read as its members.
      def self.as_numbers(route)
        route.as_path.to_s.scan(/\d+/).collect(&:to_i)
      end

      # A route's Site of Origin, the first Route Origin extended
      # community (RFC 4360 section 5) as "65000:11", or nil.
      def self.soo_of(route)
        pa = route.path_attribute
        return nil unless pa && pa.has?(BGP::Extended_communities)
        ro = pa[BGP::Extended_communities].find_all(BGP::Route_origin).first or return nil
        Array(ro.to_hash[:route_origin]).join(':')
      end

      private

      def changed
        @lock.synchronize { @listeners.dup }.each(&:call)
      end

      def prefix_order(prefix)
        ip = IPAddr.new(prefix)
        [ip.ipv4? ? 4 : 6, ip.to_i, ip.prefix]
      end

      # PeerAdapter's sink for one CE session: it hands over work items,
      # [:ops, ops, neighbor] and [:peer_down, peer], on the session's
      # dispatch thread, and they are applied at once.
      class Sink
        def initialize(table, vrf)
          @table, @vrf = table, vrf
        end

        def <<(item)
          case item
          in [:ops, ops, neighbor] then @table.apply(@vrf, neighbor.remote_addr, ops)
          in [:peer_down, peer] then @table.peer_down(@vrf, peer.address)
          else nil
          end
          self
        end
      end
    end

  end
end
