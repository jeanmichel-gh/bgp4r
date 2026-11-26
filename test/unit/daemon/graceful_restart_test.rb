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
    @now += 29
    assert_equal([], h.expire)
    assert_equal({ :state => 'restarting', :families => [{ :afi => 1, :safi => 1 }], :seconds_left => 1 }, h.row)
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
    h.up(info(open(gr(120, [1, 1, true], [2, 1, false]))))
    assert_equal([[2, 1], [1, 128]], @sp.purged, 'F clear, then missing')
    assert_equal({ :state => 'helper', :families => [{ :afi => 1, :safi => 1 }], :seconds_left => 200 }, h.row)
    @now += 150
    assert_equal([], h.expire, 'past the Restart Time: it stopped once the session was back')
    h2 = helper('stale_time' => 60)
    h2.down(info(open(gr(120, [1, 1, true], [2, 1, true]))), :tcp)
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
    assert_equal([{ :helper => { :families => [{ :afi => 1, :safi => 1 }], :restart_time => 120 } },
                  { :back => { :waiting => [{ :afi => 1, :safi => 1 }], :stale_time => 180 } },
                  { :purged => { :afi => 1, :safi => 1, :removed => 2 }, :reason => 'End-of-RIB' }], got)
    h2 = helper
    sub2 = @sp.events.subscribe
    h2.down(info(open(gr(120, [1, 1, true]))), :notification)
    e = sub2.pop(:timeout => 0)
    assert_equal({ :flushed => { :cause => 'notification' } }, e.data)
  end

  def test_what_the_key_takes
    assert_nothing_raised { [nil, true, {}, { 'restart_time' => 4095, 'stale_time' => 1 }].each { |v| GR.check(v, 'a') } }
    { 'yes' => /true or a mapping/, { 'restart_time' => 4096 } => /0 to 4095/, { 'stale_time' => 0 } => /from 1/,
      { 'notification' => true } => /RFC 8538's N bit, is not built yet/, { 'restrat_time' => 1 } => /unknown key\(s\) restrat_time/ }.each do |v, re|
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
end
