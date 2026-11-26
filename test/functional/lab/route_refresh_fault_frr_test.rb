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

# The ROUTE-REFRESH fault matrix against FRR's bgpd: every
# `BGP::Fault::REFRESH` case and the `borr_without_eorr` behaviour,
# injected by bgp4r-sim on a session of its own, and what FRR did, held
# to a table measured against 10.5.1 on the owner's VM on 2026-11-26.
# docs/design/bgp-operations.md section 2, pull request 2c. No Docker,
# no zebra.
#
#   ruby -I. test/functional/lab/route_refresh_fault_frr_test.rb
#
# Omitted when FRR's bgpd is not installed, unless LAB_REQUIRE_FRR=1.
#
# BGP:: names are written out in full, see Conventions in CLAUDE.md.

require 'test/unit'
require 'stringio'
require 'bgp4r'
require 'bgp/sim'
require_relative 'lab_helper'

class LabRouteRefreshFaultFrrTest < Test::Unit::TestCase
  include LabHelper

  F = LabHelper::Frr
  LOCAL = '127.0.0.1'
  FRR = '127.0.0.2'
  ROUTES = %w[10.10.0.0/16 10.11.0.0/16].freeze

  # 10.5.1. Others were not run.
  MEASURED = (10..10).freeze

  # What FRR 10.5.1 did, and where it is not what the RFC expects:
  #
  # - subtype 3 and 255 are read as requests and answered, with a BoRR,
  #   the routes and an EoRR, where RFC 7313 section 5 says "MUST
  #   ignore". Its log says "rcvd route-refresh (REQUEST)".
  # - the long BoRR gets 7/1 with no data, where section 5 says the data
  #   "MUST contain the complete ROUTE-REFRESH message". Its log says
  #   "7/1 [...] 0 bytes".
  # - the short EoRR gets 1/2, Bad Message Length: 22 octets is below
  #   the 23 of any ROUTE-REFRESH, which RFC 4271 section 6.1 checks in
  #   the header, before section 5's check is reached.
  FRR_DID = {
    :refresh_unadvertised_family => :ignored,
    :refresh_subtype_unknown     => :answered,
    :refresh_borr_length         => [:notification, 7, 1, ''],
    :refresh_eorr_length         => [:notification, 1, 2],
    :refresh_eorr_without_borr   => :ignored,
    :refresh_borr_before_eor     => :ignored,
  }.freeze

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

  def test_every_refresh_case
    got = {}
    BGP::Fault.refresh_catalog.each do |c|
      start(c[:gr])
      afi, safi = c[:name] == :refresh_unadvertised_family ? [2, 128] : [1, 1]
      sent = stats['routeRefreshSent']
      @sim.act('fault', 'case' => c[:name].to_s, 'afi' => afi, 'safi' => safi)
      n = @notified.pop(:timeout => 4)
      got[c[:name]] = if n
                        [:notification, n[:code], n[:subcode], *(n[:code] == 7 ? [n[:octets].to_s] : [])]
                      elsif stats['routeRefreshSent'] > sent
                        :answered
                      elsif @router.detail(ROUTES.first).to_h['stale']
                        :marked
                      else
                        :ignored
                      end
      stop
    end
    assert_equal(FRR_DID, got)
  end

  # RFC 7313 section 4: a BoRR and no EoRR. FRR marks the routes stale
  # and starts a timer, which `bgp graceful-restart stalepath-time` sets
  # (360 s by default); when it runs out FRR logs "route-refresh (BoRR)
  # timer expired" and keeps the routes, still stale. The RFC's "MAY
  # remove" allows that.
  def test_borr_without_eorr
    start(false)
    assert(@router.configure("router bgp #{@router.as}", 'bgp graceful-restart stalepath-time 2'),
           'stalepath-time is taken')
    @sim.act('behaviour', 'name' => 'borr_without_eorr')
    assert_equal(true, wait_for_bool(5) { @router.detail(ROUTES.first).to_h['stale'] }, 'marked stale')
    assert_equal(true, wait_for_bool(10) { @router.log =~ /route-refresh \(BoRR\) timer expired/ }, 'the timer ran out')
    sleep 2
    assert_equal([true, true], ROUTES.collect { |p| @router.detail(p).to_h['stale'] }, 'and the routes are kept, stale')
  end

  private

  # bgp4r-sim listening for FRR, two routes, capability 70, and GR's
  # capability when the case needs it.
  def start(gr)
    @router = F.new(:local => FRR, :as => 65002, :router_id => '10.0.0.2', :peer => LOCAL, :peer_as => 65001,
                    :port => LabHelper::Local.free_port, :network => '10.20.0.0/16')
    caps = %w[as4_byte route_refresh enhanced_route_refresh]
    caps += [{ 'graceful_restart' => [0, 120] }] if gr
    @sim = BGP::Sim::Injector.new('router_id' => '10.0.0.1', 'as' => 65001, 'listen_address' => LOCAL,
                                  'port' => @router.port,
                                  'announce' => [{ 'prefixes' => ROUTES, 'next_hop' => '192.0.2.9' }],
                                  'neighbors' => [{ 'address' => FRR, 'as' => 65002, 'capabilities' => caps }])
    @notified = Queue.new
    @sim.speaker.events.on_event do |e|
      @notified << e.data if e.kind == :notification && e.data[:direction] == 'receive'
    end
    @sim.start
    @router.up
    assert_equal(true, wait_for_bool(60) { ROUTES.all? { |p| @router.path(p) } }, 'FRR holds our routes')
  end

  def stop
    @router&.down
    @sim&.stop
    @router = @sim = nil
  end

  def stats ; @router.neighbor(LOCAL)['messageStats'] ; end

  def wait_for_bool(seconds)
    deadline = Time.now + seconds
    until Time.now > deadline
      return true if yield
      sleep 0.2
    end
    false
  end
end
