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
require 'bgp/gen'

# BGP-LS topologies, AFI 16388 SAFI 71 and 72 (RFC 9552), from a spec.
#
#   ruby -I. test/unit/gen/link_state_routes_test.rb
#
# RFC 9552 carries no worked example and no hex, so the octets below
# are this reader's arithmetic from figures 7 to 9 and section 5.2.1.4,
# with the field breakdown beside each, checked against what the
# library encodes. Which nodes a ring or a grid joins is stated by hand,
# since `expected` comes from the same code as the routes.
class TestBgpGenLinkStateRoutes < Test::Unit::TestCase

  INFO = BGP::Update::Info.new(true, :strict)

  def gen(spec = {}, sender = nil)
    BGP::Gen.new({ 'family' => 'bgp_ls', 'start' => '10.0.0.1', 'count' => 3,
                   'attributes' => { 'next_hop' => '192.0.2.1' } }.merge(spec), sender)
  end

  def parse(u, info = INFO)
    BGP::Update.new(u.encode(BGP::Update::Info.new(true)).is_packed, info)
  end

  def mp(u, key = :mp_reach) ; parse(u).path_attribute[key] ; end

  def all(g, key = :mp_reach, from = :updates)
    g.send(from).flat_map { |u| mp(u, key).nlris }
  end

  # [local, remote] router IDs of every Link NLRI, in the order sent.
  def links(g)
    all(g).select { |n| n.type == 2 }.collect do |n|
      %i[local_node_descriptors remote_node_descriptors].collect do |k|
        d = n.nlri.tlvs.find { |t| t.class.hash_key == k }
        IPAddr.new_ntoh([d.sub_tlvs.last.to_hash[:igp_router_id]].pack('H*')).to_s
      end
    end
  end

  def test_a_ring_of_three
    g = gen
    assert_equal(3 + 6, g.total)
    assert_equal([[16388, 71]], g.updates.collect { |u| [mp(u).afi, mp(u).safi] }.uniq)
    assert_equal([1, 1, 1, 2, 2, 2, 2, 2, 2], all(g).collect(&:type))
    assert_equal([%w[10.0.0.1 10.0.0.2], %w[10.0.0.2 10.0.0.1],
                  %w[10.0.0.2 10.0.0.3], %w[10.0.0.3 10.0.0.2],
                  %w[10.0.0.3 10.0.0.1], %w[10.0.0.1 10.0.0.3]], links(g))
  end

  # A ring of two is one link, not the same link twice, and one node is
  # a node alone.
  def test_small_rings
    assert_equal([%w[10.0.0.1 10.0.0.2], %w[10.0.0.2 10.0.0.1]], links(gen('count' => 2)))
    assert_equal([1], all(gen('count' => 1)).collect(&:type))
  end

  #   1 - 2 - 3
  #   |   |   |
  #   4 - 5
  def test_a_grid
    g = gen('topology' => 'grid', 'columns' => 3, 'count' => 5)
    pairs = links(g).each_slice(2).collect(&:first)
    assert_equal([%w[10.0.0.1 10.0.0.2], %w[10.0.0.1 10.0.0.4], %w[10.0.0.2 10.0.0.3],
                  %w[10.0.0.2 10.0.0.5], %w[10.0.0.4 10.0.0.5]], pairs)
    assert_equal(5 + 2 * 5, g.total)
  end

  # Figure 7, the Node NLRI: Type 1, its Total NLRI Length, Protocol-ID
  # 3 (OSPFv2), the 8-octet Identifier, then TLV 256 holding sub-TLV
  # 515, the IGP Router-ID, 4 octets for OSPF (section 5.2.1.4). 21
  # octets: 1 + 8 of head, 4 of TLV header, 4 + 4 of sub-TLV.
  def test_the_octets_of_a_node
    nlri = '0001' + '0015' + '03' + '00' * 8 + '0100' + '0008' + '0203' + '0004' + '0a000001'
    assert_match(nlri, gen('count' => 1).updates.first.to_shex)
  end

  # IS-IS takes a 6-octet system ID, here two zero octets then the
  # router ID, and an AS goes in front as sub-TLV 512.
  def test_isis_and_an_autonomous_system
    u = gen('count' => 1, 'protocol_id' => 2, 'identifier' => 9, 'autonomous_system' => 65000).updates.first
    nlri = '0001' + '001f' + '02' + '0000000000000009' + '0100' + '0012' +
           '0200' + '0004' + '0000fde8' + '0203' + '0006' + '00000a000001'
    assert_match(nlri, u.to_shex)
    assert_equal(:non_pseudonode, mp(u).nlris.first.nlri.node_type)
  end

  # Figure 8: a link carries its number + 1 as both identifiers of TLV
  # 258 (RFC 5307 section 1.1), so two links between one pair stay apart.
  def test_the_link_identifiers
    g = gen
    ids = all(g).select { |n| n.type == 2 }.collect { |n| n.nlri.tlv(258).to_hash[:link_local_remote_identifiers] }
    assert_equal([1, 1, 2, 2, 3, 3], ids.collect { |h| h[:local] })
    assert_equal(ids.collect { |h| h[:local] }, ids.collect { |h| h[:remote] })
    assert_match('0102' + '0008' + '00000001' + '00000001', g.updates.first.to_shex)
  end

  # Figure 9 and section 5.2.3.2: TLV 265 holds a length in bits and the
  # prefix packed down.
  def test_prefixes_per_node
    g = gen('prefixes' => 2, 'prefix_start' => '10.10.0.0/24')
    assert_equal(3 + 6 + 6, g.total)
    rows = g.expected.select { |r| r['nlri'] == 'ipv4_prefix' }
    assert_equal(%w[10.0.0.1 10.0.0.1 10.0.0.2 10.0.0.2 10.0.0.3 10.0.0.3], rows.collect { |r| r['node'] })
    assert_equal('10.10.5.0/24', rows.last['prefix'])
    pre = all(g).select { |n| n.type == 3 }
    assert_equal(6, pre.size)
    assert_equal('10.10.1.0/24', pre[1].nlri.prefix)
    assert_match('0109' + '0004' + '18' + '0a0a00', g.updates.to_a.last.to_shex)
    v6 = gen('count' => 1, 'prefixes' => 1, 'prefix_start' => '2001:db8::/32')
    assert_equal([1, 4], all(v6).collect(&:type))
  end

  # The BGP-LS Attribute: link values on the link number, so both halves
  # of a link agree and the next link steps.
  def test_link_attributes_run_on_the_link_number
    g = gen('igp_metric' => { 'step' => { 'start' => 10, 'by' => 10 } }, 'admin_group' => 5,
            'max_bandwidth' => 125000000, 'srlg' => { 'cycle' => [7, 8] })
    attrs = g.updates.collect { |u| parse(u).path_attribute.find(BGP::Link_state_attribute) }.compact
    assert_equal(3, attrs.size, 'one message per link, both halves in it')
    assert_equal([10, 20, 30], attrs.collect { |a| a.tlv(1095).to_hash[:igp_metric][:metric] })
    assert_equal([[7], [8], [7]], attrs.collect { |a| a.tlv(1096).to_hash[:srlg] })
    assert_equal([1088, 1089, 1095, 1096], attrs.first.tlvs.collect(&:type))
    assert_equal(125000000.0, attrs.first.tlv(1089).to_hash[:maximum_link_bandwidth])
    l = g.expected.select { |r| r['nlri'] == 'link' }
    assert_equal([10, 10, 20, 20, 30, 30], l.collect { |r| r['igp_metric'] })
    assert_nil(g.expected.first['igp_metric'], 'a node carries no link attribute')
  end

  # A node name is one per node, so each Node NLRI is a message of its
  # own; a prefix metric runs on the prefix number.
  def test_node_names_and_prefix_metrics
    g = gen('node_name' => 'r', 'prefixes' => 1, 'prefix_start' => '10.10.0.0/24',
            'prefix_metric' => { 'cycle' => [1, 2] })
    names = g.updates.collect { |u| parse(u).path_attribute.find(BGP::Link_state_attribute) }
                     .compact.collect { |a| a.tlv(1026) }.compact.collect(&:name)
    assert_equal(%w[r1 r2 r3], names)
    assert_match('0402' + '0002' + '7231', g.updates.first.to_shex)
    assert_equal([1, 2, 1], g.expected.select { |r| r['prefix'] }.collect { |r| r['prefix_metric'] })
  end

  # SAFI 72: the topology once per VRF, the VRF's RD in front of each
  # NLRI (section 5.2), and its route target.
  def test_the_vpn_safi
    g = BGP::Gen.new('family' => 'bgp_ls_vpn', 'start' => '10.0.0.1', 'count' => 2, 'rd' => '65000:1',
                     'vrfs' => 2, 'route_target' => '65000:10', 'attributes' => { 'next_hop' => '192.0.2.1' })
    assert_equal(8, g.total)
    n = g.updates.flat_map { |u| mp(u).nlris }
    assert_equal(%w[65000:1] * 4 + %w[65000:2] * 4, n.collect { |x| x.rd.to_s(false).sub('RD=', '') })
    assert_equal([[16388, 72]], g.updates.collect { |u| [mp(u).afi, mp(u).safi] }.uniq)
    assert_equal(%w[route_target:65000:10 route_target:65000:11],
                 g.expected.collect { |r| r['extended_communities'] }.flatten.uniq)
    # Section 5.5: one zero RD in front of the next hop, 12 octets.
    assert_match('4004480c' + '00' * 8 + 'c0000201', g.updates.first.to_shex)
  end

  # Section 5.5: the next hop is read by its length, so the session's
  # IPv6 address is 16 octets.
  def test_the_next_hop_is_the_sessions
    s = BGP::Gen::Sender.read('as' => 65001, 'ebgp' => true, 'next_hop' => '2001:db8::9')
    u = gen({ 'attributes' => {} }, s).updates.first
    assert_match('40044710' + '20010db8' + '00' * 11 + '09', u.to_shex)
  end

  def test_withdrawals_are_the_same_nlris
    g = gen('count' => 40, 'prefixes' => 3, 'prefix_start' => '10.10.0.0/24', 'igp_metric' => 10)
    sent = all(g).collect(&:to_shex)
    gone = all(g, :mp_unreach, :withdrawals).collect(&:to_shex)
    assert_equal(40 + 80 + 120, sent.size)
    assert_operator(g.withdrawals.count, :>, 1)
    assert_equal(sent, gone)
  end

  def test_expected_by_hand
    assert_equal({ 'nlri' => 'link', 'node' => '10.0.0.3', 'remote' => '10.0.0.1', 'link' => 3,
                   'protocol_id' => 3, 'identifier' => 0,
                   'origin' => 0, 'as_path' => [], 'next_hop' => '192.0.2.1' }, gen.expected.to_a[7])
  end

  # **validation.rb walks a BGP-LS NLRI without knowing add-path was
  # negotiated**, the gap CLAUDE.md records for flow spec and EVPN: the
  # Path Identifier is read as a Type and a Total NLRI Length. The NLRIs
  # themselves decode, since `Link_state` is told. Pinned so a fix
  # fails here and says to strike the entry.
  class AddPath < BGP::Update::Info
    def initialize ; super(true, :lenient) ; end
    def path_id?(*) ; true ; end
  end

  def test_the_receive_checks_do_not_know_add_path_yet
    u = gen('path_id' => { 'step' => { 'start' => 1, 'by' => 1 } }).updates.first
    pa = BGP::Update.new(u.encode(BGP::Update::Info.new(true)).is_packed, AddPath.new).path_attribute
    assert_equal((1..9).to_a, pa[:mp_reach].nlris.collect(&:path_id))
    assert_match(/runs past the attribute/, pa.errors.first.reason)
  end

  def test_refusals
    {
      { 'start' => '10.0.0.0/24' } => /an IPv4 address, not "10.0.0.0\/24"/,
      { 'start' => '2001:db8::1' } => /an IPv4 address/,
      { 'start' => '255.255.255.255', 'count' => 2 } => /run past 255.255.255.255/,
      { 'topology' => 'mesh' } => /topology is ring or grid/,
      { 'topology' => 'grid' } => /a grid topology needs columns/,
      { 'columns' => 2 } => /columns is for a grid/,
      { 'prefixes' => 2 } => /need a prefix_start/,
      { 'prefix_start' => '10.0.0.0/8' } => /prefixes is 0/,
      { 'prefixes' => 1, 'prefix_start' => '255.255.255.255/32', 'count' => 2 } => /run past the end/,
      { 'protocol_id' => 256 } => /protocol_id 256 does not fit/,
      { 'identifier' => 2**64 } => /identifier .* does not fit/,
      { 'autonomous_system' => 2**32 } => /autonomous_system .* does not fit/,
      { 'igp_metric' => 0x1000000 } => /igp_metric: 16777216 does not fit/,
      { 'afi' => 1 } => /afi 1 disagrees/,
    }.each do |extra, why|
      e = assert_raise(BGP::Gen::SpecError, extra.inspect) { gen(extra) }
      assert_match(why, e.message)
    end
    e = assert_raise(BGP::Gen::SpecError) { BGP::Gen.new('family' => 'bgp_ls_vpn', 'start' => '10.0.0.1', 'count' => 1) }
    assert_match(/needs an rd/, e.message)
    e = assert_raise(BGP::Gen::SpecError) { gen('rd' => '65000:1') }
    assert_match(/'rd' is for .*bgp_ls_vpn and not for 'bgp_ls'/, e.message)
    e = assert_raise(BGP::Gen::SpecError) { BGP::Gen.new('start' => '10.0.0.0/24', 'count' => 1, 'node_name' => 'r') }
    assert_match(/'node_name' is for bgp_ls, bgp_ls_vpn and not for 'unicast'/, e.message)
  end

  # Building never validates: Protocol-ID 0 is Reserved (Table 2), an
  # IS-IS system ID of 4 octets is the wrong width, and both are sent.
  def test_nothing_validates
    u = gen('count' => 1, 'protocol_id' => 0).updates.first
    assert_equal(0, mp(u).nlris.first.nlri.protocol_id)
    assert_equal('Reserved', mp(u).nlris.first.nlri.protocol)
  end
end
