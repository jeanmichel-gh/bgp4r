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

module BGP
  module TestHelpers

    # isisd's control socket, as much of it as the BGP-LS Producer reads:
    # JSON lines on a Unix socket, `events.subscribe`, `show.topology`
    # and `spf` events. The framing is isis's lib/isis/daemon/api.rb: a
    # request is {"id","method","params"}, an answer {"id","result"} or
    # {"id","error"}, and an event {"event":{"kind","data",...}}.
    #
    # `topology[level]` is the answer to `show.topology` for that level,
    # and a test changes it, then calls `spf(level)`.
    class FakeIsisd
      attr_reader :path, :requests
      attr_accessor :topology

      def initialize(topology = {})
        @dir = Dir.mktmpdir
        @path = File.join(@dir, 'isisd.sock')
        @topology = topology
        @requests = []
        @clients = []
        @lock = Mutex.new
        @seq = 0
        @server = UNIXServer.new(@path)
        @thread = Thread.new { accept_loop }
      end

      # How many connections have subscribed so far.
      def subscriptions ; @lock.synchronize { @subscriptions.to_i } ; end

      # One `spf` event, as isisd's Decision#run logs it: the IS-IS
      # level is in the data, and the top `level` is the log level.
      def spf(level)
        event('kind' => 'spf', 'level' => 'info',
              'message' => "Level #{level} SPF run",
              'data' => { 'level' => level, 'run' => (@seq + 1) })
      end

      def event(e)
        @lock.synchronize do
          @seq += 1
          @clients.each { |c| write(c, 'event' => { 'seq' => @seq }.merge(e)) }
        end
      end

      # Closes every connection, as a restarting isisd would.
      def drop
        @lock.synchronize do
          @clients.each { |c| c.close rescue nil }
          @clients.clear
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
            case req['method']
            when 'events.subscribe'
              @clients << c
              @subscriptions = @subscriptions.to_i + 1
              write(c, 'id' => req['id'], 'result' => { 'seq' => @seq, 'replayed' => 0 })
            when 'show.topology'
              level = req.dig('params', 'level')
              t = @topology[level]
              if t
                write(c, 'id' => req['id'], 'result' => t)
              else
                write(c, 'id' => req['id'], 'error' => "level #{level} is not running")
              end
            else
              write(c, 'id' => req['id'], 'error' => "unknown method #{req['method']}")
            end
          end
        end
      rescue IOError, SystemCallError
        nil
      end

      def write(c, msg)
        c.write("#{JSON.generate(msg)}\n")
      rescue IOError, SystemCallError
        nil
      end
    end

  end
end
