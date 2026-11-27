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
require 'bgp/version'
require 'bgp4r'
require 'bgp/bmp'
require 'bgp/bmp/routes'
require 'bgp/events'

module BGP
  module Bmp

    # A request the caller can fix: an HTTP 400. An ArgumentError, so
    # Sim::Http maps it without knowing this class.
    class Refused < ArgumentError ; end

    # A BMP station: what each monitored router sent, as JSON lines, and
    # its peers and their routes, for the HTTP API. `bgp4r-bmp`
    # (bgp/bmp/server.rb) serves it over TCP and HTTP.
    # docs/design/bgp-operations.md 8b, docs/bmp.md.
    #
    #   station = Bmp::Station.new(:lines => $stdout)
    #   station.listen('0.0.0.0', 5000)      # routers dial in
    #   station.connect('192.0.2.1', 5000)   # or the station dials
    #
    # `open`, `receive` and `close` take one router's connection a step
    # at a time, so the tests drive it without a socket.
    class Station

      # Where routers dial in when no port is given. RFC 7854 names no
      # port and IANA has none for BMP; 5000 is the one
      # docs/design/bgp-operations.md's examples use.
      PORT = 5000

      # Past this a Message Length is taken as corrupt and the session
      # closed, so a wrong length cannot make the station buffer without
      # end. A BGP message is at most 65535 octets (RFC 8654), and the
      # largest BMP message carries one plus its headers.
      MAX_MESSAGE = 1 << 20

      # The octets of a message that cannot be framed, in its line.
      MAX_HEX = 256

      # The JSON lines kept for /api/lines.
      KEEP_LINES = 10_000

      # RFC 7854 section 3.2: "Exponential backoff with a default initial
      # backoff of 30 seconds and a maximum of 720 seconds is suggested."
      BACKOFF = 30
      BACKOFF_MAX = 720

      Events.register_kind(:bmp)

      # One router's BMP session: where from, what its Initiation said,
      # its peers.
      class Router
        attr_reader :name, :connected_at, :peers, :findings
        attr_accessor :sys_name, :sys_descr, :initiated, :messages, :socket

        def initialize(name, now)
          @name = name
          @connected_at = now
          @peers = {}
          @findings = Hash.new(0)
          @messages = 0
        end

        def to_h
          { :router => @name, :sys_name => @sys_name, :sys_descr => @sys_descr,
            :connected_at => Station.iso(@connected_at), :messages => @messages,
            :peers => @peers.size, :up => @peers.values.count(&:up),
            :findings => @findings.sort.to_h }
        end
      end

      # A monitored peer, by RFC 7854 section 4.2's three fields that tell
      # peers apart: its type, its Distinguisher and its address.
      class Peer
        attr_reader :routes, :eor, :stats
        attr_accessor :header, :up, :session_info, :last_up, :last_down, :down_reason

        def initialize
          @routes = { 'pre_policy' => {}, 'post_policy' => {}, 'loc_rib' => {} }
          @eor = []
          @stats = {}
          @up = false
        end

        def self.key(header) ; [header.peer_type, header.distinguisher, header.address] ; end

        def ident
          { :peer_type => @header.peer_type, :distinguisher => @header.distinguisher,
            :address => @header.address, :asn => @header.asn, :bgp_id => @header.bgp_id }
        end

        def clear
          @routes.each_value(&:clear)
          @eor.clear
        end

        def to_h
          ident.merge(:up => @up, :last_up => @last_up && Station.iso(@last_up),
                      :last_down => @last_down && Station.iso(@last_down), :down_reason => @down_reason,
                      :routes => @routes.transform_values(&:size).to_h, :end_of_rib => @eor.sort.collect { |a, s| { :afi => a, :safi => s } },
                      :stats => @stats.sort.collect(&:last))
        end
      end

      # :lines, an IO for the JSON lines, or nil; :logger a
      # ->(level, message); :clock a ->() giving the Time of reception;
      # :sleep a ->(seconds), how a dialing station waits.
      def initialize(arg = {})
        @out = arg[:lines]
        @logger = arg[:logger]
        @clock = arg[:clock] || -> { Time.now }
        @sleep = arg[:sleep] || ->(seconds) { sleep(seconds) }
        @keep = arg[:keep_lines] || KEEP_LINES
        @events = Events.new
        @lock = Mutex.new
        @routers = {}
        @lines = []
        @seq = 0
        @servers = []
        @threads = []
      end

      def self.iso(time) ; time.utc.strftime('%Y-%m-%dT%H:%M:%S.%LZ') ; end

      # 'address:port', the address in brackets for IPv6.
      def self.name_of(addr)
        ip = addr.ipv6_v4mapped? ? addr.ipv6_to_ipv4.ip_address : addr.ip_address
        ip.include?(':') ? "[#{ip}]:#{addr.ip_port}" : "#{ip}:#{addr.ip_port}"
      end

      ### One router's session, a step at a time

      # A router's session begins: its Router.
      def open(name)
        router = Router.new(name, @clock.call)
        @lock.synchronize do
          @routers[name] = router
          line(router, 'connected', nil)
        end
        publish(router, 'connected', 'BMP session up')
        router
      end

      # One message's octets from a router. Returns false when the
      # session is to close: after a Termination (section 4.5: "the
      # monitoring station MUST close the TCP session"), or when the
      # octets cannot be framed.
      def receive(router, octets)
        @lock.synchronize { take(router, octets) }
      end

      # The session ended, for reason. Its peers' routes go with it: the
      # router sends them again in the next session's dump (section 3.3).
      def close(router, reason)
        @lock.synchronize do
          return unless @routers.delete(router.name)
          line(router, 'closed', nil, :reason => reason)
        end
        publish(router, 'closed', "BMP session closed: #{reason}", :reason => reason)
      end

      ### Over TCP

      # Routers dial in on bind:port; port 0 lets the system pick, which
      # `port` then gives.
      def listen(bind, port)
        server = TCPServer.new(bind, port)
        @servers << server
        @threads << Thread.new { accept_loop(server) }
        @port ||= server.addr[1]
        server.addr[1]
      end

      # The first port it listens on, kept once it stops.
      attr_reader :port

      # The station dials host:port, and again after each session ends or
      # a dial fails, waiting `backoff` between.
      def connect(host, port)
        @threads << Thread.new do
          failures = 0
          loop do
            begin
              sock = TCPSocket.new(host, port)
              failures = 0
              serve(sock)
            rescue IOError, SystemCallError, SocketError => e
              log(:warn, "bmp dial #{host}:#{port}: #{e.message}")
            end
            failures += 1
            @sleep.call(Station.backoff(failures))
          end
        end
      end

      # The wait before dial n, n from 1: 30 s doubling to 720 s.
      def self.backoff(n) ; [BACKOFF * (2**(n - 1)), BACKOFF_MAX].min ; end

      def stop
        @threads.each(&:kill)
        @servers.each { |s| s.close unless s.closed? }
        # The line first: once its socket is closed, the reading thread
        # would close the session with its own reason.
        @lock.synchronize { @routers.values }.each do |r|
          close(r, 'station stopped')
          r.socket&.close
        end
        self
      end

      # Reads one router's socket to its end.
      def serve(sock)
        router = open(Station.name_of(sock.remote_address))
        router.socket = sock
        buffer = ''.b
        buffer, reason = feed(router, buffer << sock.readpartial(64 << 10)) until reason
      rescue EOFError
        reason = 'end of stream'
      rescue IOError, SystemCallError => e
        reason = e.message
      ensure
        sock.close unless sock.closed?
        close(router, reason) if router
      end

      # What came on a router's stream so far: each whole message taken,
      # and [what is left, nil], or [_, why] when the session is to close.
      def feed(router, buffer)
        list, rest, why = Station.frame(buffer)
        list.each { |o| return [rest, 'termination'] unless receive(router, o) }
        return [rest, nil] unless why
        @lock.synchronize { unframed(router, rest) }
        [rest, why]
      end

      # Whole messages off the front of buffer: [messages, rest, why],
      # why being set when what follows cannot be framed. A version other
      # than 3 frames nothing, since RFC 7854 section 4.1 defines the
      # header for 3 only; nor does a Message Length shorter than the
      # header or past MAX_MESSAGE.
      def self.frame(buffer)
        list = []
        while buffer.bytesize >= HEADER
          version, length = buffer.unpack('CN')
          return [list, buffer, "version #{version}"] if version != VERSION
          return [list, buffer, "Message Length #{length}"] if length < HEADER || length > MAX_MESSAGE
          break if buffer.bytesize < length
          list << buffer.byteslice(0, length)
          buffer = buffer.byteslice(length..)
        end
        [list, buffer, nil]
      end

      ### The API's reads, as Sim::Http calls them

      def act(name, _body = {}) ; raise Refused, "unknown action #{name.inspect}; bgp4r-bmp has none" ; end

      def status(_params = {})
        rs = routers_now
        { :bgp4r => BGP::VERSION, :listen => port, :routers => rs.size,
          :peers => rs.sum { |r| r.peers.size }, :lines => @seq }
      end

      def routers(_params = {}) ; { :routers => routers_now.collect(&:to_h) } ; end

      def peers(params = {})
        @lock.synchronize do
          list = select_routers(params).flat_map do |r|
            r.peers.values.collect { |p| { :router => r.name, :sys_name => r.sys_name }.merge(p.to_h) }
          end
          { :peers => list }
        end
      end

      # Every route, or those of ?router=, ?peer= (an address) and
      # ?view= (pre_policy, post_policy, loc_rib).
      def routes(params = {})
        view = params['view']
        raise Refused, "view is pre_policy, post_policy or loc_rib, not #{view.inspect}" if view && !%w[pre_policy post_policy loc_rib].include?(view)
        @lock.synchronize do
          list = []
          select_routers(params).each do |r|
            r.peers.each_value do |p|
              next if params['peer'] && p.header.address != params['peer']
              p.routes.each do |v, table|
                next if view && v != view
                table.each_value { |route| list << { :router => r.name, :sys_name => r.sys_name, :peer => p.ident, :view => v }.merge(route) }
              end
            end
          end
          { :routes => list }
        end
      end

      def events_view(params = {})
        { :seq => @events.seq, :events => @events.since(since(params)).collect(&:to_h) }
      end

      # The JSON lines kept, above ?since=.
      def lines(params = {})
        n = since(params) || 0
        @lock.synchronize { { :seq => @seq, :lines => @lines.select { |l| l[:seq] > n } } }
      end

      private

      def since(params)
        s = params['since']
        return nil if s.nil?
        n = Integer(s, exception: false)
        raise Refused, "since must be an integer, got #{s.inspect}" if n.nil?
        n
      end

      def routers_now ; @lock.synchronize { @routers.values } ; end

      def select_routers(params)
        r = params['router']
        r ? @routers.values.select { |x| x.name == r || x.sys_name == r } : @routers.values
      end

      # Under @lock: octets that cannot be framed, as a line before the
      # session closes. At most the first MAX_HEX octets are kept.
      def unframed(router, octets)
        findings = Validation.check(octets.byteslice(0, HEADER))
        findings.each { |f| router.findings[f.name] += 1 }
        line(router, 'undecoded', nil, { :hex => octets.byteslice(0, MAX_HEX).unpack1('H*') }, findings)
      end

      # Under @lock.
      def take(router, octets)
        router.messages += 1
        findings = Validation.check(octets)
        # Section 3.3: the router "MUST begin by sending an Initiation
        # message". The station records the break and reads on.
        type = octets.getbyte(5)
        if !router.initiated && type != Initiation::TYPE
          findings << Validation.finding(:no_initiation, "Message Type #{type} before an Initiation")
        end
        msg = decode(router, octets, findings)
        findings.each { |f| router.findings[f.name] += 1 }
        apply(router, msg) if msg
        extra = msg ? {} : { :hex => octets.unpack1('H*') }
        line(router, msg ? msg.hash_key.to_s : 'undecoded', msg && msg.to_hash.values.first, extra, findings)
        later = findings.reject(&:ignore?)
        publish(router, 'findings', later.collect(&:to_s).join('; '), :findings => later.collect { |f| f.name.to_s }) unless later.empty?
        !msg.is_a?(Termination)
      end

      # The message, read with the session of its peer's Peer Up, or nil
      # with a `decode` finding when the codec cannot read it.
      def decode(router, octets, findings)
        if Message::TYPES[octets.getbyte(5)] == Route_monitoring && octets.bytesize >= HEADER + PER_PEER
          p = router.peers[Peer.key(Per_peer.new(octets.byteslice(HEADER, PER_PEER)))]
          info = p&.session_info
        end
        Message.factory(octets, info)
      rescue StandardError => e
        findings << Validation.finding(:decode, "#{e.class}: #{e.message}")
        nil
      end

      def apply(router, msg)
        case msg
        when Initiation, Termination
          router.initiated = true if msg.instance_of?(Initiation)
          router.sys_name = msg.sys_name || router.sys_name
          router.sys_descr = msg.sys_descr || router.sys_descr
        when Peer_up
          p = peer(router, msg.peer)
          p.clear
          p.up = true
          p.last_up = @clock.call
          p.session_info = msg.session_info
          event(router, 'peer_up', "peer #{msg.peer.address} AS #{msg.peer.asn} up", p)
        when Peer_down
          p = peer(router, msg.peer)
          p.clear
          p.up = false
          p.last_down = @clock.call
          p.down_reason = msg.reason
          event(router, 'peer_down', "peer #{msg.peer.address} down, reason #{msg.reason}", p, :reason => msg.reason)
        when Route_monitoring then monitor(router, msg)
        when Stats_report
          p = peer(router, msg.peer)
          msg.stats.each { |s| p.stats[[s.type, s.afi.to_i, s.safi.to_i]] = s.to_hash }
        end
      end

      def peer(router, header)
        p = (router.peers[Peer.key(header)] ||= Peer.new)
        # The rest of the header may change: FRR 10.5.1's first Peer Down
        # has BGP ID 0.0.0.0, its Peer Up the peer's.
        p.header = header
        p
      end

      # RFC 7854 section 5: L clear is pre-policy, set post-policy;
      # RFC 9069: the Loc-RIB is a peer type of its own.
      def self.view(header)
        return 'loc_rib' if header.loc_rib?
        header.post_policy? ? 'post_policy' : 'pre_policy'
      end

      def monitor(router, msg)
        p = peer(router, msg.peer)
        table = p.routes[Station.view(msg.peer)]
        u = msg.update
        pa = u.path_attribute
        if (family = Routes.end_of_rib(u))
          p.eor << family unless p.eor.include?(family)
          event(router, 'end_of_rib', "peer #{msg.peer.address} End-of-RIB #{family.join('/')}", p, :afi => family[0], :safi => family[1])
        end
        Routes.withdrawn(u).each { |afi, safi, n| table.delete(Routes.key(afi, safi, n)) }
        attrs = pa ? pa.to_hash.reject { |k, _| %i[mp_reach mp_unreach].include?(k) } : {}
        Routes.announced(u).each do |afi, safi, n, next_hop|
          table[Routes.key(afi, safi, n)] =
            { :afi => afi, :safi => safi, :nlri => n.to_hash, :next_hop => next_hop || attrs[:next_hop], :path_attributes => attrs }
        end
      end

      # Under @lock: one JSON line, written and kept.
      def line(router, type, message, extra = {}, findings = [])
        @seq += 1
        l = { :seq => @seq, :time => Station.iso(@clock.call), :router => router.name, :sys_name => router.sys_name,
              :type => type }
        l[:message] = message if message
        l[:findings] = findings.collect { |f| { :name => f.name.to_s, :detail => f.detail } }
        l.merge!(extra)
        @lines << l
        @lines.shift(@lines.size - @keep) if @lines.size > @keep
        @out&.puts(JSON.generate(l))
      end

      def event(router, what, message, p, data = {}) ; publish(router, what, message, { :peer => p.ident }.merge(data)) ; end

      # Events never calls back into the station, so this runs under
      # @lock as well as outside it.
      def publish(router, what, message, data = {})
        @events.publish(:kind => :bmp, :peer => router.name, :message => "#{what}: #{message}",
                        :data => { :event => what, :sys_name => router.sys_name }.merge(data))
        log(:info, "bmp #{router.name} #{what}: #{message}")
      end

      def log(level, message) ; @logger&.call(level, message) ; end

      def accept_loop(server)
        loop do
          sock = server.accept
          Thread.new(sock) { |s| serve(s) }
        end
      rescue IOError, SystemCallError
        # The server closed: the station stopped.
      end
    end
  end
end
