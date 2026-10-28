
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
    port = start_server(0, add_path_cap)
    @c = Neighbor.new(4, 100, 180, '0.0.0.2', '127.0.0.1', '127.0.0.1')
    @c.add_cap add_path_cap2
    @c.start :port=> port    
    assert ! @s.session_info.send_inet_unicast?,   "Should *not* have the capability to send inet unicast reachability path info."
    assert   @s.session_info.recv_inet_unicast?,   "Should have the capability to recv inet unicast reachability path info."
    assert   @c.session_info.send_inet_unicast?,   "Should have the capability to send inet unicast reachability path info."
    assert ! @c.session_info.recv_inet_unicast?,   "Should *not* have the capability to recv inet unicast reachability path info."
    assert ! @c.session_info.send_inet6_unicast?,  "Should *not* have the capability to send inet6 unicast reachability path info."
    assert ! @c.session_info.send_inet_multicast?, "Should *not* have the capability to send inet multicast reachability path info."
    stop_server
  end

  # The test above writes :send and :send_and_receive on both sides, so it
  # passes whichever value those symbols encode. Here the server advertises
  # the Send/Receive field itself, 1, the way a receive-only router puts it
  # on the wire, so only the direction RFC 7911 section 5 gives it passes:
  # we may send multiple paths when we advertised 2 or 3 and the peer
  # advertised 1 or 3.
  def test_the_send_receive_field_on_the_wire_decides_the_direction
    server_cap = BGP::OPT_PARM::CAP::Add_path.new(1, 1, 1)
    client_cap = BGP::OPT_PARM::CAP::Add_path.new(:send, 1, 1)
    assert_equal '0206450400010101', server_cap.to_shex, 'RFC 7911 section 4: 1 is able to receive'
    assert_equal '0206450400010102', client_cap.to_shex, 'RFC 7911 section 4: 2 is able to send'
    port = start_server(0, server_cap)
    @c = Neighbor.new(4, 100, 180, '0.0.0.2', '127.0.0.1', '127.0.0.1')
    @c.add_cap client_cap
    @c.start :port=> port
    assert   @c.session_info.path_id_send?(1, 1), "We advertised 2, the peer advertised 1."
    assert ! @c.session_info.path_id_recv?(1, 1), "The peer never said it can send to us."
    assert   @s.session_info.path_id_recv?(1, 1), "The server advertised 1, the peer advertised 2."
    assert ! @s.session_info.path_id_send?(1, 1), "The server never said it can send."
    stop_server
  end
end
