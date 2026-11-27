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

# Origin validation, bgp4rd beside FRR's bgpd: one Rtr::Cache serves
# both the same VRPs, one bgp4r-sim sends both the same routes, and the
# two must give each route the same state (RFC 6811 section 2), before
# and after a VRP change (section 4). docs/design/bgp-operations.md 7c,
# pull request 7c3. No Docker, no zebra.
#
#   ruby -I. test/functional/lab/rpki_frr_test.rb
#
# Omitted when FRR's bgpd or its RPKI module is not installed, unless
# LAB_REQUIRE_FRR=1.
#
# BGP:: names are written out in full, see Conventions in CLAUDE.md.

require 'test/unit'
require 'stringio'
require 'bgp4r'
require 'bgp/sim'
require 'bgp/rtr/cache'
require 'bgp/daemon/speaker'
require 'bgp/daemon/views'
require_relative 'lab_helper'

class LabRpkiFrrTest < Test::Unit::TestCase
  include LabHelper

  F = LabHelper::Frr
  SIM = '127.0.0.1'
  FRR = '127.0.0.2'
  BGP4RD = '127.0.0.3'

  # 10.5.1. Others were not run.
  MEASURED = (10..10).freeze

  VRPS = [{ 'prefix' => '192.0.2.0/24', 'asn' => 65_001 },
          { 'prefix' => '198.51.100.0/22', 'max_length' => 24, 'asn' => 65_099 },
          { 'prefix' => '10.0.0.0/8', 'max_length' => 16, 'asn' => 0 }].freeze

  # Each route, the AS_PATH after the sim's 65001, and the state RFC
  # 6811 section 2 gives it with VRPS.
  ROUTES = {
    '192.0.2.0/24'      => [[], 'valid'],              # Matched
    '198.51.100.0/24'   => [[], 'invalid'],            # Covered, the AS differs
    '198.51.101.0/24'   => [[65_099], 'valid'],        # within the Max Length
    '198.51.100.0/25'   => [[65_099], 'invalid'],      # longer than the Max Length
    '10.1.0.0/16'       => [[65_010], 'invalid'],      # AS 0 Matches nothing
    '203.0.113.0/24'    => [[], 'notfound'],           # not Covered
    '192.0.0.0/16'      => [[], 'notfound'],           # shorter than the VRP
  }.freeze

  # FRR's words, `rpkiValidationState`, as bgp4rd's.
  FRR_WORDS = { 'valid' => 'valid', 'invalid' => 'invalid', 'not found' => 'notfound' }.freeze

  def setup
    unless F.available? && F.rpki?
      flunk("FRR bgpd #{F.available? ? 'has no RPKI module' : 'is not installed'}") if ENV['LAB_REQUIRE_FRR'] == '1'
      omit("FRR bgpd #{F.available? ? 'has no RPKI module (frr-rpki-rtrlib)' : 'is not installed'}")
    end
    major = F.major
    unless F.measured?(MEASURED, major)
      omit("measured against FRR #{MEASURED}, found #{major.inspect}: re-measure before asserting")
    end
    Log.set_filename(StringIO.new)
    Log.level = Logger::WARN
    start
  end

  def teardown
    puts "\n== bgpd\n#{@router.log}" if @router && !passed?
    @sim&.stop
    @router&.down
    @sp&.stop
    @ticker&.kill
    @cache&.stop
  end

  def test_both_give_each_route_the_same_state
    expected = ROUTES.transform_values(&:last)
    assert(wait_until(15) { frr_states == expected }, "FRR: #{frr_states}")
    assert(wait_until(5) { bgp4rd_states == expected }, "bgp4rd: #{bgp4rd_states}")
    # Section 4: a VRP change, followed by both. 192.0.2.0/24 loses its
    # VRP, 203.0.113.0/24 gains one for another AS, and the AS 0 VRP
    # goes.
    @cache.change(announce: [{ 'prefix' => '203.0.113.0/24', 'asn' => 65_099 }],
                  withdraw: [VRPS[0], VRPS[2]])
    expected = expected.merge('192.0.2.0/24' => 'notfound', '203.0.113.0/24' => 'invalid', '10.1.0.0/16' => 'notfound')
    assert(wait_until(15) { frr_states == expected }, "FRR after the change: #{frr_states}")
    assert(wait_until(5) { bgp4rd_states == expected }, "bgp4rd after the change: #{bgp4rd_states}")
  end

  private

  def start
    @cache = BGP::Rtr::Cache.new('session_id' => 9, 'notify_every' => 0, 'retry' => 5, 'vrps' => VRPS)
    @cache.listen('127.0.0.1', 0)
    @ticker = Thread.new { loop { @cache.tick ; sleep 0.05 } }
    @router = F.new(:local => FRR, :peer => SIM, :peer_as => 65_001, :port => LabHelper::Local.free_port,
                    :neighbor_lines => [" neighbor #{SIM} passive"], :modules => ['rpki'],
                    :lines => ['rpki', ' rpki retry_interval 5', " rpki cache tcp 127.0.0.1 #{@cache.port} preference 1", 'exit'])
    @router.up
    port = LabHelper::Local.free_port(BGP4RD)
    @sp = BGP::Daemon::Speaker.new('as' => 65_000, 'router_id' => '10.0.0.3', 'listen_address' => BGP4RD, 'port' => port,
                                   'log_level' => 'error',
                                   'rpki' => { 'caches' => [{ 'address' => '127.0.0.1', 'port' => @cache.port, 'retry' => 1 }] },
                                   'neighbors' => [{ 'address' => SIM, 'as' => 65_001 }]).start
    @sim = BGP::Sim::Injector.new('router_id' => '10.0.0.1', 'as' => 65_001, 'listen_address' => SIM, 'local_address' => SIM,
                                  'port' => @router.port,
                                  'neighbors' => [{ 'address' => FRR, 'as' => 65_002, 'port' => @router.listen_port,
                                                    'connect' => true, 'retry' => 0.5, 'capabilities' => ['as4_byte'] },
                                                  { 'address' => BGP4RD, 'as' => 65_000, 'port' => port,
                                                    'connect' => true, 'retry' => 0.5, 'capabilities' => ['as4_byte'] }])
    @sim.start
    assert(wait_until(60) { @sim.speaker.peers.all?(&:established?) }, 'the sim is up with both')
    ROUTES.each do |prefix, (path, _)|
      @sim.act('announce', 'prefixes' => [prefix], 'next_hop' => '192.0.2.9', 'as_path' => path)
    end
  end

  # { prefix => state } from FRR's `show bgp ipv4 unicast PREFIX json`.
  def frr_states
    ROUTES.keys.to_h { |p| [p, FRR_WORDS[(@router.detail(p) || {})['rpkiValidationState']]] }
  end

  # { prefix => validation } from bgp4rd's show.routes.
  def bgp4rd_states
    rows = BGP::Daemon::Views.new(@sp).routes[:rows].to_h { |r| [r[:prefix], r[:validation]] }
    ROUTES.keys.to_h { |p| [p, rows[p]] }
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
