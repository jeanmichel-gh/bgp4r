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
# --dial PORT reverses that for a router whose listening port is known,
# which is every router the lab starts itself. Each case needs a session
# of its own, and waiting for the router to dial back is what that costs:
# 10 to 14s a case against GoBGP 3.23.0, where dialling it takes under
# 3s. See the comment on with_session.
#
#   ruby lab/fault_matrix.rb --peer 127.0.0.2 --peer-as 65002
#   ruby lab/fault_matrix.rb --peer 127.0.0.2 --peer-as 65002 --json out.json
#   ruby lab/fault_matrix.rb --peer 127.0.0.2 --peer-as 65002 --dial 1790
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
                        :installed, :verdict, keyword_init: true)

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
      baseline
      results = names.collect { |name| run_one(name) }
      close_session
      results
    end

    # Whether the RIB command can be trusted. A router that does not
    # install a plain route, because the next hop does not resolve in
    # this topology for instance, cannot tell us what it did with a
    # faulty one either. Saying so beats scoring every discard case
    # against a probe that always answers no.
    attr_reader :rib_usable

    def baseline
      @rib_usable = false
      return unless @opts[:rib_command]
      with_session do |up|
        next unless up
        drain
        @peer.send_message Update.new(
          Path_attribute.new(Origin.new(0), As_path.new(@opts[:my_as]),
                             Next_hop.new(@opts[:next_hop])),
          Nlri.new(PREFIX))
        wait_for_notification(@opts[:settle])
        @rib_usable = route_installed? == true
      end
      log "rib probe usable: #{@rib_usable}"
    end

    def entry(name)
      Fault.catalog.find { |e| e[:name] == name }
    end

    # One fault, on a session of its own: a reset leaves nothing to reuse.
    def run_one(name)
      e = entry(name)
      raise ArgumentError, "unknown fault #{name.inspect}" unless e
      with_session do |up|
        next no_session(e, name) unless up
        drain
        begin
          @peer.send_message update_for(name)
        rescue StandardError => ex
          log "send #{name}: #{ex.class}: #{ex.message}"
          next result(e, name, :reset, nil, nil)
        end
        notification = wait_for_notification(@opts[:settle])
        outcome = (notification or not @peer.is_established?) ? :reset : :kept
        installed = (outcome == :kept && @rib_usable) ? route_installed? : nil
        result(e, name, outcome, notification, installed)
      end
    end

    def no_session(e, name)
      Result.new(name: name, description: e[:description], expected: e[:action],
                 outcome: :no_session, verdict: :differs)
    end

    def result(e, name, outcome, notification, installed)
      Result.new(name: name, description: e[:description], expected: e[:action],
                 outcome: outcome,
                 code: notification && notification.to_hash[:code],
                 subcode: notification && notification.to_hash[:subcode],
                 installed: installed,
                 verdict: verdict(e[:action], outcome, installed))
    end

    # What was seen against what the catalog expects.
    #
    #   :agrees    the router did what RFC 7606 asks
    #   :differs   it did not
    #   :partial   the session part is right, but telling treat-as-withdraw
    #              from attribute-discard needs a RIB answer we do not have
    def verdict(expected, outcome, installed)
      return outcome == :reset ? :agrees : :differs if expected == :session_reset
      return :differs unless outcome == :kept
      return :partial if installed.nil?
      wanted = (expected == :attribute_discard)
      installed == wanted ? :agrees : :differs
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

    # A session of its own for each fault, because a reset leaves
    # nothing to reuse. Two ways to get one, and which one is used is
    # the whole per case cost.
    #
    # By default the router dials us. That works with any
    # implementation that can be told to peer with us, which is why it
    # is the default, and it is slow: GoBGP 3.23.0 waits 10 to 14s
    # before dialling back, and neither connect-retry nor
    # idle-hold-time-after-reset moves that. Measured on 2026-10-31,
    # asking for 30 instead of 2 changed nothing, outside this harness
    # as well as in it.
    #
    # --dial reverses it, for a router whose listening port is known,
    # which is every router the lab starts itself. The same GoBGP takes
    # an inbound session within 3s of the last one ending, so the
    # matrix stops paying for a timer it cannot set.
    def with_session
      ok = @opts[:dial] ? dial_session : accept_session
      yield ok
    ensure
      close_session
    end

    # How long one dial may take, and how long to wait before trying
    # again. The router may still be tearing down the previous session,
    # so a refused or unanswered dial is not a failure until
    # connect_timeout is spent.
    DIAL_TIMEOUT = 3
    DIAL_RETRY = 0.5

    def dial_session
      close_session
      deadline = Time.now + @opts[:connect_timeout]
      loop do
        @peer = new_neighbor
        begin
          @peer.start(:port => @opts[:dial], :timeout => DIAL_TIMEOUT)
          return true if @peer.is_established?
        rescue StandardError => e
          log "dial #{@opts[:peer]}:#{@opts[:dial]}: #{e.class}: #{e.message}"
        end
        close_session
        return false if Time.now > deadline
        sleep DIAL_RETRY
      end
    end

    def accept_session
      open_listener
      @peer.wait_for_state(:Established, @opts[:connect_timeout])
    end

    # A listener of its own for each fault too, when the router dials
    # us. Reusing one leaves connections the router made while we were
    # not listening queued in its backlog, and the next accept takes a
    # dead one, so every other fault saw no session at all.
    def open_listener
      close_session
      @listener = TCPServer.new(@opts[:listen], @opts[:port])
      listening = @listener
      @peer = new_neighbor
      @accepting = Thread.new do
        loop do
          begin
            session = listening.accept
            from = session.peeraddr[3] rescue nil
            if from != @opts[:peer]
              # Another router on this host dialing the same port. Its
              # answers would land in this run and look like the answers
              # of the router under test.
              log "accept: from #{from}, not #{@opts[:peer]}, hanging up"
              session.close
            elsif @peer.is_idle?
              @peer.start_session(session)
            else
              session.close
            end
          rescue StandardError
            break
          end
        end
      end
    end

    # Covers both ways in: when we dialled there is no listener and no
    # accept thread, and those two branches are simply skipped.
    def close_session
      @accepting.kill if @accepting
      begin
        @peer.close if @peer
      rescue StandardError
        nil
      end
      begin
        @listener.close if @listener and not @listener.closed?
      rescue StandardError
        nil
      end
      @accepting, @listener, @peer = nil, nil, nil
    end

    def new_neighbor
      n = Neighbor.new(4, @opts[:my_as], @opts[:holdtime], @opts[:id],
                       @opts[:peer], @opts[:listen])
      n.capability :as4_byte
      n.capability :mbgp, :ipv4, :unicast
      # The duplicate MP_REACH case carries IPv6 NLRI, so without this the
      # router resets over an address family it never agreed to instead of
      # the duplicate. --no-ipv6 turns it off for a router that cannot do
      # IPv6 at all; the duplicate case is then testing the wrong rule.
      n.capability :mbgp, :ipv6, :unicast if @opts[:ipv6]
      n.add_observer self
      n
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
        connect_timeout: 40, settle: 4, verbose: false, ipv6: true }
  OptionParser.new do |p|
    p.banner = 'Usage: ruby lab/fault_matrix.rb --peer ADDR [options]'
    p.on('--peer ADDR', 'address the router speaks from') { |v| o[:peer] = v }
    p.on('--peer-as AS', Integer, 'the router AS')        { |v| o[:peer_as] = v.to_i }
    p.on('--listen ADDR', 'address bgp4r listens on')     { |v| o[:listen] = v }
    p.on('--port PORT', Integer, 'port bgp4r listens on') { |v| o[:port] = v.to_i }
    p.on('--dial PORT', Integer,
         'dial the router on PORT instead of waiting for it to dial us') { |v| o[:dial] = v.to_i }
    p.on('--my-as AS', Integer, 'the bgp4r AS')           { |v| o[:my_as] = v.to_i }
    p.on('--id ID', 'the bgp4r router id')                { |v| o[:id] = v }
    p.on('--next-hop ADDR', 'NEXT_HOP to advertise')      { |v| o[:next_hop] = v }
    p.on('--settle SECS', Float, 'wait after each fault') { |v| o[:settle] = v }
    p.on('--rib-command CMD', 'shell command printing the router RIB') { |v| o[:rib_command] = v }
    p.on('--[no-]ipv6', 'negotiate IPv6 unicast (default on)') { |v| o[:ipv6] = v }
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
  matrix = BGP::Fault_matrix.new(opts)
  results = matrix.run(names)

  width = results.collect { |r| r.name.length }.max
  verdicts = { :agrees => 'agrees', :differs => 'DIFFERS', :partial => 'session only' }
  puts format("%-#{width}s  %-22s  %-18s  %-10s  %s", 'FAULT', 'EXPECTED (RFC 7606)', 'WHAT IT DID', 'ROUTE', 'VERDICT')
  results.each do |r|
    did = case r.outcome
          when :reset      then "reset#{r.code ? " #{r.code}/#{r.subcode}" : ' (no notification)'}"
          when :no_session then 'never reconnected'
          else                  'kept the session'
          end
    route = r.installed.nil? ? '-' : (r.installed ? 'installed' : 'dropped')
    puts format("%-#{width}s  %-22s  %-18s  %-10s  %s", r.name, r.expected, did, route, verdicts[r.verdict])
  end
  unless matrix.rib_usable
    puts "\nNo usable RIB answer: the router did not install a plain route either, so" \
         "\ntreat-as-withdraw and attribute-discard cannot be told apart here." \
         "\nThe session outcomes above still stand."
  end

  if opts[:json]
    File.write(opts[:json], JSON.pretty_generate(results.collect(&:to_h)))
    puts "\nwrote #{opts[:json]}"
  end

  exit(results.any? { |r| r.verdict == :differs } ? 1 : 0)
end
