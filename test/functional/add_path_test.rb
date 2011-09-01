
require 'bgp4r'
require 'test/helpers/server'

include BGP
include BGP::OPT_PARM::CAP
include BGP::TestHelpers

require "test/unit"

require "bgp4r"

class TestAddPath < Test::Unit::TestCase

  def test_local_and_remote_peers_can_send_and_or_receive_afi_1_safi_1_update_with_path_id
    add_path_cap = BGP::OPT_PARM::CAP::Add_path.new
    add_path_cap2 = BGP::OPT_PARM::CAP::Add_path.new
    add_path_cap.add(:send_and_receive, 1, 1)
    add_path_cap2.add(:send, 1, 1)
    start_server(3456, add_path_cap)
    @c = Neighbor.new(4, 100, 180, '0.0.0.2', '127.0.0.1', '127.0.0.1')
    @c.add_cap add_path_cap2
    @c.start :port=> 3456    
    assert ! @s.session_info.send_inet_unicast?,   "Should *not* have the capability to send inet unicast reachability path info."
    assert   @s.session_info.recv_inet_unicast?,   "Should have the capability to recv inet unicast reachability path info."
    assert   @c.session_info.send_inet_unicast?,   "Should have the capability to send inet unicast reachability path info."
    assert ! @c.session_info.recv_inet_unicast?,   "Should *not* have the capability to recv inet unicast reachability path info."
    assert ! @c.session_info.send_inet6_unicast?,  "Should *not* have the capability to send inet6 unicast reachability path info."
    assert ! @c.session_info.send_inet_multicast?, "Should *not* have the capability to send inet multicast reachability path info."
    stop_server
  end  
end
