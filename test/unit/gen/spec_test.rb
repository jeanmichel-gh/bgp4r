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
require 'bgp/gen/spec'

# What a spec reader refuses is the whole of its job, so most of these
# are refusals. Each asserts the message names what was wrong, because a
# refusal that does not say which key is the next question a user asks.
class TestBgpGenSpec < Test::Unit::TestCase
  S = BGP::Gen::Spec

  def minimal
    { 'start' => '10.0.0.0/24', 'count' => 1 }
  end

  def refused(spec, pattern)
    e = assert_raise(BGP::Gen::SpecError) { S.read(spec) }
    assert_match(pattern, e.message)
  end

  def test_the_family_defaults_to_unicast
    assert_equal('unicast', S.read(minimal)['family'])
  end

  def test_symbol_and_string_keys_read_the_same
    a = S.read(:start => '10.0.0.0/24', :count => 3, :family => :unicast,
               :attributes => { :med => 5, :as_path => [1, 2] })
    b = S.read('start' => '10.0.0.0/24', 'count' => 3, 'family' => 'unicast',
               'attributes' => { 'med' => 5, 'as_path' => [1, 2] })
    assert_equal(b, a)
  end

  def test_a_key_given_twice_is_refused
    refused(minimal.merge(:count => 2), /'count' twice/)
  end

  def test_an_unread_key_is_absent_rather_than_nil
    assert_equal(%w[family start count attributes].sort, S.read(minimal).keys.sort)
  end

  def test_every_key_reads
    s = S.read('family' => 'unicast', 'afi' => 1, 'count' => 10, 'per_update' => 5,
               'start' => '10.0.0.0/24', 'path_id' => 0xffffffff,
               'attributes' => { 'origin' => 2, 'next_hop' => '192.0.2.1', 'as_path' => [65010, 4200000000],
                                 'med' => 0, 'local_pref' => 0xffffffff, 'communities' => '65000:1',
                                 'extended_communities' => ['route_target:65000:7'],
                                 'large_communities' => ['65000:1:1'] })
    assert_equal(%w[family afi count per_update start path_id attributes].sort, s.keys.sort)
    assert_equal(['65000:1'], s['attributes']['communities'], 'a single string is a list of one')
    assert_equal(8, s['attributes'].size)
  end

  def test_a_spec_is_a_hash
    refused([], /a spec is a Hash/)
  end

  def test_an_unknown_key_is_refused_and_named
    refused(minimal.merge('prefixes' => []), /unknown key 'prefixes'/)
  end

  # docs/route-generation.md section 4 has these keys and phase 2 reads
  # them. Ignoring a seed would answer one seed's octets for another.
  def test_a_key_of_a_later_phase_is_refused_as_such
    refused(minimal.merge('seed' => 7), /'seed' is in the spec format.*phase 2/)
    refused(minimal.merge('group' => 10), /'group'.*phase 2/)
  end

  def test_start_and_count_are_required
    refused({ 'count' => 1 }, /start is required/)
    refused({ 'start' => '10.0.0.0/8' }, /count is required/)
  end

  def test_a_value_of_the_wrong_type_is_refused
    refused(minimal.merge('count' => '10'), /count is an integer/)
    refused(minimal.merge('start' => 10), /start is a string/)
    refused(minimal.merge('family' => 1), /family is a name/)
    refused(minimal.merge('attributes' => []), /attributes is a Hash/)
    refused(minimal.merge('attributes' => { 'med' => 1.5 }), /attributes.med is an integer/)
    refused(minimal.merge('attributes' => { 'as_path' => 65010 }), /as_path is a list/)
    refused(minimal.merge('attributes' => { 'as_path' => ['65010'] }), /as_path holds "65010"/)
    refused(minimal.merge('attributes' => { 'communities' => [1] }), /communities is a list of strings/)
  end

  def test_a_count_or_per_update_below_one_is_refused
    refused(minimal.merge('count' => 0), /count is at least 1/)
    refused(minimal.merge('per_update' => 0), /per_update is at least 1/)
  end

  # Conventions: a constructor may refuse what a field cannot hold, since
  # packing it would send a different value.
  def test_a_number_too_large_for_its_field_is_refused
    refused(minimal.merge('path_id' => 2**32), /path_id 4294967296 does not fit/)
    refused(minimal.merge('attributes' => { 'origin' => 256 }), /origin 256 does not fit/)
    refused(minimal.merge('attributes' => { 'med' => 2**32 }), /med .* does not fit/)
    refused(minimal.merge('attributes' => { 'as_path' => [2**32] }), /as_path holds 4294967296/)
  end

  def test_an_unknown_attribute_is_refused_and_named
    refused(minimal.merge('attributes' => { 'weight' => 1 }), /unknown attribute 'weight'/)
  end

  def test_a_pattern_is_refused_until_phase_2
    refused(minimal.merge('attributes' => { 'med' => { 'cycle' => [1, 2] } }), /attributes.med is a pattern.*phase 2/)
  end

  # Nothing validates: these are no RFC's idea of a route and all read.
  def test_nothing_validates
    s = S.read('start' => '10.0.0.0/24', 'count' => 1,
               'attributes' => { 'origin' => 255, 'as_path' => [0, 23456],
                                 'next_hop' => '0.0.0.0', 'communities' => [] })
    assert_equal(255, s['attributes']['origin'])
    assert_equal([0, 23456], s['attributes']['as_path'])
  end

  def test_reading_does_not_change_the_callers_spec
    spec = { :start => '10.0.0.0/24', :count => 1, :attributes => { :as_path => [1] } }
    copy = Marshal.load(Marshal.dump(spec))
    S.read(spec)[ 'attributes']['as_path'] << 2
    assert_equal(copy, spec)
  end
end
