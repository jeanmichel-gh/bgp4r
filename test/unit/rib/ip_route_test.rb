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

# Every command line asserted here was run against iproute2 6.1.0 in a
# network namespace before it was written down. Nothing in this file needs
# iproute2, root, or a routing table: argv is a pure function, which is
# the whole reason it is separate from running it.
#
# BGP:: names are written out in full here, see Conventions in CLAUDE.md.
class TestBgpRibIpRoute < Test::Unit::TestCase

  def install(prefix = '192.0.2.0/24', next_hop = '10.0.0.2')
    BGP::Rib::Fib::Op.new(:install, prefix, next_hop)
  end

  def remove(prefix = '192.0.2.0/24')
    BGP::Rib::Fib::Op.new(:remove, prefix, nil)
  end

  # No default, so nobody reaches the main routing table without naming
  # it. Any table is accepted once named; this refuses no value.
  def test_the_table_is_required
    assert_raise(ArgumentError) { BGP::Rib::Fib::IpRoute.new(:table => nil) }
    assert_raise(ArgumentError) { BGP::Rib::Fib::IpRoute.new }
    assert_nothing_raised { BGP::Rib::Fib::IpRoute.new(:table => 254) }
  end

  def test_the_defaults
    ip = BGP::Rib::Fib::IpRoute.new(:table => 100)
    assert_equal('100', ip.table)
    assert_equal('bgp', ip.proto)
    assert_nil(ip.netns)
    assert_nil(ip.dev)
  end

  # replace rather than add: on a prefix the table does not have it adds,
  # on one it has it changes the next hop, so one action covers both and
  # re-running it is harmless.
  def test_an_install
    ip = BGP::Rib::Fib::IpRoute.new(:table => 100)
    assert_equal(%w[ip route replace 192.0.2.0/24 via 10.0.0.2
                    table 100 proto bgp], ip.argv(install))
  end

  def test_an_install_with_a_device
    ip = BGP::Rib::Fib::IpRoute.new(:table => 100, :dev => 'veth0')
    assert_equal(%w[ip route replace 192.0.2.0/24 via 10.0.0.2 dev veth0
                    table 100 proto bgp], ip.argv(install))
  end

  # ip -n NS rather than ip netns exec NS ip: one process, not two.
  def test_an_install_in_a_namespace
    ip = BGP::Rib::Fib::IpRoute.new(:table => 100, :netns => 'bgp4r')
    assert_equal(%w[ip -n bgp4r route replace 192.0.2.0/24 via 10.0.0.2
                    table 100 proto bgp], ip.argv(install))
  end

  def test_another_proto
    ip = BGP::Rib::Fib::IpRoute.new(:table => 100, :proto => 'static')
    assert_equal('static', ip.argv(install).last)
  end

  # ip takes the family before the subcommand, and a v6 prefix with no -6
  # is rejected rather than guessed.
  def test_an_ipv6_install
    ip = BGP::Rib::Fib::IpRoute.new(:table => 100)
    assert_equal(%w[ip -6 route replace 2001:db8:1::/48 via 2001:db8::1
                    table 100 proto bgp],
                 ip.argv(install('2001:db8:1::/48', '2001:db8::1')))
  end

  def test_an_ipv6_install_in_a_namespace
    ip = BGP::Rib::Fib::IpRoute.new(:table => 100, :netns => 'bgp4r')
    argv = ip.argv(install('2001:db8:1::/48', '2001:db8::1'))
    assert_equal(%w[ip -6 -n bgp4r route replace], argv[0, 6],
                 'the family comes before the namespace')
  end

  # No via and no dev on a del: the prefix, the table and the proto name
  # the route, and naming a next hop that has since changed would mean
  # matching nothing.
  def test_a_removal
    ip = BGP::Rib::Fib::IpRoute.new(:table => 100, :dev => 'veth0')
    assert_equal(%w[ip route del 192.0.2.0/24 table 100 proto bgp],
                 ip.argv(remove))
  end

  # proto on a del reads as a filter, so this removes the route only if it
  # is one bgp4r put there. Without it a del would take out a route of the
  # same prefix that something else owns.
  def test_a_removal_keeps_the_proto_filter
    ip = BGP::Rib::Fib::IpRoute.new(:table => 100)
    assert_equal(%w[proto bgp], ip.argv(remove).last(2))
  end

  def test_an_ipv6_removal
    ip = BGP::Rib::Fib::IpRoute.new(:table => 100)
    assert_equal(%w[ip -6 route del 2001:db8:1::/48 table 100 proto bgp],
                 ip.argv(remove('2001:db8:1::/48')))
  end

  def test_argv_of_nothing_raises
    ip = BGP::Rib::Fib::IpRoute.new(:table => 100)
    assert_raise(ArgumentError) { ip.argv(nil) }
  end

  # A show has no prefix to read the family off, and ip shows one family
  # at a time, so a table holding both takes two commands.
  def test_show
    ip = BGP::Rib::Fib::IpRoute.new(:table => 100, :netns => 'bgp4r')
    assert_equal(%w[ip -n bgp4r route show table 100 proto bgp],
                 ip.show_argv)
    assert_equal(%w[ip -6 -n bgp4r route show table 100 proto bgp],
                 ip.show_argv(:ipv6 => true))
  end

  def test_flush
    ip = BGP::Rib::Fib::IpRoute.new(:table => 100)
    assert_equal(%w[ip route flush table 100 proto bgp], ip.flush_argv)
    assert_equal(%w[ip -6 route flush table 100 proto bgp],
                 ip.flush_argv(:ipv6 => true))
  end

  # Nothing here is handed to a shell, so a prefix is an argument and not
  # a string to be quoted.
  def test_every_command_is_an_array_of_arguments
    ip = BGP::Rib::Fib::IpRoute.new(:table => 100)
    [ip.argv(install), ip.argv(remove), ip.show_argv, ip.flush_argv].each do |argv|
      assert_instance_of(Array, argv)
      argv.each { |a| assert_instance_of(String, a) }
    end
  end

  def test_another_binary
    ip = BGP::Rib::Fib::IpRoute.new(:table => 100, :bin => '/usr/sbin/ip')
    assert_equal('/usr/sbin/ip', ip.argv(install).first)
  end

  def test_to_s
    assert_equal('ip route, table 100, proto bgp',
                 BGP::Rib::Fib::IpRoute.new(:table => 100).to_s)
    assert_equal('ip route, table 100, proto bgp, netns bgp4r, dev veth0',
                 BGP::Rib::Fib::IpRoute.new(:table => 100, :netns => 'bgp4r',
                                            :dev => 'veth0').to_s)
  end

end
