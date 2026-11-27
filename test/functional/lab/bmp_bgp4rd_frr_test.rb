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

# bgp4rd and FRR's bgpd, each a monitored router of one bgp4r-bmp
# station, both peers of one bgp4r-sim: the station's two views of that
# peer must hold the same routes, after the announcement, after a
# withdrawal and after the sim goes. docs/design/bgp-operations.md 8c,
# docs/bmp.md section 7. No Docker, no zebra.
#
#   ruby -I. test/functional/lab/bmp_bgp4rd_frr_test.rb
#
# Omitted when FRR's bgpd is not installed, unless LAB_REQUIRE_FRR=1.
#
# BGP:: names are written out in full, see Conventions in CLAUDE.md.

require 'test/unit'
require 'stringio'
require 'bgp4r'
require 'bgp/sim'
require 'bgp/bmp/station'
require 'bgp/daemon/speaker'
require_relative 'lab_helper'

class LabBmpBgp4rdFrrTest < Test::Unit::TestCase
  include LabHelper

  F = LabHelper::Frr
  SIM = '127.0.0.1'
  FRR = '127.0.0.2'
  BGP4RD = '127.0.0.3'

  # 10.5.1. Others were not run.
  MEASURED = (10..10).freeze

  # FRR 10.5.1 puts its own AS first in a pre-policy route's AS_PATH
  # (docs/bmp.md section 6); bgp4rd sends the UPDATE as received.
  FRR_PREPENDS = [65_002].freeze

  def setup
    unless F.available?
      flunk('FRR bgpd is not installed') if ENV['LAB_REQUIRE_FRR'] == '1'
      omit('FRR bgpd is not installed')
    end
    major = F.major
    omit("measured against FRR #{MEASURED}, found #{major.inspect}: re-measure before asserting") unless F.measured?(MEASURED, major)
    Log.set_filename(StringIO.new)
    Log.level = Logger::WARN
    start
  end

  def teardown
    puts "\n== bgpd\n#{@router.log}" if @router && !passed?
    @sim&.stop
    @sp&.stop
    @router&.down
    @station&.stop
  end

  def test_both_views_of_the_sim_hold_the_same_routes
    want = %w[192.0.2.0/24 198.51.100.0/24]
    assert(wait_until(15) { view('bgp4rd-lab').keys == want && view('bgp4r-lab-frr').keys == want },
           "bgp4rd #{view('bgp4rd-lab').keys}, FRR #{view('bgp4r-lab-frr').keys}")
    ours, theirs = view('bgp4rd-lab'), view('bgp4r-lab-frr')
    want.each do |p|
      assert_equal(same(theirs[p]), same(ours[p]), p)
      assert_equal([65_001, 65_010], ours[p][:path_attributes][:as_path][:sequence], 'bgp4rd: as received')
      assert_equal(FRR_PREPENDS + [65_001, 65_010], theirs[p][:path_attributes][:as_path][:sequence], 'FRR')
    end
    @sim.act('withdraw', 'prefixes' => %w[198.51.100.0/24])
    assert(wait_until(10) { view('bgp4rd-lab').keys == %w[192.0.2.0/24] && view('bgp4r-lab-frr').keys == %w[192.0.2.0/24] },
           "bgp4rd #{view('bgp4rd-lab').keys}, FRR #{view('bgp4r-lab-frr').keys}")
    @sim.stop
    @sim = nil
    assert(wait_until(10) { %w[bgp4rd-lab bgp4r-lab-frr].all? { |r| sim_peer(r) && !sim_peer(r)[:up] } }, 'a Peer Down from each')
    assert_equal([4, 4], %w[bgp4rd-lab bgp4r-lab-frr].collect { |r| sim_peer(r)[:down_reason] }, 'both: closed without a NOTIFICATION')
    assert_equal([{}, {}], %w[bgp4rd-lab bgp4r-lab-frr].collect { |r| view(r) })
    findings = @station.routers[:routers].to_h { |r| [r[:sys_name], r[:findings].keys] }
    assert_equal([], findings['bgp4rd-lab'], 'bgp4rd sends nothing a station finds wrong')
  end

  private

  def start
    @station = BGP::Bmp::Station.new
    port = @station.listen('127.0.0.1', 0)
    nl = [" neighbor #{SIM} passive", " neighbor #{SIM} advertisement-interval 0",
          ' address-family ipv4 unicast', "  neighbor #{SIM} soft-reconfiguration inbound", ' exit-address-family',
          ' bmp targets t1', "  bmp connect 127.0.0.1 port #{port} min-retry 100 max-retry 1000",
          '  bmp monitor ipv4 unicast pre-policy', ' exit']
    @router = F.new(:local => FRR, :peer => SIM, :peer_as => 65_001, :port => LabHelper::Local.free_port,
                    :modules => ['bmp'], :neighbor_lines => nl)
    @router.up
    bport = LabHelper::Local.free_port(BGP4RD)
    @sp = BGP::Daemon::Speaker.new('as' => 65_000, 'router_id' => '10.0.0.3', 'listen_address' => BGP4RD, 'port' => bport,
                                   'log_level' => 'error',
                                   'bmp' => { 'stations' => [{ 'address' => '127.0.0.1', 'port' => port, 'retry' => 0.5 }],
                                              'sys_name' => 'bgp4rd-lab' },
                                   'neighbors' => [{ 'address' => SIM, 'as' => 65_001 }]).start
    @sim = BGP::Sim::Injector.new('router_id' => '10.0.0.1', 'as' => 65_001, 'listen_address' => SIM, 'local_address' => SIM,
                                  'port' => @router.port,
                                  'neighbors' => [{ 'address' => FRR, 'as' => 65_002, 'port' => @router.listen_port,
                                                    'connect' => true, 'retry' => 0.5, 'capabilities' => ['as4_byte'] },
                                                  { 'address' => BGP4RD, 'as' => 65_000, 'port' => bport,
                                                    'connect' => true, 'retry' => 0.5, 'capabilities' => ['as4_byte'] }])
    @sim.start
    assert(wait_until(60) { @sim.speaker.peers.all?(&:established?) }, 'the sim is up with both')
    assert(wait_until(30) { %w[bgp4rd-lab bgp4r-lab-frr].all? { |r| sim_peer(r)&.dig(:up) } }, 'both report the sim')
    @sim.act('announce', 'prefixes' => %w[192.0.2.0/24 198.51.100.0/24], 'next_hop' => '192.0.2.9',
                         'as_path' => [65_010], 'med' => 10, 'communities' => ['65001:1'])
  end

  # { prefix => route } of the sim's peer in one router's pre-policy view.
  def view(router)
    @station.routes('router' => router, 'peer' => SIM, 'view' => 'pre_policy')[:routes]
            .sort_by { |r| r[:nlri][:prefix] }.to_h { |r| [r[:nlri][:prefix], r] }
  end

  def sim_peer(router) ; @station.peers('router' => router)[:peers].find { |p| p[:address] == SIM } ; end

  # What both routers must agree on: the route less the AS_PATH and the
  # router.
  def same(r)
    a = r[:path_attributes].reject { |k, _| k == :as_path }
    [r[:afi], r[:safi], r[:nlri], r[:next_hop], a, r[:peer].values_at(:asn, :bgp_id)]
  end

  def wait_until(seconds)
    deadline = Time.now + seconds
    until Time.now > deadline
      return true if yield
      sleep 0.2
    end
    false
  end
end
