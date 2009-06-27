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

require 'bgp/origin'
require 'test/unit'  
class Origin_Test < Test::Unit::TestCase
  include BGP
  def test_1
    assert_equal("40010100", Origin.new.to_shex)
    assert_equal("40010100", Origin.new(:igp).to_shex)
    assert_equal("40010101", Origin.new(:egp).to_shex)
    assert_equal("40010102", Origin.new(:incomplete).to_shex)
  end
  def test_2
    assert_equal("40010100", Origin.new(0).to_shex)
    assert_equal("40010101", Origin.new(1).to_shex)
    assert_equal("40010102", Origin.new(2).to_shex)
  end
  def test_3
    assert_equal("40010100", Origin.new(:origin =>  0 ).to_shex)
    assert_equal("40010101", Origin.new(:origin =>  1 ).to_shex)
    assert_equal("40010102", Origin.new(:origin =>  2 ).to_shex)
  end
  def test_4
    assert_equal("40010100", Origin.new( Origin.new.encode).to_shex)
  end
  def test_5
    assert_equal("igp", Origin.new.origin)
    assert_equal("igp", Origin.new(:igp).origin)
    assert_equal("egp", Origin.new(:egp).origin)
    assert_equal("incomplete", Origin.new(:incomplete).origin)
  end
  def test_6
    assert_equal("[wTcr]  (1)     Origin: [40010100] 'igp'", Origin.new.to_s)
    assert_equal("[wTcr]  (1)     Origin: [40010100] 'igp'", Origin.new(:igp).to_s)
    assert_equal("Origin (1), length: 1, Flags [T]: igp\n   0x0000: ", Origin.new.to_s(:tcpdump))
  end
end
