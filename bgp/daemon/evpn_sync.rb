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

require 'socket'
require 'bgp/daemon/link_state_sources'

module BGP
  module Daemon

    # vtep4rd's control socket, for the MAC-VRFs: docs/design/evpn.md,
    # decision 3. JSON lines in bgp4rd's own envelope (vtep4r
    # vxlan/daemon/api.rb), one connection kept and opened again after it
    # is lost. A request on a kept connection that turns out dead, as
    # after vtep4rd restarts, is sent once more on a new one: every method
    # bgp4rd sends is a read or sets a value, so twice is as once. call
    # raises on an error answer, a connection that cannot be made, or an
    # answer that takes longer than TIMEOUT.
    class VtepClient
      SOCKET = '/run/vtep4r/vtep4rd.sock'
      TIMEOUT = 5

      attr_reader :path

      def initialize(path = SOCKET, timeout: TIMEOUT)
        @path, @timeout = path, timeout
      end

      def call(method, params = {})
        kept = !@conn.nil?
        begin
          conn.call(method, params)
        rescue IOError, SystemCallError, JSON::ParserError => e
          close
          raise unless kept && !e.is_a?(::IO::TimeoutError)
          kept = false
          retry
        end
      end

      def close
        c, @conn = @conn, nil
        c.close if c
      end

      private

      def conn
        @conn ||= begin
          sock = UNIXSocket.new(@path)
          sock.timeout = @timeout
          LinkStateProducer::Conn.new(sock, 'vtep4rd')
        end
      end
    end

    # vtep4rd's `mac` events, on a connection of their own, since a
    # streaming connection takes no other request (vtep4r
    # vxlan/daemon/api.rb). Each event, and each reconnection, pokes the
    # sync: an event says something changed, and show.macs says what
    # (docs/design/evpn.md, Exporting, step 5). An `overflow` is one more
    # event. A lost connection is tried again every RETRY seconds.
    class VtepEvents
      RETRY = 1

      def initialize(path, sync, logger: nil, retry_after: RETRY)
        @path, @sync, @logger, @retry = path, sync, logger, retry_after
      end

      def start
        @thread = Thread.new { run }
        self
      end

      def stop
        @thread&.kill
        @sock&.close rescue nil
        self
      end

      private

      def run
        loop do
          begin
            @sock = UNIXSocket.new(@path)
            @sock.write("#{JSON.generate('id' => 1, 'method' => 'events.subscribe', 'params' => { 'kinds' => ['mac'] })}\n")
            @sync.poke
            while (line = @sock.gets)
              msg = JSON.parse(line) rescue next
              @sync.poke if msg.is_a?(Hash) && msg['event']
            end
          rescue IOError, SystemCallError
            nil
          ensure
            @sock&.close rescue nil
          end
          sleep @retry
        end
      end
    end

    # Keeps the MAC-VRFs and vtep4rd in step: docs/design/evpn.md, pull
    # requests 2 and 3. Rib::Macvrfs#sync! runs on a thread of its own
    # when the EVPN table changes, when vtep4rd sends a `mac` event
    # (VtepEvents), and every `every` seconds, which is how a vtep4rd that
    # started late, restarted or had a VNI added is found, and how the
    # hold on a lost vtep4rd ends. Pokes that arrive while a sync runs make
    # one more sync, not one each. after_sync blocks run after each, on
    # this thread: how the exporter learns what to send.
    class EvpnSync

      EVERY = 10

      def initialize(macvrfs, logger: nil, every: EVERY)
        @macvrfs, @logger, @every = macvrfs, logger, every
        @queue = Queue.new
        @errors = nil
        @after = []
      end

      def after_sync(&block)
        @after << block
        self
      end

      def start
        @worker = Thread.new { work }
        poke
      end

      def poke
        @queue << :sync
        self
      end

      def stop
        @queue << :stop
        @worker&.join(5)
        self
      end

      private

      def work
        loop do
          jobs = [@queue.pop(timeout: @every) || :sync]
          jobs << @queue.pop until @queue.empty?
          break if jobs.include?(:stop)
          @macvrfs.sync!
          @after.each(&:call)
          report(@macvrfs.errors)
        end
      rescue StandardError => e
        @logger&.call(:error, "evpn sync: #{e.class}: #{e.message}")
        sleep 1
        retry
      end

      # Logs what stops a MAC-VRF when it changes, not at every sync.
      def report(errors)
        return if errors == @errors
        (errors - Array(@errors)).each { |e| @logger&.call(:warn, "evpn: #{e}") }
        @logger&.call(:info, 'evpn: every MAC-VRF is in vtep4rd') if errors.empty? && @errors
        @errors = errors
      end
    end

  end
end
