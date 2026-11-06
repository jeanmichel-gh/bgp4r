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

require 'bgp/daemon/speaker'
require 'bgp/logging'
require 'bgp/misc/route_generator'
require 'bgp/gen'
require 'bgp/daemon/views'
require 'bgp/events'
require 'bgp/sim/sent'
require 'bgp/prompt'

module BGP
  module Sim

    # `bgp4r-sim`'s ten actions, over the sessions a
    # `BGP::Daemon::Speaker` holds.
    #
    # docs/daemon.md is the design, from its `bgp4r-sim, the injector`
    # heading on. `docs/routescope-labs.md` section 9 is what a scenario
    # asks of it.
    #
    # **Two rules are the product and everything here follows from
    # them.**
    #
    # * **It starts silent.** Nothing is announced until an action asks,
    #   because a baseline the configuration created is a baseline no
    #   assertion can rest on: a scenario asserts the peer holds
    #   nothing, announces, and asserts again. That falls out of the
    #   Speaker rather than being enforced here, since
    #   `Speaker#announcements` is `Array(config['announce'])` and an
    #   injector's node file has no `announce` block. The one waiver is
    #   a node file that does carry one, for a lab that wants a feed at
    #   start-up, and `lab/README.md` and docs/daemon.md both say so.
    # * **It validates nothing.** Any attribute, any length, any order,
    #   any repetition, a Path Identifier on a session that negotiated
    #   none, a NOTIFICATION with a code RFC 4271 does not define, a
    #   captured UPDATE replayed byte for byte. Conventions' first rule
    #   is what makes this program possible and nothing here may grow a
    #   check. `test_nothing_validates` in the test file pins specific
    #   things no RFC allows.
    #
    # **What it refuses is a request it cannot carry out, never a
    # request it disapproves of.** An unknown body key, a fault name the
    # catalog does not have, a prefix that was never announced, an
    # address that is not a configured peer, a hex string that is not
    # octets, no session to send on. Each is a 4xx with a reason, which
    # is the difference between a scenario that fails and a scenario
    # that passes having done nothing.
    #
    # **It holds no Loc-RIB**, which is the first row of docs/daemon.md's
    # two-programs table: `bgp/rib/` is not wired in and the four node
    # file keys that would build a table are refused, naming `bgp4rd`.
    # What it knows about what it sent is `bgp/sim/sent.rb`.
    class Injector

      # #log and #logger; see bgp/logging.rb.
      include BGP::Logging

      # Something the caller can fix: a bad body, an unknown name, a
      # prefix with no history. `BGP::Daemon::NoSession` is the other
      # one, and the HTTP layer tells them apart by status code.
      class Refused < StandardError ; end

      # `action => the body keys it reads`, which is the table
      # `Drivers::Sim::ACTIONS` already is, read at routescope `7eabde1`:
      # there an entry is `[path, body keys]` and the paths live in
      # `bgp/sim/http.rb`, so this half is the keys.
      #
      # **The keys are the node file's own keys** and that is a recorded
      # decision: `prefixes`, `generate`, `med`, `as_path`, `as_path_literal`,
      # `communities`, `next_hop`, `local_pref`, `path_id` and `origin`
      # are what `lab/README.md` documents for an announce block, so the
      # injector's runtime vocabulary is bgp4r's configuration
      # vocabulary and `lab/README.md` is already its reference.
      #
      # **A key no action reads is refused rather than ignored**, which
      # is what `Speaker#export_options` does for a node file and for
      # the same reason: a typo that silently changes nothing is worse
      # than both an error and a wrong value, because nothing anywhere
      # says so. It also makes this table load bearing rather than
      # documentation.
      ACTIONS = {
        'announce'      => %w[peer prefixes generate spec churn mp_reach specimen next_hop as_path
                              as_path_literal med local_pref communities extended_communities
                              large_communities path_id origin],
        'withdraw'      => %w[peer prefixes generate spec mp_unreach path_id],
        'attribute'     => %w[peer prefixes next_hop as_path as_path_literal med
                              local_pref communities extended_communities large_communities path_id origin],
        'fault'         => %w[peer case prefixes next_hop],
        'replay'        => %w[peer hex],
        'notification'  => %w[peer code subcode data],
        'session.stop'  => %w[peer],
        'session.start' => %w[peer],
        'session.flap'  => %w[peer count interval],
        'refresh'       => %w[peer afi safi subtype]
      }.freeze

      # The keys that go with each of the four selectors that are not an
      # announce block, beside the selector itself and `peer`. Any other
      # key in the body is refused, for the reason ACTIONS gives: `med`
      # beside a `spec` would otherwise change nothing in silence, since
      # a spec carries its own attributes.
      #
      # * **`spec`** is a `BGP::Gen` spec, docs/route-generation.md
      #   section 4, handed to the library unchanged. `as_path_literal`
      #   is the one announce key it reads, because the eBGP prepend is
      #   the session's rule and not the spec's. **`churn` beside it sends
      #   that spec's churn rather than the spec**, section 8 of the same
      #   document: changes to routes the spec already announced. It is
      #   on `announce` rather than an eleventh action because the ten
      #   are routescope's `Drivers::Sim::ACTIONS`, and a churn is
      #   announcements and withdrawals of one spec's routes.
      # * **`mp_reach` and `mp_unreach`** take the Hash `Mp_reach.new`
      #   and `Mp_unreach.new` read, so one message in any family the
      #   library builds, with no generator.
      # * **`specimen`** is a `BGP::Specimen` name, sent in the envelope
      #   `Fault.update` uses. `prefixes` is its NLRI and `next_hop` goes
      #   with them; a family specimen carries its own NLRI and takes
      #   neither.
      SELECTORS = {
        'announce' => { 'spec' => %w[as_path_literal churn], 'mp_reach' => [],
                        'specimen' => %w[prefixes next_hop] },
        'withdraw' => { 'spec' => [], 'mp_unreach' => [] }
      }.freeze

      # What `plan` reads: the spec and what decides how it is sent, and
      # one page of the answer. See `plan`.
      PLAN_KEYS = %w[peer spec churn as_path_literal offset limit].freeze

      # What an event line says happened. `attribute` re-announces, so
      # its line says so rather than inventing a verb for it.
      PAST = { 'announce' => 'announced', 'attribute' => 're-announced',
               'withdraw' => 'withdrew' }.freeze

      # The node file keys an injector reads. The session half is the
      # Speaker's, so this is that list plus `api`.
      CONFIG_KEYS = %w[router_id as api log_level local_address listen_address
                       port state_file neighbors announce specs].freeze

      # The four keys that would build a Loc-RIB, which an injector does
      # not have. Refused by name, pointing at the program that does:
      # a node file quietly deciding routes inside an injector would
      # make it a worse `bgp4rd` and void every assertion a scenario
      # makes about what it sent.
      ROUTER_KEYS = %w[rib originate export fib].freeze

      # Two event kinds of its own, declared rather than added to the
      # list in `bgp/events.rb`: that file's own comment says
      # `register_kind` is the growth path and that a kind for work that
      # does not exist is anticipation. `:session` and `:notification`
      # are already published by `Neighbor`, so these two are what is
      # left of docs/routescope-labs.md section 9.2's list: an UPDATE
      # sent with its prefix count, a withdrawal, and a fault case
      # injected with its catalog name.
      ROUTE = BGP::Events.register_kind(:route)
      FAULT = BGP::Events.register_kind(:fault)

      attr_reader :speaker, :sent

      # arg[:logger] is the ->(level, message) this injector and the
      # Speaker it builds log through. Its two lines are about a resend
      # and about publishing an event, both from a session thread, so
      # they belong with the speaker's rather than with the process's.
      def initialize(config, arg = {})
        Injector.check_config(config)
        @logger = arg[:logger]
        @speaker = Daemon::Speaker.new(config, :logger => @logger)
        @specs = config['specs'] || {}
        @sent = Sent.new
        @announced = {}
        @lock = Mutex.new
        @threads = []
        # What was announced on command goes again when a session comes
        # back. See resend.
        @speaker.on_established { |peer| resend(peer) }
      end

      # Refuses a node file this program cannot carry out. The Speaker
      # refuses the rest when it reads the file.
      def self.check_config(config)
        raise Refused, 'the configuration is not a YAML mapping' unless config.is_a?(Hash)
        router = config.keys & ROUTER_KEYS
        unless router.empty?
          raise Refused,
                "#{router.join(', ')}: an injector holds no Loc-RIB, so it has no " \
                "table to decide with. Those keys are bgp4rd's; see docs/daemon.md."
        end
        clients = Array(config['neighbors']).select { |n| n.is_a?(Hash) && n.key?('route_reflector_client') }
        unless clients.empty?
          raise Refused,
                "neighbor #{clients.map { |n| n['address'] }.join(', ')}: route_reflector_client: " \
                "an injector reflects nothing, since it holds no Loc-RIB. That key is bgp4rd's."
        end
        unknown = config.keys - CONFIG_KEYS
        unless unknown.empty?
          raise Refused,
                "unknown configuration key(s) #{unknown.join(', ')}: " \
                "an injector reads #{CONFIG_KEYS.join(', ')}"
        end
        check_specs(config['specs'])
        config
      end

      # `specs` names traffic the lab defines, so a scenario sends
      # `spec: NAME` rather than carrying the whole spec. **Naming a spec
      # sends nothing**: the injector still starts silent, and only an
      # `announce` starts a feed. Each spec is read by `BGP::Gen` here,
      # at start-up, so a spec it cannot read stops the node rather than
      # failing the first scenario that names it.
      SPEC_NAME = /\A[A-Za-z0-9_.-]{1,64}\z/

      def self.check_specs(specs)
        return if specs.nil?
        raise Refused, 'specs: a mapping of name to spec' unless specs.is_a?(Hash)
        specs.each do |name, spec|
          unless name.is_a?(String) && name.match?(SPEC_NAME)
            raise Refused, "specs: #{name.inspect} is not a name: letters, digits, _ . and -"
          end
          raise Refused, "specs: #{name} is not a mapping" unless spec.is_a?(Hash)
          begin
            BGP::Gen.new(spec)
          rescue BGP::Gen::SpecError => e
            raise Refused, "specs: #{name}: #{e.message}"
          end
        end
      end

      def start
        @speaker.start
        self
      end

      def stop
        @lock.synchronize { @threads.dup }.each { |t| t.kill if t.alive? }
        @speaker.stop
        self
      end

      # Waits until every session's writer has taken what it was given,
      # or until `timeout` seconds pass. Answers true when it drained.
      #
      # **A program that sends and then stops needs this and loses
      # messages without it.** `send_message` queues and
      # `BGP::IO::Output#exit` closes the queue rather than draining it,
      # so `bgp4r routegen` lost the last UPDATE of every range it sent
      # until this was here: 15 prefixes of 20 arrived and the report
      # said 20, which is the worst kind of wrong answer. Found by
      # writing the functional test, not by reading.
      #
      # `Neighbor#pending` reaching 0 means the last message was handed
      # to `IO#write` rather than acknowledged by the peer, so the
      # settle below covers the one gap left: the moment between the
      # writer thread dequeuing a message and that call returning. After
      # it the octets are in the socket buffer, which an ordinary close
      # still delivers.
      DRAIN_SETTLE = 0.1

      def drain(timeout = 10)
        deadline = Time.now + timeout
        until @speaker.peers.all? { |p| p.pending.zero? }
          return false if Time.now > deadline
          sleep 0.02
        end
        sleep DRAIN_SETTLE
        true
      end

      # One action by name. Every public action goes through here, so
      # the body check and the refusal wording are in one place.
      #
      # **`async` is how `bgp4r routegen` differs from an HTTP POST and
      # it is not a body key.** A generated feed runs on a thread of its
      # own so the request that asked for it answers at once, which is
      # what lets a console show a feed rather than a spinner; a command
      # line wants to block and then say what it sent. Both run the same
      # action, so there is one implementation of the feed.
      #
      # **It is positional and not a keyword, which is not a style
      # choice.** A method that declares any keyword parameter makes
      # Ruby read a trailing `'k' => v` list as keywords, so
      # `act('announce', 'prefixes' => [...])` raised `unknown keywords:
      # "prefixes"`. Every body here comes from JSON, so every caller
      # writes exactly that, and a keyword would mean every call site
      # bracing its own hash forever. Same family as the
      # `Attr::OVERRIDE_KEYS` trap Conventions records: an option name
      # in the same position as data.
      def act(name, body = {}, async = true)
        body = {} if body.nil?
        raise Refused, "a request body is a JSON object, got #{body.class}" unless body.is_a?(Hash)
        case name.to_s
        when 'announce'      then announce(body, 'announce', async)
        when 'withdraw'      then withdraw(body, async)
        when 'attribute'     then attribute(body)
        when 'fault'         then fault(body)
        when 'replay'        then replay(body)
        when 'notification'  then notification(body)
        when 'session.stop'  then session_stop(body)
        when 'session.start' then session_start(body)
        when 'session.flap'  then session_flap(body)
        when 'refresh'       then refresh(body)
        else
          raise Refused, "unknown action #{name.to_s.inspect}; this injector does " \
                         "#{ACTIONS.keys.join(', ')}"
        end
      end

      # What it is configured to be able to send, which is
      # `GET /api/topology`: the session half, the actions and their
      # keys, and the fault catalog. A scenario reads it to find out
      # what this node can be told to do without asking a person.
      def topology
        { :router_id => @speaker.router_id,
          :as        => @speaker.my_as,
          :neighbors => @speaker.peers.collect { |p|
            { :address      => p.address,
              :remote_as    => p.remote_as,
              :type         => p.ebgp? ? :ebgp : :ibgp,
              :connect      => p.active?,
              :description  => p.description,
              :shutdown     => p.shutdown?,
              :capabilities => Array(p.config.fetch('capabilities', ['as4_byte'])) }
          },
          :announce_at_start => @speaker.announcements.size,
          :actions           => ACTIONS,
          :plan              => PLAN_KEYS,
          :specs             => @specs.keys,
          :generators        => BGP::Gen::GENERATORS.keys,
          :faults            => BGP::Fault.names.collect { |n| n.to_s },
          :specimens         => BGP::Specimen.names.collect { |n| n.to_s } }
      end

      # One row per prefix announced on command, in the shape
      # routescope's `bgp_routes` table wants:
      # `prefix next_hop as_path origin med local_pref from paths best`.
      #
      # **`best` is nil and not false**, which docs/routescope-labs.md
      # section 9.2 asks for: an injector runs no decision process, so
      # false would claim a comparison it never made.
      #
      # **A generated range is not here**, because listing a million
      # prefixes to say what was sent is exactly what the streaming
      # generator exists to avoid. `/api/sent`'s feeds carry the range
      # and the counts instead.
      def announced
        @lock.synchronize { @announced.dup }.collect { |prefix, body|
          { :prefix     => prefix,
            :next_hop   => body['next_hop'],
            :as_path    => Array(body['as_path']).join(' '),
            :origin     => Daemon::Speaker::ORIGINS[body.fetch('origin', 0)],
            :med        => body['med'],
            :local_pref => body['local_pref'],
            :from       => @speaker.router_id,
            :peer       => body['peer'],
            :paths      => 1,
            :best       => nil }
        }.sort_by { |r| r[:prefix].to_s }
      end

      # What a spec would send to each target, as `BGP::Gen#expected`
      # rows, and nothing sent. This is `POST /api/plan`, and it is how a
      # program that does not load bgp4r, routescope above all, gets the
      # routes to assert a router's RIB against.
      #
      # **It answers per peer because the answer differs per peer**: the
      # same spec gets our AS in front of its AS_PATH and no LOCAL_PREF
      # toward an external peer, and the session's own address as next
      # hop when it gives none. Those are the rules of
      # bgp/gen/sender.rb, and they are applied to the same row both
      # `updates` and `expected` read, so the plan and the send cannot
      # disagree. The targets are `announce`'s: the named peer, or every
      # session that is up.
      #
      # **It is paged**, with `Daemon::Views`' envelope and limits,
      # because a spec of a million routes is a million rows: `offset`
      # and `limit`, then `rows`, `total`, `offset`, `limit` and
      # `next_offset`, which is nil on the last page.
      def plan(body)
        body = {} if body.nil?
        raise Refused, "a request body is a JSON object, got #{body.class}" unless body.is_a?(Hash)
        block = body.to_h { |k, v| [k.to_s, v] }
        unknown = block.keys - PLAN_KEYS
        unless unknown.empty?
          raise Refused, "plan: unknown key(s) #{unknown.join(', ')}; it reads #{PLAN_KEYS.join(', ')}"
        end
        raise Refused, 'plan: spec is required' if block['spec'].nil?
        named_spec(block)
        check(block.reject { |k, _| %w[offset limit churn].include?(k) }, 'announce')
        offset = integer(block, 'offset', 0)
        offset = 0 if offset.negative?
        limit = integer(block, 'limit', Daemon::Views::PAGE_LIMIT).clamp(1, Daemon::Views::MAX_LIMIT)
        plans = targets(block).collect { |peer|
          gen = generator(block, peer)
          if block['churn']
            c = churner(gen, block)
            summary = c.summary
            total, source = summary['held'], c.expected
          else
            total, source = gen.total, gen.expected
          end
          rows = source.lazy.drop(offset).first(limit)
          nxt = offset + limit
          page = { :peer => peer.address, :rows => rows, :total => total, :offset => offset,
                :limit => limit, :next_offset => nxt < total ? nxt : nil }
          page[:churn] = summary if summary
          page
        }
        { :action => 'plan', :plans => plans }
      end

      private

      # ---- the actions -------------------------------------------------

      # `prefixes` or `generate`, with any path attributes, to one peer
      # or to every session.
      #
      # A `prefixes` block is one UPDATE and is sent before this answers.
      # A `generate` block is a feed: it answers at once with the feed's
      # record and streams on a thread of its own, so a console shows a
      # feed rather than a spinner and a 200000 prefix range does not sit
      # inside an HTTP request. A false `async` runs it inline, which
      # is what `bgp4r routegen` wants.
      def announce(body, action = 'announce', async = true)
        block = check(body, action)
        if action == 'announce'
          return specimen(block) if block['specimen']
          one_of(block, 'prefixes', 'generate', 'spec', 'mp_reach', 'specimen')
          if block['spec'] && block['churn']
            return churn(selector(block, 'announce', 'spec'), async)
          end
          raise Refused, 'announce: churn goes with a spec' if block['churn']
          return spec_feed(block, targets(selector(block, 'announce')), 'announce', async) if block['spec']
          return mp_reach(selector(block, 'announce', 'mp_reach')) if block['mp_reach']
        end
        peers = targets(block)
        return feed(block, peers, action, async) if block['generate']
        prefixes = Array(block['prefixes'])
        raise Refused, "#{action}: prefixes is empty" if prefixes.empty?
        result = send_to(peers, action) { |peer| send_block(peer, block, action) }
        remember(prefixes, block)
        publish(ROUTE, "#{PAST[action]} #{prefixes.size} prefix(es) to " \
                       "#{peers.collect(&:address).join(', ')}",
                :prefixes => prefixes, :action => action)
        result.merge(:prefixes => prefixes)
      end

      # The same selectors, as withdrawals. A `generate` range is
      # regenerated rather than read back from a list, which is the
      # requirement that goes with a streaming feed.
      def withdraw(body, async = true)
        block = check(body, 'withdraw')
        one_of(block, 'prefixes', 'generate', 'spec', 'mp_unreach')
        return spec_feed(block, targets(selector(block, 'withdraw')), 'withdraw', async) if block['spec']
        return mp_unreach(selector(block, 'withdraw', 'mp_unreach')) if block['mp_unreach']
        peers = targets(block)
        if block['generate']
          r = feed(block, peers, 'withdraw', async)
          forget_range(block)
          return r
        end
        prefixes = Array(block['prefixes'])
        raise Refused, 'withdraw: prefixes is empty' if prefixes.empty?
        msg = BGP::Update.new(withdrawn_for(prefixes, block['path_id']))
        result = send_to(peers, 'withdraw') { |peer| send_one(peer, msg, 'withdraw', prefixes.size) }
        forget(prefixes)
        publish(ROUTE, "#{PAST['withdraw']} #{prefixes.size} prefix(es) from " \
                       "#{peers.collect(&:address).join(', ')}",
                :prefixes => prefixes, :action => 'withdraw')
        result.merge(:prefixes => prefixes)
      end

      # Changes an attribute of something already announced, so a
      # scenario can move one input and watch a router re-decide.
      #
      # **It re-announces, because that is what the protocol says this
      # is.** RFC 4271 section 3.1, read on 2026-11-02 rather than
      # recalled: "Changing the attribute(s) of a route is accomplished
      # by advertising a replacement route", and "The replacement route
      # carries new (changed) attributes and has the same address prefix
      # as the original route." So there is no separate operation to
      # perform and this action is named after the section's own
      # sentence. What makes it an action rather than an announce is the
      # lookup: the prefix keeps the attributes it was announced with
      # and only the named keys change.
      #
      # A prefix with no history is refused rather than announced from
      # nothing, since a scenario asking to change an attribute of a
      # prefix it never announced has a bug in it and a 200 would hide it.
      def attribute(body)
        block = check(body, 'attribute')
        prefixes = Array(block['prefixes'])
        raise Refused, 'attribute: prefixes is required' if prefixes.empty?
        changes = block.reject { |k, _v| k == 'prefixes' }
        raise Refused, 'attribute: nothing to change' if changes.empty?
        known = @lock.synchronize { @announced.dup }
        missing = prefixes.reject { |p| known.key?(p) }
        unless missing.empty?
          raise Refused,
                "attribute: #{missing.join(', ')} was not announced from here, so " \
                'there is nothing to change. Announce it first.'
        end
        # Grouped by the body each prefix was announced with, so prefixes
        # that came from one announcement stay in one UPDATE and ones
        # that did not are not silently merged into attributes they never
        # had.
        results = prefixes.group_by { |p| known[p] }.collect { |was, pfxs|
          announce(was.merge(changes).merge('prefixes' => pfxs), 'attribute')
        }
        { :action   => 'attribute',
          :prefixes => prefixes,
          :updates  => results.sum { |r| r[:updates] },
          :peers    => results.flat_map { |r| r[:peers] }.uniq }
      end

      # One `BGP::Fault::CATALOG` case on a session that is already up.
      #
      # **That is the difference from `lab/fault_matrix.rb` and it is
      # worth knowing before reading either.** The matrix gives every
      # case a session of its own, because a case the router answers
      # with a reset leaves nothing to reuse, and waiting for the next
      # session is the whole of its per case cost. An injector is a
      # long-lived process and injects onto the session it has: so a
      # case that resets takes that session down, the active side
      # reconnects on its own `retry` timer, and what was announced goes
      # again when it comes back. Nothing here waits for any of that,
      # which is why a scenario asserting a session survived has to read
      # the session state afterwards, as docs/routescope-labs.md section
      # 9.4's scenario C does.
      #
      # The UPDATE is `Fault.update`'s, which the matrix uses too, so one
      # catalog name is one set of octets for both programs.
      def fault(body)
        block = check(body, 'fault')
        name = block['case'].to_s
        raise Refused, 'fault: case is required' if name.empty?
        unless BGP::Fault.names.include?(name.to_sym)
          raise Refused, "fault: unknown case #{name.inspect}; the catalog has " \
                         "#{BGP::Fault.names.join(', ')}"
        end
        prefixes = Array(block['prefixes'])
        result = send_to(targets(block), 'fault') { |peer|
          # Our AS toward an external peer and an empty AS_PATH toward an
          # internal one, which is what this injector's own announce
          # does through Speaker#path_attribute: a fault case that
          # differed there would be testing AS_PATH rather than the case.
          msg = BGP::Fault.update(name.to_sym,
                                  :my_as    => (peer.ebgp? ? @speaker.my_as : nil),
                                  :next_hop => block.fetch('next_hop', peer.local_ip),
                                  :prefixes => prefixes)
          send_one(peer, msg, 'fault', prefixes.size)
        }
        publish(FAULT, "injected fault #{name}", :case => name, :prefixes => prefixes)
        result.merge(:case => name, :prefixes => prefixes)
      end

      # Octets on the wire, unchanged, which is what the
      # keep-what-you-cannot-read work exists to make possible: a capture
      # of an UPDATE no bgp4r release can build goes back out exactly as
      # it arrived.
      #
      # **Nothing is parsed and nothing is checked**, not the Marker, not
      # the Length, not the Type. `Neighbor#send_message` queues a String
      # and `BGP::IO::Output` writes it, so there is no new path here;
      # measured on 2026-11-02 rather than assumed. The one thing refused
      # is a string that is not octets, because an odd number of hex
      # digits cannot be made into bytes at all, which is the one kind of
      # refusal Conventions allows.
      def replay(body)
        block = check(body, 'replay')
        octets = hex_octets(block['hex'], 'replay: hex')
        raise Refused, 'replay: hex is empty' if octets.empty?
        result = send_to(targets(block), 'replay') { |peer| send_one(peer, octets, 'replay', 0) }
        publish(FAULT, "replayed #{octets.bytesize} octet(s)",
                :action => 'replay', :octets => octets.bytesize)
        result.merge(:octets => octets.bytesize)
      end

      # A NOTIFICATION with any code and subcode, including ones RFC 4271
      # section 4.5 does not define, and any data octets.
      def notification(body)
        block = check(body, 'notification')
        raise Refused, 'notification: code is required' if block['code'].nil?
        code = octet(block, 'code')
        subcode = block['subcode'].nil? ? 0 : octet(block, 'subcode')
        data = block['data'].nil? ? '' : hex_octets(block['data'], 'notification: data')
        msg = BGP::Notification.new(code, subcode, data)
        # Neighbor#send_message publishes the :notification event itself,
        # for a NOTIFICATION sent as well as one received, so there is
        # none here: two events for one message would double every count
        # a console keeps.
        result = send_to(targets(block), 'notification') { |peer|
          send_one(peer, msg, 'notification', 0)
        }
        result.merge(:code => code, :subcode => subcode, :data => data.unpack1('H*') || '')
      end

      def session_stop(body)
        peers = selected(check(body, 'session.stop'))
        peers.each(&:admin_stop)
        publish(:log, "session.stop #{peers.collect(&:address).join(', ')}",
                :action => 'session.stop')
        { :action => 'session.stop', :peers => peers.collect(&:address) }
      end

      # Lets a session come back.
      #
      # **For an active peer that is a dial and for a passive one it is a
      # permission**, and the difference is not ours to remove: nothing
      # here can make the other side connect. `Peer#admin_start`
      # broadcasts on the condition variable the active loop waits on, so
      # that peer dials as soon as it is let back up and the only wait is
      # its connect time; a passive peer's session returns when the peer
      # next tries, on the peer's own timer.
      def session_start(body)
        peers = selected(check(body, 'session.start'))
        peers.each(&:admin_start)
        publish(:log, "session.start #{peers.collect(&:address).join(', ')}",
                :action => 'session.start')
        { :action  => 'session.start',
          :peers   => peers.collect(&:address),
          :passive => peers.reject(&:active?).collect(&:address) }
      end

      # Takes a session down and lets it back up, `count` times,
      # `interval` seconds each way.
      #
      # **It answers before it has finished**, which is deliberate: three
      # flaps at five seconds is thirty seconds, and a POST that blocks
      # for it would sit inside a driver's HTTP timeout for no gain. A
      # scenario waits on a condition with `within:` instead, which is
      # how docs/routescope-labs.md section 9.4's scenario C is written.
      def session_flap(body)
        block = check(body, 'session.flap')
        peers = selected(block)
        count = integer(block, 'count', 1)
        raise Refused, 'session.flap: count must be at least 1' if count < 1
        interval = seconds(block, 'interval', 1)
        thread = Thread.new do
          count.times do
            peers.each(&:admin_stop)
            sleep interval
            peers.each(&:admin_start)
            sleep interval
          end
        end
        @lock.synchronize { @threads << thread }
        publish(:log, "session.flap #{peers.collect(&:address).join(', ')} " \
                      "#{count} time(s) every #{interval}s", :action => 'session.flap')
        { :action => 'session.flap', :peers => peers.collect(&:address),
          :count => count, :interval => interval, :running => true }
      end

      # A ROUTE-REFRESH, RFC 2918, with the RFC 7313 section 3.2 Message
      # Subtype when one is asked for.
      def refresh(body)
        block = check(body, 'refresh')
        afi = integer(block, 'afi', 1)
        safi = integer(block, 'safi', 1)
        h = { :afi => afi, :safi => safi }
        h[:subtype] = integer(block, 'subtype', 0) unless block['subtype'].nil?
        msg = begin
          BGP::Route_refresh.new(h)
        rescue ArgumentError => e
          raise Refused, "refresh: #{e.message} (afi #{afi}, safi #{safi})"
        end
        result = send_to(targets(block), 'refresh') { |peer| send_one(peer, msg, 'refresh', 0) }
        publish(:log, "route refresh afi #{afi} safi #{safi}", :action => 'refresh',
                :afi => afi, :safi => safi)
        result.merge(h)
      end

      # A `BGP::Gen` spec, announced or withdrawn, as a feed.
      #
      # It is `feed` with the library in place of `RouteGenerator`, and
      # it keeps `feed`'s two rules: one record per peer in `/api/sent`,
      # and a thread of its own unless `async` is false. **The spec is
      # read before anything starts**, once per peer since the sender
      # differs, so a spec the library refuses is a 400 now and never a
      # failed feed on a thread later. A spec that reads but stops
      # halfway, `Gen::Unpackable` from a set that grew too large, is a
      # failed feed with the reason in its record.
      #
      # **Nothing is remembered**, as for a generated range: there is no
      # list of a million prefixes here and `resend` replays only what
      # `prefixes` announced. A withdrawal still forgets any of those
      # its range covers, so `/api/sent` does not go on listing a prefix
      # the peer was told to drop.
      def spec_feed(block, peers, action, async)
        gens = peers.collect { |peer| [peer, generator(block, peer)] }
        records = gens.collect { |peer, gen|
          s = gen.spec
          record = @sent.start_feed(action, "#{gen.family} #{s['start']} x #{gen.total}", peer.address)
          run = lambda do
            begin
              messages = action == 'withdraw' ? gen.withdrawals : gen.updates
              messages.each do |msg|
                peer.send_message(msg)
                @sent.tick(record, Injector.prefix_count(msg) + Injector.withdrawn_count(msg))
              end
              @sent.finish_feed(record)
            rescue StandardError => e
              @sent.finish_feed(record, "#{e.class}: #{e.message}")
            end
          end
          async ? @lock.synchronize { @threads << Thread.new { run.call } } : run.call
          record
        }
        forget_expected(gens.first[1]) if action == 'withdraw' && !gens.empty?
        s = gens.first ? gens.first[1].spec : block['spec']
        publish(ROUTE, "#{action} spec #{s['family']} #{s['start']} x #{s['count']} to " \
                       "#{peers.collect(&:address).join(', ')}",
                :action => action, :spec => s)
        { :action => action, :feeds => records.collect(&:to_h) }
      end

      # A churn of a spec the peer already holds, docs/route-generation.md
      # section 8, as a feed: one UPDATE per event, paced at the churn's
      # `rate` when it gives one and sent at once when it does not.
      #
      # **It acts on what the spec announced and does not check that the
      # peer holds it**, which is `Gen::Churn`'s own rule: the caller
      # announces the spec first, and `POST /api/plan` with the same
      # `spec` and `churn` answers what the peer should hold afterwards.
      #
      # The feed's record counts every event, and the totals count each
      # under what it is, a withdrawal or an announcement, so
      # `withdrawn_sent` still means prefixes withdrawn. The pacing is
      # against the feed's start rather than event to event, so a slow
      # send does not stretch the whole churn.
      def churn(block, async = true)
        runs = targets(block).collect { |peer|
          gen = generator(block, peer)
          [peer, gen, churner(gen, block)]
        }
        records = runs.collect { |peer, gen, c|
          record = @sent.start_feed('churn', "#{gen.family} churn of #{c.routes} route(s), " \
                                             "#{c.count} event(s)", peer.address)
          run = lambda do
            begin
              t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
              c.events.each do |e|
                if c.interval
                  wait = t0 + e.number * c.interval - Process.clock_gettime(Process::CLOCK_MONOTONIC)
                  sleep wait if wait > 0
                end
                peer.send_message(e.update)
                @sent.tick(record, 1, as: e.kind == 'withdraw' ? 'withdraw' : 'announce')
              end
              @sent.finish_feed(record)
            rescue StandardError => e
              @sent.finish_feed(record, "#{e.class}: #{e.message}")
            end
          end
          async ? @lock.synchronize { @threads << Thread.new { run.call } } : run.call
          record
        }
        c = runs.first[2]
        publish(ROUTE, "churn of #{c.routes} route(s), #{c.count} event(s), to " \
                       "#{runs.collect { |peer, _, _| peer.address }.join(', ')}",
                :action => 'churn', :churn => c.spec)
        { :action => 'announce', :churn => c.spec, :summary => c.summary,
          :feeds => records.collect(&:to_h) }
      end

      # The churn for a generator. One the library cannot read is the
      # caller's to fix, so a 400 like a spec.
      def churner(gen, block)
        gen.churn(block['churn'])
      rescue BGP::Gen::SpecError => e
        raise Refused, "churn: #{e.message}"
      end

      # The generator for one peer, with that session's rules. A spec
      # the library cannot read is the caller's to fix, so a 400.
      def generator(block, peer)
        BGP::Gen.new(block['spec'], 'as' => @speaker.my_as, 'ebgp' => peer.ebgp?,
                                    'next_hop' => peer.local_ip,
                                    'as_path_literal' => block['as_path_literal'] == true)
      rescue BGP::Gen::SpecError => e
        raise Refused, "spec: #{e.message}"
      end

      # One MP_REACH_NLRI, built from the Hash `Mp_reach.new` reads, in
      # the envelope `Fault.wrap` gives every catalog case: ORIGIN and an
      # AS_PATH of our AS toward an external peer. No NEXT_HOP attribute,
      # since the next hop is inside the MP_REACH_NLRI and RFC 4760
      # section 3 says an UPDATE with no other NLRI should not carry one.
      def mp_reach(block)
        attr = build_mp(BGP::Mp_reach, block['mp_reach'], 'mp_reach')
        result = send_to(targets(block), 'announce') { |peer|
          msg = BGP::Fault.wrap(attr, :my_as => (peer.ebgp? ? @speaker.my_as : nil))
          send_one(peer, msg, 'announce', Injector.prefix_count(msg))
        }
        publish(ROUTE, "announced an MP_REACH_NLRI, AFI #{attr.afi} SAFI #{attr.safi}",
                :action => 'announce', :afi => attr.afi, :safi => attr.safi)
        result.merge(:afi => attr.afi, :safi => attr.safi, :prefixes => attr.nlris.size)
      end

      # One MP_UNREACH_NLRI and nothing else, which RFC 4760 section 4
      # allows: an UPDATE that only withdraws carries no other attribute.
      def mp_unreach(block)
        attr = build_mp(BGP::Mp_unreach, block['mp_unreach'], 'mp_unreach')
        msg = BGP::Update.new(BGP::Path_attribute.new(attr))
        result = send_to(targets(block), 'withdraw') { |peer|
          send_one(peer, msg, 'withdraw', attr.nlris.size)
        }
        publish(ROUTE, "withdrew with an MP_UNREACH_NLRI, AFI #{attr.afi} SAFI #{attr.safi}",
                :action => 'withdraw', :afi => attr.afi, :safi => attr.safi)
        result.merge(:afi => attr.afi, :safi => attr.safi, :prefixes => attr.nlris.size)
      end

      # A `BGP::Specimen` by name, sent once like a fault case and not
      # resent after a flap, in the envelope `Specimen.update` and
      # `Fault.update` share. A NEXT_HOP goes with `prefixes` only, for
      # the RFC 4760 section 3 reason `mp_reach` gives.
      def specimen(block)
        block = selector(block, 'announce', 'specimen')
        name = block['specimen'].to_s
        unless BGP::Specimen.names.include?(name.to_sym)
          raise Refused, "specimen: unknown name #{name.inspect}; the catalog has " \
                         "#{BGP::Specimen.names.join(', ')}"
        end
        prefixes = Array(block['prefixes'])
        result = send_to(targets(block), 'announce') { |peer|
          msg = BGP::Specimen.update(name.to_sym,
                                     :my_as    => (peer.ebgp? ? @speaker.my_as : nil),
                                     :next_hop => (prefixes.empty? ? nil : block.fetch('next_hop', peer.local_ip)),
                                     :prefixes => prefixes)
          send_one(peer, msg, 'announce', Injector.prefix_count(msg))
        }
        publish(ROUTE, "announced specimen #{name}", :action => 'announce', :specimen => name)
        result.merge(:specimen => name, :prefixes => prefixes)
      end

      # The body of one of the SELECTORS, refusing the keys that do not
      # go with it.
      def selector(block, action, name = nil)
        name ||= SELECTORS.fetch(action).keys.find { |k| !block[k].nil? }
        allowed = %w[peer] + [name] + SELECTORS.fetch(action).fetch(name)
        extra = block.keys - allowed
        unless extra.empty?
          raise Refused, "#{action}: #{extra.join(', ')} do(es) not go with #{name}; " \
                         "#{name} takes #{(allowed - [name]).join(', ')}"
        end
        block
      end

      # An attribute from a JSON Hash. JSON keys are Strings and the
      # constructors read Symbols, at every depth, since an NLRI Hash
      # nests. A constructor that cannot represent the input raises, and
      # `Mp_reach.new` raises a RuntimeError for a SAFI it has no arm
      # for, so anything it raises is the caller's to fix.
      def build_mp(klass, h, name)
        raise Refused, "#{name} is a JSON object, got #{h.class}" unless h.is_a?(Hash)
        klass.new(Injector.symbolize(h))
      rescue Refused
        raise
      rescue StandardError => e
        raise Refused, "#{name}: #{e.class}: #{e.message}"
      end

      def self.symbolize(o)
        case o
        when Hash then o.to_h { |k, v| [k.is_a?(String) ? k.to_sym : k, symbolize(v)] }
        when Array then o.collect { |v| symbolize(v) }
        else o
        end
      end

      # ---- sending -----------------------------------------------------

      # One announce block to one peer, through the Speaker, so the path
      # attributes an action builds are the ones a node file's announce
      # block builds. There is one place that reads `med`, `as_path`,
      # `communities` and the rest, and it is `Speaker#path_attribute`.
      def send_block(peer, block, action)
        prefixes, updates = 0, 0
        @speaker.each_update(block, peer.ebgp?, peer.local_ip, peer.session_info) do |msg|
          peer.send_message(msg)
          updates += 1
          prefixes += Injector.prefix_count(msg)
        end
        @sent.count(action, prefixes, updates)
        [prefixes, updates]
      end

      # One message to one peer.
      def send_one(peer, msg, action, prefixes)
        peer.send_message(msg)
        @sent.count(action, prefixes)
        [prefixes, 1]
      end

      # Runs the block for each target and collects what went out.
      def send_to(peers, action)
        updates = 0
        peers.each { |peer| updates += yield(peer)[1] }
        { :action => action, :updates => updates, :peers => peers.collect(&:address) }
      end

      # A generated range, on a thread of its own unless asked otherwise.
      def feed(block, peers, action, async)
        g = generate_options(block)
        # Checked here rather than inside the feed, so a bad one is a 400
        # now and not a failed feed on a thread later. The range is RFC
        # 7911 section 3's four octets, the same one RouteGenerator holds.
        path_id = integer(block, 'path_id', nil)
        if path_id && !(0..BGP::RouteGenerator::MAX_PATH_ID).include?(path_id)
          raise Refused, "path_id #{path_id} does not fit in 4 octets (RFC 7911 section 3)"
        end
        records = peers.collect { |peer|
          range = "#{g['start']} x #{g['count']}"
          record = @sent.start_feed(action, range, peer.address)
          run = lambda do
            begin
              action == 'withdraw' ? stream_withdraw(peer, block, g, record) :
                                     stream_announce(peer, block, record)
              @sent.finish_feed(record)
            rescue StandardError => e
              @sent.finish_feed(record, "#{e.class}: #{e.message}")
            end
          end
          async ? @lock.synchronize { @threads << Thread.new { run.call } } : run.call
          record
        }
        publish(ROUTE, "#{action} feed #{g['start']} x #{g['count']} to " \
                       "#{peers.collect(&:address).join(', ')}",
                :action => action, :generate => g)
        { :action => action, :feeds => records.collect(&:to_h) }
      end

      # The announcements of one generated range, one UPDATE at a time.
      # `RouteGenerator` does the packing and the one size check, which
      # is its own comment's reasoning: every prefix is the same length,
      # so the first batch is the largest.
      def stream_announce(peer, block, record)
        @speaker.each_update(block, peer.ebgp?, peer.local_ip, peer.session_info) do |msg|
          peer.send_message(msg)
          @sent.tick(record, Injector.prefix_count(msg))
        end
      end

      # The withdrawals of one generated range.
      #
      # **The prefixes are regenerated and not read back from a list**,
      # which is the requirement docs/daemon.md states for a generated
      # feed: there is no Adj-RIB-Out here, because recording a million
      # prefixes to know what was sent defeats the streaming that is the
      # whole reason the generator exists.
      #
      # **The packing is arithmetic and not measurement**, the same
      # `per_update` the announcement used. A withdrawal UPDATE of the
      # same prefixes is strictly smaller than the announcement that
      # fit, because the prefix encoding is identical (RFC 4271 section
      # 4.3 gives Withdrawn Routes and NLRI the same shape) and the path
      # attributes are gone. The first message is still measured, as
      # `RouteGenerator#check_size` measures the first batch and for the
      # same reason: that check guards **our** arithmetic, and it is not
      # a check on what a caller asked for.
      def stream_withdraw(peer, block, g, record)
        gen = BGP::RouteGenerator.new(g['start'], g['count'], g['per_update'])
        first = true
        gen.each_prefix.each_slice(g['per_update']) do |slice|
          msg = BGP::Update.new(withdrawn_for(slice, block['path_id']))
          if first
            Injector.check_size(msg, peer.session_info, g['per_update'])
            first = false
          end
          peer.send_message(msg)
          @sent.tick(record, slice.size)
        end
      end

      # The Withdrawn Routes field of RFC 4271 section 4.3, with the RFC
      # 7911 section 3 Path Identifier in front of each prefix when one
      # is asked for. It is `Speaker#nlri_for` for the other field, and
      # it is here rather than there because a node file cannot express a
      # withdrawal: only an action can.
      def withdrawn_for(prefixes, path_id)
        return BGP::Withdrawn.new(*prefixes) if path_id.nil?
        id = Integer(path_id)
        BGP::Withdrawn.new(*prefixes.collect { |p| { :path_id => id, :nlri => p } })
      rescue ArgumentError, TypeError
        raise Refused, "path_id must be an integer, got #{path_id.inspect}"
      end

      # Our arithmetic, checked once. It raises rather than reaching the
      # wire, which is the half of docs/daemon.md's packing requirement
      # that is not arithmetic.
      def self.check_size(msg, session_info, per_update)
        size = (session_info ? msg.encode(session_info) : msg.encode).bytesize
        return msg if size <= BGP::Message::MAX_SIZE
        raise Refused, "#{per_update} prefixes per message make a #{size} octet " \
                       "message; BGP allows #{BGP::Message::MAX_SIZE} " \
                       '(RFC 4271 section 4). Use a smaller per_update.'
      end

      # How many prefixes one UPDATE carries and withdraws. The counting
      # is BGP::Prompt's, which `received` prints with and which must not
      # load this file, so it is written once there.
      def self.prefix_count(msg) ; Prompt.prefix_count(msg) ; end
      def self.withdrawn_count(msg) ; Prompt.withdrawn_count(msg) ; end

      # ---- what was announced -----------------------------------------

      def remember(prefixes, body)
        @lock.synchronize { prefixes.each { |p| @announced[p.to_s] = body } }
      end

      def forget(prefixes)
        @lock.synchronize { prefixes.each { |p| @announced.delete(p.to_s) } }
      end

      # A withdrawn generated range, forgotten by regenerating it, which
      # is the same rule as sending it: there is no list to walk.
      def forget_range(block)
        g = generate_options(block)
        gen = BGP::RouteGenerator.new(g['start'], g['count'], g['per_update'])
        @lock.synchronize { gen.each_prefix { |p| @announced.delete(p) } }
      end

      # A withdrawn spec, forgotten by walking what it meant to send.
      # Skipped when nothing was announced by `prefixes`, which is the
      # usual case and saves walking a million rows for nothing.
      #
      # **Only a unicast spec forgets anything**, because `prefixes`
      # announces unicast and nothing else. A multicast, labelled or VPN
      # route of the same prefix text is another route in another table,
      # so withdrawing it leaves the unicast one on the peer.
      def forget_expected(gen)
        return unless gen.family == 'unicast'
        return if @lock.synchronize { @announced.empty? }
        gen.expected.each { |r| @lock.synchronize { @announced.delete(r['prefix']) } }
      end

      # What was announced on command, again, because the peer that has
      # just re-established holds nothing.
      #
      # **A config `announce` block gets this for free and an action does
      # not**, which is the gap this closes: `Peer#announce` replays
      # `Speaker#announcements` on every establishment, so without this a
      # `session.flap` would lose for good everything a scenario had
      # announced, and the scenario would read as a convergence failure.
      #
      # **A generated feed is not replayed**, which is the fire and
      # forget rule: there is no list of its prefixes to replay and
      # rebuilding one would be the Adj-RIB-Out the generator exists to
      # avoid. A scenario that wants a feed back asks for it again.
      #
      # It runs on the session's own thread, as `Peer#announce` does, and
      # must not raise there: a listener that killed the session would
      # take the thing it was restoring with it.
      def resend(peer)
        groups = @lock.synchronize { @announced.group_by { |_prefix, body| body } }
        blocks = 0
        groups.each do |body, pairs|
          # An announcement a `peer` key aimed at one session stays aimed
          # at it.
          next if body['peer'] && body['peer'].to_s != peer.address
          send_block(peer, body.merge('prefixes' => pairs.collect(&:first)), 'announce')
          blocks += 1
        end
        return if blocks.zero?
        publish(ROUTE, "re-announced #{blocks} block(s) to #{peer.address}",
                :peer => peer.address, :action => 'resend')
      rescue StandardError => e
        log(:warn, "bgp4r-sim: re-announcing to #{peer.address}: #{e.class}: #{e.message}")
      end

      # ---- the body ----------------------------------------------------

      # The body with its keys as Strings, refusing any key the action
      # does not read.
      #
      # **`peer` stays in it**, even though it is a selector rather than
      # part of an announce block, and that is deliberate: it is what
      # makes an announcement remember which session it was aimed at, so
      # `attribute` changes it on the same session and `resend` puts it
      # back on the same session. The announce block readers in
      # `Speaker` name the keys they read, so a key they do not read
      # costs nothing there.
      def check(body, action)
        keys = ACTIONS.fetch(action)
        given = body.keys.collect(&:to_s)
        unknown = given - keys
        unless unknown.empty?
          raise Refused, "#{action}: unknown key(s) #{unknown.join(', ')}; " \
                         "it reads #{keys.join(', ')}"
        end
        block = body.to_h { |k, v| [k.to_s, v] }
        named_spec(block)
        # A JSON boolean and nothing else. `Speaker#path_attribute` reads
        # only `true`, so a string `"true"` would quietly prepend our AS
        # and send a path the caller did not ask for.
        v = block['as_path_literal']
        unless v.nil? || v == true || v == false
          raise Refused, "as_path_literal must be true or false, got #{v.inspect}"
        end
        block
      end

      # A `spec` given as a String is the name of one in the node file's
      # `specs`, and is replaced by it. An unknown name is refused with
      # the names there are, rather than read as a spec and refused for
      # not being one.
      def named_spec(block)
        name = block['spec']
        return unless name.is_a?(String)
        spec = @specs[name]
        unless spec
          known = @specs.empty? ? 'this node file names none' : "it names #{@specs.keys.join(', ')}"
          raise Refused, "spec #{name.inspect} is not in this node's specs; #{known}"
        end
        block['spec'] = spec
      end

      def one_of(block, *names)
        given = names.select { |n| !block[n].nil? }
        return if given.size == 1
        raise Refused, "give exactly one of #{names.join(', ')}, " \
                       "got #{given.empty? ? 'neither' : given.join(' and ')}"
      end

      # The peers an action reaches: the one its `peer` key names, or
      # every session that is up.
      #
      # **An action with no session to send on is refused and not
      # ignored.** A 200 that sent nothing is the silent wrong answer a
      # scenario cannot see, and it is the commonest thing to meet: the
      # session is still coming up.
      def targets(block)
        named = block['peer']
        return [peer!(named)] if named
        list = @speaker.established_peers
        if list.empty?
          raise Daemon::NoSession,
                'no established session: ' \
                "#{@speaker.peers.collect { |p| "#{p.address} #{p.state.downcase}" }.join(', ')}"
        end
        list
      end

      # The peers a session action reaches, which is every **configured**
      # peer rather than every established one: a session that is down is
      # exactly what `session.start` is for.
      def selected(block)
        named = block['peer']
        named ? [peer!(named)] : @speaker.peers
      end

      def peer!(address)
        peer = @speaker.peer(address)
        return peer if peer
        raise Refused, "#{address} is not a configured peer; this injector has " \
                       "#{@speaker.peers.collect(&:address).join(', ')}"
      end

      def generate_options(block)
        Daemon::Speaker.generate_options(block['generate'])
      rescue ArgumentError, KeyError, TypeError => e
        raise Refused, "generate: #{e.message}"
      end

      def integer(block, name, default)
        v = block[name]
        return default if v.nil?
        Integer(v)
      rescue ArgumentError, TypeError
        raise Refused, "#{name} must be an integer, got #{v.inspect}"
      end

      def octet(block, name)
        v = integer(block, name, 0)
        return v if (0..255).include?(v)
        raise Refused, "#{name} is one octet, so 0 to 255, got #{v}"
      end

      def seconds(block, name, default)
        v = block[name]
        return default if v.nil?
        f = Float(v)
        raise Refused, "#{name} must not be negative, got #{v.inspect}" if f.negative?
        f
      rescue ArgumentError, TypeError
        raise Refused, "#{name} must be a number of seconds, got #{v.inspect}"
      end

      # Hex digits to octets. Whitespace is allowed, so a capture pasted
      # out of a dump works, and an odd number of digits is refused
      # because it is not octets at all.
      def hex_octets(value, what)
        hex = value.to_s.gsub(/\s+/, '')
        unless hex =~ /\A(\h\h)*\z/
          raise Refused, "#{what}: #{value.inspect} is not an even number of hex digits"
        end
        [hex].pack('H*')
      end

      def publish(kind, message, data = {})
        @speaker.events.publish(:kind => kind, :message => message,
                                :peer => data[:peer], :data => stringify(data))
      rescue StandardError => e
        log(:warn, "bgp4r-sim: publishing an event: #{e.class}: #{e.message}")
      end

      # JSON has no symbols, and an event's data is read by a program.
      # `Recorder.stringify` is the same conversion for the same reason.
      def stringify(h)
        Daemon::Recorder.stringify(h)
      end

    end

  end
end
