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

require 'bgp/daemon/config'

module BGP
  module Daemon

    # The candidate configuration: a second copy of the running one that
    # can be edited, compared, checked, committed, discarded and rolled
    # back. It is the `config.*` half of the control API, and
    # `show.configuration` reads it.
    #
    #   bgp4r-cli config.load '{"lines":["set neighbors 10.0.10.1 hold_time 60"]}'
    #   bgp4r-cli config.compare
    #   bgp4r-cli config.commit '{"check":true}'
    #   bgp4r-cli config.commit '{"comment":"hold time"}'
    #
    # **It is a file of its own rather than more methods on `Control`, and
    # the reason is the shape of what it holds.** `Control` is stateless:
    # it takes a request, drives the Speaker and answers what it did.
    # This holds two configurations, a commit history and the
    # configurations behind it, under a lock of its own, so it is state
    # with methods rather than methods over somebody else's state. It is
    # not `Views` either, for that file's own reason: nothing in Views
    # decides anything and a commit decides a great deal.
    #
    # ## What a commit does to a running speaker
    #
    # This is the part worth reading before changing anything here. A key
    # is one of three things, and a commit says which in its answer rather
    # than hoping:
    #
    # | Effect | Keys | What a commit does |
    # |---|---|---|
    # | live | `log_level`, `originate`, a neighbor's `description` | applies it, and nothing on the wire stops |
    # | bounce | a neighbor's `as`, `hold_time`, `capabilities`, `connect`, `port`, `retry` | ends that session and lets it come back |
    # | bounce all | `announce` | ends every session and lets them come back |
    # | restart | everything else | **refuses the commit**, naming the key |
    #
    # **A restart-class change is refused and that is the honest
    # answer**, which took some deciding, so here is the argument rather
    # than the verdict. There are three things a commit could do with
    # `router_id`: apply it, which it cannot; record it in the running
    # configuration and warn, which makes `show.configuration` describe a
    # speaker that does not exist; or refuse. The second is the one to
    # avoid, because docs/daemon.md's own rule is that a commit must not
    # claim to apply a key it ignored, and a running configuration that
    # disagrees with the running speaker is that claim in the one place a
    # reader goes to check. So it is refused, in `errors`, with the
    # mechanism in the message, and the running configuration goes on
    # being true. A person who wants the change edits the file and
    # restarts, which is what they would have had to do anyway.
    #
    # **Each restart-class group is refused for a measured reason and not
    # on principle.** The sharpest is `export` and `fib`:
    # `Table#on_change` appends to a list of listeners and there is **no
    # way to take one off**, measured in `bgp/rib/table.rb`, where
    # `@listeners` is only ever `<<`'d and `Router#stop` stops the pacer
    # thread and leaves its listener registered. So replacing a `Router`
    # live would leave the old one advertising beside the new one, with
    # two Adj-RIB-Outs disagreeing about what each peer holds. That is a
    # wrong answer on the wire, not a missing feature, and it is listed
    # under "Known issues to work on" in CLAUDE.md.
    #
    # **`warnings` is where a bounce is reported**, because a bounce is a
    # thing that happened to the session rather than a thing that went
    # wrong: "the session with 10.0.10.1 was bounced to pick up
    # hold_time". A `check` says the same thing in the future tense, so a
    # person sees what a commit would cost before paying it.
    #
    # ## The nine methods and where they came from
    #
    # **Read in routescope's `Drivers::Ospfd` at commit `7eabde1`, not
    # designed here**, and docs/daemon.md's method table said three where
    # the driver calls nine. The driver's Config pane reaches a candidate
    # through `show.configuration` with `format: 'set'` and again with
    # `candidate: true`, `config.changed`, `config.replace`,
    # `config.compare`, `config.commit` twice over (with `check: true`
    # and with `comment:`), `config.discard`, `config.history` and
    # `config.rollback`. A driver answering `candidate?` true has to have
    # all of them: `Config#with_candidate` in routescope refuses the whole
    # pane without it, and `discard_candidate`, `rollbacks` and
    # `load_rollback` are each a route in its `app.rb`.
    #
    # **`config.load` is the tenth and no driver calls it.** It is kept,
    # because ospfv2 has it and because it is the one that makes the API
    # usable by hand: changing one key with `config.replace` means sending
    # the whole configuration back, and docs/daemon.md's one principle is
    # that every action a console takes must be a command a person can
    # type. `config.load` is that command.
    class Candidate

      # Configurations kept behind the running one, and so the most
      # rollbacks a caller can ask for. The oldest is the file as it was
      # read, which has no commit in `history` of its own.
      ROLLBACKS = 20

      # What a changed key costs. See the table on the class.
      LIVE       = :live
      BOUNCE     = :bounce
      BOUNCE_ALL = :bounce_all
      RESTART    = :restart

      # A neighbor's keys that a bounced session picks up. Each is read in
      # `Peer#new_neighbor` or in `Peer#run_active` when a session starts,
      # so ending the session and letting it come back is the whole of
      # applying them.
      NEIGHBOR_BOUNCE_KEYS = %w[as hold_time capabilities connect port retry].freeze

      # A neighbor's keys that take effect with no session change at all.
      NEIGHBOR_LIVE_KEYS = %w[description].freeze

      # Why a key cannot change while bgp4rd runs, by its first path
      # token. The mechanism, not the verdict: a later reader has to be
      # able to tell whether the reason still holds.
      RESTART_REASONS = {
        'export' => 'Table#on_change cannot take a listener off again, so the Router this ' \
                    'would replace would go on advertising beside the new one',
        'fib' => 'Table#on_change cannot take a listener off again, so the FibInstaller this ' \
                 'would replace would go on installing beside the new one',
        'rib' => 'the table is built in Speaker#initialize and every session is attached to it',
        'router_id' => 'every session carries it in its OPEN and the Loc-RIB is keyed by it',
        'as' => 'every session carries it in its OPEN and the export rules compare against it',
        'socket' => 'the control socket is bound once, and this request arrived on it'
      }.freeze

      # The one it falls back to, which is true of every remaining key:
      # `listen_address`, `port`, `local_address` and `state_file` are all
      # read once by `Speaker#start`.
      RESTART_DEFAULT = 'it is read once, when bgp4rd starts'

      # Why one of a neighbor's own keys cannot change. **Looked up
      # before the table above and not through it**, because that one is
      # keyed by the first token and a neighbor's key is the third: a
      # `neighbors` row there would give every unclassified neighbor key
      # the same reason, and a test caught it doing exactly that, telling
      # a person that `record` could not change because `@peers` has no
      # lock.
      NEIGHBOR_RESTART_REASONS = {
        'record' => 'the Recorder is built once, in Peer#initialize, and counts ' \
                    'established_count and flaps across sessions, so a bounce deliberately ' \
                    'leaves those alone and replacing it would reset them'
      }.freeze

      # Adding a neighbor or taking one away, which is refused before the
      # per key pass because its keys read as ordinary bounce-class
      # changes and are not.
      NEIGHBOR_SET_REASON = '@peers is built in Speaker#initialize and read from every ' \
                            'session thread without a lock, and whether anything listens ' \
                            'for a passive peer is decided once in Speaker#start'

      attr_reader :speaker

      # :logger is a ->(level, message) or nil, as everything else in
      # bgp/daemon/ takes one.
      def initialize(speaker, config, arg = {})
        @speaker  = speaker
        @logger   = arg[:logger]
        @running   = Config.deep_copy(config)
        @candidate = Config.deep_copy(config)
        # Newest first, and one longer than @commits can be: the last is
        # the file as it was read, which no commit produced.
        @previous = []
        @commits  = []
        @lock = Mutex.new
      end

      # `show.configuration`. `format` is `set` for the set lines a driver
      # diffs, and anything else is the YAML a person edits.
      #
      # **YAML is the default and `set` is asked for**, which is the other
      # way round from ospfd's curly braces: bgp4rd's configuration **is**
      # a YAML file, so the form a person recognises is the one they get
      # with no argument, and `Drivers::Ospfd` passes `format: 'set'`
      # already.
      def configuration(params = {})
        p = strings(params, %w[format candidate])
        want = p['candidate'] == true
        @lock.synchronize do
          tree = want ? @candidate : @running
          p['format'].to_s == 'set' ? Config.to_set(tree).join("\n") + "\n" : Config.to_yaml_text(tree)
        end
      end

      # `config.changed`: **a boolean and nothing else**, because
      # `Drivers::Ospfd#running_config` uses the answer as one directly.
      def changed?(params = {})
        strings(params, [])
        @lock.synchronize { !Config.compare(@running, @candidate).empty? }
      end

      # `config.compare`: **an Array of lines**, which is what the driver
      # maps over to mask and then shows as the change list.
      def compare(params = {})
        strings(params, [])
        @lock.synchronize { Config.compare(@running, @candidate) }
      end

      # `config.replace`: `lines` become the whole candidate, which is
      # Junos's "load override" and is what the driver sends a startup
      # file as.
      #
      # **It answers `{errors: [...]}` and raises nothing**, because the
      # driver reads `['errors']` and treats an empty Array as success. A
      # text it cannot read leaves the candidate exactly as it was: a
      # half-loaded candidate is the one outcome nobody can act on.
      def replace(params = {})
        p = strings(params, %w[lines])
        lines = Array(p['lines']).map { |l| l.to_s }
        @lock.synchronize do
          tree = Config.from_set(lines)
          @candidate = tree
          { :errors => [] }
        end
      rescue Config::Error => e
        { :errors => [e.message] }
      end

      # `config.load`: `lines` applied on top of the candidate, so one key
      # can be changed without sending the rest back. The tenth method and
      # the one no driver calls; the class comment says why it is here.
      def load(params = {})
        p = strings(params, %w[lines])
        lines = Array(p['lines']).map { |l| l.to_s }
        @lock.synchronize do
          tree = Config.apply(@candidate, lines)
          @candidate = tree
          { :errors => [] }
        end
      rescue Config::Error => e
        { :errors => [e.message] }
      end

      # `config.discard`: the candidate becomes the running configuration
      # again.
      def discard(params = {})
        strings(params, [])
        @lock.synchronize do
          @candidate = Config.deep_copy(@running)
          { :discarded => true, :changed => false }
        end
      end

      # `config.commit`, with `check: true` for what it would do and
      # `comment:` for doing it.
      #
      #   { "ok": true, "errors": [], "warnings": [...], "changes": [...] }
      #
      # **The four keys are the driver's**, which reads `ok` to decide
      # whether to raise, maps `errors` and `changes` through its mask and
      # shows `warnings` as they are.
      def commit(params = {})
        p = strings(params, %w[check comment])
        check = p['check'] == true
        @lock.synchronize do
          plan = Plan.new(@speaker, @running, @candidate)
          return answer(false, plan.errors, [], []) unless plan.errors.empty?
          return answer(true, [], plan.notices, plan.changes) if check
          return answer(true, [], [], []) if plan.changes.empty?
          warnings = plan.apply
          record(plan, p['comment'])
          log(:info, "commit#{p['comment'] ? " (#{p['comment']})" : ''}: " \
                     "#{plan.changes.size} change(s)#{warnings.empty? ? '' : ", #{warnings.size} warning(s)"}")
          answer(true, [], warnings, plan.changes)
        end
      end

      # `config.history`, newest first, one row per commit. Row `i`
      # describes rollback `i`, which is what
      # `Drivers::Ospfd#rollbacks` relies on when it labels each row with
      # its index.
      def history(params = {})
        strings(params, [])
        @lock.synchronize { @commits.map { |c| c.dup } }
      end

      # `config.rollback`: configuration `number` becomes the candidate,
      # to be committed or discarded. 0 is the running one, which is
      # `config.discard` by another name and is what the pane's "rollback
      # 0" row means.
      def rollback(params = {})
        p = strings(params, %w[number])
        n = integer(p['number'] || 0, 'number')
        @lock.synchronize do
          unless n.between?(0, @previous.size)
            raise ArgumentError,
                  "rollback #{n} does not exist: this bgp4rd has " \
                  "#{@previous.empty? ? 'only 0, the running configuration' : "0 to #{@previous.size}"}"
          end
          @candidate = Config.deep_copy(n.zero? ? @running : @previous[n - 1])
          { :rollback => n, :changed => !Config.compare(@running, @candidate).empty? }
        end
      end

      # The running configuration, for a caller that wants the tree rather
      # than the text. A copy, so nothing outside can edit what the
      # speaker is running.
      def running
        @lock.synchronize { Config.deep_copy(@running) }
      end

      private

      def answer(ok, errors, warnings, changes)
        { :ok => ok, :errors => errors, :warnings => warnings, :changes => changes }
      end

      # A commit happened: the configuration that was running goes behind
      # the new one and the commit goes in the history, so the two stay in
      # step and `history[i]` keeps describing rollback `i`.
      def record(plan, comment)
        @previous.unshift(@running)
        @previous.pop while @previous.size > ROLLBACKS
        @running = Config.deep_copy(@candidate)
        @commits.unshift(:time => Recorder.iso(Time.now),
                         :comment => comment && comment.to_s,
                         :changes => plan.changes.size)
        @commits.pop while @commits.size > ROLLBACKS
      end

      def log(level, message)
        @logger.call(level, "bgp4rd: #{message}") if @logger
      end

      # The parameters with String keys, refusing a name this does not
      # read. `Control#strings`'s rule and its reason: an ignored body key
      # is a wrong answer and not a missing one.
      def strings(params, known)
        h = {}
        (params || {}).each { |k, v| h[k.to_s] = v }
        unknown = h.keys - known
        unless unknown.empty?
          raise ArgumentError,
                "unknown parameter(s) #{unknown.join(', ')}: this takes " \
                "#{known.empty? ? 'none' : known.join(', ')}"
        end
        h
      end

      def integer(v, name)
        Integer(v)
      rescue ArgumentError, TypeError
        raise ArgumentError, "#{name} must be an integer, got #{v.inspect}"
      end

      # What one commit would do, worked out before anything is touched:
      # the changes, what it cannot do, what it would cost, and then
      # doing it.
      #
      # **It is computed and then applied, in that order, so a commit that
      # cannot be done changes nothing.** `errors` is read first and a
      # commit with any stops; `apply` is the only method here that
      # touches the Speaker.
      class Plan

        attr_reader :changes, :errors, :notices

        def initialize(speaker, running, candidate)
          @speaker, @running, @candidate = speaker, running, candidate
          @changes = Config.compare(running, candidate)
          @paths   = Config.changed_paths(running, candidate)
          @errors, @notices = [], []
          @bounce, @live = [], []
          plan
        end

        # Does it, and answers what happened, in the past tense.
        def apply
          done = []
          originate = originate_operations
          # A copy, so the Speaker and the candidate cannot share a Hash
          # and a later `config.load` reach what is running.
          @speaker.reconfigure(Config.deep_copy(@candidate))
          done.concat(apply_log_level)
          done.concat(apply_originate(originate))
          done.concat(apply_bounces)
          done
        end

        private

        def plan
          refuse_added_or_removed_neighbors
          refuse_what_cannot_be_read
          @paths.each do |path|
            case Plan.effect(path)
            when LIVE   then @live << path
            when BOUNCE then bounce(path[1], path[2])
            when BOUNCE_ALL then @speaker.peers.each { |p| bounce(p.address, path.first) }
            else refuse(path)
            end
          end
          @notices.uniq!
          @errors.uniq!
        end

        # Which of the three a changed path is. The table on Candidate is
        # this method in prose.
        def self.effect(path)
          return LIVE if path == %w[log_level]
          return LIVE if path.first == 'originate'
          return BOUNCE_ALL if path.first == 'announce'
          if path.first == 'neighbors' && path.size >= 3
            return LIVE   if NEIGHBOR_LIVE_KEYS.include?(path[2])
            return BOUNCE if NEIGHBOR_BOUNCE_KEYS.include?(path[2])
          end
          RESTART
        end

        def bounce(address, key)
          peer = @speaker.peer(address.to_s)
          # A neighbor nobody configured cannot be bounced, and
          # refuse_added_or_removed_neighbors has already refused the
          # commit, so this only keeps the planning from raising.
          return if peer.nil?
          @bounce << peer unless @bounce.include?(peer)
          @notices << "the session with #{peer.address} will be bounced to pick up #{key}" \
                      "#{peer.active? ? '' : ', and it is a passive peer, so it comes back ' \
                                              'when the peer next dials'}"
        end

        def refuse(path)
          @errors << "#{path.join(' ')} cannot change while bgp4rd runs: " \
                     "#{reason(path)}. Edit the file and restart bgp4rd."
        end

        # A neighbor's own key is looked up first and by its **third**
        # token, since `RESTART_REASONS` is keyed by the first: a
        # `neighbors` row there would hand every unclassified neighbor key
        # the same reason, and a test caught it telling a person that
        # `record` could not change because `@peers` has no lock.
        def reason(path)
          if path.first == 'neighbors' && path.size >= 3
            return NEIGHBOR_RESTART_REASONS.fetch(path[2], RESTART_DEFAULT)
          end
          RESTART_REASONS.fetch(path.first, RESTART_DEFAULT)
        end

        # A neighbor added or taken away is refused before the per key
        # pass, because its keys read as ordinary bounce-class changes and
        # they are not: there is no session to bounce, or no Peer to
        # bounce it.
        def refuse_added_or_removed_neighbors
          was, now = addresses(@running), addresses(@candidate)
          (now - was).each do |a|
            @errors << "a neighbor cannot be added while bgp4rd runs (#{a}): " \
                       "#{NEIGHBOR_SET_REASON}. Edit the file and restart bgp4rd."
          end
          (was - now).each do |a|
            @errors << "a neighbor cannot be taken away while bgp4rd runs (#{a}): " \
                       "#{NEIGHBOR_SET_REASON}. Edit the file and restart bgp4rd."
          end
        end

        def addresses(config)
          Array(config['neighbors']).map { |n| n.is_a?(Hash) ? n['address'].to_s : nil }.compact
        end

        # A candidate this bgp4rd could not act on even where every
        # change is live or bounce class. **Not a check on what goes on
        # the wire**, which Conventions forbids anywhere: these are the
        # inputs a session cannot be built from at all, so a commit that
        # took them would bounce a session that then could not come back.
        def refuse_what_cannot_be_read
          begin
            Speaker.log_level(@candidate)
          rescue ArgumentError => e
            @errors << "log_level: #{e.message}"
          end
          bounced_or_live_neighbors.each { |c| refuse_unbuildable_neighbor(c) }
          refuse_originate_with_no_table
        end

        # **A dry run of the real code path rather than a list of rules**,
        # which is what makes it exact: `Peer#new_neighbor` is what a
        # bounce will call, so building a throwaway one here raises
        # exactly what the session would. It opens no socket. A bad
        # capability name comes back with `Neighbor#capability`'s own
        # message, which names every name there is.
        def refuse_unbuildable_neighbor(config)
          peer = Peer.new(@speaker, config)
          peer.remote_as
          peer.send(:new_neighbor)
        rescue StandardError => e
          @errors << "neighbor #{config['address']}: #{e.message}"
        end

        def bounced_or_live_neighbors
          touched = @paths.select { |p| p.first == 'neighbors' && p.size >= 2 }.map { |p| p[1] }.uniq
          Array(@candidate['neighbors']).select { |c| c.is_a?(Hash) && touched.include?(c['address'].to_s) }
        end

        # `originate` is live only where there is a table to originate
        # into. `Speaker#rib?` is read in `Speaker#initialize`, so a
        # configuration that had no `originate`, no `export` and no `rib`
        # built none and a commit cannot make one.
        def refuse_originate_with_no_table
          return if @speaker.rib
          return if @paths.none? { |p| p.first == 'originate' }
          @errors << 'originate cannot change while bgp4rd runs with no table: ' \
                     'Speaker#rib? is read once in Speaker#initialize, so there is nothing ' \
                     'to originate into. Edit the file and restart bgp4rd.'
        end

        # ---- doing it ----

        # **`Log.level=` raises when nothing has created a logger**, which
        # a `bgp4rd` always has by the time a commit can reach it, since
        # `Server#setup_log` runs before `build`. A Speaker built
        # directly, which is what a unit test has, has none: `Log.level=`
        # is `@@logger.level=` with no guard, where one line above it the
        # same method returns silently for a level out of range. So the
        # commit says it could not apply it rather than dying on the way
        # through. Listed under "Known issues to work on" in CLAUDE.md.
        def apply_log_level
          return [] unless @live.include?(%w[log_level])
          Log.level = Speaker.log_level(@candidate)
          ["log_level is #{@candidate['log_level']} now"]
        rescue NoMethodError
          ["log_level is #{@candidate['log_level']} in the configuration, and nothing " \
           'created a logger to apply it to']
        end

        # The prefixes to withdraw and the ones to originate, worked out
        # **before** the Speaker is reconfigured, since it is the old
        # blocks that say what is there now.
        #
        # An attribute set is compared by its encoded octets, which is how
        # `AdjRibOut` compares one: `Export` and `originate_attribute`
        # both build a new `Path_attribute` every call, so two of them are
        # never the same object.
        def originate_operations
          return nil unless @live.any? { |p| p.first == 'originate' }
          was, now = originate_map(@running), originate_map(@candidate)
          { :withdraw => was.keys - now.keys,
            :originate => now.reject { |prefix, pa| was[prefix] && was[prefix].to_shex == pa.to_shex } }
        end

        def originate_map(config)
          map = {}
          Array(config['originate']).each do |block|
            next unless block.is_a?(Hash)
            pa = @speaker.originate_attribute(Config.stringify(block))
            Array(block['prefixes']).each { |p| map[p.to_s] = pa }
          end
          map
        end

        def apply_originate(ops)
          return [] if ops.nil?
          rib = @speaker.rib
          return [] if rib.nil?
          rib.synchronize do
            ours = rib.adj_rib_in(rib.local_peer)
            ops[:withdraw].each { |prefix| rib.withdraw(rib.local_peer, prefix) if ours[prefix] }
            ops[:originate].each { |prefix, pa| rib.originate(prefix, :path_attribute => pa) }
          end
          notes = []
          notes << "withdrew #{ops[:withdraw].join(', ')}" unless ops[:withdraw].empty?
          notes << "originated #{ops[:originate].keys.join(', ')}" unless ops[:originate].empty?
          notes
        end

        # **Stop then start, and not `clear`.** `Peer#clear` is an alias
        # for `stop`, which leaves the reconnect loop to dial again on its
        # own retry interval; the administrative pair is what a commit
        # wants, because it ends the session now and brings it back now
        # rather than in `retry` seconds. For a passive peer `admin_start`
        # is a permission and not a dial, which is the same thing
        # `peer.start` reports and what the notice above says.
        def apply_bounces
          @bounce.map do |peer|
            peer.admin_stop
            peer.admin_start
            "the session with #{peer.address} was bounced" \
              "#{peer.active? ? '' : ', and it is a passive peer, so it comes back when ' \
                                     'the peer next dials'}"
          end
        end

      end

    end

  end
end
