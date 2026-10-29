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

class TestTunnelEncap < Test::Unit::TestCase
  include BGP

  Tunnel          = Tunnel_encap::Tunnel
  Sub_tlv         = Tunnel_encap::Sub_tlv
  Encapsulation   = Tunnel_encap::Encapsulation
  Protocol_type   = Tunnel_encap::Protocol_type
  Color           = Tunnel_encap::Color
  Egress_endpoint = Tunnel_encap::Egress_endpoint
  Ds_field        = Tunnel_encap::Ds_field
  Udp_dest_port   = Tunnel_encap::Udp_dest_port
  Embedded        = Tunnel_encap::Embedded_label_handling
  Label_stack     = Tunnel_encap::Mpls_label_stack

  # RFC 9012 section 3.2: type 6, length 10, reserved, family 1, address.
  EGRESS_V4 = '060a' + '00000000' + '0001' + '0a000001'
  # Family 2 and a 16 octet address make the length 22.
  EGRESS_V6 = '0616' + '00000000' + '0002' + '20010db8000000000000000000000001'
  # Family 0 and no address make the length 6 (the next hop is the endpoint).
  EGRESS_NH = '0606' + '00000000' + '0000'
  # RFC 9012 section 3.4.3: type 4, length 8, a Color Extended Community.
  COLOR100  = '0408' + '030b' + '0000' + '00000064'

  def wire(hex) [hex].pack('H*').is_packed end

  # A TLV of a tunnel type and these sub-TLV octets.
  def tlv_hex(type, sub_tlvs_hex)
    format('%04x%04x', type, sub_tlvs_hex.length / 2) + sub_tlvs_hex
  end

  # An attribute of exactly these value octets.
  def attr_hex(value_hex)
    format('c017%02x', value_hex.length / 2) + value_hex
  end

  def test_tunnel_type_names
    assert_equal 8, Tunnel.new(:vxlan).tunnel_type
    assert_equal :vxlan, Tunnel.new(8).tunnel_name
    assert_equal :mpls_in_gre, Tunnel.new(11).tunnel_name
    # RFC 9012 deprecates tunnel type 4, so bgp4r has no name for it,
    # but a test can still send it.
    assert_nil Tunnel.new(4).tunnel_name
    assert_equal 4, Tunnel.new(4).tunnel_type
  end

  # RFC 9012 section 2: tunnel type (2 octets), length (2 octets), sub-TLVs.
  def test_vxlan_with_egress_endpoint_and_color
    a = Tunnel_encap.new(Tunnel.new(:vxlan, Egress_endpoint.new('10.0.0.1'), Color.new(100)))
    assert_equal attr_hex(tlv_hex(8, EGRESS_V4 + COLOR100)), a.to_shex
    assert a.is_optional?
    assert a.is_transitive?
    assert_equal 1, a.tunnels.size
    assert_equal '10.0.0.1', a.tunnels.first.egress_endpoint
    assert_equal 100, a.tunnels.first.color
    assert_match(/vxlan: Egress endpoint 10\.0\.0\.1, Color 100/, a.to_s(:brief))
  end

  # RFC 9012 section 3.2: the length tells the address family apart.
  def test_egress_endpoint_families
    assert_equal EGRESS_V4, Egress_endpoint.new('10.0.0.1').encode.unpack1('H*')
    assert_equal EGRESS_V6, Egress_endpoint.new('2001:db8::1').encode.unpack1('H*')
    assert_equal EGRESS_NH, Egress_endpoint.new(nil).encode.unpack1('H*')
    assert_equal [1, '10.0.0.1'], [Egress_endpoint.new('10.0.0.1').address_family,
                                   Egress_endpoint.new('10.0.0.1').address]
    assert_equal [2, '2001:db8::1'], [Egress_endpoint.new('2001:db8::1').address_family,
                                      Egress_endpoint.new('2001:db8::1').address]
    assert_nil Egress_endpoint.new(nil).address
    assert_equal 'Egress endpoint the next hop', Egress_endpoint.new(nil).to_s
  end

  # RFC 9012 section 3.4.3: the first two octets are 0x030b.
  def test_color
    t = Color.new(100)
    assert_equal COLOR100, t.encode.unpack1('H*')
    assert_equal 100, t.color
    assert_equal 0, t.color_flags
    assert_equal 'Color 100', t.to_s
  end

  # RFC 9012 section 3.3: 4 octet label stack entries (RFC 3032 section
  # 2.1). The label is the top 20 bits, and the last entry has the
  # Bottom of Stack bit.
  def test_mpls_label_stack
    t = Label_stack.new(100, 200)
    assert_equal '0a08' + '00064000' + '000c8100', t.encode.unpack1('H*')
    assert_equal [100, 200], t.labels
    assert_equal [100, 200], Label_stack.new([100, 200]).labels
    assert_equal 'MPLS label stack 100, 200', t.to_s
    one = Label_stack.new(16)
    assert_equal '0a04' + '00010100', one.encode.unpack1('H*')
    assert_equal [16], one.labels
  end

  def test_fixed_size_integer_sub_tlvs
    assert_equal '0202' + '0800', Protocol_type.new(0x0800).encode.unpack1('H*')
    assert_equal 0x0800, Protocol_type.new(0x0800).protocol_type
    assert_equal '0701' + '2e', Ds_field.new(46).encode.unpack1('H*')
    assert_equal 46, Ds_field.new(46).ds_field
    assert_equal '0802' + '12b5', Udp_dest_port.new(4789).encode.unpack1('H*')
    assert_equal 4789, Udp_dest_port.new(4789).port
    assert_equal '0901' + '01', Embedded.new(1).encode.unpack1('H*')
    assert_equal 1, Embedded.new(1).handling
    assert_equal 'UDP destination port 4789', Udp_dest_port.new(4789).to_s
  end

  # RFC 9012 section 3.1: the Encapsulation sub-TLV's shape depends on
  # the tunnel type, so bgp4r keeps the octets.
  def test_encapsulation_keeps_its_octets
    a = Tunnel_encap.new(Tunnel.new(:gre, Encapsulation.new([1, 2, 3, 4].pack('C4'))))
    assert_equal attr_hex(tlv_hex(2, '0104' + '01020304')), a.to_shex
    assert_equal({:encapsulation => '01020304'}, a.tunnels.first.sub_tlvs.first.to_hash)
    assert_equal a.encode, Tunnel_encap.new(a.encode).encode
  end

  # RFC 9012 section 2: a sub-TLV of type 128 or above has a two octet
  # length.
  def test_sub_tlv_length_field_size
    assert Sub_tlv.long_length?(128)
    assert ! Sub_tlv.long_length?(127)
    short = Tunnel_encap.new(Tunnel.new(:bare, Sub_tlv.new(127, "\x09".b)))
    assert_equal attr_hex(tlv_hex(16, '7f01' + '09')), short.to_shex
    long = Tunnel_encap.new(Tunnel.new(:bare, Sub_tlv.new(200, "\x09".b)))
    assert_equal attr_hex(tlv_hex(16, 'c80001' + '09')), long.to_shex
    assert_equal long.encode, Tunnel_encap.new(long.encode).encode
    assert_equal [], Path_attribute.new(wire(long.to_shex)).errors
  end

  def test_from_wire
    hex = attr_hex(tlv_hex(8, EGRESS_V4 + COLOR100))
    a = Tunnel_encap.new(wire(hex))
    assert_equal hex, a.to_shex
    assert_equal 8, a.tunnels.first.tunnel_type
    assert_equal [Egress_endpoint, Color], a.tunnels.first.sub_tlvs.collect(&:class)
    assert_instance_of Tunnel_encap, Attr.factory(wire(hex))
  end

  def test_two_tunnels_keep_their_order
    a = Tunnel_encap.new(Tunnel.new(:gre, Encapsulation.new([1, 2, 3, 4].pack('C4'))),
                         Tunnel.new(:vxlan, Egress_endpoint.new(nil)))
    assert_equal attr_hex(tlv_hex(2, '0104' + '01020304') + tlv_hex(8, EGRESS_NH)), a.to_shex
    assert_equal [2, 8], a.tunnels.collect(&:tunnel_type)
    assert_equal a.encode, Tunnel_encap.new(a.encode).encode
    assert_equal 2, a[:gre].tunnel_type
    assert_equal 8, a[8].tunnel_type
    assert_nil a[:geneve]
    assert_equal [], Path_attribute.new(wire(a.to_shex)).errors
  end

  def test_hash_round_trip
    [Tunnel_encap.new(Tunnel.new(:vxlan, Egress_endpoint.new('10.0.0.1'), Color.new(100))),
     Tunnel_encap.new(Tunnel.new(:mpls_in_gre, Egress_endpoint.new('2001:db8::1'),
                                 Label_stack.new(100, 200), Udp_dest_port.new(4789),
                                 Protocol_type.new(0x0800), Ds_field.new(46), Embedded.new(1))),
     Tunnel_encap.new(Tunnel.new(:gre, Encapsulation.new([1, 2].pack('C2'))),
                      Tunnel.new(:vxlan, Egress_endpoint.new(nil))),
     Tunnel_encap.new(Tunnel.new(99, Sub_tlv.new(200, "\x09".b))),
     Tunnel_encap.new(Tunnel.new(:bare)),
    ].each do |a|
      h = a.to_hash
      assert_equal a.encode, Tunnel_encap.new(h[:tunnel_encap]).encode, h.inspect
      pa = Path_attribute.new(:origin => :igp, :tunnel_encap => h[:tunnel_encap])
      assert_equal a.encode, pa[:tunnel_encap].encode
      assert_equal pa.encode, Path_attribute.new(pa.to_hash).encode
      assert_instance_of Tunnel_encap, pa[ATTR::TUNNEL_ENCAP]
    end
  end

  # The friendly hash form: one tunnel, sub-TLVs by name. Named keys are
  # written in sub-TLV type order, whatever order the hash gives them,
  # so colour (type 4) comes before the egress endpoint (type 6). Pass
  # :sub_tlvs to choose the order.
  def test_build_from_a_tunnel_hash
    a = Tunnel_encap.new(:tunnel_type => :vxlan, :egress_endpoint => '10.0.0.1', :color => 100)
    assert_equal attr_hex(tlv_hex(8, COLOR100 + EGRESS_V4)), a.to_shex
    assert_equal [Color, Egress_endpoint], a.tunnels.first.sub_tlvs.collect(&:class)
    b = Tunnel_encap.new(:tunnel_type => 8, :sub_tlvs => [{:color => 100},
                                                          {:egress_endpoint => '10.0.0.1'}])
    assert_equal a.encode, b.encode
    # The other way round only through :sub_tlvs.
    c = Tunnel_encap.new(:tunnel_type => 8, :sub_tlvs => [{:egress_endpoint => '10.0.0.1'},
                                                          {:color => 100}])
    assert_equal attr_hex(tlv_hex(8, EGRESS_V4 + COLOR100)), c.to_shex
    d = Tunnel_encap.new([{:tunnel_type => :gre, :sub_tlvs => [{:type => 200, :value => '09'}]}])
    assert_equal attr_hex(tlv_hex(2, 'c80001' + '09')), d.to_shex
    assert_equal 100, Path_attribute.new(:tunnel_encap => a.to_hash[:tunnel_encap])[:tunnel_encap].tunnels.first.color
  end

  # RFC 9012 section 13: an unrecognized tunnel type is not malformed.
  # The TLV stays in the attribute when the route is propagated.
  def test_unknown_tunnel_type_is_not_an_error
    hex = attr_hex(tlv_hex(0x63, '0904' + '02030405'))
    pa = Path_attribute.new(wire(hex))
    assert_equal [], pa.errors
    assert_equal hex, pa.encode.unpack1('H*')
    assert_equal 0x63, pa[:tunnel_encap].tunnels.first.tunnel_type
    assert_nil pa[:tunnel_encap].tunnels.first.tunnel_name
  end

  # RFC 9012 section 13: an unrecognized sub-TLV is processed as if it
  # were absent, and stays in the attribute.
  def test_unknown_sub_tlv_round_trips
    a = Tunnel_encap.new(Tunnel.new(:vxlan, Sub_tlv.new(99, "\x01\x02".b)))
    assert_equal attr_hex(tlv_hex(8, '6302' + '0102')), a.to_shex
    assert_equal({:type => 99, :value => '0102'}, a.tunnels.first.sub_tlvs.first.to_hash)
    assert_equal a.encode, Tunnel_encap.new(a.encode).encode
    assert_equal [], Path_attribute.new(wire(a.to_shex)).errors
  end

  # RFC 9012 section 13: a malformed sub-TLV is treated as unrecognized,
  # so the attribute is not malformed and the octets are passed on. A
  # Color sub-TLV must be 8 octets (section 3.4.3); this one is 3.
  def test_malformed_sub_tlv_is_not_an_attribute_error
    hex = attr_hex(tlv_hex(8, '0403' + '010203'))
    pa = Path_attribute.new(wire(hex))
    assert_equal [], pa.errors
    assert_equal hex, pa.encode.unpack1('H*'), 'the octets received must be sent back'
    sub = pa[:tunnel_encap].tunnels.first.sub_tlvs.first
    assert_instance_of Sub_tlv, sub, 'kept as a plain sub-TLV, so the octets survive'
    assert_equal [4, '010203'], [sub.type, sub.value.unpack1('H*')]
    assert_nil pa[:tunnel_encap].tunnels.first.color
  end

  # RFC 9012 section 3.4.3: a Color sub-TLV of the right length but
  # without the 0x030b header is treated as unrecognized too.
  def test_color_with_the_wrong_header_is_kept_as_a_plain_sub_tlv
    hex = attr_hex(tlv_hex(8, '0408' + 'ffff' + '0000' + '00000064'))
    pa = Path_attribute.new(wire(hex))
    assert_equal [], pa.errors
    assert_equal hex, pa.encode.unpack1('H*')
    assert_instance_of Sub_tlv, pa[:tunnel_encap].tunnels.first.sub_tlvs.first
    assert_nil pa[:tunnel_encap].tunnels.first.color
    assert Color.shaped?(wire(COLOR100[4..-1]))
  end

  # RFC 9012 section 13 makes these malformed, but they are well shaped,
  # so parsing keeps the class and the accessor shows the bad value.
  def test_bad_field_values_keep_their_class
    a = Tunnel_encap.new(Tunnel.new(:vxlan, Udp_dest_port.new(0), Embedded.new(3)))
    b = Tunnel_encap.new(a.encode)
    assert_equal [Udp_dest_port, Embedded], b.tunnels.first.sub_tlvs.collect(&:class)
    assert_equal [0, 3], b.tunnels.first.sub_tlvs.collect(&:to_i)
    assert_equal a.to_shex, b.to_shex
    assert_equal [], Path_attribute.new(wire(a.to_shex)).errors
  end

  # An empty MPLS label stack is not a multiple-of-4 length, so it comes
  # back as a plain sub-TLV, but its octets survive.
  def test_empty_label_stack_round_trips
    a = Tunnel_encap.new(Tunnel.new(:mpls, Label_stack.new))
    assert_equal attr_hex(tlv_hex(10, '0a00')), a.to_shex
    assert_equal a.encode, Tunnel_encap.new(a.encode).encode
    assert_equal a.encode, Tunnel_encap.new(Tunnel_encap.new(a.encode).to_hash[:tunnel_encap]).encode
  end

  # RFC 9012 section 13: an attribute with no valid TLVs is malformed.
  def test_no_tlvs
    pa = Path_attribute.new(wire('c01700'))
    assert_equal [[23, 5, :treat_as_withdraw]], pa.errors.collect { |f| [f.type, f.subcode, f.action] }
    assert_equal 'c01700', pa.encode.unpack1('H*')
  end

  def test_tlv_header_cut
    hex = attr_hex('000800')
    pa = Path_attribute.new(wire(hex))
    assert_equal [[23, 5, :treat_as_withdraw]], pa.errors.collect { |f| [f.type, f.subcode, f.action] }
    assert_match(/a TLV header needs 4/, pa.errors.first.reason)
    assert_equal hex, pa.encode.unpack1('H*')
  end

  def test_tlv_runs_past_the_attribute
    hex = attr_hex('0008ffff')
    pa = Path_attribute.new(wire(hex))
    assert_equal [[23, 5, :treat_as_withdraw]], pa.errors.collect { |f| [f.type, f.subcode, f.action] }
    assert_match(/runs past the attribute/, pa.errors.first.reason)
    assert_equal hex, pa.encode.unpack1('H*'), 'the octets received must be sent back'
  end

  # RFC 9012 section 13: the last octet of a TLV must be the last octet
  # of its last sub-TLV.
  def test_sub_tlv_runs_past_its_tlv
    hex = attr_hex(tlv_hex(8, '060a0000'))
    pa = Path_attribute.new(wire(hex))
    assert_equal [[23, 5, :treat_as_withdraw]], pa.errors.collect { |f| [f.type, f.subcode, f.action] }
    assert_match(/sub-TLV type 6 runs past TLV type 8/, pa.errors.first.reason)
    assert_equal hex, pa.encode.unpack1('H*')
  end

  def test_sub_tlv_header_cut
    pa = Path_attribute.new(wire(attr_hex(tlv_hex(8, '06'))))
    assert_equal [[23, 5, :treat_as_withdraw]], pa.errors.collect { |f| [f.type, f.subcode, f.action] }
    assert_match(/a sub-TLV header needs 2/, pa.errors.first.reason)
    # Type 200 has a two octet length, so its header needs three.
    long = Path_attribute.new(wire(attr_hex(tlv_hex(8, 'c800'))))
    assert_match(/a sub-TLV header needs 3/, long.errors.first.reason)
    assert_equal attr_hex(tlv_hex(8, 'c800')), long.encode.unpack1('H*')
  end

  # RFC 9012 section 13 and RFC 7606 section 3 (c).
  def test_flags_are_checked
    pa = Path_attribute.new(wire('80' + attr_hex(tlv_hex(8, EGRESS_NH))[2..-1]))
    assert_equal [[23, 4, :treat_as_withdraw]], pa.errors.collect { |f| [f.type, f.subcode, f.action] }
  end

  # Tunnel#length! writes a TLV length that is not the real one, so a
  # test can send the RFC 9012 section 13 malformed case on purpose.
  def test_length_override_builds_a_malformed_tlv
    a = Tunnel_encap.new(Tunnel.new(:vxlan, Egress_endpoint.new('10.0.0.1')).length!(99))
    assert_equal attr_hex('00080063' + EGRESS_V4), a.to_shex
    assert_equal [:treat_as_withdraw], Path_attribute.new(a).validate.collect(&:action)
    assert_equal a.encode, Tunnel_encap.new(a.to_hash[:tunnel_encap]).encode
    assert_nil a.tunnels.first.length!(nil).to_hash[:length]
  end

  def test_bad_values_raise
    assert_raise(ArgumentError) { Tunnel.new(:no_such_tunnel) }
    assert_raise(ArgumentError) { Tunnel.new(0x10000) }
    assert_raise(ArgumentError) { Tunnel.new(:vxlan, 'not a sub-TLV') }
    assert_raise(ArgumentError) { Tunnel_encap.new('not a tunnel') }
    assert_raise(ArgumentError) { Sub_tlv.from_hash(:no_such_sub_tlv => 1) }
  end

  def test_a_good_attribute_has_no_findings
    assert_equal [], Path_attribute.new(wire(attr_hex(tlv_hex(8, EGRESS_V4 + COLOR100)))).errors
    assert_equal [], Path_attribute.new(Tunnel_encap.new(Tunnel.new(:vxlan,
                       Egress_endpoint.new('10.0.0.1')))).validate
  end

  def test_path_attribute_accessors
    pa = Path_attribute.new(:origin => :igp,
                            :tunnel_encap => [{:tunnel_type => :vxlan,
                                               :egress_endpoint => '10.0.0.1'}])
    assert pa.has_a_tunnel_encap_attr?
    assert_equal '10.0.0.1', pa.tunnel_encap.tunnels.first.egress_endpoint
    assert_equal pa.encode, Path_attribute.new(pa.encode.is_packed).encode
  end

  # RFC 9012 section 3.2: the shape depends on the tunnel type, so bgp4r
  # keeps the octets and reads no field. Its own new took the hash
  # straight through as the value and Sub_tlv called to_s on it, so the
  # sub-TLV value became the 28 octets of {:encapsulation=>"01020304"} as
  # Ruby inspects it. On the wire, with no error. Sub_tlv.from_hash read
  # the same hash correctly all along, which is why nothing caught it.
  def test_encapsulation_round_trips_through_its_own_new
    e = BGP::Tunnel_encap::Encapsulation.new([1, 2, 3, 4].pack('C4'))
    assert_equal({ :encapsulation => '01020304' }, e.to_hash)
    assert_equal(e.encode, BGP::Tunnel_encap::Encapsulation.new(e.to_hash).encode)
    assert_equal(e.encode, BGP::Tunnel_encap::Sub_tlv.from_hash(e.to_hash).encode)
  end

end
