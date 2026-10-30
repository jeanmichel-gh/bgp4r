#--
# Copyright 2008, 2009, 2010, 2026 Jean-Michel Esnault.
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

require 'bgp/nlris/nlris'
require 'test/unit'

class Inet_unicast_Test < Test::Unit::TestCase
  include BGP
  def test_1
    assert_equal(1,Inet_unicast.new('192.168.0.0/16').afi)
    assert_equal(1,Inet_unicast.new('192.168.0.0/16').safi)
    assert_equal(2,Inet_unicast.new('2009:4:4::/64').afi)
    assert_equal(1,Inet_unicast.new('2009:4:4::/64').safi)
  end
  # This round trip works, so Conventions requires a test to say so, and
  # its entry in test/unit/to_hash_catalog.rb records it. All three fields
  # the class carries are in the hash: the prefix, the RFC 7911 section 3
  # Path Identifier, and the tail a Length field too wide for its family
  # leaves over.
  def test_to_hash_round_trips
    n = BGP::Inet_unicast.new_ntop_extended(['00000064210102030405'].pack('H*').is_packed)
    assert_equal({:prefix=>'1.2.3.4/33', :path_id=>100, :tail=>'05'}, n.to_hash)
    assert_equal(n.encode, BGP::Inet_unicast.new(n.to_hash).encode)
  end
end
class Inet_multicast_Test < Test::Unit::TestCase
  include BGP
  def test_1
    assert_equal(1,Inet_multicast.new('192.168.0.0/16').afi)
    assert_equal(2,Inet_multicast.new('192.168.0.0/16').safi)
    assert_equal(2,Inet_multicast.new('2009:4:4::/64').afi)
    assert_equal(2,Inet_multicast.new('2009:4:4::/64').safi)
  end
  # As above, and for the same reason. The two classes differ only in the
  # safi they answer, so the round trip is the one Prefix gives them, but
  # a working round trip needs a test whether it was inherited or not.
  def test_to_hash_round_trips
    n = BGP::Inet_multicast.new_ntop_extended(['00000064210102030405'].pack('H*').is_packed)
    assert_equal({:prefix=>'1.2.3.4/33', :path_id=>100, :tail=>'05'}, n.to_hash)
    assert_equal(n.encode, BGP::Inet_multicast.new(n.to_hash).encode)
  end
end
