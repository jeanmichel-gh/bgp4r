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
require 'bgp/nlris/link_state_sr'
require 'bgp/nlris/link_state_descriptor'
require 'bgp/path_attributes/link_state_attribute'
require 'bgp/path_attributes/path_attribute'

# RFC 9085 and RFC 9086 carry no hex. Every expectation here is worked
# out from the figures, with the fields written beside it.
#
# The type numbers: 1034 to 1036 are 0x040a to 0x040c, 1099 to 1103 are
# 0x044b to 0x044f, 1158 is 0x0486, 1161 is 0x0489, 516 and 517 are
# 0x0204 and 0x0205.
class TestLinkStateSr < Test::Unit::TestCase

  include BGP

  T = BGP::Link_state::Tlv

  def wire(hex)
    [hex].pack('H*').is_packed
  end

  # Read one TLV the way the attribute does, from its framed octets.
  def read(hex)
    T.factory(wire(hex))
  end

  # The four ways, and the factory, all give back the same octets.
  def assert_four_ways(t)
    assert_equal(t.to_shex, t.class.new(t).to_shex, 'from an instance')
    assert_equal(t.to_shex, t.class.new(t.to_hash).to_shex, 'from its hash')
    assert_equal(t.to_shex, T.from_hash(t.to_hash).to_shex, 'Tlv.from_hash')
    assert_equal(t.to_shex,
                 t.class.new(wire(t.encode_value.unpack1('H*'))).to_shex,
                 'from its value octets')
    back = read(t.to_shex)
    assert_equal(t.class, back.class, 'Tlv.factory')
    assert_equal(t.to_shex, back.to_shex)
  end

  # --- RFC 9086 section 4.1, node descriptors 516 and 517 --------------

  def test_the_bgp_router_id_descriptor
    t = T::Bgp_router_id.new('10.0.0.1')
    # 0204 type, 0004 length, 0a000001.
    assert_equal('020400040a000001', t.to_shex)
    assert_equal('10.0.0.1', t.router_id)
    assert_equal('BGP Router-ID 10.0.0.1', t.to_s)
    assert_equal({ :bgp_router_id => '10.0.0.1' }, t.to_hash)
    assert_equal(t.to_shex, T::Bgp_router_id.new(t.to_hash).to_shex)
    assert_equal(t.to_shex, T::Bgp_router_id.new(0x0a000001).to_shex)
    assert_four_ways(t)
  end

  def test_the_bgp_confederation_member_descriptor
    t = T::Bgp_confederation_member.new(65001)
    assert_equal('020500040000fde9', t.to_shex)
    assert_equal('Member-AS 65001', t.to_s)
    assert_equal({ :bgp_confederation_member => 65001 }, t.to_hash)
    assert_equal(t.to_shex, T::Bgp_confederation_member.new(t.to_hash).to_shex)
    assert_four_ways(t)
  end

  # GoBGP's node descriptor, 512 then 516 then 513 (docs/bgp-ls.md
  # section 11), reads 516 as a class now and still replays.
  def test_516_in_a_node_descriptor_reads_as_a_class_and_replays
    hex = '0100001c' + '0200000400000064' + '020400040a000001' +
          '0201000400000000'
    t = read(hex)
    assert_equal(T::Local_node_descriptors, t.class)
    assert_equal(hex, t.to_shex)
    assert_equal([T::Autonomous_system, T::Bgp_router_id, T::Bgp_ls_identifier],
                 t.sub_tlvs.collect(&:class))
    assert(!t.ordered?, 'GoBGP sends them out of order, reported only')
  end

  # "non-zero" binds the sender, so zero builds and parses.
  def test_a_zero_bgp_router_id_builds_and_parses
    t = read('0204000400000000')
    assert_equal(T::Bgp_router_id, t.class)
    assert_equal('0.0.0.0', t.router_id)
  end

  # --- RFC 9085 section 2.1.1, SID/Label 1161 --------------------------

  def test_the_sid_label_tlv_as_a_label
    t = T::Sid_label.new(16000)
    # 0489 type, 0003 length, 003e80 = 16000.
    assert_equal('04890003003e80', t.to_shex)
    assert(t.label?)
    assert_equal(16000, t.label)
    assert_nil(t.index)
    assert_equal('SID/Label label 16000', t.to_s)
    assert_equal({ :sid_label => { :label => 16000 } }, t.to_hash)
    assert_equal(t.to_shex, T::Sid_label.new(t.to_hash).to_shex)
    assert_four_ways(t)
  end

  def test_the_sid_label_tlv_as_an_index
    t = T::Sid_label.new(5, 4)
    assert_equal('0489000400000005', t.to_shex)
    assert(!t.label?)
    assert_equal(5, t.index)
    assert_equal({ :sid_label => { :index => 5 } }, t.to_hash)
    assert_four_ways(t)
  end

  # "the 4 leftmost bits are set to 0". Set, they are kept, written
  # back, and answered by a reader. Nothing reports them.
  def test_a_label_with_its_high_bits_set_replays
    t = read('04890003f03e80')
    assert_equal(T::Sid_label, t.class)
    assert_equal(16000, t.label)
    assert_equal(0xf, t.label_high_bits)
    assert_equal(0xf03e80, t.sid)
    assert_equal('04890003f03e80', t.to_shex)
    assert_four_ways(t)
  end

  def test_a_sid_label_of_another_width_is_unknown
    %w[048900020001 04890005000000000a].each do |hex|
      t = read(hex)
      assert_equal(T::Unknown, t.class, hex)
      assert_equal(hex, t.to_shex)
    end
  end

  # The one refusal Conventions allows: a value the field cannot hold.
  def test_a_value_the_field_cannot_hold_is_refused
    assert_raise(ArgumentError) { T::Sid_label.new(0x1000000) }
    assert_raise(ArgumentError) { T::Sid_label.new(1, 5) }
    assert_raise(ArgumentError) { T::Adjacency_sid.new(0x100, 0, 1) }
    assert_raise(ArgumentError) { T::Sr_capabilities.new(0, [[0x1000000, 16000]]) }
    # But a label of 20 bits and more fits the 24-bit field, and builds.
    assert_equal('04890003ffffff', T::Sid_label.new(0xffffff).to_shex)
  end

  # --- RFC 9085 sections 2.1.2 and 2.1.4, 1034 and 1036 ----------------

  def test_the_sr_capabilities_tlv
    t = T::Sr_capabilities.new(0xc0, [[8000, 16000]])
    # 040a type, 000c length (the minimum, 12), c0 flags I and V,
    # 00 reserved, 001f40 range size 8000, then the 1161 sub-TLV.
    assert_equal('040a000c' + 'c000' + '001f40' + '04890003003e80', t.to_shex)
    assert_equal(0xc0, t.flags)
    assert_equal(1, t.ranges.size)
    assert_equal(8000, t.ranges[0][0])
    assert_equal(16000, t.ranges[0][1].label)
    assert(t.labels?)
    assert(!t.reserved?)
    assert_equal('SR Capabilities flags 0xc0, range 8000 from label 16000', t.to_s)
    assert_equal({ :sr_capabilities => {
                     :flags => 0xc0,
                     :ranges => [{ :size => 8000,
                                   :sid_label => { :label => 16000 } }] } },
                 t.to_hash)
    assert_equal(t.to_shex, T::Sr_capabilities.new(t.to_hash).to_shex)
    assert_four_ways(t)
  end

  def test_the_sr_local_block_tlv_with_two_ranges
    t = T::Sr_local_block.new(0, [[1000, 15000], [100, T::Sid_label.new(15500)]])
    # 040c type, 0016 length = 2 + 2 * (3 + 7) = 22.
    assert_equal('040c0016' + '0000' + '0003e8' + '04890003003a98' +
                 '000064' + '04890003003c8c', t.to_shex)
    assert_equal([1000, 100], t.ranges.collect(&:first))
    assert_equal({ :sr_local_block => {
                     :flags => 0,
                     :ranges => [{ :size => 1000, :sid_label => { :label => 15000 } },
                                 { :size => 100, :sid_label => { :label => 15500 } }] } },
                 t.to_hash)
    assert_equal(t.to_shex, T::Sr_local_block.new(t.to_hash).to_shex)
    assert_four_ways(t)
  end

  # Negative cases. None of them is refused or reported as an error:
  # each builds, parses as its class, and replays byte for byte.
  def test_a_nonzero_reserved_octet_is_kept_and_answered
    hex = '040a000c' + 'c0ff' + '001f40' + '04890003003e80'
    t = read(hex)
    assert_equal(T::Sr_capabilities, t.class)
    assert(t.reserved?)
    assert_equal(0xff, t.reserved)
    assert_equal(0xff, t.to_hash[:sr_capabilities][:reserved])
    assert_equal(hex, t.to_shex)
    assert_four_ways(t)
  end

  # "only label encoding is valid under the SR Capabilities TLV". An
  # index there is the consumer's to judge.
  def test_an_index_under_sr_capabilities_is_answered_not_refused
    t = T::Sr_capabilities.new(0, [[8000, T::Sid_label.new(16000, 4)]])
    assert_equal('040a000d' + '0000' + '001f40' + '0489000400003e80', t.to_shex)
    assert(!t.labels?)
    assert_four_ways(t)
  end

  # A sub-TLV Length that lies is kept, so the capture replays. The
  # validation side reports it (validation_test.rb).
  def test_a_sub_tlv_length_that_lies_is_kept
    hex = '040a000c' + 'c000' + '001f40' + '04890009003e80'
    t = read(hex)
    assert_equal(T::Sr_capabilities, t.class)
    assert_equal(9, t.ranges[0][1].declared_len)
    assert_equal(hex, t.to_shex)
    assert_equal(9, t.to_hash[:sr_capabilities][:ranges][0][:length])
    assert_four_ways(t)
  end

  # Another TLV in the sub-TLV's place is kept as what it is.
  def test_an_unknown_sub_tlv_is_kept
    hex = '040a000c' + '0000' + '000001' + 'fde80003010203'
    t = read(hex)
    assert_equal(T::Sr_capabilities, t.class)
    assert_equal(T::Unknown, t.ranges[0][1].class)
    assert(!t.labels?)
    assert_equal(hex, t.to_shex)
    assert_four_ways(t)
  end

  # Below the 12-octet minimum, and with no range at all: built, sent,
  # read back as the class.
  def test_building_never_validates_a_range_tlv
    t = T::Sr_capabilities.new(0)
    assert_equal('040a00020000', t.to_shex)
    assert_equal(T::Sr_capabilities, read(t.to_shex).class)
    assert_four_ways(t)
  end

  # Octets that cannot make one more range: the whole value is kept as
  # an Unknown, so nothing is lost.
  def test_a_range_tlv_with_trailing_octets_is_unknown
    ['040a0001c0',
     '040a000e' + 'c000' + '001f40' + '04890003003e80' + 'abcd'].each do |hex|
      t = read(hex)
      assert_equal(T::Unknown, t.class, hex)
      assert_equal(hex, t.to_shex)
    end
  end

  # --- RFC 9085 section 2.1.3, SR Algorithm 1035 ------------------------

  def test_the_sr_algorithm_tlv
    t = T::Sr_algorithm.new(0, 1)
    assert_equal('040b0002' + '0001', t.to_shex)
    assert_equal([0, 1], t.values)
    assert_equal('SR Algorithms 0,1', t.to_s)
    assert_equal({ :sr_algorithm => [0, 1] }, t.to_hash)
    assert_equal(t.to_shex, T::Sr_algorithm.new(t.to_hash).to_shex)
    assert_four_ways(t)
  end

  # "The minimum length is 1 octet and the maximum can be 256." Not
  # checked: none and 300 both build and read back.
  def test_the_sr_algorithm_lengths_are_not_checked
    [[], [0] * 300].each do |list|
      t = T::Sr_algorithm.new(list)
      assert_equal(T::Sr_algorithm, read(t.to_shex).class)
      assert_equal(list.size, read(t.to_shex).values.size)
    end
  end

  # --- RFC 9085 section 2.2.1, Adjacency SID 1099 -----------------------

  def test_the_adjacency_sid_tlv
    t = T::Adjacency_sid.new(0x30, 10, 24001)
    # 044b type, 0007 length, 30 flags (IS-IS V and L), 0a weight,
    # 0000 reserved, 005dc1 = 24001.
    assert_equal('044b0007' + '300a0000' + '005dc1', t.to_shex)
    assert_equal(0x30, t.flags)
    assert_equal(10, t.weight)
    assert_equal(24001, t.label)
    assert_equal('Adjacency SID flags 0x30 weight 10 label 24001', t.to_s)
    assert_equal({ :adjacency_sid => { :flags => 0x30, :weight => 10,
                                       :label => 24001 } }, t.to_hash)
    assert_equal(t.to_shex, T::Adjacency_sid.new(t.to_hash).to_shex)
    assert_four_ways(t)
  end

  def test_the_adjacency_sid_tlv_as_an_index
    t = T::Adjacency_sid.new(0, 0, 9, 4)
    assert_equal('044b0008' + '00000000' + '00000009', t.to_shex)
    assert_equal(9, t.index)
    assert_four_ways(t)
  end

  def test_an_adjacency_sid_with_reserved_set_replays
    hex = '044b0007' + '3000abcd' + '005dc1'
    t = read(hex)
    assert_equal(T::Adjacency_sid, t.class)
    assert(t.reserved?)
    assert_equal(0xabcd, t.to_hash[:adjacency_sid][:reserved])
    assert_equal('Adjacency SID flags 0x30 weight 0 reserved 0xabcd label 24001',
                 t.to_s)
    assert_equal(hex, t.to_shex)
    assert_four_ways(t)
  end

  # 7 or 8. Any other width is an Unknown, and replays.
  def test_an_adjacency_sid_of_another_width_is_unknown
    %w[044b0006300000000001 044b0009300000000000000001 044b0000].each do |hex|
      t = read(hex)
      assert_equal(T::Unknown, t.class, hex)
      assert_equal(hex, t.to_shex)
    end
  end

  # --- RFC 9085 section 2.2.2, LAN Adjacency SID 1100 -------------------

  def test_the_lan_adjacency_sid_tlv_for_is_is
    t = T::Lan_adjacency_sid.new(0x30, 0, '0000.0000.0002', 24002)
    # 044c type, 000d = 13, IS-IS with a label: 4 + 6 + 3.
    assert_equal('044c000d' + '30000000' + '000000000002' + '005dc2', t.to_shex)
    assert(t.system_id?)
    assert_equal('0000.0000.0002', t.neighbor)
    assert_equal('LAN Adjacency SID flags 0x30 weight 0 neighbor 0000.0000.0002 label 24002',
                 t.to_s)
    assert_equal({ :lan_adjacency_sid => { :flags => 0x30, :weight => 0,
                                           :neighbor => '0000.0000.0002',
                                           :label => 24002 } }, t.to_hash)
    assert_equal(t.to_shex, T::Lan_adjacency_sid.new(t.to_hash).to_shex)
    assert_four_ways(t)
  end

  # The four lengths section 2.2.2 gives, and what each one means.
  def test_each_lan_adjacency_sid_length_has_one_reading
    { 11 => ['10.0.0.2', 7, 3],
      12 => ['10.0.0.2', 7, 4],
      13 => ['0000.0000.0002', 7, 3],
      14 => ['0000.0000.0002', 7, 4] }.each do |len, (nbr, sid, w)|
      t = T::Lan_adjacency_sid.new(0, 0, nbr, sid, w)
      assert_equal(len, t.encode_value.size)
      back = read(t.to_shex)
      assert_equal(T::Lan_adjacency_sid, back.class, len.to_s)
      assert_equal(nbr, back.neighbor)
      assert_equal(w == 3, back.label?)
      assert_four_ways(t)
    end
  end

  def test_a_lan_adjacency_sid_of_another_width_is_unknown
    ['044c000a' + '00' * 10, '044c000f' + '00' * 15].each do |hex|
      assert_equal(T::Unknown, read(hex).class, hex)
      assert_equal(hex, read(hex).to_shex)
    end
  end

  def test_a_lan_neighbor_that_is_neither_form_is_refused
    assert_raise(ArgumentError) { T::Lan_adjacency_sid.new(0, 0, '2001:db8::1', 1) }
  end

  # --- RFC 9085 section 2.3.1, Prefix-SID 1158 --------------------------

  def test_the_prefix_sid_tlv
    t = T::Prefix_sid.new(0x40, 0, 5, 4)
    # 0486 type, 0008 length, 40 flags (IS-IS N), 00 algorithm,
    # 0000 reserved, 00000005 index.
    assert_equal('04860008' + '40000000' + '00000005', t.to_shex)
    assert_equal(0, t.algorithm)
    assert_equal(5, t.index)
    assert_equal('Prefix-SID flags 0x40 algorithm 0 index 5', t.to_s)
    assert_equal({ :prefix_sid => { :flags => 0x40, :algorithm => 0,
                                    :index => 5 } }, t.to_hash)
    assert_equal(t.to_shex, T::Prefix_sid.new(t.to_hash).to_shex)
    assert_four_ways(t)
  end

  def test_the_prefix_sid_tlv_as_a_label
    t = T::Prefix_sid.new(0x0c, 1, 16005)
    assert_equal('04860007' + '0c010000' + '003e85', t.to_shex)
    assert_equal(16005, t.label)
    assert_four_ways(t)
  end

  # --- RFC 9086 section 5, the three Peering SIDs ----------------------

  def test_the_peer_node_sid_tlv
    t = T::Peer_node_sid.new(0xc0, 1, 24000)
    # 044d type, 0007 length, c0 flags V and L, 01 weight, 0000
    # reserved, 005dc0 = 24000.
    assert_equal('044d0007' + 'c0010000' + '005dc0', t.to_shex)
    assert(t.value? && t.local?)
    assert(!t.backup? && !t.persistent?)
    assert_equal([:value, :local], t.names)
    assert_equal(1, t.weight)
    assert_equal('PeerNode SID flags 0xc0 weight 1 label 24000', t.to_s)
    assert_equal({ :peer_node_sid => { :flags => 0xc0, :weight => 1,
                                       :label => 24000 } }, t.to_hash)
    assert_equal(t.to_shex, T::Peer_node_sid.new(t.to_hash).to_shex)
    assert_four_ways(t)
  end

  def test_the_peer_adj_and_peer_set_sid_tlvs
    a = T::Peer_adj_sid.new(0xf0, 2, 24010)
    assert_equal('044e0007' + 'f0020000' + '005dca', a.to_shex)
    assert_equal([:value, :local, :backup, :persistent], a.names)
    assert_equal(a.to_shex, T::Peer_adj_sid.new(a.to_hash).to_shex)
    assert_four_ways(a)
    s = T::Peer_set_sid.new(0, 3, 9, 4)
    assert_equal('044f0008' + '00030000' + '00000009', s.to_shex)
    assert_equal(s.to_shex, T::Peer_set_sid.new(s.to_hash).to_shex)
    assert_four_ways(s)
  end

  # "Rsvd bits ... MUST be zero when originated and ignored when
  # received": kept and answered.
  def test_the_peer_sid_reserved_flag_bits_are_kept
    t = read('044d0007' + 'cf000000' + '005dc0')
    assert_equal(T::Peer_node_sid, t.class)
    assert_equal(0x0f, t.undefined_bits)
    assert_equal('044d0007cf000000005dc0', t.to_shex)
  end

  # "In this case, the V- and L-Flags MUST be SET" for a label. A label
  # with V clear builds and reads back: the consumer judges it.
  def test_a_peer_sid_label_with_v_clear_builds
    t = T::Peer_node_sid.new(0, 0, 24000)
    assert_equal(T::Peer_node_sid, read(t.to_shex).class)
    assert(!read(t.to_shex).value?)
  end

  # --- in the BGP-LS Attribute ------------------------------------------

  # Every SR TLV in one attribute, through the path attribute reader
  # with the strict policy: no protocol error and no coverage gap.
  def test_every_sr_tlv_reads_back_out_of_a_bgp_ls_attribute
    tlvs = [T::Sr_capabilities.new(0xc0, [[8000, 16000]]),
            T::Sr_algorithm.new(0, 1),
            T::Sr_local_block.new(0, [[1000, 15000]]),
            T::Adjacency_sid.new(0x30, 0, 24001),
            T::Lan_adjacency_sid.new(0x30, 0, '0000.0000.0002', 24002),
            T::Peer_node_sid.new(0xc0, 0, 24000),
            T::Peer_adj_sid.new(0xc0, 0, 24003),
            T::Peer_set_sid.new(0xc0, 0, 24004),
            T::Prefix_sid.new(0x40, 0, 5, 4)]
    a = BGP::Link_state_attribute.new(*tlvs)
    pa = BGP::Path_attribute.new(a.encode.is_packed, :policy => :strict)
    assert_equal([], pa.errors)
    assert_equal([], pa.undecoded)
    back = pa[BGP::ATTR::BGP_LS]
    assert_equal(tlvs.collect(&:class), back.tlvs.collect(&:class))
    assert_equal(a.to_shex, back.to_shex)
  end

  # Semantic faults are not errors (RFC 9552 section 8.2.2, RFC 9085
  # section 4): Reserved set, an off-width SID, an index in an SRGB.
  # The strict policy does not raise.
  def test_semantic_faults_are_not_protocol_errors
    hex = '044b0007' + '3000ffff' + '005dc1' +        # Reserved set
          '044b0009' + '300000000000000001' +         # 9 octets
          '040a000d' + '0000' + '001f40' + '0489000400003e80' # an index
    v = wire(hex)
    attr = wire('801d' + format('%02x', v.size) + hex)
    pa = BGP::Path_attribute.new(attr.dup.is_packed, :policy => :strict)
    assert_equal([], pa.errors)
    assert_equal(attr.unpack1('H*'), pa.encode.unpack1('H*'))
    classes = pa[BGP::ATTR::BGP_LS].tlvs.collect(&:class)
    assert_equal([T::Adjacency_sid, T::Unknown, T::Sr_capabilities], classes)
  end

  # A sub-TLV Length that runs past its 1034 is a syntactic error, so
  # the strict policy raises, and the lenient one keeps the octets.
  def test_a_sub_tlv_that_overruns_is_an_error_and_still_replays
    hex = '040a000c' + 'c000' + '001f40' + '04890009003e80'
    attr = wire('801d10' + hex)
    pa = BGP::Path_attribute.new(attr.dup.is_packed)
    assert_equal([:attribute_discard], pa.errors.collect(&:action))
    assert_equal('801d10' + hex, pa.encode.unpack1('H*'))
    assert_raise(BGP::Malformed_attribute) do
      BGP::Path_attribute.new(attr.dup.is_packed, :policy => :strict)
    end
  end

end
