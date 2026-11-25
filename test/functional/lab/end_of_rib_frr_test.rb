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
# End-of-RIB, RFC 4724 section 2, between bgp4rd and FRR's bgpd, both
# ways. No Docker, no zebra.
#
#   ruby -I. test/functional/lab/end_of_rib_frr_test.rb
#
# Omitted when FRR's bgpd is not installed, unless LAB_REQUIRE_FRR=1.
#
# FRR sends End-of-RIB after its first table with no graceful restart
# negotiated, and bgp4rd records it. FRR tracks a received End-of-RIB
# only under graceful restart (`gracefulRestartInfo.endOfRibRecv` stays
# empty without it), so ours is read from its UPDATE count: one route
# is one UPDATE without `end_of_rib`, and two with it. Measured against
# 10.5.1 on the owner's VM on 2026-11-25.
#
# BGP:: names are written out in full, see Conventions in CLAUDE.md.

require 'test/unit'
require 'stringio'
require 'tmpdir'
require 'fileutils'
require 'bgp4r'
require 'bgp/daemon'
require_relative 'lab_helper'

class LabEndOfRibFrrTest < Test::Unit::TestCase
  include LabHelper

  OUR_AS = 65001
  THEIR_AS = 65002
  FRR = '127.0.0.2'
  F = LabHelper::Frr
  # FRR refuses a loopback NEXT_HOP, so ours is a documentation address.
  OUR_NEXT_HOP = '192.0.2.9'

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
    @dir = Dir.mktmpdir('bgp4r-eor')
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

  def test_frr_sends_one_and_bgp4rd_records_it
    start(end_of_rib: false)
    wait_for('FRR\'s End-of-RIB') { peer['end_of_rib_received'] }
    assert_equal([{ 'afi' => 1, 'safi' => 1 }], peer['end_of_rib_received'])
  end

  # Ours: one route and a marker are two UPDATEs.
  def test_bgp4rd_sends_one_after_its_route
    start(end_of_rib: true)
    assert_equal(2, frr_updates)
  end

  # The control: the same route alone is one UPDATE.
  def test_without_end_of_rib_one_route_is_one_update
    start(end_of_rib: false)
    assert_equal(1, frr_updates)
  end

  private

  def start(end_of_rib:)
    @router = F.new(:local => FRR, :as => THEIR_AS, :router_id => '10.0.0.2',
                    :peer => '127.0.0.1', :peer_as => OUR_AS,
                    :port => LabHelper::Local.free_port, :network => '10.20.0.0/16')
    config = BGP::Daemon::Server.with_defaults(
      'as' => OUR_AS, 'router_id' => '10.0.0.1',
      'listen_address' => '127.0.0.1', 'port' => @router.port,
      'state_file' => File.join(@dir, 'state.json'),
      'export' => { 'next_hops' => { 1 => OUR_NEXT_HOP } },
      'originate' => [{ 'prefixes' => ['10.10.0.0/16'] }],
      'neighbors' => [{ 'address' => FRR, 'as' => THEIR_AS, 'end_of_rib' => end_of_rib }])
    @server = BGP::Daemon::Server.new(StringIO.new, @err)
    assert_not_nil(@server.build(config, :socket => File.join(@dir, 'bgp4rd.sock')),
                   "bgp4rd did not start: #{@err.string}")
    @router.up
    @client = BGP::Daemon::Client.new(File.join(@dir, 'bgp4rd.sock'))
    wait_for('the session with FRR to be established', timeout: 60) { peer['state'] == 'established' }
  end

  def peer
    @client.call('show.peers').first
  end

  # FRR's UPDATE count from us, once it holds our route and a moment
  # has passed for anything after it.
  def frr_updates
    wait_for('FRR to accept our route') { @router.path('10.10.0.0/16') }
    sleep 3
    @router.updates_received('127.0.0.1')
  end
end
