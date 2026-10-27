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

require 'bgp/path_attributes/extended_communities'
require 'bgp/path_attributes/path_attribute'
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
  def test_4
    ec = Extended_communities.new_hash  :color=> 100
    ec2 = Extended_communities.new_hash(ec.to_hash)
    assert_equal(ec.to_shex, ec2.to_shex)
    assert_equal(ec.to_hash, Extended_communities.new_hash(ec.to_hash).to_hash)
    ec = Extended_communities.new_hash  :link_bandwidth=> 999_999_999
    ec2 = Extended_communities.new_hash(ec.to_hash)
    assert_equal(ec.to_hash, Extended_communities.new_hash(ec.to_hash).to_hash)
    ec = Extended_communities.new_hash  :route_target=> ['10.0.1.2', 10]
    ec2 = Extended_communities.new_hash(ec.to_hash)
    assert_equal(ec.to_hash, Extended_communities.new_hash(ec.to_hash).to_hash)
    ec = Extended_communities.new_hash  :ospf_domain_id=> '9.1.0.1'
    ec2 = Extended_communities.new_hash(ec.to_hash)
    assert_equal(ec.to_hash, Extended_communities.new_hash(ec.to_hash).to_hash)
    assert_equal(ec.to_hash, Extended_communities.new_hash(ec.to_hash).to_hash)
    ec = Extended_communities.new_hash  :route_origin=> ['10.0.1.2', 10]
    ec2 = Extended_communities.new_hash(ec.to_hash)
    ec = Extended_communities.new_hash :extended_communities=>[{:route_target=>[13111, 26054]}]
    assert_equal({:extended_communities=>[{:route_target=>[13111, 26054]}]}, ec.to_hash)
    assert_equal(ec.to_hash, Extended_communities.new_hash(ec.to_hash).to_hash)
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
    # ec.add(Encapsulation.new(:l2tpv3))
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
    assert_equal("Color: 100",ec.sort.communities[9].to_s)
    # assert_equal("Encapsulation: 1",ec.sort.communities[10].to_s)
    assert_equal("Link bandwidth: 1000000000.0",ec.sort.communities[10].to_s)
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
    assert_equal("Link bandwidth: 1000000000.0",ec.communities[10].to_s)
    assert_equal("Color: 100",ec.communities[9].to_s)
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
  def test_getters_setters
    ec = Extended_communities.new do |c|    
      c.add(Color.new(100))
      c.add(Link_bandwidth.new(999_999_999))
      c.add(Route_target.new('10.0.1.2',10))
      c.add(Ospf_domain_id.new('9.1.0.1'))
      c.add(Route_target.new('11.0.1.1',11))
      c.add(Route_target.new('8.0.1.1',10))
      c.add(Route_target.new('7.0.1.1',8))
      ### c.add(Encapsulation.new(:l2tpv3))
      c.add(Ospf_domain_id.new('20.0.0.1'))
      c.add(Route_origin.new('10.0.3.2',9))
      c.add(Route_target.new('10.0.3.2',12))
      c.add(Ospf_router_id.new('10.0.0.1'))
    end
    assert_equal('Color: 100',ec.color.to_s)
    assert_equal('Route target: 10.0.1.2:10',ec.route_target[0].to_s)
    assert_equal('Ospf domain id: 9.1.0.1:0',ec.ospf_domain_id[0].to_s)
    ###assert_equal('Encapsulation: 1',ec.encapsulation.to_s)
    assert_equal('Ospf router id: 10.0.0.1:0',ec.ospf_router_id.to_s)
    assert_equal('Link bandwidth: 1000000000.0',ec.link_bandwidth.to_s)
    assert_equal('Route origin: 10.0.3.2:9',ec.route_origin.to_s)
    ec.route_target= '20.0.1.2', 20
    ec.link_bandwidth= 100_000
    assert_equal('Route target: 20.0.1.2:20',ec.route_target[0].to_s)
    assert_equal('Link bandwidth: 100000.0',ec.link_bandwidth.to_s)

    ec = Extended_communities.new do |c|
      c.route_target   = '10.0.0.1', 1311
      c.link_bandwidth = 100_000_000
      c.ospf_router_id = '1.1.1.1'
      c.ospf_domain_id = '2.2.2.2'
      ###c.encapsulation  = 1
      c.route_origin   = '3.3.3.3', 33
      c.color          = 1311
    end
    
  end
    
  # RFC 4360 sections 2 and 4, RFC 7606 section 7.14: unknown communities
  # must not abort parsing and must be kept.
  def test_unknown_encapsulation
    exc = Extended_communities.new(['c010080306000000000000'].pack('H*'))
    assert_equal(Extended_community::Unknown, exc.communities[0].class)
    assert_equal('c010080306000000000000', exc.to_shex)
  end

  def test_mixed_known_and_unknown
    hex = 'c01038' +
          '0002fde800000064' + # route target 65000:100
          '030c000000000007' + # encapsulation, RFC 9012
          '8006000000000000' + # flowspec traffic rate, RFC 8955
          '0202fa56ea000001' + # route target 4200000000:1, RFC 5668
          '0600000000000064' + # EVPN MAC mobility, RFC 7432
          '0203000100020003' + # route origin 65538:3, RFC 5668
          '8077000000000000'   # unassigned, kept as is
    exc = Extended_communities.new([hex].pack('H*'))
    assert_equal([Route_target, Encapsulation, Traffic_rate_bytes,
                  Route_target, Mac_mobility, Route_origin, Extended_community::Unknown],
                 exc.communities.collect { |c| c.class })
    assert_equal(hex, exc.to_shex)
    assert_match(/Route target: 65000:100/, exc.to_s)
    assert_match(/Route target: 4200000000:1/, exc.to_s)
    assert_match(/Route origin: 65538:3/, exc.to_s)
    assert_match(/type 0x80, subtype 0x77, 8077000000000000/, exc.to_s)
    assert_match(/Encapsulation: 7/, exc.to_s)
    assert_match(/MAC Mobility: sequence 100/, exc.to_s)
    assert_equal(hex, Extended_communities.new(exc).to_shex)
    assert_equal(hex, Extended_communities.new_hash(exc.to_hash).to_shex)
    assert_equal(exc.to_hash, Extended_communities.new_hash(exc.to_hash).to_hash)
    pa = Path_attribute.new(exc)
    assert_equal(hex, Path_attribute.new(pa.to_hash).to_shex)
  end

  def test_four_octet_as_hash_round_trip
    ec = Extended_communities.new_hash :route_target=>[4200000000, 1]
    assert_equal('c010080202fa56ea000001', ec.to_shex)
    assert_equal(ec.to_shex, Extended_communities.new_hash(ec.to_hash).to_shex)
  end


  # Every community round trips through to_hash and new_hash. The old
  # case list had no Origin_validation_state or Bgp_data_collect, and its
  # :encapsulation branch named a class that did not exist.
  def test_hash_round_trip_for_every_sub_type
    cs = [Route_target.new(65000, 1), Route_origin.new('10.0.0.1', 2), Color.new(100),
          Link_bandwidth.new(1000), Ospf_domain_id.new('1.1.1.1'), Ospf_router_id.new('2.2.2.2'),
          Bgp_data_collect.new(1, 2), Origin_validation_state.new(:invalid),
          Encapsulation.new(:vxlan), Traffic_rate_bytes.new(0, 1000), Traffic_rate_packets.new(1, 2),
          Traffic_action.new(sample: true), Redirect.new(65001, 100), Traffic_marking.new(46),
          Mac_mobility.new(5, sticky: true), Esi_label.new(1000), Es_import.new('00:11:22:33:44:55'),
          Router_mac.new('aa:bb:cc:dd:ee:ff'), Extended_community::Unknown.new('8077000000000000')]
    exc = Extended_communities.new(*cs)
    h = exc.to_hash
    assert_equal(exc.encode, Extended_communities.new_hash(*h[:extended_communities]).encode)
    assert_equal(Path_attribute.new(exc).encode, Path_attribute.new(h).encode)
    assert_equal(exc.encode, Extended_communities.new(exc.encode).encode)
  end

  def test_new_hash_rejects_an_unknown_key
    assert_raise(ArgumentError) { Extended_communities.new_hash(:carrier_pigeon => 1) }
  end

  def test_encapsulation_accessor
    exc = Extended_communities.new(Route_target.new(1, 1), Encapsulation.new(:vxlan))
    assert_equal(:vxlan, exc.encapsulation.tunnel_name)
  end

  def wire(hex) [hex].pack('H*').is_packed end
  def findings(hex)
    Path_attribute.new(wire(hex)).errors.collect { |f| [f.type, f.subcode, f.action, f.reason] }
  end

  RT = '0002000100000001' # route target 1:1, RFC 4360 section 3.1

  # RFC 4360 section 2: an extended community is 8 octets. A shorter
  # slice is kept as a tail, so encode gives back what was received.
  # Before this, the slice went to Extended_community.factory, and a
  # known type and subtype pair gave a community with nil fields whose
  # encode raised.
  def test_a_tail_is_kept
    { 'c010020002'             => 0, # known pair, two octet AS route target
      'c010020102'             => 0, # known pair, ipv4 address route target
      'c01002ffff'             => 0, # unknown pair
      'c0100100'               => 0, # one octet
      'c0100a' + RT + '0002'   => 1, # known pair after a whole community
      'c0100a' + RT + 'ffff'   => 1, # unknown pair after a whole community
      'c0100e' + RT + '000200010000' => 1,
      'c01009' + RT + '00'     => 1,
    }.each do |hex, n|
      exc = Extended_communities.new(wire(hex))
      assert_equal(hex, exc.to_shex, hex)
      assert_equal(n, exc.communities.size, hex)
      assert_equal(hex, Extended_communities.new(exc).to_shex, hex)
      assert_equal(hex, Path_attribute.new(wire(hex)).to_shex, hex)
    end
  end

  # RFC 7606 section 7.14: a length that is not a non-zero multiple of 8
  # is malformed, treat-as-withdraw. Keeping the octets does not change
  # what Path_attribute#errors reports.
  def test_findings_are_unchanged
    { 'c010020002'                   => 2,
      'c01002ffff'                   => 2,
      'c0100100'                     => 1,
      'c0100a' + RT + '0002'         => 10,
      'c0100a' + RT + 'ffff'         => 10,
      'c0100e' + RT + '000200010000' => 14,
    }.each do |hex, len|
      assert_equal([[16, 5, :treat_as_withdraw,
                     "length #{len}, must be a non-zero multiple of 8 (RFC 7606 section 7.14)"]],
                   findings(hex), hex)
    end
  end

  # A well formed attribute is unaffected.
  def test_a_well_formed_attribute_is_unaffected
    hex = 'c01008' + RT
    exc = Extended_communities.new(wire(hex))
    assert_equal(hex, exc.to_shex)
    assert_equal([Route_target], exc.communities.collect { |c| c.class })
    assert_equal([], findings(hex))
  end

end
