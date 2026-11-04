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
  # quick, since every message is parsed several times over. It is three
  # feeds per family, which the corpus deals out in turn, so a family
  # added to FAMILIES needs three more.
  SEEDS = Integer(ENV.fetch('GEN_SEEDS', 21))

  def test_the_generators_are_the_ones_built
    assert_equal(%w[unicast multicast labelled vpn vpn_multicast flow_spec flow_spec_vpn], BGP::Gen::GENERATORS.keys)
    assert_equal(BGP::Gen::Flow_rules, BGP::Gen::GENERATORS['flow_spec'])
    assert_equal(BGP::Gen::Flow_rules_vpn, BGP::Gen::GENERATORS['flow_spec_vpn'])
    assert_equal(BGP::Gen::Unicast, BGP::Gen::GENERATORS['unicast'])
    assert_equal(BGP::Gen::Multicast, BGP::Gen::GENERATORS['multicast'])
    assert_equal(BGP::Gen::Labelled, BGP::Gen::GENERATORS['labelled'])
    assert_equal(BGP::Gen::Vpn, BGP::Gen::GENERATORS['vpn'])
    assert_equal(BGP::Gen::Vpn_multicast, BGP::Gen::GENERATORS['vpn_multicast'])
  end

  # A family key given to a family that has no such field is refused by
  # name, so a label on a unicast spec is not dropped in silence.
  def test_a_family_key_on_another_family_is_refused
    %w[unicast multicast].each do |family|
      e = assert_raise(BGP::Gen::SpecError) do
        BGP::Gen.new('family' => family, 'start' => '10.0.0.0/8', 'count' => 1, 'label' => 16)
      end
      assert_match(/'label' is for labelled, vpn, vpn_multicast and not for '#{family}'/, e.message)
    end
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
  def random_spec(r, family = nil)
    v6 = r.rand(2) == 1
    mlen = v6 ? r.rand(16..128) : r.rand(8..32)
    start = v6 ? "2001:db8::/#{mlen}" : "10.0.0.0/#{mlen}"
    # How many prefixes fit before leaving 10.0.0.0/8 or 2001::/16.
    room = v6 ? 2**(mlen - 16) : 2**(mlen - 8)
    nh = v6 ? '2001:db8::1' : '192.0.2.1'
    a = { 'origin' => r.rand(3), 'next_hop' => nh,
          'as_path' => Array.new(r.rand(0..6)) { r.rand(1..2**32 - 1) } }
    a['med'] = r.rand(2**32) if r.rand(2) == 1
    a['local_pref'] = r.rand(2**32) if r.rand(2) == 1
    a['communities'] = Array.new(r.rand(1..40)) { "#{r.rand(65536)}:#{r.rand(65536)}" } if r.rand(2) == 1
    a['large_communities'] = Array.new(r.rand(1..20)) { "#{r.rand(2**32)}:1:#{r.rand(9)}" } if r.rand(2) == 1
    a['extended_communities'] = ["route_target:#{r.rand(65536)}:#{r.rand(2**32)}"] if r.rand(2) == 1
    # Phase 2: about half the specs vary something, each kind of pattern
    # on the value it suits.
    patterns = {
      'med' => { 'cycle' => [r.rand(100), r.rand(100), r.rand(100)] },
      'local_pref' => { 'step' => { 'start' => 100, 'by' => r.rand(1..50), 'wrap' => 400 } },
      'origin' => { 'every' => { 'n' => r.rand(1..5), 'values' => [0, 1, 2] } },
      'next_hop' => { 'random' => v6 ? { 'min' => '2001:db8::1', 'max' => '2001:db8::ff' } :
                                       { 'min' => '192.0.2.1', 'max' => '192.0.2.254' } },
      'as_path' => (r.rand(2) == 1 ?
        { 'prepend' => { 'as' => 65010, 'count' => { 'random' => { 'min' => 0, 'max' => 5 } }, 'path' => [65020] } } :
        { 'length' => { 'count' => { 'cycle' => [1, 3] }, 'min' => 64512, 'max' => 65534 } }),
      'communities' => { 'count' => { 'base' => '65000:1', 'n' => { 'cycle' => [0, 2, 30] } } },
    }
    patterns.each { |k, v| a[k] = v if r.rand(3) == 0 }
    # Drawn even when given, so the draws after it are the same either way.
    pick = FAMILIES[r.rand(FAMILIES.size)]
    family ||= pick
    # RFC 8955 section 4: a flow spec rule has no next hop.
    a.delete('next_hop') if FLOW.include?(family)
    s = { 'family' => family, 'start' => start, 'count' => r.rand(1..[room, 300].min), 'attributes' => a }
    s['per_update'] = r.rand(1..300) if r.rand(2) == 1
    # No Path Identifier on a flow spec feed: validation.rb walks a rule
    # without knowing add-path was negotiated, so it misreads the four
    # octets in front and the strict read below raises. That is a gap in
    # the receive checks and not in the generator; flow_rules_test.rb
    # sends one and reads it back leniently.
    case FLOW.include?(family) ? 0 : r.rand(3)
    when 1 then s['path_id'] = r.rand(2**32)
    when 2 then s['path_id'] = { 'step' => { 'start' => r.rand(1000), 'by' => 1 } }
    end
    s['group'] = r.rand(1..20) if r.rand(2) == 1
    if LABELLED.include?(family)
      s['label'] = r.rand(2) == 1 ? r.rand(2**20) :
        { 'step' => { 'start' => r.rand(16..1000), 'by' => r.rand(1..9), 'wrap' => 2**20 - 1 } }
    end
    # Phase 4b: the same range in up to four VRFs, under an RD of each of
    # RFC 4364 section 4.2's three types, and sometimes a route target.
    # Phase 4c: the match components and actions, each sometimes.
    if FLOW.include?(family)
      s['protocol'] = [r.rand(256), { 'cycle' => [6, 17] }][r.rand(2)] if r.rand(2) == 1
      s['destination_port'] = [r.rand(65536), { 'step' => { 'start' => r.rand(1000), 'by' => r.rand(1..300),
                                                           'wrap' => 65535 } }][r.rand(2)] if r.rand(2) == 1
      s['source'] = v6 ? '2001:db8:ffff::/48' : '192.0.2.0/24' if r.rand(2) == 1
      s['rate'] = [r.rand(2**24), { 'cycle' => [0, 1000, 125_000] }][r.rand(2)] if r.rand(2) == 1
      s['marking'] = { 'every' => { 'n' => r.rand(1..5), 'values' => [0, 10, 46] } } if r.rand(2) == 1
      s['redirect'] = "65000:#{r.rand(100)}" if r.rand(3) == 0
    end
    if VPN.include?(family)
      admin = [r.rand(65536), "192.0.2.#{r.rand(1..254)}", r.rand(65536..2**32 - 1)][r.rand(3)]
      s['rd'] = "#{admin}:#{r.rand(1000)}"
      s['vrfs'] = r.rand(1..4) if r.rand(2) == 1
      s['route_target'] = "#{admin}:#{r.rand(1000)}" if r.rand(2) == 1
    end
    s['seed'] = r.rand(2**31)
    s
  end

  FAMILIES = %w[unicast multicast labelled vpn vpn_multicast flow_spec flow_spec_vpn]
  LABELLED = %w[labelled vpn vpn_multicast]
  FLOW = %w[flow_spec flow_spec_vpn]
  VPN = %w[vpn vpn_multicast flow_spec_vpn]
  SAFI = { 'unicast' => 1, 'multicast' => 2, 'labelled' => 4, 'vpn' => 128, 'vpn_multicast' => 129,
           'flow_spec' => 133, 'flow_spec_vpn' => 134 }

  # How many routes a spec makes: count, once per VRF.
  def self.total(spec) ; spec['count'] * (spec['vrfs'] || 1) ; end

  def info_for(spec)
    spec['path_id'] ? AddPath.new : PLAIN
  end

  def keys_of(u)
    list = u.nlri || u.withdrawn
    list = list.nlris if list.respond_to?(:nlris)
    mp = u.path_attribute && (u.path_attribute[:mp_reach] || u.path_attribute[:mp_unreach])
    list = mp.nlris if mp && (list.nil? || list.empty?)
    # A VPN route's key has its RD too, since every VRF carries the same
    # prefixes (RFC 4364 section 4.1).
    list.collect do |n|
      if n.is_a?(BGP::Flow_spec)
        # A rule's key is its components and its RD, RFC 8955 section 8.
        h = n.to_hash
        rd = h.delete(:rd)
        next [h, n.path_id, rd && rd.join(':')]
      end
      next [n.to_s.sub(/\AID=\d+, /, ''), n.path_id, nil] unless n.is_a?(BGP::Labeled)
      h = n.to_hash
      [h[:prefix], n.path_id, h[:rd] && h[:rd].join(':')]
    end
  end

  def first_nlri_size(u)
    pa = u.path_attribute
    (pa[:mp_reach] || pa[:mp_unreach]).nlris.first.encode.bytesize
  end

  # The labels of a message's NLRIs, in order: the label of an
  # announcement and the Compatibility field of a withdrawal.
  def labels_of(u)
    pa = u.path_attribute
    mp = pa && (pa[:mp_reach] || pa[:mp_unreach])
    return [] unless mp
    mp.nlris.collect { |n| n.is_a?(BGP::Labeled) ? (n.to_hash[:label] || n.to_hash[:compatibility]) : nil }
  end

  # A message's attributes without its prefixes, which is what two
  # messages must share to have been one. The next hop of an IPv6 route
  # lives inside MP_REACH_NLRI, so it is kept: a sweep of 200 seeds
  # found that leaving the attribute out whole read two messages with
  # different next hops as one set and reported every one as not full.
  def attributes_of(m)
    pa = m.path_attribute
    return nil unless pa
    pa.attributes.collect do |a|
      case a
      when BGP::Mp_reach then a.nexthops
      when BGP::Mp_unreach then nil
      else a.to_shex
      end
    end
  end

  # One generated feed: the spec, its messages encoded once on a 4-octet
  # session, and each message parsed once. Built once for the whole file,
  # since every property below reads the same feeds and parsing is where
  # the time goes.
  Sample = Struct.new(:spec, :why, :gen, :updates, :withdrawals)
  Msg = Struct.new(:object, :octets, :parsed)

  def self.corpus
    @corpus ||= SEEDS.times.collect do |seed|
      spec = new('corpus').random_spec(Random.new(seed), FAMILIES[seed % FAMILIES.size])
      g = BGP::Gen.new(spec)
      info = spec['path_id'] ? AddPath.new : PLAIN
      read = lambda do |m|
        o = m.encode(AS4)
        Msg.new(m, o, BGP::Update.new(o.dup.is_packed, info))
      end
      Sample.new(spec, "seed #{seed}: #{spec.inspect}", g,
                 g.updates.collect(&read), g.withdrawals.collect(&read))
    end
  end

  def each_sample(&block) ; self.class.corpus.each(&block) ; end

  # Every message is within RFC 4271 section 4's limit on either session,
  # holds no more than per_update routes, and each but the last is full:
  # per_update reached, the next message's attributes differ, or one
  # more route would not fit. Problems are gathered and asserted once per
  # feed, so a failure names every message at fault and the assertion
  # count says how many feeds were checked.
  def test_every_message_fits_and_each_is_full
    each_sample do |x|
      spec = x.spec
      mlen = spec['start'].split('/').last.to_i
      flow = FLOW.include?(spec['family'])
      route = 1 + (mlen + 7) / 8 + (spec['path_id'] ? 4 : 0) + (spec['label'] ? 3 : 0) + (spec['rd'] ? 8 : 0)
      problems = []
      [x.updates, x.withdrawals].each do |msgs|
        msgs.each_with_index do |m, i|
          size = m.octets.bytesize
          problems << "message #{i} is #{size} octets" if size > 4096
          problems << "message #{i} is longer on a 2-octet session" if m.object.encode(AS2).bytesize > size
          routes = keys_of(m.parsed).size
          problems << "message #{i} has #{routes} routes" if spec['per_update'] && routes > spec['per_update']
          next if i == msgs.size - 1
          # A rule is as long as its components, so the one that did not
          # fit is the next message's first, measured.
          route = first_nlri_size(msgs[i + 1].parsed) if flow
          full = routes == spec['per_update'] || attributes_of(m.object) != attributes_of(msgs[i + 1].object)
          problems << "message #{i} has room left" unless full || size + route > 4096
        end
      end
      assert_equal([], problems, x.why)
    end
  end

  def test_every_message_round_trips
    each_sample do |x|
      bad = (x.updates + x.withdrawals).each_with_index.reject { |m, _| m.parsed.encode(AS4) == m.octets }
      assert_equal([], bad.collect(&:last), x.why)
    end
  end

  # validation.rb reports nothing on valid generated traffic. The info is
  # strict, so a finding raises at parse; errors and undecoded are
  # asserted as well, so a lenient read would not pass for the wrong
  # reason.
  def test_validation_reports_nothing
    each_sample do |x|
      found = x.updates.flat_map { |m| m.parsed.path_attribute.errors + m.parsed.path_attribute.undecoded }
      assert_equal([], found, x.why)
    end
  end

  def test_withdrawals_cover_exactly_what_was_announced
    each_sample do |x|
      sent = x.updates.flat_map { |m| keys_of(m.parsed) }
      gone = x.withdrawals.flat_map { |m| keys_of(m.parsed) }
      assert_equal(self.class.total(x.spec), sent.size, x.why)
      assert_equal(sent.uniq.size, sent.size, "a route announced twice; #{x.why}")
      assert_equal(sent, gone, x.why)
    end
  end

  # Each family goes where its RFC puts it: IPv4 unicast in RFC 4271's
  # own fields, everything else in MP_REACH_NLRI and MP_UNREACH_NLRI
  # under its own SAFI (RFC 4760). A labelled withdrawal carries the RFC
  # 8277 section 2.4 Compatibility field, 0x800000, and never the label.
  def test_each_family_goes_in_its_own_place
    each_sample do |x|
      family = x.spec['family']
      classic = family == 'unicast' && x.gen.afi == 1
      problems = []
      (x.updates + x.withdrawals).each_with_index do |m, i|
        pa = m.parsed.path_attribute
        mp = pa && (pa[:mp_reach] || pa[:mp_unreach])
        if classic
          problems << "message #{i} uses an MP attribute" if mp
        elsif mp.nil? || [mp.afi, mp.safi] != [x.gen.afi, SAFI[family]] || m.parsed.nlri
          problems << "message #{i} is not in MP_REACH or MP_UNREACH for its family"
        end
      end
      if LABELLED.include?(family)
        compat = x.withdrawals.flat_map { |m| labels_of(m.parsed) }.uniq
        problems << "withdrawals carry #{compat.inspect}" unless compat == ['800000']
        problems << 'an announcement has no label' if x.updates.flat_map { |m| labels_of(m.parsed) }.include?(nil)
      end
      assert_equal([], problems, x.why)
    end
  end

  # expected has count rows, in the order sent, and each says what the
  # UPDATE carrying it says.
  def test_expected_is_what_was_sent
    each_sample do |x|
      rows = x.gen.expected.to_a
      assert_equal(self.class.total(x.spec), rows.size, x.why)
      assert_equal(self.class.total(x.spec), x.gen.expected.size, x.why)
      read = x.updates.flat_map do |m|
        keys_of(m.parsed).collect { |key| row_of(*key, m.parsed.path_attribute) }
      end
      assert_equal(read, rows.collect { |r| r.reject { |k, _| k == 'extended_communities' } }, x.why)
    end
  end

  # The corpus has to exercise what it claims to. Without this a change
  # to random_spec could leave every feed unvaried and every property
  # above passing on phase 1's traffic.
  def test_the_corpus_varies_attributes_groups_and_path_ids
    specs = self.class.corpus.collect(&:spec)
    varied = specs.count { |sp| sp['attributes'].values.any? { |v| v.is_a?(Hash) } }
    assert_operator(varied, :>=, SEEDS / 4, 'feeds with a pattern')
    assert_operator(specs.count { |sp| sp['group'] }, :>=, 3, 'feeds with a group')
    assert_operator(specs.count { |sp| sp['path_id'].is_a?(Hash) }, :>=, 2, 'feeds with a path_id pattern')
    FAMILIES.each do |f|
      assert_operator(specs.count { |sp| sp['family'] == f }, :>=, 3, "feeds of #{f}")
    end
    assert_operator(specs.count { |sp| sp['vrfs'].to_i > 1 }, :>=, 1, 'feeds in more than one VRF')
    assert_operator(specs.count { |sp| sp['route_target'] }, :>=, 1, 'feeds with a route target')
    assert_operator(specs.count { |sp| sp['label'].is_a?(Hash) }, :>=, 1, 'feeds with a label pattern')
    %w[protocol destination_port source rate marking].each do |k|
      assert_operator(specs.count { |sp| sp[k] }, :>=, 1, "flow spec feeds with #{k}")
    end
    runs = self.class.corpus.collect { |x| x.updates.size }
    assert_operator(runs.max, :>, 20, 'some feed split into many messages')
  end

  # A row as the octets say it, read back with the attribute classes
  # rather than with anything in bgp/gen. The extended communities are
  # left out because Gen and this would both spell them through
  # CommunityKeys, which would compare it with itself.
  def row_of(prefix, path_id, rd, pa)
    return flow_row_of(prefix, path_id, rd, pa) if prefix.is_a?(Hash)
    r = { 'prefix' => prefix }
    r['path_id'] = path_id if path_id
    if pa[:mp_reach] && [4, 128, 129].include?(pa[:mp_reach].safi)
      h = pa[:mp_reach].nlris.collect(&:to_hash).find do |n|
        [n[:prefix], n[:path_id], n[:rd] && n[:rd].join(':')] == [prefix, path_id, rd]
      end
      r['label'] = h[:label]
      r['rd'] = rd if rd
    end
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

  # A flow spec row, read off the rule's components: one eq match each,
  # which is all bgp/gen writes.
  def flow_row_of(h, path_id, rd, pa)
    r = {}
    d = h[:destination_prefix] || h[:destination_ipv6_prefix]
    r['destination'] = d.is_a?(Hash) ? d[:prefix] : d
    src = h[:source_prefix] || h[:source_ipv6_prefix]
    r['source'] = src.is_a?(Hash) ? src[:prefix] : src if src
    proto = h[:ip_protocol] || h[:upper_layer_protocol]
    r['protocol'] = proto.first.last if proto
    r['destination_port'] = h[:destination_port].first.last if h[:destination_port]
    r['path_id'] = path_id if path_id
    r['rd'] = rd if rd
    r['origin'] = pa[:origin].to_i
    r['as_path'] = pa[:as_path].segments.flat_map(&:as)
    r['med'] = pa[:multi_exit_disc].to_i if pa[:multi_exit_disc]
    r['local_pref'] = pa[:local_pref].to_i if pa[:local_pref]
    r['communities'] = pa[:communities].communities.split if pa[:communities]
    r['large_communities'] = pa[:large_communities].large_communities.split if pa[:large_communities]
    r
  end
end
