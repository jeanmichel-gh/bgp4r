__END__


require 'bgp4r'
require 'test/helpers/server'

include BGP
include BGP::OPT_PARM::CAP
include BGP::TestHelpers

require "test/unit"

require "bgp4r"

class TestAddPath < Test::Unit::TestCase

  def setup
    start_server(3456)
    @c = Neighbor.new(4, 100, 180, '0.0.0.2', '127.0.0.1', '127.0.0.1')
    @c.start :port=> 3456
  end

  def test_misc
    
    dhcp-171-70-245-252:~ jme$ irb -r bgp4r --noreadline
    irb(main):001:0> require 'test/helpers/server'
    => true
    irb(main):002:0> include BGP
    => Object
    irb(main):003:0> include BGP::TestHelpers
    => Object
    irb(main):004:0> start_server(3100)^C^C        
    irb(main):004:0> s = start_server(3100)
    => #<Thread:0x101410cb0 sleep>
    irb(main):005:0> 
    
    # Create a neighbor and set optional capabilities.
    neighbor = Neighbor.new(4, 100, 180, '0.0.0.2', '127.0.0.1', '127.0.0.1')

    # neighbor = Neighbor.new \
    #   :version=> 4, 
    #   :my_as=> 100, 
    #   :remote_addr => '40.0.0.2', 
    #   :local_addr => '40.0.0.1', 
    #   :id=> '1.1.1.1', :holdtime=> 180

    neighbor.capability :as4_byte
    neighbor.capability :route_refresh
    neighbor.capability :route_refresh, 128
    neighbor.capability :mbgp, :ipv4, :unicast
    neighbor.capability :mbgp, :ipv4, :multicast
    neighbor.capability :mbgp, 3,1
    
  end


  def test_local_and_remote_peers_are_willing_to_send_and_receive_afi_1_safi_1_update_with_path_id
    add_path_cap = BGP::OPT_PARM::CAP::Add_path.new
    add_path_cap.add(:send_and_recv, 1, 1)
    start_server(3456, add_path_cap)
    @c = Neighbor.new(4, 100, 180, '0.0.0.2', '127.0.0.1', '127.0.0.1')
    @c.add_cap add_path_cap
    @c.start :port=> 3456    
    # Server
    assert @s.session_info.recv_inet_unicast?, 
    "Should have the capability to recv inet unicast reachability path info."
    assert @s.session_info.send_inet_unicast?, 
    "Should have the capability to send inet unicast reachability path info."
    # Client
    assert @c.session_info.recv_inet_unicast?, 
    "Should have the capability to recv inet unicast reachability path info."
    assert @c.session_info.send_inet_unicast?, 
    "Should have the capability to send inet unicast reachability path info."
    #
    stop_server
  end
  
  def test_local_and_remote_peers_can_send_and_receive_afi_1_safi_1_update_with_path_id
    add_path_cap = BGP::OPT_PARM::CAP::Add_path.new
    add_path_cap.add(:send_and_recv, 1, 1)
    start_server(3456, add_path_cap)
    @c = Neighbor.new(4, 100, 180, '0.0.0.2', '127.0.0.1', '127.0.0.1')
    @c.add_cap add_path_cap
    @c.start :port=> 3456    
    # Server
    assert @s.session_info.recv_inet_unicast?, 
    "Should have the capability to recv inet unicast reachability path info."
    assert @s.session_info.send_inet_unicast?, 
    "Should have the capability to send inet unicast reachability path info."
    # Client
    assert @c.session_info.recv_inet_unicast?, 
    "Should have the capability to recv inet unicast reachability path info."
    assert @c.session_info.send_inet_unicast?, 
    "Should have the capability to send inet unicast reachability path info."
    #
    stop_server
  end
  
  
  
end
__END__


start_server(3456)
@c = Neighbor.new(4, 100, 180, '0.0.0.2', '127.0.0.1', '127.0.0.1')
@c.start :port=> 3456