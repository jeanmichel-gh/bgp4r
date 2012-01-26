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

require "bgp/path_attributes/atomic_aggregate"

require 'test/unit'
class Atomic_aggregate_Test < Test::Unit::TestCase
  include BGP
  def test_1
    assert_equal("800600", Atomic_aggregate.new.to_shex)
    assert_equal("Atomic Aggregate (6), length: 0, Flags [O]: ", Atomic_aggregate.new.to_s)
    obj =  Atomic_aggregate.new
    assert_equal("800600", Atomic_aggregate.new(obj.encode).to_shex)
  end
  def test_2
    assert_equal({},Atomic_aggregate.new.to_hash)
  end
end

