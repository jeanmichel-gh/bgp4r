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
require 'bgp/daemon/link_state_table'

# The collector's table of docs/design/bgp-ls-producer.md: BGP-LS routes
# per peer, keyed by NLRI octets, outside the RIB.
class BGP_Daemon_LinkStateTable_Test < Test::Unit::TestCase

  T = BGP::Link_state::Tlv
  LST = BGP::Daemon::LinkStateTable

  def setup
    @t = LST.new
  end

  def local(id = '000000010101') ; { :local_node_descriptors => [{ :igp_router_id => id }] } ; end

  def node(id = '000000010101')
    BGP::Link_state.new(:node => { :protocol_id => 1, :identifier => 0, :tlvs => [local(id)] })
  end

  def link(a = '000000010101', b = '000000010102')
    BGP::Link_state.new(:link => { :protocol_id => 1, :identifier => 0,
                                   :tlvs => [local(a), { :remote_node_descriptors => [{ :igp_router_id => b }] }] })
  end

  def prefix(p = '10.200.0.1/32')
    BGP::Link_state.new(:ipv4_prefix => { :protocol_id => 1, :identifier => 0,
                                          :tlvs => [local, { :ip_reachability => p }] })
  end

  def attr(*tlvs) ; BGP::Link_state_attribute.new(*tlvs) ; end

  # --- add, replace, withdraw, session down ------------------------------

  def test_add
    @t.announce('10.2.0.1', node, attr(T::Node_name.new('r1')))
    assert_equal(1, @t.size)
    assert_equal(1, @t.size('10.2.0.1'))
    assert_equal('r1', @t['10.2.0.1', node].attribute.tlv(1026).name)
  end

  def test_replace_keeps_one_route_per_nlri
    @t.announce('10.2.0.1', link, attr(T::Igp_metric.new(10)))
    @t.announce('10.2.0.1', link, attr(T::Igp_metric.new(20)))
    assert_equal(1, @t.size)
    assert_equal(20, @t['10.2.0.1', link].attribute.tlv(1095).metric)
  end

  def test_the_same_nlri_from_two_peers_is_two_routes
    @t.announce('10.2.0.1', node, nil)
    @t.announce('10.2.0.9', node, nil)
    assert_equal(2, @t.size)
  end

  def test_withdraw
    @t.announce('10.2.0.1', node, nil)
    @t.announce('10.2.0.1', prefix, nil)
    @t.withdraw('10.2.0.1', prefix)
    assert_equal(1, @t.size)
    assert_nil(@t['10.2.0.1', prefix])
    @t.withdraw('10.2.0.1', prefix)
    @t.withdraw('10.9.9.9', prefix)
    assert_equal(1, @t.size, 'withdrawing what is not there changes nothing')
  end

  def test_session_down_removes_every_route_of_that_peer
    @t.announce('10.2.0.1', node, nil)
    @t.announce('10.2.0.1', link, nil)
    @t.announce('10.2.0.9', node, nil)
    @t.peer_down('10.2.0.1')
    assert_equal(1, @t.size)
    assert_equal(0, @t.size('10.2.0.1'))
  end

  def test_apply_takes_withdrawals_then_announcements
    @t.apply('10.2.0.1', [[:withdraw, node], [:announce, node, nil], [:announce, link, nil]])
    assert_equal(2, @t.size)
  end

  # --- the rows ---------------------------------------------------------

  def test_the_row_shape_of_each_type
    at = Time.utc(2026, 11, 9, 10)
    @t.announce('10.2.0.1', node, attr(T::Node_flag_bits.new(:overload, :attached), T::Node_name.new('r1c1'),
                                       T::Isis_area_id.new(['490001'].pack('H*'))), at)
    @t.announce('10.2.0.1', link, attr(T::Igp_metric.new(10)), at)
    @t.announce('10.2.0.1', prefix, attr(T::Prefix_metric.new(5)), at)
    rows = @t.rows
    assert_equal(%w[node link prefix], rows.collect { |r| r['type'] })
    assert_equal({ 'peer' => '10.2.0.1', 'type' => 'link', 'protocol_id' => 1, 'identifier' => 0,
                   'local' => '0000.0001.0101.00', 'remote' => '0000.0001.0102.00',
                   'prefix' => nil, 'name' => nil, 'flags' => [], 'areas' => [], 'metric' => 10,
                   'area' => nil, 'route_type' => nil, 'forwarding' => nil,
                   'since' => '2026-11-09T10:00:00.000Z' }, rows[1])
    assert_equal({ 'peer' => '10.2.0.1', 'type' => 'node', 'protocol_id' => 1, 'identifier' => 0,
                   'local' => '0000.0001.0101.00', 'remote' => nil, 'prefix' => nil, 'name' => 'r1c1',
                   'flags' => %w[overload attached], 'areas' => ['49.0001'], 'metric' => nil,
                   'area' => nil, 'route_type' => nil, 'forwarding' => nil,
                   'since' => '2026-11-09T10:00:00.000Z' }, rows[0])
    assert_equal('10.200.0.1/32', rows[2]['prefix'])
    assert_equal(5, rows[2]['metric'])
  end

  def test_a_route_with_no_attribute_has_empty_lists_and_no_metric
    @t.announce('10.2.0.1', link, nil)
    r = @t.rows.first
    assert_equal([[], [], nil, nil], [r['flags'], r['areas'], r['metric'], r['name']])
  end

  def test_node_ids_print_as_isisd_prints_them
    assert_equal('0000.0001.0101.01',
                 LST.node_id(link('000000010101', '00000001010101').nlri.remote_node_descriptors))
    assert_equal('10.0.0.1', LST.node_id(node('0a000001').nlri.local_node_descriptors))
  end

  def test_areas_print_as_isisd_prints_them
    assert_equal('49.0001', LST.area(['490001'].pack('H*')))
    assert_equal('49.0001.0002', LST.area(['4900010002'].pack('H*')))
    assert_equal(['490001'].pack('H*'), LST.area_octets('49.0001'))
  end

  # --- the session ------------------------------------------------------

  def session_info(bgp_ls_ours, bgp_ls_theirs)
    cap = ->(on) { on ? BGP::OPT_PARM::CAP::Mbgp.new(16_388, 71) : BGP::OPT_PARM::CAP::Mbgp.new(1, 1) }
    BGP::Neighbor::Capabilities.new(BGP::Open.new(4, 1, 180, '1.1.1.1', cap.call(bgp_ls_ours)),
                                    BGP::Open.new(4, 2, 180, '2.2.2.2', cap.call(bgp_ls_theirs)))
  end

  def test_negotiated_needs_both_opens
    assert(LST.negotiated?(session_info(true, true)))
    assert(!LST.negotiated?(session_info(true, false)))
    assert(!LST.negotiated?(session_info(false, true)))
    assert(!LST.negotiated?(nil))
  end

  # A Neighbor stand-in with the four methods `attach` uses.
  class FakeNeighbor
    attr_accessor :session_info
    attr_reader :observers
    def initialize(si) ; @session_info, @observers, @listeners = si, [], [] ; end
    def remote_addr ; '10.2.0.1' ; end
    def add_observer(o) ; @observers << o ; end
    def delete_observer(o) ; @observers.delete(o) ; end
    def on_state_change(&b) ; @listeners << b ; end
    def state(now, was) ; @listeners.each { |b| b.call(now, was) } ; end
    def receive(m) ; @observers.each { |o| o.update(m) } ; end
  end

  def update_with(nlris, attribute = nil)
    attrs = [BGP::Origin.new(0), BGP::As_path.new(65_002),
             BGP::Mp_reach.new(:afi => 16_388, :safi => 71, :nexthop => ['10.2.0.1'], :nlris => nlris)]
    attrs << attribute if attribute
    BGP::Update.new(BGP::Path_attribute.new(*attrs))
  end

  def test_an_attached_session_feeds_the_table_and_its_end_empties_it
    n = FakeNeighbor.new(session_info(true, true))
    feed = @t.attach(n)
    n.receive(update_with([node, link], attr(T::Igp_metric.new(10))))
    assert_equal(2, @t.size('10.2.0.1'))
    n.receive(BGP::Update.new(BGP::Path_attribute.new(
      BGP::Mp_unreach.new(:afi => 16_388, :safi => 71, :nlris => [link]))))
    assert_equal(1, @t.size('10.2.0.1'))
    n.state(:Established, :OpenConfirm)
    assert_equal(1, @t.size)
    n.state(:Idle, :Established)
    assert_equal(0, @t.size)
    @t.detach(n, feed)
    assert_equal([], n.observers)
  end

  def test_a_session_that_did_not_negotiate_bgp_ls_is_ignored
    n = FakeNeighbor.new(session_info(false, true))
    @t.attach(n)
    n.receive(update_with([node]))
    assert_equal(0, @t.size)
  end

  # --- OSPF rows (docs/design/bgp-ls-ospf.md) -------------------------------

  def ospf_head(*tlvs) ; { :protocol_id => 3, :identifier => 1, :tlvs => tlvs } ; end
  def ospf_local(area, id) ; { :local_node_descriptors => [{ :ospf_area_id => area }, { :igp_router_id => id }].compact } ; end

  O2 = '0aff0002'         # 10.255.0.2
  O3 = '0aff0003'         # 10.255.0.3
  LAN = '0aff00020a001701' # 10.255.0.2:10.0.23.1

  def test_ospf_rows_carry_the_area_the_route_type_and_the_forwarding_address
    at = Time.utc(2026, 11, 10, 10)
    lan_link = BGP::Link_state.new(:link => ospf_head(ospf_local('0.0.0.1', O3),
                                                      { :remote_node_descriptors => [{ :ospf_area_id => '0.0.0.1' }, { :igp_router_id => LAN }] }))
    ext = BGP::Link_state.new(:ipv4_prefix => ospf_head({ :local_node_descriptors => [{ :igp_router_id => O3 }] },
                                                        { :ospf_route_type => 4 }, { :ip_reachability => '192.0.2.0/24' }))
    inter = BGP::Link_state.new(:ipv4_prefix => ospf_head(ospf_local('0.0.0.0', O2), { :ospf_route_type => 2 },
                                                          { :ip_reachability => '10.0.23.0/24' }))
    @t.announce('10.2.0.5', lan_link, attr(T::Igp_metric.new(10, 2)), at)
    @t.announce('10.2.0.5', ext, attr(T::Prefix_metric.new(20), T::Ospf_forwarding_address.new('10.0.23.3')), at)
    @t.announce('10.2.0.5', inter, attr(T::Prefix_metric.new(10)), at)
    link, *prefixes = @t.rows
    assert_equal(['0.0.0.1', '10.255.0.3', '10.255.0.2:10.0.23.1', 10, nil],
                 link.values_at('area', 'local', 'remote', 'metric', 'route_type'))
    assert_equal([[nil, '192.0.2.0/24', 'external_2', '10.0.23.3'], ['0.0.0.0', '10.0.23.0/24', 'inter', nil]],
                 prefixes.collect { |r| r.values_at('area', 'prefix', 'route_type', 'forwarding') })
  end

  # An ABR's Node NLRI comes once per area; the rows sort by area.
  def test_an_abr_is_one_row_per_area
    [%w[0.0.0.1 abr], %w[0.0.0.0 abr]].each do |area, _|
      @t.announce('10.2.0.5', BGP::Link_state.new(:node => ospf_head(ospf_local(area, O2))),
                  attr(T::Node_flag_bits.new(:abr)))
    end
    assert_equal([['0.0.0.0', '10.255.0.2', ['abr']], ['0.0.0.1', '10.255.0.2', ['abr']]],
                 @t.rows.collect { |r| r.values_at('area', 'local', 'flags') })
  end

  def test_a_route_type_section_5_2_3_1_does_not_name_stays_a_number
    n = BGP::Link_state.new(:ipv4_prefix => ospf_head(ospf_local('0.0.0.0', O2), { :ospf_route_type => 9 },
                                                      { :ip_reachability => '10.9.0.0/16' }))
    assert_equal(9, LST.route_type(n.nlri))
  end

  # --- SR, RFC 9085 and RFC 9086 -----------------------------------------

  # The keys are isisd's (isis docs/isisd.md, show.topology), so a
  # collector's row and isisd's node read the same. The flag letters are
  # RFC 8667's: I is 0x80 (section 3.1), V and L of an Adj-SID 0x20 and
  # 0x10 (2.2.1), N of a Prefix-SID 0x40 (2.1).
  def test_the_sr_keys_of_each_type
    @t.announce('10.2.0.1', node, attr(T::Sr_capabilities.new(0x80, [[8000, 17000]]),
                                       T::Sr_algorithm.new(0),
                                       T::Sr_local_block.new(0, [[1000, 15000]])))
    @t.announce('10.2.0.1', link, attr(T::Igp_metric.new(10), T::Adjacency_sid.new(0x30, 0, 15000),
                                       T::Lan_adjacency_sid.new(0x30, 0, '0000.0001.0103', 15001)))
    @t.announce('10.2.0.1', prefix, attr(T::Prefix_metric.new(0), T::Prefix_sid.new(0x40, 0, 2, 4)))
    rows = @t.rows
    assert_equal({ 'srgb' => [{ 'start' => 17000, 'size' => 8000 }], 'flags' => ['I'],
                   'srlb' => [{ 'start' => 15000, 'size' => 1000 }], 'algorithms' => [0] },
                 rows[0]['sr'])
    assert_equal([{ 'flags' => %w[V L], 'label' => 15000 }], rows[1]['adj_sids'])
    assert_equal([{ 'neighbor' => '0000.0001.0103', 'flags' => %w[V L], 'label' => 15001 }],
                 rows[1]['lan_adj_sids'])
    assert_equal({ 'flags' => ['N'], 'index' => 2, 'algorithm' => 0 }, rows[2]['prefix_sid'])
  end

  # A row without SR TLVs has no SR key, as isisd's node has none: the
  # row shape of a topology without SR is what it was.
  def test_a_row_without_sr_has_no_sr_key
    @t.announce('10.2.0.1', node, attr(T::Node_name.new('r1')))
    @t.announce('10.2.0.1', link, attr(T::Igp_metric.new(10)))
    @t.announce('10.2.0.1', prefix, nil)
    @t.rows.each do |r|
      assert_equal([], r.keys & %w[sr adj_sids lan_adj_sids prefix_sid peer_sids], r['type'])
    end
  end

  # isisd's rules: `weight` when not 0, `reserved` for the flag bits no
  # letter names, `label_high` for the 4 bits above a label's 20. Flags
  # none set: no `flags` key. Every value from octets, so nothing is lost.
  def test_a_sid_row_keeps_weight_unnamed_bits_and_label_high
    t = T::Adjacency_sid.new(['3305' + '0000' + 'f03a98'].pack('H*').is_packed)
    @t.announce('10.2.0.1', link, attr(t, T::Adjacency_sid.new(0, 0, 7, 4)))
    assert_equal([{ 'flags' => %w[V L], 'reserved' => 0x03, 'weight' => 5,
                    'label' => 15000, 'label_high' => 0xf },
                  { 'index' => 7 }], @t.rows.first['adj_sids'])
  end

  # RFC 9085 says the Protocol-ID decides how to read the flags, so off
  # IS-IS they stay the octet.
  def test_off_is_is_the_flags_are_a_number
    n = BGP::Link_state.new(:ipv4_prefix => ospf_head(ospf_local('0.0.0.0', O2), { :ip_reachability => '10.9.0.0/16' }))
    @t.announce('10.2.0.1', n, attr(T::Prefix_sid.new(0x40, 0, 2, 4)))
    assert_equal({ 'flags' => 0x40, 'index' => 2, 'algorithm' => 0 }, @t.rows.first['prefix_sid'])
  end

  # RFC 9086 section 5 on a Protocol-ID 7 link: `peer_sids`, with the
  # type by GoBGP's client word and the flags `|V|L|B|P|` (Figure 3).
  def test_a_bgp_link_row_has_its_peer_sids
    n = BGP::Link_state.new(:link => { :protocol_id => 7, :identifier => 0,
                                       :tlvs => [{ :local_node_descriptors => [{ :autonomous_system => 65002 },
                                                                               { :bgp_router_id => '10.0.0.2' }] },
                                                 { :remote_node_descriptors => [{ :autonomous_system => 65001 },
                                                                                { :bgp_router_id => '10.0.0.1' }] }] })
    @t.announce('10.2.0.1', n, attr(T::Peer_node_sid.new(0xc0, 1, 24000), T::Peer_adj_sid.new(0x30, 0, 24001),
                                    T::Peer_set_sid.new(0x80, 3, 9, 4)))
    assert_equal([{ 'type' => 'node', 'flags' => %w[V L], 'weight' => 1, 'label' => 24000 },
                  { 'type' => 'adj', 'flags' => %w[B P], 'label' => 24001 },
                  { 'type' => 'set', 'flags' => %w[V], 'weight' => 3, 'index' => 9 }],
                 @t.rows.first['peer_sids'])
  end

  # The letters and the octet, both ways, for each RFC 8667 figure.
  def test_flag_letters_sit_where_the_figures_put_them
    { LST::SR_CAPABILITY_FLAGS => { 'I' => 0x80, 'V' => 0x40 },
      LST::ADJ_SID_FLAGS => { 'F' => 0x80, 'B' => 0x40, 'V' => 0x20, 'L' => 0x10, 'S' => 0x08, 'P' => 0x04 },
      LST::PREFIX_SID_FLAGS => { 'R' => 0x80, 'N' => 0x40, 'P' => 0x20, 'E' => 0x10, 'V' => 0x08, 'L' => 0x04 },
      LST::PEER_SID_FLAGS => { 'V' => 0x80, 'L' => 0x40, 'B' => 0x20, 'P' => 0x10 } }.each do |names, bits|
      bits.each do |letter, bit|
        assert_equal(bit, LST.flag_octet([letter], names), letter)
        assert_equal([letter], LST.flag_letters(bit, names), letter)
      end
    end
    assert_raise(ArgumentError) { LST.flag_octet(['X'], LST::ADJ_SID_FLAGS) }
  end

  # A BGP node, RFC 9086 section 4.2, is named by "the <ASN, BGP
  # Router-ID> tuple", since it has no IGP Router-ID. GoBGP sends 512,
  # 513, 516 and 517; the BGP-LS ID and the confederation member do not
  # name it.
  def test_a_bgp_node_is_named_by_its_as_and_bgp_router_id
    n = BGP::Link_state.new(:link => { :protocol_id => 7, :identifier => 0,
                                       :tlvs => [{ :local_node_descriptors => [{ :autonomous_system => 65002 },
                                                                               { :bgp_ls_identifier => 0 },
                                                                               { :bgp_router_id => '10.0.0.2' },
                                                                               { :bgp_confederation_member => 65102 }] },
                                                 { :remote_node_descriptors => [{ :bgp_router_id => '10.0.0.1' }] }] })
    row = LST.row(n, nil, '10.2.0.1', Time.now)
    assert_equal(['65002:10.0.0.2', '10.0.0.1'], [row['local'], row['remote']])
    assert_nil(LST.node_id(BGP::Link_state::Tlv::Local_node_descriptors.new(
                             BGP::Link_state::Tlv::Autonomous_system.new(65002))),
               'an AS alone names nothing')
  end

  # RFC 7313 section 4 for BGP-LS: every route from the peer.
  def test_stale_routes
    @t.announce('10.2.0.1', node, attr)
    @t.announce('10.2.0.1', link, attr)
    assert_equal(2, @t.mark_stale('10.2.0.1'))
    assert_equal(%w[refresh refresh], @t.rows.collect { |r| r['stale'] })
    @t.announce('10.2.0.1', node, attr)
    assert_equal(1, @t.stale_size('10.2.0.1'))
    assert_equal(1, @t.purge_stale('10.2.0.1'))
    assert_equal([['node', nil]], @t.rows.collect { |r| [r['type'], r['stale']] })
  end

  def test_peer_down_keeps_the_family
    @t.announce('10.2.0.1', node, attr)
    @t.announce('10.2.0.1', link, attr)
    @t.mark_stale('10.2.0.1')
    @t.announce('10.2.0.1', node, attr)
    @t.peer_down('10.2.0.1', [[16388, 71]])
    assert_equal([%w[node restart], %w[link restart]], @t.rows.collect { |r| [r['type'], r['stale']] }.sort_by { |t, _| t == 'node' ? 0 : 1 })
    @t.peer_down('10.2.0.1', [[1, 1]])
    assert_equal(0, @t.size)
  end
  # RFC 9494 section 4.2 for BGP-LS: nothing here decides, so the LLGR
  # period marks and removes; the communities come from the UPDATE.
  def test_the_llgr_period
    with = ->(nlris, *comm) do
      BGP::Update.new(BGP::Path_attribute.new(BGP::Origin.new(0), BGP::As_path.new(65_002),
                                              BGP::Mp_reach.new(:afi => 16_388, :safi => 71, :nexthop => ['10.2.0.1'], :nlris => nlris),
                                              *comm))
    end
    @t.apply('10.2.0.1', BGP::Rib::PeerAdapter.link_state_operations(with.([node])))
    @t.apply('10.2.0.1', BGP::Rib::PeerAdapter.link_state_operations(with.([link], BGP::Communities.new(:no_llgr))))
    @t.apply('10.2.0.2', BGP::Rib::PeerAdapter.link_state_operations(with.([prefix], BGP::Communities.new(:llgr_stale))))
    assert_equal({ '10.2.0.1' => [nil, nil], '10.2.0.2' => [true] },
                 @t.rows.group_by { |r| r['peer'] }.transform_values { |rs| rs.collect { |r| r['llgr_stale'] } }, 'received with LLGR_STALE')
    @t.peer_down('10.2.0.1', [BGP::Rib::PeerAdapter::LINK_STATE])
    assert_equal([1, 1], @t.llgr_stale('10.2.0.1'))
    rows = @t.rows.select { |r| r['peer'] == '10.2.0.1' }
    assert_equal([['long_lived', true]], rows.collect { |r| r.values_at('stale', 'llgr_stale') })
    assert_equal([nil, true], @t.rows.find { |r| r['peer'] == '10.2.0.2' }.values_at('stale', 'llgr_stale'), 'received with it')
    @t.peer_down('10.2.0.1', [BGP::Rib::PeerAdapter::LINK_STATE])
    assert_equal(['long_lived'], @t.rows.select { |r| r['peer'] == '10.2.0.1' }.collect { |r| r['stale'] })
    assert_equal([0, 0], @t.llgr_stale('10.2.0.9'))
  end

end
