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

class Mp_unreach_Test < Test::Unit::TestCase
  include BGP
  def test_1
    mpur = Mp_unreach.new(:safi=>1, :nlris=>['10.0.0.0/16', '10.1.0.0/16'])
    assert_equal(mpur.to_shex,'800f09000101100a00100a01')
    h = {:afi=>1, :safi=>1, :nlris=>["10.0.0.0/16", "10.1.0.0/16"]}
    assert_equal({:mp_unreach=>h}, mpur.to_hash)
    assert_raise(ArgumentError) { Mp_unreach.new }
  end
  
  def test_2
    mpur = Mp_unreach.new(:safi=>2, :nlris=>['192.168.1.0/24', '192.168.2.0/24'])
    assert_equal('800f0b00010218c0a80118c0a802', mpur.to_shex)
    
     mpur = Mp_unreach.new(:safi=>2, :nlris=>['2007:1::/64', '2007:2::/64','2007:3::/64'])
     assert_equal('800f1e000202402007000100000000402007000200000000402007000300000000', mpur.to_shex)

     #mpur = Mp_unreach.new(:safi=>2, :prefix=>['2007:1::/64, 101', '2007:2::/64,102','2007:3::/64, 103'])
     mpur = Mp_unreach.new(:safi=>4, :nlris=> [
       {:prefix=>'2007:1::/64', :label=> 101},
       {:prefix=>'2007:2::/64', :label=> 102},
       {:prefix=>'2007:3::/64', :label=> 103},])
       
    
    assert_equal('800f27000204580006512007000100000000580006612007000200000000580006712007000300000000', mpur.to_shex)
    assert_match(/^800f..000204/,mpur.to_shex)
    assert_match(/58000651200700010000000058/,mpur.to_shex)
    assert_match(/58000661200700020000000058/,mpur.to_shex)
    assert_match(/580006712007000300000000$/,mpur.to_shex)

    mpur = Mp_unreach.new(:safi=>128, :nlris=> [
      {:rd=> Rd.new(100,100), :prefix=> Prefix.new('192.168.1.0/24'), :label=>101},
      {:rd=> Rd.new(100,100), :prefix=> Prefix.new('192.168.2.0/24'), :label=>102},
      {:rd=> Rd.new(100,100), :prefix=> Prefix.new('192.168.3.0/24'), :label=>103},])


    assert_match(/^800f..000180/,mpur.to_shex)
    assert_equal("700006510000006400000064c0a801",mpur.nlris[0].to_shex)
    assert_equal("700006610000006400000064c0a802",mpur.nlris[1].to_shex)

    mpur = Mp_unreach.new(:safi=>128, :nlris=> [
      {:rd=> Rd.new(100,100), :prefix=> '192.168.1.0/24', :label=>101},
      {:rd=> Rd.new(100,100), :prefix=> '192.168.2.0/24', :label=>102},
      {:rd=> Rd.new(100,100), :prefix=> '192.168.3.0/24', :label=>103},])
      assert_match(/^800f..000180/,mpur.to_shex)
      assert_equal("700006510000006400000064c0a801",mpur.nlris[0].to_shex)
      assert_equal("700006610000006400000064c0a802",mpur.nlris[1].to_shex)

  end
  
  def test_3
    assert_equal '800f03000104', Mp_unreach.new(:afi=>1, :safi=>4).to_shex
    assert_equal '800f03000180', Mp_unreach.new(:afi=>1, :safi=>128).to_shex
    assert_equal '800f03000102', Mp_unreach.new(:afi=>1, :safi=>2).to_shex
  end
  
  def test_afi_1
    mpr1 =  Mp_unreach.new(:safi=>1, :nlris=> '192.168.1.0/24')
    mpr2 =  Mp_unreach.new(:safi=>1, :nlris=> '192.168.1.0/24', :path_id=>100)
    mpr3 =  Mp_unreach.new(:safi=>2, :nlris=> ['192.168.1.0/24','192.168.2.0/24'])
    mpr4 =  Mp_unreach.new(:safi=>2, :nlris=> ['192.168.1.0/24','192.168.2.0/24'], :path_id=>100)
    mpr5 =  Mp_unreach.new(:safi=>1, :nlris=> [
      {:prefix=> '192.168.1.0/24', :path_id=> 100},
      {:prefix=> '192.168.2.0/24', :path_id=> 101},
      {:prefix=> '192.168.2.0/24', :path_id=> 102},
    ])
    
    h = {:safi=>1, :nlris=> '192.168.1.0/24', :afi=>1}
    assert_equal(h, mpr1.to_hash[:mp_unreach])
    
    assert_equal({:safi=>1, :nlris=>{:prefix=>"192.168.1.0/24", :path_id=>100}, :afi=>1}, mpr2.to_hash[:mp_unreach])

    assert_equal(mpr1.to_hash, Mp_unreach.new(mpr1.to_hash[:mp_unreach]).to_hash)
    assert_equal(mpr2.to_hash, Mp_unreach.new(mpr2.to_hash[:mp_unreach]).to_hash)
    assert_equal(mpr3.to_hash, Mp_unreach.new(mpr3.to_hash[:mp_unreach]).to_hash)
    assert_equal(mpr4.to_hash, Mp_unreach.new(mpr4.to_hash[:mp_unreach]).to_hash)
    assert_equal(mpr5.to_hash, Mp_unreach.new(mpr5.to_hash[:mp_unreach]).to_hash)
    assert_equal('800f0700010118c0a801', mpr1.to_shex)
    assert_equal('800f0b0001010000006418c0a801', mpr2.to_shex)
    assert_equal attr_len(mpr1)+4, attr_len(mpr2)
    
    assert_equal('800f0b00010218c0a80118c0a802', mpr3.to_shex)
    assert_equal('800f130001020000006418c0a8010000006418c0a802', mpr4.to_shex)
    assert_equal attr_len(mpr3)+8, attr_len(mpr4)
    
    assert_equal('800f1b0001010000006418c0a8010000006518c0a8020000006618c0a802', mpr5.to_shex)

  end

  def test_afi_1_safi_1_ntop
    # Each withdrawn NLRI is one prefix, not a whole Nlri, and with add-path
    # its Path Identifier is read once (RFC 7911 section 3).
    s = '800f0b00010118c0a80118c0a802'
    mpr = Mp_unreach.new([s].pack('H*'))
    assert_equal({:safi=>1, :afi=>1, :nlris=>['192.168.1.0/24', '192.168.2.0/24']}, mpr.to_hash[:mp_unreach])
    s = '800f130001010000006418c0a8010000006518c0a802'
    mpr = Mp_unreach.new([s].pack('H*'), true)
    assert_equal(['ID=100, 192.168.1.0/24', 'ID=101, 192.168.2.0/24'], mpr.nlris.map(&:to_s))
    assert_equal(s, mpr.to_shex)
  end
  
  def test_safi_2_afi_2
    unreach1 = Mp_unreach.new( :safi=>2, :nlris=> [
      {:prefix=> '2007:1::/64'}, 
      {:prefix=> '2007:2::/64'}, 
      {:prefix=> '2007:3::/64'} 
    ]
    )
    assert_equal(3, unreach1.nlris.size)
    assert_equal(2,unreach1.afi)
    assert_equal(2,unreach1.safi)

    unreach2 = Mp_unreach.new( :safi=>2, :nlris=> [
      {:prefix=> '2007:1::/64', :path_id=> 101}, 
      {:prefix=> '2007:2::/64', :path_id=> 102}, 
      {:prefix=> '2007:3::/64', :path_id=> 103} 
    ]
    )
    
    s1 = '80 0f 1e 0002 02          40 2007000100000000          40 2007000200000000          40 2007000300000000'
    s2 = '80 0f 2a 0002 02 00000065 40 2007000100000000 00000066 40 2007000200000000 00000067 40 2007000300000000'
    assert_equal(s1.split.join,unreach1.to_shex)
    assert_equal(s2.split.join,unreach2.to_shex)

    assert_equal(s1.split.join, Mp_unreach.new(unreach1.encode).to_shex)
    assert_equal(s2.split.join, Mp_unreach.new(unreach2.encode,true).to_shex)
  
  end
  
  def test_safi_128
    
    # ffff ffff ffff ffff ffff ffff ffff ffff
    # 0031 0200 0000 1a
    # 90 0f 0016 0001 80 00000001 70 800000 00000001000000010a0101
    # 80 0f 12   0001 80          70 03e801 00000001000000010a0101
    # 80 0f 16   0001 80 00000001 70 03e801 00000001000000010a0101
    
    # Mp Reach (14), length: 9216, Flags [OE]: 
    #   AFI IPv4 (1), SAFI Labeled VPN Unicast (128)
    #   nexthop: 1.1.1.1
    #     ID=1, Label Stack=16000 (bottom) RD=1:1, IPv4=10.1.1.0/24
    #  0x0000:  0180 0c00 0000 0000 0000 0001 0101 0100
    #  0x0001:  0000 0001 7003 e801 0000 0001 0000 0001
    #  0x0002:  0a01 01
    
    unreach1 = Mp_unreach.new( :safi=> 128, :nlris => [{:rd=> Rd.new(1,1), :prefix=> '10.1.1.0/24', :label=>16000},])
    unreach2 = Mp_unreach.new( :safi=> 128, :nlris => [{:rd=> Rd.new(1,1), :prefix=> '10.1.1.0/24', :label=>16000, :path_id=> 1},])
    
    assert_equal(16000,  Label.new(['03e801'].pack('H*')).to_hash[:label])
    assert_equal(524288, Label.new(['800000'].pack('H*')).to_hash[:label])
    
    s1 = '80 0f 12 0001 80 70 03e801 000000010000000 10a0101'.split.join
    s2 = '80 0f 16   0001 80 00000001 70 03e801 00000001000000010a0101'.split.join
    assert_equal(s1, unreach1.to_shex)
    assert_equal(s1, Mp_unreach.new(unreach1.encode).to_shex)
    assert_equal(s2, unreach2.to_shex)
    assert_equal(s2, Mp_unreach.new(unreach2.encode,true).to_shex)
    
  end
  
  # The plumbing, end to end. Mp_unreach is the one place that knows an
  # NLRI is a withdrawal, which is where RFC 8277 section 2.4 says a
  # withdrawn labeled route travels, so it is the one place that can tell
  # a Compatibility field from a label.
  def test_a_labeled_withdrawal_reads_its_prefix
    mp = Mp_unreach.new(:afi => 1, :safi => 4,
                        :nlris => [{ :compatibility => '800000',
                                     :prefix => '10.0.0.0/24' }])
    back = Attr.factory(mp.encode.is_packed)
    assert_equal('Compatibility=0x800000 10.0.0.0/24', back.nlris[0].to_s)
    assert_equal(mp.to_shex, back.to_shex, 'byte for byte')
    assert_equal({ :mp_unreach => { :safi => 4, :afi => 1,
                                    :nlris => { :compatibility => '800000',
                                                :prefix => '10.0.0.0/24' } } },
                 back.to_hash)
  end

  # And MP_REACH must not get the same treatment, because an announcement
  # really does carry a label there. The two attributes are read by the
  # same code and told apart only by this, so a test holds them apart:
  # identical label octets, two readings, and the announcement's is the
  # label.
  def test_the_same_octets_in_mp_reach_are_a_label
    reach = Mp_reach.new(:afi => 1, :safi => 4, :nexthop => ['10.0.0.1'],
                         :nlris => [{ :label => 100, :prefix => '10.0.0.0/24' }])
    back = Attr.factory(reach.encode.is_packed)
    assert_equal('Label Stack=100 (bottom) 10.0.0.0/24', back.nlris[0].to_s)
    assert_equal({ :label => 100 }, back.nlris[0].to_hash.reject { |k, _| k == :prefix })
    assert_nil(back.nlris[0].to_hash[:compatibility],
               'no Compatibility field on an announcement')
  end

  # Flow spec withdrawals, RFC 8955 section 4. The NLRI length is in
  # octets and one or two octets wide, section 4.1, so this loop cannot
  # work it out the way it does for a prefix family: it asks
  # MpReachCommon::ClassMethods#nlri_size, which defers to the family.
  # See docs/flow-spec.md section 3.
  def test_a_flow_spec_withdrawal
    u = BGP::Mp_unreach.new(
      :safi => 133,
      :nlris => [{ :destination_prefix => '192.0.2.0/24',
                   :ip_protocol => [[:eq, 6]], :port => [[:eq, 25]] }])
    # MP_UNREACH has neither a next hop nor the reserved octet, so the
    # AFI and SAFI are followed straight by the section 4.1 framed rule.
    assert_equal('800f0f' + '0001' + '85' + '0b0118c00002038106048119',
                 u.to_shex)
    back = BGP::Attr.factory(u.encode.is_packed)
    assert_equal(u.to_shex, back.to_shex)
    assert_equal(1, back.afi)
    assert_equal(133, back.safi)
    assert_equal([BGP::Flow_spec], back.nlris.collect(&:class))
    assert_equal(3, back.nlris[0].size)
  end

  # RFC 8955 section 8 prepends an 8 octet Route Distinguisher for SAFI
  # 134, and "The NLRI length field shall include both the 8 octets of
  # the Route Distinguisher as well as the subsequent Flow Specification
  # NLRI value."
  def test_a_flow_spec_vpn_withdrawal_carries_its_route_distinguisher
    u = BGP::Mp_unreach.new(
      :safi => 134,
      :nlris => [{ :rd => [100, 200], :destination_prefix => '192.0.2.0/24' }])
    assert_equal('800f11000186' + '0d' + '00000064000000c8' + '0118c00002',
                 u.to_shex)
    back = BGP::Attr.factory(u.encode.is_packed)
    assert_equal(u.to_shex, back.to_shex)
    assert_equal('RD=100:200 (0x64 0x00c8)', back.nlris[0].rd.to_s)
    assert_equal(1, back.nlris[0].size)
  end

  # Two rules in one attribute, which is what the 2-tuple framing of
  # section 4 is for: the loop reads one length field after another.
  def test_two_flow_spec_rules_in_one_attribute
    u = BGP::Mp_unreach.new(
      :safi => 133,
      :nlris => [{ :destination_prefix => '192.0.2.0/24' },
                 { :source_prefix => '203.0.113.0/24', :port => [[:eq, 80]] }])
    back = BGP::Attr.factory(u.encode.is_packed)
    assert_equal(u.to_shex, back.to_shex)
    assert_equal(2, back.nlris.size)
    assert_equal('192.0.2.0/24', back.nlris[0].components[0].prefix.to_s)
    assert_equal('203.0.113.0/24', back.nlris[1].components[0].prefix.to_s)
  end

  private
  
   def attr_len(attr)
     attr.encode[2,1].unpack('C')[0]
   end
end
