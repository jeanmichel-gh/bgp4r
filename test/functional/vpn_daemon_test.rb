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
require 'tmpdir'
require 'fileutils'
require 'socket'
require 'bgp/daemon'

# A bgp4rd and a library BGP::Neighbor on loopback, the neighbor sending
# VPN-IPv4 routes (AFI 1 / SAFI 128): docs/design/l3vpn-pe.md, pull
# request 1. The daemon dials, as a PE dials its peer, so the session
# takes the daemon's own path, run_session, where the VPN table is
# attached.
class BGP_Vpn_Daemon_Functional_Test < Test::Unit::TestCase

  PORT = 17_941

  def setup
    @dir = Dir.mktmpdir
    @listener = TCPServer.new('127.0.0.1', PORT)
  end

  def teardown
    @peer.close if @peer
    @server.stop if @server
    @listener.close if @listener
    FileUtils.remove_entry(@dir) if @dir
  end

  # bgp4rd, dialing our listener, with these capabilities.
  def daemon(caps)
    err = StringIO.new
    @server = BGP::Daemon::Server.new(StringIO.new, err)
    config = BGP::Daemon::Server.with_defaults(
      'as' => 65_000, 'router_id' => '10.255.0.1', 'state_file' => File.join(@dir, 'state.json'),
      'neighbors' => [{ 'address' => '127.0.0.1', 'as' => 65_000, 'connect' => true, 'port' => PORT,
                        'retry' => 1, 'description' => 'pe2', 'capabilities' => caps }])
    assert_not_nil(@server.build(config, :socket => File.join(@dir, 'bgp4rd.sock')),
                   "bgp4rd did not start: #{err.string}")
  end

  # Our side: a library Neighbor on the socket bgp4rd opened.
  def peer(vpn: true)
    sock = @listener.accept
    @peer = BGP::Neighbor.new(:my_as => 65_000, :id => '10.255.0.3',
                              :remote_addr => '127.0.0.1', :local_addr => '127.0.0.1')
    @peer.capability :as4_byte
    @peer.capability :mbgp_ipv4_mpls_vpn_unicast if vpn
    Thread.new { @peer.start(:session => sock, :timeout => 10) }
    wait_for('the session to come up') { @peer.is_established? }
  end

  def call(method, params = {})
    c = BGP::Daemon::Client.new(@server.api.path)
    c.call(method, params)
  ensure
    c.close if c
  end

  def wait_for(what, timeout = 10)
    deadline = Time.now + timeout
    until yield
      flunk("timed out waiting for #{what}") if Time.now > deadline
      sleep 0.05
    end
  end

  def announce(*nlris)
    @peer.send_message(BGP::Update.new(BGP::Path_attribute.new(
      BGP::Origin.new(0), BGP::As_path.new, BGP::Local_pref.new(100),
      BGP::Mp_reach.new(:safi => 128, :nexthop => ['10.255.0.3'], :nlris => nlris),
      BGP::Extended_communities.new(BGP::Route_target.new(65_000, 100)))))
  end

  def withdraw(*nlris)
    @peer.send_message(BGP::Update.new(BGP::Path_attribute.new(
      BGP::Mp_unreach.new(:safi => 128, :nlris => nlris.collect { |n| n.merge(:compatibility => '800000') }))))
  end

  def rows
    call('show.vpn', 'limit' => 100)['rows']
  end

  def test_the_vpn_routes_a_peer_sends_are_in_show_vpn
    daemon(['as4_byte', 'mbgp_ipv4_mpls_vpn_unicast'])
    peer
    announce({ :prefix => '192.168.2.0/30', :rd => [65_000, 1], :label => 24_001 },
             { :prefix => '192.168.2.0/30', :rd => [65_000, 2], :label => 24_002 })
    wait_for('two VPN routes') { call('show.vpn')['total'] == 2 }
    a, b = rows
    assert_equal(['65000:1', '192.168.2.0/30', '127.0.0.1', '10.255.0.3', [24_001], ['65000:100'], true],
                 a.values_at('rd', 'prefix', 'peer', 'next_hop', 'labels', 'route_targets', 'best'))
    assert_equal(['65000:2', [24_002]], b.values_at('rd', 'labels'),
                 'the same prefix under another RD is another route (RFC 4364 section 4.1)')
    assert_equal(0, call('show.rib')['total'], 'and none of it is unicast')

    withdraw({ :prefix => '192.168.2.0/30', :rd => [65_000, 1] })
    wait_for('the withdrawal') { call('show.vpn')['total'] == 1 }
    assert_equal(['65000:2'], rows.collect { |r| r['rd'] })

    @peer.close
    @peer = nil
    wait_for('the closed session to take its routes (RFC 4271 section 6)') { call('show.vpn')['total'] == 0 }
  end

  # RFC 4364 section 4.3.4: both speakers must advertise the capability.
  def test_a_peer_that_did_not_send_the_capability_is_not_read
    daemon(['as4_byte', 'mbgp_ipv4_mpls_vpn_unicast'])
    peer(vpn: false)
    announce({ :prefix => '192.168.2.0/30', :rd => [65_000, 1], :label => 24_001 })
    sleep 1
    assert_equal(0, call('show.vpn')['total'])
  end

  def test_show_bgp_vpnv4_in_the_cli
    daemon(['as4_byte', 'mbgp_ipv4_mpls_vpn_unicast'])
    peer
    announce({ :prefix => '192.168.2.0/30', :rd => [65_000, 1], :label => 24_001 })
    wait_for('the route') { call('show.vpn')['total'] == 1 }
    shell = BGP::Daemon::Shell.new(BGP::Daemon::Client.new(@server.api.path))
    out = shell.execute('show bgp vpnv4 unicast all').text
    assert_match(/^Route Distinguisher: 65000:1$/, out)
    assert_match(/^\*>\s+192\.168\.2\.0\/30\s+10\.255\.0\.3\s+100\s+24001\s+65000:100\s+i$/, out)
    assert_equal(out, shell.execute('show bgp vpnv4').text)
  end
end
