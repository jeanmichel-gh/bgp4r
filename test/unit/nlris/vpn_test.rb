#--
# Copyright 2011 Jean-Michel Esnault.
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
end