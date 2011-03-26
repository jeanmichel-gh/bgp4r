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
  def test_factory_to_create_an_update_message
    s = "ffffffffffffffffffffffffffffffff006b0200000054400101024002009004040000000040050400000064c0100800020c8f04127ee8800a0800000001000000048009045134134d800e1f0001800c00000000000000005134134d00680114d100000c8f041291480a39"
    sbin = [s].pack('H*')
    u = Update.new(sbin)
    assert_equal(Update, Message.factory(sbin).class)
  end
  def test_factory_to_create_an_update_message_with_multiple_nlris
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
  def test_factory_to_create_a_widthdrawn_message
    s = 'ffffffffffffffffffffffffffffffff0050020000002f40010101400304c0a80105800404000000644005040000006440020402010064c0080c051f00010137003b0af50040200a0a0a0a2020202020'
    m = Message.factory([s].pack('H*'))
    w = Update.withdrawn(m)
    assert_equal(Update,w.class)
    assert_equal('200a0a0a0a2020202020', w.withdrawn.to_shex)
  end
  def test_verify_as4_byte_encoding
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
  def test_verify_access_to_update_info
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

  def test_factory_to_build_update_with_session_info
    s = 'ffffffffffffffffffffffffffffffff004a02000000274001010040020a0202000000c80000006440030428000101c0080c0137003b051f00010af50040114d0000124e0000134f0000'
    m = Message.factory([s].pack('H*'), Update::Info.new(true))
    assert_not_nil m
    assert_instance_of(Update, m)
    assert_equal(s, m.to_shex(Update::Info.new(true)))
  end

  def _test_7
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

  def test_verify_one_can_modify_update_info
    o = Update::Info.new(true)
    def o.recv_inet_unicast? ; false ; end
    s = 'FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF0072020000001F4001010040020A0204212C051319351AFE400304557200D9C00804212C045C175D76D6175D76DE1659299C175929981659235C16592D6417592D6417592D6617592D6217C3D228185D73241859284417C3FE84165C727015592190'
    m = Update.new([s].pack('H*'), o)
    pa = m.path_attribute
    assert_equal '556533011 422910718', pa[As_path].as_path
    assert_equal '85.114.0.217', pa[Next_hop].next_hop
    pa.replace Next_hop.new('10.0.0.1')
    assert_equal '10.0.0.1', pa[Next_hop].next_hop
    pa[:as_path].find_sequence.prepend(100)
    assert_equal '100 556533011 422910718', pa[As_path].as_path
  end

  def test_crate_a_withdrawn_update_message
    # FFFFFFFFFF
    # 0023 02 000C 16D40374 1755C688 16D40830 0000
    s = 'FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF002302000C16D403741755C68816D408300000'
    m = Update.new([s].pack('H*'))
    assert m.withdrawn, "Should contain withdrawn routes."
    assert_equal 3,m.withdrawn.nlris.size
  end
 
  def test_factory_to_create_an_update_message_witth_ext_inet_unicast_nlris
    o = Update::Info.new(true)
    def o.recv_inet_unicast? ; true ; end
    def o.send_inet_unicast? ; true ; end
    upd1 = Update.new(
      Path_attribute.new(
       As_path.new(100)
      ),
      Nlri.new([100,'77.0.0.0/17'])
    )
    assert_equal('ffffffffffffffffffffffffffffffff0028020000000940020602010000006400000064114d0000', upd1.to_shex(o))
    # Need to tell the factory we are dealing with a ext nlri.
    upd2 = Update.factory(upd1.encode(o), o)
    assert_equal(upd1.to_shex(o), upd2.to_shex(o))
  end
  
  def test_path_id_and_as4byte
    o = Update::Info.new(true)
    def o.recv_inet_unicast? ; true ; end
    def o.send_inet_unicast? ; true ; end
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
    assert_match(/ID=100, IPv4/,upd1.path_attribute[:mp_reach].to_s)
    
    # received as2byte encode aspath attr
    upd2 = Update.factory upd1.encode, :as4byte=> false, :path_id=>true
    # received as4byte encode aspath attr
    upd3 = Update.factory upd1.encode(o), :as4byte=> true, :path_id=>true
    assert_equal upd1.to_shex, upd2.to_shex
    assert_equal upd2.to_shex, upd3.to_shex
    
  end
  
  # updates with path_id
  
  def ext_update(s)
    sbin = [s.split.join].pack('H*')
    o = Update::Info.new(true)
    def o.path_id?(*args) ; true ; end
    def o.recv_inet_unicast? ; true ; end
    def o.send_inet_unicast? ; true ; end
    Update.factory(sbin,o)
  end
  
  def test_factory_to_build_and_update_for_inet_unicast_with_path_id
    upd = ext_update "
    ffff ffff ffff ffff ffff ffff ffff ffff
    003c 0200 0000 1c40 0101 0040 0200 4003
    040a 0000 0180 0404 0000 0066 4005 0400
    0000 6500 0000 6419 1400 0000"
    assert_equal(BGP::Update, upd.class)
    assert_equal 'ID=100, 20.0.0.0/25', upd.nlri.nlris[0].to_s
    
  end
  
  def test_factory_to_build_and_update_for_inet_mpls_vpn_unicast_with_path_id
    s = "
    ffff ffff ffff ffff ffff ffff ffff ffff
    005f 0200 0000 4840 0101 0140 0200 8004
    0400 0000 0040 0504 0000 0001 c010 0800
    0200 0400 0000 0190 0e00 2400 0180 0c00
    0000 0000 0000 0001 0101 0100 0000 0001
    7003 e801 0000 0013 0000 0011 0a01 01"
    upd = ext_update(s)

    s2 = "
    ffffffffffffffffffffffffffffffff
    005e
    02
    0000
    0047
    40010101
    400200
    80040400000000
    40050400000001
    c010080002000400000001
    800e240001800c00000000000000000101010100000000017003e80100000013000000110a0101
    "
    assert_equal(BGP::Update, upd.class)
    assert upd.path_attribute.has_a_mp_reach_attr?
    assert_equal s2.split.join, upd.to_shex
    assert_equal s2.split.join, ext_update(upd.to_shex).to_shex
    
  end
  
  def test_factory_to_build_a_withdrawn_update_for_inet_mpls_vpn_unicast_with_path_id
    upd = ext_update "
    ffff ffff ffff ffff ffff ffff ffff ffff
    0031 0200 0000 1a90 0f00 1600 0180 0000
    0001 7080 0001 0000 0001 0000 0001 0a01
    01"
    assert upd.has_a_path_attribute?
    assert upd.path_attribute.has_a_mp_unreach_attr?
    mp_unreach = upd.path_attribute[:mp_unreach]
    assert_equal 1, mp_unreach.nlris[0].path_id
    assert_equal 'Label Stack=524288 (bottom) RD=1:1, ID=1, IPv4=10.1.1.0/24', mp_unreach.nlris[0].to_s
  end

end
