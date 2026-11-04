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

      VERBS = <<~TEXT
        Sessions
          peers                         every configured peer and its state
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

      attr_reader :injector

      def initialize(injector, out = $stdout, keep = KEEP)
        @injector, @out, @keep = injector, out, keep
        @received = []
        @lock = Mutex.new
        @watch = false
        @tapped = {}
        # A Neighbor is a new object on every reconnect, so a tap goes
        # on each one as it comes up, and on those already up.
        speaker.on_established { |peer| tap(peer) }
        speaker.established_peers.each { |peer| tap(peer) }
      end

      # irb's prompt prints self, so this is what a person sees there.
      def to_s ; 'bgp4r' ; end
      def inspect ; "#<BGP::Sim::Console #{speaker.peers.size} peer(s)>" ; end

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

      # ---- sessions ------------------------------------------------------

      def speaker ; @injector.speaker ; end

      def peers
        speaker.peers.collect { |p| { :address => p.address, :as => p.remote_as, :state => p.state } }
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
        @injector.act(name.to_s, stringify(b), false)
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

      def sent ; @injector.sent.summary ; end
      def announced ; @injector.announced ; end

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

      def peer(address = nil)
        if address
          speaker.peer(address) or
            raise ArgumentError, "no peer #{address}; the peers are #{speaker.peers.collect(&:address).join(', ')}"
        else
          speaker.established_peers.first || speaker.peers.first or raise ArgumentError, 'no peer is configured'
        end
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
