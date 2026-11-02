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

require "test/unit"
require 'bgp/events'

# The concurrency cases here assert **invariants and never counts or
# deadlines**. CLAUDE.md records a load sensitive bound in
# test/unit/rib/router_test.rb that passes alone and slips inside the full
# suite on a busy machine, and that is the shape avoided: every threaded
# case below joins its threads first and then asserts something that is
# true however the scheduler ran, such as "no sequence number repeats".
#
# **And racing threads proves less here than it looks like it does**,
# which is worth knowing before anyone adds another of these. Measured on
# 2026-11-01 by sabotage: moving the subscriber push or the sequence
# increment out of the lock and then racing 32 threads through 16000
# publishes produced a duplicate number in 0 of 40 runs and an
# out of order kept list in 0 of 40. MRI does not preempt between those
# bytecodes and its Mutex hands the lock to waiters in arrival order, so
# the two placements are behaviourally identical on this interpreter.
#
# So two cases below force the interleaving instead of racing for it, and
# **one claim has no test at all**: that `@seq += 1` sits inside the lock
# cannot be observed from outside, since the only way to tell is a lost
# update that MRI will not produce and a FIFO mutex hides. It is held by
# the comment on the line and by review. It is a latent defect rather
# than a live one: on an interpreter with real parallelism it would lose
# updates, which is why the line stays where it is.
class EventsTest < Test::Unit::TestCase
  include BGP

  def setup
    @events = BGP::Events.new
  end

  def pub(n, arg={})
    @events.publish({ :kind => :session, :message => "m#{n}",
                      :peer => '10.0.0.1', :data => { :n => n } }.merge(arg))
  end

  # ---- Event, the value object --------------------------------------

  def test_the_three_fields_that_do_the_work_are_separate
    ev = pub(1)
    assert_equal(:session, ev.kind)
    assert_equal({ :n => 1 }, ev.data)
    assert_equal('m1', ev.message)
    # The point of the split: the data is reachable without touching the
    # message, so rewording a message breaks no reader.
    assert_equal(1, ev.data[:n])
  end

  def test_to_h_is_the_shape_a_console_reads
    ev = pub(1, :level => :warn)
    h = ev.to_h
    assert_equal([:seq, :time, :level, :kind, :peer, :message, :data].sort,
                 h.keys.sort)
    assert_equal(1, h[:seq])
    assert_equal('warn', h[:level])
    assert_equal('session', h[:kind])
    assert_equal('10.0.0.1', h[:peer])
    assert_equal('m1', h[:message])
    assert_equal({ :n => 1 }, h[:data])
  end

  # The field is the peer and not 'interface', which is OSPF's word for a
  # circuit. A console maps one onto the other.
  def test_the_location_field_is_the_peer_and_not_an_interface
    assert(BGP::Event.members.include?(:peer))
    assert(!BGP::Event.members.include?(:interface))
  end

  # docs/routescope-labs.md item 6 of section 6 carries the key table a
  # console reads, taken out of routescope at a named commit. The table is
  # **discovered** here rather than listed, both ways, so a key renamed in
  # the document or in the class fails this. CLAUDE.md's rule: when a
  # document makes a claim a test could make, assert it, or it reads as
  # verified while drifting.
  #
  # What this cannot check is the claim behind the table, which is what
  # routescope does with those keys. That is a read of another repository
  # and the document says so.
  def test_to_h_answers_exactly_the_keys_the_design_document_names
    doc = File.expand_path('../../docs/routescope-labs.md', File.dirname(__FILE__))
    body = File.read(doc)
    section = body[/^6\. \*\*A structured event stream.*?(?=^\d+\. \*\*)/m]
    assert_not_nil(section, 'item 6 of section 6 is not in the document any more')
    rows = section.scan(/^\s*\|\s*`(\w+)`\s*\|/).flatten.collect { |k| k.to_sym }
    assert(rows.size >= 7, "the key table has #{rows.size} rows, which is too few")
    assert_equal(rows.sort, @events.publish(:kind => :log, :message => 'x').to_h.keys.sort,
                 'Event#to_h and the table in docs/routescope-labs.md disagree')
    assert(rows.include?(:peer), 'the document stopped naming peer')
    assert(!rows.include?(:interface), 'the document named interface, which is OSPF\'s word')
  end

  # ISO 8601 with milliseconds in UTC, which is what the consumer reads.
  # Written out rather than compared against Time#iso8601, since the point
  # is that this file needs no require to produce it.
  def test_iso_time
    ev = @events.publish(:kind => :log, :message => 'x',
                         :time => Time.utc(2026, 11, 1, 22, 13, 20, 500_000))
    assert_equal('2026-11-01T22:13:20.500Z', ev.iso_time)
    assert_equal('2026-11-01T22:13:20.500Z', ev.to_h[:time])
  end

  def test_a_time_in_another_zone_is_answered_in_utc
    t = Time.new(2026, 11, 1, 22, 13, 20, '+05:00')
    ev = @events.publish(:kind => :log, :message => 'x', :time => t)
    assert_equal('2026-11-01T17:13:20.000Z', ev.iso_time)
  end

  def test_an_empty_data_is_a_hash_and_not_nil
    assert_equal({}, @events.publish(:kind => :log, :message => 'x').to_h[:data])
  end

  # An Event is not a wire object and deliberately does not answer
  # to_hash, which in this library means a hash that rebuilds its object
  # and which to_hash_catalog.rb measures by comparing #encode.
  def test_an_event_answers_to_h_and_not_to_hash
    assert(BGP::Event.method_defined?(:to_h))
    assert(!BGP::Event.method_defined?(:to_hash))
    assert(!BGP::Event.method_defined?(:encode))
  end

  def test_to_s_is_one_line_for_a_person
    ev = pub(1)
    assert_match(/info session 10\.0\.0\.1 m1\z/, ev.to_s)
  end

  # ---- publish -------------------------------------------------------

  def test_the_sequence_starts_at_one_and_counts_up
    assert_equal(0, @events.seq)
    assert_equal(1, pub(1).seq)
    assert_equal(2, pub(2).seq)
    assert_equal(2, @events.seq)
  end

  def test_the_default_level_is_info_and_the_default_kind_is_log
    ev = @events.publish(:message => 'x')
    assert_equal(:info, ev.level)
    assert_equal(:log, ev.kind)
  end

  # A kind is what a program switches on, so a typo makes an event no
  # reader can filter for. Refused rather than published.
  def test_an_unknown_kind_is_refused
    e = assert_raise(ArgumentError) { @events.publish(:kind => :nonesuch, :message => 'x') }
    assert_match(/unknown event kind :nonesuch/, e.message)
    assert_match(/register_kind/, e.message)
    assert_equal(0, @events.seq, 'a refused publish must not consume a number')
  end

  def test_register_kind_declares_one
    assert(!BGP::Events::KINDS.include?(:route_for_this_test))
    BGP::Events.register_kind(:route_for_this_test)
    assert_equal(:route_for_this_test,
                 @events.publish(:kind => :route_for_this_test, :message => 'x').kind)
    # Registering twice is not two entries.
    BGP::Events.register_kind(:route_for_this_test)
    assert_equal(1, BGP::Events::KINDS.count(:route_for_this_test))
  ensure
    BGP::Events::KINDS.delete(:route_for_this_test)
  end

  def test_the_kinds_this_pull_request_publishes_are_registered
    [:session, :notification, :log, :overflow].each do |k|
      assert(BGP::Events::KINDS.include?(k), "#{k} is not a registered kind")
    end
  end

  # ---- the bounded list ----------------------------------------------

  def test_the_kept_list_is_bounded_under_a_flood
    events = BGP::Events.new(:backlog => 10)
    1000.times { |i| events.publish(:kind => :log, :message => "m#{i}") }
    assert_equal(10, events.size)
    assert_equal(1000, events.seq, 'the sequence counts every event, kept or not')
    # The newest ten, and in order.
    assert_equal((991..1000).to_a, events.since(0).reject { |e| e.seq.nil? }.collect(&:seq))
  end

  def test_the_default_backlog_is_the_constant
    assert_equal(BGP::Events::BACKLOG, BGP::Events.new.backlog_limit)
    assert_equal(17, BGP::Events.new(:backlog => 17).backlog_limit)
    assert_equal(17, BGP::Events.new(:max_queue => 17).queue_limit)
  end

  # ---- option names are refused, not ignored ------------------------
  #
  # Each of these was measured doing the wrong thing quietly before the
  # check went in, and the answers are in the assertion messages. An
  # ignored option name is a wrong answer and not a missing one, which is
  # why this is four cases and not one.

  def test_an_unknown_constructor_option_is_refused
    e = assert_raise(ArgumentError) { BGP::Events.new(:limit => 3) }
    assert_match(/unknown option :limit/, e.message)
    # The message names what the method does take, as publish's does.
    assert_match(/:backlog/, e.message)
    assert_match(/:max_queue/, e.message)
  end

  # It took the default backlog of 2000 and said nothing, so since
  # answered short with no overflow and nothing looked wrong.
  def test_the_constructor_option_typo_no_longer_takes_the_default
    assert_raise(ArgumentError) { BGP::Events.new(:backlogg => 3) }
    assert_equal(3, BGP::Events.new(:backlog => 3).backlog_limit)
  end

  # It published an event with an empty message.
  def test_an_unknown_publish_option_is_refused
    e = assert_raise(ArgumentError) { @events.publish(:kind => :log, :mesage => 'x') }
    assert_match(/unknown option :mesage/, e.message)
    assert_equal(0, @events.seq, 'a refused publish must not consume a number')
  end

  # The worst of the four: :kind singular built a subscription with no
  # filter at all, so a reader asking for one kind got every kind.
  def test_an_unknown_subscribe_option_is_refused
    e = assert_raise(ArgumentError) { @events.subscribe(:kind => [:notification]) }
    assert_match(/unknown option :kind/, e.message)
    assert_match(/:kinds/, e.message)
    assert_equal(0, @events.subscribers, 'a refused subscribe must not register one')
  end

  # It waited for ever, which reads as a stream that went quiet.
  def test_an_unknown_pop_option_is_refused
    sub = @events.subscribe
    e = assert_raise(ArgumentError) { sub.pop(:timeouts => 1) }
    assert_match(/unknown option :timeouts/, e.message)
    assert_match(/:timeout/, e.message)
  ensure
    sub.close if sub
  end

  def test_the_options_a_method_does_take_are_accepted
    assert_nothing_raised do
      ev = BGP::Events.new(:backlog => 5, :max_queue => 5)
      ev.publish(:kind => :log, :level => :warn, :time => Time.now,
                 :peer => '10.0.0.1', :message => 'x', :data => { :a => 1 })
      ev.subscribe(:kinds => [:log], :since => 0).pop(:timeout => 0.01)
    end
  end

  def test_something_that_is_not_a_hash_is_refused
    e = assert_raise(ArgumentError) { BGP::Events.new(7) }
    assert_match(/expected a Hash of options/, e.message)
  end

  # ---- since, and the synthetic overflow -----------------------------

  def test_since_answers_what_is_above_the_number
    3.times { |i| pub(i) }
    assert_equal([2, 3], @events.since(1).collect(&:seq))
    assert_equal([], @events.since(3))
    assert_equal([], @events.since(99))
  end

  def test_since_with_no_argument_is_everything_kept
    3.times { |i| pub(i) }
    assert_equal([1, 2, 3], @events.since.collect(&:seq))
  end

  # The assertion this file exists for. A reader resuming from a number
  # that has fallen off the end is told it missed events rather than
  # quietly handed a short list, because a short list cannot be told from
  # a quiet lab.
  def test_a_reader_resuming_from_a_number_that_fell_off_the_end_gets_an_overflow
    events = BGP::Events.new(:backlog => 3)
    5.times { |i| events.publish(:kind => :log, :message => "m#{i}") }
    answer = events.since(0)
    first = answer.first
    assert_equal(:overflow, first.kind)
    assert_nil(first.seq, 'a synthetic event carries no sequence number')
    assert_equal(:warn, first.level)
    assert_equal('backlog', first.data[:reason])
    assert_equal(2, first.data[:lost], 'events 1 and 2 are gone')
    assert_equal(0, first.data[:since])
    assert_equal(3, first.data[:first_kept])
    assert_equal(3, first.data[:keeps])
    assert_equal([3, 4, 5], answer[1..-1].collect(&:seq))
  end

  def test_a_reader_still_inside_the_backlog_gets_no_overflow
    events = BGP::Events.new(:backlog => 3)
    5.times { |i| events.publish(:kind => :log, :message => "m#{i}") }
    # 3 is the oldest kept, so resuming from 2 misses nothing.
    assert_equal([], events.since(2).select { |e| e.kind == :overflow })
    assert_equal([3, 4, 5], events.since(2).collect(&:seq))
  end

  def test_the_boundary_is_the_oldest_kept_minus_one
    events = BGP::Events.new(:backlog => 3)
    5.times { |i| events.publish(:kind => :log, :message => "m#{i}") }
    assert_equal([], events.since(2).select { |e| e.kind == :overflow },
                 'resuming from the one before the oldest kept loses nothing')
    assert_equal(1, events.since(1).select { |e| e.kind == :overflow }.size,
                 'one further back has lost exactly one')
    assert_equal(1, events.since(1).first.data[:lost])
  end

  def test_an_empty_stream_answers_nothing_and_no_overflow
    assert_equal([], @events.since(0))
    assert_equal([], @events.since)
    assert_equal(0, @events.size)
  end

  # ---- subscribe -----------------------------------------------------

  def test_a_subscriber_gets_what_is_published_after_it_subscribed
    sub = @events.subscribe
    assert_equal(1, @events.subscribers)
    pub(1)
    pub(2)
    assert_equal([1, 2], [sub.pop(:timeout => 1).seq, sub.pop(:timeout => 1).seq])
    assert_nil(sub.pop(:timeout => 0.01), 'nothing left')
  end

  def test_subscribe_with_since_replays_first
    3.times { |i| pub(i) }
    sub = @events.subscribe(:since => 1)
    assert_equal(2, sub.size)
    assert_equal([2, 3], [sub.pop(:timeout => 1).seq, sub.pop(:timeout => 1).seq])
  end

  def test_subscribe_without_since_replays_nothing
    3.times { |i| pub(i) }
    assert_equal(0, @events.subscribe.size)
  end

  def test_a_kind_filter_keeps_the_other_kinds_out
    sub = @events.subscribe(:kinds => [:notification])
    pub(1)
    n = @events.publish(:kind => :notification, :message => 'n')
    assert_equal(n.seq, sub.pop(:timeout => 1).seq)
    assert_nil(sub.pop(:timeout => 0.01))
  end

  def test_a_kind_filter_takes_one_kind_or_a_list
    assert_equal([:session], @events.subscribe(:kinds => :session).kinds)
    assert_equal([:session, :log], @events.subscribe(:kinds => [:session, :log]).kinds)
    assert_nil(@events.subscribe.kinds, 'no filter means every kind')
  end

  # A subscription for a kind nobody publishes is silent forever, and
  # silence cannot be told from a quiet lab, so the typo is refused.
  def test_subscribing_to_an_unknown_kind_is_refused
    e = assert_raise(ArgumentError) { @events.subscribe(:kinds => [:session, :nope]) }
    assert_match(/unknown event kind :nope/, e.message)
    assert_equal(0, @events.subscribers)
  end

  def test_unsubscribe_and_close
    sub = @events.subscribe
    assert_equal(1, @events.subscribers)
    sub.close
    assert(sub.closed?)
    assert_equal(0, @events.subscribers)
    pub(1)
    assert_equal(0, sub.size, 'a closed subscription takes nothing more')
    assert_nil(sub.pop(:timeout => 0.01), 'and answers at once rather than waiting')
  end

  def test_unsubscribe_by_itself
    sub = @events.subscribe
    @events.unsubscribe(sub)
    assert_equal(0, @events.subscribers)
    pub(1)
    assert_equal(0, sub.size)
  end

  # ---- the subscriber queue, and its own overflow --------------------

  def test_a_slow_subscriber_loses_its_oldest_and_is_told
    events = BGP::Events.new(:max_queue => 3)
    sub = events.subscribe
    6.times { |i| events.publish(:kind => :log, :message => "m#{i}") }
    assert_equal(3, sub.size, 'the queue is bounded')
    assert_equal(3, sub.missed)
    ev = sub.pop(:timeout => 1)
    assert_equal(:overflow, ev.kind)
    assert_nil(ev.seq)
    assert_equal('queue', ev.data[:reason])
    assert_equal(3, ev.data[:lost])
    assert_equal(0, sub.missed, 'reported once')
    # Then the three it still has, the newest.
    assert_equal([4, 5, 6], [sub.pop(:timeout => 1).seq, sub.pop(:timeout => 1).seq,
                             sub.pop(:timeout => 1).seq])
  end

  # The queue side overflow is built inside pop and so never meets the
  # kind filter at all. Worth a case of its own because that is a
  # different mechanism from the one below, and reading them as one would
  # leave the one below untested.
  def test_a_filtered_reader_is_still_told_its_queue_overflowed
    events = BGP::Events.new(:max_queue => 2)
    sub = events.subscribe(:kinds => [:session])
    5.times { |i| events.publish(:kind => :session, :message => "m#{i}") }
    ev = sub.pop(:timeout => 1)
    assert_not_nil(ev)
    assert_equal(:overflow, ev.kind)
  end

  # The backlog side overflow is pushed like any other event, so it does
  # meet the filter, and Subscription#wants? has to let it past.
  # Otherwise a reader's own filter turns a gap back into quiet, which is
  # the one thing the overflow event exists to prevent.
  def test_a_replayed_overflow_passes_a_kind_filter_it_does_not_match
    events = BGP::Events.new(:backlog => 2)
    5.times { |i| events.publish(:kind => :session, :message => "m#{i}") }
    sub = events.subscribe(:kinds => [:notification], :since => 0)
    assert_equal(1, sub.size, 'the overflow did not reach a filtered reader')
    ev = sub.pop(:timeout => 1)
    assert_not_nil(ev)
    assert_equal(:overflow, ev.kind)
    assert_equal('backlog', ev.data[:reason])
  end

  def test_wants_lets_an_overflow_past_any_filter
    sub = @events.subscribe(:kinds => [:notification])
    assert(sub.wants?(BGP::Event.overflow(:backlog, 1)))
    assert(!sub.wants?(@events.publish(:kind => :session, :message => 'x')))
  end

  # ---- listeners -----------------------------------------------------

  def test_on_event_calls_the_block
    seen = []
    @events.on_event { |ev| seen << ev.seq }
    pub(1)
    pub(2)
    assert_equal([1, 2], seen)
  end

  def test_remove_event_listener
    seen = []
    block = @events.on_event { |ev| seen << ev.seq }
    pub(1)
    @events.remove_event_listener(block)
    pub(2)
    assert_equal([1], seen)
  end

  # The property Neighbor#on_state_change already has and this must keep:
  # nothing a listener does can reach the caller, which is a session's own
  # thread.
  def test_a_listener_that_raises_stops_neither_the_others_nor_the_caller
    seen = []
    @events.on_event { |_ev| raise 'first listener' }
    @events.on_event { |ev| seen << ev.seq }
    @events.on_event { |_ev| raise ArgumentError, 'third listener' }
    ev = nil
    assert_nothing_raised { ev = pub(1) }
    assert_equal(1, ev.seq, 'publish still answered its event')
    assert_equal([1], seen, 'the listener after the raising one still ran')
    assert_equal(2, @events.listener_errors)
    # And the event is in the stream, so a failing listener loses nothing.
    assert_equal([1], @events.since(0).collect(&:seq))
  end

  def test_a_listener_may_publish_without_deadlocking
    @events.on_event do |ev|
      @events.publish(:kind => :log, :message => 'from a listener') if ev.kind == :session
    end
    pub(1)
    assert_equal([:session, :log], @events.since(0).collect(&:kind))
  end

  # ---- concurrency: invariants only ----------------------------------

  # No duplicate and no missing sequence number, however the threads
  # interleaved. The set is the assertion; no count of threads or of time
  # appears in it.
  def test_sequence_numbers_never_repeat_and_never_go_backwards
    threads, per = 8, 200
    seqs = Array.new(threads) { [] }
    ts = (0...threads).collect do |t|
      Thread.new do
        per.times { |i| seqs[t] << @events.publish(:kind => :log, :message => "t#{t}-#{i}").seq }
      end
    end
    ts.each(&:join)
    all = seqs.flatten
    assert_equal(threads * per, all.size)
    assert_equal(all.size, all.uniq.size, 'a sequence number was handed out twice')
    assert_equal((1..threads * per).to_a, all.sort, 'the numbers are exactly 1..n')
    assert_equal(threads * per, @events.seq)
    # Within one thread they only ever increase.
    seqs.each { |s| assert_equal(s.sort, s, 'one publisher saw its numbers out of order') }
  end

  # A reader's queue is in sequence order, and that is why publish pushes
  # to the subscriber queues while it holds the lock.
  #
  # **Deterministic, and it has to be.** Measured on 2026-11-01: moving
  # that push outside the lock and then racing eight threads against it
  # reordered nothing in 40 runs of 16000 publishes each. MRI does not
  # preempt between those bytecodes and its Mutex hands the lock to
  # waiters in arrival order, so a probabilistic test cannot hold this
  # claim however many threads it is given. The racing case below is kept
  # for what it does prove; this one forces the interleaving instead,
  # with a subscriber whose push blocks per sequence number, released in
  # the wrong order.
  def test_the_subscriber_push_happens_under_the_lock
    events = BGP::Events.new
    gates = { 1 => Queue.new, 2 => Queue.new }
    blocker = events.subscribe
    # Blocks without holding any lock of its own, so the only lock in play
    # is the one under test.
    blocker.define_singleton_method(:push) { |ev| gates[ev.seq] && gates[ev.seq].pop ; nil }
    observer = events.subscribe
    a = Thread.new { events.publish(:kind => :log, :message => 'a') }
    # Waits on a condition and not on a clock: each publisher has to have
    # reached its gate, or the token released below is not the one it is
    # waiting on.
    Thread.pass until a.status == 'sleep' or not a.alive?
    b = Thread.new { events.publish(:kind => :log, :message => 'b') }
    Thread.pass until b.status == 'sleep' or not b.alive?
    # The second publish is released first. With the push under the lock,
    # b has no sequence number yet and nothing is waiting on gate 2, so
    # this token is simply left there for it.
    gates[2] << :go
    gates[1] << :go
    [a, b].each { |t| t.join(20) }
    got = []
    got << observer.pop(:timeout => 1).seq while observer.size > 0
    assert_equal([1, 2], got,
                 'a reader saw the events out of sequence: the push is ' \
                 'outside the lock')
  ensure
    gates.each_value { |q| q << :go } if gates
    blocker.close if blocker
    observer.close if observer
  end

  # What racing does prove: no number is handed out twice and none is
  # missing. It does **not** prove where the lock sits, for the reason on
  # the test above, so do not read a green run here as holding that.
  def test_a_subscribers_queue_is_in_sequence_order_under_concurrent_publishes
    events = BGP::Events.new(:max_queue => 10_000)
    sub = events.subscribe
    ts = (0...8).collect do |t|
      Thread.new { 200.times { |i| events.publish(:kind => :log, :message => "t#{t}-#{i}") } }
    end
    ts.each(&:join)
    got = []
    while (ev = sub.pop(:timeout => 0.01))
      got << ev.seq
    end
    assert_equal(1600, got.size, 'a queue big enough to hold them all lost none')
    assert_equal(got.sort, got, 'the queue is not in sequence order')
    assert_equal(0, sub.missed)
  end

  # Publishing must not block a session, so a subscriber nobody reads
  # cannot stall it. Asserted as "the publishes all happened and the queue
  # stayed at its bound", not as a deadline.
  def test_a_subscriber_nobody_reads_does_not_stop_publishing
    events = BGP::Events.new(:max_queue => 5, :backlog => 5)
    events.subscribe
    2000.times { |i| events.publish(:kind => :log, :message => "m#{i}") }
    assert_equal(2000, events.seq)
    assert_equal(5, events.size)
  end

  def test_several_readers_each_get_their_own_copy
    a = @events.subscribe
    b = @events.subscribe(:kinds => [:log])
    pub(1)
    @events.publish(:kind => :log, :message => 'l')
    assert_equal([1, 2], [a.pop(:timeout => 1).seq, a.pop(:timeout => 1).seq])
    assert_equal(2, b.pop(:timeout => 1).seq)
    assert_nil(b.pop(:timeout => 0.01))
  end

  # close takes its own lock, releases it, and only then takes the Events
  # lock. Nesting them the other way round deadlocks against publish,
  # which holds the Events lock and takes the subscription's.
  #
  # **Deterministic, for the reason the push test above gives.** Racing a
  # publisher against eight closers hit the inversion in none of 40 runs,
  # so the interleaving is forced instead: a publisher parked inside the
  # Events lock, then a close, then the publisher let go on into the
  # subscription whose lock the close is holding.
  #
  # The join timeout is the escape from the hang a real deadlock is, not
  # a bound on the work. The assertion is that neither thread is still
  # alive, which no amount of load changes.
  def test_close_does_not_nest_the_two_locks
    events = BGP::Events.new
    gate = Queue.new
    blocker = events.subscribe
    blocker.define_singleton_method(:push) { |_ev| gate.pop ; nil }
    sub = events.subscribe
    # The publisher now holds the Events lock and waits, so anything else
    # that wants that lock waits too.
    writer = Thread.new { events.publish(:kind => :log, :message => 'x') }
    Thread.pass until writer.status == 'sleep' or not writer.alive?
    # The close takes sub's own lock. Nesting the two, it then wants the
    # Events lock the publisher is holding, and keeps sub's.
    closer = Thread.new { sub.close }
    Thread.pass until closer.status == 'sleep' or not closer.alive?
    # And now the publisher wants sub's lock, on its way down the list.
    gate << :go
    [writer, closer].each { |t| t.join(10) }
    assert(!writer.alive?, 'the publisher is stuck: close nests the two locks')
    assert(!closer.alive?, 'close is stuck: it nests the two locks')
    assert_equal(1, events.seq)
  ensure
    gate << :go if gate
    blocker.close if blocker
  end
end
