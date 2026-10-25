#!/usr/bin/env ruby
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

#
# A generic bgp4r speaker for the lab, driven by one YAML file per node.
#
#   ruby -I. lab/speaker.rb lab/topologies/two-speakers/r1.yml
#
# It peers with the neighbors in its file, announces its routes, and keeps
# a JSON file with the state of each session and the routes it received.
# Tests read that file. See lab/README.md for the YAML keys.
#
# It is an origin and a sink, not a router: it never passes on routes it
# learned from one neighbor to another.

$LOAD_PATH.unshift File.expand_path('..', __dir__)
require 'bgp4r'
require 'bgp/misc/route_generator'
require 'yaml'
require 'json'
require 'socket'
require 'thread'

module Lab

  # Records what one neighbor tells us: peer details, received routes and
  # timing. With mode 'count' it keeps counters and timing only, not each
  # route, so a sink can take a large feed.
  class Recorder
    MODES = %w[routes count]

    attr_reader :data, :mode

    def initialize(mode='routes')
      @mode = mode.to_s
      raise ArgumentError, "record #{mode.inspect}: use one of #{MODES.join(', ')}" unless MODES.include?(@mode)
      @lock = Mutex.new
      @data = { 'peer_as' => nil, 'peer_router_id' => nil, 'updates_received' => 0,
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
      @lock.synchronize { reset_session }
    end

    def error!(txt)
      @lock.synchronize { @data['last_error'] = txt }
    end

    def snapshot
      @lock.synchronize do
        h = Marshal.load(Marshal.dump(@data))
        h['prefixes_received'] = h['received'].size if routes?
        h.merge!(timing(h['prefixes_received']))
        h.merge!('first_prefix' => @first_prefix, 'last_prefix' => @last_prefix) unless routes?
        h
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

    def iso(t) ; t && t.utc.iso8601(3) ; end
  end

  # One configured neighbor: its settings, its current session, its record.
  class Peer
    attr_reader :address, :recorder, :config

    def initialize(speaker, config)
      @speaker, @config = speaker, config
      @address = config.fetch('address')
      @recorder = Recorder.new(config.fetch('record', 'routes'))
      @neighbor = nil
      @busy = Mutex.new
    end

    def remote_as ; @config.fetch('as') ; end
    def ebgp? ; remote_as != @speaker.my_as ; end
    def active? ; @config.fetch('connect', false) ; end
    def state ; @neighbor ? @neighbor.state : 'Idle' ; end
    def established? ; @neighbor && @neighbor.is_established? ; end

    # Active side: connect, run the session, wait, reconnect, until shutdown.
    def run_active
      Thread.new do
        until @speaker.stopping?
          begin
            sock = Socket.tcp(@address, @config.fetch('port', 179),
                              @speaker.local_address, connect_timeout: 5)
            run_session(sock)
          rescue SystemCallError, IOError, SocketError => e
            @recorder.error!("connect: #{e.message}")
          end
          sleep(@config.fetch('retry', 2)) unless @speaker.stopping?
        end
      end
    end

    # Passive side: the speaker accepted a connection from this peer.
    def accept(sock)
      if @busy.locked?
        sock.close # one session per peer; keep the one we have
        return
      end
      Thread.new { run_session(sock) }
    end

    def stop
      @neighbor.stop if @neighbor
    end

    private

    def run_session(sock)
      @busy.synchronize do
        n = new_neighbor
        @neighbor = n
        n.start(:session => sock, :timeout => @config.fetch('open_timeout', 30))
        if n.is_established?
          @recorder.established!
          announce(n, sock)
          n.wait_for_state(:Idle)
        else
          @recorder.error!("session did not reach Established, state #{n.state}")
          n.stop
        end
        @recorder.session_down!
      end
    end

    def new_neighbor
      n = BGP::Neighbor.new(:my_as => @speaker.my_as, :id => @speaker.router_id,
                            :holdtime => @config.fetch('hold_time', 90),
                            :remote_addr => @address, :local_addr => @speaker.local_address)
      Array(@config.fetch('capabilities', ['as4_byte'])).each { |c| add_capability(n, c) }
      n.add_observer @recorder
      n
    end

    def add_capability(n, name)
      case name.to_s
      when 'as4_byte'          then n.capability :as4_byte
      when 'route_refresh'     then n.capability :route_refresh
      when 'mbgp_ipv4_unicast' then n.capability :mbgp, :ipv4, :unicast
      when 'mbgp_ipv6_unicast' then n.capability :mbgp, :ipv6, :unicast
      else raise ArgumentError, "unknown capability #{name.inspect} for #{@address}"
      end
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
    attr_reader :my_as, :router_id, :local_address, :announcements, :peers

    def initialize(config)
      @config = config
      @my_as = config.fetch('as')
      @router_id = config.fetch('router_id')
      @local_address = config['local_address']
      @announcements = Array(config['announce'])
      @state_file = config.fetch('state_file', '/tmp/bgp4r-state.json')
      @peers = Array(config.fetch('neighbors')).map { |c| Peer.new(self, c) }
      @stopping = false
    end

    def stopping? ; @stopping ; end

    def run
      setup_log
      @server = listen if @peers.any? { |p| !p.active? }
      @peers.select(&:active?).each(&:run_active)
      writer = Thread.new { loop { write_state ; sleep 0.5 } }
      %w[INT TERM].each { |sig| trap(sig) { @stopping = true } }
      sleep 0.2 until @stopping
      writer.kill
      @server.close if @server
      @peers.each(&:stop)
      write_state
    end

    # One UPDATE for one announce block. RFC 4271 section 5.1: an eBGP
    # speaker prepends its own AS to AS_PATH and sets NEXT_HOP to itself.
    # Over iBGP the AS_PATH is left as configured and LOCAL_PREF is sent.
    def build_update(a, ebgp, local_ip)
      BGP::Update.new(path_attribute(a, ebgp, local_ip), BGP::Nlri.new(*Array(a.fetch('prefixes'))))
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
      { 'router_id' => @router_id, 'as' => @my_as, 'updated_at' => Time.now.utc.iso8601(3),
        'neighbors' => @peers.to_h { |p| [p.address, { 'state' => p.state }.merge(p.recorder.snapshot)] } }
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
            Log.warn "lab: refused connection from unknown peer #{ip}"
            sock.close
          end
        rescue IOError
          break
        end
      end
      server
    end

    # Write atomically, so a reader never sees half a file.
    def write_state
      tmp = "#{@state_file}.tmp"
      File.write(tmp, JSON.pretty_generate(state))
      File.rename(tmp, @state_file)
    end
  end

  def self.main(argv)
    $stdout.sync = true # docker logs shows lines as they happen
    abort "usage: ruby -I. lab/speaker.rb NODE.yml" unless argv.size == 1
    Speaker.new(YAML.safe_load(File.read(argv[0]))).run
  rescue ArgumentError, KeyError => e
    abort "lab/speaker.rb: #{e.message}"
  end
end

require 'time'
Lab.main(ARGV) if $0 == __FILE__
