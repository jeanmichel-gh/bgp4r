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

# lab/speaker.rb over loopback, as plain processes, and the capability names
# a topology can ask for, which needs no process at all. No Docker needed.
#
#   ruby -I. test/functional/lab/speaker_test.rb

require_relative 'two_speakers_scenario'
require 'lab/speaker'

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

# The capabilities a topology asks for, in process: this starts no speaker,
# it builds the Neighbor a topology would and reads the OPEN parameters off
# it. lab/speaker.rb used to keep its own list of four names, so a topology
# could ask for ADD-PATH, Role, ORF, Dynamic Capability or Enhanced Route
# Refresh by no name at all, though bgp4r implements every one. It forwards
# to Neighbor#capability now, which has the only list.
class LabSpeakerCapabilityTest < Test::Unit::TestCase

  # The parameters of the OPEN the topology's first neighbor would send.
  def capabilities_of(capabilities)
    node = { 'as' => 65001, 'router_id' => '10.10.0.1',
             'local_address' => '10.10.0.1',
             'neighbors' => [{ 'address' => '10.10.0.2', 'as' => 65002 }] }
    node['neighbors'][0]['capabilities'] = capabilities if capabilities
    peer = Lab::Speaker.new(node).peers.first
    neighbor = peer.send(:new_neighbor)
    neighbor.instance_eval { @opt_parms }
  end

  def test_a_topology_can_name_a_capability_bgp4r_implements
    caps = capabilities_of(['as4_byte', 'route_refresh', 'mbgp_ipv6_unicast',
                            'enhanced_route_refresh', 'orf', 'dynamic'])
    assert_equal ['As4', 'Route_refresh', 'Mbgp', 'Enhanced_route_refresh',
                  'Orf', 'Dynamic'],
                 caps.collect { |c| c.class.to_s.split('::').last }
    # Each one's own code, read off the parameter it would send.
    assert_equal ['020641040000fde9', '02020200', '0206010400020001',
                  '02024600', '02020300', '02024300'],
                 caps.collect { |c| c.to_shex }
  end

  # A capability that takes arguments needs a form that carries them, which
  # is a one key Hash. Without it a topology could name Role or ADD-PATH and
  # still not say which Role or which direction.
  def test_a_topology_can_give_a_capability_its_arguments
    caps = capabilities_of([{ 'role' => 'customer' },
                            { 'add_path' => [1, 1, 3] },
                            { 'graceful_restart' => [0, 180] }])
    # RFC 9234 Role 3, Customer. RFC 7911 AFI 1 SAFI 1, send and receive.
    assert_equal ['0203090103', '0206450400010301', '0204400200b4'],
                 caps.collect { |c| c.to_shex }
  end

  def test_the_default_is_still_the_four_byte_as_capability
    caps = capabilities_of(nil)
    assert_equal 1, caps.size
    assert_equal 'BGP::OPT_PARM::CAP::As4', caps.first.class.to_s
  end

  # Lab.main turns an ArgumentError into abort, so this message is what an
  # operator sees for a typo in a topology. It has to name the capability and
  # the peer it was asked for.
  def test_a_name_no_capability_answers_to_names_the_peer
    e = assert_raise(ArgumentError) { capabilities_of(['nonesuch']) }
    assert_match(/nonesuch/, e.message)
    assert_match(/10\.10\.0\.2/, e.message)
    assert_match(/route_refresh/, e.message, 'and lists the names there are')
  end
end
