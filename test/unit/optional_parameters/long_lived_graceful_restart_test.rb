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

class Long_lived_graceful_restart_cap_Test < Test::Unit::TestCase

  LLGR = BGP::OPT_PARM::CAP::Long_lived_graceful_restart

  # RFC 9494 section 3.1: code 71, then per family AFI (16 bits), SAFI
  # (8 bits), Flags (8 bits) and the Long-Lived Stale Time (24 bits).
  # IPv4 unicast, F bit set, 3600 seconds: 0001 01 80 000e10.
  WIRE = '0209470700010180000e10'

  def test_the_capability_code_is_71_and_a_tuple_is_seven_octets
    assert_equal 71, BGP::OPT_PARM::CAP_LLGR
    cap = LLGR.new(1, 1, 0x80, 3600)
    assert_equal WIRE, cap.to_shex
    assert_equal 7, cap.encode.size - 4
    assert_equal [[1, 1, 0x80, 3600]], cap.tuples
  end

  # Zero tuples is allowed: section 3.1 says "zero or more".
  def test_no_tuple
    assert_equal '02024700', LLGR.new.to_shex
    assert_equal({:code=>71, :capability=>{:families=>[]}}, LLGR.new.to_hash)
  end

  def test_names_and_symbols
    assert_equal WIRE, LLGR.new(:ipv4, :unicast, :preserved, 3600).to_shex
    assert_equal '0209470700020100000e10',
                 LLGR.new(:ipv6, :unicast, :not_preserved, 3600).to_shex
  end

  def test_the_three_build_paths
    from_fields = LLGR.new(1, 1, 0x80, 3600).add(2, 1, 0, 300)
    hex = from_fields.to_shex
    from_wire = LLGR.new([hex].pack('H*'))
    from_hash = LLGR.new(from_fields.to_hash)
    assert_equal({:code=>71, :capability=>{:families=>[
                   {:afi=>1, :safi=>1, :flags=>0x80, :llst=>3600},
                   {:afi=>2, :safi=>1, :flags=>0, :llst=>300}]}},
                 from_fields.to_hash)
    [from_wire, from_hash].each { |cap| assert_equal hex, cap.to_shex }
    # The inner hash alone, as Graceful_restart takes it.
    assert_equal hex, LLGR.new(from_fields.to_hash[:capability]).to_shex
  end

  # The LLST is 24 bits wide. A value that fills it writes all three
  # octets, and one that does not fit is refused rather than truncated.
  def test_the_stale_time_is_24_bits
    cap = LLGR.new(1, 1, 0, 0xabcdef)
    assert_equal '0209470700010100abcdef', cap.to_shex
    assert_equal 0xabcdef, LLGR.new([cap.to_shex].pack('H*')).tuples[0][3]
    assert_raise(ArgumentError) { LLGR.new(1, 1, 0, 0x1000000) }
    assert_raise(ArgumentError) { LLGR.new(1, 1, 0, -1) }
    assert_raise(ArgumentError) { LLGR.new(1, 1, 0x100, 0) }
  end

  # Bits 1 to 7 of the Flags are reserved: "MUST be set to zero by the
  # sender and ignored by the receiver". The octet is kept whole, so a
  # reserved bit that arrived set replays and is named in to_s.
  def test_a_reserved_flag_bit_is_kept
    hex = '0209470700010141000e10'
    cap = LLGR.new([hex].pack('H*'))
    assert_equal hex, cap.to_shex
    assert_equal 0x41, cap.tuples[0][2]
    assert_equal false, cap.preserved?(1, 1)
    assert_match(/reserved bits 0x41/, cap.to_s)
    assert_equal hex, LLGR.new(cap.to_hash).to_shex
  end

  # Octets after the last whole tuple are kept and written back.
  def test_a_short_last_tuple_is_kept_as_a_tail
    hex = '020b470900010180000e10aabb'
    cap = LLGR.new([hex].pack('H*'))
    assert_equal 1, cap.tuples.size
    assert_equal 'aabb', cap.to_hash[:capability][:tail]
    assert_equal hex, cap.to_shex
    assert_equal hex, LLGR.new(cap.to_hash).to_shex
    assert_equal Encoding::BINARY, cap.tail.encoding
    assert_equal Encoding::BINARY, LLGR.new.tail.encoding
  end

  # Section 4.2: a family not listed in the capability has a stale time
  # of zero.
  def test_a_family_not_listed_has_a_stale_time_of_zero
    cap = LLGR.new(1, 1, 0x80, 3600)
    assert_equal 3600, cap.stale_time(:ipv4, :unicast)
    assert_equal 0, cap.stale_time(:ipv6, :unicast)
    assert cap.preserved?(1, 1)
    assert_equal false, cap.preserved?(2, 1)
  end

  # It read as Capability::Unknown before, which is what FRR's OPEN
  # showed in the lab.
  def test_the_factory_reads_it_by_name
    cap = BGP::OPT_PARM::Capability.factory([WIRE].pack('H*'))
    assert_instance_of LLGR, cap
    assert_equal WIRE, cap.to_shex
    assert_instance_of LLGR, BGP::OPT_PARM::Capability.from_hash(LLGR.new(1, 1).to_hash)
  end

  def test_the_dynamic_factory_reads_it
    cap = BGP::OPT_PARM::Capability.dynamic_factory(['47000700010180000e10'].pack('H*'))
    assert_instance_of BGP::OPT_PARM::DYN_CAP::Long_lived_graceful_restart, cap
    assert_equal '47000700010180000e10', cap.to_shex
  end

  def test_to_s
    cap = LLGR.new(1, 1, 0x80, 3600).add(2, 1, 0, 300)
    assert_equal "Option Capabilities Advertisement (2): [#{cap.to_shex}]\n" +
                 "    Long-Lived Graceful Restart (71), length: 16\n" +
                 "        AFI IPv4 (1), SAFI Unicast (1), state preserved (0x80), stale time 3600s\n" +
                 "        AFI IPv6 (2), SAFI Unicast (1), state not preserved (0x0), stale time 300s",
                 cap.to_s
    assert_equal 'Long-Lived Graceful Restart (71)', cap.to_s_brief
  end

  # Section 4.1 makes the capability depend on Graceful Restart being
  # advertised too. That is a rule about a session, so nothing here
  # refuses LLGR alone.
  def test_nothing_validates
    n = BGP::Neighbor.new(4, 100, 180, '10.0.0.1', '127.0.0.1', '127.0.0.2')
    n.capability :llgr, 1, 1, 0xff, 0xffffff
    assert_equal '02094707000101ffffffff',
                 n.instance_eval { @opt_parms }.last.to_shex
  end

  def test_in_an_open_message
    gr = BGP::OPT_PARM::CAP::Graceful_restart.new(0, 120)
    gr.add(1, 1, 0x80)
    open = BGP::Open.new(4, 100, 200, '10.0.0.1', gr, LLGR.new(1, 1, 0x80, 3600))
    back = BGP::Message.factory(open.encode)
    assert_equal open.to_shex, back.to_shex
    assert_equal 3600, back.find(LLGR).stale_time(1, 1)
  end
end
