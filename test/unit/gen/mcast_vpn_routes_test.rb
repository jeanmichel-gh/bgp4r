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

# MCAST-VPN routes, SAFI 5 (RFC 6514 section 4), from a spec.
#
#   ruby -I. test/unit/gen/mcast_vpn_routes_test.rb
#
# RFC 6514 carries no worked example and no hex, so the octets below are
# this reader's arithmetic from the section 4 figures, written out by
# hand and not taken from the library: a generator that put the wrong
# field in a route would agree with its own `expected`.
class TestBgpGenMcastVpnRoutes < Test::Unit::TestCase

  INFO = BGP::Update::Info.new(true, :strict)

  class AddPath < BGP::Update::Info
    def initialize ; super(true, :lenient) ; end
    def path_id?(*) ; true ; end
  end

  RD1 = '0000fde800000001'   # 65000:1, RFC 4364 section 4.2 type 0
  RD2 = '0000fde800000002'

  # A spec per route type, each with what that type cannot do without.
  BASE = {
    1 => { 'start' => '10.0.0.1' },
    2 => { 'start' => '65001' },
    3 => { 'start' => '239.1.1.1', 'source' => '10.9.9.9', 'originator' => '10.0.0.1' },
    4 => { 'start' => '239.1.1.1', 'originator' => '10.0.0.1', 'leaf' => '10.0.0.2' },
    5 => { 'start' => '239.1.1.1', 'source' => '10.9.9.9' },
    6 => { 'start' => '239.1.1.1', 'source_as' => 65000 },
    7 => { 'start' => '239.1.1.1', 'source_as' => 65000, 'source' => '10.9.9.9' },
  }.freeze

  def gen(type, spec = {}, sender = nil)
    BGP::Gen.new({ 'family' => 'mcast_vpn', 'route_type' => type, 'count' => 3, 'rd' => '65000:1',
                   'attributes' => { 'next_hop' => '192.0.2.1' } }.merge(BASE[type]).merge(spec), sender)
  end

  def parse(u, info = INFO)
    BGP::Update.new(u.encode(BGP::Update::Info.new(true)).is_packed, info)
  end

  def mp(u, key = :mp_reach, info = INFO) ; parse(u, info).path_attribute[key] ; end

  def nlri_hex(u, key = :mp_reach) ; mp(u, key).nlris.collect(&:to_shex) ; end

  # Section 4.1: RD and the Originating Router's IP Address, 12 octets,
  # the address stepped once per route, so N routes are N PEs.
  def test_intra_as_i_pmsi
    g = gen(1)
    assert_equal(%w[0a000001 0a000002 0a000003].collect { |a| '01' + '0c' + RD1 + a },
                 nlri_hex(g.updates.first))
    assert_equal(%w[10.0.0.1 10.0.0.2 10.0.0.3], g.expected.collect { |r| r['originator'] })
  end

  # Section 4.2: RD and a 4-octet Source AS, 12 octets, the AS stepped.
  def test_inter_as_i_pmsi
    g = gen(2)
    assert_equal(%w[0000fde9 0000fdea 0000fdeb].collect { |a| '02' + '0c' + RD1 + a },
                 nlri_hex(g.updates.first))
    assert_equal([65001, 65002, 65003], g.expected.collect { |r| r['source_as'] })
  end

  # Section 4.3: RD, Multicast Source and Group each behind a length in
  # bits, then the Originating Router's IP Address: 22 octets all IPv4.
  def test_s_pmsi
    g = gen(3)
    assert_equal(%w[ef010101 ef010102 ef010103].collect do |grp|
                   '03' + '16' + RD1 + '20' + '0a090909' + '20' + grp + '0a000001'
                 end, nlri_hex(g.updates.first))
  end

  # No source writes a Multicast Source Length of 0 and no address,
  # section 4.3's wildcard, so the route is 18 octets.
  def test_no_source_is_a_length_of_zero
    u = gen(3, 'source' => nil).updates.first
    assert_equal('03' + '12' + RD1 + '00' + '20' + 'ef010101' + '0a000001', nlri_hex(u).first)
    assert_not_include(gen(3, 'source' => nil).expected.first.keys, 'source')
  end

  # Section 4.4: the Route Key is the whole route type 3 NLRI, Route
  # Type and Length included (RFC 6515 section 2 item 4), and the Leaf
  # A-D route's own Originating Router's IP Address follows it.
  def test_leaf_a_d
    g = gen(4)
    key = '03' + '12' + RD1 + '00' + '20' + 'ef010101' + '0a000001'
    assert_equal('04' + '18' + key + '0a000002', nlri_hex(g.updates.first).first)
    assert_equal({ 'route_type' => 4, 'rd' => '65000:1', 'group' => '239.1.1.1', 'originator' => '10.0.0.1',
                   'leaf' => '10.0.0.2' }, g.expected.first.reject { |k, _| %w[origin as_path next_hop].include?(k) })
  end

  # Section 4.5: RD, Multicast Source and Group, 18 octets all IPv4.
  def test_source_active
    assert_equal('05' + '12' + RD1 + '20' + '0a090909' + '20' + 'ef010102',
                 nlri_hex(gen(5).updates.first)[1])
  end

  # Section 4.6: RD, Source AS, Multicast Source and Group, one layout
  # and two type numbers.
  def test_shared_and_source_tree_join
    assert_equal('06' + '12' + RD1 + '0000fde8' + '00' + '20' + 'ef010101',
                 nlri_hex(gen(6).updates.first).first)
    assert_equal('07' + '16' + RD1 + '0000fde8' + '20' + '0a090909' + '20' + 'ef010101',
                 nlri_hex(gen(7).updates.first).first)
  end

  # RFC 6515 section 1.1: the AFI is the family of the customer
  # addresses. An IPv6 group is AFI 2, with 128-bit lengths, and the
  # IPv4 next hop of the session stays 4 octets, not IPv4-mapped.
  def test_an_ipv6_group_is_afi_2_with_an_ipv4_next_hop
    g = gen(5, 'start' => 'ff3e::1', 'source' => '2001:db8::1')
    assert_equal(2, g.afi)
    u = g.updates.first
    assert_equal([2, 5], [mp(u).afi, mp(u).safi])
    assert_equal('05' + '2a' + RD1 + '80' + '20010db8' + '0' * 22 + '01' + '80' + 'ff3e' + '0' * 26 + '01',
                 nlri_hex(u).first)
    assert_match('000205' + '04' + 'c0000201', u.to_shex)
  end

  # Types 1 and 2 carry no customer address, so the AFI is the spec's,
  # 1 when it says nothing, and never the originator's family.
  def test_types_1_and_2_take_the_afi_from_the_spec
    assert_equal(1, gen(1, 'start' => '2001:db8::1').afi)
    assert_equal(2, gen(1, 'afi' => 2).afi)
    assert_equal(2, mp(gen(2, 'afi' => 2).updates.first).afi)
  end

  # Every VPN carries the same routes with its own RD and route target.
  def test_vrfs_and_route_targets
    g = gen(1, 'vrfs' => 2, 'route_target' => '65000:100')
    u = g.updates.to_a
    assert_equal(2, u.size, 'a route target per VPN is an attribute set per VPN')
    assert_equal('01' + '0c' + RD2 + '0a000001', nlri_hex(u[1]).first)
    assert_equal([['65000:1', 'route_target:65000:100'], ['65000:2', 'route_target:65000:101']],
                 [g.expected.to_a[0], g.expected.to_a[3]].collect { |r| [r['rd'], r['extended_communities'].first] })
  end

  def test_withdrawals_are_the_same_nlri
    g = gen(7)
    assert_equal(nlri_hex(g.updates.first), nlri_hex(g.withdrawals.first, :mp_unreach))
  end

  # The session's next hop, read by its length (RFC 6515 section 2
  # item 1), so a 16-octet one under AFI 1 is IPv6, and the eBGP rules
  # an announce block gets.
  def test_the_next_hop_is_the_sessions
    s = BGP::Gen::Sender.read('as' => 65001, 'ebgp' => true, 'next_hop' => '2001:db8::9')
    g = gen(1, { 'attributes' => {} }, s)
    u = g.updates.first
    assert_match('000105' + '10' + '20010db8' + '0' * 22 + '09', u.to_shex)
    assert_equal(['2001:db8::9', [65001]], [g.expected.first['next_hop'], g.expected.first['as_path']])
  end

  def test_a_path_id_on_every_route
    g = gen(1, 'path_id' => { 'step' => { 'start' => 10, 'by' => 1 } })
    assert_equal([10, 11, 12], mp(g.updates.first, :mp_reach, AddPath.new).nlris.collect(&:path_id))
    assert_equal([10, 11, 12], g.expected.collect { |r| r['path_id'] })
  end

  # The add-path gap of phases 4c, 4d and 4g holds here: validation.rb
  # walks the NLRIs without knowing a Path Identifier comes first, so
  # its four octets are read as a Route Type and a Length. The route
  # itself decodes. Under "Known issues to work on" in CLAUDE.md.
  def test_the_receive_checks_do_not_know_add_path_yet
    pa = parse(gen(1, 'path_id' => 7).updates.first, AddPath.new).path_attribute
    assert_match(/\AMCAST-VPN .*(RFC 6514 section 4|RFC 6515 section 2)/, pa.errors.first.reason)
    assert_empty(parse(gen(1, 'path_id' => 7).updates.first, AddPath.new).path_attribute.undecoded)
    assert_equal([7, 7, 7], pa[:mp_reach].nlris.collect(&:path_id))
  end

  def test_refusals
    [[{ 'route_type' => 8 }, /route_type, 1 to 7/],
     [{ 'route_type' => nil }, /route_type, 1 to 7/],
     [{ 'leaf' => '10.0.0.9' }, /'leaf' is for route type 4 and not for 3/],
     [{ 'source_as' => 1 }, /'source_as' is for route type 6, 7 and not for 3/],
     [{ 'originator' => nil }, /route type 3 spec needs an originator/],
     [{ 'start' => '239.1.1.0/24' }, /an address and not a prefix/],
     [{ 'start' => 'nonsense' }, /is a Multicast Group/],
     [{ 'start' => '255.255.255.254', 'count' => 3 }, /run past the end/],
     [{ 'source' => '2001:db8::1' }, /not of one family/]].each do |extra, msg|
      e = assert_raise(BGP::Gen::SpecError, extra.inspect) { gen(3, extra) }
      assert_match(msg, e.message)
    end
    e = assert_raise(BGP::Gen::SpecError) { gen(2, 'start' => 'AS65001') }
    assert_match(/Source AS as a decimal string/, e.message)
    e = assert_raise(BGP::Gen::SpecError) { gen(2, 'start' => '4294967295', 'count' => 2) }
    assert_match(/run past 4294967295/, e.message)
    e = assert_raise(BGP::Gen::SpecError) { gen(6, 'source_as' => nil) }
    assert_match(/needs a source_as/, e.message)
    e = assert_raise(BGP::Gen::SpecError) { gen(4, 'leaf' => nil) }
    assert_match(/needs a leaf/, e.message)
    spec = { 'family' => 'mcast_vpn', 'route_type' => 1, 'start' => '10.0.0.1', 'count' => 1 }
    e = assert_raise(BGP::Gen::SpecError) { BGP::Gen.new(spec) }
    assert_match(/mcast_vpn spec needs an rd/, e.message)
    e = assert_raise(BGP::Gen::SpecError) { gen(1, 'afi' => 2, 'start' => '239.1.1.1', 'route_type' => 5) }
    assert_match(/afi 2 disagrees/, e.message)
    e = assert_raise(BGP::Gen::SpecError) { BGP::Gen.new('family' => 'unicast', 'start' => '10.0.0.0/24', 'count' => 1, 'source_as' => 1) }
    assert_match(/'source_as' is for mcast_vpn/, e.message)
  end

  # Building never validates: a Source Active route with no source,
  # which section 4.5 calls outside its scope, and an SSM group, which
  # it says MUST NOT be advertised, both go out.
  def test_nothing_validates
    u = gen(5, 'source' => nil, 'start' => '232.1.1.1', 'count' => 1).updates.first
    assert_equal('05' + '0e' + RD1 + '00' + '20' + 'e8010101', nlri_hex(u).first)
  end
end
