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

# What lab/topologies/add-path says, read out of its own files.
#
#   ruby -I. test/functional/lab/add_path_topology_test.rb
#
# No Docker, no router, no socket: this loads the node YAML and builds
# what the speaker would send from it. So it catches the thing most
# likely to break a topology, which is a typo in a node file, and it
# holds the folder's README to the files beside it.
#
# It is not interoperability and does not pretend to be. The router's own
# reading of these octets is test/functional/lab/add_path_gobgp_test.rb,
# which needs gobgpd, and the Compose form is the topology itself.
#
# BGP:: names are written out in full, see Conventions in CLAUDE.md.

require 'test/unit'
require 'yaml'
require 'bgp4r'
require 'lab/speaker'

class LabAddPathTopologyTest < Test::Unit::TestCase

  DIR = File.expand_path('../../../lab/topologies/add-path', __dir__)
  PREFIX = '198.51.100.0/24'

  def node(name)
    YAML.safe_load(File.read(File.join(DIR, name)))
  end

  def sim ; @sim ||= node('sim.yml') ; end

  # The UPDATEs sim would send, built the way Peer#announce builds them
  # over eBGP.
  def updates
    s = Lab::Speaker.new(sim)
    sim['announce'].collect { |a| s.build_update(a, true, sim['local_address']) }
  end

  def test_every_node_file_loads_and_names_its_own_address
    { 'sim.yml' => ['10.40.0.1', 65001],
      'peer.yml' => ['10.40.0.3', 65003] }.each do |file, (addr, as)|
      n = node(file)
      assert_equal as, n['as'], "#{file} AS"
      assert_equal addr, n['router_id'], "#{file} router_id"
      assert_equal addr, n['local_address'], "#{file} local_address"
    end
  end

  # Every node file has to build a Speaker, or the topology fails at
  # start-up with a message in a container log nobody is watching.
  def test_every_node_file_builds_a_speaker
    %w[sim.yml peer.yml].each do |file|
      assert_nothing_raised("#{file} does not build") { Lab::Speaker.new(node(file)) }
    end
  end

  # sim dials both receivers, so neither has to win a connection race and
  # the topology comes up the same way every time.
  def test_sim_dials_both_receivers
    peers = sim['neighbors']
    assert_equal ['10.40.0.2', '10.40.0.3'], peers.collect { |p| p['address'] }
    assert_equal [true, true], peers.collect { |p| p['connect'] },
                 'both are active, so neither receiver has to dial'
    assert_nil node('peer.yml')['neighbors'].first['connect'],
               'and peer waits, which is the other half of that'
  end

  # The README says [3, 1, 1] is IPv4 unicast both ways and that the
  # reverse spelling is SAFI 3, NSAP. Hold the files to it, because this
  # is the argument order every comment in the repository had wrong.
  def test_the_capabilities_are_the_pair_the_readme_describes
    both = sim['neighbors'].collect { |p|
      p['capabilities'].find { |c| c.is_a?(Hash) && c['add_path'] }['add_path']
    }
    assert_equal [[3, 1, 1], [3, 1, 1]], both,
                 'sim advertises both directions to both receivers'

    recv = node('peer.yml')['neighbors'].first['capabilities']
              .find { |c| c.is_a?(Hash) && c['add_path'] }['add_path']
    assert_equal [1, 1, 1], recv,
                 'peer advertises receive only, which is the asymmetric case'

    # And what those spellings mean, decoded rather than asserted as hex,
    # since a wrong comment on a hex string can live forever.
    cap = BGP::OPT_PARM::CAP::Add_path.new(*recv)
    assert_equal({ :afi => 1, :safi => 1, :send_recv => 1 },
                 cap.to_hash[:capability][:families].first,
                 'AFI 1, SAFI 1, able to receive')
  end

  # Two blocks, one prefix, two identifiers. This is what no topology
  # could express before, and it is the whole point of the folder.
  def test_the_two_announce_blocks_are_two_paths_to_one_prefix
    nlris = updates.collect { |u| u.nlri.to_ary }
    assert_equal [["ID=7, #{PREFIX}"], ["ID=9, #{PREFIX}"]], nlris
    assert_not_equal updates[0].nlri.to_shex, updates[1].nlri.to_shex
  end

  # GoBGP does not echo the identifier in its RIB, so without different
  # next hops a reader of the router cannot tell the two paths apart at
  # all. The README says so; this is what stops a later edit making the
  # two blocks identical in every field the router reports.
  def test_the_two_paths_differ_in_what_the_router_can_actually_report
    hops = updates.collect { |u| u.path_attribute[:next_hop].next_hop }
    assert_equal ['10.40.0.7', '10.40.0.9'], hops
    paths = updates.collect { |u| u.path_attribute[:as_path].as_path }
    assert_equal ['65001 65010', '65001 65011 65012'], paths,
                 'our own AS first, RFC 4271 section 5.1.2 over eBGP'
  end

  # RFC 4271 section 9.1.2.2 a). The README and both scenarios claim
  # 10.40.0.7 wins, and this is the file that makes the claim checkable
  # without a router.
  def test_the_shorter_as_path_is_the_one_the_readme_calls_best
    by_length = updates.sort_by { |u| u.path_attribute[:as_path].as_path.split.size }
    assert_equal '10.40.0.7', by_length.first.path_attribute[:next_hop].next_hop
  end

  # Each scenario file has to load and name steps, or it is prose with a
  # .yml extension. Nothing runs them yet, so this is the only thing
  # between them and a syntax error.
  def test_every_scenario_loads_and_has_steps
    files = Dir[File.join(DIR, 'scenarios', '*.yml')].sort
    assert_equal %w[two-paths.yml unnegotiated-path-id.yml withdraw-one-path.yml],
                 files.collect { |f| File.basename(f) }
    files.each do |f|
      s = YAML.safe_load(File.read(f))
      assert_kind_of String, s['name'], "#{File.basename(f)} name"
      assert_operator s['steps'].size, :>=, 3, "#{File.basename(f)} steps"
      assert_operator s['timeout'], :>, 0, "#{File.basename(f)} timeout"
    end
  end

  # The two scenarios that need the injector have to say so, because a
  # reader who runs them against today's lab gets no error, only steps
  # that never pass. The README's table says which; this keeps the files
  # and the table in step.
  def test_the_scenarios_that_need_the_injector_say_so
    { 'withdraw-one-path.yml' => true, 'unnegotiated-path-id.yml' => true,
      'two-paths.yml' => false }.each do |file, needs|
      body = File.read(File.join(DIR, 'scenarios', file))
      uses_action = body.match?(/^\s+- bgp: /)
      assert_equal needs, uses_action, "#{file} uses a bgp: action"
      next unless needs
      assert_match(/NEEDS THE INJECTOR/, body,
                   "#{file} takes an action, so it must say it cannot run yet")
    end
  end

  # lab.yml is read by nothing today, so a typo in it is invisible. The
  # node names and addresses have to match the compose file and the node
  # files, since that is the whole content of a manifest.
  def test_the_routescope_manifest_matches_the_topology
    lab = YAML.safe_load(File.read(File.join(DIR, 'lab.yml')))
    assert_equal %w[sim gobgp peer], lab['nodes'].collect { |n| n['name'] }
    assert_equal %w[10.40.0.1 10.40.0.2 10.40.0.3],
                 lab['nodes'].collect { |n| n['address'] }

    compose = File.read(File.join(DIR, 'compose.yml'))
    lab['nodes'].each do |n|
      assert_match(/^  #{n['service']}:$/, compose,
                   "compose.yml has no service #{n['service']}")
      assert_match(/ipv4_address: #{Regexp.escape(n['address'])}\b/, compose,
                   "compose.yml does not give #{n['name']} #{n['address']}")
      assert_path_exist File.join(DIR, n['config'])
    end
  end
end
