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

require 'bgp/nlris/label'
require 'test/unit'

class Label_Test < Test::Unit::TestCase
  include BGP
  def test_1
    l1 =  Label.new(:label=>100, :exp=>1)
    l2 =  Label.new(100,1)
    l3 =  Label.new(l2.encode)
    assert_equal(l1.to_shex, l2.to_shex)
    assert_equal(l1.to_shex, l3.to_shex)
    assert_equal('000641', Label.new(100).to_shex)
    assert_equal('000643', Label.new(100,1).to_shex)
    assert_equal({:label=>100, :exp=>1},Label.new(100,1).to_hash)
    assert_equal({:label=>100, :exp=>1}, Label.new(:label=>100, :exp=>1).to_hash)
    assert_equal({:label=>100, :exp=>0}, Label.new(:label=>100).to_hash)
  end
end

class Label_stack_Test < Test::Unit::TestCase
  include BGP
  def test_1
    ls =  Label_stack.new(100,101,102)
    assert_equal('000640000650000661', ls.to_shex)
    assert_equal('Label Stack=100,101,102 (bottom)', ls.to_s)
    assert_equal('Label stack:(empty)', Label_stack.new.to_s)
    assert_equal(ls.encode, Label_stack.new(['000640000650000661'].pack('H*')).encode)
    assert_equal("Label Stack=100,101 (bottom)", Label_stack.new(['000640000651000661'].pack('H*')).to_s)
    assert_equal({:labels=>[100,101]}, Label_stack.new(['000640000651000661'].pack('H*')).to_hash)
    assert_equal({:labels=>[100,101,102]}, ls.to_hash)
    ls = Label_stack.new :labels=>[100,101,102]
    assert_equal('000640000650000661', ls.to_shex)
  end
end
