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
require 'bgp/nlris/rt_constrain'
require 'bgp/path_attributes/mp_reach'
# IANA is a top level module and not BGP::IANA, so the plain name is the
# full one. Every other name below is written out, per Conventions.
require 'bgp/iana'

# RFC 4684 section 4, the Route Target membership NLRI.
#
# **There are no worked examples in RFC 4684**, which is worth saying
# because the flow spec tests lean on five of them in RFC 8955 and RFC
# 8956 and are stronger for it. Every expectation below is this reader's
# arithmetic from the section's figure and its two sentences about the
# length, so it checks that the library agrees with how the figure was
# read here, and not that the reading is right. What does check the
# reading from outside is a real router, and that belongs to a lab test
# the way the flow spec and EVPN ones do.
class Rt_constrain_test < Test::Unit::TestCase
  include BGP

  # Section 4's figure: origin as (4 octets) then route target (8), as a
  # prefix of 0 to 96 bits. So 0x60 is 96 bits and the twelve octets
  # that hold them, and 0x20 is the origin AS alone.
  WHOLE   = '60' + '0000fde8' + '0002fde800000064'
  AS_ONLY = '20' + '0000fde8'
  DEFAULT = '00'

  # "Route targets can then be expressed as prefixes, where, for
  # instance, a prefix would encompass all route target extended
  # communities assigned by a given Global Administrator". A two-octet
  # AS route target is type, sub-type, a 2-octet Global Administrator
  # and a 4-octet Local Administrator (RFC 4360 section 3.1), so that
  # prefix is the origin AS plus four of its eight octets: 64 bits.
  GLOBAL_ADMIN = '40' + '0000fde8' + '0002fde8'

  def test_the_three_shapes_section_4_describes
    assert_equal(DEFAULT, BGP::Rt_constrain.new.to_shex)
    assert_equal(AS_ONLY, BGP::Rt_constrain.new(65000).to_shex)
    assert_equal(WHOLE,
      BGP::Rt_constrain.new(65000, BGP::Route_target.new(65000, 100)).to_shex)
  end

  # "the default route target, which is encoded as a zero-length prefix"
  def test_the_default_route_target_is_a_zero_length_prefix
    rt = BGP::Rt_constrain.new
    assert(rt.default?)
    assert_equal(0, rt.mlen)
    assert_equal(DEFAULT, rt.to_shex)
    assert_equal('RT constrain: default', rt.to_s)
    assert_nil(rt.origin_as)
    assert_nil(rt.route_target)
  end

  def test_a_global_administrator_prefix_is_the_documented_partial_case
    rt = BGP::Rt_constrain.new(65000, BGP::Route_target.new(65000, 100), 64)
    assert_equal(GLOBAL_ADMIN, rt.to_shex)
    assert_equal(64, rt.mlen)
    assert_equal(65000, rt.origin_as)
    # Half the community is absent, so nothing claims to have read one.
    assert_nil(rt.route_target)
    assert_equal('0002fde8', rt.route_target_bits)
    assert_equal('RT constrain: 65000, route target 0002fde8/64', rt.to_s)
  end

  # The whole community is only there at 96 bits, and which community it
  # is comes from the octets rather than being assumed: section 4 names
  # no sub-type.
  def test_the_route_target_is_read_only_when_all_of_it_is_there
    whole = BGP::Rt_constrain.new(65000, BGP::Route_target.new(65000, 100))
    assert_equal(96, whole.mlen)
    assert_instance_of(BGP::Route_target, whole.route_target)
    assert_equal('Route target: 65000:100', whole.route_target.to_s)
    assert_nil(whole.route_target_bits)
    # Every length below 96 and not just every eighth. 89 to 95 bits all
    # occupy twelve octets, so the community's octets are all there and
    # only the length says the last of them are padding. Stepping by 8
    # skipped that whole band, and a sabotage that dropped the length
    # check from route_target passed because of it.
    (0..95).each do |mlen|
      short = BGP::Rt_constrain.new(65000, BGP::Route_target.new(65000, 100), mlen)
      assert_nil(short.route_target, "mlen #{mlen} must not read a route target")
    end
    assert_equal(12, (89..95).collect { |m|
      BGP::Rt_constrain.new(65000, BGP::Route_target.new(65000, 100), m)
        .to_shex.size / 2 - 1
    }.uniq.first, 'the band that makes the length check load bearing')
  end

  def test_the_origin_as_is_read_only_when_all_of_it_is_there
    assert_nil(BGP::Rt_constrain.new(65000, nil, 0).origin_as)
    assert_nil(BGP::Rt_constrain.new(65000, nil, 24).origin_as)
    assert_equal(65000, BGP::Rt_constrain.new(65000, nil, 32).origin_as)
  end

  # All three route target structures of RFC 4360 and RFC 5668, since
  # section 4 constrains the sub-type and not the structure.
  def test_every_route_target_structure_goes_in_whole
    {
      [65000, 100]      => '0002fde800000064',
      ['10.0.0.1', 7]   => '01020a0000010007',
      [100000, 1]       => '0202000186a00001',
    }.each do |args, value|
      rt = BGP::Rt_constrain.new(65000, BGP::Route_target.new(*args))
      assert_equal('60' + '0000fde8' + value, rt.to_shex, args.inspect)
      assert_equal('Route target: %s:%s' % args, rt.route_target.to_s)
    end
  end

  # A route target given as the object, as the 8 octets, as the 64-bit
  # Integer those answer with to_i, and as the pair Route_target takes.
  def test_a_route_target_is_taken_four_ways
    want = BGP::Rt_constrain.new(65000, BGP::Route_target.new(65000, 100)).to_shex
    [BGP::Route_target.new(65000, 100),
     ['0002fde800000064'].pack('H*'),
     BGP::Route_target.new(65000, 100).to_i,
     [65000, 100]].each do |rt|
      assert_equal(want, BGP::Rt_constrain.new(65000, rt).to_shex, rt.class.to_s)
    end
  end

  def test_the_wire_form_round_trips_and_replays
    [DEFAULT, AS_ONLY, WHOLE, GLOBAL_ADMIN].each do |hex|
      s = [hex].pack('H*').is_packed
      assert_equal(hex, BGP::Rt_constrain.new(s.dup).to_shex, hex)
    end
  end

  def test_another_instance_is_re_parsed_through_its_encode
    rt = BGP::Rt_constrain.new(65000, BGP::Route_target.new(65000, 100))
    assert_equal(rt.to_shex, BGP::Rt_constrain.new(rt).to_shex)
  end

  # Either the two named fields of the figure reproduce the octets, and
  # then the hash is those fields, or they do not and it is the length
  # and the octets. Every field the class carries is exercised.
  def test_the_hash_form_round_trips
    {
      BGP::Rt_constrain.new                                    => { :mlen => 0 },
      BGP::Rt_constrain.new(65000)                             => { :origin_as => 65000 },
      BGP::Rt_constrain.new(65000, BGP::Route_target.new(65000, 100)) =>
        { :origin_as => 65000, :route_target => { :route_target => [65000, 100] } },
      BGP::Rt_constrain.new(65000, BGP::Route_target.new(65000, 100), 64) =>
        { :mlen => 64, :value => '0000fde80002fde8' },
    }.each do |rt, want|
      assert_equal(want, rt.to_hash, rt.to_s)
      assert_equal(rt.to_shex, BGP::Rt_constrain.new(rt.to_hash).to_shex, rt.to_s)
    end
  end

  def test_a_path_id_rides_in_front_and_round_trips
    rt = BGP::Rt_constrain.new(65000, BGP::Route_target.new(65000, 100))
    rt.path_id = 7
    assert_equal('00000007' + WHOLE, rt.to_shex)
    assert_equal(7, rt.to_hash[:path_id])
    assert_equal(rt.to_shex, BGP::Rt_constrain.new(rt.to_hash).to_shex)
    assert_equal(7, BGP::Rt_constrain.new_ntop([WHOLE].pack('H*'), 7).path_id)
  end

  # The framing this family does not have to own. nlri_size is the
  # prefix arithmetic every other family already uses, and section 4's
  # encoding is that arithmetic, so there is no arm for SAFI 132 in
  # MpReachCommon and this is what says so.
  def test_the_framing_is_the_prefix_arithmetic_already_there
    { DEFAULT => 1, AS_ONLY => 5, WHOLE => 13, GLOBAL_ADMIN => 9 }.each do |hex, size|
      s = [hex].pack('H*')
      assert_equal(size, s.size, hex)
      assert_equal(size, BGP::Rt_constrain.nlri_size(s), hex)
      assert_equal(size, BGP::MpReachCommon::ClassMethods
                           .instance_method(:nlri_size)
                           .bind(BGP::Mp_reach)
                           .call(s, IANA::AFI::IPv4,
                                 IANA::SAFI::ROUTE_TARGET_CONSTRAINTS), hex)
    end
    assert_nil(BGP::Rt_constrain.nlri_size(''))
    assert_nil(BGP::Rt_constrain.nlri_size(nil))
  end

  # Per the conventions in CLAUDE.md. Section 4 says "the minimum prefix
  # length is 32 bits" except for the zero-length default, and the
  # prefix is "0 to 96 bits"; both are deviated from on purpose so a
  # test can put either on the wire and watch a router decide.
  def test_nothing_validates
    assert_equal(BGP::Rt_constrain::MIN_MLEN, 32)
    assert_equal(BGP::Rt_constrain::MAX_MLEN, 96)
    # A length section 4 forbids, between the zero-length default and 32.
    short = BGP::Rt_constrain.new(0xc0000000, nil, 16)
    assert_equal('10c000', short.to_shex)
    assert_equal(16, short.mlen)
    # And one above the 96 the section allows.
    over = BGP::Rt_constrain.new(65000, BGP::Route_target.new(65000, 100), 200)
    assert_equal(200, over.mlen)
    assert_equal(26, [over.to_shex].pack('H*').size)
    # Both replay, and both say what they are rather than printing as an
    # ordinary prefix.
    [short, over].each do |rt|
      assert_equal(rt.to_shex, BGP::Rt_constrain.new([rt.to_shex].pack('H*').is_packed).to_shex)
      assert_match(%r{/#{rt.mlen}\z}, rt.to_s)
    end
  end

  # A peer whose length octet asks for more octets than it sent. The
  # octets come back as they arrived rather than padded out to the
  # length claimed, so encode replays the capture.
  def test_fewer_octets_than_the_length_demanded_replay_as_they_arrived
    hex = '40' + '0000fde8' + '0002'   # 64 bits claimed, 6 octets sent
    rt = BGP::Rt_constrain.new([hex].pack('H*').is_packed)
    assert_equal(64, rt.mlen)
    assert_equal(hex, rt.to_shex)
    assert_equal('0002', rt.route_target_bits)
    assert_nil(rt.route_target)
    assert_equal(hex, BGP::Rt_constrain.new(rt.to_hash).to_shex)
  end

  # Building from field values pads to the length and zeroes the bits
  # past it, which is what an encoder does with a prefix's padding.
  # Parsing does neither, which the test above is about.
  def test_building_zeroes_the_bits_past_the_length
    # The route target's own octets start with its type and sub-type, so
    # the widest two-octet-AS one is 0002 then six ff, not eight. The
    # first version of this test assumed eight and the library was right:
    # at 60 bits the value is the origin AS and four octets of the
    # community, 0002ffff, with the last four bits zeroed to 0002fff0.
    rt = BGP::Rt_constrain.new(0xffffffff, BGP::Route_target.new(0xffff, 0xffffffff), 60)
    assert_equal('0002ffffffffffff', BGP::Route_target.new(0xffff, 0xffffffff).to_shex)
    assert_equal('3c' + 'ffffffff' + '0002fff0', rt.to_shex)
    assert_equal(8, [rt.to_shex].pack('H*').size - 1)
  end

  # The honest view of a prefix whose length no field of the figure
  # covers: the octets and the length, with nothing inferred.
  def test_bits_is_the_whole_prefix_and_its_length
    assert_equal(['0000fde80002fde800000064', 96],
                 BGP::Rt_constrain.new(65000, BGP::Route_target.new(65000, 100)).bits)
    assert_equal(['', 0], BGP::Rt_constrain.new.bits)
    # 16 bits is two octets, not one. Written as 'c0' first; the
    # library was right and this reader was not, for the second time in
    # this file. RFC 4684 gives no worked example to check against,
    # which is the whole reason that keeps happening.
    assert_equal(['c000', 16], BGP::Rt_constrain.new(0xc0000000, nil, 16).bits)
  end

  # A String means raw octets in a positional call and hex in a hash,
  # because that is what each context means everywhere else in the
  # library: an Rd or an Esi takes octets, and a hash carries them as hex
  # under :tail and :value. Both reach the same community.
  def test_a_string_route_target_is_octets_positionally_and_hex_in_a_hash
    want = BGP::Rt_constrain.new(65000, BGP::Route_target.new(65000, 100)).to_shex
    assert_equal(want,
      BGP::Rt_constrain.new(65000, ['0002fde800000064'].pack('H*')).to_shex)
    assert_equal(want,
      BGP::Rt_constrain.new(:origin_as => 65000,
                            :route_target => '0002fde800000064').to_shex)
  end

  # A constructor may refuse what it cannot represent, per Conventions,
  # and these are the three shapes that are not a route target at all.
  # Nothing here refuses a value that is merely wrong by the RFC.
  def test_a_route_target_that_is_not_one_is_refused
    assert_raise(ArgumentError) { BGP::Rt_constrain.new(65000, :nonsense) }
    assert_raise(ArgumentError) do
      BGP::Rt_constrain.new(:origin_as => 65000, :route_target => :nonsense)
    end
    # A wrapped hash has to name exactly one community, and the name has
    # to be one Extended_communities knows how to build.
    assert_raise(ArgumentError) do
      BGP::Rt_constrain.new(:origin_as => 65000,
                            :route_target => { :route_target => [1, 2],
                                               :route_origin => [3, 4] })
    end
    assert_raise(ArgumentError) do
      BGP::Rt_constrain.new(:origin_as => 65000,
                            :route_target => { :not_a_community => [1, 2] })
    end
  end

  def test_equality_is_the_octets
    a = BGP::Rt_constrain.new(65000, BGP::Route_target.new(65000, 100))
    b = BGP::Rt_constrain.new([WHOLE].pack('H*').is_packed)
    assert_equal(a, b)
    refute_equal(a, BGP::Rt_constrain.new(65000))
    refute_equal(a, WHOLE)
  end

end
