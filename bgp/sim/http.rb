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
require 'bgp/sim/injector'

module BGP
  module Sim

    # `bgp4r-sim`'s control API: HTTP on the loopback, GET for the five
    # reads and POST for the ten actions.
    #
    # docs/daemon.md's `The HTTP API` section is the design and its two
    # tables are READS and ACTIONS below.
    #
    # **It is a few hundred lines of HTTP/1.1 and not a web framework,
    # and that is forced rather than chosen.** The library has one
    # runtime gem, `logger`, and means to keep it, so a framework is
    # out. Ruby's own `webrick` would have done and **is not available**:
    # it left the standard library and `Gem::Specification.find_by_name
    # ('webrick')` raises `Gem::MissingSpecError` on the Ruby this was
    # written on, which is the check Conventions requires before
    # requiring any standard library and which it records biting twice,
    # once killing a CI job before a test ran. `json` is a default gem
    # here and the daemon already requires it, and it is required in the
    # one method that needs it for the same reason `bgp/rib/view.rb`
    # does it that way.
    #
    # **Three things about the client are measured and not assumed**,
    # from routescope's `Drivers::Sim` read at `7eabde1`, which inlines
    # `Net::HTTP` under `docker exec`:
    #
    # * `Net::HTTP.post` sends the body with a `Content-Length` and
    #   `Content-Type: application/json`, so the body is read by that
    #   length and the content type is not looked at.
    # * **`Net::HTTP` capitalises a header name per word, so
    #   `X-BGP4R: routescope` arrives as `X-Bgp4r: routescope`.**
    #   Measured on 2026-11-02 by reading what it put on a socket. A
    #   case sensitive match on the name would refuse every POST
    #   routescope makes, with a 403 and nothing anywhere saying why, so
    #   header names are downcased here and HEADER is the downcased
    #   form.
    # * The driver prints the body and then `exit(code < 300 ? 0 : 1)`,
    #   so **the status code is the whole of how a refusal reaches a
    #   scenario**. Every refusal below is a 4xx with a reason in
    #   `{"error": "..."}`, and nothing that a caller can fix answers
    #   200.
    #
    # **It binds the loopback by default**, which docs/daemon.md gives
    # as a decision: an API on 0.0.0.0 is reachable from every other node
    # on a lab segment, which turns an injector into something any
    # container can drive and makes a scenario's record of what happened
    # incomplete. A lab reaches it with `docker exec`, which needs no
    # address. `api:` in the node file, or `--api HOST:PORT`, says
    # otherwise for a person who wants it otherwise.
    #
    # **What it does not do**, said here rather than left to be found
    # out. One connection at a time, each answered and closed: there is
    # no keep-alive, no pipelining, no chunked request body, no
    # compression, no TLS and no authentication beyond the POST header.
    # A client that promises a `Content-Length` it does not send holds
    # the one connection until IDLE. All of that is the right trade for
    # ten paths on a container's loopback, and none of it is a trade a
    # lab notices.
    #
    # **A bad request must not take the process down**, which is the
    # line `bgp/daemon/api.rb` already holds for the Unix socket and the
    # same reasoning: an injector a console can kill by accident is
    # worse than one with no API. So every connection is served inside a
    # rescue, the accept loop is untouched by anything one client does,
    # and `handle` answers data rather than writing a socket so a test
    # can drive it without one.
    class Http

      MAX_HEAD = 8 << 10      # octets of request line and headers
      MAX_BODY = 1 << 20      # octets of request body
      IDLE     = 60           # seconds a connection may sit silent
      VERSION  = 1            # of this API, raised when a path changes incompatibly

      # The header every POST carries. ospfv2 added the equivalent so a
      # cross-site form in a browser cannot flap a lab's links, and the
      # same reasoning holds for an action that tears a session down.
      # Downcased, because `Net::HTTP` sends `X-Bgp4r`: see the class
      # comment.
      HEADER       = 'x-bgp4r'
      HEADER_VALUE = 'routescope'

      # `GET path => the Views method that answers it`.
      READS = {
        '/api/status'   => :status,
        '/api/peers'    => :peers,
        '/api/sent'     => :sent,
        '/api/topology' => :topology,
        '/api/events'   => :events
      }.freeze

      # `POST path => the Injector action it runs`. This is the other
      # half of `Drivers::Sim::ACTIONS`, whose entries are
      # `[path, body keys]`; the keys are `Injector::ACTIONS`.
      ACTIONS = {
        '/api/announce'      => 'announce',
        '/api/withdraw'      => 'withdraw',
        '/api/attribute'     => 'attribute',
        '/api/fault'         => 'fault',
        '/api/replay'        => 'replay',
        '/api/notification'  => 'notification',
        '/api/session/stop'  => 'session.stop',
        '/api/session/start' => 'session.start',
        '/api/session/flap'  => 'session.flap',
        '/api/refresh'       => 'refresh'
      }.freeze

      REASONS = { 200 => 'OK', 400 => 'Bad Request', 403 => 'Forbidden',
                  404 => 'Not Found', 405 => 'Method Not Allowed',
                  409 => 'Conflict', 413 => 'Payload Too Large',
                  500 => 'Internal Server Error' }.freeze

      DEFAULT_BIND = '127.0.0.1'
      DEFAULT_PORT = 8080

      attr_reader :bind, :views, :injector

      # :bind and :port are where it listens, :logger a
      # ->(level, message) or nil.
      def initialize(views, injector, arg = {})
        @views    = views
        @injector = injector
        @bind     = arg[:bind] || DEFAULT_BIND
        @port     = arg[:port] || DEFAULT_PORT
        @logger   = arg[:logger]
      end

      # `HOST:PORT` as the two options above, which is what `api:` in a
      # node file and `--api` on the command line both give.
      #
      # An IPv6 address is written in brackets, `[::1]:8080`, because a
      # bare `::1:8080` cannot be split: the last colon is part of the
      # address as readily as it is the separator.
      def self.address(text)
        s = text.to_s.strip
        if s =~ /\A\[(.+)\]:(\d+)\z/
          { :bind => Regexp.last_match(1), :port => Integer(Regexp.last_match(2)) }
        elsif s =~ /\A([^:]*):(\d+)\z/
          host = Regexp.last_match(1)
          { :bind => host.empty? ? DEFAULT_BIND : host,
            :port => Integer(Regexp.last_match(2)) }
        elsif s =~ /\A\d+\z/
          { :bind => DEFAULT_BIND, :port => Integer(s) }
        else
          raise ArgumentError,
                "api #{text.inspect}: write it as HOST:PORT, [IPV6]:PORT or PORT"
        end
      end

      # The port it is listening on, which is the one it was given
      # unless that was 0, when the system picked one. A test asks for 0
      # so two runs cannot collide on a fixed port.
      def port
        @server ? @server.addr[1] : @port
      end

      def url
        "http://#{@bind.include?(':') ? "[#{@bind}]" : @bind}:#{port}"
      end

      def start
        @server = TCPServer.new(@bind, @port)
        @thread = Thread.new { accept_loop }
        self
      end

      def stop
        @server.close if @server && !@server.closed?
        @thread.join(2) if @thread
        self
      end

      # One request in, one `[status, body]` out, where body is data for
      # JSON or a String already rendered.
      #
      # The socket threads call it and so do the tests, which is why it
      # takes and returns data: every path, every status code and every
      # refusal is reachable without a socket, and the socket's own job
      # is then only parsing and writing.
      # **One rescue for every path, reads included**, and the first
      # draft had it around the actions alone: a view that refused a
      # query parameter then raised straight out of here and the
      # connection answered nothing. A read can refuse exactly as an
      # action can, `?since=soon` being the obvious way, so the mapping
      # from an exception to a status code belongs to the whole of
      # `handle` and not to half of it.
      #
      # **The two refusals are told apart by their class and not by
      # their wording**: `Refused` is a request the caller can fix, so
      # 400, and `NoSession` is a session that is not there, so 409.
      # Both are 4xx, so both reach a driver as a non-zero exit status,
      # and a person reading the body can tell "you asked for something
      # odd" from "it is not up yet".
      def handle(method, path, headers = {}, body = '')
        dispatch(method, path, headers, body)
      rescue Injector::Refused => e
        [400, { :error => e.message }]
      rescue Daemon::NoSession => e
        [409, { :error => e.message }]
      rescue ArgumentError, KeyError, TypeError => e
        # A library constructor refusing a value it cannot represent: an
        # AS too large for its field, a prefix IPAddr will not read. That
        # is the caller's to fix, so it is a 400 and not a 500.
        [400, { :error => e.message }]
      rescue StandardError => e
        log(:error, "api #{method} #{path}: #{e.class}: #{e.message}")
        [500, { :error => "internal error: #{e.class}" }]
      end

      def dispatch(method, path, headers, body)
        route, query = path.to_s.split('?', 2)
        return index if route == '/' || route == '/api'
        if READS.key?(route)
          return [405, { :error => "#{route} is a GET" }] unless method == 'GET'
          return [200, @views.send(READS[route], params(query))]
        end
        action = ACTIONS[route]
        return not_found(route) unless action
        return [405, { :error => "#{route} is a POST" }] unless method == 'POST'
        return [403, { :error => "a POST needs #{HEADER.upcase}: #{HEADER_VALUE}" }] unless
          headers[HEADER].to_s == HEADER_VALUE
        [200, @injector.act(action, parse_body(body))]
      end

      # What this injector answers, so a person with `curl` and a
      # scenario's author find the paths without the document. An
      # unknown path answers the same list, which is the shape
      # `bgp/daemon/api.rb` answers an unknown method with and what
      # makes a typo self correcting.
      def index
        [200, { :bgp4r => BGP::VERSION, :api => VERSION,
                :reads => READS.keys.sort,
                :actions => ACTIONS.sort.to_h,
                :post_header => "#{HEADER.upcase}: #{HEADER_VALUE}" }]
      end

      private

      def not_found(route)
        [404, { :error => "no such path #{route}; this injector answers " \
                          "#{(READS.keys + ACTIONS.keys).sort.join(', ')}" }]
      end

      def parse_body(body)
        require 'json'
        text = body.to_s.strip
        return {} if text.empty?
        parsed = JSON.parse(text)
        return parsed if parsed.is_a?(Hash)
        raise Injector::Refused, "a request body is a JSON object, got #{parsed.class}"
      rescue JSON::ParserError => e
        raise Injector::Refused, "bad JSON: #{e.message[0, 120]}"
      end

      # The query string as a Hash with String keys. Percent escapes and
      # `+` are decoded, so a value with a space in it works; no
      # parameter needs that today and leaving it out would be a trap for
      # the first one that does.
      def params(query)
        return {} if query.nil? || query.empty?
        query.split('&').each_with_object({}) do |pair, h|
          k, v = pair.split('=', 2)
          next if k.nil? || k.empty?
          h[unescape(k)] = unescape(v.to_s)
        end
      end

      def unescape(s)
        s.tr('+', ' ').gsub(/%(\h\h)/) { Regexp.last_match(1).hex.chr }
      end

      def log(level, message)
        @logger.call(level, message) if @logger
      end

      def accept_loop
        loop do
          begin
            client = @server.accept
          rescue Errno::EMFILE, Errno::ENFILE, Errno::ENOBUFS, Errno::ENOMEM => e
            # Out of descriptors: wait for some to come back, keep
            # serving, which is what bgp/daemon/api.rb does.
            log(:warn, "api: #{e.message}")
            sleep 0.5
            next
          end
          begin
            serve(client)
          rescue StandardError => e
            log(:error, "api: #{e.class}: #{e.message}")
          ensure
            begin
              client.close unless client.closed?
            rescue IOError, SystemCallError
              nil
            end
          end
        end
      rescue IOError, Errno::EBADF
        nil # the listening socket was closed by stop
      end

      def serve(sock)
        return unless sock.wait_readable(IDLE)
        head = read_head(sock)
        return if head.nil?
        method, path, headers = head
        body = read_body(sock, headers)
        status, answer = if body == :too_big
                           [413, { :error => "a request body over #{MAX_BODY} octets" }]
                         else
                           handle(method, path, headers, body)
                         end
        respond(sock, status, answer)
      rescue Errno::ECONNRESET, Errno::EPIPE, IOError, EOFError
        nil # the client went away mid request
      end

      # The request line and the headers, or nil for anything that is
      # not a request. Header names come back downcased: see HEADER.
      def read_head(sock)
        lines = []
        size = 0
        while (line = sock.gets("\n"))
          size += line.bytesize
          if size > MAX_HEAD
            respond(sock, 413, :error => "request headers over #{MAX_HEAD} octets")
            return nil
          end
          text = line.chomp
          break if text.empty?
          lines << text
        end
        return nil if lines.empty?
        method, path, = lines.first.split(' ')
        if method.nil? || path.nil?
          respond(sock, 400, :error => 'not an HTTP request line')
          return nil
        end
        headers = lines.drop(1).each_with_object({}) do |l, h|
          name, value = l.split(':', 2)
          h[name.to_s.strip.downcase] = value.to_s.strip unless value.nil?
        end
        [method.upcase, path, headers]
      end

      def read_body(sock, headers)
        len = headers['content-length'].to_i
        return '' unless len.positive?
        return :too_big if len > MAX_BODY
        sock.read(len).to_s
      end

      def respond(sock, status, answer)
        require 'json'
        body = answer.is_a?(String) ? answer : JSON.generate(answer)
        sock.write("HTTP/1.1 #{status} #{REASONS.fetch(status, 'OK')}\r\n" \
                   "Content-Type: application/json\r\n" \
                   "Content-Length: #{body.bytesize + 1}\r\n" \
                   "Connection: close\r\n\r\n#{body}\n")
        true
      rescue Errno::EPIPE, Errno::ECONNRESET, IOError
        true # it went away before it read the answer
      end

    end

  end
end
