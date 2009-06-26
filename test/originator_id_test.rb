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

require 'bgp/originator_id'
require 'test/unit'  
class Originator_id_Test < Test::Unit::TestCase
  include BGP
  def test_1
    orig_id = Originator_id.new('10.0.0.1')
    assert_equal('10.0.0.1', orig_id.originator_id)
    assert_equal("[Oncr]  (9) Originator Id: [8009040a000001] '10.0.0.1'", orig_id.to_s)
    assert_equal(167772161, orig_id.to_i)
    assert_equal('8009040a000001', orig_id.to_shex)
    assert_equal('80090401010101', Originator_id.new('1.1.1.1').to_shex)
    assert_equal(orig_id.to_shex, Originator_id.new(orig_id.encode).to_shex)
    orig_id1 = Originator_id.new(orig_id)
    assert_equal(orig_id.encode, orig_id1.encode)
  end
end
