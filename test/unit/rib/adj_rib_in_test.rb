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

class TestBgpRibAdjRibIn < Test::Unit::TestCase
  include BGP
  include BGP::Rib

  PEER = Peer.new(address: '10.0.0.2', remote_as: 65002, router_id: '2.2.2.2', local_as: 65001)
  OTHER = Peer.new(address: '10.0.0.3', remote_as: 65003, router_id: '3.3.3.3', local_as: 65001)

  def route(prefix, med: 0, path_id: nil, peer: PEER)
    Route.new(prefix, Path_attribute.new(Origin.new(0), Multi_exit_disc.new(med)), peer, path_id: path_id)
  end

  def setup
    @rib = AdjRibIn.new(PEER)
  end

  def test_announce_and_lookup
    r = route('10.1.0.0/16')
    assert_nil(@rib.announce(r))
    assert_same(r, @rib['10.1.0.0/16'])
    assert_same(r, @rib['10.1.0.9/16'], 'lookups normalize the prefix')
    assert_equal(1, @rib.size)
    assert_equal(['10.1.0.0/16'], @rib.prefixes)
  end

  def test_announce_replaces_implicitly
    # RFC 4271 section 3.1: a new announcement withdraws the old one.
    a, b = route('10.1.0.0/16', med: 1), route('10.1.0.0/16', med: 2)
    @rib.announce(a)
    assert_same(a, @rib.announce(b))
    assert_same(b, @rib['10.1.0.0/16'])
    assert_equal(1, @rib.size)
  end

  def test_withdraw
    r = route('10.1.0.0/16')
    @rib.announce(r)
    assert_same(r, @rib.withdraw('10.1.0.0/16'))
    assert_nil(@rib['10.1.0.0/16'])
    assert @rib.empty?
    assert_equal([], @rib.prefixes)
  end

  def test_withdraw_unknown_is_not_an_error
    assert_nil(@rib.withdraw('10.9.0.0/16'))
    @rib.announce(route('10.1.0.0/16', path_id: 1))
    assert_nil(@rib.withdraw('10.1.0.0/16'), 'path ID nil is not path ID 1')
    assert_equal(1, @rib.size)
  end

  def test_add_path_keeps_paths_apart
    # RFC 7911: one peer, one prefix, two paths.
    a, b = route('10.1.0.0/16', path_id: 1), route('10.1.0.0/16', path_id: 2)
    @rib.announce(a)
    @rib.announce(b)
    assert_equal(2, @rib.size)
    assert_equal([a, b], @rib.paths('10.1.0.0/16'))
    assert_same(a, @rib.withdraw('10.1.0.0/16', 1))
    assert_equal([b], @rib.paths('10.1.0.0/16'))
  end

  def test_flush
    rs = [route('10.1.0.0/16'), route('10.2.0.0/16'), route('10.2.0.0/16', path_id: 5)]
    rs.each { |r| @rib.announce(r) }
    assert_equal(rs, @rib.flush)
    assert @rib.empty?
    assert_equal([], @rib.routes)
  end

  def test_route_from_another_peer_is_refused
    assert_raise(ArgumentError) { @rib.announce(route('10.1.0.0/16', peer: OTHER)) }
  end
end
