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
    def clear ; @cleared = true ; self ; end
    def cleared? ; @cleared ; end
  end

  class FakeSpeaker
    attr_reader :peers, :hooks
    def initialize(peers) ; @peers, @hooks = peers, [] ; end
    def on_established(&b) ; @hooks << b ; self ; end
    def established_peers ; @peers.select(&:established?) ; end
    def peer(a) ; @peers.find { |p| p.address == a.to_s } ; end
  end

  class FakeInjector
    attr_reader :speaker, :acts, :config
    attr_accessor :fail_with
    def initialize(speaker, config = nil) ; @speaker, @acts, @config = speaker, [], config ; end
    def act(name, body, async) ; @acts << [name, body, async] ; { :action => name } ; end
    def start ; raise @fail_with if @fail_with ; @started = true ; self ; end
    def stop ; @stopped = true ; self ; end
    def started? ; @started ; end
    def stopped? ; @stopped ; end
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
       received last watch quiet sent announced specimens faults peers state guide
       connect listen shutdown no_shutdown clear].each do |v|
      assert_match(/^\s+#{v}\b|\b#{v}\b/, @out.string, v)
    end
  end

  # ---- sessions opened at the prompt: connect and listen ---------------

  # A console whose connect and listen build fake injectors, each with
  # one peer that is up at once, and record the node file they were given.
  def empty_console(up = true, fail_with = nil)
    @built = []
    factory = lambda do |config|
      n = config['neighbors'].first
      p = FakePeer.new(n['address'], up ? FakeNeighbor.new : nil)
      i = FakeInjector.new(FakeSpeaker.new([p]), config)
      i.fail_with = fail_with
      @built << i
      i
    end
    BGP::Sim::Console.new(nil, @out, 3, :factory => factory)
  end

  def test_with_no_session_a_verb_says_how_to_open_one
    c = empty_console
    assert_equal([], c.peers)
    e = assert_raise(ArgumentError) { c.announce('10.1.0.0/24') }
    assert_match(/connect ADDR, remote_as: AS/, e.message)
    assert_match(/--peer/, e.message)
    assert_raise(ArgumentError) { c.n }
  end

  def test_connect_builds_a_node_file_with_router_names_turned_into_its_keys
    c = empty_console
    row = c.connect('10.0.0.9', remote_as: 65_009, port: 1179, hold_time: 30,
                    capabilities: [:as4_byte, { 'add_path' => [3, 1, 1] }], local_address: '10.0.0.1')
    cfg = @built.last.config
    assert_equal(65_001, cfg['as'])
    assert_equal('10.0.0.1', cfg['router_id'])
    assert_equal('10.0.0.1', cfg['local_address'])
    assert_equal([{ 'address' => '10.0.0.9', 'as' => 65_009, 'connect' => true, 'port' => 1179,
                    'hold_time' => 30, 'capabilities' => ['as4_byte', { 'add_path' => [3, 1, 1] }] }],
                 cfg['neighbors'])
    assert(@built.last.started?)
    assert_equal({ :address => '10.0.0.9', :as => 65_002, :state => 'Established' }, row)
    assert_equal(['10.0.0.9'], c.peers.collect { |p| p[:address] })
  end

  def test_listen_is_the_passive_side_and_port_and_local_address_are_ours
    c = empty_console
    c.listen('10.0.0.9', remote_as: 65_009, local_as: 65_100, port: 1179, local_address: '127.0.0.1')
    cfg = @built.last.config
    assert_equal(false, cfg['neighbors'].first['connect'])
    assert_nil(cfg['neighbors'].first['port'])
    assert_equal(1179, cfg['port'])
    assert_equal('127.0.0.1', cfg['listen_address'])
    assert_equal(65_100, cfg['as'])
  end

  def test_listen_defaults_to_port_179
    c = empty_console
    c.listen('10.0.0.9', remote_as: 65_009)
    assert_equal(179, @built.last.config['port'])
  end

  def test_one_session_per_address
    c = empty_console
    c.connect('10.0.0.9', remote_as: 65_009)
    e = assert_raise(ArgumentError) { c.connect('10.0.0.9', remote_as: 65_009) }
    assert_match(/already has a session/, e.message)
    assert_equal(1, @built.size)
  end

  def test_a_taken_port_and_a_privileged_one_are_said_in_words
    c = empty_console(true, Errno::EADDRINUSE)
    assert_raise_message(/port 179 is taken/) { c.listen('10.0.0.9', remote_as: 1) }
    c = empty_console(true, Errno::EACCES)
    assert_raise_message(/port 179 needs root/) { c.listen('10.0.0.9', remote_as: 1) }
    assert_equal([], c.peers, 'a session that did not start is not kept')
  end

  def test_connect_answers_after_wait_when_the_session_is_not_up
    c = empty_console(false)
    t = Time.now
    row = c.connect('10.0.0.9', remote_as: 65_009, wait: 0.2)
    assert_operator(Time.now - t, :>=, 0.2)
    assert_equal('Idle', row[:state])
  end

  def test_with_two_sessions_a_verb_names_its_peer
    c = empty_console
    c.connect('10.0.0.9', remote_as: 65_009)
    c.connect('10.0.0.10', remote_as: 65_010)
    e = assert_raise(ArgumentError) { c.announce('10.1.0.0/24') }
    assert_match(/2 sessions; name one with peer: ADDR/, e.message)
    assert_match(/10\.0\.0\.9, 10\.0\.0\.10/, e.message)
    c.announce('10.1.0.0/24', peer: '10.0.0.10')
    assert_empty(@built[0].acts)
    assert_equal('announce', @built[1].acts.last[0])
    assert_equal(@built[1].speaker.peers.first, c.send(:peer, '10.0.0.10'))
  end

  def test_with_two_sessions_and_one_up_the_verb_goes_to_that_one
    c = empty_console
    c.connect('10.0.0.9', remote_as: 65_009)
    c.connect('10.0.0.10', remote_as: 65_010)
    @built[0].speaker.peers.first.state = 'Active'
    c.announce('10.1.0.0/24')
    assert_equal('announce', @built[1].acts.last[0])
  end

  def test_shutdown_sends_cease_administrative_shutdown_then_stops
    c = empty_console
    c.connect('10.0.0.9', remote_as: 65_009)
    c.shutdown
    acts = @built.last.acts.collect { |a| [a[0], a[1]] }
    assert_equal([['notification', { 'peer' => '10.0.0.9', 'code' => 6, 'subcode' => 2 }],
                  ['session.stop', { 'peer' => '10.0.0.9' }]], acts)
    c.no_shutdown('10.0.0.9')
    assert_equal(['session.start', { 'peer' => '10.0.0.9' }], @built.last.acts.last[0, 2])
  end

  def test_clear_sends_cease_administrative_reset_and_lets_it_return
    c = empty_console
    c.connect('10.0.0.9', remote_as: 65_009)
    c.clear('10.0.0.9')
    assert_equal([['notification', { 'peer' => '10.0.0.9', 'code' => 6, 'subcode' => 4 }]],
                 @built.last.acts.collect { |a| [a[0], a[1]] })
    assert(@built.last.speaker.peers.first.cleared?)
  end

  def test_no_cease_on_a_session_that_is_not_up
    c = empty_console(false)
    c.connect('10.0.0.9', remote_as: 65_009, wait: 0)
    c.clear
    c.shutdown
    assert_equal(['session.stop'], @built.last.acts.collect(&:first))
  end

  def test_stop_stops_the_sessions_it_opened_and_not_the_one_it_was_handed
    c = BGP::Sim::Console.new(@injector, @out, 3, :factory => lambda { |cfg|
      (@built ||= []) << FakeInjector.new(FakeSpeaker.new([FakePeer.new('10.0.0.9', FakeNeighbor.new)]), cfg)
      @built.last
    })
    c.connect('10.0.0.9', remote_as: 65_009)
    c.stop
    assert(@built.last.stopped?)
    assert_nil(@injector.instance_variable_get(:@stopped))
  end

  # ---- guide: docs/console.md at the prompt ---------------------------

  def guide_text(color = false)
    BGP::Sim::Guide.new(File.read(BGP::Sim::Guide::PATH, :encoding => 'UTF-8'), color)
  end

  # Every section of the document is reachable by its number, so a
  # section added to docs/console.md is reachable with no edit here.
  def test_every_section_of_the_document_is_reachable_by_number
    titles = File.read(BGP::Sim::Guide::PATH, :encoding => 'UTF-8').scan(/^## (\d+)\. /).flatten
    assert_operator(titles.size, :>=, 8)
    titles.each do |n|
      text = guide_text.section(n.to_i)
      assert_match(/\A#{n}\. /, text, n)
      assert_no_match(/^#{n.to_i + 1}\. [A-Z]/, text, "section #{n} stops at the next one")
    end
  end

  def test_guide_prints_the_whole_document_on_a_pipe
    @c.guide
    out = @out.string
    assert_match(/\AThe console: bgp4r routegen --interact$/, out)
    assert_match(/^8\. How it is tested/, out)
    assert_no_match(/^```/, out, 'fence lines go')
    assert_no_match(/^\|/, out, 'a table is laid out, not printed raw')
    assert_no_match(/\e\[/, out, 'no colour on a pipe')
  end

  def test_guide_takes_a_number_or_a_word
    @c.guide 6
    assert_match(/\A6\. What the router at the far end needs/, @out.string)
    @out.truncate(0) ; @out.rewind
    @c.guide 'Leaving'
    assert_match(/\A5\. Leaving/, @out.string)
  end

  # A number means the section numbered so, not the first heading that
  # happens to hold the digit.
  def test_a_number_is_a_section_number_and_not_a_substring
    g = BGP::Sim::Guide.new("# T\n\n## 1. Read RFC 4271 first\n\nx\n\n## 4. Four\n\ny\n")
    assert_match(/\A4\. Four/, g.section(4))
    assert_match(/\A1\. Read/, g.section('rfc'))
  end

  # Fenced code is indented, so it stands apart without the fences.
  def test_fenced_code_is_indented
    text = guide_text.section(4)
    assert_match(/^    verbs  +# what to type$/, text)
    assert_match(/^\* \*\*Every verb/, text, 'prose is not indented')
  end

  def test_an_unknown_section_lists_the_ones_there_are
    @c.guide 'no such thing'
    assert_match(/No section "no such thing"/, @out.string)
    assert_match(/^  4\. The prompt opens on the live session/, @out.string)
  end

  # The defaults table lines up, measured at the header's own offsets.
  def test_a_table_is_laid_out_in_columns
    rows = guide_text.section(1).lines.grep(/^  (Setting|Our AS|Hold time|Wait for)/)
    assert_equal(4, rows.size)
    col = rows.first.index('Default')
    rows.drop(1).each { |r| assert_match(/\A\S/, r[col..], r) ; assert_equal(' ', r[col - 1], r) }
  end

  def test_colour_only_when_asked
    plain, colour = guide_text.section(5), guide_text(true).section(5)
    assert_no_match(/\e\[/, plain)
    assert_match(/\e\[1mNo NOTIFICATION is sent\e\[22m/, colour)
    assert_match(/\e\[36mnotification 6, 2\e\[39m/, colour)
  end

  # A StringIO that says it is a terminal, so guide colours and pages.
  class Tty < StringIO
    def tty? ; true ; end
  end

  def test_on_a_terminal_it_goes_through_the_pager_in_colour
    Dir.mktmpdir do |dir|
      file = File.join(dir, 'paged')
      pager, ENV['PAGER'] = ENV['PAGER'], "cat > #{file}"
      out = Tty.new
      BGP::Sim::Console.new(@injector, out, 3).guide 5
      assert_equal('', out.string, 'the pager had it, not the console')
      assert_match(/\A\e\[1m5\. Leaving/, File.read(file))
    ensure
      ENV['PAGER'] = pager
    end
  end

  def test_with_no_pager_a_terminal_still_gets_the_text
    pager, ENV['PAGER'] = ENV['PAGER'], 'no-such-pager-bgp4r'
    out = Tty.new
    BGP::Sim::Console.new(@injector, out, 3).guide 5
    assert_match(/5\. Leaving/, out.string)
  ensure
    ENV['PAGER'] = pager
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
