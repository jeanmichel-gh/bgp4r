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

# The graceful restart matrix against FRR's bgpd as the helper: the
# eleven `gr_` behaviours of `BGP::Fault::BEHAVIOURS` and the two
# `BGP::Fault::GR` cases, run by bgp4r-sim on a session of its own, and
# what FRR did, held to a table measured against 10.5.1 on the owner's
# VM. A library Neighbor at 127.0.0.3, a second peer of bgpd, watches
# what bgpd sends on. docs/design/bgp-operations.md section 3, pull
# request 3c. No Docker, no zebra.
#
#   ruby -I. test/functional/lab/gr_fault_frr_test.rb
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

class LabGrFaultFrrTest < Test::Unit::TestCase
  include LabHelper

  F = LabHelper::Frr
  LOCAL = '127.0.0.1'
  FRR = '127.0.0.2'
  WATCHER = '127.0.0.3'
  ROUTES = %w[10.10.0.0/16 10.11.0.0/16].freeze
  # What the sim does not send again after it comes back.
  DROP = '10.11.0.0/16'
  # What it does send again.
  KEPT = '10.10.0.0/16'

  # 10.5.1. Others were not run.
  MEASURED = (10..10).freeze

  class Catcher
    attr_reader :withdrawn
    def initialize ; @withdrawn = Queue.new ; end
    def update(msg)
      return unless msg.is_a?(BGP::Update)
      msg.withdrawn.to_ary.each { |p| @withdrawn << p.to_s } if msg.withdrawn
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

  # What FRR 10.5.1 did with each behaviour that comes back: :kept
  # when KEPT, the route the sim sends again, was never gone from bgpd's
  # RIB (read every 0.05 s) nor withdrawn from the watcher, :flushed
  # when it was. Measured on 2026-11-26 in about twenty runs, bgpd
  # passive and the sim dialling. Three are not what the RFC expects:
  #
  # - gr_restart_no_f and gr_restart_family_missing: RFC 4724 section
  #   4.2 has the stale routes of a family with F clear, or missing,
  #   removed at once. In most runs bgpd keeps KEPT, stale, until it
  #   comes again; in a few it removed it, as the RFC asks (FRR_MAY).
  #   Why it differs from run to run is not known.
  # - gr_consecutive_n: N was exchanged on both sessions (bgpd logs
  #   "R-bit SET N-bit SET"), and bgpd deleted the routes left stale by
  #   the first restart when the second began. RFC 8538 section 4.1
  #   keeps them.
  FRR_DID = {
    :gr_restart                => :kept,
    :gr_restart_no_f           => :kept,
    :gr_restart_family_missing => :kept,
    :gr_new_connection         => :kept,
    :gr_consecutive            => :flushed,
    :gr_consecutive_n          => :flushed,
    :gr_graceful_cease         => :kept,
    :gr_hard_reset             => :flushed,
    :gr_notification_no_n      => :flushed,
  }.freeze

  # What bgpd did in some runs instead. In these two it also, in a few
  # runs, kept DROP after the sim's End-of-RIB, so that is not asserted
  # either; the test says what it saw.
  FRR_MAY = { :gr_restart_no_f => :flushed, :gr_restart_family_missing => :flushed }.freeze

  def test_every_behaviour_that_comes_back
    got = {}
    FRR_DID.each_key do |name|
      start(n: needs(name) == :n)
      got[name] = watch(name)
      purged = wait_for_bool(10) { @router.path(KEPT) && !@router.path(DROP) }
      if FRR_MAY.key?(name)
        notify("#{name}: bgpd kept #{DROP} after End-of-RIB this run") unless purged
      else
        assert_equal(true, purged, "#{name}: back, and #{DROP} gone")
      end
      n = @notified.pop(:timeout => 0)
      if name == :gr_new_connection && n
        # One run in about twenty: bgpd resolved the two connections as
        # a collision (RFC 4271 section 6.8), not RFC 4724 section 4.2's
        # replace, and sent Cease 6/7 on one of them.
        assert_equal([6, 7], [n[:code], n[:subcode]], "#{name}: a collision, if anything")
      else
        assert_nil(n, "#{name}: bgpd sent no NOTIFICATION")
      end
      stop
    end
    assert_equal(FRR_DID, got.to_h { |k, v| [k, FRR_MAY[k] == v ? FRR_DID[k] : v] }, "got #{got}")
  end

  # RFC 4724 section 4.2: the stale routes go at the Restart Time, the
  # sim's 2 s. bgpd logs "graceful restart timer expired", and in most
  # runs removes them; in about one in ten it kept them, stale. So what
  # is asserted is the stale mark and the timer, and the test says when
  # the routes stayed.
  def test_gr_never_back
    start(restart_time: 2)
    @sim.act('behaviour', 'name' => 'gr_never_back', 'away' => 0)
    assert_equal(true, wait_for_bool(3) { (@router.detail(KEPT) || {})['stale'] }, 'kept stale while away')
    assert_equal(true, wait_for_bool(5) { @router.log =~ /graceful restart timer expired/ }, 'the Restart Time ran out')
    if wait_for_bool(3) { ROUTES.none? { |p| @router.path(p) } }
      assert_equal(true, wait_for_bool(2) { withdrawn == ROUTES }, "withdrawn: #{withdrawn}")
    else
      notify('gr_never_back: bgpd kept the stale routes past the Restart Time this run')
    end
  end

  # RFC 8538 section 4.1: back, no End-of-RIB; what was not sent again
  # goes at the stale timer, `stalepath-time` in bgpd, here 3 s. bgpd
  # logs the timer started when the session dropped, and keeps DROP,
  # stale, 6 s after it should have run out. Why is not known.
  def test_gr_no_eor
    start(stale_time: 3)
    @sim.act('behaviour', 'name' => 'gr_no_eor', 'drop' => [DROP], 'away' => 0.5)
    assert_equal('gr_no_eor', @done.pop(:timeout => 30))
    assert_equal(true, wait_for_bool(3) { !(@router.detail(KEPT) || {})['stale'] }, 'sent again, fresh')
    assert_match(/graceful restart stalepath timer started for 3 sec/, @router.log)
    sleep 6
    assert_equal(true, (@router.detail(DROP) || {})['stale'], "#{DROP} still there, stale")
    assert_equal([], withdrawn)
  end

  # RFC 8538 section 3.2: a Hard Reset bgpd cannot read inside still
  # ends the session as RFC 4271 does.
  FRR_GR_DID = { :hard_reset_empty => :flushed, :hard_reset_unknown_inner => :flushed }.freeze

  def test_every_gr_case
    got = {}
    BGP::Fault.gr_catalog.each do |c|
      start(n: c[:n])
      @sim.act('fault', 'case' => c[:name].to_s)
      gone = wait_for_bool(5) { @router.path(KEPT).nil? || withdrawn.include?(KEPT) }
      got[c[:name]] = gone ? :flushed : :kept
      stop
    end
    assert_equal(FRR_GR_DID, got)
  end

  PROBE = ENV['GR_PROBE'] == '1'

  # Prints what FRR did with each behaviour, to measure the table.
  def test_probe
    omit('GR_PROBE=1 to measure') unless PROBE
    BGP::Fault.behaviour_catalog.select { |b| b[:name].to_s.start_with?('gr_') }.each do |b|
      # Before start, so a behaviour left out starts no bgpd.
      next if ENV['GR_ONLY'] && !ENV['GR_ONLY'].split(',').include?(b[:name].to_s)
      start(n: b[:needs] == :n, restart_time: 3, stale_time: 3)
      @router.configure('debug bgp graceful-restart')
      mark = @router.log.size
      @sim.act('behaviour', 'name' => b[:name].to_s, 'drop' => [DROP], 'away' => 1)
      trace = []
      t0 = Time.now
      while Time.now - t0 < (ENV['GR_SECS'] || 7).to_f
        trace << [(Time.now - t0).round(1), ROUTES.collect { |p| d = @router.detail(p) ; d ? (d['stale'] ? 's' : 'y') : '-' }.join]
        sleep 0.1
      end
      puts "#{b[:name]}: withdrawn #{withdrawn} trace #{trace.chunk_while { |a, c| a[1] == c[1] }.collect { |g| "#{g.first[0]}:#{g.first[1]}" }.join(' ')} " \
           "state #{(@router.neighbor(LOCAL) || {})['bgpState']}"
      puts @router.log[mark..].lines.grep(/#{LOCAL}|graceful|GR|stale|EOR|End-of-RIB/i).grep_v(/KEEPALIVE|rcvd UPDATE w\/ attr/).first(40).join if ENV['GR_LOG']
      stop
    end
  end

  private

  # bgpd with `bgp graceful-restart`, its stalepath-time stale_time; the
  # sim listening for it and dialling it, its GR capability for IPv4
  # unicast with N when n, its Restart Time restart_time; the watcher.
  def start(n: false, restart_time: 120, stale_time: 360)
    wport = LabHelper::Local.free_port(WATCHER)
    @router = F.new(:local => FRR, :as => 65002, :router_id => '10.0.0.2', :peer => LOCAL, :peer_as => 65001,
                    :port => LabHelper::Local.free_port,
                    :more_peers => [{ :address => WATCHER, :as => 65003, :port => wport }],
                    :bgp_lines => [' bgp graceful-restart', " bgp graceful-restart stalepath-time #{stale_time}"],
                    # The sim dials each time it comes back, so bgpd does
                    # not, and bgpd's withdrawals go at once rather than
                    # after eBGP's 30 s advertisement interval.
                    :neighbor_lines => [" neighbor #{LOCAL} passive", " neighbor #{LOCAL} advertisement-interval 0",
                                        " neighbor #{WATCHER} advertisement-interval 0"])
    @catcher = Catcher.new
    @seen = []
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
                                  # End-of-RIB always: bgpd sets R on its first session
                                  # too, and logs "deferred path selection" until a GR
                                  # peer's End-of-RIB.
                                  'neighbors' => [{ 'address' => FRR, 'as' => 65002, 'port' => @router.listen_port,
                                                    'connect' => true, 'retry' => 0.5, 'end_of_rib' => true,
                                                    'capabilities' => ['as4_byte',
                                                                       { 'graceful_restart' => [flags, restart_time, [1, 1, 0x80]] }] }])
    @done = Queue.new
    @notified = Queue.new
    @sim.speaker.events.on_event do |e|
      @done << e.data['behaviour'] if e.kind == :log && e.message.to_s.include?('done on')
      @notified << e.data if e.kind == :notification && e.data[:direction] == 'receive'
    end
    @sim.start
    @router.up
    assert_equal(true, wait_for_bool(60) { @sim.speaker.peers.first.established? }, 'the sim is up')
    @sim.act('announce', 'prefixes' => ROUTES, 'next_hop' => '192.0.2.9')
    assert_equal(true, wait_for_bool(30) { ROUTES.all? { |p| @router.path(p) } },
                 "FRR holds our routes: #{@router.rib.inspect[0, 300]} #{(@router.neighbor(LOCAL) || {}).slice('bgpState', 'gracefulRestartInfo')}")
    assert_equal(true, wait_for_bool(30) { @watcher.is_established? }, 'the watcher is up')
  end

  def stop
    @watcher&.stop rescue nil
    @router&.down
    @sim&.stop
    @router = @sim = @watcher = nil
  end

  def needs(name) ; BGP::Fault.behaviour_catalog.find { |b| b[:name] == name }[:needs] ; end

  # Runs a behaviour that comes back, watching KEPT in bgpd's RIB until
  # it ends: :flushed if KEPT was ever gone or withdrawn, else :kept.
  def watch(name)
    @sim.act('behaviour', 'name' => name.to_s, 'drop' => [DROP], 'away' => 1)
    gone = false
    deadline = Time.now + 30
    until @done.size > 0 || Time.now > deadline
      gone ||= @router.path(KEPT).nil?
      sleep 0.05
    end
    assert_equal(name.to_s, @done.pop(:timeout => 0), "#{name} ran to its end")
    sleep 1
    gone || withdrawn.include?(KEPT) ? :flushed : :kept
  end

  # Everything withdrawn from the watcher so far.
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
