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
require 'bgp/gen'

# Labeled VPN routes, SAFI 128 and 129 (RFC 4364, RFC 4659): an RD and a
# label in front of each prefix, the same range once per VRF, and a
# route target per VRF when one is given.
#
#   ruby -I. test/unit/gen/vpn_test.rb
#
# The octets below were written out by hand from RFC 4364 section 4.2's
# layouts and checked against what the library encodes, which is this
# reader's arithmetic and not a vector from a document: RFC 4364 carries
# no hex.
class TestBgpGenVpn < Test::Unit::TestCase

  INFO = BGP::Update::Info.new(true, :strict)

  class AddPath < BGP::Update::Info
    def initialize ; super(true, :strict) ; end
    def path_id?(*) ; true ; end
  end

  def gen(spec)
    BGP::Gen.new({ 'family' => 'vpn', 'start' => '10.0.0.0/24', 'count' => 3, 'label' => 100,
                   'rd' => '65000:1', 'attributes' => { 'next_hop' => '192.0.2.1' } }.merge(spec))
  end

  def parse(u, info = INFO)
    BGP::Update.new(u.encode(BGP::Update::Info.new(true)).is_packed, info)
  end

  def mp(u, key = :mp_reach, info = INFO) ; parse(u, info).path_attribute[key] ; end

  def nlris(u, key = :mp_reach) ; mp(u, key).nlris.collect(&:to_hash) ; end

  def test_each_prefix_carries_its_rd_and_its_label
    u = gen({}).updates.first
    assert_equal([1, 128], [mp(u).afi, mp(u).safi])
    assert_equal('192.0.2.1', mp(u).nexthops)
    assert_equal([{ :label => 100, :rd => [65000, 1], :prefix => '10.0.0.0/24' },
                  { :label => 100, :rd => [65000, 1], :prefix => '10.0.1.0/24' },
                  { :label => 100, :rd => [65000, 1], :prefix => '10.0.2.0/24' }], nlris(u))
    # RFC 4364 section 4.3.4 and RFC 8277 section 2: a length of 24 + 64
    # + 24 bits, the label 100 with the S bit, the type 0 RD, the prefix.
    assert_match('70' + '000641' + '0000fde800000001' + '0a0000', u.to_shex)
  end

  # RFC 4364 section 4.1: the RD is what lets two VRFs carry the same
  # address. So every VRF gets the whole range, under its own RD.
  def test_every_vrf_carries_the_same_prefixes_under_its_own_rd
    g = gen('vrfs' => 3)
    rows = g.expected.to_a
    assert_equal(9, rows.size)
    assert_equal(%w[65000:1 65000:2 65000:3], rows.collect { |r| r['rd'] }.uniq)
    rows.each_slice(3) { |s| assert_equal(%w[10.0.0.0/24 10.0.1.0/24 10.0.2.0/24], s.collect { |r| r['prefix'] }) }
    sent = g.updates.flat_map { |u| nlris(u) }
    assert_equal(rows.collect { |r| [r['rd'], r['prefix']] },
                 sent.collect { |h| [h[:rd].join(':'), h[:prefix]] })
  end

  # The three layouts of RFC 4364 section 4.2, picked by the
  # administrator, each stepped in its assigned number.
  def test_each_rd_type_steps_per_vrf
    { '65000:1' => [0, '0000fde800000001', '0000fde800000002'],
      '192.0.2.1:7' => [1, '0001c00002010007', '0001c00002010008'],
      '4200000000:9' => [2, '0002fa56ea000009', '0002fa56ea00000a'] }.each do |rd, (type, first, second)|
      g = gen('rd' => rd, 'vrfs' => 2, 'count' => 1)
      hex = g.updates.collect(&:to_shex).join
      assert_match(first, hex, "type #{type}, VRF 1")
      assert_match(second, hex, "type #{type}, VRF 2")
    end
  end

  # A route target per VRF makes each VRF an attribute set of its own,
  # so a message never mixes two of them, whatever per_update allows.
  def test_a_route_target_per_vrf_is_a_set_per_vrf
    g = gen('vrfs' => 2, 'route_target' => '65000:100', 'count' => 2)
    us = g.updates.to_a
    assert_equal(2, us.size, 'one message per VRF')
    us.each_with_index do |u, v|
      ec = parse(u).path_attribute[:extended_communities].to_hash[:extended_communities]
      assert_equal([{ :route_target => [65000, 100 + v] }], ec)
      assert_equal([[65000, 1 + v]], nlris(u).collect { |h| h[:rd] }.uniq)
    end
    assert_equal(['route_target:65000:100'], g.expected.first['extended_communities'])
    assert_equal(['route_target:65000:101'], g.expected.to_a.last['extended_communities'])
  end

  # Without a route target the VRFs share one set, so they pack together.
  def test_without_a_route_target_the_vrfs_pack_together
    assert_equal(1, gen('vrfs' => 4).updates.count)
  end

  # A route target joins extended communities the spec already gives.
  def test_a_route_target_joins_the_extended_communities
    g = gen('route_target' => '192.0.2.1:5',
            'attributes' => { 'next_hop' => '192.0.2.1', 'extended_communities' => ['route_origin:65000:1'] })
    assert_equal(%w[route_origin:65000:1 route_target:192.0.2.1:5], g.expected.first['extended_communities'])
  end

  # RFC 8277 section 2.4 applies to any "SAFI-x UPDATE": the withdrawal
  # names the RD and the prefix and carries 0x800000 where the label was.
  def test_a_withdrawal_names_the_rd_and_carries_the_compatibility_field
    w = gen('vrfs' => 2, 'count' => 1).withdrawals.first
    assert_equal([{ :compatibility => '800000', :rd => [65000, 1], :prefix => '10.0.0.0/24' },
                  { :compatibility => '800000', :rd => [65000, 2], :prefix => '10.0.0.0/24' }],
                 nlris(w, :mp_unreach))
  end

  # RFC 4659 section 3.2.1.2: an IPv4 next hop for VPN-IPv6 routes is a
  # VPN-IPv6 address with an RD of zero and the IPv4-mapped address, 24
  # octets. Mp_reach writes 12 when handed the IPv4 address itself.
  def test_an_ipv4_next_hop_for_ipv6_routes_goes_out_mapped
    g = gen('start' => '2001:db8::/64', 'attributes' => { 'next_hop' => '192.0.2.1' })
    m = mp(g.updates.first)
    assert_equal([2, 128], [m.afi, m.safi])
    assert_equal('::ffff:192.0.2.1', m.nexthops)
    assert_equal(24, m.encode[6, 1].unpack1('C'), 'the next hop length')
    assert_equal('192.0.2.1', g.expected.first['next_hop'], 'expected keeps the address as given')
  end

  def test_an_ipv6_next_hop_is_24_octets
    m = mp(gen('start' => '2001:db8::/64', 'attributes' => { 'next_hop' => '2001:db8::1' }).updates.first)
    assert_equal('2001:db8::1', m.nexthops)
    assert_equal(24, m.encode[6, 1].unpack1('C'))
  end

  def test_a_path_id_rides_in_front
    g = gen('path_id' => 7)
    h = mp(g.updates.first, :mp_reach, AddPath.new).nlris.first.to_hash
    assert_equal({ :label => 100, :rd => [65000, 1], :prefix => '10.0.0.0/24', :path_id => 7 }, h)
    hw = mp(g.withdrawals.first, :mp_unreach, AddPath.new).nlris.first.to_hash
    assert_equal({ :compatibility => '800000', :rd => [65000, 1], :prefix => '10.0.0.0/24', :path_id => 7 }, hw)
  end

  # The label runs on the route number across the VRFs, as path_id does.
  def test_the_label_runs_across_the_vrfs
    g = gen('vrfs' => 2, 'count' => 2, 'label' => { 'step' => { 'start' => 16, 'by' => 1 } })
    assert_equal([16, 17, 18, 19], g.expected.collect { |r| r['label'] })
  end

  def test_expected
    assert_equal({ 'prefix' => '10.0.0.0/24', 'label' => 100, 'rd' => '65000:1', 'origin' => 0,
                   'as_path' => [], 'next_hop' => '192.0.2.1' }, gen({}).expected.first)
  end

  # Eleven more octets a route than unicast, the label and the RD.
  def test_a_full_message_is_full_and_fits
    g = gen('start' => '10.0.0.0/32', 'count' => 2000, 'vrfs' => 2)
    [g.updates, g.withdrawals].each do |feed|
      sizes = feed.collect { |u| u.encode(BGP::Update::Info.new(true)).bytesize }
      assert_operator(sizes.max, :<=, 4096)
      assert_operator(sizes.first, :>, 4096 - 16)
    end
  end

  def test_vpn_multicast_is_safi_129
    g = BGP::Gen.new('family' => 'vpn_multicast', 'start' => '10.0.0.0/24', 'count' => 1, 'label' => 1,
                     'rd' => '65000:1', 'attributes' => { 'next_hop' => '192.0.2.1' })
    assert_equal([1, 129], [mp(g.updates.first).afi, mp(g.updates.first).safi])
    assert_equal([1, 129], [mp(g.withdrawals.first, :mp_unreach).afi, mp(g.withdrawals.first, :mp_unreach).safi])
  end

  def test_an_rd_and_a_label_are_required
    e = assert_raise(BGP::Gen::SpecError) { BGP::Gen.new('family' => 'vpn', 'start' => '10.0.0.0/24', 'count' => 1, 'label' => 1) }
    assert_match(/needs an rd/, e.message)
    e = assert_raise(BGP::Gen::SpecError) { BGP::Gen.new('family' => 'vpn', 'start' => '10.0.0.0/24', 'count' => 1, 'rd' => '1:1') }
    assert_match(/needs a label/, e.message)
  end

  # The one refusal: an assigned number stepped past its field would be
  # written as a different one. 16 bits for types 1 and 2, 32 for type 0.
  def test_an_rd_stepped_past_its_field_is_refused
    assert_raise(BGP::Gen::SpecError) { gen('rd' => '192.0.2.1:65535', 'vrfs' => 2) }
    assert_raise(BGP::Gen::SpecError) { gen('rd' => '4200000000:65535', 'vrfs' => 2) }
    assert_raise(BGP::Gen::SpecError) { gen('route_target' => '192.0.2.1:65535', 'vrfs' => 2) }
    assert_nothing_raised { gen('rd' => '65000:65535', 'vrfs' => 2) }
    assert_nothing_raised { gen('rd' => '192.0.2.1:65534', 'vrfs' => 2) }
  end

  def test_an_rd_that_is_not_admin_n_is_refused
    ['65000', 'x:1', '65000:x', '300.0.0.1:1', '4294967296:1', 65000].each do |rd|
      assert_raise(BGP::Gen::SpecError, rd.inspect) { gen('rd' => rd) }
    end
  end

  # The family keys belong to VPN and nothing else.
  def test_the_vpn_keys_are_refused_on_another_family
    %w[rd vrfs route_target].each do |k|
      v = k == 'vrfs' ? 2 : '65000:1'
      e = assert_raise(BGP::Gen::SpecError) do
        BGP::Gen.new('family' => 'labelled', 'start' => '10.0.0.0/24', 'count' => 1, 'label' => 1, k => v)
      end
      assert_match(/'#{k}' is for vpn, vpn_multicast/, e.message)
    end
  end

  # Building never validates: label 3 is reserved and is sent, and an RD
  # whose type no route target pairs with it goes out as written.
  def test_nothing_validates
    g = gen('label' => 3, 'rd' => '0:0', 'route_target' => '4200000000:0')
    assert_equal([3], nlris(g.updates.first).collect { |h| h[:label] }.uniq)
    assert_equal([0, 0], nlris(g.updates.first).first[:rd])
  end
end
