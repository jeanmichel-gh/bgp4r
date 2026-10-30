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

# The primitives shared by the eleven EVPN route types, and the base and
# the Unknown route type under them.
#
#   ruby -I. test/unit/nlris/evpn_route_test.rb
#
# **Every hex string in this file was produced by the library and read
# back before it was pasted**, not written out by hand. Ten hand written
# expectations were wrong in one session on the flow spec work, every
# one of them the probe's fault rather than the library's, and one of
# them made a test pass for the wrong reason. There are no RFC vectors
# for EVPN the way RFC 8955 section 4.3 prints them for flow spec, so
# the field widths and the units are what is checked against the
# document here, and the sections are quoted in the assertions.
#
# See docs/evpn.md, whose claims test/unit/evpn_doc_test.rb asserts.
#
# BGP:: names are written out in full, see Conventions in CLAUDE.md.

require 'test/unit'
require 'bgp/nlris/evpn_route'

class EvpnRouteTest < Test::Unit::TestCase

  def wire(hex)
    [hex].pack('H*').is_packed
  end

  # RFC 7432 section 5: "An ESI is encoded as a 10-octet integer in line
  # format with the most significant octet sent first."
  def test_esi_is_ten_octets
    esi = BGP::Evpn::Esi.new('00:11:22:33:44:55:66:77:88:99')
    assert_equal(10, esi.encode.size)
    assert_equal('00112233445566778899', esi.to_shex)
    assert_equal('00:11:22:33:44:55:66:77:88:99', esi.to_s)
    assert_equal(10, esi.size)
  end

  # Section 5: T "is a 1-octet field (most significant octet) that
  # specifies the format of the remaining 9 octets (ESI Value)".
  def test_esi_type_is_the_first_octet
    assert_equal(0, BGP::Evpn::Esi.new('00:11:22:33:44:55:66:77:88:99').type)
    assert_equal(1, BGP::Evpn::Esi.new(1, '001122334455667788').type)
    assert_equal('01001122334455667788',
                 BGP::Evpn::Esi.new(1, '001122334455667788').to_shex)
  end

  # Section 5: "ESI 0 denotes a single-homed site" and "ESI {0xFF}
  # (repeated 10 times) is known as MAX-ESI and is reserved".
  def test_the_two_reserved_esi_values
    assert(BGP::Evpn::Esi.new.single_homed?)
    assert_equal('00000000000000000000', BGP::Evpn::Esi.new.to_shex)
    assert(BGP::Evpn::Esi.new(wire('ff' * 10)).max?)
    refute(BGP::Evpn::Esi.new.max?)
    refute(BGP::Evpn::Esi.new(wire('ff' * 10)).single_homed?)
  end

  def test_esi_builds_four_ways
    esi = BGP::Evpn::Esi.new('00:11:22:33:44:55:66:77:88:99')
    want = esi.to_shex
    assert_equal(want, BGP::Evpn::Esi.new(esi.encode.is_packed).to_shex)
    assert_equal(want, BGP::Evpn::Esi.new(esi.to_hash).to_shex)
    assert_equal(want, BGP::Evpn::Esi.new(esi).to_shex)
    assert_equal(want, BGP::Evpn::Esi.new(0x00112233445566778899).to_shex)
  end

  # The regression for the first bug probing found here. `parse` reads
  # with `slice!`, which Conventions records as consuming the String it
  # is handed, so an `encode` that returned `@value` itself made
  # building from it empty the object being copied. The symptom is the
  # one that entry warns about: a round trip that fails while both sides
  # print the same hex, because the left side was emptied before the
  # comparison ran.
  def test_encode_does_not_hand_out_its_own_octets
    esi = BGP::Evpn::Esi.new('00:11:22:33:44:55:66:77:88:99')
    copy = BGP::Evpn::Esi.new(esi.encode.is_packed)
    assert_equal('00112233445566778899', esi.to_shex,
                 'building from esi.encode must not empty esi')
    assert_equal(esi.to_shex, copy.to_shex)
  end

  # The regression for the second. `String#<<` with an Integer appends a
  # codepoint, so on a UTF-8 String every octet from 0x80 up became the
  # two bytes of its UTF-8 encoding and the ESI came out 12 octets long.
  # Checked at 0x88 and 0x99 and again all the way up, since a test
  # using only low octets passes against the bug.
  def test_an_esi_built_from_an_integer_is_ten_octets_above_0x7f
    assert_equal(10, BGP::Evpn::Esi.new(0x00112233445566778899).encode.size)
    assert_equal('ffffffffffffffffffff',
                 BGP::Evpn::Esi.new(0xffffffffffffffffffff).to_shex)
    assert_equal(10, BGP::Evpn::Esi.new(0xffffffffffffffffffff).encode.size)
  end

  # The one refusal Conventions allows: an Integer too large for the
  # field, because the alternative is silently sending another value.
  def test_an_esi_too_wide_for_its_field_is_refused
    assert_raise(ArgumentError) { BGP::Evpn::Esi.new(1 << 80) }
    assert_nothing_raised { BGP::Evpn::Esi.new((1 << 80) - 1) }
  end

  # Nothing validates, per Conventions. Section 5 defines six ESI types,
  # 0x00 to 0x05, and the other 250 still build and encode.
  def test_an_esi_type_no_rfc_defines_still_builds
    assert_equal(0xfe, BGP::Evpn::Esi.new(0xfe, '001122334455667788').type)
    assert_equal('fe001122334455667788',
                 BGP::Evpn::Esi.new(0xfe, '001122334455667788').to_shex)
  end

  def test_ethernet_tag_id_is_four_octets
    tag = BGP::Evpn::Ethernet_tag_id.new(100)
    assert_equal(4, tag.encode.size)
    assert_equal('00000064', tag.to_shex)
    assert_equal('100', tag.to_s)
    assert_equal(4, tag.size)
  end

  # RFC 7432 section 6 on a VLAN-based service interface: "the Ethernet
  # Tag ID MUST be set to the default Ethernet tag value of 0".
  def test_the_default_ethernet_tag_is_zero
    assert_equal(0, BGP::Evpn::Ethernet_tag_id.new.value)
    assert_equal('00000000', BGP::Evpn::Ethernet_tag_id.new.to_shex)
  end

  def test_max_et_is_all_ones
    tag = BGP::Evpn::Ethernet_tag_id.new(0xffffffff)
    assert(tag.max_et?)
    assert_equal('MAX-ET', tag.to_s)
    assert_equal('ffffffff', tag.to_shex)
    refute(BGP::Evpn::Ethernet_tag_id.new(0).max_et?)
  end

  def test_ethernet_tag_id_builds_four_ways
    tag = BGP::Evpn::Ethernet_tag_id.new(100)
    want = tag.to_shex
    assert_equal(want, BGP::Evpn::Ethernet_tag_id.new(tag.encode.is_packed).to_shex)
    assert_equal(want, BGP::Evpn::Ethernet_tag_id.new(tag.to_hash).to_shex)
    assert_equal(want, BGP::Evpn::Ethernet_tag_id.new(tag).to_shex)
  end

  def test_an_ethernet_tag_id_too_wide_for_its_field_is_refused
    assert_raise(ArgumentError) { BGP::Evpn::Ethernet_tag_id.new(0x100000000) }
    assert_nothing_raised { BGP::Evpn::Ethernet_tag_id.new(0xffffffff) }
  end

  # RFC 7432 section 7.2 gives the MAC Address as "(6 octets)" with a
  # length on the line above it, and the sentence under the figure says
  # "Both the IP and MAC address lengths are in bits". So 48 is the only
  # length the figure and the sentence agree on.
  def test_a_mac_address_is_a_length_in_bits_and_six_octets
    mac = BGP::Evpn::Mac_addr.new('00:11:22:33:44:55')
    assert_equal(48, mac.bitlen)
    assert_equal('30001122334455', mac.to_shex)
    assert_equal('00:11:22:33:44:55', mac.to_s)
    assert_equal(7, mac.size, 'the length octet counts toward the wire size')
  end

  # The width does not follow the length for this field, which is where
  # it differs from the IP Address below it. A length other than 48 is
  # read and echoed and still takes 6 octets, because that is what the
  # figure says the field is.
  def test_a_mac_length_that_lies_does_not_change_the_width
    mac = BGP::Evpn::Mac_addr.new(wire('18001122334455'))
    assert_equal(24, mac.bitlen)
    assert_equal('001122334455', mac.value.unpack1('H*'),
                 'still six octets, per the figure')
    assert_equal('18001122334455', mac.to_shex, 'and the lie is echoed')
    assert_equal('00:11:22:33:44:55/24', mac.to_s)
  end

  def test_mac_address_builds_four_ways
    mac = BGP::Evpn::Mac_addr.new('00:11:22:33:44:55')
    want = mac.to_shex
    assert_equal(want, BGP::Evpn::Mac_addr.new(mac.encode.is_packed).to_shex)
    assert_equal(want, BGP::Evpn::Mac_addr.new(mac.to_hash).to_shex)
    assert_equal(want, BGP::Evpn::Mac_addr.new(mac).to_shex)
    assert_equal(want, BGP::Evpn::Mac_addr.new(48, wire('001122334455')).to_shex)
  end

  # Separators are optional, so what to_s prints reads back.
  def test_a_mac_address_reads_its_own_printed_form
    mac = BGP::Evpn::Mac_addr.new('00:11:22:33:44:55')
    assert_equal(mac.to_shex, BGP::Evpn::Mac_addr.new(mac.to_s).to_shex)
    assert_equal(mac.to_shex, BGP::Evpn::Mac_addr.new('00-11-22-33-44-55').to_shex)
  end

  # RFC 7432 section 7.2 gives the IP Address as "(0, 4, or 16 octets)",
  # so unlike the MAC its width does follow its length.
  def test_an_ip_address_width_follows_its_length
    assert_equal('20c0000201', BGP::Evpn::Addr.new('192.0.2.1').to_shex)
    assert_equal(32, BGP::Evpn::Addr.new('192.0.2.1').bitlen)
    assert_equal('8020010db8000000000000000000000001',
                 BGP::Evpn::Addr.new('2001:db8::1').to_shex)
    assert_equal(128, BGP::Evpn::Addr.new('2001:db8::1').bitlen)
  end

  # The 0 of "0, 4, or 16 octets", which route type 2 needs for a MAC
  # advertised with no IP.
  def test_the_absent_ip_address_is_a_length_octet_of_zero
    a = BGP::Evpn::Addr.new
    assert(a.empty?)
    assert_equal('00', a.to_shex)
    assert_equal(1, a.size)
    assert_equal('(none)', a.to_s)
    refute(BGP::Evpn::Addr.new('192.0.2.1').empty?)
  end

  def test_ip_address_builds_four_ways
    [BGP::Evpn::Addr.new('192.0.2.1'), BGP::Evpn::Addr.new('2001:db8::1'),
     BGP::Evpn::Addr.new].each do |a|
      want = a.to_shex
      assert_equal(want, BGP::Evpn::Addr.new(a.encode.is_packed).to_shex)
      assert_equal(want, BGP::Evpn::Addr.new(a.to_hash).to_shex)
      assert_equal(want, BGP::Evpn::Addr.new(a).to_shex)
    end
  end

  def test_an_ip_address_prints_its_family
    assert_equal('192.0.2.1/32', BGP::Evpn::Addr.new('192.0.2.1').to_s)
    assert_equal('192.0.2.1', BGP::Evpn::Addr.new('192.0.2.1').address)
    assert_equal('2001:db8::1', BGP::Evpn::Addr.new('2001:db8::1').address)
  end

  # A length no RFC allows still builds and still replays, and the
  # address reads nil rather than guessing a family from 3 octets.
  def test_an_ip_length_no_rfc_allows_still_builds
    a = BGP::Evpn::Addr.new(wire('18c00002'))
    assert_equal(24, a.bitlen)
    assert_equal(3, a.value.size, 'the width follows the length here')
    assert_equal('18c00002', a.to_shex)
    assert_nil(a.address, 'three octets are not a family')
    assert_equal('c00002/24', a.to_s)
  end

  # A length that overruns the octets it came with takes what is there
  # rather than raising, which is what keeps a truncated capture
  # readable. The length is echoed, so encode gives back what arrived.
  def test_a_length_that_overruns_takes_what_is_there
    a = BGP::Evpn::Addr.new(wire('80c0000201'))
    assert_equal(128, a.bitlen)
    assert_equal(4, a.value.size)
    assert_equal('80c0000201', a.to_shex)
  end

  # Unknown keeps its type and its whole body, which is what makes an
  # unimplemented route type replay.
  def test_an_unknown_route_type_keeps_its_octets
    u = BGP::Evpn::Unknown.new(9, wire('0011223344556677'))
    assert_equal(9, u.type)
    assert_equal('0011223344556677', u.to_shex)
    assert_equal({ :unknown => { :type => 9,
                                 :value => '0011223344556677' } }, u.to_hash)
  end

  def test_unknown_builds_three_ways
    u = BGP::Evpn::Unknown.new(9, wire('0011223344556677'))
    want = u.to_shex
    assert_equal(want, BGP::Evpn::Unknown.new(u.to_hash).to_shex)
    assert_equal(want, BGP::Evpn::Unknown.new(u).to_shex)
    assert_equal(9, BGP::Evpn::Unknown.new(u).type)
  end

  def test_unknown_does_not_hand_out_its_own_octets
    u = BGP::Evpn::Unknown.new(9, wire('0011223344556677'))
    u.encode << 'ff'
    assert_equal('0011223344556677', u.to_shex)
  end

  def test_unknown_refuses_what_it_cannot_read
    assert_raise(ArgumentError) { BGP::Evpn::Unknown.new }
    assert_raise(ArgumentError) { BGP::Evpn::Unknown.new('not a type') }
  end

  def test_the_primitives_refuse_what_they_cannot_read
    assert_raise(ArgumentError) { BGP::Evpn::Addr.new(1, 2, 3) }
    assert_raise(ArgumentError) { BGP::Evpn::Esi.new(1, 2, 3) }
    assert_raise(ArgumentError) { BGP::Evpn::Ethernet_tag_id.new(1, 2) }
    assert_raise(ArgumentError) { BGP::Evpn::Ethernet_tag_id.new('text') }
  end

  # Sized is an abstract base and from_text is where it says so: the one
  # argument form means an address or a MAC, and only its subclasses
  # know which. to_hash_catalog.rb lists it under NO_RECIPE for this.
  def test_sized_is_abstract_and_says_so
    assert_raise(ArgumentError) { BGP::Evpn::Sized.new('192.0.2.1') }
    assert_nothing_raised { BGP::Evpn::Sized.new(32, 'abcd') }
  end

  # The two nested hash forms, which are what `to_s` and a wrapped hash
  # read back through.
  def test_an_esi_reads_its_wrapped_hash_forms
    want = BGP::Evpn::Esi.new(1, '001122334455667788').to_shex
    assert_equal(want, BGP::Evpn::Esi.new(:esi => { :type => 1,
                                                    :value => '001122334455667788' }).to_shex)
    int = 0x00112233445566778899
    assert_equal(BGP::Evpn::Esi.new(int).to_shex,
                 BGP::Evpn::Esi.new(:esi => int).to_shex)
  end

  def test_an_unknown_route_type_prints_its_type_and_octets
    u = BGP::Evpn::Unknown.new(9, wire('aabb'))
    assert_equal('Unknown route type 9, 2 octets [aabb]', u.to_s)
  end

  # The Route base reads its type off the class, which is the contract
  # every route type in the parts after this one relies on. A stub here
  # proves the base works before any real route type exists to prove it.
  def test_the_route_base_reads_its_type_and_key_off_the_class
    stub = Class.new(BGP::Evpn::Route) do
      def encode_value ; ['aabb'].pack('H*') ; end
      def value_hash ; { :stub => true } ; end
    end
    # const_set, not `self::TYPE =`, which is a dynamic constant
    # assignment and a syntax error inside a block.
    stub.const_set(:TYPE, 7)
    stub.const_set(:HASH_KEY, :stub)
    assert_equal(7, stub.type)
    assert_equal(7, stub.new.type)
    assert_equal(:stub, stub.hash_key)
    assert_equal('aabb', stub.new.to_shex)
    assert_equal({ :stub => { :stub => true } }, stub.new.to_hash)
  end

  # RFC 7432 section 7.1: RD (8), ESI (10), Ethernet Tag ID (4), MPLS
  # Label (3). Fixed at 25 octets.
  def test_route_type_1_is_twenty_five_octets
    r = BGP::Evpn::Ethernet_ad.new([100, 200],
                                   '00:11:22:33:44:55:66:77:88:99',
                                   100, 500)
    assert_equal(25, r.encode.size)
    assert_equal(25, BGP::Evpn::Ethernet_ad::SIZE)
    assert_equal('00000064000000c80011223344556677889900000064001f41', r.to_shex)
    assert_equal(1, r.type)
  end

  def test_route_type_1_carries_its_four_fields
    r = BGP::Evpn::Ethernet_ad.new([100, 200],
                                   '00:11:22:33:44:55:66:77:88:99',
                                   100, 500)
    assert_equal([100, 200], r.rd.to_hash[:rd])
    assert_equal('00:11:22:33:44:55:66:77:88:99', r.esi.to_s)
    assert_equal(100, r.ethernet_tag_id.value)
    assert_equal(500, r.label.label)
  end

  def test_route_type_1_builds_four_ways
    r = BGP::Evpn::Ethernet_ad.new([100, 200],
                                   '00:11:22:33:44:55:66:77:88:99',
                                   100, 500)
    want = r.to_shex
    assert_equal(want, BGP::Evpn::Ethernet_ad.new(r.encode.is_packed).to_shex)
    assert_equal(want, BGP::Evpn::Ethernet_ad.new(r.to_hash).to_shex)
    assert_equal(want, BGP::Evpn::Ethernet_ad.new(r).to_shex)
  end

  # The hash carries the Label's own keys flat, since neither collides
  # with a field of the route, and :bottom joins them only when the low
  # bit arrived 0, which is Label#to_hash's own rule.
  def test_route_type_1_hash_merges_the_label_keys_flat
    r = BGP::Evpn::Ethernet_ad.new([100, 200],
                                   '00:11:22:33:44:55:66:77:88:99',
                                   100, 500)
    h = r.to_hash[:ethernet_ad]
    assert_equal([100, 200], h[:rd])
    assert_equal(100, h[:ethernet_tag_id])
    assert_equal(500, h[:label])
    assert_equal(0, h[:exp])
    refute(h.has_key?(:bottom), 'the low bit was 1, so no :bottom key')
  end

  # An MPLS Label with the three bits below it set and the low bit
  # clear, which only parsing or an explicit hash reaches. Exercised
  # because a field left at its default passes for the wrong reason.
  def test_route_type_1_keeps_an_unusual_label
    l = BGP::Label.new(:label => 500, :exp => 5, :bottom => 0)
    r = BGP::Evpn::Ethernet_ad.new([100, 200], BGP::Evpn::Esi.new, 0, l)
    assert_equal('00000064000000c80000000000000000000000000000001f4a', r.to_shex)
    assert_equal(5, r.to_hash[:ethernet_ad][:exp])
    assert_equal(0, r.to_hash[:ethernet_ad][:bottom])
    assert_equal(r.to_shex,
                 BGP::Evpn::Ethernet_ad.new(r.to_hash).to_shex)
  end

  # An Array field is splatted, which is the shape Rd#to_hash answers
  # with. Without that the Array lands in the Administrator field and
  # encode dies on a nil Assigned Number, which is how this was found.
  def test_a_two_part_rd_reads_back_in_either_form
    r = BGP::Evpn::Ethernet_ad.new(['10.0.0.1', 99], BGP::Evpn::Esi.new, 0, 0)
    assert_equal('00010a00000100630000000000000000000000000000000001', r.to_shex)
    assert_equal(['10.0.0.1', 99], r.to_hash[:ethernet_ad][:rd])
    assert_equal(r.to_shex, BGP::Evpn::Ethernet_ad.new(r.to_hash).to_shex)
    assert_equal(r.to_shex,
                 BGP::Evpn::Ethernet_ad.new(BGP::Rd.new('10.0.0.1', 99),
                                            BGP::Evpn::Esi.new, 0, 0).to_shex)
  end

  # RFC 7432 section 7.4: RD (8), ESI (10), IP Address Length (1),
  # Originating Router's IP Address (4 or 16). So 23 or 35 octets.
  def test_route_type_4_is_twenty_three_or_thirty_five_octets
    v4 = BGP::Evpn::Ethernet_segment.new([100, 200],
                                         '00:11:22:33:44:55:66:77:88:99',
                                         '192.0.2.1')
    assert_equal(23, v4.encode.size)
    assert_equal(23, BGP::Evpn::Ethernet_segment::SIZE_V4)
    assert_equal('00000064000000c80011223344556677889920c0000201', v4.to_shex)
    v6 = BGP::Evpn::Ethernet_segment.new([100, 200], BGP::Evpn::Esi.new,
                                         '2001:db8::1')
    assert_equal(35, v6.encode.size)
    assert_equal(35, BGP::Evpn::Ethernet_segment::SIZE_V6)
    assert_equal(4, v4.type)
  end

  def test_route_type_4_builds_four_ways
    [BGP::Evpn::Ethernet_segment.new([100, 200],
                                     '00:11:22:33:44:55:66:77:88:99',
                                     '192.0.2.1'),
     BGP::Evpn::Ethernet_segment.new([100, 200], BGP::Evpn::Esi.new,
                                     '2001:db8::1')].each do |r|
      want = r.to_shex
      assert_equal(want,
                   BGP::Evpn::Ethernet_segment.new(r.encode.is_packed).to_shex)
      assert_equal(want, BGP::Evpn::Ethernet_segment.new(r.to_hash).to_shex)
      assert_equal(want, BGP::Evpn::Ethernet_segment.new(r).to_shex)
    end
  end

  # The address hashes as a string when the octets are a whole family
  # and the bit count agrees, so a reader sees an address rather than
  # hex. Same extra-detail-only-when-unusual spirit as :tail and :bits.
  def test_route_type_4_hashes_its_address_as_a_string
    r = BGP::Evpn::Ethernet_segment.new([100, 200], BGP::Evpn::Esi.new,
                                        '192.0.2.1')
    assert_equal('192.0.2.1', r.to_hash[:ethernet_segment][:ip])
    r6 = BGP::Evpn::Ethernet_segment.new([100, 200], BGP::Evpn::Esi.new,
                                         '2001:db8::1')
    assert_equal('2001:db8::1', r6.to_hash[:ethernet_segment][:ip])
  end

  # And as the Addr hash when it is not, so a length that lies still
  # reads back. Both branches are exercised because one alone passes
  # for the wrong reason.
  def test_route_type_4_falls_back_to_the_addr_hash_for_an_odd_length
    odd = BGP::Evpn::Addr.new(24, wire('c00002'))
    r = BGP::Evpn::Ethernet_segment.new([100, 200], BGP::Evpn::Esi.new, odd)
    assert_equal({ :bitlen => 24, :value => 'c00002' },
                 r.to_hash[:ethernet_segment][:ip])
    assert_equal(r.to_shex, BGP::Evpn::Ethernet_segment.new(r.to_hash).to_shex)
    assert_equal(22, r.encode.size, 'neither 23 nor 35, and that is allowed')
  end

  def test_both_route_types_print_themselves
    r1 = BGP::Evpn::Ethernet_ad.new([100, 200],
                                    '00:11:22:33:44:55:66:77:88:99',
                                    100, 500)
    assert_equal('[1] Ethernet A-D: RD=100:200, ' \
                 'ESI 00:11:22:33:44:55:66:77:88:99, tag 100, label 500',
                 r1.to_s)
    r4 = BGP::Evpn::Ethernet_segment.new([100, 200],
                                         '00:11:22:33:44:55:66:77:88:99',
                                         '192.0.2.1')
    assert_equal('[4] Ethernet Segment: RD=100:200, ' \
                 'ESI 00:11:22:33:44:55:66:77:88:99, ' \
                 'originating router 192.0.2.1/32', r4.to_s)
  end

  # Both build with no arguments at all, which is the all-zero route the
  # RFC's reserved values describe, and both refuse what they cannot
  # read. Nothing validates: a type 4 with no address is 19 octets,
  # which section 7.4's figure does not allow, and it still builds.
  def test_both_route_types_build_empty_and_refuse_nonsense
    assert_equal(25, BGP::Evpn::Ethernet_ad.new.encode.size)
    assert_equal(19, BGP::Evpn::Ethernet_segment.new.encode.size)
    assert_raise(ArgumentError) do
      BGP::Evpn::Ethernet_ad.new(1, 2, 3, 4, 5)
    end
    assert_raise(ArgumentError) do
      BGP::Evpn::Ethernet_segment.new(1, 2, 3, 4)
    end
  end

  # The base is in place for the parts that fill it. The route type
  # table itself lives in evpn.rb and is asserted there, because this
  # file requires evpn_route.rb alone and must pass run on its own:
  # run_unit.rb requires every file before any test runs, so a file that
  # leans on another's requires passes in the suite and fails alone.
  # Asserting ROUTES here is what found that, within the minute.
  def test_the_route_base_carries_a_type_and_a_hash_key
    assert_equal(:unknown, BGP::Evpn::Unknown.hash_key)
    assert(BGP::Evpn::Unknown.ancestors.include?(BGP::Evpn::Route))
    assert_respond_to(BGP::Evpn::Unknown.new(1, 'a'), :encode_value)
  end

end
