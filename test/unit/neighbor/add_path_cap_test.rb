
require "test/unit"
require 'bgp4r'

class TestBgpNeighborAddPathCap < Test::Unit::TestCase
  include BGP
  def setup
  end
  def test_as4_cap
    speaker = Open.new(4,100, 200, '10.0.0.1', OPT_PARM::CAP::As4.new(100))
    peer    = Open.new(4,100, 200, '10.0.0.1')
    assert ! Neighbor::Capabilities.new(speaker, peer).as4byte?, "AS 2-Octet encoding expected!"
    peer = Open.new(4,100, 200, '10.0.0.1', OPT_PARM::CAP::As4.new(100))
    speaker    = Open.new(4,100, 200, '10.0.0.1')
    assert ! Neighbor::Capabilities.new(speaker, peer).as4byte?, "AS 2-Octet encoding expected!"
    peer     = Open.new(4,100, 200, '10.0.0.1', OPT_PARM::CAP::As4.new(100))
    speaker  = Open.new(4,100, 200, '10.0.0.1', OPT_PARM::CAP::As4.new(100))
    assert Neighbor::Capabilities.new(speaker, peer).as4byte?, "AS 4-Octet encoding expected!"
  end
  def test_add_path_send_and_recv_inet_unicast
    peer    = Open.new(4,100, 200, '10.0.0.1', OPT_PARM::CAP::Add_path.new( :send_and_receive, 1, 1))
    speaker = Open.new(4,100, 200, '10.0.0.1', OPT_PARM::CAP::Add_path.new( :send_and_receive, 1, 1))
    session_cap = Neighbor::Capabilities.new(speaker, peer)
    assert   session_cap.send_inet_unicast?
    assert   session_cap.path_id_recv?(1,1)
    assert   session_cap.path_id_send?(1,1)
    assert ! session_cap.send_inet_multicast?
  end
  def test_add_path_send_and_recv_inet6_multicast
    peer    = Open.new(4,100, 200, '10.0.0.1', OPT_PARM::CAP::Add_path.new( :send_and_receive, 2, 2))
    speaker = Open.new(4,100, 200, '10.0.0.1', OPT_PARM::CAP::Add_path.new( :send_and_receive, 2, 2))
    session_cap = Neighbor::Capabilities.new(speaker, peer)
    assert  ! session_cap.send_inet_unicast?
    assert  session_cap.send_inet6_multicast?
    assert  session_cap.recv_inet6_multicast?
  end
  def test_add_path_send_and_recv_inet_mpls_vpn_unicast
    peer    = Open.new(4,100, 200, '10.0.0.1', OPT_PARM::CAP::Add_path.new( :send_and_receive, 1, 128))
    speaker = Open.new(4,100, 200, '10.0.0.1', OPT_PARM::CAP::Add_path.new( :send_and_receive, 1, 128))
    session_cap = Neighbor::Capabilities.new(speaker, peer)
    assert    session_cap.send_inet_mpls_vpn_unicast?
    assert  ! session_cap.send_inet6_multicast?
    assert  ! session_cap.recv_inet6_multicast?
  end
  def test_add_path_send_and_recv_inet_mpls_vpn_multicast
    peer    = Open.new(4,100, 200, '10.0.0.1', OPT_PARM::CAP::Add_path.new( :send_and_receive, 1, 129))
    speaker = Open.new(4,100, 200, '10.0.0.1', OPT_PARM::CAP::Add_path.new( :send_and_receive, 1, 129))
    session_cap = Neighbor::Capabilities.new(speaker, peer)
    assert    session_cap.send_inet_mpls_vpn_multicast?
    assert  ! session_cap.send_inet_mpls_vpn_unicast?
    assert  ! session_cap.send_inet6_multicast?
    assert  ! session_cap.recv_inet6_multicast?
  end
end
