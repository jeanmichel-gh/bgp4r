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

    # Sends a PE's VPN routes: docs/design/l3vpn-pe.md, pull request 3.
    #
    # RFC 4364 section 4.3.2: "When a PE router distributes a VPN-IPv4
    # route via BGP, it uses its own address as the "BGP next hop". This
    # address is encoded as a VPN-IPv4 address with an RD of 0. [...] It
    # also assigns and distributes an MPLS label." The routes are
    # Rib::L3vpn#exports: each exporting VRF's prefixes, its RD, its label
    # and its Export Targets as Route Target extended communities.
    #
    # **To every VPN peer, with no Route Target filtering at the sender**
    # (the spec's "Who filters: the receiver"): every Established session
    # whose two OPENs carried AFI 1 / SAFI 128 (section 4.3.4). A session
    # that did not gets none. A route reflector's work is pull request 6.
    #
    # **IPv6, pull request 5.** A VRF's IPv6 prefixes go as AFI 2 / SAFI
    # 128, under the same RD, label and Route Targets, to the sessions
    # that negotiated that family (RFC 4659 section 3.4). The next hop is
    # local_address IPv4-mapped, with RD 0: section 3.2.1.2, "an
    # IPv4-mapped IPv6 address containing the IPv4 address of the
    # advertising BGP speaker".
    #
    # LinkStateProducer's shape: keep what was sent; on each refresh send
    # the new and changed routes and withdraw the gone ones; send a
    # session that comes up the whole set. A withdrawal carries RFC 8277
    # section 2.4's Compatibility field, 0x800000.
    class VpnExporter

      Sent = Struct.new(:export, :since)

      # The most NLRI per UPDATE, well under the 4096-octet message.
      PER_UPDATE = 100

      def initialize(speaker, logger: nil)
        @speaker = speaker
        @logger = logger
        @lock = Mutex.new
        @sent = {} # [rd, prefix] => Sent
      end

      # exports: Rib::L3vpn#exports now. Sends the difference.
      def refresh(exports)
        @lock.synchronize do
          now = exports.to_h { |e| [e.key, e] }
          changed = now.values.reject { |e| (s = @sent[e.key]) && s.export == e }
          gone = (@sent.keys - now.keys).collect { |k| @sent.delete(k).export }
          at = Time.now
          changed.each { |e| @sent[e.key] = Sent.new(e, at) }
          unless changed.empty? && gone.empty?
            log(:info, "l3vpn: #{changed.size} VPN route(s) to announce, #{gone.size} to withdraw")
            @speaker.peers.each { |p| send_to(p, changed, gone) }
          end
          [changed, gone]
        end
      end

      # A session came up: send it every route of the families it takes.
      def session_up(peer)
        @lock.synchronize { send_to(peer, @sent.values.collect(&:export), []) }
      end

      # A route refresh for one VPN family, RFC 2918 section 4: what this
      # PE sent of that AFI, again. bgp/daemon/refresh.rb.
      def resend(peer, afi)
        @lock.synchronize { send_to(peer, @sent.values.collect(&:export).select { |e| afi(e) == afi }, []) }
      end

      def size ; @lock.synchronize { @sent.size } ; end

      # What this PE sent, as show.vpn rows with peer nil. The AS_PATH
      # and ORIGIN are the ones the UPDATE to an internal peer carries:
      # a CE's, or empty and IGP. The text is As_path#as_path's, as in a
      # received row.
      def rows
        nh = next_hop_text
        @lock.synchronize do
          @sent.values.collect do |s|
            e = s.export
            { 'rd' => e.rd, 'prefix' => e.prefix, 'path_id' => nil, 'peer' => nil, 'next_hop' => nh,
              'labels' => [e.label], 'route_targets' => e.route_targets, 'soo' => e.soo,
              'as_path' => BGP::As_path.new(*Array(e.as_path)).as_path,
              'origin' => e.origin || 0, 'local_pref' => 100, 'med' => nil, 'originator_id' => nil, 'cluster_list' => [],
              'best' => true, 'reason' => 'local', 'vrf' => e.vrf,
              'since' => s.since.utc.strftime('%Y-%m-%dT%H:%M:%S.%LZ') }
          end
        end
      end

      # How many routes peer was sent, per family, as VpnTable#counts
      # answers: every route of a family the established session
      # negotiated, since each goes to every such session.
      def sent_counts(peer)
        ok = afis(peer)
        @lock.synchronize do
          @sent.each_value.with_object(Hash.new(0)) do |s, h|
            a = afi(s.export)
            h[a == 2 ? 'vpn-ipv6' : 'vpn-ipv4'] += 1 if ok.include?(a)
          end
        end
      end

      # The UPDATEs for one peer: the withdrawals, then one MP_REACH_NLRI
      # per VRF, since its Route Targets apply to every NLRI beside them.
      # Public for the tests, which read what a peer would be sent.
      #
      # One UPDATE carries one MP_REACH_NLRI, so IPv4 and IPv6 go apart.
      def updates(peer, announced, withdrawn)
        list = []
        withdrawn.group_by { |e| afi(e) }.each do |afi, es|
          es.each_slice(PER_UPDATE) do |c|
            nlris = c.collect { |e| { :prefix => e.prefix, :rd => rd(e.rd), :compatibility => '800000' } }
            list << BGP::Update.new(BGP::Path_attribute.new(BGP::Mp_unreach.new(:afi => afi, :safi => 128, :nlris => nlris)))
          end
        end
        # A CE's routes (pull request 7) carry their own AS_PATH, ORIGIN
        # and Site of Origin, so they group by those too.
        announced.group_by { |e| [e.vrf, afi(e), e.as_path, e.origin, e.soo] }.each do |(_, afi), es|
          nh = next_hop(peer, afi)
          es.each_slice(PER_UPDATE) do |c|
            nlris = c.collect { |e| { :prefix => e.prefix, :rd => rd(e.rd), :label => e.label } }
            list << BGP::Update.new(path_attribute(peer, afi, nh, nlris, c.first))
          end
        end
        list
      end

      private

      # The VPN families an established session negotiated, as AFIs.
      def afis(peer)
        return [] unless peer.established?
        BGP::Rib::VpnTable.families(peer.session_info).collect(&:first)
      end

      def afi(export) ; export.prefix.include?(':') ? 2 : 1 ; end

      # What one session takes of these: only its negotiated families.
      def send_to(peer, announced, withdrawn)
        ok = afis(peer)
        return if ok.empty?
        announced = announced.select { |e| ok.include?(afi(e)) }
        withdrawn = withdrawn.select { |e| ok.include?(afi(e)) }
        return if announced.empty? && withdrawn.empty?
        updates(peer, announced, withdrawn).each { |u| peer.send_message(u) }
      rescue StandardError => e
        log(:warn, "l3vpn: sending to #{peer.address}: #{e.class}: #{e.message}")
      end

      # RFC 4271 section 5.1.2: empty AS_PATH toward an internal peer, our
      # AS toward an external one; LOCAL_PREF to an internal peer only.
      #
      # A CE route keeps the CE's AS_PATH and ORIGIN; ours are empty and
      # IGP. Its Site of Origin rides beside the Route Targets as a Route
      # Origin extended community (RFC 4360 section 5).
      def path_attribute(peer, afi, nh, nlris, export)
        path = Array(export.as_path)
        path = [@speaker.my_as] + path if peer.ebgp?
        attrs = [BGP::Origin.new(export.origin || 0), BGP::As_path.new(*path)]
        attrs << BGP::Local_pref.new(100) unless peer.ebgp?
        attrs << BGP::Mp_reach.new(:afi => afi, :safi => 128, :nexthop => [nh], :nlris => nlris)
        rts = export.route_targets.collect { |t| BGP::Route_target.new(*rd(t)) }
        rts << BGP::Route_origin.new(*rd(export.soo)) if export.soo
        attrs << BGP::Extended_communities.new(*rts) unless rts.empty?
        BGP::Path_attribute.new(*attrs)
      end

      # The PE's own address: local_address, its loopback, which the IGP
      # carries and the far PE has a label to; else this session's. For
      # AFI 2 an IPv4 address is IPv4-mapped (RFC 4659 section 3.2.1.2);
      # the codec puts RD 0 before it.
      def next_hop(peer, afi = 1)
        nh = (@speaker.local_address || peer.local_ip).to_s
        afi == 2 && !nh.include?(':') ? "::ffff:#{nh}" : nh
      end

      def next_hop_text
        @speaker.local_address.to_s
      end

      # "65000:1" or "10.255.0.1:7" as the [admin, assigned] pair BGP::Rd
      # and BGP::Route_target take: an IPv4 administrator stays a String.
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
