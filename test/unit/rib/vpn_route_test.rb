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
require 'bgp/rib'

# BGP:: names are written out in full here, see Conventions in CLAUDE.md.
class TestBgpRibVpnRoute < Test::Unit::TestCase

  def peer
    BGP::Rib::Peer.new(:address => '10.255.0.3', :remote_as => 65000,
                       :router_id => '10.255.0.3', :local_as => 65000)
  end

  def route(*rts)
    ec = BGP::Extended_communities.new(*rts) unless rts.empty?
    pa = BGP::Path_attribute.new(*[BGP::Origin.new(0), BGP::As_path.new, ec].compact)
    BGP::Rib::VpnRoute.new('65000:1', [24001], BGP::Rib::Route.new('192.168.2.0/30', pa, peer))
  end

  def test_the_key_is_the_rd_the_prefix_and_the_path_id
    assert_equal(['65000:1', '192.168.2.0/30', nil], route.key)
    assert_equal('192.168.2.0/30', route.prefix)
  end

  # RFC 4360 section 4: the high-order octet of the type is 0x00 (a
  # 2-octet AS), 0x01 (an IPv4 address) or 0x02 (a 4-octet AS).
  def test_the_route_targets_as_text_in_every_form
    v = route(BGP::Route_target.new(65000, 100), BGP::Route_target.new('10.255.0.3', 7),
              BGP::Route_target.new(4_200_000_001, 9))
    assert_equal(['65000:100', '10.255.0.3:7', '4200000001:9'], v.route_targets)
  end

  def test_no_extended_communities_no_route_targets
    assert_equal([], route.route_targets)
  end

  # Another extended community is not a Route Target.
  def test_only_route_targets_are_read
    v = route(BGP::Route_origin.new(65000, 5), BGP::Route_target.new(65000, 100))
    assert_equal(['65000:100'], v.route_targets)
  end

  # RFC 4364 section 7: "The Site of Origin attribute, if used, is
  # encoded as a Route Origin Extended Community" (RFC 4360 section 5).
  # Read apart from the Route Targets.
  def test_the_site_of_origin_is_the_first_route_origin
    v = route(BGP::Route_target.new(65000, 100), BGP::Route_origin.new(65000, 11), BGP::Route_origin.new(65000, 12))
    assert_equal('65000:11', v.soo)
    assert_nil(route(BGP::Route_target.new(65000, 100)).soo)
    assert_nil(route.soo)
  end
end
