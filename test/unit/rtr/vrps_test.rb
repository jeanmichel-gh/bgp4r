#--
# Copyright 2026 Jean-Michel Esnault.
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
require 'bgp/rtr/vrps'
require 'bgp/rib/route'

# RFC 6811 section 2: the Route Origin ASN, Covered, Matched, and the
# three states. docs/design/bgp-operations.md 7c.
class TestRtrVrps < Test::Unit::TestCase
  include BGP

  VRPS = Rtr::Vrps.new([['192.0.2.0', 24, 24, 65_001], ['198.51.100.0', 22, 24, 65_002],
                        ['198.51.100.0', 22, 22, 65_003], ['203.0.113.0', 24, 24, 0],
                        ['2001:db8::', 32, 48, 65_004]])

  def test_the_three_states
    assert_equal(:valid, VRPS.state('192.0.2.0/24', 65_001))
    assert_equal(:invalid, VRPS.state('192.0.2.0/24', 65_009), 'Covered, the AS differs')
    assert_equal(:invalid, VRPS.state('192.0.2.128/25', 65_001), 'Covered, longer than the Max Length')
    assert_equal(:not_found, VRPS.state('192.0.0.0/16', 65_001), 'shorter than the VRP: not Covered')
    assert_equal(:not_found, VRPS.state('10.0.0.0/8', 65_001))
    assert_equal(:valid, VRPS.state('198.51.101.0/24', 65_002), 'within the Max Length')
    assert_equal(:invalid, VRPS.state('198.51.101.0/24', 65_003), 'one VRP Covers, the other Matches nothing')
    assert_equal(:valid, VRPS.state('198.51.100.0/22', 65_003), 'one of two VRPs Matches')
    assert_equal(:valid, VRPS.state('2001:db8:1::/48', 65_004))
    assert_equal(:invalid, VRPS.state('2001:db8:1::/49', 65_004))
    assert_equal(:not_found, VRPS.state('2001:db9::/32', 65_004))
  end

  # "no Route can be Matched by a VRP whose ASN is zero", and NONE
  # Matches nothing.
  def test_as_0_and_none
    assert_equal(:invalid, VRPS.state('203.0.113.0/24', 0))
    assert_equal(:invalid, VRPS.state('192.0.2.0/24', nil))
    assert_equal(:not_found, VRPS.state('10.0.0.0/8', nil))
  end

  # Covered: the VRP's length at most the route's, and the same bits for
  # it. A VRP's host bits, as a cache may send them, do not count.
  def test_covered
    v = Rtr::Vrps.new([['192.0.0.0', 24, 24, 1], ['10.1.2.3', 16, 16, 2]])
    assert_equal(:not_found, v.state('192.0.0.0/16', 1), 'a VRP longer than the route Covers nothing')
    assert_equal(:valid, v.state('10.1.0.0/16', 2))
  end

  def test_the_set
    assert_equal({ :v4 => 4, :v6 => 1 }, VRPS.counts)
    assert(VRPS.covers?('192.0.2.1/32'))
    assert(!VRPS.covers?('192.0.3.0/24'))
    other = Rtr::Vrps.new([['192.0.2.0', 24, 24, 65_001], ['10.0.0.0', 8, 8, 1]])
    added, removed = VRPS.diff(other)
    assert_equal([[['10.0.0.0', 8, 8, 1]], 4], [added.to_a, removed.size])
    assert_equal(Rtr::Vrps.new(VRPS.to_a.reverse), VRPS)
    assert_equal(1, Rtr::Vrps.new([['10.0.0.0', 8, 8, 1], ['10.0.0.0', 8, 8, 1]]).size)
    assert(Rtr::Vrps.new.empty?)
    assert(VRPS.frozen?)
  end

  # Section 2's Route Origin ASN, from the AS_PATH's final segment.
  def test_the_route_origin_asn
    peer = Rib::Peer.new(address: '10.0.0.2', remote_as: 65_002, router_id: '2.2.2.2', local_as: 65_001)
    route = ->(*segs) { Rib::Route.new('10.0.0.0/8', Path_attribute.new(Origin.new(0), Next_hop.new('10.0.0.2'), As_path.new(*segs)), peer) }
    assert_equal(65_010, route.(As_path::Sequence.new(65_002, 65_010)).origin_asn(65_001))
    assert_equal(65_001, route.().origin_asn(65_001), 'empty: our own AS')
    assert_equal(65_001, route.(As_path::Sequence.new(65_002), As_path::Confed_sequence.new(3)).origin_asn(65_001))
    assert_equal(65_001, route.(As_path::Confed_set.new(3, 4)).origin_asn(65_001))
    assert_nil(route.(As_path::Sequence.new(65_002), As_path::Set.new(1, 2)).origin_asn(65_001), 'an AS_SET last: NONE')
    assert_equal(2, route.(As_path::Set.new(1), As_path::Sequence.new(2)).origin_asn(65_001), 'the final segment counts')
  end
end
