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

# BGP::Gen against a real router: a generated feed from bgp4r into a
# gobgpd on loopback, no Docker, and the router's RIB compared with the
# spec's `expected`.
#
#   ruby -I. test/functional/lab/gen_gobgp_test.rb
#
# Omitted when gobgpd is not installed, unless LAB_REQUIRE_GOBGPD=1.
#
# What this adds over test/functional/gen_test.rb is a reader that is not
# bgp4r. There, the receiver's parser is the one the generator's own
# tests use, so a fault in both halves passes. Here GoBGP reads the
# packing, the MP_REACH_NLRI framing, the Path Identifiers and every
# attribute, and holds what it read.
#
# BGP:: names are written out in full, see Conventions in CLAUDE.md.

require 'test/unit'
require 'socket'
require 'bgp4r'
require 'bgp/gen'
require_relative 'lab_helper'

class LabGenGobgpTest < Test::Unit::TestCase
  include LabHelper

  OUR_AS = 65001
  THEIR_AS = 65002
  MED, LOCAL_PREF, COMMUNITIES, LARGE = 4, 5, 8, 32   # attribute type codes

  def setup
    unless LabHelper::Gobgpd.available?
      flunk('gobgpd is not installed') if ENV['LAB_REQUIRE_GOBGPD'] == '1'
      omit('gobgpd is not installed')
    end
  end

  def teardown
    @thread.kill if @thread
    @peer.close if @peer
    @server.close if @server && !@server.closed?
    if @router
      @router.down
      puts "\n== gobgpd\n#{@router.log}" unless passed?
    end
  end

  # A gobgpd that dials us, and a bgp4r speaker with 4-octet AS numbers,
  # IPv4 and IPv6 unicast, and add-path when asked.
  def session(add_path = false)
    @router = LabHelper::Gobgpd.new(:local => '127.0.0.2', :as => THEIR_AS,
                                    :router_id => '10.0.0.2',
                                    :peer => '127.0.0.1', :peer_as => OUR_AS,
                                    :add_path => add_path ? { :receive => true, :send_max => 0 } : nil)
    @router.up
    @server = TCPServer.new('127.0.0.1', @router.port)
    @peer = BGP::Neighbor.new(4, OUR_AS, 180, '10.0.0.1', '127.0.0.2', '127.0.0.1')
    @peer.capability :as4_byte
    @peer.capability :mbgp, :ipv4, :unicast
    @peer.capability :mbgp, :ipv6, :unicast
    if add_path
      @peer.capability :add_path, :send, 1, 1
      @peer.capability :add_path, :send, 2, 1
    end
    @thread = Thread.new do
      begin
        while (socket = @server.accept)
          @peer.start_session(socket)
        end
      rescue IOError, SystemCallError
      end
    end
    @peer.wait_for_state(:Established, 40)
  end

  # The client takes `ipv6` here, and refuses `ipv6-unicast`, which is
  # the config file's name for the same family. Measured, the fourth
  # time the two have disagreed; see CLIENT_FAMILY in lab_helper.rb.
  FAMILY = { 1 => 'ipv4', 2 => 'ipv6' }

  def rib(afi)
    @router.rib_family(FAMILY[afi])
  end

  # How many paths the router holds, from `global rib summary`. The JSON
  # RIB is no use for counting a large feed: GoBGP prints each path's
  # MP_REACH_NLRI with every prefix of the UPDATE it came in, so 2000
  # IPv6 routes are tens of megabytes of JSON per poll.
  def path_count(afi)
    out, status = @router.client_run('global', 'rib', 'summary', '-a', FAMILY[afi])
    status.success? ? out[/Path: (\d+)/, 1].to_i : -1
  end

  # Announce, compare a sample with expected, withdraw, empty.
  def crosses(spec)
    g = BGP::Gen.new(spec)
    count = spec['count']
    g.updates.each { |u| @peer.send_message u }
    wait_for("GoBGP to hold #{count} routes", :timeout => 60) { path_count(g.afi) == count }
    held = rib(g.afi)
    rows = g.expected.to_a
    [0, rows.size / 2, rows.size - 1].uniq.each do |i|
      want = rows[i]
      paths = held[want['prefix']]
      assert_not_nil(paths, "GoBGP holds #{want['prefix']}")
      assert_equal(1, paths.size, 'one path per prefix')
      read(paths.first, want)
    end
    g.withdrawals.each { |u| @peer.send_message u }
    wait_for('GoBGP to hold nothing', :timeout => 60) { path_count(g.afi) == 0 }
    g
  end

  # What GoBGP read, against the row. Each attribute GoBGP prints is
  # compared, by its type code, the way rib_router_gobgp_test.rb does.
  def read(path, want)
    a = LabHelper::Gobgpd.attrs(path)
    assert_equal(want['as_path'], LabHelper::Gobgpd.as_path(path), want['prefix'])
    assert_equal(want['origin'], a[1]['value'], 'ORIGIN')
    nh = a[3] ? a[3]['nexthop'] : a[14]['nexthop']
    assert_equal(want['next_hop'], nh, 'the next hop, NEXT_HOP or inside MP_REACH_NLRI')
    assert_equal(want['med'], a[MED] && a[MED]['metric'], 'MULTI_EXIT_DISC')
    if want['communities']
      got = a[COMMUNITIES]['communities'].collect { |c| "#{c >> 16}:#{c & 0xffff}" }
      assert_equal(want['communities'], got, 'COMMUNITIES')
    end
    if want['large_communities']
      got = a[LARGE]['value'].collect { |c| "#{c['ASN']}:#{c['LocalData1']}:#{c['LocalData2']}" }
      assert_equal(want['large_communities'], got, 'LARGE_COMMUNITY')
    end
  end

  ATTRIBUTES = { 'origin' => 1, 'as_path' => [OUR_AS, 65010, 4200000000], 'med' => 70,
                 'communities' => ['65000:1', '65000:2'], 'large_communities' => ['65000:1:1', '65000:2:3'] }

  def test_ipv4_unicast
    session
    crosses('start' => '10.0.0.0/24', 'count' => 3000,
            'attributes' => ATTRIBUTES.merge('next_hop' => '192.0.2.1'))
  end

  def test_ipv6_unicast
    session
    crosses('start' => '2001:db8::/64', 'count' => 1500,
            'attributes' => ATTRIBUTES.merge('next_hop' => '2001:db8::1'))
  end

  # RFC 7911: GoBGP reads a Path Identifier before every prefix only if
  # the session negotiated one, so holding the routes at all says the
  # identifiers are where it expects them. **That is all it says**: the
  # client's JSON prints no Path Identifier, measured on 3.23.0, so a
  # wrong value in the right place would pass here. The value is
  # test/functional/gen_test.rb's, where the Adj-RIB-In is keyed on it.
  def test_a_path_id_on_every_prefix
    session(true)
    [['10.0.0.0/24', '192.0.2.1'], ['2001:db8::/64', '2001:db8::1']].each do |start, nh|
      crosses('start' => start, 'count' => 1000, 'path_id' => 77,
              'attributes' => { 'next_hop' => nh, 'as_path' => [OUR_AS] })
    end
  end
end
