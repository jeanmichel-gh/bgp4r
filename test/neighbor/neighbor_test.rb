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
require 'test/helpers/server'

class TestBgpNeighbor < Test::Unit::TestCase
  include BGP
  include BGP::OPT_PARM::CAP
  include BGP::TestHelpers
  def setup
  end
  def teardown
  end
  def test_open_msg
    neighbor = Neighbor.new \
      :version=> 4, 
      :my_as=> 100, 
      :remote_addr => '192.168.1.200',
      :local_addr => '192.168.1.5', 
      :id=> '1.1.1.1', 
      :holdtime=> 20
    neighbor.capability Mbgp.ipv4_unicast
    neighbor.capability Mbgp.ipv4_multicast
    neighbor.capability Route_refresh.new
    neighbor.capability Route_refresh.new 128
    neighbor.capability As4.new(100)
    open_msg = neighbor.open
    assert_equal(5,open_msg.opt_parms.size)
    assert_equal(4,open_msg.version)
    assert_equal(20,open_msg.holdtime)
    assert_equal(100,open_msg.local_as)
    # puts neighbor
  end
  def test_neighbor_state_methods
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
  def test_start
    start_server(3456)
    @c = Neighbor.new(4, 100, 180, '0.0.0.2', '127.0.0.1', '127.0.0.1')
    @c.start :port=> 3456
    assert_equal('Established', @c.state)
    assert_equal('Established', @s.state)
    stop_server
  end
  def test_start_no_blocking
    start_server(3333)
    @c = Neighbor.new(4, 100, 180, '0.0.0.2', '127.0.0.1', '127.0.0.1')
    @c.start :port=> 3333, :no_blocking=>true
    assert_equal('OpenSent', @c.state)
    assert_match(/(Active|OpenSent)/, @s.state)
    stop_server
  end
  def test_send_and_receive_path_id_afi_1_safi_1
    server_add_path_cap = BGP::OPT_PARM::CAP::Add_path.new
    server_add_path_cap.add(:send_and_recv, 1, 1)
    start_server(3456, server_add_path_cap)
    @c = Neighbor.new(4, 100, 180, '0.0.0.2', '127.0.0.1', '127.0.0.1')
    @c.add_cap server_add_path_cap
    @c.start :port=> 3456    
    assert @s.session_info.recv_inet_unicast?, 
            "Should have the capability to recv inet unicast reachability path info."
    assert @s.session_info.send_inet_unicast?, 
            "Should have the capability to send inet unicast reachability path info."
    assert @c.session_info.recv_inet_unicast?, 
            "Should have the capability to recv inet unicast reachability path info."
    assert @c.session_info.send_inet_unicast?, 
           "Should have the capability to send inet unicast reachability path info."
    stop_server
  end
  def test_send_path_id_afi_1_safi_1
    server_add_path_cap = BGP::OPT_PARM::CAP::Add_path.new
    server_add_path_cap.add(:send, 1, 1)
    client_add_path_cap = BGP::OPT_PARM::CAP::Add_path.new
    client_add_path_cap.add(:recv, 1, 1)
    start_server(3456, server_add_path_cap)
    @c = Neighbor.new(4, 100, 180, '0.0.0.2', '127.0.0.1', '127.0.0.1')
    @c.add_cap client_add_path_cap
    @c.start :port=> 3456    
    assert ! @s.session_info.recv_inet_unicast?, 
            "Should NOT have the capability to recv inet unicast reachability path info."
    assert   @s.session_info.send_inet_unicast?, 
            "Should have the capability to send inet unicast reachability path info."
    assert @c.session_info.recv_inet_unicast?, 
            "Should have the capability to recv inet unicast reachability path info."
    assert ! @c.session_info.send_inet_unicast?, 
           "Should NOT have the capability to send inet unicast reachability path info."
    stop_server
  end
  def test_recv_path_id_afi_1_safi_1
    server_add_path_cap = BGP::OPT_PARM::CAP::Add_path.new
    server_add_path_cap.add(:recv, 1, 1)
    client_add_path_cap = BGP::OPT_PARM::CAP::Add_path.new
    client_add_path_cap.add(:send, 1, 1)
    start_server(3456, server_add_path_cap)
    @c = Neighbor.new(4, 100, 180, '0.0.0.2', '127.0.0.1', '127.0.0.1')
    @c.add_cap client_add_path_cap
    @c.start :port=> 3456    
    assert  @s.session_info.recv_inet_unicast?, 
            "Should have the capability to recv inet unicast reachability path info."
    assert !  @s.session_info.send_inet_unicast?, 
            "Should NOT have the capability to send inet unicast reachability path info."
    assert ! @c.session_info.recv_inet_unicast?, 
            "Should NOT have the capability to recv inet unicast reachability path info."
    assert  @c.session_info.send_inet_unicast?, 
           "Should have the capability to send inet unicast reachability path info."
    stop_server
  end

  def test_nor_recv_nor_send_path_id_afi_1_safi_1
    server_add_path_cap = BGP::OPT_PARM::CAP::Add_path.new
    server_add_path_cap.add(:recv, 1, 1)
    client_add_path_cap = BGP::OPT_PARM::CAP::Add_path.new
    client_add_path_cap.add(:recv, 1, 1)
    start_server(3456, server_add_path_cap)
    @c = Neighbor.new(4, 100, 180, '0.0.0.2', '127.0.0.1', '127.0.0.1')
    @c.add_cap client_add_path_cap
    @c.start :port=> 3456    
    assert ! @s.session_info.recv_inet_unicast?, 
            "Should NOT have the capability to recv inet unicast reachability path info."
    assert !  @s.session_info.send_inet_unicast?, 
            "Should NOT have the capability to send inet unicast reachability path info."
    assert ! @c.session_info.recv_inet_unicast?, 
            "Should NOT have the capability to recv inet unicast reachability path info."
    assert ! @c.session_info.send_inet_unicast?, 
           "Should have the capability to send inet unicast reachability path info."
    stop_server
  end


end