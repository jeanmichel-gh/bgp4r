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

# What routescope/labs/rr-lab says, read out of its own files.
#
#   ruby -I. test/functional/lab/rr_lab_topology_test.rb
#
# No Docker, no router binary and no socket. It parses the containerlab
# topology, loads each bgp4r node file through the program that reads
# it, reads the FRR, BIRD and GoBGP configs as text, and holds the
# scenarios to routescope's vocabulary. bgp4r_lab_topology_test.rb is the
# same shape for the lab beside this one.
#
# What it cannot say is whether reflection works between these four
# implementations. CI's Capture job deploys the lab and capture.sh
# checks that.
#
# Every file is read with an explicit encoding; CLAUDE.md records why.
# BGP:: names are written out in full, see Conventions in CLAUDE.md.

require 'test/unit'
require 'yaml'
require 'ipaddr'
require 'stringio'
require 'bgp4r'
require 'bgp/daemon'
require 'bgp/sim'
require_relative 'routescope_vocabulary'

class LabRrLabTopologyTest < Test::Unit::TestCase

  DIR = File.expand_path('../../../routescope/labs/rr-lab', __dir__)
  SIBLING = File.expand_path('../../../routescope/labs/bgp4r-lab', __dir__)
  WORKFLOW = File.expand_path('../../../.github/workflows/capture.yml', __dir__)

  NODES = { 'inj-c' => 'bgp4r-sim', 'inj-n' => 'bgp4r-sim', 'inj-e' => 'bgp4r-sim',
            'rr1' => 'bgp4r', 'rr2' => 'frr', 'c1' => 'frr', 'c2' => 'bird',
            'c3' => 'gobgp', 'dual' => 'bgp4r' }.freeze

  INJECTORS = { 'inj-c' => 'inj-c/sim.yml', 'inj-n' => 'inj-n/sim.yml',
                'inj-e' => 'inj-e/sim.yml' }.freeze
  DAEMONS = { 'rr1' => 'rr1/bgp4rd.yml', 'dual' => 'dual/bgp4rd.yml' }.freeze

  # rr1's roles, by node. The whole lab is built around this split.
  CLIENTS = %w[inj-c c1 c2 c3 dual].freeze
  NON_CLIENTS = %w[inj-n rr2].freeze
  EXTERNAL = %w[inj-e].freeze

  CLUSTER_1 = '1.1.1.1'
  CLUSTER_2 = '2.2.2.2'
  RR1_ID = '10.100.255.2'
  RR2_ID = '10.100.255.1'
  INJ_C_ID = '10.100.255.11'

  # The one prefix a static route on each FRR and BIRD node points at.
  LAB_NET = IPAddr.new('10.100.0.0/16')

  def read(rel, dir = DIR) ; File.read(File.join(dir, rel), :encoding => 'UTF-8') ; end
  def load_yaml(rel) ; YAML.safe_load(read(rel)) ; end

  def clab ; @clab ||= load_yaml('rr-lab.clab.yml') ; end
  def nodes ; clab['topology']['nodes'] ; end
  def links ; clab['topology']['links'] ; end
  def readme ; @readme ||= read('README.md') ; end
  def capture ; @capture ||= read('capture.sh') ; end

  # Every `ip addr add A/L dev IFACE` the topology runs, per node.
  def addresses
    @addresses ||= nodes.to_h { |name, n|
      [name, Array(n['exec']).each_with_object({}) { |line, h|
        m = line.to_s.match(/ip addr add (\S+) dev (\S+)/) or next
        h[m[2]] = m[1]
      }]
    }
  end

  # A node's address on the link to another, which is what the far side
  # names it by.
  def address_toward(node, other)
    link = links.find { |l| l['endpoints'].collect { |e| e.split(':').first }.sort == [node, other].sort }
    assert_not_nil link, "no link between #{node} and #{other}"
    iface = link['endpoints'].find { |e| e.start_with?("#{node}:") }.split(':').last
    addresses.fetch(node).fetch(iface).split('/').first
  end

  def daemon(name)
    @daemons ||= {}
    @daemons[name] ||= begin
      err = StringIO.new
      config = BGP::Daemon::Server.new(StringIO.new, err).load_config(:config => File.join(DIR, DAEMONS[name]))
      assert_not_nil config, "#{DAEMONS[name]} did not load: #{err.string}"
      BGP::Daemon::Speaker.new(BGP::Daemon::Server.with_defaults(config))
    end
  end

  def scenario_files
    Dir[File.join(DIR, 'scenarios', '*.yml')].sort.collect { |f| File.basename(f) }
  end

  # The rr-lab job of the Capture workflow, as text, up to the next job.
  def job
    wf = File.read(WORKFLOW, :encoding => 'UTF-8')
    wf[/^  rr-lab:\n.*?(?=^  \S|\z)/m].to_s
  end

  # ---------------------------------------------------------------- the topology

  def test_the_topology_names_nine_nodes_and_nine_links
    assert_equal 'rr-lab', clab['name']
    assert_equal NODES.keys.sort, nodes.keys.sort
    assert_equal 9, links.size, 'nine links, one per session'
  end

  # The one kind here routescope has no driver for, as in bgp4r-lab.
  def test_the_kinds_routescope_knows_and_the_one_it_does_not
    unknown = NODES.values.uniq - RoutescopeVocabulary::KINDS
    assert_equal %w[gobgp], unknown, 'the kinds routescope lacks have changed: re-read Lab::KINDS'
    assert_include read('rr-lab.clab.yml'), 'routescope b8e2704'
  end

  def test_every_node_carries_both_routescope_labels
    NODES.each do |name, kind|
      labels = nodes.fetch(name)['labels']
      assert_kind_of Hash, labels, "#{name} has no labels"
      assert_equal kind, labels['routescope.kind'], "#{name} kind"
      assert_equal 'bgp', labels['routescope.protocols'], "#{name} protocols"
    end
  end

  # routescope builds local images from the lab's own folder, so every
  # local image names a Dockerfile here. The three are copies of
  # bgp4r-lab's and must stay the same instructions, or the two labs
  # build different nodes under one tag. Comments may differ; the copy
  # header says where the reasons are.
  def test_every_local_image_names_a_dockerfile_that_matches_bgp4r_lab
    nodes.each do |name, n|
      image = n['image'].to_s
      build = (n['labels'] || {})['routescope.build']
      if image.start_with?('quay.io/')
        assert_nil build, "#{name}: #{image} is pulled and needs no build"
        next
      end
      assert build, "#{name}: #{image} is local and has no routescope.build label"
      assert File.file?(File.join(DIR, build)), "#{name}: #{build} is not in #{DIR}"
    end
    instructions = ->(text) { text.lines.reject { |l| l =~ /\A\s*(#|\z)/ } }
    %w[Dockerfile.node Dockerfile.bird Dockerfile.gobgp].each do |f|
      assert_equal instructions.(read(f, SIBLING)), instructions.(read(f)),
                   "#{f} here and in bgp4r-lab build different images"
      assert_match(/^# A copy of \.\.\/bgp4r-lab\/#{Regexp.escape(f)}/, read(f))
    end
    assert_match(/\A# syntax=docker\/dockerfile:1\n/, read('Dockerfile.node'),
                 'ADD of a git URL needs the BuildKit frontend line first')
  end

  def test_the_links_are_the_nine_sessions_the_readme_draws
    want = [%w[inj-c:eth1 rr1:eth1], %w[inj-n:eth1 rr1:eth2], %w[inj-e:eth1 rr1:eth3],
            %w[rr1:eth4 c1:eth1], %w[rr1:eth5 c2:eth1], %w[rr1:eth6 c3:eth1],
            %w[rr1:eth7 dual:eth1], %w[rr1:eth8 rr2:eth1], %w[rr2:eth2 dual:eth2]]
    assert_equal want, links.collect { |l| l['endpoints'] }
  end

  # Both ends of a link in one prefix, and every address in the one
  # prefix the static routes cover, or a reflected next hop does not
  # resolve at FRR and BIRD and the route is never best there.
  def test_every_link_is_addressed_in_one_prefix_inside_the_lab_net
    links.each do |l|
      a, b = l['endpoints'].collect do |e|
        node, iface = e.split(':')
        addr = addresses.fetch(node)[iface]
        assert_not_nil addr, "#{e} has no ip addr add in the topology"
        addr
      end
      assert_equal IPAddr.new(a).to_s, IPAddr.new(b).to_s, "#{l['endpoints'].inspect} are not in one prefix"
      assert_not_equal a, b
      [a, b].each { |x| assert LAB_NET.include?(IPAddr.new(x.split('/').first)), "#{x} is outside #{LAB_NET}" }
    end
  end

  # ------------------------------------------------------------- the node files

  def test_every_bgp4r_node_file_loads_through_the_program_that_reads_it
    INJECTORS.each do |name, file|
      i = nil
      assert_nothing_raised("#{file} is not a node file bgp4r-sim accepts") do
        i = BGP::Sim::Injector.new(load_yaml(file))
      end
      assert_equal 1, i.speaker.peers.size, "#{name} has one session"
      assert_nil i.speaker.rib, "#{name} holds no Loc-RIB"
    end
    assert_equal 8, daemon('rr1').peers.size, 'rr1 has eight sessions'
    assert_not_nil daemon('rr1').rib
    assert_equal 2, daemon('dual').peers.size, 'dual has two sessions'
    assert_not_nil daemon('dual').rib, 'dual holds a table, so it can say why'
  end

  # The split the lab is built on, read through the daemon's own answer
  # rather than the YAML: rr1's clients, non-clients and external peer.
  def test_rr1_reflects_for_exactly_the_clients_the_topology_draws
    rr1 = daemon('rr1')
    want = CLIENTS.collect { |n| address_toward(n, 'rr1') }
    assert_equal want.sort, rr1.reflector_clients.sort
    by = rr1.peers.to_h { |p| [p.address, p] }
    (CLIENTS + NON_CLIENTS).each { |n| assert !by.fetch(address_toward(n, 'rr1')).ebgp?, "#{n} is internal" }
    EXTERNAL.each { |n| assert by.fetch(address_toward(n, 'rr1')).ebgp?, "#{n} is external" }
    assert_equal (NODES.keys - ['rr1']).sort, (CLIENTS + NON_CLIENTS + EXTERNAL).sort,
                 'every other node has one role toward rr1'
  end

  # BIRD refuses an OPEN that carries capabilities but no Multiprotocol
  # one, with 2/7: it treats IPv4 unicast as negotiated only when the
  # peer sends no capabilities at all. The first deploy measured that.
  def test_rr1_offers_bird_the_multiprotocol_capability
    c2 = load_yaml(DAEMONS['rr1'])['neighbors'].find { |p| p['address'] == address_toward('c2', 'rr1') }
    assert_include c2['capabilities'], 'mbgp_ipv4_unicast'
  end

  # The cluster ID is not the router ID, so a CLUSTER_LIST read at a
  # client says which of the two rr1 put there.
  def test_rr1s_cluster_id_is_its_own_and_not_its_router_id
    rr1 = load_yaml(DAEMONS['rr1'])
    assert_equal RR1_ID, rr1['router_id']
    assert_equal CLUSTER_1, rr1['export']['cluster_id']
    assert_not_equal rr1['router_id'], rr1['export']['cluster_id']
    assert_equal({ 'cluster_id' => CLUSTER_1 }, rr1['export'],
                 'the flags turn reflection on; export only names the cluster')
  end

  # dual is a client of both reflectors, holds a table and sends nothing.
  def test_dual_is_a_client_of_both_reflectors_and_advertises_nothing
    d = load_yaml(DAEMONS['dual'])
    assert_equal [address_toward('rr1', 'dual'), address_toward('rr2', 'dual')].sort,
                 d['neighbors'].collect { |p| p['address'] }.sort
    assert_equal true, d['rib']
    %w[export originate fib].each { |k| assert_nil d[k], "dual has #{k}, so it would send or install" }
    assert_include daemon('rr1').reflector_clients, address_toward('dual', 'rr1')
    assert_match(/^  neighbor #{Regexp.escape(address_toward('dual', 'rr2'))} route-reflector-client$/,
                 read('rr2/frr.conf'))
  end

  # The section 9 tie break only tells right from wrong when rr2's
  # router ID is lower: a decision comparing peer IDs would then pick
  # rr2's copy at the router ID step, where the right one ties there.
  def test_rr2s_router_id_is_lower_than_rr1s
    assert_match(/^ bgp router-id #{Regexp.escape(RR2_ID)}$/, read('rr2/frr.conf'))
    assert_operator IPAddr.new(RR2_ID).to_i, :<, IPAddr.new(RR1_ID).to_i
  end

  def test_no_injector_announces_and_the_non_client_has_one_session
    INJECTORS.each_value do |file|
      n = load_yaml(file)
      assert_nil n['announce'], "#{file} announces, so it does not start silent"
      assert_equal [true], n['neighbors'].collect { |p| p['connect'] }, "#{file} dials"
    end
    # inj-n must not be meshed with rr2, or rr2 holds its route anyway.
    assert_equal [address_toward('rr1', 'inj-n')], load_yaml(INJECTORS['inj-n'])['neighbors'].collect { |p| p['address'] }
    assert_not_match(/#{Regexp.escape(address_toward('inj-n', 'rr1'))}/, read('rr2/frr.conf'))
  end

  def test_every_node_file_address_is_one_the_topology_assigns
    INJECTORS.each do |name, file|
      n = load_yaml(file)
      assert_equal addresses.fetch(name)['eth1'].split('/').first, n['local_address'], "#{name} local_address"
      assert_equal [address_toward('rr1', name)], n['neighbors'].collect { |p| p['address'] }
    end
    assigned = addresses.values.flat_map(&:values).collect { |a| a.split('/').first }
    DAEMONS.each do |name, file|
      n = load_yaml(file)
      assert_nil n['local_address'], "#{name} has several links, so its next hop is per session"
      n['neighbors'].each { |p| assert_include assigned, p['address'], "#{name} peer #{p['address']}" }
    end
  end

  # bgp4r-lab's g1 took a deploy down by binding a link address before
  # containerlab added it. Same scan, over this lab's files.
  STARTUP_LISTEN_KEYS = %w[local-address-list listen_address listen\ bgp\ address].freeze

  def test_no_node_binds_a_link_address_before_the_topology_adds_it
    wired = addresses.values.flat_map(&:values).collect { |a| a.split('/').first }
    nodes.each_key do |name|
      files = Dir[File.join(DIR, name, '*')].select { |f| File.file?(f) }
      assert_not_empty files, "#{name} has no config file"
      files.each do |path|
        File.read(path, :encoding => 'UTF-8').each_line do |line|
          next if line =~ %r{^\s*(?:[#!]|//)}
          STARTUP_LISTEN_KEYS.each do |key|
            next unless line.include?(key)
            assert_empty wired.select { |a| line.include?(a) },
                         "#{name}/#{File.basename(path)} binds a link address through #{key}"
          end
        end
      end
    end
  end

  # ---------------------------------------------------------- the router configs

  def test_rr2_reflects_for_dual_only_in_cluster_2
    f = read('rr2/frr.conf')
    assert_match(/^router bgp 65100$/, f)
    assert_match(/^ bgp cluster-id #{Regexp.escape(CLUSTER_2)}$/, f)
    assert_match(/^ neighbor #{Regexp.escape(address_toward('rr1', 'rr2'))} remote-as 65100$/, f)
    assert_match(/^ neighbor #{Regexp.escape(address_toward('dual', 'rr2'))} remote-as 65100$/, f)
    assert_equal 1, f.scan(/^\s+neighbor \S+ route-reflector-client$/).size,
                 'rr2 has one client, dual; rr1 is a non-client'
  end

  # Every FRR and BIRD node resolves the lab's next hops through one
  # static route toward rr1, and nothing sets next-hop-self, which would
  # hide whether reflection left NEXT_HOP alone.
  def test_frr_and_bird_resolve_the_lab_net_toward_rr1
    { 'rr2' => 'rr2/frr.conf', 'c1' => 'c1/frr.conf' }.each do |n, file|
      f = read(file)
      assert_match(/^ip route #{Regexp.escape(LAB_NET.to_s)}\/16 #{Regexp.escape(address_toward('rr1', n))}$/, f, n)
      assert_not_match(/next-hop-self/, f.lines.reject { |l| l.start_with?('!') }.join, n)
      assert_match(/^bgpd=yes$/, read("#{n}/daemons"))
      assert_match(/^zebra=yes$/, read("#{n}/daemons"))
      assert_match(/^staticd=yes$/, read("#{n}/daemons"))
    end
    assert_match(/^ neighbor #{Regexp.escape(address_toward('rr1', 'c1'))} remote-as 65100$/, read('c1/frr.conf'))

    b = read('c2/bird.conf')
    assert_match(/^  route 10\.100\.0\.0\/16 via #{Regexp.escape(address_toward('rr1', 'c2'))};$/, b)
    assert_match(/^  neighbor #{Regexp.escape(address_toward('rr1', 'c2'))} as 65100;$/, b)
    assert_match(/^    gateway recursive;$/, b, 'a direct iBGP session drops an off-link next hop without it')
    assert_match(/^    export none;$/, b)
  end

  # GoBGP, read as text, since toml is not a default gem.
  def test_the_gobgp_client_agrees_with_the_topology
    t = read('c3/gobgpd.toml')
    assert_match(/^\s*as = 65100$/, t)
    assert_match(/^\s*peer-as = 65100$/, t)
    assert_match(/^\s*neighbor-address = "#{Regexp.escape(address_toward('rr1', 'c3'))}"$/, t)
    assert_match(/^\s*local-address = "#{Regexp.escape(address_toward('c3', 'rr1'))}"$/, t)
  end

  # ------------------------------------------------------------- the loop UPDATEs

  # The two replayed UPDATEs, decoded: each must carry what its scenario
  # says, and the scenario, capture.sh and this test must agree on the
  # octets. A hex string nobody decodes is a claim nobody checked.
  def replayed(file)
    steps = load_yaml("scenarios/#{file}")['steps'].select { |s| s['bgp'] == 'replay' }
    assert_equal 1, steps.size, "#{file} replays once"
    steps.first['hex'].to_s
  end

  def decode(hex)
    BGP::Update.new([hex].pack('H*').is_packed, BGP::Update::Info.new(true))
  end

  def test_the_cluster_loop_carries_rr1s_cluster_id
    hex = replayed('cluster-loop-is-dropped.yml')
    assert_equal capture[/^CLUSTER_LOOP=(\h+)$/, 1], hex, 'capture.sh replays other octets'
    u = decode(hex)
    pa = u.path_attribute
    assert_equal [], pa.errors, 'a loop must not be a malformed attribute, or it tests the wrong thing'
    assert_equal [CLUSTER_1], pa[BGP::ATTR::CLUSTER_LIST].cluster_ids
    assert_equal load_yaml(DAEMONS['rr1'])['export']['cluster_id'], CLUSTER_1
    assert_nil pa[BGP::ATTR::ORIGINATOR_ID]
    assert_equal address_toward('inj-c', 'rr1'), pa[BGP::ATTR::NEXT_HOP].next_hop
    assert_equal ['10.10.6.0/24'], u.nlri.to_ary
  end

  def test_the_originator_loop_carries_rr1s_router_id
    hex = replayed('originator-loop-is-dropped.yml')
    assert_equal capture[/^ORIGINATOR_LOOP=(\h+)$/, 1], hex, 'capture.sh replays other octets'
    u = decode(hex)
    pa = u.path_attribute
    assert_equal [], pa.errors
    assert_equal load_yaml(DAEMONS['rr1'])['router_id'], pa[BGP::ATTR::ORIGINATOR_ID].originator_id
    assert_nil pa[BGP::ATTR::CLUSTER_LIST]
    assert_equal address_toward('inj-c', 'rr1'), pa[BGP::ATTR::NEXT_HOP].next_hop
    assert_equal ['10.10.7.0/24'], u.nlri.to_ary
  end

  # And rr1's own decision drops both, measured on a table built from its
  # node file rather than argued: the same RIB the daemon builds.
  def test_rr1s_table_drops_both_loops_and_keeps_a_clean_route
    table = daemon('rr1').rib
    peer = BGP::Rib::Peer.new(address: address_toward('inj-c', 'rr1'), remote_as: 65100,
                              router_id: INJ_C_ID, local_as: 65100)
    %w[cluster-loop-is-dropped.yml originator-loop-is-dropped.yml].each do |f|
      u = decode(replayed(f))
      table.announce(BGP::Rib::Route.new(u.nlri.to_ary.first, u.path_attribute, peer))
      assert_nil table.best(u.nlri.to_ary.first), "#{f}: rr1 would use the looped route"
    end
    clean = decode(replayed('cluster-loop-is-dropped.yml')).path_attribute
    clean.delete(BGP::Cluster_list)
    table.announce(BGP::Rib::Route.new('10.10.5.0/24', clean, peer))
    assert_not_nil table.best('10.10.5.0/24'), 'the same UPDATE with no loop is used'
  end

  # ---------------------------------------------------------------- the scenarios

  SCENARIOS = %w[client-reflects-to-everyone.yml cluster-loop-is-dropped.yml
                 ebgp-reaches-every-internal-peer.yml flap-and-reflect-again.yml
                 generated-feed-is-reflected.yml
                 non-client-reaches-clients-only.yml originator-loop-is-dropped.yml
                 shorter-cluster-list-wins.yml withdraw-reaches-every-reader.yml].freeze

  def test_every_scenario_loads_and_has_a_name_steps_and_a_timeout
    assert_equal SCENARIOS, scenario_files
    scenario_files.each do |f|
      s = load_yaml("scenarios/#{f}")
      assert_equal [], s.keys - %w[name description capture timeout steps], f
      assert_kind_of String, s['name'], f
      assert_operator s['steps'].size, :>=, 5, f
      assert_operator s['timeout'], :>, 0, f
    end
  end

  def test_every_scenario_step_is_in_the_language_a_scenario_runner_reads
    v = RoutescopeVocabulary
    checked = 0
    scenario_files.each do |f|
      load_yaml("scenarios/#{f}")['steps'].each_with_index do |step, i|
        where = "#{f} step #{i}"
        kinds = step.keys & %w[bgp expect mark pause]
        assert_equal 1, kinds.size, "#{where}: one action per step"
        kind = kinds.first
        extra = { 'bgp' => v::BGP_KEYS, 'expect' => %w[within measure], 'pause' => v::PAUSE_KEYS }.fetch(kind, [])
        assert_equal [], step.keys - (v::COMMON + [kind] + extra), "#{where}: #{kind} does not take those keys"
        next if kind == 'mark'
        if kind == 'pause'
          assert_kind_of String, step['pause'], "#{where}: a pause says what to do meanwhile"
          next
        end
        checked += 1
        if kind == 'bgp'
          assert_include v::BGP_ACTIONS, step['bgp'], where
          assert_include INJECTORS.keys, step['node'], "#{where}: only an injector takes an action here"
        else
          name, params = step['expect'].first
          assert_equal 1, step['expect'].size, where
          assert_not_nil v::CONDITIONS[name], "#{where}: unknown condition #{name}"
          assert_equal [], params.keys - v::CONDITIONS[name], "#{where}: #{name} does not take those keys"
          next if name == 'bgp_drained' && !params.key?('node')
          assert_include NODES.keys, params['node'].to_s, where
        end
      end
    end
    assert_operator checked, :>=, 80, 'the walk found almost no steps'
  end

  def test_every_scenario_says_it_has_not_been_run
    scenario_files.each do |f|
      assert_match(/^# NOT RUN: the lab is deployed by bgp4r's Capture job, but this scenario\n# has not been run/,
                   read("scenarios/#{f}"), f)
    end
  end

  # A bgp_best on dual can only say cluster_list_length if that is one
  # of the steps the decision process has.
  def test_every_bgp_best_reason_is_a_step_of_the_decision
    reasons = scenario_files.flat_map { |f|
      load_yaml("scenarios/#{f}")['steps'].collect { |s| (s['expect'] || {})['bgp_best'] }.compact
    }
    assert_not_empty reasons
    reasons.each do |r|
      assert_include BGP::Rib::Decision::STEPS.collect(&:to_s), r['reason']
      assert_equal 'dual', r['node'], 'dual is the node with two copies to decide between'
    end
  end

  # Each RFC 4456 rule the README lists has a scenario that names the
  # node whose answer shows it. Read off the steps, so a scenario that
  # stops checking the node it is about fails here.
  def test_each_scenario_asserts_at_the_node_that_shows_its_rule
    nodes_in = ->(f, cond, extra = {}) {
      load_yaml("scenarios/#{f}")['steps'].collect { |s| (s['expect'] || {})[cond] }.compact
        .select { |p| extra.all? { |k, v| p[k] == v } }.collect { |p| p['node'] }
    }
    reached = nodes_in.('client-reflects-to-everyone.yml', 'bgp_prefix')
    assert_equal [], (%w[c1 c2 c3 dual rr2] - reached), 'a client route must be read at every client and at rr2'
    assert_include nodes_in.('non-client-reaches-clients-only.yml', 'bgp_prefix', 'present' => false), 'rr2'
    assert_include nodes_in.('ebgp-reaches-every-internal-peer.yml', 'bgp_prefix'), 'rr2'
    assert_include nodes_in.('shorter-cluster-list-wins.yml', 'bgp_best'), 'dual'
    assert_equal [], (%w[c1 c2 c3 rr2] - nodes_in.('generated-feed-is-reflected.yml', 'bgp_prefix')),
                 'a generated feed must be read at every client kind and at rr2'
    %w[cluster-loop-is-dropped.yml originator-loop-is-dropped.yml].each do |f|
      assert_include nodes_in.(f, 'bgp_prefix', 'present' => false), 'rr1', f
      assert_include nodes_in.(f, 'bgp_session'), 'rr1', "#{f} must show the session stayed up"
    end
  end

  # A spec a scenario sends by name is one its injector's node file
  # names, so the step is not refused in the middle of a run.
  def test_every_spec_a_scenario_sends_is_named_by_its_injector
    sent = 0
    scenario_files.each do |f|
      load_yaml("scenarios/#{f}")['steps'].each do |step|
        next unless step['bgp'] && step['spec'].is_a?(String)
        specs = load_yaml(INJECTORS.fetch(step['node']))['specs'] || {}
        assert_include specs.keys, step['spec'], "#{f}: #{step['node']} names no spec #{step['spec']}"
        sent += 1
      end
    end
    assert_operator sent, :>=, 2, 'the feed scenario announces and withdraws by name'
  end

  # The prefixes and MEDs the feed scenario checks are the ones the spec
  # generates for inj-c's session, read from BGP::Gen rather than typed.
  def test_the_feed_scenario_checks_what_the_spec_generates
    spec = load_yaml(INJECTORS['inj-c'])['specs']['feed']
    sender = { 'as' => 65_100, 'ebgp' => false, 'next_hop' => '10.100.1.1' }
    rows = BGP::Gen.new(spec, sender).expected.to_a.to_h { |r| [r['prefix'], r] }
    checked = 0
    load_yaml('scenarios/generated-feed-is-reflected.yml')['steps'].each do |step|
      p = (step['expect'] || {})['bgp_prefix'] or next
      next if p['present'] == false
      row = rows[p['prefix']]
      assert_not_nil row, "#{p['prefix']} is not in the spec"
      %w[med next_hop local_pref].each { |k| assert_equal row[k], p[k], "#{p['node']} #{p['prefix']} #{k}" if p.key?(k) }
      assert_include row['communities'], p['community'] if p.key?('community')
      checked += 1
    end
    assert_operator checked, :>=, 6
    first, last = rows.keys.first, rows.keys.last
    asserted = load_yaml('scenarios/generated-feed-is-reflected.yml')['steps']
               .collect { |s| (s['expect'] || {}).dig('bgp_prefix', 'prefix') }.compact
    assert_include asserted, first
    assert_include asserted, last
  end

  # The feed scenario holds twice for a look by hand at the clients:
  # once before the announce and once after the feed has arrived and rr1
  # has drained, before the withdraw. A hold elsewhere would show a
  # person a table that is still filling.
  def test_the_feed_scenario_pauses_before_and_after_the_announce
    steps = load_yaml('scenarios/generated-feed-is-reflected.yml')['steps']
    at = ->(pred) { steps.index(&pred) }
    pauses = steps.each_index.select { |i| steps[i].key?('pause') }
    announce = at.(->(s) { s['bgp'] == 'announce' })
    withdraw = at.(->(s) { s['bgp'] == 'withdraw' })
    drained = at.(->(s) { (s['expect'] || {}).key?('bgp_drained') })
    assert_equal [announce - 1, withdraw - 1], pauses
    assert_operator drained, :<, withdraw - 1, 'the second hold comes once rr1 has drained'
    assert_operator drained, :>, announce
  end

  # ------------------------------------------------------------- ABOUT and README

  def test_about_names_every_node_and_as_and_counts_the_scenarios
    about = read('ABOUT.md')
    NODES.each_key { |n| assert_match(/`#{n}`/, about, "ABOUT.md does not name #{n}") }
    %w[65100 65200 1.1.1.1 2.2.2.2].each { |x| assert_include about, x }
    words = %w[zero one two three four five six seven eight nine ten]
    assert_match(/\b#{words.fetch(scenario_files.size)} scenarios in `scenarios\/`/i, about)
    first = about.split(/\n\s*\n/).map(&:strip).find { |b| !b.empty? && !b.start_with?('#') }
    assert_match(/\bNine nodes and four BGP implementations\b/, first)
  end

  # The README node table, against the node files and configs.
  def test_the_readme_node_table_agrees_with_the_files
    ids = { 'rr1' => load_yaml(DAEMONS['rr1'])['router_id'], 'dual' => load_yaml(DAEMONS['dual'])['router_id'],
            'rr2' => read('rr2/frr.conf')[/^ bgp router-id (\S+)$/, 1],
            'c1' => read('c1/frr.conf')[/^ bgp router-id (\S+)$/, 1],
            'c2' => read('c2/bird.conf')[/^router id (\S+);$/, 1],
            'c3' => read('c3/gobgpd.toml')[/router-id = "(\S+)"/, 1] }
    INJECTORS.each { |n, f| ids[n] = load_yaml(f)['router_id'] }
    NODES.each do |name, kind|
      row = readme[/^\| `#{Regexp.escape(name)}` \|.*$/]
      assert_not_nil row, "the README has no row for #{name}"
      cells = row.split('|').collect(&:strip)
      assert_equal "`#{kind}`", cells[2], "#{name} kind"
      assert_equal ids.fetch(name), cells[4], "#{name} router ID"
    end
  end

  # Every scenario is in the README's feature table, and every file the
  # table names exists.
  def test_the_readme_feature_table_and_the_scenarios_agree
    named = readme.scan(/`([a-z-]+\.yml)`/).flatten.uniq.sort
    assert_equal scenario_files, named
  end

  # ------------------------------------------------------- CI and capture.sh

  # The Capture workflow deploys this lab in a job of its own, builds or
  # pulls every image it names, and prints every node's log on failure.
  def test_the_capture_job_deploys_this_lab_and_logs_every_node
    j = job
    assert_not_empty j, 'the Capture workflow has no rr-lab job'
    assert_match(%r{containerlab deploy -t routescope/labs/rr-lab/rr-lab\.clab\.yml}, j)
    assert_match(%r{bash routescope/labs/rr-lab/capture\.sh}, j)
    nodes.values.collect { |n| n['image'] }.uniq.each do |image|
      assert_match(/(?:docker build[^\n]*-t|docker pull[^\n]*)\s#{Regexp.escape(image)}(\s|$)/, j,
                   "the rr-lab job neither builds nor pulls #{image}")
    end
    assert_equal nodes.keys.sort, j[/^\s*for n in ([^;]+);/, 1].to_s.split.sort,
                 'the failure log loop and the topology name different nodes'
  end

  # capture.sh reads every node, so the CI log carries each one's answer.
  def test_the_capture_script_reads_every_node
    loops = capture.scan(/^\s*for\s+(\w+)\s+in\s+([a-z0-9 -]+);?\s*do/)
                   .each_with_object({}) { |(var, list), h| (h["$#{var}"] ||= []).concat(list.split) }
    tokens = capture.scan(/^\s*(?:vshow|bshow|rshow|sshow|gshow)\s+(\S+)/).flatten.uniq
    assert_not_empty tokens
    assert_equal nodes.keys.sort, tokens.flat_map { |t| loops.fetch(t, [t]) }.uniq.sort
  end

  # The checks are what CI measures, so each one has to be run, and the
  # script has to fail when one does.
  def test_every_check_in_capture_is_called_and_a_failure_fails_the_job
    defined = capture.scan(/^(\w+)\(\) \{/).flatten
    called = capture.scan(/^check '[^']*' (\w+)$/).flatten
    assert_operator called.size, :>=, 15, 'capture.sh checks almost nothing'
    called.each { |f| assert_include defined, f, "check calls #{f}, which is not defined" }
    assert_match(/^\[ "\$FAILED" = 0 \] \|\| \{ .*exit 1; \}$/, capture)
  end
end
