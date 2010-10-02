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
    assert_equal "Option Capabilities Advertisement (2): [0206010400010001]\n    Multiprotocol Extensions (1), length: 4\n      AFI IPv4 (1), SAFI Unicast (1)", mbgp2.to_s
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
