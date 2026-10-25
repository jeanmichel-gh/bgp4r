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

# The routegen checks, shared by the loopback and the Docker test.
# The including class sets @lab, and defines gen_addr and sink_addr (the
# address each node sees its peer at), count and per_update.

require 'test/unit'
require 'bgp/misc/route_generator'
require_relative 'lab_helper'

module RoutegenScenario
  include LabHelper

  START = '11.0.0.0/28'

  # count and per_update for a lab test: ROUTEGEN_COUNT and
  # ROUTEGEN_PER_UPDATE when set, else the defaults given.
  def self.sizes(count, per_update, env=ENV)
    c, p = env['ROUTEGEN_COUNT'].to_s.strip, env['ROUTEGEN_PER_UPDATE'].to_s.strip
    [Integer(c.empty? ? count : c), Integer(p.empty? ? per_update : p)]
  end

  def teardown
    puts "\n#{@lab.logs}" unless passed?
  end

  def test_1_session_establishes
    n = wait_established(@lab, 'sink', gen_addr)
    assert_equal(65001, n['peer_as'])
    assert_equal('10.20.0.1', n['peer_router_id'])
    g = wait_established(@lab, 'gen', sink_addr)
    assert_equal(65002, g['peer_as'])
  end

  def test_2_sink_counts_every_route
    gen = BGP::RouteGenerator.new(START, count, per_update)
    timeout = [60, count / 1000].max
    n = wait_for("sink to count #{count} prefixes from #{gen_addr}", timeout: timeout) do
      s = neighbor(@lab, 'sink', gen_addr)
      s if s && s['prefixes_received'] >= count && s['prefixes_per_second']
    end
    assert_equal('Established', n['state'])
    assert_equal(count, n['prefixes_received'])
    assert_equal(gen.update_count, n['updates_received'], "ceil(#{count} / #{per_update}) updates")
    assert_equal(START, n['first_prefix'])
    assert_equal(gen.last, n['last_prefix'])
    assert_nil(n['received'], 'record: count keeps no routes')
    assert_operator(n['prefixes_per_second'], :>, 0)
    assert_operator(n['seconds_to_last_update'], :>, 0)
    %w[established_at first_update_at last_update_at].each do |k|
      assert_match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z\z/, n[k], "#{k} is ISO 8601 with milliseconds")
    end
    puts format("\nroutegen: sink got %d prefixes in %d updates, %.3fs to the last update, %.1f prefixes/s",
                n['prefixes_received'], n['updates_received'], n['seconds_to_last_update'], n['prefixes_per_second'])
  end
end
