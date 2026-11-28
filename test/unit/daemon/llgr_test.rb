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

# Long-lived graceful restart, the helper side, RFC 9494 section 4.2, on
# a manual clock. docs/design/bgp-operations.md section 4, pull request
# 4a. The sessions are test/functional/llgr_test.rb.
class TestDaemonLlgr < Test::Unit::TestCase

  GR = BGP::Daemon::GracefulRestart
  CAP = BGP::OPT_PARM::CAP

  class FakeSpeaker
    attr_reader :done, :events
    def initialize ; @done = [] ; @events = BGP::Events.new ; end
    def stale_family(_peer, afi, safi, action)
      @done << [action, afi, safi]
      yield(action == :llgr ? [3, 1] : 2)
    end
  end

  FakePeer = Struct.new(:address, :config, :vrf)

  def open(*caps) ; BGP::Open.new(4, 65_001, 180, '10.0.0.2', *caps) ; end

  def gr(time, *families)
    c = CAP::Graceful_restart.new(0, time)
    families.each { |afi, safi, f| c.add(afi, safi, f ? 0x80 : 0) }
    c
  end

  # [afi, safi, F, LLST] per family.
  def llgr(*families)
    c = CAP::Long_lived_graceful_restart.new
    families.each { |afi, safi, f, t| c.add(afi, safi, f ? 0x80 : 0, t) }
    c
  end

  def info(theirs) ; BGP::Neighbor::Capabilities.new(open, theirs) ; end

  # Both OPENs with IPv4 and IPv6 unicast, the second with caps too.
  def mp ; [CAP::Mbgp.new(1, 1), CAP::Mbgp.new(2, 1)] ; end
  def info_mp(*caps) ; BGP::Neighbor::Capabilities.new(open(*mp), open(*mp, *caps)) ; end

  def helper(llgr = {}, gr = { 'restart_time' => 0 }, vrf = nil)
    @now = 1000
    @sp = FakeSpeaker.new
    GR.new(FakePeer.new('10.0.0.2', { 'graceful_restart' => gr, 'long_lived_graceful_restart' => llgr }, vrf), @sp, clock: -> { @now })
  end

  def eor(afi = 1, safi = 1)
    afi == 1 && safi == 1 ? BGP::Update.end_of_rib_marker : BGP::Update.end_of_rib_marker(:afi => afi, :safi => safi)
  end

  def refused(value, gr, pattern)
    e = assert_raise(ArgumentError) { GR.check_llgr(value, gr, '10.0.0.2') }
    assert_match(pattern, e.message)
  end

  def test_the_key
    assert_nil(GR.check_llgr(nil, nil, '10.0.0.2'))
    assert_nil(GR.check_llgr(true, {}, '10.0.0.2'))
    assert_nil(GR.check_llgr({ 'families' => %w[ipv6_unicast], 'max_stale_time' => 3600 }, true, '10.0.0.2'))
    refused({}, nil, /needs graceful_restart too \(RFC 9494 section 4\.1\)/)
    refused([], {}, /is true or a mapping of families, max_stale_time/)
    refused({ 'stale' => 1 }, {}, /unknown key\(s\) stale/)
    refused({ 'families' => %w[ipv4_multicast] }, {}, /families are of ipv4_unicast, ipv6_unicast, vpnv4_unicast, vpnv6_unicast, l2vpn_evpn, bgp_ls, ipv4_unreachability, ipv6_unreachability, not \["ipv4_multicast"\]/)
    assert_nil(GR.check_llgr({ 'families' => GR::LLGR_FAMILIES.keys }, {}, '10.0.0.2'))
    refused({ 'families' => [] }, {}, /families are/)
    refused({ 'families' => 'ipv4_unicast' }, {}, /families are/)
    refused({ 'max_stale_time' => 1 << 24 }, {}, /max_stale_time is 0 to 16777215 seconds/)
    refused({ 'max_stale_time' => '1' }, {}, /max_stale_time/)
  end

  # Section 4.2: LLST 0 and F clear, each family bgp4rd helps.
  def test_what_bgp4rd_advertises
    assert_equal([[1, 1, 0, 0], [2, 1, 0, 0]], GR.llgr_capability(true).tuples)
    assert_equal([[2, 1, 0, 0]], GR.llgr_capability('families' => %w[ipv6_unicast]).tuples)
  end

  # Section 4.5: without a GR capability, as though none came.
  def test_what_is_received
    assert_equal({ [1, 1] => [0x80, 100] }, GR.received_llgr(open(gr(30), llgr([1, 1, true, 100]))))
    assert_nil(GR.received_llgr(open(llgr([1, 1, true, 100]))))
    assert_nil(GR.received_llgr(open(gr(30))))
    assert_nil(GR.received_llgr(nil))
    assert_equal({ [2, 1] => [0, 5] }, GR.received_llgr(open(gr(30), llgr([1, 1, true, 100]), llgr([2, 1, false, 5]))), 'the last')
  end

  # Section 4.2: GR first, then LLGR, then the routes go.
  def test_the_two_periods_in_series
    h = helper
    assert_equal([[1, 1]], h.down(info(open(gr(30, [1, 1, true]), llgr([1, 1, true, 100]))), :tcp))
    assert_equal([[:purge, 1, 1]], @sp.done, 'RFC 4724''s consecutive restart rule, no N bit')
    @sp.done.clear
    assert_equal('restarting', h.state)
    @now += 29
    assert_equal([], h.expire)
    @now += 1
    assert_equal([[1, 1, :llgr]], h.expire)
    assert_equal([[:llgr, 1, 1]], @sp.done)
    assert_equal('long_lived', h.state)
    assert_equal({ :state => 'long_lived', :families => [{ :afi => 1, :safi => 1 }], :seconds_left => 100, :notification => false,
                   :long_lived => [{ :afi => 1, :safi => 1, :seconds_left => 100 }] }, h.row)
    @now += 99
    assert_equal([], h.expire)
    @now += 1
    assert_equal([[1, 1, 'Long-Lived Stale Time']], h.expire)
    assert_equal([:purge, 1, 1], @sp.done.last)
    assert_nil(h.state)
  end

  # Section 4.2: "if the Restart Time is zero and the Long-Lived Stale
  # Time is nonzero, only the procedures particular to LLGR would apply",
  # and a family the GR capability does not list has a Restart Time of
  # zero.
  def test_restart_time_zero
    h = helper
    h.down(info(open(gr(0, [1, 1, true]), llgr([1, 1, true, 60]))), :tcp)
    assert_equal([[1, 1, :llgr]], h.expire)
    h = helper
    assert_equal([[2, 1]], h.down(info_mp(gr(120), llgr([2, 1, true, 60])), :tcp))
    assert_equal([[2, 1, :llgr]], h.expire, 'listed in LLGR alone')
  end

  # Section 4.2's "AFIs/SAFIs supported by the session": a family the
  # LLGR capability lists and the session did not carry gets no period,
  # and one the new session does not carry goes when it is back.
  def test_a_family_the_session_did_not_carry
    h = helper
    assert_equal([], h.down(info(open(gr(120), llgr([2, 1, true, 60]))), :tcp), 'IPv6 not negotiated')
    h = helper
    h.down(info_mp(gr(0, [2, 1, true]), llgr([2, 1, true, 100])), :tcp)
    h.expire
    @sp.done.clear
    sub = @sp.events.subscribe
    h.up(info(open(gr(0, [2, 1, true]), llgr([2, 1, true, 100]))))
    assert_equal([[:purge, 2, 1]], @sp.done)
    assert_equal('family not negotiated on the new session', sub.pop(:timeout => 0).data[:reason])
    assert_nil(h.state)
  end

  # "if the Long-Lived Stale Time is zero and the Restart Time is
  # nonzero, only the procedures of GR would apply".
  def test_llst_zero
    h = helper
    h.down(info(open(gr(30, [1, 1, true]), llgr([1, 1, true, 0]))), :tcp)
    @sp.done.clear
    @now += 30
    assert_equal([[1, 1, 'Restart Time']], h.expire)
    assert_equal([[:purge, 1, 1]], @sp.done)
  end

  # "MAY be reduced by local configuration"; and only for a family bgp4rd
  # advertised.
  def test_what_bgp4rd_configures
    h = helper('max_stale_time' => 10)
    h.down(info(open(gr(0, [1, 1, true]), llgr([1, 1, true, 100]))), :tcp)
    h.expire
    assert_equal(10, h.row[:seconds_left])
    h = helper('families' => %w[ipv6_unicast])
    h.down(info(open(gr(0, [1, 1, true]), llgr([1, 1, true, 100]))), :tcp)
    assert_equal([[1, 1, 'Restart Time']], h.expire)
    h = helper(nil)
    h.down(info(open(gr(0, [1, 1, true]), llgr([1, 1, true, 100]))), :tcp)
    assert_equal([[1, 1, 'Restart Time']], h.expire, 'no long_lived_graceful_restart')
    h = helper({}, { 'restart_time' => 0 }, 'A')
    h.down(info(open(gr(0, [1, 1, true]), llgr([1, 1, true, 100]))), :tcp)
    assert_equal([[1, 1, 'Restart Time']], h.expire, 'a CE in a VRF')
  end

  # Section 4.5: LLGR with no GR is no LLGR, so nothing is kept.
  def test_llgr_without_gr
    assert_equal([], helper.down(info(open(llgr([1, 1, true, 100]))), :tcp))
  end

  # A NOTIFICATION without N is RFC 4271's, in the LLGR period too.
  def test_a_notification_flushes
    h = helper
    h.down(info(open(gr(0, [1, 1, true]), llgr([1, 1, true, 100]))), :tcp)
    h.expire
    assert_equal([], h.down(info(open(gr(0, [1, 1, true]), llgr([1, 1, true, 100]))), :notification))
    assert_nil(h.state)
  end

  def back_in_llgr(new_open)
    h = helper
    h.down(info(open(gr(0, [1, 1, true]), llgr([1, 1, true, 100]))), :tcp)
    h.expire
    @now += 40
    @sp.done.clear
    yield if block_given?
    h.up(info(new_open))
    h
  end

  # Section 4.2: back with F set, the routes wait for End-of-RIB, the
  # LLST running.
  def test_back_in_the_llgr_period
    h = back_in_llgr(open(gr(0, [1, 1, true]), llgr([1, 1, true, 100])))
    assert_equal('long_lived', h.state)
    assert_equal(60, h.row[:seconds_left], 'the timer is not reset')
    h.update(eor)
    assert_equal([:purge, 1, 1], @sp.done.last)
    assert_nil(h.state)
    h = back_in_llgr(open(gr(0, [1, 1, true]), llgr([1, 1, true, 100])))
    @now += 60
    assert_equal([[1, 1, 'Long-Lived Stale Time']], h.expire, 'the LLST ends during synchronization')
    h.update(eor)
    assert_equal(1, @sp.done.count { |a, *| a == :purge }, 'once')
  end

  # "the Helper MUST immediately remove all the stale routes" when the
  # new capability does not keep them.
  def test_back_without_what_keeps_them
    [open(gr(0, [1, 1, true]), llgr([1, 1, false, 100])),
     open(gr(0, [1, 1, true]), llgr([2, 1, true, 100])),
     open(gr(0, [1, 1, true])),
     open].each do |o|
      sub = nil
      h = back_in_llgr(o) { sub = @sp.events.subscribe }
      assert_equal([:purge, 1, 1], @sp.done.last, o.to_s)
      assert_nil(h.state)
      got = []
      while (e = sub.pop(:timeout => 0)) do got << e.data end
      assert_equal([], got.select { |d| d.key?(:back) }, 'nothing waits, so no word of it')
    end
  end

  # "in the case of consecutive restarts, the previously marked stale
  # routes MUST NOT be deleted before the timer for the Long-Lived Stale
  # Time expires".
  def test_consecutive_restarts
    h = back_in_llgr(open(gr(0, [1, 1, true]), llgr([1, 1, true, 100])))
    n = @sp.done.size
    assert_equal([[1, 1]], h.down(info(open(gr(0, [1, 1, true]), llgr([1, 1, true, 100]))), :tcp))
    assert_equal(n, @sp.done.size, 'no consecutive restart purge for it')
    assert_equal([60, 'long_lived'], [h.row[:seconds_left], h.state], 'and its timer runs on')
    assert_equal([], h.expire)
  end

  # The events, one per step.
  def test_events
    h = helper
    sub = @sp.events.subscribe
    h.down(info(open(gr(0, [1, 1, true]), llgr([1, 1, true, 100]))), :tcp)
    h.expire
    h.up(info(open(gr(0, [1, 1, true]), llgr([1, 1, true, 100]))))
    got = []
    while (e = sub.pop(:timeout => 0)) do got << e.data end
    assert_equal(%i[purged helper long_lived back], got.collect { |d| d.keys.first })
    assert_equal([{ :afi => 1, :safi => 1, :llst => 100 }], got[1][:helper][:long_lived])
    assert_equal({ :long_lived => { :afi => 1, :safi => 1, :marked => 3, :removed => 1, :llst => 100 } }, got[2])
    assert_equal({ :back => { :long_lived => [{ :afi => 1, :safi => 1 }] } }, got[3])
  end

  # The speaker refuses a bad key at start, and the key on a CE.
  def test_the_speaker_checks_the_key
    base = { 'as' => 65_000, 'router_id' => '10.0.0.1' }
    e = assert_raise(ArgumentError) do
      BGP::Daemon::Speaker.new(base.merge('neighbors' => [{ 'address' => '10.0.0.2', 'as' => 65_001, 'long_lived_graceful_restart' => {} }]))
    end
    assert_match(/needs graceful_restart too/, e.message)
    e = assert_raise(ArgumentError) do
      BGP::Daemon::Speaker.new(base.merge('vrfs' => [{ 'name' => 'A', 'table' => 100, 'import' => ['65000:100'] }],
                                          'neighbors' => [{ 'address' => '10.0.0.2', 'as' => 65_001, 'vrf' => 'A',
                                                            'graceful_restart' => true, 'long_lived_graceful_restart' => {} }]))
    end
    assert_match(/long_lived_graceful_restart is for the global table, not a VRF's CE/, e.message)
  end

  # With no RIB there is nothing to mark.
  def test_no_rib
    sp = BGP::Daemon::Speaker.new('as' => 65_000, 'router_id' => '10.0.0.1',
                                  'neighbors' => [{ 'address' => '10.0.0.2', 'as' => 65_001, 'graceful_restart' => true,
                                                    'long_lived_graceful_restart' => {} }])
    got = :none
    sp.stale_family(sp.peers.first, 1, 1, :llgr) { |n| got = n }
    assert_nil(got)
  end

  Route = Struct.new(:path_attribute, :peer, :local) do
    def local? ; local ; end
  end
  RibPeer = Struct.new(:address)
  Neighbor = Struct.new(:session_info)
  SpeakerPeer = Struct.new(:address, :config, :neighbor)

  # What the decision and export ask.
  def test_the_policy
    stale = BGP::Path_attribute.new(BGP::Communities.new(:llgr_stale))
    with = SpeakerPeer.new('10.0.0.2', { 'long_lived_graceful_restart' => {} }, Neighbor.new(info(open(gr(0), llgr([1, 1, true, 9])))))
    without = SpeakerPeer.new('10.0.0.3', {}, Neighbor.new(info(open(gr(0)))))
    speaker = Struct.new(:peers).new([with, without])
    p = GR::Policy.new(speaker)
    assert_true(p.stale?(Route.new(stale, RibPeer.new('10.0.0.2'), false)))
    assert_false(p.stale?(Route.new(stale, RibPeer.new('10.0.0.3'), false)), 'section 4.3: only from a peer we advertised it to')
    assert_false(p.stale?(Route.new(BGP::Path_attribute.new, RibPeer.new('10.0.0.2'), false)))
    assert_false(p.stale?(Route.new(stale, nil, true)), 'ours')
    assert_equal([true, false, false], %w[10.0.0.2 10.0.0.3 10.0.0.9].collect { |a| p.capable?(a) })
  end
end
