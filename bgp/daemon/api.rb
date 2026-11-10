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
require 'io/wait'
require 'bgp/version'
require 'bgp/events'
require 'bgp/daemon/views'
require 'bgp/daemon/control'
require 'bgp/daemon/candidate'

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
    # `events.subscribe` turns the connection into a stream: after its
    # reply, one line per event, and a keepalive line when nothing has
    # happened for KEEPALIVE seconds. `events.unsubscribe` ends the stream
    # and the connection takes requests again; use another connection for
    # requests meanwhile.
    #
    #   -> {"id":2,"method":"events.subscribe","params":{"kinds":["session"],"since":120}}
    #   <- {"id":2,"result":{"seq":131,"replayed":11,"kinds":["session"]}}
    #   <- {"event":{"seq":121,"time":"...","level":"info","kind":"session","peer":"10.0.0.2",...}}
    #   <- {"keepalive":"2026-11-02T03:18:31.004Z","seq":131}
    #   -> {"id":3,"method":"events.unsubscribe"}
    #   <- {"id":3,"result":{"unsubscribed":true}}
    #
    # **An event carries `peer` where ospfv2's carries `interface`**, and
    # that is bgp4r's own key rather than a mismatch: interface is OSPF's
    # word for a circuit, BGP has none, and a peer is named by its
    # address. A console maps it onto its own column. `bgp/events.rb` has
    # the reason and docs/daemon.md says so too.
    #
    # **`config.*` answers now**, in `bgp/daemon/candidate.rb`: the
    # candidate configuration, with `show.configuration` reading it. The
    # nine methods a console calls were read in routescope's
    # `Drivers::Ospfd` at `7eabde1` rather than designed here, and
    # `config.load` is a tenth that no driver calls and a person does.
    # An unknown method still answers an error naming the methods that
    # exist, which is the shape `Events#publish` already answers an
    # unknown kind with.
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
      KEEPALIVE   = 15         # seconds between keepalive lines on an event stream
      VERSION     = 1          # of this API, raised when a method changes incompatibly

      # The two that turn a connection into a stream and back, which
      # `handle` cannot answer because a stream is many lines. See
      # `stream`.
      STREAM_METHODS = %w[events.subscribe events.unsubscribe].freeze

      # name => ->(api, params) { result }
      #
      # Dotted names, so a reader can guess them. **A mutating method is
      # a name of its own and never a flag on a read**, which is
      # docs/daemon.md's decision and its reason: a read-only client is
      # then a list of methods and not a trust decision. The reads go
      # through `Views` and the writes through `Control`, which is the
      # same split one layer down.
      METHODS = {
        'api.info'        => ->(a, _p) { Api.api_info(a.views) },
        'show.status'     => ->(a, _p) { a.views.status },
        'show.configuration' => ->(a, p) { a.candidate.configuration(p) },
        'show.peers'      => ->(a, _p) { a.views.peers },
        'show.routes'     => ->(a, p) { a.views.routes(p) },
        'show.rib'        => ->(a, p) { a.views.rib(p) },
        'show.adj_in'     => ->(a, p) { a.views.adj_in(p) },
        'show.adj_out'    => ->(a, p) { a.views.adj_out(p) },
        'show.fib'        => ->(a, p) { a.views.fib(p) },
        'show.link_state' => ->(a, p) { a.views.link_state(p) },
        'show.log'        => ->(a, p) { a.views.log(p) },
        'show.text'       => ->(a, p) { a.views.text(p) },
        'peer.clear'      => ->(a, p) { a.control.peer_clear(p) },
        'peer.stop'       => ->(a, p) { a.control.peer_stop(p) },
        'peer.start'      => ->(a, p) { a.control.peer_start(p) },
        'peer.refresh'    => ->(a, p) { a.control.peer_refresh(p) },
        'peer.specimen'   => ->(a, p) { a.control.peer_specimen(p) },
        'peer.fault'      => ->(a, p) { a.control.peer_fault(p) },
        'peer.replay'     => ->(a, p) { a.control.peer_replay(p) },
        'peer.resend'     => ->(a, p) { a.control.peer_resend(p) },
        'route.originate' => ->(a, p) { a.control.route_originate(p) },
        'route.withdraw'  => ->(a, p) { a.control.route_withdraw(p) },
        'config.changed'  => ->(a, p) { a.candidate.changed?(p) },
        'config.compare'  => ->(a, p) { a.candidate.compare(p) },
        'config.history'  => ->(a, p) { a.candidate.history(p) },
        'config.load'     => ->(a, p) { a.candidate.load(p) },
        'config.replace'  => ->(a, p) { a.candidate.replace(p) },
        'config.commit'   => ->(a, p) { a.candidate.commit(p) },
        'config.discard'  => ->(a, p) { a.candidate.discard(p) },
        'config.rollback' => ->(a, p) { a.candidate.rollback(p) }
      }.freeze

      # Every method this answers, the streams included, so one list is
      # what `api.info` reports and what an unknown method is refused
      # with.
      def self.names
        (METHODS.keys + STREAM_METHODS).sort
      end

      # Raised when another bgp4rd already answers on the socket path.
      class InUse < StandardError ; end

      # The version, the methods and where the event stream has got to.
      #
      # `event_seq` is the number a reader resumes `events.subscribe`
      # from, and it is answered here as well so a console can see the
      # stream advancing and know how far behind it is without
      # subscribing at all.
      def self.api_info(views)
        { :version     => BGP::VERSION,
          :api         => VERSION,
          :methods     => names,
          :event_kinds => BGP::Events::KINDS.collect { |k| k.to_s },
          :event_seq   => views.speaker.events.seq }
      end

      attr_reader :path, :views

      # :path is the socket, :logger a ->(level, message) or nil,
      # :views the Views this answers from, :candidate the candidate
      # configuration, and :keepalive the interval between keepalive lines
      # on an event stream, which a test shortens.
      def initialize(views, arg={})
        @views     = views
        @candidate = arg[:candidate]
        @path      = arg[:path]
        @logger    = arg[:logger]
        @keepalive = arg[:keepalive] || KEEPALIVE
        @clients   = []
        @lock      = Mutex.new
      end

      # The mutating half, built on first use so an Api over a Views with
      # no Speaker is still an object a test can make.
      def control
        @lock.synchronize { @control ||= Control.new(@views.speaker) }
      end

      # The candidate configuration, which answers `show.configuration`
      # and every `config.` method. Built on first use from the Speaker's
      # own configuration for the same reason `control` is, and handed in
      # by `Server` so that one of it carries the logger and the history.
      def candidate
        @lock.synchronize do
          @candidate ||= Candidate.new(@views.speaker, @views.speaker.config, :logger => @logger)
        end
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
        { :id => id, :result => fn.call(self, params) }
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
        "#{Api.names.join(', ')}"
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
          case req['method']
          when 'events.subscribe'
            # The stream owns the connection until the client
            # unsubscribes, and then this loop takes requests again. A
            # client that went away ends the thread.
            return unless stream(sock, req)
          when 'events.unsubscribe'
            write(sock, :id => req['id'], :error => 'not subscribed')
          else
            write(sock, handle(req))
          end
        end
      rescue IOError, Errno::ECONNRESET, Errno::EPIPE
        nil # the client went away
      end

      # Streams events on this connection until the client unsubscribes,
      # which answers true so the caller takes requests again, or goes
      # away, which answers false.
      #
      # **One thread and no second one.** This is the connection's own
      # thread, polling three things in turn: a line arriving, an event
      # waiting, and the keepalive deadline. A writer thread per
      # subscriber would be a thread per console and nothing to bound it,
      # where MAX_CLIENTS already bounds this.
      #
      # **The keepalive line is not decoration.** With nothing written, a
      # reader cannot tell a quiet lab from a socket that died, which is
      # the gap-against-quiet failure `bgp/events.rb` already carries a
      # synthetic overflow event for. So after KEEPALIVE seconds of
      # silence one line goes out carrying the time and the sequence the
      # stream has reached.
      def stream(sock, req)
        params = req['params'].is_a?(Hash) ? req['params'] : {}
        kinds  = params['kinds'] && Array(params['kinds']).collect { |k| k.to_sym }
        since  = params.has_key?('since') ? Integer(params['since']) : events.seq
        # A caller that named no :since gets the current sequence, so the
        # replay is empty and the stream starts here. Either way
        # Events#subscribe is given one, which is what makes
        # Subscription#replayed an answer rather than a guess: it is the
        # number of kept events that came back.
        sub = events.subscribe(:kinds => kinds, :since => since)
        # **`seq` is where the stream has got to and not the `since` it
        # was asked with**, which is the number a reader resumes from: it
        # already has everything up to it, through the replay or through
        # the event lines that follow. An event published between the
        # subscribe above and this read is on the stream as well, so a
        # reader loses nothing by it and may at worst see one line twice
        # across a reconnect.
        write(sock, :id => req['id'],
                    :result => { :seq => events.seq, :replayed => sub.replayed,
                                 :kinds => kinds && kinds.collect { |k| k.to_s } })
        pump(sock, sub)
      rescue ArgumentError, TypeError => e
        # A kind nobody publishes, or a :since that is not a number.
        # Refused on this request and the connection lives, because a
        # console can send anything.
        write(sock, :id => req['id'], :error => e.message)
        true
      ensure
        sub.close if sub
      end

      # The stream's loop. True when the client unsubscribed, false when
      # it went away.
      def pump(sock, sub)
        # String.new and not +'', because this holds what came off a
        # socket: Conventions says an octet buffer is ASCII-8BIT, which
        # String.new with no argument gives and +'' does not. ospfv2's
        # equivalent uses +'' and bgp4r's own rule is the other one.
        buffer = String.new
        last = monotonic
        loop do
          if sock.wait_readable(0)
            chunk = sock.read_nonblock(4096, :exception => false)
            return false if chunk.nil?             # the client closed its end
            buffer << chunk unless chunk == :wait_readable
            return false if buffer.bytesize > MAX_LINE
            while (i = buffer.index("\n"))
              line = buffer.slice!(0..i)
              return true if unsubscribed?(sock, line, sub)
            end
          end
          ev = sub.pop(:timeout => 0.2)
          now = monotonic
          if ev
            write(sock, :event => ev.to_h)
            last = now
          elsif now - last >= @keepalive
            # ISO 8601 with milliseconds in UTC, which is the shape
            # Event#iso_time answers. strftime and not Time#iso8601,
            # which would need `require 'time'`: Conventions records a
            # standard library becoming a bundled gem twice, once
            # killing a CI job before a test ran, and a format string
            # needs nothing at all.
            write(sock, :keepalive => Time.now.utc.strftime('%Y-%m-%dT%H:%M:%S.%LZ'),
                        :seq => events.seq)
            last = now
          end
        end
      end

      # True when this line ended the stream. Anything else on the
      # connection is refused and the stream goes on: a request answered
      # mid stream would interleave with the event lines, and dropping
      # the stream over a stray line would lose the events the caller
      # asked for.
      def unsubscribed?(sock, line, sub)
        msg = begin
                JSON.parse(line)
              rescue JSON::ParserError
                nil
              end
        if msg.is_a?(Hash) && msg['method'] == 'events.unsubscribe'
          # **Closed before the reply and not after it.** The reply means
          # the subscription is gone, so a caller that reads it can go on
          # to assert that it is; closing in the ensure below leaves a
          # window in which the reply has arrived and the subscriber is
          # still registered, which is a race a test found. The ensure
          # stays, for the path where the client simply went away, and a
          # second close is harmless.
          sub.close
          write(sock, :id => msg['id'], :result => { :unsubscribed => true })
          return true
        end
        write(sock, :id => (msg.is_a?(Hash) ? msg['id'] : nil),
                    :error => 'streaming events: only events.unsubscribe, ' \
                              'or use another connection')
        false
      end

      def events
        @views.speaker.events
      end

      # The clock a deadline is measured on. Process::CLOCK_MONOTONIC and
      # not Time.now, so a keepalive is not skipped or doubled when the
      # wall clock steps.
      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def write(sock, h)
        sock.write("#{JSON.generate(h)}\n")
      end

    end

  end
end
