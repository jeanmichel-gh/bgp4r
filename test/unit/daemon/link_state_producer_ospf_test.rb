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
require 'test/helpers/fake_ospfd'

# The BGP-LS Producer with ospfd as its source: docs/design/bgp-ls-ospf.md.
# The topology is routescope's bgp-ls-ospf lab, as o2 answers it
# (ospfv2 docs/design/ospf-topology.md):
#
#   area 0                          area 1
#   o1 .1 --10.0.12.0/30-- .2 o2 .1 --10.0.23.0/24-- .3 o3 --> 192.0.2.0/24 (E2)
#   10.255.0.1        (ABR) 10.255.0.2   o2 is DR   10.255.0.3 (ASBR)
class BGP_Daemon_LinkStateProducerOspf_Test < Test::Unit::TestCase

  class FakePeer
    attr_reader :address
    attr_accessor :session_info

    def initialize(address)
      @address = address
      @sent = []
      @lock = Mutex.new
      caps = [BGP::OPT_PARM::CAP::Mbgp.new(16_388, 71)]
      @session_info = BGP::Neighbor::Capabilities.new(BGP::Open.new(4, 65_001, 180, '10.0.0.1', *caps),
                                                      BGP::Open.new(4, 65_002, 180, '10.0.0.2', *caps))
    end

    def established? ; true ; end
    def ebgp? ; true ; end
    def local_ip ; '10.2.0.5' ; end
    def send_message(u) ; @lock.synchronize { @sent << u } ; end
    def updates ; @lock.synchronize { @sent.dup } ; end
    def clear ; @lock.synchronize { @sent.clear } ; end
  end

  class FakeSpeaker
    def initialize(peers) ; @peers = peers ; end
    def peer(a) ; @peers.find { |p| p.address == a } ; end
    def my_as ; 65_001 ; end
  end

  T = BGP::Link_state::Tlv
  P = BGP::Daemon::LinkStateProducer
  O1 = '10.255.0.1'
  O2 = '10.255.0.2'
  O3 = '10.255.0.3'
  LAN = '10.255.0.2:10.0.23.1'

  def pf(prefix, metric, type, extra = {})
    { 'prefix' => prefix, 'metric' => metric, 'route_type' => type }.merge(extra)
  end

  def router(id, neighbors, prefixes, extra = {})
    { 'id' => id, 'kind' => 'router', 'reachable' => true, 'abr' => false, 'asbr' => false,
      'neighbors' => neighbors, 'prefixes' => prefixes }.merge(extra)
  end

  # 2 nodes, 2 links, 6 prefixes in area 0; 3 nodes, 4 links, 4
  # prefixes in area 1; 1 external.
  def fixture
    {
      '0.0.0.0' => { 'area' => '0.0.0.0', 'router_id' => O2, 'run' => 3, 'nodes' => [
        router(O1, [{ 'id' => O2, 'type' => 'p2p', 'metric' => 10, 'address' => '10.0.12.1', 'remote_address' => '10.0.12.2' }],
               [pf('10.0.12.0/30', 10, 'intra'), pf('10.255.0.1/32', 0, 'intra')]),
        router(O2, [{ 'id' => O1, 'type' => 'p2p', 'metric' => 10, 'address' => '10.0.12.2', 'remote_address' => '10.0.12.1' }],
               [pf('10.0.12.0/30', 10, 'intra'), pf('10.0.23.0/24', 10, 'inter'),
                pf('10.255.0.2/32', 0, 'intra'), pf('10.255.0.3/32', 10, 'inter')], 'abr' => true)
      ] },
      '0.0.0.1' => { 'area' => '0.0.0.1', 'router_id' => O2, 'run' => 3, 'nodes' => [
        router(O2, [{ 'id' => LAN, 'type' => 'transit', 'metric' => 10 }],
               [pf('10.0.12.0/30', 10, 'inter'), pf('10.255.0.1/32', 20, 'inter')], 'abr' => true),
        router(O3, [{ 'id' => LAN, 'type' => 'transit', 'metric' => 10 }], [pf('10.255.0.3/32', 0, 'intra')], 'asbr' => true),
        { 'id' => LAN, 'kind' => 'network', 'reachable' => true, 'dr' => O2, 'address' => '10.0.23.1',
          'neighbors' => [{ 'id' => O2, 'metric' => 0 }, { 'id' => O3, 'metric' => 0 }],
          'prefixes' => [pf('10.0.23.0/24', 0, 'intra')] }
      ] },
      'as' => { 'scope' => 'as', 'router_id' => O2, 'run' => 3, 'nodes' => [
        { 'id' => O3, 'kind' => 'router', 'reachable' => true,
          'prefixes' => [pf('192.0.2.0/24', 20, 'external_2', 'forwarding' => '0.0.0.0', 'tag' => 0)] }
      ] }
    }
  end

  def setup
    @ospfd = BGP::TestHelpers::FakeOspfd.new(fixture)
    @peer = FakePeer.new('10.2.0.10')
    @speaker = FakeSpeaker.new([@peer])
  end

  def teardown
    @producer.stop if @producer
    @ospfd.stop
  end

  def producer(extra = {})
    config = { 'ospfd' => @ospfd.path, 'areas' => ['0.0.0.0', 1], 'identifier' => 1,
               'peers' => ['10.2.0.10'] }.merge(extra)
    @producer = P.new(@speaker, config, :retry => 0.05, :logger => ->(_level, _message) {})
  end

  def wait_for(timeout = 5)
    deadline = Time.now + timeout
    until yield
      flunk('timed out') if Time.now > deadline
      sleep 0.01
    end
  end

  def started(extra = {})
    producer(extra).start
    wait_for { @producer.reads == 1 }
    @producer
  end

  # Changes the fixture, sends a topology event, and waits for the read.
  def change(where = '0.0.0.0')
    reads = @producer.reads
    @peer.clear
    yield @ospfd.topology
    @ospfd.changed(where)
    wait_for { @producer.reads > reads }
  end

  def nlris(klass)
    @peer.updates.flat_map { |u| (mp = u.path_attribute.find(klass)) ? mp.nlris : [] }
  end

  def kinds(list) ; list.collect { |ls| BGP::Daemon::LinkStateTable.type(ls.nlri) }.tally ; end

  def topology_requests
    @ospfd.requests.select { |r| r['method'] == 'show.topology' }.collect { |r| r['params'] }
  end

  # --- configuration ----------------------------------------------------------

  def test_the_ospfd_defaults
    p = P.new(@speaker, 'ospfd' => '/x.sock')
    assert_equal(['/x.sock', ['0.0.0.0'], true, []], [p.path, p.areas, p.source.external, p.levels])
    assert_equal('/run/ospfv2/ospfd.sock', P.new(@speaker, 'ospfd' => nil).source.class::SOCKET)
    assert_equal(%w[0.0.0.0 0.0.0.1 10.0.0.1], P.new(@speaker, 'ospfd' => 'x', 'areas' => [0, '1', '10.0.0.1']).areas)
    assert_equal('/run/isis4r/isisd.sock', P.new(@speaker, {}).path, 'no source is isisd, as in phases 1 and 2')
  end

  def test_a_bad_ospf_block_is_refused_by_name
    { { 'isisd' => 'a', 'ospfd' => 'b' } => /isisd or ospfd, not both/,
      { 'isisd' => 'a', 'areas' => [0] } => /areas goes with ospfd/,
      { 'external' => false } => /external goes with ospfd/,
      { 'ospfd' => 'b', 'levels' => [1] } => /levels go with isisd/,
      { 'ospfd' => 'b', 'areas' => ['area0'] } => /area "area0" is not a dotted quad or a number/,
      { 'ospfd' => 'b', 'areas' => ['1.2.3.400'] } => /area "1\.2\.3\.400"/,
      { 'ospfd' => 'b', 'areas' => [] } => /areas is empty/,
      { 'ospfd' => 'b', 'external' => 'yes' } => /external is true or false/ }.each do |config, why|
      e = assert_raise(ArgumentError) { P.new(@speaker, config) }
      assert_match(why, e.message)
    end
  end

  # --- reading ospfd --------------------------------------------------------------

  def test_it_subscribes_on_one_connection_and_reads_on_another
    started
    assert_equal(2, @ospfd.connections)
    assert_equal(1, @ospfd.subscriptions)
    sub = @ospfd.requests.find { |r| r['method'] == 'events.subscribe' }
    assert_equal({ 'kinds' => ['topology'] }, sub['params'])
    assert_equal([{ 'area' => '0.0.0.0' }, { 'area' => '0.0.0.1' }, { 'scope' => 'as' }], topology_requests)
  end

  def test_the_first_read_sends_both_areas_and_the_externals
    started
    assert_equal({ 'node' => 5, 'link' => 6, 'prefix' => 11 }, kinds(nlris(BGP::Mp_reach)))
    assert_equal(22, @producer.size)
    assert_equal([3], nlris(BGP::Mp_reach).collect { |ls| ls.nlri.protocol_id }.uniq)
    assert_equal([1], nlris(BGP::Mp_reach).collect { |ls| ls.nlri.identifier }.uniq)
  end

  def test_a_metric_change_sends_one_link_nlri
    started
    change { |t| t['0.0.0.0']['nodes'][0]['neighbors'][0]['metric'] = 20 }
    assert_equal({ 'link' => 1 }, kinds(nlris(BGP::Mp_reach)))
    assert_empty(nlris(BGP::Mp_unreach))
  end

  # Section 5.9: what SPF did not reach is withdrawn.
  def test_an_unreachable_router_is_withdrawn_then_sent_again
    started
    change { |t| t['0.0.0.0']['nodes'][0]['reachable'] = false }
    assert_equal({ 'node' => 1, 'link' => 1, 'prefix' => 2 }, kinds(nlris(BGP::Mp_unreach)))
    change { |t| t['0.0.0.0']['nodes'][0]['reachable'] = true }
    assert_equal({ 'node' => 1, 'link' => 1, 'prefix' => 2 }, kinds(nlris(BGP::Mp_reach)))
  end

  def test_an_unreachable_asbr_gives_no_externals
    started
    change('as') { |t| t['as']['nodes'][0]['reachable'] = false }
    assert_equal({ 'prefix' => 1 }, kinds(nlris(BGP::Mp_unreach)))
  end

  def test_an_area_not_configured_is_not_read_nor_its_events
    started('areas' => ['0.0.0.0'])
    assert_equal([{ 'area' => '0.0.0.0' }, { 'scope' => 'as' }], topology_requests)
    @ospfd.changed('0.0.0.1')
    sleep 0.3
    assert_equal(1, @producer.reads)
    change('0.0.0.0') { |_t| nil }
    assert_equal(2, @producer.reads)
  end

  def test_external_false_reads_no_as_scope_and_ignores_its_events
    started('external' => false)
    assert_equal([{ 'area' => '0.0.0.0' }, { 'area' => '0.0.0.1' }], topology_requests)
    assert_equal(10, kinds(nlris(BGP::Mp_reach))['prefix'])
    @ospfd.changed('as')
    sleep 0.3
    assert_equal(1, @producer.reads)
  end

  def test_ospfd_closing_and_coming_back_sends_only_the_diff
    started
    @peer.clear
    @ospfd.drop
    wait_for { @ospfd.subscriptions == 2 && @producer.reads >= 2 }
    assert_empty(@peer.updates)
  end

  # --- the encoded routes, byte for byte -----------------------------------------

  def routes(node, area = '0.0.0.0', identifier = 1) ; P.ospf_routes(node, area, identifier) ; end

  def local(area, id) ; { :local_node_descriptors => [{ :ospf_area_id => area }, { :igp_router_id => id }] } ; end
  def remote(area, id) ; { :remote_node_descriptors => [{ :ospf_area_id => area }, { :igp_router_id => id }] } ; end
  def head(*tlvs) ; { :protocol_id => 3, :identifier => 1, :tlvs => tlvs } ; end

  # Section 5.2.1.4: 514, then 515 of 4 octets, in ascending order.
  # Node Flag Bits: B 0x10, E 0x20 (Table 7).
  def test_a_node_nlri_with_the_area_then_a_4_octet_router_id
    ls, attr = routes(fixture['0.0.0.0']['nodes'][1])[0]
    assert_equal('0001' '001d' '03' '0000000000000001' '01000010' '0202' '0004' '00000000' '0203' '0004' '0aff0002',
                 ls.to_shex)
    assert_equal(BGP::Link_state.new(:node => head(local('0.0.0.0', '0aff0002'))).encode, ls.encode)
    assert_match(/0400000110\z/, attr.to_shex)
    _ls, o3 = routes(fixture['0.0.0.1']['nodes'][1], '0.0.0.1')[0]
    assert_match(/0400000120\z/, o3.to_shex)
  end

  # A network node: the DR's Router-ID and its interface address, 8
  # octets. No flags.
  def test_a_network_node_is_8_octets
    ls, attr = routes(fixture['0.0.0.1']['nodes'][2], '0.0.0.1')[0]
    assert_equal(BGP::Link_state.new(:node => head(local('0.0.0.1', '0aff00020a001701'))).encode, ls.encode)
    assert_equal(:pseudonode, ls.nlri.node_type) if ls.nlri.respond_to?(:node_type)
    assert_match(/0400000100\z/, attr.to_shex)
  end

  # Section 5.2.2: 259 and 260 when both addresses are known. Section
  # 5.3.2.4: a 2-octet metric.
  def test_a_p2p_link_has_both_addresses_and_a_2_octet_metric
    _node, (ls, attr) = routes(fixture['0.0.0.0']['nodes'][0])
    hand = BGP::Link_state.new(:link => head(local('0.0.0.0', '0aff0001'), remote('0.0.0.0', '0aff0002'),
                                             { :ipv4_interface_address => '10.0.12.1' },
                                             { :ipv4_neighbor_address => '10.0.12.2' }))
    assert_equal(hand.encode, ls.encode)
    assert_match(/0103 0004 0a000c01 0104 0004 0a000c02\z/x, ls.to_shex)
    assert_equal(BGP::Link_state_attribute.new(T::Igp_metric.new(10, 2)).encode, attr.encode)
    assert_match(/0447 0002 000a\z/x, attr.to_shex)
  end

  def test_a_link_without_a_remote_address_has_no_link_descriptor
    n = fixture['0.0.0.0']['nodes'][0]
    n['neighbors'][0].delete('remote_address')
    _node, (ls, _attr) = routes(n)
    assert_equal(BGP::Link_state.new(:link => head(local('0.0.0.0', '0aff0001'), remote('0.0.0.0', '0aff0002'))).encode,
                 ls.encode)
  end

  # Router to LAN at its cost, LAN to router at 0 (RFC 2328 section 2.1).
  def test_transit_links_to_and_from_the_network_node
    _node, (to_lan, m10) = routes(fixture['0.0.0.1']['nodes'][1], '0.0.0.1')
    assert_equal(BGP::Link_state.new(:link => head(local('0.0.0.1', '0aff0003'), remote('0.0.0.1', '0aff00020a001701'))).encode,
                 to_lan.encode)
    assert_equal(10, m10.tlv(1095).metric)
    _node, (from_lan, m0), = routes(fixture['0.0.0.1']['nodes'][2], '0.0.0.1')
    assert_equal(BGP::Link_state.new(:link => head(local('0.0.0.1', '0aff00020a001701'), remote('0.0.0.1', '0aff0002'))).encode,
                 from_lan.encode)
    assert_match(/0447 0002 0000\z/x, m0.to_shex)
  end

  # Section 5.2.3.1: the route type, 264, before 265.
  def test_an_intra_area_prefix_has_its_route_type_and_metric
    _node, _link, (ls, attr) = routes(fixture['0.0.0.0']['nodes'][0])
    assert_equal(BGP::Link_state.new(:ipv4_prefix => head(local('0.0.0.0', '0aff0001'), { :ospf_route_type => 1 },
                                                          { :ip_reachability => '10.0.12.0/30' })).encode, ls.encode)
    assert_match(/0108 0001 01 0109 0005 1e 0a000c00\z/x, ls.to_shex)
    assert_equal(BGP::Link_state_attribute.new(T::Prefix_metric.new(10)).encode, attr.encode)
  end

  # An external: no Area-ID (section 5.2.1.4), External 2 (4), and 1156
  # only when the forwarding address is not 0.0.0.0.
  def test_an_external_has_no_area_and_the_forwarding_address_when_set
    o3 = fixture['as']['nodes'][0]
    (ls, attr), = routes(o3, nil)
    assert_equal(BGP::Link_state.new(:ipv4_prefix => head({ :local_node_descriptors => [{ :igp_router_id => '0aff0003' }] },
                                                          { :ospf_route_type => 4 },
                                                          { :ip_reachability => '192.0.2.0/24' })).encode, ls.encode)
    assert_equal(BGP::Link_state_attribute.new(T::Prefix_metric.new(20)).encode, attr.encode)
    o3['prefixes'][0]['forwarding'] = '10.0.23.3'
    (_ls, fwd), = routes(o3, nil)
    assert_equal(BGP::Link_state_attribute.new(T::Prefix_metric.new(20), T::Ospf_forwarding_address.new('10.0.23.3')).encode,
                 fwd.encode)
    assert_equal(1, routes(o3, nil).size, 'the AS scope gives no Node NLRI')
  end

  def test_route_types_and_router_ids
    assert_equal({ 'intra' => 1, 'inter' => 2, 'external_1' => 3, 'external_2' => 4, 'nssa_1' => 5, 'nssa_2' => 6 },
                 P::ROUTE_TYPES)
    assert_equal('0aff0002', P.ospf_router_id(O2))
    assert_equal('0aff00020a001701', P.ospf_router_id(LAN))
  end
end
