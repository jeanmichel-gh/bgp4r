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

require 'bgp/rib/vrf'

module BGP
  module Rib

    # One MAC-VRF of an EVPN PE, one per VNI: docs/design/evpn.md,
    # decision 2, pull request 2.
    #
    #   macvrfs:
    #     - vni: 100
    #       rd: 10.255.0.12:100      # the default is local_address:vni
    #       import: [65000:100]      # the default is as:vni
    #       export: [65000:100]      # the default is as:vni
    #
    # RFC 8365 section 5.1.2, option 1, "A Single Broadcast Domain per
    # EVI": "a BGP Route Distinguisher (RD) and Route Target (RT) are
    # needed per VNI on every NVE". RFC 7432 section 7.9 recommends a type
    # 1 RD, the PE's address and a number. The Route Targets default to
    # AS:VNI, which is what FRR's leaves sent in routescope's lab 3 with
    # `advertise-all-vni` alone.
    Macvrf = Struct.new(:vni, :rd, :import, :export) do
      # The MAC-VRFs of a configuration's `macvrfs:` list, each checked.
      # address is the RD's default administrator, as the AS the RTs'.
      def self.list(config, address:, as:)
        unless config.nil? || config.is_a?(Array)
          raise ArgumentError, 'macvrfs: is a list'
        end
        list = Array(config).each_with_index.collect { |c, i| from_config(c, i, address, as) }
        dup = list.group_by(&:vni).select { |_, v| v.size > 1 }.keys
        raise ArgumentError, "macvrfs: VNI #{dup.join(', ')} given twice" unless dup.empty?
        rds = list.group_by(&:rd).select { |_, v| v.size > 1 }
        unless rds.empty?
          rd, v = rds.first
          raise ArgumentError, "macvrfs: VNIs #{v.collect(&:vni).join(' and ')} share RD #{rd}"
        end
        list
      end

      def self.from_config(c, i, address, as)
        raise ArgumentError, "macvrfs: entry #{i + 1} is not a mapping" unless c.is_a?(Hash)
        vni = Integer(c['vni'], exception: false)
        # A VNI is 24 bits (RFC 7348 section 5).
        raise ArgumentError, "macvrfs: entry #{i + 1}: vni is required, 1 to 16777215" unless vni && vni.between?(1, 0xffffff)
        unknown = c.keys - Macvrf::KEYS
        unless unknown.empty?
          raise ArgumentError, "macvrf #{vni}: unknown key(s) #{unknown.join(', ')}: use one of #{Macvrf::KEYS.join(', ')}"
        end
        rd = Vrf.distinguisher(c['rd'] || "#{address}:#{vni}", "macvrf #{vni}: rd")
        rts = ->(key) {
          list = c.key?(key) ? Array(c[key]) : ["#{as}:#{vni}"]
          raise ArgumentError, "macvrf #{vni}: #{key} is empty" if list.empty?
          list.collect { |rt| Vrf.distinguisher(rt, "macvrf #{vni}: #{key}") }
        }
        new(vni, rd, rts.call('import'), rts.call('export'))
      end

      # RFC 7432 section 7.10 and RFC 4364 section 4.3.1: a route is
      # imported when one of its Route Targets is an Import Target.
      def imports?(route_targets)
        !(Array(route_targets) & import).empty?
      end
    end

    # The keys a MAC-VRF's entry may have; any other is refused, by name.
    Macvrf::KEYS = %w[vni rd import export].freeze

  end
end
