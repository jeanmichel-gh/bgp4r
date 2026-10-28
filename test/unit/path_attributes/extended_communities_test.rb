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
    assert_equal("Link bandwidth: 0:1000000000.0",ec.sort.communities[10].to_s)
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
    assert_equal("Link bandwidth: 0:1000000000.0",ec.communities[10].to_s)
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
    assert_equal('Link bandwidth: 0:1000000000.0',ec.link_bandwidth.to_s)
    assert_equal('Route origin: 10.0.3.2:9',ec.route_origin.to_s)
    ec.route_target= '20.0.1.2', 20
    ec.link_bandwidth= 100_000
    assert_equal('Route target: 20.0.1.2:20',ec.route_target[0].to_s)
    assert_equal('Link bandwidth: 0:100000.0',ec.link_bandwidth.to_s)
    # The setter takes the AS too, the same way the route target setter
    # takes an address and a local administrator.
    ec.link_bandwidth= 65_000, 100_000
    assert_equal('Link bandwidth: 65000:100000.0',ec.link_bandwidth.to_s)

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

  # RFC 10005 section 2, on RFC 4360 section 3.1: the 2 octet
  # global administrator is the advertising speaker's AS. It was filled
  # with 0 and dropped when parsing, so an attribute that carried one
  # came back without it, and to_hash gave the bandwidth alone, with
  # nowhere for the AS to go. to_hash now gives [AS, bandwidth].
  def test_link_bandwidth_as_hash_round_trip
    hex = 'c010084004fde8447a0000'   # AS 65000, 1000 bytes per second
    ec = Extended_communities.new([hex].pack('H*'))
    assert_equal(hex, ec.to_shex)
    assert_equal({:extended_communities=>[{:link_bandwidth=>[65000, 1000.0]}]}, ec.to_hash)
    assert_equal(hex, Extended_communities.new_hash(ec.to_hash).to_shex)
    assert_equal(ec.to_hash, Extended_communities.new_hash(ec.to_hash).to_hash)
    assert_equal(hex, Path_attribute.new(Path_attribute.new(ec).to_hash).to_shex)
    # From the community, and from the hash.
    assert_equal(hex, Extended_communities.new(Link_bandwidth.new(65_000, 1000)).to_shex)
    assert_equal(hex, Extended_communities.new_hash(:link_bandwidth=>[65_000, 1000]).to_shex)
    # A bandwidth on its own still means an AS of 0, the form callers and
    # tests already use.
    assert_equal('c0100840040000447a0000',
                 Extended_communities.new_hash(:link_bandwidth=>1000).to_shex)
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
    { 'c01009' + RT + 'ff'           => 9,
      'c01011' + '0002000200000002' + RT + 'ff' => 17,
      'c010020002'                   => 2,
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

  # The hash form used to work through Path_attribute.new, which builds
  # with new_hash, and not through the extended_communities= setter,
  # which calls new: new sent the hash to Extended_community.factory and
  # it raised NoMethodError. new takes every shape new_hash takes now.
  def test_the_hash_form_works_through_every_door
    [ {:route_target=>[1, 2]},
      [{:route_target=>[1, 2]}],
      [{:route_target=>[1, 2]}, {:color=>100}],
      {:route_target=>[1, 2], :color=>100},
      {:extended_communities=>[{:route_target=>[1, 2]}]},
    ].each do |h|
      hex = Extended_communities.new_hash(h).to_shex
      assert_equal(hex, Extended_communities.new(h).to_shex, h.inspect)
      assert_equal(hex, Path_attribute.new(:extended_communities=>h)[:extended_communities].to_shex, h.inspect)
      pa = Path_attribute.new
      pa.extended_communities = h
      assert_equal(hex, pa[:extended_communities].to_shex, h.inspect)
      assert_equal(hex, pa.extended_communities.to_shex, h.inspect)
    end
    assert_equal('c010080002000100000002',
                 Extended_communities.new(:route_target=>[1, 2]).to_shex)
  end

  # The setter takes the hash to_hash returns, tail and all.
  def test_the_setter_takes_the_hash_to_hash_returns
    [Extended_communities.new(Route_target.new(1, 2), Color.new(100)),
     Extended_communities.new(wire('c01009' + RT + 'ff'))].each do |exc|
      pa = Path_attribute.new
      pa.extended_communities = exc.to_hash
      assert_equal(exc.to_shex, pa.extended_communities.to_shex)
      assert_equal(exc.to_hash, pa.extended_communities.to_hash)
    end
  end

  # sort and to_hash used to drop the kept octets, so a malformed
  # attribute came back byte for byte through encode but not through a
  # hash. The tail travels as a {:tail=>hex} entry at the end of the
  # list, which new and new_hash take back.
  def test_sort_and_to_hash_keep_a_tail
    { 'c01009' + RT + 'ff'     => [{:route_target=>[1, 1]}, {:tail=>'ff'}],
      'c0100a' + RT + '0002'   => [{:route_target=>[1, 1]}, {:tail=>'0002'}],
      'c01002ffff'             => [{:tail=>'ffff'}],
    }.each do |hex, list|
      exc = Extended_communities.new(wire(hex))
      assert_equal({:extended_communities=>list}, exc.to_hash, hex)
      assert_equal(hex, exc.sort.to_shex, hex)
      assert_equal(hex, Extended_communities.new(wire(hex)).sort!.to_shex, hex)
      assert_equal(hex, Extended_communities.new(exc.to_hash).to_shex, hex)
      assert_equal(hex, Extended_communities.new_hash(exc.to_hash).to_shex, hex)
      assert_equal(exc.to_hash, Extended_communities.new(exc.to_hash).to_hash, hex)
      assert_equal(hex, Path_attribute.new(Path_attribute.new(wire(hex)).to_hash).to_shex, hex)
    end
    # sort reorders the communities and leaves the tail where it is.
    exc = Extended_communities.new(wire('c01011' + '0002000200000002' + RT + 'ff'))
    assert_equal('c01011' + RT + '0002000200000002' + 'ff', exc.sort.to_shex)
    assert_equal('c01011' + RT + '0002000200000002' + 'ff', exc.sort!.to_shex)
  end

  # The hash of a well formed attribute is the plain list it was.
  def test_a_well_formed_hash_is_unchanged
    exc = Extended_communities.new(Route_target.new(1, 1), Color.new(100))
    assert_nil(exc.tail)
    assert_equal({:extended_communities=>[{:route_target=>[1, 1]}, {:color=>100}]}, exc.to_hash)
    assert_equal({:extended_communities=>[{:route_target=>[1, 1]}, {:color=>100}]}, exc.sort.to_hash)
    assert_equal(exc.encode, Extended_communities.new(exc.to_hash).encode)
  end

  # The :extended_communities key goes through the registered builder,
  # which used to call new_hash and so took only the hash shapes. The
  # key was narrower than the class: Extended_communities.new took a hex
  # string and an array of them, and the key refused both. The builder is
  # the default one now, so the two cannot drift apart again.
  RT_1_1 = '0002000100000001'

  def test_the_hash_key_takes_every_form_new_takes
    [RT_1_1,
     [RT_1_1],
     { :route_target=> [1,1] },
     [{ :route_target=> [1,1] }],
     Route_target.new(1,1),
    ].each do |v|
      pa = Path_attribute.new(:extended_communities=> v)
      assert_equal Extended_communities.new(v).encode, pa[:extended_communities].encode, v.inspect
      assert_equal 'c01008' + RT_1_1, pa[:extended_communities].to_shex, v.inspect
    end
  end

  # The setter and the key are the same builder now, so they agree.
  def test_the_setter_and_the_key_agree
    [RT_1_1, [RT_1_1], { :route_target=> [1,1] }].each do |v|
      pa = Path_attribute.new
      pa.extended_communities = v
      assert_equal 'c01008' + RT_1_1, pa.extended_communities.to_shex, v.inspect
      assert_equal Path_attribute.new(:extended_communities=> v)[:extended_communities].encode,
                   pa.extended_communities.encode, v.inspect
    end
  end

  def test_a_whole_path_attribute_round_trips_from_the_plain_form
    pa = Path_attribute.new(:extended_communities=> [RT_1_1])
    assert_equal pa.encode, Path_attribute.new(pa.to_hash).encode
  end

  # RFC 4360 section 2: the collection slices its own copy of the
  # attribute value 8 octets at a time and hands each whole slice to the
  # factory. Extended_community#parse no longer consumes what it is
  # given, which the collection never needed, so the loop and every
  # community it builds stay byte for byte what they were. One attribute
  # per structure, the FLOAT one of RFC 10005
  # included, plus an attribute whose odd octets are kept as a tail.
  def test_the_collection_loop_still_reads_whole_communities
    [['c010100002000100000001400400004cbebc20',
      [{:route_target=>[1, 1]}, {:link_bandwidth=>[0, 100000000.0]}]],
     ['c01010010201010101006440040064447a0000',
      [{:route_target=>['1.1.1.1', 100]}, {:link_bandwidth=>[100, 1000.0]}]],
     ['c01010030b000000000064030c000000000008',
      [{:color=>100}, {:encapsulation=>:vxlan}]],
     # RFC 8097 section 2: the origin validation state is non-transitive.
     ['c0101043000000000000010008006400000064',
      [{:origin_validation_state=>1}, {:bgp_data_collect=>[100, 100]}]],
     ['c0101001050102030400000107010203040000',
      [{:ospf_domain_id=>'1.2.3.4'}, {:ospf_router_id=>'1.2.3.4'}]],
     # RFC 7606 section 7.14: octets past the last whole community are
     # kept, so encode gives back what arrived.
     ['c0100a0002000100000001ffff',
      [{:route_target=>[1, 1]}, {:tail=>'ffff'}]],
    ].each do |hex, hash|
      # Fresh octets each time: Attr#_parse_ consumes the attribute it
      # reads, which is how a stream of path attributes is parsed.
      wire = ->{ [hex].pack('H*') }
      ec = Extended_communities.new(wire.call)
      assert_equal(hex, ec.to_shex, hex)
      assert_equal({:extended_communities=> hash}, ec.to_hash, hex)
      # The hash round trips, and so does the whole attribute.
      assert_equal(hex, Extended_communities.new(ec.to_hash).to_shex, hex)
      assert_equal(hex, Extended_communities.new(ec).to_shex, hex)
      assert_equal(hex, Path_attribute.new(wire.call)[:extended_communities].to_shex, hex)
    end
    # RFC 5668 section 2: the 4 octet AS specific type octet, 0x02, with
    # the sub-types of RFC 4360 sections 4 and 5, 0x02 and 0x03. The
    # wire form round trips through the loop, and so does the hash now
    # that it carries the type octet: a 4 octet AS specific community
    # whose AS fits in 2 octets used to come back as the 2 octet AS
    # form, so c010080202000000640001 read back as c010080002006400000001.
    ['c010080202000000640001', 'c010080203000000640001',
     'c010080202fa56ea010001', 'c010080203fa56ea010001'].each do |hex|
      ec = Extended_communities.new([hex].pack('H*'))
      assert_equal(hex, ec.to_shex, hex)
      assert_equal(hex, Extended_communities.new(ec.to_hash).to_shex, hex)
      assert_equal(hex, Path_attribute.new([hex].pack('H*'))[:extended_communities].to_shex, hex)
    end
  end

  # RFC 4360 section 2: to_hash returns a hash that round trips through
  # new, and the type octet is one of the eight that has to come back.
  # The two the known issue listed, and the T bit of every other
  # community whose constructor hard codes it.
  def test_a_type_octet_the_values_cannot_reproduce_round_trips_through_the_hash
    ['c010080202000000640001', # RFC 5668 section 2, 4 octet AS specific
     'c010084202000000640001',
     'c010080203000000640001',
     'c010084203000000640001',
     'c010080300000000000001', # RFC 8097 section 2 asks for 0x43
     'c010084002000100000001', # a non-transitive route target
     'c010084102010101010064',
     'c010084003000100000001',
     'c0100800040064447a0000',
     'c010084105010203040000',
     'c010084008006400000064',
     'c01008430b000000000064',
     'c01008430c000000000008',
     'c01008c007000000000003',
     'c010084600000000000005',
     'c010084602aabbccddeeff',
     # Two of them in one attribute, with a kept tail behind them.
     'c010100202000000640001430b000000000064',
     'c010120202000000640001430b000000000064ffff',
    ].each do |hex|
      ec = Extended_communities.new([hex].pack('H*'))
      assert_equal(hex, ec.to_shex, hex)
      assert_equal(hex, Extended_communities.new(ec.to_hash).to_shex, hex)
      assert_equal(hex, Extended_communities.new(ec).to_shex, hex)
      pa = Path_attribute.new([hex].pack('H*'))
      assert_equal(hex, pa[:extended_communities].to_shex, hex)
      assert_equal(hex, Path_attribute.new(pa.to_hash)[:extended_communities].to_shex, hex)
    end
  end

  # One wire form per entry of Extended_community::FACTORY, transitive
  # and non-transitive, with every field of the value set, plus a form
  # the factory does not know, through factory, to_hash, new and encode.
  # RFC 4360 section 2 makes to_hash owe a hash that round trips, so
  # every one of them has to come back byte for byte.
  #
  # Six failed before the OSPF ID fix, the last of this set that did:
  # the 0005 and 4005 domain ID, whose two administrator fields were
  # hashed as one address, and the 0105, 4105, 0107 and 4107 forms whose
  # low 2 octets were set, which the address form dropped.
  #
  # The reserved fields of the RFC 8955, RFC 7432 and RFC 9012 shapes are
  # 0 here, as those RFCs ask. Four of those classes lose them in the
  # hash when they are not; see "Known issues to work on" in CLAUDE.md.
  def test_every_wire_form_the_factory_knows_survives_its_own_hash
    forms = [
      ['0002', '000100000001'], # RFC 4360 section 4, 2 octet AS specific
      ['0102', '010101010064'], # RFC 4360 section 3.2
      ['0202', '000000640001'], # RFC 5668 section 2
      ['0003', '000100000001'], # RFC 4360 section 5
      ['0103', '010101010064'],
      ['0203', '000000640001'],
      ['0004', '0064447a0000'], # RFC 10005 section 2
      ['0005', '000100000001'], # RFC 4577 section 4.2.6
      ['0105', '010203040009'],
      ['0205', '000100020003'],
      ['0107', '010203040009'],
      ['0008', '006400000064'], # RFC 4384
      ['030b', '000000000064'], # RFC 9012 section 4.3
      ['0300', '000000000001'], # RFC 8097 section 2
      ['030c', '000000000008'], # RFC 9012 section 4.1
      ['8006', '000a447a0000'], # RFC 8955 section 7.1
      ['800c', '000a447a0000'], # RFC 8955 section 7.2
      ['8007', '000000000003'], # RFC 8955 section 7.3
      ['8008', '000a00000064'], # RFC 8955 section 7.4
      ['8108', '010101010064'],
      ['8208', '000100020003'],
      ['8009', '000000000020'], # RFC 8955 section 7.5
      ['0600', '000000000005'], # RFC 7432 section 7.7
      ['0601', '000000000640'], # RFC 7432 section 7.5
      ['0602', 'aabbccddeeff'], # RFC 7432 section 7.6
      ['0603', 'aabbccddeeff'], # RFC 9135 section 8.1
      # RFC 4360 sections 2 and 4, RFC 7606 section 7.14: a type the
      # factory does not know keeps its octets as they are.
      ['ffff', '000000000000'],
    ]
    assert_equal(Extended_community::FACTORY.size + 1, forms.size)
    # RFC 4360 section 2: the T bit is the second bit of the type octet,
    # and the factory masks it, so each form has two.
    all = forms.collect { |ts, v|
      t = ts[0,2].to_i(16)
      [format('%02x%s%s', t, ts[2,2], v), format('%02x%s%s', t | 0x40, ts[2,2], v)]
    }.flatten.uniq
    # One short of 54: 0xff already has the bit set.
    assert_equal(53, all.size)
    all.each do |hex|
      ec = Extended_community.factory([hex].pack('H*'))
      assert_equal(hex, ec.to_shex, hex)
      assert_equal(hex, Extended_communities.new(ec.to_hash).communities[0].to_shex, hex)
      # And through the whole attribute, hash and all.
      attr_hex = 'c01008' + hex
      pa = Path_attribute.new([attr_hex].pack('H*'))
      assert_equal(attr_hex, pa[:extended_communities].to_shex, hex)
      assert_equal(attr_hex, Path_attribute.new(pa.to_hash)[:extended_communities].to_shex, hex)
    end
  end

  # The type octet is optional, and a hash written by hand says what it
  # means with it or without it. Without it the community is the one the
  # values have always built.
  def test_the_type_octet_is_optional_in_a_hash_written_by_hand
    assert_equal('c010080002006400000001',
                 Extended_communities.new(:route_target=> [100, 1]).to_shex)
    assert_equal('c010080202000000640001',
                 Extended_communities.new(:route_target=> [100, 1], :type=> 0x02).to_shex)
    assert_equal('c010080202000000640001',
                 Path_attribute.new(:extended_communities=>
                                    { :route_target=> [100, 1], :type=> 0x02 })[:extended_communities].to_shex)
    assert_equal('c010084300000000000001',
                 Extended_communities.new(:origin_validation_state=> 1).to_shex)
    assert_equal('c010080300000000000001',
                 Extended_communities.new(:origin_validation_state=> 1, :type=> 0x03).to_shex)
    # Nothing is checked: an octet no RFC asks for goes on the wire.
    # 0x84 sets the IANA authority bit of RFC 4360 section 2 on a
    # route target, which no registry has.
    assert_equal('c010088402006400000001',
                 Extended_communities.new(:route_target=> [100, 1], :type=> 0x84).to_shex)
  end

end
