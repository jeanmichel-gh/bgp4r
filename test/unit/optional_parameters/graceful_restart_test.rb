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

  # Same hole here. An address family in this capability is whatever was
  # added or arrived, and nothing validates it.
  def test_an_unnamed_address_family_prints_its_number
    gr = Graceful_restart.new(0, 120)
    gr.add(999, 77)
    assert_match(/AFI 999, SAFI 77/, gr.to_s)
    gr.add(1, 1)
    assert_match(/AFI IPv4 \(1\), SAFI Unicast \(1\)/, gr.to_s)
  end

  # It inherited Capability's bare {:code=>64}, so the restart state, the
  # restart time and every family were lost together, and a Hash went to
  # parse, which called slice! on it.
  #
  # RFC 4724 section 3: Restart Flags (4 bits), Restart Time in seconds
  # (12 bits), then per family Address Family Identifier (16 bits),
  # Subsequent Address Family Identifier (8 bits), Flags for Address
  # Family (8 bits). The most significant bit of Restart Flags is the
  # Restart State (R), and the most significant bit of Flags for Address
  # Family is the Forwarding State (F), which is the 0x80 below.
  def test_to_hash_carries_the_whole_capability_and_reads_back
    gr = BGP::OPT_PARM::CAP::Graceful_restart.new(0x8, 120)
    gr.add(1, 1, 0x80)
    gr.add(2, 128, 0)
    assert_equal({ :code => 64, :capability => {
                     :restart_state => 0x8, :restart_time => 120,
                     :families => [{ :afi => 1, :safi => 1, :flags => 0x80 },
                                   { :afi => 2, :safi => 128, :flags => 0 }] } },
                 gr.to_hash)
    assert_equal(gr.encode, BGP::OPT_PARM::CAP::Graceful_restart.new(gr.to_hash).encode)
    # Capability.from_hash used to refuse this code by name.
    assert_equal(gr.encode, BGP::OPT_PARM::Capability.from_hash(gr.to_hash).encode)
  end

  def test_a_capability_with_no_family_still_round_trips
    gr = BGP::OPT_PARM::CAP::Graceful_restart.new(0, 0)
    assert_equal({ :code => 64, :capability => {
                     :restart_state => 0, :restart_time => 0, :families => [] } },
                 gr.to_hash)
    assert_equal(gr.encode, BGP::OPT_PARM::CAP::Graceful_restart.new(gr.to_hash).encode)
  end
end
