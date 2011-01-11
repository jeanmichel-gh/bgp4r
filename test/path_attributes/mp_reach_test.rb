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

require 'bgp4r'
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
    mpr =  Mp_reach.new(:safi=>2, :nexthop=> ['2009:9:19::1/128'], :nlris=> ['2009:1::/64', '2009:2::/64', '2009:3::/64'])
    assert_equal("\n    AFI IPv6 (2), SAFI Multicast (2)\n    nexthop: 2009:9:19::1\n      2009:1::/64\n      2009:2::/64\n      2009:3::/64", mpr.mp_reach)
    assert_equal(mpr.to_shex, Mp_reach.new(mpr.encode).to_shex)
    mpr =  Mp_reach.new(:safi=>1, :nexthop=> ['10.0.0.1','10.0.0.2'], :nlris=> '192.168.0.0/24')
    assert_equal("\n    AFI IPv4 (1), SAFI Unicast (1)\n    nexthop: 10.0.0.1, 10.0.0.2\n      192.168.0.0/24", mpr.mp_reach)
    assert_equal(mpr.to_shex, Mp_reach.new(mpr.encode).to_shex)
    mpr =  Mp_reach.new(:safi=>4, :nexthop=> ['10.0.0.1','10.0.0.2'], :nlris=> {:prefix=> '192.168.0.0/24', :label=>101} )
    assert_equal("\n    AFI IPv4 (1), SAFI Labeled NLRI (4)\n    nexthop: 10.0.0.1, 10.0.0.2\n      Label Stack=101 (bottom) 192.168.0.0/24", mpr.mp_reach)
    assert_equal(mpr.to_shex, Mp_reach.new(mpr.encode).to_shex)
    mpr = Mp_reach.new(:safi=>128, :nexthop=> ['10.0.0.1','10.0.0.2'], :nlris=> {:rd=> [100,100], :prefix=> '192.168.0.0/24', :label=>101})
    assert_equal("\n    AFI IPv4 (1), SAFI Labeled VPN Unicast (128)\n    nexthop: 10.0.0.1, 10.0.0.2\n      Label Stack=101 (bottom) RD=100:100, IPv4=192.168.0.0/24", mpr.mp_reach)
    assert_equal(mpr.to_shex, Mp_reach.new(mpr.encode).to_shex)
    mpr = Mp_reach.new(:safi=>128, :nexthop=> ['10.0.0.1','10.0.0.2'], :nlris=> {:rd=> Rd.new(100,100), :prefix=> Prefix.new('192.168.0.0/24'), :label=>101})
    assert_equal("\n    AFI IPv4 (1), SAFI Labeled VPN Unicast (128)\n    nexthop: 10.0.0.1, 10.0.0.2\n      Label Stack=101 (bottom) RD=100:100, IPv4=192.168.0.0/24", mpr.mp_reach)
    assert_equal(mpr.to_shex, Mp_reach.new(mpr.encode).to_shex)
  end
  def test_7
    mpr =  Mp_reach.new(:safi=>2, :nexthop=> '2009:9:19::1/128', :nlris=> [
      '2009:1::/64', '2009:2::/64', '2009:3::/64', '2009:4::/64', '2009:5::/64', '2009:6::/64'])
    assert_equal("\n    AFI IPv6 (2), SAFI Multicast (2)\n    nexthop: 2009:9:19::1\n      2009:1::/64\n      2009:2::/64\n      2009:3::/64\n      2009:4::/64\n      2009:5::/64\n      2009:6::/64", mpr.mp_reach)
    mpr =  Mp_reach.new(:safi=>1, :nexthop=> '10.0.0.1', :nlris=> [
      '192.168.0.0/24', '192.168.1.0/24', '192.168.2.0/24', '192.168.3.0/24', '192.168.4.0/24', '192.168.5.0/24'])
    assert_equal("\n    AFI IPv4 (1), SAFI Unicast (1)\n    nexthop: 10.0.0.1\n      192.168.0.0/24\n      192.168.1.0/24\n      192.168.2.0/24\n      192.168.3.0/24\n      192.168.4.0/24\n      192.168.5.0/24", mpr.mp_reach)
  end
  def test_8
    mpr =  Mp_reach.new(:safi=>1, :nexthop=> '10.0.0.1', :nlris=> [
      '192.168.0.0/24', '192.168.1.0/24', '192.168.2.0/24', '192.168.3.0/24', '192.168.4.0/24', '192.168.5.0/24'])
    assert_equal(Mp_unreach,mpr.new_unreach.class)
    mpr2 = Mp_reach.new(mpr)
    assert_equal(mpr.encode, mpr2.encode)
    assert_equal(Mp_unreach, Mp_unreach.new(mpr.new_unreach).class)
  end
  
  def test_afi_1
    mpr1 =  Mp_reach.new(:safi=>1, :nexthop=> ['10.0.0.1'], :nlris=> '192.168.1.0/24')
    mpr2 =  Mp_reach.new(:safi=>1, :nexthop=> ['10.0.0.1'], :nlris=> '192.168.1.0/24', :path_id=>100)
    mpr3 =  Mp_reach.new(:safi=>2, :nexthop=> ['10.0.0.1'], :nlris=> ['192.168.1.0/24','192.168.2.0/24'])
    mpr4 =  Mp_reach.new(:safi=>2, :nexthop=> ['10.0.0.1'], :nlris=> ['192.168.1.0/24','192.168.2.0/24'], :path_id=>100)
    mpr5 =  Mp_reach.new(:safi=>1, :nexthop=> ['10.0.0.1'], :nlris=> [
      {:prefix=> '192.168.1.0/24', :path_id=> 100},
      {:prefix=> '192.168.2.0/24', :path_id=> 101},
      {:prefix=> '192.168.2.0/24', :path_id=> 102},
    ])
    
    assert_equal('800e0d000101040a0000010018c0a801', mpr1.to_shex)
    assert_equal('800e11000101040a000001000000006418c0a801', mpr2.to_shex)
    assert_equal attr_len(mpr1)+4, attr_len(mpr2)
    
    assert_equal('800e11000102040a0000010018c0a80118c0a802', mpr3.to_shex)
    assert_equal('800e19000102040a000001000000006418c0a8010000006418c0a802', mpr4.to_shex)
    assert_equal attr_len(mpr3)+8, attr_len(mpr4)

    assert_equal('800e21000101040a000001000000006418c0a8010000006518c0a8020000006618c0a802', mpr5.to_shex)
    
  end
  
  def test_afi_1_ntop
    
    s = '800e11000102040a0000010018c0a80118c0a802'
    sbin = [s].pack('H*') 
    mpr = Mp_reach.new(sbin, false)
    assert_match(/^\s+192.168.1.0\/24/, mpr.to_s)
    assert_match(/^\s+192.168.1.0\/24/, mpr.to_s)

    s = '800e19000102040a000001000000006418c0a8010000006418c0a802'
    sbin = [s].pack('H*') 
    mpr = Mp_reach.new(sbin, true)
    assert_match(/^\s+ID=100, 192.168.1.0\/24/, mpr.to_s)
    assert_match(/^\s+ID=100, 192.168.1.0\/24/, mpr.to_s)
  end
  

  def test_afi_2
    mpr1 =  Mp_reach.new(:safi=>1, :nexthop=> ['2011:1:7::1'], :nlris=>  '2011:1::/32')
    mpr2 =  Mp_reach.new(:safi=>1, :nexthop=> ['2011:1:7::1'], :nlris=>  '2011:1::/32', :path_id=>100)
    mpr3 =  Mp_reach.new(:safi=>2, :nexthop=> ['2011:1:7::1'], :nlris=> ['2011:1::/32','2011:2::/32'])
    mpr4 =  Mp_reach.new(:safi=>2, :nexthop=> ['2011:1:7::1'], :nlris=> ['2011:1::/32','2011:2::/32'], :path_id=>100)
    mpr5 =  Mp_reach.new(:safi=>1, :nexthop=> ['2011:1:7::1'], :nlris=> [
      {:prefix=> '2011:1::/32', :path_id=> 100},
      {:prefix=> '2011:2::/32', :path_id=> 101},
      {:prefix=> '2011:3::/32', :path_id=> 102},
    ])
    
    assert_equal('800e1a0002011020110001000700000000000000000001002020110001', mpr1.to_shex)
    assert_equal('800e1e000201102011000100070000000000000000000100000000642020110001', mpr2.to_shex)
    assert_equal attr_len(mpr1)+4, attr_len(mpr2)
    
    assert_equal('800e1f00020210201100010007000000000000000000010020201100012020110002', mpr3.to_shex)
    assert_equal('800e27000202102011000100070000000000000000000100000000642020110001000000642020110002', mpr4.to_shex)
    assert_equal attr_len(mpr3)+8, attr_len(mpr4)

    assert_equal('800e30000201102011000100070000000000000000000100000000642020110001000000652020110002000000662020110003', mpr5.to_shex)
    
    
  end
  
  def test_afi_2_ntop
    
    s = '800e1f00020210201100010007000000000000000000010020201100012020110002'
    sbin = [s].pack('H*') 
    mpr = Mp_reach.new(sbin, false)
    assert_match(/^\s+2011:1::\/32/, mpr.to_s)
    assert_match(/^\s+2011:2::\/32/, mpr.to_s)

    s = '800e27000202102011000100070000000000000000000100000000642020110001000000642020110002'
    sbin = [s].pack('H*') 
    mpr = Mp_reach.new(sbin, true)
    assert_match(/^\s+ID=100, 2011:1::\/32/, mpr.to_s)
    assert_match(/^\s+ID=100, 2011:2::\/32/, mpr.to_s)
  end

  def test_safi_4
    mpr1 =  Mp_reach.new(:safi=>4, :nexthop=> ['10.0.0.1'], :nlris=> {:prefix=> '192.168.0.0/24', :label=>101} )
    mpr2 =  Mp_reach.new(:safi=>4, :nexthop=> ['10.0.0.1'], :nlris=> {:prefix=> '192.168.0.0/24', :label=>101, :path_id=>100} )
    mpr3 =  Mp_reach.new(:safi=>4, :nexthop=> ['10.0.0.1'], :nlris=> [
      {:prefix=> '192.168.0.0/24', :label=>101,},
      {:prefix=> '192.168.1.0/24', :label=>102,},
      {:prefix=> '192.168.1.0/24', :label=>103,}
    ])
    mpr4 =  Mp_reach.new(:safi=>4, :nexthop=> ['10.0.0.1'], :path_id=> 100, :nlris=> [
      {:prefix=> '192.168.0.0/24', :label=>101,},
      {:prefix=> '192.168.1.0/24', :label=>102,},
      {:prefix=> '192.168.1.0/24', :label=>103,}
    ])
    mpr5 =  Mp_reach.new(:safi=>4, :nexthop=> ['10.0.0.1'], :nlris=> [
      {:prefix=> '192.168.0.0/24', :label=>101, :path_id=>100},
      {:prefix=> '192.168.1.0/24', :label=>102, :path_id=>101},
      {:prefix=> '192.168.1.0/24', :label=>103, :path_id=>103},
    ])
    
    assert_equal('800e10000104040a0000010030000651c0a800', mpr1.to_shex)
    assert_equal('800e14000104040a000001000000006430000651c0a800', mpr2.to_shex)
    assert_equal attr_len(mpr1)+4, attr_len(mpr2)
    
    assert_equal('800e1e000104040a0000010030000651c0a80030000661c0a80130000671c0a801', mpr3.to_shex)
    assert_equal('800e2a000104040a000001000000006430000651c0a8000000006430000661c0a8010000006430000671c0a801', mpr4.to_shex)
    assert_equal attr_len(mpr3)+12, attr_len(mpr4)

    assert_equal('800e2a000104040a000001000000006430000651c0a8000000006530000661c0a8010000006730000671c0a801', mpr5.to_shex)
    
  end
  
  def test_safi_128
    mpr1 = Mp_reach.new :safi=>128, :nexthop=> ['10.0.0.1'], :nlris=> {:rd=> [100,100], :prefix=> '192.168.0.0/24', :label=>101}
    mpr2 = Mp_reach.new :safi=>128, :nexthop=> ['10.0.0.1'], :nlris=> {:rd=> [100,100], :prefix=> '192.168.0.0/24', :label=>101, :path_id=>100}
    mpr3 = Mp_reach.new :safi=>128, :nexthop=> ['10.0.0.1'], :nlris=> [
      {:rd=> [100,100], :prefix=> '192.168.0.0/24', :label=>101},
      {:rd=> [100,100], :prefix=> '192.168.1.0/24', :label=>102},
      {:rd=> [100,100], :prefix=> '192.168.2.0/24', :label=>103},
    ]
    mpr4 = Mp_reach.new :safi=>128, :nexthop=> ['10.0.0.1'], :path_id=> 100, :nlris=> [
      {:rd=> [100,100], :prefix=> '192.168.0.0/24', :label=>101},
      {:rd=> [100,100], :prefix=> '192.168.1.0/24', :label=>102},
      {:rd=> [100,100], :prefix=> '192.168.2.0/24', :label=>103},
    ]
    mpr5 = Mp_reach.new :safi=>128, :nexthop=> ['10.0.0.1'], :nlris=> [
      {:rd=> [100,100], :prefix=> '192.168.0.0/24', :label=>101, :path_id=>101},
      {:rd=> [100,100], :prefix=> '192.168.1.0/24', :label=>102, :path_id=>102},
      {:rd=> [100,100], :prefix=> '192.168.2.0/24', :label=>103, :path_id=>103},
    ]

    assert_equal('800e200001800c00000000000000000a00000100700006510000006400000064c0a800', mpr1.to_shex)
    assert_equal('800e240001800c00000000000000000a0000010000000064700006510000006400000064c0a800', mpr2.to_shex)
    assert_equal attr_len(mpr1)+4, attr_len(mpr2)
    
    assert_equal('800e3e0001800c00000000000000000a00000100700006510000006400000064c0a800700006610000006400000064c0a801700006710000006400000064c0a802', mpr3.to_shex)
    assert_equal('800e4a0001800c00000000000000000a0000010000000064700006510000006400000064c0a80000000064700006610000006400000064c0a80100000064700006710000006400000064c0a802', mpr4.to_shex)
    assert_equal attr_len(mpr3)+12, attr_len(mpr4)

    assert_equal('800e4a0001800c00000000000000000a0000010000000065700006510000006400000064c0a80000000066700006610000006400000064c0a80100000067700006710000006400000064c0a802', mpr5.to_shex)

    # 800e3e 0001 80 0c 00000000000000000a000001 00
    #    700006510000006400000064c0a800
    #    700006610000006400000064c0a801
    #    700006710000006400000064c0a802
    # 
    # 
    # 800e4a0001800c00000000000000000a000001 00
    #    00000064 700006510000006400000064c0a800
    #    00000064 700006610000006400000064c0a801
    #    00000064 700006710000006400000064c0a802
    # 
    # 
    # 800e4a 0001 80 0c 00000000000000000a000001 00 
    #   00000065 700006510000006400000064c0a800
    #   00000066 700006610000006400000064c0a801
    #   00000067 700006710000006400000064c0a802

  end
  
  def test_safi_4_ntop
    
    s = '800e1e000104040a0000010030000651c0a80030000661c0a80130000671c0a801'
    sbin = [s].pack('H*') 
    mpr = Mp_reach.new(sbin, false)
    assert_match(/^\s+Label Stack=101 /, mpr.to_s)
    assert_match(/^\s+Label Stack=102 /, mpr.to_s)
    assert_match(/^\s+Label Stack=103 /, mpr.to_s)

    s = '800e2a000104040a000001000000006430000651c0a8000000006430000661c0a8010000006430000671c0a801'
    sbin = [s].pack('H*') 
    mpr = Mp_reach.new(sbin, true)
    assert_match(/ID=100, Label Stack=101 /, mpr.to_s)
    assert_match(/ID=100, Label Stack=102 /, mpr.to_s)
    assert_match(/ID=100, Label Stack=103 /, mpr.to_s)
  end
  
  def test_safi_128_ntop
    
    s = '800e3e0001800c00000000000000000a00000100700006510000006400000064c0a800700006610000006400000064c0a801700006710000006400000064c0a802'
    sbin = [s].pack('H*') 
    mpr = Mp_reach.new(sbin, false)
    assert_match(/^\s+Label Stack=101 /, mpr.to_s)
    assert_match(/^\s+Label Stack=102 /, mpr.to_s)
    assert_match(/^\s+Label Stack=103 /, mpr.to_s)

    s = '800e4a0001800c00000000000000000a0000010000000065700006510000006400000064c0a80000000066700006610000006400000064c0a80100000067700006710000006400000064c0a802'
    sbin = [s].pack('H*') 
    mpr = Mp_reach.new(sbin, true)
    assert_match(/ID=101, Label Stack=101 /, mpr.to_s)
    assert_match(/ID=102, Label Stack=102 /, mpr.to_s)
    assert_match(/ID=103, Label Stack=103 /, mpr.to_s)
  end
  
  private
  
  def attr_len(attr)
    attr.encode[2,1].unpack('C')[0]
  end
  
end
