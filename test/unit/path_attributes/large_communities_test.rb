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

require "test/unit"
require "bgp4r"

class TestLargeCommunities < Test::Unit::TestCase
  include BGP

  # RFC 8092 section 5 example: 64496:4294967295:2
  RFC = '0000fbf0ffffffff00000002'

  def wire(hex) [hex].pack('H*').is_packed end

  def test_value
    c = Large_communities::Large_community.new('64496:4294967295:2')
    assert_equal [64496, 4294967295, 2], c.to_a
    assert_equal '64496:4294967295:2', c.to_s
    assert_equal RFC, c.encode.unpack1('H*')
    assert_equal c, Large_communities::Large_community.new([64496, 4294967295, 2])
  end

  def test_bad_values_raise
    ['1:2', '1:2:3:4', 'a:b:c', '1:2:4294967296', '-1:2:3', '', 'no_export'].each do |s|
      assert_raise(ArgumentError, s) { Large_communities::Large_community.new(s) }
    end
    assert_raise(ArgumentError) { Large_communities::Large_community.new([1, 2]) }
    assert_raise(ArgumentError) { Large_communities::Large_community.new(12) }
  end

  def test_from_values
    lc = Large_communities.new('64496:4294967295:2', [1, 2, 3])
    assert_equal 'c02018' + RFC + '000000010000000200000003', lc.to_shex
    assert_equal '64496:4294967295:2 1:2:3', lc.large_communities
    assert_equal 2, lc.size
    assert lc.is_optional?
    assert lc.is_transitive?
  end

  def test_from_a_string_list
    assert_equal '1:2:3 4:5:6 7:8:9', Large_communities.new('1:2:3 4:5:6,7:8:9').large_communities
    assert_equal '1:2:3 4:5:6', Large_communities.new(['1:2:3', [4, 5, 6]]).large_communities
  end

  def test_from_wire
    lc = Large_communities.new(wire('c0200c' + RFC))
    assert_equal '64496:4294967295:2', lc.large_communities
    assert_equal 'c0200c' + RFC, lc.to_shex
    assert_instance_of Large_communities, Attr.factory(wire('c0200c' + RFC))
  end

  def test_hash_round_trip
    lc = Large_communities.new('64496:1:1', '64496:1:2')
    h = lc.to_hash
    assert_equal({:large_communities => ['64496:1:1', '64496:1:2']}, h)
    assert_equal lc.encode, Large_communities.new(h).encode
    pa = Path_attribute.new(:origin => :igp, :large_communities => ['64496:1:1'])
    assert_equal ['64496:1:1'], pa.to_hash[:large_communities]
    assert_equal pa.encode, Path_attribute.new(pa.to_hash).encode
    assert_instance_of Large_communities, pa[:large_communities]
    assert_instance_of Large_communities, pa[ATTR::LARGE_COMMUNITY]
  end

  def test_has
    lc = Large_communities.new('64496:1:1')
    assert lc.has?('64496:1:1')
    assert lc.has?([64496, 1, 1])
    assert lc.has_no?('64496:1:2')
  end

  # RFC 8092 section 3 says not to send duplicates. bgp4r can, on purpose.
  def test_duplicates_are_kept_and_uniq_drops_them
    lc = Large_communities.new('1:2:3', '1:2:3', '4:5:6')
    assert_equal 3, lc.size
    assert_equal 3, Large_communities.new(lc.encode).size
    assert_equal '1:2:3 4:5:6', lc.uniq.large_communities
  end

  # RFC 8092 section 6: a length that is not a non-zero multiple of 12 is
  # malformed, treat-as-withdraw. The octets are kept as received.
  def test_bad_length
    hex = 'c0200d' + '000000010000000200000003' + '00'
    lc = Large_communities.new(wire(hex))
    assert_equal '1:2:3', lc.large_communities
    assert_equal hex, lc.to_shex
    pa = Path_attribute.new(wire(hex))
    assert_equal [[32, 5, :treat_as_withdraw]], pa.errors.collect { |f| [f.type, f.subcode, f.action] }
    assert_equal [[32, 5, :treat_as_withdraw]], Path_attribute.new(wire('c02000')).errors.collect { |f| [f.type, f.subcode, f.action] }
    assert_equal [], Path_attribute.new(wire('c0200c' + RFC)).errors
  end

  def test_flags_are_checked
    pa = Path_attribute.new(wire('80200c' + RFC))
    assert_equal [[32, 4, :treat_as_withdraw]], pa.errors.collect { |f| [f.type, f.subcode, f.action] }
  end

  def test_to_s
    assert_equal "[OTcr] (32) Large Communities: [c0200c0000fbf0fffffff...] '64496:4294967295:2'",
                 Large_communities.new(wire('c0200c' + RFC)).to_s(:brief)
  end

end
