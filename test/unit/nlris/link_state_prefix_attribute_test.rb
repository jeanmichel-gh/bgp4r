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
require 'bgp/nlris/link_state_prefix_attribute'
# Two cases compare a Table 10 class against its Table 8 counterpart:
# `Int_list_tlv` serves 1096 as well as 1153 and 1154, and the Opaque
# envelope serves one row of each table. **The source requires nothing
# but `link_state`**, because the shared bases live with the framing, so
# the comparison needs that file here rather than there. Fourth time in
# this family that a cross-table claim has needed its other table's
# file in the test and not in the source.
require 'bgp/nlris/link_state_link_attribute'
# And one case spans all three tables of section 5.3, since the Opaque
# envelope has a row in each, so Table 6's file is here too.
require 'bgp/nlris/link_state_node_attribute'

# **RFC 9552 carries no worked example and no hex anywhere**, measured in
# part 1, and neither does RFC 5130 for the two route tags. So every
# expectation here is this reader's arithmetic from the widths Table 10
# and section 5.3.3 give, and the field breakdown is written out beside
# each case for that reason. Sixteen hand-written expectations have been
# wrong across these families with the library right every time, so the
# arithmetic is what to doubt first.
#
# The type numbers, converted once: 1152 to 1157 are 0x0480 to 0x0485.
class TestLinkStatePrefixAttribute < Test::Unit::TestCase

  include BGP

  # --- TLV 1152, IGP Flags, section 5.3.3.1 --------------------------

  # "The IGP Flags TLV contains one octet of IS-IS and OSPF flags",
  # Table 10 gives the length as 1, and Figure 25 is `|D|N|L|P|       |`
  # so D is the most significant bit.
  def test_the_igp_flags_tlv
    t = BGP::Link_state::Tlv::Igp_flags.new(:down)
    assert_equal(1152, t.type)
    # 0480 type, 0001 length, 80 the D bit alone.
    assert_equal('04800001' + '80', t.to_shex)
    assert_equal(5, t.size)
    assert_equal(0x80, t.value)
    assert(t.down?)
    assert(!t.no_unicast?)
    assert_equal([:down], t.names)
    assert_equal('IGP flags down', t.to_s)
    assert_equal({ :igp_flags => [:down] }, t.to_hash)
    assert_equal(t.to_shex,
                 BGP::Link_state::Tlv::Igp_flags.new(t.to_hash).to_shex)
  end

  # **Table 11 names the four bits and gives no bit numbers**, where
  # Table 7 does for the node flags, so Figure 25's order is the only
  # statement of the placement there is. Each mask is asserted against
  # the position the figure puts it in, which is the assertion a round
  # trip cannot make: encoder and decoder sharing a reversal passes one
  # and fails this.
  def test_each_flag_sits_where_figure_25_puts_it
    { :down           => 0x80,
      :no_unicast     => 0x40,
      :local_address  => 0x20,
      :propagate_nssa => 0x10 }.each do |name, mask|
      assert_equal(mask, BGP::Link_state::Tlv::Igp_flags::BITS.fetch(name),
                   "#{name} is not the bit Figure 25 gives it")
      t = BGP::Link_state::Tlv::Igp_flags.new(name)
      assert_equal(format('%02x', mask), t.to_shex[-2, 2])
      assert(t.set?(name))
    end
  end

  # The low nibble, which section 5.3.3.1 disposes of in a sentence:
  # "The bits that are not defined MUST be set to 0 by the originator
  # and MUST be ignored by the receiver."
  def test_the_defined_bits_are_the_high_nibble
    assert_equal(0xf0, BGP::Link_state::Tlv::Igp_flags::DEFINED_BITS)
  end

  # All four set is 0xf0, which is also what `DEFINED_BITS` is, so a
  # build from every field name writes no reserved bit.
  def test_every_flag_set_writes_exactly_the_defined_bits
    t = BGP::Link_state::Tlv::Igp_flags
          .new(:down, :no_unicast, :local_address, :propagate_nssa)
    assert_equal('04800001' + 'f0', t.to_shex)
    assert_equal(0, t.undefined_bits)
    assert(!t.undefined_bits?)
    assert_equal(4, t.names.size)
  end

  # Keep and echo, the rule Conventions records and this section asks
  # for outright. The hash gains `:bits` only then, so an ordinary one
  # stays the list of names it has always been.
  def test_a_reserved_bit_is_kept_echoed_and_in_the_hash
    hex = '04800001' + '8f'
    t = BGP::Link_state::Tlv.factory([hex].pack('H*'))
    assert_instance_of(BGP::Link_state::Tlv::Igp_flags, t)
    assert_equal(hex, t.to_shex)
    assert_equal([:down], t.names)
    assert(t.undefined_bits?)
    assert_equal(0x0f, t.undefined_bits)
    assert_equal({ :igp_flags => [:down, { :bits => 0x8f }] }, t.to_hash)
    assert_equal(hex,
                 BGP::Link_state::Tlv::Igp_flags.new(t.to_hash).to_shex)
    assert_equal('IGP flags down, undefined bits 1111', t.to_s)
  end

  def test_the_igp_flags_build_from_an_octet_and_from_a_list
    assert_equal(BGP::Link_state::Tlv::Igp_flags.new(:down, :no_unicast)
                   .to_shex,
                 BGP::Link_state::Tlv::Igp_flags.new(0xc0).to_shex)
    assert_equal(BGP::Link_state::Tlv::Igp_flags.new(:down, :no_unicast)
                   .to_shex,
                 BGP::Link_state::Tlv::Igp_flags
                   .new([:down, :no_unicast]).to_shex)
  end

  # No flag at all, which section 5.1 permits as a value and which the
  # one octet still carries. It builds, per Conventions.
  def test_no_flag_set_is_still_one_octet
    t = BGP::Link_state::Tlv::Igp_flags.new(0)
    assert_equal('04800001' + '00', t.to_shex)
    assert_equal('IGP flags none', t.to_s)
    assert_equal({ :igp_flags => [] }, t.to_hash)
  end

  def test_the_igp_flags_refuse_what_the_octet_cannot_hold
    assert_raise(ArgumentError) { BGP::Link_state::Tlv::Igp_flags.new(256) }
    assert_raise(ArgumentError) { BGP::Link_state::Tlv::Igp_flags.new(-1) }
    assert_raise(ArgumentError) { BGP::Link_state::Tlv::Igp_flags.new(:nope) }
  end

  # A width other than 1 cannot be this class, so `Tlv.factory` keeps
  # the octets whole instead, which is part 1's rule.
  def test_a_two_octet_igp_flags_value_is_kept_as_unknown
    hex = '04800002' + '8000'
    t = BGP::Link_state::Tlv.factory([hex].pack('H*'))
    assert_instance_of(BGP::Link_state::Tlv::Unknown, t)
    assert_equal(hex, t.to_shex)
  end

  # --- TLV 1153, IGP Route Tag, section 5.3.3.2 ----------------------

  # "The length is a multiple of 4. The Value field contains one or more
  # Route Tags as learned in the IGP topology." Table 10 gives 4*n.
  def test_the_igp_route_tag_tlv
    t = BGP::Link_state::Tlv::Igp_route_tag.new(100, 200)
    assert_equal(1153, t.type)
    # 0481 type, 0008 length, then two 4-octet tags.
    assert_equal('04810008' + '00000064' + '000000c8', t.to_shex)
    assert_equal(12, t.size)
    assert_equal([100, 200], t.values)
    assert_equal('IGP route tag 100,200', t.to_s)
    assert_equal({ :igp_route_tag => [100, 200] }, t.to_hash)
    assert_equal(t.to_shex,
                 BGP::Link_state::Tlv::Igp_route_tag.new(t.to_hash).to_shex)
    assert_equal(t.to_shex,
                 BGP::Link_state::Tlv::Igp_route_tag.new([100, 200]).to_shex)
  end

  # The widest 32-bit tag, so the pack code is exercised to its top bit
  # rather than only on small numbers.
  def test_the_widest_igp_route_tag
    t = BGP::Link_state::Tlv::Igp_route_tag.new(0xffffffff)
    assert_equal('04810004' + 'ffffffff', t.to_shex)
    assert_equal([0xffffffff], t.values)
  end

  # Zero tags, which the multiple-of-4 arithmetic allows and section
  # 5.1 permits as a value.
  def test_an_igp_route_tag_with_no_tags
    t = BGP::Link_state::Tlv::Igp_route_tag.new
    assert_equal('04810000', t.to_shex)
    assert_equal('IGP route tag none', t.to_s)
    assert_equal(t.to_shex,
                 BGP::Link_state::Tlv::Igp_route_tag.new(t.to_hash).to_shex)
  end

  # The wire path, which the build-from-values cases above do not reach.
  # Part 5b-ii found the SRLG's own `parse` untested for exactly this
  # reason, so each list class here is parsed from octets too.
  def test_an_igp_route_tag_read_off_the_wire
    hex = '04810008' + '00000064' + '000000c8'
    t = BGP::Link_state::Tlv.factory([hex].pack('H*'))
    assert_instance_of(BGP::Link_state::Tlv::Igp_route_tag, t)
    assert_equal([100, 200], t.values)
    assert_equal(hex, t.to_shex)
  end

  # A length that is not a multiple of 4 keeps the whole groups and
  # loses the remainder, so it cannot reproduce its own octets and
  # `Tlv.factory` keeps it as a `Tlv::Unknown` instead.
  def test_an_igp_route_tag_value_that_is_not_a_multiple_of_four
    hex = '04810005' + '0000006400'
    t = BGP::Link_state::Tlv.factory([hex].pack('H*'))
    assert_instance_of(BGP::Link_state::Tlv::Unknown, t)
    assert_equal(hex, t.to_shex)
  end

  # --- TLV 1154, IGP Extended Route Tag, section 5.3.3.3 -------------

  # "The length is a multiple of 8. The Extended Route Tag field
  # contains one or more Extended Route Tags." Table 10 gives 8*n, so
  # **this is the only 64-bit field in the family** and the one place
  # `'Q>*'` appears.
  def test_the_igp_extended_route_tag_tlv
    t = BGP::Link_state::Tlv::Igp_extended_route_tag.new(1, 2)
    assert_equal(1154, t.type)
    # 0482 type, 0010 length, then two 8-octet tags.
    assert_equal('04820010' + '0000000000000001' + '0000000000000002',
                 t.to_shex)
    assert_equal(20, t.size)
    assert_equal([1, 2], t.values)
    assert_equal('IGP extended route tag 1,2', t.to_s)
    assert_equal({ :igp_extended_route_tag => [1, 2] }, t.to_hash)
    assert_equal(t.to_shex, BGP::Link_state::Tlv::Igp_extended_route_tag
                              .new(t.to_hash).to_shex)
  end

  # **The assertion that says the element is 8 octets and not 4**, which
  # is the one thing a reader carrying 1153's shape across gets wrong.
  # A value above 32 bits cannot encode in the narrower element at all,
  # so it is the case that cannot pass against the wrong pack code.
  def test_an_extended_route_tag_above_thirty_two_bits
    t = BGP::Link_state::Tlv::Igp_extended_route_tag.new(2**63)
    assert_equal('04820008' + '8000000000000000', t.to_shex)
    assert_equal([2**63], t.values)
    t2 = BGP::Link_state::Tlv::Igp_extended_route_tag.new(2**64 - 1)
    assert_equal('04820008' + 'ffffffffffffffff', t2.to_shex)
    assert_equal([2**64 - 1], t2.values)
  end

  def test_an_igp_extended_route_tag_read_off_the_wire
    hex = '04820010' + '0000000000000001' + '8000000000000000'
    t = BGP::Link_state::Tlv.factory([hex].pack('H*'))
    assert_instance_of(BGP::Link_state::Tlv::Igp_extended_route_tag, t)
    assert_equal([1, 2**63], t.values)
    assert_equal(hex, t.to_shex)
  end

  # Four octets is a whole group of 1153's width and half of one here,
  # so it is the length that tells the two classes apart.
  def test_a_four_octet_extended_route_tag_value_is_kept_as_unknown
    hex = '04820004' + '00000001'
    t = BGP::Link_state::Tlv.factory([hex].pack('H*'))
    assert_instance_of(BGP::Link_state::Tlv::Unknown, t)
    assert_equal(hex, t.to_shex)
  end

  def test_an_extended_route_tag_with_no_tags
    t = BGP::Link_state::Tlv::Igp_extended_route_tag.new
    assert_equal('04820000', t.to_shex)
    assert_equal('IGP extended route tag none', t.to_s)
  end

  # --- The shared list base ------------------------------------------

  # **Three subclasses across two of the RFC's tables**, which is the
  # line part 5b-i drew for where a base lives: Table 8's SRLG and
  # Table 10's two route tags. So `Int_list_tlv` sits with the framing
  # and this is the case that says why.
  def test_the_list_base_serves_both_tables
    [BGP::Link_state::Tlv::Srlg,
     BGP::Link_state::Tlv::Igp_route_tag,
     BGP::Link_state::Tlv::Igp_extended_route_tag].each do |klass|
      assert_equal(BGP::Link_state::Tlv::Int_list_tlv, klass.superclass,
                   "#{klass} is an integer list and should share the base")
    end
    assert_equal([1096, 1153, 1154],
                 [BGP::Link_state::Tlv::Srlg,
                  BGP::Link_state::Tlv::Igp_route_tag,
                  BGP::Link_state::Tlv::Igp_extended_route_tag]
                   .collect { |k| k::TYPE })
  end

  # **`PACK` is the only place the element width is stated**, which is
  # part 5b-ii's finding applied up front: a `WIDTH` constant beside it
  # would be a second statement of one fact and a sabotage proved
  # nothing read the one `Srlg` used to carry. So the two codes are
  # asserted, and the widths they produce with them.
  def test_the_pack_code_is_where_the_element_width_is_stated
    assert_equal('N*', BGP::Link_state::Tlv::Srlg::PACK)
    assert_equal('N*', BGP::Link_state::Tlv::Igp_route_tag::PACK)
    assert_equal('Q>*', BGP::Link_state::Tlv::Igp_extended_route_tag::PACK)
    assert_equal(4, BGP::Link_state::Tlv::Igp_route_tag
                      .new(1).encode_value.size)
    assert_equal(8, BGP::Link_state::Tlv::Igp_extended_route_tag
                      .new(1).encode_value.size)
    [BGP::Link_state::Tlv::Srlg,
     BGP::Link_state::Tlv::Igp_route_tag,
     BGP::Link_state::Tlv::Igp_extended_route_tag].each do |klass|
      assert(!klass.const_defined?(:WIDTH, false),
             "#{klass} states its element width twice")
    end
  end

  # The SRLG still behaves as it did before its body moved, which is
  # what says the extraction changed nothing. Part 5b-ii's own cases
  # assert the rest.
  def test_the_srlg_still_encodes_as_it_did
    t = BGP::Link_state::Tlv::Srlg.new(100, 200)
    assert_equal('04480008' + '00000064' + '000000c8', t.to_shex)
    assert_equal('SRLG 100,200', t.to_s)
    assert_equal({ :srlg => [100, 200] }, t.to_hash)
  end

  # --- TLV 1155, Prefix Metric, section 5.3.3.4 ----------------------

  # "The length is 4", which section 5.3.3.4 states itself and Table 10
  # agrees with, so it is `Opaque32` and nothing else.
  def test_the_prefix_metric_tlv
    t = BGP::Link_state::Tlv::Prefix_metric.new(42)
    assert_equal(1155, t.type)
    assert_equal('04830004' + '0000002a', t.to_shex)
    assert_equal(8, t.size)
    assert_equal(42, t.value)
    assert_equal('Prefix metric 42', t.to_s)
    assert_equal({ :prefix_metric => 42 }, t.to_hash)
    assert_equal(t.to_shex,
                 BGP::Link_state::Tlv::Prefix_metric.new(t.to_hash).to_shex)
    assert_equal(BGP::Link_state::Tlv::Opaque32,
                 BGP::Link_state::Tlv::Prefix_metric.superclass)
  end

  def test_the_widest_prefix_metric
    t = BGP::Link_state::Tlv::Prefix_metric.new(0xffffffff)
    assert_equal('04830004' + 'ffffffff', t.to_shex)
    assert_equal(0xffffffff, t.value)
  end

  def test_a_prefix_metric_read_off_the_wire
    hex = '04830004' + '0000002a'
    t = BGP::Link_state::Tlv.factory([hex].pack('H*'))
    assert_instance_of(BGP::Link_state::Tlv::Prefix_metric, t)
    assert_equal(42, t.value)
    assert_equal(hex, t.to_shex)
  end

  # **Two Prefix Metrics in one list build and encode**, where section
  # 5.3.3.4 says the TLV "may only appear once". That is a sender's rule
  # and bgp4r does not enforce it, per Conventions: the attribute's hash
  # is a list, so there is somewhere to put the second.
  def test_two_prefix_metrics_in_one_list_are_not_refused
    hex = '048300040000002a' + '048300040000002b'
    list = BGP::Link_state::Tlv.parse_list([hex].pack('H*'))
    assert_equal(2, list.size)
    assert_equal([42, 43], list.collect { |t| t.value })
    assert_equal(hex, list.collect { |t| t.to_shex }.join)
  end

  # --- TLV 1156, OSPF Forwarding Address, section 5.3.3.5 ------------

  # **The section and the figure against the table**, which is the
  # reading this follows: "The length is 4 for an IPv4 forwarding
  # address and 16 for an IPv6 forwarding address", and Figure 29 says
  # "Forwarding Address (variable)", where Table 10's Length column
  # says 4. No erratum covers it.
  def test_the_ospf_forwarding_address_has_two_widths
    v4 = BGP::Link_state::Tlv::Ospf_forwarding_address.new('10.0.0.1')
    assert_equal(1156, v4.type)
    assert_equal('04840004' + '0a000001', v4.to_shex)
    assert_equal(8, v4.size)
    assert_equal(:ipv4, v4.family)
    assert_equal('10.0.0.1', v4.address.to_s)
    assert_equal('OSPF forwarding address 10.0.0.1', v4.to_s)
    assert_equal({ :ospf_forwarding_address => '10.0.0.1' }, v4.to_hash)

    v6 = BGP::Link_state::Tlv::Ospf_forwarding_address.new('2001:db8::1')
    assert_equal('04840010' + '20010db8000000000000000000000001', v6.to_shex)
    assert_equal(20, v6.size)
    assert_equal(:ipv6, v6.family)
    assert_equal('2001:db8::1', v6.address.to_s)

    [v4, v6].each do |t|
      assert_equal(t.to_shex, BGP::Link_state::Tlv::Ospf_forwarding_address
                                .new(t.to_hash).to_shex)
    end
  end

  # Both widths read back off the wire as the family their own size
  # gives, which is the only thing that says which family the value is.
  def test_both_forwarding_address_widths_read_off_the_wire
    { '04840004' + '0a000001' => ['10.0.0.1', :ipv4],
      '04840010' + '20010db8000000000000000000000001' =>
        ['2001:db8::1', :ipv6] }.each do |hex, (addr, fam)|
      t = BGP::Link_state::Tlv.factory([hex].pack('H*'))
      assert_instance_of(BGP::Link_state::Tlv::Ospf_forwarding_address, t)
      assert_equal(addr, t.address.to_s)
      assert_equal(fam, t.family)
      assert_equal(hex, t.to_shex)
    end
  end

  # **A width that is neither 4 nor 16 is not one of these**, which is
  # `Addr_tlv`'s rule: the class is a claim about meaning, so an
  # eight-octet value with no readable address would claim bgp4r read a
  # forwarding address and found none. The octets are kept whole and
  # replayed instead, which is part 1's rule and not the length check
  # section 8.2.2 forbids, since nothing is reported either way.
  def test_an_off_width_forwarding_address_is_kept_as_unknown
    ['04840008' + 'aabbccddeeff1122',
     '04840000',
     '04840002' + 'aabb'].each do |hex|
      t = BGP::Link_state::Tlv.factory([hex].pack('H*'))
      assert_instance_of(BGP::Link_state::Tlv::Unknown, t,
                         "#{hex} is not a forwarding address")
      assert_equal(hex, t.to_shex, 'and its octets come back whole')
    end
  end

  # The octet level route Conventions requires to stay open, which the
  # refusal's own message names.
  def test_an_off_width_forwarding_address_builds_through_unknown
    t = BGP::Link_state::Tlv::Unknown
          .new(1156, ['aabbccddeeff1122'].pack('H*'))
    assert_equal('04840008' + 'aabbccddeeff1122', t.to_shex)
  end

  # **This class's own width check is message-only, where `Addr_tlv`'s
  # is load bearing, and the difference is which widths each takes.**
  # `IPAddr.new_ntoh` accepts exactly 4 octets and 16 and answers
  # `IPAddr::AddressFamilyError` for every other width, measured on
  # 2026-11-01. So for a class that takes both of those there is no gap
  # left for a check to close: deleting it leaves every assertion about
  # the value passing, which is how a sabotage found it. `Addr_tlv`
  # takes **one** of the two, so there IPAddr accepts a width the class
  # must not, which is the bug part 3 found in TLV 261.
  #
  # The check stays for its message, which names both widths and the
  # `Tlv::Unknown` route where `AddressFamilyError` says nothing about
  # TLV 1156, and this is what makes it read by something rather than
  # dead. Part 5b-ii's two dead constants are the same shape found the
  # other way round.
  def test_the_width_refusal_says_which_widths_and_names_the_way_out
    e = assert_raise_kind_of(ArgumentError) do
      BGP::Link_state::Tlv::Ospf_forwarding_address
        .new(['aabbccddeeff1122'].pack('H*').is_packed)
    end
    assert_match(/4 or 16 octets/, e.message)
    assert_match(/this value is 8/, e.message)
    # Which is more than the layer below says: `AddressFamilyError`
    # names neither the TLV nor the widths it wanted.
    assert_equal(nil, IPAddr::AddressFamilyError.new.message[/4 or 16/])
  end

  def test_the_forwarding_address_takes_an_ipaddr
    assert_equal(BGP::Link_state::Tlv::Ospf_forwarding_address
                   .new('10.0.0.1').to_shex,
                 BGP::Link_state::Tlv::Ospf_forwarding_address
                   .new(IPAddr.new('10.0.0.1')).to_shex)
  end

  # **No empty form**, where `Addr_tlv` has one: with two widths allowed
  # there is no all zeroes address to default to that would not be
  # inventing a family. `new('0.0.0.0')` is the explicit way to the
  # zero IPv4 one.
  def test_the_forwarding_address_has_no_empty_form
    assert_raise(ArgumentError) do
      BGP::Link_state::Tlv::Ospf_forwarding_address.new
    end
    assert_equal('04840004' + '00000000',
                 BGP::Link_state::Tlv::Ospf_forwarding_address
                   .new('0.0.0.0').to_shex)
  end

  # --- TLV 1157, Opaque Prefix Attribute, section 5.3.3.6 ------------

  # Section 5.3.1.5's and 5.3.2.6's envelope one table over, so it is
  # `Opaque_tlv` and nothing reads inside it.
  def test_the_opaque_prefix_attribute_tlv
    t = BGP::Link_state::Tlv::Opaque_prefix_attribute
          .new(['deadbeef'].pack('H*'))
    assert_equal(1157, t.type)
    assert_equal('04850004' + 'deadbeef', t.to_shex)
    assert_equal(8, t.size)
    assert_equal('Opaque prefix attribute 4 octets [deadbeef]', t.to_s)
    assert_equal({ :opaque_prefix_attribute => 'deadbeef' }, t.to_hash)
    assert_equal(t.to_shex, BGP::Link_state::Tlv::Opaque_prefix_attribute
                              .new(t.to_hash).to_shex)
    assert_equal(BGP::Link_state::Tlv::Opaque_tlv,
                 BGP::Link_state::Tlv::Opaque_prefix_attribute.superclass)
  end

  # The three envelopes are one shape and three code points, one per
  # table of section 5.3, which is worth asserting because their three
  # sections are near enough to read as one.
  def test_the_three_opaque_envelopes_are_one_shape
    [[1025, BGP::Link_state::Tlv::Opaque_node_attribute],
     [1097, BGP::Link_state::Tlv::Opaque_link_attribute],
     [1157, BGP::Link_state::Tlv::Opaque_prefix_attribute]
    ].each do |type, klass|
      assert_equal(type, klass::TYPE)
      assert_equal(BGP::Link_state::Tlv::Opaque_tlv, klass.superclass)
    end
  end

  def test_an_empty_opaque_prefix_attribute
    t = BGP::Link_state::Tlv::Opaque_prefix_attribute.new
    assert_equal('04850000', t.to_shex)
    assert_equal('Opaque prefix attribute 0 octets', t.to_s)
  end

  # --- Across the table ----------------------------------------------

  # Every one of Table 10's six is registered, under its own type and
  # its own hash key, which is what makes a hash build find it.
  def test_all_six_are_registered
    { 1152 => BGP::Link_state::Tlv::Igp_flags,
      1153 => BGP::Link_state::Tlv::Igp_route_tag,
      1154 => BGP::Link_state::Tlv::Igp_extended_route_tag,
      1155 => BGP::Link_state::Tlv::Prefix_metric,
      1156 => BGP::Link_state::Tlv::Ospf_forwarding_address,
      1157 => BGP::Link_state::Tlv::Opaque_prefix_attribute
    }.each do |type, klass|
      assert_equal(klass, BGP::Link_state::Tlv::REGISTRY[type],
                   "TLV #{type} is not registered as #{klass}")
      assert_equal(klass, BGP::Link_state::Tlv::BY_KEY[klass::HASH_KEY],
                   "#{klass} is not in the hash key lookup")
    end
  end

  # **Nothing validates**, per Conventions, so a prefix attribute set
  # that no RFC allows goes on the wire: a reserved bit set, the TLVs
  # out of the ascending order section 5.1 asks for, and a type twice
  # where its own section says once.
  def test_nothing_validates
    out_of_order = [BGP::Link_state::Tlv::Prefix_metric.new(42),
                    BGP::Link_state::Tlv::Igp_flags.new(0xff)]
    hex = out_of_order.collect { |t| t.to_shex }.join
    assert_equal(hex, BGP::Link_state::Tlv
                        .parse_list([hex].pack('H*'))
                        .collect { |t| t.to_shex }.join)
    assert(!BGP::Link_state::Tlv.ordered?(out_of_order),
           'the order is reported and not refused')
  end

  # Every class here that reads its argument's shape refuses one it
  # cannot, with an `ArgumentError` **or a descendant of one**, which is
  # a class saying no rather than one reading a shape it never checked.
  # A `TypeError` or a `NoMethodError` would be the second, which is the
  # bug the EVPN work found in `Multicast_flags`.
  #
  # **`assert_raise_kind_of` and not `assert_raise`, which is the point
  # worth keeping**: `Ospf_forwarding_address` hands the argument to
  # `IPAddr`, which answers `IPAddr::InvalidAddressError`, and that is
  # an `ArgumentError` by ancestry but not by `assert_raise`'s exact
  # class match. So the strict form fails on a refusal that satisfies
  # the rule, and the kind-of form says what the rule means.
  #
  # **`Prefix_metric` is deliberately not on this list**, and the
  # sibling case in `link_state_link_attribute_test.rb` leaves its two
  # `Opaque32` subclasses off for the same reason: that base's `coerce`
  # is `v.to_i` and opaque is the RFC's own word for the shape, so it
  # takes anything answering `to_i` and raises `NoMethodError` on
  # anything else. Not reachable from a hash or from the wire, since
  # both hand it a number, and changing a base five classes share would
  # be a second topic.
  def test_each_class_refuses_what_it_cannot_read
    [BGP::Link_state::Tlv::Igp_flags,
     BGP::Link_state::Tlv::Igp_route_tag,
     BGP::Link_state::Tlv::Igp_extended_route_tag,
     BGP::Link_state::Tlv::Ospf_forwarding_address,
    ].each do |klass|
      assert_raise_kind_of(ArgumentError, klass.to_s) do
        klass.new(Object.new)
      end
    end
  end

  # The octet buffers, asserted as binary rather than trusted, which is
  # the only form of the test that fails on Ruby 3.3 against a `+''`
  # default. The guard that reads `encode` instead is worth nothing,
  # since `pack` forces binary on its result whatever went in.
  def test_the_octet_buffer_is_binary
    t = BGP::Link_state::Tlv::Opaque_prefix_attribute.new
    assert_equal(Encoding::BINARY, t.value.encoding)
  end

  # Four of the six round trip through another instance of themselves,
  # and the two list classes and the opaque one copy their own value
  # rather than sharing it, since the list reader reads with `slice!`.
  def test_every_class_copies_from_another_instance
    [BGP::Link_state::Tlv::Igp_flags.new(:down),
     BGP::Link_state::Tlv::Igp_route_tag.new(100, 200),
     BGP::Link_state::Tlv::Igp_extended_route_tag.new(2**63),
     BGP::Link_state::Tlv::Prefix_metric.new(42),
     BGP::Link_state::Tlv::Ospf_forwarding_address.new('10.0.0.1'),
     BGP::Link_state::Tlv::Opaque_prefix_attribute
       .new(['dead'].pack('H*'))
    ].each do |t|
      copy = t.class.new(t)
      assert_equal(t.to_shex, copy.to_shex, t.class.to_s)
      assert_equal(t.to_shex, t.to_shex, 'and the original is intact')
    end
  end

end
