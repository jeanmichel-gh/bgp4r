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

# Multicast, SAFI 2: unicast's routes under another SAFI, and IPv4 in
# MP_REACH_NLRI rather than RFC 4271's own fields.
#
#   ruby -I. test/unit/gen/multicast_test.rb
class TestBgpGenMulticast < Test::Unit::TestCase

  INFO = BGP::Update::Info.new(true, :strict)

  def gen(spec)
    BGP::Gen.new({ 'family' => 'multicast', 'start' => '10.0.0.0/24', 'count' => 3,
                   'attributes' => { 'next_hop' => '192.0.2.1' } }.merge(spec))
  end

  def parse(u)
    BGP::Update.new(u.encode(BGP::Update::Info.new(true)).is_packed, INFO)
  end

  # RFC 4271 section 4.3's NLRI field is IPv4 unicast's alone, so IPv4
  # multicast goes in MP_REACH_NLRI (RFC 4760 section 3), and its next
  # hop with it rather than in a NEXT_HOP attribute.
  def test_ipv4_goes_in_mp_reach_under_safi_2
    u = parse(gen({}).updates.first)
    mp = u.path_attribute[:mp_reach]
    assert_equal([1, 2], [mp.afi, mp.safi])
    assert_equal(%w[10.0.0.0/24 10.0.1.0/24 10.0.2.0/24], mp.nlris.collect(&:to_s))
    assert_equal('192.0.2.1', mp.nexthops)
    assert_nil(u.nlri)
    assert_nil(u.path_attribute[:next_hop])
  end

  def test_ipv4_is_withdrawn_in_mp_unreach
    w = parse(gen({}).withdrawals.first)
    mp = w.path_attribute[:mp_unreach]
    assert_equal([1, 2], [mp.afi, mp.safi])
    assert_equal(%w[10.0.0.0/24 10.0.1.0/24 10.0.2.0/24], mp.nlris.collect(&:to_s))
    assert_nil(w.withdrawn)
  end

  def test_ipv6_too
    g = gen('start' => '2001:db8::/48', 'attributes' => { 'next_hop' => '2001:db8::1' })
    mp = parse(g.updates.first).path_attribute[:mp_reach]
    assert_equal([2, 2], [mp.afi, mp.safi])
    assert_equal('2001:db8::1', mp.nexthops)
    assert_equal(2, g.afi)
  end

  # Unicast's rows, since nothing in the NLRI differs.
  def test_expected_is_unicasts
    rows = gen({}).expected.to_a
    assert_equal(BGP::Gen.new('start' => '10.0.0.0/24', 'count' => 3,
                              'attributes' => { 'next_hop' => '192.0.2.1' }).expected.to_a, rows)
  end

  # Fewer routes fit than unicast's, since the next hop and the AFI and
  # SAFI travel in the attribute too: the packer measures it and the
  # first message is checked against the arithmetic.
  def test_a_full_message_is_full_and_fits
    g = gen('start' => '10.0.0.0/32', 'count' => 3000)
    sizes = g.updates.collect { |u| u.encode(BGP::Update::Info.new(true)).bytesize }
    assert_operator(sizes.max, :<=, 4096)
    assert_operator(sizes.first, :>, 4096 - 5)
  end

  def test_a_label_is_not_multicasts
    assert_raise(BGP::Gen::SpecError) { gen('label' => 16) }
  end
end
