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
require 'bgp/nlris/link_state_link_descriptor'

# **The widths here are three other RFCs', not RFC 9552's**, because
# Table 4 has no Length column where Table 5 does. Each was fetched on
# 2026-11-01 and is quoted in the class it belongs to: RFC 5307 section
# 1.1 for 258, RFC 5305 sections 3.2 and 3.3 for 259 and 260, and RFC
# 6119 sections 4.2 and 4.3 for 261 and 262. The hex below is still
# this reader's arithmetic from those widths, since none of the four
# documents carries a BGP-LS example.
class TestLinkStateLinkDescriptor < Test::Unit::TestCase

  include BGP

  # --- the four address TLVs, Table 4 ---------------------------------
  #
  # Type 259 is 0x0103, 260 is 0x0104, 261 is 0x0105 and 262 is 0x0106.

  def test_the_two_ipv4_address_tlvs_are_four_octets
    i = BGP::Link_state::Tlv::Ipv4_interface_address.new('10.0.0.1')
    n = BGP::Link_state::Tlv::Ipv4_neighbor_address.new('10.0.0.2')
    assert_equal(259, i.type)
    assert_equal(260, n.type)
    assert_equal('01030004' + '0a000001', i.to_shex)
    assert_equal('01040004' + '0a000002', n.to_shex)
    assert_equal('IPv4 interface 10.0.0.1', i.to_s)
    assert_equal('IPv4 neighbor 10.0.0.2', n.to_s)
  end

  def test_the_two_ipv6_address_tlvs_are_sixteen_octets
    i = BGP::Link_state::Tlv::Ipv6_interface_address.new('2001:db8::1')
    n = BGP::Link_state::Tlv::Ipv6_neighbor_address.new('2001:db8::2')
    assert_equal(261, i.type)
    assert_equal(262, n.type)
    assert_equal('01050010' + '20010db8' + '00000000' * 2 + '00000001',
                 i.to_shex)
    assert_equal('01060010' + '20010db8' + '00000000' * 2 + '00000002',
                 n.to_shex)
    assert_equal(20, i.size)
  end

  def test_each_address_tlv_parses_back
    { '010300040a000001' =>
        [BGP::Link_state::Tlv::Ipv4_interface_address, '10.0.0.1'],
      '010400040a000002' =>
        [BGP::Link_state::Tlv::Ipv4_neighbor_address, '10.0.0.2'],
      '0105001020010db8000000000000000000000001' =>
        [BGP::Link_state::Tlv::Ipv6_interface_address, '2001:db8::1'],
      '0106001020010db8000000000000000000000002' =>
        [BGP::Link_state::Tlv::Ipv6_neighbor_address, '2001:db8::2'],
    }.each do |hex, (klass, addr)|
      t = BGP::Link_state::Tlv.factory([hex].pack('H*').is_packed)
      assert_equal(klass, t.class, hex)
      assert_equal(addr, t.address.to_s, hex)
      assert_equal(hex, t.to_shex)
    end
  end

  # The width is the class's, so a value of any other width cannot be
  # one of these and `Tlv.factory` keeps the octets whole. That is
  # part 1's encode-matches rule, and here it is what stops a 4-octet
  # value from reading back as an IPv6 address.
  def test_an_address_tlv_of_the_wrong_width_falls_back
    ['010300100a000001' + '00' * 12, '010500040a000001',
     '01030002abcd'].each do |hex|
      t = BGP::Link_state::Tlv.factory([hex].pack('H*').is_packed)
      assert_equal(BGP::Link_state::Tlv::Unknown, t.class, hex)
      assert_equal(hex, t.to_shex)
    end
  end

  # RFC 9552 section 5.2.2 and RFC 6119 sections 4.2 and 4.3 both
  # forbid a link-local address here: "IPv4/IPv6 link-local addresses
  # MUST NOT be carried in the IPv4/IPv6 interface/neighbor address
  # TLVs (259/260/261/262) as descriptors of a link since they are not
  # considered unique." Nothing refuses one, because building never
  # validates and a test has to be able to send what a router should
  # not; it is a part 6 candidate.
  def test_a_link_local_address_builds_anyway
    assert_equal('01050010fe80' + '00' * 13 + '01',
                 BGP::Link_state::Tlv::Ipv6_interface_address.new(
                   'fe80::1').to_shex)
    assert_equal('01030004a9fe0001',
                 BGP::Link_state::Tlv::Ipv4_interface_address.new(
                   '169.254.0.1').to_shex)
  end

  # --- TLV 258, the only one of the six with a stated total -----------

  # RFC 5307 section 1.1: "The type of this sub-TLV is 4, and the
  # length is 8 octets", and "The value field of this sub-TLV contains
  # 4 octets of Link Local Identifier followed by 4 octets of Link
  # Remote Identifier."
  def test_the_link_identifiers_tlv_is_two_four_octet_fields
    t = BGP::Link_state::Tlv::Link_local_remote_identifiers.new(1, 2)
    assert_equal(258, t.type)
    assert_equal(8, t.length)
    assert_equal('01020008' + '00000001' + '00000002', t.to_shex)
    assert_equal(1, t.local)
    assert_equal(2, t.remote)
  end

  def test_the_two_identifier_fields_are_in_that_order
    t = BGP::Link_state::Tlv.factory(
      ['01020008' + 'deadbeef' + 'cafebabe'].pack('H*').is_packed)
    assert_equal(0xdeadbeef, t.local)
    assert_equal(0xcafebabe, t.remote)
  end

  # Section 1.1 again: "If the Link Remote Identifier is unknown, it is
  # set to 0." So a zero remote is a statement and not a missing field,
  # which is why `remote` answers 0 and `to_s` says so.
  def test_a_zero_remote_identifier_means_unknown
    t = BGP::Link_state::Tlv::Link_local_remote_identifiers.new(7)
    assert_equal(0, t.remote)
    assert_equal('Link IDs local 7 remote unknown', t.to_s)
    assert_equal('01020008' + '00000007' + '00000000', t.to_shex)
  end

  # --- TLV 263, section 5.2.2.1 ---------------------------------------

  # "The Type is 263, the length is 2*n, and n is the number of MT-IDs
  # carried in the TLV." Type 263 is 0x0107.
  def test_the_mt_id_tlv_is_two_octets_per_identifier
    assert_equal('01070002' + '0002',
                 BGP::Link_state::Tlv::Multi_topology_id.new(2).to_shex)
    assert_equal('01070006' + '0000' + '0002' + '0003',
                 BGP::Link_state::Tlv::Multi_topology_id.new(
                   0, 2, 3).to_shex)
    assert_equal(263, BGP::Link_state::Tlv::Multi_topology_id.new(2).type)
  end

  def test_the_mt_id_tlv_parses_its_identifiers_back
    t = BGP::Link_state::Tlv.factory(
      ['01070004' + '0002' + '0003'].pack('H*').is_packed)
    assert_equal(BGP::Link_state::Tlv::Multi_topology_id, t.class)
    assert_equal([2, 3], t.ids)
    assert_equal('01070004' + '00020003', t.to_shex)
  end

  # Figure 12 gives four R bits then twelve of identifier, so the
  # widest identifier is 0x0fff and the R nibble is the top four bits.
  def test_the_identifier_is_twelve_bits_and_r_is_four
    assert_equal(0x0fff, BGP::Link_state::Tlv::Multi_topology_id::ID_MASK)
    assert_equal(0xf000, BGP::Link_state::Tlv::Multi_topology_id::R_MASK)
    t = BGP::Link_state::Tlv::Multi_topology_id.new(0x0fff)
    assert_equal([0x0fff], t.ids)
    assert_equal([0], t.reserved)
    assert_equal('010700020fff', t.to_shex)
  end

  # **The keep-and-echo rule arrives here**, since this is the first
  # BGP-LS TLV with a reserved field. Section 5.2.2.1: "When used as a
  # Link or Prefix Descriptor for IS-IS, the Bits R are reserved and
  # MUST be set to 0 ... when originated and ignored on receipt."
  # Ignored is not a licence to drop: the words are kept whole and
  # encode replays them.
  def test_reserved_bits_that_arrived_set_are_kept_and_echoed
    hex = '01070004' + '6002' + '2003'
    t = BGP::Link_state::Tlv.factory([hex].pack('H*').is_packed)
    assert_equal([2, 3], t.ids)
    assert_equal([6, 2], t.reserved)
    assert(t.reserved_set?)
    assert_equal(hex, t.to_shex)
    assert_equal('MT-ID 2, 3 (R 6, 2)', t.to_s)
  end

  # No reserved bit set, no second shape, so an ordinary MT-ID TLV
  # hashes as the plain list it has always been. Same rule as `:tail`
  # and `:bits` elsewhere in the library.
  def test_the_hash_is_the_plain_list_until_a_reserved_bit_arrives
    assert_equal({ :multi_topology_id => [2, 3] },
                 BGP::Link_state::Tlv::Multi_topology_id.new(2, 3).to_hash)
    t = BGP::Link_state::Tlv.factory(
      ['010700026002'].pack('H*').is_packed)
    assert_equal({ :multi_topology_id => { :words => [0x6002] } },
                 t.to_hash)
    assert_equal(t.to_shex,
                 BGP::Link_state::Tlv::Multi_topology_id.new(
                   t.to_hash).to_shex)
  end

  # A build from field values writes the R bits as zero, which is what
  # the section asks an originator for, so asking for 0x6002 as an
  # identifier is a value no RFC allows and still encodes.
  def test_a_word_built_whole_keeps_its_reserved_bits
    t = BGP::Link_state::Tlv::Multi_topology_id.new(0x6002)
    assert_equal([2], t.ids)
    assert_equal([6], t.reserved)
    assert_equal('010700026002', t.to_shex)
  end

  # An odd trailing octet cannot be a 16-bit word, so the value does
  # not reproduce itself and the octets are kept whole: a length of
  # 2*n+1 is a value section 5.2.2.1 does not describe.
  def test_an_odd_length_mt_id_tlv_falls_back_and_replays
    hex = '01070003' + '000201'
    t = BGP::Link_state::Tlv.factory([hex].pack('H*').is_packed)
    assert_equal(BGP::Link_state::Tlv::Unknown, t.class)
    assert_equal(hex, t.to_shex)
  end

  def test_an_empty_mt_id_tlv_builds
    t = BGP::Link_state::Tlv::Multi_topology_id.new
    assert_equal('01070000', t.to_shex)
    assert_equal([], t.ids)
    assert_equal(false, t.reserved_set?)
  end

  # --- the registry ----------------------------------------------------

  def test_every_class_here_is_in_the_one_registry
    { 258 => BGP::Link_state::Tlv::Link_local_remote_identifiers,
      259 => BGP::Link_state::Tlv::Ipv4_interface_address,
      260 => BGP::Link_state::Tlv::Ipv4_neighbor_address,
      261 => BGP::Link_state::Tlv::Ipv6_interface_address,
      262 => BGP::Link_state::Tlv::Ipv6_neighbor_address,
      263 => BGP::Link_state::Tlv::Multi_topology_id }.each do |t, k|
      assert_equal(k, BGP::Link_state::Tlv::REGISTRY[t],
                   "type #{t} must be registered as #{k}")
      assert_equal(k, BGP::Link_state::Tlv::BY_KEY[k.hash_key],
                   "#{k} must be reachable by its hash key")
    end
  end

  # --- the repetition these four allow --------------------------------

  # **Four of Table 4's six can repeat in one NLRI**, which is what
  # the three cited RFCs say of the IS-IS sub-TLVs they correspond to:
  # "This sub-TLV can occur multiple times", for 259, 260 and 261, and
  # each BGP-LS TLV value is one address. That is what section 5.1's
  # Length and Value tiebreakers are for, and it confirms part 2's
  # reading from the other side: a Node Descriptor needs no
  # tiebreakers because its once-only rule makes a repeat impossible,
  # and a Link Descriptor has no such rule.
  def test_two_of_one_address_type_are_ordered_by_value
    a = BGP::Link_state::Tlv::Ipv4_interface_address.new('10.0.0.1')
    b = BGP::Link_state::Tlv::Ipv4_interface_address.new('10.0.0.2')
    assert(BGP::Link_state::Tlv.ordered?([a, b]),
           'two of one type and one length sort by value, which is the ' \
           'third level of the section 5.1 rule')
    assert_equal(false, BGP::Link_state::Tlv.ordered?([b, a]))
  end

  # --- to_hash ---------------------------------------------------------

  # The two-places rule in Conventions: a working round trip is
  # asserted here and in test/unit/to_hash_catalog.rb.
  def test_every_class_here_rebuilds_from_its_own_hash
    [BGP::Link_state::Tlv::Ipv4_interface_address.new('10.0.0.1'),
     BGP::Link_state::Tlv::Ipv4_neighbor_address.new('10.0.0.2'),
     BGP::Link_state::Tlv::Ipv6_interface_address.new('2001:db8::1'),
     BGP::Link_state::Tlv::Ipv6_neighbor_address.new('2001:db8::2'),
     BGP::Link_state::Tlv::Link_local_remote_identifiers.new(7, 9),
     BGP::Link_state::Tlv::Multi_topology_id.new(2, 3),
     BGP::Link_state::Tlv::Multi_topology_id.new(0x6002)].each do |t|
      assert_equal(t.to_shex, t.class.new(t.to_hash).to_shex,
                   "#{t.class} must rebuild from its own hash")
      assert_equal(t.to_shex,
                   BGP::Link_state::Tlv.from_hash(t.to_hash).to_shex,
                   "#{t.class} must rebuild through the registry too")
    end
  end

  def test_a_declared_length_survives_the_hash
    hex = '0103270f' + '0a000001'
    t = BGP::Link_state::Tlv.factory([hex].pack('H*').is_packed)
    assert_equal(9999, t.declared_len)
    assert_equal(9999, t.to_hash[:length])
    assert_equal(hex,
                 BGP::Link_state::Tlv::Ipv4_interface_address.new(
                   t.to_hash).to_shex)
  end

  # --- the four build paths -------------------------------------------

  def test_every_class_here_builds_from_another_instance
    [BGP::Link_state::Tlv::Ipv4_interface_address.new('10.0.0.1'),
     BGP::Link_state::Tlv::Link_local_remote_identifiers.new(1, 2),
     BGP::Link_state::Tlv::Multi_topology_id.new(2, 3)].each do |t|
      assert_equal(t.to_shex, t.class.new(t).to_shex, "#{t.class}")
    end
    m = BGP::Link_state::Tlv::Multi_topology_id.new(2, 3)
    BGP::Link_state::Tlv::Multi_topology_id.new(m)
    assert_equal([2, 3], m.ids, 'copying must not empty the original')
  end

  def test_an_ipaddr_builds_an_address_tlv_too
    require 'ipaddr'
    assert_equal('010300040a000001',
                 BGP::Link_state::Tlv::Ipv4_interface_address.new(
                   IPAddr.new('10.0.0.1')).to_shex)
  end

  def test_the_empty_form_is_the_all_zeroes_address
    assert_equal('01030004' + '00000000',
                 BGP::Link_state::Tlv::Ipv4_interface_address.new.to_shex)
    assert_equal('01050010' + '00' * 16,
                 BGP::Link_state::Tlv::Ipv6_interface_address.new.to_shex)
  end

  def test_a_class_here_refuses_an_argument_it_cannot_read
    assert_raise(ArgumentError) do
      BGP::Link_state::Tlv::Ipv4_interface_address.new(1, 2)
    end
    assert_raise(ArgumentError) do
      BGP::Link_state::Tlv::Link_local_remote_identifiers.new(1, 2, 3)
    end
  end

  # --- nothing validates ----------------------------------------------

  # Five things no RFC allows, each building and encoding.
  def test_nothing_validates
    # An IPv6 address in the IPv4 interface address TLV, which a
    # 4-octet field cannot represent, so the typed class refuses it and
    # names the octet level route. That is the one kind of refusal
    # Conventions allows, and the route it names has to work.
    assert_raise(ArgumentError) do
      BGP::Link_state::Tlv::Ipv4_interface_address.new('2001:db8::1')
    end
    sixteen = IPAddr.new('2001:db8::1').hton
    t = BGP::Link_state::Tlv::Unknown.new(259, sixteen)
    assert_equal('01030010' + '20010db8' + '00000000' * 2 + '00000001',
                 t.to_shex)
    assert_equal(BGP::Link_state::Tlv::Unknown,
                 BGP::Link_state::Tlv.factory(
                   [t.to_shex].pack('H*').is_packed).class,
                 'and it reads back as octets rather than as an address')
    # A link-local address, which section 5.2.2 forbids outright.
    assert_equal('01060010fe80' + '00' * 13 + '01',
                 BGP::Link_state::Tlv::Ipv6_neighbor_address.new(
                   'fe80::1').to_shex)
    # R bits set in an MT-ID used as a descriptor, where section
    # 5.2.2.1 says they MUST be 0 when originated.
    assert_equal('01070002f000',
                 BGP::Link_state::Tlv::Multi_topology_id.new(
                   0xf000).to_shex)
    # Several MT-IDs in one descriptor, where section 5.2.2.1 allows
    # "only a single MT-ID TLV containing the MT-ID of the topology
    # where the link or the prefix is reachable".
    assert_equal(3,
                 BGP::Link_state::Tlv::Multi_topology_id.new(
                   1, 2, 3).ids.size)
    # A local identifier of 0, which RFC 5307 section 1.1 describes
    # for the remote one only.
    assert_equal('01020008' + '00000000' + '00000005',
                 BGP::Link_state::Tlv::Link_local_remote_identifiers.new(
                   0, 5).to_shex)
  end

end
