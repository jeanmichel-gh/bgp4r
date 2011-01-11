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

require 'test/unit'
require 'bgp4r'

class Update_Test < Test::Unit::TestCase
  include BGP
  def test_1
    s = "ffffffffffffffffffffffffffffffff006b0200000054400101024002009004040000000040050400000064c0100800020c8f04127ee8800a0800000001000000048009045134134d800e1f0001800c00000000000000005134134d00680114d100000c8f041291480a39"
    sbin = [s].pack('H*')
    u = Update.new(sbin)
    assert_equal(Update, Message.factory(sbin).class)
    #TODO: more tests with nrli, with withdrawns....
  end
  def test_2
    s = "
    ffff ffff ffff ffff
    ffff ffff ffff ffff 0070 0200 0000 5940
    0101 0240 0200 8004 0400 0000 0040 0504
    0000 0064 c008 0428 2b4e 87c0 1008 0002
    282b 0000 7530 800a 0400 0000 0180 0904
    5134 1180 800e 2100 0180 0c00 0000 0000
    0000 0051 3411 8000 7800 73b1 0000 0c8f
    0013 b42c ac1f 3ffb
    ".split.join
    m = Message.factory([s].pack('H*'))
    assert_equal(Update, m.class)
    assert_equal(s, m.to_shex)
    assert_equal(9, m.path_attribute.size)

    s = 'ffffffffffffffffffffffffffffffff0050020000002f40010101400304c0a80105800404000000644005040000006440020402010064c0080c051f00010137003b0af50040200a0a0a0a2020202020'
    m = Message.factory([s].pack('H*'))
    assert_equal(Update, m.class)
    assert_equal(2,m.nlri.size)
    assert_equal("10.10.10.10/32\n32.32.32.32/32", m.nlri.to_s)
  end
  def test_3
    s = 'ffffffffffffffffffffffffffffffff0050020000002f40010101400304c0a80105800404000000644005040000006440020402010064c0080c051f00010137003b0af50040200a0a0a0a2020202020'
    m = Message.factory([s].pack('H*'))
    w = Update.withdrawn(m)
    assert_equal(Update,w.class)
    assert_equal('000a200a0a0a0a2020202020', w.withdrawn.to_shex)
  end
  def test_4
    an_update = Update.new(
    Path_attribute.new(
    Origin.new(1),
    Next_hop.new('192.168.1.5'),
    Multi_exit_disc.new(100),
    Local_pref.new(100),
    As_path.new(100,200,300),
    Communities.new('1311:1 311:59 2805:64')
    ),
    Nlri.new('77.0.0.0/17', '78.0.0.0/18', '79.0.0.0/19')
    )
    assert_equal(3*2, an_update.encode4.size - an_update.encode.size)
  end
  def test_5
    an_update = Update.new( Path_attribute.new( Origin.new(1),
    Next_hop.new('10.0.0.1'),
    Multi_exit_disc.new(100)
    ))
    assert ! an_update.path_attribute.has?(Local_pref), "Should not contain a Local Pref attr."
    an_update << Local_pref.new(113)
    assert an_update.path_attribute.has?(Local_pref), "Should contain a Local Pref attr."
    assert_nil  an_update.nlri
    an_update << '77.0.0.0/17'
    assert_equal Nlri, an_update.nlri.class
    assert_equal 1, an_update.nlri.size
    an_update << '88.0.0.0/18'
    assert_equal 2, an_update.nlri.size
    an_update << Nlri.new('21.0.0.0/11', '22.0.0.0/22')
    assert_equal 4, an_update.nlri.size
  end

  def test_6
    s = 'ffffffffffffffffffffffffffffffff004a02000000274001010040020a0202000000c80000006440030428000101c0080c0137003b051f00010af50040114d0000124e0000134f0000'
    m = Message.factory([s].pack('H*'), :as4byte=>true)
    assert_not_nil m
    assert_instance_of(Update, m)
    assert m.as4byte
  end

  def test_7
    # build an update from a yaml description
    # advertised 172.18.179.192/27 
    # origin igp
    # nexthop 193.251.127.210
    # metric 0
    # locpref 310000
    # community 3215:102 3215:210 3215:522 3215:588 3215:903 3215:7553 3215:8000 3215:8003
    # originatorid 193.252.102.210
    # cluster 0.0.17.49 0.0.29.76 0.0.29.79
    require 'yaml'
    require 'pp'
    s = "
    ---
    prefixes:202.44.2.0/24 202.44.3.0/24 202.44.5.0/24 202.44.6.0/24 202.44.7.0/24 
    origin: incomplete
    nexthop: 10.0.0.1
    metric: 0
    localpref: 13000
    community: 3230:10 3230:110 3230:411 3230:912 3230:1010 3230:5911 
    originator-id: 10.0.0.2
    cluster: 0.0.0.1
    "
  end

  def test_8
    s = 'FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF0072020000001F4001010040020A0204212C051319351AFE400304557200D9C00804212C045C175D76D6175D76DE1659299C175929981659235C16592D6417592D6417592D6617592D6217C3D228185D73241859284417C3FE84165C727015592190'
    m = Update.new([s].pack('H*'), :as4byte=>true)
    pa = m.path_attribute
    assert_equal '556533011 422910718', pa[As_path].as_path
    assert_equal '85.114.0.217', pa[Next_hop].next_hop
    pa.replace Next_hop.new('10.0.0.1')
    assert_equal '10.0.0.1', pa[Next_hop].next_hop
    pa[:as_path].find_sequence.prepend(100)
    assert_equal '100 556533011 422910718', pa[As_path].as_path
  end

  def test_9
    s = 'FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF002302000C16D403741755C68816D408300000'
    m = Update.new([s].pack('H*'))
    assert m.withdrawn, "Should contain withdrawn routes."
    assert_equal 3,m.withdrawn.nlris.size
  end

  def test_888
    an_update = Update.new( Path_attribute.new( Origin.new(1) ))
    assert_nil  an_update.nlri
    an_update << Path_Nlri.new(100, '21.0.0.0/11', '22.0.0.0/22')
    assert_match(/(ff){16}00#{22+4}\s*02\s*0000\s*0004\s*40010101\s*000000640b150016160000/, an_update.to_shex)
  end
  
  def test_10
    upd1 = Update.new(
      Path_attribute.new(
       Origin.new(1),
       Next_hop.new('192.168.1.5'),
       Multi_exit_disc.new(100),
       Local_pref.new(100),
       As_path.new(100,200,300),
       Communities.new('1311:1 311:59 2805:64')
      ),
      Ext_Nlri.new(100, Nlri.new('77.0.0.0/17', '78.0.0.0/18', '79.0.0.0/19'))
    )
    assert_match(/ff{16}....020000.+00000064114d0000124e0000134f0000/, upd1.to_shex)
    # Need to tell the factory we are dealing with a ext nlri
    upd2 = Update.factory(upd1.encode, :path_id=>true)
    assert_equal(upd1.to_shex, upd2.to_shex)
  end
  
  def test_path_id_and_as4byte
    upd1 = Update.new(
     Path_attribute.new(
      Origin.new,
      As_path.new(100),
      Local_pref.new(10),
      Multi_exit_disc.new(20),
      Mp_reach.new( :safi=>128, :nexthop=> ['10.0.0.1'], :path_id=> 100, :nlris=> [
       {:rd=> [100,100], :prefix=> '192.168.0.0/24', :label=>101},
       {:rd=> [100,100], :prefix=> '192.168.1.0/24', :label=>102},
       {:rd=> [100,100], :prefix=> '192.168.2.0/24', :label=>103},
      ]))
    )
    assert_match(/ff{16}....020000/, upd1.to_shex)
    assert upd1.path_attribute.has_a_mp_reach_attr?, "Expecting a MP_REACH Attr."
    assert_match(/ID=100, Label Stack=102/,upd1.path_attribute[:mp_reach].to_s)
    
    # received as2byte encode aspath attr
    upd2 = Update.factory upd1.encode, :as4byte=> false, :path_id=>true
    # received as4byte encode aspath attr
    upd3 = Update.factory upd1.encode(:as4byte=>true), :as4byte=> true, :path_id=>true
    assert_equal upd1.to_shex, upd2.to_shex
    assert_equal upd2.to_shex, upd3.to_shex
    
  end

end

