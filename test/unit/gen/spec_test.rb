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

  # Phase 2 reads seed and group, which phase 1 refused by name.
  def test_seed_and_group_read
    s = S.read(minimal.merge('seed' => 7, 'group' => 10))
    assert_equal([7, 10], [s['seed'], s['group']])
    refused(minimal.merge('group' => 0), /group is at least 1/)
    refused(minimal.merge('seed' => '7'), /seed is an integer/)
  end

  # Phase 4a reads a label, as a value or a pattern, kept as given.
  # Which family may have one is Gen's to say, since Spec reads no family.
  def test_a_label_reads_and_is_20_bits
    assert_equal(16, S.read(minimal.merge('label' => 16))['label'])
    assert_equal({ 'step' => { 'start' => 16, 'by' => 1 } },
                 S.read(minimal.merge('label' => { 'step' => { 'start' => 16, 'by' => 1 } }))['label'])
    refused(minimal.merge('label' => 2**20), /label: 1048576 does not fit/)
    refused(minimal.merge('label' => '16'), /label/)
    assert_equal({ 'label' => %w[labelled] }, S::FAMILY_KEYS)
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
    refused(minimal.merge('attributes' => { 'med' => 1.5 }), /attributes.med: 1.5 is not an integer/)
    refused(minimal.merge('attributes' => { 'as_path' => 65010 }), /attributes.as_path: an AS_PATH is a list/)
    refused(minimal.merge('attributes' => { 'as_path' => ['65010'] }), /"65010" is not an AS number/)
    refused(minimal.merge('attributes' => { 'communities' => [1] }), /attributes.communities: a list of strings/)
    refused(minimal.merge('attributes' => { 'next_hop' => 'gw' }), /attributes.next_hop: "gw" is not an address/)
  end

  def test_a_count_or_per_update_below_one_is_refused
    refused(minimal.merge('count' => 0), /count is at least 1/)
    refused(minimal.merge('per_update' => 0), /per_update is at least 1/)
  end

  # Conventions: a constructor may refuse what a field cannot hold, since
  # packing it would send a different value.
  def test_a_number_too_large_for_its_field_is_refused
    refused(minimal.merge('path_id' => 2**32), /path_id: 4294967296 does not fit/)
    refused(minimal.merge('attributes' => { 'origin' => 256 }), /origin: 256 does not fit/)
    refused(minimal.merge('attributes' => { 'med' => 2**32 }), /med: .* does not fit/)
    refused(minimal.merge('attributes' => { 'as_path' => [2**32] }), /4294967296 is not an AS number/)
    refused(minimal.merge('seed' => 1, 'attributes' => { 'med' => { 'cycle' => [1, 2**32] } }),
            /med: 4294967296 does not fit/)
  end

  def test_an_unknown_attribute_is_refused_and_named
    refused(minimal.merge('attributes' => { 'weight' => 1 }), /unknown attribute 'weight'/)
  end

  # A pattern stays a Hash with String keys in what read answers, so a
  # spec that went through read reads again as itself.
  def test_a_pattern_is_kept_as_its_hash
    s = S.read(minimal.merge(:seed => 1, :attributes => { :med => { :step => { :start => 1, :by => 2 } } }))
    assert_equal({ 'step' => { 'start' => 1, 'by' => 2 } }, s['attributes']['med'])
    assert_equal(s, S.read(s))
  end

  # A pattern bgp4r cannot read is refused when the spec is, and not
  # when a generator first asks for a value.
  def test_a_bad_pattern_is_refused_with_the_spec
    refused(minimal.merge('attributes' => { 'med' => { 'zigzag' => [1] } }), /unknown pattern 'zigzag'/)
    refused(minimal.merge('attributes' => { 'med' => { 'random' => { 'min' => 1, 'max' => 2 } } }),
            /needs the spec's seed/)
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
