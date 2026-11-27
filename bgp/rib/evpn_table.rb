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
require 'bgp/rib/evpn_path'
require 'bgp/rib/decision'
require 'bgp/rib/peer_adapter'
require 'bgp/rib/vpn_table'

module BGP
  module Rib

    # The EVPN routes a speaker received, AFI 25 / SAFI 70, in a table of
    # their own beside the unicast RIB and the VPN table:
    # docs/design/evpn.md, decision 1, pull request 1. One table for both
    # types it keeps, 2 and 3.
    #
    # A route is keyed on its RD and RFC 7432's key fields (section 7.2
    # for type 2, 7.3 for type 3), with the Path Identifier: see
    # EvpnRoute.key_of. Each holds an EvpnPath, so the unicast decision
    # process picks the best path per key, as the VPN table does per [RD,
    # prefix]. MAC Mobility, which decides across RDs, is the MAC-VRFs'
    # (pull request 3), not this table's.
    #
    # Every route received is kept, whatever its Route Targets: a
    # reflector needs them all, and a MAC-VRF added later finds them.
    #
    # It reads a session only when both OPENs carried AFI 25 / SAFI 70
    # (RFC 4760 section 8). A session leaving Established removes every
    # route it sent, as RFC 4271 section 6 clears a closed connection's
    # Adj-RIB-In.
    class EvpnTable

      Entry = Struct.new(:evpn_route, :since, :stale)

      # local_as, router_id, cluster_id: ours, for the decision process.
      def initialize(local_as:, router_id:, cluster_id: nil)
        @decision = Decision.new(local_as: local_as, router_id: router_id, cluster_id: cluster_id)
        @lock = Mutex.new
        @in = {}      # peer address => { EvpnRoute#key => Entry }
        # EvpnRoute#decision_key => { [peer address, EvpnRoute#key] => Entry }:
        # the same entries by key, so decide reads a key's candidates
        # without going through every route held.
        @paths = {}
        @best = {}    # EvpnRoute#decision_key => Decision::Result
        @winner = {}  # EvpnRoute#decision_key => the EvpnRoute that won
        @other = Hash.new(0) # peer address => routes of other types announced
        @listeners = []
      end

      # True when both OPENs of a session carried L2VPN EVPN.
      def self.negotiated?(session_info)
        VpnTable.negotiated?(session_info, PeerAdapter::EVPN)
      end

      # Calls block, with no argument, after every change, on the
      # caller's thread and outside the table's lock.
      def on_change(&block)
        @lock.synchronize { @listeners << block }
        self
      end

      # The EvpnRoute that won each key, in key order.
      def winners
        @lock.synchronize { @winner.sort_by { |k, _| order(k) }.collect(&:last) }
      end

      # ops is what PeerAdapter.evpn_operations answers. peer is the
      # address of the session it came on.
      def apply(peer, ops, at = Time.now)
        @lock.synchronize do
          touched = []
          ops.each do |op, arg|
            case op
            when :withdraw
              drop(peer, arg)
              touched << arg[0..-2]
            when :announce
              put(peer, Entry.new(arg, at))
              touched << arg.decision_key
            when :other
              @other[peer] += 1
            end
          end
          touched.uniq.each { |k| decide(k) }
        end
        changed
        self
      end

      # RFC 4271 section 6: the session is gone, and so is what it sent.
      # keep: the families to retain, as [afi, safi], when the peer is
      # one we help through a graceful restart (RFC 4724 section 4.2):
      # their routes are kept and marked stale, 'restart', a route stale
      # already among them. Every other family goes, as RFC 4271 section
      # 6 has it. Empty, the default, is that rule for all of them.
      # Deleting what was stale before, RFC 4724's consecutive restart
      # rule when no N bit was exchanged (RFC 8538 section 4.1), is the
      # helper's, before this runs (GracefulRestart#down).
      def peer_down(peer, keep = [])
        @lock.synchronize do
          @other.delete(peer)
          h = @in[peer] || {}
          kept = keep.include?(PeerAdapter::EVPN)
          gone = h.select { |_, e| !kept }
          gone.each_key { |k| drop(peer, k) }
          h.each_value { |e| e.stale = 'restart' }
          gone.each_value.collect { |e| e.evpn_route.decision_key }.uniq.each { |k| decide(k) }
        end
        changed
        self
      end

      # Marks stale every route from peer, as a BoRR for L2VPN EVPN asks
      # (RFC 7313 section 4). Returns how many were marked.
      def mark_stale(peer, reason = 'refresh')
        @lock.synchronize { (@in[peer] || {}).each_value { |e| e.stale = reason }.size }
      end

      # How many routes from peer are marked stale.
      def stale_size(peer)
        @lock.synchronize { (@in[peer] || {}).each_value.count(&:stale) }
      end

      # Removes what is still stale from peer, as an EoRR asks. Returns how
      # many went.
      def purge_stale(peer)
        gone = @lock.synchronize do
          h = @in[peer] or next []
          stale = h.select { |_, e| e.stale }
          stale.each_key { |k| drop(peer, k) }
          stale.each_value.collect { |e| e.evpn_route.decision_key }.uniq.each { |k| decide(k) }
          stale
        end
        changed unless gone.empty?
        gone.size
      end

      # How many routes are held, from one peer or from all.
      def size(peer = nil)
        @lock.synchronize { peer ? (@in[peer] || {}).size : @in.values.sum(&:size) }
      end

      # The decision for one key, [rd, type, tag, ...], or nil.
      def best(key)
        @lock.synchronize { @best[key] }
      end

      # For the peer's `families` in `show.peers`: the routes held from it,
      # and the routes of other types it announced, which are not kept.
      def counts(peer)
        @lock.synchronize { { received: (@in[peer] || {}).size, other_types: @other[peer] } }
      end

      # Every route held, one row each, for `show.evpn`: sorted by RD,
      # type and key, then peer, so two tables holding the same routes
      # answer the same list. A block given each row's key answers more
      # columns for it: the MAC-VRFs' (pull request 2).
      def rows
        @lock.synchronize do
          @in.flat_map { |peer, h| h.values.collect { |e| row(peer, e) } }
        end.sort_by { |r| [*order(r['key']), r['peer'].to_s, r['path_id'].to_i] }.each do |r|
          key = r.delete('key')
          r.merge!(yield(key)) if block_given?
        end
      end

      # Starts reading what neighbor receives: one call per session.
      # retain: as VpnTable#attach's.
      def attach(neighbor, retain: nil)
        feed = Feed.new(self, neighbor)
        neighbor.add_observer(feed)
        neighbor.on_state_change do |now, was|
          peer_down(neighbor.remote_addr, retain ? retain.call : []) if was == :Established && now != was
        end
        feed
      end

      def detach(neighbor, feed)
        neighbor.delete_observer(feed)
        self
      end

      private

      # Runs the decision process again for one key, over every peer's
      # path to it. Called with the lock held.
      # Holds entry from peer, in both maps. Lock held.
      def put(peer, entry)
        v = entry.evpn_route
        (@in[peer] ||= {})[v.key] = entry
        (@paths[v.decision_key] ||= {})[[peer, v.key]] = entry
      end

      # Lets go of what peer sent under key, an EvpnRoute#key, if
      # anything. Lock held.
      def drop(peer, key)
        h = @in[peer] or return
        e = h.delete(key)
        @in.delete(peer) if h.empty?
        return unless e
        dk = e.evpn_route.decision_key
        paths = @paths[dk]
        paths.delete([peer, key])
        @paths.delete(dk) if paths.empty?
      end

      def decide(key)
        candidates = (@paths[key] || {}).values
        if candidates.empty?
          @best.delete(key)
          @winner.delete(key)
        else
          result = @decision.best(candidates.collect { |e| e.evpn_route.route })
          @best[key] = result
          winner = result.best && candidates.find { |e| e.evpn_route.route.equal?(result.best) }
          winner ? @winner[key] = winner.evpn_route : @winner.delete(key)
        end
      end

      def changed
        @lock.synchronize { @listeners.dup }.each(&:call)
      end

      def row(peer, e)
        v = e.evpn_route
        r = v.route
        result = @best[v.decision_key]
        # MAC Mobility goes with type 2 (RFC 7432 section 7.7), the PMSI
        # Tunnel with type 3 (section 11.2); one UPDATE may carry both
        # types under one set of attributes.
        seq, sticky = v.mobility if v.route_type == 2
        { 'key' => v.decision_key, 'rd' => v.rd, 'route_type' => v.route_type, 'eth_tag' => v.eth_tag,
          'mac' => v.mac, 'ip' => v.ip, 'originator' => v.originator, 'esi' => v.esi, 'vni' => v.vni, 'label' => v.label,
          'path_id' => v.path_id, 'peer' => peer, 'next_hop' => r.next_hop,
          'route_targets' => v.route_targets, 'encap' => v.encap, 'seq' => seq, 'sticky' => sticky,
          'pmsi' => (v.pmsi_row if v.route_type == 3), 'as_path' => r.as_path, 'origin' => r.origin, 'local_pref' => r.local_pref,
          'med' => r.med, 'originator_id' => r.originator_id, 'cluster_list' => r.cluster_list,
          'best' => !result.nil? && result.best.equal?(r),
          'reason' => result && result.best.equal?(r) ? result.reason.to_s : (result && result.eliminated[r]).to_s,
          'since' => e.since.utc.strftime('%Y-%m-%dT%H:%M:%S.%LZ') }.tap { |h| h['stale'] = e.stale if e.stale }
      end

      # RD, type, tag, then the MAC and IP or the originator, nil first.
      def order(key)
        key.collect { |f| f.nil? ? '' : f.is_a?(Integer) ? format('%010d', f) : f.to_s }
      end

      # The observer on one session, on its dispatch thread, as
      # VpnTable::Feed.
      class Feed
        def initialize(table, neighbor)
          @table, @neighbor = table, neighbor
        end

        def update(msg)
          return unless msg.is_a?(BGP::Update)
          return unless EvpnTable.negotiated?(@neighbor.session_info)
          peer = self.peer or return
          ops = PeerAdapter.evpn_operations(msg, peer)
          @table.apply(@neighbor.remote_addr, ops) unless ops.empty?
        end

        def peer
          as, id = @neighbor.rmt_as, @neighbor.rmt_bgp_id
          return nil unless as and id
          Peer.new(:address => @neighbor.remote_addr, :remote_as => as,
                   :router_id => id, :local_as => @neighbor.my_as)
        end
      end
    end

  end
end
