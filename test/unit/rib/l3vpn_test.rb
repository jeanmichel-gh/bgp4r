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
    attr_reader :sent, :routes, :labels
    attr_accessor :devices, :next_hops, :refuse, :connected, :connected6, :arp, :neighbors6

    def initialize
      @sent = []
      @routes = Hash.new { |h, k| h[k] = {} }
      @labels = {}
      @connected = { 'A' => ['192.168.1.0/30'], 'B' => [] }
      @devices = { 'A' => 100, 'B' => 200 }
      @next_hops = {
        '10.255.0.3' => '[{"dst":"10.255.0.3","encap":{"encap_type":"mpls","dst":"17003"},"gateway":"10.0.12.2","dev":"eth2","flags":[]}]',
        '10.255.0.4' => '[{"dst":"10.255.0.4","encap":{"encap_type":"mpls","dst":"17004"},"gateway":"10.0.12.2","dev":"eth2","flags":[]}]'
      }
      @refuse = nil
      # IPv6, pull request 5: what `ip -6 -j route show vrf A proto kernel`
      # answered on l3vpn-lab's pe1, link-local and anycast included.
      @connected6 = { 'A' => [], 'B' => [] }
      @arp = { %w[10.0.12.2 eth2] => 'aa:c1:ab:f2:d6:83' }
      @neighbors6 = { 'eth2' => [] }
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
        @routes[vrf].delete_if { |prefix, _| !prefix.include?(':') }
        result(argv, 0, '')
      in ['-j', 'route', 'show', 'vrf', vrf, 'proto', 'bgp']
        result(argv, 0, JSON.generate(kernel_rows(vrf, false)))
      in ['-6', '-j', 'route', 'show', 'vrf', vrf, 'proto', 'bgp']
        result(argv, 0, JSON.generate(kernel_rows(vrf, true)))
      in ['-j', '-f', 'mpls', 'route', 'show', 'proto', 'bgp']
        result(argv, 0, JSON.generate(@labels.collect { |l, vrf| { 'dst' => l.to_s, 'dev' => vrf, 'flags' => [] } }))
      in ['-6', 'route', 'flush', 'vrf', vrf, *]
        @routes[vrf].delete_if { |prefix, _| prefix.include?(':') }
        result(argv, 0, '')
      in ['-6', '-j', 'route', 'show', 'vrf', vrf, 'proto', 'kernel']
        rows = @connected6.fetch(vrf, []).flat_map do |d|
          [{ 'type' => 'anycast', 'dst' => d.split('/').first, 'dev' => 'eth3' }, { 'dst' => d, 'dev' => 'eth3' }]
        end
        rows += [{ 'type' => 'anycast', 'dst' => 'fe80::', 'dev' => 'eth3' }, { 'dst' => 'fe80::/64', 'dev' => 'eth3' },
                 { 'type' => 'multicast', 'dst' => 'ff00::/8', 'dev' => 'eth3' }]
        result(argv, 0, JSON.generate(rows))
      in ['-j', 'neigh', 'show', gw, 'dev', dev]
        mac = @arp[[gw, dev]]
        result(argv, 0, JSON.generate(mac ? [{ 'dst' => gw, 'lladdr' => mac, 'state' => ['REACHABLE'] }] : []))
      in ['-6', '-j', 'neigh', 'show', 'dev', dev]
        result(argv, 0, JSON.generate(@neighbors6.fetch(dev, [])))
      in ['-f', 'mpls', 'route', 'replace', label, 'dev', vrf, 'proto', 'bgp']
        @labels[label.to_i] = vrf
        result(argv, 0, '')
      in ['-f', 'mpls', 'route', 'del', label, *]
        @labels.delete(label.to_i)
        result(argv, 0, '')
      in ['-f', 'mpls', 'route', 'flush', *]
        @labels.clear
        result(argv, 0, '')
      in ['-j', 'route', 'show', 'vrf', vrf, 'proto', 'kernel', 'scope', 'link']
        result(argv, 0, JSON.generate(@connected.fetch(vrf, []).collect { |d| { 'dst' => d, 'dev' => 'eth1' } }))
      end
    end

    def result(argv, status, out) ; BGP::Rib::Fib::IpRoute::Result.new(argv, status, out) ; end

    # The VRF's routes as `ip -j route show vrf V proto bgp` answers them,
    # from what was installed: "encap mpls 17003/24001 via GW dev D proto
    # bgp". A host route's dst has no length, as the kernel prints it.
    def kernel_rows(vrf, v6)
      @routes[vrf].select { |prefix, _| prefix.include?(':') == v6 }.collect do |prefix, rest|
        w = rest.split
        at = ->(word) { (i = w.index(word)) && w[i + 1] }
        dst = prefix.end_with?('/32', '/128') ? prefix.split('/').first : prefix
        # A CE route is sent with its gateway alone; the kernel names the
        # device on the VRF's link to it.
        row = { 'dst' => dst, 'dev' => at.call('dev') || 'eth3', 'flags' => [] }
        row['encap'] = { 'encap_type' => 'mpls', 'dst' => at.call('mpls') } if at.call('mpls')
        row['gateway'] = at.call('via') if at.call('via')
        row
      end
    end
  end

  def setup
    @kernel = Kernel.new
    @table = BGP::Rib::VpnTable.new(local_as: 65000, router_id: '10.255.0.1')
    @vrfs = BGP::Rib::Vrf.list([{ 'name' => 'A', 'table' => 100, 'import' => ['65000:100'] },
                                { 'name' => 'B', 'table' => 200, 'import' => ['65000:200'] }])
  end

  # --- IPv6, pull request 5 ----------------------------------------------

  # RFC 4659 section 3.2.1.2: pe2's IPv4 address, IPv4-mapped.
  def announce6(prefix, rd: [65000, 1], label: 24101, rt: [65000, 100], nh: '::ffff:10.255.0.3')
    u = BGP::Update.new(BGP::Update.new(BGP::Path_attribute.new(
      BGP::Origin.new(0), BGP::As_path.new, BGP::Local_pref.new(100),
      BGP::Mp_reach.new(:afi => 2, :safi => 128, :nexthop => [nh], :nlris => [{ :prefix => prefix, :rd => rd, :label => label }]),
      BGP::Extended_communities.new(BGP::Route_target.new(*rt)))).encode)
    @table.apply('10.255.0.3', BGP::Rib::PeerAdapter.vpn_operations(u, peer('10.255.0.3')))
  end

  # Decision 6: the kernel takes no IPv4 gateway for an IPv6 route, so
  # the gateway is that neighbor's link-local, made from its MAC when no
  # IPv6 neighbor entry has it.
  def test_an_ipv6_route_goes_to_the_gateways_link_local
    announce6('2001:db8:2::/64')
    l = l3vpn.start
    assert_equal('encap mpls 17003/24101 via fe80::a8c1:abff:fef2:d683 dev eth2 proto bgp',
                 @kernel.routes['A']['2001:db8:2::/64'])
    r = l.rows('A').first
    assert_equal(['::ffff:10.255.0.3', [17003], 'fe80::a8c1:abff:fef2:d683', 'eui-64', true],
                 r.values_at('next_hop', 'transport_labels', 'gateway', 'gateway_from', 'installed'))
  end

  def test_the_neighbor_table_wins_over_eui_64
    @kernel.neighbors6['eth2'] = [{ 'dst' => '2001:db8:ff::2', 'lladdr' => 'aa:c1:ab:f2:d6:83' },
                                  { 'dst' => 'fe80::1234', 'lladdr' => 'aa:c1:ab:f2:d6:83' }]
    announce6('2001:db8:2::/64')
    l = l3vpn.start
    assert_equal(['fe80::1234', 'neighbor'], l.rows('A').first.values_at('gateway', 'gateway_from'),
                 'the link-local entry with the MAC, not the global one')
  end

  def test_with_no_arp_entry_an_ipv6_route_waits
    @kernel.arp.clear
    announce6('2001:db8:2::/64')
    l = l3vpn.start
    assert_equal({}, @kernel.routes['A'])
    assert_equal('no ARP entry for 10.0.12.2 on eth2: an IPv6 route needs its MAC', l.rows('A').first['error'])
    assert(l.waiting?)
    @kernel.arp[%w[10.0.12.2 eth2]] = 'aa:c1:ab:f2:d6:83'
    l.sync!
    assert(!l.waiting?)
    assert_equal(['2001:db8:2::/64'], @kernel.routes['A'].keys)
  end

  # Section 3.2.1.1: a real IPv6 next hop needs an IPv6 transport.
  def test_an_ipv6_next_hop_is_unreachable
    announce6('2001:db8:2::/64', nh: '2001:db8::3')
    l = l3vpn.start
    assert_equal({}, @kernel.routes['A'])
    assert_match(/\A2001:db8::3 is an IPv6 next hop: it needs an IPv6 transport/, l.rows('A').first['error'])
  end

  # The IPv4 route to the same PE keeps its IPv4 gateway beside it, and
  # each flush takes its own family.
  def test_both_families_in_one_vrf
    announce('10.255.0.3', [65000, 1], '192.168.2.0/30', 24001, [65000, 100])
    announce6('2001:db8:2::/64')
    l = l3vpn.start
    assert_equal(['192.168.2.0/30', '2001:db8:2::/64'], @kernel.routes['A'].keys.sort)
    assert_match(/via 10\.0\.12\.2 dev eth2/, @kernel.routes['A']['192.168.2.0/30'])
    l.stop
    assert_equal({}, @kernel.routes['A'])
    assert_includes(@kernel.sent, 'ip -6 route flush vrf A proto bgp')
  end

  def test_a_vrf_sends_its_ipv6_connected_prefixes_not_link_local
    exporting
    @kernel.connected6['A'] = ['2001:db8:1::/64']
    l = l3vpn(labels: LABELS).start
    assert_equal(['172.16.1.0/24', '192.168.1.0/30', '2001:db8:1::/64'], l.exports.collect(&:prefix).sort_by { |p| [p.include?(':') ? 1 : 0, p] })
    assert_equal([24000], l.exports.collect(&:label).uniq, 'one label per VRF, both families')
  end

  def l3vpn(transport: {}, labels: nil, logger: nil)
    BGP::Rib::L3vpn.new(vpn_table: @table, vrfs: @vrfs, local_as: 65000, router_id: '10.255.0.1',
                        transport: BGP::Rib::VpnTransport.from_config(transport, runner: @kernel),
                        fib: BGP::Rib::VrfFib.new(runner: @kernel), labels: labels, logger: logger,
                        ce_table: @ces)
  end

  # --- CEs, pull request 7 ------------------------------------------------

  def ce_route(prefix, from: '192.168.1.2', path: [65101], origin: 0)
    pa = BGP::Path_attribute.new(BGP::Origin.new(origin), BGP::As_path.new(*path), BGP::Next_hop.new(from))
    BGP::Rib::Route.new(prefix, pa, BGP::Rib::Peer.new(:address => from, :remote_as => path.first,
                                                       :router_id => from, :local_as => 65000))
  end

  def with_ces
    @ces = BGP::Rib::VrfCeTable.new(local_as: 65000, router_id: '10.255.0.1')
  end

  def ce_announce(vrf, prefix, **opts)
    r = ce_route(prefix, **opts)
    @ces.apply(vrf, r.peer.address, [[:announce, r]])
    @ces.site(r.peer.address, '65000:11')
  end

  def test_a_ce_route_is_installed_via_the_ce
    with_ces
    ce_announce('A', '172.16.1.0/24')
    l = l3vpn.start
    assert_equal('via 192.168.1.2 proto bgp', @kernel.routes['A']['172.16.1.0/24'])
    r = l.rows('A').first
    assert_equal(['ce', '192.168.1.2', '192.168.1.2', true], r.values_at('transport', 'peer', 'gateway', 'installed'))
    n = @kernel.sent.size
    l.sync!
    assert_equal(n, @kernel.sent.size, 'the kernel named the device; still the same route')
  end

  # An eBGP route from the site wins over an iBGP VPN route to it.
  def test_a_ce_route_wins_over_a_vpn_route
    with_ces
    announce('10.255.0.3', [65000, 1], '172.16.1.0/24', 24001, [65000, 100])
    ce_announce('A', '172.16.1.0/24')
    l = l3vpn.start
    assert_equal('via 192.168.1.2 proto bgp', @kernel.routes['A']['172.16.1.0/24'])
    assert_equal(['ce'], l.rows('A').collect { |r| r['transport'] })
    assert_equal([['172.16.1.0/24', '192.168.1.2']], l.installed('A').collect { |i| [i.prefix, i.ce] })
  end

  # Step 4: out as a VPN route, with the CE's AS_PATH and ORIGIN and the
  # neighbor's Site of Origin.
  def test_a_ce_route_is_exported_with_its_path
    exporting
    with_ces
    ce_announce('A', '172.16.7.0/24', path: [65101, 65201], origin: 2)
    l = l3vpn(labels: LABELS).start
    e = l.exports.find { |x| x.prefix == '172.16.7.0/24' }
    assert_equal(['65000:1', 24000, [65101, 65201], 2, '65000:11'], [e.rd, e.label, e.as_path, e.origin, e.soo])
  end

  def test_a_ce_route_the_kernel_refused_is_not_exported
    exporting
    with_ces
    ce_announce('A', '172.16.7.0/24')
    @kernel.refuse = 'route replace vrf A 172.16.7.0/24'
    l = l3vpn(labels: LABELS).start
    assert_nil(l.exports.find { |x| x.prefix == '172.16.7.0/24' })
    assert_equal([], l.installed('A').collect(&:prefix).grep('172.16.7.0/24'))
  end

  def test_the_vpn_routes_a_vrf_installed_are_listed_for_its_ces
    with_ces
    announce('10.255.0.3', [65000, 1], '192.168.2.0/30', 24001, [65000, 100])
    l = l3vpn.start
    i = l.installed('A').first
    assert_equal(['192.168.2.0/30', nil, ''], [i.prefix, i.ce, i.route.as_path.sub('empty', '')])
  end

  # --- export, pull request 3 ---------------------------------------------

  LABELS = { 'start' => 24000, 'size' => 1000 }.freeze

  def exporting
    @vrfs = BGP::Rib::Vrf.list([
      { 'name' => 'A', 'table' => 100, 'rd' => '65000:1', 'import' => ['65000:100'], 'export' => ['65000:100'],
        'prefixes' => ['172.16.1.0/24'] },
      { 'name' => 'C', 'table' => 300, 'import' => ['65000:300'] },
      { 'name' => 'B', 'table' => 200, 'rd' => '65000:2', 'import' => ['65000:200'], 'export' => ['65000:200'] }])
    @kernel.devices['C'] = 300
  end

  # Section 4.3.2: one label per VRF, from the block, in VRF order; a VRF
  # with no RD and no Export Targets only imports and gets none.
  def test_each_exporting_vrf_gets_a_label_and_its_label_route
    exporting
    l = l3vpn(labels: LABELS).start
    assert_equal({ 'A' => 24000, 'B' => 24001 }, l.labels)
    assert_equal({ 24000 => 'A', 24001 => 'B' }, @kernel.labels)
    assert_includes(@kernel.sent, 'ip -f mpls route flush proto bgp', 'what an earlier bgp4rd left goes first')
    assert_equal([[24000, 'A', true, nil], [24001, 'B', true, nil]],
                 l.label_rows.collect { |r| r.values_at('label', 'vrf', 'installed', 'error') })
  end

  def test_a_vrf_sends_its_connected_and_its_configured_prefixes
    exporting
    l = l3vpn(labels: LABELS).start
    assert_equal([['A', '65000:1', '172.16.1.0/24', 24000, ['65000:100']],
                  ['A', '65000:1', '192.168.1.0/30', 24000, ['65000:100']]],
                 l.exports.collect { |e| e.to_a.first(5) })
    assert_equal([nil], l.exports.collect(&:as_path).uniq, 'ours: no CE path')
  end

  def test_an_unusable_device_takes_its_label_and_its_routes
    exporting
    l = l3vpn(labels: LABELS).start
    @kernel.devices.delete('A')
    l.sync!
    assert_equal({ 24001 => 'B' }, @kernel.labels)
    assert_equal([], l.exports, 'B has no prefixes; A cannot send without its label')
    assert_match(/\Ano VRF device A/, l.label_rows.first['error'])
  end

  # A label nothing pops would drop the far PE's traffic: send nothing.
  def test_a_refused_label_route_sends_nothing
    exporting
    @kernel.refuse = '-f mpls route replace 24000'
    log = []
    l = l3vpn(labels: LABELS, logger: ->(level, msg) { log << [level, msg] }).start
    assert_equal([:warn], log.collect(&:first).uniq, "the speaker's ->(level, message)")
    assert_equal([], l.exports)
    assert_equal([false, 'the kernel refused it: RTNETLINK answers: Invalid argument'],
                 l.label_rows.first.values_at('installed', 'error'))
  end

  def test_stop_flushes_the_label_routes
    exporting
    l = l3vpn(labels: LABELS).start
    l.stop
    assert_equal({}, @kernel.labels)
  end

  def test_the_labels_block_is_checked
    exporting
    e = assert_raise(ArgumentError) { l3vpn }
    assert_equal('l3vpn: labels: { start:, size: } is required: VRF A exports', e.message)
    e = assert_raise(ArgumentError) { l3vpn(labels: { 'start' => 24000, 'size' => 1 }) }
    assert_equal('l3vpn: labels: 1 label(s) for 2 exporting VRFs', e.message)
    e = assert_raise(ArgumentError) { l3vpn(labels: { 'start' => 3, 'size' => 10 }) }
    assert_equal('l3vpn: labels: 3 to 12 is not 16 to 1048575 (RFC 3032)', e.message)
    @vrfs = BGP::Rib::Vrf.list([{ 'name' => 'A', 'table' => 100, 'import' => ['65000:100'] }])
    assert_equal({}, l3vpn.labels, 'no VRF exports, no block needed')
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

  # --- what is installed is the kernel's ----------------------------------

  # Found on l3vpn-lab: `ip route flush vrf A proto bgp` by hand left VRF
  # A empty until bgp4rd restarted. The sync its removal starts puts it
  # back, and the one after sends nothing.
  def test_a_route_removed_by_hand_is_put_back
    announce('10.255.0.3', [65000, 1], '192.168.2.0/30', 24001, [65000, 100])
    announce6('2001:db8:2::/64')
    l = l3vpn.start
    @kernel.routes['A'].clear
    l.sync!
    assert_equal(['192.168.2.0/30', '2001:db8:2::/64'], @kernel.routes['A'].keys.sort)
    assert(l.rows('A').all? { |r| r['installed'] })
    n = @kernel.sent.size
    l.sync!
    assert_equal(n, @kernel.sent.size, 'then nothing: the read-back matches what was sent')
  end

  def test_a_route_changed_by_hand_is_replaced
    announce('10.255.0.3', [65000, 1], '192.168.2.0/30', 24001, [65000, 100])
    l = l3vpn.start
    @kernel.routes['A']['192.168.2.0/30'] = 'encap mpls 99/24001 via 10.0.12.2 dev eth2 proto bgp'
    l.sync!
    assert_equal('encap mpls 17003/24001 via 10.0.12.2 dev eth2 proto bgp', @kernel.routes['A']['192.168.2.0/30'])
  end

  def test_a_label_route_removed_by_hand_is_put_back
    exporting
    l = l3vpn(labels: LABELS).start
    @kernel.labels.delete(24000)
    l.sync!
    assert_equal({ 24000 => 'A', 24001 => 'B' }, @kernel.labels)
    n = @kernel.sent.size
    l.sync!
    assert_equal(n, @kernel.sent.size)
  end

  # The kernel prints a host route's dst with no length: still the same
  # route, so a quiet sync sends nothing.
  def test_a_host_route_reads_back_as_itself
    announce('10.255.0.3', [65000, 1], '10.9.9.9/32', 24001, [65000, 100])
    l = l3vpn.start
    n = @kernel.sent.size
    l.sync!
    assert_equal(n, @kernel.sent.size)
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
