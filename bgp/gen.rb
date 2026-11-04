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
require 'bgp/gen/unicast'

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
  class Gen
    GENERATORS = { 'unicast' => Unicast }.freeze

    attr_reader :spec, :family

    def initialize(spec)
      @spec = Spec.read(spec)
      @family = @spec['family']
      klass = GENERATORS[@family]
      unless klass
        known = BGP::Specimen.families.collect { |name, _, _| name.to_s }
        if known.include?(@family)
          raise SpecError, "family '#{@family}' has no generator yet; bgp4r generates #{GENERATORS.keys.join(', ')}"
        end
        raise SpecError, "unknown family '#{@family}'; the families are #{known.join(', ')}"
      end
      @generator = klass.new(@spec)
    end

    def afi ; @generator.afi ; end

    # The UPDATEs that announce every route of the spec.
    def updates ; @generator.updates ; end

    # The UPDATEs that withdraw exactly what #updates announced.
    def withdrawals ; @generator.withdrawals ; end

    # One Hash per route, of plain data, `count` of them.
    def expected ; @generator.expected ; end
  end
end
