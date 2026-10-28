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

  # The capability carries no value, so there is nothing to build from
  # field values but the code. All three paths have to work even so, and
  # the wire path used to be the broken one: the factory handed this class
  # the capability code rather than the octets, and handed the octets
  # directly it put the String in @code, so to_hash carried a String.
  def test_the_three_build_paths
    from_fields = BGP::OPT_PARM::CAP::Dynamic.new
    from_wire   = BGP::OPT_PARM::CAP::Dynamic.new(['02024300'].pack('H*'))
    from_hash   = BGP::OPT_PARM::CAP::Dynamic.new(from_fields.to_hash)
    [from_fields, from_wire, from_hash].each do |cap|
      assert_equal '02024300', cap.to_shex
      assert_equal({ :code => 67 }, cap.to_hash)
    end
  end

  # Nothing is validated on either side: the draft gives the capability no
  # value, so octets that arrive anyway are kept and written back.
  def test_a_value_the_draft_does_not_allow_is_kept
    wire = '0203' + '43' + '01' + 'ff'
    cap = BGP::OPT_PARM::CAP::Dynamic.new([wire].pack('H*'))
    assert_equal wire, cap.to_shex, 'byte for byte what arrived'
    assert_equal({ :code => 67, :value => 'ff' }, cap.to_hash)
    assert_equal wire, BGP::OPT_PARM::CAP::Dynamic.new(cap.to_hash).to_shex
    assert_match(/length: 3/, cap.to_s)
  end

  def test_the_factory_keeps_a_value
    cap = BGP::OPT_PARM::Capability.factory(['020343 01 ff'.delete(' ')].pack('H*'))
    assert_instance_of BGP::OPT_PARM::CAP::Dynamic, cap
    assert_equal '02034301ff', cap.to_shex
    assert_equal({ :code => 67, :value => 'ff' }, cap.to_hash)
  end

end
