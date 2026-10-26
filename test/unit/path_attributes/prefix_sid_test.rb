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

class TestPrefixSid < Test::Unit::TestCase
  include BGP

  Label_index = Prefix_sid::Label_index
  Srgb = Prefix_sid::Originator_srgb
  Tlv = Prefix_sid::Tlv

  # RFC 8669 section 3.1: type 1, length 7, reserved, flags, label index.
  LI100 = '010007' + '00' + '0000' + '00000064'

  def wire(hex) [hex].pack('H*').is_packed end

  # An attribute of exactly these value octets.
  def attr_hex(value_hex)
    format('c028%02x', value_hex.length / 2) + value_hex
  end

  def test_label_index_tlv
    t = Label_index.new(100)
    assert_equal LI100, t.encode.unpack1('H*')
    assert_equal 100, t.label_index
    assert_equal 1, t.type
    assert_equal 'Label index: 100', t.to_s
  end

  # RFC 8669 section 3.2: type 3, flags, then 6 octet entries of a
  # 3 octet first label and a 3 octet count.
  def test_originator_srgb_tlv
    t = Srgb.new([16000, 1000])
    assert_equal '0300080000003e800003e8', t.encode.unpack1('H*')
    assert_equal [[16000, 1000]], t.ranges
    assert_equal 'SRGB: 16000..16999', t.to_s
    two = Srgb.new([16000, 1000], [20000, 10])
    assert_equal [[16000, 1000], [20000, 10]], two.ranges
    assert_equal 'SRGB: 16000..16999, 20000..20009', two.to_s
  end

  def test_from_values
    a = Prefix_sid.new(Label_index.new(100))
    assert_equal attr_hex(LI100), a.to_shex
    assert a.is_optional?
    assert a.is_transitive?
    assert_equal 100, a.label_index
    assert_nil a.srgb
  end

  def test_from_wire
    a = Prefix_sid.new(wire(attr_hex(LI100)))
    assert_equal 100, a.label_index
    assert_equal attr_hex(LI100), a.to_shex
    assert_instance_of Prefix_sid, Attr.factory(wire(attr_hex(LI100)))
  end

  def test_hash_round_trip
    a = Prefix_sid.new(Label_index.new(100), Srgb.new([16000, 1000]))
    assert_equal({:prefix_sid => {:label_index => 100, :srgb => [[16000, 1000]]}}, a.to_hash)
    assert_equal a.encode, Prefix_sid.new(a.to_hash[:prefix_sid]).encode
    pa = Path_attribute.new(:origin => :igp, :prefix_sid => a.to_hash[:prefix_sid])
    assert_equal a.encode, pa[:prefix_sid].encode
    assert_equal pa.encode, Path_attribute.new(pa.to_hash).encode
    assert_instance_of Prefix_sid, pa[ATTR::PREFIX_SID]
  end

  # RFC 8669 section 3: an unknown TLV is kept and passed on unchanged.
  def test_unknown_tlv_round_trips
    a = Prefix_sid.new(Tlv.new(9, "\x01\x02".b))
    assert_equal attr_hex('0900020102'), a.to_shex
    assert_equal a.encode, Prefix_sid.new(a.encode).encode
    assert_equal({:prefix_sid => {:tlvs => [{:type => 9, :value => '0102'}]}}, a.to_hash)
    assert_equal a.encode, Prefix_sid.new(a.to_hash[:prefix_sid]).encode
    assert_equal [], Path_attribute.new(wire(a.to_shex)).errors
  end

  def test_tlvs_keep_their_order
    a = Prefix_sid.new(Srgb.new([16000, 1000]), Label_index.new(100))
    assert_equal [Srgb, Label_index], a.tlvs.collect(&:class)
    assert_equal a.encode, Prefix_sid.new(a.encode).encode
    assert_equal 100, a.label_index
  end

  # RFC 8669 section 6, attribute discard.
  def test_label_index_wrong_length
    hex = attr_hex('010006' + '000000000064')
    pa = Path_attribute.new(wire(hex))
    assert_equal [[40, 5, :attribute_discard]], pa.errors.collect { |f| [f.type, f.subcode, f.action] }
    assert_equal hex, pa.encode.unpack1('H*')
    # Kept as a plain TLV, so the octets survive.
    assert_equal [Tlv], pa[:prefix_sid].tlvs.collect(&:class)
  end

  def test_srgb_wrong_length
    hex = attr_hex('030005' + '0000000000')
    pa = Path_attribute.new(wire(hex))
    assert_equal [[40, 5, :attribute_discard]], pa.errors.collect { |f| [f.type, f.subcode, f.action] }
    assert_equal hex, pa.encode.unpack1('H*')
  end

  def test_tlv_runs_past_the_attribute
    hex = attr_hex('01ffff00')
    pa = Path_attribute.new(wire(hex))
    assert_equal [[40, 5, :attribute_discard]], pa.errors.collect { |f| [f.type, f.subcode, f.action] }
    assert_equal hex, pa.encode.unpack1('H*'), 'the octets received must be sent back'
  end

  def test_tlv_header_cut
    hex = attr_hex('0100')
    pa = Path_attribute.new(wire(hex))
    assert_equal [[40, 5, :attribute_discard]], pa.errors.collect { |f| [f.type, f.subcode, f.action] }
    assert_equal hex, pa.encode.unpack1('H*')
  end

  def test_flags_are_checked
    pa = Path_attribute.new(wire('80' + attr_hex(LI100)[2..-1]))
    assert_equal [[40, 4, :treat_as_withdraw]], pa.errors.collect { |f| [f.type, f.subcode, f.action] }
  end

  def test_a_good_attribute_has_no_findings
    assert_equal [], Path_attribute.new(wire(attr_hex(LI100 + '0300080000003e800003e8'))).errors
    assert_equal [], Path_attribute.new(Prefix_sid.new(Label_index.new(100))).validate
  end

  # Building never refuses: a test can send any TLV length.
  def test_bad_tlvs_can_be_built
    a = Prefix_sid.new(Tlv.new(1, "\x00".b))
    assert_equal attr_hex('01000100'), a.to_shex
  end

end
