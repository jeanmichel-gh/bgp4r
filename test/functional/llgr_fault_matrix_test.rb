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
require 'stringio'
require 'bgp/sim'
require 'bgp/daemon/speaker'
require 'bgp/daemon/views'

# The LLGR matrix against bgp4rd: the three `llgr_` behaviours of
# `BGP::Fault::BEHAVIOURS` and the two `BGP::Fault::LLGR` OPEN cases,
# each run by a real bgp4r-sim, and what bgp4rd did beside what RFC 9494
# expects. A library Neighbor from 127.0.0.3, which lists no LLGR,
# watches what bgp4rd sends on: an LLGR_STALE route is withdrawn from it
# (section 4.3). docs/design/bgp-operations.md section 4, pull request
# 4c.
class TestLlgrFaultMatrix < Test::Unit::TestCase

  class Catcher
    attr_reader :withdrawn
    def initialize ; @withdrawn = Queue.new ; end
    def update(msg)
      return unless msg.is_a?(BGP::Update)
      msg.withdrawn.to_ary.each { |p| @withdrawn << p.to_s } if msg.withdrawn
    end
  end

  ROUTES = %w[10.1.0.0/16 10.2.0.0/16].freeze
  # What the sim does not send again after it comes back, or marks
  # NO_LLGR.
  DROP = '10.2.0.0/16'
  # The sim's Restart Time and Long-Lived Stale Time.
  RT = 1
  LLST = 3

  def free_port
    s = TCPServer.new('127.0.0.1', 0)
    s.addr[1]
  ensure
    s&.close
  end

  def setup
    Log.set_filename(StringIO.new)
    Log.level = Logger::WARN
  end

  def teardown
    @watcher&.stop rescue nil
    @sim&.stop
    @sp&.stop
    @watcher = @sim = @sp = @seen = nil
  end

  # bgp4rd helping 127.0.0.2 with GR and LLGR; bgp4r-sim there with a
  # GR capability (Restart Time RT) and an LLGR one (LLST) for IPv4
  # unicast; the watcher at 127.0.0.3.
  def start(n: false)
    port = free_port
    @sp = BGP::Daemon::Speaker.new('as' => 65_000, 'router_id' => '10.0.0.1', 'rib' => true,
                                   'listen_address' => '127.0.0.1', 'port' => port, 'log_level' => 'error',
                                   'export' => { 'next_hops' => { 1 => '192.0.2.1' } },
                                   'neighbors' => [{ 'address' => '127.0.0.2', 'as' => 65_001,
                                                     'graceful_restart' => { 'restart_time' => 0, 'notification' => n },
                                                     'long_lived_graceful_restart' => {} },
                                                   { 'address' => '127.0.0.3', 'as' => 65_003 }]).start
    @watcher = BGP::Neighbor.new(:my_as => 65_003, :remote_addr => '127.0.0.1', :id => '10.0.0.3')
    @watcher.capability :as4_byte
    @catcher = Catcher.new
    @watcher.add_observer(@catcher)
    sock = Socket.tcp('127.0.0.1', port, '127.0.0.3')
    Thread.new { @watcher.start(:session => sock, :timeout => 5) rescue nil }
    flags = n ? BGP::Sim::GracefulRestartBehaviour::N_BIT : 0
    neighbor = { 'address' => '127.0.0.1', 'as' => 65_000, 'connect' => true, 'port' => port, 'retry' => 0.2,
                 'capabilities' => ['as4_byte', { 'graceful_restart' => [flags, RT, [1, 1, 0x80]] },
                                    { 'llgr' => [1, 1, 0x80, LLST] }] }
    @sim = BGP::Sim::Injector.new('router_id' => '10.0.0.2', 'as' => 65_001, 'local_address' => '127.0.0.2',
                                  'neighbors' => [neighbor])
    @done = Queue.new
    @sim.speaker.events.on_event do |e|
      @done << (e.data['behaviour'] || e.data['case']) if e.kind == :log && e.message.to_s.include?('done on')
    end
    @sim.start
    assert_equal(true, wait_until(10) { @sim.speaker.peers.first.established? && @watcher.is_established? }, 'both up')
    @sim.act('announce', 'prefixes' => ROUTES, 'next_hop' => '127.0.0.2')
    assert_equal(true, wait_until(5) { adj_in.size == ROUTES.size && withdrawn_from_watcher_ready? }, 'the routes came')
  end

  def wait_until(seconds = 5)
    deadline = Time.now + seconds
    until Time.now > deadline
      return true if yield
      sleep 0.05
    end
    false
  end

  # The watcher has both routes, so a withdrawal later is bgp4rd's
  # answer to the case.
  def withdrawn_from_watcher_ready?
    BGP::Daemon::Views.new(@sp).adj_out('peer' => '127.0.0.3')[:rows].size == ROUTES.size
  end

  # The peer's Adj-RIB-In as { prefix => stale reason or nil }.
  def adj_in
    BGP::Daemon::Views.new(@sp).adj_in('peer' => '127.0.0.2')[:rows].to_h { |r| [r[:prefix], r[:stale]] }
  end

  # { prefix => whether it carries LLGR_STALE, 65535:6 } of the Loc-RIB.
  def loc_rib
    BGP::Daemon::Views.new(@sp).routes({})[:rows].to_h { |r| [r[:prefix], r[:communities].include?('65535:6')] }
  end

  # Everything withdrawn from the watcher so far.
  def withdrawn
    @seen ||= []
    @seen << @catcher.withdrawn.pop until @catcher.withdrawn.empty?
    @seen.uniq.sort
  end

  def long_lived(prefixes) ; prefixes.to_h { |p| [p, 'long_lived'] } ; end

  # Section 4.2 to 4.4: past the Restart Time the routes are LLGR_STALE,
  # withdrawn from the watcher, which lists no LLGR; back before the
  # LLST, they are fresh, DROP gone at End-of-RIB.
  def test_llgr_long_restart
    start
    @sim.act('behaviour', 'name' => 'llgr_long_restart', 'drop' => [DROP], 'away' => RT + 1.5)
    assert_equal(true, wait_until(RT + 1) { adj_in == long_lived(ROUTES) }, "long-lived: #{adj_in}")
    assert_equal(ROUTES.to_h { |p| [p, true] }, loc_rib, 'LLGR_STALE in the Loc-RIB')
    assert_equal(true, wait_until(2) { withdrawn == ROUTES }, "withdrawn from a peer without LLGR: #{withdrawn}")
    assert_equal('llgr_long_restart', @done.pop(:timeout => 10))
    assert_equal(true, wait_until(3) { adj_in == { '10.1.0.0/16' => nil } }, "back to normal: #{adj_in}")
    assert_equal({ '10.1.0.0/16' => false }, loc_rib)
  end

  # Section 4.2: away past the Restart Time and the LLST, the routes go
  # at the LLST.
  def test_llgr_never_back
    start
    t0 = Time.now
    @sim.act('behaviour', 'name' => 'llgr_never_back')
    assert_equal(true, wait_until(RT + 1) { adj_in == long_lived(ROUTES) }, "long-lived: #{adj_in}")
    assert_equal(true, wait_until(LLST + 2) { adj_in.empty? }, 'removed')
    assert_operator(Time.now - t0, :>=, RT + LLST, 'at the end of the LLST')
    assert_equal('llgr_never_back', @done.pop(:timeout => 5))
  end

  # Section 4.2: a route with NO_LLGR is removed when the LLGR period
  # begins, and the others are kept.
  def test_llgr_no_llgr_route
    start
    @sim.act('behaviour', 'name' => 'llgr_no_llgr_route', 'prefixes' => [DROP], 'away' => RT + 1.5)
    assert_equal(true, wait_until(RT + 1) { adj_in == long_lived(['10.1.0.0/16']) }, "#{DROP} removed: #{adj_in}")
    assert_equal('llgr_no_llgr_route', @done.pop(:timeout => 10))
    assert_equal(true, wait_until(3) { adj_in == ROUTES.to_h { |p| [p, nil] } }, "back: #{adj_in}")
  end

  # Section 4.5: an OPEN with LLGR and no GR. bgp4rd ignores the LLGR
  # capability, so it does not help: the routes go at the drop. Section
  # 3.1: reserved LLGR flags set are ignored, and the period runs.
  def test_every_llgr_case
    got = {}
    BGP::Fault.llgr_catalog.each do |c|
      start
      @sim.act('fault', 'case' => c[:name].to_s)
      assert_equal(c[:name].to_s, @done.pop(:timeout => 10), "#{c[:name]} ran")
      assert_equal(true, wait_until(3) { adj_in.size == ROUTES.size }, "#{c[:name]}: the routes again")
      info = @sp.peer('127.0.0.2').neighbor.session_info
      @sim.act('session.stop', {})
      kept = wait_until(RT + 2) { adj_in == long_lived(ROUTES) }
      got[c[:name]] = adj_in.empty? ? :flushed : (kept ? :long_lived : adj_in)
      got[:"#{c[:name]}_open"] = BGP::Daemon::GracefulRestart.received_llgr(info.peer)
      teardown
    end
    assert_equal({ :llgr_without_gr => :flushed, :llgr_without_gr_open => nil,
                   :llgr_reserved_flags => :long_lived, :llgr_reserved_flags_open => { [1, 1] => [0xff, LLST] } }, got)
  end
end
