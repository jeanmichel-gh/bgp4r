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

class Message_Test < Test::Unit::TestCase
  include BGP
  class MyMessage < Message
    attr_reader :data
    def initialize(s=nil)
      @data= parse(s) if s
    end
    def encode
      @msg_type=0xee
      super('abcdefghihjklmopqrstuvwxyz')
    end
  end
  def test_1
    msg1 = MyMessage.new
    msg2 = MyMessage.new(msg1.encode)
    assert_equal('abcdefghihjklmopqrstuvwxyz',msg2.data)
  end
end

class Keepalive_Test < Test::Unit::TestCase
  include BGP
  def test_1
    Keepalive.new
    assert_equal('ffffffffffffffffffffffffffffffff001304',Keepalive.new.to_shex)
    assert_equal('ffffffffffffffffffffffffffffffff001304',Message.keepalive.unpack('H*')[0])
    assert_equal(Keepalive, Message.factory(Keepalive.new.encode).class)
  end
end

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
    # Ship it!
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
    m = Message.factory([s].pack('H*'), true)
    assert_not_nil m
    assert_instance_of(Update, m)
    assert m.as4byte?
  end

  def test_5
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

end

class Open_Test < Test::Unit::TestCase
  include BGP
  def test_1
    s = "ffffffffffffffffffffffffffffffff001d0104006400c80a00000100"
    sbin = [s].pack('H*')
    assert_equal(Open, Message.factory(sbin).class)
    open =  Message.factory(sbin)
    assert_equal(s, open.to_shex)
    assert_equal(s, Open.new(4,100, 200, '10.0.0.1').to_shex)
    assert_equal(s, Open.new(4,100, 200, '10.0.0.1', []).to_shex)
    assert_equal('00290104006400c80a0000010c020641040000006402020200', Open.new(4,100, 200, '10.0.0.1', As4_cap.new(100), Route_refresh_cap.new).to_shex[32..-1])
    open1 = Open.new(4,100, 200, '10.0.0.1', As4_cap.new(100), Route_refresh_cap.new)
    open2 = Open.new(open1.encode)
    assert_equal('00290104006400c80a0000010c020641040000006402020200', open2.to_shex[32..-1])
    open = Open.new(4,100, 200, '10.0.0.1')
    open << As4_cap.new(100)
    open << Route_refresh_cap.new
    assert_equal('00290104006400c80a0000010c020641040000006402020200', open.to_shex[32..-1])
    s = 'ffffffffffffffffffffffffffffffff002d0104626200b4513411091002060104000100800202800002020200'
    open =  BGP::Message.factory([s].pack('H*'))
    assert_equal(s, open.to_shex)
    
    s = "ffff ffff ffff ffff ffff
    ffff ffff ffff 0038 0104 0023 00b4 1919
    1901 1b02 0601 0400 0100 0102 0280 0002
    0202 0002 0982 0700 0100 0101 8002".split.join
    open =  BGP::Message.factory([s].pack('H*'))
    assert_equal(s, open.to_shex)
    
    s = "ffffffffffffffffffffffffffffffff003d0104006400b402020202200206010400010001020601040001000202028000020202000206410400000064"
    open =  BGP::Message.factory([s].pack('H*'))
    assert_equal(4, open.version)
    assert_equal(100, open.local_as)
    assert_equal('2.2.2.2', open.bgp_id)
    assert_equal(180, open.holdtime)
    assert_equal(5, open.opt_parms.size)
    assert_equal(Mbgp_cap, open.opt_parms[0].class)
    assert_equal(Mbgp_cap, open.opt_parms[1].class)
    assert_equal(Route_refresh_cap, open.opt_parms[2].class)
    assert_equal(Route_refresh_cap, open.opt_parms[3].class)
    assert_equal(As4_cap, open.opt_parms[4].class)
    
  end
  def test_2
    s = "ffffffffffffffffffffffffffffffff003d0104006400b402020202200206010400010001020601040001000202028000020202000206410400000064"
    open =  BGP::Message.factory([s].pack('H*'))
    assert_equal(5, open.to_hash[:capabilities].size )
    assert_equal(1, open.to_hash[:capabilities][0][:code])
    assert_equal({:safi=>1, :afi=>1}, open.to_hash[:capabilities][0][:capability])
    assert_equal(1, open.to_hash[:capabilities][1][:code])
    assert_equal({:safi=>2, :afi=>1}, open.to_hash[:capabilities][1][:capability])
    assert_equal(128, open.to_hash[:capabilities][2][:code])
    assert_nil(open.to_hash[:capabilities][2][:capability])
    assert_equal(2, open.to_hash[:capabilities][3][:code])
    assert_nil(open.to_hash[:capabilities][3][:capability])
    assert_equal(65, open.to_hash[:capabilities][4][:code])
    assert_equal(100,open.to_hash[:capabilities][4 ][:capability][:as])
  end
end

class Route_refresh_Test < Test::Unit::TestCase
  include BGP
  def test_1
    s = "ffffffffffffffffffffffffffffffff00170500010001"
    sbin = [s].pack('H*')
    assert_equal(Route_refresh, Message.factory(sbin).class)
    rr =  Message.factory(sbin)
    assert_equal(s, rr.to_shex)
    rr.afi, rr.safi=2,2
    assert_equal(2, rr.afi)
    assert_equal(2, rr.safi)
    assert_equal('ffffffffffffffffffffffffffffffff00170500020002', rr.to_shex)
    assert_raise(ArgumentError) { rr.safi=0x100 }
    assert_raise(ArgumentError) { rr.afi=-1 }
    assert_equal(s, Route_refresh.new(1,1).to_shex)
    assert_equal(s, Route_refresh.new(:afi=>1, :safi=>1).to_shex)
    assert_equal({:afi=>1, :safi=>1}, Route_refresh.new(:afi=>1, :safi=>1).to_hash)
    assert_equal(s, Message.route_refresh(1,1).unpack('H*')[0])
  end
end


class Orf_route_refresh_Test < Test::Unit::TestCase
  include BGP
  
  def test_1
    rr =  Orf_route_refresh.new
    orf = Prefix_orf.new([
      Prefix_entry.add_and_permit(10,'10.0.0.0/8'),
      Prefix_entry.add_and_permit(20,'20.0.0.0/8'),
      Prefix_entry.add_and_permit(30,'30.0.0.0/8'),
      Prefix_entry.add_and_permit(40,'40.0.0.0/8'),
      Prefix_entry.add_and_permit(50,'50.0.0.0/8'),
    ])
    rr << orf
    rr.afi=1
    rr.safi=1
    assert_equal('0047050001000140002d000000000a0000080a000000001400000814000000001e0000081e000000002800000828000000003200000832',rr.to_shex[32..-1])
    assert_equal('IPv4', rr.afi)
    assert_equal('Unicast', rr.safi)
    assert_equal(1, rr.orfs.size)
    assert_match(/RF Route Refresh \(5\), length: 71\nAFI IPv4 \(1\), SAFI Unicast \(1\)/, rr.to_s)
  end
  
  def test_2   
    s = "ffffffffffffffffffffffffffffffff0047050001000140002d000000000a0000080a000000001400000814000000001e0000081e000000002800000828000000003200000832"
    sbin = [s].pack('H*')
    assert_equal(Orf_route_refresh, Message.factory(sbin).class)
    rr =  Message.factory(sbin)
    assert_equal(s, rr.to_shex)        
  end
end

class Notification_Test < Test::Unit::TestCase
  include BGP
  def test_1
    assert_equal('Undefined', Notification.code_to_s(0))
    assert_equal('Header Error', Notification.code_to_s(1))
    assert_equal('OPEN msg error', Notification.code_to_s(2))
    assert_equal('UPDATE msg error', Notification.code_to_s(3))
    assert_equal('Connection Not Synchronized', Notification.code_to_s(1,1))
    assert_equal('Unrecognized Well-known Attribute', Notification.code_to_s(3,2))
    notif = BGP::Notification.new(1,1)
    assert_equal('ffffffffffffffffffffffffffffffff0015030101', notif.to_shex)
    assert_equal(notif.encode, Notification.new(notif).encode)
    notif = BGP::Notification.new(2,2,'some data')
    assert_equal('ffffffffffffffffffffffffffffffff001e030202736f6d652064617461', notif.to_shex)
    assert_equal(notif.encode, Notification.new(notif).encode)
    s = 'ffffffffffffffffffffffffffffffff001e030202736f6d652064617461'
    m = Message.factory([s].pack('H*'))
    assert_equal(Notification, m.class)
    assert_equal(m.encode, Notification.new(m).encode)
  end
end

class As4_cap_Test < Test::Unit::TestCase
  include BGP
  def test_1
    cap1 = As4_cap.new(100)
    cap2 = As4_cap.new(['0206410400000064'].pack('H*'))
    cap3 = As4_cap.new(cap1.encode)
    assert_equal(cap2.encode, cap3.encode)
  end
end

class Mbgp_cap_Test < Test::Unit::TestCase
  include BGP
  def test_1
    mbgp1 = Mbgp_cap.new(1,1)
    mbgp2 = Mbgp_cap.new(['0206010400010001'].pack('H*'))
    mbgp3 = Mbgp_cap.new(mbgp1.encode)
    assert_equal(mbgp2.encode, mbgp3.encode)
  end
end

class Route_refresh_cap_Test < Test::Unit::TestCase
  include BGP
  def test_1
    assert_equal('02020200',Route_refresh_cap.new.to_shex)
    assert_equal('02028000',Route_refresh_cap.new(128).to_shex)
  end
end

class Orf_cap_Test < Test::Unit::TestCase
  include BGP
  def test_1
    ent1 =  Orf_cap::Entry.new(1,1,[1,1],[2,1],[3,1])
    assert_equal('0001000103010102010301', ent1.to_shex)
    ent2 =  Orf_cap::Entry.new(1,2,[1,1],[2,1],[3,1])
    assert_equal('0001000203010102010301', ent2.to_shex)
    ent3 = Orf_cap::Entry.new(ent1.encode)
    assert_equal(ent1.encode, ent3.encode)
    orf = Orf_cap.new
    orf.add(ent1)
    orf.add(ent2)
    assert_equal('0218031600010001030101020103010001000203010102010301', orf.to_shex)
    orf2 = Orf_cap.new(orf.encode)
    assert_equal(orf.encode, orf2.encode)
  end

end
