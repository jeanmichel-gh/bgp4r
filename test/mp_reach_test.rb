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

require 'bgp/mp_reach'
require 'test/unit'

class Mp_reach_Test < Test::Unit::TestCase
  include BGP
  def test_1
    s = '800e30000202102009000900190000000000000000000100402009000100000000402009000200000000402009000300000000'
    sbin = [s].pack('H*') 
    mpr = Mp_reach.new(sbin)
    assert_equal("\n    AFI IPv6 (2), SAFI Multicast (2)\n    nexthop: 2009:9:19::1\n      2009:1::/64\n      2009:2::/64\n      2009:3::/64", mpr.mp_reach)
    assert_equal(2, mpr.afi)
    assert_equal(2, mpr.safi)
    assert_equal(s, mpr.to_shex)
  end
  def test_2
    s = "800e2500020120200900090019000000000000000000012009000900190000000000000000000200"
    sbin = [s].pack('H*') 
    mpr = Mp_reach.new(sbin)
    assert_equal("\n    AFI IPv6 (2), SAFI Unicast (1)\n    nexthop: 2009:9:19::1, 2009:9:19::2", mpr.mp_reach)
    assert_equal(2, mpr.afi)
    assert_equal(1, mpr.safi)
    assert_equal(s, mpr.to_shex)
  end
  def test_3
    s = "800e0d000102080a0000010a00000200"
    sbin = [s].pack('H*') 
    mpr = Mp_reach.new(sbin)
    assert_equal("\n    AFI IPv4 (1), SAFI Multicast (2)\n    nexthop: 10.0.0.1, 10.0.0.2", mpr.mp_reach)
    assert_equal(1, mpr.afi)
    assert_equal(2, mpr.safi)
    assert_equal(s, mpr.to_shex)
  end
  def test_4
    s = "800e11000102040a0000010018c0a80118c0a802"
    sbin = [s].pack('H*') 
    mpr = Mp_reach.new(sbin)
    assert_equal("\n    AFI IPv4 (1), SAFI Multicast (2)\n    nexthop: 10.0.0.1\n      192.168.1.0/24\n      192.168.2.0/24", mpr.mp_reach)
    assert_equal(1, mpr.afi)
    assert_equal(2, mpr.safi)
    assert_equal(s, mpr.to_shex)
  end
  def test_5
    s = "800e39000204102009000900190000000000000000000100580006512009000100000000580006612009000200000000580006712009000300000000"
    sbin = [s].pack('H*') 
    mpr = Mp_reach.new(sbin)
    assert_equal("\n    AFI IPv6 (2), SAFI Labeled NLRI (4)\n    nexthop: 2009:9:19::1\n      Label Stack=101 (bottom) 2009:1::/64\n      Label Stack=102 (bottom) 2009:2::/64\n      Label Stack=103 (bottom) 2009:3::/64", mpr.mp_reach)
    assert_equal(2, mpr.afi)
    assert_equal(4, mpr.safi)
    assert_equal(s, mpr.to_shex)
    #puts mpr
  end
  def test_6
    mpr =  Mp_reach.new(:safi=>2, :nexthop=> ['2009:9:19::1/128'], :prefix=> ['2009:1::/64', '2009:2::/64', '2009:3::/64'])
    assert_equal("\n    AFI IPv6 (2), SAFI Multicast (2)\n    nexthop: 2009:9:19::1\n      2009:1::/64\n      2009:2::/64\n      2009:3::/64", mpr.mp_reach)
    assert_equal(mpr.to_shex, Mp_reach.new(mpr.encode).to_shex)
    mpr =  Mp_reach.new(:safi=>1, :nexthop=> ['10.0.0.1','10.0.0.2'], :prefix=> '192.168.0.0/24')
    assert_equal("\n    AFI IPv4 (1), SAFI Unicast (1)\n    nexthop: 10.0.0.1, 10.0.0.2\n      192.168.0.0/24", mpr.mp_reach)
    assert_equal(mpr.to_shex, Mp_reach.new(mpr.encode).to_shex)
    mpr =  Mp_reach.new(:safi=>4, :nexthop=> ['10.0.0.1','10.0.0.2'], :nlri=> {:prefix=> '192.168.0.0/24', :label=>101} )
    assert_equal("\n    AFI IPv4 (1), SAFI Labeled NLRI (4)\n    nexthop: 10.0.0.1, 10.0.0.2\n      Label Stack=101 (bottom) 192.168.0.0/24", mpr.mp_reach)
    assert_equal(mpr.to_shex, Mp_reach.new(mpr.encode).to_shex)
    mpr = Mp_reach.new(:safi=>128, :nexthop=> ['10.0.0.1','10.0.0.2'], :nlri=> {:rd=> [100,100], :prefix=> '192.168.0.0/24', :label=>101})
    assert_equal("\n    AFI IPv4 (1), SAFI Labeled VPN Unicast (128)\n    nexthop: 10.0.0.1, 10.0.0.2\n      Label Stack=101 (bottom) RD=100:100, IPv4=192.168.0.0/24", mpr.mp_reach)
    assert_equal(mpr.to_shex, Mp_reach.new(mpr.encode).to_shex)
    mpr = Mp_reach.new(:safi=>128, :nexthop=> ['10.0.0.1','10.0.0.2'], :nlri=> {:rd=> Rd.new(100,100), :prefix=> Prefix.new('192.168.0.0/24'), :label=>101})
    assert_equal("\n    AFI IPv4 (1), SAFI Labeled VPN Unicast (128)\n    nexthop: 10.0.0.1, 10.0.0.2\n      Label Stack=101 (bottom) RD=100:100, IPv4=192.168.0.0/24", mpr.mp_reach)
    assert_equal(mpr.to_shex, Mp_reach.new(mpr.encode).to_shex)
  end
  def test_7
    mpr =  Mp_reach.new(:safi=>2, :nexthop=> '2009:9:19::1/128', :prefix=> [
      '2009:1::/64', '2009:2::/64', '2009:3::/64', '2009:4::/64', '2009:5::/64', '2009:6::/64'])
    assert_equal("\n    AFI IPv6 (2), SAFI Multicast (2)\n    nexthop: 2009:9:19::1\n      2009:1::/64\n      2009:2::/64\n      2009:3::/64\n      2009:4::/64\n      2009:5::/64\n      2009:6::/64", mpr.mp_reach)
    mpr =  Mp_reach.new(:safi=>1, :nexthop=> '10.0.0.1', :prefix=> [
      '192.168.0.0/24', '192.168.1.0/24', '192.168.2.0/24', '192.168.3.0/24', '192.168.4.0/24', '192.168.5.0/24'])
    assert_equal("\n    AFI IPv4 (1), SAFI Unicast (1)\n    nexthop: 10.0.0.1\n      192.168.0.0/24\n      192.168.1.0/24\n      192.168.2.0/24\n      192.168.3.0/24\n      192.168.4.0/24\n      192.168.5.0/24", mpr.mp_reach)
  end
  def test_8
    mpr =  Mp_reach.new(:safi=>1, :nexthop=> '10.0.0.1', :prefix=> [
      '192.168.0.0/24', '192.168.1.0/24', '192.168.2.0/24', '192.168.3.0/24', '192.168.4.0/24', '192.168.5.0/24'])
    assert_equal(Mp_unreach,mpr.new_unreach.class)
    mpr2 = Mp_reach.new(mpr)
    assert_equal(mpr.encode, mpr2.encode)
    assert_equal(Mp_unreach, Mp_unreach.new(mpr.new_unreach).class)
  end
end

class Mp_unreach_Test < Test::Unit::TestCase
  include BGP
  def test_1
    mpur = Mp_unreach.new(:safi=>1, :prefix=>['10.0.0.0/16', '10.1.0.0/16'])
    assert_raise(ArgumentError) { Mp_unreach.new }
  end
  
  def test_2
    mpur = Mp_unreach.new(:safi=>2, :prefix=>['192.168.1.0/24', '192.168.2.0/24'])
    assert_equal('800f0b00010218c0a80118c0a802', mpur.to_shex)
    
     mpur = Mp_unreach.new(:safi=>2, :prefix=>['2007:1::/64', '2007:2::/64','2007:3::/64'])
     assert_equal('800f1e000202402007000100000000402007000200000000402007000300000000', mpur.to_shex)

     #mpur = Mp_unreach.new(:safi=>2, :prefix=>['2007:1::/64, 101', '2007:2::/64,102','2007:3::/64, 103'])
     mpur = Mp_unreach.new(:safi=>4, :nlri=> [
       {:prefix=>'2007:1::/64', :label=> 101},
       {:prefix=>'2007:2::/64', :label=> 102},
       {:prefix=>'2007:3::/64', :label=> 103},])
    assert_equal('800f27000204580006512007000100000000580006612007000200000000580006712007000300000000', mpur.to_shex)
    assert_match(/^800f..000204/,mpur.to_shex)
    assert_match(/58000651200700010000000058/,mpur.to_shex)
    assert_match(/58000661200700020000000058/,mpur.to_shex)
    assert_match(/580006712007000300000000$/,mpur.to_shex)

    mpur = Mp_unreach.new(:safi=>128, :nlri=> [
      {:rd=> Rd.new(100,100), :prefix=> Prefix.new('192.168.1.0/24'), :label=>101},
      {:rd=> Rd.new(100,100), :prefix=> Prefix.new('192.168.2.0/24'), :label=>102},
      {:rd=> Rd.new(100,100), :prefix=> Prefix.new('192.168.3.0/24'), :label=>103},])
    assert_match(/^800f..000180/,mpur.to_shex)
    assert_equal("700006510000006400000064c0a801",mpur.nlris[0].to_shex)
    assert_equal("700006610000006400000064c0a802",mpur.nlris[1].to_shex)

  end
end
