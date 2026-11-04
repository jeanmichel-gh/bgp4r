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

# BGP::Gen as a whole: which family it dispatches to, and the properties
# docs/route-generation.md section 10 says every generator owes, run
# over many random specs. A failure prints the spec, so it can be
# replayed as it is.
class TestBgpGen < Test::Unit::TestCase

  # A peer that negotiated add-path both ways reads a Path Identifier
  # before every prefix (RFC 7911 section 3); one that did not reads
  # none. Both strict, so a protocol error raises rather than being kept.
  class AddPath < BGP::Update::Info
    def initialize ; super(true, :strict) ; end
    def recv_inet_unicast? ; true ; end
    def path_id?(*) ; true ; end
  end
  PLAIN = BGP::Update::Info.new(true, :strict)
  AS2 = BGP::Update::Info.new(false)
  AS4 = BGP::Update::Info.new(true)

  # GEN_SEEDS=500 runs a longer sweep. The default keeps the unit suite
  # quick, since every message is parsed several times over.
  SEEDS = Integer(ENV.fetch('GEN_SEEDS', 25))

  def test_unicast_is_the_one_generator
    assert_equal(%w[unicast], BGP::Gen::GENERATORS.keys)
    assert_equal(BGP::Gen::Unicast, BGP::Gen::GENERATORS['unicast'])
  end

  # The names are Specimen's, so the library has one vocabulary, and a
  # family bgp4r can build but not yet generate says so.
  def test_a_family_with_no_generator_yet_is_refused_as_such
    names = BGP::Specimen.families.collect { |n, _, _| n.to_s }
    (names - BGP::Gen::GENERATORS.keys).each do |name|
      e = assert_raise(BGP::Gen::SpecError) { BGP::Gen.new('family' => name, 'start' => '10.0.0.0/8', 'count' => 1) }
      assert_match(/family '#{name}' has no generator yet/, e.message)
    end
    assert_include(names, 'unicast', 'and the one there is, is a Specimen name')
  end

  def test_an_unknown_family_is_refused_with_the_list
    e = assert_raise(BGP::Gen::SpecError) { BGP::Gen.new('family' => 'ipv4', 'start' => '10.0.0.0/8', 'count' => 1) }
    assert_match(/unknown family 'ipv4'; the families are unicast, multicast/, e.message)
  end

  def test_the_spec_is_kept_as_read
    g = BGP::Gen.new(:start => '10.0.0.0/8', :count => 1)
    assert_equal({ 'family' => 'unicast', 'start' => '10.0.0.0/8', 'count' => 1, 'attributes' => {} }, g.spec)
    assert_equal('unicast', g.family)
    assert_equal(1, g.afi)
  end

  def test_the_same_spec_gives_the_same_octets
    spec = random_spec(Random.new(3))
    a = BGP::Gen.new(spec).updates.collect { |u| u.encode(AS4) }
    b = BGP::Gen.new(spec).updates.collect { |u| u.encode(AS4) }
    assert_equal(a, b)
  end

  # A random spec of the kinds phase 1 reads. Always valid, since the
  # point is that valid input gives valid traffic; whether invalid input
  # reaches the wire is each class's own test_nothing_validates.
  def random_spec(r)
    v6 = r.rand(2) == 1
    mlen = v6 ? r.rand(16..128) : r.rand(8..32)
    start = v6 ? "2001:db8::/#{mlen}" : "10.0.0.0/#{mlen}"
    # How many prefixes fit before leaving 10.0.0.0/8 or 2001::/16.
    room = v6 ? 2**(mlen - 16) : 2**(mlen - 8)
    a = { 'origin' => r.rand(3), 'next_hop' => v6 ? '2001:db8::1' : '192.0.2.1',
          'as_path' => Array.new(r.rand(0..6)) { r.rand(1..2**32 - 1) } }
    a['med'] = r.rand(2**32) if r.rand(2) == 1
    a['local_pref'] = r.rand(2**32) if r.rand(2) == 1
    a['communities'] = Array.new(r.rand(1..40)) { "#{r.rand(65536)}:#{r.rand(65536)}" } if r.rand(2) == 1
    a['large_communities'] = Array.new(r.rand(1..20)) { "#{r.rand(2**32)}:1:#{r.rand(9)}" } if r.rand(2) == 1
    a['extended_communities'] = ["route_target:#{r.rand(65536)}:#{r.rand(2**32)}"] if r.rand(2) == 1
    s = { 'family' => 'unicast', 'start' => start, 'count' => r.rand(1..[room, 600].min), 'attributes' => a }
    s['per_update'] = r.rand(1..300) if r.rand(2) == 1
    s['path_id'] = r.rand(2**32) if r.rand(2) == 1
    s
  end

  def info_for(spec)
    spec['path_id'] ? AddPath.new : PLAIN
  end

  def keys_of(u)
    list = u.nlri || u.withdrawn
    list = list.nlris if list.respond_to?(:nlris)
    mp = u.path_attribute && (u.path_attribute[:mp_reach] || u.path_attribute[:mp_unreach])
    list = mp.nlris if mp && (list.nil? || list.empty?)
    list.collect { |n| [n.to_s.sub(/\AID=\d+, /, ''), n.path_id] }
  end

  def each_spec
    SEEDS.times do |seed|
      spec = random_spec(Random.new(seed))
      yield spec, "seed #{seed}: #{spec.inspect}"
    end
  end

  # Every message is within RFC 4271 section 4's limit on either session,
  # holds no more than per_update routes, and each but the last is full:
  # per_update reached, or one more route would not fit.
  def test_every_message_fits_and_each_is_full
    each_spec do |spec, why|
      g = BGP::Gen.new(spec)
      mlen = spec['start'].split('/').last.to_i
      route = 1 + (mlen + 7) / 8 + (spec['path_id'] ? 4 : 0)
      [g.updates.to_a, g.withdrawals.to_a].each do |msgs|
        msgs.each_with_index do |m, i|
          size = m.encode(AS4).bytesize
          assert_operator(size, :<=, 4096, why)
          assert_operator(m.encode(AS2).bytesize, :<=, size, why)
          routes = keys_of(BGP::Update.new(m.encode(AS4).is_packed, info_for(spec))).size
          assert_operator(routes, :<=, spec['per_update'], why) if spec['per_update']
          next if i == msgs.size - 1
          full = routes == spec['per_update']
          assert(full || size + route > 4096, "message #{i} has room left; #{why}")
        end
      end
    end
  end

  def test_every_message_round_trips
    each_spec do |spec, why|
      g = BGP::Gen.new(spec)
      (g.updates.to_a + g.withdrawals.to_a).each do |m|
        o = m.encode(AS4)
        assert_equal(o.unpack1('H*'), BGP::Update.new(o.dup.is_packed, info_for(spec)).encode(AS4).unpack1('H*'), why)
      end
    end
  end

  # validation.rb reports nothing on valid generated traffic. The info is
  # strict, so a finding raises; errors is asserted as well, so a lenient
  # read would not pass for the wrong reason.
  def test_validation_reports_nothing
    each_spec do |spec, why|
      BGP::Gen.new(spec).updates.each do |m|
        u = BGP::Update.new(m.encode(AS4).is_packed, info_for(spec))
        assert_equal([], u.path_attribute.errors, why)
        assert_equal([], u.path_attribute.undecoded, why)
      end
    end
  end

  def test_withdrawals_cover_exactly_what_was_announced
    each_spec do |spec, why|
      g = BGP::Gen.new(spec)
      sent = g.updates.flat_map { |m| keys_of(BGP::Update.new(m.encode(AS4).is_packed, info_for(spec))) }
      gone = g.withdrawals.flat_map { |m| keys_of(BGP::Update.new(m.encode(AS4).is_packed, info_for(spec))) }
      assert_equal(spec['count'], sent.size, why)
      assert_equal(sent.uniq.size, sent.size, "a route announced twice; #{why}")
      assert_equal(sent, gone, why)
    end
  end

  # expected has count rows, in the order sent, and each says what the
  # UPDATE carrying it says.
  def test_expected_is_what_was_sent
    each_spec do |spec, why|
      g = BGP::Gen.new(spec)
      rows = g.expected.to_a
      assert_equal(spec['count'], rows.size, why)
      assert_equal(spec['count'], g.expected.size, why)
      read = g.updates.flat_map do |m|
        u = BGP::Update.new(m.encode(AS4).is_packed, info_for(spec))
        keys_of(u).collect { |prefix, path_id| row_of(prefix, path_id, u.path_attribute) }
      end
      assert_equal(read, rows.collect { |r| r.reject { |k, _| k == 'extended_communities' } }, why)
    end
  end

  # A row as the octets say it, read back with the attribute classes
  # rather than with anything in bgp/gen. The extended communities are
  # left out because Gen and this would both spell them through
  # CommunityKeys, which would compare it with itself.
  def row_of(prefix, path_id, pa)
    r = { 'prefix' => prefix }
    r['path_id'] = path_id if path_id
    r['origin'] = pa[:origin].to_i
    r['as_path'] = pa[:as_path].segments.flat_map(&:as)
    nh = pa[:mp_reach] ? pa[:mp_reach].nexthops : pa[:next_hop].next_hop
    r['next_hop'] = nh
    r['med'] = pa[:multi_exit_disc].to_i if pa[:multi_exit_disc]
    r['local_pref'] = pa[:local_pref].to_i if pa[:local_pref]
    r['communities'] = pa[:communities].communities.split if pa[:communities]
    r['large_communities'] = pa[:large_communities].large_communities.split if pa[:large_communities]
    r
  end
end
