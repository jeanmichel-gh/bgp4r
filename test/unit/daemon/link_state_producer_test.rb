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
require 'bgp/daemon/speaker'
require 'bgp/daemon/link_state_producer'
require 'test/helpers/fake_isisd'

# The BGP-LS Producer of docs/design/bgp-ls-producer.md, against a fake
# isisd that plays `show.topology` answers and `spf` events. The peers
# are fakes too, so what was sent is read as Update objects.
class BGP_Daemon_LinkStateProducer_Test < Test::Unit::TestCase

  # A peer with the methods the Producer calls, which records what it
  # was sent.
  class FakePeer
    attr_reader :address, :sent
    attr_accessor :up, :session_info

    def initialize(address, bgp_ls = true, ebgp = true)
      @address, @ebgp, @up = address, ebgp, true
      @sent = []
      @lock = Mutex.new
      @session_info = BGP_Daemon_LinkStateProducer_Test.session_info(bgp_ls)
    end

    def established? ; @up ; end
    def ebgp? ; @ebgp ; end
    def local_ip ; '10.2.0.1' ; end
    def send_message(u) ; @lock.synchronize { @sent << u } ; end
    def updates ; @lock.synchronize { @sent.dup } ; end
    def clear ; @lock.synchronize { @sent.clear } ; end
  end

  class FakeSpeaker
    attr_reader :peers
    def initialize(peers) ; @peers = peers ; end
    def peer(a) ; @peers.find { |p| p.address == a } ; end
    def my_as ; 65_001 ; end
  end

  def self.session_info(bgp_ls)
    caps = bgp_ls ? [BGP::OPT_PARM::CAP::Mbgp.new(16_388, 71)] : [BGP::OPT_PARM::CAP::Mbgp.new(1, 1)]
    ours = BGP::Open.new(4, 65_001, 180, '10.0.0.1', *caps)
    theirs = BGP::Open.new(4, 65_002, 180, '10.0.0.2', BGP::OPT_PARM::CAP::Mbgp.new(16_388, 71))
    BGP::Neighbor::Capabilities.new(ours, theirs)
  end

  def node(id, name, neighbors, prefixes, extra = {})
    { 'id' => id, 'hostname' => name, 'areas' => ['49.0001'], 'overload' => false,
      'attached' => false, 'reachable' => true,
      'neighbors' => neighbors.collect { |n, m| { 'id' => n, 'metric' => m, 'style' => 'wide' } },
      'prefixes' => prefixes.collect { |p| { 'prefix' => p, 'metric' => 0, 'up_down' => false, 'style' => 'wide' } } }
      .merge(extra)
  end

  R1 = '0000.0001.0101.00'
  R2 = '0000.0001.0102.00'
  R3 = '0000.0001.0103.00'

  # r1 -- r2 -- r3, one prefix each: 3 Node, 4 Link and 3 Prefix NLRIs.
  def fixture
    { 1 => { 'level' => 1, 'run' => 1,
             'nodes' => [node(R1, 'r1', [[R2, 10]], ['10.200.0.1/32']),
                         node(R2, 'r2', [[R1, 10], [R3, 10]], ['10.200.0.2/32']),
                         node(R3, 'r3', [[R2, 10]], ['10.200.0.3/32'])] } }
  end

  def setup
    @isisd = BGP::TestHelpers::FakeIsisd.new(fixture)
    @peer = FakePeer.new('10.2.0.2')
    @speaker = FakeSpeaker.new([@peer, FakePeer.new('10.2.0.3'), FakePeer.new('10.2.0.4', false)])
  end

  def teardown
    @producer.stop if @producer
    @isisd.stop
  end

  def producer(extra = {})
    config = { 'isisd' => @isisd.path, 'levels' => [1], 'peers' => %w[10.2.0.2 10.2.0.4] }.merge(extra)
    @producer = BGP::Daemon::LinkStateProducer.new(@speaker, config, :retry => 0.05, :logger => ->(_level, _message) {})
  end

  def wait_for(timeout = 5)
    deadline = Time.now + timeout
    until yield
      flunk('timed out') if Time.now > deadline
      sleep 0.01
    end
  end

  def started
    producer.start
    wait_for { @producer.reads == 1 }
    @producer
  end

  # Changes the fixture, sends an spf event, and waits for the read.
  def change
    reads = @producer.reads
    @peer.clear
    yield @isisd.topology[1]['nodes']
    @isisd.spf(1)
    wait_for { @producer.reads > reads }
  end

  def reached(peer = @peer)
    peer.updates.flat_map { |u|
      mp = u.path_attribute.find(BGP::Mp_reach)
      mp ? mp.nlris : []
    }
  end

  def unreached(peer = @peer)
    peer.updates.flat_map { |u|
      mp = u.path_attribute.find(BGP::Mp_unreach)
      mp ? mp.nlris : []
    }
  end

  def kinds(nlris) ; nlris.collect { |ls| BGP::Daemon::LinkStateTable.type(ls.nlri) }.tally ; end

  def find(node_name, nodes) ; nodes.find { |n| n['hostname'] == node_name } ; end

  def attribute_of(ls, peer = @peer)
    u = peer.updates.find { |x|
      mp = x.path_attribute.find(BGP::Mp_reach)
      mp && mp.nlris.any? { |n| n.encode == ls.encode }
    }
    u.path_attribute.find(BGP::Link_state_attribute)
  end

  # --- the read and the diff --------------------------------------------

  def test_the_first_read_sends_every_node_link_and_prefix_nlri
    started
    assert_equal({ 'node' => 3, 'link' => 4, 'prefix' => 3 }, kinds(reached))
    assert_equal([], unreached)
    assert_equal(10, @producer.size)
    u = @peer.updates.first
    mp = u.path_attribute.find(BGP::Mp_reach)
    assert_equal([16_388, 71], [mp.afi, mp.safi])
    assert_equal('65001', u.path_attribute.find(BGP::As_path).as_path, 'our AS toward an external peer')
  end

  def test_it_subscribes_then_reads_each_configured_level
    started
    assert_equal(%w[events.subscribe show.topology], @isisd.requests.collect { |r| r['method'] })
    assert_equal({ 'level' => 1 }, @isisd.requests.last['params'])
  end

  def test_a_metric_change_sends_one_link_nlri
    started
    change { |nodes| find('r1', nodes)['neighbors'].first['metric'] = 20 }
    assert_equal({ 'link' => 1 }, kinds(reached))
    assert_equal([], unreached)
    ls = reached.first
    assert_equal('0000.0001.0101.00', BGP::Daemon::LinkStateTable.node_id(ls.nlri.local_node_descriptors))
    assert_equal(20, attribute_of(ls).tlv(1095).metric)
  end

  def test_a_link_gone_sends_two_withdrawals_one_per_direction
    started
    change do |nodes|
      find('r1', nodes)['neighbors'].clear
      find('r2', nodes)['neighbors'].reject! { |n| n['id'] == R1 }
    end
    assert_equal([], reached)
    assert_equal({ 'link' => 2 }, kinds(unreached))
    ends = unreached.collect { |ls|
      [ls.nlri.local_node_descriptors, ls.nlri.remote_node_descriptors]
        .collect { |d| BGP::Daemon::LinkStateTable.node_id(d) }
    }
    assert_equal([[R1, R2], [R2, R1]], ends.sort)
  end

  def test_overload_on_sends_the_node_nlri_with_o_set
    started
    change { |nodes| find('r2', nodes)['overload'] = true }
    assert_equal({ 'node' => 1 }, kinds(reached))
    assert(attribute_of(reached.first).tlv(1024).overload?)
  end

  def test_a_prefix_gone_sends_one_withdrawal
    started
    change { |nodes| find('r3', nodes)['prefixes'].clear }
    assert_equal([], reached)
    assert_equal(['10.200.0.3/32'], unreached.collect { |ls| ls.nlri.prefix })
  end

  # RFC 9552 section 5.9: withdraw what an unreachable node originated,
  # and "it MUST re-advertise those link-state objects after that node
  # becomes reachable again".
  def test_an_unreachable_node_is_withdrawn_then_sent_again
    started
    change { |nodes| find('r3', nodes)['reachable'] = false }
    assert_equal([], reached)
    assert_equal({ 'node' => 1, 'link' => 1, 'prefix' => 1 }, kinds(unreached))
    change { |nodes| find('r3', nodes)['reachable'] = true }
    assert_equal({ 'node' => 1, 'link' => 1, 'prefix' => 1 }, kinds(reached))
    assert_equal([], unreached)
  end

  def test_unreachable_keep_keeps_the_node
    producer('unreachable' => 'keep').start
    wait_for { @producer.reads == 1 }
    change { |nodes| find('r3', nodes)['reachable'] = false }
    assert_equal([], @peer.updates)
    assert_equal(10, @producer.size)
  end

  # `unreachable` changed on a running Producer rebuilds from the
  # topology it last read: the peer sees it with no SPF and no read.
  def test_switching_to_keep_sends_an_unreachable_node_again_at_once
    started
    change { |nodes| find('r3', nodes)['reachable'] = false }
    assert_equal(7, @producer.size)
    @peer.clear
    reads = @producer.reads
    announced, withdrawn = @producer.set_unreachable('keep')
    assert_equal('keep', @producer.unreachable)
    assert_equal({ 'node' => 1, 'link' => 1, 'prefix' => 1 }, kinds(reached))
    assert_equal(3, announced.size)
    assert_equal([], withdrawn)
    assert_equal(10, @producer.size)
    assert_equal(reads, @producer.reads)
  end

  def test_switching_back_to_withdraw_withdraws_at_once
    producer('unreachable' => 'keep').start
    wait_for { @producer.reads == 1 }
    change { |nodes| find('r3', nodes)['reachable'] = false }
    assert_equal([], @peer.updates)
    @producer.unreachable = 'withdraw'
    assert_equal([], reached)
    assert_equal({ 'node' => 1, 'link' => 1, 'prefix' => 1 }, kinds(unreached))
    assert_equal(7, @producer.size)
  end

  def test_unreachable_before_the_first_read_changes_the_next_one
    producer
    assert_equal([[], []], @producer.set_unreachable(:keep))
    assert_equal('keep', @producer.unreachable)
    assert_equal([], @peer.updates)
  end

  def test_an_unreachable_that_is_not_withdraw_or_keep_is_refused
    started
    e = assert_raise(ArgumentError) { @producer.set_unreachable('drop') }
    assert_match(/withdraw or keep, not drop/, e.message)
    assert_equal('withdraw', @producer.unreachable)
  end

  def test_a_refresh_that_changes_nothing_sends_nothing
    started
    change { |_nodes| }
    assert_equal([], @peer.updates)
  end

  def test_an_spf_event_of_another_level_does_not_read
    started
    @isisd.spf(2)
    @isisd.spf(1)
    wait_for { @producer.reads == 2 }
    sleep 0.2
    assert_equal(2, @producer.reads)
  end

  def test_the_socket_closing_and_coming_back_sends_only_the_diff
    started
    @peer.clear
    @isisd.topology[1]['nodes'].find { |n| n['hostname'] == 'r3' }['prefixes'].clear
    @isisd.drop
    wait_for { @producer.reads == 2 }
    assert_equal(2, @isisd.subscriptions, 'it subscribed again')
    assert_equal([], reached)
    assert_equal(['10.200.0.3/32'], unreached.collect { |ls| ls.nlri.prefix })
  end

  def test_an_isisd_that_is_not_there_is_tried_again
    @isisd.stop
    @isisd = BGP::TestHelpers::FakeIsisd.new(fixture)
    p = producer('isisd' => File.join(Dir.tmpdir, "no-isisd-#{$$}.sock")).start
    wait_for { p.last_error }
    assert_match(/ENOENT|No such file/, p.last_error)
    assert_equal(0, p.reads)
  end

  # --- who gets it --------------------------------------------------------

  def test_a_session_coming_up_gets_the_whole_set
    started
    @peer.clear
    @producer.session_up(@peer)
    assert_equal({ 'node' => 3, 'link' => 4, 'prefix' => 3 }, kinds(reached))
  end

  def test_only_a_configured_peer_that_negotiated_bgp_ls_gets_it
    started
    unlisted = @speaker.peer('10.2.0.3')
    not_negotiated = @speaker.peer('10.2.0.4')
    assert_equal([], unlisted.updates, 'not in peers')
    assert_equal([], not_negotiated.updates, 'in peers, but no 16388/71')
    @producer.session_up(unlisted)
    @producer.session_up(not_negotiated)
    assert_equal([], unlisted.updates)
    assert_equal([], not_negotiated.updates)
  end

  def test_a_peer_that_is_down_gets_nothing_until_it_comes_up
    @peer.up = false
    started
    assert_equal([], @peer.updates)
    @peer.up = true
    @producer.session_up(@peer)
    assert_equal(10, reached.size)
  end

  def test_an_internal_peer_gets_an_empty_as_path_and_local_pref
    @peer = FakePeer.new('10.2.0.2', true, false)
    @speaker = FakeSpeaker.new([@peer])
    producer('peers' => ['10.2.0.2']).start
    wait_for { @producer.reads == 1 }
    pa = @peer.updates.first.path_attribute
    assert_equal('', pa.find(BGP::As_path).as_path.sub('empty', ''))
    assert_equal(100, pa.find(BGP::Local_pref).to_i)
  end

  def test_rows_are_what_was_sent_with_peer_null
    started
    rows = @producer.rows
    assert_equal(10, rows.size)
    node = rows.find { |r| r['type'] == 'node' && r['name'] == 'r1' }
    assert_equal({ 'peer' => nil, 'type' => 'node', 'protocol_id' => 1, 'identifier' => 0,
                   'local' => R1, 'remote' => nil, 'prefix' => nil, 'name' => 'r1',
                   'flags' => [], 'areas' => ['49.0001'], 'metric' => nil,
                   'area' => nil, 'route_type' => nil, 'forwarding' => nil },
                 node.reject { |k, _| k == 'since' })
    assert_match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z\z/, node['since'])
  end

  # --- the configuration --------------------------------------------------

  def test_the_defaults
    p = BGP::Daemon::LinkStateProducer.new(@speaker, {})
    assert_equal('/run/isis4r/isisd.sock', p.path)
    assert_equal([1], p.levels)
    assert_equal(0, p.identifier)
    assert_equal([], p.peers)
  end

  def test_a_bad_block_is_refused_by_name
    { { 'isisd' => 'x', 'level' => [1] } => /unknown key\(s\) level/,
      { 'levels' => [3] } => /levels are 1 and 2/,
      { 'peers' => ['192.0.2.9'] } => /192\.0\.2\.9 are not configured/,
      { 'unreachable' => 'drop' } => /withdraw or keep/ }.each do |config, why|
      e = assert_raise(ArgumentError) { BGP::Daemon::LinkStateProducer.new(@speaker, config) }
      assert_match(why, e.message)
    end
    assert_raise(ArgumentError) { BGP::Daemon::LinkStateProducer.new(@speaker, 'yes') }
  end

  # --- the encoded routes, byte for byte ----------------------------------

  T = BGP::Link_state::Tlv

  def routes_of(n, pid = 1, identifier = 0)
    BGP::Daemon::LinkStateProducer.node_routes(n, pid, identifier)
  end

  # Figure 7 with the IGP Router-ID of section 5.2.1.4, written out:
  # type 1, length 23, Protocol-ID 1, Identifier 0, TLV 256 holding TLV
  # 515 with the 6-octet system ID.
  def test_a_node_nlri_with_a_6_octet_router_id
    ls, = routes_of(node(R1, 'r1', [], []))[0]
    assert_equal('0001' '0017' '01' '0000000000000000' '0100000a' '02030006' '000000010101', ls.to_shex)
    hand = BGP::Link_state.new(BGP::Link_state::Node.new(
      :protocol_id => 1, :identifier => 0,
      :tlvs => [{ :local_node_descriptors => [{ :igp_router_id => '000000010101' }] }]))
    assert_equal(hand.encode, ls.encode)
  end

  # A pseudonode: 7 octets, the PSN octet last.
  def test_a_link_to_a_pseudonode_has_a_7_octet_remote_router_id
    _node, (ls, _attr) = routes_of(node(R1, 'r1', [['0000.0001.0102.01', 10]], []))
    hand = BGP::Link_state.new(:link => {
      :protocol_id => 1, :identifier => 0,
      :tlvs => [{ :local_node_descriptors => [{ :igp_router_id => '000000010101' }] },
                { :remote_node_descriptors => [{ :igp_router_id => '00000001010201' }] }] })
    assert_equal(hand.encode, ls.encode)
    assert_match(/0101000b0203000700000001010201\z/, ls.to_shex)
    assert_equal(7, ls.nlri.remote_node_descriptors.sub_tlvs.first.value.size)
  end

  # RFC 9552 section 5.2.2, Table 4: TLV 259 is IS-IS 22/6 and 260 is
  # 22/8, and "If interface and neighbor addresses ... are present, then
  # the interface/neighbor address TLVs MUST be included". isisd gives
  # the two sub-TLVs per neighbor; with one of them missing, neither is
  # sent, as on the OSPF path.
  def test_a_link_with_both_addresses_carries_259_and_260
    n = node(R1, 'r1', [[R2, 10]], [])
    n['neighbors'][0].merge!('interface_address' => '10.0.12.1', 'neighbor_address' => '10.0.12.2')
    _node, (ls, _attr) = routes_of(n)
    hand = BGP::Link_state.new(:link => {
      :protocol_id => 1, :identifier => 0,
      :tlvs => [{ :local_node_descriptors => [{ :igp_router_id => '000000010101' }] },
                { :remote_node_descriptors => [{ :igp_router_id => '000000010102' }] },
                { :ipv4_interface_address => '10.0.12.1' },
                { :ipv4_neighbor_address => '10.0.12.2' }] })
    assert_equal(hand.encode, ls.encode)
    assert_match(/010300040a000c01010400040a000c02\z/, ls.to_shex)
    _node, (plain, _attr) = routes_of(node(R1, 'r1', [[R2, 10]], []))
    %w[interface_address neighbor_address].each do |k|
      one = node(R1, 'r1', [[R2, 10]], [])
      one['neighbors'][0][k] = '10.0.12.1'
      _node, (alone, _attr) = routes_of(one)
      assert_equal(plain.to_shex, alone.to_shex, "#{k} alone sends neither")
    end
  end

  def test_the_identifier_and_the_level_are_in_the_head
    ls, = routes_of(node(R1, 'r1', [], []), 2, 7)[0]
    assert_equal('0001' '0017' '02' '0000000000000007', ls.to_shex[0, 26])
  end

  # Section 5.3.2.4: "IS-IS wide metrics have a length of 3 octets", and
  # a narrow one is 1. TLV 1095.
  def test_metric_widths_3_and_1
    n = node(R1, 'r1', [[R2, 10], [R3, 63]], [])
    n['neighbors'][1]['style'] = 'narrow'
    _node, (_l1, wide), (_l2, narrow) = routes_of(n)
    assert_equal(BGP::Link_state_attribute.new(T::Igp_metric.new(10, 3)).encode, wide.encode)
    assert_match(/0447000300000a\z/, wide.to_shex)
    assert_equal(BGP::Link_state_attribute.new(T::Igp_metric.new(63, 1)).encode, narrow.encode)
    assert_match(/044700013f\z/, narrow.to_shex)
  end

  # Table 7: O is 0x80 and A is 0x40, the A per erratum 7789. The
  # attribute holds 1024, then 1026, then one 1027 per area, in type
  # order as section 5.1 asks.
  def test_node_flags_o_and_a
    n = node(R1, 'r1', [], [], 'overload' => true, 'attached' => true, 'areas' => ['49.0001', '49.0002'])
    _ls, attr = routes_of(n)[0]
    hand = BGP::Link_state_attribute.new(T::Node_flag_bits.new(:overload, :attached),
                                         T::Node_name.new('r1'),
                                         T::Isis_area_id.new(['490001'].pack('H*')),
                                         T::Isis_area_id.new(['490002'].pack('H*')))
    assert_equal(hand.encode, attr.encode)
    assert_match(/040000 01c0 0402 0002 7231 0403 0003 490001 0403 0003 490002\z/x, attr.to_shex)
    { 'overload' => '80', 'attached' => '40' }.each do |k, bits|
      _ls, a = routes_of(node(R1, '', [], [], k => true, 'areas' => []))[0]
      assert_match(/04000001#{bits}\z/, a.to_shex, k)
    end
    _ls, none = routes_of(node(R1, nil, [], [], 'areas' => []))[0]
    assert_match(/0400000100\z/, none.to_shex, 'no bit, no name, no area')
  end

  def test_a_prefix_nlri_and_its_metric
    _node, (ls, attr) = routes_of(node(R1, 'r1', [], ['10.200.0.1/32', '2001:db8::/64']))
    assert_equal(2, routes_of(node(R1, 'r1', [], ['10.200.0.1/32', '2001:db8::/64'])).size,
                 'phase 1 leaves out IPv6 prefixes')
    hand = BGP::Link_state.new(:ipv4_prefix => {
      :protocol_id => 1, :identifier => 0,
      :tlvs => [{ :local_node_descriptors => [{ :igp_router_id => '000000010101' }] },
                { :ip_reachability => '10.200.0.1/32' }] })
    assert_equal(hand.encode, ls.encode)
    assert_equal(BGP::Link_state_attribute.new(T::Prefix_metric.new(0)).encode, attr.encode)
  end

  def test_router_id_from_isisd_text
    assert_equal('000000010101', BGP::Daemon::LinkStateProducer.router_id('0000.0001.0101.00'))
    assert_equal('00000001010201', BGP::Daemon::LinkStateProducer.router_id('0000.0001.0102.01'))
  end

  # --- SR, RFC 9085, from isisd's show.topology ----------------------------

  # A real level-2 answer, isisd with isis #118, recorded on 2026-11-22
  # from r1 of isis's isis4r-sr lab (routescope's ~/labs/isis/isis4r-sr):
  # 14 nodes, each with an SRGB, an SRLB, Adj-SIDs and a Prefix-SID.
  SR_TOPOLOGY = File.expand_path('../../fixtures/isisd/show_topology_sr_l2.json', __dir__)

  def recorded
    require 'json'
    JSON.parse(File.read(SR_TOPOLOGY))
  end

  P = BGP::Daemon::LinkStateProducer
  LST = BGP::Daemon::LinkStateTable

  # Every SR value isisd gives reaches its row unchanged: the Producer
  # encodes isisd's keys into RFC 9085's TLVs, and the row decodes them
  # back into isisd's keys. So `sr`, `adj_sids` and `prefix_sid` go in
  # and come out the same, for every node of the recording.
  def test_every_sr_value_of_a_recorded_topology_comes_back_in_its_row
    topo = recorded
    sr = adj = pfx = 0
    topo['nodes'].each do |node|
      rows = P.node_routes(node, 2, 0).collect { |ls, a| [ls, LST.row(ls, a, nil, Time.now)] }
      node_row = rows.find { |_, r| r['type'] == 'node' }[1]
      assert_equal(node['sr'], node_row['sr'], node['hostname'])
      sr += 1
      node['neighbors'].each do |nb|
        rid = P.router_id(nb['id'])
        _, r = rows.find { |ls, x| x['type'] == 'link' && ls.nlri.remote_node_descriptors.encode.include?([rid].pack('H*')) }
        assert_equal(nb['adj_sids'], r['adj_sids'], "#{node['hostname']} to #{nb['id']}")
        adj += Array(nb['adj_sids']).size
      end
      node['prefixes'].select { |p| p['prefix_sid'] }.each do |p|
        _, r = rows.find { |_, x| x['prefix'] == p['prefix'] }
        assert_equal(p['prefix_sid'], r['prefix_sid'], p['prefix'])
        pfx += 1
      end
    end
    assert_equal([14, 34, 14], [sr, adj, pfx], 'not vacuous: the recording\'s counts')
  end

  # r1's Node NLRI attribute, octet by octet, from RFC 9085's figures:
  # SR Capabilities 040a, length 12, flags 0x80 (I), Reserved 0, Range
  # Size 8000 (001f40), SID/Label 0489 length 3, label 17000 (004268);
  # SR Algorithm 040b, length 1, algorithm 0; SR Local Block 040c,
  # length 12, flags 0, Range Size 1000 (0003e8), label 15000 (003a98).
  def test_a_recorded_nodes_sr_tlvs_octet_by_octet
    r1 = recorded['nodes'].find { |n| n['hostname'] == 'r1' }
    _, attr = P.node_routes(r1, 2, 0).first
    assert_equal([1024, 1026, 1027, 1034, 1035, 1036], attr.tlvs.collect(&:type),
                 'ascending, as RFC 9552 section 5.1 asks of a sender')
    hex = attr.tlvs.select { |t| t.type >= 1034 }.collect(&:to_shex).join
    assert_equal('040a000c' + '8000' + '001f40' + '04890003004268' +
                 '040b0001' + '00' +
                 '040c000c' + '0000' + '0003e8' + '04890003003a98', hex)
  end

  # Each TLV goes only on the NLRI of the node that originated the IGP
  # sub-TLV (RFC 9085 sections 2.1, 2.2, 2.3): r1's Adj-SIDs are on the
  # links whose local node is r1, and r1's Prefix-SID on its own prefix.
  def test_each_sr_tlv_goes_on_the_nlri_of_its_own_node
    r1 = recorded['nodes'].find { |n| n['hostname'] == 'r1' }
    P.node_routes(r1, 2, 0).each do |ls, a|
      assert_equal('0000.0000.0002.00', LST.node_id(ls.nlri.local_node_descriptors))
      case LST.type(ls.nlri)
      when 'node'   then assert_equal(3, a.tlvs.count { |t| [1034, 1035, 1036].include?(t.type) })
      when 'link'   then assert_equal(1, a.tlvs.count { |t| t.type == 1099 })
      when 'prefix' then assert_equal(1, a.tlvs.count { |t| t.type == 1158 })
      end
    end
  end

  # A node with no SR gets no SR TLV, so a topology without SR sends the
  # same octets as before.
  def test_a_node_without_sr_gets_no_sr_tlv
    sr_types = [1034, 1035, 1036, 1099, 1100, 1158]
    fixture[1]['nodes'].each do |n|
      P.node_routes(n, 1, 0).each do |_, a|
        assert_equal([], a.tlvs.collect(&:type) & sr_types)
      end
    end
  end

  # The recording has point-to-point links only, so a LAN Adj-SID is
  # built here in isisd's spelling: `neighbor`, `flags`, `label`
  # (isis lib/isis/subtlv/extended_is_reachability.rb, LanAdjSid#to_hash).
  # Toward a pseudonode, with an index form and a weight beside it.
  def test_lan_adj_sids_go_on_the_link_toward_the_pseudonode
    n = node(R1, 'r1', [['0000.0001.0101.01', 10]], [])
    n['neighbors'][0]['lan_adj_sids'] = [{ 'neighbor' => '0000.0001.0102', 'flags' => %w[V L], 'label' => 15001 },
                                         { 'neighbor' => '0000.0001.0103', 'flags' => [], 'weight' => 2, 'index' => 7 }]
    ls, a = P.node_routes(n, 1, 0).find { |l, _| LST.type(l.nlri) == 'link' }
    assert_equal([1095, 1100, 1100], a.tlvs.collect(&:type))
    assert_equal('044c000d' + '30000000' + '000000010102' + '003a99', a.tlvs[1].to_shex)
    assert_equal('044c000e' + '00020000' + '000000010103' + '00000007', a.tlvs[2].to_shex)
    assert_equal([{ 'neighbor' => '0000.0001.0102', 'flags' => %w[V L], 'label' => 15001 },
                  { 'neighbor' => '0000.0001.0103', 'weight' => 2, 'index' => 7 }],
                 LST.row(ls, a, nil, Time.now)['lan_adj_sids'])
  end

  # An SR change in isisd is a new attribute for that one NLRI: sent
  # again, alone, with the NLRIs and their withdrawal as they were.
  def test_an_sr_change_sends_only_the_route_it_changed
    started
    change do |nodes|
      find('r2', nodes)['prefixes'][0]['prefix_sid'] = { 'flags' => ['N'], 'algorithm' => 0, 'index' => 2 }
    end
    assert_equal({ 'prefix' => 1 }, kinds(reached))
    assert_equal([], unreached)
    ls = reached.first
    assert_equal({ 'flags' => ['N'], 'index' => 2, 'algorithm' => 0 },
                 LST.row(ls, attribute_of(ls), nil, Time.now)['prefix_sid'])
    change do |nodes|
      find('r2', nodes)['prefixes'][0]['prefix_sid']['index'] = 20
    end
    assert_equal({ 'prefix' => 1 }, kinds(reached))
    change do |nodes|
      find('r2', nodes)['prefixes'][0].delete('prefix_sid')
    end
    assert_equal({ 'prefix' => 1 }, kinds(reached), 'and its removal is a new attribute too')
    assert_equal([1155], attribute_of(reached.first).tlvs.collect(&:type))
  end

  # isisd giving a flag letter RFC 8667 does not name is a bad read, as
  # any other malformed answer is: the Producer's thread logs it and
  # tries again (`run` rescues ArgumentError).
  def test_an_unknown_flag_letter_is_an_argument_error
    n = node(R1, 'r1', [], ['10.200.0.1/32'])
    n['prefixes'][0]['prefix_sid'] = { 'flags' => ['Q'], 'algorithm' => 0, 'index' => 1 }
    assert_raise(ArgumentError) { P.node_routes(n, 1, 0) }
  end
end
