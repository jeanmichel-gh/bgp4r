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

class Route_refresh_Test < Test::Unit::TestCase
  include BGP
  def test_1
    s = "ffffffffffffffffffffffffffffffff00170500010001"
    sbin = [s].pack('H*')
    assert_equal(Route_refresh, Message.factory(sbin).class)
    rr =  Message.factory(sbin)
    assert_equal(s, rr.to_shex)
    rr.afi, rr.safi=2,2
    assert_equal(2, rr.afi)
    assert_equal(2, rr.safi)
    assert_equal('ffffffffffffffffffffffffffffffff00170500020002', rr.to_shex)
    assert_raise(ArgumentError) { rr.safi=0x100 }
    assert_raise(ArgumentError) { rr.afi=-1 }
    assert_equal(s, Route_refresh.new(1,1).to_shex)
    assert_equal(s, Route_refresh.new(:afi=>1, :safi=>1).to_shex)
    assert_equal({:afi=>1, :safi=>1}, Route_refresh.new(:afi=>1, :safi=>1).to_hash)
    assert_equal(s, Message.route_refresh(1,1).unpack('H*')[0])
  end
end
