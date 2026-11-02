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
require 'bgp/version'
require 'bgp/events'
require 'bgp/daemon/views'

module BGP
  module Daemon

    # `bgp4rd`'s control API: one JSON object per line over a Unix
    # socket, in each direction.
    #
    #   -> {"id":1,"method":"show.status","params":{}}
    #   <- {"id":1,"result":{...}}
    #   <- {"id":1,"error":"unknown method show.foo; ..."}
    #
    # **The envelope is exact and it is not a choice.** routescope's
    # `Drivers::Ospfd::CLIENT` is a Ruby one liner that opens the socket,
    # writes one line and reads one line, read at routescope `7eabde1`:
    #
    #   s.write(JSON.generate(id: 1, method: ARGV[0], params: JSON.parse(ARGV[1])) + "\n")
    #   r = JSON.parse(s.gets || abort("ospfd closed the connection"))
    #   r["error"] ? abort(r["error"]) : puts(JSON.generate(r["result"]))
    #
    # The bgp4r driver will be that one liner with the paths changed, so a
    # mismatch here is a wrong answer rather than a missing one. The same
    # shape is written in docs/daemon.md with the commit it was read at.
    #
    # **This pull request is the read side only.** `show.adj_in`,
    # `show.adj_out`, `show.fib`, `show.log`, `events.subscribe`,
    # `peer.*`, `route.*` and all of `config.*` are each their own later
    # piece of work and **are deliberately not stubbed**: an unknown
    # method answers an error naming the methods that exist, which is the
    # shape `Events#publish` already answers an unknown kind with. A
    # method that answers nothing reads as a feature that is broken.
    #
    # **A bad request must not take the daemon down.** A console can send
    # anything, and a daemon a console can kill by accident is worse than
    # one with no API: so a line that is not JSON, a line that is JSON but
    # not an object, a line longer than MAX_LINE, a method that raises and
    # a client that disappears mid request are each answered or ignored,
    # one connection at a time, with the accept loop untouched.
    #
    # **No control plane read does work on a session thread.** The
    # Speaker's threads are the session's; this runs one thread per
    # client, and every read goes through `Table#synchronize`, which is
    # reentrant and public for exactly this. Stalling the event dispatch
    # thread would stop KEEPALIVEs and the session would die on a holdtime
    # expiry (RFC 4271 section 4.4).
    class Api

      MAX_LINE    = 1 << 20   # octets in one request
      MAX_CLIENTS = 32         # connections served at once
      IDLE        = 900        # seconds a connection may sit silent
      VERSION     = 1          # of this API, raised when a method changes incompatibly

      # name => ->(views, params) { result }
      #
      # Dotted names, so a reader can guess them. Reads only; see the
      # class comment for what is deliberately absent.
      METHODS = {
        'api.info'    => ->(v, _p) { Api.api_info(v) },
        'show.status' => ->(v, _p) { v.status },
        'show.peers'  => ->(v, _p) { v.peers },
        'show.routes' => ->(v, p) { v.routes(p) },
        'show.rib'    => ->(v, p) { v.rib(p) },
        'show.text'   => ->(v, p) { v.text(p) }
      }.freeze

      # Raised when another bgp4rd already answers on the socket path.
      class InUse < StandardError ; end

      # The version, the methods and where the event stream has got to.
      #
      # **`event_seq` is here with no `events.subscribe` beside it on
      # purpose.** It is the number a reader resumes from, and
      # `bgp/events.rb` already numbers every session's events into one
      # shared stream, so a console can see the stream advancing and know
      # how far behind it is before the subscription method exists.
      def self.api_info(views)
        { :version     => BGP::VERSION,
          :api         => VERSION,
          :methods     => METHODS.keys.sort,
          :event_kinds => BGP::Events::KINDS.collect { |k| k.to_s },
          :event_seq   => views.speaker.events.seq }
      end

      attr_reader :path, :views

      # :path is the socket, :logger a ->(level, message) or nil, and
      # :views the Views this answers from.
      def initialize(views, arg={})
        @views   = views
        @path    = arg[:path]
        @logger  = arg[:logger]
        @clients = []
        @lock    = Mutex.new
      end

      def start
        require 'fileutils'
        FileUtils.mkdir_p(File.dirname(@path))
        if File.socket?(@path)
          raise InUse, "another bgp4rd answers on #{@path}" if live?(@path)
          File.delete(@path) # left behind by a daemon that died
        end
        # Born 0660, so there is no window in which umask leaves it open.
        old = File.umask(0o117)
        begin
          @server = UNIXServer.new(@path)
        ensure
          File.umask(old)
        end
        @thread = Thread.new { accept_loop }
        self
      end

      def stop
        @server.close if @server && !@server.closed?
        @thread.join(2) if @thread
        @lock.synchronize { @clients.dup }.each { |c| c.close unless c.closed? }
        File.delete(@path) if @path && File.socket?(@path)
        self
      end

      # One request Hash in, one response Hash out. The socket threads
      # call it and so do the tests, which is why it takes and returns
      # data rather than reading and writing a socket.
      #
      # `params` that is not a Hash is read as no params rather than
      # refused: every method here answers something with none.
      def handle(req)
        id   = req['id']
        name = req['method'].to_s
        fn   = METHODS[name]
        return { :id => id, :error => unknown_method(name) } unless fn
        params = req['params'].is_a?(Hash) ? req['params'] : {}
        { :id => id, :result => fn.call(@views, params) }
      rescue ArgumentError => e
        { :id => id, :error => e.message }
      rescue StandardError => e
        log(:error, "api #{name}: #{e.class}: #{e.message}")
        { :id => id, :error => "internal error: #{e.class}" }
      end

      # The methods that exist, named in the refusal, which is what makes
      # a typo self correcting. `Events#publish` answers an unknown kind
      # the same way.
      def unknown_method(name)
        "unknown method #{name.inspect}; this bgp4rd answers " \
        "#{METHODS.keys.sort.join(', ')}"
      end

      private

      def log(level, message)
        @logger.call(level, message) if @logger
      end

      def live?(path)
        UNIXSocket.new(path).close
        true
      rescue SystemCallError
        false
      end

      def accept_loop
        loop do
          begin
            client = @server.accept
          rescue Errno::EMFILE, Errno::ENFILE, Errno::ENOBUFS, Errno::ENOMEM => e
            # Out of descriptors: wait for some to come back, keep serving.
            log(:warn, "api: #{e.message}")
            sleep 0.5
            next
          end
          busy = @lock.synchronize do
            @clients.size >= MAX_CLIENTS ? true : (@clients << client ; false)
          end
          if busy
            refuse(client, "too many connections (#{MAX_CLIENTS})")
            next
          end
          Thread.new(client) do |c|
            begin
              serve(c)
            ensure
              @lock.synchronize { @clients.delete(c) }
              c.close unless c.closed?
            end
          end
        end
      rescue IOError, Errno::EBADF
        nil # the server socket was closed by stop
      end

      def refuse(client, why)
        require 'json'
        client.write("#{JSON.generate(:error => why)}\n")
        client.close
      rescue SystemCallError, IOError
        nil
      end

      def serve(sock)
        require 'json'
        while sock.wait_readable(IDLE) && (line = sock.gets(MAX_LINE))
          # A line that filled the buffer without ending is a request too
          # long to read, and the rest of it would be read as the next
          # request, so the connection ends here.
          unless line.end_with?("\n") || line.bytesize < MAX_LINE
            write(sock, :error => "request longer than #{MAX_LINE} octets")
            return
          end
          req = begin
                  JSON.parse(line)
                rescue JSON::ParserError => e
                  write(sock, :error => "bad JSON: #{e.message[0, 120]}")
                  next
                end
          unless req.is_a?(Hash)
            write(sock, :error => 'a request is a JSON object')
            next
          end
          write(sock, handle(req))
        end
      rescue IOError, Errno::ECONNRESET, Errno::EPIPE
        nil # the client went away
      end

      def write(sock, h)
        sock.write("#{JSON.generate(h)}\n")
      end

    end

  end
end
