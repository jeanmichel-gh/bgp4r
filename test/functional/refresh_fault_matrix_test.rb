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

require 'test/unit'
require 'socket'
require 'stringio'
require 'bgp/sim'
require 'bgp/daemon/speaker'
require 'bgp/daemon/views'

# The ROUTE-REFRESH fault matrix against bgp4rd: every
# `BGP::Fault::REFRESH` case and the `borr_without_eorr` behaviour,
# injected by a real bgp4r-sim on a session of its own, and what bgp4rd
# did beside what the RFC expects. docs/design/bgp-operations.md section
# 2, pull request 2c.
class TestRefreshFaultMatrix < Test::Unit::TestCase

  ROUTES = %w[10.1.0.0/16 10.2.0.0/16].freeze

  # What the RFC's word means on the receiver: :ignore and :may_ignore
  # leave the session and the routes as they were, :notification ends
  # the session with 7/1.
  OUTCOME = { :ignore => :ignored, :may_ignore => :ignored, :notification => :notification }.freeze

  # Where bgp4rd does not do what the RFC expects yet, and why. Measured
  # 2026-11-26. Graceful restart is pull request 3: until it, bgp4rd
  # reads a GR capability as an advertisement only, so a BoRR before the
  # End-of-RIB is a BoRR.
  KNOWN = { :refresh_borr_before_eor => :marked }.freeze

  def free_port
    s = TCPServer.new('127.0.0.1', 0)
    s.addr[1]
  ensure
    s&.close
  end

  def setup
    Log.set_filename(StringIO.new)
    Log.level = Logger::WARN
  end

  def teardown
    @sim&.stop
    @sp&.stop
  end

  # bgp4rd on one side, bgp4r-sim dialing it from 127.0.0.2 with two
  # routes, both with capability 70.
  def start(caps: [], neighbor: {})
    port = free_port
    @sp = BGP::Daemon::Speaker.new('as' => 65_000, 'router_id' => '10.0.0.1', 'rib' => true,
                                   'listen_address' => '127.0.0.1', 'port' => port, 'log_level' => 'error',
                                   'neighbors' => [{ 'address' => '127.0.0.2', 'as' => 65_001,
                                                     'capabilities' => %w[route_refresh enhanced_route_refresh] }.merge(neighbor)]).start
    @sent = Queue.new
    @sp.events.on_event { |e| @sent << e.data if e.kind == :notification && e.data[:direction] == 'send' }
    @sim = BGP::Sim::Injector.new('router_id' => '10.0.0.2', 'as' => 65_001, 'local_address' => '127.0.0.2',
                                  'announce' => [{ 'prefixes' => ROUTES, 'next_hop' => '127.0.0.2' }],
                                  'neighbors' => [{ 'address' => '127.0.0.1', 'as' => 65_000, 'connect' => true,
                                                    'port' => port, 'retry' => 0.2,
                                                    'capabilities' => %w[as4_byte route_refresh enhanced_route_refresh] + caps }])
    @sim.start
    assert_equal(true, wait_until(10) { adj_in.size == 2 }, 'the two routes came')
  end

  def wait_until(seconds = 5)
    deadline = Time.now + seconds
    until Time.now > deadline
      return true if yield
      sleep 0.05
    end
    false
  end

  def adj_in ; BGP::Daemon::Views.new(@sp).adj_in('peer' => '127.0.0.2')[:rows] ; end
  def row ; BGP::Daemon::Views.new(@sp).peers.first ; end

  # What bgp4rd did with what was injected.
  def outcome
    n = @sent.pop(:timeout => 2)
    return [:notification, n] if n
    r = row
    return [:down, nil] unless r[:state].to_s == 'established'
    return [:marked, nil] if r[:refresh] && r[:refresh][:stale] > 0
    return [:purged, nil] if adj_in.size < 2
    [:ignored, nil]
  end

  def test_every_refresh_case
    got = {}
    BGP::Fault.refresh_catalog.each do |c|
      start(caps: c[:gr] ? [{ 'graceful_restart' => [0, 120] }] : [])
      afi, safi = c[:name] == :refresh_unadvertised_family ? [2, 128] : [1, 1]
      @sim.act('fault', 'case' => c[:name].to_s, 'afi' => afi, 'safi' => safi)
      what, n = outcome
      got[c[:name]] = what
      want = KNOWN.fetch(c[:name], OUTCOME.fetch(c[:expected]))
      assert_equal(want, what, "#{c[:name]}: RFC #{c[:rfc]} expects #{c[:expected]}")
      if what == :notification
        sent = BGP::Fault.refresh(c[:name], afi, safi).first
        assert_equal([7, 1, sent.unpack1('H*')], [n[:code], n[:subcode], n[:octets]], 'the whole message is the data')
      end
      teardown
      @sim = @sp = nil
    end
    assert_equal({ :refresh_unadvertised_family => :ignored, :refresh_subtype_unknown => :ignored,
                   :refresh_borr_length => :notification, :refresh_eorr_length => :notification,
                   :refresh_eorr_without_borr => :ignored, :refresh_borr_before_eor => :marked }, got)
  end

  # RFC 7313 section 4's local bound: a BoRR and no EoRR, and bgp4rd's
  # refresh_stale_time removes what was not sent again.
  def test_borr_without_eorr
    start(neighbor: { 'refresh_stale_time' => 1 })
    @sim.act('behaviour', 'name' => 'borr_without_eorr')
    assert_equal(true, wait_until(3) { (row[:refresh] || {})[:stale] == 2 }, 'marked')
    assert_equal(true, wait_until(6) { adj_in.empty? }, "removed at the bound: #{adj_in}")
    assert_equal('established', row[:state].to_s)
  end
end
