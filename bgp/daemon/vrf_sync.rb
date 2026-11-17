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

    # Keeps a PE's VRFs in step: docs/design/l3vpn-pe.md, pull request 2.
    #
    # Rib::L3vpn#sync! works out every VRF's routes and sends the kernel
    # the difference. This runs it on a thread of its own, whenever:
    #
    # * the VPN table changes, a route announced or withdrawn or a
    #   session gone (VpnTable#on_change), and
    # * the kernel's routes change, which is how the IGP's convergence
    #   reaches a VRF: a new SR label toward a PE. `ip monitor route` in a
    #   child process says so. It is a trigger only: `ip -j monitor route`
    #   prints plain text, not JSON, with iproute2 6.19 (measured), and
    #   the sync reads each next hop again anyway.
    #
    # * a few seconds after a sync that left a route waiting for its
    #   gateway's MAC address (Rib::L3vpn#waiting?, pull request 5). An
    #   IPv6 route needs it, and an ARP entry appears with no route change
    #   to say so: measured on l3vpn-lab, the first sync after a deploy
    #   found none, a moment before BGP's own traffic made one.
    #
    # Pokes that arrive while a sync runs make one more sync, not one each.
    # The sync's own commands are route changes too, so they poke it
    # again; the next sync finds nothing to send and the loop settles.
    class VrfSync

      # Seconds before another sync while a route waits for a MAC address.
      RETRY = 5

      def initialize(l3vpn, logger: nil, bin: 'ip', monitor: true, retry_after: RETRY)
        @retry_after = retry_after
        @l3vpn = l3vpn
        @logger = logger
        @bin = bin
        @monitor = monitor
        @queue = Queue.new
        @after = []
      end

      # Calls block after every sync, on the sync's thread: how the VPN
      # exporter learns what to send (pull request 3).
      def after_sync(&block)
        @after << block
        self
      end

      def start
        @l3vpn.start
        @after.each(&:call)
        @worker = Thread.new { work }
        @watcher = Thread.new { watch } if @monitor
        self
      end

      def poke
        @queue << :sync
        self
      end

      def stop
        @queue << :stop
        @worker&.join(5)
        if @pid
          Process.kill('TERM', @pid) rescue nil
          Process.wait(@pid) rescue nil
        end
        @watcher&.kill
        @l3vpn.stop
        self
      end

      private

      def work
        loop do
          job = waiting? ? (@queue.pop(timeout: @retry_after) || :sync) : @queue.pop
          jobs = [job]
          jobs << @queue.pop until @queue.empty?
          break if jobs.include?(:stop)
          @l3vpn.sync!
          @after.each(&:call)
        end
      rescue StandardError => e
        @logger&.call(:error, "vrf sync: #{e.class}: #{e.message}")
        retry
      end

      def waiting?
        @l3vpn.respond_to?(:waiting?) && @l3vpn.waiting?
      end

      def watch
        io = ::IO.popen([@bin, 'monitor', 'route'], :err => [:child, :out])
        @pid = io.pid
        io.each_line { poke }
      rescue SystemCallError => e
        @logger&.call(:error, "vrf sync: ip monitor route: #{e.message}")
      end
    end

  end
end
