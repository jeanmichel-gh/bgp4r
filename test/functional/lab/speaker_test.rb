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
                            { 'add_path' => [3, 1, 1] },
                            { 'graceful_restart' => [0, 180] }])
    # RFC 9234 Role 3, Customer. RFC 7911 AFI 1, SAFI 1, Send/Receive 3.
    assert_equal ['0203090103', '0206450400010103', '0204400200b4'],
                 caps.collect { |c| c.to_shex }
  end

  # The argument order of add_path, which this file had wrong in a comment
  # for as long as lab/README.md did. CAP::Add_path#add takes (send_recv,
  # afi, safi), so [3, 1, 1] is IPv4 unicast both ways and [1, 1, 3] is
  # SAFI 3, NSAP, receive only.
  #
  # The hex above was always right and its comment was always wrong, which
  # is the whole reason this test exists: a hex string nobody decodes can
  # carry a wrong comment forever. So assert the field values and not only
  # the octets. RFC 7911 section 4: AFI 2 octets, SAFI 1, Send/Receive 1,
  # and 1 is able to receive, 2 able to send, 3 both.
  def test_add_paths_arguments_are_send_recv_then_afi_then_safi
    both = capabilities_of([{ 'add_path' => [3, 1, 1] }]).first
    assert_equal [1, 1, 3], both.to_hash[:capability][:families].first
                                 .values_at(:afi, :safi, :send_recv),
                 '[3, 1, 1] is AFI 1, SAFI 1, both directions'

    nsap = capabilities_of([{ 'add_path' => [1, 1, 3] }]).first
    assert_equal [1, 3, 1], nsap.to_hash[:capability][:families].first
                                 .values_at(:afi, :safi, :send_recv),
                 'and the reverse spelling is SAFI 3, NSAP, receive only, ' \
                 'which is what every comment on this used to claim was unicast'
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

# What a topology can say about ADD-PATH, in process, and what the state file
# then holds. This is what lab/topologies/add-path needs: a Path Identifier on
# an announce block, and the peer's own capability readable as data.
#
# BGP:: names are written out in full, see Conventions in CLAUDE.md.
class LabSpeakerAddPathTest < Test::Unit::TestCase

  PREFIX = '198.51.100.0/24'

  def speaker(announce)
    Lab::Speaker.new('as' => 65001, 'router_id' => '10.10.0.1',
                     'local_address' => '10.10.0.1',
                     'neighbors' => [{ 'address' => '10.10.0.2', 'as' => 65002 }],
                     'announce' => announce)
  end

  # One block's UPDATE, built the way Peer#announce builds it over eBGP.
  def update(block)
    speaker([block]).build_update(block, true, '10.10.0.1')
  end

  # Without path_id nothing changes, which is what keeps every existing
  # topology sending the octets it sent before.
  def test_a_block_with_no_path_id_sends_a_plain_nlri
    u = update('prefixes' => [PREFIX])
    assert_equal [PREFIX], u.nlri.to_ary
    assert_equal '18c63364', u.nlri.to_shex,
                 'one length octet and three prefix octets, no identifier'
  end

  # RFC 7911 section 3: four octets of Path Identifier in front of the
  # prefix, so the NLRI is four octets longer and the prefix is unchanged.
  def test_a_block_with_a_path_id_prefixes_every_nlri_with_it
    u = update('prefixes' => [PREFIX, '203.0.113.0/24'], 'path_id' => 7)
    assert_equal ["ID=7, #{PREFIX}", 'ID=7, 203.0.113.0/24'], u.nlri.to_ary
    assert_equal '0000000718c633640000000718cb0071', u.nlri.to_shex
  end

  # The point of the key: two blocks naming one prefix are two paths to it,
  # which is what RFC 7911 exists for and what no topology could express.
  def test_two_blocks_naming_one_prefix_are_two_paths
    seven = update('prefixes' => [PREFIX], 'path_id' => 7, 'med' => 100)
    nine  = update('prefixes' => [PREFIX], 'path_id' => 9, 'med' => 200)
    assert_not_equal seven.nlri.to_shex, nine.nlri.to_shex,
                     'the identifier is what tells them apart on the wire'
    assert_equal ['ID=7, 198.51.100.0/24'], seven.nlri.to_ary
    assert_equal ['ID=9, 198.51.100.0/24'], nine.nlri.to_ary
  end

  # A string is what YAML gives for an unquoted number in some spellings, and
  # a Path Identifier that silently became 0 would make two blocks one path.
  def test_a_path_id_from_yaml_is_read_as_a_number
    assert_equal '00000007', update('prefixes' => [PREFIX],
                                     'path_id' => '7').nlri.to_shex[0, 8]
    assert_raise(ArgumentError) do
      update('prefixes' => [PREFIX], 'path_id' => 'seven')
    end
  end

  # Nothing validates, per Conventions: a Path Identifier on a session that
  # negotiated none is four unexpected octets in front of every prefix, which
  # is a corrupt UPDATE rather than a wrong route, and a topology has to be
  # able to send one to find out what a router does with it.
  def test_nothing_checks_the_block_against_the_negotiated_capability
    node = { 'as' => 65001, 'router_id' => '10.10.0.1',
             'local_address' => '10.10.0.1',
             'neighbors' => [{ 'address' => '10.10.0.2', 'as' => 65002 }],
             'announce' => [{ 'prefixes' => [PREFIX], 'path_id' => 7 }] }
    s = Lab::Speaker.new(node)
    assert_equal '00000007',
                 s.build_update(node['announce'].first, true, '10.10.0.1')
                  .nlri.to_shex[0, 8],
                 'no add_path capability on that neighbor, and it still sends one'
  end

  # The same octets read by a peer that did not negotiate add-path, which is
  # what makes this a lab case and not only a test: one real prefix comes
  # back as five nonsense ones, a /198 among them. A console shows that; an
  # assertion only counts it.
  def test_the_same_octets_without_add_path_read_as_nonsense
    octets = update('prefixes' => [PREFIX], 'path_id' => 7).encode
    with = BGP::Update.new(octets.is_packed, AddPathInfo.new(true, :lenient))
    assert_equal ["ID=7, #{PREFIX}"], with.nlri.to_ary

    without = BGP::Update.new(octets.is_packed, BGP::Update::Info.new(true, :lenient))
    assert_equal ['0.0.0.0/0', '0.0.0.0/0', '0.0.0.0/0', '24.0.0.0/7',
                  '51.100.0.0/198'],
                 without.nlri.to_ary,
                 'the four identifier octets are read as prefixes, and the ' \
                 'prefix itself as a length of 198'
  end

  # A session that negotiated add-path for IPv4 unicast in our direction.
  # Update::Info answers false for every family, so a receiver has to be
  # told, and this is the smallest thing that tells it.
  class AddPathInfo < BGP::Update::Info
    def recv_inet_unicast? ; true ; end
  end
end

# What the state file says about the peer. A driver reads this file, so the
# capabilities go in it as data: a rendered capability carries the enclosing
# parameter's hex dump, and a reader would have to parse it back out.
class LabSpeakerPeerCapabilitiesTest < Test::Unit::TestCase

  def open_with(*capabilities)
    o = BGP::Open.new(4, 65002, 30, '10.0.0.2', *capabilities)
    BGP::Open.new(o.encode.is_packed)   # read it as a receiver would
  end

  def recorded(*capabilities)
    r = Lab::Recorder.new('routes')
    r.update(open_with(*capabilities))
    r.snapshot
  end

  def test_an_open_with_no_capabilities_records_an_empty_list
    assert_equal [], recorded['peer_capabilities']
  end

  # Each capability's own to_hash is the data, so this adds no per-capability
  # knowledge and gains a capability the day the library does.
  def test_each_capability_is_recorded_as_its_own_hash_with_its_name
    caps = recorded(BGP::OPT_PARM::CAP::As4.new(65002),
                    BGP::OPT_PARM::CAP::Route_refresh.new,
                    BGP::OPT_PARM::CAP::Mbgp.new(1, 1))['peer_capabilities']
    assert_equal %w[As4 Route_refresh Mbgp], caps.collect { |c| c['name'] }
    assert_equal [65, 2, 1], caps.collect { |c| c['code'] }
    assert_equal({ 'as' => 65002 }, caps.first['capability'])
    assert_equal({ 'afi' => 1, 'safi' => 1 }, caps.last['capability'])
  end

  # The field the whole add-path lab turns on. RFC 7911 section 4: the value
  # says what the sender of the capability can do, so a peer advertising 2
  # means it will send us several paths.
  def test_the_add_path_send_receive_field_is_recorded_as_its_value
    { 1 => 'able to receive', 2 => 'able to send', 3 => 'both' }.each do |value, what|
      caps = recorded(BGP::OPT_PARM::CAP::Add_path.new(value, 1, 1))['peer_capabilities']
      assert_equal 'Add_path', caps.first['name']
      assert_equal [{ 'afi' => 1, 'safi' => 1, 'send_recv' => value }],
                   caps.first['capability']['families'],
                   "a peer advertising #{value} is #{what}"
    end
  end

  # JSON has no symbols, so a reader must not have to deal with both
  # spellings. The state file goes through JSON.pretty_generate, where a
  # Symbol key becomes a string anyway and a Symbol value becomes one too,
  # so converting once here is what makes the two agree.
  def test_the_recorded_hash_has_string_keys_so_json_cannot_change_it
    caps = recorded(BGP::OPT_PARM::CAP::Add_path.new(3, 1, 1))['peer_capabilities']
    assert_equal caps, JSON.parse(JSON.generate(caps)),
                 'what is recorded and what is written are the same data'
  end

  # A capability bgp4r has no class for still gets a row, because an unknown
  # capability is exactly what a lab is for: the peer advertised something
  # and the state file has to say so.
  def test_an_unknown_capability_is_still_recorded
    caps = recorded(BGP::OPT_PARM::Capability.new(0x7f))['peer_capabilities']
    assert_equal 1, caps.size
    assert_equal 0x7f, caps.first['code'],
                 'the code is what a reader has to go on, so it must be there'
  end
end
