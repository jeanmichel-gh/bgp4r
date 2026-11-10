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
                   'since' => '2026-11-09T10:00:00.000Z' }, rows[1])
    assert_equal({ 'peer' => '10.2.0.1', 'type' => 'node', 'protocol_id' => 1, 'identifier' => 0,
                   'local' => '0000.0001.0101.00', 'remote' => nil, 'prefix' => nil, 'name' => 'r1c1',
                   'flags' => %w[overload attached], 'areas' => ['49.0001'], 'metric' => nil,
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
end
