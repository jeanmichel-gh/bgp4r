#--
# Copyright 2008, 2009, 2010 Jean-Michel Esnault.
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

class Keepalive_Test < Test::Unit::TestCase
  include BGP
  def test_1
    Keepalive.new
    assert_equal('ffffffffffffffffffffffffffffffff001304',Keepalive.new.to_shex)
    assert_equal('ffffffffffffffffffffffffffffffff001304',Message.keepalive.unpack('H*')[0])
    assert_equal(Keepalive, Message.factory(Keepalive.new.encode).class)
  end
end
