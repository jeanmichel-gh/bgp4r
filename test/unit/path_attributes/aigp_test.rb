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
end

__END__

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

