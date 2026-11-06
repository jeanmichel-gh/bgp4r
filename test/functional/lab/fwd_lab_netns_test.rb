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

# lab/routescope/fwd-lab run in four network namespaces, with no Docker
# and no containerlab. Packets cross bgp4rd routers here, which nothing
# else in the suite checks: fib_test.rb says a route reached the kernel,
# and this says the kernel forwards on it.
#
# **It reads the lab's own files.** The links and the `exec:` lines come
# from fwd-lab.clab.yml and each bgp4rd reads its node file from the lab
# folder, so a change to the lab is a change to what runs here. One
# difference, said rather than hidden: containerlab runs `exec:` after a
# node's entrypoint and this runs it before, so here bgp4rd starts with
# its addresses in place.
#
# A ping from A's loopback to D's, then the B to D link down, up, the
# session stopped and started, and D cut off. Which way the packets went
# is read from C's eth1 receive counter, since every packet through C
# arrives there.
#
# Needs root, or CAP_NET_ADMIN, and ping. It omits itself without them
# unless LAB_REQUIRE_NETNS=1 asks for a failure instead, as fib_test.rb
# does. About 40 seconds, most of it two hold timers running out.
#
#   sudo ruby -I. test/functional/lab/fwd_lab_netns_test.rb

require 'test/unit'
require 'yaml'
require 'tmpdir'
require 'fileutils'
require 'bgp/daemon/client'

class FwdLabNetnsTest < Test::Unit::TestCase
  self.test_order = :defined

  ROOT = File.expand_path('../../..', __dir__)
  DIR = File.join(ROOT, 'lab/routescope/fwd-lab')
  TOPOLOGY = YAML.safe_load(File.read(File.join(DIR, 'fwd-lab.clab.yml')))
  NODES = TOPOLOGY['topology']['nodes'].keys
  LINKS = TOPOLOGY['topology']['links'].collect { |l| l['endpoints'] }

  A_LO = '10.255.0.1'
  D_LO = '10.255.0.4'
  DIRECT = '10.200.4.2'   # d on the b to d link
  VIA_C = '10.200.2.2'    # c on the b to c link
  HOLD = 9                # every session's hold_time
  PINGS = 50

  def self.ns(node) ; "fwdlab-#{node}" ; end

  def self.sh(*argv) ; system(*argv, :out => File::NULL, :err => File::NULL) ; end

  def self.usable?
    return @usable unless @usable.nil?
    @usable = (sh('ip', 'netns', 'add', 'fwdlab-probe') && sh('ip', 'netns', 'del', 'fwdlab-probe') &&
               sh('sh', '-c', 'command -v ping')) || false
  end

  def self.startup
    return unless usable?
    @@dir = Dir.mktmpdir('fwd-lab')
    NODES.each do |n|
      sh('ip', 'netns', 'del', ns(n))
      sh('ip', 'netns', 'add', ns(n)) or raise "could not add #{ns(n)}"
      sh('ip', '-n', ns(n), 'link', 'set', 'lo', 'up')
    end
    LINKS.each_with_index do |(x, y), i|
      xn, xi = x.split(':')
      yn, yi = y.split(':')
      sh('ip', 'link', 'add', "fl#{i}x", 'netns', ns(xn), 'type', 'veth',
         'peer', 'name', "fl#{i}y", 'netns', ns(yn)) or raise "could not link #{x} #{y}"
      sh('ip', '-n', ns(xn), 'link', 'set', "fl#{i}x", 'name', xi, 'up')
      sh('ip', '-n', ns(yn), 'link', 'set', "fl#{i}y", 'name', yi, 'up')
    end
    TOPOLOGY['topology']['nodes'].each do |n, spec|
      Array(spec['exec']).each do |line|
        sh('ip', 'netns', 'exec', ns(n), 'sh', '-c', line) or raise "#{n}: #{line} failed"
      end
    end
    @@pids = NODES.to_h do |n|
      [n, Process.spawn('ip', 'netns', 'exec', ns(n), RbConfig.ruby, '-I', ROOT,
                        File.join(ROOT, 'exe/bgp4rd'), '-f', File.join(DIR, n, 'bgp4rd.yml'),
                        '-s', socket(n), '-l', File.join(@@dir, "#{n}.log"),
                        :out => File::NULL, :err => File.join(@@dir, "#{n}.err"))]
    end
  end

  def self.socket(node) ; File.join(@@dir, "#{node}.sock") ; end

  def self.shutdown
    return unless defined?(@@pids)
    @@pids.each_value { |p| Process.kill('TERM', p) rescue nil }
    @@pids.each_value { |p| Process.wait(p) rescue nil }
    NODES.each { |n| sh('ip', 'netns', 'del', ns(n)) }
    FileUtils.rm_rf(@@dir)
  end

  def setup
    return if self.class.usable?
    flunk('a network namespace or ping is not available') if ENV['LAB_REQUIRE_NETNS'] == '1'
    omit('a network namespace and ping are needed, which needs root')
  end

  # -------------------------------------------------------------- helpers

  def ns(node) ; self.class.ns(node) ; end
  def sh(*argv) ; self.class.sh(*argv) ; end

  def out(node, *argv)
    ::IO.popen(['ip', 'netns', 'exec', ns(node), *argv], :err => [:child, :out], &:read)
  end

  # The next hop the kernel uses, which is what forwarding follows.
  def next_hop(node, dest)
    out(node, 'ip', 'route', 'get', dest)[/ via (\S+)/, 1]
  end

  def cli(node, method, params = {})
    BGP::Daemon::Client.new(self.class.socket(node)).call(method, params)
  end

  # Polls until the block answers truthy, and answers the seconds it took.
  def wait_for(what, seconds)
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    until yield
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
      flunk("#{what} (waited #{seconds}s)\n#{logs}") if elapsed > seconds
      sleep 0.2
    end
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
  end

  def logs
    NODES.collect { |n| "--- #{n}\n" + File.read(File.join(@@dir, "#{n}.log")).lines.last(8).join rescue '' }.join
  end

  def c_rx
    out('c', 'cat', '/sys/class/net/eth1/statistics/rx_packets').to_i
  end

  # Pings D from A's loopback and answers [received, packets C took in].
  def ping
    before = c_rx
    text = out('a', 'ping', '-q', '-c', PINGS.to_s, '-i', '0.02', '-W', '1', '-I', A_LO, D_LO)
    [text[/(\d+) received/, 1].to_i, c_rx - before]
  end

  def assert_direct(what)
    got, through_c = ping
    assert_equal(PINGS, got, "#{what}: every ping answered")
    assert_operator(through_c, :<, PINGS / 5, "#{what}: the pings did not cross c")
  end

  def assert_via_c(what)
    got, through_c = ping
    assert_equal(PINGS, got, "#{what}: every ping answered")
    assert_operator(through_c, :>=, PINGS, "#{what}: the pings crossed c")
  end

  # ---------------------------------------------------------------- tests

  def test_1_every_router_learns_every_loopback_and_takes_the_direct_link
    wait_for('a to learn d\'s loopback', 60) { next_hop('a', D_LO) == '10.200.1.2' }
    wait_for('b to prefer the direct link to d', 30) { next_hop('b', D_LO) == DIRECT }
    wait_for('d to prefer the direct link back to a', 30) { next_hop('d', A_LO) == '10.200.4.1' }
    assert_direct('the direct link')
  end

  # The forwarding table bgp4rd believes in agrees with the kernel, and
  # a node's own loopback is skipped rather than installed via its
  # router ID.
  def test_2_show_fib_says_what_the_kernel_holds
    fib = cli('b', 'show.fib')
    assert_equal({ '10.255.0.1/32' => '10.200.1.1', '10.255.0.3/32' => VIA_C, '10.255.0.4/32' => DIRECT },
                 fib['rows'].to_h { |r| [r['prefix'], r['next_hop']] })
    assert_equal([{ 'prefix' => '10.255.0.2/32', 'reason' => 'originated' }], fib['fib']['skipped'])
    assert_equal([], fib['fib']['failed'])
  end

  # No NOTIFICATION crosses a link that is down, so b keeps the session
  # until its hold timer runs out, and the kernel route through eth3 is
  # gone the moment the link is. So the failover takes up to HOLD.
  def test_3_the_b_to_d_link_down_moves_traffic_through_c
    sh('ip', '-n', ns('b'), 'link', 'set', 'eth3', 'down')
    took = wait_for('b to route d\'s loopback through c', HOLD + 6) { next_hop('b', D_LO) == VIA_C }
    wait_for('d to route a\'s loopback through c', HOLD + 6) { next_hop('d', A_LO) == '10.200.3.1' }
    assert_via_c("link down, failover in #{took.round(1)}s")
  end

  def test_4_the_link_back_up_moves_it_back
    sh('ip', '-n', ns('b'), 'link', 'set', 'eth3', 'up')
    wait_for('b to prefer the direct link again', 30) { next_hop('b', D_LO) == DIRECT }
    wait_for('d to prefer the direct link again', 30) { next_hop('d', A_LO) == '10.200.4.1' }
    assert_direct('link back up')
  end

  # A session stopped by hand ends at once on both sides, so this
  # failover does not wait for a hold timer.
  def test_5_stopping_the_session_fails_over_without_the_hold_timer
    cli('b', 'peer.stop', 'peer' => DIRECT)
    took = wait_for('b to route through c after peer.stop', 3) { next_hop('b', D_LO) == VIA_C }
    assert_via_c("session stopped, failover in #{took.round(1)}s")
    cli('b', 'peer.start', 'peer' => DIRECT)
    wait_for('b to prefer the direct link after peer.start', 30) { next_hop('b', D_LO) == DIRECT }
    assert_direct('session started again')
  end

  # With both of d's links down there is no path, and a withdraws the
  # route rather than keeping a stale one.
  def test_6_d_cut_off_is_unreachable_and_comes_back
    %w[eth1 eth2].each { |i| sh('ip', '-n', ns('d'), 'link', 'set', i, 'down') }
    # The route itself and not `ip route get`, which in a containerlab
    # node answers the management default route once this one is gone.
    wait_for('a to withdraw d\'s loopback', HOLD + 6) { out('a', 'ip', 'route', 'show', 'exact', "#{D_LO}/32").empty? }
    assert_equal(0, ping.first, 'no ping answered')
    %w[eth1 eth2].each { |i| sh('ip', '-n', ns('d'), 'link', 'set', i, 'up') }
    wait_for('a to learn d\'s loopback again', 30) { next_hop('a', D_LO) == '10.200.1.2' }
    wait_for('b to prefer the direct link again', 30) { next_hop('b', D_LO) == DIRECT }
    assert_direct('d back')
  end
end
