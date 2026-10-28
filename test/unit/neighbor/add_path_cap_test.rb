
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
  def test_add_path_recv_inet_unicast
    peer    = Open.new(4,100, 200, '10.0.0.1', OPT_PARM::CAP::Add_path.new( :send, 1, 1))
    speaker = Open.new(4,100, 200, '10.0.0.1', OPT_PARM::CAP::Add_path.new( :send_and_receive, 1, 1))
    session_cap = Neighbor::Capabilities.new(speaker, peer)
    assert    session_cap.recv_inet_unicast?
    assert    session_cap.path_id_recv?(1,1)
    assert  ! session_cap.send_inet_unicast?
    assert  ! session_cap.path_id_send?(1,1)
    assert  ! session_cap.send_inet_multicast?
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

  def test_add_path_send_inet_unicast
    peer    = Open.new(4,100, 200, '10.0.0.1', OPT_PARM::CAP::Add_path.new( :recv, 1, 1))
    speaker = Open.new(4,100, 200, '10.0.0.1', OPT_PARM::CAP::Add_path.new( :send, 1, 1))
    session_cap = Neighbor::Capabilities.new(speaker, peer)
    assert   session_cap.send_inet_unicast?
    assert   session_cap.path_id_send?(1,1)
    assert ! session_cap.path_id_recv?(1,1)
    assert ! session_cap.send_inet_multicast?
  end
  def test_add_path_send_inet_unicast_2
    peer    = Open.new(4,100, 200, '10.0.0.1', OPT_PARM::CAP::Add_path.new( :send_and_receive, 1, 1))
    speaker = Open.new(4,100, 200, '10.0.0.1', OPT_PARM::CAP::Add_path.new( :send, 1, 1))
    session_cap = Neighbor::Capabilities.new(speaker, peer)
    assert   session_cap.send_inet_unicast?
    assert ! session_cap.path_id_recv?(1,1)
    assert   session_cap.path_id_send?(1,1)
    assert ! session_cap.send_inet_multicast?
  end
  def test_add_path_recv_inet6_multicast
    peer    = Open.new(4,100, 200, '10.0.0.1', OPT_PARM::CAP::Add_path.new( :send, 2, 2))
    speaker = Open.new(4,100, 200, '10.0.0.1', OPT_PARM::CAP::Add_path.new( :recv, 2, 2))
    session_cap = Neighbor::Capabilities.new(speaker, peer)
    assert ! session_cap.path_id_recv?(2,1)
    assert   session_cap.path_id_recv?(2,2)
    assert ! session_cap.path_id_send?(2,2)
    assert   session_cap.recv_inet6_multicast?
    assert ! session_cap.recv_inet_multicast?
    assert ! session_cap.send_inet_unicast?
  end

  # The tests above write the direction as a symbol on both sides, so they
  # pass whichever value the symbol encodes: the two errors cancel. These
  # write the Send/Receive field itself, the way a router puts it on the
  # wire, so only the direction RFC 7911 gives it passes.
  #
  # RFC 7911 section 5: to send multiple paths a speaker "MUST advertise the
  # ADD-PATH Capability with the Send/Receive field set to either 2 or 3, and
  # MUST receive from its peer the ADD-PATH Capability with the Send/Receive
  # field set to either 1 or 3".
  def test_the_wire_field_decides_the_direction_rfc_7911_section_5
    # We advertise 2, the peer advertises 1: we may send Path Identifiers.
    speaker = Open.new(4, 100, 200, '10.0.0.1', OPT_PARM::CAP::Add_path.new(2, 1, 1))
    peer    = Open.new(4, 100, 200, '10.0.0.1', OPT_PARM::CAP::Add_path.new(1, 1, 1))
    caps = Neighbor::Capabilities.new(speaker, peer)
    assert   caps.path_id_send?(1, 1), 'we said 2, the peer said 1'
    assert ! caps.path_id_recv?(1, 1), 'neither side said it can send to us'

    # The other way round: we advertise 1, the peer advertises 2.
    caps = Neighbor::Capabilities.new(peer, speaker)
    assert   caps.path_id_recv?(1, 1), 'we said 1, the peer said 2'
    assert ! caps.path_id_send?(1, 1), 'we never said we can send'

    # Both sides say 3, so both directions carry Path Identifiers.
    both = Open.new(4, 100, 200, '10.0.0.1', OPT_PARM::CAP::Add_path.new(3, 1, 1))
    caps = Neighbor::Capabilities.new(both, both)
    assert caps.path_id_send?(1, 1)
    assert caps.path_id_recv?(1, 1)

    # Two speakers that can only receive negotiate nothing.
    only_recv = Open.new(4, 100, 200, '10.0.0.1', OPT_PARM::CAP::Add_path.new(1, 1, 1))
    caps = Neighbor::Capabilities.new(only_recv, only_recv)
    assert ! caps.path_id_send?(1, 1)
    assert ! caps.path_id_recv?(1, 1)
  end

  # A value no RFC defines negotiates nothing. RFC 7911 section 4: any other
  # value SHOULD be treated as the capability not being understood.
  def test_an_undefined_send_receive_value_negotiates_nothing
    [0, 4, 255].each do |val|
      odd  = Open.new(4, 100, 200, '10.0.0.1', OPT_PARM::CAP::Add_path.new(val, 1, 1))
      both = Open.new(4, 100, 200, '10.0.0.1', OPT_PARM::CAP::Add_path.new(3, 1, 1))
      assert ! Neighbor::Capabilities.new(both, odd).path_id_send?(1, 1), "peer sent #{val}"
      assert ! Neighbor::Capabilities.new(both, odd).path_id_recv?(1, 1), "peer sent #{val}"
      assert ! Neighbor::Capabilities.new(odd, both).path_id_send?(1, 1), "we sent #{val}"
      assert ! Neighbor::Capabilities.new(odd, both).path_id_recv?(1, 1), "we sent #{val}"
    end
  end

  def test_extended_nexthop_needs_both_sides
    enh = OPT_PARM::CAP::Extended_nexthop
    both    = Open.new(4,100, 200, '10.0.0.1', enh.new(1, 1, 2))
    neither = Open.new(4,100, 200, '10.0.0.1')
    vpn     = Open.new(4,100, 200, '10.0.0.1', enh.new(1, 128, 2))
    assert   Neighbor::Capabilities.new(both, both).extended_nexthop?
    assert   Neighbor::Capabilities.new(both, both).extended_nexthop?(1, 1, 2)
    assert ! Neighbor::Capabilities.new(both, neither).extended_nexthop?
    assert ! Neighbor::Capabilities.new(neither, both).extended_nexthop?
    assert ! Neighbor::Capabilities.new(both, vpn).extended_nexthop?
    assert ! Neighbor::Capabilities.new(both, vpn).extended_nexthop?(1, 128)
  end

end
