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
            eligible.each { |p| send_to(p, changed, gone) }
          end
          [changed, gone]
        end
      end

      # A session came up: send it every route, if it takes VPN-IPv4.
      def session_up(peer)
        @lock.synchronize do
          send_to(peer, @sent.values.collect(&:export), []) if eligible?(peer)
        end
      end

      def size ; @lock.synchronize { @sent.size } ; end

      # What this PE sent, as show.vpn rows with peer nil.
      def rows
        nh = next_hop_text
        @lock.synchronize do
          @sent.values.collect do |s|
            e = s.export
            { 'rd' => e.rd, 'prefix' => e.prefix, 'path_id' => nil, 'peer' => nil, 'next_hop' => nh,
              'labels' => [e.label], 'route_targets' => e.route_targets, 'as_path' => 'empty', 'origin' => 0,
              'local_pref' => 100, 'med' => nil, 'best' => true, 'reason' => 'local', 'vrf' => e.vrf,
              'since' => s.since.utc.strftime('%Y-%m-%dT%H:%M:%S.%LZ') }
          end
        end
      end

      # The UPDATEs for one peer: the withdrawals, then one MP_REACH_NLRI
      # per VRF, since its Route Targets apply to every NLRI beside them.
      # Public for the tests, which read what a peer would be sent.
      def updates(peer, announced, withdrawn)
        list = []
        withdrawn.each_slice(PER_UPDATE) do |c|
          nlris = c.collect { |e| { :prefix => e.prefix, :rd => rd(e.rd), :compatibility => '800000' } }
          list << BGP::Update.new(BGP::Path_attribute.new(BGP::Mp_unreach.new(:safi => 128, :nlris => nlris)))
        end
        nh = next_hop(peer)
        announced.group_by(&:vrf).each_value do |es|
          es.each_slice(PER_UPDATE) do |c|
            nlris = c.collect { |e| { :prefix => e.prefix, :rd => rd(e.rd), :label => e.label } }
            list << BGP::Update.new(path_attribute(peer, nh, nlris, c.first.route_targets))
          end
        end
        list
      end

      private

      def eligible
        @speaker.peers.select { |p| eligible?(p) }
      end

      def eligible?(peer)
        peer.established? && BGP::Rib::VpnTable.negotiated?(peer.session_info)
      end

      def send_to(peer, announced, withdrawn)
        updates(peer, announced, withdrawn).each { |u| peer.send_message(u) }
      rescue StandardError => e
        log(:warn, "l3vpn: sending to #{peer.address}: #{e.class}: #{e.message}")
      end

      # RFC 4271 section 5.1.2: empty AS_PATH toward an internal peer, our
      # AS toward an external one; LOCAL_PREF to an internal peer only.
      def path_attribute(peer, nh, nlris, route_targets)
        attrs = [BGP::Origin.new(0), BGP::As_path.new(*(peer.ebgp? ? [@speaker.my_as] : []))]
        attrs << BGP::Local_pref.new(100) unless peer.ebgp?
        attrs << BGP::Mp_reach.new(:safi => 128, :nexthop => [nh], :nlris => nlris)
        rts = route_targets.collect { |t| BGP::Route_target.new(*rd(t)) }
        attrs << BGP::Extended_communities.new(*rts) unless rts.empty?
        BGP::Path_attribute.new(*attrs)
      end

      # The PE's own address: local_address, its loopback, which the IGP
      # carries and the far PE has a label to; else this session's.
      def next_hop(peer)
        @speaker.local_address || peer.local_ip
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
