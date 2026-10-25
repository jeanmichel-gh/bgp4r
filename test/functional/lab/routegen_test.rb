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

# lab/topologies/routegen in Docker Compose.
#
#   ruby -I. test/functional/lab/routegen_test.rb
#
# Builds the speaker image, starts the topology with a small
# ROUTEGEN_COUNT, runs the checks, and takes it down. Skipped when docker
# compose is not available.

require_relative 'routegen_scenario'

class LabRoutegenComposeTest < Test::Unit::TestCase
  include RoutegenScenario

  COUNT, PER_UPDATE = RoutegenScenario.sizes(3000, 127)

  def self.startup
    return unless LabHelper::Compose.available?
    env = { 'ROUTEGEN_COUNT' => COUNT, 'ROUTEGEN_PER_UPDATE' => PER_UPDATE }
    @@lab = LabHelper::Compose.new('routegen', env: env)
    @@lab.down
    @@lab.up
  end

  def self.shutdown
    @@lab.down if defined?(@@lab)
  end

  def setup
    unless defined?(@@lab)
      flunk('docker compose is not available') if ENV['LAB_REQUIRE_DOCKER'] == '1'
      omit('docker compose is not available')
    end
    @lab = @@lab
  end

  def teardown
    super if defined?(@@lab)
  end

  def gen_addr ; '10.20.0.1' ; end
  def sink_addr ; '10.20.0.2' ; end
  def count ; COUNT ; end
  def per_update ; PER_UPDATE ; end
end
