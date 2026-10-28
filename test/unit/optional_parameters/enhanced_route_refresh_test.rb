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

class Enhanced_route_refresh_cap_Test < Test::Unit::TestCase

  # RFC 7313 section 3.1: "IANA has assigned a Capability Code of 70 for
  # this capability" and "The Capability Length field of this capability is
  # zero." So the capability is 46 00 behind the RFC 5492 section 4
  # optional parameter header, exactly the shape of CAP::Route_refresh.
  WIRE = '02024600'

  def test_the_capability_code_is_70_and_the_length_is_zero
    assert_equal 70, BGP::OPT_PARM::CAP_ENHANCED_ROUTE_REFRESH
    cap = BGP::OPT_PARM::CAP::Enhanced_route_refresh.new
    assert_equal WIRE, cap.to_shex
    assert_equal 70, cap.to_hash[:code]
    # the value is zero octets: the whole capability is the two octet
    # code and length
    assert_equal 4, cap.encode.size
  end

  def test_the_three_build_paths
    from_fields = BGP::OPT_PARM::CAP::Enhanced_route_refresh.new
    from_wire   = BGP::OPT_PARM::CAP::Enhanced_route_refresh.new([WIRE].pack('H*'))
    from_hash   = BGP::OPT_PARM::CAP::Enhanced_route_refresh.new(from_fields.to_hash)
    [from_fields, from_wire, from_hash].each do |cap|
      assert_equal WIRE, cap.to_shex
      assert_equal({:code=>70}, cap.to_hash)
    end
  end

  def test_the_factory_reads_it
    cap = BGP::OPT_PARM::Capability.factory([WIRE].pack('H*'))
    assert_instance_of BGP::OPT_PARM::CAP::Enhanced_route_refresh, cap
    assert_equal WIRE, cap.to_shex
    assert_equal({:code=>70}, cap.to_hash)
  end

  # draft-ietf-idr-dynamic-cap-19 section 3: in a Capability message the
  # capability has a one octet code and a two octet length, so the DYN_CAP
  # class generated from this one writes 46 0000.
  def test_the_dynamic_factory_reads_it
    cap = BGP::OPT_PARM::Capability.dynamic_factory(['460000'].pack('H*'))
    assert_instance_of BGP::OPT_PARM::DYN_CAP::Enhanced_route_refresh, cap
    assert_equal '460000', cap.to_shex
    assert_equal '460000', BGP::OPT_PARM::DYN_CAP::Enhanced_route_refresh.new.to_shex
  end

  def test_to_s
    assert_equal "Option Capabilities Advertisement (2): [#{WIRE}]\n" +
                 '    Enhanced Route Refresh (70), length: 2',
                 BGP::OPT_PARM::CAP::Enhanced_route_refresh.new.to_s
    assert_equal 'Enhanced route refresh (70)',
                 BGP::OPT_PARM::CAP::Enhanced_route_refresh.new.to_s_brief
  end

  # Nothing is validated on the way out, and nothing read off the wire is
  # dropped. RFC 7313 section 3.1 gives the capability a zero length, so a
  # value is wrong by the RFC, but an implementation that sends one has to
  # be readable: the octets are kept and written back.
  def test_a_value_the_rfc_does_not_allow_is_kept
    s = '02046402' + 'aabb'
    cap = BGP::OPT_PARM::CAP::Enhanced_route_refresh.new(0x64)
    assert_equal '02026400', cap.to_shex
    with_value = BGP::OPT_PARM::CAP::Enhanced_route_refresh.new(
      ['020446' + '02' + 'aabb'].pack('H*'))
    assert_equal '02044602aabb', with_value.to_shex
    assert_equal({:code=>70, :value=>'aabb'}, with_value.to_hash)
    assert_equal '02044602aabb',
                 BGP::OPT_PARM::CAP::Enhanced_route_refresh.new(with_value.to_hash).to_shex
    assert_match(/length: 4/, with_value.to_s)
    assert_equal s, BGP::OPT_PARM::CAP::Enhanced_route_refresh.new(
      :code=>0x64, :value=>'aabb').to_shex
  end

  # An Open carries it like any other capability.
  def test_in_an_open_message
    open = BGP::Open.new(4, 100, 200, '10.0.0.1',
                         BGP::OPT_PARM::CAP::Enhanced_route_refresh.new)
    back = BGP::Message.factory(open.encode)
    assert_equal open.to_shex, back.to_shex
    assert back.find(BGP::OPT_PARM::CAP::Enhanced_route_refresh),
           'the enhanced route refresh capability reads back out of an OPEN'
  end
end
