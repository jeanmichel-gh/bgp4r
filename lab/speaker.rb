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
require 'yaml'
require 'json'
require 'socket'
require 'thread'

module Lab

  # Records what one neighbor tells us: peer details and received routes.
  class Recorder
    attr_reader :data

    def initialize
      @lock = Mutex.new
      @data = { 'peer_as' => nil, 'peer_router_id' => nil, 'updates_received' => 0,
                'established_count' => 0, 'last_error' => nil, 'received' => {} }
    end

    # Called by BGP::Neighbor (an Observable) with every message it receives.
    def update(msg)
      @lock.synchronize do
        case msg
        when BGP::Open
          @data['peer_as'] = msg.local_as
          @data['peer_router_id'] = msg.bgp_id
        when BGP::Update
          @data['updates_received'] += 1
          msg.withdrawn.to_ary.each { |p| @data['received'].delete(p) } if msg.withdrawn
          if msg.nlri
            attrs = Recorder.attributes(msg.path_attribute)
            msg.nlri.to_ary.each { |p| @data['received'][p] = attrs }
          end
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
      @lock.synchronize { @data['received'] = {} }
    end

    def error!(txt)
      @lock.synchronize { @data['last_error'] = txt }
    end

    def snapshot
      @lock.synchronize { Marshal.load(Marshal.dump(@data)) }
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
  end

  # One configured neighbor: its settings, its current session, its record.
  class Peer
    attr_reader :address, :recorder, :config

    def initialize(speaker, config)
      @speaker, @config = speaker, config
      @address = config.fetch('address')
      @recorder = Recorder.new
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
        n.send_message @speaker.build_update(a, ebgp?, local)
      end
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
      path = Array(a['as_path'])
      path = [@my_as] + path if ebgp
      attrs = [BGP::Origin.new(a.fetch('origin', 0)),
               BGP::Next_hop.new(a.fetch('next_hop', local_ip)),
               BGP::As_path.new(*path)]
      attrs << BGP::Multi_exit_disc.new(a['med']) if a['med']
      attrs << BGP::Local_pref.new(a.fetch('local_pref', 100)) unless ebgp
      attrs << BGP::Communities.new(Array(a['communities']).join(' ')) if a['communities']
      BGP::Update.new(BGP::Path_attribute.new(*attrs), BGP::Nlri.new(*Array(a.fetch('prefixes'))))
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
