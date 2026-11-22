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
require 'bgp4r'

# draft-tantsura-idr-unreachability-safi-06, SAFI 81. The hex below is
# the draft's own, from sections 3.6.1, 3.6.2 and Appendix B, so these
# tests fail if the codec and the draft part ways.
class TestBgpUnreachability < Test::Unit::TestCase

  include BGP

  U = Unreachability

  # Section 3.6.1, "Hexadecimal encoding", the two lines joined.
  SINGLE = '001F18C000020100' \
           '18C63364010000FDE9010002000302000800000000675786D8'

  def packed(hex)
    [hex.delete(' ')].pack('H*')
  end

  def reporter(id, as, reason, time)
    U::Reporter.new(id, as, U::Reason_code.new(reason), U::Timestamp.new(time))
  end

  # ---- the draft's examples --------------------------------------------

  def test_section_3_6_1_single_reporter_from_the_wire
    u = U.new(packed(SINGLE), 1)
    assert_equal '192.0.2.0/24', u.prefix
    assert_equal 1, u.reporters.size
    r = u.reporters.first
    assert_equal '198.51.100.1', r.identifier
    assert_equal 65001, r.as
    assert_equal 3, r.reason
    assert_equal 'RPKI Invalid', r.sub_tlvs.first.name
    assert_equal 1733789400, r.timestamp
    assert_equal 24, r.length
    assert_equal SINGLE.downcase, u.to_shex
  end

  def test_section_3_6_1_single_reporter_from_values
    u = U.new('192.0.2.0/24', reporter('198.51.100.1', 65001, 3, 1733789400))
    assert_equal SINGLE.downcase, u.to_shex
  end

  # Section 3.6.2 gives fields, not hex: two reporters of 27 octets and
  # "Total NLRI length ... 4 + 27 + 27 = 58 octets".
  def test_section_3_6_2_multiple_reporters
    u = U.new('192.0.2.0/24',
              reporter('198.51.100.1', 65001, 3, 1733789400),
              reporter('198.51.100.2', 65002, 1, 1733789410))
    assert_equal 58, u.encode.unpack1('n')
    assert_equal [27, 27], u.reporters.collect(&:size)
    back = U.new(u.encode.is_packed, 1)
    assert_equal [['198.51.100.1', 65001], ['198.51.100.2', 65002]],
                 back.reporters.collect(&:key)
    assert_equal [3, 1], back.reporters.collect(&:reason)
  end

  # Appendix B.1: MP_REACH_NLRI with AFI 1, SAFI 81 and Next Hop Length 0.
  def test_appendix_b_1_mp_reach_has_no_next_hop
    mp = Mp_reach.new(:safi => 81, :nlris => [U.new(packed(SINGLE), 1)])
    value = mp.encode.byteslice(3..)
    assert_equal [1, 81, 0], value.unpack('nCC')
    back = Mp_reach.new(mp.encode.is_packed)
    assert_equal 81, back.safi
    assert_equal 1, back.afi
    assert_equal SINGLE.downcase, back.nlris.first.to_shex
  end

  # Appendix B.3: the withdrawal, "NLRI Length: 4" for 192.0.2.0/24.
  def test_appendix_b_3_withdrawal
    mp = Mp_unreach.new(:afi => 1, :safi => 81, :nlris => [{ :prefix => '192.0.2.0/24' }])
    assert_equal '0004' + '18c00002', mp.encode.byteslice(6..).unpack1('H*')
    back = Mp_unreach.new(mp.encode.is_packed)
    assert back.nlris.first.withdrawal?
    assert_equal '192.0.2.0/24', back.nlris.first.prefix
  end

  # ---- four ways in ----------------------------------------------------

  def test_four_ways_give_the_same_octets
    wire = U.new(packed(SINGLE), 1)
    from_values = U.new('192.0.2.0/24', reporter('198.51.100.1', 65001, 3, 1733789400))
    from_hash = U.new(wire.to_hash)
    from_instance = U.new(wire)
    [from_values, from_hash, from_instance].each do |u|
      assert_equal wire.to_shex, u.to_shex
    end
  end

  def test_the_reporter_shortcut_hash
    r = U::Reporter.new(:identifier => '198.51.100.1', :as => 65001,
                        :reason => 3, :timestamp => 1733789400)
    assert_equal reporter('198.51.100.1', 65001, 3, 1733789400).to_shex, r.to_shex
    assert_equal({ :reporter => { :identifier => '198.51.100.1', :as => 65001,
                   :sub_tlvs => [{ :reason_code => 3 }, { :timestamp => 1733789400 }] } },
                 r.to_hash)
  end

  def test_to_hash_round_trips
    [U.new(packed(SINGLE), 1),
     U.new('2001:db8::/32', reporter('198.51.100.1', 65001, 9, 1)),
     U.new('192.0.2.0/24'),
     U.new(:afi => 1, :mlen => 33, :value => 'c000020001')].each do |u|
      assert_equal u.to_shex, U.new(u.to_hash).to_shex, u.to_s
    end
    r = U::Reporter.new(:identifier => '10.0.0.1', :as => 1, :tail => 'ff')
    assert_equal r.to_shex, U::Reporter.new(r.to_hash).to_shex
    rc = U::Reason_code.new(64536)
    assert_equal rc.to_shex, U::Reason_code.new(rc.to_hash).to_shex
    ts = U::Timestamp.new(1733789400)
    assert_equal ts.to_shex, U::Timestamp.new(ts.to_hash).to_shex
    un = U::Tlv::Unknown.new(200, "\x01\x02")
    assert_equal un.to_shex, U::Tlv::Unknown.new(un.to_hash).to_shex
  end

  # ---- IPv6, path ID, AFI ----------------------------------------------

  def test_ipv6
    u = U.new('2001:db8::/32', reporter('198.51.100.1', 65001, 9, 1733789400))
    assert_equal 2, u.afi
    back = U.new(u.encode.is_packed, 2)
    assert_equal '2001:db8::/32', back.prefix
    mp = Mp_reach.new(:safi => 81, :nlris => [u])
    assert_equal 2, mp.afi
  end

  # RFC 7911 section 3: the Path Identifier comes before the NLRI Length,
  # and section 3.2 says it is not counted.
  def test_path_id_precedes_the_nlri_length
    u = U.new(packed(SINGLE), 1)
    u.path_id = 7
    assert_equal '00000007' + SINGLE.downcase, u.to_shex
    mp = Mp_reach.new(:safi => 81, :path_id => 7, :nlris => [U.new(packed(SINGLE), 1).to_hash])
    back = Mp_reach.new(mp.encode.is_packed, true)
    assert_equal 7, back.nlris.first.path_id
  end

  # ---- nothing validates: what a peer may send replays -----------------

  def test_an_unknown_sub_tlv_replays
    hex = '0012' + '18c00002' + '01000b' + 'c6336401' + '0000fde9' + 'c80000'
    u = U.new(packed(hex), 1)
    assert_kind_of U::Tlv::Unknown, u.reporters.first.sub_tlvs.first
    assert_equal 0, u.reporters.first.reason
    assert_equal hex, u.to_shex
  end

  def test_an_unknown_reporter_tlv_type_replays
    hex = '0009' + '18c00002' + '070001' + 'ff'
    u = U.new(packed(hex), 1)
    assert_equal 7, u.reporters.first.type
    assert_equal [], u.reporter_tlvs
    assert_equal hex, u.to_shex
  end

  def test_a_short_reporter_is_kept_as_unknown_type_1
    hex = '000e' + '18c00002' + '010007' + 'c63364010000fd'
    u = U.new(packed(hex), 1)
    assert_kind_of U::Tlv::Unknown, u.reporters.first
    assert_equal 1, u.reporters.first.type
    assert_equal hex, u.to_shex
  end

  def test_a_sub_tlv_of_the_wrong_size_replays
    hex = '0013' + '18c00002' + '01000c' + 'c63364010000fde9' + '010001' + '03'
    u = U.new(packed(hex), 1)
    assert_kind_of U::Tlv::Unknown, u.reporters.first.sub_tlvs.first
    assert_equal hex, u.to_shex
  end

  def test_lengths_that_lie_replay
    hex = '00ff' + '18c00002'
    u = U.new(packed(hex), 1)
    assert_equal 255, u.declared_len
    assert_equal hex, u.to_shex
    assert_equal hex, U.new(u.to_hash).to_shex
  end

  def test_a_prefix_length_past_the_family_builds_and_replays
    u = U.new(:afi => 1, :mlen => 33, :value => 'c000020001',
              :reporters => [reporter('198.51.100.1', 65001, 3, 1)])
    assert_nil u.prefix
    assert_equal u.to_shex, U.new(u.encode.is_packed, 1).to_shex
  end

  def test_reasons
    assert_equal 'Local Link Down', U.reason_name(9)
    assert_equal 'Unassigned', U.reason_name(10)
    assert_equal 'Private Use', U.reason_name(64536)
  end

  def test_what_cannot_be_represented_is_refused
    assert_raise(ArgumentError) { U::Reason_code.new(65536) }
    assert_raise(ArgumentError) { U::Reporter.new('10.0.0.1', 2**32) }
    assert_raise(ArgumentError) { U::Tlv::Unknown.new(256, '') }
  end

  def test_registries_refuse_a_second_class_for_a_type
    klass = Class.new(U::Tlv) { const_set(:TYPE, 1); const_set(:HASH_KEY, :other) }
    assert_raise(ArgumentError) { U::SUB_TLVS.register(klass) }
  end

  def test_to_s
    u = U.new(packed(SINGLE), 1)
    assert_match(/192\.0\.2\.0\/24/, u.to_s)
    assert_match(/reporter 198\.51\.100\.1 AS65001, reason RPKI Invalid \(3\), at 2024-12-10T00:10:00Z/, u.to_s)
  end

end
