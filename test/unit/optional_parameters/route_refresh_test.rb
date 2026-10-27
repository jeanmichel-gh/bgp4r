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

class Route_refresh_cap_Test < Test::Unit::TestCase
  include BGP::OPT_PARM
  include BGP::OPT_PARM::CAP
  def test_1
    assert_equal('02020200', Route_refresh.new.to_shex)
    assert_equal('02028000', Route_refresh.new(128).to_shex)
  end
  # RFC 2918 gave route refresh capability code 2. RFC 8810 moved the
  # Cisco code 128 to the registry as a deprecated alias, and bgp4r
  # names it as such.
  def test_to_s
    assert_equal("Option Capabilities Advertisement (2): [02020200]\n" +
                 '    Route Refresh (2), length: 2', Route_refresh.new.to_s)
    assert_equal("Option Capabilities Advertisement (2): [02028000]\n" +
                 '    Route Refresh (Cisco) (128), length: 2',
                 Route_refresh.new(128).to_s)
  end
  def test_default_code_is_the_rfc_2918_one
    assert_equal CAP_ROUTE_REFRESH, Route_refresh.new.to_hash[:code]
    assert_equal CAP_ROUTE_REFRESH_CISCO, Route_refresh.new(128).to_hash[:code]
  end
  # The capability carries no value, so RFC 5492 section 4 makes it a
  # code and a zero length. It has to come back off the wire the same.
  def test_wire_round_trip
    [['02020200', CAP_ROUTE_REFRESH], ['02028000', CAP_ROUTE_REFRESH_CISCO]].each do |hex, code|
      cap = Capability.factory([hex].pack('H*'))
      assert_instance_of(Route_refresh, cap)
      assert_equal hex, cap.to_shex
      assert_equal({:code=>code}, cap.to_hash)
    end
  end
end
