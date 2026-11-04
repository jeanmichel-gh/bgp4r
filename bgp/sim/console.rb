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

require 'bgp/sim/injector'
require 'bgp/sim/guide'

module BGP
  module Sim

    # An irb prompt over a running injector, so a person can play with
    # live sessions in Ruby:
    #
    #   bgp4r routegen --peer 10.0.0.2 --peer-as 65002 --interact
    #
    #   bgp4r> announce '10.1.0.0/24', med: 10
    #   bgp4r> specimen :large_communities, '10.2.0.0/24'
    #   bgp4r> fault :origin_value, '10.3.0.0/24'
    #   bgp4r> n.send_message Update.new(...)
    #   bgp4r> received
    #
    # **irb opens with this object as self**, so a verb needs no
    # receiver. `n` is the Neighbor under it, so the whole library is
    # one word away; `BGP` is included into this class for the same
    # reason, so `Update`, `Nlri` and the rest need no prefix.
    #
    # **Every verb that sends goes through `Injector#act`**, synchronously,
    # which is the path `POST /api/...` and `bgp4r routegen` take. So
    # what a person types is what a scenario sends, with the same eBGP
    # rules and the same refusals, and there is no second way to build
    # an announcement here. `ship` is the one exception and is meant to
    # be: it hands any message or String to the session unchanged, which
    # is Conventions' first rule at the prompt.
    #
    # **It is the Console and not the Neighbor that irb opens on.** The
    # Neighbor changes object on every reconnect, and the verbs are
    # tedious to type as methods on it. This class names none of the
    # irb commands, which win over a method of the same name: `help`,
    # `ls`, `next`, `step`, `delete`, `info`, `source` and the rest.
    # That is why the list of verbs is `verbs`.
    class Console
      include BGP

      # How many received messages `received` keeps.
      KEEP = 200

      # The message printed when irb cannot be loaded. Ruby 4.0 made irb
      # a bundled gem, so under Bundler it loads only when the Gemfile
      # names it, which is the trap CLAUDE.md records for `base64`.
      IRB_MISSING = 'irb cannot be loaded. Ruby 4.0 made it a bundled gem, ' \
                    "so under Bundler add gem 'irb' to the Gemfile, or run " \
                    'without bundle exec.'

      # What a session opened at the prompt uses when a keyword is not
      # given. The same numbers `bgp4r routegen` uses, so the two agree.
      DEFAULT_AS = 65_001
      DEFAULT_ID = '10.0.0.1'

      # How long `connect` and `listen` wait for the session before they
      # answer. The session goes on trying after that either way.
      WAIT = 10

      # RFC 4486 section 4: the Cease subcodes a router sends for
      # `neighbor shutdown` and for `clear bgp`.
      CEASE = 6
      ADMIN_SHUTDOWN = 2
      ADMIN_RESET = 4

      NO_SESSION = 'no session. Open one with connect ADDR, remote_as: AS, ' \
                   'or listen ADDR, remote_as: AS, or start with --peer.'

      VERBS = <<~TEXT
        Sessions
          connect ADDR, remote_as: AS   open a session: we dial. Also local_as,
                                        router_id, port, local_address,
                                        hold_time, capabilities, wait
          listen ADDR, remote_as: AS    open a session: the peer dials in.
                                        port and local_address are ours
          shutdown [ADDR]               Cease 6/2, down, and stays down
          no_shutdown [ADDR]            let it come back up
          clear [ADDR]                  Cease 6/4, reset, and comes back
          peers                         every peer and its state
          state [ADDR]                  one peer's FSM state
          n, neighbor [ADDR]            the BGP::Neighbor, the whole API
        Sending, through the injector's actions
          announce PFX..., med: 10      also next_hop, as_path, local_pref,
                                        communities, origin, path_id, peer
          withdraw PFX...
          specimen NAME [, PFX...]      a valid UPDATE from BGP::Specimen
          fault NAME [, PFX...]         a malformed one from BGP::Fault
          replay HEX                    octets on the wire, unchanged
          notification CODE, SUBCODE
          refresh                       a ROUTE-REFRESH
          flap count: 1                 drop the session and let it return
          act 'name', {...}             any action by name, as the HTTP API
          ship MSG                      any message or String, unchanged
        Watching
          received [N]                  the last N messages in
          last                          the last message in, as an object
          watch / quiet                 print messages as they arrive, or not
          sent                          what the injector reports it sent
          announced                     what is announced on command
        Catalogs
          specimens, faults             the names each takes
        Help
          verbs                         this list
          guide [N or WORD]             docs/console.md, or one section of it
        exit stops the session and quits. ls lists every method here.
      TEXT

      # One message in, from one peer, at one time.
      Received = Struct.new(:at, :peer, :message) do
        def to_s
          format('%s %s %s', at.strftime('%H:%M:%S.%L'), peer, Console.describe(message))
        end
      end

      # The observer on one Neighbor. A separate object, so an Observable
      # sees `update` and nothing else of the console.
      class Tap
        def initialize(console, address)
          @console, @address = console, address
        end

        def update(msg)
          @console.received_from(@address, msg)
        end
      end

      # The injectors behind the prompt, one per session opened here and
      # the one handed to new, if any.
      attr_reader :sessions

      # injector is the session to start with, or nil for none.
      # arg[:factory] builds the Injector for `connect` and `listen` from
      # a node file Hash, which is the seam a test uses.
      def initialize(injector = nil, out = $stdout, keep = KEEP, arg = {})
        @out, @keep = out, keep
        @factory = arg[:factory] || ->(config) { Injector.new(config) }
        @received = []
        @lock = Mutex.new
        @watch = false
        @tapped = {}
        @sessions = []
        @owned = []
        attach(injector) if injector
      end

      # Puts an injector behind the prompt. A Neighbor is a new object on
      # every reconnect, so a tap goes on each one as it comes up, and on
      # those already up.
      def attach(injector)
        @lock.synchronize { @sessions << injector }
        injector.speaker.on_established { |peer| tap(peer) }
        injector.speaker.established_peers.each { |peer| tap(peer) }
        injector
      end

      # The injector a verb goes to. With an address, the one that has
      # that peer. Without, the only one there is, or the only one with a
      # session up.
      def injector(address = nil)
        list = @lock.synchronize { @sessions.dup }
        raise ArgumentError, NO_SESSION if list.empty?
        if address
          found = list.find { |i| i.speaker.peer(address) }
          return found if found
          raise ArgumentError, "no peer #{address}; the peers are #{addresses.join(', ')}"
        end
        return list.first if list.size == 1
        up = list.reject { |i| i.speaker.established_peers.empty? }
        return up.first if up.size == 1
        raise ArgumentError, "#{list.size} sessions; name one with peer: ADDR. " \
                             "The peers are #{addresses.join(', ')}"
      end

      # Stops the sessions this console opened. One handed to new is its
      # owner's to stop.
      def stop
        @lock.synchronize { @owned.dup }.each(&:stop)
        nil
      end

      # irb's prompt prints self, so this is what a person sees there.
      def to_s ; 'bgp4r' ; end
      def inspect ; "#<BGP::Sim::Console #{addresses.size} peer(s)>" ; end

      # Opens irb on this object and returns when the person exits.
      def interact
        Console.load_irb
        @out.puts "bgp4r console: self is the console, n is the Neighbor. " \
                  "'verbs' lists what to type, exit quits."
        instance_eval { binding }.irb(show_code: false)
        nil
      end

      # Requires irb, or raises LoadError with IRB_MISSING.
      def self.load_irb
        require 'irb'
      rescue LoadError
        raise LoadError, IRB_MISSING
      end

      def verbs
        @out.print VERBS
        nil
      end

      # docs/console.md, rendered: the whole guide, or the section whose
      # number or heading matches key. Through a pager on a terminal.
      # Named `guide` because `help` is an irb command and would win.
      def guide(key = nil)
        g = Guide.new(File.read(Guide::PATH, :encoding => 'UTF-8'), terminal?)
        text = key.nil? ? g.to_s : g.section(key)
        text ||= "No section #{key.inspect}. The sections are:\n#{g.contents}"
        page(text)
        nil
      rescue Errno::ENOENT
        @out.puts "#{Guide::PATH} is not there; the guide ships with a checkout or the gem."
        nil
      end

      # ---- sessions ------------------------------------------------------

      def speaker(address = nil) ; injector(address).speaker ; end

      def peers
        all_peers.collect { |p| { :address => p.address, :as => p.remote_as, :state => p.state } }
      end

      # Opens a session that we dial, the way a router's `neighbor ADDR
      # remote-as AS` does. Answers the peer's row once it is up, or once
      # `wait` seconds pass; the session goes on trying either way.
      #
      # remote_as and local_as are prompt names. They become the node
      # file's two `as` keys, so the node file does not change.
      def connect(address, remote_as:, local_as: DEFAULT_AS, router_id: DEFAULT_ID,
                  port: nil, local_address: nil, hold_time: nil, capabilities: nil,
                  wait: WAIT)
        neighbor = neighbor_config(address, remote_as, true, port, hold_time, capabilities)
        config = { 'router_id' => router_id, 'as' => Integer(local_as), 'neighbors' => [neighbor] }
        config['local_address'] = local_address if local_address
        open_session(address, config, wait)
      end

      # Opens a session the peer dials, on our `port` and `local_address`,
      # 179 and every address by default. One listen per port: a second
      # one on a port already taken is refused.
      def listen(address, remote_as:, local_as: DEFAULT_AS, router_id: DEFAULT_ID,
                 port: 179, local_address: nil, hold_time: nil, capabilities: nil,
                 wait: WAIT)
        neighbor = neighbor_config(address, remote_as, false, nil, hold_time, capabilities)
        config = { 'router_id' => router_id, 'as' => Integer(local_as), 'neighbors' => [neighbor],
                   'port' => Integer(port) }
        config['listen_address'] = local_address if local_address
        open_session(address, config, wait)
      end

      # `neighbor ADDR shutdown`: Cease, Administrative Shutdown, then
      # down, and it stays down until `no_shutdown`.
      def shutdown(address = nil)
        p = peer(address)
        cease(p, ADMIN_SHUTDOWN)
        act('session.stop', 'peer' => p.address)
        row(p)
      end

      # `no neighbor ADDR shutdown`: let it come back. We dial at once if
      # we are the active side; a passive one waits for the peer.
      def no_shutdown(address = nil)
        p = peer(address)
        act('session.start', 'peer' => p.address)
        row(p)
      end

      # `clear bgp ADDR`: Cease, Administrative Reset, then the session
      # ends and comes back by itself.
      def clear(address = nil)
        p = peer(address)
        cease(p, ADMIN_RESET)
        p.clear
        row(p)
      end

      def state(address = nil) ; peer(address).state ; end

      def neighbor(address = nil)
        p = peer(address)
        p.neighbor or raise ArgumentError, "#{p.address} has no session yet (state #{p.state})"
      end
      alias n neighbor

      # ---- sending -------------------------------------------------------

      def announce(*prefixes, **attrs)
        act('announce', body(prefixes, attrs))
      end

      def withdraw(*prefixes, **opts)
        act('withdraw', body(prefixes, opts))
      end

      def specimen(name, *prefixes, **opts)
        act('announce', body(prefixes, opts).merge('specimen' => name.to_s))
      end

      def fault(name, *prefixes, **opts)
        act('fault', body(prefixes, opts).merge('case' => name.to_s))
      end

      def replay(hex, **opts)
        act('replay', body([], opts).merge('hex' => hex))
      end

      def notification(code, subcode = 0, **opts)
        act('notification', body([], opts).merge('code' => code, 'subcode' => subcode))
      end

      def refresh(**opts) ; act('refresh', body([], opts)) ; end
      def flap(**opts) ; act('session.flap', body([], opts)) ; end

      # Any action by name, with the body the HTTP API takes. Synchronous,
      # so a generated feed has finished when this answers.
      def act(name, b = {})
        b = stringify(b)
        injector(b['peer']).act(name.to_s, b, false)
      end

      # Any message object, or a String of octets, onto the session as it
      # is. Nothing looks at it.
      def ship(msg, peer: nil)
        peer(peer).send_message(msg)
        msg
      end

      # ---- watching ------------------------------------------------------

      def received(count = 10)
        @lock.synchronize { @received.last(count) }.each { |r| @out.puts r }
        nil
      end

      def last
        r = @lock.synchronize { @received.last }
        r && r.message
      end

      def watch ; @watch = true ; end
      def quiet ; @watch = false ; true ; end
      def watching? ; @watch ; end

      def sent(peer: nil) ; injector(peer).sent.summary ; end
      def announced(peer: nil) ; injector(peer).announced ; end

      def specimens ; BGP::Specimen.names ; end
      def faults ; BGP::Fault.names ; end

      # Called by a Tap, on the session's reader thread.
      def received_from(address, msg)
        r = Received.new(Time.now, address, msg)
        @lock.synchronize do
          @received << r
          @received.shift while @received.size > @keep
        end
        @out.puts r if @watch
      end

      # One line about a message, for `received` and `watch`.
      def self.describe(msg)
        case msg
        when BGP::Update
          format('Update, %d prefixes, %d withdrawn',
                 Injector.prefix_count(msg), Injector.withdrawn_count(msg))
        when BGP::Message then msg.class.name.split('::').last
        when Exception then "malformed: #{msg.message}"
        else msg.to_s
        end
      end

      private

      # True when the output is a person's terminal, which is when the
      # guide gets colour and a pager.
      def terminal?
        @out.respond_to?(:tty?) && @out.tty?
      end

      # Text through $PAGER, or less, on a terminal; printed otherwise, or
      # when no pager runs. `::IO`, since `IO` here is BGP::IO. LESS gets
      # F, R and X so a short section prints and returns, colour shows,
      # and the screen is not cleared.
      def page(text)
        return @out.print(text) unless terminal?
        env = { 'LESS' => ENV.fetch('LESS', 'FRX') }
        ::IO.popen(env, ENV.fetch('PAGER', 'less'), 'w') { |io| io.print(text) }
      rescue Errno::EPIPE
        nil # the person quit the pager before the end
      rescue Errno::ENOENT
        @out.print(text)
      end

      def peer(address = nil)
        s = injector(address).speaker
        return s.peer(address) if address
        s.established_peers.first || s.peers.first or raise ArgumentError, 'no peer is configured'
      end

      def all_peers
        @lock.synchronize { @sessions.dup }.flat_map { |i| i.speaker.peers }
      end

      def addresses ; all_peers.collect(&:address) ; end

      def row(p) ; { :address => p.address, :as => p.remote_as, :state => p.state } ; end

      def neighbor_config(address, remote_as, active, port, hold_time, capabilities)
        n = { 'address' => address.to_s, 'as' => Integer(remote_as), 'connect' => active }
        n['port'] = Integer(port) if port
        n['hold_time'] = Integer(hold_time) if hold_time
        n['capabilities'] = Array(capabilities).collect { |c| c.is_a?(Symbol) ? c.to_s : c } if capabilities
        n
      end

      # Builds and starts one injector for one peer. A Speaker reads its
      # peer list once, so a session opened here is an injector of its
      # own rather than a peer added to a running one.
      def open_session(address, config, wait)
        if addresses.include?(address.to_s)
          raise ArgumentError, "#{address} already has a session; clear or shutdown it"
        end
        i = @factory.call(config)
        begin
          i.start
        rescue Errno::EADDRINUSE
          raise ArgumentError, "port #{config['port']} is taken, by another listen here " \
                               'or another program. Pass port: N'
        rescue Errno::EACCES
          raise ArgumentError, "port #{config['port']} needs root. Pass port: N above 1023"
        end
        @lock.synchronize { @owned << i }
        attach(i)
        p = i.speaker.peer(address)
        deadline = Time.now + Float(wait)
        sleep 0.05 until p.established? || Time.now > deadline
        row(p)
      end

      # A Cease with that subcode, when there is a session to send it on.
      # Neighbor#stop drains what is queued, so it reaches the wire.
      def cease(p, subcode)
        return unless p.established?
        act('notification', 'peer' => p.address, 'code' => CEASE, 'subcode' => subcode)
      end

      def tap(peer)
        n = peer.neighbor
        return if n.nil?
        @lock.synchronize do
          return if @tapped.key?(n.object_id)
          @tapped[n.object_id] = true
        end
        n.add_observer(Tap.new(self, peer.address))
      end

      def body(prefixes, opts)
        b = {}
        prefixes = prefixes.flatten.collect(&:to_s)
        b['prefixes'] = prefixes unless prefixes.empty?
        b.merge(stringify(opts))
      end

      def stringify(h)
        h.each_with_object({}) { |(k, v), o| o[k.to_s] = v }
      end

    end

  end
end
