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

require 'bgp/rib'

module BGP
  module Daemon

    # Sends each CE its VRF's routes: docs/design/l3vpn-pe.md, pull
    # request 7, "The design", step 5.
    #
    # A CE neighbor (one with `vrf:`) gets what its VRF has installed in
    # the kernel, Rib::L3vpn#installed: the VPN routes it imported and the
    # other CEs' routes. Never a route that CE sent (split horizon), and
    # never one whose Site of Origin is the neighbor's own `soo:` (RFC
    # 4364 section 7: "Routing loops are prevented by use of the Site of
    # Origin attribute"). Our AS goes first in the AS_PATH (RFC 4271
    # section 5.1.2). With `as_override`, every occurrence of the CE's own
    # AS in the path is replaced by ours first, since every site may use
    # the same ASN and "it will be stripped out by the PE" (section 7).
    # NEXT_HOP is our address on that session.
    #
    # IPv4 only: an IPv6 route to a CE needs an IPv6 next hop on that
    # link, which comes later.
    #
    # VpnExporter's shape: what was sent per CE is kept, a refresh after
    # each VRF sync sends the difference, and a session coming up gets
    # everything.
    class VrfCeExporter

      # One route as a CE is sent it.
      Out = Struct.new(:prefix, :as_path, :origin)

      def initialize(speaker, l3vpn, logger: nil)
        @speaker = speaker
        @l3vpn = l3vpn
        @logger = logger
        @lock = Mutex.new
        @sent = {} # ce address => { prefix => Out }
      end

      # Sends every established CE what changed. A CE that is down forgets
      # what it was sent, so it gets everything when it comes back.
      def refresh
        @lock.synchronize do
          ce_peers.each do |p|
            unless p.established?
              @sent.delete(p.address)
              next
            end
            sync(p, @sent[p.address] ||= {})
          end
        end
      end

      # A CE session came up: send it its VRF.
      def session_up(peer)
        return unless peer.vrf
        @lock.synchronize { sync(peer, @sent[peer.address] = {}) }
      end

      # How many routes the CE at address was sent.
      def size(address)
        @lock.synchronize { (@sent[address] || {}).size }
      end

      # What peer is to be sent now, prefix => Out. Public for the tests.
      def routes_for(peer)
        my_as = @speaker.my_as
        @l3vpn.installed(peer.vrf).filter_map do |i|
          next if i.prefix.include?(':')
          next if i.ce == peer.address
          next if peer.soo && i.soo == peer.soo
          path = Rib::VrfCeTable.as_numbers(i.route)
          path = path.collect { |as| as == peer.remote_as ? my_as : as } if peer.as_override
          [i.prefix, Out.new(i.prefix, [my_as] + path, i.route.origin || 0)]
        end.to_h
      end

      # The UPDATEs for one CE: withdrawals, then the announcements grouped
      # by path and origin. Public for the tests.
      def updates(peer, announced, withdrawn)
        list = []
        withdrawn.each_slice(VpnExporter::PER_UPDATE) do |c|
          list << BGP::Update.new(BGP::Withdrawn.new(*c))
        end
        nh = peer.local_ip.to_s
        announced.group_by { |o| [o.as_path, o.origin] }.each do |(path, origin), outs|
          outs.each_slice(VpnExporter::PER_UPDATE) do |c|
            pa = BGP::Path_attribute.new(BGP::Origin.new(origin), BGP::As_path.new(*path), BGP::Next_hop.new(nh))
            list << BGP::Update.new(pa, BGP::Nlri.new(*c.collect(&:prefix)))
          end
        end
        list
      end

      private

      def ce_peers
        @speaker.peers.select(&:vrf)
      end

      # Sends peer the difference from sent, and records it. Lock held.
      def sync(peer, sent)
        want = routes_for(peer)
        changed = want.values.reject { |o| sent[o.prefix] == o }
        gone = sent.keys - want.keys
        return if changed.empty? && gone.empty?
        updates(peer, changed, gone).each { |u| peer.send_message(u) }
        gone.each { |prefix| sent.delete(prefix) }
        changed.each { |o| sent[o.prefix] = o }
        log(:info, "vrf #{peer.vrf}: #{changed.size} route(s) to CE #{peer.address}, #{gone.size} withdrawn")
      rescue StandardError => e
        log(:warn, "vrf #{peer.vrf}: sending to CE #{peer.address}: #{e.class}: #{e.message}")
      end

      def log(level, msg)
        @logger&.call(level, msg)
      end
    end

  end
end
