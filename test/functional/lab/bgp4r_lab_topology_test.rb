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

# What lab/routescope/bgp4r-lab says, read out of its own files.
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
require_relative 'routescope_vocabulary'

class LabBgp4rLabTopologyTest < Test::Unit::TestCase

  DIR = File.expand_path('../../../lab/routescope/bgp4r-lab', __dir__)

  # The seven nodes and what each one is, which is the README's own table.
  # Asserted against the files rather than trusted, in both directions.
  NODES = { 'inj1' => 'bgp4r-sim', 'inj2' => 'bgp4r-sim', 'rtr' => 'bgp4r',
            'r1' => 'frr', 'r2' => 'frr', 'r3' => 'bird',
            'g1' => 'gobgp' }.freeze

  # `Lab::KINDS`, copied from routescope, in routescope_vocabulary.rb.
  # What this test can do is say which of this topology's kinds that read
  # knew, so a kind routescope does not have is a recorded measurement
  # rather than a silence.
  ROUTESCOPE_KINDS = RoutescopeVocabulary::KINDS

  # The kinds on this topology that routescope had no driver for at that
  # commit. One, and it is the GoBGP node: `grep -rln gobgp` across
  # routescope's Ruby, Markdown, TSX and YAML found nothing at all.
  KINDS_ROUTESCOPE_LACKS = %w[gobgp].freeze

  # The bgp4r node files, by node, and the program that reads each.
  INJECTORS = { 'inj1' => 'inj1/sim.yml', 'inj2' => 'inj2/sim.yml' }.freeze
  ROUTER = 'rtr/bgp4rd.yml'

  # The scenario language, copied from routescope into
  # routescope_vocabulary.rb, which rr_lab_topology_test.rb reads too.
  # What this test can do is keep these files inside the vocabulary that
  # read gave, so a scenario here is not merely plausible YAML.
  BGP_ACTIONS = RoutescopeVocabulary::BGP_ACTIONS
  BGP_KEYS = RoutescopeVocabulary::BGP_KEYS
  CONDITIONS = RoutescopeVocabulary::CONDITIONS
  COMMON = RoutescopeVocabulary::COMMON

  def read(rel) ; File.read(File.join(DIR, rel), :encoding => 'UTF-8') ; end
  def load_yaml(rel) ; YAML.safe_load(read(rel)) ; end

  def clab ; @clab ||= load_yaml('bgp4r-lab.clab.yml') ; end
  def nodes ; clab['topology']['nodes'] ; end
  def links ; clab['topology']['links'] ; end
  def readme ; @readme ||= read('README.md') ; end
  # The topology as text, for the claims that are in its comments rather
  # than in its YAML.
  def clab_text ; @clab_text ||= read('bgp4r-lab.clab.yml') ; end

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

  def test_the_topology_names_seven_nodes_and_seven_links
    assert_equal 'bgp4r-lab', clab['name']
    assert_equal NODES.keys.sort, nodes.keys.sort
    assert_equal 7, links.size, 'seven links, one per session'
  end

  # The one kind here routescope had no driver for, stated rather than
  # left to be discovered. **This fails the day routescope gains the
  # gobgp kind**, which is what it is for: strike the entry, and strike
  # the paragraph in the topology file and the README that say the node
  # renders as linux.
  def test_the_kinds_routescope_knows_and_the_one_it_does_not
    kinds = NODES.values.uniq
    known, unknown = kinds.partition { |k| ROUTESCOPE_KINDS.include?(k) }
    assert_equal KINDS_ROUTESCOPE_LACKS.sort, unknown.sort,
                 'the set of kinds routescope has no driver for has ' \
                 'changed: re-read Lab::KINDS and move the copy above'
    assert_equal %w[bgp4r bgp4r-sim bird frr].sort, known.sort
    # And the gap is written where a reader of the lab meets it, not
    # only here.
    assert_include clab_text, 'routescope b8e2704',
                   'the topology does not say when routescope was read'
    assert_include readme, 'gobgp',
                   'the README does not mention the kind it is waiting on'
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

  # routescope builds a lab's images when it starts the lab, from the
  # `routescope.build` label: a Dockerfile in this folder, which is the
  # build context. So every image with no registry in its name has one,
  # the file is there, and nodes sharing an image share the recipe. An
  # image from a registry, FRR's, is pulled and names none. A copy of
  # this folder carries no bgp4r checkout, which is why the bgp4r nodes
  # use Dockerfile.node and not the root Dockerfile's `lab-node` stage.
  def test_every_local_image_names_a_dockerfile_in_this_folder
    by_image = Hash.new { |h, k| h[k] = [] }
    nodes.each do |name, n|
      image = n['image'].to_s
      build = (n['labels'] || {})['routescope.build']
      if image.include?('/') && image.split('/').first.match?(/[.:]/)
        assert_nil build, "#{name}: #{image} is pulled from a registry and needs no build"
        next
      end
      assert build, "#{name}: #{image} is local and has no routescope.build label"
      assert_not_include build, '/', "#{name}: the Dockerfile is in this folder"
      assert File.file?(File.join(DIR, build)), "#{name}: #{build} is not in #{DIR}"
      by_image[image] << build
    end
    by_image.each { |image, builds| assert_equal 1, builds.uniq.size, "#{image} has two recipes: #{builds.uniq}" }
    assert_equal %w[bgp4r-bird:latest bgp4r-gobgp:latest bgp4r-lab:latest], by_image.keys.sort
    df = read('Dockerfile.node')
    assert_match(/\A# syntax=docker\/dockerfile:1\n/, df, 'ADD of a git URL needs the BuildKit frontend line first')
    assert_match(%r{^ADD https://github\.com/jeanmichel-gh/bgp4r\.git#\$\{BGP4R_REF\} /app$}, df)
    assert_match(/^ENTRYPOINT \["ruby", "-I\/app"\]$/, df, 'the cmd lines are paths under /app')
  end

  # The links of the README's diagram, as ends rather than as a drawing.
  def test_the_links_are_the_seven_sessions_the_readme_draws
    want = [%w[inj1:eth1 rtr:eth1], %w[inj2:eth1 rtr:eth2], %w[rtr:eth3 r1:eth1],
            %w[rtr:eth4 g1:eth1],
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
    assert_equal 4, s.peers.size, 'rtr has four sessions'
    assert_not_nil s.rib, 'rtr holds a Loc-RIB'
  end

  # g1 has no bgp4r node file, since it is a GoBGP, so what stands in for
  # the loader check is the TOML and the one thing it must agree with:
  # the address the topology gives its interface.
  #
  # **It is read as text and not parsed**, because `toml` is not a
  # default gem and Conventions says to check that before requiring one.
  # The claims here are a handful of lines, so matching them is cheaper
  # than a dependency the library's one-runtime-gem rule would not
  # allow. Each pattern is anchored, which is the lesson
  # `mcast_vpn_doc_test.rb` records: a bare word matches a comment as
  # readily as a setting.
  def test_the_gobgp_config_agrees_with_the_topology
    toml = read('g1/gobgpd.toml')
    addr = addresses.fetch('g1')['eth1'].split('/').first
    peer = addresses.fetch('rtr')['eth4'].split('/').first

    assert_match(/^  as = 65002$/, toml, 'g1 is in AS 65002')
    assert_match(/^    neighbor-address = "#{Regexp.escape(peer)}"$/, toml,
                 "the neighbor is not rtr's #{peer} on that link")
    # The neighbour's own key, and the only place g1's address belongs:
    # it binds on the dial, which retries. There is deliberately no
    # `local-address-list`, which binds the listener at start-up and
    # killed the deploy; the guard on that is
    # test_no_node_binds_a_link_address_before_the_topology_adds_it.
    assert_match(/^    local-address = "#{Regexp.escape(addr)}"$/, toml,
                 "the session's source address is not g1's own #{addr}")
    assert_match(/^      afi-safi-name = "ipv4-unicast"$/, toml)

    # rtr's own side has to name the same pair the other way round.
    n = router_speaker.peers.find { |p| p.remote_as == 65002 }
    assert_not_nil n, 'rtr has no session in AS 65002'
    assert_equal addr, n.address.to_s, "rtr peers with g1 at #{addr}"
    assert_equal 'g1', n.description

    # It receives and does not originate, which g1/gobgpd.toml explains:
    # a third AS announcing the same prefix would be compared before the
    # MED step and med-decides.yml would stop meaning anything.
    assert_not_match(/^\[\[defined-sets|^\s*prefix-list|^\[\[policy-definitions/, toml,
                     'g1 has grown a policy, so read what it now sends')

    # **`[zebra]`, one bracket, and the first draft of this line wrote
    # two.** The array-of-tables form it asserted does not exist, so a
    # guard that claimed to watch for a zebra integration could not have
    # matched one. Read in GoBGP's own `docs/sources/zebra.md`: the block
    # is `[zebra]` then `[zebra.config]` with `enabled = true`.
    assert_not_match(/^\[zebra\]/, toml,
                     'g1 has grown a zebra integration, so it now programs ' \
                     'a kernel FIB and the asymmetry below is stale')
    assert_not_match(/^\s*rpki/, toml)
  end

  # **What each implementation does with the kernel, which is three
  # answers and a fourth that is none.** A reader comparing what is
  # installed across these nodes is comparing four different things, so
  # the differences are asserted rather than left to be discovered:
  #
  #   rtr  bgp4rd, `fib: table: 100`, through iproute2, and **not** the
  #        main table, because a route there changes where the container
  #        sends its own traffic
  #   r1   FRR, `zebra=yes` in its daemons file, so zebra programs it
  #   r2   the same
  #   r3   BIRD, `protocol kernel` exporting `source = RTS_BGP`
  #   g1   GoBGP, nothing at all
  #
  # GoBGP does not program the Linux FIB by itself: its own
  # `docs/sources/zebra.md` routes that through an external zebra over
  # ZAPI, which this node has no block for and no zebra to talk to.
  # `NET_ADMIN` on the container would not change that.
  #
  # **That is deliberate and not a gap.** g1 is on this topology to read
  # what rtr's export side sends, which `gobgp global rib` answers in
  # full. A zebra would mean a second daemon in that container for a FIB
  # no scenario asserts.
  def test_what_each_node_does_with_the_kernel_is_stated_and_differs
    rtr = load_yaml(ROUTER)
    assert_equal 100, rtr.dig('fib', 'table'),
                 'rtr installs into table 100, which is what its own ' \
                 'comment says and why it is not the main table'

    %w[r1 r2].each do |n|
      assert_match(/^zebra=yes$/, read("#{n}/daemons"),
                   "#{n} has no zebra, so FRR there programs no kernel route")
    end

    assert_match(/^protocol kernel \{/, read('r3/bird.conf'),
                 'BIRD has no kernel protocol, so it programs no kernel route')

    # And the one that does nothing, asserted from its own config.
    toml = read('g1/gobgpd.toml')
    assert_not_match(/^\[zebra\]/, toml)
    assert_include toml, 'zebra',
                   'g1/gobgpd.toml does not say why it programs no kernel ' \
                   'route, so a reader comparing FIBs has nothing to read'

    # The README has to carry it too, since that is where a person looks.
    assert_include readme, 'ip monitor route',
                   'the README does not say how to watch a kernel install'
  end

  # The claim g1 exists for, asserted rather than left in prose: one
  # UPDATE out of rtr, read by two implementations, same AS_PATH and a
  # next hop each.
  #
  # **Written because a sabotage passed.** Deleting the g1 expectation
  # from inject-and-cross.yml moved no test: the vocabulary guards only
  # ask whether the YAML is routescope's, and the README table guard only
  # compares the actions column. So the one thing this node is on the
  # topology for had nothing holding the scenario to it. Same shape as
  # the unplaced-lab-test check in test/coverage_matrix.rb, which had its
  # own consumer and nothing else.
  #
  # The two next hops are **derived** from the topology's own `exec:`
  # lines rather than written here, so a readdressed link moves them and
  # this guard follows.
  def test_one_scenario_asserts_both_readers_of_one_update
    s = load_yaml('scenarios/inject-and-cross.yml')
    reach = s['steps'].filter_map { |x| x.dig('expect', 'bgp_prefix') }
                      .reject { |x| x['present'] == false }

    on = lambda { |node| reach.select { |x| x['node'] == node } }
    r1, g1 = on['r1'], on['g1']
    assert_not_empty g1, 'no scenario step reads the prefix at g1, so ' \
                         'nothing asserts the second reader this node is for'

    prefix = g1.first['prefix']
    twin = r1.find { |x| x['prefix'] == prefix }
    assert_not_nil twin, "r1 is not asserted on #{prefix}, so the two " \
                         'readers are not compared on one UPDATE'

    assert_equal twin['as_path'], g1.first['as_path'],
                 'the two readers are asserted with different AS_PATHs: ' \
                 'export is not per peer, so one of the two is wrong'

    # A next hop **is** per peer (RFC 4271 section 5.1.3) and rtr sets no
    # `next_hops`, so each reader sees rtr's address on its own link.
    want = { 'r1' => rtr_address_facing('r1'), 'g1' => rtr_address_facing('g1') }
    assert_not_equal want['r1'], want['g1'], 'the two links share an address'
    assert_equal want['r1'], twin['next_hop'], "r1's next hop is rtr's own end"
    assert_equal want['g1'], g1.first['next_hop'], "g1's next hop is rtr's own end"
  end

  # rtr's own address on the link to node, read out of the topology.
  def rtr_address_facing(node)
    link = links.find { |l| l['endpoints'].any? { |e| e.start_with?("#{node}:") } &&
                            l['endpoints'].any? { |e| e.start_with?('rtr:') } }
    assert_not_nil link, "no rtr link to #{node}"
    iface = link['endpoints'].find { |e| e.start_with?('rtr:') }.split(':').last
    addresses.fetch('rtr')[iface].split('/').first
  end

  # And the peer-as on each side is the other's AS, which is the mistake
  # a reader cannot see from one file.
  def test_the_two_sides_of_the_gobgp_session_agree_on_the_as
    toml = read('g1/gobgpd.toml')
    assert_match(/^    peer-as = 65000$/, toml, 'g1 peers with rtr in AS 65000')
    assert_equal 65000, router_speaker.config['as']
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

  # The other half of that, and it is the one that took the lab down.
  # containerlab runs a node's `exec:` lines **after** the container's
  # entrypoint, so an address the topology assigns does not exist while
  # the daemon is reading its config. A daemon that merely **dials** that
  # address is fine, because a dial retries; one told to **bind** a
  # listener to it is not, and it exits, and containerlab then fails the
  # whole deploy rather than the one node.
  #
  # `g1` did exactly that on 2026-11-03 and nothing here caught it. So:
  # one pattern per config format, scanned over every node's own files,
  # and a bind is a failure only when it names an address `exec:` adds,
  # since a wildcard is what all seven are supposed to use. The file set
  # comes from the node list, so a node added later is covered with no
  # edit here.
  STARTUP_LISTEN_KEYS = {
    'local-address-list' => 'gobgpd opens one listener per entry as it reads the file, ' \
                            'before any neighbour is dialled, and exits when a bind fails',
    'listen_address' => "bgp4rd hands it to TCPServer.new as the daemon starts",
    'listen bgp address' => "BIRD's global listen option binds as the daemon starts",
  }.freeze

  def test_no_node_binds_a_link_address_before_the_topology_adds_it
    wired = addresses.values.flat_map { |h| h.values }.collect { |a| a.split('/').first }
    assert_not_empty wired, 'the topology assigns no addresses, so this guard measures nothing'

    nodes.each_key do |name|
      files = Dir[File.join(DIR, name, '*')].select { |f| File.file?(f) }
      assert_not_empty files, "#{name} has no config file, so nothing was scanned for it"

      files.each do |path|
        File.read(path, :encoding => 'UTF-8').each_line do |line|
          next if line =~ %r{^\s*(?:[#!]|//)} # a comment may name the key and the address

          STARTUP_LISTEN_KEYS.each do |key, why|
            next unless line.include?(key)

            named = wired.select { |a| line.include?(a) }
            assert_empty named,
                         "#{name}/#{File.basename(path)} binds #{named.join(' ')} through " \
                         "#{key}, and the topology adds that address in exec:, which runs " \
                         "after the entrypoint, so #{why}"
          end
        end
      end
    end
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
    assert_equal %w[communities-cross.yml flap-and-drain.yml flip-the-winner.yml
                    inject-and-cross.yml med-decides.yml withdraw-reaches-bird.yml], scenario_files
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
          # bgp_drained with no node asks every speaker, so it names none.
          next if name == 'bgp_drained' && !params.key?('node')
          assert_include NODES.keys, params['node'].to_s, "#{where}: no node #{params['node']}"
        end
      end
    end
    assert_operator checked, :>=, 40, 'the walk found almost no steps, so it checked nothing'
  end

  # The lab is deployed by the Capture job, but nothing runs these
  # scenarios here: routescope does. A reader has to know that before
  # trusting an expectation in one. Matched at the start of a comment
  # line, so the words have to be the file's own statement and not a
  # phrase inside a step.
  def test_every_scenario_says_it_has_not_been_run
    scenario_files.each do |f|
      assert_match(/^# NOT RUN: the lab is deployed by bgp4r's Capture job, but this scenario\n# has not been run/, read("scenarios/#{f}"),
                   "#{f} does not say it has never been run")
    end
  end

  # ------------------------------------------------------------------ ABOUT.md

  # What routescope shows above the map, from routescope #45. It is prose,
  # so what is held is what drifts: every node and every AS it should
  # name, the scenario count it states, and that its first paragraph,
  # which is the line the Labs panel shows, says what the lab is.
  def test_about_names_every_node_and_as_and_counts_the_scenarios
    about = read('ABOUT.md')
    NODES.each_key { |n| assert_match(/`#{n}`/, about, "ABOUT.md does not name #{n}") }
    %w[65000 65001 65002 65010].each { |as| assert_include about, as, "ABOUT.md does not give AS #{as}" }
    count = Dir.glob(File.join(DIR, 'scenarios', '*.yml')).size
    words = %w[zero one two three four five six seven eight nine ten]
    assert_match(/\b#{words.fetch(count)} scenarios in `scenarios\/`/i, about, 'ABOUT.md states another scenario count')
    first = about.split(/\n\s*\n/).map(&:strip).find { |b| !b.empty? && !b.start_with?('#') }
    assert_match(/\bSeven nodes and four BGP implementations\b/, first)
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
    assert_equal %w[2 3 4 5 6 7], rows.collect { |r| r[1] }.sort,
                 "the six rows must cover the README's points 2 to 7, one each"
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

  # Both of these say where the lab is deployed, which is the one claim in
  # the folder a reader most needs, and the workflow they name has to
  # deploy this topology and run its capture.
  def test_the_topology_and_the_readme_both_say_ci_deploys_it
    assert_match(/^# \*\*This topology is deployed by CI\*\*/, read('bgp4r-lab.clab.yml'))
    assert_match(/^\*\*The topology is deployed by CI\*\*/, readme)
    wf = File.read(File.expand_path('../../../.github/workflows/capture.yml', __dir__))
    assert_match(%r{containerlab deploy -t lab/routescope/bgp4r-lab/bgp4r-lab\.clab\.yml}, wf)
    assert_match(%r{bash lab/routescope/bgp4r-lab/capture\.sh}, wf)
  end

  # **Adding a node to a topology CI deploys breaks that job, and the
  # image guard below could not see it.** That one holds the images
  # against the README; the job builds its own list, so `g1` arrived
  # naming `bgp4r-gobgp:latest` with nothing building it, and
  # `containerlab deploy` would have failed on a missing image with
  # nothing in this suite saying so. Found while merging, not by a test,
  # which is what this one is for.
  #
  # The failure log loop is held too, because a node missing from it is
  # the quietest of the two: the job still fails, and the one container
  # whose log would say why is the one not printed.
  def test_every_node_the_topology_has_is_built_and_logged_by_that_job
    wf = File.read(File.expand_path('../../../.github/workflows/capture.yml', __dir__))

    nodes.values.collect { |n| n['image'] }.uniq.each do |image|
      assert_match(/(?:docker build[^\n]*-t|docker pull[^\n]*)\s#{Regexp.escape(image)}(\s|$)/, wf,
                   "the capture job neither builds nor pulls #{image}, so " \
                   'containerlab deploy fails on a node that names it')
    end

    loop_line = wf[/^\s*for n in ([^;]+);/, 1]
    assert_not_nil loop_line, 'the capture job has no failure log loop to check'
    assert_equal nodes.keys.sort, loop_line.split.sort,
                 'the failure log loop and the topology name different nodes'
  end

  # And the script that job runs has to read every one of them, which is
  # the point of deploying the lab at all: the log is where routescope's
  # BGP fixtures are cut from, so a node nothing reads contributes
  # nothing. `g1` was deployed before it was read, which is how this came
  # to be written.
  #
  # The node list is derived from the read helpers, one per tool, with
  # the `for` loops expanded, so neither side is a list anybody keeps in
  # step by hand.
  def test_the_capture_script_reads_every_node_the_topology_has
    sh = read('capture.sh')

    loops = sh.scan(/^\s*for\s+(\w+)\s+in\s+([a-z0-9 ]+);?\s*do/)
              .each_with_object({}) { |(var, list), h| (h["$#{var}"] ||= []).concat(list.split) }
    assert_not_empty loops, 'no for loop was parsed, so $n never expands and this cannot pass'

    tokens = sh.scan(/^\s*(?:vshow|bshow|rshow|sshow|gshow)\s+(\S+)/).flatten.uniq
    assert_not_empty tokens, 'no read helper call was parsed, so this guard measures nothing'

    assert_equal nodes.keys.sort,
                 tokens.flat_map { |t| loops.fetch(t, [t]) }.uniq.sort,
                 'capture.sh and the topology name different nodes'
  end

  # The images the topology names have to be the ones the README builds,
  # and the bgp4r one has to be a stage the Dockerfile has. A `--target`
  # that does not exist fails at build time with a message about the
  # Dockerfile and nothing about this lab.
  def test_the_images_the_topology_names_are_the_ones_that_can_be_built
    images = nodes.values.collect { |n| n['image'] }.uniq.sort
    assert_equal ['bgp4r-bird:latest', 'bgp4r-gobgp:latest', 'bgp4r-lab:latest',
                  'quay.io/frrouting/frr:10.2.1'], images
    images.each { |i| assert_include readme, i, "the README does not say where #{i} comes from" }

    dockerfile = File.read(File.expand_path('../../../Dockerfile', __dir__), :encoding => 'UTF-8')
    assert_match(/^FROM speaker AS lab-node$/, dockerfile,
                 'the topology wants a lab-node image and the Dockerfile has no such stage')
    assert_match(/iproute2/, dockerfile[/^FROM speaker AS lab-node$.*?^FROM /m].to_s,
                 'the lab-node stage adds no iproute2, so ip addr add has nothing to run')
    assert_path_exist File.join(DIR, 'Dockerfile.bird')
    assert_path_exist File.join(DIR, 'Dockerfile.gobgp')
  end

  # The GoBGP wrapper exists for one reason, iproute2 for the `exec:`
  # lines, which is `Dockerfile.bird`'s reason too. And its GOBGP_IMAGE
  # default has to be the one the rest of the repository uses, or this
  # lab measures a different GoBGP than the Compose topologies and the
  # conformance stage do.
  def test_the_gobgp_wrapper_adds_iproute2_and_pins_the_same_image
    f = read('Dockerfile.gobgp')
    assert_match(/iproute2/, f, 'the wrapper adds no iproute2')
    assert_match(/^ARG GOBGP_IMAGE=(\S+)$/, f)
    mine = f[/^ARG GOBGP_IMAGE=(\S+)$/, 1]

    root = File.read(File.expand_path('../../../Dockerfile', __dir__),
                     :encoding => 'UTF-8')
    assert_equal root[/^ARG GOBGP_IMAGE=(\S+)$/, 1], mine,
                 'the wrapper and the root Dockerfile pin different GoBGP ' \
                 'images, so this lab and the conformance stage disagree'

    compose = File.read(File.expand_path('../../../lab/topologies/fault-matrix/compose.yml',
                                         __dir__), :encoding => 'UTF-8')
    assert_include compose, mine,
                   'the fault matrix pins a different GoBGP image than this lab'
  end

end
