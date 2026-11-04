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

# EVPN routes, AFI 25 SAFI 70: all eleven route types from a spec.
#
#   ruby -I. test/unit/gen/evpn_routes_test.rb
#
# The NLRI octets below are this reader's arithmetic from RFC 7432
# sections 7.1 to 7.4, RFC 9136 section 3.1, RFC 9251 sections 9.1 to
# 9.3 and RFC 9572 sections 3.1 to 3.3, checked against what the library
# encodes. The route type classes have their own tests in
# test/unit/nlris/; what is tested here is which fields step, which stay
# and where each lands.
class TestBgpGenEvpnRoutes < Test::Unit::TestCase

  INFO = BGP::Update::Info.new(true, :strict)

  # Add-path both ways, read leniently: see
  # test_the_receive_checks_do_not_know_add_path_yet.
  class AddPath < BGP::Update::Info
    def initialize ; super(true, :lenient) ; end
    def path_id?(*) ; true ; end
  end

  ESI1 = '00:00:00:00:00:00:00:00:00:01'

  BASE = { 1 => { 'start' => ESI1, 'label' => 100 },
           2 => { 'start' => '00:11:22:00:00:00', 'label' => 100 },
           3 => { 'start' => '10.0.0.1' },
           4 => { 'start' => ESI1, 'originator' => '192.0.2.1' },
           5 => { 'start' => '10.1.0.0/24', 'label' => 100 },
           6 => { 'start' => '239.1.1.1', 'originator' => '192.0.2.1' },
           7 => { 'start' => '239.1.1.1', 'originator' => '192.0.2.1' },
           8 => { 'start' => '239.1.1.1', 'originator' => '192.0.2.1' },
           9 => { 'start' => '0000000000000001' },
           10 => { 'start' => '239.1.1.1', 'originator' => '192.0.2.1' },
           11 => { 'start' => '239.1.1.1', 'originator' => '192.0.2.1', 'leaf' => '192.0.2.9' } }

  def gen(type, spec = {}, sender = nil)
    BGP::Gen.new({ 'family' => 'evpn', 'route_type' => type, 'count' => 3, 'rd' => '65000:1',
                   'attributes' => { 'next_hop' => '192.0.2.1' } }.merge(BASE[type]).merge(spec), sender)
  end

  def parse(u, info = INFO)
    BGP::Update.new(u.encode(BGP::Update::Info.new(true)).is_packed, info)
  end

  def mp(u, key = :mp_reach, info = INFO) ; parse(u, info).path_attribute[key] ; end

  def routes(u, key = :mp_reach, info = INFO)
    mp(u, key, info).nlris.collect { |n| n.to_hash.values.first }
  end

  def ext(u) ; parse(u).path_attribute[:extended_communities].to_hash[:extended_communities] ; end

  def test_route_type_2_steps_the_mac_and_the_ip
    g = gen(2, 'start' => '00:11:22:00:00:fe', 'ip' => '10.0.0.255',
               'label' => { 'step' => { 'start' => 100, 'by' => 10 } },
               'ethernet_tag' => { 'cycle' => [7, 8] }, 'esi' => '0102030405060708090a')
    u = g.updates.to_a
    assert_equal(1, u.size, 'one attribute set, one message')
    assert_equal([25, 70], [mp(u[0]).afi, mp(u[0]).safi])
    r = routes(u[0])
    assert_equal(%w[00:11:22:00:00:fe 00:11:22:00:00:ff 00:11:22:00:01:00], r.collect { |x| x[:mac] })
    assert_equal(%w[10.0.0.255 10.0.1.0 10.0.1.1], r.collect { |x| x[:ip] })
    assert_equal([100, 110, 120], r.collect { |x| x[:label1][:label] })
    assert_equal([7, 8, 7], r.collect { |x| x[:ethernet_tag_id] })
    assert_equal(['01:02:03:04:05:06:07:08:09:0a'], r.collect { |x| x[:esi] }.uniq)
    assert_equal([[65000, 1]], r.collect { |x| x[:rd] }.uniq)
  end

  # RFC 7432 section 7.2, figure order: Route Type 2, Length 37, an RD of
  # type 0, a zero ESI, the Ethernet Tag ID, a MAC Address Length of 48,
  # the MAC, an IP Address Length of 32, the IP and MPLS Label1, 100 in
  # the high 20 bits with the low bit set. Without an IP the IP Address
  # Length is 0, section 14's default, and the route is 33 octets.
  def test_route_type_2_octets
    u = gen(2, 'count' => 1, 'ip' => '10.0.0.1').updates.first
    assert_match('0225' + '00' * 2 + 'fde800000001' + '00' * 10 + '00000000' +
                 '30' + '001122000000' + '20' + '0a000001' + '000641', u.to_shex)
    u = gen(2, 'count' => 1).updates.first
    assert_match('0221' + '00' * 2 + 'fde800000001' + '00' * 10 + '00000000' +
                 '30' + '001122000000' + '00' + '000641', u.to_shex)
  end

  def test_an_ipv6_ip_on_route_type_2
    r = routes(gen(2, 'ip' => '2001:db8::ffff').updates.first)
    assert_equal(%w[2001:db8::ffff 2001:db8::1:0 2001:db8::1:1], r.collect { |x| x[:ip] })
  end

  # RFC 7432 section 7.3: an RD, an Ethernet Tag ID and the Originating
  # Router's IP Address, which steps, so three routes are three PEs.
  def test_route_type_3_steps_the_originator
    u = gen(3, 'ethernet_tag' => 77).updates.to_a
    assert_equal(1, u.size)
    r = routes(u[0])
    assert_equal(%w[10.0.0.1 10.0.0.2 10.0.0.3], r.collect { |x| x[:ip] })
    assert_equal([77], r.collect { |x| x[:ethernet_tag_id] }.uniq)
    assert_nil(parse(u[0]).path_attribute[:pmsi_tunnel])
  end

  # RFC 7432 section 11.2: Ingress Replication with "the Tunnel Identifier
  # set to a routable address of the PE". Each route is its own PE, so
  # each has its own attribute and its own message.
  def test_a_pmsi_tunnel_names_each_routes_own_originator
    g = gen(3, 'start' => '2001:db8::1', 'pmsi_label' => { 'step' => { 'start' => 50, 'by' => 1 } })
    u = g.updates.to_a
    assert_equal(3, u.size, 'one message per PE')
    u.each_with_index do |m, i|
      pm = parse(m).path_attribute[:pmsi_tunnel].to_hash[:pmsi_tunnel]
      assert_equal(:ingress_replication, pm[:tunnel_type])
      # Pmsi_tunnel hashes a 4-octet identifier as an address and any
      # other width as hex, so an IPv6 one comes back as 32 hex digits.
      assert_equal("2001:db8::#{i + 1}", IPAddr.new_ntoh([pm[:identifier]].pack('H*')).to_s)
      assert_equal(50 + i, pm[:label])
      assert_equal(["2001:db8::#{i + 1}"], routes(m).collect { |x| x[:ip] })
    end
    assert_equal({ 'tunnel_type' => 'ingress_replication', 'label' => 51, 'identifier' => '2001:db8::2' },
                 g.expected.to_a[1]['pmsi'])
  end

  # The ESI and the gateway one at a time: RFC 9136 section 3.2 asks a
  # receiver to treat a route with both non-zero as withdrawn, which
  # test_nothing_validates sends. This test first sent both and the
  # strict read refused it.
  def test_route_type_5_steps_the_prefix
    r = routes(gen(5, 'gateway' => '10.0.0.254').updates.first)
    assert_equal(%w[10.1.0.0/24 10.1.1.0/24 10.1.2.0/24], r.collect { |x| x[:ip_prefix] })
    assert_equal(['10.0.0.254'], r.collect { |x| x[:gateway] }.uniq)
    assert_equal([100], r.collect { |x| x[:label] }.uniq)
    r = routes(gen(5, 'esi' => '01:01:01:01:01:01:01:01:01:01').updates.first)
    assert_equal(['01:01:01:01:01:01:01:01:01:01'], r.collect { |x| x[:esi] }.uniq)
    assert_equal(['0.0.0.0'], r.collect { |x| x[:gateway] }.uniq)
  end

  # RFC 9136 section 3.1: the Length is 34 for IPv4 and 58 for IPv6, and
  # a GW IP Address of zero is written when there is none.
  def test_route_type_5_octets
    u = gen(5, 'count' => 1).updates.first
    assert_match('0522' + '00' * 2 + 'fde800000001' + '00' * 10 + '00000000' +
                 '18' + '0a010000' + '00000000' + '000641', u.to_shex)
    g = gen(5, 'start' => '2001:db8::/64', 'count' => 1, 'attributes' => { 'next_hop' => '2001:db8::1' })
    assert_match('053a' + '00' * 2 + 'fde800000001', g.updates.first.to_shex)
    assert_equal('::', g.expected.first['gateway'])
  end

  def test_evis_step_the_rd_and_the_route_target
    g = gen(2, 'vrfs' => 2, 'route_target' => '65000:100', 'count' => 2)
    u = g.updates.to_a
    assert_equal(2, u.size, 'a route target per EVI is a set per EVI')
    assert_equal([[[65000, 1]], [[65000, 2]]], u.collect { |m| routes(m).collect { |x| x[:rd] }.uniq })
    assert_equal([{ :route_target => [65000, 100] }, { :route_target => [65000, 101] }],
                 u.collect { |m| ext(m).first })
    assert_equal(%w[00:11:22:00:00:00 00:11:22:00:00:01] * 2, g.expected.collect { |r| r['mac'] })
    assert_equal(4, g.total)
  end

  # RFC 7432 section 7.7 and RFC 9135 section 8.1, on the group number,
  # so a MAC move is sent as a new sequence number.
  def test_mac_mobility_and_the_routers_mac
    g = gen(2, 'count' => 4, 'group' => 2, 'mac_mobility' => { 'step' => { 'start' => 1, 'by' => 1 } },
               'router_mac' => 'AA:BB:CC:DD:EE:FF')
    u = g.updates.to_a
    assert_equal(2, u.size)
    assert_equal([[{ :mac_mobility => [1, false] }, { :router_mac => 'aa:bb:cc:dd:ee:ff' }],
                  [{ :mac_mobility => [2, false] }, { :router_mac => 'aa:bb:cc:dd:ee:ff' }]],
                 u.collect { |m| ext(m) })
    assert_equal(['mac_mobility:2:false', 'router_mac:aa:bb:cc:dd:ee:ff'], g.expected.to_a[3]['extended_communities'])
    # On route type 5 too, with the spec's own communities kept.
    u = gen(5, 'router_mac' => '00:00:5e:00:53:01',
               'attributes' => { 'extended_communities' => ['route_target:1:1'] }).updates.first
    assert_equal([{ :route_target => [1, 1] }, { :router_mac => '00:00:5e:00:53:01' }], ext(u))
  end

  # RFC 7432 section 14: the next hop is a real address, read by its
  # length since the AFI is 25 for both families.
  def test_the_next_hop_is_the_sessions
    s = BGP::Gen::Sender.read('as' => 65001, 'ebgp' => true, 'next_hop' => '2001:db8::9')
    g = gen(3, { 'attributes' => {} }, s)
    m = mp(g.updates.first)
    assert_equal(['2001:db8::9'], [m.nexthops].flatten)
    assert_match('0019461020010db8' + '00' * 11 + '09', g.updates.first.to_shex)
    assert_equal([65001], g.expected.first['as_path'])
  end

  def test_withdrawals_are_the_same_nlri_in_mp_unreach
    g = gen(2, 'ip' => '10.0.0.1', 'count' => 300)
    sent = g.updates.flat_map { |u| routes(u) }
    gone = g.withdrawals.flat_map { |u| routes(u, :mp_unreach) }
    assert_equal(300, sent.size)
    assert_equal(sent, gone)
    g.withdrawals.each { |u| assert_nil(parse(u).path_attribute[:mp_reach]) }
  end

  def test_expected_by_hand
    assert_equal({ 'route_type' => 2, 'rd' => '65000:1', 'mac' => '00:11:22:00:00:01', 'ip' => '10.0.0.2',
                   'esi' => '00:00:00:00:00:00:00:00:00:00', 'label' => 100, 'ethernet_tag' => 0,
                   'origin' => 0, 'as_path' => [], 'next_hop' => '192.0.2.1' },
                 gen(2, 'ip' => '10.0.0.1').expected.to_a[1])
    assert_equal({ 'route_type' => 3, 'rd' => '65000:1', 'originator' => '10.0.0.3', 'ethernet_tag' => 0,
                   'origin' => 0, 'as_path' => [], 'next_hop' => '192.0.2.1' },
                 gen(3).expected.to_a[2])
    assert_equal({ 'route_type' => 5, 'rd' => '65000:1', 'prefix' => '10.1.1.0/24', 'gateway' => '10.9.9.9',
                   'esi' => '00:00:00:00:00:00:00:00:00:00', 'label' => 100, 'ethernet_tag' => 0,
                   'origin' => 0, 'as_path' => [], 'next_hop' => '192.0.2.1' },
                 gen(5, 'gateway' => '10.9.9.9').expected.to_a[1])
  end

  def test_refusals
    {
      [nil, {}] => /needs a route_type, 1 to 11, not nil/,
      [12, {}] => /needs a route_type, 1 to 11, not 12/,
      [5, { 'ip' => '10.0.0.1' }] => /'ip' is for route type 2 and not for 5/,
      [3, { 'label' => 5 }] => /'label' is for route type 1, 2, 5 and not for 3/,
      [4, { 'ethernet_tag' => 1 }] => /'ethernet_tag' is for route type 1, 2, 3, 5, 6, 7, 8, 9, 10 and not for 4/,
      [1, { 'label' => nil }] => /type 1 spec needs a label/,
      [4, { 'originator' => nil }] => /type 4 spec needs an originator/,
      [11, { 'leaf' => nil }] => /type 11 spec needs a leaf/,
      [6, { 'esi' => ESI1 }] => /'esi' is for route type 2, 5, 7, 8 and not for 6/,
      [7, { 'max_response_time' => 1 }] => /'max_response_time' is for route type 8/,
      [2, { 'esi_label' => 1 }] => /'esi_label' is for route type 1 and not for 2/,
      [1, { 'es_import' => true }] => /'es_import' is for route type 4 and not for 1/,
      [1, { 'start' => '00:11:22:33:44:55' }] => /type 1 start is an ESI, ten octets/,
      [4, { 'start' => 'ff:ff:ff:ff:ff:ff:ff:ff:ff:ff', 'count' => 2 }] => /run past ff:ff:ff:ff:ff:ff:ff:ff:ff:ff/,
      [6, { 'start' => '239.0.0.0/8' }] => /Multicast Group address, not a prefix/,
      [6, { 'start' => 'x' }] => /type 6 start is a Multicast Group/,
      [10, { 'source' => '2001:db8::1' }] => /not of one family/,
      [6, { 'start' => '255.255.255.255', 'count' => 2 }] => /run past the end/,
      [6, { 'igmp_flags' => ['v4'] }] => /igmp_flags is a list of v1, v2, v3, ie/,
      [8, { 'max_response_time' => 256 }] => /max_response_time 256 does not fit/,
      [4, { 'es_import' => 'yes' }] => /es_import is true or false/,
      [9, { 'start' => '01' }] => /Region ID, 8 octets of hex/,
      [9, { 'start' => 'ffffffffffffffff', 'count' => 2 }] => /run past ffffffffffffffff/,
      [4, { 'originator' => 'x' }] => /originator "x" is not an address/,
      [1, { 'esi_label' => 2**20 }] => /esi_label/,
      [2, { 'pmsi_label' => 5 }] => /'pmsi_label' is for route type 3/,
      [2, { 'gateway' => '10.0.0.1' }] => /'gateway' is for route type 5/,
      [2, { 'label' => nil }] => /needs a label/,
      [2, { 'afi' => 1 }] => /EVPN is AFI 25/,
      [2, { 'start' => '10.0.0.0/24' }] => /start is a MAC/,
      [2, { 'start' => 'ff:ff:ff:ff:ff:ff', 'count' => 2 }] => /run past ff:ff:ff:ff:ff:ff/,
      [2, { 'ip' => '255.255.255.255', 'count' => 2 }] => /run past the end/,
      [3, { 'start' => '10.0.0.0/24' }] => /originator's address, not a prefix/,
      [5, { 'gateway' => '2001:db8::1' }] => /not of one family/,
      [2, { 'esi' => '01:02' }] => /esi "01:02" is 10 octets of hex/,
      [2, { 'router_mac' => 'zz' }] => /router_mac "zz" is 6 octets/,
      [2, { 'ip' => 'x' }] => /ip "x" is not an address/,
      [2, { 'rd' => nil }] => /needs an rd/,
      [2, { 'ethernet_tag' => 2**32 }] => /ethernet_tag/,
      [3, { 'pmsi_label' => 2**20 }] => /pmsi_label/,
    }.each do |(type, extra), why|
      spec = { 'family' => 'evpn', 'count' => 1, 'rd' => '65000:1' }.merge(BASE.fetch(type, BASE[2]))
      spec['route_type'] = type if type
      spec.merge!(extra).reject! { |_, v| v.nil? }
      e = assert_raise(BGP::Gen::SpecError, extra.inspect) { BGP::Gen.new(spec) }
      assert_match(why, e.message)
    end
    e = assert_raise(BGP::Gen::SpecError) do
      BGP::Gen.new('start' => '10.0.0.0/24', 'count' => 1, 'route_type' => 2)
    end
    assert_match(/'route_type' is for evpn and not for 'unicast'/, e.message)
  end

  # Building never validates: RFC 9136 section 3.2 says a route type 5
  # with a non-zero ESI and a non-zero GW IP at once SHOULD be treated as
  # withdrawn, and this sends one. validation.rb, on the receive side, is
  # what says so.
  def test_nothing_validates
    u = gen(5, 'count' => 1, 'esi' => '01:01:01:01:01:01:01:01:01:01', 'gateway' => '10.0.0.9',
               'label' => 0, 'ethernet_tag' => 2**32 - 1).updates.first
    pa = parse(u, BGP::Update::Info.new(true, :lenient)).path_attribute
    assert_equal(1, pa.errors.size)
    assert_match(/RFC 9136 section 3.2/, pa.errors.first.reason)
  end

  # **validation.rb walks an EVPN NLRI without knowing add-path was
  # negotiated**, the gap CLAUDE.md records for flow spec, measured here
  # for EVPN too: the four octets of the Path Identifier are read as a
  # Route Type and a Length. The NLRI itself decodes, since `Evpn` is
  # told, so a lenient read gets every route back. When the receive
  # checks learn add-path the first assertion fails: take the finding
  # out and read strictly.
  def test_the_receive_checks_do_not_know_add_path_yet
    u = gen(2, 'path_id' => 7).updates.first
    pa = parse(u, AddPath.new).path_attribute
    assert_match(/EVPN .*RFC 7432 section 7/, pa.errors.first.reason)
    assert_equal([7, 7, 7], pa[:mp_reach].nlris.collect(&:path_id))
    assert_equal(%w[00:11:22:00:00:00 00:11:22:00:00:01 00:11:22:00:00:02],
                 pa[:mp_reach].nlris.collect { |n| n.to_hash.values.first[:mac] })
  end

  # ---- phase 4d2: route types 1, 4 and 6 to 11 -------------------------

  def nlri_hex(u) ; mp(u).nlris.collect(&:to_shex) ; end

  # Route type 1, RFC 7432 section 7.1: RD, ESI, Ethernet Tag ID and the
  # MPLS Label, 25 octets. The ESI steps as one 80-bit number.
  def test_ethernet_auto_discovery
    g = gen(1, 'ethernet_tag' => 7)
    assert_equal(['01' + '19' + '0000fde800000001' + '00' * 9 + '01' + '00000007' + '000641',
                  '01' + '19' + '0000fde800000001' + '00' * 9 + '02' + '00000007' + '000641'],
                 nlri_hex(g.updates.first).first(2))
    assert_equal(%w[00:00:00:00:00:00:00:00:00:01 00:00:00:00:00:00:00:00:00:02 00:00:00:00:00:00:00:00:00:03],
                 g.expected.collect { |r| r['esi'] })
  end

  # The ESI Label extended community of section 7.5, single-active flag
  # clear: type 0x06, sub-type 0x01, the flags octet, two reserved
  # octets, then the label in the high 20 bits of the last three. It runs
  # on the group number like any attribute.
  def test_the_esi_label_community
    g = gen(1, 'esi_label' => { 'cycle' => [100, 200] }, 'group' => 2, 'count' => 4)
    u = g.updates.to_a
    assert_equal(2, u.size)
    assert_match('0601' + '00' + '0000' + '000640', u[0].to_shex)
    assert_match('0601' + '00' + '0000' + '000c80', u[1].to_shex)
    assert_equal(%w[esi_label:100:false esi_label:100:false esi_label:200:false esi_label:200:false],
                 g.expected.collect { |r| r['extended_communities'] }.flatten)
  end

  # Route type 4, section 7.4: RD, ESI, then the Originating Router's IP
  # Address with its length in bits, 23 octets for IPv4.
  def test_ethernet_segment
    u = gen(4).updates.first
    assert_equal('04' + '17' + '0000fde800000001' + '00' * 9 + '01' + '20' + 'c0000201', nlri_hex(u).first)
    assert_equal(3, mp(u).nlris.size)
  end

  # Section 7.6: the ES-Import Route Target is "the high-order six bytes
  # of the 9-byte ESI Value", which follow the ESI's Type octet. So ESIs
  # that differ only in their low three octets share one, and one that
  # carries into the sixth gets its own message.
  def test_the_es_import_route_target
    g = gen(4, 'start' => '00:11:22:33:44:55:66:ff:ff:ff', 'count' => 2, 'es_import' => true)
    u = g.updates.to_a
    assert_equal(2, u.size)
    assert_match('0602' + '112233445566', u[0].to_shex)
    assert_match('0602' + '112233445567', u[1].to_shex)
    assert_equal(%w[es_import:11:22:33:44:55:66 es_import:11:22:33:44:55:67],
                 g.expected.collect { |r| r['extended_communities'] }.flatten)
    assert_equal(1, gen(4, 'es_import' => true).updates.count, 'three ESIs, one ES-Import')
  end

  # Route type 6, RFC 9251 section 9.1: RD, Ethernet Tag ID, the
  # Multicast Source with its length in bits, 0 for (*,G), the Group,
  # the Originator Router, then the Flags octet, v2 being 0x02. 24
  # octets: 8 + 4 + 1 + 0 + 1 + 4 + 1 + 4 + 1.
  def test_selective_multicast
    g = gen(6)
    assert_equal('06' + '18' + '0000fde800000001' + '00000000' + '00' + '20' + 'ef010101' +
                 '20' + 'c0000201' + '02', nlri_hex(g.updates.first).first)
    assert_equal(%w[239.1.1.1 239.1.1.2 239.1.1.3], g.expected.collect { |r| r['group'] })
    assert_equal(['v2'], g.expected.first['igmp_flags'])
    f = gen(6, 'igmp_flags' => %w[v3 ie], 'source' => '10.0.0.9', 'count' => 1).updates.first
    assert_equal('0c', nlri_hex(f).first[-2, 2], 'v3 and the Include/Exclude bit, the low nibble')
    assert_match('20' + '0a000009' + '20' + 'ef010101', nlri_hex(f).first)
  end

  # Route types 7 and 8 add the ESI, and 8 the Reserved field and the
  # Maximum Response Time before the Flags.
  def test_membership_report_and_leave_synch
    seven = gen(7, 'esi' => ESI1, 'count' => 1).updates.first
    assert_match('07' + '22' + '0000fde800000001' + '00' * 9 + '01', nlri_hex(seven).first)
    eight = gen(8, 'max_response_time' => 7, 'count' => 1).updates.first
    assert_equal('00000000' + '07' + '02', nlri_hex(eight).first[-12, 12], 'Reserved, then 7, then v2')
    assert_equal(7, gen(8, 'max_response_time' => 7).expected.first['max_response_time'])
  end

  # Route type 9, RFC 9572 section 3.1: RD, Ethernet Tag ID and the
  # 8-octet Region ID, stepped as one number.
  def test_per_region_i_pmsi
    g = gen(9, 'start' => '00090000fde800ff')
    assert_equal('09' + '14' + '0000fde800000001' + '00000000' + '00090000fde800ff', nlri_hex(g.updates.first).first)
    assert_equal(%w[00090000fde800ff 00090000fde80100 00090000fde80101], g.expected.collect { |r| r['region_id'] })
  end

  # Route type 10, section 3.2: route type 6 without its Flags octet.
  def test_s_pmsi
    u = gen(10, 'source' => '10.0.0.9', 'count' => 1).updates.first
    assert_equal('0a' + '1b' + '0000fde800000001' + '00000000' + '20' + '0a000009' + '20' + 'ef010101' +
                 '20' + 'c0000201', nlri_hex(u).first)
  end

  # Route type 11, section 3.3: the Route Key is a whole route type 10
  # NLRI, Type and Length included, then the leaf's own address. 34
  # octets: 2 + 27 of the key and 1 + 4 of the address.
  def test_leaf_a_d
    g = gen(11, 'source' => '10.0.0.9', 'vrfs' => 2)
    key = '0a' + '1b' + '0000fde800000001' + '00000000' + '20' + '0a000009' + '20' + 'ef010101' + '20' + 'c0000201'
    assert_equal('0b' + '22' + key + '20' + 'c0000209', nlri_hex(g.updates.first).first)
    assert_equal(%w[65000:1 65000:1 65000:1 65000:2 65000:2 65000:2], g.expected.collect { |r| r['rd'] },
                 'the route key carries the EVI\'s RD')
    assert_nil(g.expected.first['ethernet_tag'], 'a leaf has no Ethernet Tag ID')
  end

  # IPv6 groups and sources, and an IPv6 originator under an IPv4 group,
  # which nothing ties together.
  def test_ipv6_groups
    u = gen(10, 'start' => 'ff0e::1', 'source' => '2001:db8::9', 'originator' => '2001:db8::1',
                'count' => 1).updates.first
    assert_match('80' + '20010db8' + '00' * 11 + '09' + '80' + 'ff0e' + '00' * 13 + '01', nlri_hex(u).first)
  end

  # Every one of the eleven goes out, reads back strictly and is
  # withdrawn by the same NLRI.
  def test_every_route_type_round_trips
    (1..11).each do |t|
      g = gen(t)
      sent = g.updates.flat_map { |u| mp(u).nlris.collect(&:to_shex) }
      gone = g.withdrawals.flat_map { |u| mp(u, :mp_unreach).nlris.collect(&:to_shex) }
      assert_equal(3, sent.size, "route type #{t}")
      assert_equal(sent, gone, "route type #{t}")
      assert_equal([t], g.expected.collect { |r| r['route_type'] }.uniq)
    end
  end
end

