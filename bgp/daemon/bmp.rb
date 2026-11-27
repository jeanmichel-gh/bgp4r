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
require 'bgp/bmp'
require 'bgp/bmp/routes'
require 'bgp/daemon/end_of_rib'

module BGP
  module Daemon

    # BMP in bgp4rd, RFC 7854: bgp4rd is the monitored router and dials
    # each station of the `bmp:` key.
    #
    #   bmp:
    #     stations: [{ address: 10.0.0.9, port: 5000 }]
    #     monitor: [pre_policy]
    #     stats_interval: 60
    #
    # To each station, once its session is up: an Initiation, then for
    # each Established peer a Peer Up with both OPENs, that peer's
    # Adj-RIB-In as Route Monitoring and an End-of-RIB for each family
    # the session negotiated (section 3.3). Then each UPDATE a peer sends
    # as a Route Monitoring, a Peer Down when a session ends, a Stats
    # Report for each peer every stats_interval seconds, and a Termination
    # when bgp4rd stops. Nothing a station sends is used (section 3.2:
    # "No BMP message is ever sent from the monitoring station to the
    # monitored router"); it is read and dropped.
    #
    # Only the global table's peers are monitored; a CE's session in a
    # VRF is not. The Adj-RIB-In is pre-policy, as received; post-policy
    # and the Loc-RIB (RFC 9069) come later.
    #
    # docs/design/bgp-operations.md 8c, docs/bmp.md section 7.
    class BmpMonitor

      KIND = BGP::Events.register_kind(:bmp)

      KEYS = %w[stations monitor stats_interval sys_name sys_descr].freeze
      STATION_KEYS = %w[address port retry].freeze
      MONITOR = %w[pre_policy].freeze

      # bgp4r-bmp's (bgp/bmp/station.rb): RFC 7854 names no port.
      PORT = 5000
      STATS_INTERVAL = 60

      # Section 3.2: "a default initial backoff of 30 seconds and a
      # maximum of 720 seconds is suggested".
      BACKOFF = 30
      BACKOFF_MAX = 720

      # Peer Down reasons, section 4.9.
      LOCAL_NOTIFICATION = 1
      LOCAL_NO_NOTIFICATION = 2
      REMOTE_NOTIFICATION = 3
      REMOTE_NO_NOTIFICATION = 4

      # RFC 4271 section 8.1.2's events, for reason 2's FSM Event.
      MANUAL_STOP = 2
      HOLD_TIMER_EXPIRES = 10

      # Termination reason 0, "Session administratively closed".
      ADMINISTRATIVELY_CLOSED = 0

      def self.check(config)
        raise ArgumentError, "bmp: a mapping with #{KEYS.join(', ')}, got #{config.inspect}" unless config.is_a?(Hash)
        unknown = config.keys.collect(&:to_s) - KEYS
        raise ArgumentError, "bmp: unknown key(s) #{unknown.join(', ')}: use #{KEYS.join(', ')}" unless unknown.empty?
        stations = config['stations']
        raise ArgumentError, 'bmp: stations is a list of at least one station' unless stations.is_a?(Array) && !stations.empty?
        stations.each do |s|
          raise ArgumentError, "bmp: a station is a mapping with #{STATION_KEYS.join(', ')}, got #{s.inspect}" unless s.is_a?(Hash)
          bad = s.keys.collect(&:to_s) - STATION_KEYS
          raise ArgumentError, "bmp: a station has #{STATION_KEYS.join(', ')}, not #{bad.join(', ')}" unless bad.empty?
          raise ArgumentError, "bmp: a station needs an address, got #{s.inspect}" unless s['address']
          port = Integer(s.fetch('port', PORT))
          raise ArgumentError, "bmp: port #{port} is not 1 to 65535" unless (1..65_535).cover?(port)
          Float(s['retry']) if s.key?('retry')
        end
        names = stations.collect { |s| [IPAddr.new(s['address'].to_s).to_s, Integer(s.fetch('port', PORT))] }
        raise ArgumentError, 'bmp: a station is listed twice' unless names.uniq.size == names.size
        monitor = Array(config.fetch('monitor', MONITOR))
        bad = monitor.collect(&:to_s) - MONITOR
        raise ArgumentError, "bmp: monitor #{bad.join(', ')}: this bgp4rd monitors #{MONITOR.join(', ')} only" unless bad.empty?
        interval = Float(config.fetch('stats_interval', STATS_INTERVAL))
        raise ArgumentError, "bmp: stats_interval #{interval} is not positive" unless interval.positive?
        config
      rescue IPAddr::Error, TypeError, ArgumentError => e
        raise ArgumentError, e.message.start_with?('bmp: ') ? e.message : "bmp: #{e.message}"
      end

      # What bgp4rd keeps of one peer's session, from its Established to
      # its end. A peer is up while it is the one in @peers for its
      # address.
      class Peer
        attr_reader :address, :routes, :neighbor
        attr_accessor :header, :session_info, :local_address, :local_port, :remote_port,
                      :notification, :notification_sent, :treat_as_withdraw_updates, :treat_as_withdraw_prefixes

        def initialize(address, neighbor)
          @address = address
          @neighbor = neighbor
          @routes = {}
          @treat_as_withdraw_updates = 0
          @treat_as_withdraw_prefixes = 0
        end
      end

      # One station: its address, its session and what waits to be sent.
      class Station
        attr_reader :address, :port, :retry
        attr_accessor :state, :socket, :queue, :connected_at, :sessions, :last_error, :sent

        def initialize(config)
          @address = IPAddr.new(config['address'].to_s).to_s
          @port = Integer(config.fetch('port', PORT))
          @retry = config.key?('retry') ? Float(config['retry']) : BACKOFF
          @state = 'connecting'
          @sessions = 0
          @sent = 0
        end

        def name ; @address.include?(':') ? "[#{@address}]:#{@port}" : "#{@address}:#{@port}" ; end

        # The wait before dial n, n from 1: retry doubling to 720 s.
        def backoff(n) ; [@retry * (2**(n - 1)), BACKOFF_MAX].min ; end

        def to_h
          { :station => name, :state => @state, :sessions => @sessions, :messages => @sent,
            :connected_at => @connected_at && @connected_at.utc.strftime('%Y-%m-%dT%H:%M:%SZ'), :last_error => @last_error }
        end
      end

      attr_reader :stations, :stats_interval

      # speaker: whose peers. :clock a ->() giving the time stamped on
      # each message; :sleep a ->(seconds), how a dial waits.
      def initialize(speaker, config, arg = {})
        BmpMonitor.check(config)
        @speaker = speaker
        @logger = arg[:logger]
        @clock = arg[:clock] || -> { Time.now }
        @sleep = arg[:sleep] || ->(seconds) { sleep(seconds) }
        @stats_interval = Float(config.fetch('stats_interval', STATS_INTERVAL))
        @sys_name = (config['sys_name'] || Socket.gethostname).to_s
        @sys_descr = (config['sys_descr'] || "bgp4r #{BGP::VERSION}").to_s
        @stations = config['stations'].collect { |s| Station.new(s) }
        @lock = Mutex.new
        @peers = {}
        @threads = []
      end

      # How long stop waits for a station's Termination to go.
      STOP_WAIT = 2

      def start
        @listener = ->(ev) { notification_event(ev) }
        @speaker.events.on_event(&@listener)
        @stations.each { |s| @threads << Thread.new { dial(s) } }
        @threads << Thread.new { stats_loop }
        self
      end

      # Section 4.5: a Termination to each station up, then its session
      # closes, and no station is dialed again.
      def stop
        @stopping = true
        queues = @lock.synchronize { @stations.collect(&:queue).compact }
        queues.each { |q| q << termination.encode << :close }
        deadline = Time.now + STOP_WAIT
        sleep 0.01 until @lock.synchronize { live.empty? } || Time.now > deadline
        # A writer still stuck is killed, and its session's ensure closes
        # the station.
        @threads.each(&:kill)
        @speaker.events.remove_event_listener(@listener) if @listener
        self
      end

      # The stations, one row each, for show.bmp.
      def rows ; @lock.synchronize { @stations.collect(&:to_h) } ; end

      ### A peer's session, as the speaker runs it

      # Watches one session: its messages and its states.
      def attach(address, neighbor)
        peer = Peer.new(address, neighbor)
        neighbor.add_observer(Observer.new(self, peer))
        neighbor.on_state_change do |now, was|
          if now == :Established && was != :Established
            peer_up(peer)
          elsif was == :Established && now != :Established
            peer_down(peer)
          end
        end
      end

      # The neighbor's observer: each message it receives.
      class Observer
        def initialize(monitor, peer)
          @monitor = monitor
          @peer = peer
        end

        def update(msg)
          @monitor.received(@peer, msg) if msg.is_a?(BGP::Update)
        end
      end

      # A NOTIFICATION sent or received, which BGP::Neighbor publishes as
      # an event before the session goes down. The first one is the
      # Peer Down's, as Neighbor#down_cause's first cause is.
      def notification_event(ev)
        return unless ev.kind == :notification
        @lock.synchronize do
          p = @peers[ev.peer]
          next unless p && p.notification.nil?
          octets = ev.data[:octets] ? [ev.data[:octets]].pack('H*') : ''
          p.notification = BGP::Notification.new(ev.data[:code], ev.data[:subcode], octets)
          p.notification_sent = ev.data[:direction] == 'send'
        end
      end

      def peer_up(peer)
        n = peer.neighbor
        sock = n.socket
        @lock.synchronize do
          peer.session_info = n.session_info
          peer.header = BGP::Bmp::Per_peer.new(peer.address, n.rmt_as.to_i, n.rmt_bgp_id.to_s, 0,
                                               flags_for(peer.address, n.session_info), '0' * 16, *timestamp)
          peer.local_address = sock&.local_address&.ip_address || '0.0.0.0'
          peer.local_port = sock&.local_address&.ip_port.to_i
          peer.remote_port = sock&.remote_address&.ip_port.to_i
          @peers[peer.address] = peer
          send_all(peer_up_message(peer).encode)
          eor(peer).each { |o| send_all(o) }
        end
        publish('peer_up', "peer #{peer.address} up, reported to #{live.size} station(s)", :peer => peer.address)
      end

      def peer_down(peer)
        reason = nil
        @lock.synchronize do
          next unless up?(peer)
          @peers.delete(peer.address)
          reason, data = down_reason(peer)
          send_all(BGP::Bmp::Peer_down.new(stamped(peer), reason, data).encode)
        end
        publish('peer_down', "peer #{peer.address} down, reason #{reason}", :peer => peer.address, :reason => reason) if reason
      end

      # One UPDATE from a peer: kept, and sent on as Route Monitoring.
      def received(peer, update)
        @lock.synchronize do
          next unless up?(peer)
          keep(peer, update)
          send_all(route_monitoring(peer, update).encode)
        end
      end

      private

      def up?(peer) ; @peers[peer.address].equal?(peer) ; end

      # Section 4.2: V for an IPv6 peer, A when the session's AS_PATH is
      # two octets wide, L clear: pre-policy.
      def flags_for(address, info)
        f = IPAddr.new(address).ipv6? ? BGP::Bmp::FLAG_V : 0
        f |= BGP::Bmp::FLAG_A if info && !info.as4byte?
        f
      end

      def timestamp
        t = @clock.call
        [t.to_i, t.usec]
      end

      # The peer's header, stamped now.
      def stamped(peer)
        h = BGP::Bmp::Per_peer.new(peer.header)
        h.seconds, h.microseconds = timestamp
        h
      end

      # Under @lock. RFC 7606's treat-as-withdraw withdraws an UPDATE's
      # routes, and is counted for stats 11 and 12.
      def keep(peer, update)
        taw = update.path_attribute&.action == :treat_as_withdraw
        BGP::Bmp::Routes.withdrawn(update).each { |afi, safi, n| peer.routes.delete(BGP::Bmp::Routes.key(afi, safi, n)) }
        announced = BGP::Bmp::Routes.announced(update)
        if taw
          peer.treat_as_withdraw_updates += 1
          peer.treat_as_withdraw_prefixes += announced.size
          announced.each { |afi, safi, n| peer.routes.delete(BGP::Bmp::Routes.key(afi, safi, n)) }
          return
        end
        attrs = BGP::Bmp::Routes.attributes(update)
        reach = BGP::Bmp::Routes.mp(update, BGP::Mp_reach)
        mp = reach && reach.to_hash[:mp_reach].reject { |k, _| k == :nlris }
        announced.each do |afi, safi, n|
          peer.routes[BGP::Bmp::Routes.key(afi, safi, n)] = [afi, safi, n, attrs, ([afi, safi] == [1, 1] && !reach ? nil : mp)]
        end
      end

      def route_monitoring(peer, update)
        BGP::Bmp::Route_monitoring.new(stamped(peer), update, peer.session_info)
      end

      def peer_up_message(peer)
        BGP::Bmp::Peer_up.new(stamped(peer), peer.local_address, peer.local_port, peer.remote_port,
                              peer.session_info.speaker, peer.session_info.peer)
      end

      # Section 3.3: an End-of-RIB for each family, after the peer's
      # routes.
      def eor(peer)
        EndOfRib.families(peer.session_info).collect do |afi, safi|
          route_monitoring(peer, EndOfRib.marker(afi, safi)).encode
        end
      end

      # The peer's Adj-RIB-In, one Route Monitoring for each route, then
      # its End-of-RIBs.
      def dump(peer)
        peer.routes.values.collect do |afi, safi, n, attrs, mp|
          route_monitoring(peer, BGP::Bmp::Routes.update(afi, safi, n, attrs, mp)).encode
        end + eor(peer)
      end

      # Section 4.9: 1 with the NOTIFICATION bgp4rd sent, 3 with the one
      # it received, 2 with the FSM event when it ended the session
      # without one, 4 when the connection went without one.
      def down_reason(peer)
        if peer.notification
          return [peer.notification_sent ? LOCAL_NOTIFICATION : REMOTE_NOTIFICATION, peer.notification]
        end
        case peer.neighbor.down_cause
        when :tcp then [REMOTE_NO_NOTIFICATION, nil]
        when :hold_time then [LOCAL_NO_NOTIFICATION, HOLD_TIMER_EXPIRES]
        else [LOCAL_NO_NOTIFICATION, MANUAL_STOP]
        end
      end

      def initiation
        BGP::Bmp::Initiation.new({ :type => 1, :string => @sys_descr }, { :type => 2, :string => @sys_name })
      end

      def termination
        BGP::Bmp::Termination.new({ :type => 1, :code => ADMINISTRATIVELY_CLOSED })
      end

      ### The stations

      def live ; @stations.select { |s| s.queue } ; end

      # Under @lock: octets to every station up.
      def send_all(octets) ; live.each { |s| s.queue << octets } ; end

      # A station's life: dial, run the session, wait, and again.
      def dial(station)
        failures = 0
        loop do
          begin
            sock = TCPSocket.new(station.address, station.port)
            failures = 0
            run(station, sock)
          rescue IOError, SystemCallError, SocketError => e
            @lock.synchronize do
              station.last_error = e.message
            end
            log(:warn, "bgp4r: bmp: #{station.name}: #{e.message}")
          end
          failures += 1
          @sleep.call(station.backoff(failures))
        end
      end

      # One session with a station: the Initiation and each peer's dump
      # first, queued under the lock so nothing a peer sends meanwhile is
      # lost or put before them.
      def run(station, sock)
        queue = Queue.new
        @lock.synchronize do
          station.socket = sock
          station.state = 'up'
          station.sessions += 1
          station.connected_at = @clock.call
          station.last_error = nil
          queue << initiation.encode
          @peers.each_value do |p|
            queue << peer_up_message(p).encode
            dump(p).each { |o| queue << o }
          end
          station.queue = queue
        end
        publish('station_up', "station #{station.name} up", :station => station.name)
        reader = Thread.new { drain(sock, queue) }
        write(station, sock, queue)
      ensure
        close_station(station, @stopping ? 'bgp4rd stopped' : 'the session ended')
      end

      # What the station sends is read and dropped; its end ends the
      # session, and the writer with it.
      def drain(sock, queue)
        loop { sock.readpartial(4096) }
      rescue EOFError, IOError, SystemCallError
        queue << :close
      end

      def write(station, sock, queue)
        loop do
          o = queue.pop
          return if o == :close
          sock.write(o)
          @lock.synchronize { station.sent += 1 }
        end
      rescue IOError, SystemCallError
        # The session is over; run closes it.
      end

      def close_station(station, why)
        was = nil
        @lock.synchronize do
          was = station.queue
          station.queue = nil
          station.state = 'connecting'
          s = station.socket
          s.close if s && !s.closed?
        end
        publish('station_down', "station #{station.name} down: #{why}", :station => station.name) if was
      end

      # Section 4.8: the routes kept for each peer (7), and the UPDATEs
      # and prefixes treated as withdraw (11, 12).
      def stats_loop
        loop do
          sleep @stats_interval
          send_stats
        end
      end

      def send_stats
        @lock.synchronize do
          @peers.each_value do |p|
            send_all(BGP::Bmp::Stats_report.new(stamped(p), [7, p.routes.size], [11, p.treat_as_withdraw_updates],
                                                [12, p.treat_as_withdraw_prefixes]).encode)
          end
        end
      end

      def publish(what, message, data)
        @speaker.events.publish(:kind => KIND, :message => "BMP #{message}", :data => { :event => what }.merge(data))
      end

      def log(level, message) ; @logger&.call(level, message) ; end
    end
  end
end
