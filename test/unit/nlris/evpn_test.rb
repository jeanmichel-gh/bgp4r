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

# The EVPN NLRI framing of RFC 7432 section 7.
#
#   ruby -I. test/unit/nlris/evpn_test.rb
#
# Every hex string here was produced by the library and read back before
# it was pasted, for the reason evpn_route_test.rb gives.
#
# See docs/evpn.md, whose claims test/unit/evpn_doc_test.rb asserts.
#
# BGP:: names are written out in full, see Conventions in CLAUDE.md.

require 'test/unit'
require 'bgp/nlris/evpn'

class EvpnTest < Test::Unit::TestCase

  def wire(hex)
    [hex].pack('H*').is_packed
  end

  # A route type no part has implemented yet, which is every one of them
  # in this part, so the framing can be exercised on its own.
  def unknown(type = 9, hex = '0011223344556677')
    BGP::Evpn::Unknown.new(type, wire(hex))
  end

  # RFC 7432 section 7: Route Type (1 octet), Length (1 octet), Route
  # Type specific (variable).
  def test_the_framing_is_a_type_octet_a_length_octet_and_a_body
    n = BGP::Evpn.new(unknown)
    assert_equal('09080011223344556677', n.to_shex)
    assert_equal(9, n.type)
    assert_equal(8, n.length, 'the Length counts the body alone')
    assert_equal(10, n.size)
  end

  def test_an_nlri_builds_four_ways
    n = BGP::Evpn.new(unknown)
    want = n.to_shex
    assert_equal(want, BGP::Evpn.new(n.encode.is_packed).to_shex)
    assert_equal(want, BGP::Evpn.new(n.to_hash).to_shex)
    assert_equal(want, BGP::Evpn.new(n).to_shex)
  end

  # What the two parse loops need in place of the prefix families'
  # `(blen+7)/8+1`. It counts the two framing octets, so a caller can
  # slice exactly one NLRI off.
  def test_nlri_size_counts_the_framing
    assert_equal(10, BGP::Evpn.nlri_size(wire('09080011223344556677')))
    assert_equal(2, BGP::Evpn.nlri_size(wire('0900')))
    assert_equal(257, BGP::Evpn.nlri_size(wire('09ff')))
  end

  # nil rather than a guess, so a loop can stop and let the leftover
  # raise, which is how an attribute bgp4r cannot read still becomes an
  # Attr::Raw with an Attr::Gap. The flow spec wiring relies on the same
  # contract from Flow_spec.nlri_size.
  def test_nlri_size_answers_nil_for_octets_too_short_to_frame
    assert_nil(BGP::Evpn.nlri_size(nil))
    assert_nil(BGP::Evpn.nlri_size(wire('')))
    assert_nil(BGP::Evpn.nlri_size(wire('09')))
  end

  # It reads the length from the octets and never from the body, so a
  # Length that lies is reported as it arrived.
  def test_nlri_size_reads_the_declared_length_not_the_real_one
    assert_equal(22, BGP::Evpn.nlri_size(wire('09140011223344556677')),
                 'a Length of 0x14 with 8 octets behind it still answers 22')
  end

  # Several NLRIs sit one after another in the attribute, which is where
  # this differs from a flow spec NLRI holding a list under one length.
  def test_consecutive_nlris_are_sliced_by_their_own_lengths
    s = wire('0902aabb' + '0a03ccddee')
    first = BGP::Evpn.nlri_size(s)
    assert_equal(4, first)
    a = BGP::Evpn.new(s.byteslice(0, first).is_packed)
    rest = s.byteslice(first, s.size - first).is_packed
    assert_equal(5, BGP::Evpn.nlri_size(rest))
    b = BGP::Evpn.new(rest)
    assert_equal([9, 10], [a.type, b.type])
    assert_equal(['aabb', 'ccddee'], [a.route.value.unpack1('H*'),
                                      b.route.value.unpack1('H*')])
  end

  # A Length that disagrees with the octets that came with it is kept
  # and written back, so a malformed capture replays byte for byte.
  # Conventions: building and encoding never validate.
  def test_a_length_that_lies_is_kept_and_echoed
    n = BGP::Evpn.new(wire('09140011223344556677'))
    assert_equal(20, n.declared_len)
    assert_equal(8, n.route.value.size, 'it took what was there')
    assert_equal('09140011223344556677', n.to_shex)
    assert_equal(20, n.length)
  end

  def test_an_honest_length_keeps_no_declared_length
    n = BGP::Evpn.new(wire('09080011223344556677'))
    assert_nil(n.declared_len)
    assert_equal(8, n.length)
    assert_equal({ :unknown => { :type => 9,
                                 :value => '0011223344556677' } }, n.to_hash)
  end

  # A kept Length rides in the hash as one more key, which is the
  # extra-key-only-when-unusual rule the library already uses for :tail
  # and :bits. No lie, no key, so an ordinary NLRI hashes as it would
  # have without this.
  def test_a_kept_length_round_trips_through_the_hash
    n = BGP::Evpn.new(wire('09140011223344556677'))
    assert_equal(20, n.to_hash[:length])
    assert_equal(n.to_shex, BGP::Evpn.new(n.to_hash).to_shex)
    refute(BGP::Evpn.new(unknown).to_hash.has_key?(:length))
  end

  # An unimplemented route type reads back whole. Types 1 and 4 are
  # implemented, so a two octet body for either is not a layout they can
  # represent and falls back to Unknown; every other type has no class
  # at all. Either way the octets replay, which is the point.
  def test_an_unimplemented_route_type_reads_back_whole
    assert_equal([1, 4], BGP::Evpn::ROUTES.keys.sort)
    (1..11).each do |t|
      n = BGP::Evpn.new(wire('%02x02aabb' % t))
      assert_instance_of(BGP::Evpn::Unknown, n.route)
      assert_equal(t, n.type)
      assert_equal('%02x02aabb' % t, n.to_shex)
    end
  end

  # A body a registered route type can read resolves to that class.
  def test_a_whole_body_resolves_to_its_route_type
    n = BGP::Evpn.new(wire('0119' \
                           '00000064000000c80011223344556677889900000064001f41'))
    assert_instance_of(BGP::Evpn::Ethernet_ad, n.route)
    assert_equal(1, n.type)
    assert_equal(100, n.route.ethernet_tag_id.value)
    assert_equal(500, n.route.label.label)
    assert_nil(n.declared_len)

    m = BGP::Evpn.new(wire('0417' \
                           '00000064000000c80011223344556677889920c0000201'))
    assert_instance_of(BGP::Evpn::Ethernet_segment, m.route)
    assert_equal('192.0.2.1', m.route.ip.address)
  end

  # **A route type is kept only if it can give its own octets back.**
  # Both layouts are fixed width and nothing in the framing guarantees
  # the Length agrees, so a short or long body falls back to Unknown
  # rather than inventing the fields it did not find. Same rule
  # Flow_spec applies to its components.
  def test_a_body_the_route_type_cannot_reproduce_falls_back_to_unknown
    short = '00000064000000c8001122334455667788990000006400'
    n = BGP::Evpn.new(wire('0118' + short))
    assert_instance_of(BGP::Evpn::Unknown, n.route,
                       'a 23 octet body is not a 25 octet route type 1')
    assert_equal('0118' + short, n.to_shex)
    assert_equal(24, n.declared_len)

    long = '00000064000000c80011223344556677889900000064001f41ff'
    m = BGP::Evpn.new(wire('011a' + long))
    assert_instance_of(BGP::Evpn::Unknown, m.route)
    assert_equal('011a' + long, m.to_shex,
                 'the extra octet replays rather than being dropped')
  end

  # And a route type 4 whose address length is not 32 or 128 still
  # resolves, because its own encode does reproduce those octets. So the
  # fallback is about what the class can represent, not about what the
  # RFC allows.
  def test_an_address_length_no_rfc_allows_still_resolves
    # 0416, then RD (8), ESI (10), a length octet of 24, three octets.
    n = BGP::Evpn.new(wire('0416' + '00000064000000c8' +
                           '00000000000000000000' + '18' + 'c00002'))
    assert_instance_of(BGP::Evpn::Ethernet_segment, n.route)
    assert_equal(24, n.route.ip.bitlen)
    assert_nil(n.route.ip.address, 'three octets are not a family')
  end

  # RFC 7911 section 3 prepends a Path Identifier to the NLRI.
  def test_a_path_identifier_prepends_four_octets
    n = BGP::Evpn.new_ntop(BGP::Evpn.new(unknown).encode, 7)
    assert(n.extended?)
    assert_equal('0000000709080011223344556677', n.to_shex)
    assert_equal(14, n.size)
    assert_equal(7, n.to_hash[:path_id])
    assert_equal(n.to_shex, BGP::Evpn.new(n.to_hash).to_shex)
  end

  def test_an_nlri_without_a_path_identifier_is_not_extended
    n = BGP::Evpn.new(unknown)
    refute(n.extended?)
    refute(n.to_hash.has_key?(:path_id))
  end

  # Nothing validates. A route type number the registry does not assign,
  # a zero length body and a body of 255 octets all build and encode.
  def test_nothing_validates
    assert_equal('fe00', BGP::Evpn.new(BGP::Evpn::Unknown.new(0xfe, '')).to_shex)
    assert_equal('0900', BGP::Evpn.new(BGP::Evpn::Unknown.new(9, '')).to_shex)
    big = BGP::Evpn.new(BGP::Evpn::Unknown.new(9, "\xaa".b * 255))
    assert_equal(255, big.length)
    assert_equal(257, big.encode.size)
    assert_equal(0, BGP::Evpn.new(BGP::Evpn::Unknown.new(0, '')).type)
  end

  def test_an_nlri_refuses_what_it_cannot_read
    assert_raise(ArgumentError) { BGP::Evpn.new }
    assert_raise(ArgumentError) { BGP::Evpn.new(42) }
    assert_raise(ArgumentError) { BGP::Evpn.new(:no_such_route_type => 1) }
  end

  def test_an_nlri_prints_its_route_and_its_path_identifier
    assert_equal('Unknown route type 9, 8 octets [0011223344556677]',
                 BGP::Evpn.new(unknown).to_s)
    n = BGP::Evpn.new_ntop(BGP::Evpn.new(unknown).encode, 7)
    assert_equal('[7] Unknown route type 9, 8 octets [0011223344556677]',
                 n.to_s)
  end

  def test_two_nlris_with_the_same_octets_are_equal
    assert_equal(BGP::Evpn.new(unknown), BGP::Evpn.new(unknown))
    refute_equal(BGP::Evpn.new(unknown), BGP::Evpn.new(unknown(10)))
    refute_equal(BGP::Evpn.new(unknown), 'not an Evpn')
  end

end
