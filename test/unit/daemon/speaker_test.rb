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

# What the extraction out of lab/speaker.rb has to keep true, and the
# three things the daemon added to the shared classes.
#
# **Most of this file's subject is tested elsewhere and deliberately
# not repeated here.** The session loop, the node file keys, router
# mode and the state file are covered by
# test/functional/lab/speaker_test.rb and
# test/functional/lab/speaker_router_test.rb, which pass unchanged and
# are what says the move changed no behaviour. What is here is the
# contract of the move itself, which neither of those can see: that
# lab/speaker.rb holds no second copy, and that the names it used to
# define are the same objects.
#
#   ruby -I. test/unit/daemon/speaker_test.rb

require 'test/unit'
require 'bgp/daemon/speaker'
require 'lab/speaker'

class BGP_Daemon_Speaker_Test < Test::Unit::TestCase

  LAB_FILE = File.expand_path('../../../lab/speaker.rb', __dir__)

  def speaker(extra = {})
    BGP::Daemon::Speaker.new({ 'as' => 65_000, 'router_id' => '10.0.0.1',
                               'neighbors' => [{ 'address' => '10.0.0.2', 'as' => 65_001 }] }.merge(extra))
  end

  # The three names lab/speaker.rb used to define are these classes and
  # not copies of them, which is what lets every topology and every lab
  # test that names Lab::Speaker keep working.
  def test_the_lab_names_are_these_classes
    assert_same(BGP::Daemon::Speaker, Lab::Speaker)
    assert_same(BGP::Daemon::Peer, Lab::Peer)
    assert_same(BGP::Daemon::Recorder, Lab::Recorder)
  end

  # Read as text, because that is the only way to say a file defines
  # nothing: assert_same above would pass just as well against a second
  # copy that happened to be assigned over the first.
  def test_the_lab_file_defines_no_class_of_its_own
    src = File.read(LAB_FILE)
    assert_equal([], src.scan(/^\s*class\s+\w/),
                 'lab/speaker.rb must hold no class: the machinery is in bgp/daemon/speaker.rb')
    assert_match(/^require 'bgp\/daemon\/speaker'$/, src)
  end

  # start and stop are split out of run so a program can own its own
  # main loop; bgp4rd's does. A run that did the work inline rather than
  # calling them would let the two drift.
  def test_run_is_built_from_start_and_stop
    src = File.read(File.expand_path('../../../bgp/daemon/speaker.rb', __dir__))
    body = src[/^      def run\n(.*?)^      end$/m, 1]
    assert_not_nil(body, 'Speaker#run must still be there')
    assert_match(/^        start$/, body)
    assert_match(/^        stop$/, body)
  end

  # One Events for every session, so the sequence numbers are one
  # ordered timeline across peers rather than N streams each numbering
  # from 1. A Neighbor builds its own when nobody hands it one.
  def test_every_session_publishes_to_one_event_stream
    s = speaker('neighbors' => [{ 'address' => '10.0.0.2', 'as' => 65_001 },
                                { 'address' => '10.0.0.3', 'as' => 65_002 }])
    assert_kind_of(BGP::Events, s.events)
    streams = s.peers.collect { |p| p.send(:new_neighbor).events }
    assert_equal(2, streams.size)
    streams.each { |e| assert_same(s.events, e) }
  end

  def test_a_neighbor_on_its_own_still_has_an_event_stream_of_its_own
    assert_not_same(speaker.events, BGP::Neighbor.new(:my_as => 1, :id => '1.1.1.1').events)
  end

  # What the node file calls a peer. Nothing in the protocol carries it,
  # so it can only come from the configuration.
  def test_a_peer_carries_its_description_and_nil_without_one
    s = speaker('neighbors' => [{ 'address' => '10.0.0.2', 'as' => 65_001, 'description' => 'inj1' },
                                { 'address' => '10.0.0.3', 'as' => 65_002 }])
    assert_equal('inj1', s.peers[0].description)
    assert_nil(s.peers[1].description)
  end

  def test_a_speaker_records_when_it_started
    assert_kind_of(Time, speaker.started_at)
  end

  # A flap is a session that had reached Established going down, which
  # is not established_count: three establishments with the third still
  # up is two flaps and three with the third gone is three.
  def test_a_session_that_never_established_is_not_a_flap
    r = BGP::Daemon::Recorder.new('routes')
    assert_equal(0, r.flaps)
    r.session_down!
    assert_equal(0, r.flaps, 'a session that never came up did not flap')
  end

  def test_a_session_that_established_and_went_down_is_one_flap
    r = BGP::Daemon::Recorder.new('routes')
    r.update(keepalive) # Established, as RFC 4271 section 8.2.2 has it
    assert_equal(0, r.flaps)
    r.session_down!
    assert_equal(1, r.flaps)
    r.update(keepalive)
    assert_equal(1, r.flaps, 'coming back up is not a flap on its own')
    r.session_down!
    assert_equal(2, r.flaps)
  end

  def test_the_flap_count_is_in_the_snapshot
    r = BGP::Daemon::Recorder.new('routes')
    r.update(keepalive)
    r.session_down!
    assert_equal(1, r.snapshot['flaps'])
  end

  # established_at is the Time a caller can do arithmetic on, which is
  # what a peer row's uptime needs; the snapshot's own key is a String.
  def test_established_at_is_a_time_and_is_nil_when_the_session_is_down
    r = BGP::Daemon::Recorder.new('routes')
    assert_nil(r.established_at)
    r.update(keepalive)
    assert_kind_of(Time, r.established_at)
    assert_match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z\z/, r.snapshot['established_at'])
    r.session_down!
    assert_nil(r.established_at)
  end

  # The timestamps are written with strftime rather than Time#iso8601,
  # so the file needs no require 'time'. Same String either way, which
  # is the claim this pins.
  def test_the_timestamps_are_iso_8601_with_milliseconds
    assert_match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z\z/, speaker.state['updated_at'])
    assert_equal([], File.read(File.expand_path('../../../bgp/daemon/speaker.rb', __dir__))
                          .scan(/^require 'time'$/),
                 "bgp/daemon/speaker.rb must not require 'time': see the comment on Recorder#iso")
  end

  private

  def keepalive ; BGP::Keepalive.new ; end

end
