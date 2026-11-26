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
require 'bgp/daemon/community_keys'
require 'bgp/daemon/hand'
require 'bgp/daemon/link_state_table'
require 'bgp/daemon/link_state_producer'
require 'bgp/daemon/unreachability'
require 'bgp/daemon/vrf_sync'
require 'bgp/daemon/evpn_sync'
require 'bgp/daemon/evpn_exporter'
require 'bgp/daemon/vpn_exporter'
require 'bgp/daemon/vrf_ce_exporter'
require 'bgp/daemon/vpn_reflector'
require 'bgp/daemon/evpn_reflector'
require 'bgp/daemon/bfd'
require 'bgp/daemon/gtsm'
require 'bgp/daemon/tcp_auth'
require 'bgp/daemon/end_of_rib'
require 'bgp/daemon/graceful_restart'
require 'bgp/daemon/refresh'
require 'socket'
require 'thread'

module BGP
  module Daemon

    # Raised when something is asked of a peer's session and there is no
    # session to ask it of.
    #
    # It is a class of its own so a control plane can answer a refusal
    # rather than an internal error: `bgp4r-sim` turns it into a 4xx with
    # the address in it, which is what tells a scenario that its announce
    # went nowhere. Without it an announce to a peer that never came up
    # would answer 200 and send nothing, which is the silent wrong answer
    # this repository keeps paying for.
    class NoSession < StandardError ; end

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
            # RFC 4724 section 2's marker, one family at a time, in the
            # order they came. BGP::Neighbor publishes the event.
            eor = msg.end_of_rib
            @data['end_of_rib_received'] |= [{ 'afi' => eor[0], 'safi' => eor[1] }] if eor
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
        if pa.has?(BGP::Extended_communities)
          h['extended_communities'] = pa[:extended_communities].to_hash[:extended_communities].collect do |e|
            CommunityKeys.extended_community_text(e)
          end
        end
        h['large_communities'] = pa[:large_communities].communities.collect(&:to_s) if pa.has?(BGP::Large_communities)
        h
      end

      private

      # Forget the routes and the timing of the last session.
      def reset_session
        @data['received'] = {} if routes?
        @data['prefixes_received'] = 0
        @data['end_of_rib_received'] = []
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

      def iso(t) ; Recorder.iso(t) ; end

      # ISO 8601 with milliseconds, in UTC, which is what Time#iso8601(3)
      # answers. strftime and not that method, because iso8601 needs
      # `require 'time'`: Conventions records a standard library becoming
      # a bundled gem twice, once killing a CI job before a test ran, and
      # bgp/events.rb made the same swap for the same reason. The two
      # produce the same String.
      #
      # **It is a class method so the send side can use the one that
      # already exists.** `bgp/sim/sent.rb` reports `started_at` and
      # `finished_at` for what it sent, as this reports them for what
      # arrived, and two copies of a format string is how two timestamps
      # in one console come to disagree.
      def self.iso(t) ; t && t.utc.strftime('%Y-%m-%dT%H:%M:%S.%LZ') ; end
    end

    # One configured neighbor: its settings, its current session, its record.
    class Peer

      # The keys a neighbor block is read for, and the only ones it takes.
      #
      # **A key nothing reads is refused rather than ignored**, which is
      # `export_options`' rule one level down: a typo in a node file that
      # silently drops a setting is the worst of both. A neighbor written
      # `hold_tme: 30` used to run with the default hold time and say
      # nothing. `test_every_key_a_peer_reads_is_listed` holds this list
      # to the code, so a key read here and not listed fails the suite.
      KEYS = %w[address as capabilities connect description hold_time
                open_timeout port record retry route_reflector_client
                vrf as_override soo bfd ttl_security password end_of_rib
                refresh_stale_time graceful_restart].freeze

      # Raises ArgumentError naming every key `config` carries that no
      # code reads, and the keys there are.
      def self.check_keys(config)
        unknown = config.keys.map(&:to_s) - KEYS
        return config if unknown.empty?
        raise ArgumentError,
              "neighbor #{config['address']}: unknown key(s) #{unknown.join(', ')}: " \
              "a neighbor takes #{KEYS.join(', ')}"
      end

      attr_reader :address, :recorder, :config, :route_refresh, :graceful_restart

      # The BGP::Neighbor running the current session, or nil before the
      # first one.
      #
      # **Read it for what a live session knows, and drive the session
      # through the methods below.** What a caller outside wants is
      # `send_message`, `session_info`, `local_ip`, `pending`, `refresh`
      # and `established?`, and each of those is a method here that says
      # what it answers when there is no session. Handing the Neighbor
      # out hands out `start` and `stop` with it, where the
      # administrative pair below is how a session is driven from
      # outside.
      #
      # **The reader was taken out once as unread and had to come back**,
      # which is worth knowing before taking it out again: nothing in
      # `bgp/` or `bgp/sim/` reads it, so it looks like the dead constant
      # #223 found, and `test/functional/daemon_test.rb` reads it to
      # watch a session it set up by hand reach Established. The grep
      # that said otherwise was cut off by a `head`.
      attr_reader :neighbor
      def initialize(speaker, config)
        @speaker, @config = speaker, Peer.check_keys(config)
        @address = config.fetch('address')
        @recorder = Recorder.new(config.fetch('record', 'routes'))
        # RFC 2918 and RFC 7313's answers and counts: bgp/daemon/refresh.rb.
        @route_refresh = Refresh.new(self, speaker)
        # RFC 4724's Receiving Speaker: bgp/daemon/graceful_restart.rb.
        @graceful_restart = GracefulRestart.new(self, speaker)
        @gr_kept = []
        @neighbor = nil
        @busy = Mutex.new
        # Administratively down, which is `peer.stop` and `session.stop`
        # and is a different thing from a session that dropped: see
        # admin_stop.
        @shutdown = false
        @admin = Mutex.new
        @resume = ConditionVariable.new
      end

      # This peer's configuration, swapped for `config`, which is one
      # neighbor block of a committed candidate. Everything the session
      # reads comes off `@config`, so this is the whole of what a bounce
      # has to do before it ends the session: `new_neighbor` then reads
      # the new `hold_time` and `capabilities`, and `run_active` the new
      # `connect`, `port` and `retry`.
      #
      # **The address cannot change and the Recorder is not rebuilt.** The
      # address is what names a peer, so a changed one is a neighbor added
      # and another taken away, which `Candidate::Plan` refuses. The
      # Recorder is built once here and counts `established_count` and
      # `flaps` **across** sessions, so those numbers are deliberately
      # session independent; swapping it on a commit would reset the two
      # things a bounce is supposed to leave alone, which is why `record`
      # is a restart-class key rather than a bounce-class one.
      def reconfigure(config)
        unless config['address'].to_s == @address
          raise ArgumentError,
                "a peer is named by its address: #{@address} cannot become #{config['address']}"
        end
        @config = Peer.check_keys(config)
        self
      end

      def remote_as ; @config.fetch('as') ; end
      # What the node file calls this peer, for a console's own column.
      # Nothing in the protocol carries it.
      def description ; @config['description'] ; end
      def ebgp? ; remote_as != @speaker.my_as ; end
      # RFC 4456 section 6: a client of this reflector. IOS's
      # `neighbor X route-reflector-client`. The Speaker turns the flags
      # into Export's client list and refuses what cannot be one; see
      # Speaker#check_reflector_clients.
      def route_reflector_client? ; @config['route_reflector_client'] == true ; end
      def active? ; @config.fetch('connect', false) ; end
      # A BFD session to this neighbor, one hop away, beside BGP: see
      # bgp/daemon/bfd.rb. Speaker#check_bfd refuses any other value than
      # true or false.
      def bfd? ; @config['bfd'] == true ; end
      # GTSM, RFC 5082: the hops this neighbor is away, 1 for directly
      # connected, or nil for none. See bgp/daemon/gtsm.rb.
      # Speaker#check_ttl_security refuses anything but 1 to 254.
      def ttl_security ; @config['ttl_security'] ; end
      # TCP MD5, RFC 2385: the key this neighbor's segments are signed
      # with, or nil for none. See bgp/daemon/tcp_auth.rb.
      # Speaker#check_password refuses a key that is not 1 to 80 octets.
      def password ; @config['password']&.to_s ; end
      # RFC 4724 section 2: send an End-of-RIB per negotiated family once
      # the first table is sent. See bgp/daemon/end_of_rib.rb.
      # `graceful_restart` turns it on too: the GR capability says we send
      # it (RFC 4724 section 4).
      def end_of_rib? ; @config['end_of_rib'] == true || !@config['graceful_restart'].nil? ; end

      # The families a session that just ended keeps, which every table
      # asks as it drops the session (`retain`).
      def gr_kept ; @gr_kept ; end

      # A CE neighbor (docs/design/l3vpn-pe.md, pull request 7): the VRF
      # its session is bound to, or nil for a neighbor in the global
      # table. as_override replaces the CE's AS in what it is sent by
      # ours; soo is its Site of Origin, "65000:11", or nil.
      def vrf ; @config['vrf']&.to_s ; end
      def as_override ; @config['as_override'] == true ; end
      def soo ; @config['soo']&.to_s ; end

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
              if vrf || ttl_security || password
                sock = dial_socket
              else
                sock = Socket.tcp(@address, @config.fetch('port', 179),
                                  @speaker.local_address, connect_timeout: 5)
              end
              run_session(sock)
            rescue SystemCallError, IOError, SocketError => e
              @recorder.error!("connect: #{e.message}")
            end
            backoff
          end
        end
      end

      # A socket set up before `connect`, which `Socket.tcp` cannot do.
      #
      # A CE's session: a TCP socket bound to the VRF device and no source
      # address, so the kernel takes the VRF interface's. Measured on
      # l3vpn-lab: unbound, the CE is unreachable (ENETUNREACH).
      #
      # A GTSM session (`ttl_security`): its SYN must already go out at
      # TTL 255, or a peer with a minimum of 255 drops it. Outside a VRF
      # it binds `local_address`, as `Socket.tcp` does.
      #
      # An MD5 session (`password`): its SYN carries the digest already,
      # so the key is set before `connect` too.
      def dial_socket
        port = @config.fetch('port', 179)
        family = @address.include?(':') ? :INET6 : :INET
        s = Socket.new(family, :STREAM)
        if vrf
          s.setsockopt(Socket::SOL_SOCKET, Socket::SO_BINDTODEVICE, vrf)
        elsif @speaker.local_address
          s.bind(Addrinfo.tcp(@speaker.local_address, 0))
        end
        Gtsm.secure(s, Gtsm.minimum(ttl_security)) if ttl_security
        TcpAuth.md5(s, @address, password) if password
        addr = Socket.sockaddr_in(port, @address)
        if s.connect_nonblock(addr, exception: false) == :wait_writable
          raise Errno::ETIMEDOUT, "connect to #{@address}#{" in VRF #{vrf}" if vrf}" unless s.wait_writable(5)
          begin
            s.connect_nonblock(addr) # raises the connect's error, if it had one
          rescue Errno::EISCONN
          end
        end
        s
      rescue SystemCallError
        s&.close
        raise
      end

      # Passive side: the speaker accepted a connection from this peer.
      def accept(sock)
        if shutdown?
          # Administratively down, so there is no session to have. A
          # passive peer cannot be stopped by not dialling, so this is
          # where `peer.stop` and `session.stop` hold for one.
          sock.close
          return
        end
        if @busy.locked?
          # RFC 4724 section 4.2: from a peer we help, a new connection
          # while the session still looks Established means the old one
          # is gone. "the previous TCP session MUST be closed, and the new
          # one retained", and "no NOTIFICATION message should be sent".
          # Closed as a TCP failure, so its routes are kept.
          old = @neighbor
          if old && old.is_established? && @graceful_restart.configured? &&
             !GracefulRestart.families(old.session_info && old.session_info.peer).empty?
            old.stop_session(nil, :tcp)
            Thread.new { run_session(sock) }
            return
          end
          sock.close # one session per peer; keep the one we have
          return
        end
        # GTSM: the listener checked the handshake at the lowest minimum
        # any of its peers needs; from here on this peer's own holds, set
        # before the OPEN is read. See Gtsm.accepted.
        Gtsm.accepted(sock, ttl_security) if @speaker.gtsm_listener?(vrf)
        Thread.new { run_session(sock) }
      end

      # Ends the session, if there is one. The reconnect loop and the
      # listener are untouched, so an active peer dials again after its
      # retry interval and a passive one waits to be dialled: this is
      # `peer.clear`, not `peer.stop`.
      #
      # It sends nothing itself. `peer.clear`, `peer.stop` and a commit's
      # bounce send a Cease first through `cease`, and the injector's
      # `session.stop` does not, so the choice of subcode stays with the
      # caller that knows why the session is ending.
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
      #
      # **For a passive peer this is a permission and not an action**,
      # because nothing here can make the other side dial. The session
      # comes back when the peer next tries, on the peer's own timer, so
      # `session.start` reports which peers it only permitted.
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
        @route_refresh.send_refresh(BGP::Route_refresh.new(afi, safi, subtype))
      end

      # The `announce` blocks' UPDATEs of one family, [afi, safi], again:
      # the part of a route refresh's answer that no table holds. A CE has
      # none, as `run_session` sends it none.
      def resend_announcements(family)
        return if vrf
        n = @neighbor
        return unless n && n.is_established?
        local = local_ip
        @speaker.announcements.each do |a|
          @speaker.each_update(a, ebgp?, local, n.session_info) do |u|
            n.send_message(u) if Refresh.family(u) == family
          end
        end
      end

      # Messages queued for this session's writer and not yet handed to
      # the socket. See `Neighbor#pending`: a program that sends and
      # then stops drops them.
      def pending
        n = @neighbor
        n ? n.pending : 0
      end

      # What the session negotiated, for sizing a message the way the
      # session will encode it, or nil when there is no session.
      def session_info
        n = @neighbor
        n && n.session_info
      end

      # The address this session runs from, which is what NEXT_HOP
      # defaults to (RFC 4271 section 5.1.3). The socket's own address
      # when there is a session, since that is what `announce` reads, and
      # the configured one otherwise.
      def local_ip
        n = @neighbor
        sock = n && n.socket
        return @speaker.local_address if sock.nil? || sock.closed?
        sock.local_address.ip_address
      rescue IOError, SystemCallError
        @speaker.local_address
      end

      # RFC 4486 section 4: the Cease subcodes a router sends when it
      # administratively shuts a peering down, when it administratively
      # resets one, and when it resets one "due to a configuration change
      # other than the ones described above".
      CEASE = 6
      ADMIN_SHUTDOWN = 2
      ADMIN_RESET = 4
      OTHER_CONFIG_CHANGE = 6
      # RFC 9384 section 3: "When a BGP connection is terminated due to a
      # BFD session going into the Down state, the BGP speaker SHOULD send
      # a NOTIFICATION message with the error code "Cease" and the error
      # subcode "BFD Down"", which IANA numbered 10.
      BFD_DOWN = 10

      # A Cease with that subcode, when the session is up. True when one
      # was queued. `Neighbor#stop` waits for its writer, so a Cease sent
      # just before `stop` or `admin_stop` reaches the wire before the
      # socket closes.
      def cease(subcode)
        return false unless established?
        send_message(BGP::Notification.new(CEASE, subcode))
        true
      rescue NoSession
        false
      end

      # Sends one message on this peer's session, or raises NoSession.
      #
      # **Nothing here looks at what is being sent**, which is
      # Conventions' first rule and, for `bgp4r-sim`, the product: any
      # attribute, any length, any order, a Path Identifier on a session
      # that negotiated none, a NOTIFICATION with a code RFC 4271 does
      # not define. A String goes to the wire unchanged, which is what
      # makes replaying a capture possible.
      def send_message(msg)
        n = @neighbor
        raise NoSession, "no established session to #{@address}" unless n && n.is_established?
        n.send_message(msg)
      rescue RuntimeError => e
        # The session went away between the check and the send. The
        # active side reconnects; the caller gets a refusal rather than
        # an internal error.
        #
        # `RuntimeError` covers both ways `Neighbor#send_message` says
        # so: `Neighbor::SessionClosed`, which is a RuntimeError, and the
        # bare `raise txt` it uses when there is no output queue at all.
        raise NoSession, "session to #{@address} closed while sending: #{e.message}"
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
          # A CE's session (pull request 7) goes into its VRF's CE table
          # and nothing global: not the RIB, BGP-LS or the VPN table, and
          # the speaker's announce blocks are not its business.
          # Each table asks, as the session drops, which families to keep
          # through a graceful restart (bgp/daemon/graceful_restart.rb).
          retain = -> { @gr_kept }
          if vrf
            ce_feed = @speaker.ce_table.attach(n, vrf, soo: soo, retain: retain)
          else
            @speaker.rib&.attach(n, retain: retain)
            # BGP-LS goes in a table of its own, outside the RIB. See
            # bgp/daemon/link_state_table.rb.
            ls_feed = @speaker.link_state.attach(n, retain: retain)
            # Unreachability reports too, outside the RIB:
            # bgp/daemon/unreachability.rb.
            un_feed = @speaker.unreach.attach(n, retain: retain)
            # VPN-IPv4 too, in a table of its own: bgp/rib/vpn_table.rb.
            vpn_feed = @speaker.vpn.attach(n, retain: retain)
            # EVPN types 2 and 3 too: bgp/rib/evpn_table.rb.
            evpn_feed = @speaker.evpn.attach(n, retain: retain)
          end
          n.start(:session => sock, :timeout => @config.fetch('open_timeout', 30))
          if n.is_established?
            @recorder.established!
            @graceful_restart.up(n.session_info)
            announce(n, sock) unless vrf
            @speaker.session_established(self)
            @speaker.send_end_of_rib(self) if end_of_rib?
            n.wait_for_state(:Idle)
          else
            @recorder.error!("session did not reach Established, state #{n.state}#{": #{n.last_error.message}" if n.last_error}")
          end
          @recorder.session_down!
        ensure
          # The peer holds nothing from us once the session is over, so
          # nothing it was sent by hand is in doubt any more.
          @speaker.hand.reset(@address)
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
            @speaker.rib&.detach(n) unless vrf
            @speaker.link_state.detach(n, ls_feed) if ls_feed
            @speaker.unreach.detach(n, un_feed) if un_feed
            @speaker.vpn.detach(n, vpn_feed) if vpn_feed
            @speaker.evpn.detach(n, evpn_feed) if evpn_feed
            @speaker.ce_table.detach(ce_feed) if ce_feed
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
      #
      # A CE's session is in its VRF, where local_address, the loopback in
      # the global table, is not: its local address is the socket's.
      def new_neighbor(sock=nil)
        local = (vrf ? nil : @speaker.local_address) || (sock && sock.local_address.ip_address)
        n = BGP::Neighbor.new(:my_as => @speaker.my_as, :id => @speaker.router_id,
                              :holdtime => @config.fetch('hold_time', 90),
                              :remote_addr => @address, :local_addr => local,
                              :events => @speaker.events,
                              :logger => @speaker.logger)
        Array(@config.fetch('capabilities', ['as4_byte'])).each { |c| add_capability(n, c) }
        n.capability(GracefulRestart.capability(@config['graceful_restart'])) unless @config['graceful_restart'].nil?
        n.add_observer @recorder
        @route_refresh.reset
        n.add_observer @route_refresh
        n.add_observer @graceful_restart
        # Before any table's listener, which run_session adds after this:
        # each asks gr_kept as it drops the session.
        n.on_state_change do |now, was|
          @gr_kept = @graceful_restart.down(n.session_info, n.down_cause) if was == :Established && now != was
        end
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
      # #log and #logger. **This is what makes two speakers in one
      # process able to log apart**, which the process-wide Log
      # could not: every session this speaker runs, every BGP::IO thread
      # under it, its BGP::Events and its Rib::Table all take this
      # logger, so a harness hands each speaker its own callable and
      # neither reaches the other's destination. With none they all fall
      # back to Log, which is where these lines always went, so
      # every node file and every topology behaves as it did.
      include BGP::Logging

      attr_reader :my_as, :router_id, :local_address, :announcements, :peers, :rib, :router,
                  :events, :started_at, :hand

      # The BGP-LS routes this speaker received, per peer, and the
      # Producer that originates them from isisd, or nil with no
      # `link_state:` block. See bgp/daemon/link_state_table.rb and
      # bgp/daemon/link_state_producer.rb.
      attr_reader :link_state, :link_state_producer

      # The Unreachability reports this speaker received, per peer, and
      # the ones it makes from its `unreachability:` block. See
      # bgp/daemon/unreachability.rb.
      attr_reader :unreach, :unreach_originator

      # The VPN-IPv4 routes received, AFI 1 / SAFI 128, outside the RIB:
      # docs/design/l3vpn-pe.md, and bgp/rib/vpn_table.rb.
      attr_reader :vpn

      # The EVPN routes received, types 2 and 3 of AFI 25 / SAFI 70,
      # outside the RIB: docs/design/evpn.md, and bgp/rib/evpn_table.rb.
      attr_reader :evpn

      # The MAC-VRFs, filled from the EVPN table and written into vtep4rd,
      # or nil with no macvrfs: block (bgp/rib/macvrfs.rb,
      # docs/design/evpn.md pull request 2).
      attr_reader :macvrfs

      # What this PE sends of EVPN, or nil with no macvrfs: block
      # (bgp/daemon/evpn_exporter.rb, pull request 3).
      attr_reader :evpn_exporter

      # The PE's VRFs, filled from the VPN table and put in the kernel, or
      # nil with no vrfs: block (bgp/rib/l3vpn.rb, pull request 2).
      attr_reader :l3vpn

      # What this PE sends of its VRFs, or nil when no VRF exports
      # (bgp/daemon/vpn_exporter.rb, pull request 3).
      attr_reader :vpn_exporter

      # The CEs' routes per VRF, and what goes back to the CEs, or nil with
      # no CE neighbor (pull request 7).
      attr_reader :ce_table, :vrf_ce_exporter

      # What reflects VPN routes between PEs, or nil when this speaker is
      # not a route reflector (bgp/daemon/vpn_reflector.rb, pull request 6).
      attr_reader :vpn_reflector

      # The EvpnReflector, or nil when this speaker is not a route
      # reflector (docs/design/evpn.md, pull request 4).
      attr_reader :evpn_reflector

      # BFD for the neighbors with `bfd: true` (bgp/daemon/bfd.rb).
      attr_reader :bfd

      # The l3vpn: block's keys.
      L3VPN_KEYS = %w[labels transport tunnels].freeze

      # The configuration this speaker was built from, which
      # `BGP::Daemon::Candidate` reads as the running one and `reconfigure`
      # replaces.
      attr_reader :config

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

      # arg[:logger] is the ->(level, message) this speaker and everything
      # under it logs through. A second positional argument rather than a
      # config key, because it is a Ruby callable and a node file is YAML:
      # `log_level` and `log` in the file are the file's business and this
      # is the program's.
      #
      # arg[:bfd_client] and arg[:bfd_runner] are Bfd's :client and
      # :runner, so a test drives BFD with a fake bfdd4r and a fake `ip`.
      def initialize(config, arg = {})
        @logger = arg[:logger]
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
        @events = BGP::Events.new(:logger => @logger)
        # What was sent to a peer by hand, which `bgp4rd` lists beside the
        # Adj-RIB-Out. See bgp/daemon/hand.rb.
        @hand = Hand.new
        @started_at = Time.now
        @peers = Array(config.fetch('neighbors')).map { |c| Peer.new(self, c) }
        @on_established = []
        @stopping = false
        @originate = Array(config['originate'])
        @export = config['export']
        @fib = config['fib']
        check_reflector_clients
        @bfd = Bfd.new(self, :client => arg[:bfd_client], :runner => arg[:bfd_runner],
                       :logger => @logger)
        check_bfd
        check_ttl_security
        check_password
        @peers.each { |p| EndOfRib.check(p.config['end_of_rib'], p.address) }
        @peers.each { |p| Refresh.check(p.config['refresh_stale_time'], p.address) }
        @peers.each { |p| check_graceful_restart(p.config) }
        @link_state = LinkStateTable.new
        unreach_log = ->(level, msg) { log(level, msg) }
        @unreach = UnreachTable.new(events: @events, logger: unreach_log)
        @unreach_originator = UnreachOriginator.new(self, logger: unreach_log)
        # Read now, so a bad entry stops bgp4rd at start as any bad key
        # does, rather than at the first session.
        @unreach_originator.refresh(config['unreachability'])
        on_established { |p| @unreach_originator.session_up(p) }
        @vpn = BGP::Rib::VpnTable.new(local_as: @my_as, router_id: @router_id,
                                      cluster_id: decision_options[:cluster_id])
        @evpn = BGP::Rib::EvpnTable.new(local_as: @my_as, router_id: @router_id,
                                        cluster_id: decision_options[:cluster_id])
        build_l3vpn(config['vrfs'], config['l3vpn'])
        build_vpn_reflector
        build_evpn(config['macvrfs'], config['evpn'], arg[:vtep_client])
        if config['link_state']
          @link_state_producer = LinkStateProducer.new(self, config['link_state'], :logger => @logger)
          on_established { |p| @link_state_producer.session_up(p) }
        end
        # One table, shared by every session, which is what makes this a
        # router: a Rib::Table with two Neighbors attached decides what both
        # sent and advertises the winner to both. Built here rather than in
        # run, because it starts no thread until something attaches to it.
        @rib = BGP::Rib::Table.new(:local_as => @my_as, :router_id => @router_id,
                                   :logger => @logger, **decision_options) if rib?
      end

      def stopping? ; @stopping ; end

      # The configuration this speaker is running, swapped for a
      # committed candidate. `BGP::Daemon::Candidate` is the only caller
      # and its own comment has the table of what a commit may change.
      #
      # **What it deliberately does not touch is as much of the point as
      # what it does.** `@my_as`, `@router_id`, `@local_address`,
      # `@export`, `@fib`, `@rib` and `@peers` are read once, by
      # `initialize` and by `start`, and `@peers` is read from every
      # session thread with no lock besides. So a change to any of them
      # is refused by `Candidate::Plan` before this is called, and this
      # method cannot quietly apply half of one.
      #
      # **`@fib` is the one whose only remaining obstacle is this
      # method.** It used to be refused because `Table#on_change` could
      # not take a listener off, so a replaced FibInstaller went on
      # installing; `Table#off_change` fixed that, and the library would
      # now take a flush and a reinstall. `@export` has a library reason
      # of its own left, which `Candidate::RESTART_REASONS` states: a
      # replacement Router starts with empty Adj-RIB-Outs.
      #
      # What it does swap is the three a live or bounced session reads
      # again: the `announce` blocks, which go out on the next
      # establishment, the `originate` blocks, which the caller has
      # already turned into table operations, and each neighbor's own
      # block.
      def reconfigure(config)
        @config = config
        @announcements = Array(config['announce'])
        @originate = Array(config['originate'])
        Array(config['neighbors']).each do |c|
          next unless c.is_a?(Hash)
          p = peer(c['address'].to_s)
          p.reconfigure(c) if p
        end
        self
      end

      # The configured neighbor with this address, or nil. A peer is
      # named by its address, which is CLAUDE.md's "A peer is identified
      # by its address", so this is the whole of how a control plane
      # selects one. Every control method that acts on one session goes
      # through it, so a request naming an address nobody configured is
      # refused by name rather than acting on whatever was first in the
      # list.
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

      # The peers with a session up, which is who an action with no
      # `peer` key reaches.
      def established_peers
        @peers.select(&:established?)
      end

      # Runs block with the Peer every time one of its sessions reaches
      # Established, after the `announce` blocks of the node file have
      # gone out.
      #
      # **What it is for is anything a control plane announced**, which a
      # node file's `announce` block gets for free: `Peer#announce`
      # replays `announcements` on every establishment, so a session that
      # flapped comes back with the configured routes and without the
      # ones an API asked for. `bgp4r-sim` listens here and sends those
      # again; `bgp4rd` does not need it, because `Rib::Router` sends the
      # whole Loc-RIB on Established already.
      #
      # The block runs on the session's own thread, as `announce` does,
      # and an exception from it is logged rather than raised: that is
      # `Neighbor#on_state_change`'s rule and the reason is the same, a
      # listener must not be able to kill the session it is listening to.
      def on_established(&block)
        @on_established << block
        self
      end

      def session_established(peer)
        @on_established.each do |block|
          begin
            block.call(peer)
          rescue StandardError => e
            log(:error, "bgp4r: on_established for #{peer.address}: #{e.class}: #{e.message}")
          end
        end
      end

      # The End-of-RIB markers to one peer, one per family its session
      # negotiated, after the first table: RFC 4724 section 2, "upon
      # completion of the initial update". Called on the session's own
      # thread, once `announce` and every `on_established` block have run.
      #
      # **Two senders run behind on threads of their own**, so this waits
      # for each before it sends. The Router's table goes out from the RIB
      # feed's worker, which queued this session's [:session_up] when the
      # session reached Established, so draining the feed waits for it. The
      # VPN reflector sends on its next refresh, which `session_up` asked
      # for, so draining its queue waits for that. Every other sender sends
      # in its `on_established` block, which has returned.
      #
      # A family with nothing to send gets its marker too, as RFC 4724
      # section 4 asks of a restarting speaker: "including the case when
      # there is no update to send".
      def send_end_of_rib(peer)
        waited = [@rib && @rib.feed.drain(END_OF_RIB_WAIT), @vpn_reflector && @vpn_reflector.drain(END_OF_RIB_WAIT)]
        log(:warn, "bgp4r: End-of-RIB to #{peer.address} sent before the first table was: a sender took over #{END_OF_RIB_WAIT}s") if waited.include?(false)
        families = EndOfRib.families(peer.session_info)
        families.each { |afi, safi| peer.send_message(EndOfRib.marker(afi, safi)) }
        log(:info, "bgp4r: End-of-RIB sent to #{peer.address} for #{families.collect { |f| f.join('/') }.join(', ')}")
      rescue NoSession => e
        log(:info, "bgp4r: End-of-RIB to #{peer.address} not sent: #{e.message}")
      end

      # RFC 2918 section 4's re-advertisement of one family's Adj-RIB-Out
      # to one peer, from whichever part of bgp4rd sent it: the `announce`
      # blocks, the Router for unicast, a CE's exporter in a VRF, the VPN
      # exporter and reflector, the BGP-LS Producer, and the unreachability
      # originator. Returns once each has sent, so an EoRR after it comes
      # after the routes. bgp/daemon/refresh.rb calls it.
      def resend_family(peer, afi, safi)
        family = [afi, safi]
        peer.resend_announcements(family)
        case family
        when [1, 1], [2, 1]
          if peer.vrf
            @vrf_ce_exporter&.session_up(peer)
          elsif @rib && @router
            @rib.readvertise(peer.address, afi)
          end
        when [1, 128], [2, 128]
          @vpn_exporter&.resend(peer, afi)
          if @vpn_reflector
            @vpn_reflector.resend(peer, afi)
            @vpn_reflector.drain(END_OF_RIB_WAIT)
          end
        when [IANA::AFI::BGP_LS, IANA::SAFI::BGP_LS]
          @link_state_producer&.session_up(peer)
        else
          @unreach_originator&.resend(peer, family)
        end
      end

      # How long send_end_of_rib waits for a sender, in seconds.
      END_OF_RIB_WAIT = 30

      # A BoRR or an EoRR from peer, RFC 7313 section 4: action :mark
      # marks the peer's routes of that family stale, :purge removes what
      # is still stale. Each family goes to the table that holds it, as
      # resend_family sends it. done is called once with how many routes
      # were marked or removed. Unicast goes through the RIB's worker, in
      # its place among the UPDATEs before and after it, so done may be
      # called later, on that thread. A family no table holds calls done
      # with nil.
      def stale_family(peer, afi, safi, action, &done)
        mark = action == :mark
        address = peer.address
        n = case [afi, safi]
            when [1, 1], [2, 1]
              if peer.vrf
                @ce_table && (mark ? @ce_table.mark_stale(peer.vrf, address, afi) : @ce_table.purge_stale(peer.vrf, address, afi))
              elsif @rib
                @rib.feed << [:stale, address, afi, action, done]
                return
              end
            when [1, 128], [2, 128]
              mark ? @vpn.mark_stale(address, afi) : @vpn.purge_stale(address, afi)
            when BGP::Rib::PeerAdapter::EVPN
              # Types 2 and 3 in the EVPN table, type 254 in the
              # unreachability table: one family, two tables.
              (mark ? @evpn.mark_stale(address) : @evpn.purge_stale(address)) +
                (mark ? @unreach.mark_stale(address, [afi, safi]) : @unreach.purge_stale(address, [afi, safi]))
            when [IANA::AFI::BGP_LS, IANA::SAFI::BGP_LS]
              mark ? @link_state.mark_stale(address) : @link_state.purge_stale(address)
            else
              if Unreach::FAMILIES.include?([afi, safi])
                mark ? @unreach.mark_stale(address, [afi, safi]) : @unreach.purge_stale(address, [afi, safi])
              end
            end
        done&.call(n)
      end

      # True when the node file asks for a table at all. rib: on its own
      # builds one that decides and prints and advertises nothing, which is
      # a speaker watching its peers rather than routing between them; the
      # other three keys each need one, so each implies it.
      def rib?
        @config.fetch('rib', false) || !@originate.empty? || advertise? || !@fib.nil?
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
        @vrf_sync&.start
        @vpn_reflector&.start
        @evpn_reflector&.start
        @evpn_sync&.start
        @vtep_events&.start
        @server = listen if @peers.any? { |p| !p.active? && !p.vrf }
        # tcp_l3mdev_accept is 0, so a CE dialling in reaches only a
        # listener bound to its VRF (pull request 7, measured).
        @vrf_servers = @peers.select { |p| !p.active? && p.vrf }.collect(&:vrf).uniq.collect { |v| listen(v) }
        @peers.select(&:active?).each(&:run_active)
        @link_state_producer&.start
        # BFD comes up beside BGP and not after it: the sessions are
        # asked for now, whatever state BGP is in.
        @bfd.start
        self
      end

      def stop
        @stopping = true
        @bfd.stop
        @link_state_producer&.stop
        @server.close if @server
        Array(@vrf_servers).each(&:close)
        @peers.each(&:stop)
        stop_rib
        @vrf_sync&.stop
        @vpn_reflector&.stop
        @evpn_reflector&.stop
        @vtep_events&.stop
        @evpn_sync&.stop
        @vtep_client&.close
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
        @router = @rib.advertise(**export_options) if advertise?
        # A prefix the daemon sends the normal way is no longer one only
        # sent by hand.
        @router&.on_sent { |peer, prefixes| @hand.sent(peer.address, prefixes) }
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
        log(:error, "bgp4r: stopping the rib: #{e.class}: #{e.message}")
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
        attrs.concat(CommunityKeys.community_attributes(a))
        BGP::Path_attribute.new(*attrs)
      end

      # The export: keys the decision process must share with Rib::Export.
      #
      # **Two of them are one router-wide value read in two places.** The
      # export side prepends cluster_id to a CLUSTER_LIST and gives an
      # internal peer default_local_pref; the decision side drops a route
      # carrying our cluster_id (RFC 4456 section 8) and ranks a route with
      # no LOCAL_PREF at default_local_pref. Until this was passed on, the
      # Table was built with neither, so a reflector whose cluster_id was
      # not its router_id prepended one ID and loop checked another, and a
      # route that came back through a second reflector of the same cluster
      # stayed usable. Measured on 2026-11-05: decision 1.1.1.1, export
      # 9.9.9.9, for `cluster_id: 9.9.9.9`.
      def decision_options
        e = @export.is_a?(Hash) ? @export : {}
        opts = {}
        opts[:cluster_id] = e['cluster_id'] if e['cluster_id']
        opts[:default_local_pref] = e['default_local_pref'] if e['default_local_pref']
        opts
      end

      # True when this speaker advertises: an export block, or a neighbor
      # flagged as a reflector client, which turns reflection on by itself
      # as IOS's `route-reflector-client` does.
      def advertise?
        !@export.nil? || !reflector_clients.empty?
      end

      # The addresses of the neighbors flagged `route_reflector_client`.
      def reflector_clients
        @peers.select(&:route_reflector_client?).map(&:address)
      end

      # Raises ArgumentError when a neighbor's `bfd` is anything but true
      # or false, or when one with `bfd: true` is not one hop away, so
      # bgp4rd does not start on a BFD session it cannot run. The one hop
      # check asks the kernel, `ip -j route get`, which is why a
      # containerlab node with `bfd: true` starts bgp4rd once its link
      # addresses are there: `exec:` runs after the entrypoint.
      def check_bfd
        @peers.each do |p|
          v = p.config['bfd']
          next if v.nil? || v == true || v == false
          raise ArgumentError, "neighbor #{p.address}: bfd is true or false, got #{v.inspect}"
        end
        @bfd.check(@peers)
      end

      # Raises ArgumentError when a neighbor's `graceful_restart` does not
      # read, or when its `capabilities` list a GR capability as well: RFC
      # 4724 section 3, "A BGP speaker MUST NOT include more than one
      # instance of the Graceful Restart Capability".
      def check_graceful_restart(config)
        GracefulRestart.check(config['graceful_restart'], config['address'])
        return if config['graceful_restart'].nil?
        listed = Array(config['capabilities']).any? { |c| %w[graceful_restart gr].include?((c.is_a?(Hash) ? c.keys.first : c).to_s) }
        return unless listed
        raise ArgumentError, "neighbor #{config['address']}: graceful_restart and a graceful_restart capability " \
                             'would advertise it twice (RFC 4724 section 3); keep one'
      end

      # Raises ArgumentError when a neighbor's `ttl_security` is not a
      # number of hops from 1 to 254, so bgp4rd does not start on a GTSM
      # setting it would read some other way.
      def check_ttl_security
        @peers.each { |p| Gtsm.check(p.config['ttl_security'], p.address) }
      end

      # Raises ArgumentError when a neighbor's `password` is not a key of
      # 1 to 80 octets, the kernel's limit. See TcpAuth.check.
      def check_password
        @peers.each { |p| TcpAuth.check(p.config['password'], p.address) }
      end

      # The passive peers the listener for `vrf` (nil the global one)
      # accepts for.
      def passive_peers(vrf = nil)
        @peers.select { |p| !p.active? && p.vrf == vrf }
      end

      # Whether one of those peers has `ttl_security`, so the listener
      # sends at 255 and each accepted socket is set for its peer.
      def gtsm_listener?(vrf = nil)
        passive_peers(vrf).any?(&:ttl_security)
      end

      # The listener's minimum TTL, or nil: see Gtsm.listener_minimum.
      # docs/design/bgp-operations.md, section 5, says why one listener
      # serves every peer, and what that lets through.
      def listener_minimum(vrf = nil)
        Gtsm.listener_minimum(passive_peers(vrf).map(&:ttl_security))
      end

      # Refuses a `route_reflector_client` flag this speaker cannot act on.
      # Four cases, each an input with two readings or none:
      #
      # * a value that is not true or false, since `'yes'` in quotes would
      #   otherwise read as false and say nothing;
      # * a flag on an external neighbor, because RFC 4456 section 6 makes
      #   clients IBGP peers;
      # * a flag beside `export.clients`, because the two lists can
      #   disagree and `clients: []` already means the opposite of no key;
      # * a flag beside `export.route_reflector: false`, which asks for
      #   reflection to be off and on at once.
      def check_reflector_clients
        @peers.each do |p|
          v = p.config['route_reflector_client']
          next if v.nil? || v == true || v == false
          raise ArgumentError,
                "neighbor #{p.address}: route_reflector_client is true or false, not #{v.inspect}"
        end
        return if reflector_clients.empty?
        ebgp = @peers.select { |p| p.route_reflector_client? && p.ebgp? }.map(&:address)
        unless ebgp.empty?
          raise ArgumentError,
                "neighbor #{ebgp.join(', ')}: route_reflector_client on an external peer: " \
                'a client is an internal peer, RFC 4456 section 6'
        end
        e = @export.is_a?(Hash) ? @export : {}
        if e.key?('clients')
          raise ArgumentError,
                'export: clients and a neighbor route_reflector_client flag cannot both be given; ' \
                'use one or the other'
        end
        if e['route_reflector'] == false
          raise ArgumentError,
                'export: route_reflector is false and a neighbor is a route_reflector_client; ' \
                'a client flag turns reflection on'
        end
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
        unless reflector_clients.empty?
          policy['route_reflector'] = true
          policy['clients'] = reflector_clients
        end
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
          log(:error, "bgp4r: fib: #{@fib_error}")
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
      #
      # A path_id on the block goes in front of every generated prefix, as
      # nlri_for does for a prefixes block (RFC 7911 section 3). It used to
      # be dropped here in silence, which is phase 0 of
      # docs/route-generation.md. RouteGenerator refuses one that is not
      # an integer or does not fit in 4 octets.
      def each_update(a, ebgp, local_ip, session_info=nil, env=ENV)
        return yield(build_update(a, ebgp, local_ip)) unless a['generate']
        g = Speaker.generate_options(a['generate'], env)
        BGP::RouteGenerator.new(g['start'], g['count'], g['per_update'], path_attribute(a, ebgp, local_ip),
                                path_id: a['path_id'])
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

      # Over eBGP our own AS goes in front of `as_path`, which is RFC 4271
      # section 5.1.2 and is what a node file saying "this route reached us
      # from 65020" means. `as_path_literal: true` turns that off, so the
      # AS_PATH goes out exactly as written: an AS_PATH whose leftmost AS
      # is not the sender's is a receive check a test has to be able to
      # make (RFC 4271 section 6.3). Only `true` turns it off, so a YAML
      # `"false"` or a typo leaves the default alone.
      def path_attribute(a, ebgp, local_ip)
        path = Array(a['as_path'])
        path = [@my_as] + path if ebgp && a['as_path_literal'] != true
        attrs = [BGP::Origin.new(a.fetch('origin', 0)),
                 BGP::Next_hop.new(a.fetch('next_hop', local_ip)),
                 BGP::As_path.new(*path)]
        attrs << BGP::Multi_exit_disc.new(a['med']) if a['med']
        attrs << BGP::Local_pref.new(a.fetch('local_pref', 100)) unless ebgp
        attrs.concat(CommunityKeys.community_attributes(a))
        BGP::Path_attribute.new(*attrs)
      end

      # `show.link_state`: the routes this speaker sent as a Producer,
      # with peer nil, then the ones it received.
      # `show.unreachability`: the reports this speaker makes, with `peer`
      # null, then the ones it received, per peer, sorted by family,
      # prefix and peer.
      def unreachability_rows
        rows = @unreach_originator.rows + @unreach.rows
        order = %w[ipv4 ipv6 evpn]
        rows.sort_by { |r| [order.index(r['family']).to_i, r['rd'].to_s, r['prefix'].to_s, r['peer'].to_s] }
      end

      def link_state_rows
        (@link_state_producer ? @link_state_producer.rows : []) + @link_state.rows
      end

      # `show.vpn`: the VPN-IPv4 routes this PE sends, with peer nil, then
      # the ones it received, one row each.
      def vpn_rows
        (@vpn_exporter ? @vpn_exporter.rows : []) + @vpn.rows
      end

      # `show.evpn`: the EVPN routes received, one row each. With
      # MAC-VRFs, each row also says which import it and why one does not
      # install it (pull request 2).
      def evpn_rows
        return @evpn.rows unless @macvrfs
        @evpn_exporter.rows +
          @evpn.rows { |key| st = @macvrfs.route_state(key); st.merge('valid' => st['invalid'].nil?) }
      end

      # vtep4rd's socket, for show.status.
      def vtep_path
        @vtep_client.respond_to?(:path) ? @vtep_client.path : nil
      end

      # `show.macvrfs`: one row per MAC-VRF.
      def macvrf_rows
        @macvrfs ? @macvrfs.rows : []
      end

      # `show.macvrf`: one MAC-VRF's MACs, or nil for a VNI with none.
      def macvrf_mac_rows(vni)
        @macvrfs && @macvrfs.mac_rows(vni)
      end

      # `show.vpn_labels`: the label of each exporting VRF.
      def vpn_label_rows
        @l3vpn ? @l3vpn.label_rows : []
      end

      # `show.vrfs` and `show.vrf`: none without a vrfs: block.
      def vrfs_rows
        @l3vpn ? @l3vpn.vrf_rows : []
      end

      # How many of peer's routes are marked stale now, in every table.
      def stale_size(peer)
        address = peer.address
        n = @vpn.stale_size(address) + @evpn.stale_size(address) + @link_state.stale_size(address) + @unreach.stale_size(address)
        n += peer.vrf ? @ce_table&.stale_size(peer.vrf, address).to_i : @rib&.stale_size(address).to_i
        n
      end

      # Each row gains `stale` while the route it came from is marked: a
      # CE's in the CE table, a VPN route's in the VPN table. The rows are
      # built when the VRFs sync and a mark changes no decision, so the
      # mark is read here, as the rows are asked for.
      def vrf_route_rows(vrf = nil)
        return [] unless @l3vpn
        @l3vpn.rows(vrf).collect do |r|
          why = if r['transport'] == 'ce'
                  @ce_table&.stale(r['vrf'], r['peer'], r['prefix'])
                elsif r['rd'] && r['peer']
                  @vpn.stale(r['peer'], r['rd'], r['prefix'])
                end
          why ? r.merge('stale' => why) : r
        end
      end

      # vrfs: and l3vpn:, read and checked once, at start: a change needs a
      # restart (Candidate's RESTART_DEFAULT). With no vrfs the PE part is
      # off, whatever l3vpn says.
      # docs/design/l3vpn-pe.md, pull request 6: a speaker that reflects
      # unicast reflects VPN routes too, with the same clients and
      # CLUSTER_ID, through an Export of its own.
      def build_vpn_reflector
        e = @export.is_a?(Hash) ? @export : {}
        return unless !reflector_clients.empty? || e['route_reflector'] == true
        clients = reflector_clients.empty? ? e['clients'] : reflector_clients
        export = BGP::Rib::Export.new(:local_as => @my_as, :router_id => @router_id, :route_reflector => true,
                                      :clients => clients, :cluster_id => e['cluster_id'])
        @vpn_reflector = VpnReflector.new(self, @vpn, export, logger: @logger)
        @vpn.on_change { @vpn_reflector.poke }
        on_established { |p| @vpn_reflector.session_up(p) }
        # docs/design/evpn.md, pull request 4: EVPN routes too, with the
        # same clients and CLUSTER_ID.
        @evpn_reflector = EvpnReflector.new(self, @evpn, export, logger: @logger)
        @evpn.on_change { @evpn_reflector.poke }
        on_established { |p| @evpn_reflector.session_up(p) }
      end

      # The keys of the evpn: block, docs/design/evpn.md, Configuration.
      EVPN_KEYS = %w[vtep duplicate vtep_hold].freeze
      DUPLICATE_KEYS = %w[moves seconds].freeze

      # MAC-VRFs: docs/design/evpn.md, pull request 2. vtep_client is a
      # test's stand-in for vtep4rd's socket.
      def build_evpn(macvrfs, evpn, vtep_client)
        evpn ||= {}
        raise ArgumentError, 'evpn: is a mapping' unless evpn.is_a?(Hash)
        unknown = evpn.keys - EVPN_KEYS
        unless unknown.empty?
          raise ArgumentError, "evpn: unknown key(s) #{unknown.join(', ')}: use one of #{EVPN_KEYS.join(', ')}"
        end
        address = @local_address || @router_id
        list = BGP::Rib::Macvrf.list(macvrfs, address: address, as: @my_as)
        return if list.empty?
        dup = evpn['duplicate'] || {}
        raise ArgumentError, 'evpn: duplicate: is a mapping' unless dup.is_a?(Hash)
        unknown = dup.keys - DUPLICATE_KEYS
        unless unknown.empty?
          raise ArgumentError, "evpn: duplicate: unknown key(s) #{unknown.join(', ')}: use one of #{DUPLICATE_KEYS.join(', ')}"
        end
        positive = lambda do |v, default, what|
          n = v.nil? ? default : Integer(v, exception: false)
          raise ArgumentError, "evpn: #{what}: #{v.inspect} is not a positive number" unless n && n.positive?
          n
        end
        path = evpn.fetch('vtep', VtepClient::SOCKET)
        @vtep_client = vtep_client || VtepClient.new(path)
        @macvrfs = BGP::Rib::Macvrfs.new(
          table: @evpn, macvrfs: list, vtep: @vtep_client, address: address, logger: @logger, events: @events,
          moves: positive.call(dup['moves'], BGP::Rib::Macvrfs::MOVES, 'duplicate: moves'),
          seconds: positive.call(dup['seconds'], BGP::Rib::Macvrfs::SECONDS, 'duplicate: seconds'),
          hold: positive.call(evpn['vtep_hold'], BGP::Rib::Macvrfs::HOLD, 'vtep_hold'))
        @evpn_sync = EvpnSync.new(@macvrfs, logger: @logger)
        @evpn.on_change { @evpn_sync.poke }
        @vtep_events = VtepEvents.new(path, @evpn_sync, logger: @logger) unless vtep_client
        @evpn_exporter = EvpnExporter.new(self, logger: @logger)
        @evpn_sync.after_sync { @evpn_exporter.refresh(@macvrfs.exports) }
        on_established { |p| @evpn_exporter.session_up(p) }
      end

      # Pokes the MAC-VRFs' sync: after evpn.clear_duplicate.
      def evpn_poke
        @evpn_sync&.poke
      end

      def build_l3vpn(vrfs, l3vpn)
        l3vpn ||= {}
        raise ArgumentError, 'l3vpn: is a mapping' unless l3vpn.is_a?(Hash)
        unknown = l3vpn.keys - L3VPN_KEYS
        unless unknown.empty?
          raise ArgumentError, "l3vpn: unknown key(s) #{unknown.join(', ')}: use one of #{L3VPN_KEYS.join(', ')}"
        end
        list = BGP::Rib::Vrf.list(vrfs)
        transport = BGP::Rib::VpnTransport.from_config(l3vpn)
        ces = @peers.select(&:vrf)
        ces.each do |p|
          next if list.any? { |v| v.name == p.vrf }
          raise ArgumentError, "neighbor #{p.address}: vrf #{p.vrf} is not in vrfs:"
        end
        return if list.empty?
        @ce_table = BGP::Rib::VrfCeTable.new(local_as: @my_as, router_id: @router_id) unless ces.empty?
        @l3vpn = BGP::Rib::L3vpn.new(vpn_table: @vpn, vrfs: list, transport: transport, local_as: @my_as,
                                     router_id: @router_id, labels: l3vpn['labels'], logger: @logger,
                                     ce_table: @ce_table)
        @vrf_sync = VrfSync.new(@l3vpn, logger: @logger)
        @vpn.on_change { @vrf_sync.poke }
        if @ce_table
          @ce_table.on_change { @vrf_sync.poke }
          @vrf_ce_exporter = VrfCeExporter.new(self, @l3vpn, logger: @logger)
          @vrf_sync.after_sync { @vrf_ce_exporter.refresh }
          on_established { |p| @vrf_ce_exporter.session_up(p) }
        end
        return if @l3vpn.labels.empty?
        @vpn_exporter = VpnExporter.new(self, logger: @logger)
        @vrf_sync.after_sync { @vpn_exporter.refresh(@l3vpn.exports) }
        on_established { |p| @vpn_exporter.session_up(p) }
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

      # Points the process-wide Log at standard output, which is what
      # a container's log is, and sets its level from the node file.
      #
      # **A speaker handed a logger does nothing here**, and that is the
      # point of the guard rather than tidiness: `run` is `lab/speaker.rb`'s
      # own main loop and one process there is one node, so configuring
      # the process log is right. A speaker inside a program that gave it
      # a callable is not using Log at all, so touching `Log.level` would
      # change a destination it does not write to and that another
      # speaker in the same process may.
      def setup_log
        return if @logger
        Log.create(STDOUT)
        Log.level = Speaker.log_level(@config)
      end

      # Accept sessions from passive peers, matched by source address.
      #
      # vrf: a VRF's own listener, its socket bound to the VRF device, for
      # its passive CE neighbors (pull request 7); nil for the global one.
      def listen(vrf = nil)
        server = vrf ? vrf_listener(vrf) : TCPServer.new(@config.fetch('listen_address', '0.0.0.0'), @config.fetch('port', 179))
        # GTSM: the SYN-ACK goes out with the listener's TTL, so it sends
        # at 255 as soon as one of its peers has `ttl_security`.
        Gtsm.secure(server, listener_minimum(vrf)) if gtsm_listener?(vrf)
        # MD5: the listener holds each passive peer's key under its
        # address, and a connection accepted from that address has it from
        # the SYN on. A peer without `password` is not affected.
        passive_peers(vrf).select(&:password).each { |p| TcpAuth.md5(server, p.address, p.password) }
        Thread.new do
          loop do
            sock = server.accept
            sock = sock.first if sock.is_a?(Array) # Socket#accept answers [socket, addrinfo]
            ip = sock.remote_address.ip_address
            peer = @peers.find { |p| !p.active? && p.vrf == vrf && p.address == ip }
            if peer
              peer.accept(sock)
            else
              log(:warn, "bgp4r: refused connection from unknown peer #{ip}")
              sock.close
            end
          rescue IOError
            break
          end
        end
        server
      end

      def vrf_listener(vrf)
        s = Socket.new(:INET, :STREAM)
        s.setsockopt(:SOCKET, :REUSEADDR, true)
        s.setsockopt(Socket::SOL_SOCKET, Socket::SO_BINDTODEVICE, vrf)
        s.bind(Socket.sockaddr_in(@config.fetch('port', 179), '0.0.0.0'))
        s.listen(16)
        s
      end
    end

  end
end
