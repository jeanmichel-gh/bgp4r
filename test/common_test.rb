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
    #assert_equal('255.255.255.255', IPAddr.new('1.1.1.1').netmask)
    assert_equal('255.255.255.255', IPAddr.new('1.1.1.1/32').netmask)
    assert_equal('255.255.255.254', IPAddr.new('1.1.1.1/31').netmask)
    assert_equal('255.255.255.252', IPAddr.new('1.1.1.1/30').netmask)
    assert_equal('255.255.255.248', IPAddr.new('1.1.1.1/29').netmask)
  end
  def test_string_1      
    sbin = ['0a000001'].pack('H*')
    assert_equal('0x0000: 0a00 0001',sbin.hexlify.join)
  end
  def test_nlri
    assert_equal('14000000', IPAddr.new_nlri4(['101400'].pack('H*')).to_shex)
  end

end
