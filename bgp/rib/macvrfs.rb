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

require 'ipaddr'
require 'bgp/rib/macvrf'
require 'bgp/rib/evpn_table'

module BGP
  module Rib

    # An EVPN PE's MAC-VRFs, filled from the EVPN table and written into
    # vtep4rd: docs/design/evpn.md, pull request 2.
    #
    # **Import.** A MAC-VRF takes the winner of every key in the EVPN table
    # whose Route Targets it imports (RFC 7432 section 7.10). An imported
    # route is installed unless one of these holds, which show.evpn gives
    # as `invalid` (Receiving, steps 4 to 8):
    #
    # * `encapsulation`: no Encapsulation community naming VXLAN. RFC
    #   8365 section 5.1.3: without it "either MPLS encapsulation or a
    #   statically configured encapsulation is assumed", and the label
    #   field is then not a VNI.
    # * `vni`: the VNI is not the MAC-VRF's. vtep4rd sends a bridge
    #   domain's frames with its own VNI only.
    # * `esi`: a type 2 route with a non-zero ESI, a multihomed segment,
    #   which needs the Ethernet A-D routes first (section 9.2.2).
    # * `pmsi`: a type 3 route with no PMSI Tunnel attribute of type
    #   Ingress Replication.
    # * `own`: a route whose next hop, or type 3 tunnel, is this VTEP.
    #
    # **Type 3** gives a flood VTEP, the PMSI Tunnel Identifier, which RFC
    # 7432 section 11.2 sets "to a routable address of the PE". **Type 2**
    # gives a MAC behind its next hop, "the IPv4 or IPv6 address of the
    # advertising PE" (section 9.2.1). Where routes under two RDs bring one
    # MAC, section 15's rules pick one: see Macvrfs.prefer.
    #
    # **vtep4rd.** sync! reads what vtep4rd holds for each VNI (show.vnis,
    # show.macs) and sends it the difference (vni.flood.add and .del,
    # mac.add and .del). bgp4rd owns every flood VTEP of an `evpn` VNI,
    # since vtep4rd refuses a static `flood:` there (vtep4r #15), and
    # every MAC with `origin: api`: what it does not want, it deletes,
    # whoever added it. A MAC vtep4rd learned on a port is left alone;
    # who wins between it and a remote route is MAC Mobility, pull
    # request 3. Reading vtep4rd at each sync, rather than remembering
    # what was sent, puts back what a restarted vtep4rd lost.
    #
    # A VNI vtep4rd does not have, or has in `learn` mode, gets nothing,
    # and `errors` says why: show.status.
    #
    # vtep answers call(method, params) with the result, and raises on an
    # error answer or a lost connection: Daemon::VtepClient, or a
    # recorder in a test.
    class Macvrfs

      # The MAC a MAC-VRF installs behind a remote VTEP. route is the
      # EvpnRoute; since when this VTEP and sequence were chosen.
      Remote = Struct.new(:mac, :vtep, :seq, :sticky, :route, :since)

      Plan = Struct.new(:flood, :macs, :reasons)

      attr_reader :macvrfs, :address

      # address: this VTEP's address, local_address.
      def initialize(table:, macvrfs:, vtep:, address:, logger: nil, clock: -> { Time.now })
        @table, @macvrfs, @vtep, @address = table, macvrfs, vtep, address
        @logger, @clock = logger, clock
        @lock = Mutex.new
        @plans = {}     # vni => Plan
        @state = {}     # vni => [vtep_state, error]
        @seen = {}      # vni => { 'flood' => [...], 'local' => [rows] }
        @since = {}     # [vni, mac] => [vtep, seq, Time]
      end

      # RFC 1982 section 3.2, with SERIAL_BITS 32: true when sequence s1
      # is greater than s2. RFC 7432 section 15: "an implementation MUST
      # handle scenarios in which sequence number wraparound occurs". Two
      # values 2^31 apart are neither, "an undefined result".
      def self.serial_gt?(s1, s2)
        half = 1 << 31
        (s1 < s2 && s2 - s1 > half) || (s1 > s2 && s1 - s2 < half)
      end

      # True when Remote a is preferred to b for one MAC: section 7.7's
      # sticky MAC first ("the MAC address is static and cannot move"),
      # then section 15's higher sequence, then "the PE with the lowest IP
      # address".
      def self.prefer?(a, b)
        return a.sticky if a.sticky != b.sticky
        return true if serial_gt?(a.seq, b.seq)
        return false if serial_gt?(b.seq, a.seq)
        IPAddr.new(a.vtep).to_i < IPAddr.new(b.vtep).to_i
      end

      # Works out every MAC-VRF's flood VTEPs and remote MACs from the
      # table, then sends vtep4rd the difference.
      def sync!
        winners = @table.winners
        plans = @macvrfs.to_h { |m| [m.vni, plan(m, winners)] }
        @lock.synchronize { @plans = plans }
        state, seen = push(plans)
        @lock.synchronize { @state, @seen = state, seen }
        self
      end

      # For show.evpn: the VNIs of the MAC-VRFs that import the route of
      # key, and the first reason one of them does not install it.
      def route_state(key)
        @lock.synchronize do
          found = @plans.collect { |vni, p| [vni, p.reasons[key]] if p.reasons.key?(key) }.compact
          { 'imported' => found.collect(&:first), 'invalid' => found.collect(&:last).compact.first }
        end
      end

      # show.macvrfs: one row per MAC-VRF.
      def rows
        @lock.synchronize do
          @macvrfs.collect do |m|
            st, err = @state.fetch(m.vni, ['unknown', nil])
            seen = @seen.fetch(m.vni, {})
            { 'vni' => m.vni, 'rd' => m.rd, 'import' => m.import, 'export' => m.export,
              'vtep_state' => st, 'error' => err, 'flood' => seen.fetch('flood', []),
              'macs_local' => seen.fetch('local', []).size,
              'macs_remote' => (@plans[m.vni] ? @plans[m.vni].macs.size : 0), 'duplicates' => 0 }
          end
        end
      end

      # show.macvrf: one MAC-VRF's MACs, the remote ones this chose and the
      # local ones vtep4rd learned on its ports. nil for an unknown VNI.
      def mac_rows(vni)
        @lock.synchronize do
          return nil unless @macvrfs.any? { |m| m.vni == vni }
          remote = (@plans[vni] ? @plans[vni].macs.values : []).collect do |r|
            { 'mac' => r.mac, 'place' => 'remote', 'vtep' => r.vtep, 'port' => nil, 'seq' => r.seq,
              'sticky' => r.sticky, 'moves' => 0, 'duplicate' => false, 'since' => stamp(r.since) }
          end
          local = @seen.fetch(vni, {}).fetch('local', []).collect do |r|
            { 'mac' => r['mac'], 'place' => 'local', 'vtep' => nil, 'port' => r['port'], 'seq' => r['seq'],
              'sticky' => false, 'moves' => r['moves'], 'duplicate' => false, 'since' => nil }
          end
          (remote + local).sort_by { |r| [r['mac'], r['place']] }
        end
      end

      # What stops a MAC-VRF from working, one line each, for show.status.
      def errors
        @lock.synchronize do
          @macvrfs.collect { |m| (e = @state.dig(m.vni, 1)) && "vni #{m.vni}: #{e}" }.compact
        end
      end

      private

      def plan(m, winners)
        flood, macs, reasons = [], {}, {}
        now = @clock.call
        winners.each do |v|
          next unless [2, 3].include?(v.route_type) && m.imports?(v.route_targets)
          reason = invalid(v, m)
          reasons[v.decision_key] = reason
          next if reason
          if v.route_type == 3
            flood << v.pmsi_row['id']
          else
            seq, sticky = v.mobility || [0, false]
            r = Remote.new(v.mac, v.route.next_hop.to_s, seq, sticky, v, nil)
            macs[v.mac] = r if macs[v.mac].nil? || Macvrfs.prefer?(r, macs[v.mac])
          end
        end
        macs.each_value do |r|
          was = @since[[m.vni, r.mac]]
          @since[[m.vni, r.mac]] = was = [r.vtep, r.seq, now] unless was && was[0, 2] == [r.vtep, r.seq]
          r.since = was[2]
        end
        @since.delete_if { |(vni, mac), _| vni == m.vni && !macs.key?(mac) }
        Plan.new(flood.uniq.sort, macs, reasons)
      end

      def invalid(v, m)
        return 'encapsulation' unless v.encap == 'VXLAN'
        # Type 3's VNI is the PMSI Tunnel's label, so the tunnel first.
        p = v.pmsi_row if v.route_type == 3
        return 'pmsi' if v.route_type == 3 && !(p && p['type'] == 'ingress_replication')
        return 'vni' unless v.vni == m.vni
        return 'esi' if v.route_type == 2 && !v.esi.to_s.match?(/\A[0:]*\z/)
        return 'own' if (v.route_type == 3 ? p['id'] : v.route.next_hop.to_s) == @address
        nil
      end

      def push(plans)
        state, seen = {}, {}
        begin
          vnis = @vtep.call('show.vnis', {}).to_h { |r| [r['vni'], r] }
        rescue StandardError => e
          @macvrfs.each { |m| state[m.vni] = ['down', "vtep4rd: #{e.message}"] }
          return [state, seen]
        end
        @macvrfs.each do |m|
          row = vnis[m.vni]
          if row.nil?
            state[m.vni] = ['missing', 'vtep4rd has no such VNI']
          elsif row['mode'].to_s != 'evpn'
            state[m.vni] = ['mode', "vtep4rd has it in #{row['mode']} mode, not evpn"]
          else
            begin
              seen[m.vni] = push_vni(m, plans[m.vni], row)
              state[m.vni] = ['ok', nil]
            rescue StandardError => e
              state[m.vni] = ['error', "vtep4rd: #{e.message}"]
            end
          end
        end
        [state, seen]
      end

      # One VNI: the flood list, then the MACs.
      def push_vni(m, plan, row)
        have = Array(row['remote_vteps']).collect(&:to_s)
        (plan.flood - have).each { |v| order('vni.flood.add', 'vni' => m.vni, 'vtep' => v) }
        (have - plan.flood).each { |v| order('vni.flood.del', 'vni' => m.vni, 'vtep' => v) }
        macs = @vtep.call('show.macs', 'vni' => m.vni)
        local = macs.select { |r| r['type'].to_s == 'local' }
        api = macs.select { |r| r['origin'].to_s == 'api' }.to_h { |r| [r['mac'].to_s.downcase, r] }
        mine = local.collect { |r| r['mac'].to_s.downcase }
        plan.macs.each_value do |r|
          next if mine.include?(r.mac)
          a = api[r.mac]
          next if a && a['vtep'].to_s == r.vtep && a['seq'].to_i == r.seq
          order('mac.add', 'vni' => m.vni, 'mac' => r.mac, 'vtep' => r.vtep, 'seq' => r.seq)
        end
        (api.keys - plan.macs.keys).each { |mac| order('mac.del', 'vni' => m.vni, 'mac' => mac) }
        { 'flood' => plan.flood, 'local' => local }
      end

      def order(method, params)
        @logger&.call(:debug, "evpn: #{method} #{params.collect { |k, v| "#{k} #{v}" }.join(' ')}")
        @vtep.call(method, params)
      end

      def stamp(t)
        t && t.utc.strftime('%Y-%m-%dT%H:%M:%S.%LZ')
      end
    end

  end
end
