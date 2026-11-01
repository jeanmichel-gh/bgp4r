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
require 'bgp/nlris/link_state_descriptor'

# **RFC 9552 carries no worked example and no hex anywhere**, measured:
# the six occurrences of "0x" in the document are the OSPF route type
# values of section 5.2.3.1. So every expectation here is this reader's
# arithmetic from the Table 3 widths and the section 5.1 framing, not
# the document's own octets. The field breakdown is written out beside
# each case for that reason; the arithmetic is the thing to doubt first
# when one of these fails. Part 1 got one wrong within the hour.
class TestLinkStateDescriptor < Test::Unit::TestCase

  include BGP

  # --- the three fixed-width sub-TLVs, Table 3 ------------------------
  #
  # Each is a 4-octet value in an 8-octet TLV. Type 512 is 0x0200, 513
  # is 0x0201 and 514 is 0x0202, which is worth writing out because
  # three consecutive decimal numbers are three consecutive low octets
  # and a reader checking hex against Table 3 needs the conversion.

  def test_the_autonomous_system_sub_tlv
    t = BGP::Link_state::Tlv::Autonomous_system.new(65000)
    assert_equal(512, t.type)
    assert_equal('02000004' + '0000fde8', t.to_shex)
    assert_equal(65000, t.value)
    assert_equal('AS 65000', t.to_s)
  end

  # "Opaque value (32-bit AS Number)", so a four-octet AS is the field's
  # own width and a two-octet one sits in the low half. The field never
  # follows what the session negotiated, which is the same shape as
  # Mcast_vpn::Source_as and for the same reason: the table gives a
  # width and an NLRI carries no capability.
  def test_a_four_octet_as_fills_the_field
    assert_equal('02000004' + '00011171',
                 BGP::Link_state::Tlv::Autonomous_system.new(70001).to_shex)
    assert_equal(0xffffffff,
                 BGP::Link_state::Tlv::Autonomous_system.new(
                   0xffffffff).value)
  end

  # Section 5.2.1.4: "The default value of 0 is RECOMMENDED to be used
  # when a BGP-LS Producer includes this sub-TLV", which is what the no
  # argument form writes.
  def test_the_bgp_ls_identifier_sub_tlv_defaults_to_zero
    t = BGP::Link_state::Tlv::Bgp_ls_identifier.new
    assert_equal(513, t.type)
    assert_equal('02010004' + '00000000', t.to_shex)
    assert_equal('BGP-LS ID 0', t.to_s)
  end

  # Deprecated by RFC 9552 and implemented anyway, because section
  # 5.2.1.4 says implementations "SHOULD support the advertisement of
  # this sub-TLV for backward compatibility" with RFC 7752 producers,
  # and because reading a deprecated code point a peer still sends is
  # the job.
  def test_the_deprecated_sub_tlv_reads_a_value_a_peer_sent
    t = BGP::Link_state::Tlv.factory(['020100040000002a'].pack('H*').is_packed)
    assert_equal(BGP::Link_state::Tlv::Bgp_ls_identifier, t.class)
    assert_equal(42, t.value)
    assert_equal('020100040000002a', t.to_shex)
  end

  def test_the_ospf_area_id_sub_tlv
    t = BGP::Link_state::Tlv::Ospf_area_id.new(1)
    assert_equal(514, t.type)
    assert_equal('02020004' + '00000001', t.to_shex)
    assert_equal('0.0.0.1', t.area)
    assert_equal('Area 0.0.0.1', t.to_s)
  end

  # **The dotted quad is a convention, not the RFC's**, which says only
  # "32-bit area". It is taken because every router prints an Area-ID
  # that way and the value of a presentation form is that a line out of
  # a dump reads back, so both forms are the same four octets.
  def test_an_area_id_reads_back_from_the_form_a_router_prints
    a = BGP::Link_state::Tlv::Ospf_area_id.new('0.0.0.1')
    b = BGP::Link_state::Tlv::Ospf_area_id.new(1)
    assert_equal(b.to_shex, a.to_shex)
    assert_equal('0.0.1.0',
                 BGP::Link_state::Tlv::Ospf_area_id.new(256).area)
    assert_equal('255.255.255.255',
                 BGP::Link_state::Tlv::Ospf_area_id.new(0xffffffff).area)
  end

  # **Each of the three parses back on its own**, and that is worth a
  # case per class rather than one for the family: the width lives on
  # the shared base, so a wrong one is caught only where a class is
  # parsed from octets, and a field build encodes 4 octets either way.
  # Sabotaging `WIDTH` to 2 failed only two cases before these.
  def test_each_fixed_width_sub_tlv_parses_back
    { '020000040000fde8' => [BGP::Link_state::Tlv::Autonomous_system, 65000],
      '020100040000002a' => [BGP::Link_state::Tlv::Bgp_ls_identifier, 42],
      '0202000400000100' => [BGP::Link_state::Tlv::Ospf_area_id, 256],
    }.each do |hex, (klass, value)|
      t = BGP::Link_state::Tlv.factory([hex].pack('H*').is_packed)
      assert_equal(klass, t.class, hex)
      assert_equal(value, t.value, hex)
      assert_equal(hex, t.to_shex)
    end
  end

  # A width other than 4 cannot be one of these three, so the value
  # does not reproduce itself and Tlv.factory keeps the octets whole.
  # That is part 1's encode-matches rule, and it is what stops a
  # 2-octet 512 from reading back as AS 0.
  def test_a_fixed_width_sub_tlv_of_the_wrong_width_falls_back
    hex = '020000020102'
    t = BGP::Link_state::Tlv.factory([hex].pack('H*').is_packed)
    assert_equal(BGP::Link_state::Tlv::Unknown, t.class)
    assert_equal(hex, t.to_shex)
  end

  # --- sub-TLV 515, the variable one ----------------------------------

  # Section 5.2.1.4 describes four widths and Table 3 gives the length
  # as "Variable". The four, with what the section calls each:
  #
  #   4  OSPFv2 or OSPFv3 non-pseudonode Router-ID
  #   6  IS-IS non-pseudonode, a 6-octet ISO Node-ID
  #   7  IS-IS pseudonode, the DIS Node-ID and a 1-octet PSN identifier
  #   8  OSPF pseudonode, the DR Router-ID and an address or interface
  def test_the_four_widths_section_5_2_1_4_describes
    { 4 => [[3, 6], :non_pseudonode],
      6 => [[1, 2], :non_pseudonode],
      7 => [[1, 2], :pseudonode],
      8 => [[3, 6], :pseudonode] }.each do |width, (protocols, kind)|
      r = BGP::Link_state::Tlv::Igp_router_id.new('ff' * width)
      assert_equal(width, r.value.size)
      assert_equal(protocols, r.shape[0], "width #{width} protocols")
      assert_equal(kind, r.shape[1], "width #{width} node kind")
    end
  end

  def test_the_igp_router_id_sub_tlv
    r = BGP::Link_state::Tlv::Igp_router_id.new('0a000001')
    assert_equal(515, r.type)
    assert_equal('02030004' + '0a000001', r.to_shex)
    assert_match(/OSPF Router-ID/, r.to_s)
  end

  # **A String is hex and separators are stripped**, so the dotted form
  # a router prints an ISO System-ID in reads back as its six octets.
  # That works because the form is hex groups, not because this class
  # knows IS-IS.
  def test_the_dotted_iso_system_id_form_reads_back
    r = BGP::Link_state::Tlv::Igp_router_id.new('1921.6800.1001')
    assert_equal(6, r.value.size)
    assert_equal('192168001001', r.value.unpack1('H*'))
    assert_equal('02030006' + '192168001001', r.to_shex)
    assert_equal(r.to_shex,
                 BGP::Link_state::Tlv::Igp_router_id.new(
                   '192168001001').to_shex)
  end

  # Section 5.2.1.4: an IS-IS pseudonode is "the 6-octet ISO Node-ID of
  # the Designated Intermediate System (DIS) followed by a 1-octet,
  # nonzero PSN identifier (7 octets in total)".
  def test_a_pseudonode_router_id_reads_its_psn_identifier
    r = BGP::Link_state::Tlv::Igp_router_id.new('1921.6800.1001.02')
    assert_equal(7, r.value.size)
    assert_equal(2, r.psn)
    assert_equal(:pseudonode, r.shape[1])
  end

  # The PSN only exists at that one width, and a zero one is echoed
  # rather than refused: the section calls it nonzero and nothing here
  # validates, so a value no RFC allows still goes on the wire.
  def test_the_psn_is_nil_at_every_other_width_and_zero_is_kept
    [4, 6, 8].each do |w|
      assert_nil(BGP::Link_state::Tlv::Igp_router_id.new('ff' * w).psn,
                 "width #{w} has no PSN identifier")
    end
    r = BGP::Link_state::Tlv::Igp_router_id.new('1921.6800.1001.00')
    assert_equal(0, r.psn)
    assert_equal('02030007' + '192168001001' + '00', r.to_shex)
  end

  # Opaque is the RFC's word, so a width it does not describe is not an
  # error it names: the octets parse, replay, and answer no shape.
  def test_a_width_the_section_does_not_describe_still_replays
    [1, 2, 3, 5, 9, 20].each do |w|
      hex = format('0203%04x', w) + 'aa' * w
      t = BGP::Link_state::Tlv.factory([hex].pack('H*').is_packed)
      assert_equal(BGP::Link_state::Tlv::Igp_router_id, t.class,
                   "width #{w} is still an IGP Router-ID")
      assert_nil(t.shape, "width #{w} has no shape")
      assert_equal(hex, t.to_shex)
    end
  end

  # An Integer has no width, so it is refused rather than guessed at.
  # That is the one kind of refusal Conventions allows.
  def test_an_integer_router_id_is_refused
    assert_raise(ArgumentError) do
      BGP::Link_state::Tlv::Igp_router_id.new(1)
    end
  end

  # --- TLV 256 and TLV 257 --------------------------------------------

  # Sections 5.2.1.2 and 5.2.1.3, and figures 10 and 11 are identical:
  # the value is "one or more Node Descriptor sub-TLVs". Type 256 is
  # 0x0100 and 257 is 0x0101.
  def test_the_two_node_descriptor_tlvs_are_one_layout_and_two_numbers
    subs = [BGP::Link_state::Tlv::Autonomous_system.new(65000)]
    local = BGP::Link_state::Tlv::Local_node_descriptors.new(*subs)
    remote = BGP::Link_state::Tlv::Remote_node_descriptors.new(*subs)
    assert_equal(256, local.type)
    assert_equal(257, remote.type)
    assert_equal('01000008' + '020000040000fde8', local.to_shex)
    assert_equal('01010008' + '020000040000fde8', remote.to_shex)
    assert_equal(local.to_shex[4..], remote.to_shex[4..],
                 'the two differ in the type octets and nowhere else')
  end

  def test_a_node_descriptor_holds_several_sub_tlvs
    d = BGP::Link_state::Tlv::Local_node_descriptors.new(
      BGP::Link_state::Tlv::Autonomous_system.new(65000),
      BGP::Link_state::Tlv::Ospf_area_id.new(1),
      BGP::Link_state::Tlv::Igp_router_id.new('0a000001'))
    assert_equal(3, d.sub_tlvs.size)
    # 3 sub-TLVs of 8 octets each is 24, 0x18.
    assert_equal('01000018' + '020000040000fde8' + '0202000400000001' +
                 '020300040a000001', d.to_shex)
  end

  def test_a_node_descriptor_parses_its_sub_tlvs_back
    hex = '01000010' + '020000040000fde8' + '020300040a000001'
    d = BGP::Link_state::Tlv.factory([hex].pack('H*').is_packed)
    assert_equal(BGP::Link_state::Tlv::Local_node_descriptors, d.class)
    assert_equal([BGP::Link_state::Tlv::Autonomous_system,
                  BGP::Link_state::Tlv::Igp_router_id],
                 d.sub_tlvs.collect { |t| t.class })
    assert_equal(hex, d.to_shex)
  end

  # "One or more" is the section's wording and nothing enforces it:
  # building never validates, so an empty Node Descriptor is four
  # octets of framing and a length of zero.
  def test_an_empty_node_descriptor_builds
    d = BGP::Link_state::Tlv::Local_node_descriptors.new
    assert_equal('01000000', d.to_shex)
    assert_equal([], d.sub_tlvs)
    assert_equal('Local node: (none)', d.to_s)
  end

  # Octets that cannot frame a sub-TLV are kept and written back, which
  # is the tail rule the rest of the library already follows. Three is
  # the widest such remainder, since four octets frame a TLV header.
  def test_a_remainder_too_short_to_frame_a_sub_tlv_is_kept
    hex = '0100000b' + '020000040000fde8' + 'ffffff'
    d = BGP::Link_state::Tlv.factory([hex].pack('H*').is_packed)
    assert_equal(1, d.sub_tlvs.size)
    assert_equal('ffffff', d.tail.unpack1('H*'))
    assert_equal(hex, d.to_shex)
    assert_match(/tail \[ffffff\]/, d.to_s)
  end

  def test_no_tail_means_no_tail_key_in_the_hash
    d = BGP::Link_state::Tlv::Local_node_descriptors.new(
      BGP::Link_state::Tlv::Autonomous_system.new(1))
    assert_equal({ :local_node_descriptors => [{ :autonomous_system => 1 }] },
                 d.to_hash)
  end

  def test_a_sub_tlv_with_no_class_is_kept_inside_a_node_descriptor
    hex = '01000008' + '00ff0004deadbeef'
    d = BGP::Link_state::Tlv.factory([hex].pack('H*').is_packed)
    assert_equal([BGP::Link_state::Tlv::Unknown],
                 d.sub_tlvs.collect { |t| t.class })
    assert_equal(hex, d.to_shex)
  end

  # --- section 5.2.1.4's two rules ------------------------------------

  # "At most, there MUST be one instance of each sub-TLV type present
  # in any Node Descriptor." Reported rather than refused, because
  # building never validates; part 6 is where a receive side check
  # reads this.
  def test_a_repeated_sub_tlv_type_is_reported_and_still_encodes
    a = BGP::Link_state::Tlv::Autonomous_system.new(1)
    b = BGP::Link_state::Tlv::Autonomous_system.new(2)
    d = BGP::Link_state::Tlv::Local_node_descriptors.new(a, b)
    assert_equal([512], d.duplicate_types)
    assert_equal('01000010' + '0200000400000001' + '0200000400000002',
                 d.to_shex)
  end

  def test_one_of_each_type_reports_no_duplicate
    d = BGP::Link_state::Tlv::Local_node_descriptors.new(
      BGP::Link_state::Tlv::Autonomous_system.new(1),
      BGP::Link_state::Tlv::Bgp_ls_identifier.new(0))
    assert_equal([], d.duplicate_types)
  end

  # "The sub-TLVs within a Node Descriptor MUST be arranged in
  # ascending order by sub-TLV type."
  #
  # **That is section 5.1's rule with its tiebreakers made
  # unnecessary**, because the once-only rule above means two sub-TLVs
  # never share a type. So this asks Tlv.ordered?, which part 1 wrote
  # for section 5.1, rather than keeping a second comparison.
  def test_the_sub_tlv_ordering_rule
    a = BGP::Link_state::Tlv::Autonomous_system.new(1)
    b = BGP::Link_state::Tlv::Igp_router_id.new('0a000001')
    assert(BGP::Link_state::Tlv::Local_node_descriptors.new(a, b).ordered?)
    assert_equal(false,
                 BGP::Link_state::Tlv::Local_node_descriptors.new(
                   b, a).ordered?)
  end

  def test_an_out_of_order_node_descriptor_still_encodes
    d = BGP::Link_state::Tlv::Local_node_descriptors.new(
      BGP::Link_state::Tlv::Igp_router_id.new('0a000001'),
      BGP::Link_state::Tlv::Autonomous_system.new(1))
    assert_equal(false, d.ordered?)
    assert_equal('01000010' + '020300040a000001' + '0200000400000001',
                 d.to_shex)
  end

  def test_an_empty_or_single_node_descriptor_is_ordered
    assert(BGP::Link_state::Tlv::Local_node_descriptors.new.ordered?)
    assert(BGP::Link_state::Tlv::Local_node_descriptors.new(
      BGP::Link_state::Tlv::Autonomous_system.new(1)).ordered?)
  end

  # --- the registry ---------------------------------------------------

  # One flat registry covers TLVs and sub-TLVs alike, which is IANA's
  # doing: the registry is "BGP-LS NLRI and Attribute TLVs", one space
  # for both, and Table 18 lists 256 and 257 beside 512 to 515 with no
  # column saying which is which. So a sub-TLV number means the same
  # thing under every parent, unlike the EVPN extended community
  # sub-types.
  def test_every_class_here_is_in_the_one_registry
    { 256 => BGP::Link_state::Tlv::Local_node_descriptors,
      257 => BGP::Link_state::Tlv::Remote_node_descriptors,
      512 => BGP::Link_state::Tlv::Autonomous_system,
      513 => BGP::Link_state::Tlv::Bgp_ls_identifier,
      514 => BGP::Link_state::Tlv::Ospf_area_id,
      515 => BGP::Link_state::Tlv::Igp_router_id }.each do |t, k|
      assert_equal(k, BGP::Link_state::Tlv::REGISTRY[t],
                   "type #{t} must be registered as #{k}")
      assert_equal(k, BGP::Link_state::Tlv::BY_KEY[k.hash_key],
                   "#{k} must be reachable by its hash key")
    end
  end

  # --- to_hash ---------------------------------------------------------

  # The two-places rule in Conventions: a working round trip is
  # asserted here and in test/unit/to_hash_catalog.rb. Every field each
  # class carries is exercised, the declared length and the tail
  # included, since an assertion that misses a field passes for the
  # wrong reason.
  def test_every_class_here_rebuilds_from_its_own_hash
    [BGP::Link_state::Tlv::Autonomous_system.new(70001),
     BGP::Link_state::Tlv::Bgp_ls_identifier.new(42),
     BGP::Link_state::Tlv::Ospf_area_id.new('0.0.1.0'),
     BGP::Link_state::Tlv::Igp_router_id.new('1921.6800.1001.02'),
     BGP::Link_state::Tlv::Local_node_descriptors.new(
       BGP::Link_state::Tlv::Autonomous_system.new(1),
       BGP::Link_state::Tlv::Igp_router_id.new('0a000001')),
     BGP::Link_state::Tlv::Remote_node_descriptors.new(
       BGP::Link_state::Tlv::Ospf_area_id.new(2))].each do |t|
      assert_equal(t.to_shex, t.class.new(t.to_hash).to_shex,
                   "#{t.class} must rebuild from its own hash")
      assert_equal(t.to_shex,
                   BGP::Link_state::Tlv.from_hash(t.to_hash).to_shex,
                   "#{t.class} must rebuild through the registry too")
    end
  end

  # A Length that lied and a tail both ride in the hash, so a capture
  # rebuilt from one replays as it arrived.
  def test_a_declared_length_and_a_tail_survive_the_hash
    hex = '0100270f' + '020000040000fde8' + 'ff'
    d = BGP::Link_state::Tlv.factory([hex].pack('H*').is_packed)
    assert_equal(9999, d.declared_len)
    assert_equal('ff', d.tail.unpack1('H*'))
    h = d.to_hash
    assert_equal(9999, h[:length])
    assert_equal('ff', h[:tail])
    assert_equal(hex,
                 BGP::Link_state::Tlv::Local_node_descriptors.new(h).to_shex)
  end

  def test_a_sub_tlv_can_be_appended
    d = BGP::Link_state::Tlv::Local_node_descriptors.new
    d << BGP::Link_state::Tlv::Autonomous_system.new(65000)
    d << { :igp_router_id => '0a000001' }
    assert_equal(2, d.sub_tlvs.size)
    assert_equal('01000010' + '020000040000fde8' + '020300040a000001',
                 d.to_shex)
  end

  def test_a_bare_field_hash_builds_a_node_descriptor_too
    d = BGP::Link_state::Tlv::Local_node_descriptors.new(
      :autonomous_system => 65000)
    assert_equal('01000008' + '020000040000fde8', d.to_shex)
  end

  # --- nothing validates ----------------------------------------------

  # Six things no RFC allows, each building and encoding, because that
  # is the reason this library exists.
  def test_nothing_validates
    # A 512 whose value is not an AS at all, since the field is opaque
    # and 0 is not an AS anyone may originate with.
    assert_equal('0200000400000000',
                 BGP::Link_state::Tlv::Autonomous_system.new(0).to_shex)
    # A deprecated sub-TLV sent with a value the RFC does not recommend.
    assert_equal('02010004ffffffff',
                 BGP::Link_state::Tlv::Bgp_ls_identifier.new(
                   0xffffffff).to_shex)
    # An IGP Router-ID of a width no node kind has.
    assert_equal('02030003010203',
                 BGP::Link_state::Tlv::Igp_router_id.new('010203').to_shex)
    # An IS-IS pseudonode with the zero PSN identifier section 5.2.1.4
    # calls nonzero.
    assert_equal(0, BGP::Link_state::Tlv::Igp_router_id.new(
      '00000000000000').psn)
    # A Node Descriptor with none of the sub-TLVs section 5.2.1.2 calls
    # "one or more".
    assert_equal('01010000',
                 BGP::Link_state::Tlv::Remote_node_descriptors.new.to_shex)
    # Two of one type, out of order, which breaks both rules of section
    # 5.2.1.4 at once.
    d = BGP::Link_state::Tlv::Local_node_descriptors.new(
      BGP::Link_state::Tlv::Igp_router_id.new('0a000001'),
      BGP::Link_state::Tlv::Autonomous_system.new(2),
      BGP::Link_state::Tlv::Autonomous_system.new(1))
    assert_equal(false, d.ordered?)
    assert_equal([512], d.duplicate_types)
    assert_equal(28, d.size)
  end

  # --- the four build paths -------------------------------------------

  def test_every_class_here_builds_from_another_instance
    [BGP::Link_state::Tlv::Autonomous_system.new(65000),
     BGP::Link_state::Tlv::Ospf_area_id.new(1),
     BGP::Link_state::Tlv::Igp_router_id.new('0a000001'),
     BGP::Link_state::Tlv::Local_node_descriptors.new(
       BGP::Link_state::Tlv::Autonomous_system.new(1))].each do |t|
      assert_equal(t.to_shex, t.class.new(t).to_shex,
                   "#{t.class} must copy")
    end
  end

  # Copying must not empty the instance it copied, which is the trap
  # Conventions records for every class whose parse reads with slice!.
  def test_copying_leaves_the_original_whole
    r = BGP::Link_state::Tlv::Igp_router_id.new('0a000001')
    BGP::Link_state::Tlv::Igp_router_id.new(r)
    assert_equal('0a000001', r.value.unpack1('H*'))
    d = BGP::Link_state::Tlv::Local_node_descriptors.new(r)
    BGP::Link_state::Tlv::Local_node_descriptors.new(d)
    assert_equal(1, d.sub_tlvs.size)
    assert_equal('0a000001', r.value.unpack1('H*'))
  end

  def test_a_class_here_refuses_an_argument_it_cannot_read
    assert_raise(ArgumentError) do
      BGP::Link_state::Tlv::Autonomous_system.new(1, 2)
    end
    assert_raise(ArgumentError) do
      BGP::Link_state::Tlv::Igp_router_id.new(1, 2)
    end
  end

end
