#--
# Copyright 2010, 2026 Jean-Michel Esnault.
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

require 'test/unit'
require 'bgp4r'

class Mbgp_cap_Test < Test::Unit::TestCase
  include BGP::OPT_PARM::CAP
  def test_1
    mbgp1 = Mbgp.new(1,1)
    mbgp2 = Mbgp.new(['0206010400010001'].pack('H*'))
    mbgp3 = Mbgp.new(mbgp1.encode)
    assert_equal(mbgp2.encode, mbgp3.encode)
    assert_equal "Option Capabilities Advertisement (2): [0206010400010001]\n    Multiprotocol Extensions (1), length: 4\n      AFI IPv4 (1), SAFI Unicast (1)", mbgp2.to_s
  end
  def test_mbgp_capabilities
    assert_equal(1,Mbgp.ipv4_unicast.afi)
    assert_equal(1,Mbgp.ipv4_unicast.safi)
    assert_equal(2,Mbgp.ipv6_unicast.afi)
    assert_equal(1,Mbgp.ipv6_unicast.safi)
    assert_equal(3,Mbgp.nsap_unicast.afi)
    assert_equal(1,Mbgp.nsap_unicast.safi)
    assert_equal(1,Mbgp.ipv4_multicast.afi)
    assert_equal(2,Mbgp.ipv4_multicast.safi)
    assert_equal(2,Mbgp.ipv6_multicast.afi)
    assert_equal(2,Mbgp.ipv6_multicast.safi)
    assert_equal(3,Mbgp.nsap_multicast.afi)
    assert_equal(2,Mbgp.nsap_multicast.safi)
    assert_equal(1,Mbgp.ipv4_mpls_vpn_unicast.afi)
    assert_equal(2,Mbgp.ipv6_mpls_vpn_multicast.afi)
    assert_equal(3,Mbgp.nsap_mpls_vpn_unicast.afi)
    assert_equal(128,Mbgp.ipv4_mpls_vpn_unicast.safi)
    assert_equal(129,Mbgp.ipv6_mpls_vpn_multicast.safi)
    assert_equal(128,Mbgp.nsap_mpls_vpn_unicast.safi)
  end

  # An AFI or a SAFI IANA has no name for prints its number. Both forms
  # used to interpolate a nil: to_s said "AFI  (999), SAFI  (77)" and
  # to_s_brief said "MBGP , ". Building is never validated, so any AFI and
  # any SAFI can be sent and a Capability message then showed a row that
  # named nothing.
  def test_an_unnamed_address_family_prints_its_number
    cap = Mbgp.new(999, 77)
    assert_equal('MBGP 999, 77', cap.to_s_brief)
    assert_match(/AFI 999, SAFI 77/, cap.to_s)
    # A named one is unchanged.
    assert_equal('MBGP IPv6, Labeled VPN Unicast', Mbgp.new(2, 128).to_s_brief)
    assert_match(/AFI IPv4 \(1\), SAFI Unicast \(1\)/, Mbgp.new(1, 1).to_s)
  end

  # The third build path, which was missing: a Hash reached IANA.afi and
  # raised TypeError. Both the nested form to_hash writes and the bare
  # inner hash are taken.
  def test_builds_from_its_own_hash
    [[1, 1], [2, 1], [1, 128], [2, 128]].each do |afi, safi|
      cap = Mbgp.new(afi, safi)
      assert_equal({ :code => 1, :capability => { :afi => afi, :safi => safi } },
                   cap.to_hash)
      assert_equal(cap.encode, Mbgp.new(cap.to_hash).encode, "#{afi}/#{safi}")
      assert_equal(cap.encode, Mbgp.new(:afi => afi, :safi => safi).encode)
    end
  end
end
