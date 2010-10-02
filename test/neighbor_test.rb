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

require "test/unit"
require 'bgp4r'

class TestBgpNeighbor < Test::Unit::TestCase
  include BGP
  def test_open_msg
    neighbor = Neighbor.new \
      :version=> 4, 
      :my_as=> 100, 
      :remote_addr => '192.168.1.200',
      :local_addr => '192.168.1.5', 
      :id=> '1.1.1.1', 
      :holdtime=> 20
    neighbor.capability Mbgp_cap.ipv4_unicast
    neighbor.capability Mbgp_cap.ipv4_multicast
    neighbor.capability Route_refresh_cap.new
    neighbor.capability Route_refresh_cap.new 128
    neighbor.capability As4_cap.new(100)
    open_msg = neighbor.open
    assert_equal(5,open_msg.opt_parms.size)
    assert_equal(4,open_msg.version)
    assert_equal(20,open_msg.holdtime)
    assert_equal(100,open_msg.local_as)
    # puts neighbor
  end
  def test_states
    neighbor = Neighbor.new \
      :version=> 4, 
      :my_as=> 100, 
      :remote_addr => '192.168.1.200', 
      :local_addr => '192.168.1.5', 
      :id=> '1.1.1.1', 
      :holdtime=> 20
      assert neighbor.is_idle?
      assert ! neighbor.is_established?
      assert ! neighbor.is_openrecv?
      assert ! neighbor.is_openconfirm?  
  end
end