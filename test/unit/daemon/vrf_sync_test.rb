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
require 'stringio'
require 'logger'
require 'bgp/daemon'

# BGP:: names are written out in full here, see Conventions in CLAUDE.md.
class TestBgpDaemonVrfSync < Test::Unit::TestCase

  # An L3vpn stand-in that counts what it is asked to do. Its sync can be
  # made slow, to pile pokes up behind it, or to raise once.
  class FakeL3vpn
    attr_reader :calls
    attr_accessor :slow, :raise_once

    def initialize ; @calls = [] ; @lock = Mutex.new ; end
    def start ; record(:start) ; end
    def stop ; record(:stop) ; end

    def sync!
      sleep @slow if @slow
      if @raise_once
        @raise_once = false
        raise 'a sync that failed'
      end
      record(:sync)
    end

    def syncs ; @lock.synchronize { @calls.count(:sync) } ; end
    def record(c) ; @lock.synchronize { @calls << c } ; self ; end
  end

  def setup
    @l3vpn = FakeL3vpn.new
    @sync = BGP::Daemon::VrfSync.new(@l3vpn, monitor: false)
  end

  def wait_for(timeout = 5)
    deadline = Time.now + timeout
    sleep 0.01 until yield || Time.now > deadline
    yield
  end

  def test_start_fills_the_vrfs_and_a_poke_syncs_them
    @sync.start
    assert_equal([:start], @l3vpn.calls)
    @sync.poke
    assert(wait_for { @l3vpn.syncs == 1 })
    @sync.stop
    assert_equal(:stop, @l3vpn.calls.last)
  end

  # Pokes that arrive while a sync runs make one more sync, not one each.
  def test_pokes_during_a_sync_make_one_more
    @l3vpn.slow = 0.3
    @sync.start
    @sync.poke
    sleep 0.1
    5.times { @sync.poke }
    assert(wait_for { @l3vpn.syncs == 2 })
    sleep 0.5
    assert_equal(2, @l3vpn.syncs)
    @sync.stop
  end

  # A sync that raises is logged and the next poke still syncs.
  def test_a_failed_sync_does_not_stop_the_thread
    log = StringIO.new
    @sync = BGP::Daemon::VrfSync.new(@l3vpn, monitor: false, logger: Logger.new(log))
    @l3vpn.raise_once = true
    @sync.start
    @sync.poke
    assert(wait_for { log.string.include?('vrf sync: RuntimeError: a sync that failed') })
    @sync.poke
    assert(wait_for { @l3vpn.syncs == 1 })
    @sync.stop
  end
end
