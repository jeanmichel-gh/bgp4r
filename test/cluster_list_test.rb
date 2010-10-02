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

require 'bgp/path_attributes/cluster_list'
require 'test/unit'  
class Cluster_list_Test < Test::Unit::TestCase
  include BGP
  def test_1
    list1 = Cluster_list.new('192.168.0.1','10.0.0.1')
    list2 = Cluster_list.new('192.168.0.1 10.0.0.1')
    assert_equal('800a08c0a800010a000001', list1.to_shex)
    assert_equal(list1.to_shex, list2.to_shex)
    assert_equal('192.168.0.1 10.0.0.1',list1.cluster_list)
    assert_equal("[Oncr] (10) Cluster List: [800a08c0a800010a00000...] '192.168.0.1 10.0.0.1'", list1.to_s)
    list3 = Cluster_list.new(['800a08c0a800010a000001'].pack('H*'))
    assert_equal(list1.encode, list3.encode)
    list4 = Cluster_list.new(list3)
    assert_equal(list3.encode, list4.encode)
  end
end
