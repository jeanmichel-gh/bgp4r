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

# The speaker's generate announce block and the record: count mode,
# without a session.
#
#   ruby -I. test/functional/lab/generate_test.rb

require 'test/unit'
require_relative '../../../lab/speaker'

class LabGenerateTest < Test::Unit::TestCase
  BLOCK = { 'generate' => { 'start' => '11.0.0.0/28', 'count' => 10, 'per_update' => 4 },
            'med' => 100, 'communities' => ['100:1', '200:1'], 'as_path' => [90, 80] }

  def speaker
    Lab::Speaker.new('as' => 65001, 'router_id' => '10.20.0.1', 'neighbors' => [])
  end

  def updates(block, ebgp, env={})
    list = []
    speaker.each_update(block, ebgp, '10.20.0.1', nil, env) { |u| list << u }
    list
  end

  def test_generate_packs_prefixes
    list = updates(BLOCK, true)
    assert_equal([4, 4, 2], list.map { |u| u.nlri.size })
    assert_equal('11.0.0.0/28', list.first.nlri.to_ary.first)
    assert_equal('11.0.0.144/28', list.last.nlri.to_ary.last)
  end

  # RFC 4271 section 5.1: over eBGP, our AS first and NEXT_HOP is us.
  def test_generate_ebgp_attributes
    a = Lab::Recorder.attributes(updates(BLOCK, true).first.path_attribute)
    assert_equal('65001 90 80', a['as_path'])
    assert_equal('10.20.0.1', a['next_hop'])
    assert_equal(100, a['med'])
    assert_equal('100:1 200:1', a['communities'])
    assert_nil(a['local_pref'])
  end

  def test_generate_ibgp_attributes
    a = Lab::Recorder.attributes(updates(BLOCK, false).first.path_attribute)
    assert_equal('90 80', a['as_path'])
    assert_equal(100, a['local_pref'])
  end

  def test_generate_has_the_same_attributes_as_prefixes
    plain = BLOCK.reject { |k, _| k == 'generate' }.merge('prefixes' => ['11.0.0.0/28'])
    [true, false].each do |ebgp|
      assert_equal(updates(plain, ebgp).first.path_attribute.to_hash,
                   updates(BLOCK, ebgp).first.path_attribute.to_hash)
    end
  end

  def test_prefixes_block_is_one_update
    list = updates({ 'prefixes' => ['192.168.1.0/24', '192.168.2.0/24'] }, true)
    assert_equal(1, list.size)
    assert_equal(['192.168.1.0/24', '192.168.2.0/24'], list[0].nlri.to_ary)
  end

  def test_env_overrides_count_and_per_update
    env = { 'ROUTEGEN_COUNT' => '300', 'ROUTEGEN_PER_UPDATE' => '127' }
    assert_equal([127, 127, 46], updates(BLOCK, true, env).map { |u| u.nlri.size })
    assert_equal({ 'start' => '11.0.0.0/28', 'count' => 10, 'per_update' => 4 },
                 Lab::Speaker.generate_options(BLOCK['generate'], 'ROUTEGEN_COUNT' => ' '))
  end

  def test_generate_errors
    assert_raise(ArgumentError) { Lab::Speaker.generate_options('11.0.0.0/28', {}) }
    assert_raise(KeyError) { Lab::Speaker.generate_options({ 'count' => 1 }, {}) }
    assert_raise(ArgumentError) { Lab::Speaker.generate_options(BLOCK['generate'], 'ROUTEGEN_COUNT' => 'many') }
    assert_raise(ArgumentError) { Lab::Recorder.new('everything') }
  end

  def update(nlri: [], withdrawn: [])
    u = BGP::Update.new(BGP::Path_attribute.new(BGP::Origin.new(0), BGP::Next_hop.new('10.0.0.1'), BGP::As_path.new(1)),
                        BGP::Nlri.new(*nlri))
    u.withdrawn = BGP::Withdrawn.new(*withdrawn) unless withdrawn.empty?
    u
  end

  def test_count_mode_keeps_counters_not_routes
    r = Lab::Recorder.new('count')
    r.update(BGP::Keepalive.new)
    r.update(update(nlri: ['11.0.0.0/28', '11.0.0.16/28', '11.0.0.32/28']))
    r.update(update(nlri: ['11.0.0.48/28'], withdrawn: ['11.0.0.0/28']))
    s = r.snapshot
    assert_nil(s['received'])
    assert_equal(3, s['prefixes_received'])
    assert_equal(2, s['updates_received'])
    assert_equal('11.0.0.0/28', s['first_prefix'])
    assert_equal('11.0.0.48/28', s['last_prefix'])
    assert_not_nil(s['established_at'])
    assert_not_nil(s['first_update_at'])
    assert_operator(s['seconds_to_last_update'], :>=, 0)
    r.session_down!
    s = r.snapshot
    assert_equal(0, s['prefixes_received'])
    assert_nil(s['last_update_at'])
  end

  def test_routes_mode_also_counts_and_times
    r = Lab::Recorder.new
    r.update(BGP::Keepalive.new)
    r.update(update(nlri: ['11.0.0.0/28', '11.0.0.16/28']))
    r.update(update(withdrawn: ['11.0.0.16/28']))
    s = r.snapshot
    assert_equal(['11.0.0.0/28'], s['received'].keys)
    assert_equal(1, s['prefixes_received'])
    assert_not_nil(s['last_update_at'])
    assert_false(s.key?('first_prefix'))
  end
end
