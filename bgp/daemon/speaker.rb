#--
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

# The session, configuration and recording machinery a bgp4r speaker
# needs, shared by `bgp4rd` and by `lab/speaker.rb`.
#
# **It lives here rather than in lab/ because two programs use it, and
# that is the whole of the decision.** `lab/speaker.rb` was most of a
# daemon already: it reads one YAML file, holds a session per neighbor,
# records what each one sends, and since #231 wires in the tables of
# `bgp/rib/` behind the `rib`, `originate`, `export` and `fib` keys.
# `bgp4rd` needs all of that and adds a socket, so there were three
# ways to go and two of them were worse.
#
# * **`bgp4rd` requires `lab/speaker.rb`.** An installed gem ships
#   `bgp/` and `exe/`; `lab/` is a folder of the repository and is not
#   on a user's load path, so the executable would work from a checkout
#   and fail from `gem install bgp4r`.
# * **`bgp4rd` keeps its own copy.** Two session loops drifting apart is
#   the shape CLAUDE.md records three times already, most recently the
#   capability name list that lived in two methods and in
#   `lab/speaker.rb` and fell behind the library in all three.
# * **The shared part moves into the library and both use it.** This
#   one. `lab/speaker.rb` is now its command line, its state file
#   writer and three constants pointing here, so there is one session
#   loop and no copy.
#
# The extraction is deliberately as small as it can be while leaving no
# duplicate, and the test that it is right is that
# `test/functional/lab/speaker_test.rb`,
# `test/functional/lab/speaker_router_test.rb` and
# `test/functional/lab/add_path_topology_test.rb` all pass **unchanged**.
#
# What the daemon adds on top is elsewhere: `bgp/daemon/views.rb` turns
# this and `rib.view` into the JSON of `docs/daemon.md`,
# `bgp/daemon/api.rb` serves it over a Unix socket, and
# `bgp/daemon/server.rb` is `bgp4rd` itself.
#
# The node file keys are docs/daemon.md's, because that daemon's
# configuration is the lab node file with more in it and the two must
# not drift. lab/README.md documents them.

$LOAD_PATH.unshift File.expand_path('../..', __dir__)
require 'bgp4r'
require 'bgp/misc/route_generator'
require 'bgp/rib'
require 'socket'
require 'thread'

module BGP
  module Daemon

    # Records what one neighbor tells us: peer details, received routes and
    # timing. With mode 'count' it keeps counters and timing only, not each
    # route, so a sink can take a large feed.
    class Recorder
      MODES = %w[routes count]

      attr_reader :data, :mode

      # When the current session reached Established, as a Time, or nil
      # when it is not up. The snapshot carries the same instant as a
      # String under 'established_at'; this is the one a caller can do
      # arithmetic on, which is what a peer row's uptime needs.
      def established_at ; @lock.synchronize { @established_at } ; end

      # How many times a session that had reached Established went down.
      # **It is counted here rather than derived from
      # established_count**, because the two differ whenever a session is
      # up: three establishments with the third still up is two flaps,
      # and three with the third already gone is three.
      def flaps ; @lock.synchronize { @flaps } ; end

      def initialize(mode='routes')
        @mode = mode.to_s
        raise ArgumentError, "record #{mode.inspect}: use one of #{MODES.join(', ')}" unless MODES.include?(@mode)
        @lock = Mutex.new
        @flaps = 0
        @data = { 'peer_as' => nil, 'peer_router_id' => nil, 'peer_capabilities' => [],
                  'updates_received' => 0,
                  'prefixes_received' => 0, 'established_count' => 0, 'last_error' => nil }
        reset_session
      end

      def routes? ; @mode == 'routes' ; end

      # Called by BGP::Neighbor (an Observable) with every message it receives.
      def update(msg)
        @lock.synchronize do
          case msg
          when BGP::Open
            @data['peer_as'] = msg.local_as
            @data['peer_router_id'] = msg.bgp_id
            @data['peer_capabilities'] = Recorder.capabilities(msg)
            reset_session
          when BGP::Keepalive
            # RFC 4271 section 8.2.2: the first KEEPALIVE after OPEN takes the
            # session to Established. Taken here, on the thread that also
            # sees the UPDATEs, so no UPDATE can come before it.
            @established_at ||= Time.now
          when BGP::Update
            @last_update_at = Time.now
            @first_update_at ||= @last_update_at
            @data['updates_received'] += 1
            routes? ? record_routes(msg) : count_routes(msg)
          when BGP::Notification
            @data['last_error'] = "notification: #{msg}"
          when String
            @data['last_error'] = msg
          end
        end
      end

      def established!
        @lock.synchronize { @data['established_count'] += 1 }
      end

      def session_down!
        @lock.synchronize do
          @flaps += 1 if @established_at
          reset_session
        end
      end

      def error!(txt)
        @lock.synchronize { @data['last_error'] = txt }
      end

      def snapshot
        @lock.synchronize do
          h = Marshal.load(Marshal.dump(@data))
          h['flaps'] = @flaps
          h['prefixes_received'] = h['received'].size if routes?
          h.merge!(timing(h['prefixes_received']))
          h.merge!('first_prefix' => @first_prefix, 'last_prefix' => @last_prefix) unless routes?
          h
        end
      end

      # What the peer's OPEN advertised, as data rather than as its rendered
      # form. Each capability's own to_hash is the data, so this adds no
      # per-capability knowledge and cannot drift from the library: an
      # ADD-PATH capability comes back as
      #
      #   {"code" => 69, "name" => "Add_path",
      #    "capability" => {"families" => [{"afi" => 1, "safi" => 1, "send_recv" => 2}]}}
      #
      # where send_recv is RFC 7911 section 4's field value, so 2 is "able to
      # send" and is what says the peer read our half the way we meant it.
      #
      # Rendered text is deliberately not what goes in the state file: a reader
      # of this file is another program, and to_s here carries the enclosing
      # parameter's hex dump as well as the capability.
      def self.capabilities(open)
        Array(open.opt_parms).flat_map { |p|
          p.respond_to?(:capabilities) ? Array(p.capabilities) : [p]
        }.collect { |c|
          h = (c.respond_to?(:to_hash) ? c.to_hash : {}) rescue {}
          { 'name' => c.class.to_s.split('::').last }.merge(stringify(h))
        }
      end

      # JSON has no symbols, so a hash from the library is converted once here
      # rather than leaving a reader to deal with both spellings.
      def self.stringify(o)
        case o
        when Hash  then o.to_h { |k, v| [k.to_s, stringify(v)] }
        when Array then o.collect { |v| stringify(v) }
        when Symbol then o.to_s
        else o
        end
      end

      def self.attributes(pa)
        return {} unless pa
        h = {}
        h['as_path'] = pa[:as_path].as_path if pa.has?(BGP::As_path)
        h['as_path'] = '' if h['as_path'] == 'empty'
        h['next_hop'] = pa[:next_hop].next_hop if pa.has?(BGP::Next_hop)
        h['med'] = pa[:multi_exit_disc].to_i if pa.has?(BGP::Multi_exit_disc)
        h['local_pref'] = pa[:local_pref].to_i if pa.has?(BGP::Local_pref)
        h['communities'] = pa[:communities].communities if pa.has?(BGP::Communities)
        h
      end

      private

      # Forget the routes and the timing of the last session.
      def reset_session
        @data['received'] = {} if routes?
        @data['prefixes_received'] = 0
        @established_at = @first_update_at = @last_update_at = nil
        @first_prefix = @last_prefix = nil
      end

      def record_routes(msg)
        msg.withdrawn.to_ary.each { |p| @data['received'].delete(p) } if msg.withdrawn
        return unless msg.nlri
        attrs = Recorder.attributes(msg.path_attribute)
        msg.nlri.to_ary.each { |p| @data['received'][p] = attrs }
      end

      # A running count: prefixes announced minus prefixes withdrawn.
      def count_routes(msg)
        @data['prefixes_received'] -= msg.withdrawn.size if msg.withdrawn
        return unless msg.nlri && msg.nlri.size > 0
        @data['prefixes_received'] += msg.nlri.size
        @first_prefix ||= msg.nlri.nlris.first.to_s
        @last_prefix = msg.nlri.nlris.last.to_s
      end

      # Times of the current session. prefixes_per_second is the prefixes
      # held divided by the time from Established to the last UPDATE.
      def timing(prefixes)
        secs = @established_at && @last_update_at && (@last_update_at - @established_at)
        { 'established_at' => iso(@established_at), 'first_update_at' => iso(@first_update_at),
          'last_update_at' => iso(@last_update_at),
          'seconds_to_last_update' => secs && secs.round(3),
          'prefixes_per_second' => secs && secs > 0 ? (prefixes / secs).round(1) : nil }
      end

      # ISO 8601 with milliseconds, in UTC, which is what Time#iso8601(3)
      # answers. strftime and not that method, because iso8601 needs
      # `require 'time'`: Conventions records a standard library becoming
      # a bundled gem twice, once killing a CI job before a test ran, and
      # bgp/events.rb made the same swap for the same reason. The two
      # produce the same String.
      def iso(t) ; t && t.utc.strftime('%Y-%m-%dT%H:%M:%S.%LZ') ; end
    end

    # One configured neighbor: its settings, its current session, its record.
    class Peer
      attr_reader :address, :recorder, :config

      # The BGP::Neighbor running the current session, or nil before the
      # first one. It is here because `peer.refresh` has to put a message
      # on this session and nothing else can reach it; a reader also wants
      # `last_error` and `session_info`, which only a Neighbor answers.
      attr_reader :neighbor

      def initialize(speaker, config)
        @speaker, @config = speaker, config
        @address = config.fetch('address')
        @recorder = Recorder.new(config.fetch('record', 'routes'))
        @neighbor = nil
        @busy = Mutex.new
        # Administratively down, which is `peer.stop` and is a different
        # thing from a session that dropped: see admin_stop.
        @shutdown = false
        @admin = Mutex.new
        @resume = ConditionVariable.new
      end

      def remote_as ; @config.fetch('as') ; end
      # What the node file calls this peer, for a console's own column.
      # Nothing in the protocol carries it.
      def description ; @config['description'] ; end
      def ebgp? ; remote_as != @speaker.my_as ; end
      def active? ; @config.fetch('connect', false) ; end
      def state ; @neighbor ? @neighbor.state : 'Idle' ; end
      def established? ; @neighbor && @neighbor.is_established? ; end

      # Active side: connect, run the session, wait, reconnect, until
      # shutdown. One thread for the life of the Speaker, which is what
      # makes `peer.stop` then `peer.start` work: it waits while this peer
      # is administratively down rather than ending, so nothing has to
      # start a second dialling thread beside one that is still sleeping
      # out its retry interval. See admin_stop.
      def run_active
        @thread ||= Thread.new do
          Thread.current['name'] = "BGP peer #{@address}"
          until @speaker.stopping?
            wait_while_shutdown
            break if @speaker.stopping?
            begin
              sock = Socket.tcp(@address, @config.fetch('port', 179),
                                @speaker.local_address, connect_timeout: 5)
              run_session(sock)
            rescue SystemCallError, IOError, SocketError => e
              @recorder.error!("connect: #{e.message}")
            end
            backoff
          end
        end
      end

      # Passive side: the speaker accepted a connection from this peer.
      def accept(sock)
        if shutdown?
          # Administratively down, so there is no session to have. A
          # passive peer cannot be stopped by not dialling, so this is
          # where `peer.stop` holds for one.
          sock.close
          return
        end
        if @busy.locked?
          sock.close # one session per peer; keep the one we have
          return
        end
        Thread.new { run_session(sock) }
      end

      # Ends the session, if there is one. The reconnect loop and the
      # listener are untouched, so an active peer dials again after its
      # retry interval and a passive one waits to be dialled: this is
      # `peer.clear`, not `peer.stop`.
      #
      # **It closes the connection and sends no NOTIFICATION, and that is
      # a gap recorded rather than a choice.** A router answers
      # `clear bgp NEIGHBOR` with Cease and RFC 4486 section 4's
      # Administrative Reset, subcode 4, or Administrative Shutdown,
      # subcode 2. `Neighbor#stop` closes the output queue and the socket
      # in one breath, so a NOTIFICATION queued just before it is one the
      # writer thread may never get on the wire, and a method that
      # reported sending one would be claiming something it cannot
      # verify. Sending it properly means draining the output before the
      # socket closes, which is a change to `bgp/io.rb` and its own piece
      # of work.
      def stop
        @admin.synchronize { @resume.broadcast }
        @neighbor.stop if @neighbor
        self
      end
      alias clear stop

      # True when `peer.stop` took this peer down and `peer.start` has not
      # brought it back.
      def shutdown? ; @admin.synchronize { @shutdown } ; end

      # Administratively down: the session ends and does not come back.
      # That is the whole difference from clear, and it is why the flag
      # exists: without it the reconnect loop dials again two seconds
      # later and a `peer.stop` reads as a session that flapped.
      def admin_stop
        @admin.synchronize { @shutdown = true ; @resume.broadcast }
        @neighbor.stop if @neighbor
        self
      end

      # Administratively up again. An active peer's thread is waiting on
      # the condition variable, so this wakes it rather than starting
      # one; a peer that has never run gets its thread here, which is
      # what makes `peer.start` work on a node file that said nothing
      # about connecting.
      def admin_start
        @admin.synchronize { @shutdown = false ; @resume.broadcast }
        run_active if active?
        self
      end

      # RFC 2918 section 3: a ROUTE-REFRESH message asks the peer to
      # re-advertise the Adj-RIB-Out it holds for one <AFI, SAFI>. RFC
      # 7313 section 3.2 redefines RFC 2918's Reserved octet as the
      # Message Subtype, with 0 a normal request, 1 the beginning of a
      # route refresh operation, 2 its end and 255 Reserved.
      #
      # **Nothing here checks that the peer advertised capability 2**, and
      # that is Conventions rather than an omission: a tool for testing
      # the protocol has to be able to send a refresh to a speaker that
      # never asked for one and watch what it does. What is refused is a
      # session that is not Established, because there is no connection
      # to write to and `send_message` would raise a bare RuntimeError
      # about a session that was never started.
      def refresh(afi = 1, safi = 1, subtype = nil)
        n = @neighbor
        unless n && n.is_established?
          raise ArgumentError, "#{@address}: the session is #{state.to_s.downcase}, not established"
        end
        msg = BGP::Route_refresh.new(afi, safi, subtype)
        n.send_message(msg)
        msg
      end

      private

      # Waits while this peer is administratively down. The one second
      # timeout is a backstop and not the mechanism: admin_start and stop
      # both broadcast, so a resume is immediate, and the timeout is there
      # so no path can leave this thread waiting for ever.
      def wait_while_shutdown
        @admin.synchronize do
          @resume.wait(@admin, 1) while @shutdown && !@speaker.stopping?
        end
      end

      # Between connection attempts. It waits on the same condition
      # variable rather than sleeping, so a `peer.stop` during the retry
      # interval is noticed at once instead of being followed by one more
      # dial.
      def backoff
        @admin.synchronize do
          next if @speaker.stopping? || @shutdown
          @resume.wait(@admin, @config.fetch('retry', 2))
        end
      end

      def run_session(sock)
        @busy.synchronize do
          # Each session gets a new Neighbor. close ends the old one's thread.
          @neighbor.close if @neighbor
          n = new_neighbor(sock)
          @neighbor = n
          # Attached before the session starts, so the table sees the first
          # UPDATE and router mode sees Established. A Neighbor per session
          # means an adapter per session, so the ensure below detaches: an
          # adapter nobody detached is a peer whose routes stay in the table
          # after its session is gone.
          @speaker.rib&.attach(n)
          n.start(:session => sock, :timeout => @config.fetch('open_timeout', 30))
          if n.is_established?
            @recorder.established!
            announce(n, sock)
            n.wait_for_state(:Idle)
          else
            @recorder.error!("session did not reach Established, state #{n.state}#{": #{n.last_error.message}" if n.last_error}")
          end
          @recorder.session_down!
        ensure
          if n
            # **Hygiene, and not what removes the peer's routes.** That is
            # PeerAdapter#state_change, which queues :peer_down the moment a
            # session leaves Established, so RFC 4271 section 6 is answered
            # with or without this line: deleting it moved no assertion in
            # the loopback lab. What it is for is the adapter, one per
            # session because there is a Neighbor per session, and
            # PeerFeed#adapters is what Router#run_changes walks. Left out,
            # a speaker reconnecting every retry seconds to a peer that is
            # down accumulates one adapter per attempt for as long as it
            # runs.
            @speaker.rib&.detach(n)
            n.close
          end
        end
      end

      # sock is the session this Neighbor will run, when there is one.
      #
      # local_addr falls back to our address on that socket, which is what
      # RFC 4271 section 5.1.3 wants in NEXT_HOP toward an external peer and
      # what Rib::Router reads to build one. The speaker always hands
      # Neighbor#start a socket, so local_addr is never used to dial, and a
      # container with one address then needs no local_address key to be a
      # transit router. export.next_hops still wins over both.
      def new_neighbor(sock=nil)
        local = @speaker.local_address || (sock && sock.local_address.ip_address)
        n = BGP::Neighbor.new(:my_as => @speaker.my_as, :id => @speaker.router_id,
                              :holdtime => @config.fetch('hold_time', 90),
                              :remote_addr => @address, :local_addr => local,
                              :events => @speaker.events)
        Array(@config.fetch('capabilities', ['as4_byte'])).each { |c| add_capability(n, c) }
        n.add_observer @recorder
        n
      end

      # One capability from a topology. Either a name on its own, or a one key
      # Hash of a name and the arguments that follow it:
      #
      #   capabilities: [as4_byte, route_refresh, mbgp_ipv6_unicast]
      #   capabilities: [{role: customer}, {add_path: [3, 1, 1]}]
      #
      # Mind add_path's argument order, which is CAP::Add_path#add's:
      # (send_recv, afi, safi). So [3, 1, 1] is IPv4 unicast both ways, and
      # [1, 1, 3] is SAFI 3, NSAP, receive only. Both lines here and in
      # lab/README.md gave the second while meaning the first.
      #
      # Neighbor#capability knows every name bgp4r implements, so this
      # forwards rather than keeping a list of its own. The list here was four
      # names long and six behind the library, which is why no topology could
      # exercise ADD-PATH or Role against a real router.
      def add_capability(n, spec)
        name, args = spec.is_a?(Hash) ? spec.first : [spec, []]
        # YAML gives strings, and a capability takes its arguments as symbols
        # or numbers: role: customer is :customer, add_path: [1, 1, 3] is
        # three Integers.
        args = Array(args).collect { |a| a.is_a?(String) ? a.to_sym : a }
        n.capability(name.to_s, *args)
      rescue ArgumentError => e
        raise ArgumentError, "capability #{name.inspect} for #{@address}: #{e.message}"
      end

      # Send each announce block of the speaker as one UPDATE.
      def announce(n, sock)
        local = sock.local_address.ip_address
        @speaker.announcements.each do |a|
          @speaker.each_update(a, ebgp?, local, n.session_info) { |u| n.send_message u }
        end
      rescue RuntimeError => e
        # The session went down while we were sending. run_session waits for
        # Idle next, and the active side reconnects.
        @recorder.error!("announce: #{e.message}")
      end
    end

    class Speaker
      attr_reader :my_as, :router_id, :local_address, :announcements, :peers, :rib, :router,
                  :events, :started_at

      # The export: keys that go to Rib::Export rather than to Rib::Router.
      EXPORT_POLICY_KEYS = %w[route_reflector clients cluster_id default_local_pref].freeze
      EXPORT_KEYS = (EXPORT_POLICY_KEYS + %w[next_hops mrai]).freeze

      # The fib: keys, which are Rib::Fib::IpRoute's.
      FIB_KEYS = %w[table netns dev proto].freeze

      # ORIGIN of RFC 4271 section 5.1.1 as the state file spells it, which
      # is docs/daemon.md's show.routes. Its own words rather than the ones
      # bgp/rib/show.rb prints, because those are vendor presentation and a
      # reader of this file must not depend on them. See rib_state.
      ORIGINS = { 0 => 'igp', 1 => 'egp', 2 => 'incomplete' }.freeze

      def initialize(config)
        @config = config
        @my_as = config.fetch('as')
        @router_id = config.fetch('router_id')
        @local_address = config['local_address']
        @announcements = Array(config['announce'])
        @state_file = config.fetch('state_file', '/tmp/bgp4r-state.json')
        # **One event stream for every session, not one per Neighbor.**
        # A Neighbor builds its own BGP::Events so that a Neighbor on its
        # own is useful, and N of those number from 1 independently, so a
        # reader cannot order them. Sharing one is what makes several
        # sessions one ordered timeline, with Event#peer telling them
        # apart. Nothing in the lab reads them; `api.info` answers its
        # sequence and `events.subscribe` is a later pull request.
        @events = BGP::Events.new
        @started_at = Time.now
        @peers = Array(config.fetch('neighbors')).map { |c| Peer.new(self, c) }
        @stopping = false
        @originate = Array(config['originate'])
        @export = config['export']
        @fib = config['fib']
        # One table, shared by every session, which is what makes this a
        # router: a Rib::Table with two Neighbors attached decides what both
        # sent and advertises the winner to both. Built here rather than in
        # run, because it starts no thread until something attaches to it.
        @rib = BGP::Rib::Table.new(:local_as => @my_as, :router_id => @router_id) if rib?
      end

      def stopping? ; @stopping ; end

      # The configured neighbor with this address, or nil. Every control
      # method that acts on one session goes through it, so a request
      # naming an address nobody configured is refused by name rather
      # than acting on whatever was first in the list.
      def peer(address) ; @peers.find { |p| p.address == address.to_s } ; end

      # The one the caller named, or an ArgumentError listing the ones
      # there are, which is the shape an unknown API method is refused
      # with.
      def peer!(address)
        peer(address) or
          raise ArgumentError,
                "no neighbor #{address.inspect} is configured; this bgp4rd has " \
                "#{@peers.empty? ? 'none' : @peers.collect(&:address).join(', ')}"
      end

      # True when the node file asks for a table at all. rib: on its own
      # builds one that decides and prints and advertises nothing, which is
      # a speaker watching its peers rather than routing between them; the
      # other three keys each need one, so each implies it.
      def rib?
        @config.fetch('rib', false) || !@originate.empty? || !@export.nil? || !@fib.nil?
      end

      # The tables, the listening socket and the sessions, and nothing
      # that waits. **`start` and `stop` are split out of `run` so a
      # program can own its own main loop**: `lab/speaker.rb` wants a
      # state file writer and two signal traps, and `bgp4rd` wants a
      # control socket and three, so neither can live in here. It sets up
      # no logging either, for the same reason: the lab writes to standard
      # output and `bgp4rd` takes `--log FILE`.
      def start
        start_rib
        @server = listen if @peers.any? { |p| !p.active? }
        @peers.select(&:active?).each(&:run_active)
        self
      end

      def stop
        @stopping = true
        @server.close if @server
        @peers.each(&:stop)
        stop_rib
        self
      end

      # The lab's main loop: start, write the state file at 2 Hz, and stop
      # on INT or TERM.
      def run
        setup_log
        start
        writer = Thread.new { loop { write_state ; sleep 0.5 } }
        %w[INT TERM].each { |sig| trap(sig) { @stopping = true } }
        sleep 0.2 until @stopping
        writer.kill
        stop
        write_state
      end

      # Router mode, the forwarding table and our own prefixes, in that
      # order and before any session starts, so a peer that comes up at once
      # finds the table ready and gets the whole Loc-RIB.
      def start_rib
        return unless @rib
        @router = @rib.advertise(**export_options) if @export
        install_fib if @fib
        originate_routes
      end

      # Takes our routes back out of the forwarding table and stops the
      # worker and pacer threads. Nothing else tidies a routing table up.
      def stop_rib
        return unless @rib
        @rib.uninstall if @fib_installer
        @rib.feed.stop
      rescue StandardError => e
        Log.error "bgp4r: stopping the rib: #{e.class}: #{e.message}"
      end

      # Each originate: block, through Table#originate, so our own prefixes
      # go in the Loc-RIB and out through the export rules rather than
      # straight onto one session the way an announce: block does.
      def originate_routes
        @originate.each do |a|
          Array(a.fetch('prefixes')).each { |p| @rib.originate(p, :path_attribute => originate_attribute(a)) }
        end
      end

      # The path attributes of one originate: block.
      #
      # Two of them are deliberately not what an announce: block builds.
      # AS_PATH starts **empty**, because RFC 4271 section 5.1.2 wants an
      # empty one toward an internal peer and our AS alone toward an
      # external one, and both fall out of prepending onto an empty
      # attribute in the export step. NEXT_HOP is a placeholder, because
      # section 5.1.3 makes it ours on each session and the export step
      # replaces it there; a next_hop key here would be read and then
      # overwritten, so there is none.
      def originate_attribute(a)
        attrs = [BGP::Origin.new(a.fetch('origin', 0)),
                 BGP::As_path.new(*Array(a['as_path'])),
                 BGP::Next_hop.new(@router_id)]
        attrs << BGP::Multi_exit_disc.new(a['med']) if a['med']
        attrs << BGP::Local_pref.new(a['local_pref']) if a['local_pref']
        attrs << BGP::Communities.new(Array(a['communities']).join(' ')) if a['communities']
        BGP::Path_attribute.new(*attrs)
      end

      # The export: block as Rib::Router.new's options. A key no option
      # answers to raises rather than doing nothing quietly, which is what
      # add_capability does for a capability name: a typo in a node file
      # that silently turns reflection off is the worst of both.
      def export_options
        e = @export.is_a?(Hash) ? @export : {}
        unknown = e.keys - EXPORT_KEYS
        unless unknown.empty?
          raise ArgumentError,
                "export: unknown key(s) #{unknown.join(', ')}: use one of #{EXPORT_KEYS.join(', ')}"
        end
        opts = {}
        # Ours per address family, toward an external peer. Export will not
        # invent our address and a family with none is skipped rather than
        # given a next hop that is not ours, which is how a route becomes a
        # black hole. An IPv4 session falls back to its own local address.
        opts[:next_hops] = e['next_hops'].to_h { |afi, address| [Integer(afi), address.to_s] } if e['next_hops']
        # RFC 4271 section 9.2.1.1. Off is the default and stays it: a
        # script driving a router through a sequence of UPDATEs wants each
        # one on the wire when it says so.
        opts[:mrai] = e['mrai'].to_h { |k, v| [k.to_sym, v] } if e['mrai']
        policy = e.select { |k, _v| EXPORT_POLICY_KEYS.include?(k) }
        unless policy.empty?
          opts[:export] = BGP::Rib::Export.new(:local_as => @my_as, :router_id => @router_id,
                                               **policy.to_h { |k, v| [k.to_sym, v] })
        end
        opts
      end

      # The fib: block as Rib::Fib::IpRoute's options. table has no default
      # there and none here: a route in the main table changes where the
      # machine sends its own traffic, so nobody reaches it without naming
      # it.
      def fib_options
        f = @fib.is_a?(Hash) ? @fib : {}
        unknown = f.keys - FIB_KEYS
        unless unknown.empty?
          raise ArgumentError,
                "fib: unknown key(s) #{unknown.join(', ')}: use one of #{FIB_KEYS.join(', ')}"
        end
        raise ArgumentError, 'fib: table is required, and has no default' unless f['table']
        f.to_h { |k, v| [k.to_sym, v] }
      end

      # Installing routes needs CAP_NET_ADMIN and the lab speaker runs as
      # the non-root user bgp, so a node file asking for a forwarding table
      # in a container that cannot write one is an ordinary thing to meet.
      # It must say why rather than taking the speaker down with it: the
      # reason goes in the state file under fib, beside the per prefix
      # failures the installer itself records. A bad fib: block is a
      # different thing and still aborts, which is why fib_options is
      # outside the rescue.
      def install_fib
        opts = fib_options
        @fib_table = opts[:table].to_s
        begin
          @fib_installer = @rib.install(**opts)
        rescue StandardError => e
          @fib_error = "#{e.class}: #{e.message}"
          Log.error "bgp4r: fib: #{@fib_error}"
        end
      end

      # One UPDATE for one announce block. RFC 4271 section 5.1: an eBGP
      # speaker prepends its own AS to AS_PATH and sets NEXT_HOP to itself.
      # Over iBGP the AS_PATH is left as configured and LOCAL_PREF is sent.
      def build_update(a, ebgp, local_ip)
        BGP::Update.new(path_attribute(a, ebgp, local_ip), nlri_for(a))
      end

      # The NLRI of one prefixes block. With path_id every prefix in the block
      # carries that Path Identifier (RFC 7911 section 3), so two blocks naming
      # one prefix with two identifiers are two paths to it rather than one
      # block overwriting the other.
      #
      # The identifier is the sender's to allocate, and it may only go on a
      # session that negotiated add-path in our direction, which is
      # capabilities: [{add_path: [2, 1, 1]}] or [3, 1, 1]. Nothing here
      # checks that, deliberately: a Path Identifier on a session that did not
      # negotiate one is four unexpected octets in front of every prefix, so
      # sending one is a test a topology should be able to run.
      def nlri_for(a)
        prefixes = Array(a.fetch('prefixes'))
        return BGP::Nlri.new(*prefixes) unless a['path_id']
        id = Integer(a['path_id'])
        BGP::Nlri.new(*prefixes.collect { |p| { :path_id => id, :nlri => p } })
      end

      # Yields the UPDATEs of one announce block, one at a time. A prefixes
      # block makes one. A generate block makes many with BGP::RouteGenerator,
      # all with the same path attributes as build_update.
      def each_update(a, ebgp, local_ip, session_info=nil, env=ENV)
        return yield(build_update(a, ebgp, local_ip)) unless a['generate']
        g = Speaker.generate_options(a['generate'], env)
        BGP::RouteGenerator.new(g['start'], g['count'], g['per_update'], path_attribute(a, ebgp, local_ip))
                           .each_update(session_info) { |u| yield u }
      end

      # start, count and per_update of a generate block. ROUTEGEN_COUNT and
      # ROUTEGEN_PER_UPDATE, when set, override count and per_update.
      def self.generate_options(g, env=ENV)
        raise ArgumentError, "generate: expected start, count and per_update, got #{g.inspect}" unless g.is_a?(Hash)
        count = env['ROUTEGEN_COUNT'].to_s.strip
        per = env['ROUTEGEN_PER_UPDATE'].to_s.strip
        { 'start' => g.fetch('start'),
          'count' => Integer(count.empty? ? g.fetch('count') : count),
          'per_update' => Integer(per.empty? ? g.fetch('per_update', 1) : per) }
      end

      def path_attribute(a, ebgp, local_ip)
        path = Array(a['as_path'])
        path = [@my_as] + path if ebgp
        attrs = [BGP::Origin.new(a.fetch('origin', 0)),
                 BGP::Next_hop.new(a.fetch('next_hop', local_ip)),
                 BGP::As_path.new(*path)]
        attrs << BGP::Multi_exit_disc.new(a['med']) if a['med']
        attrs << BGP::Local_pref.new(a.fetch('local_pref', 100)) unless ebgp
        attrs << BGP::Communities.new(Array(a['communities']).join(' ')) if a['communities']
        BGP::Path_attribute.new(*attrs)
      end

      def state
        h = { 'router_id' => @router_id, 'as' => @my_as,
              'updated_at' => Time.now.utc.strftime('%Y-%m-%dT%H:%M:%S.%LZ'),
              'neighbors' => @peers.to_h { |p|
                [p.address, { 'state' => p.state }.merge(p.recorder.snapshot).merge(peer_rib_state(p))]
              } }
        @rib ? h.merge(rib_state) : h
      end

      # The Loc-RIB, the export side and the forwarding table, as plain data.
      #
      # **Plain data and not rib.show.** docs/routescope-labs.md section 5
      # says the state has to be the data under bgp/rib/show.rb rather than
      # its text, and CLAUDE.md says of those three vendor styles that
      # nothing in them has been diffed against a real device, so no test
      # anywhere should depend on the text byte for byte. A state file a
      # driver parses would be exactly such a test.
      #
      # The row shape is docs/daemon.md's show.routes. The serialising is
      # here and not in bgp/rib/ on purpose: a view layer belongs there and
      # is its own piece of work, item 3 of section 6. Move this onto it
      # when it lands.
      def rib_state
        rows = @rib.synchronize do
          @rib.loc_rib.prefixes.sort.collect do |prefix|
            route_row(prefix, @rib.loc_rib.best(prefix), @rib.candidates(prefix).size)
          end
        end
        { 'loc_rib' => rows, 'router' => router_state, 'fib' => fib_state }.compact
      end

      # One best route. best is always true here, because a Loc-RIB holds
      # the winner and nothing else; the flag is in the row because the row
      # shape is shared with a per path view that needs it.
      def route_row(prefix, route, paths)
        { 'prefix' => prefix,
          'next_hop' => route.next_hop,
          'as_path' => route.as_path == 'empty' ? '' : route.as_path,
          'origin' => ORIGINS[route.origin],
          'med' => route.med,
          'local_pref' => route.local_pref,
          'from' => route.peer.address,
          'paths' => paths,
          'best' => true }
      end

      def router_state
        return nil unless @router
        { 'advertising' => true, 'updates_sent' => @router.sent, 'held' => @router.held }
      end

      def fib_state
        return nil unless @fib
        { 'table' => @fib_table, 'installed' => @rib.fib ? @rib.fib.size : 0,
          'error' => @fib_error,
          'failed' => (@fib_installer ? @fib_installer.failed : {})
                        .collect { |prefix, result| { 'prefix' => prefix, 'error' => result.to_s } } }
      end

      # What this speaker sent one peer, and what it could not send. A route
      # silently not advertised is the hardest kind of bug to see from
      # outside, which is what Rib::Router#skipped is for and why it is in
      # this file rather than only in a log line.
      def peer_rib_state(peer)
        return {} unless @router
        out = @router.peers.find { |p| p.address == peer.address }
        { 'advertised' => out ? @router.adj_rib_out(out).size : 0,
          'skipped' => @router.skipped
                              .select { |(_prefix, p, _reason)| p && p.address == peer.address }
                              .collect { |(prefix, _p, reason)| { 'prefix' => prefix, 'reason' => reason.to_s } } }
      end

      # Write the state file atomically, so a reader never sees half a
      # file. Public, because the loop that calls it belongs to whatever
      # owns the main loop: see start and stop.
      #
      # The require is here and not at the top of the file, which is
      # bgp/rib/view.rb's reasoning: json is a default gem today and
      # Conventions records twice over that the local Ruby is not the CI
      # Ruby, so a top level require would take the whole file down at
      # load time on some future Ruby rather than failing in the one
      # method that wanted it.
      def write_state
        require 'json'
        tmp = "#{@state_file}.tmp"
        File.write(tmp, JSON.pretty_generate(state))
        File.rename(tmp, @state_file)
      end

      private

      LOG_LEVELS = { 'debug' => Logger::DEBUG, 'info' => Logger::INFO, 'warn' => Logger::WARN }

      # LAB_LOG_LEVEL wins over log_level in the node file, so one run can
      # turn on debug for every node: LAB_LOG_LEVEL=debug docker compose up
      def self.log_level(config, env=ENV)
        name = env['LAB_LOG_LEVEL'].to_s.strip.downcase
        name = config.fetch('log_level', 'info').to_s.downcase if name.empty?
        LOG_LEVELS.fetch(name) do
          raise ArgumentError, "log level #{name.inspect}: use one of #{LOG_LEVELS.keys.join(', ')}"
        end
      end

      def setup_log
        Log.create(STDOUT)
        Log.level = Speaker.log_level(@config)
      end

      # Accept sessions from passive peers, matched by source address.
      def listen
        server = TCPServer.new(@config.fetch('listen_address', '0.0.0.0'), @config.fetch('port', 179))
        Thread.new do
          loop do
            sock = server.accept
            ip = sock.remote_address.ip_address
            peer = @peers.find { |p| !p.active? && p.address == ip }
            if peer
              peer.accept(sock)
            else
              Log.warn "bgp4r: refused connection from unknown peer #{ip}"
              sock.close
            end
          rescue IOError
            break
          end
        end
        server
      end
    end

  end
end
