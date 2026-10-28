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
require 'bgp/misc/route_generator'

class TestBgpRouteGenerator < Test::Unit::TestCase
  include BGP

  def pa
    Path_attribute.new(Origin.new(0), Next_hop.new('40.0.0.1'), As_path.new(100, 90, 80),
                       Communities.new('100:1 200:1 300:1'))
  end

  def test_prefixes_start_at_start
    g = RouteGenerator.new('11.0.0.0/28', 4)
    assert_equal(['11.0.0.0/28', '11.0.0.16/28', '11.0.0.32/28', '11.0.0.48/28'], g.each_prefix.to_a)
    assert_equal('11.0.0.0/28', g.start)
    assert_equal('11.0.0.48/28', g.last)
  end

  def test_host_bits_are_masked
    assert_equal('11.0.0.0/28', RouteGenerator.new('11.0.0.5/28', 1).start)
  end

  def test_steps_cross_octets
    g = RouteGenerator.new('10.0.255.0/24', 3)
    assert_equal(['10.0.255.0/24', '10.1.0.0/24', '10.1.1.0/24'], g.each_prefix.to_a)
  end

  def test_packing
    g = RouteGenerator.new('11.0.0.0/28', 10, 4, pa)
    assert_equal(3, g.update_count)
    sizes = g.each_update.map { |u| u.nlri.to_ary.size }
    assert_equal([4, 4, 2], sizes)
    all = g.each_update.flat_map { |u| u.nlri.to_ary }
    assert_equal(g.each_prefix.to_a, all)
  end

  def test_one_prefix_per_update_by_default
    assert_equal(5, RouteGenerator.new('11.0.0.0/28', 5).update_count)
  end

  def test_updates_round_trip_with_attributes
    u = RouteGenerator.new('11.0.0.0/28', 3, 3, pa).each_update.first
    m = Message.factory(u.encode)
    assert_equal(['11.0.0.0/28', '11.0.0.16/28', '11.0.0.32/28'], m.nlri.to_ary)
    assert_equal('100 90 80', m.path_attribute[:as_path].as_path)
    assert_equal('100:1 200:1 300:1', m.path_attribute[:communities].communities)
  end

  def test_original_routegen_load_fits_in_messages
    # The examples/routegen.yml load: 127 /28s per UPDATE.
    g = RouteGenerator.new('11.0.0.0/28', 199_999, 127, pa)
    assert_equal(1575, g.update_count)
    assert_equal('11.48.211.224/28', g.last)
    assert_operator(g.each_update.first.encode.bytesize, :<=, RouteGenerator::MAX_MESSAGE_SIZE)
  end

  def test_too_many_prefixes_per_update_is_an_error
    # RFC 4271 section 4: at most 4096 octets. 5 octets per /28, so 1000 is too many.
    e = assert_raise(ArgumentError) { RouteGenerator.new('11.0.0.0/28', 1000, 1000, pa).each_update { } }
    assert_match(/4096/, e.message)
  end

  def test_bad_arguments
    assert_raise(ArgumentError) { RouteGenerator.new('2001:db8::/48', 1) }
    assert_raise(ArgumentError) { RouteGenerator.new('11.0.0.0/28', 0) }
    assert_raise(ArgumentError) { RouteGenerator.new('11.0.0.0/28', 1, 0) }
    assert_raise(ArgumentError) { RouteGenerator.new('255.255.255.0/24', 2) }
    assert_raise(IndexError) { RouteGenerator.new('11.0.0.0/28', 2).prefix(2) }
  end

  def test_last_prefix_of_the_address_space
    assert_equal('255.255.255.0/24', RouteGenerator.new('255.255.255.0/24', 1).last)
  end

  def test_enumerators_know_their_size
    g = RouteGenerator.new('11.0.0.0/28', 10, 4)
    assert_equal(10, g.each_prefix.size)
    assert_equal(3, g.each_update.size)
  end

  # Session info for a peer that negotiated add-path both ways for every
  # family (RFC 7911 section 4), as the add-path update tests do.
  def add_path_session
    o = Update::Info.new(false)
    def o.path_id?(*args) ; true ; end
    def o.recv_inet_unicast? ; true ; end
    def o.send_inet_unicast? ; true ; end
    o
  end

  def mp_reach_of(u)
    u.path_attribute[:mp_reach]
  end

  # IPv6

  def test_ipv6_prefixes_start_at_start
    g = RouteGenerator.new('2014:13:11::/49', 4, 1, nil, nexthop: '2014:33::fe')
    assert_equal(['2014:13:11::/49', '2014:13:11:8000::/49', '2014:13:12::/49', '2014:13:12:8000::/49'],
                 g.each_prefix.to_a)
    assert_equal('2014:13:11::/49', g.start)
    assert_equal('2014:13:12:8000::/49', g.last)
    assert_equal(2, g.afi)
    assert(g.mp_reach?)
  end

  def test_ipv6_host_bits_are_masked
    assert_equal('2001:db8::/32', RouteGenerator.new('2001:db8::1/32', 1, 1, nil, nexthop: '::1').start)
  end

  def test_ipv6_steps_cross_64_bit_boundary
    g = RouteGenerator.new('2001:db8:0:ffff:ffff:ffff:ffff:fffe/127', 3, 1, nil, nexthop: '2001:db8::1')
    assert_equal(['2001:db8:0:ffff:ffff:ffff:ffff:fffe/127', '2001:db8:1::/127', '2001:db8:1::2/127'],
                 g.each_prefix.to_a)
  end

  def test_ipv6_last_prefix_of_the_address_space
    g = RouteGenerator.new('ffff:ffff:ffff:ffff::/64', 1, 1, nil, nexthop: '::1')
    assert_equal('ffff:ffff:ffff:ffff::/64', g.last)
    assert_raise(ArgumentError) { RouteGenerator.new('ffff:ffff:ffff:ffff::/64', 2, 1, nil, nexthop: '::1') }
    assert_raise(ArgumentError) { RouteGenerator.new('ffff:ffff:ffff:fffe::/63', 2, 1, nil, nexthop: '::1') }
  end

  def test_ipv6_packing_in_mp_reach
    g = RouteGenerator.new('2014:13:11::/49', 22, 10, pa, nexthop: '2014:33::fe')
    assert_equal(3, g.update_count)
    updates = g.each_update.to_a
    assert_equal([10, 10, 2], updates.map { |u| mp_reach_of(u).nlris.size })
    assert_equal(g.each_prefix.to_a, updates.flat_map { |u| mp_reach_of(u).nlris.map(&:to_s) })
    updates.each do |u|
      assert_nil(u.nlri, 'IPv6 never goes in plain NLRI (RFC 4271 section 4.3)')
      mp = mp_reach_of(u)
      assert_equal([2, 1], [mp.afi, mp.safi])
      assert_equal('2014:33::fe', mp.nexthops)
    end
  end

  def test_ipv6_wire_round_trip
    u = RouteGenerator.new('2014:13:11::/49', 3, 3, pa, nexthop: '2014:33::fe').each_update.first
    m = Message.factory(u.encode)
    assert_instance_of(Update, m)
    assert_equal(u.to_shex, m.to_shex)
    mp = mp_reach_of(m)
    assert_equal([2, 1], [mp.afi, mp.safi])
    assert_equal('2014:33::fe', mp.nexthops)
    assert_equal(['2014:13:11::/49', '2014:13:11:8000::/49', '2014:13:12::/49'], mp.nlris.map(&:to_s))
    assert_equal('100 90 80', m.path_attribute[:as_path].as_path)
    assert_equal('100:1 200:1 300:1', m.path_attribute[:communities].communities)
  end

  def test_ipv6_wire_round_trip_with_4_byte_as
    o = Update::Info.new(true)
    g = RouteGenerator.new('2014:13:11::/49', 22, 10, pa, nexthop: '2014:33::fe')
    g.each_update(o) do |u|
      m = Message.factory(u.encode(o), o)
      assert_equal(u.to_shex(o), m.to_shex(o))
      assert_equal(mp_reach_of(u).nlris.map(&:to_s), mp_reach_of(m).nlris.map(&:to_s))
    end
  end

  def test_ipv6_with_an_ipv4_nexthop_is_mapped
    # RFC 4760 section 3 gives no IPv4 form for an AFI 2 next hop, so
    # Mp_reach sends an IPv4-mapped IPv6 address, ::ffff:a.b.c.d.
    u = RouteGenerator.new('2001:db8::/48', 1, 1, pa, nexthop: '10.0.0.1').each_update.first
    assert_match(/00000000000000000000ffff0a000001/, mp_reach_of(u).to_shex)
  end

  def test_ipv6_too_many_prefixes_per_update_is_an_error
    # A /64 is 9 octets in MP_REACH_NLRI, so 500 make more than 4096 octets.
    g = RouteGenerator.new('2001:db8::/64', 500, 500, pa, nexthop: '2001:db8::1')
    e = assert_raise(ArgumentError) { g.each_update { } }
    assert_match(/4096/, e.message)
    assert_nothing_raised { RouteGenerator.new('2001:db8::/64', 400, 400, pa, nexthop: '2001:db8::1').each_update { } }
  end

  def test_ipv6_bad_arguments
    e = assert_raise(ArgumentError) { RouteGenerator.new('2001:db8::/48', 1) }
    assert_match(/only IPv4/, e.message)
    assert_raise(ArgumentError) { RouteGenerator.new('2001:db8::/48', 1, 1, nil, nexthop: '2001:db8::1', mp_reach: false) }
    assert_raise(ArgumentError) { RouteGenerator.new('2001:db8::/48', 1, 1, nil, nexthop: 'not an address') }
    assert_raise(ArgumentError) { RouteGenerator.new('not a prefix', 1) }
  end

  # MP_REACH_NLRI replaces the one in the given path attributes, and does
  # not change them.

  def test_mp_reach_is_replaced_not_added
    old = Mp_reach.new(:afi => 2, :safi => 1, :nexthop => '2001:db8::99', :nlris => '2001:db8:99::/48')
    given = Path_attribute.new(Origin.new(0), As_path.new(100), old)
    before = given.to_shex
    u = RouteGenerator.new('2014:13:11::/49', 2, 2, given, nexthop: '2014:33::fe').each_update.first
    assert_equal(1, u.path_attribute.attributes.count { |a| a.is_a?(Mp_reach) })
    assert_equal(['2014:13:11::/49', '2014:13:11:8000::/49'], mp_reach_of(u).nlris.map(&:to_s))
    assert_equal(before, given.to_shex, 'the given path attributes are not changed')
    assert_same(old, given[:mp_reach])
  end

  def test_mp_reach_without_path_attributes
    u = RouteGenerator.new('2014:13:11::/49', 1, 1, nil, nexthop: '2014:33::fe').each_update.first
    assert_equal([Mp_reach], u.path_attribute.has?)
    assert_equal(['2014:13:11::/49'], mp_reach_of(Message.factory(u.encode)).nlris.map(&:to_s))
  end

  # IPv4 in MP_REACH_NLRI

  def test_ipv4_in_mp_reach
    g = RouteGenerator.new('13.11.0.0/26', 22, 10, pa, nexthop: '22.22.22.254', mp_reach: true)
    assert(g.mp_reach?)
    updates = g.each_update.to_a
    assert_equal([10, 10, 2], updates.map { |u| mp_reach_of(u).nlris.size })
    assert_equal(g.each_prefix.to_a, updates.flat_map { |u| mp_reach_of(u).nlris.map(&:to_s) })
    updates.each { |u| assert_nil(u.nlri) }
    m = Message.factory(updates[0].encode)
    assert_equal(updates[0].to_shex, m.to_shex)
    mp = mp_reach_of(m)
    assert_equal([1, 1], [mp.afi, mp.safi])
    assert_equal('22.22.22.254', mp.nexthops)
    assert_equal('13.11.0.0/26', mp.nlris[0].to_s)
    assert_equal('40.0.0.1', m.path_attribute[:next_hop].next_hop, 'other attributes are kept')
  end

  def test_ipv4_with_an_ipv6_nexthop_rfc8950
    g = RouteGenerator.new('13.11.0.0/26', 3, 3, pa, nexthop: '2001:db8::1', mp_reach: true)
    u = g.each_update.first
    m = Message.factory(u.encode)
    assert_equal(u.to_shex, m.to_shex)
    mp = mp_reach_of(m)
    assert_equal([1, 1], [mp.afi, mp.safi])
    assert_equal('2001:db8::1', mp.nexthops)
    assert_equal(['13.11.0.0/26', '13.11.0.64/26', '13.11.0.128/26'], mp.nlris.map(&:to_s))
    # RFC 8950 section 3: AFI 1, SAFI 1, next hop length 16, the IPv6
    # next hop, a reserved 0, then the IPv4 NLRI.
    assert_equal(%w(800e24 0001 01 10 20010db8000000000000000000000001 00
                    1a0d0b0000 1a0d0b0040 1a0d0b0080).join, mp.to_shex)
  end

  def test_ipv4_in_mp_reach_size_check
    # A /28 is 5 octets in MP_REACH_NLRI too.
    e = assert_raise(ArgumentError) do
      RouteGenerator.new('11.0.0.0/28', 1000, 1000, pa, nexthop: '40.0.0.1', mp_reach: true).each_update { }
    end
    assert_match(/4096/, e.message)
  end

  def test_ipv4_mp_reach_bad_arguments
    assert_raise(ArgumentError) { RouteGenerator.new('11.0.0.0/28', 1, 1, pa, mp_reach: true) }
    assert_raise(ArgumentError) { RouteGenerator.new('11.0.0.0/28', 1, 1, pa, nexthop: 'not an address', mp_reach: true) }
    e = assert_raise(ArgumentError) { RouteGenerator.new('11.0.0.0/28', 1, 1, pa, nexthop: '40.0.0.1') }
    assert_match(/mp_reach/, e.message)
  end

  def test_plain_nlri_by_default
    g = RouteGenerator.new('11.0.0.0/28', 1, 1, pa)
    assert(!g.mp_reach?)
    assert_nil(g.each_update.first.path_attribute[:mp_reach])
  end

  # Add-path

  def test_path_id_on_plain_nlri
    g = RouteGenerator.new('13.11.0.0/26', 22, 10, pa, path_id: 0x100)
    updates = g.each_update.to_a
    assert_equal([10, 10, 2], updates.map { |u| u.nlri.size })
    assert(updates.all? { |u| u.nlri.nlris.all? { |n| n.path_id == 0x100 } })
    assert_equal('ID=256, 13.11.0.0/26', updates[0].nlri.nlris[0].to_s)
  end

  def test_path_id_on_plain_nlri_wire_round_trip
    u = RouteGenerator.new('77.0.0.0/17', 2, 2, Path_attribute.new(As_path.new(100)), path_id: 100).each_update.first
    # RFC 7911 section 3: 4 octet Path Identifier, then length and prefix.
    # 00000064 11 4d0000 is ID 100, 77.0.0.0/17.
    assert_match(/00000064114d000000000064114d0080$/, u.to_shex)
    s = add_path_session
    m = Message.factory(u.encode(s), s)
    assert_equal(['ID=100, 77.0.0.0/17', 'ID=100, 77.0.128.0/17'], m.nlri.to_ary)
    assert_equal(u.to_shex(s), m.to_shex(s))
  end

  def test_path_id_with_ipv6_wire_round_trip
    g = RouteGenerator.new('2014:13:11::/49', 3, 3, pa, nexthop: '2014:33::fe', path_id: 7)
    u = g.each_update.first
    assert(mp_reach_of(u).nlris.all? { |n| n.path_id == 7 })
    m = Message.factory(u.encode, add_path_session)
    assert_equal(['ID=7, 2014:13:11::/49', 'ID=7, 2014:13:11:8000::/49', 'ID=7, 2014:13:12::/49'],
                 mp_reach_of(m).nlris.map(&:to_s))
    assert_equal(u.to_shex, m.to_shex)
  end

  def test_path_id_with_ipv4_mp_reach_wire_round_trip
    g = RouteGenerator.new('13.11.0.0/26', 2, 2, pa, nexthop: '22.22.22.254', mp_reach: true, path_id: 0x200)
    u = g.each_update.first
    m = Message.factory(u.encode, add_path_session)
    assert_equal(['ID=512, 13.11.0.0/26', 'ID=512, 13.11.0.64/26'], mp_reach_of(m).nlris.map(&:to_s))
    assert_equal(u.to_shex, m.to_shex)
  end

  def test_path_id_zero_is_a_path_id
    u = RouteGenerator.new('11.0.0.0/24', 1, 1, pa, path_id: 0).each_update.first
    assert_equal(0, u.nlri.nlris[0].path_id)
    assert_match(/00000000180b0000$/, u.to_shex)
  end

  def test_path_id_counts_in_the_size_check
    # A /28 is 5 octets, 9 with a path ID. 700 fit without one, not with one.
    assert_nothing_raised { RouteGenerator.new('11.0.0.0/28', 700, 700, pa).each_update { } }
    e = assert_raise(ArgumentError) { RouteGenerator.new('11.0.0.0/28', 700, 700, pa, path_id: 1).each_update { } }
    assert_match(/4096/, e.message)
    e = assert_raise(ArgumentError) do
      RouteGenerator.new('2001:db8::/64', 400, 400, pa, nexthop: '2001:db8::1', path_id: 1).each_update { }
    end
    assert_match(/4096/, e.message)
  end

  def test_path_id_bad_arguments
    assert_raise(ArgumentError) { RouteGenerator.new('11.0.0.0/24', 1, 1, pa, path_id: -1) }
    assert_raise(ArgumentError) { RouteGenerator.new('11.0.0.0/24', 1, 1, pa, path_id: 2**32) }
    assert_raise(ArgumentError) { RouteGenerator.new('11.0.0.0/24', 1, 1, pa, path_id: 'one') }
    assert_raise(ArgumentError) { RouteGenerator.new('11.0.0.0/24', 1, 1, pa, path_id: nil, colour: 1) }
    assert_equal(0xffffffff, RouteGenerator.new("11.0.0.0/24", 1, 1, pa, path_id: 0xffffffff).path_id)
  end

  # The 4096 octet limit is RFC 4271 section 4 and belongs to a BGP
  # message, so it is defined once on BGP::Message and read from there.
  # This file used to carry its own copy of the number.
  def test_the_message_limit_comes_from_bgp_message
    assert_equal BGP::Message::MAX_SIZE, BGP::RouteGenerator::MAX_MESSAGE_SIZE
  end

end
