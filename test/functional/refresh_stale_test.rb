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
require 'socket'
require 'bgp/daemon/speaker'
require 'bgp/daemon/views'

# Receiving BoRR and EoRR, RFC 7313 sections 4 and 5, through a real
# Speaker over loopback. A library Neighbor from 127.0.0.2 announces
# routes, then a BoRR, some of them again, and an EoRR.
class TestRefreshStale < Test::Unit::TestCase

  class Catcher
    attr_reader :messages
    def initialize ; @messages = Queue.new ; end
    def update(msg)
      @messages << msg if msg.is_a?(BGP::Notification)
    end
  end

  ROUTES = %w[10.1.0.0/16 10.2.0.0/16 10.3.0.0/16 10.4.0.0/16].freeze
  ERR = %w[route_refresh enhanced_route_refresh].freeze

  def free_port
    s = TCPServer.new('127.0.0.1', 0)
    s.addr[1]
  ensure
    s&.close
  end

  def speaker(neighbor = {})
    @port = free_port
    @sp = BGP::Daemon::Speaker.new('as' => 65_000, 'router_id' => '10.0.0.1',
                                   'listen_address' => '127.0.0.1', 'port' => @port,
                                   'log_level' => 'error', 'rib' => true,
                                   'neighbors' => [{ 'address' => '127.0.0.2', 'as' => 65_001,
                                                     'capabilities' => ERR }.merge(neighbor)]).start
    @events = Queue.new
    @sp.events.on_event { |e| @events << e.data if e.kind == :refresh }
  end

  def client(caps = ERR.collect(&:to_sym))
    @catcher = Catcher.new
    @n = BGP::Neighbor.new(:my_as => 65_001, :remote_addr => '127.0.0.1', :id => '10.0.0.9')
    caps.each { |c| @n.capability c }
    @n.add_observer(@catcher)
    sock = Socket.tcp('127.0.0.1', @port, '127.0.0.2')
    Thread.new { @n.start(:session => sock, :timeout => 5) rescue nil }
    assert_equal(true, wait_until { @n.is_established? }, 'the session came up')
  end

  def announce(prefixes)
    pa = BGP::Path_attribute.new(BGP::Origin.new(0), BGP::As_path.new(65_001), BGP::Next_hop.new('127.0.0.2'))
    @n.send_message(BGP::Update.new(pa, BGP::Nlri.new(*prefixes)))
  end

  def wait_until(seconds = 5)
    deadline = Time.now + seconds
    until Time.now > deadline
      return true if yield
      sleep 0.05
    end
    false
  end

  # The peer's Adj-RIB-In as { prefix => stale reason or nil }.
  def adj_in
    BGP::Daemon::Views.new(@sp).adj_in('peer' => '127.0.0.2')[:rows].to_h { |r| [r[:prefix], r[:stale]] }
  end

  def row ; BGP::Daemon::Views.new(@sp).peers.first ; end

  def teardown
    @n&.stop
    @sp&.stop
  end

  def table_of_four
    announce(ROUTES)
    assert_equal(true, wait_until { adj_in.size == 4 }, 'four routes in')
  end

  # Section 4: a BoRR marks every route of the family stale, a route sent
  # again is fresh, and the EoRR removes the rest.
  def test_the_eorr_removes_what_was_not_sent_again
    speaker
    client
    table_of_four
    @n.send_message(BGP::Route_refresh.new(1, 1, :borr))
    announce(ROUTES.first(2))
    assert_equal(true, wait_until { adj_in == ROUTES.to_h { |p| [p, ROUTES.first(2).include?(p) ? nil : 'refresh'] } },
                 "two fresh, two stale: #{adj_in}")
    assert_equal(2, row[:refresh][:stale])
    assert_equal([{ :afi => 1, :safi => 1 }], row[:refresh][:waiting])
    rib = BGP::Daemon::Views.new(@sp).rib('prefix' => '10.3.0.0/16')[:rows].first
    assert_equal('refresh', rib[:paths].first[:stale], 'show.rib says so too')
    @n.send_message(BGP::Route_refresh.new(1, 1, :eorr))
    assert_equal(true, wait_until { adj_in.keys.sort == ROUTES.first(2) }, "the stale two went: #{adj_in}")
    assert_equal(nil, @sp.rib.best('10.3.0.0/16'), 'and left the Loc-RIB')
    assert_equal([0, []], [row[:refresh][:stale], row[:refresh][:waiting]])
    assert_equal(true, @n.is_established?)
  end

  # Section 4's local upper bound: refresh_stale_time, with no EoRR.
  def test_the_bound_removes_them_without_an_eorr
    speaker('refresh_stale_time' => 1)
    client
    table_of_four
    @n.send_message(BGP::Route_refresh.new(1, 1, :borr))
    announce(ROUTES.first(1))
    assert_equal(true, wait_until(6) { adj_in.keys == ROUTES.first(1) }, "the bound ran out: #{adj_in}")
    data = nil
    wait_until { (data = @events.pop(:timeout => 1)) && data[:purged] }
    assert_equal({ :purged => { :afi => 1, :safi => 1, :removed => 3 }, :reason => 'refresh_stale_time' }, data)
  end

  # Section 4: only from a peer that sent capability 70.
  def test_a_borr_from_a_peer_without_70_is_ignored
    speaker
    client(%i[route_refresh])
    table_of_four
    @n.send_message(BGP::Route_refresh.new(1, 1, :borr))
    @n.send_message(BGP::Route_refresh.new(1, 1, :eorr))
    sleep 1
    assert_equal(ROUTES.to_h { |p| [p, nil] }, adj_in)
  end

  # Section 4: an EoRR with no BoRR before it may be ignored, and is.
  def test_an_eorr_alone_is_ignored
    speaker
    client
    table_of_four
    @n.send_message(BGP::Route_refresh.new(1, 1, :eorr))
    sleep 1
    assert_equal(ROUTES.to_h { |p| [p, nil] }, adj_in)
  end

  # Section 5: a subtype other than 0, 1 or 2 is ignored, and the session
  # stays.
  def test_an_unknown_subtype_is_ignored
    speaker
    client
    table_of_four
    @n.send_message(BGP::Route_refresh.new(1, 1, 3))
    sleep 1
    assert_equal(ROUTES.to_h { |p| [p, nil] }, adj_in)
    assert_equal(true, @n.is_established?)
    assert_equal({ :other => 1 }, row[:refresh][:received])
  end

  # Section 5: a BoRR one octet too long gets NOTIFICATION 7/1 with the
  # whole message as its data.
  def test_a_borr_of_the_wrong_length_ends_the_session
    speaker
    client
    long = BGP::Route_refresh.new(1, 1, :borr).encode
    long = long[0, 16] + [24].pack('n') + long[18..] + "\0"
    @n.send_message(long)
    assert_equal(true, wait_until { !@catcher.messages.empty? }, 'a NOTIFICATION came')
    h = @catcher.messages.pop.to_hash
    assert_equal([7, 1, long], [h[:code], h[:subcode], h[:data]])
  end

  # Section 5's NOTIFICATION "is applicable only when a BGP speaker has
  # received the "Enhanced Route Refresh Capability" from a peer": from
  # any other, the message is dropped and the session stays.
  def test_a_borr_of_the_wrong_length_from_a_peer_without_70_is_dropped
    speaker
    client(%i[route_refresh])
    long = BGP::Route_refresh.new(1, 1, :borr).encode
    long = long[0, 16] + [24].pack('n') + long[18..] + "\0"
    @n.send_message(long)
    sleep 1
    assert_equal([true, true], [@n.is_established?, @catcher.messages.empty?])
  end
end
