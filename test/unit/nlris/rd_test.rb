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

require 'bgp/nlris/rd'

require 'test/unit'
require 'stringio'
class Rd_Test < Test::Unit::TestCase
  include BGP
  def test_1
    assert_equal('RD=1:1 (0x01 0x0001)',Rd.new(1,1).to_s)
    assert_equal('0000000100000001',Rd.new(1,1).to_shex)
    assert_equal('RD=1.1.1.1:1 (0x1010101 0x01)',Rd.new('1.1.1.1',1).to_s)
    assert_equal('0001010101010001',Rd.new('1.1.1.1',1).to_shex)
    assert_equal('RD=1:257 (0x0001 0x101)', Rd.new(1,257,2).to_s)
    assert_equal('0002000000010101', Rd.new(1,257,2).to_shex)
    assert_equal('RD=1:1 (0x01 0x0001)',Rd.new(1,1,0).to_s)
    assert_equal('RD=1:1 (0x0001 0x01)',Rd.new(1,1,2).to_s)
    assert_equal('RD=1:1 (0x01 0x0001)',Rd.new(:rd=>[1,1]).to_s)
    assert_equal({:rd=>[1,1]},Rd.new(:rd=>[1,1]).to_hash)
  end
  def test_2
    assert_equal('0000000100000001', Rd.new(['0000000100000001'].pack('H*')).to_shex)
    assert_equal('0001010101010001', Rd.new(['0001010101010001'].pack('H*')).to_shex)
    assert_equal('0002000000010101', Rd.new(['0002000000010101'].pack('H*')).to_shex)
  end
  # RFC 4364 section 4.2 type 1: a 4 octet IPv4 administrator and a
  # 2 octet assigned number. The three argument form names the type.
  def test_type_1_with_an_explicit_encoding_type
    rd = Rd.new('10.0.0.1', 65535, 1)
    assert_equal 1, rd.encoding_type?
    assert_equal '10.0.0.1', rd.admin.to_s
    assert_equal 65535, rd.assign
    assert_equal '00010a000001ffff', rd.to_shex
    assert_equal 'RD=10.0.0.1:65535', rd.to_s(false)
    assert_equal({:rd=>['10.0.0.1', 65535]}, rd.to_hash)
    assert_equal rd.to_shex, Rd.new(rd.encode).to_shex
  end
  def test_explicit_encoding_types_match_the_inferred_ones
    assert_equal Rd.new(1, 1).to_shex, Rd.new(1, 1, 0).to_shex
    assert_equal Rd.new('1.1.1.1', 1).to_shex, Rd.new('1.1.1.1', 1, 1).to_shex
    assert_equal 0, Rd.new(1, 1).encoding_type?
    assert_equal 1, Rd.new('1.1.1.1', 1).encoding_type?
    # The two argument form no longer reads a String assigned number as an
    # inferred type 2, so type 2 is named: see the refusal test below.
    assert_equal 2, Rd.new(1, 257, 2).encoding_type?
    assert_equal 0, Rd.new.encoding_type?
  end
  def test_built_from_another_rd
    # Rd.new(Rd) goes through encode and parse, so the copy is byte for
    # byte what the original puts on the wire.
    [Rd.new(1, 1), Rd.new('1.1.1.1', 1), Rd.new(65536, 1, 2), Rd.new].each do |rd|
      copy = Rd.new(rd)
      assert_equal rd.to_shex, copy.to_shex
      assert_equal rd.encoding_type?, copy.encoding_type?
      assert_equal rd.to_s(false), copy.to_s(false)
      assert_equal rd.to_hash, copy.to_hash
    end
  end
  def test_terse_to_s
    assert_equal 'RD=1:1', Rd.new(1, 1).to_s(false)
    assert_equal 'RD=1.1.1.1:1', Rd.new('1.1.1.1', 1).to_s(false)
    assert_equal 'RD=1:1', Rd.new(1, 1, 2).to_s(false)
    assert_equal 'RD=65536:1', Rd.new(65536, 1, 2).to_s(false)
  end
  def test_zero_rd
    # The all zero RD, which an MP_REACH next hop carries ahead of the
    # address (RFC 4364 section 4.3.2).
    rd = Rd.new
    assert_equal '0000000000000000', rd.to_shex
    assert_equal({:rd=>[0, 0]}, rd.to_hash)
    assert_equal 'RD=0:0', rd.to_s(false)
    assert_equal 64, rd.bit_length
  end
  # RFC 4364 section 4.2 gives encoding type 0 a 2 octet administrator and a
  # 4 octet assigned number. The verbose form used to print the assigned
  # number in both places, so the administrator never showed.
  def test_type_0_verbose_to_s_prints_its_administrator
    assert_equal 'RD=7:9 (0x07 0x0009)', Rd.new(7, 9).to_s
    assert_equal 'RD=65535:65536 (0xffff 0x10000)', Rd.new(65535, 65536).to_s
  end
  # One line per encoding type, each printing its own two fields.
  def test_verbose_to_s_prints_each_types_own_fields
    assert_equal 'RD=7:9 (0x07 0x0009)', Rd.new(7, 9, 0).to_s
    assert_equal 'RD=1.1.1.1:9 (0x1010101 0x09)', Rd.new('1.1.1.1', 9, 1).to_s
    assert_equal 'RD=7:9 (0x0007 0x09)', Rd.new(7, 9, 2).to_s
  end
  # RFC 4364 section 4.2 gives encoding types 1 and 2 a 2 octet assigned
  # number, so a 32 bit address cannot go there. The constructor says so
  # instead of keeping a value its own encode truncates.
  def test_an_address_is_refused_as_an_assigned_number
    e = assert_raise(ArgumentError) { Rd.new(1, '1.1.1.1') }
    assert_match(/1\.1\.1\.1/, e.message)
    assert_match(/RFC 4364/, e.message)
  end
  # Refusing the String leaves every octet level route open.
  def test_a_type_2_assigned_number_can_still_be_built_and_agrees_with_its_bytes
    assert_equal '0002000000010101', Rd.new(1, 257, 2).to_shex
    wire = ['0002000000010101'].pack('H*')
    assert_equal '0002000000010101', Rd.new(wire).to_shex
    assert_equal 'RD=1:257', Rd.new(wire).to_s(false)
    rd = Rd.new(1, 257, 2)
    assert_equal rd.to_s(false), Rd.new(rd.encode).to_s(false)
  end
  def test_unknown_type_raises_quietly
    out, $stdout = $stdout, StringIO.new
    assert_raise(ArgumentError) { Rd.new(['0003000000010001'].pack('H*')) }
    assert_equal('', $stdout.string)
  ensure
    $stdout = out
  end
end
