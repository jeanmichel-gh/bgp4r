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

class TestPmsiTunnel < Test::Unit::TestCase
  include BGP

  def wire(hex) [hex].pack('H*').is_packed end

  # RFC 6514 section 5: flags, tunnel type, 3 octet label, identifier.
  # Label 100 sits in the high 20 bits, so the field is 100 << 4.
  def test_ingress_replication
    a = Pmsi_tunnel.new(:ingress_replication, '10.0.0.1', :label => 100)
    assert_equal 'c0160900060006400a000001', a.to_shex
    assert_equal 6, a.tunnel_type
    assert_equal :ingress_replication, a.tunnel_name
    assert_equal 100, a.label
    assert ! a.leaf_info_required?
    assert a.is_optional?
    assert a.is_transitive?
  end

  def test_pim_ssm_and_leaf_info_required
    a = Pmsi_tunnel.new(:pim_ssm, ['10.0.0.1', '232.1.1.1'], :leaf_info_required => true)
    assert_equal 'c0160d01030000000a000001e8010101', a.to_shex
    assert a.leaf_info_required?
    assert_nil a.label, 'a zero label field means no label'
    assert_match(/pim_ssm: 10\.0\.0\.1 -> 232\.1\.1\.1, leaf info required/, a.to_s(:brief))
  end

  def test_no_tunnel
    a = Pmsi_tunnel.new(:no_tunnel)
    assert_equal 'c016050000000000', a.to_shex
    assert_equal :no_tunnel, a.tunnel_name
    assert_equal '', a.identifier
  end

  def test_from_wire
    a = Pmsi_tunnel.new(wire('c0160900060006400a000001'))
    assert_equal [6, 100, '0a000001'], [a.tunnel_type, a.label, a.identifier.unpack1('H*')]
    assert_equal 'c0160900060006400a000001', a.to_shex
    assert_instance_of Pmsi_tunnel, Attr.factory(wire('c0160900060006400a000001'))
  end

  def test_hash_round_trip
    [Pmsi_tunnel.new(:ingress_replication, '10.0.0.1', :label => 100),
     Pmsi_tunnel.new(:pim_ssm, ['10.0.0.1', '232.1.1.1'], :leaf_info_required => true),
     Pmsi_tunnel.new(:no_tunnel),
     Pmsi_tunnel.new(9, '0102030405')].each do |a|
      h = a.to_hash
      assert_equal a.encode, Pmsi_tunnel.new(h[:pmsi_tunnel]).encode, h.inspect
      pa = Path_attribute.new(:origin => :igp, :pmsi_tunnel => h[:pmsi_tunnel])
      assert_equal a.encode, pa[:pmsi_tunnel].encode
      assert_equal pa.encode, Path_attribute.new(pa.to_hash).encode
    end
  end

  # **The 4 bits below the 20 bit label are kept and echoed**, because
  # RFC 6514 section 5 names the field "MPLS Label" and describes no
  # layout for them, and an encoder that wrote them back as 0 could not
  # replay a capture. Before this, 000641 came back as 000640, and worse,
  # a field of 000001 became a label of 0 and encoded as 000000, which
  # the section makes mean no label at all: a non-zero field arrived and
  # left as absent. Every test in this file used :label => 100, whose
  # low 4 bits are zero, which is why nothing caught it.
  def test_the_label_field_keeps_the_four_bits_below_the_label
    { '000640' => [100, nil],         # the ordinary case, no extra key
      '000641' => [100, 0x000641],
      '00064f' => [100, 0x00064f],
      '000001' => [0, 0x000001],      # a field too small to hold a label
      'ffffff' => [0xfffff, 0xffffff],
    }.each do |field, (label, bits)|
      hex = 'c01609' + '0006' + field + '0a000001'
      a = Pmsi_tunnel.new(wire(hex))
      assert_equal label, a.label, field
      assert_equal hex, a.to_shex, "#{field} did not replay"
      h = a.to_hash[:pmsi_tunnel]
      assert_equal bits, h[:label_bits], "#{field} :label_bits"
      assert_equal !bits.nil?, a.undefined_label_bits?, field
      assert_equal a.encode, Pmsi_tunnel.new(h).encode, h.inspect
    end
    # A zero field is still no label, and carries neither key.
    a = Pmsi_tunnel.new(wire('c01609' + '0006' + '000000' + '0a000001'))
    assert_nil a.label
    refute a.undefined_label_bits?
    refute a.to_hash[:pmsi_tunnel].key?(:label_bits)
    # Built from field values the 4 bits are 0, which is what an encoder
    # is asked for, so :label_bits is the only way to set them.
    assert_equal 0x000640, Pmsi_tunnel.new(:no_tunnel, nil, :label => 100).label_bits
    assert_equal 0x00064f,
                 Pmsi_tunnel.new(:no_tunnel, nil, :label_bits => 0x00064f).label_bits
    assert_equal 100, Pmsi_tunnel.new(:no_tunnel, nil, :label_bits => 0x00064f).label
    assert_raise(ArgumentError) do
      Pmsi_tunnel.new(:no_tunnel, nil, :label_bits => 0x1000000)
    end
  end

  # **Flags 0x41 lost the RFC 7902 Extension bit**, because to_hash wrote
  # :flags only when no leaf bit was set, so the octet came back as 0x01.
  # The two keys are not exclusive: :flags carries the whole octet
  # whenever it holds a bit other than the one :leaf_info_required names.
  def test_the_flags_octet_rebuilds_whatever_bits_it_holds
    [0x00, 0x01, 0x40, 0x41, 0x80, 0xff].each do |f|
      a = Pmsi_tunnel.new(:tunnel_type => :pim_ssm,
                          :identifier => ['10.0.0.1', '232.1.1.1'],
                          :label => 100, :flags => f)
      assert_equal f, a.pmsi_flags, format('flags 0x%02x', f)
      h = a.to_hash[:pmsi_tunnel]
      assert_equal a.encode, Pmsi_tunnel.new(h).encode, format('flags 0x%02x', f)
      assert_equal f, Pmsi_tunnel.new(h).pmsi_flags, format('flags 0x%02x', f)
    end
    # The two common octets hash as they always did.
    assert_equal({ :tunnel_type => :no_tunnel },
                 Pmsi_tunnel.new(:no_tunnel).to_hash[:pmsi_tunnel])
    assert_equal({ :tunnel_type => :no_tunnel, :leaf_info_required => true },
                 Pmsi_tunnel.new(:no_tunnel, nil, :leaf_info_required => true)
                   .to_hash[:pmsi_tunnel])
    # And 0x41 carries both, where it used to carry the leaf bit alone.
    assert_equal({ :tunnel_type => :no_tunnel, :flags => 0x41,
                   :leaf_info_required => true },
                 Pmsi_tunnel.new(:tunnel_type => :no_tunnel, :flags => 0x41)
                   .to_hash[:pmsi_tunnel])
  end

  # **`:flags` means two different things and `Attr::OVERRIDE_KEYS` is
  # why**, which is worth a test because it reads as a bug and is a
  # feature. `Attr.new` pops a trailing Hash whose keys are *all* in
  # `[:flags, :type, :length]` and applies it to the attribute header,
  # which is how Conventions lets a test make the header lie. So at the
  # multi-argument call site `:flags` is the **header's** 4 bits and
  # never reaches the PMSI Tunnel flags octet, and the single Hash form
  # is how that octet is set. A hash carrying any other key is not
  # popped, so `:label => 100, :flags => 1` reaches the octet after all.
  def test_the_flags_option_is_the_header_override_at_the_multi_arg_call_site
    # Popped: the header flags become 0x41, and the octet stays 0.
    a = Pmsi_tunnel.new(:no_tunnel, nil, :flags => 0x41)
    assert_equal 0, a.pmsi_flags
    assert_equal '10', a.to_shex[0, 2], 'the header flags were not overridden'
    # Not popped, because :label is not an override key.
    b = Pmsi_tunnel.new(:no_tunnel, nil, :label => 100, :flags => 0x41)
    assert_equal 0x41, b.pmsi_flags
    assert_equal 'c0', b.to_shex[0, 2], 'the header flags were overridden'
    # The single Hash form always reaches the octet, since :tunnel_type
    # is not an override key, which is what to_hash relies on.
    c = Pmsi_tunnel.new(:tunnel_type => :no_tunnel, :flags => 0x41)
    assert_equal 0x41, c.pmsi_flags
    assert_equal 'c0', c.to_shex[0, 2]
  end

  # **RFC 8317 section 6.2's composite tunnel bit is a layout change and
  # not only a name.** "the high-order bit of the Tunnel Type field
  # (composite tunnel bit) is set while the remaining low-order seven
  # bits indicate the Tunnel Type as before", and "When this composite
  # tunnel bit is set, the 'tunnel identifier' field begins with a
  # three-octet label, followed by the actual tunnel identifier for the
  # transmit tunnel."
  def test_a_composite_tunnel_reads_its_type_and_its_leading_label
    # flags 00, type 0x82, label 100, leading label 200, then two
    # addresses, which is where the layout change shows: a reader that
    # ignored the bit would take the label's octets as the identifier.
    hex = 'c01610' + '00' + '83' + '000640' + '000c80' + '0a000001e8010101'
    a = Pmsi_tunnel.new(wire(hex))
    assert a.composite?
    assert_equal 3, a.tunnel_type, 'the low 7 bits are the registry number'
    assert_equal :pim_ssm, a.tunnel_name
    assert_equal 100, a.label
    assert_equal 200, a.ir_label
    assert_equal ['10.0.0.1', '232.1.1.1'], a.to_hash[:pmsi_tunnel][:identifier]
    assert_equal hex, a.to_shex
    assert_match(/composite pim_ssm/, a.to_s)
    assert_match(/ir label 200/, a.to_s)
    h = a.to_hash[:pmsi_tunnel]
    assert_equal true, h[:composite]
    assert_equal 200, h[:ir_label]
    assert_equal a.encode, Pmsi_tunnel.new(h).encode, h.inspect
    # A plain tunnel carries neither key, so an ordinary attribute
    # hashes as it always did.
    plain = Pmsi_tunnel.new(:ingress_replication, '10.0.0.1', :label => 100)
    refute plain.composite?
    assert_nil plain.ir_label
    refute plain.to_hash[:pmsi_tunnel].key?(:composite)
    refute plain.to_hash[:pmsi_tunnel].key?(:ir_label)
  end

  # Nothing a caller could already write changes its octets: a number
  # with the high bit set is what the composite bit is, so `new(0x82)`
  # encodes what it always did and `tunnel_type` now answers 2.
  def test_a_tunnel_type_with_the_high_bit_set_is_the_composite_bit
    a = Pmsi_tunnel.new(0x82)
    assert_equal 'c016050082000000', a.to_shex
    assert a.composite?
    assert_equal 2, a.tunnel_type
    # And :composite asks for the bit with a plain type, same octets.
    assert_equal a.to_shex,
                 Pmsi_tunnel.new(:mldp_p2mp, nil, :composite => true).to_shex
    # The range check is still on the octet a caller passes.
    assert_raise(ArgumentError) { Pmsi_tunnel.new(256) }
  end

  # **Two cases where the leading label is absent rather than zero**, and
  # the hash has to tell them apart or a rebuild invents three octets.
  def test_an_absent_leading_label_is_not_a_zero_one
    # Composite, but the body leaves fewer than 3 octets after the fixed
    # part, so there is nowhere to put the field. The octets stay in the
    # identifier and replay; nothing is invented.
    %w[0082000640 008200064000 00820006400a01].each do |value|
      hex = format('c016%02x', value.size / 2) + value
      a = Pmsi_tunnel.new(wire(hex))
      assert a.composite?, value
      assert_nil a.ir_label, "#{value} invented a leading label"
      assert_nil a.ir_label_bits, value
      assert_equal hex, a.to_shex, "#{value} did not replay"
      h = a.to_hash[:pmsi_tunnel]
      refute h.key?(:ir_label), value
      assert_equal a.encode, Pmsi_tunnel.new(h).encode, h.inspect
    end
    # A zero field is present and reads as 0, where `label` would answer
    # nil: this field is optional, so nil has to mean absent.
    z = Pmsi_tunnel.new(wire('c016080082000640000000'))
    assert_equal 0, z.ir_label
    assert_equal 0, z.ir_label_bits
    assert_equal 0, z.to_hash[:pmsi_tunnel][:ir_label]
    assert_equal 'c016080082000640000000', z.to_shex
    assert_equal z.encode, Pmsi_tunnel.new(z.to_hash[:pmsi_tunnel]).encode
    # Built, the two options behave the same way: neither given writes
    # no field even with the bit set, since building never validates.
    assert_equal 'c016050082000000',
                 Pmsi_tunnel.new(:mldp_p2mp, nil, :composite => true).to_shex
    assert_equal 'c016080082000000000000',
                 Pmsi_tunnel.new(:mldp_p2mp, nil, :composite => true,
                                 :ir_label => 0).to_shex
    assert_equal 'c01608008200000000064f',
                 Pmsi_tunnel.new(:mldp_p2mp, nil, :composite => true,
                                 :ir_label_bits => 0x00064f).to_shex
    assert_raise(ArgumentError) do
      Pmsi_tunnel.new(:mldp_p2mp, nil, :ir_label => 0x100000)
    end
    assert_raise(ArgumentError) do
      Pmsi_tunnel.new(:mldp_p2mp, nil, :ir_label_bits => 0x1000000)
    end
  end

  # The 4 bits below the leading label are kept and echoed too, the same
  # rule the attribute's own label field follows.
  def test_the_leading_label_keeps_the_four_bits_below_it
    hex = 'c0160c' + '00' + '82' + '000640' + '00012c' + '0a000001'
    a = Pmsi_tunnel.new(wire(hex))
    assert_equal 0x12, a.ir_label
    assert_equal 0x00012c, a.ir_label_bits
    assert a.undefined_ir_label_bits?
    assert_equal hex, a.to_shex
    h = a.to_hash[:pmsi_tunnel]
    assert_equal 0x00012c, h[:ir_label_bits]
    assert_equal a.encode, Pmsi_tunnel.new(h).encode, h.inspect
    # And no key when those bits are clear.
    b = Pmsi_tunnel.new(wire('c0160c00820006400000c00a000001'))
    refute b.undefined_ir_label_bits?
    refute b.to_hash[:pmsi_tunnel].key?(:ir_label_bits)
  end

  # A tunnel type bgp4r has no shape for keeps its octets.
  def test_unknown_tunnel_type
    a = Pmsi_tunnel.new(9, '0102030405')
    assert_equal 'c0160a000900000' + '00102030405', a.to_shex
    assert_nil a.tunnel_name
    assert_equal({:pmsi_tunnel => {:tunnel_type => 9, :identifier => '0102030405'}}, a.to_hash)
    assert_equal a.encode, Pmsi_tunnel.new(a.encode).encode
  end

  def test_bad_values_raise
    assert_raise(ArgumentError) { Pmsi_tunnel.new(:no_such_tunnel) }
    assert_raise(ArgumentError) { Pmsi_tunnel.new(:ingress_replication, '10.0.0.1', :label => 0x100000) }
    assert_raise(ArgumentError) { Pmsi_tunnel.new(300, '10.0.0.1') }
  end

  # Building never refuses a shape the RFC does not define.
  def test_any_identifier_can_be_built
    a = Pmsi_tunnel.new(:pim_ssm, '00')
    assert_equal 'c01606000300000000', a.to_shex
  end

  # RFC 6514 section 5: the fixed part is 5 octets.
  def test_too_short
    pa = Path_attribute.new(wire('c01604' + '00000000'))
    assert_equal [[22, 5, :treat_as_withdraw]], pa.errors.collect { |f| [f.type, f.subcode, f.action] }
    assert_equal 'c0160400000000', pa.encode.unpack1('H*')
    assert_equal [], Path_attribute.new(wire('c016050000000000')).errors
  end

  # RFC 6514 section 5: a value too short to hold the fixed part is kept
  # as it came, and the hash carries it as a :tail key (Attr::TAIL_KEY)
  # inside the nested hash, so a to_hash round trip is byte for byte on a
  # malformed attribute too.
  def test_hash_round_trip_keeps_the_short_value
    ['', '00', '00000000'].each do |value_hex|
      hex = format('c016%02x', value_hex.length / 2) + value_hex
      a = Pmsi_tunnel.new(wire(hex))
      h = a.to_hash
      assert_equal hex, a.to_shex
      assert_equal value_hex, h[:pmsi_tunnel][:tail], h.inspect
      assert_equal a.encode, Pmsi_tunnel.new(h[:pmsi_tunnel]).encode, h.inspect
      pa = Path_attribute.new(:origin => :igp, :pmsi_tunnel => h[:pmsi_tunnel])
      assert_equal a.encode, pa[:pmsi_tunnel].encode
      assert_equal pa.encode, Path_attribute.new(pa.to_hash).encode
    end
  end

  # An attribute with no kept octets hashes as it always has.
  def test_hash_has_no_tail_key_without_a_short_value
    assert_equal({:pmsi_tunnel => {:tunnel_type => :no_tunnel}}, Pmsi_tunnel.new(:no_tunnel).to_hash)
  end

  def test_flags_are_checked
    pa = Path_attribute.new(wire('80160900060006400a000001'))
    assert_equal [[22, 4, :treat_as_withdraw]], pa.errors.collect { |f| [f.type, f.subcode, f.action] }
  end

  def test_validate_is_clean_for_a_good_attribute
    assert_equal [], Path_attribute.new(Pmsi_tunnel.new(:ingress_replication, '10.0.0.1')).validate
  end

end
