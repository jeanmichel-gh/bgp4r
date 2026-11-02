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

# What lab/topologies/bgp4r-lab says, read out of its own files.
#
#   ruby -I. test/functional/lab/bgp4r_lab_topology_test.rb
#
# No Docker, no router binary and no socket: it parses the containerlab
# topology, loads each node file through the program that reads it, and
# holds the folder to its own README. So it catches the thing most likely
# to break a topology, which is a typo in a node file or an address in
# two places that disagree, and it is the only cover those files have
# until the lab can be deployed.
#
# It is not interoperability and does not pretend to be. The lab has
# never been run; `add_path_topology_test.rb` is the same shape for the
# Compose topology beside it and records the same.
#
# **Every file is read with an explicit encoding.** CLAUDE.md records two
# places where a test that read a file as text and matched a regexp
# against it blew up on one non-ASCII character in somebody's prose, from
# a test that had nothing to do with the character.
#
# BGP:: names are written out in full, see Conventions in CLAUDE.md.

require 'test/unit'
require 'yaml'
require 'stringio'
require 'bgp4r'
require 'bgp/daemon'
require 'bgp/sim'

class LabBgp4rLabTopologyTest < Test::Unit::TestCase

  DIR = File.expand_path('../../../lab/topologies/bgp4r-lab', __dir__)

  # The six nodes and what each one is, which is the README's own table.
  # Asserted against the files rather than trusted, in both directions.
  NODES = { 'inj1' => 'bgp4r-sim', 'inj2' => 'bgp4r-sim', 'rtr' => 'bgp4r',
            'r1' => 'frr', 'r2' => 'frr', 'r3' => 'bird' }.freeze

  # The bgp4r node files, by node, and the program that reads each.
  INJECTORS = { 'inj1' => 'inj1/sim.yml', 'inj2' => 'inj2/sim.yml' }.freeze
  ROUTER = 'rtr/bgp4rd.yml'

  # The scenario language, **copied** from routescope `7eabde1` on its
  # `claude/bgp4r-driver` branch, read on 2026-11-02:
  # `Scenario::BGP_ACTIONS`, `Scenario::BGP_KEYS`, `Scenario::CONDITIONS`
  # and `Scenario::COMMON`. docs/routescope-labs.md section 12 is why
  # this is a copy: every fact in this repository about that one is a read
  # at a commit and this suite cannot assert one. What it can do is keep
  # these four files inside the vocabulary that read gave, so a scenario
  # here is not merely plausible YAML.
  BGP_ACTIONS = %w[announce attribute fault notification peer.clear peer.refresh
                   peer.start peer.stop refresh replay route.originate
                   route.withdraw session.flap session.start session.stop
                   withdraw].freeze
  BGP_KEYS = %w[afi as_path case code communities count data generate hex interval
                local_pref med next_hop node origin path_id peer prefix prefixes
                safi subcode subtype].freeze
  CONDITIONS = { 'bgp_session' => %w[node peer state],
                 'bgp_routes' => %w[node count],
                 'bgp_prefix' => %w[node prefix present next_hop med as_path local_pref],
                 'bgp_best' => %w[node prefix reason] }.freeze
  COMMON = %w[name continue].freeze

  def read(rel) ; File.read(File.join(DIR, rel), :encoding => 'UTF-8') ; end
  def load_yaml(rel) ; YAML.safe_load(read(rel)) ; end

  def clab ; @clab ||= load_yaml('bgp4r-lab.clab.yml') ; end
  def nodes ; clab['topology']['nodes'] ; end
  def links ; clab['topology']['links'] ; end
  def readme ; @readme ||= read('README.md') ; end

  # Every `ip addr add A/L dev IFACE` the topology runs, per node, as
  # { node => { iface => 'A/L' } }. Both spellings are read, the bare one
  # the bgp4r and BIRD nodes use and the `sh -c "... || true"` one the FRR
  # nodes need for a link wired after the daemon starts.
  def addresses
    @addresses ||= nodes.to_h { |name, n|
      [name, Array(n['exec']).each_with_object({}) { |line, h|
        m = line.to_s.match(/ip addr add (\S+) dev (\S+)/) or next
        h[m[2]] = m[1]
      }]
    }
  end

  def scenario_files
    Dir[File.join(DIR, 'scenarios', '*.yml')].sort.collect { |f| File.basename(f) }
  end

  # ---------------------------------------------------------------- the topology

  def test_the_topology_names_six_nodes_and_six_links
    assert_equal 'bgp4r-lab', clab['name']
    assert_equal NODES.keys.sort, nodes.keys.sort
    assert_equal 6, links.size, 'six links, one per session'
  end

  # Both labels on every node, and not inherited from a defaults block:
  # `routescope.kind` is what gives a node its driver and
  # `routescope.protocols` is what it is asked about. A kind routescope
  # does not know is kept as a plain Linux node, so a typo here shows as
  # a node with no BGP rather than as an error.
  def test_every_node_carries_both_routescope_labels
    NODES.each do |name, kind|
      labels = nodes.fetch(name)['labels']
      assert_kind_of Hash, labels, "#{name} has no labels"
      assert_equal kind, labels['routescope.kind'], "#{name} kind"
      assert_equal 'bgp', labels['routescope.protocols'], "#{name} protocols"
    end
  end

  # The links of the README's diagram, as ends rather than as a drawing.
  def test_the_links_are_the_six_sessions_the_readme_draws
    want = [%w[inj1:eth1 rtr:eth1], %w[inj2:eth1 rtr:eth2], %w[rtr:eth3 r1:eth1],
            %w[r1:eth2 r2:eth1], %w[r1:eth3 r3:eth1], %w[r2:eth2 r3:eth2]]
    assert_equal want, links.collect { |l| l['endpoints'] }
  end

  # Every end of every link has an address, and the two ends of one link
  # are in one prefix. This is the check that catches the commonest
  # containerlab mistake, which is an interface number and an address that
  # drifted apart: a session on it then never comes up and nothing says
  # why.
  def test_both_ends_of_every_link_are_addressed_in_one_prefix
    links.each do |l|
      a, b = l['endpoints'].collect do |e|
        node, iface = e.split(':')
        addr = addresses.fetch(node)[iface]
        assert_not_nil addr, "#{e} has no ip addr add in the topology"
        addr
      end
      assert_equal a.split('/').last, b.split('/').last, "#{l['endpoints'].inspect} prefix lengths"
      assert_equal IPAddr.new(a).to_s, IPAddr.new(b).to_s,
                   "#{l['endpoints'].inspect} are not in one prefix"
      assert_not_equal a, b, "#{l['endpoints'].inspect} are the same address"
    end
  end

  # ------------------------------------------------------------- the node files

  # Each node file has to load through the program that reads it, or the
  # lab fails at start-up with a message in a container log nobody is
  # watching. These are the real loaders: `Injector.new` runs
  # `Injector.check_config` and builds the Speaker, and `Server#load_config`
  # plus `Server.with_defaults` is what `bgp4rd -f FILE` does.
  def test_every_node_file_loads_through_the_program_that_reads_it
    INJECTORS.each do |name, file|
      i = nil
      assert_nothing_raised("#{file} is not a node file bgp4r-sim accepts") do
        i = BGP::Sim::Injector.new(load_yaml(file))
      end
      assert_equal 1, i.speaker.peers.size, "#{name} has one session"
      assert_nil i.speaker.rib, "#{name} holds no Loc-RIB, which is what an injector is"
    end

    s = router_speaker
    assert_equal 3, s.peers.size, 'rtr has three sessions'
    assert_not_nil s.rib, 'rtr holds a Loc-RIB'
  end

  # The router, built the way `bgp4rd -f FILE` builds it. The two IOs are
  # the ones Server prints a reason to, so a bad file fails here with that
  # reason rather than with a nil.
  def router_speaker
    @router_speaker ||= begin
      err = StringIO.new
      config = BGP::Daemon::Server.new(StringIO.new, err).load_config(:config => File.join(DIR, ROUTER))
      assert_not_nil config, "#{ROUTER} did not load: #{err.string}"
      BGP::Daemon::Speaker.new(BGP::Daemon::Server.with_defaults(config))
    end
  end

  # Both injectors in one AS, which is the design decision this whole
  # topology rests on: MULTI_EXIT_DISC is only compared between paths from
  # one neighbouring AS (RFC 4271 section 9.1.2.2 c), so two ASes here
  # would be decided at AS_PATH length and no scenario could reach the MED
  # step.
  def test_the_two_injectors_are_in_one_as_and_have_their_own_router_ids
    as = INJECTORS.values.collect { |f| load_yaml(f)['as'] }
    assert_equal [65_010, 65_010], as, 'one AS, so MED is comparable'
    ids = INJECTORS.values.collect { |f| load_yaml(f)['router_id'] }
    assert_equal ids.uniq.size, ids.size, 'and two identifiers, since one AS is not one speaker'
    assert_equal 65_000, router_speaker.my_as
  end

  # An injector starts silent. `bgp/sim/injector.rb`'s header is why: a
  # baseline the configuration created is a baseline no assertion can rest
  # on, and the scenarios' empty-baseline steps are built on this.
  def test_neither_injector_announces_anything
    INJECTORS.each do |name, file|
      assert_nil load_yaml(file)['announce'], "#{name} has an announce block"
      assert_equal [], BGP::Sim::Injector.new(load_yaml(file)).speaker.announcements,
                   "#{name} would announce something at start-up"
    end
  end

  # The four keys that make a speaker a router, and the two of them that
  # have a validator go through it. `export_options` and `fib_options` are
  # what `Speaker#start` calls, and reaching them without starting a
  # socket is the only way to run the real check here.
  def test_the_router_carries_the_four_router_keys
    config = load_yaml(ROUTER)
    assert_equal true, config['rib']
    assert_kind_of Array, config['originate']
    assert_kind_of Hash, config['export']
    assert_kind_of Hash, config['fib']

    s = router_speaker
    assert_nothing_raised('export: is not a block Speaker accepts') { s.send(:export_options) }
    opts = nil
    assert_nothing_raised('fib: is not a block Speaker accepts') { opts = s.send(:fib_options) }
    assert_equal 100, opts[:table], 'and table has no default, so it must be named'
    assert_nothing_raised('the fib block does not build an ip route command') do
      BGP::Rib::Fib::IpRoute.new(**opts)
    end
  end

  # **The distinction point 2 of the README rests on.** rtr routes what the
  # injectors send and originates one prefix of its own, so no prefix a
  # scenario injects may be in the originate block: if one were, the chain
  # the lab demonstrates would be origination and the injectors would be
  # decoration.
  def test_the_router_originates_nothing_a_scenario_injects
    ours = load_yaml(ROUTER)['originate'].flat_map { |b| Array(b['prefixes']) }
    assert_equal ['10.255.0.0/24'], ours
    injected = scenario_files.flat_map { |f|
      load_yaml("scenarios/#{f}")['steps'].select { |s| s['bgp'] }.flat_map { |s| Array(s['prefixes']) }
    }.uniq
    refute_empty injected, 'the scenarios inject nothing, so this proves nothing'
    assert_equal [], ours & injected,
                 'a prefix rtr originates is injected by a scenario, so that scenario ' \
                 'measures origination and not transit'
  end

  # Every address a node file names has to be the one the topology gives
  # that interface, or the speaker binds one address and the container has
  # another, which shows up as a session that never comes up.
  def test_every_node_file_address_is_one_the_topology_assigns
    assigned = addresses.values.flat_map { |h| h.values }.collect { |a| a.split('/').first }

    INJECTORS.each do |name, file|
      n = load_yaml(file)
      assert_include assigned, n['local_address'], "#{name} local_address"
      assert_equal addresses.fetch(name)['eth1'].split('/').first, n['local_address'],
                   "#{name} binds an address that is not on its own link"
      n['neighbors'].each do |p|
        assert_include assigned, p['address'], "#{name} peer #{p['address']}"
      end
    end

    # rtr names no local_address on purpose: it has three, and a next hop
    # is per session, so `Peer#new_neighbor` fills it from the socket.
    rtr = load_yaml(ROUTER)
    assert_nil rtr['local_address'],
               'rtr names one of its three addresses, so one session would advertise another'
    rtr['neighbors'].each { |p| assert_include assigned, p['address'], "rtr peer #{p['address']}" }
  end

  # Who dials whom, which is what makes the lab come up the same way every
  # time. The injectors dial, as docs/daemon.md's own example has them, and
  # rtr dials r1 because FRR dials too and one of the two wins.
  def test_the_injectors_dial_the_router_and_the_router_dials_frr
    INJECTORS.each_value do |file|
      assert_equal [true], load_yaml(file)['neighbors'].collect { |p| p['connect'] }
    end
    by_address = router_speaker.peers.to_h { |p| [p.address, p] }
    assert_equal [false, false, true],
                 %w[10.0.10.1 10.0.11.1 10.0.20.2].collect { |a| by_address.fetch(a).active? }
    assert_equal [true, true, true],
                 %w[10.0.10.1 10.0.11.1 10.0.20.2].collect { |a| by_address.fetch(a).ebgp? },
                 'all three of rtr sessions are external, which is what makes MED comparable ' \
                 'between the two injectors and dropped on the way to r1'
  end

  # ---------------------------------------------------------- the router configs

  # The FRR and BIRD files, held to the ASes and addresses the topology
  # gives them. Matched as configuration lines rather than as words, so a
  # sentence in a comment cannot satisfy one of these.
  def test_the_frr_and_bird_configs_name_their_own_as_and_addresses
    r1 = read('r1/frr.conf')
    assert_match(/^router bgp 65001$/, r1)
    assert_match(/^ bgp router-id 10\.255\.1\.1$/, r1)
    assert_match(/^ neighbor 10\.0\.20\.1 remote-as 65000$/, r1, 'the eBGP session to rtr')
    assert_match(/^ neighbor 10\.1\.12\.2 remote-as 65001$/, r1)
    assert_match(/^ neighbor 10\.1\.13\.2 remote-as 65001$/, r1)

    r2 = read('r2/frr.conf')
    assert_match(/^router bgp 65001$/, r2)
    assert_match(/^ bgp router-id 10\.255\.1\.2$/, r2)
    assert_match(/^ neighbor 10\.1\.12\.1 remote-as 65001$/, r2)
    assert_match(/^ neighbor 10\.1\.23\.2 remote-as 65001$/, r2)

    r3 = read('r3/bird.conf')
    assert_match(/^router id 10\.255\.1\.3;$/, r3)
    assert_match(/^  local as 65001;$/, r3)
    assert_match(/neighbor 10\.1\.13\.1 as 65001/, r3)
    assert_match(/neighbor 10\.1\.23\.1 as 65001/, r3)

    # bgpd has to be the daemon that runs, and zebra with it or nothing
    # installs a route.
    %w[r1 r2].each do |n|
      assert_match(/^bgpd=yes$/, read("#{n}/daemons"), "#{n} does not run bgpd")
      assert_match(/^zebra=yes$/, read("#{n}/daemons"), "#{n} does not run zebra")
    end
  end

  # Point 2 claims rtr is the next hop at r2 and r3, which is plain iBGP:
  # NEXT_HOP is unchanged toward an internal peer (RFC 4271 section
  # 5.1.3). So r1 must not set next-hop-self, and r2 and r3 must each be
  # able to reach rtr's address or the path is not usable there. The three
  # go together: any one of them alone is a different lab.
  def test_the_next_hop_at_the_far_end_is_the_router_and_is_reachable
    assert_not_match(/^\s*neighbor \S+ next-hop-self\s*$/, read('r1/frr.conf'),
                     'r1 sets next-hop-self, so the next hop at r2 and r3 is r1 and ' \
                     "the README's point 2 is no longer what the lab shows")
    assert_match(/^ip route 10\.0\.20\.0\/30 10\.1\.12\.1$/, read('r2/frr.conf'),
                 'r2 cannot reach the next hop it is given')
    assert_match(/^  route 10\.0\.20\.0\/30 via 10\.1\.13\.1;$/, read('r3/bird.conf'),
                 'r3 cannot reach the next hop it is given')
  end

  # BIRD is the far end of the chain, and the point of that is that
  # nothing in its table is its own doing. An export filter other than
  # none would make an absence there satisfiable by r3 itself.
  def test_the_bird_node_advertises_nothing
    assert_match(/^    export none;$/, read('r3/bird.conf'))
    assert_match(/^    import all;$/, read('r3/bird.conf'))
  end

  # ---------------------------------------------------------------- the scenarios

  def test_every_scenario_loads_and_has_a_name_steps_and_a_timeout
    assert_equal %w[flip-the-winner.yml inject-and-cross.yml med-decides.yml
                    withdraw-reaches-bird.yml], scenario_files
    scenario_files.each do |f|
      s = load_yaml("scenarios/#{f}")
      assert_equal [], s.keys - %w[name description capture timeout steps],
                   "#{f} has a key a scenario does not take"
      assert_kind_of String, s['name'], "#{f} name"
      assert_operator s['steps'].size, :>=, 3, "#{f} steps"
      assert_operator s['timeout'], :>, 0, "#{f} timeout"
    end
  end

  # Inside the vocabulary and not merely valid YAML: every action name,
  # every body key and every condition, against the lists copied at the
  # top of this file. A scenario nothing runs is prose with a .yml
  # extension unless something checks it against the language it is
  # written in.
  def test_every_scenario_step_is_in_the_language_a_scenario_runner_reads
    checked = 0
    scenario_files.each do |f|
      load_yaml("scenarios/#{f}")['steps'].each_with_index do |step, i|
        where = "#{f} step #{i}"
        kinds = step.keys & %w[bgp expect mark]
        assert_equal 1, kinds.size, "#{where}: one action per step, got #{step.keys.inspect}"
        kind = kinds.first
        extra = case kind
                when 'bgp' then BGP_KEYS
                when 'expect' then %w[within measure]
                else []
                end
        assert_equal [], step.keys - (COMMON + [kind] + extra),
                     "#{where}: #{kind} does not take those keys"
        next unless kind == 'bgp' || kind == 'expect'
        checked += 1
        if kind == 'bgp'
          assert_include BGP_ACTIONS, step['bgp'], "#{where}: unknown bgp action"
        else
          c = step['expect']
          assert_kind_of Hash, c, "#{where}: a condition is a map"
          assert_equal 1, c.size, "#{where}: one condition per expect"
          name, params = c.first
          allowed = CONDITIONS[name]
          assert_not_nil allowed, "#{where}: unknown condition #{name}"
          assert_equal [], params.keys - allowed, "#{where}: #{name} does not take those keys"
          assert_include NODES.keys, params['node'].to_s, "#{where}: no node #{params['node']}"
        end
      end
    end
    assert_operator checked, :>=, 40, 'the walk found almost no steps, so it checked nothing'
  end

  # A reader who runs one of these against a lab that was never deployed
  # gets steps that never pass and nothing saying why. Matched at the
  # start of a comment line, so the words have to be the file's own
  # statement and not a phrase inside a step.
  def test_every_scenario_says_it_has_not_been_run
    scenario_files.each do |f|
      assert_match(/^# NOT RUN: this lab has not been deployed/, read("scenarios/#{f}"),
                   "#{f} does not say it has never been run")
    end
  end

  # ------------------------------------------------------------------ the README

  # The README's scenario table says which actions each file uses. Read
  # out of the table and out of the files, both ways, so a scenario that
  # grows an action has to say so and a table row cannot name one that is
  # not there.
  def test_the_readme_names_every_scenario_and_the_actions_it_uses
    rows = readme.scan(/^\| `(\S+\.yml)` \| (\d) \| (.+?) \|$/)
    assert_equal scenario_files, rows.collect { |r| r[0] }.sort,
                 'the README scenario table and the folder disagree'
    assert_equal %w[2 3 4 5], rows.collect { |r| r[1] }.sort,
                 "the four rows must cover the README's points 2 to 5, one each"
    rows.each do |file, _point, actions|
      listed = actions.scan(/`([\w.]+)`/).flatten.sort
      used = load_yaml("scenarios/#{file}")['steps']
                 .filter_map { |s| s['bgp'] }.uniq.sort
      assert_equal listed, used, "#{file}: the README's actions column and the file disagree"
    end
  end

  # The node table, read out of the README against the files: an AS or a
  # router ID written in one place and changed in the other is exactly
  # the kind of thing nobody notices until a session does not come up.
  def test_the_readme_node_table_agrees_with_the_node_files
    rows = readme.scan(/^\| `(\w+)` \| `([\w-]+)` \| (\d+) \| ([\d.]+) \|/)
    assert_equal NODES.keys.sort, rows.collect { |r| r[0] }.sort
    rows.each do |name, kind, as, id|
      assert_equal NODES.fetch(name), kind, "#{name} kind in the README"
      assert_equal kind, nodes.fetch(name)['labels']['routescope.kind'],
                   "#{name} kind in the topology"
      next unless (file = INJECTORS[name] || (name == 'rtr' ? ROUTER : nil))
      n = load_yaml(file)
      assert_equal n['as'], as.to_i, "#{name} AS"
      assert_equal n['router_id'], id, "#{name} router_id"
    end
  end

  # Both of these say the lab has never been deployed, which is the one
  # claim in the folder a reader most needs and the one a later edit is
  # most likely to leave stale. When it has been, both lines go.
  def test_the_topology_and_the_readme_both_say_it_has_not_been_deployed
    assert_match(/^# \*\*This topology has not been deployed\.\*\*/,
                 read('bgp4r-lab.clab.yml'))
    assert_match(/^\*\*The topology has not been deployed\.\*\*/, readme)
  end

  # The images the topology names have to be the ones the README builds,
  # and the bgp4r one has to be a stage the Dockerfile has. A `--target`
  # that does not exist fails at build time with a message about the
  # Dockerfile and nothing about this lab.
  def test_the_images_the_topology_names_are_the_ones_that_can_be_built
    images = nodes.values.collect { |n| n['image'] }.uniq.sort
    assert_equal ['bgp4r-bird:latest', 'bgp4r-lab:latest', 'quay.io/frrouting/frr:10.2.1'],
                 images
    images.each { |i| assert_include readme, i, "the README does not say where #{i} comes from" }

    dockerfile = File.read(File.expand_path('../../../Dockerfile', __dir__), :encoding => 'UTF-8')
    assert_match(/^FROM speaker AS lab-node$/, dockerfile,
                 'the topology wants a lab-node image and the Dockerfile has no such stage')
    assert_match(/iproute2/, dockerfile[/^FROM speaker AS lab-node$.*?^FROM /m].to_s,
                 'the lab-node stage adds no iproute2, so ip addr add has nothing to run')
    assert_path_exist File.join(DIR, 'Dockerfile.bird')
  end

end
