require "test/unit"
require "bgp/optional_parameters/graceful_restart"
require 'bgp/common'
require 'bgp/iana'

class TestBgpOptionalParametersGracefulCapRestart < Test::Unit::TestCase
  include BGP::OPT_PARM::CAP
  def test_new
    gr = Graceful_restart.new  0, 120
    gr.add( 1, 1, 0x80)
    assert_equal '02084006007800010180', gr.to_shex
    gr2 = Graceful_restart.new(gr.encode)
    assert_equal gr.to_shex, gr2.to_shex
    gr.add( 1, 2, 0x80)
    assert_equal '020c400a00780001018000010280', gr.to_shex
    gr2 = Graceful_restart.new 0, 120
    gr2.add(:ipv4, :unicast)
    assert_equal '02084006007800010100', gr2.to_shex
    gr2.add( :ipv4, :multicast)
    assert_equal '020c400a00780001018000010280', gr.to_shex
    assert_match(/Restart Time 120s/, gr2.to_s)
    assert_match(/AFI IPv4 \(1\), SAFI Unicast \(1\)/, gr2.to_s)
    assert_match(/AFI IPv4 \(1\), SAFI Multicast \(2\)/, gr2.to_s)
    assert_match(/Restart Time 120s/, gr2.to_s)
  end
  def test_add_afi_safi_with_af_state
    gr = Graceful_restart.new 0, 120
    gr.ipv4_unicast_forwarding_state_preserved
    gr.ipv4_unicast_forwarding_state_not_preserved
    gr.ipv4_multicast_forwarding_state_preserved
    gr.ipv4_multicast_forwarding_state_not_preserved
    gr.nsap_unicast_forwarding_state_preserved
    gr.nsap_mpls_vpn_unicast_forwarding_state_not_preserved
    gr.ipv6_mpls_vpn_multicast_forwarding_state_not_preserved
    gr.ipv6_label_nlri_forwarding_state_not_preserved
    assert_match(/Restart Time 120s/, gr.to_s)
    assert_match(/AFI IPv4 \(1\), SAFI Unicast \(1\)/, gr.to_s)
    assert_match(/AFI IPv4 \(1\), SAFI Multicast \(2\)/, gr.to_s)
    assert_match(/Restart Time 120s/, gr.to_s)
  end
end
