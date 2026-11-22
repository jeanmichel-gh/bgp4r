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

# draft-tantsura-bess-evpn-unreachability-02, the IP Prefix
# Unreachability route, type 254 (provisional). The hex is the draft's
# Appendix A, with the draft's TT replaced by FE.
class TestEvpnIpPrefixUnreachability < Test::Unit::TestCase

  include BGP

  R = Evpn::Ip_prefix_unreachability
  U = Unreachability

  # Example 1 as the draft prints it has 51 octets where 2 + Length (48)
  # is 50: fifteen zero octets for the ESI and Ethernet Tag where there
  # are fourteen (review note 2 in docs/design/unreachability.md). This
  # is it with one zero removed.
  EXAMPLE_1 = 'FE 30 00 01 C6 33 64 01 00 64 00 00 00 00 00 00 ' \
              '00 00 00 00 00 00 00 00 01 18 C0 00 02 00 00 00 ' \
              '00 00 01 00 0D C6 33 64 01 00 00 FD E9 01 00 02 00 04'

  EXAMPLE_1_AS_PRINTED =
              'FE 30 00 01 C6 33 64 01 00 64 00 00 00 00 00 00 ' \
              '00 00 00 00 00 00 00 00 00 01 18 C0 00 02 00 00 00 ' \
              '00 00 01 00 0D C6 33 64 01 00 00 FD E9 01 00 02 00 04'

  EXAMPLE_2 = 'FE 71 00 01 C6 33 64 01 00 64 00 00 00 00 00 00 ' \
              '00 00 00 00 00 00 00 00 01 18 C6 33 64 00 00 00 ' \
              '00 00 01 00 18 C6 33 64 01 00 00 FD E9 01 00 02 ' \
              '00 08 02 00 08 00 00 00 00 65 9B 3B 00 01 00 18 ' \
              'C6 33 64 02 00 00 FD E9 01 00 02 00 08 02 00 08 ' \
              '00 00 00 00 65 9B 3B 05 01 00 18 C6 33 64 03 00 ' \
              '00 FD E9 01 00 02 00 08 02 00 08 00 00 00 00 65 ' \
              '9B 3B 08'

  EXAMPLE_3 = 'FE 3C 00 01 C6 33 64 01 00 64 00 00 00 00 00 00 ' \
              '00 00 00 00 00 00 00 00 02 20 20 01 0D B8 00 00 ' \
              '00 00 00 00 00 00 00 00 00 00 00 00 00 00 01 00 ' \
              '0D C6 33 64 01 00 00 FD E9 01 00 02 00 09'

  def packed(hex)
    [hex.delete(' ')].pack('H*').is_packed
  end

  def hex(s)
    s.delete(' ').downcase
  end

  def reporter(id, reason, time = nil)
    subs = [U::Evpn_reason_code.new(reason)]
    subs << U::Timestamp.new(time) if time
    U::Evpn_reporter.new(id, 65001, *subs)
  end

  # ---- the draft's examples --------------------------------------------

  def test_example_1_minimal
    e = Evpn.new(packed(EXAMPLE_1))
    r = e.route
    assert_instance_of R, r
    assert_equal 254, e.type
    assert_equal 48, e.length
    assert_equal '198.51.100.1:100', r.rd.to_s(false).sub('RD=', '')
    assert_equal 1, r.address_family
    assert_equal '192.0.2.0/24', r.ip_prefix
    assert_equal 1, r.reporters.size
    assert_equal 4, r.reporters.first.reason
    assert_equal 'No Export Policy', r.reporters.first.sub_tlvs.first.name
    assert_equal 13, r.reporters.first.length
    assert_equal hex(EXAMPLE_1), e.to_shex
  end

  # The example as printed: its Length says 48 and 49 octets follow, so
  # the route is not 48 octets of this type, and the codec keeps it as
  # an Unknown that replays the one extra octet as a second NLRI's start.
  def test_example_1_as_printed_is_one_octet_too_long
    s = packed(EXAMPLE_1_AS_PRINTED)
    assert_equal 51, s.size
    assert_equal 0x30, s.getbyte(1)
    assert_equal 2 + 0x30 + 1, s.size
  end

  def test_example_1_from_values
    r = R.new(Rd.new('198.51.100.1', 100), nil, nil, '192.0.2.0/24',
              [reporter('198.51.100.1', 4)])
    assert_equal hex(EXAMPLE_1), Evpn.new(r).to_shex
  end

  def test_example_2_three_reporters
    e = Evpn.new(packed(EXAMPLE_2))
    r = e.route
    assert_equal 113, e.length
    assert_equal '198.51.100.0/24', r.ip_prefix
    assert_equal %w[198.51.100.1 198.51.100.2 198.51.100.3],
                 r.reporters.collect(&:identifier)
    assert_equal [1704672000, 1704672005, 1704672008], r.reporters.collect(&:timestamp)
    assert_equal [8, 8, 8], r.reporters.collect(&:reason)
    assert_equal hex(EXAMPLE_2), e.to_shex
  end

  def test_example_3_ipv6
    e = Evpn.new(packed(EXAMPLE_3))
    r = e.route
    assert_equal 60, e.length
    assert r.ipv6?
    assert_equal '2001:db8::/32', r.ip_prefix
    assert_equal 'Local Link Down', r.reporters.first.sub_tlvs.first.name
    assert_equal hex(EXAMPLE_3), e.to_shex
  end

  # Example 4: the route inside MP_REACH_NLRI, AFI 25 SAFI 70, next hop
  # 198.51.100.1, with a Reason and a Timestamp: Length 59.
  def test_example_4_in_mp_reach
    r = R.new(:rd => ['198.51.100.1', 100], :ip_prefix => '192.0.2.0/24',
              :reporters => [{ :reporter => { :identifier => '198.51.100.1', :as => 65001,
                                              :reason => 3, :timestamp => 1733789400 } }])
    assert_equal 59, Evpn.new(r).length
    mp = Mp_reach.new(:afi => 25, :safi => 70, :nexthop => '198.51.100.1', :nlris => [Evpn.new(r)])
    back = Mp_reach.new(mp.encode.is_packed)
    assert_instance_of R, back.nlris.first.route
    assert_equal mp.to_shex, back.to_shex
    assert_equal [], Path_attribute.new(mp.encode.is_packed).errors
  end

  # Example 6: the withdrawal, the key fields without reporters, Length 32.
  def test_example_6_withdrawal
    r = R.new(Rd.new('198.51.100.1', 100), nil, nil, '192.0.2.0/24')
    e = Evpn.new(r)
    assert_equal 32, e.length
    assert r.withdrawal?
    mp = Mp_unreach.new(:afi => 25, :safi => 70, :nlris => [e])
    back = Mp_unreach.new(mp.encode.is_packed)
    assert_instance_of R, back.nlris.first.route
    assert_equal [], Path_attribute.new(mp.encode.is_packed).errors
  end

  # ---- four ways in ----------------------------------------------------

  def test_four_ways_give_the_same_octets
    wire = R.new(packed(EXAMPLE_2).byteslice(2..).is_packed)
    [R.new(wire.to_hash), R.new(wire), Evpn.new(Evpn.new(packed(EXAMPLE_2)).to_hash).route].each do |r|
      assert_equal wire.to_shex, r.to_shex
    end
  end

  def test_to_hash_round_trips_odd_routes
    odd = R.new(:rd => ['10.0.0.1', 1], :esi => '00:11:22:33:44:55:66:77:88:99',
                :ethernet_tag_id => 7,
                :ip_prefix => { :address_family => 1, :len => 40, :octets => 'c0000201' },
                :gateway => '0a000001', :mpls_label => 16, :tail => 'ff',
                :reporters => [{ :reporter => { :identifier => '10.0.0.2', :as => 1,
                                 :sub_tlvs => [{ :evi => 100 }, { :reason_code => 12 }] } }])
    assert_equal odd.to_shex, R.new(odd.to_hash).to_shex
    assert_equal odd.to_shex, R.new(odd.encode.is_packed).to_shex
    assert_nil odd.ip_prefix
  end

  # ---- EVPN's own sub-TLV ----------------------------------------------

  def test_the_evi_sub_tlv
    r = U::Evpn_reporter.new('198.51.100.1', 65001, U::Evi.new(100))
    assert_equal 100, r.evi
    assert_equal '01000fc63364010000fde9' + '03000400000064', r.to_shex
    back = R.new(R.new(nil, nil, nil, '192.0.2.0/24', [r]).encode.is_packed)
    assert_instance_of U::Evi, back.reporters.first.sub_tlvs.first
    e = U::Evi.new(7)
    assert_equal e.to_shex, U::Evi.new(e.to_hash).to_shex
  end

  # Under SAFI 81 type 3 is unassigned, so the same octets read as an
  # Unknown there.
  def test_the_evi_is_unknown_under_safi_81
    r = U::Reporter.new(['c63364010000fde9' + '03000400000064'].pack('H*'))
    assert_instance_of U::Tlv::Unknown, r.sub_tlvs.first
  end

  def test_evpn_reason_names
    assert_equal 'VTEP Unreachable', U::Evpn_reason_code.new(12).name
    assert_equal 'Unassigned', U::Reason_code.new(12).name
    rc = U::Evpn_reason_code.new(10)
    assert_equal rc.to_shex, U::Evpn_reason_code.new(rc.to_hash).to_shex
  end

  def test_the_reporter_shortcut_uses_the_evpn_reason_code
    r = U::Evpn_reporter.new(:identifier => '10.0.0.1', :as => 1, :reason => 11)
    assert_instance_of U::Evpn_reason_code, r.sub_tlvs.first
    assert_equal r.to_shex, U::Evpn_reporter.new(r.to_hash).to_shex
  end

  # ---- what does not read as this route replays -------------------------

  def test_an_address_family_other_than_1_or_2_reads_as_unknown
    s = packed(EXAMPLE_1)
    s.setbyte(2 + 22, 3)
    e = Evpn.new(s.dup.is_packed)
    assert_instance_of Evpn::Unknown, e.route
    assert_equal s.unpack1('H*'), e.to_shex
  end

  def test_a_non_zero_gateway_and_label_replay
    r = R.new(:rd => ['10.0.0.1', 1], :ip_prefix => '192.0.2.0/24',
              :gateway => '0a000001', :mpls_label => 16,
              :reporters => [reporter('10.0.0.2', 1)])
    e = Evpn.new(r.encode.then { |b| [254, b.size].pack('CC') + b }.is_packed)
    assert_instance_of R, e.route
    assert_equal '0a000001', e.route.gw_octets.unpack1('H*')
    assert_equal 16, e.route.mpls_label
  end

  # RFC 7432 section 7's one-octet Length: 21 reporters of 11 octets
  # after IPv4's 32 is 263, which does not fit.
  def test_a_route_past_255_octets_is_refused
    fits = R.new(nil, nil, nil, '192.0.2.0/24',
                 (1..20).collect { |i| U::Evpn_reporter.new("10.0.0.#{i}", 1) })
    assert_equal 252, Evpn.new(fits).length
    assert_nothing_raised { Evpn.new(fits).encode }
    over = R.new(nil, nil, nil, '192.0.2.0/24',
                 (1..21).collect { |i| U::Evpn_reporter.new("10.0.0.#{i}", 1) })
    assert_raise(ArgumentError) { Evpn.new(over).encode }
  end

  def test_what_cannot_be_represented_is_refused
    assert_raise(ArgumentError) { U::Evi.new(2**32) }
    assert_raise(ArgumentError) { R.new(:mpls_label => 2**24) }
  end

  def test_to_s
    s = Evpn.new(packed(EXAMPLE_1)).to_s
    assert_match(/\[254\] IP Prefix Unreachability: RD=198\.51\.100\.1:100/, s)
    assert_match(/prefix 192\.0\.2\.0\/24/, s)
    assert_match(/reporter 198\.51\.100\.1 AS65001, reason No Export Policy \(4\)/, s)
  end

  # ---- findings ----------------------------------------------------------

  def reach_errors(route_hex)
    mp = Mp_reach.new(:afi => 25, :safi => 70, :nexthop => '10.0.0.1',
                      :nlris => [Evpn.new(packed(route_hex))])
    Path_attribute.new(mp.encode.is_packed).errors
  end

  def strongest(route_hex)
    f = reach_errors(route_hex)
    s = Attr.strongest(f)
    s ? [s.subcode, s.action] : f.collect { |x| [x.subcode, x.action] }
  end

  def test_the_examples_have_no_findings
    [EXAMPLE_1, EXAMPLE_2, EXAMPLE_3].each { |x| assert_equal [], reach_errors(x) }
  end

  def test_findings_4_11_1_reset
    af3 = packed(EXAMPLE_1).tap { |s| s.setbyte(24, 3) }.unpack1('H*')
    assert_equal [9, :session_reset], strongest(af3)
    plen = packed(EXAMPLE_1).tap { |s| s.setbyte(25, 33) }.unpack1('H*')
    assert_equal [9, :session_reset], strongest(plen)
    short = 'fe10' + '00' * 16
    assert_equal [9, :session_reset], strongest(short)
  end

  def test_findings_4_11_2_treat_as_withdraw
    esi = packed(EXAMPLE_1).tap { |s| s.setbyte(12, 1) }.unpack1('H*')
    assert_equal [9, :treat_as_withdraw], strongest(esi)
    label = packed(EXAMPLE_1).tap { |s| s.setbyte(33, 1) }.unpack1('H*')
    assert_equal [9, :treat_as_withdraw], strongest(label)
    bare = hex(EXAMPLE_1)[0, 2] + '20' + hex(EXAMPLE_1)[4, 64]
    assert_equal [9, :treat_as_withdraw], strongest(bare)
    assert_match(/4\.11\.2/, reach_errors(bare).first.reason)
  end

  def test_findings_4_11_3_a_malformed_reporter
    short = hex(EXAMPLE_1)[0, 2] + '26' + hex(EXAMPLE_1)[4, 64] + '010003' + 'c63364'
    f = reach_errors(short)
    assert_equal [9, :treat_as_withdraw], [Attr.strongest(f).subcode, Attr.strongest(f).action]
    assert_match(/4\.11\.3/, f.last.reason)
  end

  def test_an_evi_of_the_wrong_size_is_a_sub_tlv_finding
    bad = hex(EXAMPLE_1)[0, 2] + '38' + hex(EXAMPLE_1)[4, 64] +
          '010015c63364010000fde9' + '030005' + '0000000064' + '010002' + '0004'
    f = reach_errors(bad)
    assert_equal [[nil, nil]], f.collect { |x| [x.subcode, x.action] }
    assert_match(/type 3 Length 5, must be 4/, f.first.reason)
  end

end
