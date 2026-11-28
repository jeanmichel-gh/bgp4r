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

# The LLGR matrix against FRR's bgpd as the helper: the three `llgr_`
# behaviours of `BGP::Fault::BEHAVIOURS` and the two `BGP::Fault::LLGR`
# OPEN cases, run by bgp4r-sim, and what bgpd did, held to what was
# measured against 10.5.1 on the owner's VM. A library Neighbor at
# 127.0.0.3, a second peer of bgpd that lists no LLGR, watches what bgpd
# sends on. docs/design/bgp-operations.md section 4, pull request 4c.
# No Docker, no zebra.
#
#   ruby -I. test/functional/lab/llgr_fault_frr_test.rb
#
# Omitted when FRR's bgpd is not installed, unless LAB_REQUIRE_FRR=1.
#
# BGP:: names are written out in full, see Conventions in CLAUDE.md.

require 'test/unit'
require 'socket'
require 'stringio'
require 'bgp4r'
require 'bgp/sim'
require_relative 'lab_helper'

class LabLlgrFaultFrrTest < Test::Unit::TestCase
  include LabHelper

  F = LabHelper::Frr
  LOCAL = '127.0.0.1'
  FRR = '127.0.0.2'
  WATCHER = '127.0.0.3'
  ROUTES = %w[10.10.0.0/16 10.11.0.0/16].freeze
  # What the sim does not send again, or marks NO_LLGR.
  DROP = '10.11.0.0/16'
  KEPT = '10.10.0.0/16'
  # The sim's Restart Time and Long-Lived Stale Time.
  RT = 2
  LLST = 4

  # 10.5.1. Others were not run.
  MEASURED = (10..10).freeze

  # What bgpd sends the watcher: withdrawals, and each announcement
  # with its communities.
  class Catcher
    attr_reader :withdrawn, :announced
    def initialize ; @withdrawn = Queue.new ; @announced = Queue.new ; end
    def update(msg)
      return unless msg.is_a?(BGP::Update)
      msg.withdrawn.to_ary.each { |p| @withdrawn << p.to_s } if msg.withdrawn
      c = msg.path_attribute && msg.path_attribute[BGP::Communities]
      msg.nlri.to_ary.each { |p| @announced << [p.to_s, c ? c.communities : nil] } if msg.nlri
    end
  end

  def setup
    unless F.available?
      flunk('FRR bgpd is not installed') if ENV['LAB_REQUIRE_FRR'] == '1'
      omit('FRR bgpd is not installed')
    end
    major = F.major
    unless F.measured?(MEASURED, major)
      omit("measured against FRR #{MEASURED}, found #{major.inspect}: re-measure before asserting")
    end
    Log.set_filename(StringIO.new)
    Log.level = Logger::WARN
  end

  def teardown
    puts "\n== bgpd\n#{@router.log}" if @router && !passed?
    stop
  end

  # Measured 2026-11-28: without this line bgpd shows
  # configuredLlgrStaleTime 0 and deletes the routes at the Restart
  # Time, with no LLGR period. With it, the period is the sim's LLST,
  # the smaller of the two.
  LLGR_LINE = ' bgp long-lived-graceful-restart stale-time 20'

  # Section 4.2 to 4.4. bgpd keeps both routes stale, attaches
  # LLGR_STALE at the Restart Time, and at End-of-RIB has KEPT fresh and
  # DROP gone. Section 4.3 says such a route "SHOULD NOT be advertised"
  # to a neighbor that sent no LLGR, and so withdrawn from it; section
  # 4.6's exception is for internal neighbors with NO_EXPORT and a
  # LOCAL_PREF of 0. bgpd 10.5.1 announced both routes to the watcher, an
  # external neighbor with no LLGR, again with LLGR_STALE and nothing
  # else: that is measured here, not what the RFC asks.
  def test_llgr_long_restart
    start(lines: [LLGR_LINE])
    @sim.act('behaviour', 'name' => 'llgr_long_restart', 'drop' => [DROP], 'away' => RT + 2)
    assert_equal(true, wait_for_bool(RT + 1) { marks == 'll' }, "LLGR_STALE at the Restart Time: #{marks}")
    assert_equal(true, wait_for_bool(3) { announced.include?([KEPT, '65535:6']) && announced.include?([DROP, '65535:6']) },
                 "bgpd sent them on, LLGR_STALE: #{announced}")
    assert_equal([], withdrawn, 'and withdrew neither')
    assert_equal('llgr_long_restart', @done.pop(:timeout => 20))
    assert_equal(true, wait_for_bool(5) { marks == 'y-' }, "back: #{KEPT} fresh, #{DROP} gone: #{marks}")
    assert_equal(true, wait_for_bool(3) { withdrawn == [DROP] }, "withdrawn: #{withdrawn}")
    assert_equal(true, wait_for_bool(3) { announced.include?([KEPT, nil]) }, "#{KEPT} fresh to the watcher")
  end

  # Section 4.2: the routes go at the end of the LLST, the sim's 4 s.
  def test_llgr_never_back
    start(lines: [LLGR_LINE])
    t0 = Time.now
    @sim.act('behaviour', 'name' => 'llgr_never_back')
    assert_equal(true, wait_for_bool(RT + 1) { marks == 'll' }, "LLGR_STALE at the Restart Time: #{marks}")
    assert_equal(true, wait_for_bool(LLST + 2) { marks == '--' }, "removed: #{marks}")
    assert_operator(Time.now - t0, :>=, RT + LLST - 0.5, 'at the end of the LLST, not before')
    assert_equal(true, wait_for_bool(3) { withdrawn == ROUTES }, "withdrawn: #{withdrawn}")
  end

  # Section 4.2: a route with NO_LLGR goes when the LLGR period begins;
  # the other is kept, LLGR_STALE.
  def test_llgr_no_llgr_route
    start(lines: [LLGR_LINE])
    @sim.act('behaviour', 'name' => 'llgr_no_llgr_route', 'prefixes' => [DROP], 'away' => RT + 2)
    assert_equal(true, wait_for_bool(RT + 1) { marks == 'l-' }, "#{DROP} removed, #{KEPT} kept: #{marks}")
    assert_equal('llgr_no_llgr_route', @done.pop(:timeout => 20))
    assert_equal(true, wait_for_bool(5) { marks == 'yy' }, "back, both: #{marks}")
  end

  # Section 4.5: an OPEN with LLGR and no GR; bgpd shows remoteGrMode
  # Disable and flushes at the drop. Section 3.1: reserved bits set;
  # bgpd ignores them, reads F, and runs the period.
  FRR_LLGR_DID = { :llgr_without_gr => :flushed, :llgr_reserved_flags => :long_lived }.freeze

  def test_every_llgr_case
    got = {}
    BGP::Fault.llgr_catalog.each do |c|
      start(lines: [LLGR_LINE])
      @sim.act('fault', 'case' => c[:name].to_s)
      assert_equal(c[:name].to_s, @done.pop(:timeout => 30), "#{c[:name]} ran")
      assert_equal(true, wait_for_bool(10) { marks == 'yy' }, "#{c[:name]}: the routes again: #{marks}")
      @sim.act('session.stop', {})
      got[c[:name]] = if wait_for_bool(2) { marks == '--' } then :flushed
                      elsif wait_for_bool(RT + 2) { marks == 'll' } then :long_lived
                      else marks
                      end
      stop
    end
    assert_equal(FRR_LLGR_DID, got)
  end

  PROBE = ENV['LLGR_PROBE'] == '1'

  # Prints what bgpd did with each case, to measure: a trace of both
  # routes in bgpd's RIB, '-' gone, 'y' there, 's' stale, 'l' with
  # LLGR_STALE.
  def test_probe
    omit('LLGR_PROBE=1 to measure') unless PROBE
    lines = ENV['LLGR_LINES'] ? ENV['LLGR_LINES'].split(';') : []
    cases = %w[llgr_long_restart llgr_never_back llgr_no_llgr_route llgr_without_gr llgr_reserved_flags]
    cases &= ENV['LLGR_ONLY'].split(',') if ENV['LLGR_ONLY']
    cases.each do |name|
      start(lines: lines)
      mark = @router.log.size
      if name.start_with?('llgr_without', 'llgr_reserved')
        @sim.act('fault', 'case' => name)
        wait_for_bool(20) { @done.size > 0 }
        @done.pop
        sleep 1
        puts "#{name}: bgpd's view of the sim's LLGR: #{(@router.neighbor(LOCAL) || {}).dig('gracefulRestartInfo').inspect[0, 400]}"
        @sim.act('session.stop', {})
      else
        body = { 'name' => name, 'away' => (name == 'llgr_never_back' ? 0 : RT + 2) }
        body['prefixes'] = [DROP] if name == 'llgr_no_llgr_route'
        body['drop'] = [DROP] if name == 'llgr_long_restart'
        @sim.act('behaviour', body)
      end
      trace = []
      t0 = Time.now
      while Time.now - t0 < (ENV['LLGR_SECS'] || RT + LLST + 4).to_f
        trace << [(Time.now - t0).round(1), ROUTES.collect { |p| mark_of(@router.detail(p)) }.join]
        sleep 0.1
      end
      got = [] ; got << @catcher.announced.pop until @catcher.announced.empty?
      puts "#{name}: announced to the watcher after the start #{got.inspect}"
      puts "#{name}: withdrawn #{withdrawn} trace #{trace.chunk_while { |a, c| a[1] == c[1] }.collect { |g| "#{g.first[0]}:#{g.first[1]}" }.join(' ')} " \
           "state #{(@router.neighbor(LOCAL) || {})['bgpState']}"
      puts @router.log[mark..].lines.grep(/llgr|long|stale|graceful|EOR|End-of-RIB/i).grep_v(/KEEPALIVE/).first(30).join if ENV['LLGR_LOG']
      stop
    end
  end

  private

  # Both routes in bgpd's RIB, KEPT then DROP, as mark_of has them.
  def marks ; ROUTES.collect { |p| mark_of(@router.detail(p)) }.join ; end

  # What bgpd has announced to the watcher since start, [prefix,
  # communities or nil].
  def announced
    @heard << @catcher.announced.pop until @catcher.announced.empty?
    @heard
  end

  def mark_of(d)
    return '-' unless d
    c = d.dig('community', 'string').to_s
    return 'l' if c =~ /llgr-stale/
    d['stale'] ? 's' : 'y'
  end

  # bgpd with `bgp graceful-restart` and lines; the sim dialling it, its
  # GR capability for IPv4 unicast (Restart Time RT) and its LLGR one
  # (LLST); the watcher.
  def start(lines: [], n: false)
    wport = LabHelper::Local.free_port(WATCHER)
    @router = F.new(:local => FRR, :as => 65002, :router_id => '10.0.0.2', :peer => LOCAL, :peer_as => 65001,
                    :port => LabHelper::Local.free_port,
                    :more_peers => [{ :address => WATCHER, :as => 65003, :port => wport }],
                    :bgp_lines => [' bgp graceful-restart', *lines],
                    :neighbor_lines => [" neighbor #{LOCAL} passive", " neighbor #{LOCAL} advertisement-interval 0",
                                        " neighbor #{WATCHER} advertisement-interval 0"])
    @catcher = Catcher.new
    @seen = []
    @heard = []
    @watcher = BGP::Neighbor.new(:my_as => 65003, :remote_addr => FRR, :id => WATCHER)
    @watcher.capability :as4_byte
    @watcher.add_observer(@catcher)
    server = TCPServer.new(WATCHER, wport)
    @watch_thread = Thread.new do
      sock = server.accept
      server.close
      @watcher.start(:session => sock, :timeout => 30)
    rescue StandardError
      nil
    end
    flags = n ? BGP::Sim::GracefulRestartBehaviour::N_BIT : 0
    @sim = BGP::Sim::Injector.new('router_id' => '10.0.0.1', 'as' => 65001, 'listen_address' => LOCAL,
                                  'local_address' => LOCAL, 'port' => @router.port,
                                  'neighbors' => [{ 'address' => FRR, 'as' => 65002, 'port' => @router.listen_port,
                                                    'connect' => true, 'retry' => 0.5, 'end_of_rib' => true,
                                                    'capabilities' => ['as4_byte',
                                                                       { 'graceful_restart' => [flags, RT, [1, 1, 0x80]] },
                                                                       { 'llgr' => [1, 1, 0x80, LLST] }] }])
    @done = Queue.new
    @notified = Queue.new
    @sim.speaker.events.on_event do |e|
      @done << (e.data['behaviour'] || e.data['case']) if e.kind == :log && e.message.to_s.include?('done on')
      @notified << e.data if e.kind == :notification && e.data[:direction] == 'receive'
    end
    @sim.start
    @router.up
    assert_equal(true, wait_for_bool(60) { @sim.speaker.peers.first.established? }, 'the sim is up')
    @sim.act('announce', 'prefixes' => ROUTES, 'next_hop' => '192.0.2.9')
    assert_equal(true, wait_for_bool(30) { ROUTES.all? { |p| @router.path(p) } }, 'FRR holds our routes')
    assert_equal(true, wait_for_bool(30) { @watcher.is_established? }, 'the watcher is up')
    assert_equal(true, wait_for_bool(10) { @catcher.announced.size >= ROUTES.size }, 'the watcher has both routes')
    @catcher.announced.clear
  end

  def stop
    @watcher&.stop rescue nil
    @router&.down
    @sim&.stop
    @router = @sim = @watcher = nil
  end

  def withdrawn
    @seen << @catcher.withdrawn.pop until @catcher.withdrawn.empty?
    @seen.uniq.sort
  end

  def wait_for_bool(seconds)
    deadline = Time.now + seconds
    until Time.now > deadline
      return true if yield
      sleep 0.2
    end
    false
  end
end
