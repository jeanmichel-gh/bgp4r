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
require 'bgp/rib'

class TestBgpRibRoute < Test::Unit::TestCase
  include BGP
  include BGP::Rib

  def peer(addr='10.0.0.2', as=65002)
    Peer.new(address: addr, remote_as: as, router_id: '2.2.2.2', local_as: 65001)
  end

  def path(*segments)
    As_path.new(*segments.map { |type, *ases| As_path::Segment.new(type, *ases) })
  end

  def test_peer
    p1 = peer
    assert p1.ebgp?
    assert !p1.ibgp?
    assert peer('10.0.0.3', 65001).ibgp?
    assert_equal(p1, peer('10.0.0.2', 65002))
    assert_equal(1, [p1, peer].uniq.size)
    assert_equal('10.0.0.2 AS65002', p1.to_s)
    assert p1.frozen?
  end

  def test_prefix_is_normalized_and_keyed
    r = Route.new('192.168.1.7/24', nil, peer)
    assert_equal('192.168.1.0/24', r.prefix)
    assert_equal(['192.168.1.0/24', nil], r.key)
    assert_equal(['2001:db8::/32', 7], Route.new('2001:db8::1/32', nil, peer, path_id: 7).key)
    assert_equal(1, r.afi)
    assert_equal(2, Route.new('2001:db8::/32', nil, peer).afi)
    assert r.frozen?
  end

  def test_attributes
    pa = Path_attribute.new(Origin.new(1), Next_hop.new('10.0.0.2'), Multi_exit_disc.new(20),
                            Local_pref.new(200), Originator_id.new('9.9.9.9'),
                            Cluster_list.new('1.1.1.1', '3.3.3.3'), As_path.new(65002, 65003))
    r = Route.new('10.1.0.0/16', pa, peer)
    assert_equal(1, r.origin)
    assert_equal('10.0.0.2', r.next_hop)
    assert_equal(20, r.med)
    assert_equal(200, r.local_pref)
    assert_equal('9.9.9.9', r.originator_id)
    assert_equal(['1.1.1.1', '3.3.3.3'], r.cluster_list)
    assert_equal('65002 65003', r.as_path)
    assert_equal('9.9.9.9', r.router_id, 'ORIGINATOR_ID replaces the router ID (RFC 4456 section 9)')
  end

  def test_missing_attributes
    r = Route.new('10.1.0.0/16', nil, peer)
    [:origin, :next_hop, :med, :local_pref, :originator_id].each { |m| assert_nil(r.send(m), m.to_s) }
    assert_equal([], r.cluster_list)
    assert_equal([], r.as_path_segments)
    assert_equal('empty', r.as_path)
    assert_equal(0, r.as_path_length)
    assert_equal('2.2.2.2', r.router_id)
  end

  def test_next_hop_from_mp_reach
    pa = Path_attribute.new(Mp_reach.new(:afi=>2, :safi=>1, :nexthop=>['2001:db8::1'], :nlris=>['2001:db8:1::/48']))
    assert_equal('2001:db8::1', Route.new('2001:db8:1::/48', pa, peer).next_hop)
  end

  def test_as_path_length_counts_a_set_as_one
    # RFC 4271 section 9.1.2.2 a).
    r = Route.new('10.0.0.0/8', Path_attribute.new(path([:sequence, 1, 2, 3], [:set, 4, 5, 6])), peer)
    assert_equal(4, r.as_path_length)
  end

  def test_as_path_length_skips_confederation_segments
    # RFC 5065 section 5.3.
    r = Route.new('10.0.0.0/8', Path_attribute.new(path([:confed_sequence, 65010, 65011], [:sequence, 1, 2])), peer)
    assert_equal(2, r.as_path_length)
  end

  def test_as_path_include
    r = Route.new('10.0.0.0/8', Path_attribute.new(path([:confed_sequence, 65001], [:sequence, 1], [:set, 2, 3])), peer)
    assert r.as_path_include?(1)
    assert r.as_path_include?(3)
    assert !r.as_path_include?(65001), 'confederation members are not an AS loop'
  end

  def test_neighbor_as
    # RFC 4271 section 9.1.2.2 c): the first AS of the path, else our AS.
    assert_equal(65002, Route.new('10.0.0.0/8', Path_attribute.new(As_path.new(65002, 3)), peer).neighbor_as)
    assert_equal(65001, Route.new('10.0.0.0/8', Path_attribute.new(As_path.new), peer('10.0.0.3', 65001)).neighbor_as)
    assert_equal(65001, Route.new('10.0.0.0/8', Path_attribute.new(path([:set, 4, 5])), peer).neighbor_as)
    confed = Path_attribute.new(path([:confed_sequence, 65010], [:sequence, 7, 8]))
    assert_equal(7, Route.new('10.0.0.0/8', confed, peer).neighbor_as)
  end

  def test_parsed_from_the_wire
    pa = Path_attribute.new(Origin.new(0), Next_hop.new('10.0.0.2'),
                            As_path.new(As_path::Segment.new(:sequence, 65002), As_path::Segment.new(:set, 1, 2)))
    m = Message.factory(Update.new(pa, Nlri.new('10.1.0.0/16')).encode)
    r = Route.new(m.nlri.to_ary.first, m.path_attribute, peer)
    assert_equal('10.1.0.0/16', r.prefix)
    assert_equal(2, r.as_path_length)
    assert_equal(65002, r.neighbor_as)
  end

  def test_bad_arguments
    assert_raise(ArgumentError) { Route.new('10.0.0.0/8', nil, '10.0.0.2') }
    assert_raise(IPAddr::InvalidAddressError) { Route.new('not a prefix', nil, peer) }
  end

  def test_to_s
    pa = Path_attribute.new(Next_hop.new('10.0.0.2'), As_path.new(65002))
    assert_equal('ID=3, 10.1.0.0/16 via 10.0.0.2 from 10.0.0.2 AS65002 path 65002',
                 Route.new('10.1.0.0/16', pa, peer, path_id: 3).to_s)
  end

  def test_same_path
    pa = Path_attribute.new(Origin.new(0), Next_hop.new('10.0.0.2'), As_path.new(65002))
    a = Route.new('10.1.0.0/16', pa, peer)
    assert a.same_path?(Route.new('10.1.0.0/16', Path_attribute.new(pa.encode(true), true), peer))
    assert !a.same_path?(Route.new('10.1.0.0/16', pa, peer('10.0.0.9')))
    assert !a.same_path?(Route.new('10.1.0.0/16', pa, peer, path_id: 1))
    assert !a.same_path?(Route.new('10.2.0.0/16', pa, peer))
    assert !a.same_path?(Route.new('10.1.0.0/16', Path_attribute.new(Origin.new(1), Next_hop.new('10.0.0.2'), As_path.new(65002)), peer))
    assert !a.same_path?(nil)
  end

  def test_with_path_attribute
    a = Route.new('10.1.0.0/16', nil, peer, path_id: 4)
    b = a.with_path_attribute(Path_attribute.new(Origin.new(2)))
    assert_equal(2, b.origin)
    assert_nil(a.origin)
    assert_equal(a.key, b.key)
    assert_equal(a.peer, b.peer)
  end
end
