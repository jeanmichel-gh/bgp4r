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
# Sends every BGP::Fault::CATALOG case to a router and reports what it
# did with each one. bgp4r listens and the router connects, so it works
# with any implementation that can be told to peer with us.
#
#   ruby lab/fault_matrix.rb --peer 127.0.0.2 --peer-as 65002
#   ruby lab/fault_matrix.rb --peer 127.0.0.2 --peer-as 65002 --json out.json
#
# What it can tell apart from one session:
#
#   reset     the router sent a NOTIFICATION, or dropped the session
#   kept      the session stayed up
#
# RFC 7606 treat-as-withdraw and attribute-discard both keep the session
# up. To tell those two apart the router has to say whether it installed
# the route, so --rib-command runs a shell command that prints its RIB
# and the prefix is looked for in the output.

$LOAD_PATH.unshift File.expand_path('..', __dir__)
require 'bgp4r'
require 'socket'
require 'json'
require 'optparse'

module BGP
  class Fault_matrix

    # The prefix each faulty UPDATE carries.
    PREFIX = '203.0.113.0/24'

    Result = Struct.new(:name, :description, :expected, :outcome, :code, :subcode,
                        :installed, :agrees, keyword_init: true)

    def initialize(opts)
      @opts = opts
      @inbox = Queue.new
    end

    def log(msg)
      warn msg if @opts[:verbose]
    end

    # Called by the Neighbor for every message received.
    def update(msg)
      @inbox << msg
    end

    def run(names)
      results = names.collect { |name| run_one(name) }
      stop_listening
      results
    end

    private

    def entry(name)
      Fault.catalog.find { |e| e[:name] == name }
    end

    # One fault, on a session of its own: a reset leaves nothing to reuse.
    def run_one(name)
      e = entry(name)
      raise ArgumentError, "unknown fault #{name.inspect}" unless e
      session = establish
      return Result.new(name: name, description: e[:description], expected: e[:action],
                        outcome: :no_session, agrees: false) unless session

      drain
      @peer.send_message update_for(name)
      notification = wait_for_notification(@opts[:settle])
      kept = @peer.is_established?

      outcome = (notification or not kept) ? :reset : :kept
      installed = (outcome == :kept) ? route_installed? : nil

      Result.new(name: name, description: e[:description], expected: e[:action],
                 outcome: outcome,
                 code: notification && notification.to_hash[:code],
                 subcode: notification && notification.to_hash[:subcode],
                 installed: installed,
                 agrees: agrees?(e[:action], outcome, installed))
    ensure
      reset_session
    end

    # The RFC 7606 action the catalog expects, against what was seen.
    def agrees?(expected, outcome, installed)
      case expected
      when :session_reset       then outcome == :reset
      when :treat_as_withdraw   then outcome == :kept && installed != true
      when :attribute_discard   then outcome == :kept && installed != false
      end
    end

    def update_for(name)
      built = Fault.build(name)
      pa = built.is_a?(Path_attribute) ? built : Path_attribute.new(built)
      # The attributes a plain UPDATE needs, unless the fault is that one.
      have = pa.attributes.collect { |a| a.type }
      pa.append Origin.new(0)                    unless have.include?(ATTR::ORIGIN)
      pa.append As_path.new(@opts[:my_as])       unless have.include?(ATTR::AS_PATH)
      pa.append Next_hop.new(@opts[:next_hop])   unless have.include?(ATTR::NEXT_HOP)
      Update.new(pa, Nlri.new(PREFIX))
    end

    def listener
      @listener ||= TCPServer.new(@opts[:listen], @opts[:port])
    end

    def accept_loop
      @accepting ||= Thread.new do
        loop do
          begin
            @peer.start_session(listener.accept)
          rescue StandardError => e
            log "accept: #{e.class}: #{e.message}"
          end
        end
      end
    end

    def neighbor
      @peer ||= begin
        n = Neighbor.new(4, @opts[:my_as], @opts[:holdtime], @opts[:id],
                         @opts[:peer], @opts[:listen])
        n.capability :as4_byte
        n.capability :mbgp, :ipv4, :unicast
        # The duplicate MP_REACH case carries IPv6 NLRI. Without this the
        # router resets over an AFI it never agreed to, not the duplicate.
        n.capability :mbgp, :ipv6, :unicast
        n.add_observer self
        n
      end
    end

    # Waits for the router to connect and finish the OPEN exchange.
    def establish
      neighbor
      accept_loop
      return true if @peer.is_established?
      @peer.wait_for_state(:Established, @opts[:connect_timeout])
    end

    def reset_session
      @peer.stop if @peer and not @peer.is_idle?
    rescue StandardError => e
      log "stop: #{e.class}: #{e.message}"
    end

    def stop_listening
      @accepting.kill if @accepting
      @peer.close if @peer
      @listener.close if @listener
    rescue StandardError
      nil
    end

    def drain
      @inbox.clear
    end

    # A NOTIFICATION within secs, or nil. Other messages are ignored.
    def wait_for_notification(secs)
      deadline = Time.now + secs
      loop do
        left = deadline - Time.now
        return nil if left <= 0
        begin
          msg = Timeout.timeout(left) { @inbox.pop }
        rescue Timeout::Error
          return nil
        end
        return msg if msg.is_a?(Notification)
      end
    end

    # true when the router installed the prefix, false when it did not,
    # nil when there is no way to ask.
    def route_installed?
      cmd = @opts[:rib_command]
      return nil unless cmd
      out = `#{cmd} 2>&1`
      out.include?(PREFIX.split('/').first)
    rescue StandardError => e
      log "rib: #{e.class}: #{e.message}"
      nil
    end

  end
end

def parse(argv)
  o = { listen: '127.0.0.1', port: 179, my_as: 65001, peer_as: 65002,
        id: '10.0.0.1', next_hop: '10.0.0.1', holdtime: 180,
        connect_timeout: 40, settle: 4, verbose: false }
  OptionParser.new do |p|
    p.banner = 'Usage: ruby lab/fault_matrix.rb --peer ADDR [options]'
    p.on('--peer ADDR', 'address the router speaks from') { |v| o[:peer] = v }
    p.on('--peer-as AS', Integer, 'the router AS')        { |v| o[:peer_as] = v.to_i }
    p.on('--listen ADDR', 'address bgp4r listens on')     { |v| o[:listen] = v }
    p.on('--port PORT', Integer, 'port bgp4r listens on') { |v| o[:port] = v.to_i }
    p.on('--my-as AS', Integer, 'the bgp4r AS')           { |v| o[:my_as] = v.to_i }
    p.on('--id ID', 'the bgp4r router id')                { |v| o[:id] = v }
    p.on('--next-hop ADDR', 'NEXT_HOP to advertise')      { |v| o[:next_hop] = v }
    p.on('--settle SECS', Float, 'wait after each fault') { |v| o[:settle] = v }
    p.on('--rib-command CMD', 'shell command printing the router RIB') { |v| o[:rib_command] = v }
    p.on('--only NAMES', 'comma separated fault names')   { |v| o[:only] = v.split(',').collect(&:to_sym) }
    p.on('--json FILE', 'write the results as JSON')      { |v| o[:json] = v }
    p.on('--verbose', 'log what the harness is doing')    { o[:verbose] = true }
    p.on('-h', '--help') { puts p; exit 0 }
  end.parse!(argv)
  abort 'need --peer ADDR' unless o[:peer]
  o
end

if __FILE__ == $0
  opts = parse(ARGV)
  Log.create
  Log.level = opts[:verbose] ? Logger::WARN : Logger::FATAL

  names = opts[:only] || BGP::Fault::CATALOG.collect(&:first)
  results = BGP::Fault_matrix.new(opts).run(names)

  width = results.collect { |r| r.name.length }.max
  puts format("%-#{width}s  %-22s  %-18s  %-8s  %s", 'FAULT', 'EXPECTED (RFC 7606)', 'WHAT IT DID', 'ROUTE', 'AGREES')
  results.each do |r|
    did = r.outcome == :reset ? "reset#{r.code ? " #{r.code}/#{r.subcode}" : ' (no notification)'}" : 'kept the session'
    route = r.installed.nil? ? '-' : (r.installed ? 'installed' : 'dropped')
    puts format("%-#{width}s  %-22s  %-18s  %-8s  %s", r.name, r.expected, did, route, r.agrees ? 'yes' : 'NO')
  end

  if opts[:json]
    File.write(opts[:json], JSON.pretty_generate(results.collect(&:to_h)))
    puts "\nwrote #{opts[:json]}"
  end

  exit(results.all?(&:agrees) ? 0 : 1)
end
