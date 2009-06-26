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

require 'bgp/common'
require 'bgp/path_attribute'
require 'test/unit'

class ATTR_Test < Test::Unit::TestCase
  include BGP
  class Attr_test < Attr
    def initialize
      @type, @flags = 0, 0
    end
    def encode
      @type=0xee
      @flags=0xf
      super()
    end
  end
  def test_1
   assert_equal('f0ee00',Attr_test.new.to_shex)
   attr = Attr_test.new
   assert_equal(attr.encode4, attr.encode)
  end
end
class Attr_factory_Test < Test::Unit::TestCase
  include BGP
  def test_1
    s = ['400101014003040a000001800404000000644005040000006440020c020500010002000300040005c0080c051f00010137003b0af50040'].pack('H*')
    assert_equal(Origin, BGP::Attr.factory(s).class)
    assert_equal(Next_hop, BGP::Attr.factory(s).class)
    assert_equal(Multi_exit_disc, BGP::Attr.factory(s).class)
    assert_equal(Local_pref, BGP::Attr.factory(s).class)
    assert_equal(As_path, BGP::Attr.factory(s).class)
    assert_equal(Communities, BGP::Attr.factory(s).class)
    assert_equal('',s)
  end
end
