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

module BGP
  module Daemon

    # BFD for the neighbors whose block says `bfd: true`: a session asked
    # of bfdd4r for each, and a BGP session reset when one fails.
    # routescope's docs/design/bfd-clients.md, step 6d, is the design;
    # docs/bfd.md is the guide.
    #
    # bfdd4r runs the BFD sessions, one per network namespace, and
    # `BFD::Client` from bfd4r (bfd/client.rb) is how a router talks to
    # it. This class is the BGP half and nothing else:
    #
    # * **Which sessions.** One per neighbor with `bfd: true`, wanted for
    #   as long as the neighbor is configured so, whatever BGP is doing:
    #   BFD comes up beside BGP and not after it, and BGP never waits for
    #   it. RFC 5882 section 4.1 says to block an adjacency only when both
    #   ends are known to be willing, and BGP has no signal that says so.
    # * **One hop only.** `ip -j route get ADDRESS` must answer with no
    #   `gateway`, and its `dev` and `prefsrc` are the session's interface
    #   and local address. Multihop BFD (RFC 5883) is not here.
    # * **What acts.** An Up session that went Down, `failure?`, on an
    #   Established peer: a Cease with subcode 10, "BFD Down" (RFC 9384
    #   section 3), then the session is cleared, and an active peer dials
    #   again after its `retry`. RFC 5882 section 10.2: "the EBGP session
    #   should be torn down". An AdminDown at either end never acts (RFC
    #   5882 section 4.2), and `BFD::Client` reports it as `:admin_down`
    #   so `failure?` is false. bfdd4r going away, `:lost`, keeps every
    #   session and logs once: the local system then simply does not run
    #   BFD, which section 4.1 allows.
    #
    # **The client is injected**, as `:client` on the Speaker, so the unit
    # tests drive this with a fake and only test/functional/bfd_test.rb
    # needs bfd4r on the load path. That is also why `bfd/client` is
    # required in `client` and not at the top: a speaker with no `bfd:
    # true` neighbor never loads it.
    class Bfd
      include BGP::Logging

      # The client name bfdd4r keeps on each session this asks for.
      CLIENT = 'bgp4rd'

      # How long the thread waits on bfdd4r's sockets before polling
      # anyway, which is what lets it notice a reconnect is due.
      WAIT = 0.2

      # The refusal, with the start the design gives it word for word.
      NOT_ONE_HOP = 'bfd needs a neighbor one hop away'

      Hop = Struct.new(:interface, :local)

      # speaker: the Speaker whose peers this serves.
      # arg[:client]: a BFD::Client, or something that answers like one;
      #   built on first use when absent.
      # arg[:runner]: ->(argv) answering a Fib::IpRoute::Result, for
      #   `ip -j route get`; IO.popen when absent.
      # arg[:logger]: the speaker's.
      def initialize(speaker, arg = {})
        @speaker = speaker
        @client = arg[:client]
        @runner = arg[:runner]
        @logger = arg[:logger]
        @lock = Mutex.new
        @hops = {}            # address => Hop, for each session asked for
        @thread = nil
        @stopping = false
      end

      # The interface and local address of the one hop to address, or an
      # ArgumentError naming the neighbor. Asks the kernel every time: a
      # commit is when the answer may have changed.
      def hop(address)
        require 'json'
        r = execute(['ip', '-j', 'route', 'get', address.to_s])
        route = r.ok? ? (JSON.parse(r.output).first rescue nil) : nil
        unless route.is_a?(Hash) && route['dev']
          raise ArgumentError, "neighbor #{address}: #{NOT_ONE_HOP}: ip route get answers " \
                               "#{r.ok? ? 'no route' : r.output.to_s.strip}"
        end
        if route['gateway']
          raise ArgumentError, "neighbor #{address}: #{NOT_ONE_HOP}: it is reached " \
                               "via #{route['gateway']} dev #{route['dev']}"
        end
        Hop.new(route['dev'], route['prefsrc'])
      end

      # Raises the first refusal among the peers that want BFD. What a
      # Speaker runs when it is built, so bgp4rd will not start on a
      # neighbor it cannot run BFD to.
      def check(peers)
        peers.select(&:bfd?).each { |p| hop(p.address) }
        self
      end

      # Asks for a session for each peer that wants one and lets go of
      # the others. What `start` does and what a commit of a neighbor's
      # `bfd` key does. Answers [added, dropped] addresses.
      def sync
        wanted = @speaker.peers.select(&:bfd?).to_h { |p| [p.address, p] }
        added, dropped = [], []
        hops = wanted.keys.reject { |a| @hops.key?(a) }.to_h { |a| [a, hop(a)] }
        @lock.synchronize do
          (@hops.keys - wanted.keys).each do |a|
            h = @hops.delete(a)
            client.drop(interface: h.interface, peer: a)
            dropped << a
          end
          hops.each do |a, h|
            client.want(interface: h.interface, peer: a, local: h.local)
            @hops[a] = h
            added << a
          end
        end
        added.each { |a| log(:info, "bfd: session to #{a} on #{@hops[a].interface} wanted") }
        dropped.each { |a| log(:info, "bfd: session to #{a} no longer wanted") }
        run unless @hops.empty?
        [added, dropped]
      end
      alias start sync

      # Stops the thread and lets go of every session, so bfdd4r takes
      # the ones no other client holds to AdminDown and the peer does not
      # act on it (RFC 5882 section 4.2).
      def stop
        @stopping = true
        @thread&.join(2)
        @lock.synchronize do
          @client&.close(release: true) unless @hops.empty?
          @hops.clear
        end
        self
      end

      # What show.peers says of a peer: nil when it does not run BFD,
      # else the session's state as bfdd4r last told it, `down`, `init`,
      # `up` or `admin_down`, or `unknown` before it has told one, which
      # is also what it says while bfdd4r is away.
      def state(address)
        @lock.synchronize do
          h = @hops[address.to_s] or return nil
          s = @client && @client.state(interface: h.interface, peer: address.to_s)
          s ? s.to_s : 'unknown'
        end
      end

      # One poll, and what it does with each event. The thread's body,
      # and what a test calls in place of the thread.
      def poll(now = Process.clock_gettime(Process::CLOCK_MONOTONIC))
        events = @lock.synchronize { client.poll(now) }
        events.each { |e| handle(e) }
        events
      end

      # One event from BFD::Client.
      def handle(e)
        case e.type
        when :state
          down(e) if e.failure?
          log(:info, "bfd: session to #{e.peer} on #{e.interface} #{e.from || 'new'} -> #{e.state}" \
                     "#{e.diag ? " (#{e.diag})" : ''}")
        when :lost
          log(:warn, "bfd: #{e.message}; BGP sessions are kept, and BFD is asked for again " \
                     'when bfdd4r is back')
        when :connected
          log(:info, "bfd: #{e.message}")
        when :error
          log(:warn, "bfd: #{e.peer}: #{e.message}")
        end
      end

      private

      # RFC 5882 section 4.2 and 10.2, RFC 9384 section 3: an Up session
      # went Down, and the peer is Established, so the BGP session goes
      # with it. A peer that is not Established has nothing to tear down.
      def down(e)
        peer = @speaker.peer(e.peer)
        return unless peer && @lock.synchronize { @hops.key?(peer.address) }
        unless peer.established?
          log(:info, "bfd: session to #{e.peer} went down; the BGP session is #{peer.state}, " \
                     'nothing to reset')
          return
        end
        sent = peer.cease(Peer::BFD_DOWN)
        # RFC 9384 section 4: the reason is part of the operational state
        # even when the NOTIFICATION could not be sent.
        peer.recorder.error!("BFD Down#{e.diag ? " (#{e.diag})" : ''}")
        peer.clear
        log(:warn, "bfd: session to #{e.peer} on #{e.interface} went down" \
                   "#{e.diag ? " (#{e.diag})" : ''}: BGP session reset" \
                   "#{sent ? ', Cease 6/10 BFD Down sent' : ''}")
      end

      def client
        @client ||= begin
          require 'bfd/client'
          BFD::Client.new(CLIENT)
        end
      end

      def run
        @stopping = false
        return if @thread&.alive?
        @thread = Thread.new do
          Thread.current['name'] = 'bgp4rd bfd'
          until @stopping
            begin
              ios = @lock.synchronize { client.ios }
              # ::IO, because IO inside module BGP is BGP::IO (CLAUDE.md).
              ios.empty? ? sleep(WAIT) : ::IO.select(ios, nil, nil, WAIT)
              poll
            rescue IOError, SystemCallError
              # A socket the client closed under the select: the next
              # poll reconnects.
            rescue StandardError => e
              log(:error, "bfd: #{e.class}: #{e.message}")
              sleep WAIT
            end
          end
        end
      end

      def execute(argv)
        return @runner.call(argv) if @runner
        output = ::IO.popen(argv, :err => [:child, :out]) { |io| io.read }
        BGP::Rib::Fib::IpRoute::Result.new(argv, $?.exitstatus, output.to_s)
      rescue SystemCallError => e
        BGP::Rib::Fib::IpRoute::Result.new(argv, -1, e.message)
      end
    end

  end
end
