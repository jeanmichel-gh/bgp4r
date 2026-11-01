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
require 'bgp/nlris/link_state_link_attribute'
# Three cases compare a Table 8 class against its Table 6 counterpart,
# since `Text_tlv` and `Opaque_tlv` each serve one of each and the local
# Router-IDs are Table 6's rows as well. **The source requires nothing
# but `link_state`**, because part 5b-i put the shared bases with the
# framing, so the comparison needs that file here rather than there.
# Third time in this family that a cross-table claim has needed its
# other table's file in the test and not in the source.
require 'bgp/nlris/link_state_node_attribute'

# **RFC 9552 carries no worked example and no hex anywhere**, measured in
# part 1, and neither does RFC 5305 or RFC 5307 for these sub-TLVs. So
# every expectation here is this reader's arithmetic from the widths in
# the document that gives each one, and the field breakdown is written
# out beside each case for that reason. Sixteen hand-written
# expectations have been wrong across these families with the library
# right every time, so the arithmetic is what to doubt first.
#
# The type numbers, converted once: 1030 is 0x0406, 1031 is 0x0407, then
# 1088 to 1098 are 0x0440 to 0x044a.
class TestLinkStateLinkAttribute < Test::Unit::TestCase

  include BGP

  # --- TLV 1030 and 1031, the remote Router-IDs, section 5.3.2.1 ------

  # Table 8 cites RFC 5305 section 4.3 and RFC 6119 section 4.1, the
  # same two citations Table 6 gives for the local pair, so 4 and 16.
  def test_the_remote_router_id_tlvs
    t = BGP::Link_state::Tlv::Ipv4_remote_router_id.new('10.0.0.2')
    assert_equal(1030, t.type)
    assert_equal('04060004' + '0a000002', t.to_shex)
    assert_equal('Remote IPv4 Router-ID 10.0.0.2', t.to_s)

    t6 = BGP::Link_state::Tlv::Ipv6_remote_router_id.new('2001:db8::2')
    assert_equal(1031, t6.type)
    assert_equal('04070010' + '20010db8000000000000000000000002', t6.to_shex)
    assert_equal(8, t.size)
    assert_equal(20, t6.size)
  end

  # The local and the remote pair are four distinct code points and four
  # classes, which is worth asserting because section 5.3.2.1 describes
  # all four in one paragraph and a reader could take them for two.
  def test_the_local_and_remote_router_ids_are_four_classes
    assert_equal([1028, 1029, 1030, 1031],
                 [BGP::Link_state::Tlv::Ipv4_local_router_id,
                  BGP::Link_state::Tlv::Ipv6_local_router_id,
                  BGP::Link_state::Tlv::Ipv4_remote_router_id,
                  BGP::Link_state::Tlv::Ipv6_remote_router_id,
                 ].collect { |k| k.type })
  end

  # --- TLV 1088, Administrative group, RFC 5305 section 3.1 ----------

  # **Group N is bit N counting from the bottom**, which that section
  # says outright: "the least significant bit is referred to as 'group
  # 0', and the most significant bit is referred to as 'group 31'". So
  # this is the one bitfield in the family numbered the other way up,
  # and asserting the mask for each end is what catches a reversal,
  # where a round trip would not.
  def test_the_administrative_group_numbers_bits_from_the_bottom
    assert_equal('04400004' + '00000001',
                 BGP::Link_state::Tlv::Administrative_group.new(1).to_shex)
    assert_equal([0], BGP::Link_state::Tlv::Administrative_group.new(1).groups)
    assert_equal([31], BGP::Link_state::Tlv::Administrative_group
                         .new(0x80000000).groups)
    assert_equal((0..31).to_a, BGP::Link_state::Tlv::Administrative_group
                                 .new(0xffffffff).groups)
  end

  def test_the_administrative_group_tlv
    t = BGP::Link_state::Tlv::Administrative_group.new(0x80000005)
    assert_equal(1088, t.type)
    assert_equal('04400004' + '80000005', t.to_shex)
    assert_equal([0, 2, 31], t.groups)
    assert(t.group?(2))
    assert(!t.group?(1))
    assert_equal('Admin group 0,2,31', t.to_s)
    assert_equal({ :administrative_group => 0x80000005 }, t.to_hash)
    assert_equal(t.to_shex, BGP::Link_state::Tlv::Administrative_group
                              .new(t.to_hash).to_shex)
  end

  def test_no_administrative_group_set
    t = BGP::Link_state::Tlv::Administrative_group.new
    assert_equal('04400004' + '00000000', t.to_shex)
    assert_equal([], t.groups)
    assert_equal('Admin group none', t.to_s)
  end

  # Every one of the 32 bits is an administrative group, so unlike its
  # neighbours this class has nothing reserved and no `:bits` entry.
  def test_the_administrative_group_reserves_nothing
    assert(!BGP::Link_state::Tlv::Administrative_group
             .const_defined?(:DEFINED_BITS, false))
    assert_equal({ :administrative_group => 0xffffffff },
                 BGP::Link_state::Tlv::Administrative_group
                   .new(0xffffffff).to_hash)
  end

  # --- TLV 1089, 1090 and 1091, the bandwidths ------------------------

  # **The units are bytes per second and not bits**, which RFC 5305
  # sections 3.4, 3.5 and 3.6 each put as "The units are bytes (not
  # bits!) per second". The same trap as RFC 10005 for the Link
  # Bandwidth extended community.
  #
  # 1,250,000 bytes per second is 10 Mbit/s. The hex is the library's
  # own, computed rather than typed, which is the rule these families
  # earned sixteen times over: `[1_250_000.0].pack('g')`.
  def test_the_maximum_link_bandwidth_tlv
    t = BGP::Link_state::Tlv::Maximum_link_bandwidth.new(1_250_000.0)
    assert_equal(1089, t.type)
    assert_equal('04410004' + '49989680', t.to_shex)
    assert_equal(1_250_000.0, t.value)
    assert_equal('Max bandwidth 1250000.0 Bps', t.to_s)
    assert_equal({ :maximum_link_bandwidth => 1_250_000.0 }, t.to_hash)
    assert_equal(t.to_shex, BGP::Link_state::Tlv::Maximum_link_bandwidth
                              .new(t.to_hash).to_shex)
  end

  def test_the_max_reservable_link_bandwidth_tlv
    t = BGP::Link_state::Tlv::Max_reservable_link_bandwidth.new(1_000_000.0)
    assert_equal(1090, t.type)
    assert_equal('04420004' + '49742400', t.to_shex)
    assert_equal(8, t.size)
  end

  # An Integer is taken as a bandwidth too, since a caller is as likely
  # to have one, and it reaches the same octets as the Float.
  def test_a_bandwidth_from_an_integer
    assert_equal(BGP::Link_state::Tlv::Maximum_link_bandwidth
                   .new(1_250_000.0).to_shex,
                 BGP::Link_state::Tlv::Maximum_link_bandwidth
                   .new(1_250_000).to_shex)
  end

  # **The one width in Table 8 that memory gets wrong**: 32 octets, not
  # 4. RFC 5305 section 3.6: "this sub-TLV contains eight 32-bit IEEE
  # floating point numbers", and the order is the section's too,
  # "priority 0 occurring at the start of the sub-TLV, and priority 7 at
  # the end".
  # The value is built from `PRIORITIES` rather than from a literal 8, so
  # the constant is read by something: an earlier draft had it read by
  # nothing at all and a sabotage setting it to 1 passed the whole suite.
  def test_the_unreserved_bandwidth_tlv_is_eight_floats
    n = BGP::Link_state::Tlv::Unreserved_bandwidth::PRIORITIES
    v = (0...n).collect { |i| (i + 1) * 1000.0 }
    t = BGP::Link_state::Tlv::Unreserved_bandwidth.new(*v)
    assert_equal(1091, t.type)
    assert_equal(32, t.encode_value.size)
    assert_equal(36, t.size)
    assert_equal(v, t.values)
    assert(t.full?, 'eight priorities is a full value')
    assert_equal(1000.0, t.at(0), 'priority 0 is first')
    assert_equal(8000.0, t.at(7), 'and priority 7 is last')
    assert_equal({ :unreserved_bandwidth => v }, t.to_hash)
    assert_equal(t.to_shex, BGP::Link_state::Tlv::Unreserved_bandwidth
                              .new(t.to_hash).to_shex)
  end

  def test_the_unreserved_bandwidth_from_a_list
    v = [1.0, 2.0]
    assert_equal(BGP::Link_state::Tlv::Unreserved_bandwidth.new(*v).to_shex,
                 BGP::Link_state::Tlv::Unreserved_bandwidth.new(v).to_shex)
  end

  # **A value of other than eight priorities is kept as this class and
  # replayed**, which is section 8.2.2 from the other side: it names
  # "whether the length of a fixed-length TLV is correct" among the
  # semantic validations a BGP-LS Propagator should not perform.
  def test_seven_priorities_are_kept_rather_than_refused
    hex = '0443001c' + '447a0000' * 7
    t = BGP::Link_state::Tlv.factory([hex].pack('H*'))
    assert_instance_of(BGP::Link_state::Tlv::Unreserved_bandwidth, t)
    assert_equal(7, t.values.size)
    assert(!t.full?, 'seven is not full, and that is not an error')
    assert_nil(t.at(7))
    assert_equal(hex, t.to_shex)
  end

  # **A NaN with a payload cannot survive the round trip**, and that is
  # Ruby canonicalising it rather than this class: `unpack1('g')` on
  # 7fc00001 gives NaN and packing that back gives 7fc00000. So the
  # value fails `Tlv.factory`'s encode-matches rule and is kept whole as
  # a `Tlv::Unknown`, which replays it. Measured on 2026-11-01, where 0,
  # -0, both infinities and the canonical NaN are all exact.
  def test_a_nan_payload_is_kept_as_an_unknown_tlv
    hex = '04410004' + '7fc00001'
    t = BGP::Link_state::Tlv.factory([hex].pack('H*'))
    assert_instance_of(BGP::Link_state::Tlv::Unknown, t)
    assert_equal(hex, t.to_shex, 'and the octets come back either way')
  end

  def test_the_float_values_that_do_round_trip
    %w[00000000 80000000 7f800000 ff800000 7fc00000].each do |v|
      hex = '04410004' + v
      t = BGP::Link_state::Tlv.factory([hex].pack('H*'))
      assert_instance_of(BGP::Link_state::Tlv::Maximum_link_bandwidth, t)
      assert_equal(hex, t.to_shex)
    end
  end

  # --- TLV 1092, TE Default Metric, section 5.3.2.3 -------------------

  def test_the_te_default_metric_tlv
    t = BGP::Link_state::Tlv::Te_default_metric.new(10)
    assert_equal(1092, t.type)
    assert_equal('04440004' + '0000000a', t.to_shex)
    assert_equal('TE metric 10', t.to_s)
    assert_equal({ :te_default_metric => 10 }, t.to_hash)
    assert_equal(t.to_shex, BGP::Link_state::Tlv::Te_default_metric
                              .new(t.to_hash).to_shex)
  end

  # Section 5.3.2.3: "If a source protocol uses a metric width of fewer
  # than 32 bits, then the high-order bits of this field MUST be padded
  # with zero." That holds by construction for a big-endian 32-bit
  # write, so it needed no code; asserted anyway, because a rule that
  # holds by accident of implementation is one a later change can break
  # in silence. **Not a reserved field**: every bit is the metric.
  def test_the_te_metric_pads_its_high_order_bits_with_zero
    assert_equal('0000000a', BGP::Link_state::Tlv::Te_default_metric
                               .new(10).encode_value.unpack1('H*'))
    assert_equal('00ffffff', BGP::Link_state::Tlv::Te_default_metric
                               .new(0xffffff).encode_value.unpack1('H*'))
  end

  # --- TLV 1093, Link Protection Type, RFC 5307 section 1.2 -----------

  # **Two octets**, which is the second width here that memory gets
  # wrong: a protection capability bit vector then one octet the section
  # disposes of in a sentence.
  def test_the_link_protection_type_tlv
    t = BGP::Link_state::Tlv::Link_protection_type.new(:shared, :enhanced)
    assert_equal(1093, t.type)
    assert_equal('04450002' + '2400', t.to_shex)
    assert_equal(6, t.size)
    assert_equal([:shared, :enhanced], t.names)
    assert(t.set?(:shared))
    assert_equal(0, t.reserved)
    assert_equal('Link protection shared,enhanced', t.to_s)
    assert_equal({ :link_protection_type => [:shared, :enhanced] }, t.to_hash)
    assert_equal(t.to_shex, BGP::Link_state::Tlv::Link_protection_type
                              .new(t.to_hash).to_shex)
  end

  # Each bit against the value RFC 5307 section 1.2 gives it, one by
  # one. A reversal of a set of disjoint masks is still a set of
  # disjoint masks and a round trip cannot see it.
  def test_each_protection_bit_is_the_value_its_section_gives
    { :extra_traffic => 0x01, :unprotected => 0x02, :shared => 0x04,
      :dedicated_1_1 => 0x08, :dedicated_1_plus_1 => 0x10,
      :enhanced => 0x20 }.each do |name, mask|
      t = BGP::Link_state::Tlv::Link_protection_type.new(name)
      assert_equal(mask, t.flags, "#{name} should be #{format('0x%02x', mask)}")
      assert_equal([name], t.names)
    end
  end

  # The six tile the low six bits and overlap nowhere, and the two the
  # section names only as "Reserved" are what is left.
  def test_the_protection_masks_cover_six_bits_and_overlap_nowhere
    bits = BGP::Link_state::Tlv::Link_protection_type::BITS.values
    assert_equal(0x3f, bits.inject(0) { |a, b| a | b })
    assert_equal(0x3f, BGP::Link_state::Tlv::Link_protection_type::DEFINED_BITS)
    bits.combination(2).each do |a, b|
      assert_equal(0, a & b)
    end
  end

  # **Both reserved places are kept and echoed**: the two bits of the
  # first octet RFC 5307 names only as "Reserved", and the whole second
  # octet, which "SHOULD be set to zero by the sender, and SHOULD be
  # ignored by the receiver". So the hash's `:bits` entry carries all
  # sixteen.
  def test_the_reserved_bits_and_the_reserved_octet_are_kept
    hex = '04450002' + 'e4ff'
    t = BGP::Link_state::Tlv.factory([hex].pack('H*'))
    assert_instance_of(BGP::Link_state::Tlv::Link_protection_type, t)
    assert_equal(hex, t.to_shex)
    assert_equal([:shared, :enhanced], t.names)
    assert_equal(0xff, t.reserved)
    assert_equal(0xc0ff, t.undefined_bits)
    assert(t.undefined_bits?)
    assert_equal({ :link_protection_type =>
                   [:shared, :enhanced, { :bits => 0xe4ff }] }, t.to_hash)
    assert_equal(hex, BGP::Link_state::Tlv::Link_protection_type
                        .new(t.to_hash).to_shex)
  end

  # An ordinary value has nothing outside the six bits, so no entry.
  def test_an_ordinary_protection_type_hashes_to_the_plain_list
    t = BGP::Link_state::Tlv::Link_protection_type.new(:unprotected)
    assert(!t.undefined_bits?)
    assert_equal({ :link_protection_type => [:unprotected] }, t.to_hash)
  end

  # A width other than 2 is not this TLV, so it falls back and replays.
  def test_a_one_octet_protection_type_reads_back_as_unknown
    hex = '04450001' + '04'
    t = BGP::Link_state::Tlv.factory([hex].pack('H*'))
    assert_instance_of(BGP::Link_state::Tlv::Unknown, t)
    assert_equal(hex, t.to_shex)
  end

  # --- TLV 1094, MPLS Protocol Mask, section 5.3.2.2 ------------------

  # Figure 19 is `|L|R|  Reserved |`, so L is the most significant bit,
  # which is this family's own numbering and the opposite of 1088's.
  # Table 9 names them: L is LDP, R is RSVP-TE.
  def test_the_mpls_protocol_mask_tlv
    t = BGP::Link_state::Tlv::Mpls_protocol_mask.new(:ldp, :rsvp_te)
    assert_equal(1094, t.type)
    assert_equal('04460001' + 'c0', t.to_shex)
    assert_equal(5, t.size)
    assert(t.ldp?)
    assert(t.rsvp_te?)
    assert_equal('MPLS protocols ldp,rsvp_te', t.to_s)
    assert_equal({ :mpls_protocol_mask => [:ldp, :rsvp_te] }, t.to_hash)
    assert_equal(t.to_shex, BGP::Link_state::Tlv::Mpls_protocol_mask
                              .new(t.to_hash).to_shex)
  end

  def test_each_mpls_protocol_bit_is_where_the_figure_puts_it
    assert_equal(0x80, BGP::Link_state::Tlv::Mpls_protocol_mask
                         .new(:ldp).value)
    assert_equal(0x40, BGP::Link_state::Tlv::Mpls_protocol_mask
                         .new(:rsvp_te).value)
    assert_equal(0xc0, BGP::Link_state::Tlv::Mpls_protocol_mask::DEFINED_BITS)
  end

  # The section says the reserved bits must be zero on transmit and
  # ignored on receipt, twice over, so they are kept and echoed.
  def test_a_reserved_mpls_protocol_bit_is_kept
    hex = '04460001' + '81'
    t = BGP::Link_state::Tlv.factory([hex].pack('H*'))
    assert_equal(hex, t.to_shex)
    assert_equal([:ldp], t.names)
    assert_equal(1, t.undefined_bits)
    assert_equal({ :mpls_protocol_mask => [:ldp, { :bits => 0x81 }] },
                 t.to_hash)
    assert_equal(hex, BGP::Link_state::Tlv::Mpls_protocol_mask
                        .new(t.to_hash).to_shex)
  end

  def test_no_mpls_protocol_set
    t = BGP::Link_state::Tlv::Mpls_protocol_mask.new
    assert_equal('0446000100', t.to_shex)
    assert_equal('MPLS protocols none', t.to_s)
  end

  # --- TLV 1095, IGP Metric, section 5.3.2.4 --------------------------

  # The section lists three widths and nothing else: 1 octet for IS-IS
  # small metrics, 2 for OSPF, 3 for IS-IS wide.
  def test_the_three_igp_metric_widths
    assert_equal('04470001' + '0a',
                 BGP::Link_state::Tlv::Igp_metric.new(10, 1).to_shex)
    assert_equal('04470002' + '000a',
                 BGP::Link_state::Tlv::Igp_metric.new(10, 2).to_shex)
    assert_equal('04470003' + '00000a',
                 BGP::Link_state::Tlv::Igp_metric.new(10, 3).to_shex)
    assert_equal([1, 2, 3], BGP::Link_state::Tlv::Igp_metric::WIDTHS)
  end

  # **The width is a fact about the source IGP and not about the value**,
  # so it is carried rather than inferred: a metric of 10 is legal at
  # all three widths and nothing in the section picks one. `new(10)`
  # defaults to 3, the only width that holds any 24-bit metric.
  def test_the_width_is_carried_and_defaults_to_three
    t = BGP::Link_state::Tlv::Igp_metric.new(10)
    assert_equal(1095, t.type)
    assert_equal(3, t.width)
    assert_equal(10, t.metric)
    assert_equal('IGP metric 10 (3 octets)', t.to_s)
    assert_equal({ :igp_metric => { :metric => 10, :width => 3 } }, t.to_hash)
    assert_equal(t.to_shex, BGP::Link_state::Tlv::Igp_metric
                              .new(t.to_hash).to_shex)
    assert_equal('IGP metric 10 (1 octet)',
                 BGP::Link_state::Tlv::Igp_metric.new(10, 1).to_s)
  end

  # The width comes off the wire, so all three read back saying which
  # they were and the hash carries it.
  def test_each_width_reads_back_with_its_width
    { 1 => '0a', 2 => '000a', 3 => '00000a' }.each do |w, v|
      hex = format('0447%04x', w) + v
      t = BGP::Link_state::Tlv.factory([hex].pack('H*'))
      assert_instance_of(BGP::Link_state::Tlv::Igp_metric, t)
      assert_equal(w, t.width)
      assert_equal(10, t.metric)
      assert(t.known_width?)
      assert_equal(hex, t.to_shex)
      assert_equal(hex, BGP::Link_state::Tlv::Igp_metric.new(t.to_hash).to_shex)
    end
  end

  # **The 1-octet form has two reserved bits and the others have none**:
  # "IS-IS small metrics are 6 bits in size but are encoded in a 1-octet
  # field; therefore, the two most significant bits of the field MUST be
  # set to 0 by the originator and MUST be ignored by the receiver."
  def test_the_reserved_bits_of_the_one_octet_form
    hex = '04470001' + 'c3'
    t = BGP::Link_state::Tlv.factory([hex].pack('H*'))
    assert_equal(hex, t.to_shex)
    assert_equal(195, t.metric)
    assert_equal(0xc0, t.undefined_bits)
    assert(t.undefined_bits?)
    assert_equal(0x3f, BGP::Link_state::Tlv::Igp_metric::DEFINED_BITS)
    assert_equal({ :igp_metric =>
                   { :metric => 195, :width => 1, :bits => 195 } }, t.to_hash)
    assert_equal(hex, BGP::Link_state::Tlv::Igp_metric.new(t.to_hash).to_shex)
  end

  # And the wider forms reserve nothing, however their own high bits
  # read, so no `:bits` entry however large the metric.
  def test_the_wider_forms_reserve_nothing
    [2, 3].each do |w|
      t = BGP::Link_state::Tlv::Igp_metric.new((1 << (w * 8)) - 1, w)
      assert_equal(0, t.undefined_bits, "width #{w}")
      assert(!t.undefined_bits?)
      assert_equal({ :metric => (1 << (w * 8)) - 1, :width => w },
                   t.to_hash[:igp_metric])
    end
  end

  # A width the section does not list is a value no RFC describes, so it
  # is kept rather than refused, and `known_width?` is how a reader asks.
  def test_a_width_no_section_lists_is_kept
    hex = '04470005' + '0000000001'
    t = BGP::Link_state::Tlv.factory([hex].pack('H*'))
    assert_instance_of(BGP::Link_state::Tlv::Igp_metric, t)
    assert_equal(5, t.width)
    assert_equal(1, t.metric)
    assert(!t.known_width?)
    assert_equal(hex, t.to_shex)
  end

  # A value of no octets cannot say what width it was, so it is refused
  # and `Tlv.factory` keeps it whole instead.
  def test_an_empty_igp_metric_value_reads_back_as_unknown
    hex = '04470000'
    t = BGP::Link_state::Tlv.factory([hex].pack('H*'))
    assert_instance_of(BGP::Link_state::Tlv::Unknown, t)
    assert_equal(hex, t.to_shex)
  end

  # --- TLV 1096, Shared Risk Link Group, section 5.3.2.5 -------------

  # "The length of this TLV is 4 * (number of SRLG values)."
  def test_the_srlg_tlv
    t = BGP::Link_state::Tlv::Srlg.new(100, 200)
    assert_equal(1096, t.type)
    assert_equal('04480008' + '00000064' + '000000c8', t.to_shex)
    assert_equal([100, 200], t.values)
    assert_equal('SRLG 100,200', t.to_s)
    assert_equal({ :srlg => [100, 200] }, t.to_hash)
    assert_equal(t.to_shex, BGP::Link_state::Tlv::Srlg.new(t.to_hash).to_shex)
    assert_equal(t.to_shex,
                 BGP::Link_state::Tlv::Srlg.new([100, 200]).to_shex)
  end

  # Zero values is what that arithmetic gives for no SRLGs, and section
  # 5.1 permits a value of nothing outright.
  def test_an_srlg_tlv_with_no_values
    t = BGP::Link_state::Tlv::Srlg.new
    assert_equal('04480000', t.to_shex)
    assert_equal('SRLG none', t.to_s)
    assert_equal(t.to_shex, BGP::Link_state::Tlv::Srlg.new(t.to_hash).to_shex)
  end

  # **The wire path, which the two build-from-values cases above do not
  # reach.** Coverage found this: every other class here is parsed from
  # octets by a case of its own and the SRLG was not, so `Srlg#parse`
  # had no test at all.
  def test_an_srlg_tlv_read_off_the_wire
    hex = '04480008' + '00000064' + '000000c8'
    t = BGP::Link_state::Tlv.factory([hex].pack('H*'))
    assert_instance_of(BGP::Link_state::Tlv::Srlg, t)
    assert_equal([100, 200], t.values)
    assert_equal(hex, t.to_shex)
  end

  # A value that is not a multiple of 4 keeps the whole groups and loses
  # the remainder, so it cannot reproduce its own octets and
  # `Tlv.factory` keeps it as a `Tlv::Unknown` instead. Section
  # 5.3.2.5's arithmetic makes 4*n the only legal length, and this is
  # how a value outside it still replays.
  def test_an_srlg_value_that_is_not_a_multiple_of_four
    hex = '04480005' + '0000006400'
    t = BGP::Link_state::Tlv.factory([hex].pack('H*'))
    assert_instance_of(BGP::Link_state::Tlv::Unknown, t)
    assert_equal(hex, t.to_shex)
  end

  # **One TLV carries both families**, which the section says and which
  # IS-IS does not do: there it is TLV 138 for IPv4 and TLV 139 for
  # IPv6. So there is no second class and nothing here is per family.
  def test_there_is_one_srlg_class_for_both_families
    assert_equal(1, BGP::Link_state::Tlv::REGISTRY.values
                      .count { |k| k == BGP::Link_state::Tlv::Srlg })
  end

  # --- TLV 1097 and 1098, the shapes Table 6 already had -------------

  def test_the_opaque_link_attribute_tlv
    t = BGP::Link_state::Tlv::Opaque_link_attribute
          .new(['deadbeef'].pack('H*'))
    assert_equal(1097, t.type)
    assert_equal('04490004' + 'deadbeef', t.to_shex)
    assert_equal('Opaque link attribute 4 octets [deadbeef]', t.to_s)
    assert_equal({ :opaque_link_attribute => 'deadbeef' }, t.to_hash)
    assert_equal(t.to_shex, BGP::Link_state::Tlv::Opaque_link_attribute
                              .new(t.to_hash).to_shex)
  end

  # 'to-core-1' is nine octets of 7-bit ASCII.
  def test_the_link_name_tlv
    t = BGP::Link_state::Tlv::Link_name.new('to-core-1')
    assert_equal(1098, t.type)
    assert_equal('044a0009' + '746f2d636f72652d31', t.to_shex)
    assert_equal('to-core-1', t.name)
    assert(t.ascii?)
    assert_equal("Link name 'to-core-1'", t.to_s)
    assert_equal({ :link_name => 'to-core-1' }, t.to_hash)
    assert_equal(t.to_shex, BGP::Link_state::Tlv::Link_name
                              .new(t.to_hash).to_shex)
  end

  # **1098 and 1026 are one shape and two type numbers**, which is what
  # part 5b-i lifted `Text_tlv` out of `Node_name` for: sections 5.3.1.3
  # and 5.3.2.7 are the same three paragraphs with "router link" for
  # "router node". Asserted so the sharing is on record.
  def test_the_two_name_tlvs_share_one_shape
    assert_equal(BGP::Link_state::Tlv::Text_tlv,
                 BGP::Link_state::Tlv::Link_name.superclass)
    assert_equal(BGP::Link_state::Tlv::Text_tlv,
                 BGP::Link_state::Tlv::Node_name.superclass)
    assert_equal(BGP::Link_state::Tlv::Node_name.new('x').encode_value,
                 BGP::Link_state::Tlv::Link_name.new('x').encode_value)
  end

  # And 1097 and 1025 likewise, through `Opaque_tlv`.
  def test_the_two_opaque_tlvs_share_one_shape
    assert_equal(BGP::Link_state::Tlv::Opaque_tlv,
                 BGP::Link_state::Tlv::Opaque_link_attribute.superclass)
    assert_equal(BGP::Link_state::Tlv::Opaque_tlv,
                 BGP::Link_state::Tlv::Opaque_node_attribute.superclass)
  end

  # --- the registry and the family ------------------------------------

  # Table 8's thirteen new code points, each registered to the class
  # that reads it and to a hash key of its own.
  def test_table_8_is_registered
    { 1030 => BGP::Link_state::Tlv::Ipv4_remote_router_id,
      1031 => BGP::Link_state::Tlv::Ipv6_remote_router_id,
      1088 => BGP::Link_state::Tlv::Administrative_group,
      1089 => BGP::Link_state::Tlv::Maximum_link_bandwidth,
      1090 => BGP::Link_state::Tlv::Max_reservable_link_bandwidth,
      1091 => BGP::Link_state::Tlv::Unreserved_bandwidth,
      1092 => BGP::Link_state::Tlv::Te_default_metric,
      1093 => BGP::Link_state::Tlv::Link_protection_type,
      1094 => BGP::Link_state::Tlv::Mpls_protocol_mask,
      1095 => BGP::Link_state::Tlv::Igp_metric,
      1096 => BGP::Link_state::Tlv::Srlg,
      1097 => BGP::Link_state::Tlv::Opaque_link_attribute,
      1098 => BGP::Link_state::Tlv::Link_name,
    }.each do |type, klass|
      assert_equal(klass, BGP::Link_state::Tlv::REGISTRY[type])
      assert_equal(klass, BGP::Link_state::Tlv::BY_KEY[klass.hash_key])
      assert_equal(type, klass.type)
    end
  end

  # Every class here builds from another instance, the fourth build path
  # and the one that catches an encoder that consumes what it was
  # handed.
  def test_every_class_builds_from_another_instance
    [BGP::Link_state::Tlv::Ipv4_remote_router_id.new('10.0.0.2'),
     BGP::Link_state::Tlv::Ipv6_remote_router_id.new('2001:db8::2'),
     BGP::Link_state::Tlv::Administrative_group.new(0x80000005),
     BGP::Link_state::Tlv::Maximum_link_bandwidth.new(1_250_000.0),
     BGP::Link_state::Tlv::Max_reservable_link_bandwidth.new(1_000_000.0),
     BGP::Link_state::Tlv::Unreserved_bandwidth.new(1.0, 2.0),
     BGP::Link_state::Tlv::Te_default_metric.new(10),
     BGP::Link_state::Tlv::Link_protection_type.new(:shared),
     BGP::Link_state::Tlv::Mpls_protocol_mask.new(:ldp),
     BGP::Link_state::Tlv::Igp_metric.new(10, 2),
     BGP::Link_state::Tlv::Srlg.new(100, 200),
     BGP::Link_state::Tlv::Opaque_link_attribute.new(['dead'].pack('H*')),
     BGP::Link_state::Tlv::Link_name.new('x'),
    ].each do |t|
      assert_equal(t.to_shex, t.class.new(t).to_shex, t.class.to_s)
      assert_equal(t.to_shex, t.class.new(t).to_shex,
                   "#{t.class} was consumed by its own copy")
    end
  end

  # Every octet buffer in this file is BINARY, which is the Ruby version
  # bug #218 shipped in this family: `+''` is US-ASCII and an empty one
  # handed to IPAddr raises on 3.4 and passes on 3.3. Assert the buffer
  # and not `encode`, which `pack` forces binary whatever went in.
  def test_the_octet_buffers_are_binary
    assert_equal(Encoding::BINARY,
                 BGP::Link_state::Tlv::Opaque_link_attribute
                   .new.value.encoding)
    assert_equal(Encoding::BINARY,
                 BGP::Link_state::Tlv::Link_name.new.name.encoding)
  end

  # Nothing validates, per Conventions. Seven things no RFC allows, each
  # of which a test of a router has to be able to put on the wire.
  def test_nothing_validates
    # A reserved protection bit and a non-zero reserved octet.
    assert_equal('04450002' + 'c0ff',
                 BGP::Link_state::Tlv::Link_protection_type
                   .new(:bits => 0xc0ff).to_shex)
    # A reserved MPLS Protocol Mask bit, which the section says twice
    # over must be zero.
    assert_equal('04460001' + '3f',
                 BGP::Link_state::Tlv::Mpls_protocol_mask.new(0x3f).to_shex)
    # The two bits of a 1-octet IGP metric the section reserves.
    assert_equal('04470001' + 'ff',
                 BGP::Link_state::Tlv::Igp_metric.new(0xff, 1).to_shex)
    # An IGP metric of a width no section lists.
    assert_equal('0447000800000000000000ff',
                 BGP::Link_state::Tlv::Igp_metric.new(0xff, 8).to_shex)
    # Unreserved bandwidth at three priorities rather than eight.
    assert_equal(12, BGP::Link_state::Tlv::Unreserved_bandwidth
                       .new(1.0, 2.0, 3.0).encode_value.size)
    # A negative bandwidth, which no section describes.
    assert_equal('04410004' + 'c9989680',
                 BGP::Link_state::Tlv::Maximum_link_bandwidth
                   .new(-1_250_000.0).to_shex)
    # A Length that disagrees with the value that came with it.
    t = BGP::Link_state::Tlv::Srlg.new(100)
    t.declared_len = 9
    assert_equal('04480009' + '00000064', t.to_shex)
  end

  # A value the field cannot hold is the one refusal Conventions allows,
  # and the octet-level route stays open, which it requires.
  def test_a_value_the_field_cannot_hold_is_refused
    assert_raise(ArgumentError) do
      BGP::Link_state::Tlv::Mpls_protocol_mask.new(0x100)
    end
    assert_raise(ArgumentError) do
      BGP::Link_state::Tlv::Link_protection_type.new(0x100)
    end
    assert_raise(ArgumentError) do
      BGP::Link_state::Tlv::Igp_metric.new(256, 1)
    end
    assert_raise(ArgumentError) do
      BGP::Link_state::Tlv::Igp_metric.new(10, 0)
    end
    assert_equal('04470001' + 'ff',
                 BGP::Link_state::Tlv::Unknown
                   .new(1095, ['ff'].pack('H*')).to_shex)
  end

  # The capability octet on its own, which is the form a caller with a
  # value out of a capture uses rather than naming six bits.
  def test_a_protection_type_from_its_capability_octet
    t = BGP::Link_state::Tlv::Link_protection_type.new(0x24)
    assert_equal('04450002' + '2400', t.to_shex)
    assert_equal([:shared, :enhanced], t.names)
    assert_equal(0, t.reserved)
  end

  # A name neither bitfield knows is refused and says what it has, which
  # is what stops a typo building a value of zero in silence.
  def test_a_bit_name_no_class_knows_is_refused
    e = assert_raise(ArgumentError) do
      BGP::Link_state::Tlv::Link_protection_type.new(:dedicated)
    end
    assert_match(/unknown protection type :dedicated/, e.message)
    assert_match(/extra_traffic/, e.message, 'and names the ones it has')
    e = assert_raise(ArgumentError) do
      BGP::Link_state::Tlv::Mpls_protocol_mask.new(:sr_mpls)
    end
    assert_match(/unknown MPLS protocol :sr_mpls/, e.message)
    assert_match(/rsvp_te/, e.message)
  end

  # A width other than 1 is not the MPLS Protocol Mask, whose section
  # says "The length of this TLV is 1", so it falls back and replays.
  def test_a_two_octet_mpls_protocol_mask_reads_back_as_unknown
    hex = '04460002' + 'c000'
    t = BGP::Link_state::Tlv.factory([hex].pack('H*'))
    assert_instance_of(BGP::Link_state::Tlv::Unknown, t)
    assert_equal(hex, t.to_shex)
  end

  def test_the_unreserved_bandwidth_prints_every_priority
    t = BGP::Link_state::Tlv::Unreserved_bandwidth.new(1.0, 2.0)
    assert_equal('Unreserved bandwidth 1.0,2.0 Bps', t.to_s)
    assert_equal('Unreserved bandwidth  Bps',
                 BGP::Link_state::Tlv::Unreserved_bandwidth.new.to_s)
  end

  # An argument no class here understands is refused rather than
  # building something else.
  def test_an_argument_no_class_understands_is_refused
    [BGP::Link_state::Tlv::Maximum_link_bandwidth,
     BGP::Link_state::Tlv::Unreserved_bandwidth,
     BGP::Link_state::Tlv::Link_protection_type,
     BGP::Link_state::Tlv::Mpls_protocol_mask,
     BGP::Link_state::Tlv::Igp_metric,
     BGP::Link_state::Tlv::Srlg,
    ].each do |klass|
      assert_raise(ArgumentError, klass.to_s) { klass.new(Object.new) }
    end
  end

  # Section 5.3.2.1 says the Router-ID TLVs repeat, so two of a type in
  # one list is ordinary traffic and section 5.1's tiebreakers order
  # them. The same holds for the SRLG, which carries its own list.
  def test_two_remote_router_ids_in_one_list
    hex = '040600040a000002' + '040600040a000003'
    list = BGP::Link_state::Tlv.parse_list([hex].pack('H*'))
    assert_equal(2, list.size)
    assert_equal(hex, list.collect { |t| t.to_shex }.join)
    assert(BGP::Link_state::Tlv.ordered?(list))
  end

end
