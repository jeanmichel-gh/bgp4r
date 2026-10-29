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

# BGP:: names are written out in full here, see Conventions in CLAUDE.md.
class TestBgpRibFib < Test::Unit::TestCase

  PEER = BGP::Rib::Peer.new(:address => '10.0.0.2', :remote_as => 65002,
                            :router_id => '2.2.2.2', :local_as => 65001)

  def setup
    @fib = BGP::Rib::Fib.new
  end

  def route(prefix = '192.0.2.0/24', next_hop = '10.0.0.2')
    attrs = [BGP::Origin.new(0), BGP::As_path.new(65002)]
    attrs << BGP::Next_hop.new(next_hop) if next_hop
    BGP::Rib::Route.new(prefix, BGP::Path_attribute.new(*attrs), PEER)
  end

  def change(prefix, new_route, old_route = nil)
    BGP::Rib::LocRib::Change.new(prefix, old_route, new_route, :only_route)
  end

  def install(prefix = '192.0.2.0/24', next_hop = '10.0.0.2')
    @fib.commit(@fib.plan(change(prefix, route(prefix, next_hop))))
  end

  def test_an_empty_one
    assert(@fib.empty?)
    assert_equal(0, @fib.size)
    assert_equal([], @fib.prefixes)
    assert_nil(@fib['192.0.2.0/24'])
    assert_equal({}, @fib.skipped)
  end

  def test_a_new_prefix_is_planned_as_an_install
    op = @fib.plan(change('192.0.2.0/24', route))
    assert(op.install?)
    assert(!op.remove?)
    assert_equal('192.0.2.0/24', op.prefix)
    assert_equal('10.0.0.2', op.next_hop)
  end

  # The property the whole split exists for: planning is a question, not
  # an answer. A plan that recorded its own intent would claim a route the
  # kernel went on to refuse, which is the bug Mrai nearly shipped in part
  # 8 of RIB phase 3.
  def test_planning_records_nothing
    op = @fib.plan(change('192.0.2.0/24', route))
    assert(@fib.empty?, 'planned but not committed, so not installed')
    assert_nil(@fib['192.0.2.0/24'])
    assert_equal(op, @fib.plan(change('192.0.2.0/24', route)),
                 'and the same plan again, since nothing moved')
  end

  def test_commit_records_an_install
    assert_equal(:new, install)
    assert_equal(1, @fib.size)
    assert_equal(['192.0.2.0/24'], @fib.prefixes)
    assert_equal('10.0.0.2', @fib['192.0.2.0/24'])
    assert(!@fib.empty?)
  end

  def test_the_same_route_again_needs_nothing
    install
    assert_nil(@fib.plan(change('192.0.2.0/24', route)),
               'the FIB already agrees with it')
  end

  def test_a_changed_next_hop_is_an_install
    install
    op = @fib.plan(change('192.0.2.0/24', route('192.0.2.0/24', '10.0.0.3')))
    assert(op.install?, 'replace covers a changed next hop too')
    assert_equal('10.0.0.3', op.next_hop)
    assert_equal(:changed, @fib.commit(op))
    assert_equal('10.0.0.3', @fib['192.0.2.0/24'])
    assert_equal(1, @fib.size, 'and it is still one route')
  end

  # commit answers what it did, so a caller that re-ran a command it had
  # already run can tell. :same never comes out of plan, which returns nil
  # in that case, but a resync may commit one.
  def test_committing_the_same_install_twice_is_the_same
    op = @fib.plan(change('192.0.2.0/24', route))
    assert_equal(:new, @fib.commit(op))
    assert_equal(:same, @fib.commit(op))
    assert_equal(1, @fib.size)
  end

  def test_commit_of_nothing_is_nothing
    assert_nil(@fib.commit(nil))
    assert(@fib.empty?)
  end

  def test_a_withdrawn_route_is_planned_as_a_removal
    install
    op = @fib.plan(change('192.0.2.0/24', nil, route))
    assert(op.remove?)
    assert_equal('192.0.2.0/24', op.prefix)
    assert_nil(op.next_hop)
    assert_equal('10.0.0.2', @fib.commit(op), 'the next hop it had')
    assert(@fib.empty?)
  end

  def test_withdrawing_a_prefix_the_fib_never_had_does_nothing
    assert_nil(@fib.plan(change('192.0.2.0/24', nil, route)))
  end

  def test_a_route_with_no_next_hop_is_skipped
    assert_nil(@fib.plan(change('192.0.2.0/24', route('192.0.2.0/24', nil))))
    assert(@fib.empty?)
    assert_equal(:no_next_hop, @fib.skipped['192.0.2.0/24'])
  end

  # The Loc-RIB can no longer say where to send this, so continuing to
  # forward on it is worse than not having it.
  def test_an_installed_route_that_loses_its_next_hop_comes_out
    install
    op = @fib.plan(change('192.0.2.0/24', route('192.0.2.0/24', nil)))
    assert(op.remove?)
    assert_equal(:no_next_hop, @fib.skipped['192.0.2.0/24'])
    @fib.commit(op)
    assert(@fib.empty?)
  end

  def test_skipped_can_be_cleared
    @fib.plan(change('192.0.2.0/24', route('192.0.2.0/24', nil)))
    assert_equal(1, @fib.skipped.size)
    @fib.clear_skipped
    assert_equal({}, @fib.skipped)
  end

  def test_skipped_is_a_copy
    @fib.plan(change('192.0.2.0/24', route('192.0.2.0/24', nil)))
    @fib.skipped.clear
    assert_equal(1, @fib.skipped.size, 'clearing the copy changed nothing')
  end

  # The next hop can arrive in MP_REACH_NLRI instead (RFC 4760 section 3),
  # which Route#next_hop already reads, so the FIB needs no v6 branch.
  def test_an_ipv6_route
    mp = BGP::Mp_reach.new(:afi => 2, :safi => 1, :nexthop => ['2001:db8::1'],
                           :nlris => ['2001:db8:1::/48'])
    r = BGP::Rib::Route.new('2001:db8:1::/48',
                            BGP::Path_attribute.new(BGP::Origin.new(0),
                                                    BGP::As_path.new(65002), mp),
                            PEER)
    op = @fib.plan(change('2001:db8:1::/48', r))
    assert(op.install?)
    assert_equal('2001:db8::1', op.next_hop)
    assert_equal(:new, @fib.commit(op))
  end

  def test_each
    install('192.0.2.0/24', '10.0.0.2')
    install('198.51.100.0/24', '10.0.0.3')
    assert_equal([['192.0.2.0/24', '10.0.0.2'], ['198.51.100.0/24', '10.0.0.3']],
                 @fib.each.to_a.sort)
    seen = {}
    @fib.each { |prefix, next_hop| seen[prefix] = next_hop }
    assert_equal(2, seen.size)
  end

  # A FIB whose table was emptied underneath it has to be told, because it
  # removes nothing by itself.
  def test_flush_forgets_without_removing
    install
    assert_same(@fib, @fib.flush)
    assert(@fib.empty?)
    assert(@fib.plan(change('192.0.2.0/24', route)).install?,
           'so the next decision installs it again')
  end

  def test_to_s
    assert_equal('FIB: 0 routes', @fib.to_s)
    install
    assert_equal('FIB: 1 route', @fib.to_s)
    install('198.51.100.0/24')
    assert_equal('FIB: 2 routes', @fib.to_s)
  end

  def test_op_to_s
    assert_equal('install 192.0.2.0/24 via 10.0.0.2',
                 @fib.plan(change('192.0.2.0/24', route)).to_s)
    install
    assert_equal('remove 192.0.2.0/24',
                 @fib.plan(change('192.0.2.0/24', nil, route)).to_s)
  end

end
