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

# lab/speaker.rb over loopback, as plain processes. No Docker needed.
#
#   ruby -I. test/functional/lab/speaker_test.rb

require_relative 'two_speakers_scenario'

class LabSpeakerLoopbackTest < Test::Unit::TestCase
  include TwoSpeakersScenario

  PORT = LabHelper::Local.free_port

  # The same nodes as lab/topologies/two-speakers, moved to 127.0.0.1.
  def self.nodes
    topo = File.join(LabHelper::ROOT, 'lab', 'topologies', 'two-speakers')
    r1 = YAML.safe_load(File.read(File.join(topo, 'r1.yml')))
    r2 = YAML.safe_load(File.read(File.join(topo, 'r2.yml')))
    r1.merge!('listen_address' => '127.0.0.1', 'port' => PORT)
    r1['neighbors'][0]['address'] = '127.0.0.1'
    r2['neighbors'][0].merge!('address' => '127.0.0.1', 'port' => PORT, 'retry' => 0.5)
    { 'r1' => r1, 'r2' => r2 }
  end

  def self.startup
    @@lab = LabHelper::Local.new(nodes)
    @@lab.up
  end

  def self.shutdown
    @@lab.down
  end

  def setup
    @lab = @@lab
  end

  def r1_addr ; '127.0.0.1' ; end
  def r2_addr ; '127.0.0.1' ; end
end
