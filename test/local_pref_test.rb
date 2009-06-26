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

require 'bgp/local_pref'
require 'test/unit'  
class Local_pref_Test < Test::Unit::TestCase
  include BGP
  def test_1
    assert_equal("40050400000064", Local_pref.new.to_shex)
    assert_equal("40050400000064", Local_pref.new(100).to_shex)
    assert_equal("400504000000c8", Local_pref.new(200).to_shex)
    assert_equal('40050400000064', Local_pref.new(:local_pref=>100).to_shex)
    assert_raise(ArgumentError) { Local_pref.new({})}
  end
  def test_2
    lp =  Local_pref.new(200)
    assert_equal("400504000000c8", Local_pref.new(lp.encode).to_shex)
    assert_equal("(0x00c8) 200", Local_pref.new(200).local_pref)
    assert_equal("[wTcr]  (5) Local Pref: [400504000000c8] '(0x00c8) 200'", Local_pref.new(200).to_s)
    assert_equal(200, Local_pref.new(200).to_i)
    lp1 = Local_pref.new(lp)
    assert_equal(lp.encode, lp1.encode)
  end
end
