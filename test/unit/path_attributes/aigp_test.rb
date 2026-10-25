require "test/unit"
require "bgp/path_attributes/aigp"

class TestAigp < Test::Unit::TestCase
  include BGP
  def test_1
    assert Aigp.new
    assert_equal('801a0b01000b0000000000000000', Aigp.new.to_shex)
    assert_equal(0, Aigp.new.to_i)
    assert_equal(4294967295, Aigp.new(0xffffffff).to_i)
    assert_equal('801a0b01000b00000000ffffffff', Aigp.new(0xffffffff).to_shex)
    assert_equal('(0xffffffff) 4294967295', Aigp.new(0xffffffff).metric)
    assert_equal(72057594037927935, Aigp.new(0xffffffffffffff).to_i)
    assert_equal('801a0b01000b00ffffffffffffff', Aigp.new(0xffffffffffffff).to_shex)
    assert_equal('(0xffffffffffffff) 72057594037927935', Aigp.new(0xffffffffffffff).metric)
    assert_equal('801a0b01000b0001020304050607', Aigp.new(Aigp.new(0x01020304050607).encode).to_shex) 
    assert ! Aigp.new.is_transitive?
    assert   Aigp.new.is_optional?    
  end
  def test_2
    assert Aigp.new_hash
    assert Aigp.new_hash :aigp=> 0x1f2f3f4f5f6f7f8f
    m1 = Aigp.new 0x1f2f3f4f5f6f7f8f
    m2 = Aigp.new_hash :aigp=> 0x1f2f3f4f5f6f7f8f
    assert_equal(m1.encode, m2.encode)
    assert_equal({:aigp=>2247084349217275791}, m2.to_hash)
  end
  # RFC 7311 section 3: the minimum TLV length is 3, no value.
  def test_tlv_length_3
    a = Aigp.new(['801a03010003'].pack('H*'))
    assert_equal('801a03010003', a.to_shex)
    assert_equal(0, a.to_i)
    assert ! a.has_metric?
    assert_equal('none', a.metric)
    assert_equal('801a03010003', Aigp.new(a).to_shex)
    assert_equal('801a03010003', Aigp.new(a.to_hash[:aigp]).to_shex)
  end
  # RFC 7311 section 3.2: unknown TLV types do not make it malformed.
  def test_unknown_tlv_alone
    a = Aigp.new(['801a05090005abcd'].pack('H*'))
    assert_equal('801a05090005abcd', a.to_shex)
    assert_equal(0, a.to_i)
    assert_equal(['090005abcd'], a.tlvs.collect { |t| t.unpack('H*')[0] })
    assert_equal({:aigp=>{:tlvs=>['090005abcd']}}, a.to_hash)
    assert_equal('801a05090005abcd', Aigp.new_hash(a.to_hash).to_shex)
    assert_equal('801a05090005abcd', Aigp.new(a.to_hash).to_shex)
    assert_equal(5, Aigp.new(:aigp=>5).to_i)
  end
  def test_unknown_tlv_before_and_after
    shex = '801a12' + '090004ff' + '01000b0000000000000064' + '0a0003'
    a = Aigp.new([shex].pack('H*'))
    assert_equal(shex, a.to_shex)
    assert_equal(100, a.to_i)
    assert a.has_metric?
    assert_equal(3, a.tlvs.size)
    assert_equal(shex, Aigp.new(a.to_hash[:aigp]).to_shex)
  end
  # RFC 7311 section 3: only the first AIGP TLV is used, the others
  # are passed along unchanged.
  def test_two_aigp_tlvs
    shex = '801a16' + '01000b0000000000000064' + '01000b00000000000000c8'
    a = Aigp.new([shex].pack('H*'))
    assert_equal(shex, a.to_shex)
    assert_equal(100, a.to_i)
    assert_equal(shex, Aigp.new(a.to_hash[:aigp]).to_shex)
  end
  def test_truncated_tlv
    ['801a0701000b00000000', '801a020100', '801a0101', '801a03010000',
     '801a0c01000b000000000000006409'].each do |shex|
      a = Aigp.new([shex].pack('H*'))
      assert_equal(shex, a.to_shex)
      assert_equal(shex, Aigp.new(a).to_shex)
      assert_equal(shex, Aigp.new(a.to_hash[:aigp]).to_shex)
    end
    assert_equal(0, Aigp.new(['801a0701000b00000000'].pack('H*')).to_i)
    assert_equal(100, Aigp.new(['801a0c01000b000000000000006409'].pack('H*')).to_i)
  end
  def test_wrong_length_aigp_tlv_then_valid
    shex = '801a0f' + '01000400' + '01000b0000000000000064'
    a = Aigp.new([shex].pack('H*'))
    assert_equal(shex, a.to_shex)
    assert_equal(100, a.to_i)
  end
  def test_add_tlv
    a = Aigp.new(100).add_tlv(9, ['0102'].pack('H*'))
    assert_equal('801a1001000b0000000000000064090005' + '0102', a.to_shex)
    assert_equal(100, a.to_i)
    assert_equal('801a03010003', Aigp.new(:tlvs=>[]).add_tlv(1).to_shex)
    assert_equal('801a03010003', Aigp.new(:tlvs=>[]).add_tlv(1, '').to_shex)
    assert_equal('801a0301000b', Aigp.new(:tlvs=>[]).add_tlv(1, '', length: 11).to_shex)
    assert_equal('801a0301ffff', Aigp.new(:tlvs=>[]).add_tlv(1, '', length: 0xffff).to_shex)
    assert_equal('801a00', Aigp.new(:tlvs=>[]).to_shex)
    a = Aigp.new(:tlvs=>['01000b0000000000000001', '0a0003'])
    assert_equal(1, a.to_i)
    assert_equal('801a0e01000b00000000000000010a0003', a.to_shex)
  end
  def test_path_attribute_hash
    require 'bgp/path_attributes/path_attribute'
    a = Aigp.new(7).add_tlv(9)
    pa = Path_attribute.new(a.to_hash)
    assert_equal(a.to_shex, pa[ATTR::ACCUMULATED_IGP_METRIC].to_shex)
    assert_equal({:aigp=>7}, Path_attribute.new(:aigp=>7).to_hash)
  end
  def test_to_s
    a = Aigp.new(['801a03010003'].pack('H*'))
    assert_match(/none/, a.to_s)
    assert_match(/0x00000064/, Aigp.new(100).to_s)
  end
end

__END__

RFC 7311, section 3 (AIGP Attribute):

   When an AIGP attribute is created, it SHOULD contain no more than one
   AIGP TLV.  However, if it contains more than one AIGP TLV, only the
   first one is used as described in Sections 3.4 and 4.  [...]  Any
   other AIGP TLVs in the AIGP attribute MUST be passed along unchanged
   if the AIGP attribute is passed along.

RFC 7311, section 3.2 (Handling a Malformed AIGP Attribute): an AIGP
attribute MUST NOT be considered malformed because it contains more
than one TLV of a given type, or because it contains TLVs of unknown
types.

The draft text this file was written against follows.

3. AIGP Attribute

   The AIGP Attribute is an optional non-transitive BGP Path Attribute.
   The attribute type code for the AIGP Attribute is 26.

   The value field of the AIGP Attribute is defined here to be a set of
   elements encoded as "Type/Length/Value" (i.e., a set of "TLVs").
   Each such TLV is encoded as shown in Figure 1.


       0                   1                   2                   3
       0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
       |     Type      |         Length                |               |
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+               |
       ~                                                               ~
       |                           Value                               |
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+..........................


                                 AIGP TLV
                                 Figure 1


    - Type: A single octet encoding the TLV Type.  Only type 1, "AIGP
      TLV", is defined in this document.

    - Length: Two octets encoding the length in octets of the TLV,
      including the type and length fields.  The length is encoded as an
      unsigned binary integer.  (Note that the minimum length is 3,
      indicating that no value field is present.)





Mohapatra, et al.                                               [Page 5]
 
Internet Draft         draft-ietf-idr-aigp-06.txt              June 2011


    - A value field containing zero or more octets.

  This document defines only a single such TLV, the "AIGP TLV".  The
  AIGP TLV is encoded as follows:

    - Type: 1

    - Length: 11

    - Accumulated IGP Metric.

      The value field of the AIGP TLV is always 8 bytes long.  IGP
      metrics are frequently expressed as 4-octet values, and this
      ensures that the AIGP attribute can be used to hold the sum of an
      arbitrary number of 4-octet values.

