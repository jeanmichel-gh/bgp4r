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

    # Sends a PE's EVPN routes: docs/design/evpn.md, pull request 3,
    # "Exporting". The routes are Rib::Macvrfs#exports.
    #
    # * **Type 3**, one per MAC-VRF: its RD, Ethernet Tag 0, the
    #   originator local_address, the export Route Targets, the
    #   Encapsulation community VXLAN, and a PMSI Tunnel of type Ingress
    #   Replication with local_address as its identifier and the VNI as
    #   its label (RFC 8365 section 5.1.3). RFC 7432 section 11.2: the
    #   Leaf Information Required flag "MUST be set to zero".
    # * **Type 2**, one per local MAC: RD, ESI 0, Ethernet Tag 0, the MAC,
    #   no IP (decision 5), the VNI in Label1, the Route Targets, VXLAN,
    #   and a MAC Mobility community when the MAC has a sequence (section
    #   15).
    #
    # **Over MPLS** (docs/design/evpn-mpls.md, "Exporting"): Label1 is the
    # MAC-VRF's unicast label and the PMSI label its BUM label, each in
    # the field's high 20 bits, and no Encapsulation community is sent
    # (decision 6, RFC 8365 section 5.1.3: without one "either MPLS
    # encapsulation or a statically configured encapsulation is assumed").
    #
    # The next hop is local_address. EVPN routes go to every established
    # session whose two OPENs carried AFI 25 / SAFI 70 (Exporting, step 4).
    #
    # VpnExporter's shape: keep what was sent; on each refresh send the
    # new and changed routes and withdraw the gone ones; send a session
    # that comes up the whole set.
    class EvpnExporter

      Sent = Struct.new(:export, :since)

      # The most NLRI per UPDATE, well under the 4096-octet message.
      PER_UPDATE = 100

      def initialize(speaker, logger: nil)
        @speaker = speaker
        @logger = logger
        @lock = Mutex.new
        @sent = {} # Export#key => Sent
      end

      # exports: Rib::Macvrfs#exports now. Sends the difference.
      def refresh(exports)
        @lock.synchronize do
          now = exports.to_h { |e| [e.key, e] }
          changed = now.values.reject { |e| (s = @sent[e.key]) && s.export == e }
          gone = (@sent.keys - now.keys).collect { |k| @sent.delete(k).export }
          at = Time.now
          changed.each { |e| @sent[e.key] = Sent.new(e, at) }
          unless changed.empty? && gone.empty?
            @logger&.call(:info, "evpn: #{changed.size} EVPN route(s) to announce, #{gone.size} to withdraw")
            @speaker.peers.each { |p| send_to(p, changed, gone) }
          end
          [changed, gone]
        end
      end

      # A session came up: send it every route.
      def session_up(peer)
        @lock.synchronize { send_to(peer, @sent.values.collect(&:export), []) }
      end

      def size ; @lock.synchronize { @sent.size } ; end

      # How many routes peer was sent: all of them, to a session that
      # negotiated EVPN.
      def sent_count(peer)
        ok?(peer) ? size : 0
      end

      # What this PE sends, as show.evpn rows with peer nil and reason
      # `local`.
      def rows
        nh = (@speaker.local_address || @speaker.router_id).to_s
        @lock.synchronize do
          @sent.values.collect do |s|
            e = s.export
            { 'rd' => e.rd, 'route_type' => e.route_type, 'eth_tag' => 0, 'mac' => e.mac, 'ip' => nil,
              'originator' => nh, 'esi' => (e.route_type == 2 ? '00:00:00:00:00:00:00:00:00:00' : nil),
              'vni' => (mpls?(e) ? nil : e.vni), 'label' => (e.label if mpls?(e)),
              'path_id' => nil, 'peer' => nil, 'next_hop' => nh,
              'route_targets' => e.route_targets, 'encap' => (mpls?(e) ? nil : 'VXLAN'), 'seq' => e.seq,
              'sticky' => (e.route_type == 2 ? false : nil),
              'pmsi' => (e.route_type == 3 ? { 'type' => 'ingress_replication', 'id' => nh } : nil),
              'as_path' => '', 'origin' => 0, 'local_pref' => 100, 'med' => nil, 'originator_id' => nil,
              'cluster_list' => [], 'best' => true, 'reason' => 'local',
              'since' => s.since.utc.strftime('%Y-%m-%dT%H:%M:%S.%LZ') }
          end
        end
      end

      # The UPDATEs for one peer: the withdrawals, then one MP_REACH_NLRI
      # per MAC-VRF, type and sequence, since the attributes beside them
      # apply to every NLRI. Public for the tests.
      def updates(peer, announced, withdrawn)
        list = []
        withdrawn.each_slice(PER_UPDATE) do |c|
          mp = BGP::Mp_unreach.new(:afi => 25, :safi => 70, :nlris => c.collect { |e| nlri(e) })
          list << BGP::Update.new(BGP::Path_attribute.new(mp))
        end
        nh = next_hop(peer)
        announced.group_by { |e| [e.vni, e.route_type, e.seq, e.encapsulation] }.each_value do |es|
          es.each_slice(PER_UPDATE) do |c|
            list << BGP::Update.new(path_attribute(peer, nh, c))
          end
        end
        list
      end

      private

      def mpls?(e)
        e.encapsulation == 'mpls'
      end

      def ok?(peer)
        peer.established? && BGP::Rib::EvpnTable.negotiated?(peer.session_info)
      end

      def send_to(peer, announced, withdrawn)
        return unless ok?(peer)
        return if announced.empty? && withdrawn.empty?
        updates(peer, announced, withdrawn).each { |u| peer.send_message(u) }
      rescue StandardError => e
        @logger&.call(:warn, "evpn: sending to #{peer.address}: #{e.class}: #{e.message}")
      end

      # The VNI as Label1's three fields, the whole 24 bits (RFC 8365
      # section 5.1.3).
      def label1(vni)
        { :label => vni >> 4, :exp => (vni >> 1) & 7, :bottom => vni & 1 }
      end

      def nlri(e)
        if e.route_type == 3
          { :inclusive_multicast => { :rd => rd(e.rd), :ethernet_tag_id => 0, :ip => originator } }
        else
          # Over MPLS, the label in the high 20 bits and the bottom of stack
          # bit set, as BGP::Label writes a label by default.
          l1 = mpls?(e) ? { :label => e.label } : label1(e.vni)
          { :mac_ip_advertisement => { :rd => rd(e.rd), :ethernet_tag_id => 0, :mac => e.mac,
                                       :label1 => l1 } }
        end
      end

      # RFC 4271 section 5.1.2: empty AS_PATH toward an internal peer, our
      # AS toward an external one; LOCAL_PREF to an internal peer only.
      def path_attribute(peer, nh, exports)
        e = exports.first
        attrs = [BGP::Origin.new(0), BGP::As_path.new(*(peer.ebgp? ? [@speaker.my_as] : []))]
        attrs << BGP::Local_pref.new(100) unless peer.ebgp?
        attrs << BGP::Mp_reach.new(:afi => 25, :safi => 70, :nexthop => [nh], :nlris => exports.collect { |x| nlri(x) })
        ecs = e.route_targets.collect { |t| BGP::Route_target.new(*rd(t)) }
        ecs << BGP::Encapsulation.new(:vxlan) unless mpls?(e)
        ecs << BGP::Mac_mobility.new(sequence: e.seq) if e.route_type == 2 && e.seq
        attrs << BGP::Extended_communities.new(*ecs)
        if e.route_type == 3
          label = mpls?(e) ? { :label => e.label } : { :label_bits => e.vni }
          attrs << BGP::Pmsi_tunnel.new(:tunnel_type => :ingress_replication, :identifier => originator, **label)
        end
        BGP::Path_attribute.new(*attrs)
      end

      # Section 11.2: the PMSI Tunnel Identifier is "a routable address of
      # the PE", and section 9.2.1's next hop "the IPv4 or IPv6 address of
      # the advertising PE": local_address, else the router ID.
      def originator
        (@speaker.local_address || @speaker.router_id).to_s
      end

      def next_hop(peer)
        (@speaker.local_address || peer.local_ip).to_s
      end

      # "65000:1" or "10.255.0.1:7" as the [admin, assigned] pair.
      def rd(text)
        admin, assigned = text.split(':', 2)
        [admin.include?('.') ? admin : Integer(admin), Integer(assigned)]
      end
    end

  end
end
