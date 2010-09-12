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
require 'bgp/path_attribute'

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
      Origin.new(2),
      As_path.new(100,200),
      Local_pref.new(11),
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
  
  def test_4
    s =   '4001010040020a0202000000c80000006440030428000101c0080c0137003b051f00010af50040'
    sbin = [s].pack('H*')
    assert_instance_of(Origin, attr = Attr.factory(sbin))
    assert_instance_of(As_path, attr = Attr.factory(sbin,true))
    assert_equal '200 100', attr.as_path
    assert_instance_of(Next_hop, Attr.factory(sbin,true))
    assert_instance_of(Communities, Attr.factory(sbin,true))
    assert_equal 0, sbin.size
  end
  
end