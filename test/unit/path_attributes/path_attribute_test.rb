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

require 'test/unit'
require 'stringio'
require 'bgp/path_attributes/path_attribute'
require 'bgp/path_attributes/attributes'

class Path_attribute_Test < Test::Unit::TestCase # :nodoc:
  include BGP

  def setup
    pa = Path_attribute.new
    pa << Origin.new(1)
    pa << Next_hop.new('10.0.0.1')
    pa << Multi_exit_disc.new(100)
    pa << Local_pref.new(100)
    pa << As_path.new(1,2,3,4,5)
    pa << Communities.new('1311:1 311:59 2805:64')
    @pa = pa
  end

  def test_1
    assert_equal(100,@pa[:local_pref].to_i)
    assert_equal([BGP::Origin,
      BGP::Next_hop,
      BGP::Multi_exit_disc,
      BGP::Local_pref,
      BGP::As_path,
      BGP::Communities], @pa.has?)
    assert(@pa.has? Multi_exit_disc)
    assert(@pa.has? As_path)
    pa = Path_attribute.new { |p|  
      p << Origin.new(1)
      p << Next_hop.new('1.1.1.1')
      p << Multi_exit_disc.new(222)
      p << Local_pref.new(333)
      p << As_path.new( :set=> [1,2,3,4], :sequence=> [11,12,13])
    }
    assert_equal([BGP::Origin,BGP::Next_hop,BGP::Multi_exit_disc,BGP::Local_pref,BGP::As_path], pa.has?)
  end
  
  def test_2
    ss = '400101014003040a000001800404000000644005040000006440020c020500010002000300040005c0080c051f00010137003b0af50040'
    assert_equal(ss, @pa.to_shex)
    s = @pa.encode
    assert_equal(Origin, Attr.factory(s).class)
    assert_equal(Next_hop, Attr.factory(s).class)
    assert_equal(Multi_exit_disc, Attr.factory(s).class)
    assert_equal(Local_pref, Attr.factory(s).class)
    assert_equal(As_path, Attr.factory(s).class)
    assert_equal(Communities, Attr.factory(s).class)
    assert_equal('',s)
  end
  
  def test_3
    # test []
    assert_equal(Origin,@pa[ATTR::ORIGIN].class)
    assert_equal(Origin,@pa[:origin].class)
    assert_equal(As_path,@pa[ATTR::AS_PATH].class)
    assert_equal(As_path,@pa[:as_path].class)
    assert_equal(Next_hop,@pa[ATTR::NEXT_HOP].class)
    assert_equal(Next_hop,@pa[:next_hop].class)
    assert_equal(Local_pref,@pa[ATTR::LOCAL_PREF].class)
    assert_equal(Local_pref,@pa[:local_pref].class)
    assert_equal(Multi_exit_disc,@pa[ATTR::MULTI_EXIT_DISC].class)
    assert_equal(Multi_exit_disc,@pa[:multi_exit_disc].class)
    assert_equal(Communities,@pa[ATTR::COMMUNITIES].class)
    assert_equal(Communities,@pa[:communities].class)

    # TODO:
    #   when  ATOMIC_AGGREGATE, :atomic_aggregate
    #   when  AGGREGATOR, :aggregator
    #   when ORIGINATOR_ID, :originator_id
    #   when CLUSTER_LIST, :cluster_list
    #   when MP_REACH, :mp_reach
    #   when MP_UNREACH, :mp_unreach
    #   when EXTENDED_COMMUNITY, :extended_community
    #   when AS4_PATH, :as4_path
    #   when AS4_AGGREGATOR, :as4_aggregator

  end
  
  def test_4
    
    path_attr = Path_attribute.new
    path_attr.insert(
      Origin.new,
      As_path.new,
      Local_pref.new(10),
      Multi_exit_disc.new(20)
    )
    
    path_attr.replace(
      As_path.new(100,200),
      Local_pref.new(11),
      Origin.new(2),
      Multi_exit_disc.new(21)
    )
    
    assert_equal(4,path_attr.size)
    assert_equal(11, path_attr[:local_pref].to_i)
    assert_equal('100 200', path_attr[:as_path].as_path)
    assert_equal(21, path_attr[ATTR::MULTI_EXIT_DISC].to_i)
    
    path_attr.delete Local_pref, Next_hop, Origin
    assert_equal(2, path_attr.size)
    assert( ! path_attr.has?(Local_pref),"Local_pref attr not deleted")
    assert( ! path_attr.has?(Origin),"Origin attr not deleted")
    
    path_attr.insert(Origin.new(1), Local_pref.new(100))
    assert_equal(4, path_attr.size)
    assert(  path_attr.has?(As_path),"Local_pref attr not deleted")
    assert(  path_attr.has?(Origin),"Origin attr not deleted")
    
  end
  
  def test_5
    s =   '4001010040020a0202000000c80000006440030428000101c0080c0137003b051f00010af50040'
    sbin = [s].pack('H*')
    assert_instance_of(Origin, attr = Attr.factory(sbin))
    assert_instance_of(As_path, attr = Attr.factory(sbin,true))
    assert_equal '200 100', attr.as_path
    assert_instance_of(Next_hop, Attr.factory(sbin,true))
    assert_instance_of(Communities, Attr.factory(sbin,true))
    assert_equal 0, sbin.size
  end
  
  def test_6
    assert @pa.has_a_origin_attr?
    assert @pa.has_a_next_hop_attr?
    assert @pa.has_a_local_pref_attr?
    assert ! @pa.has_a_aggregator_attr?
    assert ! @pa.has_a_mp_unreach_attr?
  end

  def test_7
    s =   '800e1000010404ffffffff0030000651c0a800'
    sbin = [s].pack('H*')
    assert_equal(BGP::Mp_reach, Attr.factory(sbin, :path_id=>false).class)
    s = '800e1400010404ffffffff000000006430000651c0a800'
    sbin = [s].pack('H*')
    assert_equal(BGP::Mp_reach, Attr.factory(sbin, :path_id=>true).class)
  end
  
  def test_8
    
    mp_reach = {:safi=>128, :nexthop=> ['10.0.0.1'], :path_id=> 100, :nlris=> [
      {:rd=> [100,100], :prefix=> '192.168.0.0/24', :label=>101},
      {:rd=> [100,100], :prefix=> '192.168.1.0/24', :label=>102},
      {:rd=> [100,100], :prefix=> '192.168.2.0/24', :label=>103},
    ]}
    
    mp_unreach = {:safi=>2, :nlris=>['192.168.1.0/24', '192.168.2.0/24']}
    
    p = Path_attribute.new  :local_pref=>100, 
                            :next_hop => '10.0.0.1', 
                            :med=>300, 
                            :mp_reach=> mp_reach, 
                            :mp_unreach=> mp_unreach, 
                            :origin=> :igp, 
                            :as_path=> {:set=> [1,2], :sequence=>[3,4], :confed_sequence=>[5,6], :confed_set=>[7,8]},
                            :cluster_list=> ['1.1.1.1', '2.2.2.2', '3.3.3.3'],
                            :communities=> ["145:30", "145:40", "145:50", "145:60", :no_export, :no_advertise,],
                            :extended_communities=> [ :color => 100, :link_bandwidth => 999_999_999, :route_origin => ['10.0.1.2', 10], ],
                            :aggregator=> { :address=>'1.1.1.1', :asn=>100 },
                            :originator_id=> '2.2.2.2',
                            :as4_aggregator=> { :asn=> 200, :address=> '4.4.4.4' },
                            :as4_path=> {:set=> [11,12], :sequence=>[13,14], :confed_sequence=>[15,16], :confed_set=>[17,18]},
                            :atomic_aggregate=> 1
  
    assert p.has?(Origin), "Path attributes should have a Origin attr."
    assert p.has?(Local_pref), "Path attributes should have a Local_pref attr."
    assert p.has?(Next_hop), "Path attributes should have a Next_hop  attr."
    assert p.has?(Multi_exit_disc), "Path attributes should have a Multi_exit_disc attr."
    assert p.has?(As_path), "Path attributes should have a As_path attr."
    assert p.has?(As4_path), "Path attributes should have a As4_path attr."
    assert p.has?(As4_aggregator), "Path attributes should have a As4_aggregator attr."
    assert p.has?(Mp_reach), "Path attributes should have a Mp_reach attr."
    assert p.has?(Mp_unreach), "Path attributes should have a Mp_unreach attr."
    assert p.has?(Communities), "Path attributes should have a Communities attr."
    assert p.has?(Extended_communities), "Path attributes should have a Extended_communities attr."
    assert p.has?(Atomic_aggregate), "Path attributes should have a Atomic_aggregate attr."
    assert p.has?(Originator_id), "Path attributes should have a Originator_id attr."
    assert p.has?(Cluster_list), "Path attributes should have a Cluster_list attr."
    
  end
  
  # The same five attributes added in two different orders: the lists
  # encode differently, sort to the same bytes, and compare equal.
  #
  # The two AS_PATHs must stay identical, segment order included. They
  # used to differ, 11 12 13 against 11 12 14 and set before sequence,
  # and the test passed only because As_path.new ignored a bare segment
  # hash and built an empty path from both. Once it honoured the hash
  # the assertion below was false, because the paths really were
  # different. Attribute order is what this test is about, so the fix is
  # to make the paths equal, not to compare different ones.
  def test_9
    pa1 = Path_attribute.new { |p|
      p << Multi_exit_disc.new(222)
      p << Next_hop.new('1.1.1.1')
      p << Local_pref.new(333)
      p << As_path.new( :set=> [1,2,3,4], :sequence=> [11,12,13])
      p << Origin.new(1)
    }
    pa2 = Path_attribute.new { |p|
      p << Next_hop.new('1.1.1.1')
      p << Origin.new(1)
      p << Local_pref.new(333)
      p << As_path.new( :set=> [1,2,3,4], :sequence=> [11,12,13])
      p << Multi_exit_disc.new(222)
    }
    assert_not_equal(pa1.to_shex,pa2.to_shex)
    assert_equal(pa1.sort.to_shex, pa2.sort.to_shex)
    assert_equal(0, pa1 <=> pa2)
    pa1.add(Communities.new("1:1"))
    assert_equal(1, pa1 <=> pa2)
    pa2.insert(Communities.new("1:1"))
    assert_equal(0, pa1 <=> pa2)
  end
    
  
  def test_path_attribute_path_id_true_and_as4byte_false
    path_attr = Path_attribute.new
    path_attr.insert(
    Origin.new,
    As_path.new(100),
    Mp_reach.new( :safi=>128, :nexthop=> ['10.0.0.1'], :path_id=> 100, :nlris=> [
      {:rd=> [100,100], :prefix=> '192.168.0.0/24', :label=>101},
      {:rd=> [100,100], :prefix=> '192.168.1.0/24', :label=>102},
      {:rd=> [100,100], :prefix=> '192.168.2.0/24', :label=>103},
    ])
    )
    assert_match(/ID=100, IPv4=192.168.0.0/, path_attr.to_s)
    path_attr_new = Path_attribute.new(path_attr.encode(true), :as4byte=> true, :path_id=>true)
    assert_equal(path_attr.to_shex, path_attr_new.to_shex)
    
    # TODO: UT: a path attr with mp_reach w path_id and ! as4
    # TODO: UT: a path attr with mp_unreach w path_id
    # TODO: UT: a path attr with mp_reach w path_id and as4
    
  end
  
  def test_hash
    
    h = {
      :aigp=> 0x1f2f3f4f5f6f7f8f,
      :aggregator=>{:asn=>100, :address=>"10.0.0.1"},
      :cluster_list=>["1.0.1.1"], 
      :as_path=>{}, 
      :communities=>["1133:2015"], 
      :local_pref=>113, 
      :origin=>:incomplete,
      :med=>10, 
      :extended_communities=>[{:route_target=>[13111, 26054]}], 
      :originator_id=>"196.168.28.123", 
      :mp_reach=>{
        :nexthop=>["10.0.0.2"], :afi=>1, :safi=>128, 
        :nlris=>[
          {:label=>2226, :prefix=>"172.23.21.113/32", :rd=>[1311, 4567814]}, 
          {:label=>2151, :prefix=>"10.48.9.175/32",   :rd=>[1311, 32117824]}, 
          {:label=>3382, :prefix=>"172.33.169.92/32", :rd=>[1311, 80037224]}, 
          {:label=>1452, :prefix=>"10.46.52.31/32",   :rd=>[1311, 3117824]}, 
          {:label=>3785, :prefix=>"172.41.96.104/32", :rd=>[1311, 45657424]}, 
          {:label=>5228, :prefix=>"10.46.53.69/32",   :rd=>[1311, 59407624]}, 
          {:label=>5141, :prefix=>"172.21.55.36/32",  :rd=>[1311, 321617824]}, 
          {:label=>3724, :prefix=>"10.99.25.81/32",   :rd=>[1311, 311197824]}, 
          {:label=>2281, :prefix=>"10.35.9.169/32",   :rd=>[1311, 321147824]}, 
          {:label=>4615, :prefix=>"10.65.128.200/32", :rd=>[1311, 6627884]}, 
          {:label=>3404, :prefix=>"172.29.96.8/32",   :rd=>[1311, 45657824]}, 
          {:label=>3767, :prefix=>"10.32.19.165/32",  :rd=>[1311, 44657824]}, 
          {:label=>3451, :prefix=>"10.14.186.28/32",  :rd=>[1311, 45657824]}, 
          {:label=>3027, :prefix=>"10.95.176.91/32",  :rd=>[1311, 371197824]}, 
          {:label=>5034, :prefix=>"10.24.176.99/32",  :rd=>[1311, 321197824]}, 
          {:label=>3565, :prefix=>"10.72.83.239/32",  :rd=>[1311, 311197824]}, 
          {:label=>3551, :prefix=>"10.45.142.161/32", :rd=>[1311, 321157824]}, 
          {:label=>5238, :prefix=>"10.32.83.219/32",  :rd=>[1311, 351177824]}, 
          {:label=>5223, :prefix=>"10.13.142.117/32", :rd=>[1311, 321197824]}, 
          {:label=>3360, :prefix=>"172.50.34.141/32", :rd=>[1311, 348987824]},  
          {:label=>3579, :prefix=>"10.26.42.36/32",   :rd=>[1311, 325697824]}, 
          {:label=>4118, :prefix=>"10.76.42.34/32",   :rd=>[1311, 347517824]}, 
          {:label=>3971, :prefix=>"172.21.192.24/32", :rd=>[1311, 86627824]},
          {:label=>4223, :prefix=>"10.12.209.131/32", :rd=>[1311, 42655824]}, 
          {:label=>2241, :prefix=>"10.34.186.201/32", :rd=>[1311, 42656824]},
        ], 
      }
    }
    assert_equal(h[:local_pref], Path_attribute.new(h).to_hash[:local_pref])
    assert_equal(h[:as_path], Path_attribute.new(h).to_hash[:as_path])
    assert_equal(h[:extended_communities], Path_attribute.new(h).to_hash[:extended_communities])
    assert_equal(h[:communities], Path_attribute.new(h).to_hash[:communities])
    assert_equal(h[:cluster_list], Path_attribute.new(h).to_hash[:cluster_list])
    assert_equal(h[:aggregator], Path_attribute.new(h).to_hash[:aggregator])
    assert_equal(h[:mp_reach], Path_attribute.new(h).to_hash[:mp_reach])
    assert_equal(h, Path_attribute.new(h).to_hash)
  end
  
  def test_setters
    h = {
      :aigp=> 0x1f2f3f4f5f6f7f8f,
      :nexthop=> '2.2.2.2',
      :aggregator=>{:asn=>100, :address=>"10.0.0.1"},
      :cluster_list=>["1.0.1.1"], 
      :as_path=>{}, 
      :communities=>["1133:2015"], 
      :local_pref=>113, 
      :origin=>:incomplete,
      :med=>10, 
      :extended_communities=>[{:route_target=>[13111, 26054]}, {:ospf_domain_id=>'1.1.1.1'}], 
      :originator_id=>"196.168.28.123", 
      :mp_reach=>{
        :nexthop=>["10.0.0.2"], :afi=>1, :safi=>128, 
        :nlris=>[
          {:label=>2226, :prefix=>"172.23.21.113/32", :rd=>[1311, 4567814]}, 
          {:label=>2151, :prefix=>"10.48.9.175/32",   :rd=>[1311, 32117824]}, 
        ], 
      }
    }
    
    pa = Path_attribute.new h
    pa.origin=:egp
    pa.as_path_sequence=[1,2,3,4]
    pa.next_hop='1.2.3.4'
    pa.local_pref=20
    pa.med=30
    pa.communities="1113:2805"
    pa.aggregator.asn=200
    pa.aggregator.address='11.0.0.2'
    pa.originator_id='2.2.2.2'
    pa.cluster_list=['11.1.1.1','12.2.2.2']
    pa.extended_communities.route_target= '10.0.0.1', 1311
    pa.extended_communities.link_bandwidth= 100_000_000
    pa.extended_communities.ospf_router_id= '1.1.1.1'
    pa.extended_communities.ospf_domain_id= '2.2.2.2'
    # pa.extended_communities.encapsulation=1
    pa.extended_communities.route_origin= '3.3.3.3', 33
    pa.extended_communities.color=1311    
    assert_equal(1, pa[Origin].to_i)
    assert_equal(:egp, pa.origin.to_sym)
    assert_equal("1 2 3 4", pa.as_path.as_path)
    assert_equal(200, pa.aggregator.asn)
    assert_equal("11.0.0.2", pa.aggregator.address)
    assert_equal("2.2.2.2", pa.originator_id.originator_id)
    assert_equal("b010101", pa.cluster_list.to_ary[0].to_s(16))
    assert_equal("c020202", pa.cluster_list.to_ary[1].to_s(16))
    assert_equal("Route target: 10.0.0.1:1311", pa.extended_communities.route_target.to_s)
    assert_equal("Ospf domain id: 2.2.2.2:0", pa.extended_communities.ospf_domain_id.to_s)
    assert_equal("Link bandwidth: 100000000.0", pa.extended_communities.link_bandwidth.to_s)
  end

  # method_missing caught 'med=' and its body was commented out, so
  # pa.med=10 returned 10 and did nothing. A script that set a MED sent
  # an UPDATE without one and got no warning.
  def test_med_setter_is_not_a_silent_no_op
    pa = Path_attribute.new(Origin.new(:igp))
    pa.med = 10
    assert(pa.has_a_med_attr?)
    assert(pa.has_a_multi_exit_disc_attr?)
    assert_equal(Multi_exit_disc, pa[:med].class)
    assert_equal(10, pa.med.to_i)
    assert_equal(10, pa.multi_exit_disc.to_i)
    assert_equal('8004040000000a', pa.med.to_shex)
    assert_equal({:origin=>:igp, :med=>10}, pa.to_hash)
  end

  # The alias key and the canonical name are the same attribute, so a
  # setter replaces, it does not append a second MULTI_EXIT_DISC.
  def test_med_alias_and_canonical_name_are_one_attribute
    pa = Path_attribute.new(:med=>10)
    pa.med = 20
    assert_equal(1, pa.size)
    assert_equal(20, pa.multi_exit_disc.to_i)
    pa.multi_exit_disc = 30
    assert_equal(1, pa.size)
    assert_equal(30, pa.med.to_i)
  end

  # Every other alias key gets accessors too.
  def test_alias_accessors_for_the_other_keys
    pa = Path_attribute.new(Origin.new(:igp))
    pa.nexthop = '1.2.3.4'
    pa.community = '1311:1'
    pa.large_community = '1:2:3'
    pa.extended_community = Route_target.new(13111, 26054)
    assert(pa.has_a_nexthop_attr?)
    assert(pa.has_a_community_attr?)
    assert(pa.has_a_large_community_attr?)
    assert(pa.has_an_extended_community?)
    assert_equal('40030401020304', pa.next_hop.to_shex)
    assert_equal('c00804051f0001', pa.communities.to_shex)
    assert_equal('c0200c000000010000000200000003', pa.large_communities.to_shex)
    assert_equal('c0100800023337000065c6', pa.extended_communities.to_shex)
    # The alias getter finds the same attribute as the canonical one.
    assert_same(pa.next_hop, pa.nexthop)
    assert_same(pa.communities, pa.community)
    assert_same(pa.large_communities, pa.large_community)
    assert_same(pa.extended_communities, pa.extended_community)
  end

  # A setter nobody registered must raise, never be swallowed.
  def test_unknown_setter_raises
    pa = Path_attribute.new(Origin.new(:igp))
    assert_raise(NoMethodError) { pa.no_such_attr = 1 }
    assert_raise(NoMethodError) { pa.local_preference = 1 }
    assert_raise(NoMethodError) { pa.multi_exit_discriminator = 1 }
    assert_equal(1, pa.size)
  end

  # The /^as_path_(.+)=$/ branch of method_missing, one per
  # As_path.new_* builder. A name with no builder raises.
  def test_as_path_builder_setters
    pa = Path_attribute.new(Origin.new(:igp))
    pa.as_path_sequence = [1, 2, 3]
    assert_equal('1 2 3', pa.as_path.as_path)
    pa.as_path_set = [4, 5]
    assert_equal('{4, 5}', pa.as_path.as_path)
    assert_equal(2, pa.size)
    assert_raise(NoMethodError) { pa.as_path_bogus = [1] }
  end

  def test_unknown_hash_key_raises_quietly
    out, $stdout = $stdout, StringIO.new
    assert_raise(ArgumentError) { Path_attribute.new(:no_such_attr=>1) }
    assert_equal('', $stdout.string)
  ensure
    $stdout = out
  end

  def test_lookup_as4_aggregator_and_extended_communities
    pa = Path_attribute.new(
      :as4_aggregator=>{:asn=>100, :address=>'1.1.1.1'},
      :extended_communities=>[{:route_target=>[13111, 26054]}]
    )
    assert_equal(As4_aggregator, pa[:as4_aggregator].class)
    assert_equal(As4_aggregator, pa[ATTR::AS4_AGGREGATOR].class)
    assert_equal(Extended_communities, pa[:extended_communities].class)
    assert_equal(Extended_communities, pa[:extended_community].class)
    assert_equal(Extended_communities, pa[ATTR::EXTENDED_COMMUNITY].class)
    assert_nil(pa[:aggregator])
    assert_nil(pa[:no_such_attr])
  end

  def test_as_path_and_as4_path_are_kept_apart
    pa = Path_attribute.new(As4_path.new(1,2), As_path.new(3))
    assert_equal(As4_path, pa[:as4_path].class)
    assert_equal(As_path, pa[:as_path].class)
    assert_equal(As_path, pa.as_path.class)
    assert_equal(As4_path, pa.as4_path.class)
  end

  def test_helpers_for_aigp_as4_path_as4_aggregator
    pa = Path_attribute.new(:aigp=>10, :as4_path=>{:sequence=>[1,2]})
    assert pa.has_an_aigp?
    assert pa.has_a_aigp_attr?
    assert pa.has_an_as4_path?
    assert ! pa.has_an_as4_aggregator?
    assert ! pa.has_an_as_path?
    assert_equal(10, pa.aigp.to_i)
    assert_equal('1 2', pa.as4_path.as_path)
    pa.as4_aggregator = {:address=>'1.1.1.1', :asn=>100}
    assert pa.has_an_as4_aggregator?
    assert_equal(100, pa.as4_aggregator.asn)
    pa.aigp = 20
    assert_equal(20, pa.aigp.to_i)
  end

  def test_wire_round_trip_with_new_types
    pa = Path_attribute.new(
      Origin.new(0), As_path.new(1), As4_path.new(1),
      As4_aggregator.new('1.1.1.1',100), Aigp.new(10)
    )
    parsed = Path_attribute.new(pa.encode)
    assert_equal([Origin, As_path, As4_path, As4_aggregator, Aigp], parsed.attributes.map(&:class))
    assert_equal(pa.encode, parsed.encode)
  end

  def test_factory_unknown_attribute_is_quiet
    out, $stdout = $stdout, StringIO.new
    assert_equal(Attr::Unknown, Attr.factory(['c0630100'].pack('H*')).class)
    assert_equal('', $stdout.string)
  ensure
    $stdout = out
  end

  # B6: an unknown attribute made Path_attribute#to_hash raise.
  def test_unknown_to_hash
    pa = Path_attribute.new(Origin.new(0), Attr.factory(['c0ff0401020304'].pack('H*')))
    h = pa.to_hash
    assert_equal({:origin=>:igp, :unknown=>[{:flags=>0xc, :type=>255, :value=>'01020304'}]}, h)
    assert_equal(pa.to_shex, Path_attribute.new(h).to_shex)
  end

  def test_several_unknowns_to_hash
    s = ['40010100c0ff0401020304806302abcd'].pack('H*')
    pa = Path_attribute.new(s)
    h = pa.to_hash
    assert_equal([
      {:flags=>0xc, :type=>255, :value=>'01020304'},
      {:flags=>0x8, :type=>99, :value=>'abcd'},
    ], h[:unknown])
    assert_equal('40010100c0ff0401020304806302abcd', Path_attribute.new(h).to_shex)
  end

  def test_unknown_old_forms
    # Four argument form, the length argument is ignored.
    assert_equal('c0630178', Attr::Unknown.new(0xc, 99, 0, 'x').to_shex)
    assert_equal('c0630178', Attr::Unknown.new(['c0630178'].pack('H*')).to_shex)
    assert_kind_of(Attr::Raw, Attr::Unknown.new(0xc, 99, 0, 'x'))
  end

  # B7: RFC 4271 section 5 and 9.1.2.2. An unrecognized optional
  # transitive attribute passed on has its Partial bit set.
  def test_unknown_partial
    a = Attr.factory(['c0ff0401020304'].pack('H*'))
    assert_equal(false, a.partial?)
    assert_same(a, a.partial!)
    assert_equal(true, a.partial?)
    assert_equal('e0ff0401020304', a.to_shex)
    assert_equal(0xe, a.to_hash[:unknown][0][:flags])
  end

  def test_unknown_partial_not_set_when_non_transitive
    a = Attr.factory(['80ff0401020304'].pack('H*'))
    assert_equal('80ff0401020304', a.partial!.to_shex)
  end


  # Receive policies (RFC 7606)

  def wire(hex) [hex.delete(' ')].pack('H*') end
  GOOD = '40010100 4002060201fa56ea01 4003040a000001'

  # B9: flags were never checked.
  def test_flags_error_is_reported
    pa = Path_attribute.new(wire('c0010100 4002060201fa56ea01 4003040a000001'), true)
    assert_instance_of Origin, pa[:origin]
    assert_equal [[1, 4, :treat_as_withdraw]], pa.errors.collect { |f| [f.type, f.subcode, f.action] }
    assert_equal :treat_as_withdraw, pa.action
  end

  # B10: lengths were never checked.
  def test_bad_lengths_are_reported
    pa = Path_attribute.new(wire('40010100 c008050102030405'), true)
    assert_equal [[8, 5, :treat_as_withdraw]], pa.errors.collect { |f| [f.type, f.subcode, f.action] }
    pa = Path_attribute.new(wire('40010100 40030800 0a000001'), true)
    assert_equal [[3, 1, :treat_as_withdraw]], pa.errors.collect { |f| [f.type, f.subcode, f.action] }
    assert_instance_of Attr::Raw, pa.attributes.last
  end

  def test_cut_attributes_keep_their_octets
    %w{ 400101004003080a000001 400101004001 4001010040 }.each do |hex|
      pa = Path_attribute.new(wire(hex), true)
      assert_equal hex, pa.encode(true).unpack1('H*'), hex
      assert_equal 1, pa.errors.size, hex
    end
  end

  # B11: duplicates were accepted silently.
  def test_duplicates_are_reported
    pa = Path_attribute.new(wire('40010100 40010102'), true)
    assert_equal 2, pa.size                        # what was on the wire
    assert_equal [[1, 1, :attribute_discard]], pa.errors.collect { |f| [f.type, f.subcode, f.action] }
    mp = Mp_reach.new(:afi=>2, :safi=>1, :nexthop=>'2001:db8::1', :nlris=>['2001:db8:1::/48']).encode
    pa = Path_attribute.new((mp + mp).is_packed, true)
    assert_equal :session_reset, pa.action
  end

  def test_clean_attributes_have_no_errors
    pa = Path_attribute.new(wire(GOOD), true)
    assert_equal [], pa.errors
    assert_nil pa.action
    assert_equal [], Path_attribute.new(Origin.new(0)).errors
  end

  def test_strict_policy_raises_the_strongest_finding
    e = assert_raise(Malformed_attribute) {
      Path_attribute.new(wire('80060101 c0010100 40fa0178'), :as4byte=>true, :policy=>:strict)
    }
    assert_equal [250, 2, :session_reset], [e.type, e.subcode, e.action]
    # ATOMIC_AGGREGATE: flags and length, ORIGIN: flags, type 250: well-known.
    assert_equal 4, e.findings.size
    assert_instance_of Path_attribute, e.path_attribute
    assert_nothing_raised { Path_attribute.new(wire(GOOD), :as4byte=>true, :policy=>:strict) }
  end

  def test_raw_policy_keeps_every_octet
    hex = '50010001 00 c008050102030405 40010102 4003080a000001'.delete(' ')
    pa = Path_attribute.new(wire(hex), :as4byte=>true, :policy=>:raw)
    assert pa.attributes.all? { |a| a.instance_of?(Attr::Raw) }
    assert_equal hex, pa.encode(true).unpack1('H*')
    # COMMUNITIES length, ORIGIN twice, NEXT_HOP cut. Extended Length is fine.
    assert_equal 3, pa.errors.size
  end

  def test_lenient_decodes_as_before
    hex = '50010001 00 4002060201fa56ea01 4003040a000001'.delete(' ')
    pa = Path_attribute.new(wire(hex), true)
    assert_instance_of Origin, pa[:origin]
    assert_equal '4200000001', pa[:as_path].as_path
  end

  def test_unknown_policy
    assert_raise(ArgumentError) { Path_attribute.new(wire(GOOD), :policy=>:loose) }
  end

  def test_validate_built_attributes
    assert_equal [], Path_attribute.new(Origin.new(0), As_path.new(100), Next_hop.new('1.1.1.1')).validate
    found = Path_attribute.new(Origin.new(0).override(length: 2), Origin.new(1),
                               Origin.new(0).override(flags: ATTR::OPTIONAL_TRANSITIVE)).validate
    assert_equal [[1, :treat_as_withdraw], [1, :attribute_discard], [4, :treat_as_withdraw], [1, :attribute_discard]],
                 found.collect { |f| [f.subcode, f.action] }
  end

  def test_validate_reports_a_cut_as_number
    pa = Path_attribute.new(As_path.new(4200000001), Aggregator.new('1.1.1.1', 4200000002))
    found = pa.validate(false)
    assert_equal [[2, nil], [7, nil]], found.collect { |f| [f.type, f.action] }
    assert_equal [], pa.validate(true)
    assert_equal [], pa.as4_fixup.validate(false)
  end

  # B17: validate read segments and asn off whatever carried those type
  # codes, so a malformed one raised instead of being reported.
  def test_validate_handles_raw_attributes
    pa = Path_attribute.new(Attr::Raw.new(ATTR::WELL_KNOWN_MANDATORY, ATTR::AS_PATH, "\x02\x02\x00".b),
                            Attr::Raw.new(ATTR::OPTIONAL_TRANSITIVE, ATTR::AGGREGATOR, "\x00\x64".b))
    found = nil
    assert_nothing_raised { found = pa.validate(false) }
    assert_equal [[2, :treat_as_withdraw], [7, :attribute_discard]],
                 found.collect { |f| [f.type, f.action] }
  end

end
