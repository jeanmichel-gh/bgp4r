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

# Graceful restart, RFC 4724 section 4.2, with bgp4rd as the Receiving
# Speaker and FRR's bgpd the speaker that restarts. bgpd is killed, which
# sends no Cease, and started again. No Docker, no zebra.
#
#   ruby -I. test/functional/lab/graceful_restart_frr_test.rb
#
# Omitted when FRR's bgpd is not installed, unless LAB_REQUIRE_FRR=1.
#
# Measured against 10.5.1 on the owner's VM on 2026-11-26. With `bgp
# graceful-restart`, bgpd advertises Restart Flags 12 (R and N set, R on
# its first session too), its Restart Time, and IPv4 unicast with F
# clear: with no zebra it keeps no forwarding state. `bgp
# graceful-restart preserve-fw-state` sets F. bgpd sends End-of-RIB.
#
# With bgp4rd's N bit too (RFC 8538, pull request 3b), N is exchanged:
# `clear bgp` sends a Hard Reset carrying 6/4, `neighbor shutdown` one
# carrying 6/2, and bgp4rd flushes on both; bgp4rd's `peer.clear` sends
# a graceful 6/4 and keeps bgpd's routes; its `peer.stop` sends a Hard
# Reset carrying 6/2, and bgpd drops ours.
#
# BGP:: names are written out in full, see Conventions in CLAUDE.md.

require 'test/unit'
require 'stringio'
require 'tmpdir'
require 'fileutils'
require 'bgp4r'
require 'bgp/daemon'
require_relative 'lab_helper'

class LabGracefulRestartFrrTest < Test::Unit::TestCase
  include LabHelper

  F = LabHelper::Frr
  FRR = '127.0.0.2'
  LOCAL = '127.0.0.1'
  GR = [' bgp graceful-restart', ' bgp graceful-restart restart-time 60'].freeze

  # 10.5.1 on the owner's VM on 2026-11-26. Others were not run.
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
    @dir = Dir.mktmpdir('bgp4r-gr')
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

  # F clear: kept through the restart, gone at once when bgpd is back,
  # then sent again.
  def test_frr_restarts_with_f_clear
    start(GR)
    assert_equal({ :restart_state => 12, :restart_time => 60, :families => [{ :afi => 1, :safi => 1, :flags => 0 }] },
                 frr_capability)
    restart
    wait_for('bgpd to be back') { peer['state'] == 'established' }
    wait_for('the route again, fresh') { adj_in == [['10.20.0.0/16', nil]] }
    # Two: bgpd's route, and ours, which bgpd had sent back.
    assert_equal(['helper started after tcp: 1 family kept stale for the peer\'s Restart Time, 60 s',
                  'F bit clear for AFI 1 SAFI 1: 2 stale removed'], gr_messages)
  end

  # F set: kept until bgpd's End-of-RIB, which removes the one route it
  # did not send again.
  def test_frr_restarts_with_f_set_and_end_of_rib_ends_it
    start(GR + [' bgp graceful-restart preserve-fw-state'])
    assert_equal(128, frr_capability[:families].first[:flags])
    @router.network = '10.21.0.0/16'
    restart
    wait_for('bgpd to be back') { peer['state'] == 'established' }
    wait_for('End-of-RIB to remove the old route') { adj_in == [['10.21.0.0/16', nil]] }
    assert_equal(['helper started after tcp: 1 family kept stale for the peer\'s Restart Time, 60 s',
                  'session back: 1 family waits for End-of-RIB, at most 180 s',
                  'End-of-RIB for AFI 1 SAFI 1: 1 stale removed'], gr_messages)
  end

  # bgpd's own resets are Hard Resets, and bgp4rd flushes.
  def test_under_n_frr_clear_and_shutdown_are_hard_resets
    { "clear bgp #{LOCAL}" => '0604', 'shutdown' => '0602' }.each do |what, inner|
      start(GR + [' bgp graceful-restart preserve-fw-state'], 'notification' => true)
      assert_equal(true, peer['graceful_restart']['notification'], 'N exchanged')
      what == 'shutdown' ? @router.configure("router bgp #{@router.as}", "neighbor #{LOCAL} shutdown") : @router.vty(what)
      wait_for('the routes flushed') { adj_in.empty? }
      n = @notes.pop(:timeout => 5)
      assert_equal([6, 9, inner], [n[:code], n[:subcode], n[:octets]], what)
      @router.down
      @server.stop
      @router = @server = nil
    end
  end

  # bgp4rd's peer.clear is graceful under N: bgpd's routes are kept,
  # stale, until bgpd's End-of-RIB on the new session.
  def test_under_n_our_clear_keeps_and_our_stop_flushes
    start(GR + [' bgp graceful-restart preserve-fw-state'], 'notification' => true)
    assert_equal('cease/administrative_reset', @client.call('peer.clear', 'peer' => FRR)['notification'])
    wait_for('the route kept stale') { adj_in.include?(['10.20.0.0/16', 'restart']) }
    wait_for('bgpd back and its End-of-RIB', timeout: 60) { adj_in.include?(['10.20.0.0/16', nil]) }
    wait_for('bgpd to hold our route') { @router.path('10.10.0.0/16') }
    assert_equal('cease/hard_reset/administrative_shutdown', @client.call('peer.stop', 'peer' => FRR)['notification'])
    wait_for('bgp4rd to flush') { adj_in.empty? }
    wait_for('bgpd to drop our route') { @router.path('10.10.0.0/16').nil? }
  end

  private

  def start(lines, gr = true)
    @router = F.new(:local => FRR, :as => 65002, :router_id => '10.0.0.2', :peer => LOCAL, :peer_as => 65001,
                    :port => LabHelper::Local.free_port, :network => '10.20.0.0/16', :bgp_lines => lines)
    config = BGP::Daemon::Server.with_defaults(
      'as' => 65001, 'router_id' => '10.0.0.1', 'listen_address' => LOCAL, 'port' => @router.port,
      'state_file' => File.join(@dir, 'state.json'),
      'export' => { 'next_hops' => { 1 => '192.0.2.9' } }, 'originate' => [{ 'prefixes' => ['10.10.0.0/16'] }],
      'neighbors' => [{ 'address' => FRR, 'as' => 65002, 'graceful_restart' => gr }])
    @server = BGP::Daemon::Server.new(StringIO.new, @err)
    assert_not_nil(@server.build(config, :socket => File.join(@dir, 'bgp4rd.sock')), "bgp4rd did not start: #{@err.string}")
    @client = BGP::Daemon::Client.new(File.join(@dir, 'bgp4rd.sock'))
    @gr = Queue.new
    @notes = Queue.new
    @server.speaker.events.on_event do |e|
      @gr << e.message if e.kind == :gr
      @notes << e.data if e.kind == :notification && e.data[:direction] == 'receive'
    end
    @router.up
    wait_for('the session with FRR to be established', timeout: 60) { peer['state'] == 'established' }
    wait_for('FRR\'s route') { adj_in.include?(['10.20.0.0/16', nil]) }
  end

  # bgpd killed, the route kept stale, bgpd started again.
  def restart
    @router.crash
    wait_for('the route kept stale') { adj_in == [['10.20.0.0/16', 'restart']] }
    assert_equal('restarting', peer['graceful_restart']['state'])
    @router.up
  end

  def frr_capability
    BGP::Daemon::GracefulRestart.received(@server.speaker.peer(FRR).neighbor.session_info.peer)
  end

  def peer ; @client.call('show.peers').first ; end
  # bgpd's own routes in bgp4rd's Adj-RIB-In. Ours, 10.10.0.0/16, comes
  # back from bgpd with our AS in its path, and is left out.
  def adj_in
    @client.call('show.adj_in', 'peer' => FRR)['rows'].collect { |r| [r['prefix'], r['stale']] }
                                                      .reject { |p, _| p == '10.10.0.0/16' }
  end

  def gr_messages
    out = []
    out << @gr.pop until @gr.empty?
    out
  end
end
