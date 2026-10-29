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

# Nothing here runs a process or touches a routing table: the backend is a
# fake that records what it was asked to do. The real commands are asserted
# in ip_route_test.rb and run for real in
# test/functional/lab/fib_test.rb.
#
# BGP:: names are written out in full here, see Conventions in CLAUDE.md.
class TestBgpRibFibInstaller < Test::Unit::TestCase

  LOCAL_AS = 65001
  PEER = BGP::Rib::Peer.new(:address => '10.0.0.2', :remote_as => 65002,
                            :router_id => '2.2.2.2', :local_as => LOCAL_AS)

  # A backend that answers like Fib::IpRoute without being one. Full BGP::
  # names inside a nested class: constant lookup goes up the lexical scope
  # and then this class's own ancestors, never the enclosing class's.
  class Backend
    attr_reader :ran, :flushes

    # refuse: prefixes whose commands come back failed. Mutable, so a test
    # can let a prefix start failing and then succeed.
    attr_reader :refuse

    def initialize(refuse: [])
      @ran = []
      @flushes = []
      @refuse = refuse
    end

    def run(op)
      @ran << op
      result(op.prefix.to_s, !@refuse.include?(op.prefix))
    end

    def flush(ipv6: false)
      @flushes << ipv6
      result('flush', true)
    end

    def to_s ; 'fake backend' ; end

    private

    def result(what, ok)
      BGP::Rib::Fib::IpRoute::Result.new(['ip', what], ok ? 0 : 2,
                                         ok ? '' : 'RTNETLINK answers: no')
    end
  end

  def setup
    @rib = BGP::Rib.new(:local_as => LOCAL_AS, :router_id => '1.1.1.1')
    @backend = Backend.new
  end

  def route(prefix = '192.0.2.0/24', next_hop = '10.0.0.2')
    attrs = [BGP::Origin.new(0), BGP::As_path.new(65002)]
    attrs << BGP::Next_hop.new(next_hop) if next_hop
    BGP::Rib::Route.new(prefix, BGP::Path_attribute.new(*attrs), PEER)
  end

  # install returns the installer and the second call returns the same one,
  # which is how advertise behaves for router mode.
  def test_install_is_off_until_asked_for
    assert_nil(@rib.fib_installer)
    assert_nil(@rib.fib)
    i = @rib.install(:backend => @backend)
    assert_instance_of(BGP::Rib::FibInstaller, i)
    assert(i.started?)
    assert_same(i, @rib.install(:backend => @backend))
    assert_same(i, @rib.fib_installer)
    assert_same(i.fib, @rib.fib)
  end

  # table: has no default, so install through the real backend needs one.
  def test_install_needs_a_table
    assert_raise(ArgumentError) { @rib.install }
    assert_nothing_raised { @rib.install(:table => 100, :runner => ->(a) { a }) }
  end

  def test_a_route_reaches_the_forwarding_table
    @rib.install(:backend => @backend)
    @rib.announce(route)
    @rib.drain
    assert_equal(1, @backend.ran.size)
    assert(@backend.ran.first.install?)
    assert_equal('192.0.2.0/24', @backend.ran.first.prefix)
    assert_equal('10.0.0.2', @rib.fib['192.0.2.0/24'])
    assert_equal({}, @rib.fib_installer.failed)
  end

  def test_a_withdrawn_route_leaves_it
    @rib.install(:backend => @backend)
    @rib.announce(route)
    @rib.drain
    @rib.withdraw(PEER, '192.0.2.0/24')
    @rib.drain
    assert_equal(2, @backend.ran.size)
    assert(@backend.ran.last.remove?)
    assert(@rib.fib.empty?)
  end

  def test_a_changed_next_hop_is_installed_again
    @rib.install(:backend => @backend)
    @rib.announce(route('192.0.2.0/24', '10.0.0.2'))
    @rib.drain
    @rib.announce(route('192.0.2.0/24', '10.0.0.9'))
    @rib.drain
    assert_equal(2, @backend.ran.size)
    assert_equal('10.0.0.9', @rib.fib['192.0.2.0/24'])
  end

  # Turning it on part way through has to install what is already there,
  # not only what changes next. Router#session_up does this for a peer.
  def test_installing_after_the_table_filled_syncs_what_is_there
    @rib.announce(route('192.0.2.0/24'))
    @rib.announce(route('198.51.100.0/24'))
    @rib.install(:backend => @backend)
    @rib.drain
    assert_equal(%w[192.0.2.0/24 198.51.100.0/24], @rib.fib.prefixes.sort)
    assert_equal(2, @backend.ran.size)
  end

  def test_syncing_an_empty_table_queues_nothing
    @rib.install(:backend => @backend)
    @rib.drain
    assert_equal([], @backend.ran)
  end

  # The point of planning before committing: a command the kernel refused
  # must not leave the FIB claiming the route.
  def test_a_refused_install_is_not_recorded
    @rib.install(:backend => Backend.new(:refuse => ['192.0.2.0/24']))
    @rib.announce(route)
    @rib.drain
    assert(@rib.fib.empty?, 'the command failed, so nothing is installed')
    result = @rib.fib_installer.failed['192.0.2.0/24']
    assert_not_nil(result, 'and it says so')
    assert(!result.ok?)
    assert_equal(2, result.status)
  end

  # And it is tried again next time rather than being stuck, because
  # nothing was recorded, so the plan still wants it.
  def test_a_refused_install_is_planned_again
    backend = Backend.new(:refuse => ['192.0.2.0/24'])
    @rib.install(:backend => backend)
    @rib.announce(route('192.0.2.0/24', '10.0.0.2'))
    @rib.drain
    @rib.announce(route('192.0.2.0/24', '10.0.0.9'))
    @rib.drain
    assert_equal(2, backend.ran.size)
  end

  # The asymmetry, and the reason for it: ip route del exits 2 for a route
  # the table does not have, so the commonest way a removal fails is that
  # the route was already gone, which is the outcome it wanted. Going on
  # believing it is installed would mean never trying again.
  def test_a_refused_removal_is_recorded_anyway
    backend = Backend.new(:refuse => ['192.0.2.0/24'])
    @rib.install(:backend => backend)
    # Get it installed first, past the refusing backend.
    @rib.fib.commit(BGP::Rib::Fib::Op.new(:install, '192.0.2.0/24', '10.0.0.2'))
    @rib.announce(route)
    @rib.drain
    @rib.withdraw(PEER, '192.0.2.0/24')
    @rib.drain
    assert(backend.ran.last.remove?)
    assert(@rib.fib.empty?, 'removed from the record even though it failed')
    assert_not_nil(@rib.fib_installer.failed['192.0.2.0/24'], 'and recorded')
  end

  def test_a_later_success_clears_the_failure
    backend = Backend.new(:refuse => ['192.0.2.0/24'])
    @rib.install(:backend => backend)
    @rib.announce(route)
    @rib.drain
    assert_not_nil(@rib.fib_installer.failed['192.0.2.0/24'])
    backend.refuse.clear
    @rib.announce(route('192.0.2.0/24', '10.0.0.9'))
    @rib.drain
    assert_equal({}, @rib.fib_installer.failed)
    assert_equal('10.0.0.9', @rib.fib['192.0.2.0/24'])
  end

  def test_failed_is_a_copy_and_can_be_cleared
    @rib.install(:backend => Backend.new(:refuse => ['192.0.2.0/24']))
    @rib.announce(route)
    @rib.drain
    @rib.fib_installer.failed.clear
    assert_equal(1, @rib.fib_installer.failed.size, 'clearing the copy did nothing')
    @rib.fib_installer.clear_failed
    assert_equal({}, @rib.fib_installer.failed)
  end

  # Both families, because a flush names one and a table can hold both.
  def test_uninstall_flushes_both_families_and_forgets
    @rib.install(:backend => @backend)
    @rib.announce(route)
    @rib.drain
    @rib.uninstall
    assert_equal([false, true], @backend.flushes, 'v4 then v6')
    assert(@rib.fib.empty?)
    assert(!@rib.fib_installer.started?)
  end

  def test_uninstall_without_install_does_nothing
    assert_nil(@rib.uninstall)
  end

  # Installing again after an uninstall runs each command once and records
  # no failure.
  #
  # Be precise about what holds this up. FibInstaller#start guards against
  # registering a second on_change listener, but removing that guard moves
  # no test, because the duplicate comes to nothing anyway: Fib#plan
  # answers nil for an install the FIB already agrees with and nil for a
  # removal of a prefix it no longer holds. So what this really pins is
  # that re-installing is idempotent, which is the plan-then-commit design
  # doing its job, and not the guard.
  def test_installing_again_after_uninstall_does_not_double_up
    @rib.install(:backend => @backend)
    @rib.uninstall
    @rib.install(:backend => @backend)
    @rib.announce(route)
    @rib.drain
    assert_equal(1, @backend.ran.size, 'one command, not two')
    @rib.withdraw(PEER, '192.0.2.0/24')
    @rib.drain
    assert_equal(2, @backend.ran.size)
    assert_equal({}, @rib.fib_installer.failed, 'and no spurious failure')
  end

  def test_apply_of_nothing_is_nothing
    @rib.install(:backend => @backend)
    assert_nil(@rib.fib_installer.apply(nil))
    assert_equal([], @backend.ran)
  end

  # A route with no next hop never gets as far as the FIB, and the reason
  # is upstream of it: Decision#eligible answers :next_hop_unreachable for
  # a route whose next_hop is nil, which is in Decision::INELIGIBLE, so the
  # route stays in the Adj-RIB-In and never becomes a Loc-RIB best. So
  # there is no change to plan and the FIB is never asked.
  #
  # That is why Fib's own :no_next_hop branch cannot be reached through a
  # live table, and is covered in fib_test.rb by calling plan directly. It
  # is kept because plan is public and pure, and anyone may hand it a
  # change this table would not have produced.
  def test_a_route_with_no_next_hop_never_gets_to_the_fib
    @rib.install(:backend => @backend)
    @rib.announce(route('192.0.2.0/24', nil))
    @rib.drain
    assert_equal([], @backend.ran)
    assert(@rib.fib.empty?)
    assert_equal([], @rib.loc_rib.prefixes, 'it is not a best route at all')
    assert_equal({}, @rib.fib.skipped, 'so the FIB was never asked about it')
    assert(BGP::Rib::Decision::INELIGIBLE.include?(:next_hop_unreachable))
  end

  def test_to_s
    @rib.install(:backend => @backend)
    assert_equal('FIB installer: FIB: 0 routes, fake backend',
                 @rib.fib_installer.to_s)
  end

end
