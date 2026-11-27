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

# FRR's bgpd_bmp dialing bgp4r's station: a bgp4r-sim peer announces two
# routes, withdraws one and goes, and the station's pre-policy,
# post-policy and Loc-RIB views follow, beside FRR's own table.
# docs/design/bgp-operations.md 8b, docs/bmp.md section 6. No Docker,
# no zebra.
#
#   ruby -I. test/functional/lab/bmp_frr_test.rb
#
# Omitted when FRR's bgpd is not installed, unless LAB_REQUIRE_FRR=1.
#
# BGP:: names are written out in full, see Conventions in CLAUDE.md.

require 'test/unit'
require 'stringio'
require 'bgp4r'
require 'bgp/sim'
require 'bgp/bmp/station'
require_relative 'lab_helper'

class LabBmpFrrTest < Test::Unit::TestCase
  include LabHelper

  F = LabHelper::Frr
  SIM = '127.0.0.1'
  FRR = '127.0.0.2'

  # 10.5.1. Others were not run.
  MEASURED = (10..10).freeze

  # Measured on FRR 10.5.1 (docs/bmp.md section 6). Each is what FRR
  # does, asserted so that a change in FRR shows.
  #
  # The AS_PATH of a pre-policy and a post-policy route starts with
  # FRR's own AS, where the sim sent 65001 65010 and FRR's table shows
  # 65001 65010.
  FRR_PREPENDS = [65_002].freeze
  # When the sim goes, FRR drops its route from its table and sends no
  # Loc-RIB withdrawal for it.
  FRR_KEEPS_LOC_RIB = true

  ATTRS = { 'next_hop' => '192.0.2.9', 'as_path' => [65_010], 'med' => 10, 'communities' => ['65001:1'] }.freeze

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
    @router&.down
    @station&.stop
  end

  def test_the_station_follows_frr
    assert(wait_until(15) { frr_prefixes.size == 3 && loc_rib == frr_prefixes }, "Loc-RIB #{loc_rib}, FRR #{frr_prefixes}")
    init = @lines.string.lines.collect { |l| JSON.parse(l) }.find { |l| l['type'] == 'initiation' }
    assert_equal('bgp4r-lab-frr', init['sys_name'])
    assert_match(/\AFRRouting 10\./, @station.routers[:routers].first[:sys_descr])
    sim = @station.peers[:peers].find { |p| p[:address] == SIM }
    assert_equal([0, 65_001, '10.0.0.1', true], [sim[:peer_type], sim[:asn], sim[:bgp_id], sim[:up]])
    assert_equal([3, 65_002, '10.0.0.2'], @station.peers[:peers].find { |p| p[:peer_type] == 3 }.values_at(:peer_type, :asn, :bgp_id))
    %w[pre_policy post_policy].each do |view|
      rows = sim_routes(view)
      assert_equal(%w[192.0.2.0/24 198.51.100.0/24], rows.keys.sort, view)
      rows.each_value do |r|
        a = r[:path_attributes]
        assert_equal([FRR_PREPENDS + [65_001, 65_010], '192.0.2.9', 10, ['65001:1']],
                     [a[:as_path][:sequence], r[:next_hop], a[:med], a[:communities]], view)
      end
    end
    assert_equal('65001 65010', @router.vty_json('show bgp ipv4 unicast json')['routes']['192.0.2.0/24'].first['path'],
                 'FRR\'s own table, without its AS')

    @sim.act('withdraw', 'prefixes' => %w[198.51.100.0/24])
    assert(wait_until(10) { frr_prefixes.size == 2 && loc_rib == frr_prefixes }, "Loc-RIB #{loc_rib}, FRR #{frr_prefixes}")
    assert(wait_until(5) { %w[pre_policy post_policy].all? { |v| sim_routes(v).keys == %w[192.0.2.0/24] } },
           "#{sim_routes('pre_policy').keys} #{sim_routes('post_policy').keys}")

    @sim.stop
    @sim = nil
    assert(wait_until(10) { !@station.peers[:peers].find { |p| p[:address] == SIM }[:up] }, 'a Peer Down for the sim')
    sim = @station.peers[:peers].find { |p| p[:address] == SIM }
    assert_equal([4, { 'pre_policy' => 0, 'post_policy' => 0, 'loc_rib' => 0 }], [sim[:down_reason], sim[:routes]])
    assert(wait_until(10) { frr_prefixes == %w[203.0.113.0/24] }, "FRR #{frr_prefixes}")
    sleep 3
    if FRR_KEEPS_LOC_RIB
      assert_equal(%w[192.0.2.0/24 203.0.113.0/24], loc_rib, 'no Loc-RIB withdrawal from FRR 10.5.1')
    else
      assert_equal(frr_prefixes, loc_rib)
    end
    findings = @station.routers[:routers].first[:findings].keys
    assert_equal([], findings - %i[reserved_flags unknown_stat], 'nothing but what docs/bmp.md section 4 lists')
  end

  private

  def start
    @lines = StringIO.new
    @station = BGP::Bmp::Station.new(:lines => @lines)
    port = @station.listen('127.0.0.1', 0)
    nl = [" neighbor #{SIM} passive", " neighbor #{SIM} advertisement-interval 0",
          ' address-family ipv4 unicast', "  neighbor #{SIM} soft-reconfiguration inbound", ' exit-address-family',
          ' bmp targets t1', "  bmp connect 127.0.0.1 port #{port} min-retry 100 max-retry 1000",
          '  bmp monitor ipv4 unicast pre-policy', '  bmp monitor ipv4 unicast post-policy',
          '  bmp monitor ipv4 unicast loc-rib', ' exit']
    @router = F.new(:local => FRR, :peer => SIM, :peer_as => 65_001, :port => LabHelper::Local.free_port,
                    :modules => ['bmp'], :neighbor_lines => nl, :network => '203.0.113.0/24')
    @router.up
    @sim = BGP::Sim::Injector.new('router_id' => '10.0.0.1', 'as' => 65_001, 'listen_address' => SIM, 'local_address' => SIM,
                                  'port' => @router.port,
                                  'neighbors' => [{ 'address' => FRR, 'as' => 65_002, 'port' => @router.listen_port,
                                                    'connect' => true, 'retry' => 0.5, 'capabilities' => ['as4_byte'] }])
    @sim.start
    assert(wait_until(60) { @sim.speaker.peers.first.established? }, 'the sim is up')
    assert(wait_until(30) { @station.peers[:peers].any? { |p| p[:address] == SIM && p[:up] } }, 'FRR dialed the station')
    @sim.act('announce', ATTRS.merge('prefixes' => %w[192.0.2.0/24 198.51.100.0/24]))
  end

  def frr_prefixes ; ((@router.vty_json('show bgp ipv4 unicast json') || {})['routes'] || {}).keys.sort ; end
  def loc_rib ; @station.routes('view' => 'loc_rib')[:routes].collect { |r| r[:nlri][:prefix] }.sort ; end

  def sim_routes(view)
    @station.routes('view' => view, 'peer' => SIM)[:routes].to_h { |r| [r[:nlri][:prefix], r] }
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
