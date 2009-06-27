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

require 'bgp/communities'

require 'test/unit'  
class Community_Test < Test::Unit::TestCase
  include BGP
  def test_1
    assert_equal(0xFFFFFF01,Communities::Community.new(:no_export).to_i)
    assert_equal(0xFFFFFF02,Communities::Community.new(:no_advertise).to_i)
    assert_equal(0xFFFFFF03,Communities::Community.new(:no_export_sub_confed).to_i)
    assert_equal(0xFFFFFF04,Communities::Community.new(:no_peer).to_i)
    assert_equal(0xdeadbeef,Communities::Community.new(0xdeadbeef).to_i)
  end
end
class Communities_Test < Test::Unit::TestCase
  include BGP
  def test_1
    assert_equal('113:10 113:20 113:30 113:40', Communities.new("113:10", "113:20", "113:30", "113:40").communities)
    assert_equal('113:10 113:20 113:30 113:40', Communities.new("113:10 113:20 113:30 113:40").communities)
    assert_equal('113:10 113:20 113:30 113:40', Communities.new("113:10, 113:20, 113:30, 113:40").communities)
    assert_equal('113:20', Communities.new("113:20").communities)
    com = Communities.new
    com << '113:10'
    assert_equal('113:10', com.communities)
    com << '113:20'
    assert_equal('113:10 113:20', com.communities)
    com << '113:30'
    assert_equal('113:10 113:20 113:30', com.communities)
    assert_equal('c0080c0071000a007100140071001e', com.to_shex)
    com1 = Communities.new("145:30", "145:40", "145:50", "145:60")
    com2 = Communities.new("145:30,145:40,145:50,145:60")
    assert_equal(com1.to_shex, com2.to_shex)
    assert_equal(["0x91001e", "0x910028", "0x910032", "0x91003c"], com2.to_ary.collect { |c| "0x#{c.to_s(16)}" })
    assert_equal('c008100091001e00910028009100320091003c',com1.to_shex)
    com3 = Communities.new(0x91001E, 0x910028, 0x910032, 0x91003c)
    assert_equal('c008100091001e00910028009100320091003c',com3.to_shex)
    assert_equal('145:30 145:40 145:50 145:60', com3.communities)
    assert_equal("[OTcr]  (8) Communities: [c008100091001e0091002...] '145:30 145:40 145:50 145:60'", com3.to_s)        
    assert_equal(com3.to_shex, Communities.new(com3.encode).to_shex)
  end
  def test_2
    com1 = Communities.new("145:60", "145:10", "145:30", "145:20")
    com2 = Communities.new("145:30,145:20,145:10,145:60")
    assert(com1 ==  com2)
    com1.sort
    assert_equal('145:60 145:10 145:30 145:20', com1.communities)
    com1.sort!
    assert_equal('145:10 145:20 145:30 145:60', com1.communities)
    com3 = Communities.new(com1)
    assert_equal(com1.encode, com3.encode)
  end
end

#MiniTest::Unit.autorun