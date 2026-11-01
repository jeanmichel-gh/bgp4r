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

require 'test/unit'
require 'bgp/nlris/link_state_node_attribute'
# TLV 263 is Table 4's and Table 6's and is registered by the link
# descriptor file, so the case asserting that it is shared needs that
# file as code. **The source no longer requires it**: part 5b-i moved
# `Addr_tlv` into `link_state_tlv.rb`, which was the only reason it
# did. So the require moved to where the claim is, which is here, and
# running this file on its own is what said so.
require 'bgp/nlris/link_state_link_descriptor'

# **RFC 9552 carries no worked example and no hex anywhere**, measured
# in part 1: the six occurrences of "0x" in the document are the OSPF
# route type values of section 5.2.3.1. So every expectation here is
# this reader's arithmetic from the Table 6 widths and the section 5.1
# framing, not the document's own octets. The field breakdown is written
# out beside each case for that reason; the arithmetic is the thing to
# doubt first when one of these fails. Part 1 got one wrong within the
# hour and part 4 got one wrong backwards.
#
# The type numbers are worth converting once here, since Table 6 gives
# decimals and the wire carries two octets: 1024 is 0x0400, 1025 is
# 0x0401, 1026 is 0x0402, 1027 is 0x0403, 1028 is 0x0404 and 1029 is
# 0x0405.
class TestLinkStateNodeAttribute < Test::Unit::TestCase

  include BGP

  # --- TLV 1024, Node Flag Bits, section 5.3.1.1 ----------------------

  # One octet of value in a five-octet TLV. 0x80 is 'O', the Overload
  # bit, which Table 7 puts first and Figure 15 draws leftmost.
  def test_the_node_flag_bits_tlv
    t = BGP::Link_state::Tlv::Node_flag_bits.new(:overload)
    assert_equal(1024, t.type)
    assert_equal('04000001' + '80', t.to_shex)
    assert_equal(0x80, t.value)
    assert(t.overload?)
    assert_equal('Node flags overload', t.to_s)
  end

  # **The bit each name sits at, asserted against Table 7 one by one**,
  # because a reversal of a set of disjoint masks is still a set of
  # disjoint masks and a round trip cannot see it: encoder and decoder
  # share the mistake. The pairs below are the document's, Figure 15's
  # order read against Table 7's list, with erratum 7789 applied.
  def test_each_flag_sits_at_the_bit_its_own_table_gives_it
    { :overload => 0x80, :attached => 0x40, :external => 0x20,
      :abr => 0x10, :router => 0x08, :v6 => 0x04 }.each do |name, mask|
      t = BGP::Link_state::Tlv::Node_flag_bits.new(name)
      assert_equal(mask, t.value, "#{name} should be #{format('0x%02x', mask)}")
      assert_equal([name], t.names)
      assert(t.set?(name))
    end
  end

  # **Erratum ID 7789, Technical, verified.** Figure 15 prints
  # `|O|T|E|B|R|V|` where Table 7 of the same section defines the second
  # bit as 'A', the Attached Bit. The erratum is that one letter. So the
  # name here is attached and there is no T bit, and this test says so
  # rather than leaving a reader to wonder which the library followed.
  def test_the_second_bit_is_attached_and_not_the_figures_t
    t = BGP::Link_state::Tlv::Node_flag_bits.new(:attached)
    assert_equal(0x40, t.value)
    assert(t.attached?)
    assert_raise(KeyError) { t.set?(:t) }
    assert_raise(ArgumentError) do
      BGP::Link_state::Tlv::Node_flag_bits.new(:t)
    end
  end

  # The six masks tile the octet's top six bits and no two claim a bit.
  # Coverage alone proves nothing, since OR is idempotent, so both
  # halves are here.
  def test_the_masks_cover_six_bits_and_overlap_nowhere
    bits = BGP::Link_state::Tlv::Node_flag_bits::BITS.values
    assert_equal(0xfc, bits.inject(0) { |a, b| a | b })
    assert_equal(0xfc, BGP::Link_state::Tlv::Node_flag_bits::DEFINED_BITS)
    bits.combination(2).each do |a, b|
      assert_equal(0, a & b, "#{format('0x%02x', a)} and " \
                             "#{format('0x%02x', b)} share a bit")
    end
  end

  def test_several_flags_at_once_in_either_form
    hex = '04000001' + 'c0'
    assert_equal(hex, BGP::Link_state::Tlv::Node_flag_bits
                        .new(:overload, :attached).to_shex)
    assert_equal(hex, BGP::Link_state::Tlv::Node_flag_bits
                        .new([:attached, :overload]).to_shex)
    assert_equal(hex, BGP::Link_state::Tlv::Node_flag_bits.new(0xc0).to_shex)
  end

  # Section 5.3.1.1: "The bits that are not defined MUST be set to 0 by
  # the originator and MUST be ignored by the receiver." So a build from
  # names writes them as 0, and a value that arrived with one set keeps
  # it and echoes it, which is the rule Conventions records for
  # Traffic_action, Prefix_entry and Evpn::Flags.
  def test_an_undefined_bit_is_kept_and_echoed
    t = BGP::Link_state::Tlv::Node_flag_bits.new([0x83].pack('C').is_packed)
    assert_equal('04000001' + '83', t.to_shex)
    assert_equal([:overload], t.names)
    assert_equal(3, t.undefined_bits)
    assert(t.undefined_bits?)
    assert_equal('Node flags overload, undefined bits 11', t.to_s)
  end

  def test_an_ordinary_flags_hash_is_the_plain_list
    t = BGP::Link_state::Tlv::Node_flag_bits.new(:router, :v6)
    assert_equal({ :node_flag_bits => [:router, :v6] }, t.to_hash)
    assert_equal(t.to_shex,
                 BGP::Link_state::Tlv::Node_flag_bits.new(t.to_hash).to_shex)
  end

  # The whole octet rides behind the names only when an undefined bit is
  # set, and then the hash has to rebuild the octet and not the names.
  def test_the_hash_of_an_undefined_bit_rebuilds_the_octet
    t = BGP::Link_state::Tlv::Node_flag_bits.new([0x83].pack('C').is_packed)
    assert_equal({ :node_flag_bits => [:overload, { :bits => 0x83 }] },
                 t.to_hash)
    assert_equal(t.to_shex,
                 BGP::Link_state::Tlv::Node_flag_bits.new(t.to_hash).to_shex)
  end

  def test_no_flag_set_is_a_zero_octet
    t = BGP::Link_state::Tlv::Node_flag_bits.new
    assert_equal('04000001' + '00', t.to_shex)
    assert_equal([], t.names)
    assert_equal('Node flags none', t.to_s)
    assert_equal(t.to_shex,
                 BGP::Link_state::Tlv::Node_flag_bits.new(t.to_hash).to_shex)
  end

  # A value wider than the one octet Table 6 gives is not this TLV, so
  # it falls back to Tlv::Unknown and replays. Same rule as part 3's
  # Addr_tlv, and it is what keeps a family of fixed widths honest.
  def test_a_wider_value_reads_back_as_an_unknown_tlv
    hex = '04000002' + 'c0c0'
    t = BGP::Link_state::Tlv.factory([hex].pack('H*'))
    assert_instance_of(BGP::Link_state::Tlv::Unknown, t)
    assert_equal(hex, t.to_shex)
  end

  # --- TLV 1025 and 1027, the opaque pair -----------------------------

  # Section 5.3.1.5 gives the whole layout in one line: "The Type is as
  # specified in Table 6. The length is variable."
  def test_the_opaque_node_attribute_tlv
    t = BGP::Link_state::Tlv::Opaque_node_attribute
          .new(['deadbeef'].pack('H*'))
    assert_equal(1025, t.type)
    assert_equal('04010004' + 'deadbeef', t.to_shex)
    assert_equal('Opaque node attribute 4 octets [deadbeef]', t.to_s)
    assert_equal({ :opaque_node_attribute => 'deadbeef' }, t.to_hash)
    assert_equal(t.to_shex, BGP::Link_state::Tlv::Opaque_node_attribute
                              .new(t.to_hash).to_shex)
  end

  # Area 49.0001 is three octets, which is the IS-IS area address a
  # reader will recognise. **The dotted form is not parsed here**, by
  # decision: section 5.3.1.2 gives the value as "IS-IS Area Identifier
  # (variable)" and nothing more, so a presentation form would be
  # bgp4r's invention and nothing could check it.
  def test_the_isis_area_identifier_tlv
    t = BGP::Link_state::Tlv::Isis_area_id.new(['490001'].pack('H*'))
    assert_equal(1027, t.type)
    assert_equal('04030003' + '490001', t.to_shex)
    assert_equal('IS-IS area 3 octets [490001]', t.to_s)
    assert_equal({ :isis_area_id => '490001' }, t.to_hash)
    assert_equal(t.to_shex,
                 BGP::Link_state::Tlv::Isis_area_id.new(t.to_hash).to_shex)
  end

  # Section 5.1 permits a value of nothing outright: "a TLV with no
  # value portion would have a length of zero".
  def test_an_opaque_tlv_with_no_value
    t = BGP::Link_state::Tlv::Opaque_node_attribute.new
    assert_equal('04010000', t.to_shex)
    assert_equal('Opaque node attribute 0 octets', t.to_s)
    assert_equal(t.to_shex, BGP::Link_state::Tlv::Opaque_node_attribute
                              .new(t.to_hash).to_shex)
  end

  # The octet buffer is BINARY, which is the Ruby version bug #218 shipped
  # in this family: `+''` is US-ASCII and an empty one handed to IPAddr
  # raises on 3.4 and passes on 3.3. Assert the buffer and not `encode`,
  # which `pack` forces binary whatever went in.
  def test_the_opaque_buffers_are_binary
    assert_equal(Encoding::BINARY,
                 BGP::Link_state::Tlv::Opaque_node_attribute.new.value.encoding)
    assert_equal(Encoding::BINARY,
                 BGP::Link_state::Tlv::Isis_area_id.new.value.encoding)
    assert_equal(Encoding::BINARY,
                 BGP::Link_state::Tlv::Node_name.new.name.encoding)
  end

  # --- TLV 1026, Node Name, section 5.3.1.3 ---------------------------

  # 'router1' is seven octets of 7-bit ASCII, which is what the section
  # asks for.
  def test_the_node_name_tlv
    t = BGP::Link_state::Tlv::Node_name.new('router1')
    assert_equal(1026, t.type)
    assert_equal('04020007' + '726f7574657231', t.to_shex)
    assert_equal('router1', t.name)
    assert(t.ascii?)
    assert_equal("Node name 'router1'", t.to_s)
    assert_equal({ :node_name => 'router1' }, t.to_hash)
    assert_equal(t.to_shex,
                 BGP::Link_state::Tlv::Node_name.new(t.to_hash).to_shex)
  end

  # **The one class in Table 6 whose field form and hash form are the
  # same String**, because the value is text where 1025's and 1027's are
  # not. Said as a test so the asymmetry is on record rather than only
  # in a comment.
  def test_the_name_is_text_where_its_siblings_are_hex
    assert_equal({ :node_name => 'abc' },
                 BGP::Link_state::Tlv::Node_name.new('abc').to_hash)
    assert_equal({ :isis_area_id => '616263' },
                 BGP::Link_state::Tlv::Isis_area_id.new('abc').to_hash)
  end

  def test_a_name_read_off_the_wire
    t = BGP::Link_state::Tlv.factory([('04020003' + '616263')].pack('H*'))
    assert_instance_of(BGP::Link_state::Tlv::Node_name, t)
    assert_equal('abc', t.name)
    assert_equal('04020003616263', t.to_shex)
  end

  # --- TLV 1028 and 1029, the local Router-IDs, section 5.3.1.4 -------

  # Table 6 gives 4 octets citing RFC 5305 section 4.3, so the TLV is 8.
  def test_the_ipv4_local_router_id_tlv
    t = BGP::Link_state::Tlv::Ipv4_local_router_id.new('10.0.0.1')
    assert_equal(1028, t.type)
    assert_equal('04040004' + '0a000001', t.to_shex)
    assert_equal('Local IPv4 Router-ID 10.0.0.1', t.to_s)
    assert_equal({ :ipv4_local_router_id => '10.0.0.1' }, t.to_hash)
    assert_equal(t.to_shex, BGP::Link_state::Tlv::Ipv4_local_router_id
                              .new(t.to_hash).to_shex)
  end

  # Table 6 gives 16 octets citing RFC 6119 section 4.1, so the TLV is 20.
  def test_the_ipv6_local_router_id_tlv
    t = BGP::Link_state::Tlv::Ipv6_local_router_id.new('2001:db8::1')
    assert_equal(1029, t.type)
    assert_equal('04050010' + '20010db8000000000000000000000001', t.to_shex)
    assert_equal('Local IPv6 Router-ID 2001:db8::1', t.to_s)
    assert_equal({ :ipv6_local_router_id => '2001:db8::1' }, t.to_hash)
    assert_equal(t.to_shex, BGP::Link_state::Tlv::Ipv6_local_router_id
                              .new(t.to_hash).to_shex)
  end

  # The two widths cannot be confused, which is part 3's Addr_tlv lesson
  # arriving in Table 6: IPAddr.new_ntoh reads 4 octets as IPv4 and 16 as
  # IPv6 and hton gives back whatever it was handed, so a 4-octet value
  # under type 1029 reproduced itself until parse required the width.
  def test_a_four_octet_value_is_not_an_ipv6_router_id
    hex = '04050004' + '0a000001'
    t = BGP::Link_state::Tlv.factory([hex].pack('H*'))
    assert_instance_of(BGP::Link_state::Tlv::Unknown, t)
    assert_equal(hex, t.to_shex)
  end

  # --- the registry and the family ------------------------------------

  # Table 6's six new code points, each registered to the class that
  # reads it and to a hash key of its own.
  def test_table_6_is_registered
    { 1024 => BGP::Link_state::Tlv::Node_flag_bits,
      1025 => BGP::Link_state::Tlv::Opaque_node_attribute,
      1026 => BGP::Link_state::Tlv::Node_name,
      1027 => BGP::Link_state::Tlv::Isis_area_id,
      1028 => BGP::Link_state::Tlv::Ipv4_local_router_id,
      1029 => BGP::Link_state::Tlv::Ipv6_local_router_id,
    }.each do |type, klass|
      assert_equal(klass, BGP::Link_state::Tlv::REGISTRY[type])
      assert_equal(klass, BGP::Link_state::Tlv::BY_KEY[klass.hash_key])
      assert_equal(type, klass.type)
    end
  end

  # **TLV 263 is Table 4's and Table 6's and it is one class**, which is
  # the flat registry paying for itself rather than a shortcut: section
  # 5.3.1's row for it cites section 5.2.2.1, its own definition. So the
  # Multi-Topology Identifier needed nothing from this part.
  def test_the_multi_topology_identifier_is_shared_and_not_redefined
    assert_equal(BGP::Link_state::Tlv::Multi_topology_id,
                 BGP::Link_state::Tlv::REGISTRY[263])
    assert_equal('01070002' + '0001',
                 BGP::Link_state::Tlv::Multi_topology_id.new(1).to_shex)
  end

  # Table 6's own row for 1024 says "1", so a TLV of five octets, and
  # the two Router-IDs are 8 and 20. Asserted together because a reader
  # comparing widths across the table will otherwise work them out.
  def test_the_fixed_widths_of_table_6
    assert_equal(5, BGP::Link_state::Tlv::Node_flag_bits.new.size)
    assert_equal(8, BGP::Link_state::Tlv::Ipv4_local_router_id.new.size)
    assert_equal(20, BGP::Link_state::Tlv::Ipv6_local_router_id.new.size)
  end

  # Nothing validates, per Conventions. Six things no RFC allows, each
  # of which a test of a router has to be able to put on the wire.
  def test_nothing_validates
    # An undefined bit set, which the section says MUST be 0.
    assert_equal('0400000103',
                 BGP::Link_state::Tlv::Node_flag_bits.new(0x03).to_shex)
    # A name that is not 7-bit ASCII.
    t = BGP::Link_state::Tlv::Node_name.new(['ff'].pack('H*'))
    assert_equal('04020001ff', t.to_shex)
    assert(!t.ascii?)
    # A name past the section's 255, on either reading of that sentence.
    assert_equal(300, BGP::Link_state::Tlv::Node_name.new('a' * 300)
                        .encode_value.size)
    # An IS-IS area address of a length ISO 10589 does not describe.
    assert_equal('0403000101',
                 BGP::Link_state::Tlv::Isis_area_id.new(['01'].pack('H*'))
                   .to_shex)
    # A Length that disagrees with the value that came with it.
    f = BGP::Link_state::Tlv::Node_flag_bits.new(:overload)
    f.declared_len = 9
    assert_equal('0400000980', f.to_shex)
    # An empty node name, which the section calls a symbolic name.
    assert_equal('04020000', BGP::Link_state::Tlv::Node_name.new.to_shex)
  end

  # A value the field cannot hold is the one refusal Conventions allows,
  # and the octet-level route stays open, which it requires.
  def test_a_value_the_octet_cannot_hold_is_refused
    assert_raise(ArgumentError) do
      BGP::Link_state::Tlv::Node_flag_bits.new(0x100)
    end
    assert_equal('04000002' + '0100',
                 BGP::Link_state::Tlv::Unknown
                   .new(1024, ['0100'].pack('H*')).to_shex)
  end

  # Every class here builds from another instance, which is the fourth
  # build path and the one that catches an encoder that consumes what it
  # was handed.
  def test_every_class_builds_from_another_instance
    [BGP::Link_state::Tlv::Node_flag_bits.new(:overload, :v6),
     BGP::Link_state::Tlv::Opaque_node_attribute.new(['dead'].pack('H*')),
     BGP::Link_state::Tlv::Node_name.new('r1'),
     BGP::Link_state::Tlv::Isis_area_id.new(['490001'].pack('H*')),
     BGP::Link_state::Tlv::Ipv4_local_router_id.new('10.0.0.1'),
     BGP::Link_state::Tlv::Ipv6_local_router_id.new('2001:db8::1'),
    ].each do |t|
      assert_equal(t.to_shex, t.class.new(t).to_shex, t.class.to_s)
      assert_equal(t.to_shex, t.class.new(t).to_shex,
                   "#{t.class} was consumed by its own copy")
    end
  end

  # The argument neither a value, a hash nor an instance. Each class
  # says so rather than building something else, which is the
  # `Multicast_flags` hazard Conventions records: a class may refuse an
  # input, it may not accept one and build a different object.
  def test_an_argument_no_class_here_understands_is_refused
    [BGP::Link_state::Tlv::Node_flag_bits,
     BGP::Link_state::Tlv::Opaque_node_attribute,
     BGP::Link_state::Tlv::Node_name,
     BGP::Link_state::Tlv::Isis_area_id,
    ].each do |klass|
      assert_raise(ArgumentError, klass.to_s) { klass.new(1, 2, 3) }
    end
    assert_raise(ArgumentError) do
      BGP::Link_state::Tlv::Opaque_node_attribute.new(42)
    end
    assert_raise(ArgumentError) { BGP::Link_state::Tlv::Node_name.new(42) }
  end

  # **The two variable-width classes do not consume what they are
  # handed, and have no `is_packed?` branch to decide it.** For a
  # fixed-width class that test tells a wire value from a field value;
  # here the value is the octets, so both readings take everything and
  # the only thing left to decide would be whether the caller's String
  # survives. It does. `Array#pack` marks its result packed, so a
  # consuming branch would have taken almost every octet string a
  # caller holds without the caller choosing it.
  def test_the_variable_classes_do_not_consume_their_argument
    octets = ['deadbeef'].pack('H*')
    assert(octets.is_packed?, 'pack marks its result')
    t = BGP::Link_state::Tlv::Opaque_node_attribute.new(octets)
    assert_equal('deadbeef', t.value.unpack1('H*'))
    assert_equal(4, octets.size, 'and the caller still has its octets')
    name = ['616263'].pack('H*')
    assert_equal('abc', BGP::Link_state::Tlv::Node_name.new(name).name)
    assert_equal(3, name.size)
    assert(!BGP::Link_state::Tlv::Opaque_tlv.method_defined?(:parse),
           'and neither has a parse, since nothing would call one')
  end

  # Section 5.3.1.2 says the IS-IS Area Identifier repeats: "If multiple
  # area addresses are present, multiple TLVs are used to encode them."
  # So two of a type in one list is ordinary traffic here, and section
  # 5.1's Length and Value tiebreakers are what order them.
  def test_two_area_identifiers_in_one_list
    hex = '04030003' + '490001' + '04030003' + '490002'
    list = BGP::Link_state::Tlv.parse_list([hex].pack('H*'))
    assert_equal(2, list.size)
    assert(list.all? do |t|
      t.is_a?(BGP::Link_state::Tlv::Isis_area_id)
    end)
    assert_equal(hex, list.collect { |t| t.to_shex }.join)
    assert(BGP::Link_state::Tlv.ordered?(list))
  end

end
