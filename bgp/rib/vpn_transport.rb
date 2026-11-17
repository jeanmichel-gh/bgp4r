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

    # How a VPN packet reaches a remote PE: docs/design/l3vpn-pe.md,
    # decision 3. bgp4rd runs no IGP and no LDP; RFC 4364 section 4.3.2
    # asks only "that a label switched path exist between those two
    # routers or else that some other tunneling technology (e.g.,
    # [MPLS-in-IP-GRE]) can be used between them". Two transports, chosen
    # per remote PE:
    #
    # * **mpls**, the default: the labels the IGP put on the kernel's route
    #   to the BGP next hop, read with `ip -j route get NH`. isisd and FRR
    #   both put their SR label there:
    #
    #     [{"dst":"10.255.0.3","encap":{"encap_type":"mpls","dst":"17003"},
    #       "gateway":"10.0.12.2","dev":"eth2",...}]
    #
    #   A neighbor's loopback reached by PHP has no encap: no label. A next
    #   hop on a connected subnet has no gateway: the next hop is the via.
    #
    # * **gre**: the VPN label alone, into a GRE tunnel toward that PE
    #   (section 5, RFC 4023). The lab makes the tunnel; this checks it
    #   exists and is up. A tunnel that is up says so in its flags, UP and
    #   LOWER_UP; its operstate is UNKNOWN (measured, iproute2 6.19).
    #
    # Every `ip` here goes through a runner, as IpRoute's do, so the unit
    # tests run with no kernel.
    class VpnTransport

      # What reaches one next hop. transport is 'mpls' or 'gre'; labels
      # the transport's labels, top first, pushed above the VPN label;
      # gateway and dev where the packet goes. error says why the next hop
      # cannot be reached, and then the rest is nil.
      Hop = Struct.new(:transport, :labels, :gateway, :dev, :error) do
        def ok? ; error.nil? ; end
      end

      TRANSPORTS = %w[mpls gre].freeze

      attr_reader :default, :tunnels

      # default: 'mpls' or 'gre', for a next hop with no tunnel named.
      # tunnels: next hop => GRE device, the PEs reached over GRE.
      def initialize(default: 'mpls', tunnels: {}, bin: 'ip', runner: nil)
        unless TRANSPORTS.include?(default.to_s)
          raise ArgumentError, "l3vpn: transport is #{TRANSPORTS.join(' or ')}, not #{default.inspect}"
        end
        @default = default.to_s
        @tunnels = tunnels.to_h { |nh, dev| [nh.to_s, dev.to_s] }
        @bin = bin
        @runner = runner
      end

      # The l3vpn: block's transport keys:
      #
      #   l3vpn:
      #     transport: mpls                  # the default
      #     tunnels:
      #       10.255.0.9: { gre: gre-pe9 }   # next hop => its GRE device
      def self.from_config(c, **opts)
        c ||= {}
        tunnels = (c['tunnels'] || {}).to_h do |nh, t|
          dev = t.is_a?(Hash) ? t['gre'] : nil
          raise ArgumentError, "l3vpn: tunnels: #{nh}: name the device, { gre: DEVICE }" if dev.to_s.empty?
          (IPAddr.new(nh.to_s) rescue raise(ArgumentError, "l3vpn: tunnels: #{nh.inspect} is not an address"))
          [nh.to_s, dev]
        end
        new(default: c.fetch('transport', 'mpls'), tunnels: tunnels, **opts)
      end

      # The Hop toward next_hop.
      def resolve(next_hop)
        nh = next_hop.to_s
        if (dev = @tunnels[nh]) then gre(dev)
        elsif @default == 'gre' then Hop.new('gre', nil, nil, nil, "no GRE tunnel is configured toward #{nh}")
        else mpls(nh)
        end
      end

      # json is required here and not at the top of the file, as
      # View#json does: a Ruby where it is a bundled gem must not stop the
      # library from loading (view_test.rb).
      def mpls(nh)
        require 'json'
        r = execute([@bin, '-j', 'route', 'get', nh])
        return Hop.new('mpls', nil, nil, nil, "no route to #{nh}: #{r.output.strip}") unless r.ok?
        route = JSON.parse(r.output).first or return Hop.new('mpls', nil, nil, nil, "no route to #{nh}")
        encap = route['encap']
        labels = encap && encap['encap_type'] == 'mpls' ? encap['dst'].to_s.split('/').collect(&:to_i) : []
        Hop.new('mpls', labels, route['gateway'] || nh, route['dev'], nil)
      rescue JSON::ParserError => e
        Hop.new('mpls', nil, nil, nil, "ip route get #{nh}: #{e.message}")
      end

      def gre(dev)
        require 'json'
        r = execute([@bin, '-j', 'link', 'show', 'dev', dev])
        return Hop.new('gre', nil, nil, dev, "GRE tunnel #{dev}: #{r.output.strip}") unless r.ok?
        flags = Array((JSON.parse(r.output).first || {})['flags'])
        return Hop.new('gre', nil, nil, dev, "GRE tunnel #{dev} is down") unless (%w[UP LOWER_UP] - flags).empty?
        Hop.new('gre', [], nil, dev, nil)
      rescue JSON::ParserError => e
        Hop.new('gre', nil, nil, dev, "ip link show #{dev}: #{e.message}")
      end

      private

      def execute(argv)
        return @runner.call(argv) if @runner
        output = ::IO.popen(argv, :err => [:child, :out]) { |io| io.read }
        Fib::IpRoute::Result.new(argv, $?.exitstatus, output.to_s)
      rescue SystemCallError => e
        Fib::IpRoute::Result.new(argv, -1, e.message)
      end
    end

  end
end
