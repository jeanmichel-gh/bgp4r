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

require 'bgp4r'
require 'bgp/gen/spec'
require 'bgp/gen/packer'
require 'bgp/gen/sender'
require 'bgp/gen/unicast'
require 'bgp/gen/multicast'
require 'bgp/gen/labelled'
require 'bgp/gen/vpn'
require 'bgp/gen/flow_rules'
require 'bgp/gen/evpn_routes'
require 'bgp/gen/rt_constrain_routes'
require 'bgp/gen/link_state_routes'
require 'bgp/gen/mcast_vpn_routes'
require 'bgp/gen/churn'

module BGP
  # Generates UPDATEs and withdrawals in bulk from a spec of plain JSON
  # types, and says as data what it meant to send.
  #
  #   g = BGP::Gen.new('family' => 'unicast', 'start' => '10.0.0.0/24',
  #                    'count' => 10_000, 'per_update' => 100,
  #                    'attributes' => { 'next_hop' => '192.0.2.1', 'as_path' => [65010] })
  #   g.updates.each { |u| neighbor.send_message u }
  #   g.expected.first  # => {"prefix"=>"10.0.0.0/24", "origin"=>0, ...}
  #   g.withdrawals.each { |u| neighbor.send_message u }
  #
  # docs/route-generation.md is the design and the plan. It is pure: no
  # socket, no thread, no clock, so the same spec gives the same octets
  # every time. `updates`, `withdrawals` and `expected` are Enumerators,
  # so a million routes are built one message or one row at a time.
  #
  # It refuses a spec it cannot read, with a Gen::SpecError, and never a
  # route no RFC allows. Which families have a generator is GENERATORS;
  # the names are BGP::Specimen's, so the library has one vocabulary,
  # and a name Specimen knows that has no generator yet is refused as
  # such rather than as unknown.
  #
  # A second argument says what session the spec goes out on, so the
  # eBGP and iBGP rules an announce block gets apply here too: see
  # bgp/gen/sender.rb. `bgp4r-sim` passes one; the library alone sends
  # what the spec says.
  class Gen
    GENERATORS = { 'unicast' => Unicast, 'multicast' => Multicast,
                   'labelled' => Labelled, 'vpn' => Vpn,
                   'vpn_multicast' => Vpn_multicast,
                   'flow_spec' => Flow_rules, 'flow_spec_vpn' => Flow_rules_vpn,
                   'evpn' => Evpn_routes, 'rt_constrain' => Rt_constrain_routes,
                   'mcast_vpn' => Mcast_vpn_routes,
                   'bgp_ls' => Link_state_routes, 'bgp_ls_vpn' => Link_state_vpn_routes }.freeze

    attr_reader :spec, :family, :sender

    def initialize(spec, sender = nil)
      @spec = Spec.read(spec)
      @sender = Sender.read(sender)
      @family = @spec['family']
      klass = GENERATORS[@family]
      unless klass
        known = BGP::Specimen.families.collect { |name, _, _| name.to_s }
        if known.include?(@family)
          raise SpecError, "family '#{@family}' has no generator yet; bgp4r generates #{GENERATORS.keys.join(', ')}"
        end
        raise SpecError, "unknown family '#{@family}'; the families are #{known.join(', ')}"
      end
      Spec::FAMILY_KEYS.each do |k, families|
        next if !@spec.key?(k) || families.include?(@family)
        raise SpecError, "'#{k}' is for #{families.join(', ')} and not for '#{@family}'"
      end
      @generator = klass.new(@spec, @sender)
    end

    def afi ; @generator.afi ; end

    # The UPDATEs that announce every route of the spec.
    def updates ; @generator.updates ; end

    # The UPDATEs that withdraw exactly what #updates announced.
    def withdrawals ; @generator.withdrawals ; end

    # One Hash per route, of plain data, `count` of them.
    def expected ; @generator.expected ; end

    # How many routes the spec makes: `count`, or `count` once per VRF
    # for VPN. What a plan's total and a feed's description say.
    def total ; @generator.total ; end
  end
end
