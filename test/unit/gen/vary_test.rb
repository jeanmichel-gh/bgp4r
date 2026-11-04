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
require 'bgp/gen/vary'

# The patterns, one claim per test. What the values do to the wire is
# test/unit/gen/unicast_test.rb's and test/unit/gen_test.rb's.
class TestBgpGenVary < Test::Unit::TestCase
  V = BGP::Gen::Vary

  # Positional options and not keywords: a braceless Hash of String
  # keys handed to a method with keyword parameters is an error in
  # Ruby 3, and every pattern here is written that way.
  def int(v, opts = {})
    V.compile(v, 'attributes.med', :int, max: opts.fetch(:max, 0xffffffff), seed: opts[:seed])
  end

  def at(p, n = 6) ; (0...n).collect { |i| p.at(i) } ; end

  def refused(pattern)
    e = assert_raise(BGP::Gen::SpecError) { yield }
    assert_match(pattern, e.message)
  end

  def test_a_plain_value_is_fixed
    p = int(7)
    assert_kind_of(V::Fixed, p)
    assert_equal([7] * 6, at(p))
    assert_false(V.varies?(p))
    assert_equal([7] * 6, at(int('fixed' => 7)))
  end

  def test_cycle
    assert_equal([1, 2, 3, 1, 2, 3], at(int('cycle' => [1, 2, 3])))
    assert(V.varies?(int('cycle' => [1, 2])))
  end

  def test_step_without_wrap_keeps_going
    assert_equal([100, 110, 120, 130, 140, 150], at(int('step' => { 'start' => 100, 'by' => 10 })))
  end

  # docs/route-generation.md section 5: back to start at wrap, so wrap
  # itself is never a value.
  def test_step_goes_back_to_start_at_wrap
    assert_equal([100, 110, 120, 100, 110, 120],
                 at(int('step' => { 'start' => 100, 'by' => 10, 'wrap' => 130 })))
  end

  def test_every
    assert_equal([5, 5, 6, 6, 5, 5], at(int('every' => { 'n' => 2, 'values' => [5, 6] })))
  end

  def test_random_stays_in_its_range_and_is_repeatable
    p = int({ 'random' => { 'min' => 1, 'max' => 1000 } }, seed: 7)
    values = at(p, 500)
    assert(values.all? { |v| (1..1000) === v })
    assert_operator(values.uniq.size, :>, 300, 'and it does vary')
    assert_equal(values, at(int({ 'random' => { 'min' => 1, 'max' => 1000 } }, seed: 7), 500))
    assert_not_equal(values, at(int({ 'random' => { 'min' => 1, 'max' => 1000 } }, seed: 8), 500))
  end

  # The values themselves, pinned. They come from this library, so this
  # is not a check against anything outside it; what it catches is a
  # change to the hash or the generator that would silently give every
  # seeded spec different octets than it gave before. MT19937, which
  # Random is, should give the same sequence on every Ruby, and CI runs
  # this on four of them, which is what turns should into measured.
  def test_random_values_are_pinned
    assert_equal([961, 449, 584, 394, 861, 256],
                 at(int({ 'random' => { 'min' => 1, 'max' => 1000 } }, seed: 7)))
  end

  # FNV-1a 64 of "a" is 0xaf63dc4c8601ec8c, from the algorithm's own
  # published test vectors, so this one is checked against something
  # outside bgp4r.
  def test_fnv_is_fnv_1a_64
    assert_equal(0xaf63dc4c8601ec8c, V.fnv('a'))
    assert_equal(0xcbf29ce484222325, V.fnv(''))
  end

  # A route's value depends on its number and not on what came before,
  # which is what lets withdrawals regenerate the announcement.
  def test_a_value_is_a_function_of_the_route_number_alone
    p = int({ 'random' => { 'min' => 1, 'max' => 10**9 } }, seed: 3)
    forward = at(p, 50)
    assert_equal(forward.reverse, 49.downto(0).collect { |i| p.at(i) })
  end

  # Two values with the same seed draw from different streams, so
  # adding a random MED to a spec does not move its random LOCAL_PREF.
  def test_the_name_salts_the_stream
    a = V.compile({ 'random' => { 'min' => 1, 'max' => 10**9 } }, 'attributes.med', :int, seed: 3)
    b = V.compile({ 'random' => { 'min' => 1, 'max' => 10**9 } }, 'attributes.local_pref', :int, seed: 3)
    assert_not_equal(at(a, 20), at(b, 20))
  end

  def test_an_address_steps_and_wraps_in_its_own_family
    p = V.compile({ 'step' => { 'start' => '192.0.2.254', 'by' => 1 } }, 'attributes.next_hop', :addr)
    assert_equal(%w[192.0.2.254 192.0.2.255 192.0.3.0], at(p, 3))
    p = V.compile({ 'step' => { 'start' => '2001:db8::1', 'by' => 1, 'wrap' => '2001:db8::3' } },
                  'attributes.next_hop', :addr)
    assert_equal(%w[2001:db8::1 2001:db8::2 2001:db8::1], at(p, 3))
  end

  def test_a_random_address
    p = V.compile({ 'random' => { 'min' => '192.0.2.1', 'max' => '192.0.2.254' } },
                  'attributes.next_hop', :addr, seed: 7)
    assert(at(p, 100).all? { |a| (IPAddr.new('192.0.2.1').to_i..IPAddr.new('192.0.2.254').to_i) === IPAddr.new(a).to_i })
  end

  def test_addresses_of_two_families_are_refused
    refused(/not the family of the first address/) do
      V.compile({ 'cycle' => ['192.0.2.1', '2001:db8::1'] }, 'attributes.next_hop', :addr)
    end
  end

  def test_as_path_prepend
    p = V.compile({ 'prepend' => { 'as' => 65010, 'count' => { 'cycle' => [0, 1, 3] }, 'path' => [65020] } },
                  'attributes.as_path', :list)
    assert_equal([[65020], [65010, 65020], [65010, 65010, 65010, 65020]], at(p, 3))
  end

  def test_as_path_length_from_a_range
    p = V.compile({ 'length' => { 'count' => { 'cycle' => [1, 4] }, 'min' => 64512, 'max' => 64520 } },
                  'attributes.as_path', :list, seed: 9)
    paths = at(p, 4)
    assert_equal([1, 4, 1, 4], paths.collect(&:size))
    assert(paths.flatten.all? { |as| (64512..64520) === as })
  end

  def test_as_path_cycles_whole_paths
    p = V.compile({ 'cycle' => [[1], [2, 3]] }, 'attributes.as_path', :list)
    assert_equal([[1], [2, 3], [1]], at(p, 3))
  end

  # fixed and every take whole lists for both list kinds, the same as
  # cycle does.
  def test_fixed_and_every_over_whole_lists
    p = V.compile({ 'fixed' => [1, 2] }, 'attributes.as_path', :list)
    assert_equal([[1, 2]] * 2, at(p, 2))
    p = V.compile({ 'every' => { 'n' => 2, 'values' => [[1], [2]] } }, 'attributes.as_path', :list)
    assert_equal([[1], [1], [2], [2]], at(p, 4))
    p = V.compile({ 'fixed' => '65000:1' }, 'attributes.communities', :strings)
    assert_equal([%w[65000:1]] * 2, at(p, 2))
    p = V.compile({ 'every' => { 'n' => 3, 'values' => [['1:1'], ['2:2']] } }, 'attributes.communities', :strings)
    assert_equal([%w[1:1]] * 3 + [%w[2:2]], at(p, 4))
  end

  def test_a_community_count_counts_up_from_its_base
    p = V.compile({ 'count' => { 'base' => '65000:7', 'n' => { 'step' => { 'start' => 1, 'by' => 1, 'wrap' => 4 } } } },
                  'attributes.communities', :strings)
    assert_equal([%w[65000:7], %w[65000:7 65000:8], %w[65000:7 65000:8 65000:9], %w[65000:7]], at(p, 4))
    p = V.compile({ 'count' => { 'base' => 'route_target:65000:10', 'n' => 2 } },
                  'attributes.extended_communities', :strings)
    assert_equal(%w[route_target:65000:10 route_target:65000:11], p.at(0))
  end

  def test_a_count_of_zero_is_an_empty_list
    p = V.compile({ 'count' => { 'base' => '65000:1', 'n' => 0 } }, 'attributes.communities', :strings)
    assert_equal([], p.at(0))
  end

  def test_step_and_random_over_lists_are_refused
    refused(/unknown pattern 'step'; an AS_PATH takes/) do
      V.compile({ 'step' => { 'start' => 1, 'by' => 1 } }, 'attributes.as_path', :list)
    end
    refused(/unknown pattern 'random'; a community list takes/) do
      V.compile({ 'random' => { 'min' => 1, 'max' => 2 } }, 'attributes.communities', :strings)
    end
  end

  def test_what_a_pattern_cannot_read_is_refused_and_named
    refused(/a pattern of one key/) { int('cycle' => [1], 'fixed' => 1) }
    refused(/unknown pattern 'zigzag'/) { int('zigzag' => [1]) }
    refused(/a list of values/) { int('cycle' => []) }
    refused(/every.n is an integer of at least 1/) { int('every' => { 'n' => 0, 'values' => [1] }) }
    refused(/unknown key 'size'/) { int('step' => { 'start' => 1, 'by' => 1, 'size' => 2 }) }
    refused(/by is required/) { int('step' => { 'start' => 1 }) }
    refused(/step.by is an integer/) { int('step' => { 'start' => 1, 'by' => 1.5 }) }
    refused(/wrap 1 is not above start 5/) { int('step' => { 'start' => 5, 'by' => 1, 'wrap' => 1 }) }
    refused(/random.min is above random.max/) { int({ 'random' => { 'min' => 5, 'max' => 1 } }, seed: 1) }
    refused(/needs the spec's seed/) { int('random' => { 'min' => 1, 'max' => 2 }) }
    refused(/needs the spec's seed/) do
      V.compile({ 'length' => { 'count' => 1, 'min' => 1, 'max' => 2 } }, 'attributes.as_path', :list)
    end
    refused(/length.min is above length.max/) do
      V.compile({ 'length' => { 'count' => 1, 'min' => 9, 'max' => 2 } }, 'attributes.as_path', :list, seed: 1)
    end
    refused(/count.base is a community ending in a number/) do
      V.compile({ 'count' => { 'base' => 'no_export', 'n' => 1 } }, 'attributes.communities', :strings)
    end
  end

  # Every value a pattern can give is checked against the field when
  # the pattern is read, so a cycle cannot smuggle a value too large.
  def test_each_value_of_a_pattern_fits_its_field
    refused(/256 does not fit/) { int({ 'cycle' => [1, 256] }, max: 255) }
    refused(/-1 is below 0/) { int('fixed' => -1) }
  end

  # Nothing validates: no RFC allows an empty AS_PATH on eBGP, an AS 0,
  # or a MED stepping past 2**32; the first two read, and the third is
  # a value its field cannot hold, which Conventions lets a reader
  # refuse. The step's own bounds are checked; values past them are
  # the encoder's, and are not checked here.
  def test_nothing_validates
    assert_equal([[], [0]], at(V.compile({ 'cycle' => [[], [0]] }, 'attributes.as_path', :list), 2))
  end
end
