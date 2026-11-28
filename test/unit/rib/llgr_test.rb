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
require 'bgp/rib'

# RFC 9494 in the table: the LLGR period's mark and community, NO_LLGR,
# the least preferred step and the export rule.
# docs/design/bgp-operations.md section 4, pull request 4a.
class TestBgpRibLlgr < Test::Unit::TestCase
  include BGP
  include BGP::Rib

  LOCAL_AS = 65_001
  E1 = Peer.new(address: '10.0.0.2', remote_as: 65_002, router_id: '2.2.2.2', local_as: LOCAL_AS)
  E2 = Peer.new(address: '10.0.0.3', remote_as: 65_003, router_id: '3.3.3.3', local_as: LOCAL_AS)
  I1 = Peer.new(address: '10.0.0.4', remote_as: LOCAL_AS, router_id: '4.4.4.4', local_as: LOCAL_AS)

  def route(peer, prefix = '10.1.0.0/16', communities: nil, local_pref: nil)
    attrs = [Origin.new(0), Next_hop.new(peer.address), As_path.new(*(peer.ebgp? ? [peer.remote_as] : []))]
    attrs << Local_pref.new(local_pref) if local_pref
    attrs << Communities.new(*communities) if communities
    Route.new(prefix, Path_attribute.new(*attrs), peer)
  end

  # Least preferred: LLGR_STALE from E1, the peer helped.
  LEAST = ->(r) { !r.local? && Llgr.stale?(r.path_attribute) && r.peer.address == '10.0.0.2' }

  def setup
    @rib = BGP::Rib.new(local_as: LOCAL_AS, router_id: '1.1.1.1')
    @rib.llgr = LEAST
  end

  def test_the_communities
    pa = route(E1).path_attribute
    assert_false(Llgr.stale?(pa))
    assert_true(Llgr.stale?(Llgr.attach(pa)))
    assert_false(Llgr.stale?(pa), 'a copy')
    twice = Llgr.attach(Llgr.attach(route(E1, communities: ['65001:1']).path_attribute))
    assert_equal('65001:1 65535:6', twice[Communities].communities, 'once, beside what was there')
    assert_true(Llgr.no_llgr?(route(E1, communities: [:no_llgr]).path_attribute))
    assert_false(Llgr.no_llgr?(nil))
  end

  # Section 4.2: the stale routes of the family carry LLGR_STALE, a
  # NO_LLGR route goes, a fresh route is left alone, and the other
  # family too.
  def test_the_llgr_period_begins
    @rib.announce(route(E1, '10.1.0.0/16'))
    @rib.announce(route(E1, '10.2.0.0/16', communities: [:no_llgr]))
    @rib.announce(route(E1, '2001:db8::/32'))
    @rib.peer_down(E1, [[1, 1], [2, 1]])
    @rib.announce(route(E1, '10.3.0.0/16'))
    assert_equal([1, 1], @rib.llgr_stale('10.0.0.2', 1))
    assert_equal(Llgr::MARK, @rib.stale(E1, '10.1.0.0/16'))
    assert_true(Llgr.stale?(@rib.best('10.1.0.0/16').path_attribute), 'in the Loc-RIB too')
    assert_nil(@rib.best('10.2.0.0/16'), 'NO_LLGR: removed')
    assert_false(Llgr.stale?(@rib.best('10.3.0.0/16').path_attribute), 'fresh')
    assert_nil(@rib.stale(E1, '10.3.0.0/16'))
    assert_equal('restart', @rib.stale(E1, '2001:db8::/32'), 'IPv6 still in its Restart Time')
    assert_equal([1, 0], @rib.llgr_stale('10.0.0.2', 2))
    assert_equal([0, 0], @rib.llgr_stale('10.0.0.9', 1), 'nobody')
  end

  # Section 4.4: least preferred loses to any route that is not, whatever
  # the LOCAL_PREF.
  def test_least_preferred
    @rib.announce(route(I1, local_pref: 50))
    @rib.announce(route(E1))
    assert_same(E1, @rib.best('10.1.0.0/16').peer)
    @rib.peer_down(E1, [[1, 1]])
    changes = []
    @rib.on_change { |c| changes << c }
    @rib.llgr_stale('10.0.0.2', 1)
    assert_same(I1, @rib.best('10.1.0.0/16').peer)
    assert_equal([:replaced], changes.collect(&:type), 'the Router sends what changed')
    assert_equal(:llgr_stale, @rib.result('10.1.0.0/16').reason)
    assert_same(E1, @rib.candidates('10.1.0.0/16').find { |r| r.peer == E1 }.peer)
  end

  # "When performing route selection between two routes when both are
  # least preferred, normal tiebreaking applies"; and LLGR_STALE from a
  # peer not helped is not least preferred (section 4.3).
  def test_between_two
    d = Decision.new(local_as: LOCAL_AS, router_id: '1.1.1.1', llgr: ->(_) { true })
    a, b = route(E1, local_pref: 200), route(E2, local_pref: 100)
    assert_equal([a, :local_pref], d.best([a, b]).then { |r| [r.best, r.reason] })
    plain = route(E2, communities: [:llgr_stale])
    @rib.announce(route(I1, local_pref: 50))
    @rib.announce(plain)
    assert_same(plain, @rib.best('10.1.0.0/16'), 'E2 is not a peer we help')
  end

  # Section 4.2: at a second restart a route in its LLGR period keeps
  # that mark.
  def test_a_second_restart_keeps_the_mark
    @rib.announce(route(E1))
    @rib.peer_down(E1, [[1, 1]])
    @rib.llgr_stale('10.0.0.2', 1)
    @rib.peer_down(E1, [[1, 1]])
    assert_equal(Llgr::MARK, @rib.stale(E1, '10.1.0.0/16'))
    @rib.announce(route(E1, '10.9.0.0/16'))
    @rib.peer_down(E1, [[1, 1]])
    assert_equal('restart', @rib.stale(E1, '10.9.0.0/16'))
  end

  # The rows: stale long_lived and llgr_stale, and the reason in words.
  def test_the_rows
    @rib.announce(route(I1, local_pref: 50))
    @rib.announce(route(E2, '10.5.0.0/16', communities: [:llgr_stale]))
    @rib.announce(route(E1))
    @rib.peer_down(E1, [[1, 1]])
    @rib.llgr_stale('10.0.0.2', 1)
    rows = @rib.view.rib('10.1.0.0/16')
    lost = rows.first[:paths].find { |p| p[:from] == '10.0.0.2' }
    assert_equal(['long_lived', true, :llgr_stale], lost.values_at(:stale, :llgr_stale, :lost_at))
    assert_equal('LLGR_STALE, where another path is not (RFC 9494 section 4.4)', lost[:reason])
    received = @rib.view.rib('10.5.0.0/16').first[:paths].first
    assert_equal([nil, true], received.values_at(:stale, :llgr_stale), 'received with it')
    assert_false(rows.first[:paths].find { |p| p[:from] == '10.0.0.4' }.key?(:llgr_stale))
  end

  Policy = Struct.new(:capable) do
    def stale?(route) ; LEAST.call(route) ; end
    def capable?(address) ; capable.include?(address) ; end
  end

  # Section 4.3: "SHOULD NOT be advertised to any neighbor from which the
  # Long-Lived Graceful Restart Capability has not been received",
  # internal or external.
  def test_export
    x = Export.new(local_as: LOCAL_AS, router_id: '1.1.1.1', llgr: Policy.new(['10.0.0.3']))
    stale = route(E1, communities: [:llgr_stale])
    sent = x.for(stale, E2, :next_hop => '10.0.0.1')
    assert_true(sent.advertise?)
    assert_true(Llgr.stale?(sent.path_attribute), 'section 4.3: "MUST NOT be removed"')
    assert_equal(:llgr_stale, x.for(stale, I1, :next_hop => '10.0.0.1').reason)
    assert_true(x.for(route(E1), I1, :next_hop => '10.0.0.1').advertise?, 'a fresh route')
    assert_true(x.for(route(E2, communities: [:llgr_stale]), I1, :next_hop => '10.0.0.1').advertise?, 'not a peer we help')
    plain = Export.new(local_as: LOCAL_AS, router_id: '1.1.1.1')
    assert_true(plain.for(stale, I1, :next_hop => '10.0.0.1').advertise?, 'no llgr: nothing changes')
    assert_include(Export::REFUSALS, :llgr_stale)
  end
end
