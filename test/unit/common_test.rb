#--
# Copyright 2008, 2009 Jean-Michel Esnault.
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

require "bgp/common"

require 'test/unit'
class Common_Test < Test::Unit::TestCase
  def test_ipaddr_1
    s = [1,2,3].pack('C*')
    assert(s.is_packed?)
    assert( ! "1234".is_packed?)
  end
  def test_ipaddr_2
    ip = IPAddr.new('10.0.0.1')
    assert_equal('0a000001', ip.to_shex)
    assert_equal('0a000001', IPAddr.create(ip.encode).to_shex)
    assert_equal('0a000001', IPAddr.create(ip.to_i).to_shex)
  end
  def test_ipaddr_3
    assert_equal(32, IPAddr.new('10.0.0.1').mlen)
    assert_equal(16, IPAddr.new('10.0.0.1/16').mlen)
    assert_equal(7, IPAddr.new('10.0.0.0/7').mlen)
    assert_equal(128, IPAddr.new('0::0').mlen)
    assert_equal(96, IPAddr.new('2004::0001:3/96').mlen)
    assert_equal('255.255.255.255', IPAddr.new('1.1.1.1').netmask)
    assert_equal('255.255.255.255', IPAddr.new('1.1.1.1/32').netmask)
    assert_equal('255.255.255.254', IPAddr.new('1.1.1.1/31').netmask)
    assert_equal('255.255.255.252', IPAddr.new('1.1.1.1/30').netmask)
    assert_equal('255.255.255.248', IPAddr.new('1.1.1.1/29').netmask)
    assert_equal('ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff',IPAddr.new('2011:1:18::1').netmask)
    assert_equal('ffff:ffff:ffff:ffff:ffff:ffff:ffff:fffe',IPAddr.new('2011:1:18::1/127').netmask)
    assert_equal('ffff:ffff:ffff:ffff:8000:0000:0000:0000',IPAddr.new('2011:1:18::1/65').netmask)
    assert_equal('ffff:ffff:ffff:ffff:0000:0000:0000:0000',IPAddr.new('2011:1:18::1/64').netmask)
    assert_equal('ffff:ffff:ffff:fffe:0000:0000:0000:0000',IPAddr.new('2011:1:18::1/63').netmask)
    assert_equal('ffff:ffff:ffff:0000:0000:0000:0000:0000',IPAddr.new('2011:1:18::1/48').netmask)
    assert_equal('ffff:ffff:0000:0000:0000:0000:0000:0000',IPAddr.new('2011:1:18::1/32').netmask)
  end
  def test_ipaddr_4
    ip1 = IPAddr.new('10.0.0.1/28')
    ip2 = IPAddr.new('10.0.0.1/24')
    ip3 = IPAddr.new('10.0.0.1/12')
    assert_equal('10.0.0.16/28', ip1 ^ 1)
    assert_equal('10.0.0.32/28', ip1 ^ 2)
    assert_equal('10.0.1.0/24', ip2 ^ 1)
    assert_equal('10.0.2.0/24', ip2 ^ 2)
    assert_equal('10.16.0.0/12', ip3 ^ 1)
    assert_equal('10.32.0.0/12', ip3 ^ 2)
  end
  def test_string_1      
    sbin = ['00'].pack('H*')
    assert_equal '0x0000:  00', sbin.hexlify.join
    sbin = ['0001'].pack('H*')
    assert_equal '0x0000:  0001', sbin.hexlify.join
    sbin = ['000102'].pack('H*')
    assert_equal '0x0000:  0001 02', sbin.hexlify.join
    sbin = ['000102030405060708090a0b0c0d0e0f'].pack('H*')
    assert_equal '0x0000:  0001 0203 0405 0607 0809 0a0b 0c0d 0e0f', sbin.hexlify.join
    sbin = ['000102030405060708090a0b0c0d0e0f10'].pack('H*')
    sbin = ['000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20'].pack('H*')
    assert_equal '0x0001:  1011 1213 1415 1617 1819 1a1b 1c1d 1e1f', sbin.hexlify[2]
    assert_equal '0x0002:  20', sbin.hexlify[3]
  end
  # FIXME: remove...
  # def test_nlri
  #   assert_equal('14000000', IPAddr.new_nlri4(['101400'].pack('H*')).to_shex)
  # end
end
