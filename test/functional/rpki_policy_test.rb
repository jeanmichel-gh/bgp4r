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

# What bgp4rd sends an internal peer under origin validation: the RFC
# 8097 community with mark_ibgp, and nothing Invalid with reject, each
# following a VRP change. An Rtr::Cache over loopback; a library
# Neighbor from 127.0.0.2, external, announces three prefixes with a
# community claiming Valid, which bgp4rd drops; one from 127.0.0.3,
# internal, keeps every UPDATE. docs/design/bgp-operations.md 7c.
class TestRpkiPolicy < Test::Unit::TestCase

  VALID, INVALID, NOT_FOUND = '192.0.2.0/24', '198.51.100.0/24', '203.0.113.0/24'

  # The prefix's last UPDATE: its RFC 8097 states, or :withdrawn.
  class Catcher
    attr_reader :last
    def initialize ; @last = {} ; @lock = Mutex.new ; end
    def update(msg)
      return unless msg.is_a?(BGP::Update)
      @lock.synchronize do
        (msg.withdrawn ? msg.withdrawn.to_ary : []).each { |p| @last[p] = :withdrawn }
        pa = msg.path_attribute
        ov = pa && pa.has?(BGP::Extended_communities) ? pa[BGP::Extended_communities].find_all(BGP::Origin_validation_state) : []
        (msg.nlri ? msg.nlri.to_ary : []).each { |p| @last[p] = ov.collect(&:validation_state) }
      end
    end
    def [](prefix) ; @lock.synchronize { @last[prefix] } ; end
  end

  def free_port
    s = TCPServer.new('127.0.0.1', 0)
    s.addr[1]
  ensure
    s&.close
  end

  def start(rpki)
    @cache = BGP::Rtr::Cache.new('session_id' => 9, 'notify_every' => 0, 'retry' => 1,
                                 'vrps' => [{ 'prefix' => VALID, 'asn' => 65_001 },
                                            { 'prefix' => INVALID, 'asn' => 65_099 }])
    @cache.listen('127.0.0.1', 0)
    @ticker = Thread.new { loop { @cache.tick ; sleep 0.05 } }
    port = free_port
    caches = [{ 'address' => '127.0.0.1', 'port' => @cache.port, 'retry' => 1 }]
    @sp = BGP::Daemon::Speaker.new('as' => 65_000, 'router_id' => '10.0.0.1',
                                   'listen_address' => '127.0.0.1', 'port' => port, 'log_level' => 'error',
                                   'rpki' => rpki.merge('caches' => caches), 'export' => { 'next_hops' => { 1 => '127.0.0.1' } },
                                   'neighbors' => [{ 'address' => '127.0.0.2', 'as' => 65_001 },
                                                   { 'address' => '127.0.0.3', 'as' => 65_000 }]).start
    assert(wait_until { @sp.rpki.cache_rows.first[:state] == 'up' }, 'the cache is up')
    @catcher = Catcher.new
    @int = neighbor(port, '127.0.0.3', 65_000, '10.0.0.3') { |n| n.add_observer(@catcher) }
    @ext = neighbor(port, '127.0.0.2', 65_001, '10.0.0.2')
    ec = BGP::Extended_communities.new(BGP::Origin_validation_state.new(:valid))
    pa = BGP::Path_attribute.new(BGP::Origin.new(0), BGP::As_path.new(65_001), BGP::Next_hop.new('127.0.0.2'), ec)
    @ext.send_message(BGP::Update.new(pa, BGP::Nlri.new(VALID, INVALID, NOT_FOUND)))
  end

  def neighbor(port, from, as, id)
    n = BGP::Neighbor.new(:my_as => as, :remote_addr => '127.0.0.1', :id => id)
    yield n if block_given?
    sock = Socket.tcp('127.0.0.1', port, from)
    Thread.new { n.start(:session => sock, :timeout => 5) rescue nil }
    assert(wait_until { n.is_established? }, "the session from #{from} came up")
    n
  end

  def teardown
    [@ext, @int, @sp, @cache].each { |x| x&.stop }
    @ticker&.kill
  end

  def wait_until(seconds = 5)
    deadline = Time.now + seconds
    until Time.now > deadline
      return true if yield
      sleep 0.05
    end
    false
  end

  def seen ; [VALID, INVALID, NOT_FOUND].collect { |p| @catcher[p] } ; end

  # RFC 8097 section 2: our state toward the internal peer, not the
  # external peer's claim, and again when a VRP change moves it.
  def test_mark_ibgp
    start('mark_ibgp' => true)
    assert(wait_until { seen == [[:valid], [:invalid], [:not_found]] }, seen.inspect)
    @cache.change(announce: [{ 'prefix' => INVALID, 'asn' => 65_001 }], withdraw: [{ 'prefix' => VALID, 'asn' => 65_001 }])
    assert(wait_until { seen == [[:not_found], [:valid], [:not_found]] }, seen.inspect)
  end

  # Without mark_ibgp no community goes, the external one dropped.
  def test_no_mark
    start({})
    assert(wait_until { seen == [[], [], []] }, seen.inspect)
  end

  # invalid: reject: the Invalid route is not used and so not sent; a
  # VRP change that makes it Valid sends it, one that makes another
  # Invalid withdraws that one.
  def test_reject
    start('invalid' => 'reject')
    assert(wait_until { @catcher[VALID] && @catcher[NOT_FOUND] }, seen.inspect)
    sleep 0.3
    assert_nil(@catcher[INVALID])
    row = BGP::Daemon::Views.new(@sp).adj_in('peer' => '127.0.0.2')[:rows].find { |r| r[:prefix] == INVALID }
    assert_equal(['invalid', false], row.values_at(:validation, :best), 'kept in the Adj-RIB-In')
    @cache.change(announce: [{ 'prefix' => INVALID, 'asn' => 65_001 }, { 'prefix' => NOT_FOUND, 'asn' => 65_099 }])
    assert(wait_until { seen == [[], [], :withdrawn] }, seen.inspect)
  end
end
