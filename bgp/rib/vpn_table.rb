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
require 'bgp/rib/vpn_route'
require 'bgp/rib/decision'
require 'bgp/rib/peer_adapter'

module BGP
  module Rib

    # The VPN-IPv4 routes a speaker received, AFI 1 / SAFI 128 (RFC 4364
    # section 4.3.4), in a table of their own beside the unicast RIB, and
    # since pull request 5 the VPN-IPv6 ones, AFI 2 / SAFI 128 (RFC 4659),
    # each family read only on a session that negotiated it.
    #
    # docs/design/l3vpn-pe.md, decision 1, option A. A VPN route is keyed
    # on its Route Distinguisher and prefix: RFC 4364 section 4.1, "Since
    # VPN-IPv4 addresses and IPv4 addresses are different address
    # families, BGP never treats them as comparable addresses." Each one
    # holds a Rib::Route for its prefix and path attributes, so the
    # unicast decision process picks the best per [RD, prefix], as
    # section 4.3.1 says: "the BGP rules for route preference are used to
    # choose which VPN-IPv4 route is installed by BGP."
    #
    # Every route received is kept, per peer, in this table's Adj-RIB-In.
    # Filtering by Route Target, VRFs and the kernel come with the next
    # pull request (the spec's "Who filters: the receiver").
    #
    # It takes what a session sends only when that session negotiated
    # AFI 1 / SAFI 128, both ways (section 4.3.4: "they must use BGP
    # Capabilities Advertisement to ensure that they both are capable of
    # properly processing such NLRI"). A session leaving Established
    # removes every route it sent, as RFC 4271 section 6 clears a closed
    # connection's Adj-RIB-In.
    class VpnTable

      Entry = Struct.new(:vpn_route, :since, :stale)

      # local_as, router_id, cluster_id: ours, for the decision process.
      def initialize(local_as:, router_id:, cluster_id: nil)
        @decision = Decision.new(local_as: local_as, router_id: router_id, cluster_id: cluster_id)
        @lock = Mutex.new
        @in = {}   # peer address => { [rd, prefix, path_id] => Entry }
        @best = {} # [rd, prefix] => Decision::Result
        @winner = {} # [rd, prefix] => the VpnRoute that won
        @listeners = []
      end

      # Calls block, with no argument, after every change to the table:
      # an announcement, a withdrawal or a session's end. It runs on the
      # caller's thread, outside the table's lock, so a VRF can read the
      # table from it. docs/design/l3vpn-pe.md, pull request 2.
      def on_change(&block)
        @lock.synchronize { @listeners << block }
        self
      end

      # The VpnRoute that won each [RD, prefix], in RD then prefix order.
      def winners
        @lock.synchronize { @winner.sort_by { |(rd, prefix), _| [rd, prefix_order(prefix)] }.collect(&:last) }
      end

      # True when both OPENs of a session carried the Multiprotocol
      # capability for family, AFI 1 / SAFI 128 by default (RFC 4760
      # section 8; RFC 4659 section 3.4 for AFI 2).
      def self.negotiated?(session_info, family = PeerAdapter::VPN)
        return false unless session_info
        [session_info.speaker, session_info.peer].all? { |open| vpn?(open, family) }
      end

      # The VPN families a session negotiated, of PeerAdapter::VPN_FAMILIES.
      def self.families(session_info)
        PeerAdapter::VPN_FAMILIES.select { |f| negotiated?(session_info, f) }
      end

      def self.vpn?(open, family)
        return false unless open
        Array(open.opt_parms).flat_map { |p|
          p.respond_to?(:capabilities) ? Array(p.capabilities) : [p]
        }.any? { |c|
          c.is_a?(BGP::OPT_PARM::CAP::Mbgp) && [c.afi, c.safi] == family
        }
      end
      private_class_method :vpn?

      # ops is what PeerAdapter.vpn_operations answers. peer is the
      # address of the session it came on.
      def apply(peer, ops, at = Time.now)
        @lock.synchronize do
          touched = []
          ops.each do |op, *args|
            case op
            when :withdraw
              rd, prefix, path_id = args
              h = @in[peer]
              h&.delete([rd, Route.normalize(prefix), path_id])
              @in.delete(peer) if h && h.empty?
              touched << [rd, Route.normalize(prefix)]
            when :announce
              v = args.first
              (@in[peer] ||= {})[v.key] = Entry.new(v, at)
              touched << [v.rd, v.prefix]
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
      # their routes are kept and marked stale, 'restart', and a route
      # already stale goes, since "To deal with possible consecutive
      # restarts, a route (from the peer) previously marked as stale MUST
      # be deleted". Every other family goes, as RFC 4271 section 6 has
      # it. Empty, the default, is that rule for all of them.
      def peer_down(peer, keep = [])
        @lock.synchronize do
          h = @in[peer] || {}
          gone = h.select { |_, e| e.stale || !keep.include?([Table.afi_of(e.vpn_route.prefix), IANA::SAFI::MPLS_VPN_UNICAST]) }
          gone.each_key { |k| h.delete(k) }
          h.each_value { |e| e.stale = 'restart' }
          @in.delete(peer) if h.empty?
          gone.each_value { |e| decide([e.vpn_route.rd, e.vpn_route.prefix]) }
        end
        changed
        self
      end

      # Marks stale the routes of one AFI from peer, as a BoRR for
      # AFI/128 asks (RFC 7313 section 4). An announcement replaces the
      # Entry, and with it the mark. Returns how many were marked.
      def mark_stale(peer, afi, reason = 'refresh')
        @lock.synchronize do
          entries(peer, afi).each { |e| e.stale = reason }.size
        end
      end

      # Removes what is still stale of that AFI from peer, as an EoRR asks.
      # Returns how many went.
      def purge_stale(peer, afi)
        gone = @lock.synchronize do
          h = @in[peer] or next []
          stale = entries(peer, afi).select(&:stale)
          stale.each { |e| h.delete(e.vpn_route.key) }
          @in.delete(peer) if h.empty?
          stale.collect { |e| [e.vpn_route.rd, e.vpn_route.prefix] }.uniq.each { |k| decide(k) }
          stale
        end
        changed unless gone.empty?
        gone.size
      end

      # How many routes from peer are marked stale.
      def stale_size(peer)
        @lock.synchronize { (@in[peer] || {}).each_value.count(&:stale) }
      end

      # The reason peer's route to [rd, prefix] is stale, or nil. Any path.
      def stale(peer, rd, prefix)
        @lock.synchronize do
          prefix = Route.normalize(prefix)
          (@in[peer] || {}).each_value.find { |e| e.stale && e.vpn_route.rd == rd && e.vpn_route.prefix == prefix }&.stale
        end
      end

      # How many routes are held, from one peer or from all.
      def size(peer = nil)
        @lock.synchronize { peer ? (@in[peer] || {}).size : @in.values.sum(&:size) }
      end

      # The decision for one [RD, prefix], a Decision::Result, or nil.
      def best(rd, prefix)
        @lock.synchronize { @best[[rd, Route.normalize(prefix)]] }
      end

      # Every route held, one row each, for `show.vpn`: sorted by RD, then
      # prefix, then peer, so two tables holding the same routes answer
      # the same list.
      def rows
        @lock.synchronize do
          @in.flat_map { |peer, h| h.values.collect { |e| row(peer, e) } }
        end.sort_by { |r| [r['rd'], prefix_order(r['prefix']), r['peer'].to_s, r['path_id'].to_i] }
      end

      # How many routes one peer sent, per family: { 'vpn-ipv4' => n,
      # 'vpn-ipv6' => m }, a family with none left out. For the peer's
      # `families` in `show.peers`.
      def counts(peer)
        @lock.synchronize do
          (@in[peer] || {}).each_value.with_object(Hash.new(0)) do |e, h|
            h[e.vpn_route.prefix.include?(':') ? 'vpn-ipv6' : 'vpn-ipv4'] += 1
          end
        end
      end

      # Starts reading what neighbor receives: one call per session.
      # retain, when given, answers the families to keep when the session
      # ends (peer_down's keep).
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

      # peer's entries of one AFI. Called with the lock held.
      def entries(peer, afi)
        (@in[peer] || {}).values.select { |e| Table.afi_of(e.vpn_route.prefix) == afi }
      end

      # Runs the decision process again for one [RD, prefix], over every
      # peer's route to it. Called with the lock held.
      def decide(key)
        rd, prefix = key
        candidates = @in.values.flat_map { |h|
          h.values.select { |e| e.vpn_route.rd == rd && e.vpn_route.prefix == prefix }
        }.collect { |e| e.vpn_route.route }
        if candidates.empty?
          @best.delete(key)
          @winner.delete(key)
        else
          result = @decision.best(candidates)
          @best[key] = result
          winner = result.best && @in.values.flat_map(&:values).find { |e| e.vpn_route.route.equal?(result.best) }
          winner ? @winner[key] = winner.vpn_route : @winner.delete(key)
        end
      end

      def changed
        @lock.synchronize { @listeners.dup }.each(&:call)
      end

      def row(peer, e)
        v = e.vpn_route
        r = v.route
        result = @best[[v.rd, v.prefix]]
        { 'rd' => v.rd, 'prefix' => v.prefix, 'path_id' => v.path_id,
          'peer' => peer, 'next_hop' => r.next_hop, 'labels' => v.labels,
          'route_targets' => v.route_targets, 'soo' => v.soo, 'as_path' => r.as_path,
          'origin' => r.origin, 'local_pref' => r.local_pref, 'med' => r.med,
          'originator_id' => r.originator_id, 'cluster_list' => r.cluster_list,
          'best' => !result.nil? && result.best.equal?(r),
          'reason' => result && result.best.equal?(r) ? result.reason.to_s : (result && result.eliminated[r]).to_s,
          'since' => e.since.utc.strftime('%Y-%m-%dT%H:%M:%S.%LZ') }.tap { |h| h['stale'] = e.stale if e.stale }
      end

      def prefix_order(prefix)
        ip = IPAddr.new(prefix)
        [ip.ipv4? ? 4 : 6, ip.to_i, ip.prefix]
      end

      # The observer on one session. It runs on the session's dispatch
      # thread, as PeerAdapter does, so it does the least it can.
      class Feed
        def initialize(table, neighbor)
          @table, @neighbor = table, neighbor
        end

        def update(msg)
          return unless msg.is_a?(BGP::Update)
          families = VpnTable.families(@neighbor.session_info)
          return if families.empty?
          peer = self.peer or return
          ops = PeerAdapter.vpn_operations(msg, peer, families: families)
          @table.apply(@neighbor.remote_addr, ops) unless ops.empty?
        end

        # The Peer the session's OPEN names, as PeerAdapter builds it.
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
