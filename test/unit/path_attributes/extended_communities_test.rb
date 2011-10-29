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

require 'bgp/path_attributes/extended_communities'
require 'test/unit'
class Extended_communitiesTest < Test::Unit::TestCase
  include BGP
  
  def test1
    ec = Extended_communities.new
    ec.add(Route_target.new('10.0.0.1',100))
    assert_equal("c0100801020a0000010064", ec.to_shex)
    ec.add(Route_origin.new('10.0.0.1',200))
    assert_equal("c0101001020a000001006401030a00000100c8", ec.to_shex)
    ec.add(Ospf_domain_id.new('10.0.0.1'))
    assert_match(/Route target: 10.0.0.1:100/m, ec.to_s)
    assert_match(/Route origin: 10.0.0.1:200/m, ec.to_s)
    assert_match(/Ospf domain id: 10.0.0.1:0/m, ec.to_s)
    ec1 = Extended_communities.new(ec)
    assert_equal(ec.encode, ec1.encode)
  end
  def test2
    ec = Extended_communities.new
    (100..140).each { |g| ec.add(Route_target.new(g,100)) }
    assert_equal("d", ec.to_shex.slice(0,1))
  end
  def test_3
    exc = Extended_communities.new(['c010080002282b00007530'].pack('H*'))
    assert_equal(Route_target, exc.communities[0].class)
  end
  def test_sort
    ec = Extended_communities.new
    ec.add(Color.new(100))
    ec.add(Link_bandwidth.new(999_999_999))
    ec.add(Route_target.new('10.0.1.2',10))
    ec.add(Ospf_domain_id.new('9.1.0.1'))
    ec.add(Route_target.new('11.0.1.1',10))
    ec.add(Route_target.new('8.0.1.1',10))
    ec.add(Route_target.new('7.0.1.1',8))
    ec.add(Encapsulation.new(:l2tpv3))
    ec.add(Ospf_domain_id.new('20.0.0.1'))
    ec.add(Route_origin.new('10.0.3.2',9))
    ec.add(Route_target.new('10.0.3.2',7))
    ec.add(Ospf_router_id.new('10.0.0.1'))
    assert_equal("Route target: 7.0.1.1:8",ec.sort.communities[0].to_s) 
    assert_equal("Route target: 8.0.1.1:10",ec.sort.communities[1].to_s)
    assert_equal("Route target: 10.0.1.2:10",ec.sort.communities[2].to_s)
    assert_equal("Route target: 10.0.3.2:7",ec.sort.communities[3].to_s)
    assert_equal("Route target: 11.0.1.1:10",ec.sort.communities[4].to_s)
    assert_equal("Route origin: 10.0.3.2:9",ec.sort.communities[5].to_s)
    assert_equal("Ospf domain id: 9.1.0.1:0",ec.sort.communities[6].to_s)
    assert_equal("Ospf domain id: 20.0.0.1:0",ec.sort.communities[7].to_s)
    assert_equal("Ospf router id: 10.0.0.1:0",ec.sort.communities[8].to_s)
    assert_equal("Encapsulation: 1",ec.sort.communities[9].to_s)
    assert_equal("Link bandwidth: 1000000000.0",ec.sort.communities[10].to_s)
    assert_equal("Color: 100",ec.sort.communities[11].to_s)
  end
  def test_sort!
    ec = Extended_communities.new
    ec.add(Link_bandwidth.new(999_999_999))
    ec.add(Route_target.new('10.0.1.2',10))
    ec.add(Ospf_domain_id.new('9.1.0.1'))
    ec.add(Color.new(100))
    ec.add(Route_target.new('11.0.1.1',10))
    ec.add(Route_target.new('8.0.1.1',10))
    ec.add(Route_target.new('7.0.1.1',8))
    ec.add(Ospf_domain_id.new('20.0.0.1'))
    ec.add(Route_origin.new('10.0.3.2',9))
    ec.add(Route_target.new('10.0.3.2',7))
    ec.add(Ospf_router_id.new('10.0.0.1'))
    ec.sort!
    assert_equal("Route target: 7.0.1.1:8",ec.communities[0].to_s) 
    assert_equal("Route target: 8.0.1.1:10",ec.communities[1].to_s)
    assert_equal("Route target: 10.0.1.2:10",ec.communities[2].to_s)
    assert_equal("Route target: 10.0.3.2:7",ec.communities[3].to_s)
    assert_equal("Route target: 11.0.1.1:10",ec.communities[4].to_s)
    assert_equal("Route origin: 10.0.3.2:9",ec.communities[5].to_s)
    assert_equal("Ospf domain id: 9.1.0.1:0",ec.communities[6].to_s)
    assert_equal("Ospf domain id: 20.0.0.1:0",ec.communities[7].to_s)
    assert_equal("Ospf router id: 10.0.0.1:0",ec.communities[8].to_s)
    assert_equal("Link bandwidth: 1000000000.0",ec.communities[9].to_s)
    assert_equal("Color: 100",ec.communities[10].to_s)
    ec1 = Extended_communities.new(ec)
    assert_equal(ec.encode, ec1.encode)
  end
  
  def test_compare_eql?
    ec = Extended_communities.new
    ec.add(Route_target.new('10.0.1.2',100))
    ec.add(Ospf_domain_id.new('10.0.0.1'))
    ec.add(Route_target.new('10.0.1.1',100))
    ec.add(Ospf_domain_id.new('10.0.0.1'))
    ec.add(Route_origin.new('10.0.1.1',99))
    ec.add(Route_target.new('10.0.1.1',99))
    ec.add(Ospf_router_id.new('10.0.0.1'))
    ec2 =  ec.sort
    assert_equal(0, ec <=> ec2)
    assert(! ec.eql?(ec2))
  end
    
end

#MiniTest::Unit.autorun
