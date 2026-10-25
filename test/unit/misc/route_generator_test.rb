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
end
