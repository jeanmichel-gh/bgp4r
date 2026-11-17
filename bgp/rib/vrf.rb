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

require 'ipaddr'

module BGP
  module Rib

    # One VRF of a PE, as configured (docs/design/l3vpn-pe.md):
    #
    #   vrfs:
    #     - name: A                      # the kernel VRF device
    #       table: 100                   # its routing table
    #       rd: 65000:1                  # RFC 4364 section 4.2
    #       import: [65000:100]          # Import Targets, section 4.3.1
    #       export: [65000:100]          # Export Targets
    #       prefixes: [192.168.1.0/24]   # its own, besides connected ones
    #
    # rd, export and prefixes are what the VRF sends, pull request 3. A
    # list of one may come as one value, which is how a configuration
    # read back from set lines gives it (bgp/daemon/config.rb).
    #
    # The lab makes the VRF device and its table; bgp4rd checks it
    # (open question 2).
    Vrf = Struct.new(:name, :table, :rd, :import, :export, :prefixes) do
      # The VRFs of a configuration's `vrfs:` list, each checked. Raises
      # ArgumentError naming the VRF and what is wrong with it.
      def self.list(config)
        vrfs = Array(config).each_with_index.collect { |c, i| from_config(c, i) }
        dup = vrfs.group_by(&:name).select { |_, v| v.size > 1 }.keys
        raise ArgumentError, "vrfs: #{dup.join(', ')} named twice" unless dup.empty?
        tables = vrfs.group_by(&:table).select { |_, v| v.size > 1 }
        unless tables.empty?
          t, v = tables.first
          raise ArgumentError, "vrfs: #{v.collect(&:name).join(' and ')} share table #{t}"
        end
        vrfs
      end

      def self.from_config(c, i)
        raise ArgumentError, "vrfs: entry #{i + 1} is not a mapping" unless c.is_a?(Hash)
        name = c['name'].to_s
        raise ArgumentError, "vrfs: entry #{i + 1} has no name" if name.empty?
        unknown = c.keys - Vrf::KEYS
        unless unknown.empty?
          raise ArgumentError, "vrf #{name}: unknown key(s) #{unknown.join(', ')}: use one of #{Vrf::KEYS.join(', ')}"
        end
        table = Integer(c['table'], exception: false)
        raise ArgumentError, "vrf #{name}: table is required, a number" unless table && table.positive?
        rd = c['rd'] && distinguisher(c['rd'], "vrf #{name}: rd")
        import = Array(c['import']).collect { |rt| distinguisher(rt, "vrf #{name}: import") }
        export = Array(c['export']).collect { |rt| distinguisher(rt, "vrf #{name}: export") }
        prefixes = Array(c['prefixes']).collect do |p|
          ip = IPAddr.new(p.to_s) rescue raise(ArgumentError, "vrf #{name}: prefixes: #{p.inspect} is not a prefix")
          "#{ip}/#{ip.prefix}"
        end
        new(name, table, rd, import, export, prefixes)
      end

      # RFC 4364 section 4.2 and RFC 4360 section 4: an administrator, an
      # AS number or an IPv4 address, then a number, "65000:1" or
      # "10.255.0.1:7". Kept as text, the form VpnRoute gives them.
      def self.distinguisher(v, what)
        admin, assigned = v.to_s.split(':', 2)
        ok = admin && assigned && assigned.match?(/\A\d+\z/) &&
             (admin.match?(/\A\d+\z/) || (IPAddr.new(admin).ipv4? rescue false))
        raise ArgumentError, "#{what}: #{v.inspect} is not ADMIN:NUMBER" unless ok
        "#{admin}:#{assigned}"
      end

      # RFC 4364 section 4.3.1: a route is eligible for this VRF when "there
      # is some Route Target that is both one of the route's Route Targets
      # and one of the VRF's Import Targets".
      def imports?(route_targets)
        !(Array(route_targets) & import).empty?
      end
    end

    # The keys a VRF's entry may have; any other is refused, by name.
    Vrf::KEYS = %w[name table rd import export prefixes].freeze

  end
end
