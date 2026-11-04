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

# Route Target membership, AFI 1 SAFI 132 (RFC 4684), from a spec.
#
#   ruby -I. test/unit/gen/rt_constrain_routes_test.rb
#
# RFC 4684 carries no worked example, so the octets below are this
# reader's arithmetic from section 4's figure and RFC 4360 section 3,
# checked against what the library encodes.
class TestBgpGenRtConstrainRoutes < Test::Unit::TestCase

  INFO = BGP::Update::Info.new(true, :strict)

  # Add-path both ways, read strictly: unlike flow spec and EVPN there
  # is no NLRI walk in validation.rb for this family, so nothing
  # misreads the Path Identifier.
  class AddPath < BGP::Update::Info
    def initialize ; super(true, :strict) ; end
    def path_id?(*) ; true ; end
  end

  def gen(spec = {}, sender = nil)
    BGP::Gen.new({ 'family' => 'rt_constrain', 'start' => '65000:100', 'count' => 3, 'origin_as' => 65001,
                   'attributes' => { 'next_hop' => '192.0.2.1' } }.merge(spec), sender)
  end

  def parse(u, info = INFO)
    BGP::Update.new(u.encode(BGP::Update::Info.new(true)).is_packed, info)
  end

  def mp(u, key = :mp_reach, info = INFO) ; parse(u, info).path_attribute[key] ; end

  def nlris(u, key = :mp_reach, info = INFO) ; mp(u, key, info).nlris.collect(&:to_hash) ; end

  def test_the_route_target_steps
    u = gen.updates.to_a
    assert_equal(1, u.size)
    assert_equal([1, 132], [mp(u[0]).afi, mp(u[0]).safi])
    assert_equal([65000, 100, 65000, 101, 65000, 102].each_slice(2).collect do |a, n|
                   { :origin_as => 65001, :route_target => { :route_target => [a, n] } }
                 end, nlris(u[0]))
  end

  # RFC 4684 section 4: a length of 96 bits, the origin AS in 4 octets,
  # then the 8 octets of the route target, which for a two-octet AS
  # is type 0x00, sub-type 0x02, the AS and a 4-octet number (RFC 4360
  # section 3.1).
  def test_the_octets
    u = gen('count' => 1).updates.first
    assert_match('60' + '0000fde9' + '0002' + 'fde8' + '00000064', u.to_shex)
  end

  # The administrator picks the layout, as for an RD: an IPv4 address is
  # type 0x01 with a 2-octet number (RFC 4360 section 3.2), a 4-octet AS
  # type 0x02 (RFC 5668 section 2).
  def test_the_three_layouts
    assert_match('60' + '0000fde9' + '0102' + 'c0000201' + '0007',
                 gen('start' => '192.0.2.1:7', 'count' => 1).updates.first.to_shex)
    assert_match('60' + '0000fde9' + '0202' + 'fa56ea00' + '0007',
                 gen('start' => '4200000000:7', 'count' => 1).updates.first.to_shex)
  end

  # Section 4's example: 64 bits is "all route target extended
  # communities assigned by a given Global Administrator", so the
  # number is not sent, and three routes of one administrator are one
  # prefix three times.
  def test_a_shorter_prefix
    g = gen('prefix_length' => 64)
    assert_match('40' + '0000fde9' + '0002fde8', g.updates.first.to_shex)
    assert_equal(3, g.updates.first.to_shex.scan('400000fde90002fde8').size)
    assert_equal([64], g.expected.collect { |r| r['prefix_length'] }.uniq)
    assert_match('20' + '0000fde9', gen('prefix_length' => 32, 'count' => 1).updates.first.to_shex)
  end

  def test_the_origin_as_is_a_pattern_on_the_route_number
    g = gen('origin_as' => { 'cycle' => [64512, 4200000000] }, 'count' => 4)
    assert_equal([64512, 4200000000, 64512, 4200000000], nlris(g.updates.first).collect { |h| h[:origin_as] })
  end

  # Section 4: the default route target is "encoded as a zero-length
  # prefix", in front of the range here.
  def test_the_default_route_target
    g = gen('default' => true, 'count' => 2)
    assert_equal(3, g.total)
    assert_equal([{ :mlen => 0 }], nlris(g.updates.first).first(1))
    # The SNPA count, then the default's length octet 0, then the first
    # route's 96.
    assert_match(/800e..000184 04 c0000201 00 00 60/x, g.updates.first.to_shex)
    assert_equal({ 'default' => true, 'origin' => 0, 'as_path' => [], 'next_hop' => '192.0.2.1' },
                 g.expected.first)
    assert_equal('65000:101', g.expected.to_a.last['route_target'])
  end

  def test_a_path_id_on_every_route
    g = gen('path_id' => { 'step' => { 'start' => 1, 'by' => 1 } }, 'default' => true)
    pa = parse(g.updates.first, AddPath.new).path_attribute
    assert_equal([], pa.errors)
    assert_equal([1, 2, 3, 4], pa[:mp_reach].nlris.collect(&:path_id))
  end

  # The next hop is read by its length, RFC 4684 section 4, so an IPv6
  # one under AFI 1 is 16 octets.
  def test_the_next_hop_is_the_sessions
    s = BGP::Gen::Sender.read('as' => 65001, 'ebgp' => true, 'next_hop' => '2001:db8::9')
    g = gen({ 'attributes' => {} }, s)
    assert_equal('2001:db8::9', mp(g.updates.first).nexthops)
    assert_match('00018410' + '20010db8' + '00' * 11 + '09', g.updates.first.to_shex)
    assert_equal([65001], g.expected.first['as_path'])
  end

  def test_withdrawals_are_the_same_nlri
    g = gen('count' => 600, 'default' => true)
    sent = g.updates.flat_map { |u| nlris(u) }
    gone = g.withdrawals.flat_map { |u| nlris(u, :mp_unreach) }
    assert_equal(601, sent.size)
    assert_operator(g.updates.count, :>, 1)
    assert_equal(sent, gone)
  end

  def test_expected_by_hand
    assert_equal({ 'origin_as' => 65001, 'route_target' => '65000:102', 'prefix_length' => 96,
                   'origin' => 0, 'as_path' => [], 'next_hop' => '192.0.2.1' }, gen.expected.to_a[2])
  end

  def test_refusals
    {
      { 'origin_as' => nil } => /needs an origin_as/,
      { 'afi' => 2 } => /RFC 4684 section 4 gives route target membership AFI 1/,
      { 'start' => '10.0.0.0/24' } => /not ADMIN:N/,
      { 'start' => '192.0.2.1:65535', 'count' => 2 } => /steps to 65536/,
      { 'origin_as' => 2**32 } => /origin_as: 4294967296 does not fit/,
      { 'prefix_length' => 256 } => /prefix_length 256 does not fit/,
      { 'default' => 'yes' } => /default is true or false/,
    }.each do |extra, why|
      spec = { 'family' => 'rt_constrain', 'start' => '65000:100', 'count' => 1, 'origin_as' => 1 }
      spec = spec.merge(extra).reject { |_, v| v.nil? }
      e = assert_raise(BGP::Gen::SpecError, extra.inspect) { BGP::Gen.new(spec) }
      assert_match(why, e.message)
    end
    e = assert_raise(BGP::Gen::SpecError) { BGP::Gen.new('start' => '10.0.0.0/24', 'count' => 1, 'origin_as' => 1) }
    assert_match(/'origin_as' is for rt_constrain and not for 'unicast'/, e.message)
  end

  # Building never validates: section 4's minimum of 32 bits, outside
  # the default, and its maximum of 96, are both sent past.
  def test_nothing_validates
    assert_match('10' + '0000', gen('prefix_length' => 16, 'count' => 1).updates.first.to_shex)
    long = gen('prefix_length' => 200, 'count' => 1).updates.first
    assert_match(/c8/, long.to_shex)
    assert_equal(200, mp(long).nlris.first.mlen)
  end
end
