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

# What bgp4r-sim has sent, as data. Pure: no socket, no session and no
# message, so every key docs/daemon.md names is reachable here.
#
#   ruby -I. test/unit/sim/sent_test.rb

require 'test/unit'
require 'bgp/sim/sent'

class BGP_Sim_Sent_Test < Test::Unit::TestCase

  def sent ; @sent ||= BGP::Sim::Sent.new ; end

  def test_nothing_sent_answers_zeros_and_no_times
    s = sent.summary
    assert_equal(0, s[:prefixes_sent])
    assert_equal(0, s[:updates_sent])
    assert_nil(s[:started_at])
    assert_nil(s[:finished_at])
    assert_nil(s[:prefixes_per_second])
    assert_equal([], sent.feeds)
  end

  # The five keys docs/daemon.md names for the send side.
  def test_the_summary_answers_the_five_documented_keys
    sent.count('announce', 3)
    s = sent.summary
    %i[prefixes_sent updates_sent started_at finished_at prefixes_per_second].each do |k|
      assert(s.key?(k), "#{k} is missing from the summary")
    end
    assert_equal(3, s[:prefixes_sent])
    assert_equal(1, s[:updates_sent])
  end

  # A withdrawal is counted apart from an announcement, because a console
  # showing one number for both cannot say whether a feed is going out or
  # coming back.
  def test_a_withdrawal_is_counted_apart_from_an_announcement
    sent.count('announce', 5)
    sent.count('withdraw', 2)
    s = sent.summary
    assert_equal(5, s[:prefixes_sent])
    assert_equal(2, s[:prefixes_withdrawn])
    assert_equal(2, s[:updates_sent])
  end

  # A NOTIFICATION, a ROUTE-REFRESH and a replayed capture are messages
  # and none of them is an UPDATE of ours, so `updates_sent` must not
  # move: UPDATE_ACTIONS is what says which is which.
  def test_a_message_that_is_not_an_update_of_ours_is_counted_as_a_message
    sent.count('notification', 0)
    sent.count('refresh', 0)
    sent.count('replay', 0)
    s = sent.summary
    assert_equal(3, s[:messages_sent])
    assert_equal(0, s[:updates_sent])
    assert_equal(0, s[:prefixes_sent])
  end

  # The times are ISO 8601 in UTC with milliseconds, which is
  # Recorder.iso's format: one format for the send side and the receive
  # side, from one method.
  def test_the_times_are_the_recorders_own_format
    sent.count('announce', 1, 1, Time.utc(2026, 11, 2, 14, 30, 0))
    assert_equal('2026-11-02T14:30:00.000Z', sent.summary[:started_at])
    assert_equal(BGP::Daemon::Recorder.iso(Time.utc(2026, 11, 2)),
                 BGP::Sim::Sent.new.tap { |s| s.count('announce', 1, 1, Time.utc(2026, 11, 2)) }
                               .summary[:started_at])
  end

  def test_a_rate_is_prefixes_over_the_seconds_between_the_two_times
    t = Time.utc(2026, 11, 2, 14, 30, 0)
    sent.count('announce', 100, 1, t)
    sent.count('announce', 100, 1, t + 4)
    assert_equal(50.0, sent.summary[:prefixes_per_second])
  end

  # nil and not zero, which bgp/rib/view.rb's rule explains: a key with a
  # value is an answer, and "no time has passed" is not a rate of zero.
  def test_no_measurable_time_is_no_rate_rather_than_a_rate_of_zero
    t = Time.utc(2026, 11, 2)
    sent.count('announce', 10, 1, t)
    assert_nil(sent.summary[:prefixes_per_second])
    assert_nil(BGP::Sim::Sent.rate(10, t, t))
    assert_nil(BGP::Sim::Sent.rate(10, t, nil))
  end

  # **The one that matters for a console**: while a feed runs there is no
  # finished_at and no rate, so a reader cannot take a total off a feed
  # that is still going.
  def test_a_running_feed_has_no_finished_at_and_no_rate
    feed = sent.start_feed('announce', '11.0.0.0/28 x 300')
    sent.tick(feed, 50)
    assert_equal(true, sent.running?)
    assert_nil(sent.summary[:finished_at])
    assert_nil(sent.summary[:prefixes_per_second])
    assert_equal(1, sent.summary[:feeds_running])
    assert_equal(true, sent.feeds.first[:running])
    assert_nil(sent.feeds.first[:finished_at])
  end

  def test_a_finished_feed_carries_its_range_its_counts_and_its_rate
    t = Time.utc(2026, 11, 2, 14, 30, 0)
    feed = sent.start_feed('announce', '11.0.0.0/28 x 300', '10.0.0.2', t)
    6.times { |i| sent.tick(feed, 50, 1, t + i + 1) }
    sent.finish_feed(feed, nil, t + 6)
    row = sent.feeds.first
    assert_equal('11.0.0.0/28 x 300', row[:range])
    assert_equal('10.0.0.2', row[:peer])
    assert_equal(300, row[:prefixes_sent])
    assert_equal(6, row[:updates_sent])
    assert_equal(50.0, row[:prefixes_per_second])
    assert_equal(false, row[:running])
    assert_equal(false, sent.running?)
    assert_not_nil(sent.summary[:finished_at])
  end

  # A feed that fell over keeps how far it got, because that is the
  # interesting part, and says why.
  def test_a_feed_that_failed_keeps_its_counts_and_says_why
    feed = sent.start_feed('announce', '11.0.0.0/28 x 300')
    sent.tick(feed, 50)
    sent.finish_feed(feed, 'BGP::Daemon::NoSession: session closed')
    row = sent.feeds.first
    assert_equal(50, row[:prefixes_sent])
    assert_match(/NoSession/, row[:error])
    assert_equal(false, row[:running])
  end

  def test_a_feeds_prefixes_are_in_the_totals_too
    feed = sent.start_feed('withdraw', '11.0.0.0/28 x 100')
    sent.tick(feed, 100)
    sent.finish_feed(feed)
    assert_equal(100, sent.summary[:prefixes_withdrawn])
    assert_equal(1, sent.summary[:updates_sent])
    assert_equal(1, sent.summary[:feeds])
  end

  def test_feeds_are_numbered_from_one
    a = sent.start_feed('announce', 'a')
    b = sent.start_feed('announce', 'b')
    assert_equal([1, 2], [a.id, b.id])
  end

  # **One lock and a Feed with none of its own**, which is what keeps
  # this free of the two-lock deadlock bgp/events.rb records. Several
  # threads ticking one feed while another reads the summary is the
  # arrangement a generated feed really runs in.
  def test_many_threads_ticking_while_another_reads
    feeds = Array.new(4) { |i| sent.start_feed('announce', "feed #{i}") }
    readers = 2.times.collect { Thread.new { 200.times { sent.summary ; sent.feeds } } }
    writers = feeds.collect { |f| Thread.new { 250.times { sent.tick(f, 1) } } }
    (writers + readers).each(&:join)
    feeds.each { |f| sent.finish_feed(f) }
    assert_equal(1000, sent.summary[:prefixes_sent])
    assert_equal(1000, sent.summary[:updates_sent])
    assert_equal([250] * 4, sent.feeds.collect { |f| f[:prefixes_sent] })
  end

  def test_to_h_is_the_summary_and_the_feeds
    feed = sent.start_feed('announce', 'a')
    sent.tick(feed, 1)
    h = sent.to_h
    assert_equal([:summary, :feeds], h.keys)
    assert_equal(1, h[:feeds].size)
  end

end
