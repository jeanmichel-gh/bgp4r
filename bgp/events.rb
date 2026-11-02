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

# Log, for a listener that raises. bgp/common.rb defines it.
require 'bgp/common'

module BGP

  # One event, as a console reads it.
  #
  # **Three fields do the work and they are not interchangeable.** +kind+
  # is a Symbol a program switches on. +data+ is a Hash of the fields
  # behind it, so a program need not parse anything. +message+ is for a
  # person and nothing parses it, so rewording one breaks no reader. That
  # split is the whole point of this file: a console that has to match a
  # regexp against a message string is a console that breaks the next time
  # somebody improves the wording.
  #
  # +peer+ is this library's answer to the column a console keeps for
  # where an event happened. routescope calls that column the interface,
  # which is OSPF's word for a circuit; BGP has no circuits and a peer is
  # named by its address (see "A peer is identified by its address" in
  # CLAUDE.md), so the field here is the peer and **a console maps it onto
  # its own column**. Naming it +interface+ in bgp4r would be borrowing
  # another protocol's vocabulary for a thing it does not have.
  #
  # +seq+ is assigned by Events and is **nil on a synthetic event**, which
  # is how an :overflow says it is not part of the sequence. A reader
  # tracking the last number it saw leaves its cursor alone for one of
  # those.
  Event = Struct.new(:seq, :time, :level, :kind, :peer, :message, :data) do

    # ISO 8601 with milliseconds, in UTC: "2026-11-01T22:13:20.000Z".
    #
    # strftime and not Time#iso8601, which would need require 'time'.
    # Conventions in CLAUDE.md records a standard library becoming a
    # bundled gem twice, once killing a CI job before a test ran, and a
    # format string needs nothing at all.
    def iso_time
      time.utc.strftime('%Y-%m-%dT%H:%M:%S.%LZ')
    end

    # The record as plain data, ready for whatever serialises it.
    #
    # It overrides Struct#to_h on purpose: what a reader wants is the shape
    # a console reads, with the time as a string, and not the members.
    #
    # **Named to_h and not to_hash, and that is a decision rather than a
    # style.** A +to_hash+ in this library is a hash that rebuilds its
    # object through +new+, and test/unit/to_hash_catalog.rb measures every
    # one of them by comparing #encode before and after. An Event has no
    # #encode and is not a wire object, so the only way to satisfy that
    # machinery would be to give it one, which would claim it is.
    #
    # There is deliberately no #to_json here either. Whether +json+ is a
    # default gem is a per Ruby version question, which Conventions
    # records biting twice, and serialising belongs to whatever serves the
    # socket or the HTTP API. Neither exists yet. JSON.generate(ev.to_h)
    # is one line in the program that does.
    def to_h
      { :seq     => seq,
        :time    => iso_time,
        :level   => level.to_s,
        :kind    => kind.to_s,
        :peer    => peer,
        :message => message,
        :data    => data || {} }
    end

    def to_s
      "#{iso_time} #{level} #{kind}#{peer ? " #{peer}" : ''} #{message}"
    end

    # A synthetic overflow event, carrying no sequence number of its own.
    #
    # **Two reasons, and a reader wants to know which**, because they ask
    # different things of it: :backlog means the kept list had already
    # rolled past the number asked for, so the reader resumed too late,
    # and :queue means this reader is not keeping up with the stream.
    def self.overflow(reason, lost, data={})
      text = reason == :backlog ?
             "#{lost} event(s) missed: they are no longer kept" :
             "#{lost} event(s) dropped: reading too slowly"
      new(nil, Time.now, :warn, :overflow, nil, text,
          { :reason => reason.to_s, :lost => lost }.merge(data))
    end
  end

  # A sequenced, bounded event stream, so something outside bgp4r can read
  # a timeline of what a session did.
  #
  #   events = BGP::Events.new
  #   events.publish(:kind => :session, :peer => '10.0.0.1',
  #                  :message => 'Active -> Established',
  #                  :data => { :state => :Established })
  #   events.since(0)                 # every kept event, in order
  #   sub = events.subscribe          # a reader that waits
  #   sub.pop(:timeout => 5)
  #
  # **Publishing never blocks and never raises into its caller's thread.**
  # The first caller is a BGP finite state machine: Neighbor runs its state
  # listeners outside its mutex with exceptions logged rather than raised,
  # deliberately, so nothing outside can kill the FSM, and a stream hung
  # off that same path has to keep the property. So the backlog drops its
  # oldest when it is full, a subscriber that reads too slowly loses its
  # oldest and is told so, and a listener that raises is caught.
  #
  # **Two locks, and the order between them is one way.** publish holds
  # this object's lock and takes each Subscription's; Subscription#close
  # releases its own before it calls unsubscribe. Do not move that call
  # inside the synchronize block: nesting it the other way is a deadlock,
  # and it is the kind of thing a later edit does by tidying.
  class Events

    # Kept events, and the most a subscriber may fall behind. Both are per
    # instance, so a test uses a small number instead of flooding, and the
    # defaults are ospfv2's, which has run them in a daemon.
    BACKLOG   = 2000
    MAX_QUEUE = 10_000

    # The kinds a program may switch on.
    #
    # Only what is published today, plus :log as the catch-all and
    # :overflow which is synthetic. A kind for work that does not exist is
    # anticipation, which this repository has decided against twice over a
    # registry; register_kind is the growth path, shaped on Attr.register,
    # so the daemon declares :route and :fault when it has them rather
    # than editing this list.
    KINDS = [:session, :notification, :log, :overflow]

    # Declares a kind. A kind is a published name a program switches on,
    # so a later layer adds its own here. Returns the Symbol.
    def self.register_kind(kind)
      k = kind.to_sym
      KINDS << k unless KINDS.include?(k)
      k
    end

    # Refuses an option name the caller's method does not read, and
    # answers the Hash so a caller can use it inline.
    #
    # **Every option Hash in this file goes through it, and the reason is
    # that an ignored option name is a wrong answer and not a missing
    # one.** `Events.new(:limit => 3)` took the default backlog of 2000
    # and said nothing, so a reader asking `since` got a short answer and
    # no overflow and nothing anywhere was wrong. Worse,
    # `subscribe(:kind => [:notification])`, singular, built a
    # subscription with **no filter at all**, so a console asking for one
    # kind quietly got every kind. Conventions let a constructor refuse an
    # input it cannot represent "because the alternative is silently
    # sending a different value", and an option name in place of a field
    # value is that case.
    #
    # **A hand written check and not keyword arguments, which would have
    # given the same refusal for free.** `def initialize(backlog:
    # BACKLOG, max_queue: MAX_QUEUE)` raises `unknown keyword: :limit`
    # with no code to maintain, and that is a real argument for it. Three
    # things decided against. Every constructor in bgp4r takes `arg={}`,
    # so this would be the first that does not, and `Subscription#new`
    # sits in this same file taking positional arguments, so the file
    # would carry two conventions across twenty lines. The refusal here
    # names **what the method does take**, which `unknown keyword` does
    # not, and that is the shape `publish` already answers an unknown
    # kind with, so a reader meets one message and not two. And `pop` and
    # `publish` are called with a Hash a program built at runtime, which
    # is how `Neighbor#set` is written; keywords would make every such
    # caller splat. The cost is the line below, and that it has to be
    # edited when an option is added. That is the trade, stated so nobody
    # re-litigates it from the free-refusal half alone.
    def self.check_options(arg, *known)
      return arg if arg.nil?
      raise ArgumentError, "expected a Hash of options, got #{arg.class}" unless arg.is_a?(Hash)
      unknown = arg.keys - known
      return arg if unknown.empty?
      raise ArgumentError,
            "unknown option #{unknown.collect { |k| k.inspect }.join(', ')}; " \
            "this takes #{known.collect { |k| k.inspect }.join(', ')}"
    end

    attr_reader :backlog_limit, :queue_limit

    # :backlog and :max_queue override BACKLOG and MAX_QUEUE. Any other
    # option name is refused; see check_options.
    def initialize(arg={})
      Events.check_options(arg, :backlog, :max_queue)
      @backlog_limit   = arg[:backlog]   || BACKLOG
      @queue_limit     = arg[:max_queue] || MAX_QUEUE
      @seq             = 0
      @kept            = []
      @subscribers     = []
      @listeners       = []
      @listener_errors = 0
      @lock            = Mutex.new
    end

    # The number of the last event published, which is what a control API
    # answers so a reader knows where to resume from.
    def seq
      @lock.synchronize { @seq }
    end

    # How many events are kept.
    def size
      @lock.synchronize { @kept.size }
    end

    # How many times a listener raised. Logged as well, but a count is
    # what a test can assert on: CLAUDE.md records that an exception
    # swallowed in an observer is invisible, and that an observer with a
    # wrong constant therefore failed as "nothing was received" and said
    # nothing about the name.
    def listener_errors
      @lock.synchronize { @listener_errors }
    end

    # Publishes one event and returns it.
    #
    #   publish(:kind => :session, :level => :info, :peer => '10.0.0.1',
    #           :message => 'a line for a person', :data => { :state => :Idle })
    #
    # :time defaults to now, which is how a caller with its own clock
    # supplies one. :level is :debug, :info, :warn or :error.
    #
    # **Nothing here publishes at :debug, and that is ospfv2's rule kept
    # for its reason**: a per message debug line belongs in the log, since
    # kept in a bounded list it would push out the events people look for.
    # The level is accepted so a caller can choose; the discipline is the
    # caller's.
    def publish(arg={})
      Events.check_options(arg, :kind, :level, :time, :peer, :message, :data)
      kind = (arg[:kind] || :log).to_sym
      unless KINDS.include?(kind)
        raise ArgumentError,
              "unknown event kind #{kind.inspect}; declare it with " \
              "Events.register_kind or use one of #{KINDS.inspect}"
      end
      ev = Event.new(nil, arg[:time] || Time.now, (arg[:level] || :info).to_sym,
                     kind, arg[:peer], arg[:message].to_s, arg[:data] || {})
      @lock.synchronize do
        @seq += 1
        ev.seq = @seq
        @kept << ev
        @kept.shift(@kept.size - @backlog_limit) if @kept.size > @backlog_limit
        # Inside the lock, so every subscriber's queue is in sequence
        # order. Outside it two threads could push out of order and a
        # reader tracking the last number it saw would go backwards.
        # Subscription#push never publishes, so there is no way back here.
        @subscribers.each { |s| s.push(ev) }
      end
      notify(ev)
      ev
    end

    # Every kept event numbered above +n+, in order. With no argument,
    # every kept event.
    #
    # **When +n+ is below what is still kept, the events between are gone
    # and the answer begins with a synthetic :overflow saying how many.**
    # That is the whole reason this is not Array#select: a reader handed a
    # short list cannot tell a gap from quiet, and a console that cannot
    # tell them apart shows a converged lab when it has only missed the
    # convergence.
    def since(n=nil)
      @lock.synchronize { _since(n) }
    end

    # A Subscription to events of :kinds (every kind when absent),
    # replaying the kept events above :since first when that is given.
    #
    #   events.subscribe(:kinds => [:session], :since => 0)
    #
    # An unknown kind is refused rather than filtered out. A subscription
    # for a kind nobody publishes is silent forever, and silence is
    # indistinguishable from a quiet lab, so a typo there is a wrong
    # answer rather than a missing one.
    def subscribe(arg={})
      # :kind, singular, is the typo this refusal exists for: it used to
      # build a subscription with no filter at all.
      Events.check_options(arg, :kinds, :since)
      kinds = arg[:kinds] && Array(arg[:kinds]).collect { |k| k.to_sym }
      if kinds
        unknown = kinds - KINDS
        unless unknown.empty?
          raise ArgumentError,
                "unknown event kind #{unknown.collect { |k| k.inspect }.join(', ')}; " \
                "kinds: #{KINDS.inspect}"
        end
      end
      @lock.synchronize do
        sub = Subscription.new(self, kinds, @queue_limit)
        _since(arg[:since]).each { |e| sub.push(e) } if arg.has_key?(:since)
        # Before it joins @subscribers, so the count is the replay and
        # nothing else. See Subscription#replayed.
        sub.replayed!
        @subscribers << sub
        sub
      end
    end

    def unsubscribe(sub)
      @lock.synchronize { @subscribers.delete(sub) }
      nil
    end

    def subscribers
      @lock.synchronize { @subscribers.size }
    end

    # Calls block with each Event as it is published, and returns the block
    # so it can be removed again.
    #
    # **The block runs outside this object's lock**, which is the choice
    # Neighbor#new_state makes for its state listeners and for the same
    # reason: it is arbitrary code, so holding the lock across it would let
    # one listener stall every session's publish, and a listener that
    # published would deadlock on a Mutex that is not reentrant. The cost
    # is that two concurrent publishes may call listeners in either order.
    # The **ordered** view is subscribe and since; a listener that cares
    # about order reads Event#seq.
    def on_event(&block)
      @lock.synchronize { @listeners << block }
      block
    end

    def remove_event_listener(block)
      @lock.synchronize { @listeners.delete(block) }
    end

    # One reader's events, waiting to be read.
    class Subscription

      attr_reader :kinds

      def initialize(events, kinds, limit)
        @events   = events
        @kinds    = kinds
        @limit    = limit
        @queue    = []
        @missed   = 0
        @replayed = 0
        @lock     = Mutex.new
        @ready    = ConditionVariable.new
        @closed   = false
      end

      # How many kept events were replayed into this subscription when it
      # was created, which is what a reader resuming from a sequence
      # number has to be told: it says whether anything came back, and a
      # synthetic :overflow among them says whether anything was lost.
      # 0 for a subscription created with no :since.
      #
      # **It lives here rather than in subscribe's return value, and that
      # is a decision with two things rejected.** ospfv2's equivalent
      # answers `[sub, replayed]` from its own subscribe, which is the
      # obvious shape and would break every caller here: `events
      # .subscribe` is documented and tested as answering a Subscription,
      # and an Array answers `pop(:timeout => 5)` with a TypeError rather
      # than an event, so the breakage would be loud and in the wrong
      # place. Counting in whatever serves the socket was the other
      # option, and it cannot be done without a race: the replay happens
      # inside Events' own lock, so a count taken after subscribe returns
      # may already include an event published since.
      attr_reader :replayed

      # Called by Events#subscribe, holding the Events lock, before this
      # subscription is in @subscribers. Nothing else can have pushed
      # into it, so what is queued is exactly the replay.
      def replayed!
        @lock.synchronize { @replayed = @queue.size }
      end

      # :overflow always passes the filter. A reader watching one kind
      # still has to be told it missed events, or its own filter turns a
      # gap back into quiet, which is what the overflow event exists to
      # prevent.
      def wants?(ev)
        ev.kind == :overflow or @kinds.nil? or @kinds.include?(ev.kind)
      end

      # Queues one event, dropping this reader's oldest when it is too far
      # behind. It never blocks: the caller is publish, on a session's own
      # thread.
      def push(ev)
        return nil unless wants?(ev)
        @lock.synchronize do
          return nil if @closed
          @queue << ev
          if @queue.size > @limit
            @queue.shift
            @missed += 1
          end
          @ready.signal
        end
        nil
      end

      # The next event, nil after :timeout seconds, or nil at once once
      # closed. After a loss, the :overflow event first.
      def pop(arg={})
        # Outside the lock: a refusal is the caller's mistake and has
        # nothing to do with the queue. A mis-spelled :timeout used to
        # wait for ever, which reads as a stream that went quiet.
        Events.check_options(arg, :timeout)
        @lock.synchronize do
          if @missed > 0
            n = @missed
            @missed = 0
            return Event.overflow(:queue, n)
          end
          @ready.wait(@lock, arg[:timeout]) if @queue.empty? and not @closed
          @queue.shift
        end
      end

      def size
        @lock.synchronize { @queue.size }
      end

      # Events lost because this reader was too slow and not yet reported.
      def missed
        @lock.synchronize { @missed }
      end

      def closed?
        @lock.synchronize { @closed }
      end

      # unsubscribe is called with this object's lock released. Taking the
      # two in that order is a deadlock against publish, which holds the
      # Events lock and takes this one.
      def close
        @lock.synchronize do
          @closed = true
          @queue.clear
          @ready.broadcast
        end
        @events.unsubscribe(self)
        nil
      end
    end

    private

    # since, for a caller that already holds the lock.
    def _since(n)
      return @kept.dup if n.nil?
      n = n.to_i
      n = 0 if n < 0
      kept = @kept.select { |e| e.seq > n }
      return kept if @kept.empty?
      first = @kept.first.seq
      return kept if n + 1 >= first
      [Event.overflow(:backlog, first - (n + 1),
                      :since => n, :first_kept => first,
                      :keeps => @backlog_limit)] + kept
    end

    def notify(ev)
      @lock.synchronize { @listeners.dup }.each do |block|
        begin
          block.call(ev)
        rescue => e
          # Counted and logged, not published. Publishing an event about it
          # would re-enter publish and the same listener would raise again.
          @lock.synchronize { @listener_errors += 1 }
          Log.warn "BGP::Events listener raised #{e.class}: #{e.message}"
        end
      end
    end

  end
end
