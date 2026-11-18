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

    # Reflects VPN routes between PEs: docs/design/l3vpn-pe.md, pull
    # request 6.
    #
    # RFC 4364 section 4.3.3: "it is advantageous to make use of BGP Route
    # Reflectors". The VPN table keeps every route it is sent, whatever its
    # Route Targets, so this sends on the one it chose for each [RD,
    # prefix]. The rules are RFC 4456's, from Rib::Export#for: section 6,
    # a non-client's route to clients only and a client's to everyone,
    # never back to the sender; section 8, ORIGINATOR_ID added if absent
    # and our CLUSTER_ID prepended to CLUSTER_LIST. The decision process
    # already drops a route that looped back (`originator_id_loop`,
    # `cluster_list_loop`).
    #
    # The UPDATE keeps the route's own next hop, RD and labels in its
    # MP_REACH_NLRI: RFC 4271 section 5.1.3, an internal peer's route keeps
    # its next hop, so the label the far PE gave still points at the PE
    # that gave it. Only internal, established, non-CE sessions that
    # negotiated the route's family get it; inter-AS is out of scope.
    #
    # VpnExporter's shape: what each peer was sent is kept, and only the
    # difference goes, a withdrawal carrying RFC 8277's Compatibility
    # field. It runs on a thread of its own, poked by the VPN table, so a
    # session's dispatch thread never waits on another session's send.
    class VpnReflector

      # What one peer was sent for one [RD, prefix]: its encoded attributes
      # and NLRI, to compare, and the AFI to withdraw it with.
      Out = Struct.new(:key, :afi, :update, :wire)

      def initialize(speaker, vpn_table, export, logger: nil)
        @speaker = speaker
        @table = vpn_table
        @export = export
        @logger = logger
        @lock = Mutex.new
        @sent = {} # peer address => { [rd, prefix] => Out }
        @queue = Queue.new
      end

      def start
        @worker = Thread.new { work }
        self
      end

      def stop
        @queue << :stop
        @worker&.join(5)
        self
      end

      # Something changed: the table, or a session. Pokes that arrive
      # while a refresh runs make one more, not one each.
      def poke
        @queue << :refresh
        self
      end

      # A session came up: it gets everything, on the next refresh.
      def session_up(peer)
        @lock.synchronize { @sent.delete(peer.address) }
        poke
      end

      # Sends every peer what changed. Public for the tests, which call it
      # with no worker.
      def refresh
        winners = @table.winners
        @lock.synchronize do
          @speaker.peers.each do |p|
            unless eligible?(p)
              @sent.delete(p.address)
              next
            end
            sync(p, winners, @sent[p.address] ||= {})
          end
        end
        self
      end

      # What peer is to be sent now, [rd, prefix] => Out. Public for the
      # tests.
      def wanted(peer, winners = @table.winners)
        families = BGP::Rib::VpnTable.families(peer.session_info).collect(&:first)
        target = rib_peer(peer)
        winners.each_with_object({}) do |w, out|
          afi = w.prefix.include?(':') ? 2 : 1
          next unless families.include?(afi)
          result = @export.for(w.route, target)
          next unless result.path_attribute
          pa = result.path_attribute
          pa << BGP::Mp_reach.new(:afi => afi, :safi => 128, :nexthop => [w.route.next_hop.to_s],
                                  :nlris => [{ :prefix => w.prefix, :rd => rd(w.rd), :label => w.labels }])
          u = BGP::Update.new(pa)
          out[[w.rd, w.prefix]] = Out.new([w.rd, w.prefix], afi, u, u.encode)
        end
      end

      def size(peer_address = nil)
        @lock.synchronize { peer_address ? (@sent[peer_address] || {}).size : @sent.values.sum(&:size) }
      end

      private

      def work
        loop do
          jobs = [@queue.pop]
          jobs << @queue.pop until @queue.empty?
          break if jobs.include?(:stop)
          refresh
        end
      rescue StandardError => e
        log(:error, "vpn reflector: #{e.class}: #{e.message}")
        retry
      end

      # An internal, established session in the global table.
      def eligible?(peer)
        peer.established? && !peer.vrf && !peer.ebgp? && !BGP::Rib::VpnTable.families(peer.session_info).empty?
      end

      # The Rib::Peer Export reads: its address, for the client list and
      # split horizon, and its AS.
      def rib_peer(peer)
        n = peer.neighbor
        BGP::Rib::Peer.new(:address => peer.address, :remote_as => peer.remote_as,
                           :router_id => (n && n.rmt_bgp_id) || peer.address, :local_as => @speaker.my_as)
      end

      # Sends peer the difference from sent, and records it. Lock held.
      def sync(peer, winners, sent)
        want = wanted(peer, winners)
        changed = want.values.reject { |o| (s = sent[o.key]) && s.wire == o.wire }
        gone = sent.keys - want.keys
        return if changed.empty? && gone.empty?
        gone.each do |key|
          o = sent.delete(key)
          rd_text, prefix = key
          nlri = { :prefix => prefix, :rd => rd(rd_text), :compatibility => '800000' }
          peer.send_message(BGP::Update.new(BGP::Path_attribute.new(
            BGP::Mp_unreach.new(:afi => o.afi, :safi => 128, :nlris => [nlri]))))
        end
        changed.each do |o|
          peer.send_message(o.update)
          sent[o.key] = o
        end
        log(:info, "vpn reflector: #{changed.size} route(s) to #{peer.address}, #{gone.size} withdrawn")
      rescue StandardError => e
        log(:warn, "vpn reflector: sending to #{peer.address}: #{e.class}: #{e.message}")
      end

      # "65000:1" or "10.255.0.1:7" as the [admin, assigned] pair BGP::Rd
      # takes, an IPv4 administrator kept as a String.
      def rd(text)
        admin, assigned = text.split(':', 2)
        [admin.include?('.') ? admin : Integer(admin), Integer(assigned)]
      end

      def log(level, msg)
        @logger&.call(level, msg)
      end
    end

  end
end
