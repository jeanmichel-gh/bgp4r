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

require 'bgp/nlris/label'
require 'test/unit'

class Label_Test < Test::Unit::TestCase
  include BGP
  def test_1
    l1 =  Label.new(:label=>100, :exp=>1)
    l2 =  Label.new(100,1)
    l3 =  Label.new(l2.encode)
    assert_equal(l1.to_shex, l2.to_shex)
    assert_equal(l1.to_shex, l3.to_shex)
    assert_equal('000641', Label.new(100).to_shex)
    assert_equal('000643', Label.new(100,1).to_shex)
    assert_equal({:label=>100, :exp=>1},Label.new(100,1).to_hash)
    assert_equal({:label=>100, :exp=>1}, Label.new(:label=>100, :exp=>1).to_hash)
    assert_equal({:label=>100, :exp=>0}, Label.new(:label=>100).to_hash)
  end

  # RFC 8277 section 2.2 on the Bottom of Stack bit: "This 1-bit field MUST
  # be set to one on transmission and MUST be ignored on reception". encode
  # wrote 1 for everything, so a label read off the wire with the bit clear
  # came back with it set. The case that matters is the Compatibility field
  # of section 2.4, which "SHOULD be set to 0x800000": its low octet is
  # zero, so the three octets a peer sent came back as 0x800001.
  def test_a_label_keeps_the_bottom_of_stack_bit_it_arrived_with
    { '800000' => [524288, 0, 0],   # the section 2.4 Compatibility field
      '000640' => [100, 0, 0],
      '000641' => [100, 0, 1],
      '00064f' => [100, 7, 1],
      '00064e' => [100, 7, 0],
    }.each do |hex, (label, exp, bottom)|
      l = Label.new([hex].pack('H*'))
      assert_equal(label, l.label, hex)
      assert_equal(bottom, l.bottom, hex)
      assert_equal(hex, l.to_shex, hex)
      # The hash carries the bit only when it is clear, since a build from
      # the hash writes 1 without it, and it builds the same octets back.
      assert_equal(bottom == 0, l.to_hash.key?(:bottom), hex)
      assert_equal(hex, Label.new(l.to_hash).to_shex, hex)
      assert_equal({:label=> label, :exp=> exp}, l.to_hash.reject { |k, _| k == :bottom }, hex)
    end
  end

  # A label built from values still writes the bit set, which is what
  # section 2.2 asks a sender for and what every caller had before.
  def test_a_label_built_from_values_sets_the_bottom_of_stack_bit
    assert_nil(Label.new(100).bottom)
    assert_equal('000641', Label.new(100).to_shex)
    assert_equal('000641', Label.new(:label=>100).to_shex)
    assert_equal('000643', Label.new(100, 1).to_shex)
    # And a hash can ask for it clear, which is how a withdrawal is built.
    assert_equal('800000', Label.new(:label=>524288, :bottom=>0).to_shex)
    # The caller's own argument still wins, which is what Label_stack uses
    # for every entry above the bottom of a stack.
    assert_equal('000640', Label.new(100).encode(0).unpack('H*')[0])
  end
end

class Label_stack_Test < Test::Unit::TestCase
  include BGP
  def test_1
    ls =  Label_stack.new(100,101,102)
    assert_equal('000640000650000661', ls.to_shex)
    assert_equal('Label Stack=100,101,102 (bottom)', ls.to_s)
    assert_equal('Label stack:(empty)', Label_stack.new.to_s)
    assert_equal(ls.encode, Label_stack.new(['000640000650000661'].pack('H*')).encode)
    assert_equal("Label Stack=100,101 (bottom)", Label_stack.new(['000640000651000661'].pack('H*')).to_s)
    assert_equal({:labels=>[100,101]}, Label_stack.new(['000640000651000661'].pack('H*')).to_hash)
    assert_equal({:labels=>[100,101,102]}, ls.to_hash)
    ls = Label_stack.new :labels=>[100,101,102]
    assert_equal('000640000650000661', ls.to_shex)
  end

  # Two things went wrong on a stack whose last entry arrived with the
  # Bottom of Stack bit clear, which is what RFC 8277 section 2.4's
  # Compatibility field is. The walk read on past the end of the octets and
  # raised NoMethodError on nil, and where it did not, encode set the bit
  # the entry did not have.
  def test_a_stack_whose_last_entry_has_the_bit_clear_round_trips
    ['000640', '800000', '000640000650'].each do |hex|
      st = Label_stack.new([hex].pack('H*').is_packed)
      assert_equal(hex, st.to_shex, hex)
    end
    # Fewer than the three octets of an entry is not an entry: the walk
    # stops and leaves them, where it used to unpack nil and raise.
    st = Label_stack.new(s = ['8000000a'].pack('H*').is_packed)
    assert_equal(1, st.size)
    assert_equal('800000', st.to_shex)
    assert_equal('0a', s.unpack('H*')[0], 'the octet that is not an entry is left for the caller')
    # A built stack is untouched: 0 above the bottom, 1 on it.
    assert_equal('000640000650000661', Label_stack.new(100, 101, 102).to_shex)
  end
end
