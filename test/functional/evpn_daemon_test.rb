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
require 'bgp/gen/evpn_routes'
require 'bgp/gen/sender'

# A bgp4rd and a library BGP::Neighbor on loopback, the neighbor sending
# EVPN routes (AFI 25 / SAFI 70) as bgp4r-sim does, from the generator:
# docs/design/evpn.md, pull request 1. The daemon dials, so the session
# takes run_session, where the EVPN table is attached.
class BGP_Evpn_Daemon_Functional_Test < Test::Unit::TestCase

  PORT = 17_943

  def setup
    @dir = Dir.mktmpdir
    @listener = TCPServer.new('127.0.0.1', PORT)
  end

  def teardown
    @peer.close if @peer
    @server.stop if @server
  ensure
    @listener.close if @listener
    FileUtils.remove_entry(@dir) if @dir
  end

  def daemon(caps)
    err = StringIO.new
    @server = BGP::Daemon::Server.new(StringIO.new, err)
    config = BGP::Daemon::Server.with_defaults(
      { 'as' => 65_000, 'router_id' => '10.255.0.12', 'state_file' => File.join(@dir, 'state.json'),
        'neighbors' => [{ 'address' => '127.0.0.1', 'as' => 65_000, 'connect' => true, 'port' => PORT,
                          'retry' => 1, 'description' => 's1', 'capabilities' => caps }] })
    assert_not_nil(@server.build(config, :socket => File.join(@dir, 'bgp4rd.sock')),
                   "bgp4rd did not start: #{err.string}")
  end

  def peer(evpn: true)
    sock = @listener.accept
    @peer = BGP::Neighbor.new(:my_as => 65_000, :id => '10.0.9.2',
                              :remote_addr => '127.0.0.1', :local_addr => '127.0.0.1')
    @peer.capability :as4_byte
    @peer.capability :mbgp_l2vpn_evpn if evpn
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

  # What lab 3's inject scenario sends: a type 3 route for 10.0.9.2 and
  # MACs behind it, with the VNI whole and the encapsulation VXLAN.
  def spec(type, start, count = 1)
    { 'family' => 'evpn', 'route_type' => type, 'start' => start, 'count' => count, 'rd' => '10.0.9.2:100',
      'route_target' => '65000:100', 'vni' => 100,
      'attributes' => { 'extended_communities' => ['encapsulation:vxlan'] } }
  end

  # The generator's UPDATEs, with the next hop and LOCAL_PREF its
  # Sender gives an internal peer (bgp/gen/sender.rb), as bgp4r-sim's.
  def send_spec(s, withdraw: false)
    sender = BGP::Gen::Sender.read('as' => 65_000, 'next_hop' => '10.0.9.2')
    BGP::Gen::Evpn_routes.new(s, sender).updates.each do |u|
      if withdraw
        nlris = u.path_attribute[BGP::Mp_reach].nlris.collect(&:to_hash)
        u = BGP::Update.new(BGP::Path_attribute.new(BGP::Mp_unreach.new(:afi => 25, :safi => 70, :nlris => nlris)))
      end
      @peer.send_message(u)
    end
  end

  def rows(params = {})
    call('show.evpn', { 'limit' => 1000 }.merge(params))['rows']
  end

  def test_the_evpn_routes_a_peer_sends_are_in_show_evpn
    daemon(%w[as4_byte mbgp_l2vpn_evpn])
    peer
    send_spec(spec(3, '10.0.9.2'))
    send_spec(spec(2, '02:00:00:99:00:00', 10))
    wait_for('eleven EVPN routes') { call('show.evpn')['total'] == 11 }
    imet = rows('route_type' => 3).first
    assert_equal(['10.0.9.2:100', '10.0.9.2', 100, 'VXLAN', { 'type' => 'ingress_replication', 'id' => '10.0.9.2' }, true],
                 imet.values_at('rd', 'originator', 'vni', 'encap', 'pmsi', 'best'))
    macs = rows('route_type' => 2)
    assert_equal(10, macs.size)
    assert_equal(['02:00:00:99:00:00', nil, 100, '10.0.9.2', '127.0.0.1', ['65000:100']],
                 macs.first.values_at('mac', 'ip', 'vni', 'next_hop', 'peer', 'route_targets'))
    assert_equal(['02:00:00:99:00:05'], rows('mac' => '02:00:00:99:00:05').collect { |r| r['mac'] })
    assert_equal(0, call('show.rib')['total'], 'and none of it is unicast')
    evpn = call('show.peers').first['families'].find { |f| f['family'] == 'evpn' }
    assert_equal({ 'family' => 'evpn', 'received' => 11, 'sent' => 0, 'other_types' => 0 }, evpn)

    send_spec(spec(2, '02:00:00:99:00:00', 10), withdraw: true)
    wait_for('the withdrawal') { call('show.evpn')['total'] == 1 }

    @peer.close
    @peer = nil
    wait_for('the closed session to take its routes (RFC 4271 section 6)') { call('show.evpn')['total'] == 0 }
  end

  # RFC 4760 section 8: both speakers must advertise the capability.
  def test_a_peer_that_did_not_send_the_capability_is_not_read
    daemon(%w[as4_byte mbgp_l2vpn_evpn])
    peer(evpn: false)
    send_spec(spec(3, '10.0.9.2'))
    sleep 1
    assert_equal(0, call('show.evpn')['total'])
    assert_nil(call('show.peers').first['families'])
  end
end
