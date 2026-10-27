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

  # An OPEN whose Capabilities parameters hold the given capability TLVs.
  # packed: one parameter with all of them, which RFC 5492 section 4
  # allows and GoBGP does. Otherwise one parameter each, which bgp4r
  # sends.
  def open_with(tlvs, packed: true)
    parms = if packed
      caps = tlvs.join
      '02' + format('%02x', caps.size / 2) + caps
    else
      tlvs.collect { |t| '02' + format('%02x', t.size / 2) + t }.join
    end
    body = '04' + 'fde9' + '00b4' + '0a1e0002' + format('%02x', parms.size / 2) + parms
    Open.new(['ff' * 16 + format('%04x', 19 + body.size / 2) + '01' + body].pack('H*').is_packed)
  end

  ROUTE_REFRESH = '0200'
  AS4_65001     = '4104' + '0000fde9'
  MBGP_IPV4     = '0104' + '00010001'

  # RFC 5492 section 4: one Capabilities optional parameter may carry
  # more than one capability. Reading only the first dropped the rest in
  # silence. Missing 4-octet AS that way left the 2-octet default on, and
  # the AS_PATH that follows is unparseable to a peer expecting 4 octets.
  def test_several_capabilities_in_one_optional_parameter
    open = open_with([ROUTE_REFRESH, AS4_65001, MBGP_IPV4])
    assert_equal 3, open.opt_parms.size
    assert open.find(OPT_PARM::CAP::Route_refresh), 'route refresh'
    assert open.find(OPT_PARM::CAP::As4), 'the 4-octet AS capability must not be lost'
    assert open.find(OPT_PARM::CAP::Mbgp), 'mbgp'
    assert_match(/4-octet AS number: 65001/, open.find(OPT_PARM::CAP::As4).to_s)
  end

  # Order within the parameter must not matter.
  def test_capability_order_in_one_parameter_does_not_matter
    [[AS4_65001, ROUTE_REFRESH], [ROUTE_REFRESH, AS4_65001]].each do |tlvs|
      open = open_with(tlvs)
      assert_equal 2, open.opt_parms.size, tlvs.inspect
      assert open.find(OPT_PARM::CAP::As4), tlvs.inspect
    end
  end

  # One capability per parameter, the shape bgp4r sends, still works.
  def test_one_capability_per_optional_parameter
    open = open_with([ROUTE_REFRESH, AS4_65001, MBGP_IPV4], :packed => false)
    assert_equal 3, open.opt_parms.size
    assert open.find(OPT_PARM::CAP::As4)
  end

  # A single capability in a single parameter is the old path.
  def test_one_capability_in_one_parameter
    open = open_with([AS4_65001])
    assert_equal 1, open.opt_parms.size
    assert_match(/4-octet AS number: 65001/, open.find(OPT_PARM::CAP::As4).to_s)
  end

  # A length that runs past the parameter stops the walk rather than
  # raising, so a peer cannot crash the parse with a short capability.
  def test_a_truncated_capability_does_not_raise
    open = nil
    assert_nothing_raised { open = open_with([ROUTE_REFRESH, '41ff' + '0000']) }
    assert open.find(OPT_PARM::CAP::Route_refresh), 'what came before it is kept'
    assert_nil open.find(OPT_PARM::CAP::As4)
  end
end
