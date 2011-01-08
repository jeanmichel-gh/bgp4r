#--
# Copyright 2011 Jean-Michel Esnault.
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
require 'bgp4r'
require "bgp/optional_parameters/add_path"

class TestBgpOptionalParametersAddPath < Test::Unit::TestCase
  include BGP::OPT_PARM::CAP
  def test_1
    ap = Add_path.new
    ap.add( :send, 1, 1)
    assert_equal '0206450400010101', ap.to_shex
    ap.add( :recv, 2, 128)
    assert_equal '020a45080001010100028002', ap.to_shex
    ap.add :send_and_receive, :ipv6, :unicast
    assert_equal '020e450c000101010002010300028002', ap.to_shex
  end
  def test_2
    ap = Add_path.new
    ap.add( :send, 1, 1)
    ap.add( :send, 2, 128)
    assert_match( /AFI IPv6 \(2\), SAFI Labeled VPN Unicast \(128\), SEND \(1\)/, ap.to_s)
    assert_match( /AFI IPv4 \(1\), SAFI Unicast \(1\), SEND \(1\)/, ap.to_s)
  end
  def test_3
    ap1 = Add_path.new_array [[1, 1 ,2 ], [2, 10, 10]]
    ap2 = Add_path.new_array [[:send, :ipv4 ,:multicast], [:recv, 10, 10]]
    assert_equal ap1.to_shex, ap2.to_shex
  end
  def test_4
    speaker = Add_path.new :send, 1, 1
    assert speaker.agrees_to? :send, 1, 1
    assert ! speaker.agrees_to?(:recv, 1, 1), "speaker should not agree to recv afi 1 safi 1"
    peer = Add_path.new :recv, 1, 1
    assert peer.agrees_to?(:recv, 1, 1), "peer should agree to recv afi 1 safi 1"
    assert include_path_id?(speaker, peer, :send, 1, 1), "route should include path id for afi 1 safi 1!"
    assert ! include_path_id?(speaker, peer, :send, 1, 2), "route should include path id for afi 1 safi 2 !"
    peer.add :recv, 1, 2
    assert ! include_path_id?(speaker, peer, :send, 1, 2), "route should include path id for afi 1 safi 2 !"
    assert ! speaker.agrees_to?(:send, 1, 2)
    speaker.add :send, 1,2
    assert speaker.agrees_to?(:send, 1, 2)
    assert include_path_id?(speaker, peer, :send, 1, 2), "route should include path id for afi 1 safi 2 !"
  end
end

__END__


add_path_cap = BGP::OPT_PARM::CAP::Add_path.new
add_path_cap.add :send, 1, 1
add_path_cap.add :recv, 2, 128
add_path_cap.add :send_and_receive, :ipv6, :unicast

> puts add_path_cap
Option Capabilities Advertisement (2): [020e450c000101010002010300028002]
    Add-path Extension (69), length: 4
        AFI IPv6 (2), SAFI Unicast (1), SEND_AND_RECV (3)
        AFI IPv4 (1), SAFI Unicast (1), SEND (1)
        AFI IPv6 (2), SAFI Labeled VPN Unicast (128), RECV (2)

