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
require 'bgp/daemon'

# bgp/daemon/unreachability.rb, without a session: the configuration,
# what one UPDATE asks of the table, and the table itself.
class TestDaemonUnreachability < Test::Unit::TestCase

  include BGP
  D = BGP::Daemon
  R = D::Unreach

  V4 = [IANA::AFI::IPv4, R::SAFI].freeze
  V6 = [IANA::AFI::IPv6, R::SAFI].freeze

  def reporter(id, as, reason = 3, time = 1_733_789_400)
    Unreachability::Reporter.new(id, as, Unreachability::Reason_code.new(reason),
                                 Unreachability::Timestamp.new(time))
  end

  # Through the wire, as a session hands it over, so the UPDATE carries
  # the findings its parse made.
  def update(nlri, *extra, path: [65_001])
    mp = Mp_reach.new(:afi => nlri.afi, :safi => R::SAFI, :nlris => [nlri])
    Update.new(Update.new(Path_attribute.new(Origin.new(2), As_path.new(*path), mp, *extra)).encode.is_packed)
  end

  # ---- the configuration -------------------------------------------------

  def test_a_report_from_the_configuration
    r = R::Report.from_config({ 'prefix' => '192.0.2.1/24', 'reason' => 'rpki_invalid',
                                'timestamp' => 5 })
    assert_equal(['192.0.2.0/24', 3, 5, V4], [r.prefix, r.reason, r.timestamp, r.family])
    assert_equal('ipv4', r.family_name)
    assert_equal('0004' + '18c00002', r.nlri('10.0.0.1', 1, true).to_shex)
    assert_equal(r.to_config, R::Report.from_config(r.to_config).to_config)
  end

  def test_reason_names_and_numbers
    assert_equal(9, R.reason('local_link_down'))
    assert_equal(12, R.reason('VTEP Unreachable'))
    assert_equal(64_536, R.reason(64_536))
    assert_equal(0, R.reason(nil))
    assert_raise(ArgumentError) { R.reason('nope') }
  end

  def test_an_evpn_report
    r = R::Report.from_config({ 'prefix' => '2001:db8::/32', 'reason' => 12, 'timestamp' => 1,
                                'evpn' => { 'rd' => '10.0.0.1:7', 'route_targets' => ['65001:7'],
                                            'ethernet_tag' => 3, 'evi' => 70 } })
    assert_equal([R::EVPN, 'evpn'], [r.family, r.family_name])
    route = r.nlri('10.0.0.1', 65_001).route
    assert_instance_of(Evpn::Ip_prefix_unreachability, route)
    assert_equal(['2001:db8::/32', 3, 70], [route.ip_prefix, route.ethernet_tag_id.value,
                                            route.reporters.first.evi])
  end

  def test_what_the_configuration_refuses
    assert_raise(ArgumentError) { R.reports([{ 'reason' => 3 }]) }
    assert_raise(ArgumentError) { R.reports([{ 'prefix' => 'nope' }]) }
    assert_raise(ArgumentError) { R.reports([{ 'prefix' => '192.0.2.0/24', 'colour' => 1 }]) }
    assert_raise(ArgumentError) { R.reports([{ 'prefix' => '192.0.2.0/24', 'evpn' => {} }]) }
    assert_raise(ArgumentError) { R.reports([{ 'prefix' => '192.0.2.0/24' }, { 'prefix' => '192.0.2.0/24' }]) }
    # The same prefix in two RDs is two reports.
    assert_equal(2, R.reports([{ 'prefix' => '192.0.2.0/24', 'evpn' => { 'rd' => '1:1' } },
                               { 'prefix' => '192.0.2.0/24', 'evpn' => { 'rd' => '1:2' } }]).size)
  end

  # ---- one UPDATE ---------------------------------------------------------

  def test_an_announcement
    ops = R.operations(update(Unreachability.new('192.0.2.0/24', reporter('10.0.0.1', 65_001))), [V4])
    assert_equal(1, ops.size)
    op, key, fields = ops.first
    assert_equal(:announce, op)
    assert_equal([V4, 24, "\xc0\x00\x02".b], key)
    assert_equal('192.0.2.0/24', fields['prefix'])
    assert_equal([], fields['reporter_as_not_in_path'])
    assert_equal('RPKI Invalid', fields['reporters'].first['reason_name'])
  end

  def test_a_family_the_session_did_not_negotiate_gives_nothing
    assert_equal([], R.operations(update(Unreachability.new('192.0.2.0/24', reporter('1.1.1.1', 1))), [V6]))
  end

  # SAFI section 5.2, through the UPDATE's own findings.
  def test_no_reporter_is_a_withdrawal
    ops = R.operations(update(Unreachability.new('192.0.2.0/24')), [V4])
    assert_equal([[:withdraw, [V4, 24, "\xc0\x00\x02".b]]], ops)
  end

  # SAFI section 5.1: a session reset takes nothing from the UPDATE.
  def test_a_structural_error_takes_nothing
    bad = Unreachability.new(:afi => 1, :mlen => 33, :value => 'c000020000',
                             :reporters => [reporter('1.1.1.1', 1)])
    assert_equal([], R.operations(update(bad), [V4]))
  end

  # SAFI section 7 item 5.
  def test_a_reporter_as_not_in_the_path_is_named
    u = Unreachability.new('192.0.2.0/24', reporter('10.0.0.1', 65_001), reporter('10.0.0.9', 64_999))
    fields = R.operations(update(u, path: [65_001]), [V4]).first[2]
    assert_equal([64_999], fields['reporter_as_not_in_path'])
    fields = R.operations(update(u, path: []), [V4]).first[2]
    assert_equal([], fields['reporter_as_not_in_path'])
  end

  # SAFI 3.4, 4.8 and 5.3: duplicates, unknown types and the limit.
  def test_what_a_receiver_keeps_of_the_reporters
    list = [reporter('10.0.0.1', 1), reporter('10.0.0.1', 1, 7),
            Unreachability::Tlv::Unknown.new(9, 'x'), reporter('10.0.0.2', 1)]
    assert_equal(%w[10.0.0.1 10.0.0.2], R.kept_reporters(list).collect(&:identifier))
    assert_equal(3, R.kept_reporters(list).first.reason)
    many = (1..60).collect { |i| reporter("10.0.1.#{i}", 1) }
    assert_equal(50, R.kept_reporters(many).size)
  end

  # ---- the table -----------------------------------------------------------

  def test_the_table_replaces_withdraws_and_forgets_a_peer
    t = D::UnreachTable.new
    a = R.operations(update(Unreachability.new('192.0.2.0/24', reporter('10.0.0.1', 65_001, 3))), [V4])
    b = R.operations(update(Unreachability.new('192.0.2.0/24', reporter('10.0.0.1', 65_001, 7))), [V4])
    t.apply('10.0.0.1', a)
    t.apply('10.0.0.1', b)
    assert_equal(1, t.size)
    assert_equal(7, t.rows.first['reporters'].first['reason'])
    t.apply('10.0.0.2', a)
    assert_equal(2, t.size)
    t.apply('10.0.0.1', [[:withdraw, a.first[1]]])
    assert_equal(['10.0.0.2'], t.rows.collect { |r| r['peer'] })
    t.peer_down('10.0.0.2')
    assert_equal(0, t.size)
  end

  def test_the_table_publishes_what_arrives_and_goes
    ev = Events.new
    t = D::UnreachTable.new(events: ev)
    ops = R.operations(update(Unreachability.new('192.0.2.0/24', reporter('10.0.0.1', 65_001))), [V4])
    t.apply('10.0.0.1', ops)
    t.apply('10.0.0.1', [[:withdraw, ops.first[1]]])
    got = ev.since(0).select { |e| e.kind == :unreachability }
    assert_equal(%w[received withdrawn], got.collect { |e| e.data['event'] })
    assert_match(/192\.0\.2\.0\/24 \(RPKI Invalid\)/, got.first.message)
  end

  # ---- the originator ------------------------------------------------------

  class FakeSpeaker
    attr_reader :router_id, :my_as, :peers, :events, :local_address
    def initialize
      @router_id, @my_as, @peers, @events, @local_address = '10.0.0.1', 65_001, [], BGP::Events.new, '10.0.0.1'
    end
  end

  def test_a_report_with_no_timestamp_keeps_its_first_one
    o = D::UnreachOriginator.new(FakeSpeaker.new)
    changed, = o.refresh([{ 'prefix' => '192.0.2.0/24' }], 100)
    assert_equal(1, changed.size)
    changed, gone = o.refresh([{ 'prefix' => '192.0.2.0/24' }], 200)
    assert_equal([[], []], [changed, gone])
    assert_equal(100, o.reports.first.timestamp)
    changed, = o.refresh([{ 'prefix' => '192.0.2.0/24', 'reason' => 1 }], 300)
    assert_equal(300, changed.first.timestamp)
    _, gone = o.refresh([], 400)
    assert_equal(1, gone.size)
  end

  # SAFI 4.6: ORIGIN INCOMPLETE; Appendix B.1: no next hop. EVPN: its
  # Route Targets and our next hop.
  def test_the_updates_it_sends
    sp = FakeSpeaker.new
    o = D::UnreachOriginator.new(sp)
    peer = Struct.new(:ebgp?, :local_ip).new(true, '10.0.0.1')
    reports = R.reports([{ 'prefix' => '192.0.2.0/24', 'reason' => 3, 'timestamp' => 1 },
                         { 'prefix' => '198.51.100.0/24', 'timestamp' => 1,
                           'evpn' => { 'rd' => '10.0.0.1:1', 'route_targets' => ['65001:1'] } }])
    u = o.updates(peer, reports, [])
    assert_equal(2, u.size)
    pa = u.first.path_attribute
    assert_equal({ :origin => :incomplete }, pa[Origin].to_hash)
    assert_equal('65001', pa[As_path].as_path)
    assert_equal([1, 81], [pa[Mp_reach].afi, pa[Mp_reach].safi])
    assert_equal('', pa[Mp_reach].nexthops)
    assert_equal([], pa.errors)
    pe = u.last.path_attribute
    assert_equal([25, 70], [pe[Mp_reach].afi, pe[Mp_reach].safi])
    assert_equal('10.0.0.1', pe[Mp_reach].nexthops)
    assert_equal([[65_001, 1]], pe[Extended_communities].communities.collect { |c| c.to_hash[:route_target] })
    assert_equal([], pe.errors)
    w = o.updates(peer, [], reports)
    assert_equal(['0004' + '18c00002'], [w.first.path_attribute[Mp_unreach].nlris.first.to_shex])
  end

end
