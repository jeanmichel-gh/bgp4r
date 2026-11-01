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
require 'bgp/nlris/mcast_vpn'

# The MCAST-VPN NLRI of RFC 6514 section 4: a Route Type octet, a Length
# octet, and a Route Type specific field whose length that Length gives.
# docs/mcast-vpn.md is the guide.
#
# **No route type is implemented in this part**, so every body here
# reads back as an Mcast_vpn::Unknown that replays byte for byte. What
# is under test is the framing, which is what the two parse loops in
# mp_reach.rb and mp_unreach.rb will ask about once the wiring part
# lands.
#
# There are no worked examples in RFC 6514, so every expectation is this
# reader's arithmetic from the section 4 figure, computed with the
# library and pasted. See the note in mcast_vpn_route_test.rb.
#
# BGP:: names are written out in full, see Conventions in CLAUDE.md.
class Mcast_vpn_test < Test::Unit::TestCase

  M = BGP::Mcast_vpn

  # A route type 1 shaped body, which is what section 4.1 describes: an
  # RD of 8 octets then the Originating Router's IP Address. 12 octets,
  # so the Length is 0x0c and the NLRI is 14.
  BODY  = '00000064000000c8' + '0a000001'
  NLRI1 = '01' + '0c' + BODY

  def test_the_length_counts_the_body_alone
    assert_equal(2, M::FRAMING)
    assert_equal(255, M::MAX_LEN)
    n = M.new([NLRI1].pack('H*').is_packed)
    assert_equal(1, n.type)
    assert_equal(12, n.length)
    assert_equal(14, n.size)
    assert_equal(NLRI1, n.to_shex)
  end

  # What the two parse loops need in place of the prefix families'
  # (blen+7)/8+1. Both framing octets are included in the answer.
  def test_nlri_size_is_two_plus_the_length
    assert_equal(14, M.nlri_size([NLRI1].pack('H*')))
    assert_equal(2, M.nlri_size(['0100'].pack('H*')))
    assert_equal(257, M.nlri_size(['01ff'].pack('H*')))
  end

  # It answers nil rather than guessing, so a loop stops and lets the
  # leftover raise, which is how an attribute bgp4r cannot read still
  # becomes an Attr::Raw with an Attr::Gap.
  def test_nlri_size_answers_nil_for_octets_too_short_to_frame
    assert_nil(M.nlri_size(nil))
    assert_nil(M.nlri_size(''))
    assert_nil(M.nlri_size(['01'].pack('H*')))
  end

  # No route type is registered yet, so every type reads as Unknown.
  def test_every_route_type_reads_back_as_unknown_in_this_part
    assert_equal({}, M::ROUTES)
    (1..7).each do |t|
      n = M.new([format('%02x0c', t) + BODY].pack('H*').is_packed)
      assert_equal(M::Unknown, n.route.class, "route type #{t}")
      assert_equal(t, n.type)
      assert_equal(format('%02x0c', t) + BODY, n.to_shex)
    end
  end

  # The three mLDP types of RFC 7441, which are out of scope and replay
  # from here. 0x43, 0x44 and 0x47 are 67, 68 and 71.
  def test_the_three_mldp_route_types_replay_byte_for_byte
    [0x43, 0x44, 0x47].each do |t|
      hex = format('%02x06', t) + '010203040506'
      n = M.new([hex].pack('H*').is_packed)
      assert_equal(M::Unknown, n.route.class)
      assert_equal(t, n.type)
      assert_equal(hex, n.to_shex)
    end
  end

  # A Length that disagrees with the octets that came with it is kept,
  # so encode gives the peer's own Length back rather than correcting
  # it. Nothing validates.
  def test_a_length_that_overruns_its_octets_is_kept_and_echoed
    hex = '01ff' + '0a000001'
    n = M.new([hex].pack('H*').is_packed)
    assert_equal(255, n.declared_len)
    assert_equal(255, n.length)
    assert_equal(hex, n.to_shex)
  end

  def test_a_length_that_agrees_records_no_declared_length
    n = M.new([NLRI1].pack('H*').is_packed)
    assert_nil(n.declared_len)
  end

  # A body of nothing is a Length of 0, which section 4 does not
  # describe and which parses and replays.
  def test_an_empty_body_parses_and_replays
    n = M.new(['0100'].pack('H*').is_packed)
    assert_equal(0, n.length)
    assert_equal('0100', n.to_shex)
  end

  def test_four_ways_in
    n = M.new([NLRI1].pack('H*').is_packed)
    assert_equal(NLRI1, M.new(n).to_shex)
    assert_equal(NLRI1, M.new(n.to_hash).to_shex)
    assert_equal(NLRI1, M.new(M::Unknown.new(1, [BODY].pack('H*'))).to_shex)
    assert_equal(NLRI1,
                 M.new(:unknown => { :type => 1, :value => BODY }).to_shex)
  end

  def test_an_nlri_round_trips_through_its_own_hash
    n = M.new([NLRI1].pack('H*').is_packed)
    assert_equal({ :unknown => { :type => 1, :value => BODY } }, n.to_hash)
    assert_equal(n.encode, M.new(n.to_hash).encode)
  end

  # A kept Length rides in the hash as one more key, the way a tail and
  # reserved bits do elsewhere, so no key means an ordinary NLRI.
  def test_a_kept_length_rides_in_the_hash_and_only_then
    hex = '01ff' + '0a000001'
    n = M.new([hex].pack('H*').is_packed)
    assert_equal(255, n.to_hash[:length])
    assert_equal(hex, M.new(n.to_hash).to_shex)
    assert(!M.new([NLRI1].pack('H*').is_packed).to_hash.has_key?(:length))
  end

  # RFC 7911 section 3 prepends a Path Identifier, so an extended NLRI
  # is four octets longer.
  def test_a_path_identifier_rides_in_front
    n = M.new_ntop([NLRI1].pack('H*'), 7)
    assert(n.extended?)
    assert_equal(7, n.path_id)
    assert_equal('00000007' + NLRI1, n.to_shex)
    assert_equal(18, n.size)
    assert_equal(7, n.to_hash[:path_id])
    assert_equal('00000007' + NLRI1, M.new(n.to_hash).to_shex)
  end

  def test_an_nlri_with_no_path_identifier_has_no_key_for_one
    n = M.new_ntop([NLRI1].pack('H*'))
    assert(!n.extended?)
    assert(!n.to_hash.has_key?(:path_id))
  end

  def test_equality_is_the_octets
    a = M.new([NLRI1].pack('H*').is_packed)
    b = M.new([NLRI1].pack('H*').is_packed)
    assert_equal(a, b)
    assert_not_equal(a, M.new(['0100'].pack('H*').is_packed))
    assert_not_equal(a, NLRI1)
  end

  def test_an_nlri_refuses_an_argument_it_cannot_read
    assert_raise(ArgumentError) { M.new }
    assert_raise(ArgumentError) { M.new(42) }
    assert_raise(ArgumentError) { M.new(:no_such_route_type => 1) }
  end

  def test_to_s_names_the_route_it_holds
    n = M.new([NLRI1].pack('H*').is_packed)
    assert_match(/Unknown route type 1/, n.to_s)
    assert_match(/\[7\]/, M.new_ntop([NLRI1].pack('H*'), 7).to_s)
  end

  # Building from an instance must not empty it, since parse reads with
  # slice!.
  def test_building_from_an_instance_leaves_it_whole
    n = M.new([NLRI1].pack('H*').is_packed)
    M.new(n)
    assert_equal(NLRI1, n.to_shex)
  end

  # The framing is recursive, which route type 4 needs: a Route Key read
  # as a whole nested NLRI has its extent in its own Length octet. That
  # reading is settled in a later part; what is asserted here is only
  # that nlri_size can already answer for a nested one.
  def test_the_framing_can_already_answer_for_a_nested_nlri
    inner = NLRI1
    outer = '04' + format('%02x', inner.size / 2 + 4) + inner + '0a000002'
    assert_equal(inner.size / 2, M.nlri_size([inner].pack('H*')))
    n = M.new([outer].pack('H*').is_packed)
    assert_equal(4, n.type)
    assert_equal(outer, n.to_shex)
    assert_equal(inner.size / 2 + 4, n.length)
  end

end
