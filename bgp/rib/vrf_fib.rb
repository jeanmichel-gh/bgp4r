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

require 'bgp/rib/ip_route'

module BGP
  module Rib

    # A VRF's routes in the kernel, as iproute2 command lines:
    # docs/design/l3vpn-pe.md, decision 4. As with Fib::IpRoute, building
    # a command line and running it are apart, so every command is
    # asserted in a unit test with no kernel, and a runner can take the
    # running's place.
    #
    # The forms were measured, iproute2 6.19, in a network namespace with
    # a VRF device A on table 100, then read back with `ip -j route show
    # vrf A proto bgp`:
    #
    #   ip route replace vrf A P encap mpls T/L via GW dev D proto bgp   (mpls)
    #   ip route replace vrf A P encap mpls L dev TUNNEL proto bgp       (gre)
    #   ip route del vrf A P proto bgp
    #   ip route flush vrf A proto bgp
    #
    # T is the transport's labels and L the VPN label, top first. A route
    # in VRF A may leave on a device outside it, which is how the VPN
    # route reaches the core. replace on another label stack changes it
    # in place. The flush with proto bgp leaves the VRF's connected and
    # other routes alone.
    class VrfFib

      PROTO = 'bgp'

      def initialize(bin: 'ip', runner: nil)
        @bin = bin
        @runner = runner
      end

      # The command installing prefix in vrf, pushing stack (top first),
      # out of hop (a VpnTransport::Hop).
      def install_argv(vrf, prefix, stack, hop)
        argv = [@bin, 'route', 'replace', 'vrf', vrf, prefix, 'encap', 'mpls', stack.join('/')]
        argv += ['via', hop.gateway] if hop.gateway
        argv + ['dev', hop.dev, 'proto', PROTO]
      end

      def remove_argv(vrf, prefix)
        [@bin, 'route', 'del', 'vrf', vrf, prefix, 'proto', PROTO]
      end

      def flush_argv(vrf)
        [@bin, 'route', 'flush', 'vrf', vrf, 'proto', PROTO]
      end

      # The VRF device: `ip -j -d link show dev NAME` answers its kind and
      # table, {"info_kind":"vrf","info_data":{"table":100}}.
      def link_argv(vrf)
        [@bin, '-j', '-d', 'link', 'show', 'dev', vrf]
      end

      def run(argv)
        return @runner.call(argv) if @runner
        output = ::IO.popen(argv, :err => [:child, :out]) { |io| io.read }
        Fib::IpRoute::Result.new(argv, $?.exitstatus, output.to_s)
      rescue SystemCallError => e
        Fib::IpRoute::Result.new(argv, -1, e.message)
      end
    end

  end
end
