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

# Long-lived graceful restart, RFC 9494, with bgp4rd the helper and FRR's
# bgpd both ways: the peer that restarts, and a peer that receives
# bgp4rd's LLGR_STALE routes. No Docker, no zebra.
# docs/design/bgp-operations.md section 4, pull request 4a.
#
#   ruby -I. test/functional/lab/llgr_frr_test.rb
#
# Omitted when FRR's bgpd is not installed, unless LAB_REQUIRE_FRR=1.
#
# BGP:: names are written out in full, see Conventions in CLAUDE.md.

require 'test/unit'
require 'socket'
require 'stringio'
require 'tmpdir'
require 'fileutils'
require 'bgp4r'
require 'bgp/daemon'
require_relative 'lab_helper'

class LabLlgrFrrTest < Test::Unit::TestCase
  include LabHelper

  F = LabHelper::Frr
  FRR = '127.0.0.2'
  LOCAL = '127.0.0.1'
  SIM = '127.0.0.3'
  LLGR = [' bgp graceful-restart', ' bgp graceful-restart restart-time 1',
          ' bgp long-lived-graceful-restart stale-time 20'].freeze

  # 10.5.1 on the owner's VM on 2026-11-27. Others were not run.
  MEASURED = (10..10).freeze

  # Measured: FRR 10.5.1 lists IPv4 unicast in its LLGR capability with
  # F set, though its GR capability has F clear with no zebra. So
  # bgp4rd, back in the LLGR period, waits for its End-of-RIB.
  FRR_LLGR_F = 0x80

  # Measured too: with no LLGR line at all, bgpd still sends an LLGR
  # capability, IPv4 unicast with F set and an LLST of 0, beside a GR one
  # with no families, and so it gets LLGR_STALE routes (section 4.3).
  FRR_DEFAULT_LLGR = { [1, 1] => [0x80, 0] }.freeze

  def setup
    unless F.available?
      flunk('FRR bgpd is not installed') if ENV['LAB_REQUIRE_FRR'] == '1'
      omit('FRR bgpd is not installed')
    end
    major = F.major
    omit("measured against FRR #{MEASURED}, found #{major.inspect}: re-measure before asserting") unless F.measured?(MEASURED, major)
    Log.set_filename(StringIO.new)
    Log.level = Logger::WARN
    @dir = Dir.mktmpdir('bgp4r-llgr')
    @err = StringIO.new
  end

  def teardown
    @sim&.stop rescue nil
    @router&.down
    @server&.stop
    unless passed?
      puts "\n== bgpd\n#{@router.log}" if @router
      puts "\n== bgp4rd\n#{@err.string}" if @err
    end
    FileUtils.remove_entry(@dir) if @dir
  end

  # bgpd killed: its route is kept, then carries LLGR_STALE after its
  # Restart Time, 1 s; bgpd back, the route is fresh again.
  def test_frr_restarts
    start(LLGR)
    assert_equal({ [1, 1] => [FRR_LLGR_F, 20] }, BGP::Daemon::GracefulRestart.received_llgr(frr_open))
    @router.crash
    wait_for('the LLGR period') { adj_in == [['10.20.0.0/16', 'long_lived', true]] }
    assert_equal('long_lived', peer['graceful_restart']['state'])
    @router.up
    wait_for('bgpd back, and its route fresh', timeout: 30) { peer['state'] == 'established' && adj_in == [['10.20.0.0/16', nil, nil]] }
    wait_for('the End-of-RIB to end the period') { peer['graceful_restart']['state'].nil? }
    assert_include(gr_messages, 'session back: 1 long-lived family waits for End-of-RIB, the LLST running')
  end

  # A sim restarts: bgpd, which sent LLGR, gets the route with
  # LLGR_STALE (section 4.3), with LLGR configured or not.
  def test_frr_receives_llgr_stale_routes
    [LLGR, []].each do |lines|
      start(lines, sim: true)
      assert_equal(FRR_DEFAULT_LLGR, BGP::Daemon::GracefulRestart.received_llgr(frr_open)) if lines.empty?
      wait_for("bgpd to hold the sim's route") { @router.path('10.30.0.0/16') }
      @sim.stop
      wait_for('LLGR_STALE at bgpd') { (@router.detail('10.30.0.0/16') || {}).dig('community', 'string').to_s.include?('llgr-stale') }
      @router.down
      @server.stop
      @router = @server = @sim = nil
    end
  end

  private

  def start(lines, sim: false)
    @router = F.new(:local => FRR, :as => 65_002, :router_id => '10.0.0.2', :peer => LOCAL, :peer_as => 65_001,
                    :port => LabHelper::Local.free_port, :network => '10.20.0.0/16', :bgp_lines => lines)
    neighbors = [{ 'address' => FRR, 'as' => 65_002, 'graceful_restart' => true, 'long_lived_graceful_restart' => {} }]
    neighbors << { 'address' => SIM, 'as' => 65_003, 'graceful_restart' => true, 'long_lived_graceful_restart' => {} } if sim
    config = BGP::Daemon::Server.with_defaults(
      'as' => 65_001, 'router_id' => '10.0.0.1', 'listen_address' => LOCAL, 'port' => @router.port,
      'state_file' => File.join(@dir, "state#{rand(1 << 30)}.json"),
      'export' => { 'next_hops' => { 1 => '192.0.2.9' } }, 'neighbors' => neighbors)
    @server = BGP::Daemon::Server.new(StringIO.new, @err)
    sock = File.join(@dir, "bgp4rd#{rand(1 << 30)}.sock")
    assert_not_nil(@server.build(config, :socket => sock), "bgp4rd did not start: #{@err.string}")
    @client = BGP::Daemon::Client.new(sock)
    @gr = Queue.new
    @server.speaker.events.on_event { |e| @gr << e.message if e.kind == :gr }
    @router.up
    wait_for('the session with FRR', timeout: 60) { peer['state'] == 'established' }
    wait_for('FRR\'s route') { adj_in.include?(['10.20.0.0/16', nil, nil]) }
    dial_sim if sim
  end

  # A library Neighbor from SIM, with GR and LLGR for IPv4 unicast and an
  # LLST of 30 s, and one route.
  def dial_sim
    @sim = BGP::Neighbor.new(:my_as => 65_003, :remote_addr => LOCAL, :id => SIM)
    @sim.capability :as4_byte
    gr = BGP::OPT_PARM::CAP::Graceful_restart.new(0, 0)
    gr.add(1, 1, 0x80)
    @sim.capability gr
    @sim.capability BGP::OPT_PARM::CAP::Long_lived_graceful_restart.new(1, 1, 0x80, 30)
    s = Socket.tcp(LOCAL, @router.port, SIM)
    Thread.new { @sim.start(:session => s, :timeout => 5) rescue nil }
    wait_for('the sim') { @sim.is_established? }
    pa = BGP::Path_attribute.new(BGP::Origin.new(0), BGP::As_path.new(65_003), BGP::Next_hop.new(SIM))
    @sim.send_message(BGP::Update.new(pa, BGP::Nlri.new('10.30.0.0/16')))
  end

  def frr_open ; @server.speaker.peer(FRR).neighbor.session_info.peer ; end
  def peer ; @client.call('show.peers').find { |p| p['address'] == FRR } ; end

  # bgpd's own route in bgp4rd's Adj-RIB-In: prefix, stale, llgr_stale.
  def adj_in
    @client.call('show.adj_in', 'peer' => FRR)['rows'].collect { |r| [r['prefix'], r['stale'], r['llgr_stale']] }
                                                      .select { |p, _| p == '10.20.0.0/16' }
  end

  def gr_messages
    out = []
    out << @gr.pop until @gr.empty?
    out
  end
end
