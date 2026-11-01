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
require 'bgp/nlris/link_state_nlri'

# **RFC 9552 carries no worked example and no hex anywhere**, so every
# expectation here is this reader's arithmetic from the figure 7 field
# widths. The breakdown is written out beside each case for that
# reason; the arithmetic is the thing to doubt first when one fails.
class TestLinkStateNlri < Test::Unit::TestCase

  include BGP

  # The head of every Link-State NLRI type: a Protocol-ID octet and an
  # 8-octet Identifier. Written out once so the cases below can say
  # what they add to it. Protocol-ID 2 is IS-IS Level 2, Table 2, and
  # the Identifier is the BGP-LS Instance-ID.
  HEAD = '02' + '0000000000000000'

  # A Local Node Descriptors TLV holding one AS sub-TLV: type 256,
  # length 8, then type 512, length 4, 65000.
  LOCAL = '01000008' + '020000040000fde8'

  # --- section 5.2, figure 7 ------------------------------------------

  def test_the_node_nlri_is_the_head_and_its_descriptor_tlvs
    n = BGP::Link_state::Node.new(
      2, 0, BGP::Link_state::Tlv::Local_node_descriptors.new(
        BGP::Link_state::Tlv::Autonomous_system.new(65000)))
    assert_equal(1, n.type)
    assert_equal(HEAD + LOCAL, n.to_shex)
    # 1 + 8 + 12 octets of value.
    assert_equal(21, n.encode.size)
  end

  def test_the_identifier_is_eight_octets
    n = BGP::Link_state::Node.new(1, 0xffffffffffffffff)
    assert_equal('01' + 'ffffffffffffffff', n.to_shex)
    assert_equal(0xffffffffffffffff, n.identifier)
  end

  # The one place a Node NLRI's head can be got wrong in a way nothing
  # else catches: the Identifier is big endian and eight octets, so a
  # small Instance-ID is seven zero octets and then the value.
  def test_a_small_instance_id_is_big_endian_in_eight_octets
    assert_equal('03' + '0000000000000005',
                 BGP::Link_state::Node.new(3, 5).to_shex)
  end

  def test_the_whole_nlri_through_the_framing
    n = BGP::Link_state::Node.new(
      2, 0, BGP::Link_state::Tlv::Local_node_descriptors.new(
        BGP::Link_state::Tlv::Autonomous_system.new(65000)))
    ls = BGP::Link_state.new(n)
    # NLRI type 1, Total NLRI Length 21 (0x15), then the value.
    assert_equal('0001' + '0015' + HEAD + LOCAL, ls.to_shex)
    assert_equal(21, ls.length)
    assert_equal(BGP::Link_state.nlri_size([ls.to_shex].pack('H*')),
                 ls.size)
  end

  def test_a_node_nlri_parses_back_through_the_framing
    hex = '0001' + '0015' + HEAD + LOCAL
    ls = BGP::Link_state.new_ntop([hex].pack('H*'))
    assert_equal(BGP::Link_state::Node, ls.nlri.class)
    assert_equal(2, ls.nlri.protocol_id)
    assert_equal(0, ls.nlri.identifier)
    assert_equal(hex, ls.to_shex)
  end

  # --- Table 2, the Protocol-IDs --------------------------------------

  def test_every_protocol_id_table_2_defines
    { 1 => 'IS-IS Level 1', 2 => 'IS-IS Level 2', 3 => 'OSPFv2',
      4 => 'Direct', 5 => 'Static configuration',
      6 => 'OSPFv3' }.each do |id, name|
      assert_equal(name, BGP::Link_state::Node.new(id, 0).protocol,
                   "Protocol-ID #{id}")
    end
  end

  # The ranges around Table 2, from the IANA registry: 0 Reserved, 200
  # to 255 Private Use, and everything else unassigned.
  def test_the_ranges_around_table_2
    assert_equal('Reserved', BGP::Link_state::Node.new(0, 0).protocol)
    assert_equal('Unassigned', BGP::Link_state::Node.new(7, 0).protocol)
    assert_equal('Unassigned', BGP::Link_state::Node.new(199, 0).protocol)
    assert_equal('Private use', BGP::Link_state::Node.new(200, 0).protocol)
    assert_equal('Private use', BGP::Link_state::Node.new(255, 0).protocol)
  end

  # A name reads better than a number in a test, and the table is small
  # enough to accept one.
  def test_a_protocol_can_be_named_rather_than_numbered
    assert_equal(3, BGP::Link_state::Node.new('OSPFv2', 0).protocol_id)
    assert_equal(1, BGP::Link_state::Node.new('IS-IS Level 1', 0).protocol_id)
    assert_equal(5, BGP::Link_state::Node.new('static configuration',
                                              0).protocol_id)
    assert_raise(ArgumentError) { BGP::Link_state::Node.new('OSPFv4', 0) }
  end

  # --- the body is a TLV list -----------------------------------------

  # **Section 5.1 is why**, not convenience: "Unknown and unsupported
  # types MUST be preserved and propagated within both the NLRI and the
  # BGP-LS Attribute", and their presence "MUST NOT result in the NLRI
  # or the BGP-LS Attribute being considered malformed". A layout of
  # named fields would have nowhere to put this TLV.
  def test_a_tlv_with_no_class_is_preserved_in_the_body
    hex = HEAD + LOCAL + '00ff0004deadbeef'
    n = BGP::Link_state::Node.new([hex].pack('H*').is_packed)
    assert_equal(2, n.tlvs.size)
    assert_equal([BGP::Link_state::Tlv::Local_node_descriptors,
                  BGP::Link_state::Tlv::Unknown],
                 n.tlvs.collect { |t| t.class })
    assert_equal(hex, n.to_shex)
  end

  # Section 5.2.1.2 calls the Local Node Descriptors TLV "a mandatory
  # TLV in all three types of NLRIs", and this builds an NLRI without
  # one anyway. Right twice over: building never validates, and section
  # 8.2.2 names "presence of a mandatory TLV" among the semantic
  # validations a BGP-LS Propagator should **not** perform.
  def test_a_node_nlri_with_no_descriptors_builds_and_parses
    n = BGP::Link_state::Node.new(2, 0)
    assert_equal(HEAD, n.to_shex)
    assert_nil(n.local_node_descriptors)
    assert_equal(HEAD,
                 BGP::Link_state::Node.new(
                   [HEAD].pack('H*').is_packed).to_shex)
  end

  def test_octets_too_short_to_frame_a_tlv_are_kept_as_a_tail
    hex = HEAD + LOCAL + 'ffffff'
    n = BGP::Link_state::Node.new([hex].pack('H*').is_packed)
    assert_equal(1, n.tlvs.size)
    assert_equal('ffffff', n.tail.unpack1('H*'))
    assert_equal(hex, n.to_shex)
    assert_match(/tail \[ffffff\]/, n.to_s)
  end

  # A body too short for the head takes what it can, cannot reproduce
  # itself, and so is kept whole by `Link_state::Unknown` instead. That
  # is part 1's encode-matches rule, and it is why nothing in `Headed`
  # has to refuse a short body.
  def test_a_body_too_short_for_the_head_falls_back_to_unknown
    (0..8).each do |n|
      hex = format('0001%04x', n) + 'aa' * n
      ls = BGP::Link_state.new_ntop([hex].pack('H*'))
      assert_equal(BGP::Link_state::Unknown, ls.nlri.class,
                   "a #{n} octet body cannot be a Node NLRI")
      assert_equal(hex, ls.to_shex)
    end
    # Nine octets is exactly the head and no TLVs, which is a Node.
    hex = '00010009' + 'aa' * 9
    assert_equal(BGP::Link_state::Node,
                 BGP::Link_state.new_ntop([hex].pack('H*')).nlri.class)
  end

  def test_the_first_tlv_of_a_type_is_what_a_reader_gets
    d1 = BGP::Link_state::Tlv::Local_node_descriptors.new(
      BGP::Link_state::Tlv::Autonomous_system.new(1))
    d2 = BGP::Link_state::Tlv::Local_node_descriptors.new(
      BGP::Link_state::Tlv::Autonomous_system.new(2))
    n = BGP::Link_state::Node.new(2, 0, d1, d2)
    assert_equal(1, n.local_node_descriptors.sub_tlvs.first.value,
                 'two of a type is not impossible at this level, and the ' \
                 'first is what a reader asks for')
    assert_nil(n.tlv(999))
  end

  # --- section 5.2.1.4's node type rule -------------------------------

  # "The TLV size in combination with the protocol identifier enables
  # the decoder to determine the type of the node."
  #
  # Both halves, which is why this lives on the NLRI: the width is the
  # IGP Router-ID sub-TLV's and the Protocol-ID is the NLRI's.
  def test_the_node_type_needs_the_width_and_the_protocol_id
    { [1, '1921.6800.1001']      => :non_pseudonode,
      [2, '1921.6800.1001']      => :non_pseudonode,
      [1, '1921.6800.1001.02']   => :pseudonode,
      [2, '1921.6800.1001.02']   => :pseudonode,
      [3, '0a000001']            => :non_pseudonode,
      [6, '0a000001']            => :non_pseudonode,
      [3, '0a0000010a000002']    => :pseudonode,
      [6, '0a0000010a000002']    => :pseudonode }.each do |(p, r), kind|
      n = node_with(p, r)
      assert_equal(kind, n.node_type, "Protocol-ID #{p} with #{r}")
      assert_match(/\(#{kind}\)/, n.to_s)
    end
  end

  # **nil is an answer and not a failure**, and these are the four ways
  # to reach it. The 'Direct' case is the one that matters: section
  # 5.2.1.4 says that for 'Direct' or 'Static configuration' the value
  # "SHOULD be taken from an IPv4 or IPv6 address", so it describes no
  # node kind there at all and reporting one would be inventing it.
  def test_the_node_type_is_nil_where_the_section_names_none
    # A width the section describes, under a Protocol-ID it does not
    # describe that width for.
    assert_nil(node_with(4, '0a000001').node_type, 'Direct')
    assert_nil(node_with(5, '1921.6800.1001').node_type, 'Static')
    assert_nil(node_with(1, '0a000001').node_type,
               'IS-IS with a 4 octet Router-ID')
    assert_nil(node_with(3, '1921.6800.1001').node_type,
               'OSPFv2 with a 6 octet Router-ID')
    # A width the section does not describe at all.
    assert_nil(node_with(1, '010203').node_type)
    # A Protocol-ID outside Table 2.
    assert_nil(node_with(200, '0a000001').node_type)
    # No IGP Router-ID sub-TLV.
    assert_nil(BGP::Link_state::Node.new(
      1, 0, BGP::Link_state::Tlv::Local_node_descriptors.new(
        BGP::Link_state::Tlv::Autonomous_system.new(1))).node_type)
    # No Local Node Descriptors TLV at all.
    assert_nil(BGP::Link_state::Node.new(1, 0).node_type)
  end

  # The rule reads the **Local** Node Descriptors and not any Router-ID
  # that happens to be in the NLRI, since the Remote one describes the
  # other end of a link.
  def test_the_node_type_reads_the_local_descriptors
    n = BGP::Link_state::Node.new(
      1, 0, BGP::Link_state::Tlv::Remote_node_descriptors.new(
        BGP::Link_state::Tlv::Igp_router_id.new('1921.6800.1001')))
    assert_nil(n.node_type)
  end

  # --- the four build paths -------------------------------------------

  def test_builds_from_field_values
    n = BGP::Link_state::Node.new(
      2, 7, BGP::Link_state::Tlv::Local_node_descriptors.new(
        BGP::Link_state::Tlv::Autonomous_system.new(65000)))
    assert_equal('02' + '0000000000000007' + LOCAL, n.to_shex)
  end

  def test_builds_from_a_hash
    h = { :node => { :protocol_id => 2, :identifier => 0,
                     :tlvs => [{ :local_node_descriptors =>
                                 [{ :autonomous_system => 65000 }] }] } }
    assert_equal(HEAD + LOCAL, BGP::Link_state::Node.new(h).to_shex)
  end

  def test_builds_from_wire_bytes
    assert_equal(HEAD + LOCAL,
                 BGP::Link_state::Node.new(
                   [HEAD + LOCAL].pack('H*').is_packed).to_shex)
  end

  def test_builds_from_another_instance
    a = BGP::Link_state::Node.new(
      2, 0, BGP::Link_state::Tlv::Local_node_descriptors.new(
        BGP::Link_state::Tlv::Autonomous_system.new(65000)))
    b = BGP::Link_state::Node.new(a)
    assert_equal(a.to_shex, b.to_shex)
    assert_equal(1, a.tlvs.size, 'copying must not empty the original')
  end

  def test_refuses_an_argument_it_cannot_read
    assert_raise(ArgumentError) { BGP::Link_state::Node.new }
    assert_raise(ArgumentError) { BGP::Link_state::Node.new(42) }
  end

  def test_a_tlv_can_be_appended
    n = BGP::Link_state::Node.new(2, 0)
    n << BGP::Link_state::Tlv::Local_node_descriptors.new(
      BGP::Link_state::Tlv::Autonomous_system.new(65000))
    assert_equal(HEAD + LOCAL, n.to_shex)
  end

  # --- to_hash ---------------------------------------------------------

  # The two-places rule in Conventions: a working round trip is
  # asserted here and in test/unit/to_hash_catalog.rb. Every field the
  # class carries is exercised, the tail included.
  def test_rebuilds_from_its_own_hash_with_every_field_set
    hex = HEAD + LOCAL + 'ffffff'
    n = BGP::Link_state::Node.new([hex].pack('H*').is_packed)
    h = n.to_hash
    assert_equal(2, h[:node][:protocol_id])
    assert_equal(0, h[:node][:identifier])
    assert_equal('ffffff', h[:node][:tail])
    assert_equal(hex, BGP::Link_state::Node.new(h).to_shex)
  end

  def test_no_tail_means_no_tail_key
    n = BGP::Link_state::Node.new(2, 0)
    assert_equal({ :node => { :protocol_id => 2, :identifier => 0,
                              :tlvs => [] } }, n.to_hash)
  end

  # And through the NLRI above it, which is how a test writes one.
  def test_the_nlri_rebuilds_a_node_from_its_own_hash
    ls = BGP::Link_state.new(
      :node => { :protocol_id => 3, :identifier => 1,
                 :tlvs => [{ :local_node_descriptors =>
                             [{ :igp_router_id => '0a000001' }] }] })
    assert_equal(BGP::Link_state::Node, ls.nlri.class)
    assert_equal(:non_pseudonode, ls.nlri.node_type)
    assert_equal(ls.to_shex, BGP::Link_state.new(ls.to_hash).to_shex)
  end

  # --- the registry ----------------------------------------------------

  def test_the_node_nlri_is_registered_both_ways
    assert_equal(BGP::Link_state::Node, BGP::Link_state::TYPES[1])
    assert_equal(BGP::Link_state::Node, BGP::Link_state::BY_KEY[:node])
  end

  # --- nothing validates ----------------------------------------------

  # Five things no RFC allows, each building and encoding.
  def test_nothing_validates
    # Protocol-ID 0, which the registry reserves.
    assert_equal('00' + '0000000000000000',
                 BGP::Link_state::Node.new(0, 0).to_shex)
    # A Node NLRI carrying a Remote Node Descriptors TLV, which section
    # 5.2.1.3 makes a Link NLRI's field.
    n = BGP::Link_state::Node.new(
      2, 0, BGP::Link_state::Tlv::Remote_node_descriptors.new(
        BGP::Link_state::Tlv::Autonomous_system.new(1)))
    assert_equal(HEAD + '01010008' + '0200000400000001', n.to_shex)
    # Two Local Node Descriptors TLVs, where figure 7 shows one.
    d = BGP::Link_state::Tlv::Local_node_descriptors.new(
      BGP::Link_state::Tlv::Autonomous_system.new(1))
    assert_equal(HEAD + d.to_shex * 2,
                 BGP::Link_state::Node.new(2, 0, d, d).to_shex)
    # Descending TLV order, which section 5.1 makes malformed in an
    # NLRI, inside a Node NLRI that builds anyway.
    two = BGP::Link_state::Node.new(
      2, 0, BGP::Link_state::Tlv::Remote_node_descriptors.new, d)
    assert_equal(false, BGP::Link_state::Tlv.ordered?(two.tlvs))
    assert_equal(HEAD + '01010000' + d.to_shex, two.to_shex)
    # No descriptors at all, which section 5.2.1.2 calls mandatory.
    assert_equal(HEAD, BGP::Link_state::Node.new(2, 0).to_shex)
  end

  # Not a test method: a helper, kept below every test and with no
  # `private` above it, because a test method after `private` never
  # runs and nothing says so.
  def node_with(protocol_id, router_id)
    BGP::Link_state::Node.new(
      protocol_id, 0,
      BGP::Link_state::Tlv::Local_node_descriptors.new(
        BGP::Link_state::Tlv::Igp_router_id.new(router_id)))
  end

end
