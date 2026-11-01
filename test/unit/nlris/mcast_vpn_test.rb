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

  # **This test's example has expired twice**, once when route types 1,
  # 2 and 5 landed and once when 3, 6 and 7 did, and both times it was
  # re-pointed rather than weakened, the way #185 re-pointed #116's
  # undecodable family. It originally asserted that every type reads as
  # Unknown, which was true only while ROUTES was empty.
  #
  # **NO_CLASS is picked so it cannot expire a third time.** 0x43 is
  # assigned, as the mLDP form of route type 3, and it is out of scope
  # by decision rather than by backlog: RFC 7441 defers its mLDP FEC
  # Element to RFC 6388 section 2.2, so the field belongs to LDP and
  # bgp4r has nothing of LDP. Route type 4 would have been the obvious
  # choice and lands in the next part, which is exactly the mistake
  # this constant avoids.
  NO_CLASS = 0x43

  def test_a_route_type_with_no_class_reads_back_as_unknown
    assert_equal([1, 2, 3, 5, 6, 7], M::ROUTES.keys.sort)
    assert(!M::ROUTES.has_key?(NO_CLASS), 'the mLDP types stay out of scope')
    [4, NO_CLASS].each do |t|
      n = M.new([format('%02x0c', t) + BODY].pack('H*').is_packed)
      assert_equal(M::Unknown, n.route.class, "route type #{t}")
      assert_equal(t, n.type)
      assert_equal(format('%02x0c', t) + BODY, n.to_shex)
    end
  end

  # The three types this part added, read back through the framing.
  # Every vector is computed with the library and pasted.
  REGISTERED = {
    '010c' + '00000064000000c8' + '0a000001' => M::Intra_as_i_pmsi,
    '0118' + '00000064000000c8' +
      '20010db8000000000000000000000001'     => M::Intra_as_i_pmsi,
    '020c' + '00000064000000c8' + '0000fde8' => M::Inter_as_i_pmsi,
    '0512' + '00000064000000c8' +
      '20c0000201' + '20e8010101'            => M::Source_active,
    '050e' + '00000064000000c8' +
      '00' + '20e8010101'                    => M::Source_active,
    '0316' + '00000064000000c8' +
      '20c0000201' + '20e8010101' +
      '0a000001'                             => M::S_pmsi,
    '033a' + '00000064000000c8' +
      '8020010db8000000000000000000000001' +
      '80ff3e0000000000000000000000000001' +
      '20010db8000000000000000000000002'     => M::S_pmsi,
    '0616' + '00000064000000c8' + '0000fde8' +
      '20c0000201' + '20e8010101'            => M::Shared_tree_join,
    '0716' + '00000064000000c8' + '0000fde8' +
      '20c0000201' + '20e8010101'            => M::Source_tree_join,
    '072e' + '00000064000000c8' + '0000fde8' +
      '8020010db8000000000000000000000001' +
      '80ff3e0000000000000000000000000001'   => M::Source_tree_join,
  }.freeze

  def test_the_three_registered_route_types_read_back_as_themselves
    REGISTERED.each do |hex, klass|
      n = M.new([hex].pack('H*').is_packed)
      assert_equal(klass, n.route.class, hex)
      assert_equal(hex, n.to_shex, "#{hex} must replay")
      assert_nil(n.declared_len, "#{hex} has an honest Length")
    end
  end

  def test_each_registered_route_type_round_trips_through_the_nlri_hash
    REGISTERED.each_key do |hex|
      n = M.new([hex].pack('H*').is_packed)
      assert_equal(hex, M.new(n.to_hash).to_shex, hex)
      assert_equal(hex, M.new(n).to_shex, hex)
    end
  end

  # The encode-matches rule, which is what keeps a registered type from
  # inventing the fields a short or long body does not hold. A route
  # type 2 body with two octets too many cannot be reproduced, so the
  # NLRI keeps the octets whole as an Unknown rather than dropping them.
  def test_a_body_a_registered_type_cannot_reproduce_falls_back_to_unknown
    hex = '020e' + '00000064000000c8' + '0000fde8' + 'ffff'
    n = M.new([hex].pack('H*').is_packed)
    assert_equal(M::Unknown, n.route.class)
    assert_equal(2, n.type, 'the type octet is still what arrived')
    assert_equal(hex, n.to_shex)
  end

  # Route type 2 is fixed at 12 octets, so a short body is the other
  # half of that rule.
  def test_a_body_too_short_for_a_registered_type_falls_back_too
    hex = '020a' + '00000064000000c8' + '00fd'
    n = M.new([hex].pack('H*').is_packed)
    assert_equal(M::Unknown, n.route.class)
    assert_equal(hex, n.to_shex)
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

  # **Re-pointed when route type 1 landed.** This used to assert the
  # :unknown hash shape for NLRI1, which was right while no route type
  # had a class. The shape claim moved to the unregistered type below;
  # what is asserted here is unchanged, that an NLRI rebuilds from its
  # own hash.
  def test_an_nlri_round_trips_through_its_own_hash
    n = M.new([NLRI1].pack('H*').is_packed)
    assert_equal({ :intra_as_i_pmsi => { :rd => [100, 200],
                                         :originator => '10.0.0.1' } },
                 n.to_hash)
    assert_equal(n.encode, M.new(n.to_hash).encode)
  end

  # And the :unknown shape, on a type that has no class.
  def test_an_unregistered_type_hashes_under_the_unknown_key
    hex = format('%02x0c', NO_CLASS) + BODY
    n = M.new([hex].pack('H*').is_packed)
    assert_equal({ :unknown => { :type => NO_CLASS, :value => BODY } },
                 n.to_hash)
    assert_equal(hex, M.new(n.to_hash).to_shex)
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

  # Re-pointed when route type 1 landed, as the hash shape test above
  # was: the registered type names itself now, and the Unknown wording
  # is asserted on a type that has no class.
  def test_to_s_names_the_route_it_holds
    n = M.new([NLRI1].pack('H*').is_packed)
    assert_match(/\[1\] Intra-AS I-PMSI A-D/, n.to_s)
    assert_match(/Unknown route type #{NO_CLASS}/,
                 M.new([format('%02x0c', NO_CLASS) + BODY]
                         .pack('H*').is_packed).to_s)
    assert_match(/\[7\]/, M.new_ntop([NLRI1].pack('H*'), 7).to_s,
                 'the path identifier is printed in front')
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
