#--
# Copyright 2008, 2009, 2026 Jean-Michel Esnault.
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
require 'stringio'

class Mp_reach_Test < Test::Unit::TestCase
  include BGP

  def test_invalid_arguments_raise_quietly
    out, $stdout = $stdout, StringIO.new
    assert_raise(ArgumentError) { Mp_reach.new(1, 2) }
    assert_raise(ArgumentError) { Mp_reach.new(:safi=>1, :nexthop=>['10.0.0.1'], :nlris=>1) }
    assert_equal('', $stdout.string)
  ensure
    $stdout = out
  end

  def test_iso_mapped_ip_addr
    mapped_addr = Iso_ip_mapped.new('10.0.0.1')
    assert_equal('470006010a00000100', mapped_addr.to_shex)
    mapped_addr = Iso_ip_mapped.new('2011::1')
    assert_equal('3500002011000000000000000000000000000100', mapped_addr.to_shex)
  end

  # RFC 8950 section 3: IPv4 NLRI with an IPv6 next hop. The next hop
  # length tells the type: 16 or 32 for SAFI 1, 2 and 4, 24 or 48 for
  # SAFI 128 and 129. RFC 8950 has no hex capture; these follow its
  # field layout.

  def test_rfc8950_afi_1_safi_1_ipv6_nexthop
    s = '800e17 0001 01 10 20010db8000000000000000000000001 00 080a'.split.join
    mpr = Mp_reach.new(:afi=>1, :safi=>1, :nexthop=>'2001:db8::1', :nlris=>'10.0.0.0/8')
    assert_equal(s, mpr.to_shex)
    mpr2 = Mp_reach.new([s].pack('H*'))
    assert_equal('2001:db8::1', mpr2.nexthops)
    assert_equal('10.0.0.0/8', mpr2.nlris[0].to_s)
    assert_equal(mpr.to_hash, mpr2.to_hash)
    assert_equal(s, mpr2.to_shex)
  end

  def test_rfc8950_afi_1_safi_1_global_and_link_local_nexthops
    s = ('800e27 0001 01 20 20010db8000000000000000000000001 ' +
         'fe800000000000000000000000000001 00 080a').split.join
    mpr = Mp_reach.new([s].pack('H*'))
    assert_equal('2001:db8::1, fe80::1', mpr.nexthops)
    assert_equal(s, mpr.to_shex)
    assert_equal(s, Mp_reach.new(mpr.to_hash[:mp_reach]).to_shex)
  end

  def test_rfc8950_afi_1_safi_4_ipv6_nexthop
    s = '800e1a 0001 04 10 20010db8000000000000000000000001 00 20 000641 0a'.split.join
    mpr = Mp_reach.new([s].pack('H*'))
    assert_equal('2001:db8::1', mpr.nexthops)
    assert_equal(s, mpr.to_shex)
  end

  def test_rfc8950_afi_1_safi_128_vpn_ipv6_nexthop
    # Next hop: an RD of 8 zero octets, then the IPv6 address.
    s = ('800e2a 0001 80 18 0000000000000000 20010db8000000000000000000000001 00 ' +
         '60 000651 0000006400000064 0a').split.join
    mpr = Mp_reach.new(:afi=>1, :safi=>128, :nexthop=>'2001:db8::1',
                       :nlris=>{:rd=>[100,100], :prefix=>'10.0.0.0/8', :label=>101})
    assert_equal(s, mpr.to_shex)
    mpr2 = Mp_reach.new([s].pack('H*'))
    assert_equal('2001:db8::1', mpr2.nexthops)
    assert_equal(mpr.to_hash, mpr2.to_hash)
    s48 = ('800e42 0001 80 30 0000000000000000 20010db8000000000000000000000001 ' +
           '0000000000000000 fe800000000000000000000000000001 00 60 000651 0000006400000064 0a').split.join
    assert_equal('2001:db8::1, fe80::1', Mp_reach.new([s48].pack('H*')).nexthops)
  end

  def test_rfc8950_ipv4_nexthops_still_parse_as_ipv4
    # Two IPv4 next hops are 8 octets, not an RFC 8950 length.
    s = '800e0f 0001 01 08 0a000001 0a000002 00 080a'.split.join
    assert_equal('10.0.0.1, 10.0.0.2', Mp_reach.new([s].pack('H*')).nexthops)
  end
  
  def test_afi_3_safi_1_ipv4_mapped_nexthops
    mpr1 =  Mp_reach.new( :afi=>3, 
                          :safi=>1, 
                          :nexthop=> ['10.0.0.1',], 
                          :nlris=> '49.0001.0002.0003.0004.0005.0006/64' )
    
    s = '80 0e 17 0003 01 09 470006010a00000100 00 40 4900010002000300'

    assert_equal(s.split.join, mpr1.to_shex)
    
    mpr2 = Mp_reach.new(:afi=>3, 
                        :safi=>1, 
                        :nexthop=> ['1.1.1.1','2.2.2.2'], 
                        :nlris => '49.0001.0002.0003.0004.0005.0006')
    
    s = '80 0e 29 0003 01 10 4700060101010101   4700060102020202   00 98 49000100020003000400050006000000000000'
    s = '80 0e 2b 0003 01 12 470006010101010100 470006010202020200 00 98 49000100020003000400050006000000000000'    
    assert_equal(s.split.join, mpr2.to_shex)

    mpr2 = Mp_reach.new( :afi=>3, 
                         :safi=>1, 
                         :nexthop=> ['1.1.1.1','2.2.2.2'], 
                         :nlris => ['49.0001.0002.0003.0004.0005.0006','49.0011.0012.0013.0014.0015.0016'] 
                        )
    
    s = "80 0e 3d 0003 01 10 4700060101010101 4700060102020202 00 
              98 49000100020003000400050006000000000000
              98 49001100120013001400150016000000000000"
    s = '80 0e 3f 0003 01 12 470006010101010100 470006010202020200 00 
              98 49000100020003000400050006000000000000
              9849001100120013001400150016000000000000'

    assert_equal(s.split.join, mpr2.to_shex)

    mpr3 = Mp_reach.new( :afi=>3, 
                         :safi=>1, 
                         :nexthop=> '1.1.1.1', 
                         :nlris => ['49.0001.0002.0003.0004.0005.0006/48','49.0011.0012.0013.0014.0015.0016/72'] 
                        )
    
    s = "80 0e 1f 0003 01 09 470006010101010100 00 3049000100020048490011001200130014"

    assert_equal(s.split.join, mpr3.to_shex)

  end
  
  def test_afi_3_safi_1_ipv6_mapped_nexthops
    mpr1 =  Mp_reach.new(:afi=>3, :safi=>1, :nexthop=> ['2011::1'], :nlris=> '49.0001.0002.0003.0004.0005.0006/72' )

    s = '80 0e 23 000301143500002011000000000000000000000000000100 00 48490001000200030004'
    assert_equal(s.split.join, mpr1.to_shex)

    mpr2 =  Mp_reach.new(:afi=>3, :safi=>1, :nexthop=> ['2011::1', '2011::2'], :nlris=> '49.0001.0002.0003.0004.0005.0006/103' )

    s = '
    80 0e 3b 0003 01 28
        350000 2011000000000000000000000000000100
        350000 2011000000000000000000000000000200 00
        6749000100020003000400050006'
    assert_equal(s.split.join, mpr2.to_shex)

  end

  def test_afi_3_safi_1_ipv6_mapped_nexthops_with_path_id
    mpr1 =  Mp_reach.new(:afi=>3, :safi=>1, :nexthop=> ['2011::1'], :nlris=> '49.0001.0002.0003.0004.0005.0006/72', :path_id=>100 )

    s = '80 0e 27 0003 01 14 350000 2011000000000000000000000000000100 00 00000064 48490001000200030004'
    assert_equal(s.split.join, mpr1.to_shex)

    mpr2 =  Mp_reach.new(:afi=>3, :safi=>1, :nexthop=> ['2011::1', '2011::2'], :nlris=> '49.0001.0002.0003.0004.0005.0006/103' )

    s = '
    80 0e 3b 0003 01 28
        350000 2011000000000000000000000000000100
        350000 2011000000000000000000000000000200 00
        6749000100020003000400050006'
    assert_equal(s.split.join, mpr2.to_shex)

  end
  
  def test_afi_3_safi_1_ipv4_mapped_nexthops_ntoh
    
    # Mp Reach (14), length: 27, Flags [O]: 
    #     AFI  (3), SAFI Unicast (1)
    #     nexthop: 10.0.0.1
    #       49.0001.0002.0003.0004.0005.0006
    #    0x0000:  0003 0108 4700 0601 0a00 0001 0068 4900
    #    0x0001:  0100 0200 0300 0400 0500 06

    s = '800e1c00030109470006010a00000100006849000100020003000400050006'
    sbin = [s.split.join].pack('H*') 
    mpr = Mp_reach.new(sbin)

    assert_equal(s.split.join, mpr.to_shex)
    assert_equal("[Oncr] (14)   Mp Reach: [800e1c000301094700060...] '\n    AFI NSAP (3), SAFI Unicast (1)\n    nexthop: 10.0.0.1\n      49.0001.0002.0003.0004.0005.0006.0000.0000.0000.00/104'", mpr.to_s)
    
  end

  def test_afi_3_safi_128_ipv4_mapped_nexthops
    mpr =   Mp_reach.new(:afi=>3, :safi=>128, :nexthop=> '1.1.1.1', :nlris=> [
      {:rd=> [100,100], :prefix=> '49.abab.cdcd.efef/48', :label=>100},
      ]
    )
    smpr = '800e280003801100000000000000004700060101010101000088000641000000640000006449ababcdcdef'
    assert_equal(smpr, mpr.to_shex)

  end

  def test_afi_3_safi_128_ipv6_mapped_nexthops
    mpr =   Mp_reach.new(:afi=>3, :safi=>128, :nexthop=> '2011:03:26::1', :nlris=> [
      {:rd=> [100,100], :prefix=> '49.abab.cdcd.efef/48', :label=>100},
      ]
    )
    smpr = '80 0e 33 0003 80 
      1c 0000000000000000 350000 2011000300260000000000000000000100 00 88 000641 0000006400000064 49ababcdcdef'
    assert_equal(smpr.split.join, mpr.to_shex)
  end
  
  def test_afi_3_safi_128_ipv6_mapped_nexthops_ntoh
    s = '80 0e 33 0003 80 
    1c 0000000000000000 350000 2011000300260000000000000000000100 00 88 000641 0000006400000064 49ababcdcdef'
    sbin = [s.split.join].pack('H*') 
    mpr = Mp_reach.new(sbin)

    assert_equal(s.split.join, mpr.to_shex)
    assert_match(/nexthop: 2011:3:26::1/, mpr.to_s())
    assert_match(/Label Stack=100 \(bottom\) RD=100:100/, mpr.to_s())
    assert_match(/NSAP=49.abab.cdcd.ef00.0000.0000.0000.0000.0000.0000.00\/48/, mpr.to_s())

    mpr =   Mp_reach.new(:afi=>3, :safi=>128, :nexthop=> '2011:03:26::1', :nlris=> [
      {:rd=> [100,100], :prefix=> '49.abab.cdcd.efef/48', :label=>100},
    ]
    )
    smpr = '80 0e 33 0003 80 
    1c 0000000000000000 350000 2011000300260000000000000000000100 00 88 000641 0000006400000064 49ababcdcdef'
    assert_equal(smpr.split.join, mpr.to_shex)
  end
  
  def test_afi_3_safi_1_ipv6_mapped_nexthops_ntoh

    # Mp Reach (14), length: 57, Flags [O]: 
    #     AFI  (3), SAFI Unicast (1)
    #     nexthop: 2011::1, 2011::2
    #       49.0001.0002.0003.0004.0005.0006
    #    0x0000:  0003 0126 3500 0020 1100 0000 0000 0000
    #    0x0001:  0000 0000 0000 0135 0000 2011 0000 0000
    #    0x0002:  0000 0000 0000 0000 0002 0068 4900 0100
    #    0x0003:  0200 0300 0400 0500 06

    s = '
    80 0e 3b 0003 01 
    28 
      350000 2011000000000000000000000000000100
      350000 2011000000000000000000000000000200
    00
    68 49000100020003000400050006'
    sbin = [s.split.join].pack('H*') 
    
    mpr = Mp_reach.new(sbin)
    
    assert_equal(s.split.join, mpr.to_shex)
    assert_equal("[Oncr] (14)   Mp Reach: [800e3b000301283500002...] '\n    AFI NSAP (3), SAFI Unicast (1)\n    nexthop: 2011::1, 2011::2\n      49.0001.0002.0003.0004.0005.0006.0000.0000.0000.00/104'", mpr.to_s())
  end    
  
  def test_afi_2_safi_2_ipv4_mapped
    s = '800e30000202102009000900190000000000000000000100402009000100000000402009000200000000402009000300000000'
    sbin = [s].pack('H*') 
    mpr = Mp_reach.new(sbin)
    assert_equal("\n    AFI IPv6 (2), SAFI Multicast (2)\n    nexthop: 2009:9:19::1\n      2009:1::/64\n      2009:2::/64\n      2009:3::/64", mpr.mp_reach)
    assert_equal(2, mpr.afi)
    assert_equal(2, mpr.safi)
    assert_equal(s, mpr.to_shex)
  end
  
  
  def test_afi_2_safi_2
    s = '800e30000202102009000900190000000000000000000100402009000100000000402009000200000000402009000300000000'
    sbin = [s].pack('H*') 
    mpr = Mp_reach.new(sbin)
    assert_equal("\n    AFI IPv6 (2), SAFI Multicast (2)\n    nexthop: 2009:9:19::1\n      2009:1::/64\n      2009:2::/64\n      2009:3::/64", mpr.mp_reach)
    assert_equal(2, mpr.afi)
    assert_equal(2, mpr.safi)
    assert_equal(s, mpr.to_shex)
  end
  def test_afi_2_safi_1_nexthop_2
    s = "800e2500020120200900090019000000000000000000012009000900190000000000000000000200"
    sbin = [s].pack('H*') 
    mpr = Mp_reach.new(sbin)
    assert_equal("\n    AFI IPv6 (2), SAFI Unicast (1)\n    nexthop: 2009:9:19::1, 2009:9:19::2", mpr.mp_reach)
    assert_equal(2, mpr.afi)
    assert_equal(1, mpr.safi)
    assert_equal(s, mpr.to_shex)
  end
  def test_afi_1_safi_2_nexthop_2
    s = "800e0d000102080a0000010a00000200"
    sbin = [s].pack('H*') 
    mpr = Mp_reach.new(sbin)
    assert_equal("\n    AFI IPv4 (1), SAFI Multicast (2)\n    nexthop: 10.0.0.1, 10.0.0.2", mpr.mp_reach)
    assert_equal(1, mpr.afi)
    assert_equal(2, mpr.safi)
    assert_equal(s, mpr.to_shex)
  end
  def test_afi_1_safi_2_nexthop_1
    s = "800e11000102040a0000010018c0a80118c0a802"
    sbin = [s].pack('H*') 
    mpr = Mp_reach.new(sbin)
    assert_equal("\n    AFI IPv4 (1), SAFI Multicast (2)\n    nexthop: 10.0.0.1\n      192.168.1.0/24\n      192.168.2.0/24", mpr.mp_reach)
    assert_equal(1, mpr.afi)
    assert_equal(2, mpr.safi)
    assert_equal(s, mpr.to_shex)
  end
  def test_afi_2_safi_4_nexthop_1
    s = "800e39000204102009000900190000000000000000000100580006512009000100000000580006612009000200000000580006712009000300000000"
    sbin = [s].pack('H*') 
    mpr = Mp_reach.new(sbin)
    assert_equal("\n    AFI IPv6 (2), SAFI Labeled NLRI (4)\n    nexthop: 2009:9:19::1\n      Label Stack=101 (bottom) 2009:1::/64\n      Label Stack=102 (bottom) 2009:2::/64\n      Label Stack=103 (bottom) 2009:3::/64", mpr.mp_reach)
    assert_equal(2, mpr.afi)
    assert_equal(4, mpr.safi)
    assert_equal(s, mpr.to_shex)
    #puts mpr
  end
  def test_afi_1_2_safi_1_2_4_128_hash
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
  def ___test_afi_1_2_safi_1_2_4_128_hash
    mpr = Mp_reach.new(:safi=>128, :nexthop=> ['10.0.0.1','10.0.0.2'], :nlris=> {:rd=> [100,100], :prefix=> '192.168.0.0/24', :label=>101})
    assert_equal("\n    AFI IPv4 (1), SAFI Labeled VPN Unicast (128)\n    nexthop: 10.0.0.1, 10.0.0.2\n      Label Stack=101 (bottom) RD=100:100, IPv4=192.168.0.0/24", mpr.mp_reach)
    assert_equal(mpr.to_shex, Mp_reach.new(mpr.encode).to_shex)
  end
  def test_afi_1_2_safi_1_2_hash_multiple_prefix
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
    
    assert_equal('800e 0d 0001 01 04 0a000001 00 18c0a801'.split.join, mpr1.to_shex)
    assert_equal('800e 11 0001 01 04 0a000001 00 00000064 18c0a801'.split.join, mpr2.to_shex)
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

  def test_afi_1_safi_1_ntop
    # AFI 1 SAFI 1 used to parse each prefix as a whole Nlri: to_hash gave
    # {:nlris=>[...]} per prefix, and with path IDs the ID was read twice.
    s = '800e11000101040a0000010018c0a80118c0a802'
    mpr = Mp_reach.new([s].pack('H*'), false)
    assert_equal(['192.168.1.0/24', '192.168.2.0/24'], mpr.nlris.map(&:to_s))
    assert_equal({:mp_reach=>{:safi=>1, :afi=>1, :nexthop=>['10.0.0.1'],
                              :nlris=>['192.168.1.0/24', '192.168.2.0/24']}}, mpr.to_hash)
    assert_equal(s, mpr.to_shex)

    # RFC 7911 section 3: each NLRI starts with its 4 octet Path Identifier.
    s = '800e19000101040a000001000000006418c0a8010000006518c0a802'
    mpr = Mp_reach.new([s].pack('H*'), true)
    assert_equal(['ID=100, 192.168.1.0/24', 'ID=101, 192.168.2.0/24'], mpr.nlris.map(&:to_s))
    assert_equal(s, mpr.to_shex)
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
    
    assert_equal('800e1a0 002 01 10 20110001000700000000000000000001 00 2020110001'.split.join, mpr1.to_shex)
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
  
  def test_afi_3_safi_1
    # TODO: either use :iso_nexthop=> ''2011:3:27::1'
    # :afi=> :iso or :nasp
    # test :afi=> ipv4 ipv6 osi nsap
    # test :safi unicast multicast
    mpr1 =  Mp_reach.new(:afi=>3, :safi=>1, :nexthop=> '2011:3:27::1', :nlris=>  '49.0001.0002.0000/48')
    mpr2 =  Mp_reach.new(:afi=>3, :safi=>1, :nexthop=> '2011:3:27::1', :nlris=>  '49.0001.0002.0000/48', :path_id=>100)
    mpr3 =  Mp_reach.new(:afi=>3, :safi=>1, :nexthop=> '2011:3:27::1', :nlris=> ['49.0001.0002.0000/48','49.0a00.0b00/32'])
    mpr4 =  Mp_reach.new(:afi=>3, :safi=>1, :nexthop=> '2011:3:27::1', :nlris=> ['49.0001.0002.0000/48','49.0a00.0b00/32'], :path_id=>100)
    mpr5 =  Mp_reach.new(:afi=>3, :safi=>1, :nexthop=> '2011:3:27::1', :nlris=> [
      {:prefix=> '49.0a00.0b00/32', :path_id=> 100},
      {:prefix=> '49.0a00.0b00/32', :path_id=> 101},
      {:prefix=> '49.0a00.0b00/32', :path_id=> 102},
    ])
    
    assert_equal('80 0e 20 0003 01 14 3500002011000300270000000000000000000100 00          30 490001000200'.split.join, mpr1.to_shex)
    assert_equal('80 0e 24 0003 01 14 3500002011000300270000000000000000000100 00 00000064 30 490001000200'.split.join, mpr2.to_shex)
    assert_equal attr_len(mpr1)+4, attr_len(mpr2)
    
    assert_equal('800e25000301143500002011000300270000000000000000000100 00 30 49000100020020 490a000b'.split.join, mpr3.to_shex)
    assert_equal('800e2d0003011435000020110003002700000000000000000001000000000064304900010002000000006420490a000b'.split.join, mpr4.to_shex)
    assert_equal attr_len(mpr3)+8, attr_len(mpr4) 
    
    smpr5 = '
      80 0e 34 0003 01 14 3500002011000300270000000000000000000100 00 
      00000064 20490a000b 
      0000006520490a000b
      0000006620490a000b'
    assert_equal(smpr5.split.join, mpr5.to_shex)
  end
  
  def test_afi_3_safi_1_ntop
    s = '800e25000301143500002011000300270000000000000000000100 00 30 49000100020020 490a000b'
    sbin = [s.split.join].pack('H*') 
    mpr = Mp_reach.new(sbin, false)
    assert_match(/nexthop: 2011:3:27::1/, mpr.to_s)
    assert_match(/^\s+49.0001.0002.0000.0000.0000.0000.0000.0000.0000.00\/48/, mpr.to_s)
    assert_match(/^\s+49.0a00.0b00.0000.0000.0000.0000.0000.0000.0000.00\/32/, mpr.to_s)

    s = '
      80 0e 34 0003 01 14 3500002011000300270000000000000000000100 00 
      00000064 20490a100b 
      00000065 20490a200b
      00000066 20490a300b'
    sbin = [s.split.join].pack('H*') 
    mpr = Mp_reach.new(sbin, true)

    assert_match(/nexthop: 2011:3:27::1/, mpr.to_s)
    assert_match(/ID=100, 49.0a10.0b00.0000.0000.0000.0000.0000.0000.0000.00\/32/, mpr.to_s)
    assert_match(/ID=101, 49.0a20.0b00.0000.0000.0000.0000.0000.0000.0000.00\/32/, mpr.to_s)
    assert_match(/ID=102, 49.0a30.0b00.0000.0000.0000.0000.0000.0000.0000.00\/32/, mpr.to_s)
    
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
  
  def test_afi_1_safi_128
    
    smpr1 = '80 0e 20 0001 80 0c 00000000000000000a000001 00          70 000651 0000006400000064 c0a800'
    smpr2 = '80 0e 24 0001 80 0c 00000000000000000a000001 00 00000064 70 000651 0000006400000064 c0a800'
    smpr3 = '80 0e 3e 0001 80 0c 00000000000000000a000001 00 
                               70 000651 0000006400000064 c0a800
                               70 000661 0000006400000064 c0a801
                               70 000671 0000006400000064 c0a802'
    smpr4 = '80 0e 4a 0001 80 0c 00000000000000000a000001 00
                      00000064 70 000651 0000006400000064 c0a800  
                      00000064 70 000661 0000006400000064 c0a801
                      00000064 70 000671 0000006400000064 c0a802'
    smpr5 = '80 0e 4a 0001 80 0c 00000000000000000a000001 00 
                      00000065 70 000651 0000006400000064 c0a800
                      00000066 70 000661 0000006400000064 c0a801
                      00000067 70 000671 0000006400000064 c0a802'
    
    mpr1 = Mp_reach.new :safi=>128, :nexthop=> ['10.0.0.1'], 
                        :nlris=> {:rd=> [100,100], :prefix=> '192.168.0.0/24', :label=>101}
    mpr2 = Mp_reach.new :safi=>128, :nexthop=> ['10.0.0.1'], 
                        :nlris=> {:rd=> [100,100], :prefix=> '192.168.0.0/24', :label=>101, :path_id=>100}
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

    assert_equal(smpr1.split.join, mpr1.to_shex)
    assert_equal(smpr2.split.join, mpr2.to_shex)
    assert_equal attr_len(mpr1)+4, attr_len(mpr2)
    assert_equal(smpr3.split.join, mpr3.to_shex)
    assert_equal(smpr4.split.join, mpr4.to_shex)
    assert_equal attr_len(mpr3)+12, attr_len(mpr4)
    assert_equal(smpr5.split.join, mpr5.to_shex)

  end
  
  def test_afi_1safi_4_ntop
    
    s = '80 0e 1e 0001 04 04 0a000001 00 30000651 c0a800
                                         30000661 c0a801
                                         30000671 c0a801'
    sbin = [s.split.join].pack('H*') 
    mpr = Mp_reach.new(sbin, false)
    assert_match(/^\s+Label Stack=101 /, mpr.to_s)
    assert_match(/^\s+Label Stack=102 /, mpr.to_s)
    assert_match(/^\s+Label Stack=103 /, mpr.to_s)

    s = '80 0e 2a 0001 04 04 0a000001 00 00000064 30000651 c0a800 
                                         00000064 30000661 c0a801 
                                         00000064 30000671 c0a801'

    sbin = [s.split.join].pack('H*') 
    mpr = Mp_reach.new(sbin, true)
    assert_match(/Stack=101 \(bottom\) ID=100/, mpr.to_s)
    assert_match(/Stack=102 \(bottom\) ID=100/, mpr.to_s)
    assert_match(/Stack=103 \(bottom\) ID=100/, mpr.to_s)
  end
  
  def test_afi_1_safi_128_ntop
    
    s = '80 0e 3e 0001 80 0c 0000000000000000 0a000001 00 70 000651 0000006400000064 c0a800
                                                          70 000661 0000006400000064 c0a801
                                                          70 000671 0000006400000064 c0a802'
    sbin = [s.split.join].pack('H*') 
    mpr = Mp_reach.new(sbin, false)
    assert_match(/^\s+Label Stack=101 /, mpr.to_s)
    assert_match(/^\s+Label Stack=102 /, mpr.to_s)
    assert_match(/^\s+Label Stack=103 /, mpr.to_s)
    
    assert_equal(s.split.join, mpr.to_shex)
    
    s = '80 0e 4a 0001 80 0c 00000000000000000a000001 00 00000065 70 000651 0000006400000064 c0a800
                                                         00000066 70 000661 0000006400000064 c0a801
                                                         00000067 70 000671 0000006400000064 c0a802'
    sbin = [s.split.join].pack('H*') 
    mpr = Mp_reach.new(sbin, true)
    assert_match(/Label Stack=101.*ID=101, /, mpr.to_s)
    assert_match(/Label Stack=102.*ID=102, /, mpr.to_s)
    assert_match(/Label Stack=103.*ID=103, /, mpr.to_s)
    
    s = '80 0e 3b 0001 80 0c 0000000000000000 0a000001 00 70 000651 0000006400000064 c0a800
                                                          70 000661 0000006400000064 c0a801
                                                          58 000671 0000006400000064'
    sbin = [s.split.join].pack('H*')
    mpr = Mp_reach.new(sbin, false)
    assert_equal(s.split.join, mpr.to_shex)
    assert_match(/IPv4=0.0.0.0\/0/, mpr.to_s)
  
  end
  
  def test_derive_afi_from_nlris
    assert_equal(1, Mp_reach.afi_from_nlris('192.168.1.0/24'))
    assert_equal(2, Mp_reach.afi_from_nlris('2011:1::/32'))
    assert_equal(3, Mp_reach.afi_from_nlris('49.0001.0002.0003.0004.0005.0006/64'))
    assert_equal(1, Mp_reach.afi_from_nlris(['192.168.1.0/24','192.168.2.0/24' ]))
    assert_equal(2, Mp_reach.afi_from_nlris(['2011:1::/32','2011:2::/32']))
    assert_equal(3, Mp_reach.afi_from_nlris(['49.0001.0002.0003.0004.0005.0006/64','49.0001.0002/32']))
    assert_equal(1, Mp_reach.afi_from_nlris(:prefix=>'192.168.1.0/24'))
    assert_equal(3, Mp_reach.afi_from_nlris(:prefix=>'49.0001.0002.0003.0004.0005.0006/64'))
    assert_equal(1, Mp_reach.afi_from_nlris([{:prefix=>'192.168.1.0/24'}]))
    assert_equal(3, Mp_reach.afi_from_nlris([
      {:rd=> [100,100], :prefix=> '49.abab.cdcd.efef/48', :label=>100},
      ]))
  end
  
  def test_to_hash
    
    mpr1 = Mp_reach.new :safi=>128, :nexthop=> ['10.0.0.1'], 
                        :nlris=> {:rd=> [100,100], :prefix=> '192.168.0.0/24', :label=>101}
    mpr2 = Mp_reach.new :safi=>128, :nexthop=> ['10.0.0.1'], 
                        :nlris=> {:rd=> [100,100], :prefix=> '192.168.0.0/24', :label=>101, :path_id=>100}
    mpr3 = Mp_reach.new :safi=>128, :nexthop=> ['10.0.0.1'], :nlris=> [
      {:rd=> [100,100], :prefix=> '192.168.0.0/24', :label=>101},
      {:rd=> [100,100], :prefix=> '192.168.1.0/24', :label=>102},
      {:rd=> [100,100], :prefix=> '192.168.2.0/24', :label=>103},
    ]
    
    h = {:safi=>128, :nexthop=> ['10.0.0.1'], 
                        :nlris=> {:rd=> [100,100], :prefix=> '192.168.0.0/24', :label=>101}}

    assert_equal( 128, mpr1.to_hash[:mp_reach][:safi])
    assert_equal( 1, mpr1.to_hash[:mp_reach][:afi])
    assert_equal( h[:nexthop], mpr1.to_hash[:mp_reach][:nexthop])
    assert_equal( h[:nlris], mpr1.to_hash[:mp_reach][:nlris])
    
    h = {:safi=>128, :nexthop=> ['10.0.0.1'], :nlris=> [
      {:rd=> [100,100], :prefix=> '192.168.0.0/24', :label=>101},
      {:rd=> [100,100], :prefix=> '192.168.1.0/24', :label=>102},
      {:rd=> [100,100], :prefix=> '192.168.2.0/24', :label=>103},
      ]}

    assert_equal( 128, mpr3.to_hash[:mp_reach][:safi])
    assert_equal( 1, mpr3.to_hash[:mp_reach][:afi])
    assert_equal( h[:nexthop], mpr3.to_hash[:mp_reach][:nexthop])
    assert_equal( h[:nlris], mpr3.to_hash[:mp_reach][:nlris])
    
    
    assert_equal(mpr1.to_hash, Mp_reach.new(mpr1.to_hash[:mp_reach]).to_hash)
    assert_equal(mpr2.to_hash, Mp_reach.new(mpr2.to_hash[:mp_reach]).to_hash)
    assert_equal(mpr3.to_hash, Mp_reach.new(mpr3.to_hash[:mp_reach]).to_hash)
    
  end

  def test_invalid_nlri_type_without_afi_has_a_message
    e = assert_raise(ArgumentError) { Mp_reach.new(:safi=>1, :nexthop=>'10.0.0.1', :nlris=>[1]) }
    assert_match(/invalid NLRI: 1/, e.message)
  end

  def test_unknown_afi_has_a_message
    e = assert_raise(ArgumentError) { Mp_reach.new(:afi=>5, :safi=>1, :nexthop=>'10.0.0.1', :nlris=>'10.0.0.0/8') }
    assert_match(/AFI 5 is not supported/, e.message)
  end

  def test_iso_mapped_next_hops_need_afi_3
    mpr = Mp_reach.new(:safi=>1, :nexthop=>'10.0.0.1', :nlris=>'10.0.0.0/8')
    e = assert_raise(ArgumentError) { mpr.parse_iso_mapped_next_hops(['470006010a00000100'].pack('H*')) }
    assert_match(/need AFI 3, not AFI 1/, e.message)
  end

  def test_unknown_iso_mapped_next_hop_has_a_message
    # Same as the AFI 3 test above, with IDP 0x99 in place of 0x47.
    s =['800e1700030109990006010a00000100004049000100020003'+'00'].pack('H*')
    e = assert_raise(ArgumentError) { Mp_reach.new(s) }
    assert_match(/IDP 0x99/, e.message)
  end

  def test_top_level_path_id_applies_to_hash_nlris
    mpr = Mp_reach.new(:safi=>1, :nexthop=>'10.0.0.1', :path_id=>7,
                       :nlris=>[{:prefix=>'10.0.0.0/8'}, {:prefix=>'11.0.0.0/8', :path_id=>9}])
    assert_equal([7, 9], mpr.nlris.collect { |n| n.path_id })
    # AFI 1, SAFI 1, next hop 10.0.0.1, then <path id, length, prefix>
    # per NLRI (RFC 7911 section 3).
    assert_equal('800e15000101040a0000010000000007080a00000009080b', mpr.to_shex)
    v6 = Mp_reach.new(:safi=>1, :nexthop=>'2001:db8::1', :path_id=>3, :nlris=>{:prefix=>'2001:db8:1::/48'})
    assert_equal(3, v6.nlris[0].path_id)
  end

  private

  def attr_len(attr)
    attr.encode[2,1].unpack('C')[0]
  end
  
end
