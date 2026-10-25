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

class TestBgpRibTable < Test::Unit::TestCase
  include BGP
  include BGP::Rib

  LOCAL_AS = 65001
  E1 = Peer.new(address: '10.0.0.2', remote_as: 65002, router_id: '2.2.2.2', local_as: LOCAL_AS)
  E2 = Peer.new(address: '10.0.0.3', remote_as: 65003, router_id: '3.3.3.3', local_as: LOCAL_AS)
  I1 = Peer.new(address: '10.0.0.4', remote_as: LOCAL_AS, router_id: '4.4.4.4', local_as: LOCAL_AS)

  def route(peer, prefix='10.1.0.0/16', local_pref: nil, as_path: nil, med: nil, path_id: nil)
    attrs = [Origin.new(0), Next_hop.new(peer.address)]
    attrs << As_path.new(*(as_path || (peer.ebgp? ? [peer.remote_as] : [])))
    attrs << Local_pref.new(local_pref) if local_pref
    attrs << Multi_exit_disc.new(med) if med
    Route.new(prefix, Path_attribute.new(*attrs), peer, path_id: path_id)
  end

  def setup
    @rib = BGP::Rib.new(local_as: LOCAL_AS, router_id: '1.1.1.1')
    @changes = []
    @rib.on_change { |c| @changes << c }
  end

  def test_shortcut_builds_a_table
    assert_kind_of(Table, @rib)
    assert_equal(LOCAL_AS, @rib.local_as)
    assert_equal('1.1.1.1', @rib.router_id)
  end

  def test_announce_withdraw_and_fallback
    a, b = route(E1), route(E2)
    assert_equal([:added], @rib.announce(a).map(&:type))
    assert_equal([], @rib.announce(b), 'E1 still wins on router ID')
    assert_same(a, @rib.best('10.1.0.0/16'))
    changes = @rib.withdraw(E1, '10.1.0.0/16')
    assert_equal([[:replaced, a, b]], changes.map { |c| [c.type, c.old, c.new] })
    assert_equal([:withdrawn], @rib.withdraw(E2, '10.1.0.0/16').map(&:type))
    assert_equal([:added, :replaced, :withdrawn], @changes.map(&:type), 'listeners see the same changes')
  end

  def test_withdraw_unknown_changes_nothing
    assert_equal([], @rib.withdraw(E1, '10.1.0.0/16'))
    assert_equal([], @changes)
  end

  def test_peer_down_falls_back_on_every_prefix
    %w[10.1.0.0/16 10.2.0.0/16].each do |p|
      @rib.announce(route(E1, p))
      @rib.announce(route(E2, p))
    end
    @rib.announce(route(E1, '10.3.0.0/16'))
    changes = @rib.peer_down(E1)
    assert_equal({ '10.1.0.0/16' => :replaced, '10.2.0.0/16' => :replaced, '10.3.0.0/16' => :withdrawn },
                 changes.to_h { |c| [c.prefix, c.type] })
    assert @rib.adj_rib_in(E1).empty?
    assert_equal([E2, E2], %w[10.1.0.0/16 10.2.0.0/16].map { |p| @rib.best(p).peer })
    assert_equal([], @rib.peer_down(E1), 'twice is harmless')
  end

  def test_local_pref_from_ebgp_is_ignored
    # RFC 4271 section 5.1.5. With it, E2 would win on LOCAL_PREF.
    @rib.announce(route(E1))
    @rib.announce(route(E2, local_pref: 500))
    assert_same(E1, @rib.best('10.1.0.0/16').peer)
    imported = @rib.candidates('10.1.0.0/16').find { |r| r.peer == E2 }
    assert_nil(imported.local_pref)
    assert_equal(500, @rib.adj_rib_in(E2)['10.1.0.0/16'].local_pref, 'the Adj-RIB-In keeps the route as received')
  end

  def test_local_pref_from_ibgp_is_used
    @rib.announce(route(E1))
    @rib.announce(route(I1, as_path: [65009], local_pref: 500))
    assert_same(I1, @rib.best('10.1.0.0/16').peer)
    assert_equal(:local_pref, @rib.result('10.1.0.0/16').reason)
  end

  def test_import_block_can_change_or_reject
    rib = BGP::Rib.new(local_as: LOCAL_AS, router_id: '1.1.1.1', import: lambda { |r|
      next nil if r.prefix == '10.9.0.0/16'
      next r unless r.peer == E2
      pa = Path_attribute.new(r.path_attribute.encode(true), true)
      pa.add(Local_pref.new(300))
      r.with_path_attribute(pa)
    })
    rib.announce(route(E1))
    rib.announce(route(E2))
    assert_same(E2, rib.best('10.1.0.0/16').peer, 'policy set LOCAL_PREF 300 on E2 routes')
    assert_equal([], rib.announce(route(E1, '10.9.0.0/16')), 'rejected')
    assert_equal(1, rib.adj_rib_in(E1).paths('10.9.0.0/16').size, 'still in the Adj-RIB-In')
    assert_equal([], rib.candidates('10.9.0.0/16'))
  end

  def test_refresh_reruns_import_and_decision
    reject = false
    rib = BGP::Rib.new(local_as: LOCAL_AS, router_id: '1.1.1.1', import: ->(r) { reject && r.peer == E1 ? nil : r })
    rib.announce(route(E1))
    rib.announce(route(E2))
    assert_same(E1, rib.best('10.1.0.0/16').peer)
    reject = true
    changes = rib.refresh
    assert_equal([[:replaced, E1, E2]], changes.map { |c| [c.type, c.old.peer, c.new.peer] })
  end

  def test_add_path_routes_from_one_peer
    a, b = route(E1, path_id: 1, med: 20), route(E1, path_id: 2, med: 10)
    @rib.announce(a)
    @rib.announce(b)
    assert_same(b, @rib.best('10.1.0.0/16'))
    assert_equal(:med, @rib.result('10.1.0.0/16').reason)
    @rib.withdraw(E1, '10.1.0.0/16', 2)
    assert_same(a, @rib.best('10.1.0.0/16'))
  end

  # Random announcements, withdrawals and session drops. After every step
  # the table must match a decision run from scratch over everything the
  # peers have sent, and the change events must describe exactly what moved.
  # RIB_MODEL_STEPS=5000 runs a longer check.
  def test_model_check_against_a_full_recompute
    steps = Integer(ENV.fetch('RIB_MODEL_STEPS', 400))
    [11, 23, 42].each { |seed| model_check(seed, steps) }
  end

  private

  def model_check(seed, steps)
    rng = Random.new(seed)
    peers = [E1, E2, I1, Peer.new(address: '10.0.0.5', remote_as: 65002, router_id: '5.5.5.5', local_as: LOCAL_AS)]
    prefixes = %w[10.1.0.0/16 10.2.0.0/16 10.3.0.0/16 10.4.0.0/24 10.5.0.0/24]
    rib = BGP::Rib.new(local_as: LOCAL_AS, router_id: '1.1.1.1')
    oracle = Decision.new(local_as: LOCAL_AS, router_id: '1.1.1.1')
    sent = {}   # [peer, prefix, path_id] => route, what each peer has sent
    mirror = {} # prefix => best route, rebuilt only from change events
    rib.on_change { |c| c.new ? mirror[c.prefix] = c.new : mirror.delete(c.prefix) }

    steps.times do |step|
      before = expected_best(oracle, sent, prefixes)
      peer = peers[rng.rand(peers.size)]
      prefix = prefixes[rng.rand(prefixes.size)]
      path_id = peer == peers[3] ? [nil, 1, 2][rng.rand(3)] : nil
      case rng.rand(10)
      when 0..5
        path = Array.new(rng.rand(4)) { [65002, 65003, 65004, 65005][rng.rand(4)] }
        path = [peer.remote_as] + path if peer.ebgp?
        path << LOCAL_AS if rng.rand(15) == 0 # a loop now and then
        r = route(peer, prefix, as_path: path, path_id: path_id,
                  local_pref: [nil, 90, 100, 200][rng.rand(4)], med: [nil, 0, 10, 20][rng.rand(4)])
        changes = rib.announce(r)
        sent[[peer, r.prefix, path_id]] = r
        touched = [r.prefix]
      when 6..8
        changes = rib.withdraw(peer, prefix, path_id)
        sent.delete([peer, prefix, path_id])
        touched = [prefix]
      else
        changes = rib.peer_down(peer)
        sent.delete_if { |(p, _, _), _| p == peer }
        touched = prefixes
      end
      after = expected_best(oracle, sent, prefixes)
      msg = "seed #{seed} step #{step}"
      prefixes.each do |p|
        assert(same?(after[p], rib.best(p)), "#{msg}: best for #{p}")
        assert(same?(after[p], mirror[p]), "#{msg}: change events for #{p}")
      end
      moved = prefixes.reject { |p| same?(before[p], after[p]) }
      assert_equal(moved.sort, changes.map(&:prefix).sort, "#{msg}: one change per prefix that moved")
      assert((changes.map(&:prefix) - touched).empty?, "#{msg}: only touched prefixes change")
    end
  end

  # What the decision picks from scratch, after the import rule.
  def expected_best(oracle, sent, prefixes)
    prefixes.to_h do |p|
      cands = sent.select { |(_, pfx, _), _| pfx == p }.values.map do |r|
        next r unless r.peer.ebgp? && r.local_pref
        pa = Path_attribute.new(r.path_attribute.encode(true), true)
        pa.delete(Local_pref)
        r.with_path_attribute(pa)
      end
      [p, oracle.best(cands).best]
    end
  end

  def same?(a, b)
    (a.nil? && b.nil?) || (a && b && a.same_path?(b))
  end
end
