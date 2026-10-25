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

# lab/topologies/routegen over loopback, as plain processes. No Docker.
#
#   ruby -I. test/functional/lab/routegen_loopback_test.rb
#   ROUTEGEN_COUNT=200000 ruby -I. test/functional/lab/routegen_loopback_test.rb

require_relative 'routegen_scenario'

class LabRoutegenLoopbackTest < Test::Unit::TestCase
  include RoutegenScenario

  PORT = LabHelper::Local.free_port
  COUNT, PER_UPDATE = RoutegenScenario.sizes(3000, 127)

  # The same nodes as lab/topologies/routegen, moved to 127.0.0.1.
  def self.nodes
    topo = File.join(LabHelper::ROOT, 'lab', 'topologies', 'routegen')
    gen = YAML.safe_load(File.read(File.join(topo, 'gen.yml')))
    sink = YAML.safe_load(File.read(File.join(topo, 'sink.yml')))
    sink.merge!('listen_address' => '127.0.0.1', 'port' => PORT)
    sink['neighbors'][0]['address'] = '127.0.0.1'
    gen['neighbors'][0].merge!('address' => '127.0.0.1', 'port' => PORT, 'retry' => 0.5)
    { 'sink' => sink, 'gen' => gen }
  end

  def self.startup
    env = { 'ROUTEGEN_COUNT' => COUNT.to_s, 'ROUTEGEN_PER_UPDATE' => PER_UPDATE.to_s }
    @@lab = LabHelper::Local.new(nodes, env: env)
    @@lab.up
  end

  def self.shutdown
    @@lab.down
  end

  def setup
    @lab = @@lab
  end

  def gen_addr ; '127.0.0.1' ; end
  def sink_addr ; '127.0.0.1' ; end
  def count ; COUNT ; end
  def per_update ; PER_UPDATE ; end
end
