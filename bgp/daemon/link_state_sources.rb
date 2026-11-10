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

require 'json'
require 'io/wait'

module BGP
  module Daemon
    class LinkStateProducer

      class Error < StandardError ; end

      # One JSON-lines connection to an IGP daemon's control socket: a
      # request is {"id","method","params"}, an answer {"id","result"} or
      # {"id","error"}, an event {"event":{...}}. isis's and ospfv2's
      # APIs both frame it this way.
      class Conn
        def initialize(io, name)
          @io, @name = io, name
          @id = 0
        end

        # Sends one request and reads lines until its answer. Each other
        # message read on the way goes to the block.
        def call(method, params)
          id = (@id += 1)
          @io.write("#{JSON.generate('id' => id, 'method' => method, 'params' => params)}\n")
          loop do
            msg = next_message
            next (yield msg if block_given?) unless msg.key?('id')
            next unless msg['id'] == id
            raise Error, "#{method}: #{msg['error']}" if msg['error']
            return msg['result']
          end
        end

        def next_message
          line = @io.gets
          raise IOError, "#{@name} closed the socket" if line.nil?
          msg = JSON.parse(line)
          raise Error, "#{@name} sent a line that is not a JSON object" unless msg.is_a?(Hash)
          msg
        end

        def wait_readable(t) ; @io.wait_readable(t) ; end

        def close
          @io.close unless @io.closed?
        rescue IOError
          nil
        end
      end

      # isisd: one connection, subscribed to every event, which still
      # answers requests. A change is an `spf` event of a configured
      # level, whose data names the level.
      class IsisSource
        NAME = 'isisd'
        SOCKET = '/run/isis4r/isisd.sock'

        attr_reader :path, :levels

        def initialize(path, levels)
          @path, @levels = path, levels
          @dirty = false
        end

        def name ; NAME ; end
        def scopes ; @levels ; end

        # connect answers a connected IO.
        def open(connect)
          @conn = Conn.new(connect.call, NAME)
          @dirty = false
          @conn.call('events.subscribe', {}) { |m| note(m) }
        end

        # One `show.topology` answer per level.
        def read
          @dirty = false
          @levels.collect { |l| @conn.call('show.topology', 'level' => l) { |m| note(m) } }
        end

        # True when an event read during the last read asks for another.
        def dirty? ; @dirty ; end

        # Reads until an `spf` event of a configured level, then a little
        # longer, so one change that runs SPF at both levels is one read.
        def wait(stopping)
          note(@conn.next_message) until @dirty || stopping.call
          note(@conn.next_message) while !stopping.call && @conn.wait_readable(0.1)
        end

        def close
          c, @conn = @conn, nil
          c.close if c
        end

        def note(msg)
          ev = msg['event']
          return unless ev.is_a?(Hash) && ev['kind'] == 'spf'
          data = ev['data'].is_a?(Hash) ? ev['data'] : {}
          @dirty = true if @levels.include?(data['level'])
        end
      end

      # ospfd: two connections. ospfd's `events.subscribe` turns its
      # connection into a stream that takes no other request
      # (ospfv2 lib/ospfv2/daemon/api.rb), so requests go on a second
      # one. A change is a `topology` event naming a configured area, or
      # the AS scope when `external` is on (ospfv2
      # docs/design/ospf-topology.md).
      class OspfSource
        NAME = 'ospfd'
        SOCKET = '/run/ospfv2/ospfd.sock'

        attr_reader :path, :areas, :external

        # areas are dotted quads.
        def initialize(path, areas, external)
          @path, @areas, @external = path, areas, external
          @dirty = false
        end

        def name ; NAME ; end
        def scopes ; @external ? @areas + ['as'] : @areas ; end

        def open(connect)
          @events = Conn.new(connect.call, NAME)
          @events.call('events.subscribe', 'kinds' => ['topology'])
          @requests = Conn.new(connect.call, NAME)
          @dirty = false
        end

        # One `show.topology` answer per area, then the AS scope's.
        def read
          @dirty = false
          out = @areas.collect { |a| @requests.call('show.topology', 'area' => a) }
          out << @requests.call('show.topology', 'scope' => 'as') if @external
          out
        end

        # Events wait on their own connection, so none arrives during a
        # read; an event that came during it is read by the next wait.
        def dirty? ; false ; end

        # Reads until a `topology` event of a configured area or of the
        # AS, then 0.1 s more, so one SPF run, which sends one event per
        # area, is one read.
        def wait(stopping)
          note(@events.next_message) until @dirty || stopping.call
          note(@events.next_message) while !stopping.call && @events.wait_readable(0.1)
        end

        def close
          [@events, @requests].each { |c| c.close if c }
          @events = @requests = nil
        end

        def note(msg)
          ev = msg['event']
          return unless ev.is_a?(Hash) && ev['kind'] == 'topology'
          data = ev['data'].is_a?(Hash) ? ev['data'] : {}
          @dirty = true if @areas.include?(data['area']) || (@external && data['scope'] == 'as')
        end
      end

    end
  end
end
