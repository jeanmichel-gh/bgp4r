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
    # An IPv6 route takes the same forms, its gateway the neighbor's
    # link-local (decision 6): `replace` and `del` take the family from
    # the prefix, `flush` does not, and needs -6 (measured, iproute2 6.19):
    #
    #   ip route replace vrf A 2001:db8:2::/64 encap mpls T/L via fe80::.. dev D proto bgp
    #   ip -6 route flush vrf A proto bgp
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

      # `ip route flush` leaves IPv6 routes alone (measured).
      def flush6_argv(vrf)
        [@bin, '-6', 'route', 'flush', 'vrf', vrf, 'proto', PROTO]
      end

      # The label route a VRF's label pops into the VRF, for a lookup there
      # (RFC 4364 section 4.3.2, one label per VRF): measured with
      # iproute2 6.19, it reads back as {"dst":"24001","dev":"A"}. The
      # flush with proto bgp removes only these: isisd's label routes,
      # proto isis, stay.
      def label_argv(label, vrf)
        [@bin, '-f', 'mpls', 'route', 'replace', label.to_s, 'dev', vrf, 'proto', PROTO]
      end

      def label_remove_argv(label)
        [@bin, '-f', 'mpls', 'route', 'del', label.to_s, 'proto', PROTO]
      end

      def label_flush_argv
        [@bin, '-f', 'mpls', 'route', 'flush', 'proto', PROTO]
      end

      # A VRF's connected prefixes, which it sends as VPN routes:
      # [{"dst":"192.168.1.0/30","dev":"eth1",...}].
      def connected_argv(vrf)
        [@bin, '-j', 'route', 'show', 'vrf', vrf, 'proto', 'kernel', 'scope', 'link']
      end

      # Its IPv6 ones. The answer also lists fe80::/64 and anycast and
      # multicast routes, as {"type":"anycast",...}; L3vpn keeps the
      # unicast ones that are not link-local (measured):
      # [{"dst":"2001:db8:1::/64","dev":"eth3","metric":256,...}].
      def connected6_argv(vrf)
        [@bin, '-6', '-j', 'route', 'show', 'vrf', vrf, 'proto', 'kernel']
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
