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
require 'json'
require 'tmpdir'
require 'fileutils'
require 'time'

module BGP
  module TestHelpers

    # ospfd's control socket, as much of it as the BGP-LS Producer reads:
    # JSON lines on a Unix socket, `events.subscribe`, `show.topology`
    # and `topology` events. As ospfv2's lib/ospfv2/daemon/api.rb does,
    # a subscribed connection streams events and answers any request but
    # `events.unsubscribe` with an error: requests go on another one.
    #
    # `topology[area]` is the answer to `show.topology` for that area (a
    # dotted quad), and `topology['as']` for `scope: "as"`. A test
    # changes it, then calls `changed(area)` or `changed('as')`.
    class FakeOspfd
      attr_reader :path, :requests
      attr_accessor :topology

      def initialize(topology = {})
        @dir = Dir.mktmpdir
        @path = File.join(@dir, 'ospfd.sock')
        @topology = topology
        @requests = []
        @streams = []
        @conns = []
        @lock = Mutex.new
        @seq = 0
        @server = UNIXServer.new(@path)
        @thread = Thread.new { accept_loop }
      end

      def subscriptions ; @lock.synchronize { @subscriptions.to_i } ; end
      def connections ; @lock.synchronize { @connections.to_i } ; end

      # One `topology` event, as ospfd's Instance#topology_changed
      # publishes it: { area } or { scope: "as" }, and the SPF run.
      def changed(where)
        data = where == 'as' ? { 'scope' => 'as' } : { 'area' => where }
        event('kind' => 'topology', 'level' => 'info', 'message' => "topology #{where} changed",
              'data' => data.merge('run' => @seq + 1))
      end

      def event(e)
        @lock.synchronize do
          @seq += 1
          @streams.each { |c| write(c, 'event' => { 'seq' => @seq, 'time' => Time.now.utc.iso8601(3) }.merge(e)) }
        end
      end

      # Closes every connection, as a restarting ospfd would.
      def drop
        @lock.synchronize do
          @conns.each { |c| c.close rescue nil }
          @conns.clear
          @streams.clear
        end
      end

      def stop
        drop
        @server.close rescue nil
        @thread.kill
        FileUtils.remove_entry(@dir)
      end

      private

      def accept_loop
        loop do
          c = @server.accept
          @lock.synchronize do
            @conns << c
            @connections = @connections.to_i + 1
          end
          Thread.new(c) { |s| serve(s) }
        end
      rescue IOError, SystemCallError
        nil
      end

      def serve(c)
        while (line = c.gets)
          req = JSON.parse(line)
          @lock.synchronize do
            @requests << req
            if @streams.include?(c)
              write(c, 'id' => req['id'], 'error' => 'streaming events: only events.unsubscribe, or use another connection')
              next
            end
            case req['method']
            when 'events.subscribe'
              @streams << c
              @subscriptions = @subscriptions.to_i + 1
              kinds = req.dig('params', 'kinds')
              write(c, 'id' => req['id'], 'result' => { 'seq' => @seq, 'replayed' => 0, 'kinds' => kinds })
            when 'show.topology'
              answer(c, req)
            else
              write(c, 'id' => req['id'], 'error' => "unknown method #{req['method']}")
            end
          end
        end
      rescue IOError, SystemCallError
        nil
      end

      def answer(c, req)
        params = req['params'] || {}
        key = params['scope'] == 'as' ? 'as' : params['area']
        t = @topology[key]
        if t
          write(c, 'id' => req['id'], 'result' => t)
        else
          write(c, 'id' => req['id'], 'error' => "not in area #{key}")
        end
      end

      def write(c, msg)
        c.write("#{JSON.generate(msg)}\n")
      rescue IOError, SystemCallError
        nil
      end
    end

  end
end
