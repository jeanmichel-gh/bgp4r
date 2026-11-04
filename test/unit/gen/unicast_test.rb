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

# IPv4 and IPv6 unicast, one claim per test. The properties every family
# owes, over many random specs, are in test/unit/gen_test.rb.
class TestBgpGenUnicast < Test::Unit::TestCase

  # Reads what was sent the way a peer that negotiated add-path both ways
  # would, strictly, so a protocol error raises.
  class AddPath < BGP::Update::Info
    def initialize ; super(true, :strict) ; end
    def recv_inet_unicast? ; true ; end
    def path_id?(*) ; true ; end
  end

  def gen(spec)
    BGP::Gen.new({ 'start' => '10.0.0.0/24', 'count' => 3 }.merge(spec))
  end

  def parse(u, info = BGP::Update::Info.new(true, :strict))
    BGP::Update.new(u.encode(BGP::Update::Info.new(true)).is_packed, info)
  end

  def test_ipv4_goes_in_the_rfc_4271_fields
    g = gen('attributes' => { 'next_hop' => '192.0.2.1' })
    u = parse(g.updates.first)
    assert_equal(%w[10.0.0.0/24 10.0.1.0/24 10.0.2.0/24], u.nlri.to_ary)
    assert_nil(u.path_attribute[:mp_reach])
    assert_equal('192.0.2.1', u.path_attribute[:next_hop].next_hop)
    w = parse(g.withdrawals.first)
    assert_equal(%w[10.0.0.0/24 10.0.1.0/24 10.0.2.0/24], w.withdrawn.to_ary)
    assert_nil(w.path_attribute)
  end

  def test_ipv6_goes_in_mp_reach_and_mp_unreach
    g = gen('start' => '2001:db8::/48', 'attributes' => { 'next_hop' => '2001:db8::1' })
    u = parse(g.updates.first)
    mp = u.path_attribute[:mp_reach]
    assert_equal([2, 1], [mp.afi, mp.safi])
    assert_equal(%w[2001:db8::/48 2001:db8:1::/48 2001:db8:2::/48], mp.nlris.collect(&:to_s))
    assert_equal('2001:db8::1', mp.nexthops)
    assert_nil(u.path_attribute[:next_hop], 'the next hop is inside MP_REACH_NLRI')
    assert_nil(u.nlri, 'and the RFC 4271 field is empty')
    un = parse(g.withdrawals.first).path_attribute[:mp_unreach]
    assert_equal([2, 1], [un.afi, un.safi])
    assert_equal(3, un.nlris.size)
  end

  # The library knows no session, so it puts no AS in front and fills in
  # no next hop. bgp4r-sim does both, in phase 3.
  def test_the_attributes_go_as_written
    u = parse(gen('attributes' => { 'as_path' => [65020, 65030] }).updates.first)
    assert_equal('65020 65030', u.path_attribute[:as_path].as_path)
    assert_nil(u.path_attribute[:next_hop], 'no next_hop in the spec, no NEXT_HOP on the wire')
    assert_nil(u.path_attribute[:local_pref])
    assert_nil(u.path_attribute[:multi_exit_disc])
  end

  def test_origin_and_as_path_are_always_there
    pa = parse(gen({}).updates.first).path_attribute
    assert_equal(0, pa[:origin].to_i)
    assert_equal('empty', pa[:as_path].as_path, 'what As_path prints for no segments')
    assert_equal([], pa[:as_path].segments)
  end

  def test_every_attribute_key_reaches_the_wire
    a = { 'origin' => 2, 'next_hop' => '192.0.2.1', 'as_path' => [65010], 'med' => 7, 'local_pref' => 300,
          'communities' => ['65000:1', 'no_export'], 'extended_communities' => ['route_target:65000:7'],
          'large_communities' => ['65000:1:1'] }
    pa = parse(gen('attributes' => a).updates.first).path_attribute
    assert_equal(2, pa[:origin].to_i)
    assert_equal(7, pa[:multi_exit_disc].to_i)
    assert_equal(300, pa[:local_pref].to_i)
    assert_equal('65000:1 65535:65281', pa[:communities].communities)
    assert_equal('65000:1:1', pa[:large_communities].large_communities)
    assert_equal([{ :route_target => [65000, 7] }], pa[:extended_communities].to_hash[:extended_communities])
  end

  # RFC 7911 section 3, on every prefix, announce and withdraw, both
  # families.
  def test_a_path_id_reaches_every_prefix_both_ways
    %w[10.0.0.0/24 2001:db8::/48].each do |start|
      g = gen('start' => start, 'path_id' => 9, 'count' => 5, 'attributes' => { 'next_hop' => '192.0.2.1' })
      [g.updates, g.withdrawals].each do |msgs|
        msgs.each do |m|
          u = parse(m, AddPath.new)
          list = u.nlri || u.withdrawn ||
                 (u.path_attribute[:mp_reach] || u.path_attribute[:mp_unreach]).nlris
          ids = (list.respond_to?(:nlris) ? list.nlris : list).collect(&:path_id)
          assert_equal([9] * 5, ids, start)
        end
      end
    end
  end

  def test_the_prefixes_step_by_their_own_length
    assert_equal(%w[10.0.0.0/32 10.0.0.1/32 10.0.0.2/32],
                 gen('start' => '10.0.0.0/32').expected.collect { |r| r['prefix'] })
    assert_equal(%w[2001:db8::/128 2001:db8::1/128 2001:db8::2/128],
                 gen('start' => '2001:db8::/128').expected.collect { |r| r['prefix'] })
  end

  def test_host_bits_in_start_are_masked
    assert_equal('10.0.0.0/8', gen('start' => '10.1.2.3/8').expected.first['prefix'])
  end

  def test_a_range_past_the_address_space_is_refused
    e = assert_raise(BGP::Gen::SpecError) { gen('start' => '255.255.255.0/24', 'count' => 2) }
    assert_match(/run past the end/, e.message)
  end

  def test_an_afi_that_disagrees_with_start_is_refused
    e = assert_raise(BGP::Gen::SpecError) { gen('afi' => 2) }
    assert_match(/afi 2 disagrees with start 10.0.0.0\/24, which is AFI 1/, e.message)
    assert_equal(1, gen('afi' => 1).afi)
  end

  def test_a_start_that_is_not_a_prefix_is_refused
    assert_raise(BGP::Gen::SpecError) { gen('start' => 'ten') }
  end

  def test_attributes_with_no_room_for_a_route_are_refused_at_once
    big = (1..1100).collect { |i| "1:#{i}" }
    e = assert_raise(BGP::Gen::Unpackable) { gen('attributes' => { 'communities' => big }) }
    assert_match(/leave no room/, e.message)
  end

  # The first message is measured against the packer's arithmetic, so a
  # slip there raises before it reaches a wire. Lying about one route's
  # size is the slip.
  def test_the_first_message_is_measured
    g = BGP::Gen::Unicast.new(BGP::Gen::Spec.read('start' => '10.0.0.0/24', 'count' => 3))
    g.define_singleton_method(:route_octets) { super() + 1 }
    e = assert_raise(BGP::Gen::PackingError) { g.updates.first }
    assert_match(/computed 45 octets for a message that encodes to 42/, e.message)
    assert_raise(BGP::Gen::PackingError) { g.withdrawals.first }
  end

  def test_expected_spells_communities_the_way_they_read_back
    r = gen('attributes' => { 'communities' => ['no_export'], 'extended_communities' => ['route_target:65000:7'],
                              'large_communities' => ['65000:1:1'] }).expected.first
    assert_equal(['65535:65281'], r['communities'])
    assert_equal(['route_target:65000:7'], r['extended_communities'])
    assert_equal(['65000:1:1'], r['large_communities'])
  end

  def test_expected_carries_only_what_is_sent
    assert_equal({ 'prefix' => '10.0.0.0/24', 'origin' => 0, 'as_path' => [] }, gen({}).expected.first)
    assert_equal(9, gen('path_id' => 9).expected.first['path_id'])
  end

  # A million routes are numbered, not listed: the first message and the
  # row count cost nothing.
  def test_a_large_count_is_built_one_message_at_a_time
    g = gen('count' => 1_000_000, 'start' => '10.0.0.0/32')
    t = Time.now
    assert_equal(1_000_000, g.expected.size)
    size = g.updates.first.encode(BGP::Update::Info.new(true)).bytesize
    assert_operator(size, :<=, 4096)
    assert_operator(size + 5, :>, 4096, 'and a /32 more would not fit')
    assert_operator(Time.now - t, :<, 2)
  end
end
