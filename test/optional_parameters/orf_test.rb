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
require 'bgp4r'

class Orf_cap_Test < Test::Unit::TestCase
  include BGP
  def test_1
    ent1 =  Orf_cap::Entry.new(1,1,[1,1],[2,1],[3,1])
    assert_equal('0001000103010102010301', ent1.to_shex)
    ent2 =  Orf_cap::Entry.new(1,2,[1,1],[2,1],[3,1])
    assert_equal('0001000203010102010301', ent2.to_shex)
    ent3 = Orf_cap::Entry.new(ent1.encode)
    assert_equal(ent1.encode, ent3.encode)
    orf = Orf_cap.new
    orf.add(ent1)
    orf.add(ent2)
    assert_equal('0218031600010001030101020103010001000203010102010301', orf.to_shex)
    orf2 = Orf_cap.new(orf.encode)
    assert_equal(orf.encode, orf2.encode)
  end

end
