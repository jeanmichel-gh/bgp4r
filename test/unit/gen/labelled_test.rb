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

# Labelled unicast, SAFI 4 (RFC 8277): a label in front of each prefix,
# and the Compatibility field in its place on a withdrawal.
#
#   ruby -I. test/unit/gen/labelled_test.rb
class TestBgpGenLabelled < Test::Unit::TestCase

  INFO = BGP::Update::Info.new(true, :strict)

  class AddPath < BGP::Update::Info
    def initialize ; super(true, :strict) ; end
    def path_id?(*) ; true ; end
  end

  def gen(spec)
    BGP::Gen.new({ 'family' => 'labelled', 'start' => '10.0.0.0/24', 'count' => 3, 'label' => 100,
                   'attributes' => { 'next_hop' => '192.0.2.1' } }.merge(spec))
  end

  def parse(u, info = INFO)
    BGP::Update.new(u.encode(BGP::Update::Info.new(true)).is_packed, info)
  end

  def nlris(u, key = :mp_reach) ; parse(u).path_attribute[key].nlris.collect(&:to_hash) ; end

  def test_each_prefix_carries_its_label
    u = gen({}).updates.first
    assert_equal([1, 4], [parse(u).path_attribute[:mp_reach].afi, parse(u).path_attribute[:mp_reach].safi])
    assert_equal([{ :label => 100, :prefix => '10.0.0.0/24' }, { :label => 100, :prefix => '10.0.1.0/24' },
                  { :label => 100, :prefix => '10.0.2.0/24' }], nlris(u))
  end

  # The label is part of the NLRI and not of the attributes, so a
  # pattern runs on the route number and a group does not hold it.
  def test_a_label_pattern_runs_per_route_and_a_group_does_not_hold_it
    g = gen('label' => { 'step' => { 'start' => 16, 'by' => 2 } }, 'group' => 3)
    assert_equal([16, 18, 20], nlris(g.updates.first).collect { |h| h[:label] })
    assert_equal(1, g.updates.count, 'one attribute set, so one message')
    assert_equal([16, 18, 20], g.expected.collect { |r| r['label'] })
  end

  # RFC 8277 section 2.4: "Upon transmission, the Compatibility field
  # SHOULD be set to 0x800000". bgp4r reads it back as that field, so
  # the withdrawal names the prefixes and no label.
  def test_a_withdrawal_carries_the_compatibility_field
    w = gen({}).withdrawals.first
    assert_equal([{ :compatibility => '800000', :prefix => '10.0.0.0/24' },
                  { :compatibility => '800000', :prefix => '10.0.1.0/24' },
                  { :compatibility => '800000', :prefix => '10.0.2.0/24' }], nlris(w, :mp_unreach))
    assert_match(/308000000a0000/, w.to_shex, 'a length of 48 bits, the three octets, then the prefix')
  end

  def test_ipv6_and_a_path_id
    g = gen('start' => '2001:db8::/48', 'path_id' => 7, 'attributes' => { 'next_hop' => '2001:db8::1' })
    mp = parse(g.updates.first, AddPath.new).path_attribute[:mp_reach]
    assert_equal([2, 4], [mp.afi, mp.safi])
    assert_equal({ :label => 100, :prefix => '2001:db8::/48', :path_id => 7 }, mp.nlris.first.to_hash)
    mw = parse(g.withdrawals.first, AddPath.new).path_attribute[:mp_unreach]
    assert_equal({ :compatibility => '800000', :prefix => '2001:db8::/48', :path_id => 7 }, mw.nlris.first.to_hash)
  end

  def test_expected_carries_the_label
    assert_equal({ 'prefix' => '10.0.0.0/24', 'label' => 100, 'origin' => 0, 'as_path' => [],
                   'next_hop' => '192.0.2.1' }, gen({}).expected.first)
  end

  # Three more octets a route than unicast, so the packer's arithmetic
  # has to know: the first message of each set is measured against it,
  # and every message fits and the first is full.
  def test_a_full_message_is_full_and_fits
    g = gen('start' => '10.0.0.0/32', 'count' => 3000)
    sizes = g.updates.collect { |u| u.encode(BGP::Update::Info.new(true)).bytesize }
    assert_operator(sizes.max, :<=, 4096)
    assert_operator(sizes.first, :>, 4096 - 8)
    w = g.withdrawals.collect { |u| u.encode(BGP::Update::Info.new(true)).bytesize }
    assert_operator(w.max, :<=, 4096)
    assert_operator(w.first, :>, 4096 - 8)
  end

  def test_a_label_is_required
    e = assert_raise(BGP::Gen::SpecError) do
      BGP::Gen.new('family' => 'labelled', 'start' => '10.0.0.0/24', 'count' => 1)
    end
    assert_match(/needs a label/, e.message)
  end

  # 20 bits, RFC 3032 section 2.1: a larger value cannot be written.
  def test_a_label_wider_than_20_bits_is_refused
    assert_raise(BGP::Gen::SpecError) { gen('label' => 2**20) }
    assert_raise(BGP::Gen::SpecError) { gen('label' => { 'cycle' => [1, 2**20] }) }
    assert_nothing_raised { gen('label' => 2**20 - 1) }
  end

  # Labels 0 to 15 are reserved (RFC 3032 section 2.1) and are sent
  # anyway: building never validates.
  def test_nothing_validates
    assert_equal([3, 3, 3], nlris(gen('label' => 3).updates.first).collect { |h| h[:label] })
  end
end
