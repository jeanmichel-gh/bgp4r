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

class TestBgpOptionalParametersExtendedNexthop < Test::Unit::TestCase
  include BGP::OPT_PARM
  include BGP::OPT_PARM::CAP

  # RFC 8950 has no hex capture. These follow the section 4 layout:
  # optional parameter 2, length, capability code 5, length, then
  # <NLRI AFI (2), NLRI SAFI (2), Nexthop AFI (2)> triples.
  ONE = '0208' + '0506' + '000100010002'
  TWO = '020e' + '050c' + '000100010002' + '000100800002'

  def test_from_fields
    assert_equal(ONE, Extended_nexthop.new(1, 1, 2).to_shex)
    assert_equal(ONE, Extended_nexthop.new(:ipv4, :unicast, :ipv6).to_shex)
    assert_equal(TWO, Extended_nexthop.new([1, 1, 2], [1, 128, 2]).to_shex)
    cap = Extended_nexthop.new(1, 1, 2)
    cap.add(1, 128)
    assert_equal(TWO, cap.to_shex)
    cap.add(1, 128, 2)
    assert_equal(TWO, cap.to_shex, 'a family is listed once')
  end

  def test_from_wire_bytes
    cap = Extended_nexthop.new([TWO].pack('H*'))
    assert_equal([[1, 1, 2], [1, 128, 2]], cap.families)
    assert_equal(TWO, cap.to_shex)
    assert_instance_of(Extended_nexthop, Capability.factory([TWO].pack('H*')))
  end

  def test_from_hash
    cap = Extended_nexthop.new([1, 1, 2], [1, 128, 2])
    h = {:code=>5, :capability=>{:families=>[{:afi=>1, :safi=>1, :nexthop_afi=>2},
                                             {:afi=>1, :safi=>128, :nexthop_afi=>2}]}}
    assert_equal(h, cap.to_hash)
    assert_equal(TWO, Extended_nexthop.new(h).to_shex)
    assert_equal(TWO, Extended_nexthop.new(h[:capability]).to_shex)
  end

  def test_has
    cap = Extended_nexthop.new(1, 1, 2)
    assert(cap.has?(1, 1))
    assert(cap.has?(:ipv4, :unicast, :ipv6))
    assert(!cap.has?(1, 128))
  end

  def test_to_s
    assert_match(/Extended Next Hop Encoding \(5\).*\n.*AFI IPv4 \(1\), SAFI Unicast \(1\), Nexthop AFI IPv6 \(2\)/,
                 Extended_nexthop.new(1, 1, 2).to_s)
  end

  def test_in_an_open_message
    o = BGP::Open.new(4, 100, 180, '10.0.0.1', Extended_nexthop.new(1, 1, 2))
    o2 = BGP::Message.factory(o.encode)
    assert_equal(o.to_shex, o2.to_shex)
    assert(o2.find(Extended_nexthop).has?(1, 1, 2))
  end

  def test_bad_arguments
    assert_raise(ArgumentError) { Extended_nexthop.new(1, 1) }
    assert_raise(ArgumentError) { Extended_nexthop.new(1, 0x10000, 2) }
    assert_raise(ArgumentError) { Extended_nexthop.new(1, :bogus, 2) }
    e = assert_raise(ArgumentError) { Extended_nexthop.new(['0207050500010001 00'.delete(' ')].pack('H*')) }
    assert_match(/multiple of 6/, e.message)
  end

  # The long form used to interpolate a nil for a family IANA does not
  # name, where to_s_brief already fell back to the number.
  def test_an_unnamed_address_family_prints_its_number
    cap = Extended_nexthop.new(999, 77, 888)
    assert_match(/AFI 999, SAFI 77, Nexthop AFI 888/, cap.to_s)
    assert_equal('Extended Next Hop 999, 77 via 888', cap.to_s_brief)
    assert_match(/AFI IPv4 \(1\), SAFI Unicast \(1\), Nexthop AFI IPv6 \(2\)/,
                 Extended_nexthop.new(1, 1, 2).to_s)
  end
end
