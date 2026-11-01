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
require 'bgp/path_attributes/link_state_attribute'
# The attribute set, for the cases that read this attribute back out of
# one. Required here and not relied on from the suite: a file that does
# not require what it names passes in the suite and fails on its own,
# which is the load order trap Conventions records and which this
# family's doc test met three times.
require 'bgp/path_attributes/path_attribute'

# **RFC 9552 carries no worked example and no hex anywhere**, measured
# in part 1. So every expectation here is this reader's arithmetic from
# the Table 6 widths and the section 5.1 framing, and the field
# breakdown is written out beside each case for that reason.
#
# The attribute header, once: flags 0x80 is optional non-transitive with
# the Extended Length bit clear, and 0x1d is 29.
class TestLinkStateAttribute < Test::Unit::TestCase

  include BGP

  # Three TLVs in ascending type order, which section 5.1 asks a sender
  # for. 1024 is a 5-octet TLV, 1026 with 'router1' is 11 and 1028 is 8,
  # so the value is 24 octets and the Length is 0x18.
  SHEX = '801d18' +
         '04000001' + 'c0' +
         '04020007' + '726f7574657231' +
         '04040004' + '0a000001'

  def tlvs
    [BGP::Link_state::Tlv::Node_flag_bits.new(:overload, :attached),
     BGP::Link_state::Tlv::Node_name.new('router1'),
     BGP::Link_state::Tlv::Ipv4_local_router_id.new('10.0.0.1')]
  end

  def test_the_attribute_from_field_values
    a = BGP::Link_state_attribute.new(*tlvs)
    assert_equal(29, a.type)
    assert_equal(SHEX, a.to_shex)
    assert_equal(3, a.tlvs.size)
  end

  # Section 5.3: "an optional, non-transitive BGP Attribute". So the
  # Optional bit and not the Transitive one, which is what the flags
  # octet says and what `flags` prints as [Oncr].
  def test_the_attribute_is_optional_and_non_transitive
    a = BGP::Link_state_attribute.new(*tlvs)
    assert_equal(0x80, a.encode.unpack1('C'))
    assert_equal('[Oncr]', a.flags)
  end

  def test_the_attribute_from_wire_bytes
    a = BGP::Link_state_attribute.new([SHEX].pack('H*').is_packed)
    assert_equal(SHEX, a.to_shex)
    assert_equal([BGP::Link_state::Tlv::Node_flag_bits,
                  BGP::Link_state::Tlv::Node_name,
                  BGP::Link_state::Tlv::Ipv4_local_router_id],
                 a.tlvs.collect { |t| t.class })
    assert_equal('router1', a.tlv(1026).name)
  end

  def test_the_attribute_from_another_instance
    a = BGP::Link_state_attribute.new(*tlvs)
    assert_equal(SHEX, BGP::Link_state_attribute.new(a).to_shex)
    assert_equal(SHEX, BGP::Link_state_attribute.new(a).to_shex,
                 'the copy consumed the instance it copied')
  end

  # **The hash is a list and not a map keyed by type**, which is the one
  # thing this attribute does differently from `Path_attribute`'s own
  # hash and it is deliberate: section 5.3.1.2 says the IS-IS Area
  # Identifier repeats and section 5.3.1.4 says each auxiliary Router-ID
  # is a separate TLV, so repetition is the design here where
  # `Path_attribute` had to bolt on a `:duplicates` key.
  def test_the_attribute_from_its_own_hash
    a = BGP::Link_state_attribute.new(*tlvs)
    assert_equal({ :link_state => [{ :node_flag_bits => [:overload, :attached] },
                                   { :node_name => 'router1' },
                                   { :ipv4_local_router_id => '10.0.0.1' }] },
                 a.to_hash)
    assert_equal(SHEX, BGP::Link_state_attribute.new(a.to_hash).to_shex)
  end

  def test_two_of_a_type_survive_the_hash
    a = BGP::Link_state_attribute.new(
      BGP::Link_state::Tlv::Isis_area_id.new(['490001'].pack('H*')),
      BGP::Link_state::Tlv::Isis_area_id.new(['490002'].pack('H*')))
    # Two 7-octet TLVs, so the value is 14 octets and the Length is
    # 0x0e. **Written as 0x0c first**, which is the fourteenth
    # hand-written expectation wrong in this family with the library
    # right every time.
    assert_equal('801d0e' + '04030003490001' + '04030003490002', a.to_shex)
    assert_equal(2, a.to_hash[:link_state].size)
    assert_equal(a.to_shex, BGP::Link_state_attribute.new(a.to_hash).to_shex)
  end

  # One TLV's hash, with no :link_state key, is a value like any other,
  # which is the branch `Cluster_list` takes for the same reason.
  def test_one_tlv_hash_is_not_read_as_the_attributes_own_hash
    a = BGP::Link_state_attribute.new(:node_name => 'r1')
    assert_equal('801d06' + '04020002' + '7231', a.to_shex)
    assert_equal(1, a.tlvs.size)
  end

  def test_add_takes_instances_and_hashes
    a = BGP::Link_state_attribute.new
    a << BGP::Link_state::Tlv::Node_flag_bits.new(:overload)
    a << { :node_name => 'r1' }
    assert_equal('801d0b' + '0400000180' + '040200027231', a.to_shex)
    assert_equal(2, a.tlvs.size)
  end

  def test_a_hash_key_nothing_knows_is_refused
    assert_raise(ArgumentError) do
      BGP::Link_state_attribute.new(:not_a_bgp_ls_tlv => 1)
    end
  end

  def test_a_value_that_is_neither_a_tlv_nor_a_hash_is_refused
    assert_raise(ArgumentError) { BGP::Link_state_attribute.new(42) }
  end

  # An attribute with no TLV at all. Section 5.3 defines the attribute
  # as "a set of Type/Length/Value (TLV) triplets" and says nothing
  # about an empty set, so this is one of the things nothing validates.
  def test_an_attribute_with_no_tlvs
    a = BGP::Link_state_attribute.new
    assert_equal('801d00', a.to_shex)
    assert_equal([], a.tlvs)
    assert_equal({ :link_state => [] }, a.to_hash)
    assert_equal('801d00', BGP::Link_state_attribute.new(a.to_hash).to_shex)
  end

  # --- what cannot frame a TLV is kept ---------------------------------

  # Two octets cannot frame a TLV, since the framing is four. They are
  # kept and written back, which is `Attr::TAIL_KEY` and the mechanism
  # six other attributes already use.
  def test_octets_that_cannot_frame_a_tlv_are_kept
    hex = '801d07' + '0400000100' + 'ffff'
    a = BGP::Link_state_attribute.new([hex].pack('H*').is_packed)
    assert_equal(hex, a.to_shex)
    assert_equal(1, a.tlvs.size)
    assert_equal('ffff', a.tail.unpack1('H*'))
  end

  def test_a_kept_tail_survives_the_hash
    hex = '801d07' + '0400000100' + 'ffff'
    a = BGP::Link_state_attribute.new([hex].pack('H*').is_packed)
    assert_equal({ :tail => 'ffff' }, a.to_hash[:link_state].last)
    assert_equal(hex, BGP::Link_state_attribute.new(a.to_hash).to_shex)
  end

  # A Length that overran took everything that was there, so there is
  # nothing left for a tail, and the Length that lied is kept so encode
  # writes the peer's own number back.
  def test_a_tlv_length_that_overruns_is_kept_as_declared
    hex = '801d05' + '04000009' + 'c0'
    a = BGP::Link_state_attribute.new([hex].pack('H*').is_packed)
    assert_equal(hex, a.to_shex)
    assert_equal(9, a.tlvs.first.declared_len)
    assert_nil(a.tail)
    assert_equal(hex, BGP::Link_state_attribute.new(a.to_hash).to_shex)
  end

  # Section 5.1: "Unknown and unsupported types MUST be preserved and
  # propagated within both the NLRI and the BGP-LS Attribute", and
  # their presence "MUST NOT result in the NLRI or the BGP-LS Attribute
  # being considered malformed". 0x270f is 9999, which no document
  # defines.
  def test_an_unknown_tlv_beside_a_known_one
    hex = '801d0b' + '0400000180' + '270f0002abcd'
    a = BGP::Link_state_attribute.new([hex].pack('H*').is_packed)
    assert_equal(hex, a.to_shex)
    assert_equal([BGP::Link_state::Tlv::Node_flag_bits,
                  BGP::Link_state::Tlv::Unknown],
                 a.tlvs.collect { |t| t.class })
    assert_equal(hex, BGP::Link_state_attribute.new(a.to_hash).to_shex)
  end

  # --- ordering --------------------------------------------------------

  # **Section 5.1 makes this attribute's ordering a SHOULD and says
  # outright that a breach is not malformed**, where the NLRI's is a
  # MUST. So the attribute reports and refuses nothing.
  def test_an_unordered_attribute_builds_and_reports
    a = BGP::Link_state_attribute.new(
      BGP::Link_state::Tlv::Node_name.new('x'),
      BGP::Link_state::Tlv::Node_flag_bits.new)
    assert_equal('801d0a' + '0402000178' + '0400000100', a.to_shex)
    assert(!a.ordered?)
    assert(BGP::Link_state_attribute.new(*tlvs).ordered?)
  end

  # The rule lives with the TLV, so this asks rather than keeping a
  # second comparison, which is the lesson flow spec part 4 records
  # about a check reimplementing what a family already owns.
  def test_the_ordering_rule_is_the_tlvs_own
    a = BGP::Link_state_attribute.new(*tlvs)
    assert_equal(BGP::Link_state::Tlv.ordered?(a.tlvs), a.ordered?)
  end

  # --- inside an attribute set -----------------------------------------

  # The whole point of a path attribute: it has to read back out of a
  # set, with no protocol error and no coverage gap. Before this part a
  # BGP-LS Attribute came back as an `Attr::Unknown` with an
  # `Attr::Gap`, which part 7 measured against a real router.
  def test_the_attribute_reads_back_out_of_an_attribute_set
    pa = BGP::Path_attribute.new(BGP::Link_state_attribute.new(*tlvs))
    assert_equal(SHEX, pa.to_shex)
    back = BGP::Path_attribute.new([pa.to_shex].pack('H*').is_packed)
    assert_equal(SHEX, back.to_shex)
    assert_equal([BGP::Link_state_attribute],
                 back.attributes.collect { |a| a.class })
    assert_equal(0, back.errors.size)
    assert_equal(0, back.undecoded.size)
  end

  def test_the_attribute_set_hash_carries_it
    pa = BGP::Path_attribute.new(BGP::Link_state_attribute.new(*tlvs))
    assert_equal(3, pa.to_hash[:link_state].size)
    assert_equal(SHEX, BGP::Path_attribute.new(pa.to_hash).to_shex)
  end

  def test_the_attribute_is_registered
    # `by_key` answers the Registration and not the class, which is
    # what every other caller of it reads.
    assert_equal(BGP::Link_state_attribute,
                 BGP::Attr.by_key(:link_state).klass)
    assert_equal(BGP::Link_state_attribute, BGP::Attr.by_type(29).klass)
    assert_equal(29, BGP::ATTR::BGP_LS)
  end

  # --- nothing validates ------------------------------------------------

  # Per Conventions. Four things no RFC allows, each of which a test of a
  # router has to be able to put on the wire.
  def test_nothing_validates
    # A node attribute TLV and a link descriptor TLV in one attribute,
    # which no table puts together.
    a = BGP::Link_state_attribute.new(
      BGP::Link_state::Tlv::Node_flag_bits.new(:overload),
      BGP::Link_state::Tlv::Ipv4_interface_address.new('192.0.2.1'))
    # TLV 259 is 0x0103 and its value is 4 octets, so that TLV is 8 and
    # the attribute's value is 13, 0x0d.
    assert_equal('801d0d' + '0400000180' + '01030004' + 'c0000201',
                 a.to_shex)
    # A TLV type no document defines.
    assert_equal('801d06' + '270f0002abcd',
                 BGP::Link_state_attribute
                   .new(BGP::Link_state::Tlv::Unknown
                          .new(9999, ['abcd'].pack('H*'))).to_shex)
    # The header made to lie, through Attr::OVERRIDE_KEYS.
    assert_equal('c01d00',
                 BGP::Link_state_attribute.new(:flags => 0xc).to_shex)
    # A transitive BGP-LS Attribute, which section 5.3 says it is not.
    assert_equal('c01d05' + '0400000180',
                 BGP::Link_state_attribute
                   .new(BGP::Link_state::Tlv::Node_flag_bits.new(:overload),
                        :flags => 0xc).to_shex)
  end

  # The attribute may be large, so the Extended Length bit has to be
  # written when the value needs two octets. Section 5.3 expects it:
  # "The size of the BGP-LS Attribute may potentially grow large."
  def test_a_value_over_255_octets_sets_the_extended_length_bit
    a = BGP::Link_state_attribute.new(
      BGP::Link_state::Tlv::Node_name.new('a' * 300))
    assert_equal('901d0130', a.to_shex[0, 8])
    assert_equal(304, a.encode.size - 4)
    back = BGP::Link_state_attribute.new([a.to_shex].pack('H*').is_packed)
    assert_equal(a.to_shex, back.to_shex)
  end

  def test_to_s_names_the_attribute_and_its_tlvs
    a = BGP::Link_state_attribute.new(*tlvs)
    s = a.to_s
    assert_match(/Link State Attribute/, s)
    assert_match(/Node flags overload,attached/, s)
    assert_match(/Node name 'router1'/, s)
  end

end
