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

    # An EVPN PE's MAC-VRFs: docs/design/evpn.md, pull requests 2 and 3.
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
    # * `pmsi`: a type 3 route with no PMSI Tunnel attribute of type
    #   Ingress Replication. Checked before the VNI, which is its label.
    # * `vni`: the VNI is not the MAC-VRF's. vtep4rd sends a bridge
    #   domain's frames with its own VNI only.
    # * `esi`: a type 2 route with a non-zero ESI, a multihomed segment,
    #   which needs the Ethernet A-D routes first (section 9.2.2).
    # * `own`: a route whose next hop, or type 3 tunnel, is this VTEP:
    #   ours, sent back by a reflector.
    #
    # **Over MPLS** (docs/design/evpn-mpls.md, "Receiving"): a route with
    # no Encapsulation community, or one naming MPLS, is taken, and one
    # naming VXLAN is `encapsulation`. There is no VNI to match: Label1
    # and the PMSI label are the remote PE's labels, read as 20 bits, and
    # one that is absent or reserved (0 to 15, RFC 3032 section 2.1) is
    # `label`, since vtep4rd could not push it.
    #
    # **Type 3** gives a flood VTEP, the PMSI Tunnel Identifier, which RFC
    # 7432 section 11.2 sets "to a routable address of the PE". **Type 2**
    # gives a MAC behind its next hop, "the IPv4 or IPv6 address of the
    # advertising PE" (section 9.2.1).
    #
    # **One place per MAC** (decision 4): local, on one of vtep4rd's
    # ports, or behind one remote VTEP. Among remote routes, sticky first,
    # then the higher sequence, then the lower address: Macvrfs.prefer?.
    # Between a local MAC and a remote route, RFC 7432 section 15 (see
    # decide). bgp4rd tells vtep4rd the result; vtep4rd keeps it.
    #
    # **Export** (pull request 3). A MAC-VRF whose VNI vtep4rd has in
    # `evpn` mode sends a type 3 route, and a type 2 route for each local
    # MAC it holds: `exports`, which Daemon::EvpnExporter sends.
    #
    # **vtep4rd.** sync! reads what vtep4rd holds for each VNI (show.vnis,
    # show.macs), decides, and sends it the difference. bgp4rd owns every
    # flood VTEP of an `evpn` VNI and every MAC with `origin: api`: what it
    # does not want, it deletes. A MAC vtep4rd learned on a port is
    # replaced only by a remote route that wins. When vtep4rd cannot be
    # reached, the last local MACs it gave are kept for `hold` seconds and
    # then dropped, and their routes withdrawn (Exporting, step 6).
    #
    # vtep answers call(method, params) with the result, and raises on an
    # error answer or a lost connection: Daemon::VtepClient, or a
    # recorder in a test. events, when given, is the speaker's
    # BGP::Events, for the `evpn` kind.
    class Macvrfs

      # A MAC behind a VTEP: a remote route, or this PE's own for a
      # comparison. route is the EvpnRoute, nil for ours.
      Remote = Struct.new(:mac, :vtep, :seq, :sticky, :route, :since, :label)

      # A route this PE sends (Exporting, steps 1 and 2). type 3 has no
      # mac; seq is nil for a type 2 route with no MAC Mobility community.
      # Over MPLS, encapsulation is 'mpls' and label the MAC-VRF's unicast
      # label for type 2, its BUM label for type 3.
      Export = Struct.new(:vni, :rd, :route_type, :mac, :seq, :route_targets, :encapsulation, :label) do
        def key ; [rd, route_type, mac] ; end
      end

      # A local MAC this PE advertises: its sequence, nil for none, and
      # since when.
      Adv = Struct.new(:seq, :since)

      # flood_labels: over MPLS, each flood VTEP's BUM label.
      Plan = Struct.new(:flood, :macs, :reasons, :flood_labels)

      KIND = BGP::Events.register_kind(:evpn)

      # RFC 7432 section 15.1: "with a default value of M = 180" and "a
      # default value of N = 5".
      MOVES = 5
      SECONDS = 180
      # Exporting, step 6: evpn: vtep_hold, 30 s by default.
      HOLD = 30

      attr_reader :macvrfs, :address, :moves_limit, :seconds, :hold, :seq_memory

      # address: this VTEP's address, local_address.
      def initialize(table:, macvrfs:, vtep:, address:, logger: nil, events: nil, clock: -> { Time.now },
                     moves: MOVES, seconds: SECONDS, hold: HOLD, seq_memory: nil)
        @table, @macvrfs, @vtep, @address = table, macvrfs, vtep, address
        @logger, @events, @clock = logger, events, clock
        @moves_limit, @seconds, @hold = moves, seconds, hold
        @seq_memory = seq_memory || seconds
        @lock = Mutex.new
        @plans = {}        # vni => Plan
        @state = {}        # vni => [vtep_state, error]
        @seen = {}         # vni => { 'flood' => [...], 'local' => [rows] }
        @installed = {}    # vni => { mac => Remote }, what vtep4rd is told
        @since = {}        # [vni, mac] => [vtep, seq, Time]
        @held = {}         # vni => [Time vtep4rd last answered, local rows]
        @adv = {}          # [vni, mac] => Adv
        @place = {}        # [vni, mac] => 'local' or a VTEP address
        @moved = Hash.new { |h, k| h[k] = [] } # [vni, mac] => times it moved
        @dup = {}          # [vni, mac] => Time marked duplicate
        @last_remote = {}  # [vni, mac] => the last remote sequence seen
        @gone = {}         # [vni, mac] => Time a MAC with a @last_remote was first found gone
        @alerted = {}      # [vni, mac] => true once a sticky MAC's local learn is logged
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

      # Reads vtep4rd, decides every MAC-VRF's flood VTEPs and MACs, sends
      # vtep4rd the difference, and works out what this PE exports.
      def sync!
        winners = @table.winners
        now = @clock.call
        vnis = begin
          @vtep.call('show.vnis', {}).to_h { |r| [r['vni'], r] }
        rescue StandardError => e
          e
        end
        @lock.synchronize do
          @macvrfs.each { |m| sync_vni(m, plan(m, winners, now), vnis, now) }
        end
        self
      end

      # The routes this PE sends now (Exporting, steps 1 and 2).
      def exports
        @lock.synchronize do
          @macvrfs.flat_map do |m|
            next [] unless exporting?(m.vni)
            labels = m.labels || {}
            [Export.new(m.vni, m.rd, 3, nil, nil, m.export, m.encapsulation, labels['bum'])] +
              @adv.select { |(v, _), _| v == m.vni }.collect do |(_, mac), a|
                Export.new(m.vni, m.rd, 2, mac, a.seq, m.export, m.encapsulation, labels['unicast'])
              end
          end
        end
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
            row = { 'vni' => m.vni, 'rd' => m.rd, 'import' => m.import, 'export' => m.export,
                    'vtep_state' => st, 'error' => err, 'flood' => seen.fetch('flood', []),
                    'macs_local' => seen.fetch('local', []).size,
                    'macs_remote' => @installed.fetch(m.vni, {}).size,
                    'duplicates' => @dup.count { |(v, _), _| v == m.vni },
                    'encapsulation' => m.encapsulation }
            next row unless m.mpls?
            row.merge('labels' => m.labels, 'flood_labels' => seen.fetch('flood_labels', {}))
          end
        end
      end

      # show.macvrf: one MAC-VRF's MACs, the remote ones vtep4rd is told,
      # the local ones it learned on its ports, and the duplicates. nil for
      # an unknown VNI.
      def mac_rows(vni)
        @lock.synchronize do
          return nil unless @macvrfs.any? { |m| m.vni == vni }
          now = @clock.call
          rows = @installed.fetch(vni, {}).values.collect do |r|
            extra = { 'vtep' => r.vtep, 'seq' => r.seq, 'sticky' => r.sticky, 'since' => stamp(r.since) }
            extra['label'] = r.label if r.label
            mac_row(vni, r.mac, 'remote', now, extra)
          end
          @seen.fetch(vni, {}).fetch('local', []).each do |r|
            mac = r['mac'].to_s.downcase
            a = @adv[[vni, mac]]
            rows << mac_row(vni, mac, 'local', now, 'port' => r['port'], 'seq' => a && a.seq,
                                                    'since' => stamp(a && a.since))
          end
          @dup.each_key do |(v, mac)|
            next unless v == vni && rows.none? { |r| r['mac'] == mac }
            rows << mac_row(vni, mac, 'none', now)
          end
          rows.sort_by { |r| [r['mac'], r['place']] }
        end
      end

      # What stops a MAC-VRF from working, one line each, for show.status.
      def errors
        @lock.synchronize do
          @macvrfs.collect { |m| (e = @state.dig(m.vni, 1)) && "vni #{m.vni}: #{e}" }.compact
        end
      end

      # evpn.clear_duplicate: section 15.1's "corrective action [...] by
      # the operator". The MAC's moves are forgotten and the next sync
      # handles it again. Raises ArgumentError when it is not marked.
      def clear_duplicate(vni, mac)
        mac = mac.to_s.downcase
        @lock.synchronize do
          raise ArgumentError, "vni #{vni}: #{mac} is not marked duplicate" unless @dup.delete([vni, mac])
          @moved.delete([vni, mac])
        end
        publish(:info, "mac #{mac} vni #{vni}: duplicate mark cleared", 'type' => 'cleared', 'vni' => vni, 'mac' => mac)
        { 'vni' => vni, 'mac' => mac, 'cleared' => true }
      end

      private

      def mac_row(vni, mac, place, now, extra = {})
        key = [vni, mac]
        { 'mac' => mac, 'place' => place, 'vtep' => nil, 'port' => nil, 'seq' => nil, 'sticky' => false,
          'moves' => @moved[key].count { |t| now - t < @seconds }, 'duplicate' => @dup.key?(key),
          'since' => nil }.merge(extra)
      end

      # Type 3 and the local MACs are sent while vtep4rd has the VNI, or
      # was last heard to have it less than `hold` seconds ago.
      def exporting?(vni)
        st = @state.dig(vni, 0)
        st == 'ok' || (%w[down error].include?(st) && @held[vni] && @clock.call - @held[vni][0] < @hold)
      end

      def plan(m, winners, now)
        flood, macs, reasons, labels = [], {}, {}, {}
        winners.each do |v|
          next unless [2, 3].include?(v.route_type) && m.imports?(v.route_targets)
          reason = invalid(v, m)
          reasons[v.decision_key] = reason
          next if reason
          if v.route_type == 3
            id = v.pmsi_row['id']
            flood << id
            labels[id] = v.label if m.mpls?
          else
            seq, sticky = v.mobility || [0, false]
            r = Remote.new(v.mac, v.route.next_hop.to_s, seq, sticky, v, nil, (v.label if m.mpls?))
            macs[v.mac] = r if macs[v.mac].nil? || Macvrfs.prefer?(r, macs[v.mac])
          end
        end
        @plans[m.vni] = Plan.new(flood.uniq.sort, macs, reasons, labels)
      end

      def invalid(v, m)
        if m.mpls?
          return 'encapsulation' unless v.encap.nil? || v.encap == 'MPLS'
        else
          return 'encapsulation' unless v.encap == 'VXLAN'
        end
        # Type 3's VNI or label is the PMSI Tunnel's, so the tunnel first.
        p = v.pmsi_row if v.route_type == 3
        return 'pmsi' if v.route_type == 3 && !(p && p['type'] == 'ingress_replication')
        if m.mpls?
          return 'label' unless v.label && v.label >= 16
        else
          return 'vni' unless v.vni == m.vni
        end
        return 'esi' if v.route_type == 2 && !v.esi.to_s.match?(/\A[0:]*\z/)
        return 'own' if (v.route_type == 3 ? p['id'] : v.route.next_hop.to_s) == @address
        nil
      end

      # One VNI: read, decide, send.
      def sync_vni(m, plan, vnis, now)
        if vnis.is_a?(Exception)
          return lost(m, plan, now, 'down', "vtep4rd: #{vnis.message}")
        end
        row = vnis[m.vni]
        if row.nil?
          return absent(m, plan, now, 'missing', 'vtep4rd has no such VNI')
        elsif row['mode'].to_s != 'evpn'
          return absent(m, plan, now, 'mode', "vtep4rd has it in #{row['mode']} mode, not evpn")
        elsif (row['encap'] || 'vxlan').to_s != m.encapsulation
          # A vtep4rd before EVPN over MPLS answers no encap: VXLAN.
          return absent(m, plan, now, 'encap', "vtep4rd has it as #{row['encap'] || 'vxlan'}, not #{m.encapsulation}")
        end
        begin
          macs = @vtep.call('show.macs', 'vni' => m.vni)
          local = macs.select { |r| r['type'].to_s == 'local' }
          api = macs.select { |r| r['origin'].to_s == 'api' }.to_h { |r| [r['mac'].to_s.downcase, r] }
          install = decide(m, plan, local, now)
          push(m, plan, row, api, install)
          @held[m.vni] = [now, local]
          @seen[m.vni] = { 'flood' => plan.flood, 'local' => local, 'flood_labels' => plan.flood_labels }
          @state[m.vni] = ['ok', nil]
        rescue StandardError => e
          lost(m, plan, now, 'error', "vtep4rd: #{e.message}")
        end
      end

      # vtep4rd cannot be reached: decide from the local MACs it last
      # gave, for `hold` seconds, then from none. Nothing is sent to it.
      def lost(m, plan, now, state, error)
        @state[m.vni] = [state, error]
        at, local = @held[m.vni]
        local = [] unless at && now - at < @hold
        decide(m, plan, local, now)
        @seen[m.vni] = { 'flood' => [], 'local' => local }
      end

      # vtep4rd answers but has no evpn VNI: no local MAC, nothing held.
      def absent(m, plan, now, state, error)
        @state[m.vni] = [state, error]
        @held.delete(m.vni)
        decide(m, plan, [], now)
        @seen[m.vni] = {}
      end

      # Every MAC's place, from the local MACs and the remote routes: RFC
      # 7432 section 15. Fills @adv, what this PE advertises, and answers
      # what vtep4rd is to hold behind remote VTEPs, { mac => Remote }.
      def decide(m, plan, local, now)
        vni = m.vni
        ports = local.to_h { |r| [r['mac'].to_s.downcase, r['port']] }
        install = {}
        macs = (ports.keys + plan.macs.keys + @adv.keys.select { |v, _| v == vni }.collect(&:last)).uniq
        macs.each do |mac|
          key = [vni, mac]
          # Section 15.1: "stop sending and processing any BGP MAC/IP
          # Advertisement routes for that MAC address".
          next if @dup.key?(key)
          r = plan.macs[mac]
          @last_remote[key] = r.seq if r
          ours = @adv[key]
          if ports.key?(mac)
            if ours
              me = Remote.new(mac, @address, ours.seq || 0, false)
              if r && Macvrfs.prefer?(r, me)
                # "A PE receiving a MAC/IP Advertisement route for a MAC
                # address with [...] a higher sequence number than that
                # which it had previously advertised withdraws its MAC/IP
                # Advertisement route"; with the same sequence, the lowest
                # IP address wins.
                @adv.delete(key)
                install[mac] = r
                moved(key, r.vtep, now)
              else
                moved(key, 'local', now)
              end
            elsif r && r.sticky
              # Section 15.2: "the PE MUST alert the operator".
              unless @alerted[key]
                @alerted[key] = true
                publish(:warn, "mac #{mac} vni #{vni}: learned on #{ports[mac]}, but #{r.vtep} holds it sticky",
                        'type' => 'sticky', 'vni' => vni, 'mac' => mac, 'port' => ports[mac], 'vtep' => r.vtep)
              end
              install[mac] = r
              moved(key, r.vtep, now)
            else
              # "with a sequence number one greater than the sequence
              # number in the MAC Mobility extended community attribute of
              # the received MAC/IP Advertisement route", 0 when it had
              # none; with none at all when advertised "for the first time".
              base = r ? r.seq : @last_remote[key]
              @adv[key] = Adv.new(base && (base + 1) & 0xffffffff, now)
              moved(key, 'local', now)
            end
          else
            @adv.delete(key)
            @alerted.delete(key)
            if r
              install[mac] = r
              moved(key, r.vtep, now)
            else
              @place.delete(key)
            end
          end
        end
        install.each_value do |r|
          was = @since[[vni, r.mac]]
          @since[[vni, r.mac]] = was = [r.vtep, r.seq, now] unless was && was[0, 2] == [r.vtep, r.seq]
          r.since = was[2]
        end
        @since.delete_if { |(v, mac), _| v == vni && !install.key?(mac) }
        forget(vni, ports, plan, now)
        @installed[vni] = install
      end

      # The last remote sequence of a MAC gone from every table (no route,
      # not learned here, not advertised, not duplicate) is forgotten after
      # `seq_memory` seconds, so a MAC that comes back is sent as if
      # advertised "for the first time". RFC 7432 section 15 sets no limit
      # on "previously received"; without one, a lab could claim a MAC
      # with a fixed sequence only once per bgp4rd. The default is
      # `duplicate: seconds`: a MAC gone that long has no move left to
      # count either.
      def forget(vni, ports, plan, now)
        @last_remote.each_key do |key|
          v, mac = key
          next unless v == vni
          # A MAC this PE advertises is on a port: decide deleted the rest.
          if ports.key?(mac) || plan.macs.key?(mac) || @dup.key?(key)
            @gone.delete(key)
          else
            @gone[key] ||= now
          end
        end
        @gone.delete_if do |key, at|
          next false unless now - at >= @seq_memory
          @last_remote.delete(key)
          true
        end
      end

      # Notes a MAC's place. A change of place is a move; N moves in M
      # seconds, the last a local learn, is a duplicate (section 15.1: "a
      # PE that detects a MAC mobility event via local learning starts an
      # M-second timer [...] and if it detects N MAC moves before the
      # timer expires [...] it concludes that a duplicate-MAC situation
      # has occurred").
      def moved(key, place, now)
        was = @place[key]
        @place[key] = place
        return if was.nil? || was == place
        vni, mac = key
        times = @moved[key]
        times << now
        times.reject! { |t| now - t >= @seconds }
        publish(:info, "mac #{mac} vni #{vni}: moved from #{was} to #{place}",
                'type' => 'moved', 'vni' => vni, 'mac' => mac, 'from' => was, 'to' => place)
        return unless place == 'local' && times.size >= @moves_limit
        @dup[key] = now
        @adv.delete(key)
        publish(:warn, "mac #{mac} vni #{vni}: #{times.size} moves in #{@seconds} s, marked duplicate " \
                       '(RFC 7432 section 15.1); evpn.clear_duplicate clears it',
                'type' => 'duplicate', 'vni' => vni, 'mac' => mac, 'moves' => times.size)
      end

      # Sends vtep4rd the difference for one VNI: over MPLS our two labels
      # first, then the flood list, then the MACs. Over MPLS a flood VTEP
      # or a MAC whose label changed is sent again. A duplicate MAC is left
      # as it is.
      def push(m, plan, row, api, install)
        have = Array(row['remote_vteps']).collect(&:to_s)
        if m.mpls? && row['labels'].to_h.transform_keys(&:to_s) != m.labels
          order('vni.labels', 'vni' => m.vni, 'unicast' => m.labels['unicast'], 'bum' => m.labels['bum'])
        end
        if m.mpls?
          had = row['flood_labels'].to_h.transform_keys(&:to_s)
          plan.flood.each do |v|
            next if had[v] == plan.flood_labels[v]
            order('vni.flood.add', 'vni' => m.vni, 'vtep' => v, 'label' => plan.flood_labels[v])
          end
        else
          (plan.flood - have).each { |v| order('vni.flood.add', 'vni' => m.vni, 'vtep' => v) }
        end
        (have - plan.flood).each { |v| order('vni.flood.del', 'vni' => m.vni, 'vtep' => v) }
        install.each_value do |r|
          a = api[r.mac]
          next if a && a['vtep'].to_s == r.vtep && a['seq'].to_i == r.seq && a['label'] == r.label
          params = { 'vni' => m.vni, 'mac' => r.mac, 'vtep' => r.vtep, 'seq' => r.seq }
          params['label'] = r.label if r.label
          order('mac.add', params)
        end
        (api.keys - install.keys).each do |mac|
          next if @dup.key?([m.vni, mac])
          order('mac.del', 'vni' => m.vni, 'mac' => mac)
        end
      end

      def order(method, params)
        @logger&.call(:debug, "evpn: #{method} #{params.collect { |k, v| "#{k} #{v}" }.join(' ')}")
        @vtep.call(method, params)
      end

      def publish(level, message, data)
        @logger&.call(level, "evpn: #{message}")
        @events&.publish(:kind => KIND, :level => level, :message => message, :data => data)
      end

      def stamp(t)
        t && t.utc.strftime('%Y-%m-%dT%H:%M:%S.%LZ')
      end
    end

  end
end
