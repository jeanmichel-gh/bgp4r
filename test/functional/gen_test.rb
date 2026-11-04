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
    rows.sort_by { |r| [r['prefix'], r['path_id'].to_i] }
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
end
