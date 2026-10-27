#--
# Copyright 2011, 2026 Jean-Michel Esnault.
# All rights reserved.
# See LICENSE.txt for permissions.
#
#
# This file is part of BGP4R.
# 

require "test/unit"
require 'bgp/nlris/vpn'
require 'bgp/nlris/rd'
require 'bgp/nlris/prefix'

class TestNlrisVpn < Test::Unit::TestCase
  include BGP
  def test_1
    assert_equal('RD=1.1.1.1:1, IPv4=10.0.0.0/8', Vpn.new("10.0.0.1/8", Rd.new('1.1.1.1',1)).to_s)
    assert_equal('RD=1.1.1.1:1, IPv6=2011:1::/48', Vpn.new("2011:1::1/48", Rd.new('1.1.1.1',1)).to_s)
    assert_equal('4800000001000000010a', Vpn.new("10.1.2.3/8", Rd.new(1,1)).to_shex)
    assert_equal('RD=1:1, IPv4=10.0.0.0/8', Vpn.new(["4800000001000000010a"].pack('H*')).to_s)
    assert_equal('4900010101010100010a00', Vpn.new("10.1.2.3/9", Rd.new('1.1.1.1',1)).to_shex)
    assert_equal('RD=1.1.1.1:1, IPv4=10.0.0.0/9', Vpn.new(["4900010101010100010a00"].pack('H*')).to_s)
    assert_equal('4a00010101010100010a00', Vpn.new("10.1.2.3/10", Rd.new('1.1.1.1',1)).to_shex)
    assert_equal('5000010101010100010a01', Vpn.new("10.1.2.3/16", Rd.new('1.1.1.1',1)).to_shex)
    assert_equal('5100010101010100010a0100', Vpn.new("10.1.2.3/17", Rd.new('1.1.1.1',1)).to_shex)
    assert_equal('5800010101010100010a0102', Vpn.new("10.1.2.3/24", Rd.new('1.1.1.1',1)).to_shex)
    assert_equal('5900010101010100010a010200', Vpn.new("10.1.2.3/25", Rd.new('1.1.1.1',1)).to_shex)
    assert_equal('6000010101010100010a010203', Vpn.new("10.1.2.3/32", Rd.new('1.1.1.1',1)).to_shex)
    assert_equal('4a00010101010100010a00', Vpn.new(["4a00010101010100010a00"].pack('H*')).to_shex)
    assert_equal('5000010101010100010a01', Vpn.new(["5000010101010100010a01"].pack('H*')).to_shex)
    assert_equal('5100010101010100010a0100', Vpn.new(["5100010101010100010a0100"].pack('H*')).to_shex)
    assert_equal('5800010101010100010a0102', Vpn.new(["5800010101010100010a0102"].pack('H*')).to_shex)
    assert_equal('5900010101010100010a010200', Vpn.new(["5900010101010100010a010200"].pack('H*')).to_shex)
    assert_equal('6000010101010100010a010203', Vpn.new(["6000010101010100010a010203"].pack('H*')).to_shex)
    assert_equal('400000000100000001', Vpn.new(Rd.new(1,1)).to_shex)
    assert_equal('400000000100000001', Vpn.new(["400000000100000001"].pack('H*')).to_shex)
    assert_equal('RD=1:1, IPv4=0.0.0.0/0', Vpn.new(Rd.new(1,1)).to_s)
    vpn = Vpn.new('1.2.3.4/32', Rd.new(1,1))
    assert_equal('000000010000000101020304', vpn.encode_without_len_without_path_id.unpack('H*')[0])
  end
  def test_2
    vpn = Vpn.new("10.0.0.1/8", Rd.new('1.1.1.1',1))
    assert_equal("RD=1.1.1.1:1, IPv4=10.0.0.0/8", vpn.to_s)
    assert_equal({:prefix=>"10.0.0.0/8", :rd=>["1.1.1.1", 1]}, vpn.to_hash)
    vpn = Vpn.new("10.0.0.1/8", Rd.new(1,1))
    assert_equal("RD=1:1, IPv4=10.0.0.0/8", vpn.to_s)
    assert_equal({:prefix=>"10.0.0.0/8", :rd=>[1, 1]}, vpn.to_hash)
  end
  # The RD can be given as its own field values rather than as an Rd,
  # and the result has to be the same VPN-IPv4 NLRI (RFC 4364).
  def test_rd_given_as_field_values
    assert_equal Vpn.new('10.0.0.1/8', Rd.new(1, 1)).to_shex,
                 Vpn.new('10.0.0.1/8', 1, 1).to_shex
    assert_equal Vpn.new('10.0.0.1/8', Rd.new('1.1.1.1', 1)).to_shex,
                 Vpn.new('10.0.0.1/8', '1.1.1.1', 1).to_shex
    assert_equal Vpn.new('10.0.0.1/8', Rd.new(65536, 1, 2)).to_shex,
                 Vpn.new('10.0.0.1/8', 65536, 1, 2).to_shex
    assert_equal({:rd=>[1, 1], :prefix=>'10.0.0.0/8'}, Vpn.new('10.0.0.1/8', 1, 1).to_hash)
  end
  def test_no_rd_given_is_the_zero_rd
    vpn = Vpn.new('10.0.0.1/8')
    assert_equal '4800000000000000000a', vpn.to_shex
    assert_equal 'RD=0:0, IPv4=10.0.0.0/8', vpn.to_s
    assert_equal 0, vpn.rd.encoding_type?
  end
  def test_encode_prefix_with_and_without_the_length
    vpn = Vpn.new('10.1.2.3/24', Rd.new(1, 1))
    assert_equal '180a0102', vpn.encode_prefix(true).unpack('H*')[0]
    assert_equal '0a0102', vpn.encode_prefix(false).unpack('H*')[0]
    # An RD with no prefix contributes nothing either way.
    assert_equal '', Vpn.new(Rd.new(1, 1)).encode_prefix(true).unpack('H*')[0]
    assert_equal '', Vpn.new(Rd.new(1, 1)).encode_prefix(false).unpack('H*')[0]
  end
  def test_address_family_of_the_prefix
    vpn = Vpn.new('10.0.0.1/8', Rd.new(1, 1))
    assert_equal true, vpn.ipv4?
    assert_equal false, vpn.ipv6?
    assert_equal 1, vpn.afi
    # 64 bits of RD plus the prefix length, which is what goes in the
    # one octet length ahead of the NLRI.
    assert_equal 72, vpn.bit_length
    vpn = Vpn.new('2011:1::1/48', Rd.new(1, 1))
    assert_equal false, vpn.ipv4?
    assert_equal true, vpn.ipv6?
    assert_equal 2, vpn.afi
    assert_equal 112, vpn.bit_length
  end
  def test_rd_without_a_prefix_names_the_default_route_of_its_afi
    vpn = Vpn.new(Rd.new(1, 1))
    assert_equal 'RD=1:1, IPv4=0.0.0.0/0', vpn.to_s(1)
    assert_equal 'RD=1:1, IPv6=0::0/0', vpn.to_s(2)
    # No afi to go on, so nothing is claimed about the prefix.
    assert_equal 'RD=1:1, ', vpn.to_s(3)
    assert_equal({:rd=>[1, 1]}, vpn.to_hash)
    assert_nil vpn.path_id
  end
  def test_ipv6_vpn_round_trip
    s = '700001010101010001201100010000'
    vpn = Vpn.new([s].pack('H*'), 2)
    assert_equal 'RD=1.1.1.1:1, IPv6=2011:1::/48', vpn.to_s(2)
    assert_equal s, vpn.to_shex
    assert_equal 2, vpn.afi
  end
  def test_next_hop_carries_a_zero_rd
    # RFC 4364 section 4.3.2: the VPN-IPv4 next hop is an all zero RD
    # followed by the address.
    assert_equal '00000000000000000a0102',
                 Vpn.new('10.1.2.3/24', Rd.new(1, 1)).encode_next_hop.unpack('H*')[0]
  end
end