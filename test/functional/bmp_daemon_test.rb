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
require 'stringio'
require 'json'
require 'bgp4r'
require 'bgp/sim'
require 'bgp/bmp/station'
require 'bgp/daemon/speaker'
require 'bgp/daemon/control'

# bgp4rd to bgp4r-bmp over loopback: the Initiation first, a Peer Up for
# the peer, its dump with an End-of-RIB, each UPDATE, a withdrawal, the
# stats, a Peer Down with each reason bgp4rd gives, a station that comes
# late or goes, and the Termination. docs/design/bgp-operations.md 8c.
class TestBmpDaemon < Test::Unit::TestCase

  SIM = '127.0.0.1'
  BGP4RD = '127.0.0.3'

  def setup
    Log.set_filename(StringIO.new)
    @io = StringIO.new
    @station = BGP::Bmp::Station.new(:lines => @io)
  end

  def teardown
    @sim&.stop
    @sp&.stop
    @station&.stop
  end

  def free(host = SIM) ; s = TCPServer.new(host, 0) ; p = s.addr[1] ; s.close ; p ; end

  def start(station_port, bmp = {})
    @port = free(BGP4RD)
    bmp = { 'stations' => [{ 'address' => SIM, 'port' => station_port, 'retry' => 0.2 }], 'sys_name' => 'r1' }.merge(bmp)
    @sp = BGP::Daemon::Speaker.new('as' => 65_000, 'router_id' => '10.0.0.3', 'listen_address' => BGP4RD, 'port' => @port,
                                   'log_level' => 'error', 'bmp' => bmp,
                                   'neighbors' => [{ 'address' => SIM, 'as' => 65_001, 'retry' => 0.2 }]).start
    @sim = BGP::Sim::Injector.new('router_id' => '10.0.0.1', 'as' => 65_001, 'listen_address' => SIM, 'local_address' => SIM,
                                  'port' => free,
                                  'neighbors' => [{ 'address' => BGP4RD, 'as' => 65_000, 'port' => @port, 'connect' => true,
                                                    'retry' => 0.2, 'capabilities' => ['as4_byte'] }])
    @sim.start
    sim_up
  end

  def sim_up ; assert(wait_until(15) { @sim.speaker.peers.first.established? }, 'the sim is up') ; end
  def lines ; @io.string.lines.collect { |l| JSON.parse(l) } ; end
  def types ; lines.collect { |l| l['type'] } ; end
  def routes ; @station.routes('view' => 'pre_policy')[:routes].collect { |r| r[:nlri][:prefix] }.sort ; end
  def peer ; @station.peers[:peers].find { |p| p[:address] == SIM } ; end
  def downs ; lines.select { |l| l['type'] == 'peer_down' }.collect { |l| l['message'] } ; end

  def announce(*prefixes)
    @sim.act('announce', 'prefixes' => prefixes, 'next_hop' => '192.0.2.9', 'as_path' => [65_010], 'med' => 10)
  end

  def wait_until(seconds = 5)
    deadline = Time.now + seconds
    until Time.now > deadline
      return true if yield
      sleep 0.05
    end
    false
  end

  def test_a_session_reported
    start(@station.listen('127.0.0.1', 0))
    assert(wait_until { peer&.dig(:up) }, 'a Peer Up')
    announce('192.0.2.0/24', '198.51.100.0/24')
    assert(wait_until { routes == %w[192.0.2.0/24 198.51.100.0/24] }, routes.inspect)
    r = @station.routes('view' => 'pre_policy')[:routes].first
    assert_equal([{ :sequence => [65_001, 65_010] }, '192.0.2.9', 10],
                 [r[:path_attributes][:as_path], r[:next_hop], r[:path_attributes][:med]])
    @sim.act('withdraw', 'prefixes' => %w[198.51.100.0/24])
    assert(wait_until { routes == %w[192.0.2.0/24] }, routes.inspect)
    assert_equal(%w[connected initiation peer_up route_monitoring route_monitoring route_monitoring], types.first(6))
    i = lines[1]
    assert_equal(['r1', "bgp4r #{BGP::VERSION}"], [i['sys_name'], i['message']['information'].first['string']])
    up = lines[2]['message']
    assert_equal([0, 0, SIM, 65_001, '10.0.0.1'], up['peer'].values_at('peer_type', 'flags', 'address', 'asn', 'bgp_id'))
    assert_equal([BGP4RD, @port], up.values_at('local_address', 'local_port'))
    assert_equal([65_000, 65_001], [up['sent_open']['my_as'], up['received_open']['my_as']].collect(&:to_i))
    assert_equal([{ :afi => 1, :safi => 1 }], peer[:end_of_rib], 'an End-of-RIB after the Peer Up')
    assert_equal({}, @station.routers[:routers].first[:findings], 'nothing a station finds wrong')
    @sim.stop
    @sim = nil
    assert(wait_until { downs.size == 1 })
    assert_equal(4, downs.first['reason'], 'the sim went without a NOTIFICATION')
    @sp.stop
    assert(wait_until { types.last == 'closed' })
    assert_equal(%w[termination closed], types.last(2))
    assert_equal('termination', lines.last['reason'])
    @sp = nil
  end

  # Section 4.9: 3 with the sim's NOTIFICATION, 1 with bgp4rd's Cease.
  def test_the_reasons
    start(@station.listen('127.0.0.1', 0))
    assert(wait_until { peer&.dig(:up) })
    @sim.act('notification', 'code' => 6, 'subcode' => 2)
    assert(wait_until { downs.size == 1 })
    assert_equal([3, { 'code' => 6, 'subcode' => 2, 'data' => '' }], downs[0].values_at('reason', 'notification'))
    sim_up
    assert(wait_until { peer&.dig(:up) })
    BGP::Daemon::Control.new(@sp).peer_clear('peer' => SIM)
    assert(wait_until { downs.size == 2 })
    assert_equal([1, { 'code' => 6, 'subcode' => 4, 'data' => '' }], downs[1].values_at('reason', 'notification'))
  end

  # The station comes after the routes: Peer Up, each route, the
  # End-of-RIB, all before anything new. And it comes back when it went.
  def test_the_dump
    port = free
    start(port)
    announce('192.0.2.0/24', '198.51.100.0/24')
    assert(wait_until { @sp.bmp.instance_variable_get(:@peers).values.first&.routes&.size == 2 })
    @station.listen('127.0.0.1', port)
    assert(wait_until { peer&.dig(:end_of_rib)&.size == 1 }, types.inspect)
    assert_equal(%w[connected initiation peer_up route_monitoring route_monitoring route_monitoring], types)
    assert_equal(%w[192.0.2.0/24 198.51.100.0/24], routes)
    assert_equal('up', @sp.bmp.rows.first[:state])
    @station.stop
    @station = BGP::Bmp::Station.new(:lines => (@io = StringIO.new))
    @station.listen('127.0.0.1', port)
    assert(wait_until(10) { routes == %w[192.0.2.0/24 198.51.100.0/24] }, 'a new session, the dump again')
    assert(wait_until { @sp.bmp.rows.first[:sessions] == 2 })
  end

  # Section 4.8: routes kept (7), UPDATEs and prefixes treated as
  # withdraw (11, 12), every stats_interval.
  def test_the_stats
    start(@station.listen('127.0.0.1', 0), 'stats_interval' => 0.2)
    assert(wait_until { peer&.dig(:up) })
    announce('192.0.2.0/24')
    @sim.act('fault', 'case' => 'origin_value', 'prefixes' => ['10.9.0.0/16'])
    want = [{ :type => 7, :value => 1 }, { :type => 11, :value => 1 }, { :type => 12, :value => 1 }]
    assert(wait_until { peer[:stats] == want }, peer[:stats].inspect)
  end

  def bmp_events ; @sp.events.since(0).select { |e| e.kind == :bmp }.collect(&:message) ; end

  def test_events_and_rows
    start(@station.listen('127.0.0.1', 0))
    assert(wait_until { peer&.dig(:up) })
    row = @sp.bmp.rows.first
    assert_equal(['up', 1, nil], row.values_at(:state, :sessions, :last_error))
    assert_match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z/, row[:connected_at])
    assert(wait_until { @sp.bmp.rows.first[:messages] == lines.size - 1 }, 'each message counted')
    @sim.stop
    @sim = nil
    assert(wait_until { downs.size == 1 })
    sp, @sp = @sp, nil
    sp.stop
    events = sp.events.since(0).select { |e| e.kind == :bmp }.collect(&:message)
    station = "127.0.0.1:#{@station.port}"
    assert_equal(["BMP station #{station} up", "BMP peer #{SIM} up, reported to 1 station(s)", "BMP peer #{SIM} down, reason 4",
                  "BMP station #{station} down: bgp4rd stopped"], events)
  end

  # A peer that went is not in the next session's start.
  def test_a_peer_gone_is_not_reported_again
    port = free
    start(@station.listen('127.0.0.1', port))
    assert(wait_until { peer&.dig(:up) })
    @sim.stop
    @sim = nil
    assert(wait_until { downs.size == 1 })
    @station.stop
    @station = BGP::Bmp::Station.new(:lines => (@io = StringIO.new))
    @station.listen('127.0.0.1', port)
    assert(wait_until(10) { types.include?('initiation') })
    sleep 0.3
    assert_equal(%w[connected initiation], types)
  end

  def test_a_station_that_is_not_there
    start(free)
    assert(wait_until { @sp.bmp.rows.first[:last_error] }, 'a dial fails')
    assert_equal(['connecting', 0], @sp.bmp.rows.first.values_at(:state, :sessions))
    events = @sp.events.since(0).select { |e| e.kind == :bmp }
    assert_equal([], events.select { |e| e.data[:event] == 'station_up' })
  end
end
