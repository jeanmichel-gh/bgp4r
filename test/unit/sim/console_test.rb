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

# The console's verbs, against a fake injector: what body each one hands
# to `Injector#act`, the received ring and the taps. No session and no
# irb here; test/functional/console_test.rb has both.
#
#   ruby -I. test/unit/sim/console_test.rb

require 'test/unit'
require 'stringio'
require 'tmpdir'
require 'bgp4r'
require 'bgp/sim/console'
require 'bgp/sim/routegen'

class BGP_Sim_Console_Test < Test::Unit::TestCase

  # The four things the console asks of a Speaker's peer.
  class FakePeer
    attr_reader :address, :remote_as, :sent
    attr_accessor :neighbor, :state
    def initialize(address, neighbor = nil)
      @address, @remote_as, @neighbor = address, 65_002, neighbor
      @state = neighbor ? 'Established' : 'Idle'
      @sent = []
    end
    def established? ; @state == 'Established' ; end
    def send_message(m) ; @sent << m ; end
  end

  class FakeSpeaker
    attr_reader :peers, :hooks
    def initialize(peers) ; @peers, @hooks = peers, [] ; end
    def on_established(&b) ; @hooks << b ; self ; end
    def established_peers ; @peers.select(&:established?) ; end
    def peer(a) ; @peers.find { |p| p.address == a.to_s } ; end
  end

  class FakeInjector
    attr_reader :speaker, :acts
    def initialize(speaker) ; @speaker, @acts = speaker, [] ; end
    def act(name, body, async) ; @acts << [name, body, async] ; { :action => name } ; end
  end

  # An Observable is all a tap needs from a Neighbor.
  class FakeNeighbor
    include BGP::Observable
    def deliver(m) ; changed and notify_observers(m) ; end
  end

  def setup
    @n1 = FakeNeighbor.new
    @p1 = FakePeer.new('10.0.0.2', @n1)
    @p2 = FakePeer.new('10.0.0.3')
    @speaker = FakeSpeaker.new([@p1, @p2])
    @injector = FakeInjector.new(@speaker)
    @out = StringIO.new
    @c = BGP::Sim::Console.new(@injector, @out, 3)
  end

  def last_act ; @injector.acts.last ; end

  # ---- sending goes through act, synchronously ----------------------

  def test_announce_hands_the_prefixes_and_attributes_to_act
    @c.announce('10.1.0.0/24', '10.1.1.0/24', med: 10, as_path: [90, 80])
    assert_equal(['announce',
                  { 'prefixes' => ['10.1.0.0/24', '10.1.1.0/24'], 'med' => 10, 'as_path' => [90, 80] },
                  false], last_act)
  end

  def test_a_prefix_list_may_be_an_array
    @c.withdraw(%w[10.1.0.0/24 10.1.1.0/24])
    assert_equal(['withdraw', { 'prefixes' => %w[10.1.0.0/24 10.1.1.0/24] }, false], last_act)
  end

  def test_specimen_and_fault_name_their_catalog_entry
    @c.specimen(:large_communities, '10.2.0.0/24')
    assert_equal(['announce', { 'prefixes' => ['10.2.0.0/24'], 'specimen' => 'large_communities' }, false],
                 last_act)
    @c.fault(:origin_value, '10.3.0.0/24', peer: '10.0.0.2')
    assert_equal(['fault', { 'prefixes' => ['10.3.0.0/24'], 'peer' => '10.0.0.2', 'case' => 'origin_value' },
                  false], last_act)
  end

  # A family specimen carries its own NLRI, so no prefixes key at all.
  def test_a_family_specimen_sends_no_prefixes_key
    @c.specimen(:evpn)
    assert_equal({ 'specimen' => 'evpn' }, last_act[1])
  end

  def test_the_other_actions
    @c.replay('ffff')
    assert_equal(['replay', { 'hex' => 'ffff' }], last_act[0, 2])
    @c.notification(6, 2)
    assert_equal(['notification', { 'code' => 6, 'subcode' => 2 }], last_act[0, 2])
    @c.refresh
    assert_equal(['refresh', {}], last_act[0, 2])
    @c.flap(count: 2)
    assert_equal(['session.flap', { 'count' => 2 }], last_act[0, 2])
    @c.act(:announce, med: 1)
    assert_equal(['announce', { 'med' => 1 }, false], last_act)
  end

  # ship is the one verb that does not go through act: it hands the
  # message over unchanged, to the established peer by default.
  def test_ship_hands_the_message_over_unchanged
    msg = BGP::Keepalive.new
    assert_same(msg, @c.ship(msg))
    assert_same(msg, @p1.sent.last)
    @c.ship('octets', peer: '10.0.0.3')
    assert_equal(['octets'], @p2.sent)
    assert_empty(@injector.acts)
  end

  # ---- sessions -------------------------------------------------------

  def test_neighbor_is_the_established_peers_by_default
    assert_same(@n1, @c.n)
    assert_same(@n1, @c.neighbor('10.0.0.2'))
  end

  def test_a_peer_with_no_session_says_so
    e = assert_raise(ArgumentError) { @c.neighbor('10.0.0.3') }
    assert_match(/10\.0\.0\.3 has no session yet \(state Idle\)/, e.message)
  end

  def test_an_unknown_peer_names_the_ones_there_are
    e = assert_raise(ArgumentError) { @c.state('10.9.9.9') }
    assert_match(/no peer 10\.9\.9\.9; the peers are 10\.0\.0\.2, 10\.0\.0\.3/, e.message)
  end

  def test_peers_and_state
    assert_equal([{ :address => '10.0.0.2', :as => 65_002, :state => 'Established' },
                  { :address => '10.0.0.3', :as => 65_002, :state => 'Idle' }], @c.peers)
    assert_equal('Idle', @c.state('10.0.0.3'))
  end

  # ---- watching -------------------------------------------------------

  def test_a_session_already_up_is_tapped_and_kept_to_the_limit
    5.times { @n1.deliver(BGP::Keepalive.new) }
    upd = BGP::Update.new(BGP::Path_attribute.new(BGP::Origin.new(0)), BGP::Nlri.new('10.1.0.0/24'))
    @n1.deliver(upd)
    assert_same(upd, @c.last)
    assert_nil(@c.received(10))
    lines = @out.string.lines
    assert_equal(3, lines.size, 'the ring keeps what it was told to')
    assert_match(/ 10\.0\.0\.2 Update, 1 prefixes, 0 withdrawn$/, lines.last)
  end

  # A Neighbor is a new object on every reconnect, so the console taps
  # each one as it comes up, once.
  def test_a_session_that_comes_up_later_is_tapped_once
    n2 = FakeNeighbor.new
    @p2.neighbor = n2
    @speaker.hooks.each { |h| h.call(@p2) }
    @speaker.hooks.each { |h| h.call(@p2) }
    n2.deliver(BGP::Keepalive.new)
    assert_kind_of(BGP::Keepalive, @c.last)
    @c.received
    assert_equal(1, @out.string.lines.size, 'tapped twice would record it twice')
    assert_match(/ 10\.0\.0\.3 Keepalive$/, @out.string)
  end

  def test_watch_prints_as_messages_arrive_and_quiet_stops_it
    @n1.deliver(BGP::Keepalive.new)
    assert_equal('', @out.string)
    @c.watch
    @n1.deliver(BGP::Keepalive.new)
    assert_match(/Keepalive/, @out.string)
    @c.quiet
    @out.truncate(0) ; @out.rewind
    @n1.deliver(BGP::Keepalive.new)
    assert_equal('', @out.string)
  end

  def test_describe_a_malformed_message_and_a_string
    assert_equal('malformed: bad', BGP::Sim::Console.describe(RuntimeError.new('bad')))
    assert_equal('Cease', BGP::Sim::Console.describe('Cease'))
  end

  # ---- the prompt -----------------------------------------------------

  # irb prints self in its prompt.
  def test_the_prompt_reads_bgp4r
    assert_equal('bgp4r', @c.to_s)
  end

  # An irb command wins over a method of the same name, so a verb with
  # one of those names could never be typed. Asked of irb itself when it
  # loads, and of a fixed list when it does not.
  def test_no_verb_is_an_irb_command
    names = %w[help ls next step delete info source exit cd edit measure history]
    begin
      BGP::Sim::Console.load_irb
      require 'irb/command'
      names |= IRB::Command.commands.keys.collect(&:to_s)
    rescue LoadError, NameError
      nil
    end
    verbs = BGP::Sim::Console.public_instance_methods(false).collect(&:to_s)
    assert_empty(verbs & names)
  end

  def test_verbs_lists_every_sending_verb
    @c.verbs
    %w[announce withdraw specimen fault replay notification refresh flap act ship
       received last watch quiet sent announced specimens faults peers state].each do |v|
      assert_match(/^\s+#{v}\b|\b#{v}\b/, @out.string, v)
    end
  end

  # ---- bgp4r routegen --interact ---------------------------------------

  def routegen
    @routegen ||= BGP::Sim::Routegen.new(StringIO.new, StringIO.new)
  end

  def plan(argv)
    routegen.plan(routegen.send(:parse, argv))
  end

  def test_interact_starts_silent
    _config, blocks = plan(%w[--peer 10.0.0.2 --peer-as 65002 --interact])
    assert_equal([], blocks)
  end

  def test_interact_with_a_range_still_sends_it_first
    _config, blocks = plan(%w[--peer 10.0.0.2 --peer-as 65002 --interact --count 20])
    assert_equal(20, blocks.first['generate']['count'])
  end

  def test_interact_takes_a_node_file_with_no_announce_block
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'n.yml')
      File.write(path, "router_id: 10.0.0.1\nas: 65001\nneighbors:\n  - address: 10.0.0.2\n    as: 65002\n")
      config, blocks = plan([path, '--interact'])
      assert_equal([], blocks)
      assert_equal(65_001, config['as'])
      assert_equal([nil, nil], plan([path]), 'without --interact it is still refused')
    end
  end

  # ---- docs/console.md ------------------------------------------------

  ROOT = File.expand_path('../../..', __dir__)

  def console_doc
    File.read(File.join(ROOT, 'docs', 'console.md'), :encoding => 'UTF-8')
  end

  # The defaults table, as { setting => default } read out of the
  # document. Its row count is asserted first, so a parse that finds
  # nothing fails rather than passing every row it did not read.
  def documented_defaults
    rows = console_doc.scan(/^\| ([A-Z][^|]*?) \| ([^|]+?) \| [^|]+\|$/)
    rows.reject { |setting, _| setting == 'Setting' }.to_h
  end

  # What the command line in the document really builds: a Neighbor from
  # the node file routegen plans, with nothing else given.
  def default_neighbor
    config, = plan(%w[--peer 10.0.0.2 --peer-as 65002 --interact])
    BGP::Daemon::Speaker.new(config).peers.first.send(:new_neighbor)
  end

  def source(path)
    File.read(File.join(ROOT, path), :encoding => 'UTF-8')
  end

  def test_the_documented_defaults_are_the_ones_the_command_uses
    doc = documented_defaults
    assert_equal(8, doc.size, 'the defaults table has eight rows')
    n = default_neighbor
    open = n.open
    assert_equal(n.instance_variable_get(:@my_as).to_s, doc['Our AS'])
    assert_equal(BGP::Sim::Routegen::DEFAULT_AS.to_s, doc['Our AS'])
    assert_equal(BGP::Sim::Routegen::DEFAULT_ID, doc['Our router ID'])
    assert_equal(BGP::Sim::Routegen::DEFAULT_ID, open.bgp_id)
    assert_equal(n.holdtime.to_s, doc['Hold time'])
    caps = open.opt_parms.flat_map { |p| Array(p.respond_to?(:capabilities) ? p.capabilities : p) }
    assert_equal([BGP::OPT_PARM::CAP::As4], caps.collect(&:class))
    assert_equal('as4_byte', doc['Capabilities'])
  end

  # Three defaults are a `fetch` inside a method that dials or waits, so
  # they are held by the line of code that applies them. Anchored at the
  # start of a line, so a comment naming the value cannot match.
  def test_the_documented_port_retry_and_wait_are_in_the_code
    doc = documented_defaults
    speaker = source('bgp/daemon/speaker.rb')
    routegen = source('bgp/sim/routegen.rb')
    assert_match(/^\s+sock = Socket\.tcp\(@address, @config\.fetch\('port', #{doc['Peer TCP port']}\),/, speaker)
    assert_match(/^\s+@resume\.wait\(@admin, @config\.fetch\('retry', #{doc['Retry after a failed dial']}\)\)/, speaker)
    assert_match(/^\s+deadline = Time\.now \+ Float\(opts\[:timeout\] \|\| #{doc['Wait for Established']}\)/, routegen)
  end

  def test_the_documented_node_file_is_what_routegen_builds
    config, = plan(%w[--peer 10.0.0.2 --peer-as 65002 --interact])
    yaml = console_doc[/^## 1\..*?```yaml\n(.*?)```/m, 1]
    assert_not_nil(yaml, 'section 1 carries the node file')
    require 'yaml'
    assert_equal(config, YAML.safe_load(yaml))
  end

  def test_the_usage_names_interact
    out = StringIO.new
    BGP::Sim::Routegen.new(out, StringIO.new).start(['--help'])
    assert_match(/--interact/, out.string)
  end

end
