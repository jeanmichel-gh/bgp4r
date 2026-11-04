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

# BGP::Gen::Churn, docs/route-generation.md section 8.
#
# **`expected` and the events come from the same generator**, so a test
# that only compares them proves consistency. The cases that say more
# state octets, kinds and values by hand: the withdrawal octets, the MED
# a replacement carries, the rule that a withdrawn route can only come
# back, and the order a seed gives.
class Gen_Churn_Test < Test::Unit::TestCase

  INFO = BGP::Update::Info.new(true)

  SPEC = { 'start' => '10.0.0.0/24', 'count' => 5,
           'attributes' => { 'next_hop' => '192.0.2.1' } }.freeze

  STEP = { 'med' => { 'step' => { 'start' => 1, 'by' => 1 } } }.freeze

  def churn(c, spec = SPEC, sender = nil)
    BGP::Gen.new(spec, sender).churn(c)
  end

  def parse(msg)
    BGP::Update.new(msg.encode(INFO).is_packed, INFO)
  end

  # The events of this churn, worked out by hand from the RFC 4271 rules
  # and the seed's first draws, are not the point; what is stated here is
  # the octets of one of each kind.
  def test_a_withdrawal_is_one_prefix_in_withdrawn_routes
    e = churn('events' => 50, 'withdraw' => 1).events.first
    assert_equal('withdraw', e.kind)
    # RFC 4271 section 4.3: Withdrawn Routes Length 4, one /24, no
    # attributes and no NLRI.
    want = 'ffffffffffffffffffffffffffffffff001b020004180a00' + format('%02x', e.route) + '0000'
    assert_equal(want, e.update.to_shex)
  end

  def test_a_replacement_carries_the_churn_attributes_at_its_event_number
    c = churn('events' => 40, 'withdraw' => 0, 'attributes' => STEP)
    c.events.each do |e|
      assert_equal('replace', e.kind)
      u = parse(e.update)
      assert_equal(["10.0.#{e.route}.0/24"], u.nlri.to_ary)
      assert_equal(e.number + 1, u.path_attribute[:multi_exit_disc].to_i)
      assert_equal('192.0.2.1', u.path_attribute[:next_hop].next_hop)
    end
  end

  def test_with_no_attributes_a_replacement_repeats_the_spec_row
    g = BGP::Gen.new(SPEC)
    base = g.updates.first
    c = g.churn('events' => 5, 'withdraw' => 0)
    c.events.each do |e|
      assert_nil(parse(e.update).path_attribute[:multi_exit_disc])
      assert_equal(parse(base).path_attribute.to_shex, parse(e.update).path_attribute.to_shex)
    end
  end

  # A withdrawn route is announced next time it is picked, and never
  # withdrawn twice in a row; a held one is never announced.
  def test_a_withdrawn_route_can_only_come_back
    held = Hash.new(true)
    churn('events' => 500, 'withdraw' => 0.6).events.each do |e|
      if held[e.route]
        assert_not_equal('announce', e.kind, "event #{e.number}")
      else
        assert_equal('announce', e.kind, "event #{e.number}")
      end
      held[e.route] = e.kind != 'withdraw'
    end
  end

  def test_withdraw_one_alternates
    kinds = churn('events' => 200, 'routes' => 1, 'withdraw' => 1).events.collect(&:kind)
    assert_equal((%w[withdraw announce] * 100), kinds)
  end

  def test_routes_bounds_what_is_picked
    picked = churn('events' => 300, 'routes' => 3).events.collect(&:route).uniq.sort
    assert_equal([0, 1, 2], picked)
  end

  def test_the_seed_decides_and_the_share_does_not_move_the_picks
    a = churn('events' => 100, 'seed' => 7).events.collect { |e| [e.route, e.kind] }
    b = churn('events' => 100, 'seed' => 7).events.collect { |e| [e.route, e.kind] }
    c = churn('events' => 100, 'seed' => 8).events.collect { |e| [e.route, e.kind] }
    d = churn('events' => 100, 'seed' => 7, 'withdraw' => 0.1).events.collect(&:route)
    assert_equal(a, b)
    assert_not_equal(a, c)
    assert_equal(a.collect(&:first), d)
    assert_not_equal(a.collect(&:last), churn('events' => 100, 'seed' => 7, 'withdraw' => 0.1).events.collect(&:kind))
  end

  def test_the_spec_seed_is_the_default
    a = churn({ 'events' => 30 }, SPEC.merge('seed' => 3)).events.collect(&:route)
    b = churn('events' => 30, 'seed' => 3).events.collect(&:route)
    assert_equal(a, b)
  end

  def test_expected_is_the_state_after_every_event
    c = churn('events' => 60, 'withdraw' => 0.4, 'attributes' => STEP)
    # A model of the receiver, fed the decoded messages.
    rib = {}
    5.times { |i| rib["10.0.#{i}.0/24"] = nil }
    c.events.each do |e|
      u = parse(e.update)
      u.withdrawn.to_ary.each { |p| rib.delete(p) } if u.withdrawn
      if u.nlri
        med = u.path_attribute[:multi_exit_disc]
        u.nlri.to_ary.each { |p| rib[p] = med && med.to_i }
      end
    end
    rows = c.expected.to_a
    assert_equal(rib.keys.sort, rows.collect { |r| r['prefix'] }.sort)
    rows.each { |r| assert_equal(rib[r['prefix']], r['med'], r['prefix']) }
    assert_equal(c.summary['held'], rows.size)
    assert_equal(5 - rows.size, c.summary['withdrawn'])
  end

  def test_a_route_the_churn_left_alone_keeps_the_spec_row
    g = BGP::Gen.new(SPEC.merge('count' => 10))
    c = g.churn('events' => 20, 'routes' => 2, 'attributes' => STEP)
    base = g.expected.to_a
    rows = c.expected.to_a
    assert_equal(base[2..], rows.select { |r| r['prefix'] >= '10.0.2.0/24' })
  end

  def test_the_summary_counts_the_kinds
    c = churn('events' => 400, 'withdraw' => 0.25)
    s = c.summary
    kinds = c.events.collect(&:kind).tally
    assert_equal(kinds, s['kinds'].reject { |_, v| v.zero? })
    assert_equal(400, s['events'])
    assert_equal(400, s['kinds'].values.sum)
  end

  def test_the_overlay_does_not_leak_into_the_spec
    g = BGP::Gen.new(SPEC)
    before = g.updates.collect(&:to_shex)
    g.churn('events' => 20, 'withdraw' => 0, 'attributes' => STEP).events.to_a
    assert_equal(before, g.updates.collect(&:to_shex))
    assert_nil(g.expected.first['med'])
  end

  # The sender's rules run after the churn's attributes, so a churned
  # AS_PATH gets our AS in front over eBGP and LOCAL_PREF is dropped.
  def test_the_senders_rules_apply_to_the_churn
    c = churn({ 'events' => 10, 'withdraw' => 0,
                'attributes' => { 'as_path' => [65099], 'local_pref' => 500 } },
              SPEC, 'as' => 65000, 'ebgp' => true)
    c.events.each do |e|
      pa = parse(e.update).path_attribute
      assert_equal('65000 65099', pa[:as_path].as_path)
      assert_nil(pa[:local_pref])
    end
    assert_equal([65000, 65099], c.expected.to_a.first['as_path'])
  end

  def test_an_ipv6_vpn_churn
    spec = { 'family' => 'vpn', 'start' => '2001:db8::/64', 'count' => 4, 'label' => 100,
             'rd' => '65000:1', 'vrfs' => 2, 'attributes' => { 'next_hop' => '2001:db8::1' } }
    c = churn({ 'events' => 30, 'withdraw' => 1, 'routes' => 8 }, spec)
    e = c.events.first
    attr = parse(e.update).path_attribute[:mp_unreach]
    assert_equal([2, 128], [attr.afi, attr.safi])
    rd = e.route >= 4 ? 'RD=65000:2' : 'RD=65000:1'
    assert_match(/#{rd}/, attr.to_s)
    assert_match(/2001:db8:0:#{e.route % 4}::\/64/, attr.to_s)
  end

  def test_rate_and_duration
    c = churn('rate' => 20, 'duration' => 1.5)
    assert_equal(30, c.count)
    assert_in_delta(0.05, c.interval, 1e-9)
    assert_nil(churn('events' => 3).interval)
    assert_equal(4, churn('events' => 4, 'rate' => 1000).count)
    assert_equal(1, churn('rate' => 1, 'duration' => 0.1).count)
  end

  def test_refusals
    [
      [{ 'events' => 1, 'bogus' => 1 }, /unknown churn key 'bogus'/],
      [{ 'events' => 1, 'duration' => 3, 'rate' => 1 }, /events or duration, not both/],
      [{ 'duration' => 3 }, /duration needs a rate/],
      [{}, /needs events, or rate and duration/],
      [{ 'events' => 0 }, /churn.events is at least 1/],
      [{ 'events' => 1, 'withdraw' => 1.5 }, /share from 0 to 1/],
      [{ 'events' => 1, 'withdraw' => '0.5' }, /share from 0 to 1/],
      [{ 'events' => 1, 'routes' => 6 }, /churn.routes 6 does not fit/],
      [{ 'events' => 1, 'rate' => 0 }, /churn.rate is a number above 0/],
      [{ 'events' => 1, 'attributes' => { 'colour' => 1 } }, /unknown churn attribute 'colour'/],
      [{ 'events' => 1, 'attributes' => { 'med' => { 'step' => { 'start' => 1 } } } },
       /churn.attributes.med: by is required/],
      [[1], /a churn is a Hash/],
    ].each do |c, re|
      e = assert_raise(BGP::Gen::SpecError, c.inspect) { churn(c) }
      assert_match(re, e.message)
    end
  end

  # Symbol keys read as String ones, as a spec's do.
  def test_symbol_keys
    a = churn(:events => 20, :withdraw => 0.3).events.collect { |e| [e.route, e.kind] }
    b = churn('events' => 20, 'withdraw' => 0.3).events.collect { |e| [e.route, e.kind] }
    assert_equal(a, b)
  end

  def test_the_spec_answer_is_plain_data
    s = churn('rate' => 10, 'duration' => 2, 'attributes' => STEP).spec
    assert_equal({ 'events' => 20, 'routes' => 5, 'withdraw' => 0.5, 'seed' => 0,
                   'attributes' => { 'med' => { 'step' => { 'start' => 1, 'by' => 1 } } },
                   'rate' => 10, 'duration' => 2 }, s)
  end

  # Every family takes a churn, and every event parses back strictly.
  def test_every_family
    specs = {
      'labelled' => { 'family' => 'labelled', 'start' => '10.0.0.0/24', 'count' => 6, 'label' => 100 },
      'flow' => { 'family' => 'flow_spec', 'start' => '10.0.0.0/24', 'count' => 6, 'rate' => 1000 },
      'evpn' => { 'family' => 'evpn', 'route_type' => 3, 'start' => '10.0.0.1', 'count' => 6,
                  'rd' => '65000:1', 'pmsi_label' => 10 },
      'rtc' => { 'family' => 'rt_constrain', 'start' => '65000:1', 'count' => 6, 'origin_as' => 65000 },
      'ls' => { 'family' => 'bgp_ls', 'start' => '10.0.0.1', 'count' => 4, 'topology' => 'ring',
                'prefixes' => 1, 'prefix_start' => '10.9.0.0/24' },
      'mvpn' => { 'family' => 'mcast_vpn', 'route_type' => 3, 'start' => '232.0.0.1', 'count' => 6,
                  'rd' => '65000:1', 'source' => '10.0.0.1', 'originator' => '192.0.2.1' },
    }
    strict = BGP::Update::Info.new(true, :strict)
    specs.each do |name, spec|
      g = BGP::Gen.new(spec, 'as' => 65000, 'ebgp' => true, 'next_hop' => '192.0.2.9')
      c = g.churn('events' => 40, 'withdraw' => 0.3, 'attributes' => STEP)
      c.events.each do |e|
        u = BGP::Update.new(e.update.encode(strict).is_packed, strict)
        assert_equal([], u.path_attribute.errors, "#{name} event #{e.number}")
      end
      assert_equal(c.summary['held'], c.expected.count, name)
    end
  end
end
