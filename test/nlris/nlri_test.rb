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

require 'bgp/nlris/nlris'
# require 'bgp/nlris/vpn'
# require 'bgp/nlris/inet'
# require 'bgp/nlris/labeled'

require 'test/unit'  
class NLRI_Ip4_Test < Test::Unit::TestCase
  include BGP
  def test_1
    el = Nlri::Ip4.new('20.0.0.0/16')
    el2 = Nlri::Ip4.new(el)
    assert_equal(el2.to_shex, el.to_shex)
    assert_equal(Nlri::Ip4, el2.class)
    assert_equal('0f1400', Nlri::Ip4.new('20.0.0.0/15').to_shex)
    assert_equal('101400', Nlri::Ip4.new('20.0.0.0/16').to_shex)
    assert_equal('11140000', Nlri::Ip4.new('20.0.0.0/17').to_shex)
    assert_equal('17140000', Nlri::Ip4.new('20.0.0.0/23').to_shex)
    assert_equal('18140000', Nlri::Ip4.new('20.0.0.0/24').to_shex)
    assert_equal('1914000000', Nlri::Ip4.new('20.0.0.0/25').to_shex)
    assert_equal('20.0.0.0/25', Nlri::Ip4.new('20.0.0.0/25').to_s)
  end

  def test_2
    assert_equal('0f1400',Nlri::Ip4.new(['0f1400'].pack('H*')).to_shex)
    assert_equal('101400',Nlri::Ip4.new(['101400'].pack('H*')).to_shex)
    assert_equal('11140000',Nlri::Ip4.new(['11140000'].pack('H*')).to_shex)
    assert_equal('18140000',Nlri::Ip4.new(['18140000'].pack('H*')).to_shex)
    assert_equal('1914000000',Nlri::Ip4.new(['1914000000'].pack('H*')).to_shex)
    s = ['0f140010140011140000'].pack('H*')
    ip4 = Nlri::Ip4.new(s)
    assert_equal('10140011140000', s.unpack('H*')[0])
    ip4 = Nlri::Ip4.new(s)
    assert_equal('11140000', s.unpack('H*')[0])
    ip4 = Nlri::Ip4.new(s)
    assert_equal('', s.unpack('H*')[0])

  end
end
class NLRI_Ip6_Test < Test::Unit::TestCase
  include BGP
  def test_1
    assert_equal('0410',Nlri::Ip6.new('1111:2222:3333:4444:5555:6666:7777:8888/4').to_shex)
    assert_equal('0510',Nlri::Ip6.new('1111:2222:3333:4444:5555:6666:7777:8888/5').to_shex)
    assert_equal('0710',Nlri::Ip6.new('1111:2222:3333:4444:5555:6666:7777:8888/7').to_shex)
    assert_equal('0811',Nlri::Ip6.new('1111:2222:3333:4444:5555:6666:7777:8888/8').to_shex)
    assert_equal('091100',Nlri::Ip6.new('1111:2222:3333:4444:5555:6666:7777:8888/9').to_shex)
    assert_equal('30111122223333',Nlri::Ip6.new('1111:2222:3333:4444:5555:6666:7777:8888/48').to_shex)
    assert_equal('3111112222333300',Nlri::Ip6.new('1111:2222:3333:4444:5555:6666:7777:8888/49').to_shex)
    assert_equal('401111222233334444',Nlri::Ip6.new('1111:2222:3333:4444:5555:6666:7777:8888/64').to_shex)
    assert_equal('41111122223333444400',Nlri::Ip6.new('1111:2222:3333:4444:5555:6666:7777:8888/65').to_shex)
    assert_equal('7f11112222333344445555666677778888',Nlri::Ip6.new('1111:2222:3333:4444:5555:6666:7777:8888/127').to_shex)
    assert_equal('8011112222333344445555666677778888',Nlri::Ip6.new('1111:2222:3333:4444:5555:6666:7777:8888/128').to_shex)
  end
end

class Withdrawn_Test < Test::Unit::TestCase
  include BGP
  def test_1
    nlri1 = Withdrawn.new
    assert_equal('0000', nlri1.to_shex)
    nlri1 << Withdrawn::Ip4.new('20.0.0.0/15')
    nlri1 << '20.0.0.0/17'
    nlri1 << '20.0.0.0/24'
    s = '0f140010140011140000'
    nlri2 = Withdrawn.new([s].pack('H*'))
    assert_equal('000a0f140010140011140000', nlri2.to_shex)
    assert_equal('000a0f140010140011140000', nlri2.to_shex(true))
    assert_equal('0f140010140011140000', nlri2.to_shex(false))
    assert_equal(3,nlri2.nlris.size)
  end
end

class Nlri_Test < Test::Unit::TestCase
  include BGP
  def test_1
    nlri1 = Nlri.new
    nlri1 << Nlri::Ip4.new('20.0.0.0/15')
    nlri1 << '20.0.0.0/17'
    nlri1 << '20.0.0.0/24'
    s = '0f140010140011140000'
    nlri2 = Nlri.new([s].pack('H*'))
    assert_equal('0f140010140011140000', nlri2.to_shex)
    assert_raise(ArgumentError)  { nlri2.to_shex(true) }
    assert_equal(3,nlri2.nlris.size)
         
  end

  def test_2
    nlri1 = Nlri.new
    nlri1 << Nlri::Ip4.new('20.0.0.0/15')
    nlri1 << '20.0.0.0/17'
    nlri1 << '20.0.0.0/24'
    s = '0f140010140011140000'
    nlri2 = Nlri.new([s].pack('H*'))
    assert_equal('0f140010140011140000', nlri2.to_shex)
    assert_raise(ArgumentError)  { nlri2.to_shex(true) }
    assert_equal(3,nlri2.nlris.size)      
  end
end

class Prefix_Test < Test::Unit::TestCase
  include BGP
  def test_1
    assert_equal('::/128',Prefix.new.to_s)
    assert_equal(2,Prefix.new.afi)
    assert_equal('192.168.0.0/16',Prefix.new('192.168.0.0/16').to_s)
    assert_equal(1,Prefix.new('192.168.0.0/16').afi)
    assert(Prefix.new('192.168.0.0/16').ipv4?)
    assert_equal('10c0a8',Prefix.new('192.168.0.0/16').to_shex)
    assert_equal('402009000400040000',Prefix.new('2009:4:4::/64').to_shex)
    assert('402009000400040000',Prefix.new('2009:4:4::/64').ipv6?)
    assert_equal('2009:4:4::/64',Prefix.new('2009:4:4::/64').to_s)
  end
end
class Inet_unicast_Test < Test::Unit::TestCase
  include BGP
  def test_1
    assert_equal(1,Inet_unicast.new('192.168.0.0/16').afi)
    assert_equal(1,Inet_unicast.new('192.168.0.0/16').safi)
    assert_equal(2,Inet_unicast.new('2009:4:4::/64').afi)
    assert_equal(1,Inet_unicast.new('2009:4:4::/64').safi)
    assert_equal(1,Inet_multicast.new('192.168.0.0/16').afi)
    assert_equal(2,Inet_multicast.new('192.168.0.0/16').safi)
    assert_equal(2,Inet_multicast.new('2009:4:4::/64').afi)
    assert_equal(2,Inet_multicast.new('2009:4:4::/64').safi)
  end
end

class Vpn_Test < Test::Unit::TestCase
  include BGP
  def test_1
    assert_equal('5800000001000000010a0000', Vpn.new('10.0.0.1/24', Rd.new(1,1)).to_shex)
    assert_equal('00000001000000010a0000', Vpn.new('10.0.0.1/24', Rd.new(1,1)).to_shex(false))
    assert_equal('RD=1:1, IPv4=10.0.0.0/24', Vpn.new('10.0.0.1/24', Rd.new(1,1)).to_s)
    assert_equal(88, Vpn.new('10.0.0.1/24', Rd.new(1,1)).bit_length)
    assert_equal(1,Vpn.new('10.0.0.1/24', Rd.new(1,1)).afi)
    assert_equal(true,Vpn.new('10.0.0.1/24', Rd.new(1,1)).ipv4?)
    assert_equal(false,Vpn.new('10.0.0.1/24', Rd.new(1,1)).ipv6?)
    assert_equal(2,Vpn.new('2009:4:5::/105', Rd.new(1,1)).afi)
    assert_equal(false,Vpn.new('2009:4:5::/105', Rd.new(1,1)).ipv4?)
    assert_equal(true,Vpn.new('2009:4:5::/105', Rd.new(1,1)).ipv6?)
    assert_equal('RD=1:1, IPv6=2009:4:5::/105',Vpn.new('2009:4:5::/105', Rd.new(1,1)).to_s)
    assert_equal('700000000100000001200900040005',Vpn.new('2009:4:5::/48', Rd.new(1,1)).to_shex)
    assert_equal(169,Vpn.new('2009:4:5::/105', Rd.new(1,1)).bit_length)
  end
  def test_2
    vpn = Vpn.new(['5800000001000000010a0000'].pack('H*'))
    assert_equal(  '5800000001000000010a0000', vpn.to_shex)
    assert_equal(  '00000001000000010a0000', vpn.to_shex(false))
    vpn = Vpn.new(['700000000100000001200900040005'].pack('H*'), 2)
    assert_equal(  '700000000100000001200900040005', vpn.to_shex)
    vpn = Vpn.new(['700000000100000001200900040005'].pack('H*'), 2)
    assert_equal(  '700000000100000001200900040005', vpn.to_shex)
  end
end

class Labeled_Test < Test::Unit::TestCase
  include BGP
  def test_1
    assert_equal('Label Stack=1,2,3 (bottom) 10.0.0.0/24', Labeled.new(Prefix.new('10.0.0.1/24'),1,2,3).to_s)
    assert_equal(3*24+24, Labeled.new(Prefix.new('10.0.0.1/24'),1,2,3).bit_length)
    assert_equal('600000100000200000310a0000', Labeled.new(Prefix.new('10.0.0.1/24'),1,2,3).to_shex)
    assert_equal('6b0006510000006400000064c0a800',Labeled.new(Vpn.new('192.168.0.0/19', Rd.new(100,100)),101).to_shex)
    assert_equal('d8000651000000640000006420090004000500000000000000000001',Labeled.new(Vpn.new('2009:4:5::1', Rd.new(100,100)),101).to_shex)
    assert_equal(24+64+128,Labeled.new(Vpn.new('2009:4:5::1', Rd.new(100,100)),101).bit_length)
    assert_equal(24+64+64,Labeled.new(Vpn.new('2009:4:5::1/64', Rd.new(100,100)),101).bit_length)
    assert_equal(24*3+64+48,Labeled.new(Vpn.new('2009:4:5::1/48', Rd.new(100,100)),101,102,103).bit_length)
    assert_equal('9800065100000064000000642009000400050000',Labeled.new(Vpn.new('2009:4:5::1/64', Rd.new(100,100)),101).to_shex)
    assert_equal('9800065100000064000000642009000400050000',Labeled.new(['9800065100000064000000642009000400050000'].pack('H*'),2).to_shex)
  end
end
