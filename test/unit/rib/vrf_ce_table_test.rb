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

# BGP:: names are written out in full here, see Conventions in CLAUDE.md.
# A PE in AS 65000 with CEs in VRF A: docs/design/l3vpn-pe.md, pull
# request 7.
class TestBgpRibVrfCeTable < Test::Unit::TestCase

  def setup
    @table = BGP::Rib::VrfCeTable.new(local_as: 65000, router_id: '10.255.0.1')
  end

  def peer(address, as = 65101)
    BGP::Rib::Peer.new(:address => address, :remote_as => as, :router_id => address, :local_as => 65000)
  end

  # What a CE's UPDATE gives PeerAdapter#operations: a route, encoded and
  # parsed back.
  def route(prefix, from, path: [65101], med: nil)
    attrs = [BGP::Origin.new(0), BGP::As_path.new(*path), BGP::Next_hop.new(from)]
    attrs << BGP::Multi_exit_disc.new(med) if med
    pa = BGP::Update.new(BGP::Update.new(BGP::Path_attribute.new(*attrs), BGP::Nlri.new(prefix)).encode).path_attribute
    BGP::Rib::Route.new(prefix, pa, peer(from, path.first || 65000))
  end

  def announce(vrf, from, prefix, **opts)
    @table.apply(vrf, from, [[:announce, route(prefix, from, **opts)]])
  end

  def test_a_ce_route_is_in_its_vrf_only
    announce('A', '192.168.1.2', '172.16.1.0/24')
    assert_equal([['A', '172.16.1.0/24', '192.168.1.2', '65101']],
                 @table.best('A').collect { |b| [b.vrf, b.prefix, b.peer, b.route.as_path] })
    assert_equal([], @table.best('B'))
    assert_equal(1, @table.size('A'))
  end

  # What one CE sent into one VRF, for show.peers.
  def test_received_counts_one_ces_routes_in_one_vrf
    announce('A', '192.168.1.2', '172.16.1.0/24')
    announce('A', '192.168.1.2', '172.16.11.0/24')
    announce('A', '192.168.3.2', '172.16.3.0/24')
    assert_equal(2, @table.received('A', '192.168.1.2'))
    assert_equal(1, @table.received('A', '192.168.3.2'))
    assert_equal(0, @table.received('B', '192.168.1.2'))
    assert_equal(3, @table.size, 'asking about B added nothing')
  end

  # Two CEs of one VRF with one prefix: the decision process picks.
  def test_one_best_per_prefix_across_the_vrfs_ces
    announce('A', '192.168.1.2', '172.16.1.0/24', path: [65101, 65201])
    announce('A', '192.168.3.2', '172.16.1.0/24', path: [65103])
    assert_equal(['192.168.3.2'], @table.best('A').collect(&:peer), 'the shorter AS_PATH')
  end

  # RFC 4271 section 9.1.2: a route holding our AS is not used.
  def test_a_route_with_our_as_is_passed_over
    announce('A', '192.168.1.2', '172.16.9.0/24', path: [65101, 65000])
    assert_equal([], @table.best('A'))
    assert_equal(1, @table.size('A'), 'still held, as an Adj-RIB-In holds it')
  end

  def test_a_withdrawal_and_a_session_ending
    announce('A', '192.168.1.2', '172.16.1.0/24')
    announce('A', '192.168.1.2', '172.16.2.0/24')
    @table.apply('A', '192.168.1.2', [[:withdraw, peer('192.168.1.2'), '172.16.1.0/24', nil]])
    assert_equal(['172.16.2.0/24'], @table.best('A').collect(&:prefix))
    @table.peer_down('A', '192.168.1.2')
    assert_equal(0, @table.size)
  end

  def test_every_change_is_heard
    n = 0
    @table.on_change { n += 1 }
    announce('A', '192.168.1.2', '172.16.1.0/24')
    @table.peer_down('A', '192.168.1.2')
    assert_equal(2, n)
  end

  # The sink PeerAdapter feeds, with the work items it sends.
  def test_the_sink_takes_what_a_peer_adapter_sends
    sink = BGP::Rib::VrfCeTable::Sink.new(@table, 'A')
    n = Struct.new(:remote_addr).new('192.168.1.2')
    sink << [:ops, [[:announce, route('172.16.1.0/24', '192.168.1.2')]], n]
    assert_equal(1, @table.size('A'))
    sink << [:peer_down, peer('192.168.1.2')]
    assert_equal(0, @table.size('A'))
  end

  def test_as_numbers_and_site_of_origin
    assert_equal([65101, 65201], BGP::Rib::VrfCeTable.as_numbers(route('172.16.1.0/24', '192.168.1.2', path: [65101, 65201])))
    assert_equal([], BGP::Rib::VrfCeTable.as_numbers(route('172.16.1.0/24', '192.168.1.2', path: [])))
    pa = BGP::Path_attribute.new(BGP::Origin.new(0), BGP::As_path.new,
                                 BGP::Extended_communities.new(BGP::Route_target.new(65000, 100), BGP::Route_origin.new(65000, 11)))
    with = BGP::Rib::Route.new('172.16.1.0/24', pa, peer('10.255.0.3', 65000))
    assert_equal('65000:11', BGP::Rib::VrfCeTable.soo_of(with))
    assert_nil(BGP::Rib::VrfCeTable.soo_of(route('172.16.1.0/24', '192.168.1.2')))
  end

  # RFC 7313 section 4 for a CE: one AFI of one CE in one VRF.
  def test_stale_routes
    announce('A', '192.168.1.2', '172.16.1.0/24')
    announce('A', '192.168.1.2', '172.16.2.0/24')
    announce('A', '192.168.1.3', '172.16.3.0/24')
    assert_equal(2, @table.mark_stale('A', '192.168.1.2', 1))
    assert_equal(0, @table.mark_stale('A', '192.168.1.2', 2), 'no IPv6 from it')
    assert_equal('refresh', @table.stale('A', '192.168.1.2', '172.16.2.0/24'))
    announce('A', '192.168.1.2', '172.16.1.0/24')
    assert_nil(@table.stale('A', '192.168.1.2', '172.16.1.0/24'))
    assert_equal(1, @table.stale_size('A', '192.168.1.2'))
    assert_equal(1, @table.purge_stale('A', '192.168.1.2', 1))
    assert_equal(%w[172.16.1.0/24 172.16.3.0/24], @table.best('A').collect(&:prefix))
    @table.mark_stale('A', '192.168.1.3', 1)
    assert_equal(0, @table.purge_stale('A', '192.168.1.2', 1), 'the other CE\'s marks are its own')
    assert_equal([0, 1], [@table.stale_size('A', '192.168.1.2'), @table.stale_size('A', '192.168.1.3')])
    @table.peer_down('A', '192.168.1.3')
    assert_equal(0, @table.stale_size('A', '192.168.1.3'), 'a closed session leaves no mark')
  end
end
