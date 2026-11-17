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

require 'bgp/rib/decision'
require 'bgp/rib/vrf'
require 'bgp/rib/vpn_table'
require 'bgp/rib/vpn_transport'
require 'bgp/rib/vrf_fib'

module BGP
  module Rib

    # A PE's VRFs, filled from the VPN table and put in the kernel:
    # docs/design/l3vpn-pe.md, pull request 2.
    #
    # **Import.** RFC 4364 section 4.3.1: a VPN route "is only eligible for
    # installation in a particular VRF if there is some Route Target that
    # is both one of the route's Route Targets and one of the VRF's Import
    # Targets". Each VRF takes the winner of every [RD, prefix] it imports;
    # where two RDs bring one prefix, the decision process picks one of
    # them, with a resolver that makes a next hop with no transport
    # unreachable (`next_hop_unreachable`), the spec's decision 3.
    #
    # **The kernel.** The chosen route is installed in the VRF's table,
    # pushing the transport's labels and the VPN label (VrfFib). What is
    # installed is compared with what is wanted after every change, and
    # only the difference is sent. A VRF whose device is missing, or is
    # not a VRF on the configured table, gets nothing, and show.vrfs says
    # why: the lab makes the device (open question 2).
    #
    # **Export** (pull request 3). A VRF with an RD and Export Targets
    # sends its routes: its connected prefixes, read from its table, and
    # its configured `prefixes`. It gets one label, from the l3vpn:
    # labels block in VRF order, and a label route popping it into the
    # VRF, for a lookup there: section 4.3.2, "One may choose to have a
    # single label for an entire VRF". `exports` lists the VPN routes a
    # Daemon::VpnExporter sends.
    #
    # sync! does all of it, and is what a change to the VPN table, a
    # change to the kernel's routes, or a test calls.
    class L3vpn

      Want = Struct.new(:vpn_route, :hop, :stack, :argv)

      # One VPN route this PE sends: section 4.3.2, its own address as
      # next hop (added by the exporter), the VRF's RD, label and Export
      # Targets.
      Export = Struct.new(:vrf, :rd, :prefix, :label, :route_targets) do
        def key ; [rd, prefix] ; end
      end

      attr_reader :vrfs, :transport, :labels

      # labels: the l3vpn: labels block, { 'start' =>, 'size' => }, or nil
      # when no VRF exports.
      def self.labels(vrfs, block)
        exporting = vrfs.select(&:exports?)
        return {} if exporting.empty?
        unless block.is_a?(Hash) && block['start'] && block['size']
          raise ArgumentError, "l3vpn: labels: { start:, size: } is required: VRF #{exporting.first.name} exports"
        end
        start, size = Integer(block['start']), Integer(block['size'])
        unless start >= 16 && start + size - 1 <= 0xfffff
          raise ArgumentError, "l3vpn: labels: #{start} to #{start + size - 1} is not 16 to 1048575 (RFC 3032)"
        end
        if exporting.size > size
          raise ArgumentError, "l3vpn: labels: #{size} label(s) for #{exporting.size} exporting VRFs"
        end
        exporting.each_with_index.to_h { |v, i| [v.name, start + i] }
      end

      def initialize(vpn_table:, vrfs:, transport:, local_as:, router_id:, labels: nil, fib: VrfFib.new, logger: nil)
        @vpn_table = vpn_table
        @vrfs = vrfs
        @transport = transport
        @fib = fib
        @local_as = local_as
        @router_id = router_id
        @logger = logger
        @lock = Mutex.new
        @installed = Hash.new { |h, k| h[k] = {} } # vrf name => { prefix => argv }
        @rows = {}                                  # vrf name => [row]
        @devices = {}                               # vrf name => nil, or why it is unusable
        @labels = L3vpn.labels(vrfs, labels)        # vrf name => its label
        @label_installed = {}                       # label => true when the kernel has it
        @label_errors = {}                          # label => why not
        @exports = {}                               # vrf name => [Export]
        @syncs = 0
      end

      # Removes what an earlier bgp4rd left in each VRF, then fills them.
      def start
        @vrfs.each { |v| @fib.run(@fib.flush_argv(v.name)) if device_error(v).nil? }
        @fib.run(@fib.label_flush_argv) unless @labels.empty?
        sync!
        self
      end

      # Removes every route this put in the VRFs (proto bgp only).
      def stop
        @lock.synchronize do
          @vrfs.each { |v| @fib.run(@fib.flush_argv(v.name)) if @devices[v.name].nil? }
          @fib.run(@fib.label_flush_argv) unless @labels.empty?
          @installed.clear
          @label_installed.clear
        end
        self
      end

      # Works out every VRF's routes and sends the kernel the difference.
      def sync!
        winners = @vpn_table.winners
        @lock.synchronize do
          @syncs += 1
          hops = {}
          hop = ->(nh) { hops[nh.to_s] ||= @transport.resolve(nh) }
          @vrfs.each do |v|
            @devices[v.name] = device_error(v)
            want, rows = wanted(v, winners, hop)
            if @devices[v.name]
              @installed.delete(v.name)
              rows.each { |r| r['error'] ||= @devices[v.name] }
            else
              apply(v, want, rows)
            end
            @rows[v.name] = rows
            export(v)
          end
        end
        self
      end

      # show.vrf's rows: every route each VRF imported, installed or not,
      # sorted by VRF then prefix.
      def rows(vrf = nil)
        @lock.synchronize do
          names = vrf ? [vrf.to_s] : @vrfs.collect(&:name)
          names.flat_map { |n| @rows.fetch(n, []) }
        end
      end

      # show.vrfs's rows, one per VRF.
      def vrf_rows
        @lock.synchronize do
          @vrfs.collect do |v|
            list = @rows.fetch(v.name, [])
            { 'name' => v.name, 'table' => v.table, 'rd' => v.rd, 'import' => v.import, 'export' => v.export,
              'device' => @devices[v.name] ? 'unusable' : 'ok', 'error' => @devices[v.name],
              'routes' => list.size, 'installed' => list.count { |r| r['installed'] } }
          end
        end
      end

      def syncs ; @lock.synchronize { @syncs } ; end

      # The VPN routes this PE sends, every exporting VRF's, as Export.
      # A VRF whose device is unusable, or whose label route the kernel
      # refused, sends nothing: a label nothing pops would drop traffic.
      def exports
        @lock.synchronize { @exports.values.flatten.sort_by { |e| [e.rd, prefix_order(e.prefix)] } }
      end

      # show.vpn_labels: one row per VRF label.
      def label_rows
        @lock.synchronize do
          @labels.collect do |vrf, label|
            { 'label' => label, 'vrf' => vrf, 'action' => 'pop, then look up in the VRF',
              'installed' => @label_installed.key?(label), 'error' => @label_errors[label] }
          end
        end
      end

      private

      # The VRF device as the configuration says: a VRF, on its table.
      def device_error(v)
        require 'json' # here, as View#json does: see vpn_transport.rb
        r = @fib.run(@fib.link_argv(v.name))
        return "no VRF device #{v.name}: #{r.output.strip}" unless r.ok?
        info = (JSON.parse(r.output).first || {})['linkinfo'] || {}
        return "#{v.name} is not a VRF device" unless info['info_kind'] == 'vrf'
        table = (info['info_data'] || {})['table']
        return "VRF #{v.name} is on table #{table}, not #{v.table}" unless table == v.table
        nil
      rescue JSON::ParserError => e
        "ip link show #{v.name}: #{e.message}"
      end

      # [{ prefix => Want }, rows] for one VRF.
      def wanted(v, winners, hop)
        decision = Decision.new(local_as: @local_as, router_id: @router_id,
                                resolver: ->(nh) { hop.call(nh).ok? ? 0 : nil })
        want = {}
        rows = []
        winners.select { |w| v.imports?(w.route_targets) }.group_by(&:prefix).each do |prefix, list|
          result = decision.best(list.collect(&:route))
          chosen = result.best && list.find { |w| w.route.equal?(result.best) }
          w = chosen || list.first
          h = hop.call(w.route.next_hop)
          row = { 'vrf' => v.name, 'prefix' => prefix, 'rd' => w.rd, 'peer' => w.peer.address,
                  'next_hop' => w.route.next_hop, 'vpn_labels' => w.labels, 'transport' => h.transport,
                  'transport_labels' => h.labels, 'gateway' => h.gateway, 'dev' => h.dev,
                  'candidates' => list.size, 'installed' => false, 'error' => nil }
          if chosen
            stack = Array(h.labels) + w.labels
            want[prefix] = Want.new(w, h, stack, @fib.install_argv(v.name, prefix, stack, h))
          else
            row['error'] = h.error || result.reason.to_s
          end
          rows << row
        end
        [want, rows.sort_by { |r| prefix_order(r['prefix']) }]
      end

      # The VRF's label route, and the VPN routes it sends. Lock held.
      def export(v)
        label = @labels[v.name]
        return @exports.delete(v.name) unless label
        if @devices[v.name]
          @fib.run(@fib.label_remove_argv(label)) if @label_installed.delete(label)
          @label_errors[label] = @devices[v.name]
          return @exports.delete(v.name)
        end
        unless @label_installed[label]
          r = @fib.run(@fib.label_argv(label, v.name))
          if r.ok?
            @label_installed[label] = true
            @label_errors.delete(label)
          else
            @label_errors[label] = "the kernel refused it: #{r.output.strip}"
            log(:warn, "vrf #{v.name}: #{r}")
            return @exports.delete(v.name)
          end
        end
        prefixes = (connected(v) + v.prefixes).uniq
        @exports[v.name] = prefixes.collect { |p| Export.new(v.name, v.rd, p, label, v.export) }
      end

      # The VRF's connected prefixes, from its table.
      def connected(v)
        require 'json' # here, as View#json does: see vpn_transport.rb
        r = @fib.run(@fib.connected_argv(v.name))
        return [] unless r.ok?
        JSON.parse(r.output).filter_map { |route| route['dst'] && normalize(route['dst']) }
      rescue JSON::ParserError
        []
      end

      def normalize(dst)
        ip = IPAddr.new(dst)
        "#{ip}/#{ip.prefix}"
      end

      # Sends the kernel what differs, and marks each row.
      def apply(v, want, rows)
        have = @installed[v.name]
        (have.keys - want.keys).each do |prefix|
          r = @fib.run(@fib.remove_argv(v.name, prefix))
          log(:warn, "vrf #{v.name}: #{r}") unless r.ok?
          have.delete(prefix)
        end
        by_prefix = rows.to_h { |r| [r['prefix'], r] }
        want.each do |prefix, w|
          unless have[prefix] == w.argv
            r = @fib.run(w.argv)
            if r.ok?
              have[prefix] = w.argv
            else
              have.delete(prefix)
              by_prefix[prefix]['error'] = "the kernel refused it: #{r.output.strip}"
              log(:warn, "vrf #{v.name}: #{r}")
            end
          end
          by_prefix[prefix]['installed'] = have[prefix] == w.argv
        end
      end

      def prefix_order(prefix)
        ip = IPAddr.new(prefix)
        [ip.ipv4? ? 4 : 6, ip.to_i, ip.prefix]
      end

      def log(level, msg)
        @logger&.call(level, msg)
      end
    end

  end
end
