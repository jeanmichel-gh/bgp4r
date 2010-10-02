#--
# Copyright 2008, 2009 Jean-Michel Esnault.
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
end

class As_path_Test < Test::Unit::TestCase
  include BGP
  def test_1
    assert_equal('400200', As_path.new.to_shex)
    path =  As_path.new(1)
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
    path =  As_path.new(1)
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
end

class As4_path_Test < Test::Unit::TestCase
  include BGP
  def test_1
    assert_equal('c01100', As4_path.new.to_shex)
    path =  As4_path.new(1)
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
end

#MiniTest::Unit.autorun
