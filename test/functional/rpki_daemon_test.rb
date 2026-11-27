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
require 'bgp/rtr/cache'

# Origin validation in bgp4rd, RFC 6811, from an Rtr::Cache over
# loopback, with a library Neighbor announcing a Valid, an Invalid and
# a NotFound prefix, then the VRPs changing under them.
# docs/design/bgp-operations.md 7c.
class TestRpkiDaemon < Test::Unit::TestCase

  VALID, INVALID, NOT_FOUND = '192.0.2.0/24', '198.51.100.0/24', '203.0.113.0/24'

  def free_port
    s = TCPServer.new('127.0.0.1', 0)
    s.addr[1]
  ensure
    s&.close
  end

  def setup
    @cache = BGP::Rtr::Cache.new('session_id' => 9, 'notify_every' => 0, 'retry' => 1,
                                 'vrps' => [{ 'prefix' => VALID, 'asn' => 65_001 },
                                            { 'prefix' => '198.51.100.0/22', 'max_length' => 24, 'asn' => 65_099 }])
    @cache.listen('127.0.0.1', 0)
    @ticker = Thread.new { loop { @cache.tick ; sleep 0.05 } }
    @port = free_port
    @sp = BGP::Daemon::Speaker.new('as' => 65_000, 'router_id' => '10.0.0.1',
                                   'listen_address' => '127.0.0.1', 'port' => @port, 'log_level' => 'error',
                                   'rpki' => { 'caches' => [{ 'address' => '127.0.0.1', 'port' => @cache.port, 'retry' => 1 }] },
                                   'neighbors' => [{ 'address' => '127.0.0.2', 'as' => 65_001 }]).start
    @n = BGP::Neighbor.new(:my_as => 65_001, :remote_addr => '127.0.0.1', :id => '10.0.0.9')
    sock = Socket.tcp('127.0.0.1', @port, '127.0.0.2')
    Thread.new { @n.start(:session => sock, :timeout => 5) rescue nil }
    assert(wait_until { @n.is_established? }, 'the session came up')
    pa = BGP::Path_attribute.new(BGP::Origin.new(0), BGP::As_path.new(65_001), BGP::Next_hop.new('127.0.0.2'))
    @n.send_message(BGP::Update.new(pa, BGP::Nlri.new(VALID, INVALID, NOT_FOUND)))
    assert(wait_until { states.size == 3 }, 'three routes in')
  end

  def teardown
    @n&.stop
    @sp&.stop
    @ticker&.kill
    @cache&.stop
  end

  def wait_until(seconds = 5)
    deadline = Time.now + seconds
    until Time.now > deadline
      return true if yield
      sleep 0.05
    end
    false
  end

  def views ; BGP::Daemon::Views.new(@sp) ; end

  # { prefix => validation } from show.routes.
  def states ; views.routes[:rows].to_h { |r| [r[:prefix], r[:validation]] } ; end

  def test_each_route_has_its_state_and_follows_the_vrps
    assert(wait_until { states == { VALID => 'valid', INVALID => 'invalid', NOT_FOUND => 'notfound' } }, states.inspect)
    assert_equal('invalid', views.rib('prefix' => INVALID)[:rows].first[:paths].first[:validation])
    assert_equal('valid', views.adj_in('peer' => '127.0.0.2')[:rows].find { |r| r[:prefix] == VALID }[:validation])
    cache = views.rpki[:rows].first
    assert_equal(['up', 1, 9, 1, 2, 0], cache.values_at(:state, :version, :session_id, :serial, :vrps_v4, :vrps_v6))
    assert_equal([{ :prefix => '192.0.2.0/24', :max_length => 24, :asn => 65_001 },
                  { :prefix => '198.51.100.0/22', :max_length => 24, :asn => 65_099 }], views.rpki_vrps[:rows])
    assert_equal({ :caches => 1, :synced => 1, :vrps_v4 => 2, :vrps_v6 => 0, :invalid => 'accept' }, views.status[:rpki])
    # A VRP added makes the Invalid one Valid, and one removed makes the
    # Valid one NotFound, through Serial Notify and Serial Query.
    @cache.change(announce: [{ 'prefix' => INVALID, 'asn' => 65_001 }], withdraw: [{ 'prefix' => VALID, 'asn' => 65_001 }])
    assert(wait_until { states == { VALID => 'notfound', INVALID => 'valid', NOT_FOUND => 'notfound' } }, states.inspect)
    moved = nil
    assert(wait_until { moved = @sp.events.since.find { |e| e.kind == :rpki && e.data[:event] == 'routes' } })
    assert_equal(2, moved.data[:changed])
    assert_equal([{ :prefix => VALID, :from => '127.0.0.2', :was => 'valid', :now => 'notfound' },
                  { :prefix => INVALID, :from => '127.0.0.2', :was => 'invalid', :now => 'valid' }],
                 moved.data[:routes].sort_by { |r| r[:prefix] })
    assert(@sp.rib.best(INVALID), 'invalid: accept leaves every route in the decision')
  end

  # RFC 8210 section 6: with the cache gone the data stays; the cache
  # back, the client comes back to it.
  def test_the_cache_goes_and_comes_back
    assert(wait_until { states[VALID] == 'valid' })
    port = @cache.port
    @cache.stop
    assert(wait_until { views.rpki[:rows].first[:state] == 'down' })
    assert_equal('valid', states[VALID], 'kept until Expire')
    # A new cache on the port, another Session ID and other VRPs: the
    # Serial Query gets Corrupt Data (section 5.1), the data goes, and a
    # Reset Query loads the new table.
    @cache = BGP::Rtr::Cache.new('session_id' => 10, 'vrps' => [{ 'prefix' => NOT_FOUND, 'asn' => 65_001 }])
    @cache.listen('127.0.0.1', port)
    assert(wait_until(10) { states[NOT_FOUND] == 'valid' }, states.inspect)
    assert_equal([10, 'notfound'], [views.rpki[:rows].first[:session_id], states[VALID]])
  end
end
