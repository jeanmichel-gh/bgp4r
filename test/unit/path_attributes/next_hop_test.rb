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

require 'bgp/path_attributes/next_hop'
require 'test/unit'  
class Next_hop_Test < Test::Unit::TestCase
  include BGP
  def test_1
    next_hop = Next_hop.new('10.0.0.1')
    assert_equal('10.0.0.1', next_hop.next_hop)
    assert_equal("[wTcr]  (3)   Next Hop: [4003040a000001] '10.0.0.1'", next_hop.to_s)
    assert_equal(167772161, next_hop.to_i)
    assert_equal('4003040a000001', next_hop.to_shex)
    assert_equal(next_hop.to_shex, Next_hop.new(next_hop.encode).to_shex)
    next_hop1 = Next_hop.new(next_hop)
    assert_equal(next_hop.encode, next_hop1.encode)
  end
  def test_2
    next_hop = Next_hop.new_hash :next_hop=> '10.0.0.1'
  end
end
