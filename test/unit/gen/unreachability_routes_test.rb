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

# bgp/gen/unreachability_routes.rb, docs/design/unreachability.md pull
# request 4.
class TestBgpGenUnreachabilityRoutes < Test::Unit::TestCase

  def gen(spec) ; BGP::Gen.new(spec) ; end

  def safi81(extra = {})
    gen({ 'family' => 'unreachability', 'start' => '192.0.2.0/24', 'count' => 3 }.merge(extra))
  end

  def evpn(extra = {})
    gen({ 'family' => 'evpn_unreachability', 'start' => '192.0.2.0/24', 'count' => 3,
          'rd' => '65000:1' }.merge(extra))
  end

  def nlris(msgs, klass)
    msgs.flat_map { |m| m.path_attribute[klass].nlris }
  end

  def test_the_defaults
    g = safi81
    n = nlris(g.updates.to_a, BGP::Mp_reach)
    assert_equal(%w[192.0.2.0/24 192.0.3.0/24 192.0.4.0/24], n.collect(&:prefix))
    r = n.first.reporters
    assert_equal([['192.0.2.1', 64_512, 0, nil]], r.collect { |x| [x.identifier, x.as, x.reason, x.timestamp] })
    assert_equal([BGP::Unreachability::Reason_code], r.first.sub_tlvs.collect(&:class))
    pa = g.updates.first.path_attribute
    assert_equal({ :origin => :incomplete }, pa[BGP::Origin].to_hash)
    assert_equal('', pa[BGP::Mp_reach].nexthops)
    assert_equal(1, g.afi)
  end

  def test_reporters_step_from_reporter_and_patterns_vary_by_route
    g = safi81('reporters' => 3, 'reporter' => '10.0.0.254', 'reporter_as' => { 'cycle' => [1, 2] },
               'reason' => { 'step' => { 'start' => 1, 'by' => 1 } }, 'timestamp' => 7)
    n = nlris(g.updates.to_a, BGP::Mp_reach)
    assert_equal(%w[10.0.0.254 10.0.0.255 10.0.1.0], n.first.reporters.collect(&:identifier))
    assert_equal([[1, 1, 7], [2, 2, 7], [1, 3, 7]], n.collect { |x| r = x.reporters.first ; [r.as, r.reason, r.timestamp] })
    e = g.expected.to_a
    assert_equal({ 'prefix' => '192.0.3.0/24', 'reporters' => %w[10.0.0.254 10.0.0.255 10.0.1.0],
                   'reporter_as' => 2, 'reason' => 2, 'timestamp' => 7, 'origin' => 2, 'as_path' => [] }, e[1])
  end

  def test_an_origin_in_attributes_wins
    assert_equal({ :origin => :igp }, safi81('attributes' => { 'origin' => 0 }).updates.first.path_attribute[BGP::Origin].to_hash)
  end

  # Section 4.3.2: a withdrawal is the prefix alone.
  def test_withdrawals_carry_no_reporters
    g = safi81('reporters' => 5, 'timestamp' => 1, 'count' => 400, 'start' => '2001:db8::/48')
    w = nlris(g.withdrawals.to_a, BGP::Mp_unreach)
    assert_equal(400, w.size)
    assert(w.all?(&:withdrawal?))
    assert_equal(g.expected.collect { |r| r['prefix'] }, w.collect(&:prefix))
  end

  def test_the_messages_fit_and_parse_clean
    g = safi81('reporters' => 50, 'timestamp' => 1, 'count' => 200)
    (g.updates.to_a + g.withdrawals.to_a).each do |m|
      assert_operator(m.encode.bytesize, :<=, 4096)
      assert_equal([], BGP::Path_attribute.new(m.path_attribute.encode.is_packed).errors)
    end
    assert_equal(200, nlris(g.updates.to_a, BGP::Mp_reach).size)
  end

  def test_a_path_id
    n = nlris(safi81('path_id' => 9).updates.to_a, BGP::Mp_reach)
    assert_equal([9, 9, 9], n.collect(&:path_id))
  end

  def test_the_same_spec_gives_the_same_octets
    a = safi81('reason' => { 'random' => { 'min' => 0, 'max' => 9 } }, 'seed' => 4).updates.collect(&:to_shex)
    b = safi81('reason' => { 'random' => { 'min' => 0, 'max' => 9 } }, 'seed' => 4).updates.collect(&:to_shex)
    assert_equal(a, b)
  end

  def test_evpn
    g = evpn('vrfs' => 2, 'route_target' => '65000:7', 'ethernet_tag' => 4, 'reporters' => 2,
             'reason' => 12, 'attributes' => { 'next_hop' => '10.0.0.1' })
    assert_equal(6, g.total)
    msgs = g.updates.to_a
    n = nlris(msgs, BGP::Mp_reach)
    assert(n.all? { |e| e.route.is_a?(BGP::Evpn::Ip_prefix_unreachability) })
    assert_equal(%w[65000:1 65000:1 65000:1 65000:2 65000:2 65000:2],
                 n.collect { |e| e.route.rd.to_s(false).sub('RD=', '') })
    assert_equal([4], n.collect { |e| e.route.ethernet_tag_id.value }.uniq)
    assert_equal('VTEP Unreachable', n.first.route.reporters.first.sub_tlvs.first.name)
    mp = msgs.first.path_attribute[BGP::Mp_reach]
    assert_equal([25, 70, '10.0.0.1'], [mp.afi, mp.safi, mp.nexthops])
    assert_equal(['route_target:65000:7', 'route_target:65000:8'],
                 g.expected.collect { |r| r['extended_communities'] }.flatten.uniq)
    w = nlris(g.withdrawals.to_a, BGP::Mp_unreach)
    assert(w.all? { |e| e.route.withdrawal? })
    assert_equal(6, w.size)
  end

  # RFC 7432 section 7's one-octet Length (review note 3).
  def test_evpn_reporters_are_what_fits
    assert_nothing_raised { evpn('reporters' => 8, 'timestamp' => 1) }
    assert_raise(BGP::Gen::SpecError) { evpn('reporters' => 9, 'timestamp' => 1) }
    assert_nothing_raised { evpn('reporters' => 7, 'timestamp' => 1, 'start' => '2001:db8::/48') }
    assert_raise(BGP::Gen::SpecError) { evpn('reporters' => 8, 'timestamp' => 1, 'start' => '2001:db8::/48') }
    assert_nothing_raised { evpn('reporters' => 13) }
  end

  def test_refusals
    { { 'reporters' => 51 } => /at most 50/,
      { 'reporter' => 'nope' } => /not an IPv4 address/,
      { 'reporter' => '255.255.255.255', 'reporters' => 2 } => /run past 255\.255\.255\.255/,
      { 'reason' => 65_536 } => /reason/,
      { 'rd' => '65000:1' } => /'rd' is for .* not for 'unreachability'/ }.each do |extra, why|
      e = assert_raise(BGP::Gen::SpecError, extra.inspect) { safi81(extra) }
      assert_match(why, e.message)
    end
    e = assert_raise(BGP::Gen::SpecError) do
      gen('family' => 'evpn_unreachability', 'start' => '192.0.2.0/24', 'count' => 1)
    end
    assert_match(/needs an rd/, e.message)
    e = assert_raise(BGP::Gen::SpecError) { safi81('esi' => '00:11:22:33:44:55:66:77:88:99') }
    assert_match(/not for 'unreachability'/, e.message)
  end

end
