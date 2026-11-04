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
require 'bgp/gen/packer'

# The packer counts and never encodes, so these are arithmetic. Whether
# the arithmetic matches a real message is test/unit/gen/unicast_test.rb's
# question, since only a family builds one.
class TestBgpGenPacker < Test::Unit::TestCase
  P = BGP::Gen::Packer

  def items(n, len)
    (0...n).collect { |i| [i, len] }
  end

  def test_the_limit_is_rfc_4271s
    assert_equal(4096, P::MAX)
  end

  def test_size_adds_the_routes_to_the_empty_message
    assert_equal(23 + 10, P.new(23).size(10))
  end

  # RFC 4271 section 4.3: past 255 octets the attribute Length takes two
  # octets, which costs one more.
  def test_an_mp_attribute_crossing_255_octets_costs_one_more
    p = P.new(50, :mp_value => 250)
    assert_equal(55, p.size(5), 'a value of 255 still has a one octet Length')
    assert_equal(57, p.size(6), 'a value of 256 does not')
  end

  def test_an_mp_attribute_already_past_255_costs_nothing_more
    p = P.new(400, :mp_value => 300)
    assert_equal(410, p.size(10))
  end

  def test_per_update_ends_a_message
    sizes = P.new(23, :per_update => 3).each_batch(items(7, 4)).collect { |b, _| b.size }
    assert_equal([3, 3, 1], sizes)
  end

  # Every message but the last is as full as the limit allows: one more
  # route would not fit.
  def test_the_limit_ends_a_message_and_each_one_is_full
    p = P.new(23)
    batches = p.each_batch(items(3000, 4)).to_a
    batches[0..-2].each do |b, octets|
      assert(p.fits?(octets), 'within the limit')
      assert_false(p.fits?(octets + 4), 'and one more route would not be')
    end
    assert_equal(3000, batches.sum { |b, _| b.size })
    assert_equal((0...3000).to_a, batches.flat_map(&:first), 'in order, none lost or repeated')
  end

  def test_the_octets_of_each_batch_are_its_routes
    P.new(23, :per_update => 5).each_batch(items(12, 7)) do |b, octets|
      assert_equal(b.size * 7, octets)
    end
  end

  def test_routes_of_different_sizes
    batches = P.new(4000).each_batch([[:a, 50], [:b, 46], [:c, 1]]).to_a
    assert_equal([[[:a, :b], 96], [[:c], 1]], batches)
  end

  def test_a_route_that_cannot_fit_on_its_own_is_refused
    e = assert_raise(BGP::Gen::Unpackable) { P.new(4090).each_batch(items(1, 7)).to_a }
    assert_match(/4097 octet message/, e.message)
    assert_kind_of(ArgumentError, e, 'the spec asked for it, so it is an ArgumentError')
  end

  # A later set that leaves no room stops the feed, but only after the
  # batch of the set before it has gone, so nothing that fit is lost.
  def test_a_set_that_cannot_fit_stops_after_the_batch_before_it
    small, big = P.new(100), P.new(4090)
    got = []
    assert_raise(BGP::Gen::Unpackable) do
      BGP::Gen::Packer.batches([[:a, 7, small], [:b, 7, small], [:c, 7, big]]) { |b, _, _| got << b }
    end
    assert_equal([[:a, :b]], got)
  end

  def test_nothing_in_nothing_out
    assert_equal([], P.new(23).each_batch([]).to_a)
  end
end
