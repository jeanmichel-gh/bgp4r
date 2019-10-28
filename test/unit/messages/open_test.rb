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

class Open_Test < Test::Unit::TestCase
  include BGP
  include BGP::OPT_PARM::CAP
  def test_1
    s = "ffffffffffffffffffffffffffffffff001d0104006400c80a00000100"
    sbin = [s].pack('H*')
    assert_equal(Open, Message.factory(sbin).class)
    open =  Message.factory(sbin)
    assert_equal(s, open.to_shex)
    assert_equal(s, Open.new(4,100, 200, '10.0.0.1').to_shex)
    # assert_equal(s, Open.new(4,100, 200, '10.0.0.1', []).to_shex)
    assert_equal('00290104006400c80a0000010c020641040000006402020200', Open.new(4,100, 200, '10.0.0.1', OPT_PARM::CAP::As4.new(100), OPT_PARM::CAP::Route_refresh.new).to_shex[32..-1])
    open1 = Open.new(4,100, 200, '10.0.0.1', OPT_PARM::CAP::As4.new(100), OPT_PARM::CAP::Route_refresh.new)
    open2 = Open.new(open1.encode)
    assert_equal('00290104006400c80a0000010c020641040000006402020200', open2.to_shex[32..-1])
    open = Open.new(4,100, 200, '10.0.0.1')
    open << OPT_PARM::CAP::As4.new(100)
    open << OPT_PARM::CAP::Route_refresh.new
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
    assert_equal(Mbgp, open.opt_parms[1].class)
    assert_equal(Route_refresh, open.opt_parms[2].class)
    assert_equal(Route_refresh, open.opt_parms[3].class)
    assert_equal(As4, open.opt_parms[4].class)
    
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
  def test_3
    s = "
    ffff ffff ffff ffff ffff ffff ffff ffff
    003f 0104 00c8 005a c0a8 7f01 2202 0601
    0400 0100 0102 0280 0002 0202 0002 0840
    0600 7800 0101 8002 0641 0400 0000 c8
    ".split.join
    open = BGP::Message.factory([s].pack('H*'))
    assert_equal s, open.to_shex
  end
  def test_4
    open = Open.new(4,100, 200, '10.0.0.1')
    open << OPT_PARM::CAP::As4.new(100)
    open << OPT_PARM::CAP::Route_refresh.new
    open << OPT_PARM::CAP::Add_path.new(:recv, 1, 1)
    assert open.find(As4)
    assert open.find(Route_refresh)
    assert open.find(Add_path)
  end
  def test_5
    open = Open.new(4,0xffff, 200, '10.0.0.1')
    assert_match(/my AS 65535/, open.to_s)
    open = Open.new(4,0x1ffff, 200, '10.0.0.1')
    assert_match(/my AS 23456/, open.to_s)
  end
end
