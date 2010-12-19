require "test/unit"
require 'bgp4r'
require "bgp/optional_parameters/add_path"

class TestBgpOptionalParametersAddPath < Test::Unit::TestCase
  include BGP::OPT_PARM::CAP
  def test_1
    ap = Add_path.new
    ap.add( :send, 1, 1)
    assert_equal '0206450400010101', ap.to_shex
    ap.add( :recv, 2, 128)
    assert_equal '020a45080001010100028002', ap.to_shex
    ap.add :send_and_receive, :ipv6, :unicast
    assert_equal '020e450c000101010002010300028002', ap.to_shex
  end
  def test_2
    ap = Add_path.new
    ap.add( :send, 1, 1)
    ap.add( :send, 2, 128)
    #puts ap
  end
  def test_3
    ap1 = Add_path.new_array [[1, 1 ,2 ], [2, 10, 10]]
    ap2 = Add_path.new_array [[:send, :ipv4 ,:multicast], [:recv, 10, 10]]
    assert_equal ap1.to_shex, ap2.to_shex
  end
  def test_4
    speaker = Add_path.new :send, 1, 1
    assert speaker.agrees_to? :send, 1, 1
    assert ! speaker.agrees_to?(:recv, 1, 1), "speaker should not agree to recv afi 1 safi 1"
    peer = Add_path.new :recv, 1, 1
    assert peer.agrees_to?(:recv, 1, 1), "peer should agree to recv afi 1 safi 1"
    assert include_path_id?(speaker, peer, :send, 1, 1), "route should include path id for afi 1 safi 1!"
    assert ! include_path_id?(speaker, peer, :send, 1, 2), "route should include path id for afi 1 safi 2 !"
    peer.add :recv, 1, 2
    assert ! include_path_id?(speaker, peer, :send, 1, 2), "route should include path id for afi 1 safi 2 !"
    assert ! speaker.agrees_to?(:send, 1, 2)
    speaker.add :send, 1,2
    assert speaker.agrees_to?(:send, 1, 2)
    assert include_path_id?(speaker, peer, :send, 1, 2), "route should include path id for afi 1 safi 2 !"
  end
end


__END__


Option Capabilities Advertisement (2): [020a45080001010100028001]
    Add-path Extension (69), length: 4
        AFI IPv4 (1), SAFI Unicast (1), SEND (1)
        AFI IPv6 (2), SAFI Labeled VPN Unicast (128), SEND (1)
        
Option Capabilities Advertisement (2): [020a450800010201000a0a02]
    Add-path Extension (69), length: 4
        AFI IPv4 (1), SAFI Multicast (2), SEND (1)
        AFI  (10), SAFI  (10), RECV (2)
