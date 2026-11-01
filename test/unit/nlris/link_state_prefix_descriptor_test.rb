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
require 'bgp/nlris/link_state_prefix_descriptor'

# **These two widths are RFC 9552's own**, unlike the link descriptors:
# Table 5 has a Length column where Table 4 does not, giving 1 for the
# OSPF Route Type and variable for the IP Reachability Information. The
# hex is still this reader's arithmetic, since the RFC carries no
# example.
class TestLinkStatePrefixDescriptor < Test::Unit::TestCase

  include BGP

  # --- TLV 264, section 5.2.3.1 ---------------------------------------
  #
  # Type 264 is 0x0108, and Table 5 gives the length as 1.

  # The six the section names, in its own words and its own order:
  # "Intra-Area (0x1), Inter-Area (0x2), External 1 (0x3), External 2
  # (0x4), NSSA 1 (0x5), NSSA 2 (0x6)".
  def test_the_six_route_types_the_section_names
    { 1 => 'Intra-Area', 2 => 'Inter-Area', 3 => 'External 1',
      4 => 'External 2', 5 => 'NSSA 1',
      6 => 'NSSA 2' }.each do |v, name|
      t = BGP::Link_state::Tlv::Ospf_route_type.new(v)
      assert_equal(264, t.type)
      assert_equal(format('01080001%02x', v), t.to_shex)
      assert_equal(name, t.name, "route type #{v}")
      assert_equal("OSPF route type #{name}", t.to_s)
    end
  end

  def test_a_route_type_can_be_named_rather_than_numbered
    assert_equal(1, BGP::Link_state::Tlv::Ospf_route_type.new(
      'Intra-Area').route_type)
    assert_equal(6, BGP::Link_state::Tlv::Ospf_route_type.new(
      'nssa 2').route_type)
    assert_raise(ArgumentError) do
      BGP::Link_state::Tlv::Ospf_route_type.new('Intra-Galactic')
    end
  end

  # The section names six values and no range, so 0 and 7 to 255 are
  # values it does not describe. They build, parse and print as the
  # number: an unnamed value is not an error this document names.
  def test_a_value_the_section_does_not_name_prints_as_its_number
    [0, 7, 255].each do |v|
      t = BGP::Link_state::Tlv.factory(
        [format('01080001%02x', v)].pack('H*').is_packed)
      assert_equal(BGP::Link_state::Tlv::Ospf_route_type, t.class)
      assert_equal(v.to_s, t.name, "route type #{v}")
      assert_equal(format('01080001%02x', v), t.to_shex)
    end
  end

  # Route type 0 is one a peer can really send: section 5.2.3.1 says
  # "the route type value 0" may be carried in the OSPFv2 Extended
  # Prefix TLV and tells a producer to look at another LSA for it.
  def test_route_type_zero_is_the_empty_form
    assert_equal('01080001' + '00',
                 BGP::Link_state::Tlv::Ospf_route_type.new.to_shex)
  end

  def test_a_route_type_tlv_of_the_wrong_width_falls_back
    hex = '010800020102'
    t = BGP::Link_state::Tlv.factory([hex].pack('H*').is_packed)
    assert_equal(BGP::Link_state::Tlv::Unknown, t.class)
    assert_equal(hex, t.to_shex)
  end

  # --- TLV 265, section 5.2.3.2 ---------------------------------------
  #
  # Type 265 is 0x0109. The value is a Prefix Length in bits then
  # `(bits + 7) / 8` octets of prefix.

  # The section spells the first four cases out rather than leaving
  # them to be derived: "1 octet for prefix length 1 up to 8, 2 octets
  # for prefix length 9 up to 16, 3 octets for prefix length 17 up to
  # 24, 4 octets for prefix length 25 up to 32, etc."
  def test_the_octet_count_the_section_states
    { 1 => 1, 8 => 1, 9 => 2, 16 => 2, 17 => 3, 24 => 3, 25 => 4,
      32 => 4 }.each do |bits, octets|
      assert_equal(octets,
                   BGP::Link_state::Tlv::Ip_reachability.octets_for(bits),
                   "#{bits} bits")
    end
    # And the two the "etc." covers at either end.
    assert_equal(0, BGP::Link_state::Tlv::Ip_reachability.octets_for(0))
    assert_equal(16, BGP::Link_state::Tlv::Ip_reachability.octets_for(128))
  end

  def test_the_ip_reachability_tlv
    t = BGP::Link_state::Tlv::Ip_reachability.new('10.0.0.0/8')
    assert_equal(265, t.type)
    assert_equal(8, t.bitlen)
    assert_equal('0a', t.octets.unpack1('H*'))
    assert_equal('01090002' + '08' + '0a', t.to_shex)
  end

  def test_a_prefix_is_packed_down_to_its_significant_octets
    { '10.0.0.0/8' => '08' + '0a',
      '10.1.0.0/16' => '10' + '0a01',
      '192.0.2.0/24' => '18' + 'c00002',
      '192.0.2.1/32' => '20' + 'c0000201',
      '2001:db8::/32' => '20' + '20010db8',
      '2001:db8::1/128' => '80' + '20010db8' + '00000000' * 2 +
                           '00000001' }.each do |prefix, value|
      t = BGP::Link_state::Tlv::Ip_reachability.new(prefix)
      assert_equal(format('0109%04x', value.size / 2) + value, t.to_shex,
                   prefix)
    end
  end

  def test_the_default_route_is_a_length_of_zero_and_no_octets
    t = BGP::Link_state::Tlv::Ip_reachability.new
    assert_equal('01090001' + '00', t.to_shex)
    assert_equal(0, t.bitlen)
    assert_equal('', t.octets)
    assert_equal('0.0.0.0/0', t.prefix(1))
    assert_equal('::/0', t.prefix(2))
  end

  # **The octets are BINARY whatever built them, and the empty default is
  # the case that caught this.** `(+'')` is US-ASCII, so the default
  # route handed `IPAddr.new_ntoh` a US-ASCII string: Ruby 3.3 accepted
  # it and 3.4, 4.0 and head all raise `IPAddr::InvalidAddressError:
  # invalid encoding (given UTF-8, expected BINARY)`. So the encoding is
  # asserted here rather than left to whichever Ruby happens to run,
  # which is the only form of this test that fails on 3.3 as well.
  def test_the_octets_are_binary_on_every_build_path
    [BGP::Link_state::Tlv::Ip_reachability.new,
     BGP::Link_state::Tlv::Ip_reachability.new('10.0.0.0/8'),
     BGP::Link_state::Tlv::Ip_reachability.new('2001:db8::/32'),
     BGP::Link_state::Tlv::Ip_reachability.new(8, ['0a'].pack('H*')),
     BGP::Link_state::Tlv::Ip_reachability.new(
       :ip_reachability => { :bitlen => 8, :octets => '0a' }),
     BGP::Link_state::Tlv.factory(
       ['0109000108'].pack('H*').is_packed)].each do |t|
      assert_equal(Encoding::BINARY, t.octets.encoding,
                   "octets of #{t.to_shex}")
      assert_equal(Encoding::BINARY, t.encode.encoding)
    end
  end

  def test_it_parses_back
    t = BGP::Link_state::Tlv.factory(
      ['01090004' + '18' + 'c00002'].pack('H*').is_packed)
    assert_equal(BGP::Link_state::Tlv::Ip_reachability, t.class)
    assert_equal(24, t.bitlen)
    assert_equal('192.0.2.0/24', t.prefix(1))
  end

  # **The family is not in the TLV, which is the second cross-level
  # read in this family.** The same Prefix Length and the same octets
  # are a different prefix under each NLRI type, and nothing below
  # `Link_state::Prefix_nlri` can say which.
  def test_the_same_octets_are_two_prefixes_under_the_two_families
    t = BGP::Link_state::Tlv::Ip_reachability.new(8, ['0a'].pack('H*'))
    assert_equal('10.0.0.0/8', t.prefix(IANA::AFI::IPv4))
    assert_equal('a00::/8', t.prefix(IANA::AFI::IPv6))
  end

  # nil where the octets cannot make an address of the family asked
  # for: a Prefix Length wider than the family, and a value cut short.
  def test_the_prefix_is_nil_where_the_octets_cannot_make_one
    wide = BGP::Link_state::Tlv::Ip_reachability.new(
      64, ['00' * 8].pack('H*'))
    assert_nil(wide.prefix(IANA::AFI::IPv4), '64 bits is not an IPv4 prefix')
    assert_equal(64, wide.bitlen)
    assert_not_nil(wide.prefix(IANA::AFI::IPv6))
    short = BGP::Link_state::Tlv.factory(
      ['01090002' + '18' + 'c0'].pack('H*').is_packed)
    assert_equal(24, short.bitlen)
    assert_equal(1, short.octets.size)
    assert_nil(short.prefix(IANA::AFI::IPv4),
               'a value cut short cannot make a prefix')
    assert_equal('01090002' + '18c0', short.to_shex,
                 'and it still replays')
  end

  # Section 5.2.3.2: "Any trailing bits MUST be set to 0." That binds a
  # sender, so this reports rather than refusing, and the octets are
  # echoed as they arrived rather than re-masked. Part 6 is where a
  # receive side check reads it.
  def test_trailing_bits_that_arrived_set_are_reported_and_echoed
    hex = '01090004' + '18' + 'c00003'
    t = BGP::Link_state::Tlv.factory([hex].pack('H*').is_packed)
    assert_equal(24, t.bitlen)
    assert_equal(false, t.trailing_bits_set?,
                 '24 bits in 3 octets has no trailing bits')
    # 20 bits in 3 octets leaves 4, and 0x03 sets two of them.
    odd = BGP::Link_state::Tlv.factory(
      ['01090004' + '14' + 'c00003'].pack('H*').is_packed)
    assert(odd.trailing_bits_set?)
    assert_equal('01090004' + '14c00003', odd.to_shex,
                 'the octets are echoed rather than re-masked')
  end

  def test_no_trailing_bits_is_the_ordinary_case
    ['10.0.0.0/8', '192.0.2.0/24', '2001:db8::/32',
     '0.0.0.0/0'].each do |p|
      assert_equal(false,
                   BGP::Link_state::Tlv::Ip_reachability.new(
                     p).trailing_bits_set?, p)
    end
  end

  # --- the registry ----------------------------------------------------

  def test_both_classes_here_are_registered
    assert_equal(BGP::Link_state::Tlv::Ospf_route_type,
                 BGP::Link_state::Tlv::REGISTRY[264])
    assert_equal(BGP::Link_state::Tlv::Ip_reachability,
                 BGP::Link_state::Tlv::REGISTRY[265])
    assert_equal(BGP::Link_state::Tlv::Ospf_route_type,
                 BGP::Link_state::Tlv::BY_KEY[:ospf_route_type])
    assert_equal(BGP::Link_state::Tlv::Ip_reachability,
                 BGP::Link_state::Tlv::BY_KEY[:ip_reachability])
  end

  # Table 5's third row is TLV 263, which section 5.2.2.1 defines and
  # the link descriptor file holds, so it is one class in two tables
  # rather than two classes.
  def test_the_mt_id_tlv_is_shared_with_table_4
    require 'bgp/nlris/link_state_link_descriptor'
    assert_equal(BGP::Link_state::Tlv::Multi_topology_id,
                 BGP::Link_state::Tlv::REGISTRY[263])
  end

  # --- to_hash ---------------------------------------------------------

  # The two-places rule in Conventions: a working round trip is
  # asserted here and in test/unit/to_hash_catalog.rb.
  def test_both_classes_rebuild_from_their_own_hash
    [BGP::Link_state::Tlv::Ospf_route_type.new(3),
     BGP::Link_state::Tlv::Ospf_route_type.new(0),
     BGP::Link_state::Tlv::Ip_reachability.new('192.0.2.0/24'),
     BGP::Link_state::Tlv::Ip_reachability.new('2001:db8::/32'),
     BGP::Link_state::Tlv::Ip_reachability.new,
     BGP::Link_state::Tlv::Ip_reachability.new(
       20, ['c00003'].pack('H*'))].each do |t|
      assert_equal(t.to_shex, t.class.new(t.to_hash).to_shex,
                   "#{t.class} #{t.to_shex}")
      assert_equal(t.to_shex,
                   BGP::Link_state::Tlv.from_hash(t.to_hash).to_shex)
    end
  end

  # **The hash carries the bit count and the octets and not a prefix
  # string**, because a string needs a family this class does not have
  # and a hash that carried one would be inventing it.
  def test_the_hash_carries_no_family
    h = BGP::Link_state::Tlv::Ip_reachability.new('10.0.0.0/8').to_hash
    assert_equal({ :ip_reachability => { :bitlen => 8,
                                         :octets => '0a' } }, h)
  end

  # A prefix string is still what a test writes, and it builds.
  def test_a_prefix_string_in_the_hash_builds
    t = BGP::Link_state::Tlv::Ip_reachability.new(
      :ip_reachability => '192.0.2.0/24')
    assert_equal('0109000418c00002', t.to_shex)
  end

  # --- the four build paths -------------------------------------------

  def test_both_classes_build_from_another_instance
    [BGP::Link_state::Tlv::Ospf_route_type.new(2),
     BGP::Link_state::Tlv::Ip_reachability.new('10.0.0.0/8')].each do |t|
      assert_equal(t.to_shex, t.class.new(t).to_shex)
    end
    r = BGP::Link_state::Tlv::Ip_reachability.new('10.0.0.0/8')
    BGP::Link_state::Tlv::Ip_reachability.new(r)
    assert_equal('0a', r.octets.unpack1('H*'),
                 'copying must not empty the original')
  end

  def test_a_class_here_refuses_an_argument_it_cannot_read
    assert_raise(ArgumentError) do
      BGP::Link_state::Tlv::Ospf_route_type.new(1, 2)
    end
    assert_raise(ArgumentError) do
      BGP::Link_state::Tlv::Ip_reachability.new(1, 2, 3)
    end
  end

  # --- nothing validates ----------------------------------------------

  # Five things no RFC allows, each building and encoding.
  def test_nothing_validates
    # A route type the section does not name.
    assert_equal('010800010f',
                 BGP::Link_state::Tlv::Ospf_route_type.new(15).to_shex)
    # A Prefix Length of 200, which no family has.
    t = BGP::Link_state::Tlv::Ip_reachability.new(200, ['ff'].pack('H*'))
    assert_equal('01090002' + 'c8' + 'ff', t.to_shex)
    assert_nil(t.prefix(1))
    assert_nil(t.prefix(2))
    # Trailing bits set, which section 5.2.3.2 says MUST be 0.
    assert_equal('01090002' + '04' + 'ff',
                 BGP::Link_state::Tlv::Ip_reachability.new(
                   4, ['ff'].pack('H*')).to_shex)
    # A value with more octets than the Prefix Length asks for, which
    # the section's arithmetic does not produce.
    assert_equal('01090005' + '08' + '0a000001',
                 BGP::Link_state::Tlv::Ip_reachability.new(
                   8, ['0a000001'].pack('H*')).to_shex)
    # A Prefix Length of 0 with octets behind it, same thing at the
    # other end.
    assert_equal('01090002' + '00' + 'ff',
                 BGP::Link_state::Tlv::Ip_reachability.new(
                   0, ['ff'].pack('H*')).to_shex)
  end

end
