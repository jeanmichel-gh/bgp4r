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

require 'json'
require 'open3'
require 'rbconfig'
require 'socket'
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

    def initialize(topology)
      @file = File.join(ROOT, 'lab', 'topologies', topology, 'compose.yml')
    end

    def up ; compose('up', '--detach', '--build') ; end
    def down ; compose('down', '--volumes', '--remove-orphans', '--timeout', '5') ; end
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
      out, status = Open3.capture2e('docker', 'compose', '-f', @file, *args)
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
      @pids[node] = Process.spawn(@env, RbConfig.ruby, File.join(ROOT, 'lab', 'speaker.rb'), conf,
                                  out: log, err: log)
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
