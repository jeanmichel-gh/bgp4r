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
require 'bgp/rib'

# BGP:: names are written out in full here, see Conventions in CLAUDE.md.
#
# A PE, pe1, with VRFs A (table 100, imports 65000:100) and B (table 200,
# imports 65000:200), its VPN routes from pe2 (10.255.0.3), and a fake
# `ip` answering what the kernel would and keeping what was sent.
class TestBgpRibL3vpn < Test::Unit::TestCase

  # A kernel stand-in: VRF devices, routes to next hops, and the routes
  # bgp4rd installs, by VRF. Any command can be told to fail.
  class Kernel
    attr_reader :sent, :routes
    attr_accessor :devices, :next_hops, :refuse

    def initialize
      @sent = []
      @routes = Hash.new { |h, k| h[k] = {} }
      @devices = { 'A' => 100, 'B' => 200 }
      @next_hops = {
        '10.255.0.3' => '[{"dst":"10.255.0.3","encap":{"encap_type":"mpls","dst":"17003"},"gateway":"10.0.12.2","dev":"eth2","flags":[]}]',
        '10.255.0.4' => '[{"dst":"10.255.0.4","encap":{"encap_type":"mpls","dst":"17004"},"gateway":"10.0.12.2","dev":"eth2","flags":[]}]'
      }
      @refuse = nil
    end

    def call(argv)
      line = argv.join(' ')
      @sent << line unless line.include?(' -j ')
      return result(argv, 2, "RTNETLINK answers: Invalid argument\n") if @refuse && line.include?(@refuse)
      case argv[1..]
      in ['-j', '-d', 'link', 'show', 'dev', name]
        t = @devices[name] or return result(argv, 1, "Device \"#{name}\" does not exist.\n")
        result(argv, 0, JSON.generate([{ 'ifname' => name, 'linkinfo' => { 'info_kind' => 'vrf', 'info_data' => { 'table' => t } } }]))
      in ['-j', 'route', 'get', nh]
        @next_hops[nh] ? result(argv, 0, @next_hops[nh]) : result(argv, 2, "RTNETLINK answers: Network is unreachable\n")
      in ['-j', 'link', 'show', 'dev', dev]
        result(argv, 0, JSON.generate([{ 'ifname' => dev, 'flags' => %w[POINTOPOINT NOARP UP LOWER_UP] }]))
      in ['route', 'replace', 'vrf', vrf, prefix, *rest]
        @routes[vrf][prefix] = rest.join(' ')
        result(argv, 0, '')
      in ['route', 'del', 'vrf', vrf, prefix, *]
        @routes[vrf].delete(prefix)
        result(argv, 0, '')
      in ['route', 'flush', 'vrf', vrf, *]
        @routes[vrf].clear
        result(argv, 0, '')
      end
    end

    def result(argv, status, out) ; BGP::Rib::Fib::IpRoute::Result.new(argv, status, out) ; end
  end

  def setup
    @kernel = Kernel.new
    @table = BGP::Rib::VpnTable.new(local_as: 65000, router_id: '10.255.0.1')
    @vrfs = BGP::Rib::Vrf.list([{ 'name' => 'A', 'table' => 100, 'import' => ['65000:100'] },
                                { 'name' => 'B', 'table' => 200, 'import' => ['65000:200'] }])
  end

  def l3vpn(transport: {})
    BGP::Rib::L3vpn.new(vpn_table: @table, vrfs: @vrfs, local_as: 65000, router_id: '10.255.0.1',
                        transport: BGP::Rib::VpnTransport.from_config(transport, runner: @kernel),
                        fib: BGP::Rib::VrfFib.new(runner: @kernel))
  end

  def peer(address)
    BGP::Rib::Peer.new(:address => address, :remote_as => 65000, :router_id => address, :local_as => 65000)
  end

  # pe2's VPN route, as a session would receive it.
  def announce(from, rd, prefix, label, rt, local_pref: 100)
    pa = BGP::Path_attribute.new(
      BGP::Origin.new(0), BGP::As_path.new, BGP::Local_pref.new(local_pref),
      BGP::Mp_reach.new(:safi => 128, :nexthop => [from], :nlris => [{ :prefix => prefix, :rd => rd, :label => label }]),
      BGP::Extended_communities.new(BGP::Route_target.new(*rt)))
    u = BGP::Update.new(BGP::Update.new(pa).encode)
    @table.apply(from, BGP::Rib::PeerAdapter.vpn_operations(u, peer(from)))
  end

  def test_an_imported_route_pushes_the_transport_and_the_vpn_label
    announce('10.255.0.3', [65000, 1], '192.168.2.0/30', 24001, [65000, 100])
    l3vpn.start
    assert_equal({ '192.168.2.0/30' => 'encap mpls 17003/24001 via 10.0.12.2 dev eth2 proto bgp' }, @kernel.routes['A'])
    assert_equal({}, @kernel.routes['B'], 'B imports another Route Target')
  end

  # RFC 4364 section 4.3.1: no Route Target in common, no install.
  def test_a_route_no_vrf_imports_is_not_installed
    announce('10.255.0.3', [65000, 9], '10.9.0.0/16', 24009, [65000, 999])
    l = l3vpn.start
    assert_equal([], l.rows)
    assert_equal(1, @table.size, 'it stays in the VPN table (the spec\'s "Who filters")')
  end

  def test_each_vrf_takes_its_own_routes_on_the_same_addresses
    announce('10.255.0.3', [65000, 1], '192.168.2.0/30', 24001, [65000, 100])
    announce('10.255.0.3', [65000, 2], '192.168.2.0/30', 24002, [65000, 200])
    l3vpn.start
    assert_equal('encap mpls 17003/24001 via 10.0.12.2 dev eth2 proto bgp', @kernel.routes['A']['192.168.2.0/30'])
    assert_equal('encap mpls 17003/24002 via 10.0.12.2 dev eth2 proto bgp', @kernel.routes['B']['192.168.2.0/30'])
  end

  # Two RDs bring one prefix to one VRF: the decision process picks one.
  def test_two_rds_for_one_prefix_in_one_vrf
    announce('10.255.0.3', [65000, 1], '192.168.2.0/30', 24001, [65000, 100], local_pref: 100)
    announce('10.255.0.4', [65000, 7], '192.168.2.0/30', 24007, [65000, 100], local_pref: 200)
    l = l3vpn.start
    assert_equal('encap mpls 17004/24007 via 10.0.12.2 dev eth2 proto bgp', @kernel.routes['A']['192.168.2.0/30'])
    assert_equal([['65000:7', 2, true]], l.rows('A').collect { |r| r.values_at('rd', 'candidates', 'installed') })
  end

  # Decision 3: a next hop with no transport is unreachable, so a route
  # through another PE wins even with a lower LOCAL_PREF.
  def test_a_next_hop_with_no_transport_loses
    @kernel.next_hops.delete('10.255.0.4')
    announce('10.255.0.3', [65000, 1], '192.168.2.0/30', 24001, [65000, 100], local_pref: 100)
    announce('10.255.0.4', [65000, 7], '192.168.2.0/30', 24007, [65000, 100], local_pref: 200)
    l3vpn.start
    assert_equal('encap mpls 17003/24001 via 10.0.12.2 dev eth2 proto bgp', @kernel.routes['A']['192.168.2.0/30'])
  end

  def test_with_no_transport_at_all_nothing_is_installed_and_the_row_says_why
    @kernel.next_hops.clear
    announce('10.255.0.3', [65000, 1], '192.168.2.0/30', 24001, [65000, 100])
    l = l3vpn.start
    assert_equal({}, @kernel.routes['A'])
    r = l.rows('A').first
    assert_equal([false, 'no route to 10.255.0.3: RTNETLINK answers: Network is unreachable'], r.values_at('installed', 'error'))
  end

  def test_a_withdrawal_removes_the_route_and_a_quiet_sync_sends_nothing
    announce('10.255.0.3', [65000, 1], '192.168.2.0/30', 24001, [65000, 100])
    l = l3vpn.start
    n = @kernel.sent.size
    l.sync!
    assert_equal(n, @kernel.sent.size, 'nothing changed, nothing sent')
    @table.apply('10.255.0.3', [[:withdraw, '65000:1', '192.168.2.0/30', nil]])
    l.sync!
    assert_equal(['ip route del vrf A 192.168.2.0/30 proto bgp'], @kernel.sent[n..])
    assert_equal({}, @kernel.routes['A'])
  end

  # The IGP moved: the transport label changes, and the route is replaced.
  def test_a_new_transport_label_replaces_the_route
    announce('10.255.0.3', [65000, 1], '192.168.2.0/30', 24001, [65000, 100])
    l = l3vpn.start
    @kernel.next_hops['10.255.0.3'] = '[{"dst":"10.255.0.3","encap":{"encap_type":"mpls","dst":"19003"},"gateway":"10.0.13.2","dev":"eth3","flags":[]}]'
    l.sync!
    assert_equal('encap mpls 19003/24001 via 10.0.13.2 dev eth3 proto bgp', @kernel.routes['A']['192.168.2.0/30'])
  end

  def test_gre_sends_the_vpn_label_into_the_tunnel
    announce('10.255.0.3', [65000, 1], '192.168.2.0/30', 24001, [65000, 100])
    l = l3vpn(transport: { 'transport' => 'gre', 'tunnels' => { '10.255.0.3' => { 'gre' => 'gre-pe2' } } }).start
    assert_equal('encap mpls 24001 dev gre-pe2 proto bgp', @kernel.routes['A']['192.168.2.0/30'])
    assert_equal(['gre', [], 'gre-pe2'], l.rows('A').first.values_at('transport', 'transport_labels', 'dev'))
  end

  # Open question 2: the lab makes the VRF device; bgp4rd checks it.
  def test_a_missing_or_wrong_vrf_device_gets_nothing
    @kernel.devices.delete('A')
    @kernel.devices['B'] = 999
    announce('10.255.0.3', [65000, 1], '192.168.2.0/30', 24001, [65000, 100])
    l = l3vpn.start
    assert_equal({}, @kernel.routes['A'])
    vrfs = l.vrf_rows.to_h { |v| [v['name'], v.values_at('device', 'error')] }
    assert_equal(['unusable', 'no VRF device A: Device "A" does not exist.'], vrfs['A'])
    assert_equal(['unusable', 'VRF B is on table 999, not 200'], vrfs['B'])
    assert_equal('no VRF device A: Device "A" does not exist.', l.rows('A').first['error'])
  end

  def test_a_route_the_kernel_refuses_says_so_and_is_tried_again
    @kernel.refuse = 'route replace'
    announce('10.255.0.3', [65000, 1], '192.168.2.0/30', 24001, [65000, 100])
    l = l3vpn.start
    r = l.rows('A').first
    assert_equal([false, 'the kernel refused it: RTNETLINK answers: Invalid argument'], r.values_at('installed', 'error'))
    @kernel.refuse = nil
    l.sync!
    assert_equal([true, nil], l.rows('A').first.values_at('installed', 'error'))
  end

  def test_start_flushes_what_was_left_and_stop_takes_what_it_put
    @kernel.routes['A']['10.99.0.0/16'] = 'left by an earlier bgp4rd'
    announce('10.255.0.3', [65000, 1], '192.168.2.0/30', 24001, [65000, 100])
    l = l3vpn.start
    assert_equal(['192.168.2.0/30'], @kernel.routes['A'].keys)
    l.stop
    assert_equal({}, @kernel.routes['A'])
    assert_includes(@kernel.sent, 'ip route flush vrf A proto bgp')
  end

  def test_show_vrfs_counts
    announce('10.255.0.3', [65000, 1], '192.168.2.0/30', 24001, [65000, 100])
    announce('10.255.0.3', [65000, 1], '192.168.3.0/30', 24001, [65000, 100])
    v = l3vpn.start.vrf_rows.first
    assert_equal(['A', 100, ['65000:100'], 'ok', 2, 2], v.values_at('name', 'table', 'import', 'device', 'routes', 'installed'))
  end
end
