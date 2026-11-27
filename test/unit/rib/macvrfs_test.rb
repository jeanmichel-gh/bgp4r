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

# The MAC-VRFs, filled from the EVPN table and written into vtep4rd:
# docs/design/evpn.md, pull request 2. Routes are built as a session
# receives them, as in evpn_table_test.rb; vtep4rd is FakeVtep, which
# keeps what vtep4rd would and records each order.
# BGP:: names are written out in full here, see Conventions in CLAUDE.md.
class TestBgpRibMacvrfs < Test::Unit::TestCase

  H1 = '02:00:00:00:01:01'
  H2 = '02:00:00:00:01:02'
  L1 = '10.255.0.11'
  L2 = '10.255.0.12'
  L3 = '10.255.0.13'
  RR = '10.255.0.1'

  # vtep4rd's tables and answers, as vtep4r's vxlan/daemon/api.rb gives
  # them after JSON: show.vnis and show.macs rows, and the orders.
  class FakeVtep
    attr_reader :orders
    attr_accessor :down

    # vnis: VNI => its mode, or [mode, encap] for vtep4r's EVPN over MPLS
    # (vtep4r docs/mpls.md): show.vnis then gives encap, labels and
    # flood_labels, and the orders take labels.
    def initialize(vnis)
      @vnis = vnis.to_h do |v, (mode, encap)|
        [v, { 'mode' => mode, 'encap' => encap, 'flood' => [], 'flood_labels' => {}, 'macs' => {}, 'labels' => nil }]
      end
      @orders = []
    end

    def age(vni, mac)
      @vnis[vni]['macs'].delete(mac)
    end

    def learn(vni, mac, port)
      @vnis[vni]['macs'][mac] = { 'mac' => mac, 'type' => 'local', 'port' => port, 'vtep' => nil,
                                  'origin' => 'learned', 'seq' => 0, 'moves' => 0 }
    end

    def api_mac(vni, mac, vtep, seq = 0, label = nil)
      @vnis[vni]['macs'][mac] = { 'mac' => mac, 'type' => 'remote', 'port' => nil, 'vtep' => vtep,
                                  'origin' => 'api', 'seq' => seq, 'moves' => 0 }
      @vnis[vni]['macs'][mac]['label'] = label if label
    end

    def restart
      @vnis.each_value { |v| v['flood'] = [] ; v['macs'] = {} }
    end

    def call(method, params)
      raise Errno::ENOENT, '/run/vtep4r/vtep4rd.sock' if down
      vni = params['vni']
      case method
      when 'show.vnis'
        @vnis.collect do |n, v|
          row = { 'vni' => n, 'mode' => v['mode'], 'remote_vteps' => v['flood'].dup }
          next row unless v['encap']
          row.merge('encap' => v['encap'])
             .merge(v['encap'] == 'mpls' ? { 'labels' => v['labels'], 'flood_labels' => v['flood_labels'].dup } : {})
        end
      when 'show.macs'
        @vnis[vni]['macs'].values.collect(&:dup)
      else
        @orders << [method, params]
        case method
        when 'vni.flood.add'
          @vnis[vni]['flood'] |= [params['vtep']]
          @vnis[vni]['flood_labels'][params['vtep']] = params['label'] if params['label']
        when 'vni.flood.del'
          @vnis[vni]['flood'] -= [params['vtep']]
          @vnis[vni]['flood_labels'].delete(params['vtep'])
        when 'vni.labels' then @vnis[vni]['labels'] = { 'unicast' => params['unicast'], 'bum' => params['bum'] }
        when 'mac.add' then api_mac(vni, params['mac'], params['vtep'], params['seq'], params['label'])
        when 'mac.del' then @vnis[vni]['macs'].delete(params['mac'])
        end
        {}
      end
    end
  end

  def setup
    @now = Time.utc(2026, 11, 25, 12)
    @events = BGP::Events.new
    @t = BGP::Rib::EvpnTable.new(local_as: 65000, router_id: L1)
    @vtep = FakeVtep.new(100 => 'evpn', 200 => 'evpn')
    @m = macvrfs([{ 'vni' => 100 }, { 'vni' => 200 }])
  end

  def macvrfs(config)
    list = BGP::Rib::Macvrf.list(config, address: L1, as: 65000)
    BGP::Rib::Macvrfs.new(table: @t, macvrfs: list, vtep: @vtep, address: L1, events: @events,
                          clock: -> { @now })
  end

  # @m replaced by one with other settings; send_routes syncs it.
  def macvrfs_with(**opts)
    list = BGP::Rib::Macvrf.list([{ 'vni' => 100 }], address: L1, as: 65000)
    @m = BGP::Rib::Macvrfs.new(table: @t, macvrfs: list, vtep: @vtep, address: L1, events: @events,
                               clock: -> { @now }, **opts)
  end

  # What this PE sends: [type, mac, seq] per MAC-VRF 100 route.
  def sent(vni = 100)
    @m.exports.select { |e| e.vni == vni }.collect { |e| [e.route_type, e.mac, e.seq] }
  end

  def evpn_events(type)
    @events.since.select { |e| e.kind == :evpn && e.data['type'] == type }
  end

  def peer(address)
    BGP::Rib::Peer.new(:address => address, :remote_as => 65000, :router_id => address, :local_as => 65000)
  end

  def label1(vni)
    { :label => vni >> 4, :exp => (vni >> 1) & 7, :bottom => vni & 1 }
  end

  def type2(rd, mac, vni: 100, esi: nil)
    h = { :rd => rd, :ethernet_tag_id => 0, :mac => mac, :label1 => label1(vni) }
    h[:esi] = esi if esi
    { :mac_ip_advertisement => h }
  end

  def type3(rd, originator)
    { :inclusive_multicast => { :rd => rd, :ethernet_tag_id => 0, :ip => originator } }
  end

  def ir(id, vni)
    BGP::Pmsi_tunnel.new(:tunnel_type => :ingress_replication, :identifier => id, :label_bits => vni)
  end

  def ecs(rt: 100, encap: :vxlan, seq: nil, sticky: false)
    list = [BGP::Route_target.new(65000, rt)]
    list << BGP::Encapsulation.new(encap) if encap
    list << BGP::Mac_mobility.new(sequence: seq, sticky: sticky) if seq
    list
  end

  # An UPDATE from a peer, through the wire and back, into the table.
  def send_routes(from, nlris, nh: from, ecs: ecs(), pmsi: nil, withdraw: false)
    mp = (withdraw ? BGP::Mp_unreach : BGP::Mp_reach).new(
      { :afi => 25, :safi => 70, :nlris => nlris }.merge(withdraw ? {} : { :nexthop => [nh] }))
    list = withdraw ? [mp] : [BGP::Origin.new(0), BGP::As_path.new, BGP::Local_pref.new(100), mp,
                              BGP::Extended_communities.new(*ecs), *Array(pmsi)]
    u = BGP::Update.new(BGP::Update.new(BGP::Path_attribute.new(*list)).encode)
    @t.apply(from, BGP::Rib::PeerAdapter.evpn_operations(u, peer(from)))
    @m.sync!
  end

  def imet(from, rd, vni: 100, **opts)
    send_routes(from, [type3(rd, from)], pmsi: ir(from, vni), **opts)
  end

  def evpn_row(type, rd, mac = nil)
    @t.rows { |key| @m.route_state(key) }.find { |r| r['route_type'] == type && r['rd'] == rd && r['mac'] == mac }
  end

  # Receiving, step 4: an imported type 3 route gives a flood VTEP, its
  # PMSI Tunnel Identifier; its withdrawal takes it away.
  def test_a_type_3_route_floods_to_its_vtep
    imet(L2, [L2, 100])
    assert_equal([['vni.flood.add', { 'vni' => 100, 'vtep' => L2 }]], @vtep.orders)
    assert_equal({ 'imported' => [100], 'invalid' => nil }, evpn_row(3, "#{L2}:100").slice('imported', 'invalid'))
    send_routes(L2, [type3([L2, 100], L2)], withdraw: true)
    assert_equal(['vni.flood.del', { 'vni' => 100, 'vtep' => L2 }], @vtep.orders.last)
    assert_equal([], @m.rows.first['flood'])
  end

  # Receiving, step 5: an imported type 2 route puts its MAC behind its
  # next hop, "the IPv4 or IPv6 address of the advertising PE" (RFC 7432
  # section 9.2.1), with the route's sequence; its withdrawal deletes it.
  def test_a_type_2_route_puts_a_mac_behind_its_next_hop
    send_routes(RR, [type2([L2, 100], H2)], nh: L2)
    assert_equal([['mac.add', { 'vni' => 100, 'mac' => H2, 'vtep' => L2, 'seq' => 0 }]], @vtep.orders)
    send_routes(RR, [type2([L2, 100], H2)], withdraw: true)
    assert_equal(['mac.del', { 'vni' => 100, 'mac' => H2 }], @vtep.orders.last)
  end

  # Each route goes to the MAC-VRF whose Route Targets import it, and
  # only there (RFC 7432 section 7.10).
  def test_the_route_targets_choose_the_macvrf
    send_routes(L2, [type2([L2, 200], H2, vni: 200)], ecs: ecs(rt: 200))
    send_routes(L2, [type2([L2, 300], H1, vni: 300)], ecs: ecs(rt: 300))
    assert_equal([['mac.add', { 'vni' => 200, 'mac' => H2, 'vtep' => L2, 'seq' => 0 }]], @vtep.orders)
    assert_equal({ 'imported' => [], 'invalid' => nil }, evpn_row(2, "#{L2}:300", H1).slice('imported', 'invalid'))
    assert_equal([[100, 0], [200, 1]], @m.rows.collect { |r| r.values_at('vni', 'macs_remote') })
  end

  # Receiving, steps 4 and 6 to 8, and a route of this VTEP's own: kept,
  # shown with its reason, and not installed.
  def test_what_is_kept_and_not_installed
    send_routes(L2, [type2([L2, 100], H1)], ecs: ecs(encap: nil))
    send_routes(L2, [type2([L2, 101], H1)], ecs: ecs(encap: 10))
    send_routes(L2, [type2([L2, 102], H1, vni: 200)])
    send_routes(L2, [type2([L2, 103], H1, esi: '00:11:22:33:44:55:66:77:88:99')])
    send_routes(L2, [type3([L2, 104], L2)])
    send_routes(L2, [type3([L2, 105], L2)],
                pmsi: BGP::Pmsi_tunnel.new(:pim_ssm, [L2, '232.1.1.1']))
    send_routes(RR, [type2([L1, 106], H1)], nh: L1)
    imet(L1, [L1, 107])
    assert_equal([], @vtep.orders, 'nothing installed')
    assert_equal({ 100 => 'encapsulation', 101 => 'encapsulation', 102 => 'vni', 103 => 'esi', 104 => 'pmsi',
                   105 => 'pmsi', 106 => 'own', 107 => 'own' },
                 @t.rows { |key| @m.route_state(key) }.to_h { |r| [r['rd'].split(':').last.to_i, r['invalid']] })
  end

  # Section 15 across two RDs: the higher sequence, then the lowest
  # address; a sticky MAC always (section 7.7).
  def test_one_mac_under_two_rds
    send_routes(L2, [type2([L2, 100], H2)])
    send_routes(L3, [type2([L3, 100], H2)])
    assert_equal(L2, @m.mac_rows(100).first['vtep'], 'the same sequence: the lowest address')
    send_routes(L3, [type2([L3, 100], H2)], ecs: ecs(seq: 1))
    assert_equal([L3, 1], @m.mac_rows(100).first.values_at('vtep', 'seq'), 'the higher sequence')
    assert_equal(['mac.add', { 'vni' => 100, 'mac' => H2, 'vtep' => L3, 'seq' => 1 }], @vtep.orders.last)
    send_routes(L2, [type2([L2, 100], H2)], ecs: ecs(seq: 0, sticky: true))
    assert_equal([L2, true], @m.mac_rows(100).first.values_at('vtep', 'sticky'), 'sticky')
  end

  # RFC 1982 section 3.2: after 4294967295 comes 0.
  def test_the_sequence_wraps
    send_routes(L2, [type2([L2, 100], H2)], ecs: ecs(seq: 0xffffffff))
    send_routes(L3, [type2([L3, 100], H2)], ecs: ecs(seq: 0))
    assert_equal([L3, 0], @m.mac_rows(100).first.values_at('vtep', 'seq'))
  end

  def test_serial_numbers
    gt = ->(a, b) { BGP::Rib::Macvrfs.serial_gt?(a, b) }
    assert_true(gt.(1, 0))
    assert_false(gt.(0, 1))
    assert_false(gt.(5, 5))
    assert_true(gt.(0, 0xffffffff))
    assert_true(gt.(5, 0xfffffff0))
    assert_false(gt.(0xffffffff, 0))
    # "s1 is not equal to s2, but [...] neither greater than, nor less than".
    assert_false(gt.(1 << 31, 0))
    assert_false(gt.(0, 1 << 31))
  end

  # A sync with nothing changed sends nothing.
  def test_a_second_sync_sends_nothing
    imet(L2, [L2, 100])
    send_routes(L2, [type2([L2, 100], H2)])
    n = @vtep.orders.size
    @m.sync!
    assert_equal(n, @vtep.orders.size)
  end

  # What vtep4rd lost is read again at the next sync and sent again.
  def test_a_restarted_vtep4rd_gets_it_all_back
    imet(L2, [L2, 100])
    send_routes(L2, [type2([L2, 100], H2)])
    @vtep.restart
    @vtep.orders.clear
    @m.sync!
    assert_equal([['vni.flood.add', { 'vni' => 100, 'vtep' => L2 }],
                  ['mac.add', { 'vni' => 100, 'mac' => H2, 'vtep' => L2, 'seq' => 0 }]], @vtep.orders)
  end

  # Every MAC with origin api is bgp4rd's: one no route asks for goes,
  # as one a bgp4rd before a restart put there.
  def test_a_mac_no_route_asks_for_is_deleted
    @vtep.api_mac(100, H1, L3)
    @m.sync!
    assert_equal([['mac.del', { 'vni' => 100, 'mac' => H1 }]], @vtep.orders)
  end

  # A MAC vtep4rd learned on a port, with no route for it: advertised
  # "for the first time [...] with no MAC Mobility extended community",
  # and the type 3 route beside it (Exporting, steps 1 and 2).
  def test_a_local_mac_is_advertised
    @vtep.learn(100, H1, 'eth1')
    @m.sync!
    assert_equal([[3, nil, nil], [2, H1, nil]], sent)
    e = @m.exports.find { |x| x.route_type == 2 }
    assert_equal([100, "#{L1}:100", ['65000:100']], [e.vni, e.rd, e.route_targets])
    assert_equal([[H1, 'local', nil, 'eth1']], @m.mac_rows(100).collect { |r| r.values_at('mac', 'place', 'vtep', 'port') })
    assert_equal(1, @m.rows.first['macs_local'])
    @vtep.age(100, H1)
    @m.sync!
    assert_equal([[3, nil, nil]], sent, 'aged: withdrawn')
  end

  # Section 15: a remote MAC learned locally is advertised with the
  # remote sequence plus one, 0 for a route with no community; vtep4rd
  # keeps the port, and no order is sent.
  def test_a_remote_mac_learned_here_is_advertised_one_higher
    send_routes(L2, [type2([L2, 100], H2)])
    @vtep.learn(100, H2, 'eth1')
    @vtep.orders.clear
    @m.sync!
    assert_equal([[3, nil, nil], [2, H2, 1]], sent)
    assert_equal([], @vtep.orders)
    send_routes(L2, [type2([L2, 100], H2)], ecs: ecs(seq: 7))
    assert_equal([[3, nil, nil]], sent, 'a higher sequence elsewhere: ours withdrawn')
    assert_equal(['mac.add', { 'vni' => 100, 'mac' => H2, 'vtep' => L2, 'seq' => 7 }], @vtep.orders.last)
    assert_equal([['moved', 'local', L2]], evpn_events('moved').last(1).collect { |e| e.data.values_at('type', 'from', 'to') })
  end

  # "If two (or more) PEs advertise the same MAC address with the same
  # sequence number [...] the PE with the lowest IP address" wins, and the
  # originator that lost "will withdraw the route".
  def test_the_same_sequence_and_the_lower_address
    @vtep.learn(100, H2, 'eth1')
    @m.sync!
    assert_equal([2, H2, nil], sent.last)
    send_routes(L2, [type2([L2, 100], H2)])
    assert_equal([2, H2, nil], sent.last, 'L1 is lower than L2: ours stays')
    send_routes('10.255.0.9', [type2(['10.255.0.9', 100], H2)])
    assert_equal([[3, nil, nil]], sent, '10.255.0.9 is lower: ours goes')
    assert_equal(['mac.add', { 'vni' => 100, 'mac' => H2, 'vtep' => '10.255.0.9', 'seq' => 0 }], @vtep.orders.last)
  end

  # RFC 1982: one more than 4294967295 is 0.
  def test_the_sequence_sent_wraps
    send_routes(L2, [type2([L2, 100], H2)], ecs: ecs(seq: 0xffffffff))
    @vtep.learn(100, H2, 'eth1')
    @m.sync!
    assert_equal([2, H2, 0], sent.last)
  end

  # Section 15: a MAC first learned here after its remote route went is
  # sent one above the sequence "previously received".
  def test_the_last_remote_sequence_is_remembered
    send_routes(L2, [type2([L2, 100], H2)], ecs: ecs(seq: 7))
    @now += 10
    send_routes(L2, [type2([L2, 100], H2)], withdraw: true)
    @now += 170
    @m.sync!
    @vtep.learn(100, H2, 'eth1')
    @m.sync!
    assert_equal([2, H2, 8], sent.last, '170 s gone: remembered')
  end

  # A MAC gone from every table for seq_memory seconds, the duplicate
  # window by default, loses its last remote sequence: it comes back as
  # if advertised for the first time. The time counts from the first
  # sync that finds it gone.
  def test_the_last_remote_sequence_is_forgotten
    assert_equal(180, @m.seq_memory)
    send_routes(L2, [type2([L2, 100], H2)], ecs: ecs(seq: 7))
    send_routes(L2, [type2([L2, 100], H2)], withdraw: true)
    @now += 179
    @m.sync!
    @now += 1
    @m.sync!
    @vtep.learn(100, H2, 'eth1')
    @m.sync!
    assert_equal([2, H2, nil], sent.last, '180 s gone: no MAC Mobility community')
  end

  # A MAC still somewhere is not gone: learned here, advertised, or
  # behind a remote VTEP. The time starts again when it goes.
  def test_a_mac_somewhere_keeps_its_sequence
    send_routes(L2, [type2([L2, 100], H2)], ecs: ecs(seq: 7))
    @now += 300
    @m.sync!
    send_routes(L2, [type2([L2, 100], H2)], withdraw: true)
    @now += 100
    @vtep.learn(100, H2, 'eth1')
    @m.sync!
    assert_equal([2, H2, 8], sent.last, 'behind L2 for 300 s, then 100 s gone')
    @now += 300
    @m.sync!
    @vtep.age(100, H2)
    @m.sync!
    @now += 100
    @m.sync!
    @vtep.learn(100, H2, 'eth1')
    @m.sync!
    assert_equal([2, H2, 8], sent.last, 'here for 300 s, then 100 s gone')
  end

  # A MAC marked duplicate keeps its sequence while marked, however long.
  def test_a_duplicate_keeps_its_sequence
    m = macvrfs_with(moves: 2)
    send_routes(L2, [type2([L2, 100], H2)], ecs: ecs(seq: 7))
    @vtep.learn(100, H2, 'eth1')
    m.sync!
    send_routes(L2, [type2([L2, 100], H2)], ecs: ecs(seq: 9))
    @vtep.learn(100, H2, 'eth1')
    m.sync!
    assert_equal(1, evpn_events('duplicate').size)
    send_routes(L2, [type2([L2, 100], H2)], withdraw: true)
    @vtep.age(100, H2)
    m.sync!
    @now += 400
    m.sync!
    m.clear_duplicate(100, H2)
    @now += 10
    m.sync!
    @vtep.learn(100, H2, 'eth1')
    m.sync!
    assert_equal([2, H2, 10], m.exports.select { |e| e.vni == 100 }.collect { |e| [e.route_type, e.mac, e.seq] }.last,
                 '400 s marked, 10 s gone')
  end

  # seq_memory is its own setting.
  def test_seq_memory
    m = macvrfs_with(seq_memory: 30)
    assert_equal(30, m.seq_memory)
    send_routes(L2, [type2([L2, 100], H2)], ecs: ecs(seq: 7))
    send_routes(L2, [type2([L2, 100], H2)], withdraw: true)
    m.sync!
    @now += 30
    m.sync!
    @vtep.learn(100, H2, 'eth1')
    m.sync!
    assert_equal([2, H2, nil], m.exports.select { |e| e.vni == 100 }.collect { |e| [e.route_type, e.mac, e.seq] }.last)
  end

  # Section 7.7 and 15.2: a sticky MAC cannot move. Learned here, it is
  # put back behind its VTEP, and the operator is told once.
  def test_a_sticky_mac_learned_here
    send_routes(L2, [type2([L2, 100], H2)], ecs: ecs(seq: 0, sticky: true))
    @vtep.learn(100, H2, 'eth1')
    @vtep.orders.clear
    @m.sync!
    @m.sync!
    assert_equal([[3, nil, nil]], sent)
    assert_equal([['mac.add', { 'vni' => 100, 'mac' => H2, 'vtep' => L2, 'seq' => 0 }]], @vtep.orders)
    assert_equal(1, evpn_events('sticky').size)
  end

  # Section 15.1: five moves in 180 s, the last a local learn, mark the
  # MAC duplicate. Its route is withdrawn and its routes no longer
  # processed, until evpn.clear_duplicate.
  def test_five_moves_in_180_seconds_mark_a_duplicate
    seq = 0
    move_here = lambda do
      @now += 10
      @vtep.learn(100, H2, 'eth1')
      @m.sync!
    end
    move_away = lambda do
      @now += 10
      seq += 2
      send_routes(L2, [type2([L2, 100], H2)], ecs: ecs(seq: seq))
    end
    send_routes(L2, [type2([L2, 100], H2)])
    move_here.call # 1
    move_away.call # 2
    move_here.call # 3
    move_away.call # 4
    assert_equal([], evpn_events('duplicate'))
    move_here.call # 5
    assert_equal(1, evpn_events('duplicate').size)
    assert_equal([[3, nil, nil]], sent, 'withdrawn')
    row = @m.mac_rows(100).find { |r| r['mac'] == H2 }
    assert_equal([true, 5], row.values_at('duplicate', 'moves'))
    assert_equal(1, @m.rows.first['duplicates'])
    @vtep.orders.clear
    move_away.call
    assert_equal([], @vtep.orders, 'routes for it are not processed')
    assert_equal([[3, nil, nil]], sent, 'nor is it sent again')
    e = assert_raise(ArgumentError) { @m.clear_duplicate(100, H1) }
    assert_equal("vni 100: #{H1} is not marked duplicate", e.message)
    assert_equal({ 'vni' => 100, 'mac' => H2, 'cleared' => true }, @m.clear_duplicate(100, H2.upcase))
    @m.sync!
    assert_equal([2, H2, seq + 1], sent.last, 'cleared, and still on eth1: advertised again, one higher')
    assert_equal(0, @m.rows.first['duplicates'])
  end

  # Moves further apart than 180 s are no duplicate.
  def test_slow_moves_are_no_duplicate
    seq = 0
    send_routes(L2, [type2([L2, 100], H2)])
    6.times do
      @now += 60
      @vtep.learn(100, H2, 'eth1')
      @m.sync!
      @now += 60
      seq += 2
      send_routes(L2, [type2([L2, 100], H2)], ecs: ecs(seq: seq))
    end
    assert_equal([], evpn_events('duplicate'))
  end

  # Exporting, step 6: vtep4rd lost, its routes are kept for the hold,
  # 30 s, then withdrawn. A VNI vtep4rd lacks sends nothing.
  def test_the_hold_on_a_lost_vtep4rd
    @vtep.learn(100, H1, 'eth1')
    @m.sync!
    @vtep.down = true
    @now += 20
    @m.sync!
    assert_equal([[3, nil, nil], [2, H1, nil]], sent)
    @now += 15
    @m.sync!
    assert_equal([], sent)
    @vtep.down = false
    @m.sync!
    assert_equal([[3, nil, nil], [2, H1, nil]], sent)
  end

  def test_a_vni_vtep4rd_lacks_sends_nothing
    @vtep = FakeVtep.new(200 => 'learn')
    @m = macvrfs([{ 'vni' => 100 }, { 'vni' => 200 }])
    @m.sync!
    assert_equal([], @m.exports)
  end

  # Configuration: a VNI vtep4rd lacks, or has in learn mode, gets
  # nothing, and errors says why.
  def test_a_vni_vtep4rd_lacks_or_learns
    @vtep = FakeVtep.new(200 => 'learn')
    @m = macvrfs([{ 'vni' => 100 }, { 'vni' => 200 }])
    imet(L2, [L2, 100])
    send_routes(L2, [type2([L2, 200], H2, vni: 200)], ecs: ecs(rt: 200))
    assert_equal([], @vtep.orders)
    assert_equal(['vni 100: vtep4rd has no such VNI', 'vni 200: vtep4rd has it in learn mode, not evpn'], @m.errors)
    assert_equal(%w[missing mode], @m.rows.collect { |r| r['vtep_state'] })
  end

  def test_vtep4rd_down
    @vtep.down = true
    imet(L2, [L2, 100])
    assert_equal(['vni 100: vtep4rd: No such file or directory - /run/vtep4r/vtep4rd.sock',
                  'vni 200: vtep4rd: No such file or directory - /run/vtep4r/vtep4rd.sock'], @m.errors)
    assert_equal(%w[down down], @m.rows.collect { |r| r['vtep_state'] })
    @vtep.down = false
    @m.sync!
    assert_equal([], @m.errors)
    assert_equal([['vni.flood.add', { 'vni' => 100, 'vtep' => L2 }]], @vtep.orders)
  end

  def test_the_rows
    imet(L2, [L2, 100])
    send_routes(L2, [type2([L2, 100], H2)], ecs: ecs(seq: 3))
    assert_equal({ 'vni' => 100, 'rd' => "#{L1}:100", 'import' => ['65000:100'], 'export' => ['65000:100'],
                   'vtep_state' => 'ok', 'error' => nil, 'flood' => [L2], 'macs_local' => 0, 'macs_remote' => 1,
                   'duplicates' => 0, 'encapsulation' => 'vxlan' }, @m.rows.first)
    r = @m.mac_rows(100).first
    assert_equal([H2, 'remote', L2, 3, false, 0, false], r.values_at('mac', 'place', 'vtep', 'seq', 'sticky', 'moves', 'duplicate'))
    assert_match(/\A\d{4}-\d\d-\d\dT/, r['since'])
    assert_nil(@m.mac_rows(999))
  end

  # EVPN over MPLS (docs/design/evpn-mpls.md). MAC-VRF 300 is mpls, with
  # this PE's labels 25000 (unicast) and 25001 (BUM); L2 gave 26000 and
  # 26001. vtep4rd has VNI 300 as mpls.

  def mpls_setup(vtep_encap: 'mpls')
    @vtep = FakeVtep.new(300 => ['evpn', vtep_encap])
    list = BGP::Rib::Macvrf.list([{ 'vni' => 300, 'encapsulation' => 'mpls', 'import' => ['65000:300'],
                                    'export' => ['65000:300'] }], address: L1, as: 65000)
    BGP::Rib::Macvrf.assign_labels(list, { 'start' => 25_000, 'size' => 100 })
    @m = BGP::Rib::Macvrfs.new(table: @t, macvrfs: list, vtep: @vtep, address: L1, events: @events, clock: -> { @now })
  end

  def mpls_type2(rd, mac, label)
    { :mac_ip_advertisement => { :rd => rd, :ethernet_tag_id => 0, :mac => mac, :label1 => { :label => label } } }
  end

  def mpls_ir(id, label)
    BGP::Pmsi_tunnel.new(:tunnel_type => :ingress_replication, :identifier => id, :label => label)
  end

  def test_over_mpls_our_labels_go_to_vtep4rd_first
    mpls_setup
    @m.sync!
    assert_equal([['vni.labels', { 'vni' => 300, 'unicast' => 25_000, 'bum' => 25_001 }]], @vtep.orders)
    @m.sync!
    assert_equal(1, @vtep.orders.size, 'not sent again while vtep4rd has them')
  end

  # Receiving over MPLS: no Encapsulation community, the remote PE's
  # labels taken as 20 bits.
  def test_over_mpls_a_remote_pes_labels_go_to_vtep4rd
    mpls_setup
    send_routes(L2, [type3([L2, 300], L2)], pmsi: mpls_ir(L2, 26_001), ecs: ecs(rt: 300, encap: nil))
    send_routes(L2, [mpls_type2([L2, 300], H2, 26_000)], ecs: ecs(rt: 300, encap: nil))
    assert_include(@vtep.orders, ['vni.flood.add', { 'vni' => 300, 'vtep' => L2, 'label' => 26_001 }])
    assert_include(@vtep.orders, ['mac.add', { 'vni' => 300, 'mac' => H2, 'vtep' => L2, 'seq' => 0, 'label' => 26_000 }])
    n = @vtep.orders.size
    @m.sync!
    assert_equal(n, @vtep.orders.size, 'nothing again while nothing changed')
    assert_equal([{ 'mac' => H2, 'label' => 26_000 }], @m.mac_rows(300).collect { |r| r.slice('mac', 'label') })
    row = @m.rows.first
    assert_equal(['mpls', { 'unicast' => 25_000, 'bum' => 25_001 }, { L2 => 26_001 }],
                 row.values_at('encapsulation', 'labels', 'flood_labels'))
  end

  # A remote PE that gives a new label is sent again.
  def test_over_mpls_a_new_remote_label_is_sent_again
    mpls_setup
    send_routes(L2, [type3([L2, 300], L2)], pmsi: mpls_ir(L2, 26_001), ecs: ecs(rt: 300, encap: nil))
    send_routes(L2, [type3([L2, 300], L2)], pmsi: mpls_ir(L2, 26_011), ecs: ecs(rt: 300, encap: nil))
    assert_equal(['vni.flood.add', { 'vni' => 300, 'vtep' => L2, 'label' => 26_011 }], @vtep.orders.last)
  end

  # An MPLS route may say MPLS (tunnel type 10, RFC 8365 section 11); one
  # that says VXLAN is not for an MPLS MAC-VRF, nor a reserved label.
  def test_over_mpls_what_is_refused
    mpls_setup
    send_routes(L2, [mpls_type2([L2, 300], H2, 26_000)], ecs: ecs(rt: 300, encap: 10))
    assert_nil(evpn_row(2, "#{L2}:300", H2)['invalid'])
    send_routes(L3, [mpls_type2([L3, 300], H1, 26_000)], ecs: ecs(rt: 300, encap: :vxlan))
    assert_equal('encapsulation', evpn_row(2, "#{L3}:300", H1)['invalid'])
    send_routes(L3, [mpls_type2([L3, 301], '02:00:00:00:01:09', 3)], ecs: ecs(rt: 300, encap: nil))
    assert_equal('label', evpn_row(2, "#{L3}:301", '02:00:00:00:01:09')['invalid'])
  end

  # A VXLAN MAC-VRF still refuses a route with no Encapsulation community.
  def test_a_vxlan_macvrf_refuses_a_route_with_no_encapsulation
    send_routes(L2, [type2([L2, 100], H2)], ecs: ecs(encap: nil))
    assert_equal('encapsulation', evpn_row(2, "#{L2}:100", H2)['invalid'])
  end

  # vtep4rd with the VNI as vxlan, or a vtep4rd from before EVPN over
  # MPLS, which gives no encap: the MAC-VRF is not served.
  def test_over_mpls_a_vtep4rd_with_the_vni_as_vxlan_is_refused
    mpls_setup(vtep_encap: nil)
    @m.sync!
    assert_equal([], @vtep.orders)
    assert_equal(['encap', 'vtep4rd has it as vxlan, not mpls'], @m.rows.first.values_at('vtep_state', 'error'))
  end

  # Exporting over MPLS: the labels, and no Encapsulation community.
  def test_over_mpls_exports_carry_our_labels
    mpls_setup
    @vtep.learn(300, H1, 'eth3')
    @m.sync!
    assert_equal([[3, nil, 'mpls', 25_001], [2, H1, 'mpls', 25_000]],
                 @m.exports.collect { |e| [e.route_type, e.mac, e.encapsulation, e.label] })
  end
end
