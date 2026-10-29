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

  # RFC 8669 section 3: octets parsing cannot interpret are kept, and the
  # hash carries them as a :tail key (Attr::TAIL_KEY) inside the nested
  # hash, so a to_hash round trip is byte for byte on a malformed
  # attribute too.
  def test_hash_round_trip_keeps_the_tail
    # value octets, and the octets parse keeps out of them.
    [['0100',           '0100'],
     ['01ffff00',       '01ffff00'],
     [LI100 + '0100',   '0100']].each do |value_hex, tail_hex|
      a = Prefix_sid.new(wire(attr_hex(value_hex)))
      h = a.to_hash
      assert_equal attr_hex(value_hex), a.to_shex
      assert_equal tail_hex, h[:prefix_sid][:tail], h.inspect
      assert_equal a.encode, Prefix_sid.new(h[:prefix_sid]).encode, h.inspect
      pa = Path_attribute.new(:origin => :igp, :prefix_sid => h[:prefix_sid])
      assert_equal a.encode, pa[:prefix_sid].encode
      assert_equal pa.encode, Path_attribute.new(pa.to_hash).encode
    end
  end

  # An attribute with no tail hashes as it always has.
  def test_hash_has_no_tail_key_without_a_tail
    h = Prefix_sid.new(Label_index.new(100)).to_hash
    assert_equal({:prefix_sid => {:label_index => 100}}, h)
  end

  # Building never refuses: a test can send any TLV length.
  def test_bad_tlvs_can_be_built
    a = Prefix_sid.new(Tlv.new(1, "\x00".b))
    assert_equal attr_hex('01000100'), a.to_shex
  end

  # The attribute nests everything under :prefix_sid, which is the key
  # Path_attribute merges, and new read only the inner hash. Given its
  # own to_hash it found no key it knew and built an empty attribute,
  # c02800, in silence. The recipe carries both TLVs with the RFC 8669
  # reserved and flags fields set, and the tail of a cut TLV header.
  def test_to_hash_round_trips_with_every_field_set
    v = '010007' + '0ac00000000064' + '030008' + 'c0de003e800003e8' + '0100'
    wire = ['c028' + format('%02x', v.size / 2) + v].pack('H*').is_packed
    a = BGP::Prefix_sid.new(wire)
    assert_equal(a.encode, BGP::Prefix_sid.new(a.to_hash).encode)
    assert_equal(a.encode, BGP::Path_attribute.new(a.to_hash).encode)
  end

  # RFC 8669 section 3.1 gives Label-Index a reserved octet and 2 octets
  # of flags, and section 3.2 gives Originator SRGB 2 octets of flags.
  # None had a key, so a TLV read off the wire came back zeroed. They go
  # in the value rather than beside it, because Prefix_sid#to_hash
  # merges the known TLVs into one hash where two :flags keys would
  # collide. An ordinary TLV hashes exactly as it always did.
  def test_a_tlv_with_nothing_unusual_hashes_as_it_always_did
    assert_equal({ :label_index => 100 }, BGP::Prefix_sid::Label_index.new(100).to_hash)
    assert_equal({ :srgb => [[16000, 1000]] },
                 BGP::Prefix_sid::Originator_srgb.new([16000, 1000]).to_hash)
  end

  def test_a_tlv_carries_its_reserved_and_flags_when_they_arrived_set
    li = BGP::Prefix_sid::Label_index.new(['0ac00000000064'].pack('H*'))
    assert_equal({ :label_index => { :index => 100, :flags => 0xc000, :reserved => 0x0a } },
                 li.to_hash)
    assert_equal(li.encode, BGP::Prefix_sid::Label_index.new(li.to_hash).encode)
    srgb = BGP::Prefix_sid::Originator_srgb.new(['c0de003e800003e8'].pack('H*'))
    assert_equal({ :srgb => { :ranges => [[16000, 1000]], :flags => 0xc0de } }, srgb.to_hash)
    assert_equal(srgb.encode, BGP::Prefix_sid::Originator_srgb.new(srgb.to_hash).encode)
  end

  # The keeper for a TLV bgp4r has no shape for. Nothing read its hash:
  # new took it as the type and pack raised.
  def test_an_unshaped_tlv_round_trips
    t = BGP::Prefix_sid::Tlv.new(9, "\x01\x02\x03".b)
    assert_equal({ :type => 9, :value => '010203' }, t.to_hash)
    assert_equal(t.encode, BGP::Prefix_sid::Tlv.new(t.to_hash).encode)
  end

end
