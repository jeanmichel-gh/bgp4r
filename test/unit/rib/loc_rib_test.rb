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

class TestBgpRibLocRib < Test::Unit::TestCase
  include BGP
  include BGP::Rib

  A = Peer.new(address: '10.0.0.2', remote_as: 65002, router_id: '2.2.2.2', local_as: 65001)
  B = Peer.new(address: '10.0.0.3', remote_as: 65003, router_id: '3.3.3.3', local_as: 65001)

  def route(peer, local_pref: 100, prefix: '10.1.0.0/16')
    pa = Path_attribute.new(Origin.new(0), Next_hop.new(peer.address), As_path.new(peer.remote_as), Local_pref.new(local_pref))
    Route.new(prefix, pa, peer)
  end

  def setup
    @loc = LocRib.new(Decision.new(local_as: 65001, router_id: '1.1.1.1'))
  end

  def test_added_replaced_withdrawn
    a, b = route(A), route(B, local_pref: 200)
    c = @loc.update('10.1.0.0/16', [a])
    assert_equal([:added, nil, a, :only_route], [c.type, c.old, c.new, c.reason])
    c = @loc.update('10.1.0.0/16', [a, b])
    assert_equal([:replaced, a, b, :local_pref], [c.type, c.old, c.new, c.reason])
    c = @loc.update('10.1.0.0/16', [])
    assert_equal([:withdrawn, b, nil], [c.type, c.old, c.new])
    assert @loc.empty?
    assert_nil(@loc.best('10.1.0.0/16'))
  end

  def test_no_change_when_the_best_path_stays
    a, b = route(A, local_pref: 200), route(B)
    @loc.update('10.1.0.0/16', [a])
    assert_nil(@loc.update('10.1.0.0/16', [a, b]), 'a still wins')
    assert_nil(@loc.update('10.1.0.0/16', [route(A, local_pref: 200)]), 'same path again')
    assert_nil(@loc.update('10.9.0.0/16', []), 'nothing to nothing')
  end

  def test_result_and_queries
    a, b = route(A), route(B)
    @loc.update('10.1.0.0/16', [a, b])
    @loc.update('10.2.0.0/16', [route(B, prefix: '10.2.0.0/16')])
    assert_same(a, @loc.best('10.1.0.9/16'))
    r = @loc.result('10.1.0.0/16')
    assert_equal(:router_id, r.reason)
    assert_equal({ b => :router_id }, r.eliminated)
    assert_equal(['10.1.0.0/16', '10.2.0.0/16'], @loc.prefixes)
    assert_equal(2, @loc.size)
    seen = []
    @loc.each { |prefix, best| seen << [prefix, best.peer] }
    assert_equal([['10.1.0.0/16', A], ['10.2.0.0/16', B]], seen)
  end

  def test_only_unusable_routes_means_withdrawn
    a = route(A)
    @loc.update('10.1.0.0/16', [a])
    looped = Route.new('10.1.0.0/16', Path_attribute.new(Origin.new(0), Next_hop.new('10.0.0.2'), As_path.new(65002, 65001)), A)
    c = @loc.update('10.1.0.0/16', [looped])
    assert_equal(:withdrawn, c.type)
  end
end
