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

class Dynamic_capability_Test < Test::Unit::TestCase
  include BGP::OPT_PARM
  include BGP::OPT_PARM::CAP
  def test_1
    assert_equal('02024300',Dynamic.new.to_shex)
  end
  def test_2
    assert_equal '02024300', Dynamic.new.to_shex
  end
  # draft-ietf-idr-dynamic-cap-19 section 9: the Dynamic Capability
  # capability is code 67 with no value, so RFC 5492 section 4 makes it
  # a code and a zero length inside the Capabilities parameter. Dynamic
  # capability has no RFC; the draft is the only specification, and IANA
  # registers 67 citing draft-ietf-idr-dynamic-cap-13.
  def test_to_s
    assert_equal("Option Capabilities Advertisement (2): [02024300]\n" +
                 '    Dynamic Capability 67, length: 2', Dynamic.new.to_s)
  end
  def test_default_code
    assert_equal CAP_DYNAMIC, Dynamic.new.to_hash[:code]
    assert_equal({:code=>67}, Dynamic.new.to_hash)
  end
  def test_wire_round_trip
    cap = Capability.factory(['02024300'].pack('H*'))
    assert_instance_of(Dynamic, cap)
    assert_equal '02024300', cap.to_shex
    assert_equal Dynamic.new.to_s, cap.to_s
  end
end
