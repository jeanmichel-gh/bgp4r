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

# The FIB adapter against a real kernel: routes the Loc-RIB decided on,
# read back out of a routing table with `ip route show`.
#
# **No Docker.** The recorded plan said this part wanted a container, and
# what it actually wanted is what a network namespace gives: a routing
# table of its own, so nothing here can touch the routing table of the
# machine it runs on. #156 measured that; this is the test that depends on
# it.
#
# Three things keep it off the host's own routing:
#
# Every route goes in a namespace of its own, named below, created in
# setup and deleted in teardown, which takes its whole routing state with
# it.
#
# Inside that namespace it still uses a table of its own, TABLE, and never
# the main one, so even a bug in the namespace handling writes somewhere
# the machine does not route from.
#
# And every route is marked `proto bgp`, so the flush that ends it removes
# exactly what bgp4r put there.
#
# Omitted when a namespace cannot be created, which is the ordinary case
# without root, unless LAB_REQUIRE_NETNS=1 asks for a failure instead.
#
# IPv6 is not exercised. The kernel this was written on has IPv6 compiled
# out: /proc/sys/net/ipv6 does not exist and `ip -6 route add` answers
# "Operation not supported", on the host as much as in a namespace. The v6
# command building is asserted in test/unit/rib/ip_route_test.rb instead.
#
# BGP:: names are written out in full here, see Conventions in CLAUDE.md.
class TestBgpRibFibNetns < Test::Unit::TestCase

  NETNS = 'bgp4r-fib-test'
  TABLE = 100
  LOCAL_AS = 65001

  # Inside the namespace, on lo, so a next hop in this subnet resolves and
  # the kernel picks the device itself.
  SUBNET = '10.77.0.1/24'
  NEXT_HOP = '10.77.0.2'
  OTHER_NEXT_HOP = '10.77.0.3'

  PEER = BGP::Rib::Peer.new(:address => '10.0.0.2', :remote_as => 65002,
                            :router_id => '2.2.2.2', :local_as => LOCAL_AS)

  class << self
    # Whether a namespace can be made at all, asked once.
    def usable?
      return @usable unless @usable.nil?
      @usable = system('ip', 'netns', 'add', NETNS_PROBE,
                       :out => File::NULL, :err => File::NULL) || false
      system('ip', 'netns', 'del', NETNS_PROBE,
             :out => File::NULL, :err => File::NULL) if @usable
      @usable
    end
    NETNS_PROBE = 'bgp4r-fib-probe'
  end

  def setup
    unless self.class.usable?
      flunk('a network namespace cannot be created') if ENV['LAB_REQUIRE_NETNS'] == '1'
      omit('a network namespace cannot be created, which needs root')
    end
    sh('ip', 'netns', 'del', NETNS)       # in case a previous run died
    assert(sh('ip', 'netns', 'add', NETNS), 'created the namespace')
    assert(sh('ip', '-n', NETNS, 'link', 'set', 'lo', 'up'))
    assert(sh('ip', '-n', NETNS, 'addr', 'add', SUBNET, 'dev', 'lo'))
    @rib = BGP::Rib.new(:local_as => LOCAL_AS, :router_id => '1.1.1.1')
  end

  def teardown
    @rib&.uninstall
    @rib&.feed&.stop
    sh('ip', 'netns', 'del', NETNS)
  end

  def sh(*argv)
    system(*argv, :out => File::NULL, :err => File::NULL)
  end

  def install
    @rib.install(:table => TABLE, :netns => NETNS)
  end

  def route(prefix, next_hop = NEXT_HOP)
    pa = BGP::Path_attribute.new(BGP::Origin.new(0), BGP::Next_hop.new(next_hop),
                                 BGP::As_path.new(65002))
    BGP::Rib::Route.new(prefix, pa, PEER)
  end

  # What the kernel has, as "prefix => next hop", read with the same proto
  # filter the adapter writes with. This is the assertion that matters:
  # not what bgp4r thinks it did, but what the routing table says.
  def kernel_routes
    out = ::IO.popen(['ip', '-n', NETNS, 'route', 'show', 'table', TABLE.to_s,
                      'proto', 'bgp'], :err => [:child, :out]) { |io| io.read }
    out.lines.each_with_object({}) do |line, h|
      fields = line.split
      h[fields[0]] = fields[2] if fields[1] == 'via'
    end
  end

  def test_a_decided_route_reaches_the_kernel
    install
    @rib.announce(route('198.51.100.0/24'))
    @rib.drain
    assert_equal({ '198.51.100.0/24' => NEXT_HOP }, kernel_routes)
    assert_equal(NEXT_HOP, @rib.fib['198.51.100.0/24'],
                 'and the FIB agrees with the kernel')
    assert_equal({}, @rib.fib_installer.failed)
  end

  def test_a_withdrawn_route_leaves_the_kernel
    install
    @rib.announce(route('198.51.100.0/24'))
    @rib.drain
    assert_equal(1, kernel_routes.size)
    @rib.withdraw(PEER, '198.51.100.0/24')
    @rib.drain
    assert_equal({}, kernel_routes, 'the kernel no longer has it')
    assert(@rib.fib.empty?)
  end

  # The whole reason install is `ip route replace`: one command covers a
  # prefix the table does not have and one whose next hop changed.
  def test_a_better_route_replaces_the_one_in_the_kernel
    install
    @rib.announce(route('198.51.100.0/24', NEXT_HOP))
    @rib.drain
    assert_equal(NEXT_HOP, kernel_routes['198.51.100.0/24'])
    # A shorter AS path, so this one wins the decision (RFC 4271 section
    # 9.1.2.2 a) and the kernel entry has to follow it.
    pa = BGP::Path_attribute.new(BGP::Origin.new(0),
                                 BGP::Next_hop.new(OTHER_NEXT_HOP),
                                 BGP::As_path.new)
    better = BGP::Rib::Route.new('198.51.100.0/24', pa,
                                 BGP::Rib::Peer.new(:address => '10.0.0.9',
                                                    :remote_as => 65009,
                                                    :router_id => '9.9.9.9',
                                                    :local_as => LOCAL_AS))
    @rib.announce(better)
    @rib.drain
    assert_equal(OTHER_NEXT_HOP, kernel_routes['198.51.100.0/24'])
    assert_equal(1, kernel_routes.size, 'replaced, not added beside')
  end

  # A table fed by nothing but rib.originate has no session and nothing to
  # attach, which is the case that found the feed's worker only starting on
  # the first attach.
  #
  # originate uses the router ID as its next hop (RFC 4271 section 5.1.3),
  # so the router ID has to be an address this namespace can reach for the
  # route to be installable at all. The next test is the other half.
  def test_a_prefix_we_originate_with_no_peers_at_all
    @rib.feed.stop
    @rib = BGP::Rib.new(:local_as => LOCAL_AS, :router_id => '10.77.0.9')
    install
    @rib.originate('203.0.113.0/24')
    @rib.drain
    assert_equal('10.77.0.9', kernel_routes['203.0.113.0/24'],
                 'originate uses the router ID as its next hop')
  end

  # **bgp4r does not resolve a next hop.** A real router resolves the BGP
  # next hop recursively against its IGP; bgp4r has no IGP, so the next hop
  # goes to the kernel as it arrived and the kernel decides. Here the
  # kernel cannot reach 1.1.1.1 from this namespace and refuses the route
  # with "Nexthop has invalid gateway".
  #
  # What matters is that the refusal is recorded rather than claimed: the
  # FIB does not say it installed a route the kernel threw out. That is the
  # whole reason plan and commit are separate.
  def test_an_unreachable_next_hop_is_refused_and_recorded
    install
    @rib.originate('203.0.113.0/24')    # next hop 1.1.1.1, outside the subnet
    @rib.drain
    assert_equal({}, kernel_routes, 'the kernel would not take it')
    assert(@rib.fib.empty?, 'and the FIB does not claim it')
    result = @rib.fib_installer.failed['203.0.113.0/24']
    assert_not_nil(result, 'the failure is recorded')
    assert(!result.ok?)
    assert_match(/gateway|unreachable|No route/i, result.output,
                 "what the kernel said: #{result.output.strip}")
  end

  # Turning it on after the table filled has to install what is already
  # there, not only what changes next.
  def test_installing_after_the_table_filled
    @rib.announce(route('198.51.100.0/24'))
    @rib.announce(route('192.0.2.0/24'))
    install
    @rib.drain
    assert_equal(%w[192.0.2.0/24 198.51.100.0/24], kernel_routes.keys.sort)
  end

  # What a FIB owes the machine on the way out, since nothing else tidies a
  # routing table up.
  def test_uninstall_takes_every_route_back_out
    install
    @rib.announce(route('198.51.100.0/24'))
    @rib.announce(route('192.0.2.0/24'))
    @rib.drain
    assert_equal(2, kernel_routes.size)
    @rib.uninstall
    assert_equal({}, kernel_routes, 'the kernel table is empty again')
    assert(@rib.fib.empty?)
  end

  # What the proto filter on the flush buys: a route something else owns in
  # the same table survives the flush that ends the install. Drop proto
  # from flush_argv and this test fails, which is how it was checked.
  #
  # It is the flush this pins and not the del. A del names one prefix, so
  # its proto filter can only matter for a foreign route of that same
  # prefix, which the next test shows the kernel does not allow.
  def test_the_flush_leaves_a_route_bgp4r_did_not_put_there
    assert(sh('ip', '-n', NETNS, 'route', 'add', '172.16.0.0/16',
              'via', NEXT_HOP, 'table', TABLE.to_s, 'proto', 'static'))
    install
    @rib.announce(route('198.51.100.0/24'))
    @rib.drain
    @rib.uninstall
    assert_equal({}, kernel_routes, 'ours are gone')
    out = ::IO.popen(['ip', '-n', NETNS, 'route', 'show', 'table', TABLE.to_s],
                     :err => [:child, :out]) { |io| io.read }
    assert_match(%r{172\.16\.0\.0/16}, out, 'and the static one is still there')
  end

  # The price of using replace, asserted rather than left to be discovered.
  #
  # Linux holds one route per prefix in a table whatever the proto, so a
  # foreign route of a prefix bgp4r also has is taken over: replace
  # overwrites it and marks it proto bgp, and the flush on the way out then
  # removes it. No proto filter can prevent that, because by then the route
  # is marked as ours.
  #
  # So a table shared with another daemon is safe only where the prefixes
  # do not overlap. This is why table: has no default.
  def test_a_foreign_route_of_the_same_prefix_is_taken_over
    assert(sh('ip', '-n', NETNS, 'route', 'add', '198.51.100.0/24',
              'via', NEXT_HOP, 'table', TABLE.to_s, 'proto', 'static'))
    assert(!sh('ip', '-n', NETNS, 'route', 'add', '198.51.100.0/24',
               'via', OTHER_NEXT_HOP, 'table', TABLE.to_s, 'proto', 'bgp'),
           'the kernel will not hold two protos for one prefix')
    install
    @rib.announce(route('198.51.100.0/24', OTHER_NEXT_HOP))
    @rib.drain
    assert_equal({ '198.51.100.0/24' => OTHER_NEXT_HOP }, kernel_routes,
                 'it is ours now, proto bgp')
    @rib.uninstall
    out = ::IO.popen(['ip', '-n', NETNS, 'route', 'show', 'table', TABLE.to_s],
                     :err => [:child, :out]) { |io| io.read }
    assert_equal('', out.strip, 'and the flush took it with ours')
  end

  # The namespace is the isolation, so the host's own table of the same
  # number must stay empty throughout.
  def test_nothing_reaches_the_host_routing_table
    install
    @rib.announce(route('198.51.100.0/24'))
    @rib.drain
    assert_equal(1, kernel_routes.size, 'in the namespace')
    host = ::IO.popen(['ip', 'route', 'show', 'table', TABLE.to_s],
                      :err => [:child, :out]) { |io| io.read }
    assert(!host.include?('198.51.100.0/24'),
           "the host's table #{TABLE} must not have it")
  end

end
