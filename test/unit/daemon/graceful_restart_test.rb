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

require 'test/unit'
require 'bgp/daemon/speaker'

# The Receiving Speaker's rules, RFC 4724 section 4.2, on a manual
# clock. The sessions are test/functional/graceful_restart_test.rb.
class TestDaemonGracefulRestart < Test::Unit::TestCase

  GR = BGP::Daemon::GracefulRestart
  CAP = BGP::OPT_PARM::CAP

  class FakeSpeaker
    attr_reader :purged, :events
    def initialize ; @purged = [] ; @events = BGP::Events.new ; end
    def stale_family(_peer, afi, safi, action)
      @purged << [afi, safi] if action == :purge
      yield 2
    end
  end

  FakePeer = Struct.new(:address, :config)

  def open(*caps) ; BGP::Open.new(4, 65_001, 180, '10.0.0.2', *caps) ; end

  # A GR capability: Restart Time, then [afi, safi, F] per family.
  def gr(time, *families)
    c = CAP::Graceful_restart.new(0, time)
    families.each { |afi, safi, f| c.add(afi, safi, f ? 0x80 : 0) }
    c
  end

  def info(theirs) ; BGP::Neighbor::Capabilities.new(open, theirs) ; end

  def helper(config = { 'restart_time' => 0 })
    @now = 1000
    @sp = FakeSpeaker.new
    GR.new(FakePeer.new('10.0.0.2', 'graceful_restart' => config), @sp, clock: -> { @now })
  end

  def eor(afi = 1, safi = 1)
    afi == 1 && safi == 1 ? BGP::Update.end_of_rib_marker : BGP::Update.end_of_rib_marker(:afi => afi, :safi => safi)
  end

  # Only a TCP failure, only with families, only when configured.
  def test_what_a_drop_keeps
    h = helper
    two = info(open(gr(120, [1, 1, true], [2, 1, true])))
    assert_equal([[1, 1], [2, 1]], h.down(two, :tcp))
    assert_equal('restarting', h.state)
    assert_equal([], helper.down(two, :notification), 'section 4: a NOTIFICATION is RFC 4271')
    assert_equal([], helper.down(two, :hold_time), 'the hold timer sends one')
    assert_equal([], helper.down(two, nil), 'our own stop')
    assert_equal([], helper.down(info(open(gr(120))), :tcp), 'no families listed: section 3, a helper only')
    assert_equal([], helper.down(info(open), :tcp), 'no capability')
    off = GR.new(FakePeer.new('10.0.0.2', {}), FakeSpeaker.new)
    assert_equal([], off.down(two, :tcp), 'not configured')
  end

  # The last instance counts, section 3.
  def test_the_last_capability_counts
    two = open(gr(120, [1, 1, true]), gr(30, [2, 1, false]))
    assert_equal({ [2, 1] => false }, GR.families(two))
    assert_equal(30, GR.received(two)[:restart_time])
  end

  # The peer's Restart Time, with no session back.
  def test_the_restart_time
    h = helper
    h.down(info(open(gr(30, [1, 1, true]))), :tcp)
    @sp.purged.clear # the consecutive restart's purge, test_without_n_what_was_stale_goes_first
    @now += 29
    assert_equal([], h.expire)
    assert_equal({ :state => 'restarting', :families => [{ :afi => 1, :safi => 1 }], :seconds_left => 1,
                   :notification => false, :long_lived => [] }, h.row)
    @now += 1
    assert_equal([[1, 1, 'Restart Time']], h.expire)
    assert_equal([[1, 1]], @sp.purged)
    assert_equal(nil, h.state)
  end

  # Back: F set waits, F clear and missing go at once; End-of-RIB ends
  # one, the stale timer the other.
  def test_the_new_session
    h = helper('stale_time' => 200)
    h.down(info(open(gr(120, [1, 1, true], [2, 1, true], [1, 128, true]))), :tcp)
    @sp.purged.clear
    h.up(info(open(gr(120, [1, 1, true], [2, 1, false]))))
    assert_equal([[2, 1], [1, 128]], @sp.purged, 'F clear, then missing')
    assert_equal({ :state => 'helper', :families => [{ :afi => 1, :safi => 1 }], :seconds_left => 200,
                   :notification => false, :long_lived => [] }, h.row)
    @now += 150
    assert_equal([], h.expire, 'past the Restart Time: it stopped once the session was back')
    h2 = helper('stale_time' => 60)
    h2.down(info(open(gr(120, [1, 1, true], [2, 1, true]))), :tcp)
    @sp.purged.clear
    h2.up(info(open(gr(120, [1, 1, true], [2, 1, true]))))
    h2.update(eor(2, 1))
    assert_equal([[2, 1]], @sp.purged, 'End-of-RIB for IPv6')
    h2.update(eor(2, 1))
    assert_equal(1, @sp.purged.size, 'a second one finds nothing waiting')
    @now += 59
    assert_equal([], h2.expire)
    @now += 1
    assert_equal([[1, 1, 'stale_time']], h2.expire)
  end

  # A watcher that ended between the session coming back and the
  # stale timer starting is started again.
  def test_the_stale_timer_has_a_watcher
    h = helper
    h.down(info(open(gr(120, [1, 1, true]))), :tcp)
    h.instance_variable_get(:@watcher)&.kill
    h.instance_variable_set(:@watcher, nil)
    h.up(info(open(gr(120, [1, 1, true]))))
    assert_not_nil(h.instance_variable_get(:@watcher))
  ensure
    h&.instance_variable_get(:@watcher)&.kill
  end

  # graceful_restart turns End-of-RIB on: the capability says we send it.
  def test_the_key_turns_end_of_rib_on
    sp = BGP::Daemon::Speaker.new('as' => 65_000, 'router_id' => '10.0.0.1',
                                  'neighbors' => [{ 'address' => '10.0.0.2', 'as' => 65_001, 'graceful_restart' => true },
                                                  { 'address' => '10.0.0.3', 'as' => 65_001 }])
    assert_equal([true, false], [sp.peer('10.0.0.2').end_of_rib?, sp.peer('10.0.0.3').end_of_rib?])
  end

  def test_no_capability_on_the_new_session
    h = helper
    h.down(info(open(gr(120, [1, 1, true]))), :tcp)
    @sp.purged.clear
    h.up(info(open))
    assert_equal([[1, 1]], @sp.purged)
    assert_equal(nil, h.state)
  end

  def test_events
    h = helper
    sub = @sp.events.subscribe
    h.down(info(open(gr(120, [1, 1, true]))), :tcp)
    h.up(info(open(gr(120, [1, 1, true]))))
    h.update(eor)
    got = []
    while (e = sub.pop(:timeout => 0)) do got << e.data end
    assert_equal([{ :purged => { :afi => 1, :safi => 1, :removed => 2 }, :reason => 'consecutive restart, no N bit' },
                  { :helper => { :families => [{ :afi => 1, :safi => 1 }], :restart_time => 120, :cause => 'tcp',
                                 :notification => false, :long_lived => [] } },
                  { :back => { :waiting => [{ :afi => 1, :safi => 1 }], :stale_time => 180 } },
                  { :purged => { :afi => 1, :safi => 1, :removed => 2 }, :reason => 'End-of-RIB' }], got)
    h2 = helper
    sub2 = @sp.events.subscribe
    h2.down(info(open(gr(120, [1, 1, true]))), :notification)
    e = sub2.pop(:timeout => 0)
    assert_equal({ :flushed => { :cause => 'notification', :notification => false } }, e.data)
  end

  def test_what_the_key_takes
    assert_nothing_raised do
      [nil, true, {}, { 'restart_time' => 4095, 'stale_time' => 1, 'notification' => true }, { 'notification' => false }].each { |v| GR.check(v, 'a') }
    end
    { 'yes' => /true or a mapping/, { 'restart_time' => 4096 } => /0 to 4095/, { 'stale_time' => 0 } => /from 1/,
      { 'notification' => 'yes' } => /notification is true or false, not "yes"/, { 'restrat_time' => 1 } => /unknown key\(s\) restrat_time/ }.each do |v, re|
      e = assert_raise(ArgumentError, v.inspect) { GR.check(v, '10.0.0.2') }
      assert_match(re, e.message)
    end
  end

  def test_what_we_advertise
    assert_equal({ :restart_state => 0, :restart_time => 0, :families => [] }, GR.capability(true).to_hash[:capability])
    assert_equal(30, GR.capability('restart_time' => 30).to_hash[:capability][:restart_time])
  end

  # Two GR capabilities in one OPEN are refused, section 3.
  def test_the_key_and_the_capability_together_are_refused
    e = assert_raise(ArgumentError) do
      BGP::Daemon::Speaker.new('as' => 65_000, 'router_id' => '10.0.0.1',
                               'neighbors' => [{ 'address' => '10.0.0.2', 'as' => 65_001, 'graceful_restart' => true,
                                                 'capabilities' => [{ 'graceful_restart' => [0, 120] }] }])
    end
    assert_match(/would advertise it twice/, e.message)
  end

  # ---- RFC 8538, pull request 3b ------------------------------------

  # A GR capability with the N bit, Restart Flags 4.
  def gr_n(time, *families)
    c = CAP::Graceful_restart.new(GR::N_BIT, time)
    families.each { |afi, safi, f| c.add(afi, safi, f ? 0x80 : 0) }
    c
  end

  def both_n ; BGP::Neighbor::Capabilities.new(open(gr_n(0)), open(gr_n(120, [1, 1, true]))) ; end

  def test_the_n_bit_is_exchanged_only_both_ways
    assert_equal(true, GR.exchanged?(both_n))
    assert_equal(false, GR.exchanged?(BGP::Neighbor::Capabilities.new(open(gr(0)), open(gr_n(120, [1, 1, true])))))
    assert_equal(false, GR.exchanged?(BGP::Neighbor::Capabilities.new(open(gr_n(0)), open(gr(120, [1, 1, true])))))
    assert_equal(false, GR.exchanged?(nil))
  end

  def test_we_advertise_n_when_asked
    assert_equal(GR::N_BIT, GR.capability('notification' => true).to_hash[:capability][:restart_state])
    assert_equal(0, GR.capability('notification' => false).to_hash[:capability][:restart_state])
  end

  # Section 4: with N, a NOTIFICATION other than a Hard Reset and the
  # hold timer keep; a Hard Reset flushes (section 3.2).
  def test_what_a_drop_keeps_under_n
    h = helper('notification' => true)
    assert_equal([[1, 1]], h.down(both_n, :notification))
    assert_equal([[1, 1]], helper('notification' => true).down(both_n, :hold_time))
    assert_equal([], helper('notification' => true).down(both_n, :hard_reset))
    assert_equal([], helper('notification' => true).down(both_n, nil), 'a stop of our own that sent nothing')
    assert_equal({ :state => 'restarting', :families => [{ :afi => 1, :safi => 1 }], :seconds_left => 120,
                   :notification => true, :long_lived => [] }, h.row)
  end

  # Section 4.1: with N, what was stale stays; without, it goes first.
  def test_consecutive_restarts_keep_what_was_stale_under_n
    h = helper('notification' => true)
    h.down(both_n, :tcp)
    assert_equal([], @sp.purged)
    h2 = helper
    h2.down(info(open(gr(120, [1, 1, true]))), :tcp)
    assert_equal([[1, 1]], @sp.purged)
  end

  def test_a_hard_reset_is_published
    h = helper('notification' => true)
    sub = @sp.events.subscribe
    h.down(both_n, :hard_reset)
    e = sub.pop(:timeout => 0)
    assert_equal({ :flushed => { :cause => 'hard_reset', :notification => true } }, e.data)
    assert_match(/a Hard Reset, as RFC 8538 section 3.2 asks/, e.message)
  end

  # Section 3.1's encoding and section 5.1's table, on a session with N
  # and without.
  def test_which_cease_goes
    hex = ->(subcode, hard = nil, si = both_n) { GR.cease(subcode, si, hard).encode.unpack1('H*')[38..] }
    assert_equal('06090602', hex.(2), 'Administrative Shutdown: hard, wrapping 6/2')
    assert_equal('0604', hex.(4), 'Administrative Reset: graceful unless asked')
    assert_equal('06090604', hex.(4, true))
    assert_equal('0602', hex.(2, false), 'asked graceful')
    assert_equal('060a', hex.(10), 'BFD Down: graceful')
    assert_equal('0606', hex.(6), 'Other Configuration Change: graceful')
    assert_equal('0602', hex.(2, true, info(open(gr(120, [1, 1, true])))), 'no N exchanged: no Hard Reset')
    assert_equal('0609', hex.(9), 'a Hard Reset asked for itself is not wrapped again')
  end

  # The row says what the session that came back exchanged.
  def test_the_row_follows_the_new_session
    h = helper('notification' => true)
    h.down(info(open(gr(120, [1, 1, true]))), :tcp)
    assert_equal(false, h.row[:notification])
    h.up(both_n)
    assert_equal(true, h.row[:notification])
  end

  # The purge before a restart with no N says nothing when it removed
  # nothing, which is the usual case.
  def test_the_consecutive_purge_is_quiet_when_empty
    h = helper
    def @sp.stale_family(_peer, afi, safi, action)
      @purged << [afi, safi] if action == :purge
      yield 0
    end
    sub = @sp.events.subscribe
    h.down(info(open(gr(120, [1, 1, true]))), :tcp)
    got = []
    while (e = sub.pop(:timeout => 0)) do got << e.data.keys end
    assert_equal([[:helper]], got)
  end
end
