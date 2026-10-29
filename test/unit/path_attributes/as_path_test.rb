#--
# Copyright 2008, 2009, 2026 Jean-Michel Esnault.
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

require 'bgp/path_attributes/as_path'
# The new test checks what Path_attribute rebuilds from an As4_path hash.
require 'bgp/path_attributes/path_attribute'
require 'test/unit'

class Segment_Test < Test::Unit::TestCase
  include BGP
  def test_1
    assert_equal(BGP::ATTR::SEQUENCE, As_path::Segment.new(:sequence, 1).seg_type)
    assert_equal([1], As_path::Segment.new(:sequence, 1).as)
    assert_equal([1,2,3], As_path::Segment.new(:sequence, 1,2,3).as)
    assert_equal('1 2 3', As_path::Segment.new(:sequence, 1,2,3).to_s)
  end
  def test_2
    assert_equal('02010001', As_path::Segment.new(:sequence, 1).to_shex)
    assert_equal('020100000001', As_path::Segment.new(:sequence, 1).to_shex(true))
    assert_equal('02010001', As_path::Segment.new(['02010001'].pack('H*')).to_shex)
    assert_equal('0203000100020003', As_path::Segment.new(:sequence, 1,2,3).to_shex)
    assert_equal('0203000100020003', As_path::Sequence.new(1,2,3).to_shex)
  end
  def test_3
    assert_equal('01010001', As_path::Segment.new(:set, 1).to_shex)
    assert_equal('030100000001', As_path::Segment.new(:confed_sequence, 1).to_shex(true))
    assert_equal('030100000001', As_path::Segment.new(:confed_sequence, 1).to_shex(true))
    assert_equal('030100000001', As_path::Confed_sequence.new(1).to_shex(true))
    assert_equal('040100000001', As_path::Confed_set.new(1).to_shex(true))
    assert_equal('02010001', As_path::Segment.new(['02010001'].pack('H*')).to_shex)
  end
  def test_4
    seg = As_path::Segment.factory(['0203000100020003'].pack('H*'))
    assert_equal(As_path::Sequence,seg.class)
    seg = As_path::Segment.factory(['0103000100020003'].pack('H*'))
    assert_equal(As_path::Set,seg.class)
    seg = As_path::Segment.factory(['0303000100020003'].pack('H*'))
    assert_equal(As_path::Confed_sequence,seg.class)
    seg = As_path::Segment.factory(['0403000100020003'].pack('H*'))
    assert_equal(As_path::Confed_set,seg.class)
    seg = As_path::Segment.factory(['0203000100020003'].pack('H*'))
    assert_equal(As_path::Sequence,seg.class)
    assert_equal('0203000100020003', seg.to_shex)
    assert_equal('0203000000010000000200000003', seg.to_shex(true))
    seg = As_path::Segment.factory(['0203000000010000000200000003'].pack('H*'), true)
    assert_equal('0203000000010000000200000003', seg.to_shex(true))
    assert_equal('0203000100020003', seg.to_shex(false))
  end
  def test_5
    assert_equal({:set=>[1, 2]},As_path::Set.new(1,2).to_hash)
    assert_equal({:sequence=>[3,4]},As_path::Sequence.new(3,4).to_hash)
    assert_equal({:confed_sequence=>[5,6]},As_path::Confed_sequence.new(5,6).to_hash)
    assert_equal({:confed_set=>[7,8]},As_path::Confed_set.new(7,8).to_hash)
  end
end

class As_path_Test < Test::Unit::TestCase
  include BGP
  def test_1
    assert_equal('400200', As_path.new.to_shex)
    assert_equal("40020402010001", As_path.new(1).to_shex)
    assert_equal("40020402010001", As_path.new(As_path::Sequence.new(1)).to_shex)
    assert_equal("40020402010001", As_path.new(As_path::Segment.new(:sequence,1)).to_shex)
    assert_equal("4002080203000100020003", As_path.new(1,2,3).to_shex)
    assert_equal("4002080203000100020003", As_path.new(As_path::Sequence.new(1,2,3)).to_shex)
    assert_equal("4002080203000100020003", As_path.new(As_path::Segment.new(:sequence,1,2,3)).to_shex)
  end
  def test_2
    path =  As_path.new(['4002080203000100020003'].pack('H*').is_packed)
    assert_equal('4002080203000100020003', path.to_shex)
    path << As_path::Set.new(1,2,3)
    path << As_path::Confed_sequence.new(1,2,3)
    assert_equal('400218020300010002000301030001000200030303000100020003', path.to_shex)
    assert_equal('40021802030...', path.to_shex_len(10))
    assert_equal("[wTcr]  (2)    As Path: [400218020300010002000...] '1 2 3 {1, 2, 3} (1 2 3)'", path.to_s)
    path.find_set.prepend(100)
    assert_equal '1 2 3 {100, 1, 2, 3} (1 2 3)', path.as_path
    path.find_sequence.prepend(100)
    assert_equal '100 1 2 3 {100, 1, 2, 3} (1 2 3)', path.as_path
  end
  def test_3
    path = As_path.new(1,2,3)
    path.as4byte=true
    assert_equal('40020e0203000000010000000200000003', path.to_shex)
    assert_equal('4002080203000100020003', path.to_shex(false))
    path.as4byte=false
    assert_equal('4002080203000100020003', path.to_shex)
    assert_equal('40020e0203000000010000000200000003', path.to_shex(true))
  end
  def test_4
    assert_equal('400200', As_path.new.to_shex)
    assert_equal("1", As_path.new(1).as_path)
    assert_equal("1", As_path.new(As_path::Sequence.new(1)).as_path)
    assert_equal("1", As_path.new(As_path::Segment.new(:sequence,1)).as_path)
    assert_equal("1 2 3 4 5 6 7", As_path.new(1,2,3,4,5,6,7).as_path)
    assert_equal("{1, 2, 3}", As_path.new(As_path::Set.new(1,2,3)).as_path)
    assert_equal("(1 2 3)", As_path.new(As_path::Segment.new(:confed_sequence,1,2,3)).as_path)
    assert_equal("[1, 2, 3]", As_path.new(As_path::Segment.new(:confed_set,1,2,3)).as_path)
    assert_equal("[wTcr]  (2)    As Path: [400208040300010002000...] '[1, 2, 3]'", As_path.new(As_path::Segment.new(:confed_set,1,2,3)).to_s)    
  end
  def test_5
    two_byte_as = '4002080203000100020003'
    four_byte_as = '40020e0203000000010000000200000003'
    path = As_path.new([four_byte_as].pack('H*'),true)
    assert_equal(two_byte_as, path.to_shex)
    assert_equal(four_byte_as, path.to_shex(true))
    path = As_path.new([two_byte_as].pack('H*'))
    assert_equal(two_byte_as, path.to_shex)
    assert_equal(four_byte_as, path.to_shex(true))
    asp = As_path.new(['40020c020500010002000300040005c0080c051f00010137003b0af50040'].pack('H*'))
    asp2 = As_path.new(asp)
    assert_equal(asp.encode, asp2.encode)
  end
  def test_6
    set1 = As_path.new_set 1,2,3,4
    set2 = As_path.new As_path.new(As_path::Set.new(1,2,3,4))
    assert_equal( set1.encode, set2.encode)
    set1 = As_path.new_sequence 1,2,3,4
    set2 = As_path.new As_path.new(As_path::Sequence.new(1,2,3,4))
    assert_equal( set1.encode, set2.encode)
    set1 = As_path.new_confed_set 1,2,3,4
    set2 = As_path.new As_path.new(As_path::Confed_set.new(1,2,3,4))
    assert_equal( set1.encode, set2.encode)
    set1 = As_path.new_confed_sequence 1,2,3,4
    set2 = As_path.new As_path.new(As_path::Confed_sequence.new(1,2,3,4))
    assert_equal( set1.encode, set2.encode)
  end
  def test_7
    set1 = As_path.new_hash :set=> [1,2,3,4]
    set2 = As_path.new As_path.new(As_path::Set.new(1,2,3,4))
    assert_equal( set1.encode, set2.encode)
    set1 = As_path.new_hash :sequence=> [1,2,3,4]
    set2 = As_path.new As_path.new(As_path::Sequence.new(1,2,3,4))
    assert_equal( set1.encode, set2.encode)
    set1 = As_path.new_hash :confed_set=> [1,2,3,4]
    set2 = As_path.new As_path.new(As_path::Confed_set.new(1,2,3,4))
    assert_equal( set1.encode, set2.encode)
    set1 = As_path.new_hash :confed_sequence=> [1,2,3,4]
    set2 = As_path.new As_path.new(As_path::Confed_sequence.new(1,2,3,4))
    assert_equal( set1.encode, set2.encode)
  end
  def test_8
    set = As_path.new_hash :set=> [1,2], :sequence=>[3,4], :confed_sequence=>[5,6], :confed_set=>[7,8]
    assert_equal('400218010200010002020200030004030200050006040200070008', set.to_shex)
    assert_equal [1,2], set.to_hash[:as_path][:set]
    assert_equal [3,4], set.to_hash[:as_path][:sequence]
    assert_equal [5,6], set.to_hash[:as_path][:confed_sequence]
    assert_equal [7,8], set.to_hash[:as_path][:confed_set]
    set1 = As4_path.new
    set1 << As_path::Set.new(1,2)
    set1 << As_path::Sequence.new(3,4)
    set1 << As_path::Confed_sequence.new(5,6)
    set1 << As_path::Confed_set.new(7,8)
    set2 = As4_path.new_hash :set=> [1,2], :sequence=>[3,4], :confed_sequence=>[5,6], :confed_set=>[7,8]
    assert_equal(set1.to_shex, set2.to_shex)    
    # :as4_path, not :as_path. set2 is an As4_path, and it used to hash
    # under its parent's key, which made Path_attribute rebuild a 2 octet
    # AS_PATH from it and cut the AS numbers.
    assert_equal [1,2], set2.to_hash[:as4_path][:set]
    assert_equal [3,4], set2.to_hash[:as4_path][:sequence]
    assert_equal [5,6], set2.to_hash[:as4_path][:confed_sequence]
    assert_equal [7,8], set2.to_hash[:as4_path][:confed_set]
  end
  # to_hash used to merge every segment into one hash, so all but the
  # last segment of a type was lost and the hash did not round trip.
  def test_to_hash_keeps_repeated_sequences
    path = As_path.new(As_path::Sequence.new(1,2), As_path::Sequence.new(3,4))
    assert_equal({:as_path=>{:segments=>[{:sequence=>[1,2]}, {:sequence=>[3,4]}]}}, path.to_hash)
    assert_equal('1 2 3 4', path.as_path)
    assert_equal(path.to_shex, As_path.new(path.to_hash).to_shex)
    assert_equal(path.to_hash, As_path.new(path.to_hash).to_hash)
    assert_equal(path.to_shex, As_path.new_hash(path.to_hash[:as_path]).to_shex)
  end
  def test_to_hash_keeps_a_set_between_two_sequences
    path = As_path.new(As_path::Sequence.new(1,2), As_path::Set.new(3), As_path::Sequence.new(4,5))
    assert_equal({:as_path=>{:segments=>[{:sequence=>[1,2]}, {:set=>[3]}, {:sequence=>[4,5]}]}}, path.to_hash)
    assert_equal('1 2 {3} 4 5', path.as_path)
    assert_equal('40021002020001000201010003020200040005', path.to_shex)
    assert_equal(path.to_shex, As_path.new(path.to_hash).to_shex)
    assert_equal(path.to_hash, As_path.new(path.to_hash).to_hash)
  end
  # RFC 5065 section 3: a path can carry more than one confederation
  # segment of the same type.
  def test_to_hash_keeps_repeated_confederation_segments
    path = As_path.new(As_path::Confed_sequence.new(65001,65002), As_path::Confed_set.new(65003),
                       As_path::Confed_sequence.new(65004), As_path::Sequence.new(1))
    assert_equal({:as_path=>{:segments=>[{:confed_sequence=>[65001,65002]}, {:confed_set=>[65003]},
                                         {:confed_sequence=>[65004]}, {:sequence=>[1]}]}}, path.to_hash)
    assert_equal('4002120302fde9fdea0401fdeb0301fdec02010001', path.to_shex)
    assert_equal(path.to_shex, As_path.new(path.to_hash).to_shex)
    assert_equal(path.to_hash, As_path.new(path.to_hash).to_hash)
  end
  def test_to_hash_round_trips_a_path_parsed_from_wire_bytes
    wire = '40021002020001000201010003020200040005'
    path = As_path.new([wire].pack('H*').is_packed)
    assert_equal(wire, path.to_shex)
    assert_equal(wire, As_path.new(path.to_hash).to_shex)
    assert_equal(path.to_hash, As_path.new(path.to_hash).to_hash)
    four_byte = '40021a0202000000010000000201010000000302020000000400000005'
    path4 = As_path.new([four_byte].pack('H*').is_packed, true)
    assert_equal(path.to_hash, path4.to_hash)
    assert_equal(four_byte, As_path.new(path4.to_hash).to_shex(true))
  end
  def test_as4_path_to_hash_keeps_repeated_segments
    path = As4_path.new(As_path::Sequence.new(100,4200000001), As_path::Sequence.new(200))
    assert_equal({:as4_path=>{:segments=>[{:sequence=>[100,4200000001]}, {:sequence=>[200]}]}}, path.to_hash)
    assert_equal(path.to_shex, As4_path.new(path.to_hash).to_shex)
    assert_equal(path.to_hash, As4_path.new(path.to_hash).to_hash)
  end
  # Its own key, for the same reason As4_aggregator has one: it used to
  # inherit As_path's :as_path, so Path_attribute rebuilt a type 2
  # AS_PATH from this hash, in the 2 octet form, and cut the AS numbers
  # with it. segments_from_hash reads either key, so a build straight
  # from the hash went on working and nothing said anything.
  def test_as4_path_hashes_under_its_own_key
    path = BGP::As4_path.new(BGP::As_path::Sequence.new(4200000001, 2))
    assert_equal({:as4_path=>{:sequence=>[4200000001, 2]}}, path.to_hash)
    assert_equal(path.encode, BGP::Path_attribute.new(path.to_hash).encode)
    assert_equal(BGP::As4_path, BGP::Path_attribute.new(path.to_hash)[:as4_path].class)
  end
  # The one key per segment type hash is still what to_hash returns
  # while no type repeats, and new_hash still takes it.
  def test_one_key_per_segment_type_hash_still_works
    assert_equal({:as_path=>{:sequence=>[1,2]}}, As_path.new_hash(:sequence=>[1,2]).to_hash)
    old = {:set=>[1,2], :sequence=>[3,4], :confed_sequence=>[5,6], :confed_set=>[7,8]}
    assert_equal('400218010200010002020200030004030200050006040200070008', As_path.new_hash(old).to_shex)
    assert_equal({:as_path=>old}, As_path.new_hash(old).to_hash)
    assert_equal(As_path.new_hash(old).to_shex, As_path.new(:as_path=> old).to_shex)
    assert_equal('400200', As_path.new_hash({}).to_shex)
    assert_equal('400200', As_path.new(:as_path=>{}).to_shex)
    assert_equal('4002040201006f', As_path.new_hash('sequence'=>111).to_shex)
    assert_equal('4002040201006f', As_path.new(:segments=>[{'sequence'=>111}]).to_shex)
  end
  def test_hash_with_an_unknown_segment_type_raises
    assert_raise(ArgumentError) { As_path.new_hash(:carrier_pigeon=>[1,2]) }
    assert_raise(ArgumentError) { As_path.new(:as_path=>{:carrier_pigeon=>[1,2]}) }
    assert_raise(ArgumentError) { As_path.new(:segments=>[{:sequence=>[1], :set=>[2]}]) }
    assert_raise(ArgumentError) { As_path.new_hash(As_path::Sequence.new(1)) }
  end
  def test_segments
    path = As_path.new(As_path::Segment.new(:sequence, 1, 2), As_path::Segment.new(:set, 3, 4))
    segs = path.segments
    assert_equal([As_path::SEQUENCE, As_path::SET], segs.map(&:seg_type))
    assert_equal([[1, 2], [3, 4]], segs.map(&:as))
    segs.clear
    assert_equal(2, path.segments.size, 'segments returns a copy')
    assert_equal([], As_path.new.segments)
  end
end

class As4_path_Test < Test::Unit::TestCase
  include BGP
  def test_1
    assert_equal('c01100', As4_path.new.to_shex)
    assert_equal("c01106020100000001", As4_path.new(1).to_shex)
    assert_equal("c01106020100000001", As4_path.new(As_path::Sequence.new(1)).to_shex)
    assert_equal("c01106020100000001", As4_path.new(As_path::Segment.new(:sequence,1)).to_shex)
    assert_equal("c0110e0203000000010000000200000003", As4_path.new(1,2,3).to_shex)
    assert_equal("c0110e0203000000010000000200000003", As4_path.new(As_path::Sequence.new(1,2,3)).to_shex)
    assert_equal("c0110e0203000000010000000200000003", As4_path.new(As_path::Segment.new(:sequence,1,2,3)).to_shex)
  end
  def test_2
    path =  As4_path.new(['c0110e0203000000010000000200000003'].pack('H*'))
    assert_equal('c0110e0203000000010000000200000003', path.to_shex)
    path << As_path::Set.new(1,2,3)
    path << As_path::Confed_sequence.new(1,2,3)
    assert_equal('c0112a020300000001000000020000000301030000000100000002000000030303000000010000000200000003', path.to_shex)
    assert_equal('c0112a02030...', path.to_shex_len(10))
    assert_equal('1 2 3 {1, 2, 3} (1 2 3)',path.as_path)
    assert_equal("[OTcr] (17)   As4 Path: [c0112a020300000001000...] '1 2 3 {1, 2, 3} (1 2 3)'",path.to_s)
  end
  # RFC 6793 section 3: 4-octet AS numbers even when asked for 2.
  def test_as4_path_encode_is_always_4_octets
    path = As4_path.new(As_path::Sequence.new(100, 4200000001))
    assert_equal 'c0110a020200000064fa56ea01', path.encode(false).unpack1('H*')
    assert_equal path.encode(true), path.encode(false)
  end

  # new used to ignore a bare hash of segment types and build an empty
  # path from it, while new_hash built the real thing.
  def test_new_takes_a_bare_segment_hash
    h = { :set=> [1,2], :sequence=> [3,4] }
    assert_equal '40020c010200010002020200030004', As_path.new(h).to_shex
    assert_equal As_path.new_hash(h).to_shex, As_path.new(h).to_shex
    assert_equal '{1, 2} 3 4', As_path.new(h).as_path
    # Order of the keys is the order of the segments on the wire.
    assert_not_equal As_path.new(:set=> [1,2], :sequence=> [3,4]).to_shex,
                     As_path.new(:sequence=> [3,4], :set=> [1,2]).to_shex
    # RFC 5065 section 3 confederation segments, and the subclass.
    c = { :confed_sequence=> [1,2], :confed_set=> [3] }
    assert_equal As4_path.new_hash(c).to_shex, As4_path.new(c).to_shex
    assert_equal '(1 2) [3]', As4_path.new(c).as_path
  end

  def test_the_other_hash_shapes_still_build
    seq = As_path.new(As_path::Sequence.new(1,2))
    assert_equal seq.to_shex, As_path.new(seq.to_hash).to_shex
    assert_equal seq.to_shex, As_path.new(:sequence=> [1,2]).to_shex
    assert_equal seq.to_shex, As_path.new(:segments=> [{ :sequence=> [1,2] }]).to_shex
    two = As_path.new(As_path::Sequence.new(1,2), As_path::Sequence.new(3,4))
    assert_equal two.to_shex, As_path.new(two.to_hash).to_shex
  end

  # An argument new cannot turn into segments is refused. It used to
  # return an AS_PATH of no segments with no warning, so a caller who
  # mistyped sent an empty path and never knew.
  def test_an_uninterpretable_argument_raises
    [{ :bogus=> [1,2] }, '1 2', :igp, [1,2], 1.5].each do |arg|
      assert_raise(ArgumentError, arg.inspect) { As_path.new(arg) }
    end
  end

  # No argument, or nil, stays an empty path to add segments to.
  def test_an_empty_path_is_still_allowed
    assert_equal '400200', As_path.new.to_shex
    assert_equal '400200', As_path.new(nil).to_shex
    path = As_path.new
    path << As_path::Sequence.new(1,2)
    assert_equal '400206020200010002', path.to_shex
  end
end

#MiniTest::Unit.autorun
