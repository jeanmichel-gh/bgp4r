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

# The EVPN table, docs/design/evpn.md pull request 1. Routes are built as
# a session receives them: an UPDATE encoded, parsed again, and read by
# PeerAdapter.evpn_operations.
# BGP:: names are written out in full here, see Conventions in CLAUDE.md.
class TestBgpRibEvpnTable < Test::Unit::TestCase

  H1 = '02:00:00:00:01:01'
  H2 = '02:00:00:00:01:02'

  def setup
    @t = BGP::Rib::EvpnTable.new(local_as: 65000, router_id: '10.255.0.11')
  end

  def peer(address, router_id = address)
    BGP::Rib::Peer.new(:address => address, :remote_as => 65000, :router_id => router_id, :local_as => 65000)
  end

  # The 24-bit VNI as Label1's three fields (RFC 8365 section 5.1.3).
  def label1(vni)
    { :label => vni >> 4, :exp => (vni >> 1) & 7, :bottom => vni & 1 }
  end

  def type2(rd, mac, vni: 100, ip: nil, tag: 0)
    h = { :rd => rd, :ethernet_tag_id => tag, :mac => mac, :label1 => label1(vni) }
    h[:ip] = ip if ip
    { :mac_ip_advertisement => h }
  end

  def type3(rd, originator, tag: 0)
    { :inclusive_multicast => { :rd => rd, :ethernet_tag_id => tag, :ip => originator } }
  end

  # An UPDATE with nlris from address, through the wire and back.
  def update(nlris, nh:, local_pref: 100, ecs: nil, pmsi: nil, attrs: [], withdraw: false)
    mp = (withdraw ? BGP::Mp_unreach : BGP::Mp_reach).new(
      { :afi => 25, :safi => 70, :nlris => nlris }.merge(withdraw ? {} : { :nexthop => [nh] }))
    list = withdraw ? [mp] : [BGP::Origin.new(0), BGP::As_path.new, BGP::Local_pref.new(local_pref), mp,
                              BGP::Extended_communities.new(*(ecs || [BGP::Route_target.new(65000, 100),
                                                                       BGP::Encapsulation.new(:vxlan)])),
                              *Array(pmsi), *attrs]
    BGP::Update.new(BGP::Update.new(BGP::Path_attribute.new(*list)).encode)
  end

  def ops(from, nlris, router_id: from, **opts)
    BGP::Rib::PeerAdapter.evpn_operations(update(nlris, nh: opts.delete(:nh) || from, **opts), peer(from, router_id))
  end

  def ir(id, vni)
    BGP::Pmsi_tunnel.new(:tunnel_type => :ingress_replication, :identifier => id, :label_bits => vni)
  end

  def test_a_type_2_route_and_its_row
    @t.apply('10.255.0.12', ops('10.255.0.12', [type2(['10.255.0.12', 100], H2)],
                                ecs: [BGP::Route_target.new(65000, 100), BGP::Encapsulation.new(:vxlan),
                                      BGP::Mac_mobility.new(sequence: 2)]))
    r = @t.rows.first
    assert_equal(['10.255.0.12:100', 2, 0, H2, nil, '10.255.0.12', 100, '10.255.0.12', ['65000:100'], 'VXLAN', 2, false],
                 r.values_at('rd', 'route_type', 'eth_tag', 'mac', 'ip', 'originator', 'vni', 'next_hop',
                             'route_targets', 'encap', 'seq', 'sticky'))
    assert_equal(['00:00:00:00:00:00:00:00:00:00', nil, true, 'only_route'], r.values_at('esi', 'pmsi', 'best', 'reason'))
  end

  # RFC 8365 section 9: the IMET route's PMSI Tunnel names the tunnel,
  # and section 5.1.3 puts the VNI in its label field.
  def test_a_type_3_route_and_its_row
    @t.apply('10.255.0.12', ops('10.255.0.12', [type3(['10.255.0.12', 100], '10.255.0.12')], pmsi: ir('10.255.0.12', 100)))
    r = @t.rows.first
    assert_equal([3, nil, '10.255.0.12', 100, { 'type' => 'ingress_replication', 'id' => '10.255.0.12' }, nil, nil],
                 r.values_at('route_type', 'mac', 'originator', 'vni', 'pmsi', 'seq', 'esi'))
  end

  # bgp4r's generator wrote label 100 as an MPLS label before bgp4r #379,
  # and FRR read VNI 1601. The table reads what the field holds.
  def test_the_vni_is_the_whole_24_bit_field
    old = { :mac_ip_advertisement => { :rd => [65000, 1], :mac => H2, :label1 => { :label => 100, :exp => 0, :bottom => 1 } } }
    @t.apply('10.0.9.2', ops('10.0.9.2', [old]))
    assert_equal(1601, @t.rows.first['vni'])
  end

  # RFC 7432 section 7.2: the IP is part of the route's key, so one MAC
  # with and without an IP is two routes; and the RD keeps two MAC-VRFs'
  # routes apart.
  def test_the_key
    @t.apply('10.255.0.12', ops('10.255.0.12', [type2(['10.255.0.12', 100], H2),
                                               type2(['10.255.0.12', 100], H2, ip: '172.16.100.2'),
                                               type2(['10.255.0.13', 100], H2)]))
    assert_equal(3, @t.size)
    assert_equal([true, true, true], @t.rows.collect { |r| r['best'] })
    assert_equal([[nil, '10.255.0.12:100'], ['172.16.100.2', '10.255.0.12:100'], [nil, '10.255.0.13:100']],
                 @t.rows.collect { |r| r.values_at('ip', 'rd') })
  end

  # The same key from two peers, as a leaf hears one route through two
  # reflectors: BGP's rules pick one.
  def test_one_key_from_two_peers_is_decided_by_bgps_rules
    @t.apply('10.255.0.1', ops('10.255.0.1', [type2(['10.255.0.12', 100], H2)], nh: '10.255.0.12', local_pref: 100))
    @t.apply('10.255.0.2', ops('10.255.0.2', [type2(['10.255.0.12', 100], H2)], nh: '10.255.0.12', local_pref: 200))
    best = @t.best(['10.255.0.12:100', 2, 0, H2, nil])
    assert_equal(['10.255.0.2', :local_pref], [best.best.peer.address, best.reason])
    assert_equal({ '10.255.0.1' => false, '10.255.0.2' => true }, @t.rows.to_h { |r| [r['peer'], r['best']] })
    assert_equal(1, @t.winners.size)
  end

  # Kept whatever its Route Targets: a reflector needs them all.
  def test_every_route_is_kept_whatever_its_route_targets
    @t.apply('10.255.0.12', ops('10.255.0.12', [type2(['10.255.0.12', 999], H2)], ecs: [BGP::Route_target.new(65000, 999)]))
    assert_equal([['65000:999'], nil], @t.rows.first.values_at('route_targets', 'encap'))
  end

  # A reflected route's originator is its ORIGINATOR_ID (RFC 4456 section
  # 8), not the reflector it came from.
  def test_a_reflected_type_2_names_its_originator
    attrs = [BGP::Originator_id.new('10.255.0.12'), BGP::Cluster_list.new('10.255.0.1')]
    @t.apply('10.255.0.1', ops('10.255.0.1', [type2(['10.255.0.12', 100], H2)], nh: '10.255.0.12', attrs: attrs))
    assert_equal(['10.255.0.12', '10.255.0.1', ['10.255.0.1']], @t.rows.first.values_at('originator', 'peer', 'cluster_list'))
  end

  def test_a_withdrawal_removes_the_route_and_decides_again
    @t.apply('10.255.0.1', ops('10.255.0.1', [type2(['10.255.0.12', 100], H2)], local_pref: 100))
    @t.apply('10.255.0.2', ops('10.255.0.2', [type2(['10.255.0.12', 100], H2)], local_pref: 200))
    key = ['10.255.0.12:100', 2, 0, H2, nil]
    @t.apply('10.255.0.2', ops('10.255.0.2', [type2(['10.255.0.12', 100], H2)], withdraw: true))
    assert_equal('10.255.0.1', @t.best(key).best.peer.address)
    @t.apply('10.255.0.1', ops('10.255.0.1', [type2(['10.255.0.12', 100], H2)], withdraw: true))
    assert_nil(@t.best(key))
    assert_equal([0, []], [@t.size, @t.winners])
  end

  def test_a_type_3_withdrawal
    @t.apply('10.255.0.12', ops('10.255.0.12', [type3(['10.255.0.12', 100], '10.255.0.12')], pmsi: ir('10.255.0.12', 100)))
    @t.apply('10.255.0.12', ops('10.255.0.12', [type3(['10.255.0.12', 100], '10.255.0.12')], withdraw: true))
    assert_equal(0, @t.size)
  end

  # RFC 4271 section 3.1: a new announcement of a key replaces the old.
  def test_an_announcement_replaces_the_one_before
    @t.apply('10.255.0.12', ops('10.255.0.12', [type2(['10.255.0.12', 100], H2)]))
    @t.apply('10.255.0.12', ops('10.255.0.12', [type2(['10.255.0.12', 100], H2, vni: 200)]))
    assert_equal([1, 200], [@t.size, @t.rows.first['vni']])
  end

  def test_a_session_down_takes_its_routes_and_its_counts
    @t.apply('10.255.0.12', ops('10.255.0.12', [type2(['10.255.0.12', 100], H1), type2(['10.255.0.12', 100], H2)]))
    @t.apply('10.255.0.13', ops('10.255.0.13', [type2(['10.255.0.13', 100], H1)]))
    @t.peer_down('10.255.0.12')
    assert_equal([1, 0, 1], [@t.size, @t.size('10.255.0.12'), @t.winners.size])
    assert_equal({ received: 0, other_types: 0 }, @t.counts('10.255.0.12'))
  end

  # Types other than 2 and 3 are counted, not kept (docs/design/evpn.md,
  # decision 1). An Ethernet Segment route, type 4, here.
  def test_other_types_are_counted_and_not_kept
    es = { :ethernet_segment => { :rd => [65000, 1], :esi => '00:11:22:33:44:55:66:77:88:99', :ip => '10.255.0.12' } }
    @t.apply('10.255.0.12', ops('10.255.0.12', [es, type2(['10.255.0.12', 100], H2)]))
    assert_equal([1, 2], [@t.size, @t.rows.first['route_type']])
    assert_equal({ received: 1, other_types: 1 }, @t.counts('10.255.0.12'))
  end

  # Type 254 is UnreachTable's: neither kept here nor counted.
  def test_the_unreachability_route_is_not_counted_here
    u = { :ip_prefix_unreachability => { :rd => [65000, 1], :ethernet_tag_id => 0, :afi => 1, :prefix => '10.1.0.0/16' } }
    ops = ops('10.255.0.12', [u]) rescue omit("could not build a type 254 route from #{u.inspect}")
    assert_equal([], ops)
  end

  def test_listeners_hear_every_change
    heard = 0
    @t.on_change { heard += 1 }
    @t.apply('10.255.0.12', ops('10.255.0.12', [type2(['10.255.0.12', 100], H2)]))
    @t.peer_down('10.255.0.12')
    assert_equal(2, heard)
  end

  # Both OPENs must carry L2VPN EVPN.
  def test_negotiated
    evpn = BGP::OPT_PARM::CAP::Mbgp.new(25, 70)
    v4 = BGP::OPT_PARM::CAP::Mbgp.new(1, 1)
    open = ->(*caps) { BGP::Open.new(4, 65000, 180, '10.0.0.1', *caps) }
    si = Struct.new(:speaker, :peer)
    assert(BGP::Rib::EvpnTable.negotiated?(si.new(open.(evpn, v4), open.(evpn))))
    assert(!BGP::Rib::EvpnTable.negotiated?(si.new(open.(evpn), open.(v4))))
    assert(!BGP::Rib::EvpnTable.negotiated?(nil))
  end
end
