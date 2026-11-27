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

require 'set'
require 'socket'
require 'bgp/rtr/pdus'
require 'bgp/rtr/validation'
require 'bgp/rtr/vrps'

module BGP
  module Rtr

    # The router's side of RTR, RFC 8210, toward one cache: it asks, it
    # reads the answers into the VRPs this cache gave, and it keeps them
    # by section 6's timers. docs/design/bgp-operations.md 7c, docs/rpki.md.
    #
    #   c = Rtr::Client.new('address' => '10.0.0.9', 'port' => 323)
    #   c.on_change { |client| ... }   # its VRPs changed
    #   c.start                        # a thread: connect, ask, read, again
    #   c.vrps                         # an Rtr::Vrps
    #
    # `connected`, `receive`, `tick` and `closed` are the whole protocol,
    # with the clock given, and write nothing: each returns the octets
    # to send. The thread in `start` is the socket around them. So the
    # unit tests drive every timer without one.
    class Client

      # Section 6: "If the router has never issued a successful query
      # against a particular cache, it SHOULD retry periodically using
      # the default Retry Interval". A cache entry's `retry` sets
      # another, which a lab whose cache starts late wants.
      DEFAULT_REFRESH = End_of_data::REFRESH
      DEFAULT_RETRY = End_of_data::RETRY
      DEFAULT_EXPIRE = End_of_data::EXPIRE

      KEYS = %w[address port preference retry].freeze

      # The longest PDU read from a cache before it is called corrupt: an
      # Error Report or a Router Key can be long, a prefix is 32 octets.
      MAX_PDU = 64 << 10

      CONNECT_TIMEOUT = 5
      TICK = 0.5

      attr_reader :address, :port, :preference, :version, :session_id, :serial,
                  :state, :refresh, :retry, :expire, :since, :last_error

      # config: a cache entry of the rpki: block. :clock is a monotonic
      # ->() in seconds, :logger a ->(level, message), :events a
      # ->(what, message, data) for BGP::Events.
      def self.check(config)
        raise ArgumentError, "rpki: a cache is a mapping, got #{config.inspect}" unless config.is_a?(Hash)
        unknown = config.keys.collect(&:to_s) - KEYS
        raise ArgumentError, "rpki: cache: unknown key(s) #{unknown.join(', ')}: use #{KEYS.join(', ')}" unless unknown.empty?
        raise ArgumentError, 'rpki: a cache needs an address' unless config['address']
        IPAddr.new(config['address'].to_s)
        port = Integer(config.fetch('port', PORT))
        raise ArgumentError, "rpki: cache #{config['address']}: port #{port} is not 1 to 65535" unless (1..65_535).cover?(port)
        Integer(config.fetch('preference', 1))
        Integer(config.fetch('retry', DEFAULT_RETRY)).tap do |r|
          raise ArgumentError, "rpki: cache #{config['address']}: retry #{r} is below 1 second" if r < 1
        end
        config
      rescue IPAddr::Error, TypeError => e
        raise ArgumentError, "rpki: cache #{config['address'].inspect}: #{e.message}"
      end

      def initialize(config, arg = {})
        Client.check(config)
        @address = IPAddr.new(config['address'].to_s).to_s
        @port = Integer(config.fetch('port', PORT))
        @preference = Integer(config.fetch('preference', 1))
        @clock = arg[:clock] || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
        @logger = arg[:logger]
        @events = arg[:events]
        @listeners = []
        @lock = Mutex.new
        @version = VERSION
        @refresh = DEFAULT_REFRESH
        @retry = Integer(config.fetch('retry', DEFAULT_RETRY))
        @expire = DEFAULT_EXPIRE
        @vrps = Vrps.new
        @data = Set.new        # this cache's VRP keys, as the last End of Data left them
        @expire_at = nil       # when @data goes, section 6
        @state = 'idle'
        @since = Time.now
        @negotiated = false
      end

      def name ; @address.include?(':') ? "[#{@address}]:#{@port}" : "#{@address}:#{@port}" ; end

      # Runs block with this client whenever its VRPs change.
      def on_change(&block) ; @listeners << block ; self ; end

      # The VRPs this cache gave, none once they expire.
      def vrps ; @lock.synchronize { @vrps } ; end

      # True while the data is there: synchronised once, and not expired.
      def synced? ; @lock.synchronize { !@expire_at.nil? } ; end

      def to_h
        @lock.synchronize do
          c = @vrps.counts
          { :address => @address, :port => @port, :mode => 'tcp', :preference => @preference,
            :state => @state, :version => @negotiated ? @version : nil, :session_id => @session_id,
            :serial => @serial, :vrps_v4 => c[:v4], :vrps_v6 => c[:v6],
            :refresh => @refresh, :retry => @retry, :expire => @expire,
            :since => @since.utc.strftime('%Y-%m-%dT%H:%M:%SZ'), :last_error => @last_error }
        end
      end

      ### The protocol, with the clock given

      # The transport is up. Section 8.1: a Serial Query when this cache's
      # data is still there and its Session ID known, else a Reset Query.
      def connected(now = @clock.call)
        @lock.synchronize do
          @negotiated = false
          @in_answer = nil
          set_state('connected')
          [first_query]
        end
      end

      # One PDU from the cache: [octets to send, whether to close].
      def receive(octets, now = @clock.call)
        changed = false
        out = @lock.synchronize do
          r, changed = read(octets.b, now)
          r
        end
        notify if changed
        out
      end

      # What waits on the clock: the data expiring, and the next query at
      # the Refresh Interval, or after a failed one at the Retry Interval.
      # Returns the octets to send.
      def tick(now = @clock.call)
        expired = false
        out = @lock.synchronize do
          if @expire_at && now >= @expire_at
            expired = flush("its data expired, #{@expire} s after the last End of Data (RFC 8210 section 6)")
          end
          if %w[connected up].include?(@state) && @in_answer.nil? && @query_at && now >= @query_at
            @query_at = nil
            [query]
          else
            []
          end
        end
        notify if expired
        out
      end

      # The transport went. The data stays until it expires (section 6);
      # the next connection is at the Retry Interval.
      def closed(why, now = @clock.call)
        @lock.synchronize do
          @in_answer = nil
          @negotiated = false
          @last_error = why if why
          @connect_at ||= now + @retry
          set_state('down', why)
        end
      end

      # When the next connection may be tried, then forgets it.
      def connect_at ; @lock.synchronize { @connect_at } ; end

      ### The socket

      def start
        @stopping = false
        @thread = Thread.new { run }
        self
      end

      def stop
        @stopping = true
        @lock.synchronize { @sock&.close rescue nil }
        @thread&.join(2)
        @thread&.kill
        self
      end

      private

      def set_state(state, why = nil)
        return if @state == state
        @state = state
        @since = Time.now
        event(state, "#{name} #{state}#{why ? ": #{why}" : ''}", :cache => name, :state => state)
      end

      def first_query
        @expire_at && @session_id && @serial ? query : reset_query
      end

      def query
        return reset_query unless @session_id && @serial && @expire_at
        @asked = :serial
        Serial_query.new(@session_id, @serial).tap { |p| p.version = @version }.encode
      end

      def reset_query
        @asked = :reset
        Reset_query.new.tap { |p| p.version = @version }.encode
      end

      # Under @lock. [[octets to send, close?], whether the VRPs changed].
      def read(octets, now)
        version, type = octets.unpack('CC')
        return error_from_cache(octets, now) if type == 10
        # Section 7: before negotiation, a version 0 answer to a version 1
        # query is a downgrade the router "MUST either" take "or terminate
        # the connection"; this one takes it. A Serial Notify then is
        # ignored, whatever its version.
        unless @negotiated
          return [[[], false], false] if type == 0
          if version == 0 && @version == 1
            @version = 0
            event('downgraded', "#{name} answered in version 0", :cache => name, :version => 0)
          end
        end
        findings = Validation.check(octets, negotiated: @negotiated ? @version : nil)
        return [error(findings.first.code, octets, findings.first.detail), false] unless findings.empty?
        case type
        when 0 then [serial_notify(Serial_notify.new(octets)), false]
        when 3 then cache_response(Cache_response.new(octets))
        when 4, 6 then [prefix(Pdu.factory(octets)), false]
        when 7 then end_of_data(End_of_data.new(octets), now)
        when 8 then [cache_reset, false]
        when 9 then [[[], false], false] # Router Keys are BGPsec's, not read here
        else [error(0, octets, "a cache does not send PDU type #{type}"), false]
        end
      end

      # Section 8.2: a hint to ask now. Ignored while an answer is coming.
      def serial_notify(pdu)
        return [[], false] if @in_answer || pdu.session_id != @session_id
        @query_at = nil
        [[query], false]
      end

      # Returns [[octets, close?], changed].
      def cache_response(pdu)
        return [error(0, pdu.encode, 'a Cache Response inside another answer'), false] if @in_answer
        # Section 5.1: a Session ID that differs, answering a Serial Query,
        # "MUST immediately terminate the session with an Error Report PDU
        # with code 0", and "the router MUST flush all data learned from
        # that cache".
        if @asked == :serial && pdu.session_id != @session_id
          was = @session_id
          changed = flush("its Session ID changed from #{was} to #{pdu.session_id}")
          return [error(0, pdu.encode, "Session ID #{pdu.session_id}, where it was #{was}"), changed]
        end
        @negotiated = true
        set_state('up')
        @answer_session = pdu.session_id
        # A Reset Query's answer is the whole table (5.5); a Serial Query's
        # the changes to what is there.
        @in_answer = { :reset => @asked == :reset, :add => Set.new, :drop => Set.new }
        [[[], false], false]
      end

      # Section 12, codes 6 and 7, against the data as this answer leaves it.
      def prefix(pdu)
        return error(0, pdu.encode, 'a prefix outside an answer') unless @in_answer
        a = @in_answer
        key = pdu.key.freeze
        has = a[:reset] ? a[:add].include?(key) : (@data.include?(key) && !a[:drop].include?(key)) || a[:add].include?(key)
        if pdu.announce?
          return error(7, pdu.encode, "#{pdu.prefix} max #{pdu.max_length} AS #{pdu.asn} is there already") if has
          a[:add] << key
        else
          return error(6, pdu.encode, "#{pdu.prefix} max #{pdu.max_length} AS #{pdu.asn} is not there") unless has
          a[:add].delete(key)
          a[:drop] << key
        end
        [[], false]
      end

      # Section 5.8: the answer is whole. It becomes the data, the serial
      # and the timers. Returns [[octets, close?], changed].
      def end_of_data(pdu, now)
        return [error(0, pdu.encode, 'an End of Data outside an answer'), false] unless @in_answer
        if pdu.session_id != @answer_session
          return [error(0, pdu.encode, "End of Data Session ID #{pdu.session_id}, the answer's is #{@answer_session}"), false]
        end
        a = @in_answer
        @in_answer = nil
        before = @data
        @data = a[:reset] ? a[:add] : (@data - a[:drop]) | a[:add]
        @session_id = pdu.session_id
        @serial = pdu.serial
        if @version == 1
          @refresh, @retry, @expire = pdu.refresh, pdu.retry, pdu.expire
        end
        @expire_at = now + @expire
        @query_at = now + @refresh
        @last_error = nil
        @vrps = Vrps.new(@data.to_a)
        added, removed = (@data - before).size, (before - @data).size
        event('synced', "#{name} serial #{@serial}: #{added} added, #{removed} removed, #{@data.size} VRPs",
              :cache => name, :serial => @serial, :added => added, :removed => removed, :vrps => @data.size)
        [[[], false], added + removed > 0]
      end

      # Section 8.3: "it MUST issue a Reset Query".
      def cache_reset
        @in_answer = nil
        [[reset_query], false]
      end

      # An Error Report from the cache: [[octets, close?], changed]. Code
      # 2, No Data Available, keeps the session and asks again at the
      # Retry Interval (8.4); a fatal code ends it (12). None is answered
      # (5.11).
      def error_from_cache(octets, now)
        report = Error_report.new(octets)
        @in_answer = nil
        @last_error = "#{report.name} (#{report.code})#{report.text.empty? ? '' : ": #{report.text}"}"
        event('error_received', "#{name}: #{@last_error}", :cache => name, :code => report.code)
        # Section 5.1: a Session ID that differs, which a cache that
        # restarted answers a Serial Query with as code 0, and "the router
        # MUST flush all data learned from that cache". The next
        # connection then starts with a Reset Query.
        changed = report.code == 0 && @asked == :serial && flush('it answered the Serial Query with Corrupt Data')
        [error_reply(report, now), changed]
      end

      def error_reply(report, now)
        if report.code == 4 && !@negotiated && @version == 1
          # Section 7: the cache "may terminate the connection, perhaps
          # with a version 0 Error Report PDU. In this case, the router MAY
          # retry the connection using protocol version 0."
          @version = 0
          @connect_at = now
          return [[], true]
        end
        if report.fatal?
          @connect_at = now + @retry
          return [[], true]
        end
        @query_at = now + @retry
        [[], false]
      end

      # An Error Report for octets, and whether section 12 ends the
      # session for its code.
      def error(code, octets, detail)
        report = Error_report.new(code, octets.byteslice(0, 1024), detail).tap { |p| p.version = @version }
        @in_answer = nil
        @last_error = "sent #{report.name} (#{code}): #{detail}"
        event('error_sent', "#{name}: #{@last_error}", :cache => name, :code => code)
        [[report.encode], report.fatal?]
      end

      # Under @lock. Drops this cache's data; true when there was some.
      def flush(why)
        had = !@data.empty? || !@expire_at.nil?
        @data = Set.new
        @vrps = Vrps.new
        @expire_at = nil
        @serial = nil
        @session_id = nil
        event('expired', "#{name}: #{why}", :cache => name) if had
        had
      end

      def notify ; @listeners.each { |l| l.call(self) } ; end

      def event(what, message, data)
        @events&.call(what, message, data)
        @logger&.call(:info, "rpki: #{message}")
      end

      def run
        until @stopping
          wait_to_connect
          break if @stopping
          begin
            sock = Socket.tcp(@address, @port, connect_timeout: CONNECT_TIMEOUT)
            sock.setsockopt(Socket::SOL_SOCKET, Socket::SO_KEEPALIVE, true)
          rescue SystemCallError, SocketError, IOError => e
            closed("connect: #{e.message}")
            next
          end
          @lock.synchronize { @sock = sock ; @connect_at = nil }
          converse(sock)
          sock.close rescue nil
        end
      end

      def wait_to_connect
        until @stopping
          at = connect_at
          return if at.nil? || @clock.call >= at
          sleep TICK
          tick
        end
      end

      def converse(sock)
        connected.each { |o| sock.write(o) }
        buffer = ''.b
        until @stopping
          tick.each { |o| sock.write(o) }
          next unless sock.wait_readable(TICK)
          buffer << sock.readpartial(4096)
          if buffer.bytesize >= HEADER && buffer.unpack1('@4N') > MAX_PDU
            out, = @lock.synchronize { error(0, buffer, "Length #{buffer.unpack1('@4N')} is more than #{MAX_PDU}") }
            out.each { |o| sock.write(o) }
            return closed('a PDU too long')
          end
          pdus, buffer = Rtr.pdus(buffer)
          pdus.each do |pdu|
            out, close = receive(pdu.encode)
            out.each { |o| sock.write(o) }
            return closed(@last_error) if close
          end
        end
      rescue EOFError
        closed('the cache closed the connection')
      rescue IOError, SystemCallError => e
        closed(e.message) unless @stopping
      end
    end
  end
end
