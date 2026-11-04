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

# EVPN routes, AFI 25 SAFI 70: route types 2, 3 and 5 from a spec.
#
#   ruby -I. test/unit/gen/evpn_routes_test.rb
#
# The NLRI octets below are this reader's arithmetic from RFC 7432
# section 7.2 and RFC 9136 section 3.1, checked against what the library
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

  BASE = { 2 => { 'start' => '00:11:22:00:00:00', 'label' => 100 },
           3 => { 'start' => '10.0.0.1' },
           5 => { 'start' => '10.1.0.0/24', 'label' => 100 } }

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
      [nil, {}] => /needs a route_type, 2, 3, 5/,
      [1, {}] => /needs a route_type/,
      [5, { 'ip' => '10.0.0.1' }] => /'ip' is for route type 2 and not for 5/,
      [3, { 'label' => 5 }] => /'label' is for route type 2 and 5 and not for 3/,
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
end
