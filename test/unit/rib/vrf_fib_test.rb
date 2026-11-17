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
# Each command line is the form measured in a network namespace,
# iproute2 6.19 (bgp/rib/vrf_fib.rb).
class TestBgpRibVrfFib < Test::Unit::TestCase

  Hop = BGP::Rib::VpnTransport::Hop

  def setup
    @fib = BGP::Rib::VrfFib.new
  end

  def test_an_mpls_route_pushes_the_transport_then_the_vpn_label
    hop = Hop.new('mpls', [17003], '10.0.12.2', 'eth2', nil)
    assert_equal('ip route replace vrf A 192.168.2.0/30 encap mpls 17003/24001 via 10.0.12.2 dev eth2 proto bgp',
                 @fib.install_argv('A', '192.168.2.0/30', [17003, 24001], hop).join(' '))
  end

  def test_a_gre_route_pushes_the_vpn_label_into_the_tunnel
    hop = Hop.new('gre', [], nil, 'gre-pe2', nil)
    assert_equal('ip route replace vrf A 192.168.2.0/30 encap mpls 24001 dev gre-pe2 proto bgp',
                 @fib.install_argv('A', '192.168.2.0/30', [24001], hop).join(' '))
  end

  def test_remove_flush_and_the_device
    assert_equal('ip route del vrf A 192.168.2.0/30 proto bgp', @fib.remove_argv('A', '192.168.2.0/30').join(' '))
    assert_equal('ip route flush vrf A proto bgp', @fib.flush_argv('A').join(' '))
    assert_equal('ip -j -d link show dev A', @fib.link_argv('A').join(' '))
  end

  # With no runner a real process runs, and its exit status is read.
  def test_with_no_runner_the_command_runs
    assert_equal(0, BGP::Rib::VrfFib.new(bin: 'true').run(%w[true]).status)
    assert_equal(1, BGP::Rib::VrfFib.new(bin: 'false').run(%w[false]).status)
    assert_equal(-1, BGP::Rib::VrfFib.new.run(%w[/nonexistent/ip]).status)
  end

  def test_a_runner_takes_the_running
    seen = []
    fib = BGP::Rib::VrfFib.new(runner: ->(argv) { seen << argv; BGP::Rib::Fib::IpRoute::Result.new(argv, 0, '') })
    assert(fib.run(fib.flush_argv('A')).ok?)
    assert_equal([%w[ip route flush vrf A proto bgp]], seen)
  end
end
