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

# Helpers for lab tests: run speakers, read their state files, wait.
#
# Compose runs a topology from lab/topologies/<name>/compose.yml.
# Local runs lab/speaker.rb as plain processes on loopback, no Docker.
# Gobgpd runs a real router the same way, also no Docker.

require 'json'
require 'open3'
require 'rbconfig'
require 'socket'
require 'timeout'
require 'tmpdir'
require 'fileutils'
require 'yaml'

module LabHelper
  ROOT = File.expand_path('../../..', __dir__)
  STATE_FILE = '/tmp/bgp4r-state.json'

  class Compose
    # True when the compose plugin is installed and the daemon answers.
    def self.available?
      [%w[docker compose version], %w[docker info]].all? do |cmd|
        _, status = Open3.capture2e(*cmd)
        status.success?
      end
    rescue SystemCallError
      false
    end

    # env: extra environment for docker compose, e.g. ROUTEGEN_COUNT. The
    # compose file passes the variables it names on to the containers.
    def initialize(topology, env: {})
      @file = File.join(ROOT, 'lab', 'topologies', topology, 'compose.yml')
      @env = env.to_h { |k, v| [k.to_s, v.to_s] }
    end

    def up ; compose('up', '--detach', '--build') ; end
    def down ; compose('down', '--volumes', '--remove-orphans', '--timeout', '5') ; end

    # For a topology whose point is one container running to completion:
    # runs in the foreground until service exits and returns [output,
    # that service's exit status]. Never raises on a non-zero status, the
    # status is the answer.
    def up_until_exit(service, timeout: 900)
      out, status = Timeout.timeout(timeout) do
        Open3.capture2e(@env, 'docker', 'compose', '-f', @file, 'up', '--build',
                        '--abort-on-container-exit', '--exit-code-from', service)
      end
      [out, status.exitstatus]
    end

    # Copies a file out of a service's container into dir. Works after
    # the container has exited, which is when a one-shot run is read.
    def cp(service, path, dir)
      compose('cp', "#{service}:#{path}", dir)
    end

    def stop(node) ; compose('stop', '--timeout', '5', node) ; end
    def start(node) ; compose('start', node) ; end
    def logs ; compose('logs', '--no-color', check: false) ; end

    # The node's state as written by lab/speaker.rb, or nil if not there yet.
    def state(node)
      JSON.parse(compose('exec', '-T', node, 'cat', STATE_FILE, check: false))
    rescue JSON::ParserError
      nil
    end

    private

    def compose(*args, check: true)
      out, status = Open3.capture2e(@env, 'docker', 'compose', '-f', @file, *args)
      raise "docker compose #{args.join(' ')} failed:\n#{out}" if check && !status.success?
      out
    end
  end

  class Local
    # nodes: name => speaker config (a Hash). state_file is filled in here.
    # env: extra environment for every speaker process, e.g. LAB_LOG_LEVEL.
    def initialize(nodes, env: {})
      @env = env
      @dir = Dir.mktmpdir('bgp4r-lab')
      @nodes = nodes.to_h { |name, conf| [name, conf.merge('state_file' => File.join(@dir, "#{name}.json"))] }
      @pids = {}
    end

    def self.free_port
      s = TCPServer.new('127.0.0.1', 0)
      s.addr[1]
    ensure
      s.close if s
    end

    def up ; @nodes.each_key { |n| start(n) ; sleep 0.3 } ; end

    def down
      @pids.each_key { |n| stop(n) }
      FileUtils.rm_rf(@dir)
    end

    def start(node)
      conf = File.join(@dir, "#{node}.yml")
      File.write(conf, @nodes.fetch(node).to_yaml)
      log = File.join(@dir, "#{node}.log")
      # One open file for both streams. out: log, err: log opened it twice,
      # and lines from stderr overwrote lines from stdout.
      @pids[node] = Process.spawn(@env, RbConfig.ruby, File.join(ROOT, 'lab', 'speaker.rb'), conf,
                                  out: log, err: [:child, :out])
    end

    def stop(node)
      pid = @pids.delete(node) or return
      Process.kill('TERM', pid)
      Process.wait(pid)
    rescue Errno::ESRCH, Errno::ECHILD
    end

    def log(node)
      File.read(File.join(@dir, "#{node}.log"))
    rescue Errno::ENOENT
      ''
    end

    def logs
      Dir[File.join(@dir, '*.log')].sort.map { |f| "== #{File.basename(f)}\n#{File.read(f)}" }.join("\n")
    end

    def state(node)
      JSON.parse(File.read(@nodes.fetch(node)['state_file']))
    rescue Errno::ENOENT, JSON::ParserError
      nil
    end
  end

  # A real router as a plain process on loopback, no Docker. GoBGP is the
  # one implementation in the lab that needs no privilege and no container
  # to peer with bgp4r, so a test can have a second implementation's
  # opinion wherever the binary is installed.
  #
  # docs/protocol-testing.md runs one by hand on the standard port, with
  # lab/conformance/gobgpd.conf. This writes its own config instead, on
  # ports of its own, for two reasons: a test must not collide with a
  # daemon somebody is already running, and neither side then needs root
  # or net.ipv4.ip_unprivileged_port_start to use port 179. GoBGP listens
  # on 179 by default even when it only dials out, so the generated config
  # moves that too.
  #
  # GOBGPD and GOBGP name the binaries when they are not on PATH.
  class Gobgpd
    def self.bin ; ENV['GOBGPD'] || 'gobgpd' ; end
    def self.client ; ENV['GOBGP'] || 'gobgp' ; end

    # The daemon's own version line, or nil when it is not installed.
    def self.version
      out, status = Open3.capture2e(bin, '--version')
      status.success? ? out.strip : nil
    rescue SystemCallError
      nil
    end

    def self.available? ; !version.nil? ; end

    # The major version, which is what a conformance expectation turns on:
    # GoBGP 4 fixed a case GoBGP 3 answers with a session reset. nil when
    # the daemon is missing or its version line does not parse, and a
    # caller that cannot name the version must not guess at the answers.
    def self.major
      v = version or return nil
      v[/\bversion\s+v?(\d+)\./, 1]&.to_i
    end

    attr_reader :local, :as, :router_id, :peer, :peer_as, :port

    # local:   address the router speaks from
    # peer:    address bgp4r listens on, which the router dials
    # port:    port bgp4r listens on, which the router dials
    def initialize(local: '127.0.0.2', as: 65002, router_id: '10.0.0.2',
                   peer: '127.0.0.1', peer_as: 65001, port: nil, ipv6: true)
      @local, @as, @router_id = local, as, router_id
      @peer, @peer_as, @ipv6 = peer, peer_as, ipv6
      @port = port || Local.free_port
      @listen_port = Local.free_port
      @api_port = Local.free_port
      @dir = Dir.mktmpdir('bgp4r-gobgpd')
    end

    def config
      families = ['ipv4-unicast']
      families << 'ipv6-unicast' if @ipv6
      afi_safis = families.collect { |f|
        "  [[neighbors.afi-safis]]\n" \
        "    [neighbors.afi-safis.config]\n" \
        "      afi-safi-name = \"#{f}\"\n"
      }.join
      global = <<~TOML
        [global.config]
          as = #{@as}
          router-id = "#{@router_id}"
          local-address-list = ["#{@local}"]
          # Its own listening port, so the daemon needs no privilege. It
          # only dials out here; GoBGP would still bind 179 without this.
          port = #{@listen_port}

        [[neighbors]]
          [neighbors.config]
            neighbor-address = "#{@peer}"
            peer-as = #{@peer_as}
          [neighbors.transport.config]
            local-address = "#{@local}"
            # Where bgp4r listens, so our side needs no privilege either.
            remote-port = #{@port}
          [neighbors.timers.config]
            # A caller may give each case its own session, so keep coming back.
            connect-retry = 2
            idle-hold-time-after-reset = 0
      TOML
      global + afi_safis
    end

    # Starts the daemon and waits until its API answers, which is the only
    # signal that it read the config at all. Raises with the daemon's log,
    # which names the config key it rejected.
    def up(timeout: 30)
      path = File.join(@dir, 'gobgpd.conf')
      File.write(path, config)
      @log = File.join(@dir, 'gobgpd.log')
      @pid = Process.spawn(self.class.bin, '-f', path, '--api-hosts', "#{@local}:#{@api_port}",
                           out: @log, err: [:child, :out])
      deadline = Time.now + timeout
      until neighbors
        raise "gobgpd did not come up in #{timeout}s:\n#{log}" if Time.now > deadline
        sleep 0.5
      end
      self
    end

    def down
      @log_text = log
      if @pid
        Process.kill('TERM', @pid)
        Process.wait(@pid)
      end
    rescue Errno::ESRCH, Errno::ECHILD
    ensure
      @pid = nil
      FileUtils.rm_rf(@dir)
    end

    # The client's neighbor table, or nil while the daemon is not answering.
    def neighbors
      out, status = Open3.capture2e(self.class.client, '-u', @local,
                                    '-p', @api_port.to_s, 'neighbor')
      status.success? ? out : nil
    rescue SystemCallError
      nil
    end

    # What to pass lab/fault_matrix.rb as --rib-command: one argument,
    # spaces and all, since the matrix runs it through a shell.
    def rib_command
      "#{self.class.client} -u #{@local} -p #{@api_port} global rib"
    end

    # The router's RIB, parsed: prefix => array of paths. nil while the
    # daemon is not answering. An empty RIB answers {}, which is a real
    # answer and not the same as nil, so a caller can tell "nothing there"
    # from "could not ask".
    #
    # This is what a test asserts a bgp4r UPDATE against, because it is the
    # router's own reading of what we sent rather than ours.
    def rib
      out, status = Open3.capture2e(self.class.client, '-u', @local,
                                    '-p', @api_port.to_s, 'global', 'rib', '-j')
      return nil unless status.success?
      JSON.parse(out)
    rescue SystemCallError, JSON::ParserError
      nil
    end

    # One path out of that RIB for a prefix, or nil. Picks the best path,
    # since a prefix with one path has that one marked best.
    def path(prefix)
      paths = (rib || {})[prefix] or return nil
      paths.find { |p| p['best'] } || paths.first
    end

    # A path's attributes keyed by their BGP attribute type code, so an
    # assertion names the code point the RFC does: 2 AS_PATH, 3 NEXT_HOP,
    # 5 LOCAL_PREF, 9 ORIGINATOR_ID and 10 CLUSTER_LIST here. The client
    # prints no attribute bgp4r did not send, so a missing key means the
    # attribute did not arrive.
    def self.attrs(path)
      (path['attrs'] || []).to_h { |a| [a['type'], a] }
    end

    # A path's AS_PATH as one flat list of AS numbers, in order. RFC 4271
    # section 4.3 gives AS_PATH as a sequence of segments, and the client
    # prints them that way, so this is the common case flattened. An empty
    # AS_PATH, which is what an internal peer gets, has no segments and
    # answers []. Read the segments themselves when the shape matters, as
    # it does for telling an AS_SEQUENCE from an AS_SET.
    def self.as_path(path)
      segments = (attrs(path)[2] || {})['as_paths'] || []
      segments.collect { |s| s['asns'] || [] }.flatten
    end

    # The daemon's own log: what it made of each UPDATE, in its words.
    # Cached at down, since the directory goes with it.
    def log
      return @log_text if @log_text
      @log ? File.read(@log) : ''
    rescue Errno::ENOENT
      ''
    end
  end

  # Wait until the block returns a truthy value, or fail with message.
  def wait_for(message, timeout: 30, interval: 0.5)
    deadline = Time.now + timeout
    loop do
      result = yield
      return result if result
      flunk "#{message} (waited #{timeout}s)" if Time.now > deadline
      sleep interval
    end
  end

  # One neighbor's entry in a node's state, or nil.
  def neighbor(lab, node, address)
    s = lab.state(node)
    s && s['neighbors'] && s['neighbors'][address]
  end

  def wait_established(lab, node, address, timeout: 30)
    wait_for("#{node} session to #{address} Established", timeout: timeout) do
      n = neighbor(lab, node, address)
      n if n && n['state'] == 'Established'
    end
  end

  def wait_routes(lab, node, address, prefixes, timeout: 30)
    wait_for("#{node} to receive #{prefixes.join(', ')} from #{address}", timeout: timeout) do
      n = neighbor(lab, node, address)
      n if n && (prefixes - n['received'].keys).empty?
    end
  end
end
