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
  
    h = {
      :path_attributes=> {
        :origin=>:incomplete,
        :as_path=>{},
        :med=>0,
        :local_pref=>100,
        :communities=>["10283:20103"],
        :extended_communities=>[{:route_target=>[10283, 30000]}],
        :cluster_list=>["0.0.0.1"],
        :originator_id=>"81.52.17.128",
        :mp_reach=> {
          :safi=>128,
          :afi=>1,
          :nlris=>{:label=>1851, :rd=>[3215, 1291308], :prefix=>"172.31.63.251/32"},
          :nexthop=>["81.52.17.128"]
        }
      }
    }
  
    assert_equal(h[:path_attributes][:originator_id], m.to_hash[:path_attributes][:originator_id])
    assert_equal(h[:path_attributes][:as_path], m.to_hash[:path_attributes][:as_path])
    assert_equal(h[:path_attributes][:multi_exit_disc], m.to_hash[:path_attributes][:multi_exit_disc])
    assert_equal(h[:path_attributes][:local_pref], m.to_hash[:path_attributes][:local_pref])
    assert_equal(h[:path_attributes][:originator_id], m.to_hash[:path_attributes][:originator_id])
    assert_equal(h[:path_attributes][:mp_unreach], m.to_hash[:path_attributes][:mp_unreach])
    assert_equal(h[:path_attributes], m.to_hash[:path_attributes])
    assert_equal(h, m.to_hash)
  
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
    assert_equal({:withdrawns=>["10.10.10.10/32", "32.32.32.32/32"]}, w.to_hash)
    assert_equal(Update,w.class)
    assert_equal('200a0a0a0a2020202020', w.withdrawn.to_shex)
  end
  
  def test_experiment
    upd = Update.new do
      path_attribute << Local_pref.new
      path_attribute << Origin.new
      path_attribute << Next_hop.new('10.1.1.1')
      5.times { |i| nlri << "10.0.#{i}.0/24"}
    end
    h = {
      :path_attributes=>{
        :local_pref=>100, 
        :next_hop=>"10.1.1.1", 
        :origin=>:igp
      }, 
      :nlris=>["10.0.0.0/24", "10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24", "10.0.4.0/24"]
    }
    assert_equal(h, upd.to_hash)
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
    
    h = {
      :path_attributes=> {
        :multi_exit_disc=>100, 
        :local_pref=>113, 
        :next_hop=>"10.0.0.1", 
        :origin=>:egp
      }, 
      :nlris=> ["77.0.0.0/17", "88.0.0.0/18", "21.0.0.0/11", "22.0.0.0/22"]
    }

    upd = Update.new h
    assert_equal(0, an_update.path_attribute <=> upd.path_attribute)
    
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
    assert_equal({:withdrawns=>["212.3.116.0/22", "85.198.136.0/23", "212.8.48.0/22"]}, m.to_hash)
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
    assert_equal({:path_attributes=>{:as_path=>{:sequence=>[100]}}, :nlris=>["ID=100, 77.0.0.0/17"]}, upd1.to_hash)
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
    h = {
      :path_attributes=>{
        :as_path=>{:sequence=>[100]},
        :med=>20,
        :mp_reach=>{
          :nexthop=>["10.0.0.1"],
          :safi=>128,
          :afi=>1,
          :nlris=>[
            {:label=>101,:rd=>[100, 100],:prefix=>"192.168.0.0/24",:path_id=>100},
            {:label=>102,:rd=>[100, 100],:prefix=>"192.168.1.0/24",:path_id=>100},
            {:label=>103,:rd=>[100, 100],:prefix=>"192.168.2.0/24",:path_id=>100}
          ]
        },
        :local_pref=>10,
        :origin=>:igp
      }
    }
    assert_equal(h, upd3.to_hash)
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
    h = {
      :path_attributes=>{
        :as_path=>{}, 
        :med=>0, 
        :mp_reach=>{
          :nexthop=>["1.1.1.1"], 
          :safi=>128, 
          :afi=>1, 
          :nlris=>{:label=>16000, :rd=>[19, 17], :prefix=>"10.1.1.0/24", :path_id=>1}
        }, 
        :local_pref=>1, 
        :origin=>:egp, 
        :extended_communities=>[{:route_target=>[4, 1] }]
      }
    }
    assert_equal(h, upd.to_hash)
    assert_equal(BGP::Route_target, upd.path_attribute.extended_communities.route_target.class)
    assert_equal(BGP::Route_target, upd.path_attribute.extended_communities.route_target.to_s)
    assert_equal(128, upd.path_attribute.mp_reach.safi)
    assert_equal('Label Stack=16000 (bottom) RD=19:17, ID=1, IPv4=10.1.1.0/24', upd.path_attribute.mp_reach.nlris[0].to_s)
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
    h = {
      :path_attributes=>{
        :mp_unreach=>{
          :safi=>128, :afi=>1, 
          :nlris=>{:label=>524288, :rd=>[1, 1], :prefix=>"10.1.1.0/24", :path_id=>1}
        }
      }
    }
    assert_equal(h, upd.to_hash)
    upd2 = Update.new upd.to_hash
    assert_equal(upd2.to_shex, upd.to_shex)
  end
  
  def test_to_hash
    h = {:nlris=>
      ["59.88.128.0/18",
        "59.88.192.0/18",
        "59.89.0.0/18",
        "59.89.192.0/18",
        "59.90.0.0/18",
        "59.90.64.0/18",
        "59.90.128.0/18",
        "59.90.192.0/18",
        "59.91.192.0/18",
        "59.93.128.0/18",
        "59.93.192.0/18",
        "59.94.0.0/18",
        "59.94.64.0/18",
        "59.94.128.0/18",
        "59.94.192.0/18",
        "59.95.0.0/18",
        "59.95.128.0/18",
        "59.96.128.0/18",
        "59.96.192.0/18",
        "59.97.128.0/18",
        "59.97.192.0/18",
        "59.98.192.0/18",
        "59.99.0.0/18",
        "59.99.64.0/18",
        "117.197.0.0/18",
        "117.197.64.0/18",
        "117.197.128.0/18",
        "117.198.128.0/18",
        "117.198.192.0/18",
        "117.199.64.0/18",
        "117.199.128.0/18",
        "117.199.192.0/18",
        "117.200.0.0/18",
        "117.200.64.0/18",
        "117.201.0.0/18",
        "117.201.64.0/18",
        "117.202.192.0/18",
        "117.203.0.0/18",
        "117.203.128.0/18",
        "117.203.192.0/18",
        "117.205.0.0/18",
        "117.205.64.0/18",
        "117.205.192.0/18",
        "117.206.128.0/18",
        "117.206.192.0/18",
        "117.207.0.0/18",
        "117.207.128.0/18",
        "117.209.192.0/18",
        "117.210.0.0/18",
        "117.210.64.0/18",
        "117.210.128.0/18",
        "117.210.192.0/18",
        "117.212.0.0/18",
        "117.212.64.0/18",
        "117.214.0.0/18",
        "117.214.128.0/18",
        "117.214.192.0/18",
        "117.218.0.0/18",
        "117.239.0.0/18",
        "117.239.64.0/18",
        "117.239.128.0/18",
        "117.239.192.0/18",
        "117.241.0.0/18",
        "117.241.64.0/18",
        "117.241.128.0/18",
        "117.241.192.0/18",
        "117.242.0.0/18",
        "117.242.64.0/18",
        "117.242.128.0/18",
        "117.242.192.0/18",
        "210.212.0.0/18",
        "210.212.64.0/18",
        "210.212.128.0/18",
        "210.212.192.0/18",
        "218.248.0.0/18",
        "218.248.128.0/18"],
        :path_attributes=> {
          :communities=>["28289:65500"],
          :origin=>:igp,
          :as_path=>{:sequence=>[28289, 53131, 16735, 3549, 9829, 9829, 9829]},
          :next_hop=>"187.121.193.33"
        }
      }
       u = Update.new h       
       assert_equal(h, u.to_hash)
              
       # s = "ffffffffffffffffffffffffffffffff016c02000000254001010040021002076e81cf8b415f0ddd266526652665400304bb79c121c008046e81ffdc123b5880123b58c0123b5900123b59c0123b5a00123b5a40123b5a80123b5ac0123b5bc0123b5d80123b5dc0123b5e00123b5e40123b5e80123b5ec0123b5f00123b5f80123b6080123b60c0123b6180123b61c0123b62c0123b6300123b63401275c5001275c5401275c5801275c6801275c6c01275c7401275c7801275c7c01275c8001275c8401275c9001275c9401275cac01275cb001275cb801275cbc01275cd001275cd401275cdc01275ce801275cec01275cf001275cf801275d1c01275d2001275d2401275d2801275d2c01275d4001275d4401275d6001275d6801275d6c01275da001275ef001275ef401275ef801275efc01275f1001275f1401275f1801275f1c01275f2001275f2401275f2801275f2c012d2d40012d2d44012d2d48012d2d4c012daf80012daf880" 
       # assert_equal(s, u.to_shex)
  end
  
  

end
