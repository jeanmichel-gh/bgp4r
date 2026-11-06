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

# What lab/routescope/fwd-lab says, read out of its own files.
#
#   ruby -I. test/functional/lab/fwd_lab_topology_test.rb
#
# No Docker, no namespace and no socket, so it runs on every pull
# request. It parses the containerlab topology, loads each node file
# through bgp4rd's own loader, checks that both ends of every session
# name each other, and holds the scenarios to routescope's vocabulary.
#
# Whether packets cross the routers is fwd_lab_netns_test.rb's question,
# which runs these same files in network namespaces, and capture.sh's,
# which runs them in containers in CI.
#
# Every file is read with an explicit encoding; CLAUDE.md records why.

require 'test/unit'
require 'yaml'
require 'ipaddr'
require 'stringio'
require 'bgp4r'
require 'bgp/daemon'
require_relative 'routescope_vocabulary'

class LabFwdLabTopologyTest < Test::Unit::TestCase

  DIR = File.expand_path('../../../lab/routescope/fwd-lab', __dir__)
  SIBLING = File.expand_path('../../../lab/routescope/bgp4r-lab', __dir__)
  WORKFLOW = File.expand_path('../../../.github/workflows/capture.yml', __dir__)

  # node => [AS, loopback]
  NODES = { 'a' => [65001, '10.255.0.1'], 'b' => [65002, '10.255.0.2'],
            'c' => [65003, '10.255.0.3'], 'd' => [65004, '10.255.0.4'] }.freeze

  def read(rel, dir = DIR) ; File.read(File.join(dir, rel), :encoding => 'UTF-8') ; end
  def load_yaml(rel) ; YAML.safe_load(read(rel)) ; end

  def clab ; @clab ||= load_yaml('fwd-lab.clab.yml') ; end
  def nodes ; clab['topology']['nodes'] ; end
  def links ; clab['topology']['links'].collect { |l| l['endpoints'] } ; end

  # Every `ip addr add A/L dev IFACE` the topology runs, per node.
  def addresses
    @addresses ||= nodes.to_h { |name, n|
      [name, Array(n['exec']).each_with_object({}) { |line, h|
        m = line.to_s.match(/ip addr add (\S+) dev (\S+)/) or next
        h[m[2]] = m[1]
      }]
    }
  end

  def config(name)
    @configs ||= {}
    @configs[name] ||= begin
      err = StringIO.new
      c = BGP::Daemon::Server.new(StringIO.new, err).load_config(:config => File.join(DIR, name, 'bgp4rd.yml'))
      assert_not_nil c, "#{name}/bgp4rd.yml did not load: #{err.string}"
      BGP::Daemon::Server.with_defaults(c)
    end
  end

  def scenario_files
    Dir[File.join(DIR, 'scenarios', '*.yml')].sort.collect { |f| File.basename(f) }
  end

  # ---------------------------------------------------------------- the topology

  def test_four_bgp4rd_nodes_and_the_square_with_one_diagonal
    assert_equal 'fwd-lab', clab['name']
    assert_equal NODES.keys, nodes.keys
    assert_equal [%w[a:eth1 b:eth1], %w[b:eth2 c:eth1], %w[c:eth2 d:eth1], %w[b:eth3 d:eth2]], links
    nodes.each do |name, n|
      assert_equal 'bgp4r', n['labels']['routescope.kind'], name
      assert_equal 'bgp', n['labels']['routescope.protocols'], name
      assert_equal 'Dockerfile.node', n['labels']['routescope.build'], name
      assert_equal 'bgp4r-lab:latest', n['image'], name
      assert_equal "exe/bgp4rd -f /etc/bgp4r/bgp4rd.yml -s /run/bgp4r/bgp4rd.sock -l -", n['cmd'], name
      assert_equal ["#{name}/bgp4rd.yml:/etc/bgp4r/bgp4rd.yml"], n['binds'], name
    end
  end

  # The image is bgp4r-lab's. routescope builds from this folder, so the
  # copy must build the same image, ping and traceroute included.
  def test_the_dockerfile_is_bgp4r_labs_with_ping_and_traceroute
    instructions = ->(text) { text.lines.reject { |l| l =~ /\A\s*(#|\z)/ } }
    assert_equal instructions.(read('Dockerfile.node', SIBLING)), instructions.(read('Dockerfile.node'))
    assert_match(/^# A copy of \.\.\/bgp4r-lab\/Dockerfile\.node/, read('Dockerfile.node'))
    root = File.read(File.expand_path('../../../Dockerfile', __dir__))
    [read('Dockerfile.node'), root[root.index('AS lab-node')..]].each do |t|
      assert_match(/install -y --no-install-recommends iproute2 iputils-ping traceroute/, t)
    end
  end

  # Both ends of a link in one /30, a loopback on lo, and forwarding on.
  def test_every_node_has_its_loopback_and_forwards
    links.each do |x, y|
      ax, ay = [x, y].collect { |e| n, i = e.split(':') ; addresses.fetch(n)[i] }
      assert_not_nil ax, "#{x} has no address"
      assert_not_nil ay, "#{y} has no address"
      assert_equal IPAddr.new(ax).to_s, IPAddr.new(ay).to_s, "#{x} #{y} are not in one prefix"
      assert_equal '/30', ax[/\/\d+\z/]
    end
    NODES.each do |name, (_as, lo)|
      assert_equal "#{lo}/32", addresses[name]['lo'], name
      assert_include nodes[name]['exec'], 'sh -c "echo 1 > /proc/sys/net/ipv4/ip_forward"', name
    end
  end

  # ---------------------------------------------------------------- the node files

  # Each node is the router the README says: its AS, its loopback as the
  # router ID and the one prefix it originates, transit on, and the main
  # table, which is the one the kernel forwards from.
  def test_each_node_file_is_a_transit_router_into_the_main_table
    NODES.each do |name, (as, lo)|
      c = config(name)
      assert_equal as, c['as'], name
      assert_equal lo, c['router_id'], name
      assert_equal [{ 'prefixes' => ["#{lo}/32"] }], c['originate'], name
      assert_equal({}, c['export'], name)
      assert_equal({ 'table' => 254 }, c['fib'], name)
      BGP::Daemon::Speaker.new(c)
    end
  end

  # Every link is one session: each end names the other's address and
  # AS, and exactly one end dials, so the two never race.
  def test_both_ends_of_every_link_name_each_other_and_one_dials
    links.each do |x, y|
      (xn, xi), (yn, yi) = x.split(':'), y.split(':')
      ends = [[xn, yn, addresses[yn][yi]], [yn, xn, addresses[xn][xi]]].collect do |me, far, far_addr|
        nb = config(me)['neighbors'].find { |n| n['address'] == far_addr.split('/').first }
        assert_not_nil nb, "#{me} has no neighbor at #{far_addr}"
        assert_equal NODES[far][0], nb['as'], "#{me} names #{far}'s AS"
        assert_equal 9, nb['hold_time'], "#{me} toward #{far}"
        nb
      end
      assert_equal 1, ends.count { |nb| nb['connect'] == true }, "#{x} #{y}: exactly one end dials"
    end
    NODES.each_key do |name|
      assert_equal links.count { |l| l.any? { |e| e.start_with?("#{name}:") } },
                   config(name)['neighbors'].size, "#{name} has one neighbor per link"
    end
  end

  # ---------------------------------------------------------------- the scenarios

  SCENARIOS = %w[d-cut-off.yml direct-link-wins.yml link-down-moves-to-c.yml
                 session-stop-moves-to-c.yml].freeze

  def test_every_scenario_step_is_in_the_language_a_scenario_runner_reads
    v = RoutescopeVocabulary
    assert_equal SCENARIOS, scenario_files
    checked = 0
    scenario_files.each do |f|
      s = load_yaml("scenarios/#{f}")
      assert_equal [], s.keys - %w[name description capture timeout steps], f
      assert_match(/^# NOT RUN: the lab is deployed by bgp4r's Capture job, but this scenario\n# has not been run/,
                   read("scenarios/#{f}"), f)
      s['steps'].each_with_index do |step, i|
        where = "#{f} step #{i}"
        kinds = step.keys & %w[bgp expect mark interface]
        assert_equal 1, kinds.size, "#{where}: one action per step"
        kind = kinds.first
        extra = { 'bgp' => v::BGP_KEYS, 'expect' => %w[within measure],
                  'interface' => v::INTERFACE_KEYS }.fetch(kind, [])
        assert_equal [], step.keys - (v::COMMON + [kind] + extra), "#{where}: #{kind} does not take those keys"
        checked += 1
        case kind
        when 'bgp'
          assert_include v::BGP_ACTIONS, step['bgp'], where
          assert_include NODES.keys, step['node'], where
        when 'interface'
          node, iface = step['interface'].split(':')
          assert_include addresses.fetch(node).keys, iface, "#{where}: no such interface"
          assert_include %w[up down], step['state'], where
        when 'expect'
          name, params = step['expect'].first
          assert_not_nil v::CONDITIONS[name], "#{where}: unknown condition #{name}"
          assert_equal [], params.keys - v::CONDITIONS[name], "#{where}: #{name} does not take those keys"
          assert_include NODES.keys, params['node'].to_s, where unless name == 'bgp_drained'
        end
      end
    end
    assert_operator checked, :>=, 30, 'the walk found almost no steps'
  end

  # A link a scenario takes down comes back up in the same scenario, or
  # the next one starts on a broken lab.
  def test_every_interface_taken_down_is_brought_back_up
    scenario_files.each do |f|
      steps = load_yaml("scenarios/#{f}")['steps'].select { |s| s['interface'] }
      down = steps.select { |s| s['state'] == 'down' }.collect { |s| s['interface'] }
      up = steps.select { |s| s['state'] == 'up' }.collect { |s| s['interface'] }
      assert_equal down.sort, up.sort, f
    end
  end

  # ---------------------------------------------------------------- the rest

  def test_ci_deploys_it_and_runs_its_capture_script
    wf = File.read(WORKFLOW, :encoding => 'UTF-8')
    job = wf[/^  fwd-lab:\n.*?(?=^  \S|\z)/m].to_s
    assert_include job, 'containerlab deploy -t lab/routescope/fwd-lab/fwd-lab.clab.yml'
    assert_include job, 'bash lab/routescope/fwd-lab/capture.sh'
    assert(File.executable?(File.join(DIR, 'capture.sh')), 'capture.sh is executable')
  end

  def test_the_readme_and_about_name_every_node
    [read('README.md'), read('ABOUT.md')].each do |t|
      NODES.each { |name, (as, lo)| assert_match(/`#{name}`.*#{as}|#{lo}/m, t) }
    end
  end
end
