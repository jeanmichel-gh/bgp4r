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

# Flow specification rules, SAFI 133 and 134 (RFC 8955, RFC 8956): one
# rule per destination prefix, the other match components and the
# actions from the spec.
#
#   ruby -I. test/unit/gen/flow_rules_test.rb
#
# The rule octets below are this reader's arithmetic from RFC 8955
# section 4.2.2's layouts, checked against what the library encodes.
# The RFC's own five vectors are in test/unit/nlris/, where the
# component classes are tested; nothing here re-tests those.
class TestBgpGenFlowRules < Test::Unit::TestCase

  INFO = BGP::Update::Info.new(true, :strict)

  # Add-path both ways, read leniently: see
  # test_the_receive_checks_do_not_know_add_path_yet.
  class AddPath < BGP::Update::Info
    def initialize ; super(true, :lenient) ; end
    def path_id?(*) ; true ; end
  end

  def gen(spec, sender = nil)
    BGP::Gen.new({ 'family' => 'flow_spec', 'start' => '10.0.0.0/24', 'count' => 3 }.merge(spec), sender)
  end

  def parse(u, info = INFO)
    BGP::Update.new(u.encode(BGP::Update::Info.new(true)).is_packed, info)
  end

  def mp(u, key = :mp_reach, info = INFO) ; parse(u, info).path_attribute[key] ; end

  def rules(u, key = :mp_reach, info = INFO) ; mp(u, key, info).nlris.collect(&:to_hash) ; end

  def ext(u) ; parse(u).path_attribute[:extended_communities] ; end

  def test_each_rule_matches_its_destination_with_the_other_components
    u = gen('protocol' => 6, 'destination_port' => 80).updates.first
    assert_equal([1, 133], [mp(u).afi, mp(u).safi])
    assert_equal([{ :destination_prefix => '10.0.0.0/24', :ip_protocol => [[:eq, 6]], :destination_port => [[:eq, 80]] },
                  { :destination_prefix => '10.0.1.0/24', :ip_protocol => [[:eq, 6]], :destination_port => [[:eq, 80]] },
                  { :destination_prefix => '10.0.2.0/24', :ip_protocol => [[:eq, 6]], :destination_port => [[:eq, 80]] }],
                 rules(u))
    # RFC 8955 section 4.1 and 4.2.2: a length of 11, then type 1 with a
    # /24, type 3 with the end-of-list and eq bits and a one octet 6, and
    # type 5 the same with 80.
    assert_match('0b' + '01180a0000' + '038106' + '058150', u.to_shex)
  end

  # RFC 8956 section 3.1 adds an offset to an IPv6 prefix component, 0
  # here, and type 3 is the upper layer protocol.
  def test_an_ipv6_rule
    u = gen('start' => '2001:db8::/48', 'count' => 1, 'protocol' => 17, 'source' => '2001:db8:ff::/48').updates.first
    assert_equal([2, 133], [mp(u).afi, mp(u).safi])
    assert_equal([{ :destination_ipv6_prefix => { :prefix => '2001:db8::/48' },
                    :source_ipv6_prefix => { :prefix => '2001:db8:ff::/48' },
                    :upper_layer_protocol => [[:eq, 17]] }], rules(u))
  end

  # RFC 8955 section 4: "the Length of the Next-Hop Network Address MUST
  # be set to 0". A Sender's address is not filled in.
  def test_there_is_no_next_hop
    g = gen({}, 'as' => 65001, 'ebgp' => true, 'next_hop' => '192.0.2.9')
    u = g.updates.first
    assert_equal('', mp(u).nexthops)
    # The MP_REACH_NLRI header: flags, type, length, AFI 1, SAFI 133, and
    # a next hop length of 0.
    assert_match(/800e..00018500/, u.to_shex)
    assert_nil(g.expected.first['next_hop'])
    assert_equal([65001], g.expected.first['as_path'], 'the other Sender rules still apply')
  end

  # Building never validates, so a next hop the spec gives itself goes.
  def test_a_next_hop_the_spec_gives_is_sent
    g = gen('attributes' => { 'next_hop' => '192.0.2.1' })
    assert_equal('192.0.2.1', mp(g.updates.first).nexthops)
    assert_equal('192.0.2.1', g.expected.first['next_hop'])
  end

  # RFC 8955 sections 7.1, 7.4 and 7.5, in one extended communities
  # attribute with the spec's own.
  def test_the_actions_are_extended_communities
    u = gen('rate' => 1000, 'redirect' => '65000:100', 'marking' => 10,
            'attributes' => { 'extended_communities' => ['route_target:65000:7'] }).updates.first
    e = ext(u)
    assert_equal(%w[Route_target Traffic_rate_bytes Redirect Traffic_marking],
                 e.communities.collect { |c| c.class.name.split('::').last })
    # 0x8006, AS 0, 1000 as an IEEE float; 0x8008, AS 65000, 100; 0x8009
    # with the DSCP in the last octet.
    assert_match('80060000447a0000' + '8008fde800000064' + '80090000000000' + '0a', e.to_shex)
  end

  def test_redirect_takes_the_three_layouts
    %w[65000:100 192.0.2.1:100 4200000000:100].zip(%w[8008 8108 8208]).each do |t, type|
      assert_match(type, ext(gen('redirect' => t).updates.first).to_shex, t)
    end
  end

  # An action is an attribute, so it runs on the group number and a
  # change of action ends a message. A component is part of the rule,
  # so it runs on the route number and does not.
  def test_actions_run_on_the_group_and_components_on_the_route
    g = gen('count' => 6, 'group' => 2, 'marking' => { 'cycle' => [10, 20, 30] },
            'destination_port' => { 'step' => { 'start' => 80, 'by' => 1 } })
    msgs = g.updates.to_a
    assert_equal(3, msgs.size)
    assert_equal([[80, 81], [82, 83], [84, 85]], msgs.collect { |u| rules(u).collect { |r| r[:destination_port][0][1] } })
    assert_equal([10, 20, 30], msgs.collect { |u| ext(u).to_hash[:extended_communities][0][:traffic_marking] })
  end

  def test_a_withdrawal_is_the_same_rule_in_mp_unreach
    g = gen('protocol' => 6)
    w = g.withdrawals.first
    pa = parse(w).path_attribute
    assert_equal([BGP::Mp_unreach], pa.attributes.collect(&:class))
    assert_equal([1, 133], [pa[:mp_unreach].afi, pa[:mp_unreach].safi])
    assert_equal(rules(g.updates.first), rules(w, :mp_unreach))
  end

  # A port of 80 is one octet and 8080 two (RFC 8955 section 4.2.1.1),
  # so the rules differ in length and each is measured.
  def test_rules_of_different_lengths_pack_full
    g = gen('start' => '10.0.0.0/32', 'count' => 900, 'destination_port' => { 'cycle' => [80, 8080] })
    msgs = g.updates.to_a
    assert_operator(msgs.size, :>, 1)
    msgs.each_cons(2) do |m, n|
      size = m.encode(BGP::Update::Info.new(true)).bytesize
      assert_operator(size, :<=, 4096)
      next_rule = mp(n).nlris.first.encode.bytesize
      assert_operator(size + next_rule, :>, 4096, 'the next rule would have fitted')
    end
    assert_equal(900, msgs.sum { |u| mp(u).nlris.size })
    assert_equal([10, 11], rules(msgs[0])[0, 2].collect { |r| BGP::Flow_spec.new(r).encode.bytesize })
  end

  def test_expected
    g = gen('count' => 2, 'protocol' => 6, 'destination_port' => { 'cycle' => [80, 443] }, 'source' => '192.0.2.0/24',
            'rate' => 0, 'attributes' => { 'as_path' => [65010] })
    assert_equal({ 'destination' => '10.0.1.0/24', 'source' => '192.0.2.0/24', 'protocol' => 6,
                   'destination_port' => 443, 'origin' => 0, 'as_path' => [65010],
                   'extended_communities' => ['traffic_rate_bytes:0:0.0'] }, g.expected.to_a[1])
  end

  def test_a_path_id_rides_in_front
    u = gen('path_id' => { 'step' => { 'start' => 7, 'by' => 1 } }).updates.first
    assert_equal([7, 8, 9], mp(u, :mp_reach, AddPath.new).nlris.collect(&:path_id))
    assert_match('00000007' + '05' + '01180a0000', u.to_shex)
  end

  # validation.rb walks a flow spec rule without knowing add-path was
  # negotiated, so it reads the Path Identifier as a length and reports
  # a rule with no component. The rule itself decodes, as the case above
  # shows. Pinned, so the day the checks learn add-path this fails and
  # says to drop the corpus exclusion in test/unit/gen_test.rb.
  def test_the_receive_checks_do_not_know_add_path_yet
    u = gen('path_id' => 7).updates.first
    errors = parse(u, AddPath.new).path_attribute.errors
    assert_equal(1, errors.size)
    assert_match(/flow spec NLRI with no component/, errors.first.reason)
  end

  def test_vpn_rules_carry_an_rd_per_vrf_and_a_route_target_per_vrf
    g = BGP::Gen.new('family' => 'flow_spec_vpn', 'start' => '10.0.0.0/24', 'count' => 2, 'vrfs' => 2,
                     'rd' => '65000:1', 'route_target' => '65000:10', 'protocol' => 6)
    assert_equal(4, g.total)
    msgs = g.updates.to_a
    assert_equal(2, msgs.size, 'one attribute set per VRF')
    assert_equal([1, 134], [mp(msgs[0]).afi, mp(msgs[0]).safi])
    assert_equal([[[65000, 1], '10.0.0.0/24'], [[65000, 1], '10.0.1.0/24'],
                  [[65000, 2], '10.0.0.0/24'], [[65000, 2], '10.0.1.0/24']],
                 msgs.flat_map { |u| rules(u).collect { |r| [r[:rd], r[:destination_prefix]] } })
    assert_equal(%w[65000:10 65000:11], msgs.collect { |u| ext(u).to_hash[:extended_communities][0][:route_target].join(':') })
    assert_equal(%w[65000:1 65000:1 65000:2 65000:2], g.expected.collect { |r| r['rd'] })
    # RFC 8955 section 8: the RD sits inside the rule, after its length.
    # 16 octets: the RD's 8, the /24 destination's 5, the protocol's 3.
    assert_match('10' + '0000fde800000001' + '01180a0000' + '038106', msgs[0].to_shex)
  end

  def test_refusals
    {
      { 'source' => '2001:db8::/32' } => /not of one family/,
      { 'source' => 'nowhere' } => /source "nowhere" is not a prefix/,
      { 'protocol' => 256 } => /protocol/,
      { 'destination_port' => 65536 } => /destination_port/,
      { 'marking' => 64 } => /marking/,
      { 'redirect' => '65000' } => /not ADMIN:N/,
      { 'rd' => '65000:1' } => /'rd' is for vpn, vpn_multicast, flow_spec_vpn, evpn and not for 'flow_spec'/,
    }.each do |bad, why|
      e = assert_raise(BGP::Gen::SpecError, bad.inspect) { gen(bad) }
      assert_match(why, e.message)
    end
    e = assert_raise(BGP::Gen::SpecError) { BGP::Gen.new('family' => 'flow_spec_vpn', 'start' => '10.0.0.0/8', 'count' => 1) }
    assert_match(/a flow_spec_vpn spec needs an rd/, e.message)
    %w[protocol destination_port source rate redirect marking].each do |k|
      v = { 'source' => '10.0.0.0/8', 'redirect' => '65000:1' }.fetch(k, 1)
      e = assert_raise(BGP::Gen::SpecError, k) { BGP::Gen.new('start' => '10.0.0.0/8', 'count' => 1, k => v) }
      assert_match(/'#{k}' is for flow_spec, flow_spec_vpn and not for 'unicast'/, e.message)
    end
  end

  # Nothing no RFC allows is refused: a rule matching port 0 and
  # protocol 0, from and to one prefix, with a next hop.
  def test_nothing_validates
    g = gen('count' => 1, 'protocol' => 0, 'destination_port' => 0, 'source' => '10.0.0.0/24',
            'attributes' => { 'next_hop' => '10.0.0.1' })
    assert_equal([{ :destination_prefix => '10.0.0.0/24', :source_prefix => '10.0.0.0/24',
                    :ip_protocol => [[:eq, 0]], :destination_port => [[:eq, 0]] }],
                 rules(g.updates.first, :mp_reach, BGP::Update::Info.new(true, :lenient)))
  end
end
