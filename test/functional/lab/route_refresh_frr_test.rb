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
# Route refresh, RFC 2918 and RFC 7313, between bgp4rd and FRR's bgpd,
# both ways, with and without the Enhanced Route Refresh capability on
# our side. No Docker, no zebra.
#
#   ruby -I. test/functional/lab/route_refresh_frr_test.rb
#
# Omitted when FRR's bgpd is not installed, unless LAB_REQUIRE_FRR=1.
#
# FRR counts ROUTE-REFRESH messages of every subtype in its
# `messageStats` (`routeRefreshSent`, `routeRefreshRecv`); bgp4rd counts
# them by subtype on the peer row. The two must agree. Measured against
# 10.5.1 on the owner's VM on 2026-11-25: `clear bgp X soft in` is one
# request from FRR, and bgp4rd's answer is a BoRR, the routes and an
# EoRR, since FRR advertises capability 70; `peer.refresh` is one
# request from bgp4rd, and FRR answers between a BoRR and an EoRR only
# when we advertised 70 too. bgp4rd reads that BoRR and EoRR: FRR's
# route is marked stale, sent again, and kept.
#
# BGP:: names are written out in full, see Conventions in CLAUDE.md.

require 'test/unit'
require 'stringio'
require 'tmpdir'
require 'fileutils'
require 'bgp4r'
require 'bgp/daemon'
require_relative 'lab_helper'

class LabRouteRefreshFrrTest < Test::Unit::TestCase
  include LabHelper

  OUR_AS = 65001
  THEIR_AS = 65002
  FRR = '127.0.0.2'
  F = LabHelper::Frr
  # FRR refuses a loopback NEXT_HOP, so ours is a documentation address.
  OUR_NEXT_HOP = '192.0.2.9'
  ENHANCED = %w[as4_byte route_refresh enhanced_route_refresh].freeze
  PLAIN = %w[as4_byte route_refresh].freeze

  # 10.5.1 on the owner's VM on 2026-11-25. Others were not run.
  MEASURED = (10..10).freeze

  def setup
    unless F.available?
      flunk('FRR bgpd is not installed') if ENV['LAB_REQUIRE_FRR'] == '1'
      omit('FRR bgpd is not installed')
    end
    major = F.major
    unless F.measured?(MEASURED, major)
      omit("measured against FRR #{MEASURED}, found #{major.inspect}: re-measure before asserting")
    end
    @dir = Dir.mktmpdir('bgp4r-refresh')
    @err = StringIO.new
  end

  def teardown
    @router.down if @router
    @server.stop if @server
    unless passed?
      puts "\n== bgpd\n#{@router.log}" if @router
      puts "\n== bgp4rd\n#{@err.string}" if @err
    end
    FileUtils.remove_entry(@dir) if @dir
  end

  # FRR asks; bgp4rd answers between BoRR and EoRR, since FRR advertised
  # capability 70, whatever ours says.
  def test_frr_asks_and_bgp4rd_answers
    [ENHANCED, PLAIN].each do |caps|
      start(caps)
      updates = stats['updatesRecv']
      @router.vty("clear bgp #{LOCAL} soft in")
      wait_for('bgp4rd to answer') { (refresh || {})['answered'] == 1 }
      r = refresh
      assert_equal({ 'normal' => 1 }, r['received'], caps.inspect)
      assert_equal({ 'borr' => 1, 'eorr' => 1 }, r['sent'], caps.inspect)
      wait_for('FRR to count our EoRR') { stats['routeRefreshRecv'] == 2 }
      assert_counts_agree(r)
      assert_operator(stats['updatesRecv'], :>, updates, 'our routes came again')
      stop
    end
  end

  # bgp4rd asks with `peer.refresh`; FRR answers, wrapped only when we
  # advertised capability 70.
  def test_bgp4rd_asks_and_frr_answers
    [[ENHANCED, { 'normal' => 1, 'borr' => 1, 'eorr' => 1 }], [PLAIN, { 'normal' => 0 }]].each do |caps, want_sent_by_frr|
      start(caps)
      updates = stats['updatesSent']
      @client.call('peer.refresh', 'peer' => FRR, 'afi' => 1, 'safi' => 1)
      wait_for('FRR to count our request') { stats['routeRefreshRecv'] == 1 }
      # FRR's routes again, and a moment for an EoRR after them, so a
      # BoRR that should not come has had its chance.
      wait_for('FRR\'s answer') { stats['updatesSent'] > updates }
      sleep 2
      expect = want_sent_by_frr.reject { |k, _| k == 'normal' }
      assert_equal(expect, refresh['received'] || {}, caps.inspect)
      assert_equal({ 'normal' => 1 }, refresh['sent'], caps.inspect)
      assert_counts_agree(refresh)
      stop
    end
  end

  # 2b: FRR's answer comes between a BoRR and an EoRR, so bgp4rd marks
  # FRR's routes stale, FRR sends them again, and the EoRR removes
  # nothing. RFC 7313 section 4, read from a real sender.
  def test_frr_answer_is_marked_then_kept
    start(ENHANCED)
    marks = Queue.new
    @server.speaker.events.on_event { |e| marks << e.data if e.kind == :refresh && (e.data[:stale] || e.data[:purged]) }
    # Measured against 10.5.1: FRR sends our two routes back, AS_PATH
    # "65002 65001", which the Adj-RIB-In keeps and the decision passes
    # over, beside its own. All three are marked and all three come back.
    wait_for('FRR\'s three routes') { adj_in.size == 3 }
    @client.call('peer.refresh', 'peer' => FRR, 'afi' => 1, 'safi' => 1)
    stale = marks.pop(:timeout => 10)
    purged = marks.pop(:timeout => 10)
    assert_equal({ :afi => 1, :safi => 1, :marked => 3, :seconds => 180 }, stale && stale[:stale])
    assert_equal({ :purged => { :afi => 1, :safi => 1, :removed => 0 }, :reason => 'EoRR' }, purged)
    assert_equal([['10.10.0.0/16', nil], ['10.11.0.0/16', nil], ['10.20.0.0/16', nil]],
                 adj_in.collect { |r| [r['prefix'], r['stale']] })
    assert_equal([0, []], refresh.values_at('stale', 'waiting'))
  end

  private

  LOCAL = '127.0.0.1'

  def start(caps)
    @router = F.new(:local => FRR, :as => THEIR_AS, :router_id => '10.0.0.2',
                    :peer => LOCAL, :peer_as => OUR_AS,
                    :port => LabHelper::Local.free_port, :network => '10.20.0.0/16')
    config = BGP::Daemon::Server.with_defaults(
      'as' => OUR_AS, 'router_id' => '10.0.0.1',
      'listen_address' => LOCAL, 'port' => @router.port,
      'state_file' => File.join(@dir, 'state.json'),
      'export' => { 'next_hops' => { 1 => OUR_NEXT_HOP } },
      'originate' => [{ 'prefixes' => ['10.10.0.0/16', '10.11.0.0/16'] }],
      'neighbors' => [{ 'address' => FRR, 'as' => THEIR_AS, 'capabilities' => caps }])
    @server = BGP::Daemon::Server.new(StringIO.new, @err)
    assert_not_nil(@server.build(config, :socket => File.join(@dir, 'bgp4rd.sock')),
                   "bgp4rd did not start: #{@err.string}")
    @router.up
    @client = BGP::Daemon::Client.new(File.join(@dir, 'bgp4rd.sock'))
    wait_for('the session with FRR to be established', timeout: 60) { peer['state'] == 'established' }
    wait_for('FRR to hold our routes') { @router.path('10.11.0.0/16') }
  end

  def stop
    @router.down
    @server.stop
    @router = @server = nil
  end

  def peer ; @client.call('show.peers').first ; end
  def refresh ; peer['refresh'] ; end
  def adj_in ; @client.call('show.adj_in', 'peer' => FRR)['rows'] ; end
  def stats ; @router.neighbor(LOCAL)['messageStats'] ; end

  # What one side sent, the other read, every subtype together.
  def assert_counts_agree(r)
    s = stats
    assert_equal(s['routeRefreshSent'], r['received'].values.sum, 'FRR sent what we read')
    assert_equal(s['routeRefreshRecv'], r['sent'].values.sum, 'FRR read what we sent')
  end
end
