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

require 'bgp/extended_community'
require 'test/unit'
class Extended_community_Test < Test::Unit::TestCase
  include BGP
  def test_community
    ec = Extended_community.new
    assert_equal('Extended community: 0:0', ec.to_s)
    assert_equal('0000000000000000',ec.to_shex)
    assert_equal('Extended community: 0:0', ec.to_s)
    assert_raise(ArgumentError) { Extended_community.new(0,2, '192.168.0.1',1) }
  end

  def test_to_i
    assert_equal("000200ff00deadbe",Route_target.new(0xff,0xdeadbe).to_shex)
    assert_equal(0x200ff00deadbe,Route_target.new(0xff,0xdeadbe).to_i)
    assert_equal('030a0a0000010064', Opaque.new(10,"0a0000010064").to_shex)
    assert_equal(0x030a0a0000010064, Opaque.new(10,"0a0000010064").to_i)
  end

  def test_compare
    rt = Route_target.new(0xff,0xdeadbe)
    op = Opaque.new(10,"0a0000010064")
    assert( rt < op )
  end

  def test_opaque
    ec = Opaque.new(10,"0a0000010064")
    ec.instance_of?(Extended_community)
    assert_equal('030a0a0000010064', ec.to_shex)
    assert_equal('Opaque: 0a0000010064', ec.to_s)
  end

  def test_route_target
    assert_raise(ArgumentError) { Route_target.new }
    assert_raise(ArgumentError) { Route_target.new('172.21.0.0') }
    assert_equal("0102010101010064",Route_target.new('1.1.1.1', 100).to_shex)
    assert_equal("Route target: 2.2.2.2:333",Route_target.new('2.2.2.2', 333).to_s)
    assert_equal("Route target: 10:20",Route_target.new(10, 20).to_s)
    assert_equal("000200ff00deadbe",Route_target.new(0xff,0xdeadbe).to_shex)
  end

  def test_route_origin
    assert_raise(ArgumentError) { Route_origin.new }
    assert_raise(ArgumentError) { Route_origin.new('172.21.0.0') }
    assert_equal("0103010101010064",Route_origin.new('1.1.1.1', 100).to_shex)
    assert_equal("Route origin: 2.2.2.2:333",Route_origin.new('2.2.2.2', 333).to_s)
    assert_equal("Route origin: 10:20",Route_origin.new(10, 20).to_s)
    assert_equal("000300ff00deadbe",Route_origin.new(0xff,0xdeadbe).to_shex)
  end

  def test_ospf_domain_id
    did = Ospf_domain_id.new('1.1.1.1')
    assert_equal('Ospf domain id: 1.1.1.1:0', did.to_s)
    assert_equal("0105010203040000",Ospf_domain_id.new('1.2.3.4').to_shex)
    assert_equal("Ospf domain id: 1.2.3.4:0", Ospf_domain_id.new(['0105010203040000'].pack('H*')).to_s)
  end

  def test_ospf_router_id
    did = Ospf_router_id.new('1.1.1.1')
    assert_equal('Ospf router id: 1.1.1.1:0', did.to_s)
    assert_equal("0107010203040000",Ospf_router_id.new('1.2.3.4').to_shex)
    assert_equal("Ospf router id: 1.2.3.4:0", Ospf_router_id.new(['0105010203040000'].pack('H*')).to_s)
  end

  def test_bgp_data_collect
    assert_equal("0008006400000064",Bgp_data_collect.new(100,100).to_shex)
    assert_equal("Bgp data collect: 100:100",Bgp_data_collect.new(100,100).to_s)
    assert_equal("Bgp data collect: 100:100", Bgp_data_collect.new(['0008006400000064'].pack('H*')).to_s)
  end

end
