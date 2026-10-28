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
class TestBgpRibPeerFeed < Test::Unit::TestCase

  def setup
    @rib = BGP::Rib.new(:local_as => 65001, :router_id => '1.1.1.1')
    @changes = []
    @rib.on_change { |c| @changes << c }
    @neighbors = []
  end

  def teardown
    @rib.feed.stop if @rib
    @neighbors.each { |n| n.close }
  end

  # A Neighbor that has already read its peer's OPEN, which is what names
  # the peer (RFC 4271 section 4.2).
  def neighbor(last_octet = 2, as = 65002, id = nil)
    n = BGP::Neighbor.new(:my_as => 65001, :remote_addr => "10.0.0.#{last_octet}",
                          :local_addr => '10.0.0.1', :id => '1.1.1.1')
    n.instance_variable_set(:@rmt_as, as)
    n.instance_variable_set(:@rmt_bgp_id, id || "#{last_octet}.#{last_octet}.#{last_octet}.#{last_octet}")
    n.instance_variable_set(:@state, :Established)
    @neighbors << n
    n
  end

  # What BGP::Neighbor#dispatch_event does once a message is parsed: the
  # named rcv_ hook, then the observers. The adapter listens as an observer,
  # because rcv_update is a hook a subclass overrides and the table attaches
  # to a Neighbor it was handed. The functional test drives the real socket.
  def deliver(n, msg)
    n.changed
    n.notify_observers(msg)
  end

  def update(*prefixes, as: 65002, nexthop: '10.0.0.2', withdrawn: nil)
    args = []
    args << BGP::Withdrawn.new(*withdrawn) if withdrawn
    unless prefixes.empty?
      args << BGP::Path_attribute.new(BGP::Origin.new(0), BGP::Next_hop.new(nexthop),
                                      BGP::As_path.new(as))
      args << BGP::Nlri.new(*prefixes)
    end
    BGP::Update.new(*args)
  end

  def test_a_table_nobody_attached_to_runs_no_thread
    assert(!@rib.feed.running?)
    assert(@rib.drain, 'and draining it is not an error')
  end

  def test_attach_returns_one_adapter_per_neighbor
    n = neighbor
    a = @rib.attach(n)
    assert_kind_of(BGP::Rib::PeerAdapter, a)
    assert_same(a, @rib.attach(n), 'the same neighbor attaches once')
    assert_equal([n], @rib.feed.neighbors)
    assert(@rib.feed.running?, 'the first attach starts the worker')
  end

  def test_an_update_reaches_the_table
    n = neighbor
    @rib.attach(n)
    deliver(n, update('10.0.0.0/8', '192.168.1.0/24'))
    assert(@rib.drain, 'the worker applied it')
    assert_equal(2, @rib.loc_rib.size)
    assert_equal('10.0.0.2', @rib.best('10.0.0.0/8').next_hop)
    assert_equal(%w[10.0.0.0/8 192.168.1.0/24], @changes.map(&:prefix).sort)
  end

  # The worker runs behind the session, so a read without drain can be early.
  # The test asserts what drain is for, not a timing coincidence.
  def test_drain_is_what_makes_a_read_safe
    n = neighbor
    @rib.attach(n)
    50.times { |i| deliver(n, update("10.#{i}.0.0/16")) }
    assert(@rib.drain)
    assert_equal(50, @rib.loc_rib.size)
    assert_equal(0, @rib.feed.pending)
  end

  def test_a_withdrawal_reaches_the_table
    n = neighbor
    @rib.attach(n)
    deliver(n, update('10.0.0.0/8'))
    assert(@rib.drain)
    deliver(n, update(:withdrawn => ['10.0.0.0/8']))
    assert(@rib.drain)
    assert_equal(0, @rib.loc_rib.size)
    assert_equal([:added, :withdrawn], @changes.map(&:type))
  end

  # RFC 4271 section 9.1.2: the routes a peer sent go when its session does.
  def test_a_session_going_down_removes_its_routes
    n = neighbor
    @rib.attach(n)
    deliver(n, update('10.0.0.0/8', '10.1.0.0/16'))
    assert(@rib.drain)
    assert_equal(2, @rib.loc_rib.size)
    n.send(:new_state, :Idle, 'test')
    assert(@rib.drain)
    assert_equal(0, @rib.loc_rib.size)
    assert_equal(1, @rib.peers.size, 'the Adj-RIB-In stays, emptied')
    assert(@rib.adj_rib_in(@rib.peers.first).empty?)
  end

  def test_detach_removes_the_routes_and_stops_the_reporting
    n = neighbor
    @rib.attach(n)
    deliver(n, update('10.0.0.0/8'))
    assert(@rib.drain)
    @rib.detach(n)
    assert(@rib.drain)
    assert_equal(0, @rib.loc_rib.size)
    assert_equal([], @rib.feed.neighbors)
    assert_equal(0, n.count_observers)
    deliver(n, update('10.2.0.0/16'))
    assert(@rib.drain)
    assert_equal(0, @rib.loc_rib.size, 'nothing arrives after a detach')
  end

  def test_detach_of_an_unattached_neighbor_is_not_an_error
    assert_nil(@rib.detach(neighbor))
  end

  # Two sessions, one table, one worker. The decision runs over both.
  def test_two_neighbors_feed_one_table
    a = neighbor(2, 65002)
    b = neighbor(3, 65003)
    @rib.attach(a)
    @rib.attach(b)
    deliver(a, update('10.0.0.0/8', :as => 65002, :nexthop => '10.0.0.2'))
    deliver(b, update('10.0.0.0/8', :as => 65003, :nexthop => '10.0.0.3'))
    assert(@rib.drain)
    assert_equal(1, @rib.loc_rib.size)
    assert_equal(2, @rib.candidates('10.0.0.0/8').size, 'one path per peer')
    # Equal otherwise, so the lowest BGP Identifier wins (RFC 4271 9.1.2.2 f).
    assert_equal('2.2.2.2', @rib.best('10.0.0.0/8').router_id)
    assert_equal(2, @rib.feed.adapters.size, 'both are attached')
    @rib.detach(a)
    assert(@rib.drain)
    assert_equal('3.3.3.3', @rib.best('10.0.0.0/8').router_id, 'and the other takes over')
  end

  # The worker is the table's only one. A work item that raises must not
  # take it down, or every later UPDATE is lost in silence.
  def test_the_worker_survives_a_bad_work_item
    n = neighbor
    @rib.attach(n)
    @rib.feed << [:nonsense]
    assert(@rib.drain)
    assert_equal(1, @rib.feed.errors.size)
    assert_kind_of(ArgumentError, @rib.feed.errors.first)
    assert(@rib.feed.running?, 'and it is still there')
    deliver(n, update('10.0.0.0/8'))
    assert(@rib.drain)
    assert_equal(1, @rib.loc_rib.size, 'later UPDATEs still arrive')
  end

  def test_stop_ends_the_worker_and_detaches
    n = neighbor
    @rib.attach(n)
    assert(@rib.feed.running?)
    @rib.feed.stop
    assert(!@rib.feed.running?)
    assert_equal([], @rib.feed.neighbors)
    assert_equal(0, n.count_observers)
  end
end
