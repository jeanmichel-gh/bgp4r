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
require 'bgp/nlris/mapped_ipv4'

class Ipv4_mapped_Test < Test::Unit::TestCase
  include BGP
  # RFC 4291 section 2.5.5.2: an IPv4 address inside an IPv6 one is
  # 80 zero bits, 16 one bits, then the 4 octets. An MP_REACH next hop
  # for an IPv4 prefix over an IPv6 session is written that way
  # (RFC 8950 section 3).
  def test_encode
    assert_equal '00000000000000000000ffff01020304',
                 Ipv4_mapped.new('1.2.3.4').encode.unpack('H*')[0]
    assert_equal '00000000000000000000ffff0a000001',
                 Ipv4_mapped.new('10.0.0.1').encode.unpack('H*')[0]
    assert_equal 16, Ipv4_mapped.new('1.2.3.4').encode.size
  end
  def test_encode_next_hop_is_the_same_encoding
    nh = Ipv4_mapped.new('1.2.3.4')
    assert_equal nh.encode, nh.encode_next_hop
  end
  def test_nexthop_names_the_ipv4_address
    assert_equal '1.2.3.4', Ipv4_mapped.new('1.2.3.4').nexthop
    assert_equal '10.0.0.1', Ipv4_mapped.new('10.0.0.1').nexthop
    assert_equal Ipv4_mapped.new('1.2.3.4').to_s, Ipv4_mapped.new('1.2.3.4').nexthop
  end
  def test_only_ipv4_addresses
    # The encoding has nowhere to put an IPv6 address, so one is refused
    # rather than silently written as something else.
    assert_raise(RuntimeError) { Ipv4_mapped.new('2011:1::1') }
  end
  def test_it_is_an_ipaddr
    nh = Ipv4_mapped.new('1.2.3.4')
    assert_kind_of(IPAddr, nh)
    assert_equal true, nh.ipv4?
    assert_equal 'c0a80001', Ipv4_mapped.new('192.168.0.1').hton.unpack('H*')[0]
  end
end
