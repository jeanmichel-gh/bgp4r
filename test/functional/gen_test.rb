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
require 'bgp4r'
require 'bgp/rib'
require 'bgp/gen'
require 'test/helpers/server'

# BGP::Gen over a real session: a bgp4r sender, a bgp4r receiver with a
# table attached, and the receiver's Adj-RIB-In compared with the spec's
# own `expected`. Then the withdrawals, and the Adj-RIB-In must be empty.
#
# The unit tests read the octets back with the parser in the same
# process. This is the one that says a peer reading them off a socket,
# with what its session negotiated, gets the routes the spec meant: the
# Adj-RIB-In is built by `PeerAdapter`, which knows nothing of bgp/gen.
#
# The comparison proves consistency and not correctness, which
# docs/route-generation.md section 10 says once for the whole design:
# `expected` comes from the code that sends.
#
# BGP:: names are written out in full, see Conventions in CLAUDE.md.
class GenFunctionalTest < Test::Unit::TestCase
  include BGP::TestHelpers

  SERVER_AS = 100
  CLIENT_AS = 200

  def teardown
    @caught = nil
    @rib.feed.stop if @rib
    @c.close if @c
    stop_server
  end

  # The table is attached before the session, as rib_feed_test.rb does,
  # so it sees every UPDATE. cap, when given, is advertised by both sides,
  # and so is the 4-octet AS capability unless as4 is false.
  def session(cap = nil, as4: true)
    @port = start_server(0, cap)
    @s.add_cap BGP::OPT_PARM::CAP::As4.new(SERVER_AS) if as4
    @rib = BGP::Rib.new(:local_as => SERVER_AS, :router_id => '0.0.0.1')
    @adapter = @rib.attach(@s)
    @c = BGP::Neighbor.new(4, CLIENT_AS, 180, '0.0.0.2', '127.0.0.1', '127.0.0.1')
    @c.add_cap cap if cap
    @c.add_cap BGP::OPT_PARM::CAP::As4.new(CLIENT_AS) if as4
    @c.start :port => @port
    assert(wait_for { @s.is_established? }, 'the session came up')
    assert_equal(as4, @c.session_info.as4byte?, 'the AS width is what was asked for')
  end

  def wait_for(timeout = 10)
    deadline = Time.now + timeout
    loop do
      return true if yield
      return false if Time.now > deadline
      sleep 0.02
    end
  end

  def adj_rib_in
    @rib.adj_rib_in(@adapter.peer)
  end

  # A route in the Adj-RIB-In as a row of `expected`'s shape, read with
  # the RIB's own accessors and the attribute classes.
  def row_of(route)
    pa = route.path_attribute
    r = { 'prefix' => route.prefix }
    r['path_id'] = route.path_id if route.path_id
    r['origin'] = route.origin
    r['as_path'] = route.as_path_segments.flat_map(&:as)
    r['next_hop'] = route.next_hop if route.next_hop
    r['med'] = route.med if route.med
    r['local_pref'] = route.local_pref if route.local_pref
    r['communities'] = pa[:communities].communities.split if pa[:communities]
    r['large_communities'] = pa[:large_communities].large_communities.split if pa[:large_communities]
    if pa[:extended_communities]
      r['extended_communities'] = pa[:extended_communities].to_hash[:extended_communities].collect do |h|
        BGP::Daemon::CommunityKeys.extended_community_text(h)
      end
    end
    r
  end

  def by_key(rows)
    rows.sort_by { |r| [r['prefix'], r['path_id'].to_i, r['rd'].to_s] }
  end

  # Announce, compare, withdraw, empty. Answers how many UPDATEs each way.
  def crosses(spec)
    g = BGP::Gen.new(spec)
    count = spec['count']
    g.updates.each { |u| @c.send_update u }
    sent = g.updates.count
    assert(wait_for { @rib.drain && adj_rib_in.routes.size == count },
           "#{adj_rib_in.routes.size} of #{count} routes arrived")
    want, got = by_key(g.expected.to_a), by_key(adj_rib_in.routes.collect { |r| row_of(r) })
    # One row at a time, so a failure prints the row that differs and
    # not two lists of thousands.
    assert_equal(want.size, got.size)
    want.zip(got).each { |w, r| assert_equal(w, r) unless w == r }
    g.withdrawals.each { |u| @c.send_update u }
    assert(wait_for { @rib.drain && adj_rib_in.routes.empty? },
           "#{adj_rib_in.routes.size} routes left after the withdrawals")
    [sent, g.withdrawals.count]
  end

  ATTRIBUTES = {
    'origin' => 1, 'as_path' => [CLIENT_AS, 65010, 4200000000], 'med' => 70, 'local_pref' => 300,
    'communities' => ['65000:1', 'no_export'], 'extended_communities' => ['route_target:65000:7'],
    'large_communities' => ['65000:1:1', '65000:1:2'],
  }

  def test_ipv4_unicast
    session
    n = crosses('start' => '10.0.0.0/24', 'count' => 5000,
                'attributes' => ATTRIBUTES.merge('next_hop' => '192.0.2.1'))
    assert_operator(n[0], :>, 1, 'more than one UPDATE, so the packing was on the wire')
  end

  def test_ipv4_unicast_per_update
    session
    assert_equal([10, 10], crosses('start' => '10.0.0.0/32', 'count' => 100, 'per_update' => 10,
                                   'attributes' => { 'next_hop' => '192.0.2.1', 'as_path' => [CLIENT_AS] }))
  end

  # No LOCAL_PREF here, and the reason is the receiver's and not bgp/gen's.
  # Table#import drops LOCAL_PREF from an external peer's route (RFC 4271
  # section 5.1.5) by encoding and re-parsing the route's whole attribute
  # set, and for IPv6 that set holds the MP_REACH_NLRI with every prefix
  # of the UPDATE. So each route costs as much as its message, and 3000
  # routes took 45 seconds. CLAUDE.md files it under Known issues.
  def test_ipv6_unicast
    session
    a = ATTRIBUTES.reject { |k, _| k == 'local_pref' }
    n = crosses('start' => '2001:db8::/64', 'count' => 3000,
                'attributes' => a.merge('next_hop' => '2001:db8::1'))
    assert_operator(n[0], :>, 1)
  end

  # `expected` is what the spec meant, and a session that did not
  # negotiate 4-octet AS numbers cannot carry one: the sender writes
  # AS_TRANS in its place (RFC 6793 section 4.2.2) and bgp4r adds no
  # AS4_PATH. So `expected` holds for a 4-octet session and this is the
  # one difference on a 2-octet one, measured rather than left to be
  # found out.
  def test_a_two_octet_session_carries_as_trans_where_expected_has_the_as
    session(nil, :as4 => false)
    g = BGP::Gen.new('start' => '10.0.0.0/24', 'count' => 3,
                     'attributes' => { 'next_hop' => '192.0.2.1', 'as_path' => [CLIENT_AS, 4200000000] })
    g.updates.each { |u| @c.send_update u }
    assert(wait_for { @rib.drain && adj_rib_in.routes.size == 3 })
    assert_equal([[CLIENT_AS, 4200000000]] * 3, g.expected.collect { |r| r['as_path'] })
    assert_equal([[CLIENT_AS, 23456]] * 3, adj_rib_in.routes.collect { |r| row_of(r)['as_path'] })
  end

  # RFC 7911: the receiver reads a Path Identifier before every prefix,
  # because the session negotiated it, and keys the Adj-RIB-In on it.
  def test_ipv4_unicast_with_a_path_id
    session(BGP::OPT_PARM::CAP::Add_path.new(:send_and_receive, 1, 1))
    assert(@s.session_info.recv_inet_unicast?, 'the receiver reads Path Identifiers')
    crosses('start' => '10.0.0.0/24', 'count' => 2000, 'path_id' => 77,
            'attributes' => { 'next_hop' => '192.0.2.1', 'as_path' => [CLIENT_AS] })
  end

  def test_ipv6_unicast_with_a_path_id
    session(BGP::OPT_PARM::CAP::Add_path.new(:send_and_receive, 2, 1))
    crosses('start' => '2001:db8::/48', 'count' => 2000, 'path_id' => 77,
            'attributes' => { 'next_hop' => '2001:db8::1', 'as_path' => [CLIENT_AS] })
  end

  # Phase 2: patterns over a real session. The receiver's Adj-RIB-In
  # holds one row per route, so a value that varies has to arrive on the
  # route it was meant for, not just somewhere in the feed.
  PATTERNS = {
    'origin' => { 'every' => { 'n' => 2, 'values' => [0, 1, 2] } },
    'as_path' => { 'prepend' => { 'as' => CLIENT_AS, 'count' => { 'cycle' => [1, 2, 3] }, 'path' => [65010] } },
    'med' => { 'random' => { 'min' => 0, 'max' => 5 } },
    'local_pref' => { 'step' => { 'start' => 100, 'by' => 10, 'wrap' => 160 } },
    'communities' => { 'count' => { 'base' => '65000:1', 'n' => { 'cycle' => [0, 1, 4] } } },
    'large_communities' => { 'cycle' => [['65000:1:1'], ['65000:2:2', '65000:2:3']] },
  }

  def test_ipv4_unicast_with_patterns_and_a_group
    session
    n = crosses('start' => '10.0.0.0/24', 'count' => 3000, 'group' => 7, 'seed' => 11,
                'attributes' => PATTERNS.merge('next_hop' => { 'step' => { 'start' => '192.0.2.1', 'by' => 1, 'wrap' => '192.0.2.9' } }))
    assert_operator(n[0], :>, 3000 / 7 / 4, 'the sets changed, so the messages did')
  end

  # IPv6 sends no LOCAL_PREF, for the reason test_ipv6_unicast gives.
  def test_ipv6_unicast_with_patterns
    session
    crosses('start' => '2001:db8::/64', 'count' => 1500, 'seed' => 12, 'group' => 5,
            'attributes' => PATTERNS.reject { |k, _| k == 'local_pref' }
                                    .merge('next_hop' => { 'cycle' => %w[2001:db8::1 2001:db8::2] }))
  end

  # A Path Identifier that changes every route keys the Adj-RIB-In on a
  # different identifier per prefix, which is the only place its value
  # is checked by something other than bgp4r's own encoder.
  def test_a_path_id_pattern
    session(BGP::OPT_PARM::CAP::Add_path.new(:send_and_receive, 1, 1))
    crosses('start' => '10.0.0.0/24', 'count' => 1000, 'seed' => 13, 'group' => 4,
            'path_id' => { 'random' => { 'min' => 1, 'max' => 2**32 - 1 } },
            'attributes' => { 'next_hop' => '192.0.2.1', 'as_path' => [CLIENT_AS] })
  end

  # ---- phase 4a: multicast and labelled ----------------------------------

  # Multicast goes in the table like unicast, since PeerAdapter reads
  # SAFI 1 and 2. IPv4 travels in MP_REACH_NLRI here, so this is the
  # test that says the receiver's MP path, and not the RFC 4271 fields,
  # gets IPv4 multicast.
  def test_ipv4_multicast
    session
    c = catcher
    n = crosses('family' => 'multicast', 'start' => '10.0.0.0/24', 'count' => 3000, 'group' => 3,
                'seed' => 21, 'attributes' => PATTERNS.reject { |k, _| k == 'local_pref' }
                                                      .merge('next_hop' => '192.0.2.1'))
    assert_operator(n[0], :>, 1)
    # The table keys on the prefix and cannot tell SAFI 2 from SAFI 1, so
    # the octets that crossed are what say this was multicast: every
    # UPDATE carried its routes in MP_REACH_NLRI or MP_UNREACH_NLRI under
    # SAFI 2 and none in RFC 4271's own fields.
    got = c.drain
    assert_operator(got.size, :>=, n.sum)
    safis = got.collect { |u| pa = u.path_attribute ; mp = pa[:mp_reach] || pa[:mp_unreach] ; mp && [mp.afi, mp.safi] }
    assert_equal([[1, 2]], safis.uniq)
    assert(got.none? { |u| u.nlri || u.withdrawn }, 'nothing in the RFC 4271 fields')
  end

  def test_ipv6_multicast
    session
    crosses('family' => 'multicast', 'start' => '2001:db8::/64', 'count' => 1500,
            'attributes' => { 'next_hop' => '2001:db8::1', 'as_path' => [CLIENT_AS], 'med' => 7 })
  end

  # Keeps every UPDATE the receiver parsed. A labelled route is not a
  # table's (CLAUDE.md, RIB phase 2 part 3: a label is part of the key
  # and a Route has nowhere to put one), so these are read off the wire.
  class Catcher
    attr_reader :updates
    def initialize ; @updates = Queue.new ; end
    def update(msg) ; @updates << msg if msg.is_a?(BGP::Update) ; end
    def drain ; a = [] ; a << @updates.shift while @updates.size > 0 ; a ; end
  end

  def catcher
    @caught ||= Catcher.new.tap { |c| @s.add_observer(c) }
  end

  # What a labelled UPDATE says, one row per route in `expected`'s shape,
  # and what a labelled withdrawal names.
  def labelled_rows(updates)
    updates.flat_map do |u|
      pa = u.path_attribute
      mp = pa && pa[:mp_reach]
      next [] unless mp
      attrs = { 'origin' => pa[:origin].to_i, 'as_path' => pa[:as_path].segments.flat_map(&:as),
                'next_hop' => mp.nexthops }
      attrs['med'] = pa[:multi_exit_disc].to_i if pa[:multi_exit_disc]
      if pa[:extended_communities]
        attrs['extended_communities'] = pa[:extended_communities].to_hash[:extended_communities].collect do |e|
          BGP::Daemon::CommunityKeys.extended_community_text(e)
        end
      end
      mp.nlris.collect do |n|
        h = n.to_hash
        r = { 'prefix' => h[:prefix] }
        r['path_id'] = h[:path_id] if h[:path_id]
        r['label'] = h[:label]
        r['rd'] = h[:rd].join(':') if h[:rd]
        r.merge(attrs)
      end
    end
  end

  def labelled_withdrawn(updates)
    updates.flat_map do |u|
      mp = u.path_attribute && u.path_attribute[:mp_unreach]
      mp ? mp.nlris.collect { |n| n.to_hash } : []
    end
  end

  # want maps a row of expected to what the octets should say, which is
  # the row itself except where the wire form differs on purpose.
  #
  # Positional and not a keyword, since a braceless spec with String
  # keys beside a keyword is read as keywords.
  def labelled_crosses(spec, want = ->(r) { r })
    c = catcher
    g = BGP::Gen.new(spec)
    sent = g.updates.count
    g.updates.each { |u| @c.send_update u }
    got = []
    assert(wait_for { got.concat(c.drain) ; got.size >= sent }, "#{got.size} of #{sent} UPDATEs arrived")
    assert_equal([], got.flat_map { |u| u.path_attribute.errors }, 'no protocol error')
    # The SAFI is stated here and not read from the generator, since a
    # generator sending the wrong one would agree with its own expected.
    safi = { 'labelled' => 4, 'vpn' => 128, 'vpn_multicast' => 129 }.fetch(spec['family'])
    assert_equal([safi], got.collect { |u| u.path_attribute[:mp_reach].safi }.uniq, 'the SAFI on the wire')
    @rows = labelled_rows(got)
    want_rows, got_rows = by_key(g.expected.collect(&want)), by_key(labelled_rows(got))
    assert_equal(want_rows.size, got_rows.size)
    want_rows.zip(got_rows).each { |w, r| assert_equal(w, r) unless w == r }
    back = g.withdrawals.count
    g.withdrawals.each { |u| @c.send_update u }
    gone = []
    assert(wait_for { gone.concat(c.drain) ; gone.size >= back }, "#{gone.size} of #{back} withdrawals arrived")
    w = labelled_withdrawn(gone)
    assert_equal(g.expected.collect { |r| [r['rd'], r['prefix']] },
                 w.collect { |h| [h[:rd] && h[:rd].join(':'), h[:prefix]] })
    assert_equal(['800000'], w.collect { |h| h[:compatibility] }.uniq, 'RFC 8277 section 2.4')
    [sent, back]
  end

  def test_ipv4_labelled
    session
    n = labelled_crosses('family' => 'labelled', 'start' => '10.0.0.0/24', 'count' => 2000,
                         'label' => { 'step' => { 'start' => 16, 'by' => 1, 'wrap' => 1000 } },
                         'attributes' => { 'next_hop' => '192.0.2.1', 'as_path' => [CLIENT_AS],
                                           'med' => { 'cycle' => [1, 2] } }, 'group' => 50)
    assert_operator(n[0], :>, 1)
  end

  def test_ipv6_labelled
    session
    labelled_crosses('family' => 'labelled', 'start' => '2001:db8::/64', 'count' => 1000, 'label' => 3,
                     'attributes' => { 'next_hop' => '2001:db8::1', 'as_path' => [CLIENT_AS] })
  end

  def test_labelled_with_a_path_id
    session(BGP::OPT_PARM::CAP::Add_path.new(:send_and_receive, 1, 4))
    labelled_crosses('family' => 'labelled', 'start' => '10.0.0.0/24', 'count' => 500, 'label' => 100,
                     'path_id' => { 'step' => { 'start' => 1, 'by' => 1 } },
                     'attributes' => { 'next_hop' => '192.0.2.1', 'as_path' => [CLIENT_AS] })
  end

  # ---- phase 4b: VPN, SAFI 128 and 129 -----------------------------------

  # Three VRFs carrying the same 700 prefixes, so the receiver reads 2100
  # routes whose prefixes repeat and whose RDs keep them apart, each VRF
  # with its own route target and so its own messages.
  def test_ipv4_vpn
    session
    n = labelled_crosses('family' => 'vpn', 'start' => '10.0.0.0/24', 'count' => 700, 'vrfs' => 3,
                         'rd' => '65000:1', 'route_target' => '65000:100',
                         'label' => { 'step' => { 'start' => 16, 'by' => 1, 'wrap' => 5000 } },
                         'attributes' => { 'next_hop' => '192.0.2.1', 'as_path' => [CLIENT_AS],
                                           'med' => { 'cycle' => [1, 2] } }, 'group' => 50)
    assert_operator(n[0], :>, 3)
    # Each VRF's route target, stated by hand rather than read from
    # expected: a generator that gave every VRF the first one's set would
    # agree with its own expected and pass the comparison above.
    by_rd = @rows.group_by { |r| r['rd'] }
    assert_equal(%w[65000:1 65000:2 65000:3], by_rd.keys.sort)
    by_rd.each do |rd, rows|
      v = rd.split(':').last.to_i
      assert_equal([["route_target:65000:#{99 + v}"]], rows.collect { |r| r['extended_communities'] }.uniq, rd)
    end
  end

  def test_ipv6_vpn
    session
    labelled_crosses('family' => 'vpn', 'start' => '2001:db8::/64', 'count' => 500, 'vrfs' => 2,
                     'rd' => '192.0.2.1:7', 'label' => 3,
                     'attributes' => { 'next_hop' => '2001:db8::1', 'as_path' => [CLIENT_AS] })
  end

  # RFC 4659 section 3.2.1.2: the IPv4 next hop of IPv6 VPN routes goes
  # out IPv4-mapped, and the receiver reads the mapped form back, where
  # expected keeps the address it was given.
  def test_ipv6_vpn_with_an_ipv4_next_hop
    session
    labelled_crosses({ 'family' => 'vpn', 'start' => '2001:db8::/64', 'count' => 200,
                       'rd' => '4200000000:1', 'label' => 100,
                       'attributes' => { 'next_hop' => '192.0.2.1', 'as_path' => [CLIENT_AS] } },
                     ->(r) { r.merge('next_hop' => '::ffff:192.0.2.1') })
  end

  def test_vpn_multicast
    session
    labelled_crosses('family' => 'vpn_multicast', 'start' => '10.0.0.0/24', 'count' => 300, 'vrfs' => 2,
                     'rd' => '4200000000:1', 'route_target' => '4200000000:9', 'label' => 100,
                     'attributes' => { 'next_hop' => '192.0.2.1', 'as_path' => [CLIENT_AS] })
  end

  def test_vpn_with_a_path_id
    session(BGP::OPT_PARM::CAP::Add_path.new(:send_and_receive, 1, 128))
    labelled_crosses('family' => 'vpn', 'start' => '10.0.0.0/24', 'count' => 300, 'vrfs' => 2, 'label' => 100,
                     'rd' => '65000:1', 'path_id' => { 'step' => { 'start' => 1, 'by' => 1 } },
                     'attributes' => { 'next_hop' => '192.0.2.1', 'as_path' => [CLIENT_AS] })
  end


  # ---- phase 4c: flow spec, SAFI 133 and 134 ------------------------------

  # What a flow spec UPDATE says, one row per rule in `expected`'s shape,
  # read with the component classes and not with anything in bgp/gen.
  def flow_rows(updates, key = :mp_reach)
    updates.flat_map do |u|
      pa = u.path_attribute
      mp = pa && pa[key]
      next [] unless mp
      attrs = { 'origin' => pa[:origin].to_i, 'as_path' => pa[:as_path].segments.flat_map(&:as) } if pa[:origin]
      if pa[:extended_communities]
        attrs['extended_communities'] = pa[:extended_communities].to_hash[:extended_communities].collect do |e|
          BGP::Daemon::CommunityKeys.extended_community_text(e)
        end
      end
      mp.nlris.collect do |n|
        h = n.to_hash
        d = h[:destination_prefix] || h[:destination_ipv6_prefix]
        r = { 'destination' => d.is_a?(Hash) ? d[:prefix] : d }
        src = h[:source_prefix] || h[:source_ipv6_prefix]
        r['source'] = src.is_a?(Hash) ? src[:prefix] : src if src
        proto = h[:ip_protocol] || h[:upper_layer_protocol]
        r['protocol'] = proto[0][1] if proto
        r['destination_port'] = h[:destination_port][0][1] if h[:destination_port]
        r['rd'] = h[:rd].join(':') if h[:rd]
        attrs ? r.merge(attrs) : r
      end
    end
  end

  def flow_key(r) ; [r['rd'].to_s, r['destination']] ; end

  # Announce, compare, withdraw, compare. The SAFI and the next hop
  # length are stated here and not read from the generator.
  def flow_crosses(spec)
    c = catcher
    g = BGP::Gen.new(spec)
    sent = g.updates.count
    g.updates.each { |u| @c.send_update u }
    got = []
    assert(wait_for { got.concat(c.drain) ; got.size >= sent }, "#{got.size} of #{sent} UPDATEs arrived")
    assert_equal([], got.flat_map { |u| u.path_attribute.errors + u.path_attribute.undecoded }, 'no protocol error')
    safi = { 'flow_spec' => 133, 'flow_spec_vpn' => 134 }.fetch(spec['family'])
    assert_equal([[safi, '']], got.collect { |u| mp = u.path_attribute[:mp_reach] ; [mp.safi, mp.nexthops] }.uniq,
                 'the SAFI, and RFC 8955 section 4\'s empty next hop')
    @rows = flow_rows(got)
    want_rows, got_rows = g.expected.to_a.sort_by { |r| flow_key(r) }, @rows.sort_by { |r| flow_key(r) }
    assert_equal(want_rows.size, got_rows.size)
    want_rows.zip(got_rows).each { |w, r| assert_equal(w, r) unless w == r }
    back = g.withdrawals.count
    g.withdrawals.each { |u| @c.send_update u }
    gone = []
    assert(wait_for { gone.concat(c.drain) ; gone.size >= back }, "#{gone.size} of #{back} withdrawals arrived")
    assert_equal(g.expected.collect { |r| r.slice('destination', 'source', 'protocol', 'destination_port', 'rd') },
                 flow_rows(gone, :mp_unreach))
    [sent, back]
  end

  # 1500 rules, so a feed of several messages, each matching a port
  # stepped per rule, with a rate that changes every 100 rules.
  def test_ipv4_flow_spec
    session
    n = flow_crosses('family' => 'flow_spec', 'start' => '10.0.0.0/24', 'count' => 1500,
                     'protocol' => { 'cycle' => [6, 17] }, 'source' => '192.0.2.0/24',
                     'destination_port' => { 'step' => { 'start' => 1, 'by' => 7, 'wrap' => 65535 } },
                     'rate' => { 'cycle' => [0, 125_000] }, 'marking' => 46, 'redirect' => '65000:100',
                     'group' => 100, 'attributes' => { 'as_path' => [CLIENT_AS] })
    assert_operator(n[0], :>=, 15)
    # The actions, stated by hand: a generator that put one group's rate
    # on every rule would agree with its own expected.
    rates = @rows.each_slice(100).collect { |s| s.collect { |r| r['extended_communities'] }.uniq }
    assert_equal(15, rates.size)
    rates.each_with_index do |r, i|
      assert_equal([["traffic_rate_bytes:0:#{[0, 125_000][i % 2]}.0", 'redirect:65000:100', 'traffic_marking:46']], r)
    end
  end

  def test_ipv6_flow_spec
    session
    flow_crosses('family' => 'flow_spec', 'start' => '2001:db8::/48', 'count' => 400, 'protocol' => 58,
                 'attributes' => { 'as_path' => [CLIENT_AS] })
  end

  def test_vpn_flow_spec
    session
    flow_crosses('family' => 'flow_spec_vpn', 'start' => '10.0.0.0/24', 'count' => 300, 'vrfs' => 3,
                 'rd' => '65000:1', 'route_target' => '65000:100', 'destination_port' => 443,
                 'attributes' => { 'as_path' => [CLIENT_AS] })
    by_rd = @rows.group_by { |r| r['rd'] }
    assert_equal(%w[65000:1 65000:2 65000:3], by_rd.keys.sort)
    by_rd.each do |rd, rows|
      v = rd.split(':').last.to_i
      assert_equal([["route_target:65000:#{99 + v}"]], rows.collect { |r| r['extended_communities'] }.uniq, rd)
    end
  end

  # ---- phase 4d: EVPN ---------------------------------------------------

  EVPN_KEYS = { :mac_ip_advertisement => 2, :inclusive_multicast => 3, :ip_prefix_route => 5 }

  # Rows read off the routes the far side parsed, with nothing from
  # bgp/gen: the route type's own hash, and the attributes beside it.
  def evpn_rows(updates, key = :mp_reach)
    updates.flat_map do |u|
      pa = u.path_attribute
      mp = pa && pa[key]
      next [] unless mp
      attrs = nil
      if pa[:origin]
        attrs = { 'origin' => pa[:origin].to_i, 'as_path' => pa[:as_path].segments.flat_map(&:as),
                  'next_hop' => mp.nexthops }
        if pa[:extended_communities]
          attrs['extended_communities'] = pa[:extended_communities].to_hash[:extended_communities].collect do |e|
            BGP::Daemon::CommunityKeys.extended_community_text(e)
          end
        end
        if (t = pa[:pmsi_tunnel])
          t = t.to_hash[:pmsi_tunnel]
          id = t[:identifier]
          id = IPAddr.new_ntoh([id].pack('H*')).to_s unless id.include?('.')
          attrs['pmsi'] = { 'tunnel_type' => t[:tunnel_type].to_s, 'label' => t[:label], 'identifier' => id }
        end
      end
      mp.nlris.collect do |n|
        k, v = n.to_hash.first
        r = { 'route_type' => EVPN_KEYS.fetch(k), 'rd' => v[:rd].join(':') }
        case r['route_type']
        when 2
          r['mac'] = v[:mac]
          r['ip'] = v[:ip] if v[:ip].is_a?(String)
          r['esi'] = v[:esi]
          r['label'] = v[:label1][:label]
        when 3
          r['originator'] = v[:ip]
        when 5
          r['prefix'] = v[:ip_prefix]
          r['gateway'] = v[:gateway]
          r['esi'] = v[:esi]
          r['label'] = v[:label]
        end
        r['ethernet_tag'] = v[:ethernet_tag_id]
        attrs ? r.merge(attrs) : r
      end
    end
  end

  def evpn_key(r) ; [r['rd'], r['mac'] || r['originator'] || r['prefix']] ; end

  # Announce, compare, withdraw, compare. The SAFI is stated here and
  # not read from the generator.
  def evpn_crosses(spec)
    c = catcher
    g = BGP::Gen.new(spec)
    sent = g.updates.count
    g.updates.each { |u| @c.send_update u }
    got = []
    assert(wait_for { got.concat(c.drain) ; got.size >= sent }, "#{got.size} of #{sent} UPDATEs arrived")
    assert_equal([], got.flat_map { |u| u.path_attribute.errors + u.path_attribute.undecoded }, 'no protocol error')
    assert_equal([[25, 70]], got.collect { |u| mp = u.path_attribute[:mp_reach] ; [mp.afi, mp.safi] }.uniq)
    @rows = evpn_rows(got)
    want_rows, got_rows = g.expected.to_a.sort_by { |r| evpn_key(r) }, @rows.sort_by { |r| evpn_key(r) }
    assert_equal(want_rows.size, got_rows.size)
    want_rows.zip(got_rows).each { |w, r| assert_equal(w, r) unless w == r }
    back = g.withdrawals.count
    g.withdrawals.each { |u| @c.send_update u }
    gone = []
    assert(wait_for { gone.concat(c.drain) ; gone.size >= back }, "#{gone.size} of #{back} withdrawals arrived")
    keys = %w[route_type rd mac ip originator prefix ethernet_tag]
    assert_equal(g.expected.collect { |r| r.slice(*keys) }, evpn_rows(gone, :mp_unreach).collect { |r| r.slice(*keys) })
    [sent, back]
  end

  # 2000 MACs with an IP each in two EVIs, a label stepped per route and
  # a MAC Mobility sequence number that changes every 100 routes.
  def test_evpn_mac_ip_routes
    session
    n = evpn_crosses('family' => 'evpn', 'route_type' => 2, 'start' => '00:11:22:00:00:00', 'count' => 1000,
                     'ip' => '10.0.0.1', 'label' => { 'step' => { 'start' => 16, 'by' => 1 } },
                     'rd' => '65000:1', 'vrfs' => 2, 'route_target' => '65000:100', 'group' => 100,
                     'mac_mobility' => { 'step' => { 'start' => 1, 'by' => 1 } },
                     'router_mac' => '00:00:5e:00:53:01',
                     'attributes' => { 'as_path' => [CLIENT_AS], 'next_hop' => '192.0.2.1' })
    assert_operator(n[0], :>=, 20)
    # Stated by hand: a generator that put one EVI's route target on
    # every route, or one group's sequence number on every group, would
    # agree with its own expected. The group runs on the route number
    # across both EVIs, as VPN's does, so the second EVI's MACs move
    # from sequence number 11.
    by_rd = @rows.group_by { |r| r['rd'] }
    assert_equal(%w[65000:1 65000:2], by_rd.keys.sort)
    by_rd.each do |rd, rows|
      v = rd.split(':').last.to_i
      rows.sort_by { |r| r['mac'] }.each_slice(100).with_index do |slice, k|
        assert_equal([["route_target:65000:#{99 + v}", "mac_mobility:#{k + 1 + 10 * (v - 1)}:false",
                       'router_mac:00:00:5e:00:53:01']], slice.collect { |r| r['extended_communities'] }.uniq)
      end
    end
    last = @rows.find { |r| r['rd'] == '65000:2' && r['mac'] == '00:11:22:00:03:e7' }
    assert_equal(['10.0.3.232', 16 + 1999], [last['ip'], last['label']])
  end

  # A PMSI Tunnel per PE, so one message per route, and an IPv6 next
  # hop, 16 octets under AFI 25 (RFC 7432 section 14).
  def test_evpn_inclusive_multicast_routes
    session
    n = evpn_crosses('family' => 'evpn', 'route_type' => 3, 'start' => '2001:db8::1', 'count' => 50,
                     'rd' => '65000:1', 'ethernet_tag' => 100, 'pmsi_label' => 10,
                     'attributes' => { 'as_path' => [CLIENT_AS], 'next_hop' => '2001:db8::ff' })
    assert_equal([50, 1], n)
    assert_equal({ 'tunnel_type' => 'ingress_replication', 'label' => 10, 'identifier' => '2001:db8::32' },
                 @rows.find { |r| r['originator'] == '2001:db8::32' }['pmsi'])
    assert_equal(['2001:db8::ff'], @rows.collect { |r| r['next_hop'] }.uniq)
  end

  def test_evpn_ip_prefix_routes
    session
    evpn_crosses('family' => 'evpn', 'route_type' => 5, 'start' => '10.1.0.0/24', 'count' => 1000,
                 'rd' => '192.0.2.1:5', 'gateway' => '10.0.0.254', 'label' => 500,
                 'attributes' => { 'as_path' => [CLIENT_AS], 'next_hop' => '192.0.2.1' })
    evpn_crosses('family' => 'evpn', 'route_type' => 5, 'start' => '2001:db8::/64', 'count' => 500,
                 'rd' => '65000:5', 'esi' => '00:00:00:00:00:00:00:00:00:07', 'label' => 500,
                 'attributes' => { 'as_path' => [CLIENT_AS], 'next_hop' => '2001:db8::1' })
    assert_equal(['00:00:00:00:00:00:00:00:00:07'], @rows.collect { |r| r['esi'] }.uniq)
    assert_equal(['::'], @rows.collect { |r| r['gateway'] }.uniq)
  end

end
