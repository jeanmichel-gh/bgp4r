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

  # The three the registry assigns that Table 2 does not, each named by
  # the document that assigned it. **This is what the lab found**: GoBGP
  # 3.23.0 originates with Protocol-ID 7, and bgp4r printed Unassigned
  # for it until the registry was read rather than Table 2.
  def test_the_three_protocol_ids_outside_table_2
    { 7 => 'BGP', 8 => 'RSVP-TE', 9 => 'Segment Routing' }.each do |id, name|
      assert_equal(name, BGP::Link_state::Node.new(id, 0).protocol,
                   "Protocol-ID #{id}, which Table 2 does not list")
    end
  end

  # The ranges around them, from the IANA registry: 0 Reserved, 10 to
  # 199 Unassigned, 200 to 255 Private Use.
  #
  # Unassigned is the one verdict here that can expire, since IANA
  # assigns from the bottom of that range, so this asserts both ends of
  # it rather than one value in the middle: 10 is what the next
  # assignment takes and 199 is what it takes last.
  def test_the_ranges_around_the_protocol_ids
    assert_equal('Reserved', BGP::Link_state::Node.new(0, 0).protocol)
    assert_equal('Unassigned', BGP::Link_state::Node.new(10, 0).protocol)
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

  # **The hash build path has to reach the same width as the field value
  # path, and it did not.** `Igp_router_id#from_hash` used
  # `pack('H*')`, which maps a separator by its low nibble rather than
  # skipping it, so `'1921.6800.1001.02'` through a hash built nine
  # octets and `node_type` answered nil because no shape has that width.
  # The field value path stripped separators and built the right seven.
  # Found in #219 by test/functional/link_state_test.rb; the two paths
  # share one method now and link_state_descriptor_test.rb pins that at
  # its own level. This is the same bug seen from the top, which is
  # where it was visible at all.
  def test_the_node_type_rule_sees_a_dotted_router_id_from_a_hash
    n = BGP::Link_state::Node.new(
      :node => { :protocol_id => 1, :identifier => 0,
                 :tlvs => [{ :local_node_descriptors =>
                             [{ :igp_router_id => '1921.6800.1001.02' }] }] })
    r = n.local_node_descriptors.sub_tlvs.first
    assert_equal(7, r.value.size)
    assert_equal(:pseudonode, n.node_type)
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

  # --- section 5.2, figure 8, the Link NLRI ---------------------------

  # A Remote Node Descriptors TLV holding one AS sub-TLV, and the three
  # link descriptors the cases below use. Type 257 is 0x0101, 258 is
  # 0x0102, 259 is 0x0103 and 260 is 0x0104.
  REMOTE = '01010008' + '020000040000fde9'
  IDS    = '01020008' + '0000000100000002'
  V4     = '01030004' + '0a000001'
  N4     = '01040004' + '0a000002'

  def test_the_link_nlri_is_the_head_two_descriptor_sets_and_the_link
    l = link
    assert_equal(2, l.type)
    assert_equal(HEAD + LOCAL + REMOTE + IDS + V4 + N4, l.to_shex)
    # 1 + 8 + 12 + 12 + 12 + 8 + 8 octets of value.
    assert_equal(61, l.encode.size)
  end

  def test_the_whole_link_nlri_through_the_framing
    ls = BGP::Link_state.new(link)
    # NLRI type 2, Total NLRI Length 61 (0x3d), then the value.
    assert_equal('0002' + '003d' + HEAD + LOCAL + REMOTE + IDS + V4 + N4,
                 ls.to_shex)
    assert_equal(61, ls.length)
  end

  def test_a_link_nlri_parses_back_through_the_framing
    hex = '0002' + '003d' + HEAD + LOCAL + REMOTE + IDS + V4 + N4
    ls = BGP::Link_state.new_ntop([hex].pack('H*'))
    assert_equal(BGP::Link_state::Link, ls.nlri.class)
    assert_equal(5, ls.nlri.tlvs.size)
    assert_equal(65001, ls.nlri.remote_node_descriptors.sub_tlvs.first.value)
    assert_equal(hex, ls.to_shex)
  end

  # The one reader this class adds over the base, and nil is an answer:
  # section 5.2.1.3 calls the Remote Node Descriptors TLV a Link NLRI's
  # field, and an NLRI can still arrive without one.
  def test_the_remote_node_descriptors_reader
    assert_equal(65001, link.remote_node_descriptors.sub_tlvs.first.value)
    assert_nil(BGP::Link_state::Link.new(2, 0).remote_node_descriptors)
  end

  # **A Link NLRI is half a link**, which section 5.2.2 says outright:
  # "To fully describe a single logical link, two anchor routers
  # advertise a half-link each, i.e., two Link NLRIs are advertised for
  # a given point-to-point link." So nothing here pairs two of them, and
  # the two halves of one link are two independent NLRIs that differ in
  # which end is local.
  def test_the_two_halves_of_one_link_are_two_independent_nlris
    a = BGP::Link_state::Link.new(
      2, 0, BGP::Link_state::Tlv::Local_node_descriptors.new(
        BGP::Link_state::Tlv::Autonomous_system.new(65000)),
      BGP::Link_state::Tlv::Remote_node_descriptors.new(
        BGP::Link_state::Tlv::Autonomous_system.new(65001)))
    b = BGP::Link_state::Link.new(
      2, 0, BGP::Link_state::Tlv::Local_node_descriptors.new(
        BGP::Link_state::Tlv::Autonomous_system.new(65001)),
      BGP::Link_state::Tlv::Remote_node_descriptors.new(
        BGP::Link_state::Tlv::Autonomous_system.new(65000)))
    assert_not_equal(a.to_shex, b.to_shex)
    assert_equal(HEAD + LOCAL + REMOTE, a.to_shex)
    assert_equal(HEAD + '01000008' + '020000040000fde9' +
                 '01010008' + '020000040000fde8', b.to_shex)
  end

  # Section 5.2.2 says of four of the link descriptors "This sub-TLV can
  # occur multiple times", so a Link NLRI holding two of a type is
  # ordinary traffic and not a negative test. That is also what section
  # 5.1's Length and Value tiebreakers are for, read from the other end.
  def test_a_repeated_link_descriptor_is_ordinary
    l = BGP::Link_state::Link.new(
      2, 0,
      BGP::Link_state::Tlv::Ipv4_interface_address.new('10.0.0.1'),
      BGP::Link_state::Tlv::Ipv4_interface_address.new('10.0.0.3'))
    assert_equal(HEAD + V4 + '010300040a000003', l.to_shex)
    assert(BGP::Link_state::Tlv.ordered?(l.tlvs),
           'two of a type in ascending Value order is still ordered')
  end

  def test_the_link_nlri_is_registered_both_ways
    assert_equal(BGP::Link_state::Link, BGP::Link_state::TYPES[2])
    assert_equal(BGP::Link_state::Link, BGP::Link_state::BY_KEY[:link])
  end

  def test_the_link_nlri_rebuilds_from_its_own_hash
    l = BGP::Link_state::Link.new(
      [(HEAD + LOCAL + REMOTE + IDS + V4 + N4 +
        'ffffff')].pack('H*').is_packed)
    h = l.to_hash
    assert_equal('ffffff', h[:link][:tail])
    assert_equal(l.to_shex, BGP::Link_state::Link.new(h).to_shex)
    ls = BGP::Link_state.new(l)
    assert_equal(ls.to_shex, BGP::Link_state.new(ls.to_hash).to_shex)
  end

  # --- section 5.2, figure 9, the two Prefix NLRIs --------------------

  # An IP Reachability Information TLV for 24 bits over 3 octets: type
  # 265 is 0x0109, length 4, then the Prefix Length and the octets.
  REACH = '01090004' + '18' + 'c00002'

  # **One layout and two type numbers**, which is what the figure says:
  # "The IPv4 and IPv6 Prefix NLRIs (NLRI Type = 3 and Type = 4) use the
  # same format". So the same content encodes to the same octets under
  # both, and only the framing's NLRI Type field differs.
  def test_the_two_prefix_nlris_are_one_layout
    a = prefix_nlri(BGP::Link_state::Ipv4_prefix)
    b = prefix_nlri(BGP::Link_state::Ipv6_prefix)
    assert_equal(a.to_shex, b.to_shex)
    assert_equal(HEAD + LOCAL + REACH, a.to_shex)
    assert_equal(3, a.type)
    assert_equal(4, b.type)
    assert_equal('0003' + '001d' + HEAD + LOCAL + REACH,
                 BGP::Link_state.new(a).to_shex)
    assert_equal('0004' + '001d' + HEAD + LOCAL + REACH,
                 BGP::Link_state.new(b).to_shex)
  end

  # **The family is the NLRI type's and nothing below this class has
  # it**, so the same octets are two prefixes. That is the second
  # cross-level read in this family, after section 5.2.1.4's node type
  # rule, and it is why `Ip_reachability#prefix` takes an AFI.
  def test_the_same_octets_are_two_prefixes_under_the_two_types
    assert_equal('192.0.2.0/24',
                 prefix_nlri(BGP::Link_state::Ipv4_prefix).prefix)
    assert_equal('c000:200::/24',
                 prefix_nlri(BGP::Link_state::Ipv6_prefix).prefix)
    assert_equal(IANA::AFI::IPv4, BGP::Link_state::Ipv4_prefix.afi)
    assert_equal(IANA::AFI::IPv6, BGP::Link_state::Ipv6_prefix.afi)
  end

  # The TLV prints octets and a bit count because it has no family;
  # this is the only level that can print the prefix those octets make.
  def test_the_prefix_appears_in_to_s_only_at_this_level
    a = prefix_nlri(BGP::Link_state::Ipv4_prefix)
    assert_match(/prefix c00002\/24 as 192\.0\.2\.0\/24/, a.to_s)
    assert_equal('prefix c00002/24', a.ip_reachability.to_s)
  end

  def test_the_prefix_is_nil_where_the_octets_cannot_make_one
    # No IP Reachability Information TLV at all, which section 5.2.3.2
    # calls mandatory and which builds anyway.
    bare = BGP::Link_state::Ipv4_prefix.new(2, 0)
    assert_nil(bare.ip_reachability)
    assert_nil(bare.prefix)
    assert_equal(HEAD, bare.to_shex)
    # 64 bits, which is not an IPv4 prefix and is an IPv6 one.
    r = BGP::Link_state::Tlv::Ip_reachability.new(64, ['00' * 8].pack('H*'))
    assert_nil(BGP::Link_state::Ipv4_prefix.new(2, 0, r).prefix)
    assert_equal('::/64', BGP::Link_state::Ipv6_prefix.new(2, 0, r).prefix)
  end

  def test_a_prefix_nlri_parses_back_through_the_framing
    [[3, BGP::Link_state::Ipv4_prefix, '192.0.2.0/24'],
     [4, BGP::Link_state::Ipv6_prefix, 'c000:200::/24']].each do |t, k, p|
      hex = format('%04x', t) + '001d' + HEAD + LOCAL + REACH
      ls = BGP::Link_state.new_ntop([hex].pack('H*'))
      assert_equal(k, ls.nlri.class)
      assert_equal(p, ls.nlri.prefix)
      assert_equal(hex, ls.to_shex)
    end
  end

  # The descriptor set is a TLV list like any other, so the OSPF Route
  # Type of section 5.2.3.1 rides in it beside the reachability TLV.
  def test_a_prefix_nlri_carries_the_other_descriptor_too
    p = BGP::Link_state::Ipv4_prefix.new(
      2, 0, BGP::Link_state::Tlv::Local_node_descriptors.new(
        BGP::Link_state::Tlv::Autonomous_system.new(65000)),
      BGP::Link_state::Tlv::Ospf_route_type.new('Intra-Area'),
      BGP::Link_state::Tlv::Ip_reachability.new(24, ['c00002'].pack('H*')))
    assert_equal(HEAD + LOCAL + '01080001' + '01' + REACH, p.to_shex)
    assert_equal('Intra-Area',
                 p.tlv(BGP::Link_state::Tlv::Ospf_route_type.type).name)
  end

  def test_both_prefix_nlris_are_registered_both_ways
    assert_equal(BGP::Link_state::Ipv4_prefix, BGP::Link_state::TYPES[3])
    assert_equal(BGP::Link_state::Ipv6_prefix, BGP::Link_state::TYPES[4])
    assert_equal(BGP::Link_state::Ipv4_prefix,
                 BGP::Link_state::BY_KEY[:ipv4_prefix])
    assert_equal(BGP::Link_state::Ipv6_prefix,
                 BGP::Link_state::BY_KEY[:ipv6_prefix])
  end

  # **The base the two share is not itself an NLRI type**, and the
  # registry is what keeps it from reading as one: it has no TYPE, it is
  # registered nowhere, and no type number answers it. MCAST-VPN part 3
  # chose modules over base classes because its doc test discovers from
  # subclasses; here discovery is from the registry, so a base class
  # costs nothing and this is what says so.
  def test_the_shared_base_is_not_a_type
    assert_equal(false,
                 BGP::Link_state::TYPES.values.include?(
                   BGP::Link_state::Prefix_nlri))
    assert_equal(false,
                 BGP::Link_state::BY_KEY.values.include?(
                   BGP::Link_state::Prefix_nlri))
    assert_equal(false,
                 BGP::Link_state::Prefix_nlri.const_defined?(:TYPE, false))
  end

  def test_both_prefix_nlris_rebuild_from_their_own_hash
    [[BGP::Link_state::Ipv4_prefix, :ipv4_prefix],
     [BGP::Link_state::Ipv6_prefix, :ipv6_prefix]].each do |k, key|
      p = k.new([(HEAD + LOCAL + REACH + 'ffffff')].pack('H*').is_packed)
      h = p.to_hash
      assert_equal('ffffff', h[key][:tail])
      assert_equal(p.to_shex, k.new(h).to_shex)
      ls = BGP::Link_state.new(p)
      assert_equal(ls.to_shex, BGP::Link_state.new(ls.to_hash).to_shex)
    end
  end

  # --- nothing validates, at these two types --------------------------

  # Four more things no RFC allows, each building and encoding.
  def test_nothing_validates_about_the_link_and_prefix_types
    # A Link NLRI with no Remote Node Descriptors TLV, which figure 8
    # shows and section 5.2.1.3 describes.
    assert_equal(HEAD + LOCAL,
                 BGP::Link_state::Link.new(
                   2, 0, BGP::Link_state::Tlv::Local_node_descriptors.new(
                     BGP::Link_state::Tlv::Autonomous_system.new(
                       65000))).to_shex)
    # An IPv6 prefix in an IPv4 Prefix NLRI. **It does not read back as
    # nothing, it reads back as a different prefix**, and that is the
    # cross-level point put as sharply as it goes: 2001:db8::/32 packs
    # down to the same four octets as 32.1.13.184/32, so the TLV cannot
    # tell them apart and the NLRI type is the only thing that decides.
    # A mis-typed NLRI is therefore wrong without being malformed, which
    # is why nothing here refuses it and why `prefix` is at this level.
    # The hand written expectation here was the other way round first,
    # and the library was right.
    r6 = BGP::Link_state::Tlv::Ip_reachability.new('2001:db8::/32')
    p = BGP::Link_state::Ipv4_prefix.new(2, 0, r6)
    assert_equal(HEAD + '01090005' + '20' + '20010db8', p.to_shex)
    assert_equal('32.1.13.184/32', p.prefix)
    assert_equal('2001:db8::/32',
                 BGP::Link_state::Ipv6_prefix.new(2, 0, r6).prefix)
    # A Link NLRI carrying a prefix descriptor and a Prefix NLRI
    # carrying a link descriptor, which section 8.2.2 names as a
    # semantic check a BGP-LS Propagator should not make.
    assert_equal(HEAD + REACH,
                 BGP::Link_state::Link.new(
                   2, 0, BGP::Link_state::Tlv::Ip_reachability.new(
                     24, ['c00002'].pack('H*'))).to_shex)
    assert_equal(HEAD + V4,
                 BGP::Link_state::Ipv4_prefix.new(
                   2, 0, BGP::Link_state::Tlv::Ipv4_interface_address.new(
                     '10.0.0.1')).to_shex)
  end

  # Not a test method: helpers, kept below every test and with no
  # `private` above them, because a test method after `private` never
  # runs and nothing says so.
  def link
    BGP::Link_state::Link.new(
      2, 0,
      BGP::Link_state::Tlv::Local_node_descriptors.new(
        BGP::Link_state::Tlv::Autonomous_system.new(65000)),
      BGP::Link_state::Tlv::Remote_node_descriptors.new(
        BGP::Link_state::Tlv::Autonomous_system.new(65001)),
      BGP::Link_state::Tlv::Link_local_remote_identifiers.new(1, 2),
      BGP::Link_state::Tlv::Ipv4_interface_address.new('10.0.0.1'),
      BGP::Link_state::Tlv::Ipv4_neighbor_address.new('10.0.0.2'))
  end

  def prefix_nlri(klass)
    klass.new(
      2, 0, BGP::Link_state::Tlv::Local_node_descriptors.new(
        BGP::Link_state::Tlv::Autonomous_system.new(65000)),
      BGP::Link_state::Tlv::Ip_reachability.new(24, ['c00002'].pack('H*')))
  end

  def node_with(protocol_id, router_id)
    BGP::Link_state::Node.new(
      protocol_id, 0,
      BGP::Link_state::Tlv::Local_node_descriptors.new(
        BGP::Link_state::Tlv::Igp_router_id.new(router_id)))
  end

end
