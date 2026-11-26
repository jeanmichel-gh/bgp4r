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

    # Reflects EVPN routes between leaves: docs/design/evpn.md, pull
    # request 4, "The reflector".
    #
    # VpnReflector's rules, for AFI 25 / SAFI 70. The EVPN table keeps
    # every route it is sent, whatever its Route Targets, so this sends
    # on the one it chose for each key. RFC 4456 comes from
    # Rib::Export#for: section 6, a non-client's route to clients only
    # and a client's to everyone, never back to the sender; section 8,
    # ORIGINATOR_ID added if absent and our CLUSTER_ID prepended to
    # CLUSTER_LIST. The table's decision process already drops a route
    # that looped back.
    #
    # The UPDATE keeps the route's next hop, RD, labels and attributes:
    # the PMSI Tunnel, MAC Mobility and Encapsulation communities go on as
    # they came, so a leaf floods to and sends to the leaf that sent the
    # route. RFC 7432 asks nothing more of a reflector. The NLRI is sent
    # without its Path Identifier, since nothing here negotiates ADD-PATH
    # for EVPN. Only internal, established sessions in the global table
    # that negotiated L2VPN EVPN get it.
    #
    # VpnReflector's shape: what each peer was sent is kept, and only the
    # difference goes. It runs on a thread of its own, poked by the EVPN
    # table and by each session that comes up.
    #
    # A refresh exports only the keys whose winner changed since the last
    # one: the table keeps the same EvpnRoute while nothing replaces it,
    # so what a peer was sent, or refused, is kept with the winner it was
    # built from. Exporting all of them on every poke cost 0.9 s of CPU a
    # refresh at 1000 routes (measured 2026-11-26), and a poke comes with
    # each UPDATE received.
    class EvpnReflector

      # What one peer was sent for one key: the UPDATE, its encoding to
      # compare, the NLRI to withdraw it with, and the winner it came from.
      Out = Struct.new(:key, :nlri, :update, :wire, :source)

      def initialize(speaker, evpn_table, export, logger: nil)
        @speaker = speaker
        @table = evpn_table
        @export = export
        @logger = logger
        @lock = Mutex.new
        @sent = {} # peer address => { decision key => Out }
        @refused = {} # peer address => { decision key => the winner Export refused }
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
        @lock.synchronize { forget(peer.address) }
        poke
      end

      # Sends every peer what changed. Public for the tests, which call it
      # with no worker.
      def refresh
        winners = @table.winners
        @lock.synchronize do
          @speaker.peers.each do |p|
            unless eligible?(p)
              forget(p.address)
              next
            end
            sync(p, winners, @sent[p.address] ||= {}, @refused[p.address] ||= {})
          end
        end
        self
      end

      # What peer is to be sent now, decision key => Out. Public for the
      # tests.
      def wanted(peer, winners = @table.winners)
        target = rib_peer(peer)
        winners.each_with_object({}) do |w, out|
          o = out_for(w, target)
          out[w.decision_key] = o if o
        end
      end

      # How many routes one peer was sent, for show.peers.
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
        log(:error, "evpn reflector: #{e.class}: #{e.message}")
        retry
      end

      # An internal, established session in the global table that
      # negotiated L2VPN EVPN.
      def eligible?(peer)
        peer.established? && !peer.vrf && !peer.ebgp? && BGP::Rib::EvpnTable.negotiated?(peer.session_info)
      end

      # The Rib::Peer Export reads: its address, for the client list and
      # split horizon, and its AS.
      def rib_peer(peer)
        n = peer.neighbor
        BGP::Rib::Peer.new(:address => peer.address, :remote_as => peer.remote_as,
                           :router_id => (n && n.rmt_bgp_id) || peer.address, :local_as => @speaker.my_as)
      end

      # The UPDATE for winner w to target, a Rib::Peer, or nil when Export
      # refuses it.
      def out_for(w, target)
        result = @export.for(w.route, target)
        return unless result.path_attribute
        nlri = w.nlri.dup
        nlri.path_id = nil
        pa = result.path_attribute
        pa << BGP::Mp_reach.new(:afi => 25, :safi => 70, :nexthop => [w.route.next_hop.to_s], :nlris => [nlri])
        u = BGP::Update.new(pa)
        Out.new(w.decision_key, nlri, u, u.encode, w)
      end

      def forget(address)
        @sent.delete(address)
        @refused.delete(address)
      end

      # Sends peer the difference from sent, and records it. A winner
      # already sent or refused is not exported again. Lock held.
      def sync(peer, winners, sent, refused)
        target = nil
        want = {}    # the keys peer is to have
        still = {}   # the refusals that hold: their winner still wins
        changed = []
        winners.each do |w|
          k = w.decision_key
          s = sent[k]
          if s && s.source.equal?(w)
            want[k] = true
          elsif refused[k].equal?(w)
            still[k] = w
          elsif (o = out_for(w, target ||= rib_peer(peer))).nil?
            still[k] = w
          else
            want[k] = true
            s && s.wire == o.wire ? s.source = w : changed << o
          end
        end
        refused.replace(still)
        gone = sent.keys.reject { |k| want.key?(k) }
        return if changed.empty? && gone.empty?
        gone.each do |key|
          o = sent.delete(key)
          peer.send_message(BGP::Update.new(BGP::Path_attribute.new(
            BGP::Mp_unreach.new(:afi => 25, :safi => 70, :nlris => [o.nlri]))))
        end
        changed.each do |o|
          peer.send_message(o.update)
          sent[o.key] = o
        end
        log(:info, "evpn reflector: #{changed.size} route(s) to #{peer.address}, #{gone.size} withdrawn")
      rescue StandardError => e
        log(:warn, "evpn reflector: sending to #{peer.address}: #{e.class}: #{e.message}")
      end

      def log(level, msg)
        @logger&.call(level, msg)
      end
    end

  end
end
