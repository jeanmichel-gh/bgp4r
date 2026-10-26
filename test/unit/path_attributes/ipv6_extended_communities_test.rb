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

require "test/unit"
require "bgp4r"

class TestIpv6ExtendedCommunities < Test::Unit::TestCase
  include BGP

  Comm = Ipv6_extended_communities::Ipv6_extended_community

  # RFC 5701 section 2: type 0x00, sub-type 0x02 (Route Target),
  # 2001:db8::1, local 100.
  RT = '0002' + '20010db8000000000000000000000001' + '0064'

  def wire(hex) [hex].pack('H*').is_packed end

  def test_value
    c = Comm.new(:route_target, '2001:db8::1', 100)
    assert_equal RT, c.encode.unpack1('H*')
    assert_equal [0, 2, '2001:db8::1', 100], c.to_a
    assert_equal :route_target, c.name
    assert c.transitive?
    assert_equal 'Route target: [2001:db8::1]:100', c.to_s
    assert_equal c, Comm.new(2, '2001:db8::1', 100)
    assert_equal c, Comm.new(c.encode)
    assert_equal c, Comm.new(c.to_hash)
  end

  def test_route_origin_and_type_octets
    assert_equal '0003', Comm.new(:route_origin, '2001:db8::1', 1).encode.unpack1('H*')[0, 4]
    c = Comm.new(:route_target, '2001:db8::1', 1, transitive: false)
    assert_equal '4002', c.encode.unpack1('H*')[0, 4]
    assert ! c.transitive?
    assert_equal 'Route target: [2001:db8::1]:1 (type 0x40)', c.to_s
    assert_equal 'ff09', Comm.new(9, '::1', 1, type: 0xff).encode.unpack1('H*')[0, 4]
  end

  def test_unknown_sub_types_round_trip
    hex = '4009' + 'fe800000000000000000000000000001' + 'ffff'
    c = Comm.new(wire(hex))
    assert_equal hex, c.encode.unpack1('H*')
    assert_nil c.name
    assert_equal 'Sub-type 0x09: [fe80::1]:65535 (type 0x40)', c.to_s
    assert_equal hex, Comm.new(c.to_hash).encode.unpack1('H*')
  end

  def test_bad_values_raise
    assert_raise(ArgumentError) { Comm.new(:route_target, '10.0.0.1', 1) }
    assert_raise(ArgumentError) { Comm.new(:route_target, 'not an address', 1) }
    assert_raise(ArgumentError) { Comm.new(:route_target, '2001:db8::1', 65536) }
    assert_raise(ArgumentError) { Comm.new(:route_target, '2001:db8::1', -1) }
    assert_raise(ArgumentError) { Comm.new(:color, '2001:db8::1', 1) }
    assert_raise(ArgumentError) { Comm.new(256, '2001:db8::1', 1) }
    assert_raise(ArgumentError) { Comm.new(2, '2001:db8::1', 1, type: 300) }
    assert_raise(ArgumentError) { Comm.new(2, '2001:db8::1') }
  end

  def test_attribute
    a = Ipv6_extended_communities.new([:route_target, '2001:db8::1', 100], [:route_origin, '2001:db8::2', 7])
    assert_equal 'c01928' + RT + '0003' + '20010db8000000000000000000000002' + '0007', a.to_shex
    assert_equal 2, a.size
    assert a.is_optional?
    assert a.is_transitive?
    assert a.has?([:route_target, '2001:db8::1', 100])
    assert ! a.has?([:route_target, '2001:db8::1', 101])
  end

  def test_from_wire
    a = Ipv6_extended_communities.new(wire('c01914' + RT))
    assert_equal 'c01914' + RT, a.to_shex
    assert_instance_of Ipv6_extended_communities, Attr.factory(wire('c01914' + RT))
  end

  def test_hash_round_trip
    a = Ipv6_extended_communities.new([:route_target, '2001:db8::1', 100], [9, 'fe80::1', 1])
    h = a.to_hash
    assert_equal({:ipv6_extended_communities => [
      {:type=>0, :subtype=>:route_target, :global_admin=>'2001:db8::1', :local_admin=>100},
      {:type=>0, :subtype=>9, :global_admin=>'fe80::1', :local_admin=>1}]}, h)
    assert_equal a.encode, Ipv6_extended_communities.new(h).encode
    pa = Path_attribute.new(:origin => :igp, :ipv6_extended_communities => h[:ipv6_extended_communities])
    assert_equal a.encode, pa[:ipv6_extended_communities].encode
    assert_equal pa.encode, Path_attribute.new(pa.to_hash).encode
    assert_instance_of Ipv6_extended_communities, pa[ATTR::IPV6_EXTENDED_COMMUNITY]
  end

  # RFC 7606 section 7.15: a length that is not a non-zero multiple of 20
  # is malformed, treat-as-withdraw. The octets are kept as received.
  def test_bad_length
    hex = 'c01915' + RT + '00'
    pa = Path_attribute.new(wire(hex))
    assert_equal [[25, 5, :treat_as_withdraw]], pa.errors.collect { |f| [f.type, f.subcode, f.action] }
    assert_equal hex, pa.encode.unpack1('H*')
    assert_equal 1, pa[:ipv6_extended_communities].size
    assert_equal [[25, 5, :treat_as_withdraw]], Path_attribute.new(wire('c01900')).errors.collect { |f| [f.type, f.subcode, f.action] }
    assert_equal [], Path_attribute.new(wire('c01914' + RT)).errors
  end

  def test_flags_are_checked
    pa = Path_attribute.new(wire('801914' + RT))
    assert_equal [[25, 4, :treat_as_withdraw]], pa.errors.collect { |f| [f.type, f.subcode, f.action] }
  end

end
