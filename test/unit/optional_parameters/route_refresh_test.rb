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

  # The capability carries no value, so there is nothing to build from
  # field values but the code. All three paths have to work even so, and
  # the wire path used to be the broken one: the factory handed this class
  # the capability code rather than the octets, and handed the octets
  # directly it put the String in @code and took encode down.
  def test_the_three_build_paths
    from_fields = BGP::OPT_PARM::CAP::Route_refresh.new
    from_wire   = BGP::OPT_PARM::CAP::Route_refresh.new(['02020200'].pack('H*'))
    from_hash   = BGP::OPT_PARM::CAP::Route_refresh.new(from_fields.to_hash)
    [from_fields, from_wire, from_hash].each do |cap|
      assert_equal '02020200', cap.to_shex
      assert_equal({ :code => 2 }, cap.to_hash)
    end
    # And the Cisco code through each of them.
    assert_equal '02028000', BGP::OPT_PARM::CAP::Route_refresh.new(128).to_shex
    assert_equal '02028000', BGP::OPT_PARM::CAP::Route_refresh.new(['02028000'].pack('H*')).to_shex
    assert_equal '02028000', BGP::OPT_PARM::CAP::Route_refresh.new(:code => 128).to_shex
  end

  # RFC 2918 section 3 gives the capability a zero length, so a value is
  # wrong by the RFC. An implementation that sends one still has to be
  # readable: the octets are kept and written back rather than dropped.
  def test_a_value_the_rfc_does_not_allow_is_kept
    wire = '0203' + '02' + '01' + '41'
    cap = BGP::OPT_PARM::CAP::Route_refresh.new([wire].pack('H*'))
    assert_equal wire, cap.to_shex, 'byte for byte what arrived'
    assert_equal({ :code => 2, :value => '41' }, cap.to_hash)
    assert_equal wire, BGP::OPT_PARM::CAP::Route_refresh.new(cap.to_hash).to_shex
    assert_match(/length: 3/, cap.to_s)
    assert_equal '41', cap.value.unpack1('H*')
  end

  # The factory used to hand this class the capability code, so the 41
  # above reached nothing and no complaint was made about it either.
  def test_the_factory_keeps_a_value
    cap = BGP::OPT_PARM::Capability.factory(['0203020141'].pack('H*'))
    assert_instance_of BGP::OPT_PARM::CAP::Route_refresh, cap
    assert_equal '0203020141', cap.to_shex
    assert_equal({ :code => 2, :value => '41' }, cap.to_hash)
    cisco = BGP::OPT_PARM::Capability.factory(['02028000'].pack('H*'))
    assert_instance_of BGP::OPT_PARM::CAP::Route_refresh, cisco
    assert_equal 128, cisco.to_hash[:code]
  end

  # draft-ietf-idr-dynamic-cap-19 section 3: in a Capability message the
  # capability has a one octet code and a two octet length, so the DYN_CAP
  # class generated from this one writes 02 0000.
  def test_the_dynamic_factory_keeps_a_value
    cap = BGP::OPT_PARM::Capability.dynamic_factory(['020000'].pack('H*'))
    assert_instance_of BGP::OPT_PARM::DYN_CAP::Route_refresh, cap
    assert_equal '020000', cap.to_shex
    with_value = BGP::OPT_PARM::Capability.dynamic_factory(['02000141'].pack('H*'))
    assert_equal '02000141', with_value.to_shex
    assert_equal({ :code => 2, :value => '41' }, with_value.to_hash)
  end

end
