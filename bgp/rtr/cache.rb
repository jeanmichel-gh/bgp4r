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
require 'bgp/events'
require 'bgp/fault'

module BGP
  module Rtr

    # A request the caller can fix: an HTTP 400. An ArgumentError, so
    # Sim::Http maps it without knowing this class.
    class Refused < ArgumentError ; end

    # An RTR cache: a table of VRPs, the serials it went through, and
    # the routers connected to it. It answers each router's queries as
    # RFC 8210 section 8 draws them, sends Serial Notify when the table
    # changes, and runs BGP::Fault::RTR and the RTR behaviours on
    # request. `bgp4r-rtr` (bgp/rtr/server.rb) reads the node file and
    # serves this over TCP and HTTP. docs/design/bgp-operations.md 7b,
    # docs/rpki.md.
    #
    #   cache = Rtr::Cache.new('vrps' => [{ 'prefix' => '192.0.2.0/24', 'asn' => 65001 }])
    #   cache.listen('127.0.0.1', 0)
    #   cache.load([...])     # a new serial, and a Serial Notify to every router
    #
    # `receive` takes one PDU from a router and returns what to send
    # back, so the tests drive every answer without a socket. `tick`
    # runs what waits on time, with the clock given, so they drive that
    # too.
    class Cache

      # Section 8.2: "The cache MUST rate-limit Serial Notifies to no
      # more frequently than one per minute."
      NOTIFY_EVERY = 60

      # The serials kept to answer a Serial Query from. An older serial
      # gets a Cache Reset (section 5.3).
      HISTORY = 100

      # The longest PDU read from a router. A router sends 8 and 12
      # octet queries and Error Reports; a Length past this is corrupt.
      MAX_PDU = 64 << 10

      # How much of a PDU an Error Report carries back (section 5.11:
      # "the Erroneous PDU field MAY be truncated").
      MAX_ENCAPSULATED = 1024

      # How long a behaviour runs without `away`.
      AWAY = 60

      KEYS = %w[listen api session_id refresh retry expire notify_every history vrps watch].freeze

      Events.register_kind(:rtr)

      # One router's connection: where from, the version agreed, and the
      # answer a behaviour holds for its next Serial Query.
      class Session
        attr_reader :name, :connected_at
        attr_accessor :version, :reset_next, :fault, :serial, :last_query, :socket

        def initialize(name, socket = nil, now = Time.now)
          @name = name
          @socket = socket
          @connected_at = now
          @version = nil
          @reset_next = false
          @lock = Mutex.new
        end

        def negotiated? ; !@version.nil? ; end

        # Writes octets, under a lock, since Serial Notify comes from
        # another thread. False once the router has gone.
        def write(octets)
          return false unless @socket
          @lock.synchronize { @socket.write(octets) }
          true
        rescue IOError, SystemCallError
          false
        end

        def close
          @socket.close if @socket && !@socket.closed?
        rescue IOError, SystemCallError
          nil
        end

        def to_h
          { :router => @name, :version => @version, :connected_at => @connected_at.utc.strftime('%Y-%m-%dT%H:%M:%SZ'),
            :serial => @serial, :last_query => @last_query, :reset_next => @reset_next, :fault => @fault }
        end
      end

      attr_reader :session_id, :serial, :refresh, :retry, :expire, :notify_every, :events

      # config: the node file's keys, as Strings (KEYS). :clock is a
      # monotonic ->() in seconds, :logger a ->(level, message).
      def initialize(config = {}, arg = {})
        config = config.transform_keys(&:to_s)
        unknown = config.keys - KEYS
        raise Refused, "unknown keys #{unknown.join(', ')}; a node file has #{KEYS.join(', ')}" unless unknown.empty?
        @clock = arg[:clock] || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
        @logger = arg[:logger]
        # Section 5.1: "A seconds-since-epoch timestamp value such as the
        # POSIX time() function makes a good Session ID value."
        @session_id = Integer(config['session_id'] || (Time.now.to_i & 0xffff)) & 0xffff
        @refresh = Integer(config['refresh'] || End_of_data::REFRESH)
        @retry = Integer(config['retry'] || End_of_data::RETRY)
        @expire = Integer(config['expire'] || End_of_data::EXPIRE)
        @notify_every = Float(config['notify_every'] || NOTIFY_EVERY)
        @history_size = Integer(config['history'] || HISTORY)
        @events = Events.new
        @lock = Mutex.new
        @sessions = []
        @serial = 0
        @vrps = Set.new
        @history = { 0 => @vrps }
        @notify_pending = false
        @last_notify = nil
        @behaviour = nil
        timing_warnings.each { |w| log(:warn, w) }
        load(config['vrps'] || [], 'file') unless (config['vrps'] || []).empty?
        # No router has the table yet, so none needs telling of it.
        @notify_pending = false
      end

      # Section 6's ranges, which a lab may leave on purpose: a short
      # Expire, say, to see the data dropped. Said, not refused.
      def timing_warnings
        w = []
        w << "refresh #{@refresh} is outside section 6's 1 to 86400" unless (1..86_400).cover?(@refresh)
        w << "retry #{@retry} is outside section 6's 1 to 7200" unless (1..7200).cover?(@retry)
        w << "expire #{@expire} is outside section 6's 600 to 172800" unless (600..172_800).cover?(@expire)
        w << "expire #{@expire} is not larger than refresh and retry, which section 6 says it MUST be" unless
          @expire > [@refresh, @retry].max
        w << "notify_every #{@notify_every} is under section 8.2's one a minute" if @notify_every < NOTIFY_EVERY
        w
      end

      # The Session ID a session of this version is answered with.
      # Section 5.1: caches "SHOULD NOT use the same Session ID across
      # multiple protocol versions", so version 0's is the next one.
      def session_id_for(version) ; version.zero? ? (@session_id + 1) & 0xffff : @session_id ; end

      ### The table

      # A VRP from the node file or the API, as its key: [address,
      # prefix length, max length, asn]. Refused when it cannot be one.
      def self.vrp(entry)
        h = entry.transform_keys(&:to_s)
        unknown = h.keys - %w[prefix max_length asn]
        raise Refused, "a VRP has prefix, max_length and asn, not #{unknown.join(', ')}" unless unknown.empty?
        raise Refused, "a VRP needs a prefix and an asn: #{entry.inspect}" unless h['prefix'] && h['asn']
        address, length = h['prefix'].to_s.split('/')
        ip = IPAddr.new(address.to_s)
        bits = ip.ipv4? ? 32 : 128
        length = Integer(length || bits)
        max = Integer(h['max_length'] || length)
        asn = Integer(h['asn'])
        raise Refused, "#{h['prefix']}: Max Length #{max} is not between #{length} and #{bits}" unless (length..bits).cover?(max)
        raise Refused, "AS #{asn} does not fit 32 bits" unless (0..0xffff_ffff).cover?(asn)
        [ip.mask(length).to_s, length, max, asn].freeze
      rescue IPAddr::Error => e
        raise Refused, "#{entry.inspect}: #{e.message}"
      end

      def self.vrp_pdu(key, version, announce = true)
        klass = key[0].include?(':') ? Ipv6_prefix : Ipv4_prefix
        klass.new("#{key[0]}/#{key[1]}", key[2], key[3], announce).tap { |p| p.version = version }
      end

      # 'address:port', the address in brackets for IPv6, and an IPv4
      # address mapped into IPv6 written as IPv4.
      def self.router_name(addr)
        ip = addr.ipv6_v4mapped? ? addr.ipv6_to_ipv4.ip_address : addr.ip_address
        ip.include?(':') ? "[#{ip}]:#{addr.ip_port}" : "#{ip}:#{addr.ip_port}"
      end

      def self.vrp_hash(key) ; { :prefix => "#{key[0]}/#{key[1]}", :max_length => key[2], :asn => key[3] } ; end

      # The whole table becomes vrps. A change is a new serial, kept in
      # the history, and a Serial Notify waiting for `tick`. Returns
      # what changed.
      def load(vrps, source = 'api')
        list = Set.new(Array(vrps).collect { |v| Cache.vrp(v) })
        update(source) { list }
      end

      # Adds and removes VRPs from the table as it is.
      def change(announce: [], withdraw: [], source: 'api')
        add = Array(announce).collect { |v| Cache.vrp(v) }
        drop = Array(withdraw).collect { |v| Cache.vrp(v) }
        update(source) { |now| (now - drop) | add }
      end

      def vrp_keys ; @lock.synchronize { @vrps.to_a } ; end

      ### What a router is answered

      # One PDU from a router, as octets: [the octets to send back, and
      # whether to close the session].
      def receive(session, octets)
        octets = octets.b
        version, type = octets.unpack('CC')
        return error_from_router(session, octets) if type == 10
        findings = Validation.check(octets, negotiated: session.version)
        return error(session, findings.first.code, octets, findings.first.detail) unless findings.empty?
        # Section 7: "A router MUST start each transport connection by
        # issuing either a Reset Query or a Serial Query", and nothing
        # else in section 5 comes from a router.
        unless [1, 2].include?(type)
          return error(session, 3, octets, "a router sends a Serial Query or a Reset Query, not PDU type #{type}")
        end
        # Section 7: "If a cache which supports version 1 receives a query
        # from a router which specifies version 0, the cache MUST
        # downgrade to protocol version 0".
        unless session.negotiated?
          session.version = version
          publish(session, 'negotiated', "version #{version}", :version => version)
        end
        query(session, type, octets)
      end

      # Section 8.1 to 8.4: a Reset Query is the whole table, a Serial
      # Query the changes since its serial, or a Cache Reset when they
      # are not kept.
      def query(session, type, octets)
        v = session.version
        sid = session_id_for(v)
        q = type == 1 ? Serial_query.new(octets) : nil
        session.last_query = q ? "serial #{q.serial}" : 'reset'
        case behaviour_now
        when :rtr_silent
          publish(session, 'ignored', "#{session.last_query} query, behaviour rtr_silent")
          return [[], false]
        when :rtr_no_data
          return error(session, 2, octets, 'behaviour rtr_no_data')
        end
        if q && q.session_id != sid
          # Section 5.1: the party "which detects the mismatch MUST
          # immediately terminate the session with an Error Report PDU
          # with code 0".
          return error(session, 0, octets, "Session ID #{q.session_id}, where this cache's is #{sid}")
        end
        if session.fault
          name, session.fault = session.fault, nil
          publish(session, 'fault_sent', "#{name}, for the #{session.last_query} query", :fault => name.to_s)
          return [Fault.rtr(name, sid), false]
        end
        @lock.synchronize do
          if q.nil?
            session.reset_next = false
            return answer(session, sid, @vrps, Set.new, 'reset')
          end
          old = @history[q.serial]
          if session.reset_next || old.nil?
            why = session.reset_next ? 'behaviour rtr_cache_reset' : "serial #{q.serial} is not kept"
            session.reset_next = false
            publish(session, 'cache_reset', why, :serial => q.serial)
            return [[Cache_reset.new.tap { |p| p.version = v }.encode], false]
          end
          # Section 5.3: "the minimum set of changes", withdrawals first.
          answer(session, sid, @vrps - old, old - @vrps, "serial #{q.serial}")
        end
      end

      ### Time

      # What waits on the clock: a behaviour that has run its time, and a
      # Serial Notify held back by notify_every. The server calls it
      # every TICK seconds.
      def tick(now = @clock.call)
        sessions = nil
        @lock.synchronize do
          if @behaviour && now >= @behaviour[:until]
            publish(nil, 'behaviour_end', @behaviour[:name].to_s, :behaviour => @behaviour[:name].to_s)
            @behaviour = nil
          end
          due = @notify_pending && !(@behaviour && @behaviour[:name] == :rtr_silent)
          if due && (@last_notify.nil? || now - @last_notify >= @notify_every)
            @notify_pending = false
            sessions = @sessions.select(&:negotiated?)
            # One sent to no router does not hold the next one back.
            @last_notify = now unless sessions.empty?
          end
        end
        sessions&.each { |s| notify(s) }
      end

      ### Sessions over TCP

      def listen(bind, port)
        @server = TCPServer.new(bind, port)
        @accept = Thread.new { accept_loop }
        self
      end

      def port ; @server&.addr&.[](1) ; end

      def sessions ; @lock.synchronize { @sessions.dup } ; end

      def stop
        @server.close if @server && !@server.closed?
        @accept&.join(2)
        sessions.each(&:close)
        self
      end

      ### Faults and behaviours

      # One BGP::Fault::RTR case, the answer to the next query of every
      # router that agreed version 1, or of the one named router
      # ('address:port'). A Serial Notify goes out now to bring the query
      # on. It waits for a query because a router reads what comes while
      # it has none open as it likes: FRR 10.7.1 drops it unread.
      def fault(body)
        name = body['name'].to_s
        raise Refused, "fault needs a name, one of #{Fault.rtr_names.join(', ')}" if name.empty?
        raise Refused, "unknown RTR fault #{name.inspect}, one of #{Fault.rtr_names.join(', ')}" unless
          Fault.rtr_names.include?(name.to_sym)
        targets = sessions.select { |s| s.version == 1 && (body['router'].nil? || s.name == body['router']) }
        raise Refused, "no router has agreed version 1#{" as #{body['router']}" if body['router']}; the RTR faults are version 1's" if targets.empty?
        targets.each do |s|
          s.fault = name.to_sym
          publish(s, 'fault', "#{name}, the answer to the next query", :fault => name)
          notify(s)
        end
        { :fault => name, :routers => targets.collect(&:name) }
      end

      # One of BGP::Fault::RTR_BEHAVIOURS, for away seconds (AWAY when not
      # given). A new one replaces the one running; away 0 ends it.
      #
      # * rtr_no_data: every query is answered with Error Report 2, "No
      #   Data Available" (section 8.4), which is not fatal.
      # * rtr_silent: queries are read and not answered, and no Serial
      #   Notify goes out. The router keeps the data until Expire
      #   (section 6).
      # * rtr_cache_reset: each router's next Serial Query is answered
      #   with Cache Reset (section 8.3), and a Serial Notify goes out
      #   now to bring that query on. It runs until each router has had
      #   its Cache Reset; away does not apply.
      def behaviour(body)
        name = body['name'].to_s
        names = Fault.rtr_behaviour_names.collect(&:to_s)
        raise Refused, "behaviour needs a name, one of #{names.join(', ')}" if name.empty?
        raise Refused, "unknown RTR behaviour #{name.inspect}, one of #{names.join(', ')}" unless names.include?(name)
        away = Float(body['away'] || AWAY)
        if name == 'rtr_cache_reset'
          targets = sessions.select(&:negotiated?)
          targets.each { |s| s.reset_next = true ; notify(s) }
          publish(nil, 'behaviour', name, :behaviour => name, :routers => targets.collect(&:name))
          return { :behaviour => name, :routers => targets.collect(&:name) }
        end
        @lock.synchronize do
          @behaviour = { :name => name.to_sym, :until => @clock.call + away }
        end
        publish(nil, 'behaviour', name, :behaviour => name, :away => away)
        { :behaviour => name, :away => away }
      end

      ### The API's reads and actions, as Sim::Http calls them

      def act(name, body = {})
        body = {} if body.nil?
        case name
        when 'fault' then fault(body)
        when 'behaviour' then behaviour(body)
        when 'vrps' then vrps_action(body)
        else raise Refused, "unknown action #{name.inspect}"
        end
      end

      def status(_params = {})
        b = @lock.synchronize { @behaviour }
        { :bgp4r => BGP::VERSION, :session_id => @session_id, :session_id_v0 => session_id_for(0),
          :serial => @serial, :vrps => vrp_keys.size, :routers => sessions.size,
          :refresh => @refresh, :retry => @retry, :expire => @expire, :notify_every => @notify_every,
          :behaviour => b && b[:name].to_s, :listen => port }
      end

      def vrps(_params = {})
        { :serial => @serial, :vrps => vrp_keys.sort_by { |k| [k[0].include?(':') ? 1 : 0, IPAddr.new(k[0]).to_i, k[1], k[2], k[3]] }
                                             .collect { |k| Cache.vrp_hash(k) } }
      end

      def routers(_params = {}) ; { :routers => sessions.collect(&:to_h) } ; end

      def events_view(params = {})
        since = params['since']
        n = since.nil? ? nil : Integer(since, exception: false)
        raise Refused, "since must be an integer, got #{since.inspect}" if since && n.nil?
        { :seq => @events.seq, :events => @events.since(n).collect(&:to_h) }
      end

      private

      # The block takes the table and gives the new one, under the lock.
      def update(source)
        changed = nil
        @lock.synchronize do
          new_set = yield(@vrps)
          added, removed = new_set - @vrps, @vrps - new_set
          return { :serial => @serial, :announced => 0, :withdrawn => 0 } if added.empty? && removed.empty?
          @vrps = new_set.freeze
          @serial = (@serial + 1) & 0xffff_ffff
          @history[@serial] = @vrps
          @history.shift while @history.size > @history_size
          @notify_pending = true
          changed = { :serial => @serial, :announced => added.size, :withdrawn => removed.size }
        end
        publish(nil, 'vrps', "serial #{changed[:serial]}: #{changed[:announced]} announced, " \
                             "#{changed[:withdrawn]} withdrawn, from the #{source}", changed.merge(:source => source))
        changed
      end

      # Under @lock. A Cache Response, the payload, an End of Data.
      def answer(session, sid, announce, withdraw, what)
        v = session.version
        out = [Cache_response.new(sid).tap { |p| p.version = v }.encode]
        withdraw.each { |k| out << Cache.vrp_pdu(k, v, false).encode }
        announce.each { |k| out << Cache.vrp_pdu(k, v).encode }
        out << End_of_data.new(sid, @serial, @refresh, @retry, @expire).tap { |p| p.version = v }.encode
        session.serial = @serial
        publish(session, 'answer', "#{what} query: #{announce.size} announced, #{withdraw.size} withdrawn, serial #{@serial}",
                :query => what, :announced => announce.size, :withdrawn => withdraw.size, :serial => @serial)
        [out, false]
      end

      # An Error Report for octets, in the session's version (version 1
      # before one is agreed), and whether section 12 drops the session.
      def error(session, code, octets, detail)
        report = Error_report.new(code, octets.byteslice(0, MAX_ENCAPSULATED), detail)
        report.version = session.version || VERSION
        fatal = report.fatal?
        publish(session, 'error_sent', "#{report.name} (#{code}): #{detail}#{fatal ? ', closing' : ''}",
                :code => code, :name => report.name, :fatal => fatal)
        [[report.encode], fatal]
      end

      # Section 5.11: "An Error Report PDU MUST NOT be sent for an Error
      # Report PDU. If an erroneous Error Report PDU is received, the
      # session SHOULD be dropped." A fatal one drops it too (section 12).
      def error_from_router(session, octets)
        bad = Validation.check(octets, negotiated: session.version)
        report = Error_report.new(octets)
        close = !bad.empty? || report.fatal?
        detail = bad.empty? ? report.text : bad.first.to_s
        publish(session, 'error_received', "#{report.name} (#{report.code}): #{detail}#{close ? ', closing' : ''}",
                :code => report.code, :name => report.name, :text => report.text, :fatal => close)
        [[], close]
      end

      def notify(session)
        v = session.version
        # Said before it is written, so the query it brings on comes after.
        publish(session, 'notify', "serial #{@serial}", :serial => @serial)
        session.write(Serial_notify.new(session_id_for(v), @serial).tap { |p| p.version = v }.encode)
      end

      def behaviour_now
        @lock.synchronize do
          @behaviour = nil if @behaviour && @clock.call >= @behaviour[:until]
          @behaviour && @behaviour[:name]
        end
      end

      def publish(session, what, message, data = {})
        @events.publish(:kind => :rtr, :peer => session&.name, :message => "#{what}: #{message}",
                        :data => { :event => what }.merge(data))
        log(:info, "rtr #{session ? "#{session.name} " : ''}#{what}: #{message}")
      end

      def log(level, message) ; @logger&.call(level, message) ; end

      def accept_loop
        loop do
          sock = @server.accept
          Thread.new(sock) { |s| serve(s) }
        end
      rescue IOError, Errno::EBADF
        nil # stop closed the listening socket
      end

      # Section 9: "both caches and routers SHOULD enable keep-alives
      # when available in the chosen transport protocol."
      def serve(sock)
        sock.setsockopt(Socket::SOL_SOCKET, Socket::SO_KEEPALIVE, true)
        session = Session.new(Cache.router_name(sock.remote_address), sock)
        @lock.synchronize { @sessions << session }
        publish(session, 'connected', session.name)
        read_loop(session, sock)
      rescue IOError, SystemCallError
        nil
      ensure
        if session
          @lock.synchronize { @sessions.delete(session) }
          # Said before the socket goes, so whoever sees it go finds it.
          publish(session, 'closed', session.name)
          session.close
        end
      end

      def read_loop(session, sock)
        buffer = ''.b
        loop do
          buffer << sock.readpartial(4096)
          if buffer.bytesize >= HEADER && buffer.unpack1('@4N') > MAX_PDU
            out, = error(session, 0, buffer, "Length #{buffer.unpack1('@4N')} is more than the #{MAX_PDU} a router sends")
            out.each { |o| session.write(o) }
            return
          end
          pdus, buffer = Rtr.pdus(buffer)
          pdus.each do |pdu|
            out, close = receive(session, pdu.encode)
            out.each { |o| session.write(o) }
            return if close
          end
        end
      rescue EOFError
        nil
      end

      def vrps_action(body)
        unknown = body.keys - %w[vrps announce withdraw]
        raise Refused, "vrps takes vrps, or announce and withdraw, not #{unknown.join(', ')}" unless unknown.empty?
        return load(body['vrps']) if body.key?('vrps')
        change(announce: body['announce'] || [], withdraw: body['withdraw'] || [])
      end
    end
  end
end
