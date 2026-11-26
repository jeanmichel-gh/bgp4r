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
require 'bgp/daemon/views'

# Route refresh's rules and counts. The answers on the wire are
# test/functional/route_refresh_test.rb.
class TestDaemonRefresh < Test::Unit::TestCase

  R = BGP::Daemon::Refresh
  CAP = BGP::OPT_PARM::CAP

  def open(*caps)
    BGP::Open.new(4, 65_000, 180, '10.0.0.1', *caps)
  end

  def info(ours, theirs = open)
    BGP::Neighbor::Capabilities.new(ours, theirs)
  end

  def rr ; CAP::Route_refresh.new ; end
  def err ; CAP::Enhanced_route_refresh.new ; end
  def mp(afi, safi) ; CAP::Mbgp.new(afi, safi) ; end

  # RFC 2918 section 4: our OPEN must carry the capability and the
  # family; an OPEN with no Multiprotocol capability carries IPv4
  # unicast.
  def test_what_is_answered
    assert_nil(R.refusal(info(open(rr)), 1, 1))
    assert_nil(R.refusal(info(open(err)), 1, 1), 'capability 70 alone will do')
    assert_nil(R.refusal(info(open(rr, mp(1, 1), mp(2, 1))), 2, 1))
    assert_equal('we did not advertise AFI 2 SAFI 1', R.refusal(info(open(rr)), 2, 1))
    assert_equal('we did not advertise AFI 1 SAFI 1', R.refusal(info(open(rr, mp(2, 1))), 1, 1))
    assert_equal('we did not advertise the Route Refresh capability', R.refusal(info(open(mp(1, 1))), 1, 1))
    assert_equal('no session', R.refusal(nil, 1, 1))
  end

  # RFC 7313 section 4: BoRR and EoRR only to a peer that sent 70.
  def test_enhanced_is_the_peers_capability
    assert_equal(true, R.enhanced?(info(open(rr), open(rr, err))))
    assert_equal(false, R.enhanced?(info(open(rr, err), open(rr))))
    assert_equal(false, R.enhanced?(nil))
  end

  def test_the_family_of_an_update
    pa = BGP::Path_attribute.new(BGP::Origin.new(0), BGP::As_path.new, BGP::Next_hop.new('10.0.0.1'))
    assert_equal([1, 1], R.family(BGP::Update.new(pa, BGP::Nlri.new('10.1.0.0/16'))))
    assert_equal([1, 1], R.family(BGP::Update.new(BGP::Withdrawn.new('10.1.0.0/16'))))
    v6 = BGP::Path_attribute.new(BGP::Origin.new(0), BGP::As_path.new,
                                 BGP::Mp_reach.new(:afi => 2, :safi => 1, :nexthop => ['2001:db8::1'], :prefix => '2001:db8:1::/48'))
    assert_equal([2, 1], R.family(BGP::Update.new(v6)))
    assert_equal([2, 1], R.family(BGP::Update.new(BGP::Path_attribute.new(BGP::Mp_unreach.new(:afi => 2, :safi => 1, :nlris => ['2001:db8:1::/48'])))))
  end

  # Counted by subtype both ways, as FRR counts; the row says so once
  # there is something to say, and a new session starts again.
  def test_counts_and_the_row
    sp = BGP::Daemon::Speaker.new('as' => 65_000, 'router_id' => '10.0.0.1',
                                  'neighbors' => [{ 'address' => '10.0.0.2', 'as' => 65_001 }])
    peer = sp.peer('10.0.0.2')
    row = -> { BGP::Daemon::Views.new(sp).peers.first }
    assert_equal(false, row.().key?(:refresh))
    peer.route_refresh.update(BGP::Route_refresh.new(1, 1, :borr))
    peer.route_refresh.update(BGP::Route_refresh.new(1, 1, :eorr))
    peer.route_refresh.update(BGP::Route_refresh.new(1, 1, 3))
    assert_equal({ :received => { :borr => 1, :eorr => 1, :other => 1 }, :sent => {}, :answered => 0, :ignored => 0,
                   :stale => 0, :waiting => [] },
                 row.()[:refresh])
    peer.route_refresh.reset
    assert_equal(false, row.().key?(:refresh))
  end

  # Receiving, 2b. A peer and a speaker that record what Refresh asks of
  # them, and a clock the test moves.
  class FakeSpeaker
    attr_reader :calls, :events
    def initialize ; @calls = [] ; @events = BGP::Events.new ; end
    def stale_family(peer, afi, safi, action)
      @calls << [afi, safi, action]
      yield 3
    end
    def log(*) ; end
  end

  FakePeer = Struct.new(:address, :session_info, :config)

  def receiver(theirs = open(err), config = {})
    @now = 100
    @sp = FakeSpeaker.new
    @peer = FakePeer.new('10.0.0.2', info(open(rr, err), theirs), config)
    R.new(@peer, @sp, clock: -> { @now })
  end

  # RFC 7313 section 4: a BoRR marks, the EoRR purges, once.
  def test_a_borr_then_an_eorr
    r = receiver
    sub = @sp.events.subscribe
    r.update(BGP::Route_refresh.new(1, 1, :borr))
    assert_equal([[1, 1, :mark]], @sp.calls)
    got = []
    while (e = sub.pop(:timeout => 0)) do got << e.data end
    assert_equal({ :stale => { :afi => 1, :safi => 1, :marked => 3, :seconds => 180 } }, got.last)
    assert_equal([[1, 1]], r.waiting)
    r.update(BGP::Route_refresh.new(1, 1, :eorr))
    assert_equal([[1, 1, :mark], [1, 1, :purge]], @sp.calls)
    assert_equal([], r.waiting)
    r.update(BGP::Route_refresh.new(1, 1, :eorr))
    assert_equal(2, @sp.calls.size, 'a second EoRR has no BoRR before it, and is ignored')
  end

  # Section 4's local bound: refresh_stale_time, else 180 s, on the clock.
  def test_the_bound_purges_on_the_clock
    r = receiver(open(err), 'refresh_stale_time' => 30)
    r.update(BGP::Route_refresh.new(2, 1, :borr))
    @now += 29
    assert_equal([], r.expire)
    @now += 1
    assert_equal([[2, 1]], r.expire)
    assert_equal([[2, 1, :mark], [2, 1, :purge]], @sp.calls)
    assert_equal([], r.waiting)
    r2 = receiver
    r2.update(BGP::Route_refresh.new(1, 1, :borr))
    @now += R::STALE_TIME - 1
    assert_equal([], r2.expire)
    @now += 1
    assert_equal([[1, 1]], r2.expire)
  end

  # Section 4: a GR peer's BoRR before its End-of-RIB for the family is
  # ignored, and logged as an error; after it, read.
  def test_a_gr_peers_borr_waits_for_its_end_of_rib
    gr = BGP::OPT_PARM::CAP::Graceful_restart.new(0, 120)
    gr.add(1, 1, 0x80)
    @now = 100
    @sp = FakeSpeaker.new
    rec = BGP::Daemon::Recorder.new
    peer = Struct.new(:address, :session_info, :config, :recorder).new('10.0.0.2', info(open(rr, err), open(err, gr)), {}, rec)
    r = R.new(peer, @sp, clock: -> { @now })
    sub = @sp.events.subscribe
    r.update(BGP::Route_refresh.new(1, 1, :borr))
    assert_equal([], @sp.calls)
    e = nil
    while (x = sub.pop(:timeout => 0)) do e = x end
    assert_equal([:error, 'a BoRR before the End-of-RIB from a peer that advertised graceful restart (RFC 7313 section 4)'],
                 [e.level, e.data[:reason]])
    rec.update(BGP::Update.end_of_rib_marker)
    r.update(BGP::Route_refresh.new(1, 1, :borr))
    assert_equal([[1, 1, :mark]], @sp.calls)
  end

  # Section 4: "applicable only if a BGP speaker has received the
  # "Enhanced Route Refresh Capability" from a peer".
  def test_nothing_from_a_peer_without_70
    r = receiver(open(rr))
    sub = @sp.events.subscribe
    r.update(BGP::Route_refresh.new(1, 1, :borr))
    r.update(BGP::Route_refresh.new(1, 1, :eorr))
    assert_equal([], @sp.calls)
    why = []
    while (e = sub.pop(:timeout => 0)) do why << e.data[:reason] if e.data[:reason] end
    assert_equal(['the peer did not advertise Enhanced Route Refresh (70)'] * 2, why)
    assert_equal([], r.waiting)
  end

  # Section 5: a subtype other than 0, 1 or 2 is ignored, and said so.
  def test_an_unknown_subtype_is_ignored
    r = receiver
    sub = @sp.events.subscribe
    r.update(BGP::Route_refresh.new(1, 1, 3))
    assert_equal([], @sp.calls)
    got = []
    while (e = sub.pop(:timeout => 0)) do got << e.message end
    assert_equal(['Recv ROUTE-REFRESH 3 AFI 1 SAFI 1',
                  'ROUTE-REFRESH for AFI 1 SAFI 1 ignored: subtype 3 is not 0, 1 or 2 (RFC 7313 section 5)'], got)
  end

  # A new session waits for no EoRR.
  def test_reset_forgets_what_waits
    r = receiver
    r.update(BGP::Route_refresh.new(1, 1, :borr))
    r.reset
    assert_equal([], r.waiting)
  end

  def test_refresh_stale_time_is_a_whole_number_from_1
    assert_nothing_raised { R.check(nil, 'a') ; R.check(1, 'a') }
    [0, -1, 1.5, '30'].each { |v| assert_raise(ArgumentError, v.inspect) { R.check(v, 'a') } }
    e = assert_raise(ArgumentError) do
      BGP::Daemon::Speaker.new('as' => 65_000, 'router_id' => '10.0.0.1',
                               'neighbors' => [{ 'address' => '10.0.0.2', 'as' => 65_001, 'refresh_stale_time' => 0 }])
    end
    assert_match(/whole number of seconds/, e.message, 'refused at start')
    assert_nothing_raised('a neighbor key bgp4rd reads') do
      BGP::Daemon::Speaker.new('as' => 65_000, 'router_id' => '10.0.0.1',
                               'neighbors' => [{ 'address' => '10.0.0.2', 'as' => 65_001, 'refresh_stale_time' => 30 }])
    end
  end

  # Speaker#stale_family: each family to the table that holds it, and
  # stale_size counting them all. EVPN is two tables.
  def test_each_family_goes_to_its_table
    sp = BGP::Daemon::Speaker.new('as' => 65_000, 'router_id' => '10.0.0.1', 'rib' => true,
                                  'neighbors' => [{ 'address' => '10.0.0.2', 'as' => 65_001 }])
    peer = sp.peer('10.0.0.2')
    t = { :vpn => sp.instance_variable_get(:@vpn), :evpn => sp.instance_variable_get(:@evpn),
          :ls => sp.instance_variable_get(:@link_state), :unreach => sp.instance_variable_get(:@unreach) }
    called = []
    { [1, 128] => :vpn, [2, 128] => :vpn, [25, 70] => :evpn, [16388, 71] => :ls }.each do |(afi, safi), name|
      tbl = t[name]
      def tbl.mark_stale(*a) ; (@got ||= []) << [:mark, *a] ; 1 ; end
      def tbl.purge_stale(*a) ; (@got ||= []) << [:purge, *a] ; 2 ; end
      called << [afi, safi]
    end
    u = t[:unreach]
    def u.mark_stale(*a) ; (@got ||= []) << [:mark, *a] ; 10 ; end
    def u.purge_stale(*a) ; (@got ||= []) << [:purge, *a] ; 20 ; end
    got = {}
    called.each do |afi, safi|
      sp.stale_family(peer, afi, safi, :mark) { |n| got[[afi, safi, :mark]] = n }
      sp.stale_family(peer, afi, safi, :purge) { |n| got[[afi, safi, :purge]] = n }
    end
    sp.stale_family(peer, 1, 81, :mark) { |n| got[[1, 81, :mark]] = n }
    sp.stale_family(peer, 1, 4, :mark) { |n| got[[1, 4, :mark]] = n }
    assert_equal({ [1, 128, :mark] => 1, [1, 128, :purge] => 2, [2, 128, :mark] => 1, [2, 128, :purge] => 2,
                   [25, 70, :mark] => 11, [25, 70, :purge] => 22, [16388, 71, :mark] => 1, [16388, 71, :purge] => 2,
                   [1, 81, :mark] => 10, [1, 4, :mark] => nil }, got)
    assert_equal([[:mark, '10.0.0.2', 1], [:purge, '10.0.0.2', 1], [:mark, '10.0.0.2', 2], [:purge, '10.0.0.2', 2]],
                 t[:vpn].instance_variable_get(:@got))
    assert_equal([[:mark, '10.0.0.2', [25, 70]], [:purge, '10.0.0.2', [25, 70]], [:mark, '10.0.0.2', [1, 81]]],
                 u.instance_variable_get(:@got))
    ce = Object.new
    def ce.mark_stale(*a) ; (@got ||= []) << [:mark, *a] ; 4 ; end
    def ce.purge_stale(*a) ; (@got ||= []) << [:purge, *a] ; 5 ; end
    sp.instance_variable_set(:@ce_table, ce)
    a_ce = Struct.new(:address, :vrf).new('192.168.1.2', 'A')
    sp.stale_family(a_ce, 1, 1, :mark) { |n| got[:ce_mark] = n }
    sp.stale_family(a_ce, 1, 1, :purge) { |n| got[:ce_purge] = n }
    assert_equal([4, 5], got.values_at(:ce_mark, :ce_purge), 'a CE\'s unicast is its VRF\'s')
    assert_equal([[:mark, 'A', '192.168.1.2', 1], [:purge, 'A', '192.168.1.2', 1]], ce.instance_variable_get(:@got))
  end

  # Unicast goes through the RIB's worker, in its place among the
  # UPDATEs, and done is called from there.
  def test_unicast_goes_through_the_rib
    sp = BGP::Daemon::Speaker.new('as' => 65_000, 'router_id' => '10.0.0.1', 'rib' => true,
                                  'neighbors' => [{ 'address' => '10.0.0.2', 'as' => 65_001 }])
    peer = sp.peer('10.0.0.2')
    rp = BGP::Rib::Peer.new(:address => '10.0.0.2', :remote_as => 65_001, :router_id => '10.0.0.2', :local_as => 65_000)
    pa = BGP::Path_attribute.new(BGP::Origin.new(0), BGP::As_path.new(65_001), BGP::Next_hop.new('10.0.0.2'))
    %w[10.1.0.0/16 2001:db8::/32].each { |p| sp.rib.announce(BGP::Rib::Route.new(p, pa, rp)) }
    sp.rib.feed.start
    q = Queue.new
    sp.stale_family(peer, 2, 1, :mark) { |n| q << n }
    assert_equal(1, q.pop(:timeout => 5))
    assert_equal(1, sp.stale_size(peer))
    sp.stale_family(peer, 2, 1, :purge) { |n| q << n }
    assert_equal(1, q.pop(:timeout => 5))
    assert_equal([0, ['10.1.0.0/16']], [sp.stale_size(peer), sp.rib.loc_rib.prefixes])
  ensure
    sp&.rib&.feed&.stop
  end

  # show.vrf: a row is stale while its CE route or VPN route is.
  def test_vrf_rows_read_the_mark
    sp = BGP::Daemon::Speaker.new('as' => 65_000, 'router_id' => '10.0.0.1',
                                  'neighbors' => [{ 'address' => '10.0.0.2', 'as' => 65_001 }])
    rows = [{ 'vrf' => 'A', 'prefix' => '172.16.1.0/24', 'transport' => 'ce', 'peer' => '192.168.1.2', 'rd' => nil },
            { 'vrf' => 'A', 'prefix' => '172.16.2.0/24', 'transport' => 'mpls', 'peer' => '10.255.0.3', 'rd' => '65000:1' },
            { 'vrf' => 'A', 'prefix' => '172.16.3.0/24', 'transport' => 'mpls', 'peer' => '10.255.0.3', 'rd' => '65000:1' }]
    l3 = Object.new
    l3.define_singleton_method(:rows) { |_vrf| rows }
    ce = Object.new
    ce.define_singleton_method(:stale) { |vrf, a, p| [vrf, a, p] == ['A', '192.168.1.2', '172.16.1.0/24'] ? 'refresh' : nil }
    vpn = sp.instance_variable_get(:@vpn)
    vpn.define_singleton_method(:stale) { |a, rd, p| [a, rd, p] == ['10.255.0.3', '65000:1', '172.16.2.0/24'] ? 'refresh' : nil }
    sp.instance_variable_set(:@l3vpn, l3)
    sp.instance_variable_set(:@ce_table, ce)
    assert_equal(['refresh', 'refresh', nil], sp.vrf_route_rows('A').collect { |r| r['stale'] })
    assert_equal(false, sp.vrf_route_rows('A').last.key?('stale'))
  end
end
