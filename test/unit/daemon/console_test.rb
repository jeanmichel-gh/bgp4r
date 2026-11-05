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

# The prompt of `bgp4rd --interact`, over a real Speaker, Views and Api
# with no socket and no session: `Api#handle` is the entry point the
# socket uses, and it needs neither. A session crossing the prompt is
# test/functional/daemon_test.rb's. Nothing here reaches irb, which
# reads standard input.
#
#   ruby -I. test/unit/daemon/console_test.rb
#
# BGP:: names are written out in full here, see Conventions in CLAUDE.md.

require 'test/unit'
require 'stringio'
require 'bgp/daemon/views'
require 'bgp/daemon/candidate'
require 'bgp/daemon/api'
require 'bgp/daemon/console'

class BGP_Daemon_Console_Test < Test::Unit::TestCase

  NEIGHBORS = [{ 'address' => '10.0.0.2', 'as' => 65_001, 'description' => 'up1' },
               { 'address' => '10.0.0.3', 'as' => 65_002 }].freeze

  def setup
    @out = StringIO.new
    @c = console
  end

  def teardown
    @speaker.stop_rib if @speaker
  end

  def console(extra = {})
    config = { 'as' => 65_000, 'router_id' => '10.0.0.1', 'rib' => true,
               'neighbors' => NEIGHBORS }.merge(extra)
    @speaker = BGP::Daemon::Speaker.new(config)
    @speaker.start_rib
    views = BGP::Daemon::Views.new(@speaker)
    api = BGP::Daemon::Api.new(views, :candidate => BGP::Daemon::Candidate.new(@speaker, config))
    BGP::Daemon::Console.new(api, @out)
  end

  # ---- the socket's methods, as the socket answers them ---------------

  # The answer has been through JSON, so it is what bgp4r-cli would
  # print: String keys, and a Symbol nowhere.
  def test_api_answers_what_the_socket_would_send
    r = @c.api('route.originate', :prefix => '10.255.0.0/24')
    assert_equal(%w[changes marked originated rib total], r.keys.sort)
    assert_equal(['10.255.0.0/24'], r['originated'])
  end

  # A refusal is the daemon's own message, raised, so irb prints it.
  def test_a_refusal_is_the_daemons_own_message
    e = assert_raise(ArgumentError) { @c.api('show.adj_in', :peer => '10.9.9.9') }
    assert_match(/no neighbor "10.9.9.9" is configured; this bgp4rd has 10.0.0.2, 10.0.0.3/, e.message)
    e = assert_raise(ArgumentError) { @c.api('show.nothing') }
    assert_match(/unknown method "show.nothing"/, e.message)
  end

  # Each acting verb goes through Api#handle with the socket's method
  # name, which is the whole claim that the prompt and bgp4r-cli cannot
  # disagree.
  def test_every_acting_verb_is_a_socket_method
    called = []
    api = @c.api_server
    api.define_singleton_method(:handle) { |req| called << req['method'] ; super(req) }
    @c.originate('10.255.0.0/24')
    @c.announce('10.255.1.0/24')
    @c.withdraw('10.255.1.0/24')
    @c.clear('10.0.0.2')
    @c.shutdown('10.0.0.2')
    @c.no_shutdown('10.0.0.2')
    assert_raise(ArgumentError) { @c.refresh('10.0.0.3') }
    assert_equal(%w[route.originate route.originate route.withdraw peer.clear
                    peer.stop peer.start peer.refresh], called)
  end

  # The sending verbs are socket methods too, all but `ship`, which takes
  # an object and so goes to the same `Control#ship` they end in.
  def test_every_sending_verb_but_ship_is_a_socket_method
    up('10.0.0.2')
    called = []
    api = @c.api_server
    api.define_singleton_method(:handle) { |req| called << req['method'] ; super(req) }
    @c.specimen(:large_communities, '10.30.0.0/24', peer: '10.0.0.2')
    @c.fault(:origin_value, '10.10.0.0/24', peer: '10.0.0.2')
    @c.replay('00', peer: '10.0.0.2')
    @c.resend('10.0.0.2')
    @c.ship(BGP::Keepalive.new, peer: '10.0.0.2')
    assert_equal(%w[peer.specimen peer.fault peer.replay peer.resend], called)
  end

  # ---- sending by hand ------------------------------------------------

  # A Peer whose session says it is up and keeps what it is sent.
  def up(address)
    p = @speaker.peer(address)
    sent = []
    p.define_singleton_method(:established?) { true }
    p.define_singleton_method(:send_message) { |m| sent << m }
    p.define_singleton_method(:local_ip) { '10.0.0.1' }
    sent
  end

  # docs/console.md section 10 step 6 and 7, as the prompt prints them:
  # the rows unchanged, and the list beside them.
  def test_adj_out_prints_what_was_sent_by_hand_after_the_rows
    up('10.0.0.3')
    @c.specimen(:large_communities, '10.30.0.0/24', peer: '10.0.0.3')
    @c.fault(:origin_value, '10.10.0.0/24', peer: '10.0.0.3')
    @out.truncate(0) ; @out.rewind
    @c.adj_out('10.0.0.3')
    text = @out.string
    assert_match(/^sent by hand, state at peer unknown:$/, text)
    assert_match(/^10\.30\.0\.0\/24\s+specimen large_communities at \d\d:\d\d:\d\d$/, text)
    assert_match(/^10\.10\.0\.0\/24\s+fault origin_value at \d\d:\d\d:\d\d$/, text)
    assert_operator(text.index('specimen'), :<, text.index('fault origin_value'), 'oldest first')
  end

  def test_adj_out_prints_nothing_about_hand_until_something_is_sent
    @c.adj_out('10.0.0.3')
    assert_no_match(/sent by hand/, @out.string)
  end

  def test_peers_has_a_hand_column
    up('10.0.0.3')
    @c.fault(:origin_value, '10.10.0.0/24', '10.11.0.0/24', peer: '10.0.0.3')
    @c.peers
    lines = @out.string.lines
    assert_match(/\bbest\s+hand$/, lines[0])
    assert_match(/\s0$/, lines[1])
    assert_match(/\s2$/, lines[2])
  end

  # `ship` sends the object as it is and reads it back for the list.
  def test_ship_sends_the_object_and_lists_what_it_carries
    sent = up('10.0.0.3')
    u = BGP::Update.new(BGP::Path_attribute.new(BGP::Origin.new(0), BGP::As_path.new(65_000),
                                                BGP::Next_hop.new('127.0.0.1')),
                        BGP::Nlri.new('10.40.0.0/24'))
    r = @c.ship(u, peer: '10.0.0.3')
    assert_same(u, sent.first)
    assert_equal({ 'peer' => '10.0.0.3', 'prefixes' => ['10.40.0.0/24'] }, r)
    assert_equal('ship', @speaker.hand.rows('10.0.0.3').first[:verb])
  end

  def test_a_whole_peer_row_prints_as_the_whole_peer
    up('10.0.0.3')
    @c.replay('ff', peer: '10.0.0.3')
    @out.truncate(0) ; @out.rewind
    @c.adj_out('10.0.0.3')
    assert_match(/^\(the whole peer\)\s+replay at /, @out.string)
  end

  def test_resend_answers_as_peer_resend
    up('10.0.0.3')
    @c.fault(:origin_value, '10.10.0.0/24', peer: '10.0.0.3')
    r = @c.resend('10.0.0.3')
    assert_equal({ 'peer' => '10.0.0.3', 'resent' => [], 'withdrawn' => ['10.10.0.0/24'], 'hand' => 0 }, r)
  end

  # ---- reading --------------------------------------------------------

  # Every configured peer is listed, the ones that are down included.
  def test_peers_lists_every_configured_peer
    assert_nil(@c.peers)
    lines = @out.string.lines
    assert_match(/\Apeer\s+as\s+state\s+uptime\s+rcvd\s+sent\s+best/, lines[0])
    assert_match(/\A10\.0\.0\.2\s+65001\s+idle\s+-\s+0\s+-\s+0/, lines[1])
    assert_match(/\A10\.0\.0\.3\s+65002\s+idle/, lines[2])
    assert_equal(3, lines.size)
  end

  def test_rib_prints_show_bgp
    @c.originate('10.255.0.0/24')
    assert_nil(@c.rib)
    assert_match(/Network\s+Next Hop/, @out.string)
    assert_match(%r{10\.255\.0\.0/24}, @out.string)
  end

  def test_rib_takes_a_style
    @c.originate('10.255.0.0/24')
    @c.rib(:junos)
    assert_match(/inet\.0/, @out.string)
  end

  def test_why_prints_each_path_with_its_reason
    @c.originate('10.255.0.0/24')
    assert_nil(@c.why('10.255.0.0/24'))
    lines = @out.string.lines
    assert_match(%r{\A10\.255\.0\.0/24, 1 path, decided at the }, lines[0])
    assert_match(/\A  best  from 10\.0\.0\.1/, lines[1])
  end

  def test_why_says_when_a_prefix_is_not_there
    @c.why('10.99.0.0/24')
    assert_equal("10.99.0.0/24 is not in the Loc-RIB\n", @out.string)
  end

  def test_adj_in_and_adj_out_print_a_heading_for_a_peer_with_no_routes
    @c.adj_in('10.0.0.2')
    assert_match(/\Afrom\s+prefix\s+next hop\s+as path\s+communities/, @out.string)
    @out.truncate(0) ; @out.rewind
    @c.adj_out('10.0.0.2')
    assert_match(/\Aprefix\s+next hop\s+as path/, @out.string)
  end

  def test_adj_in_refuses_a_peer_nobody_configured
    assert_raise(ArgumentError) { @c.adj_in('10.9.9.9') }
  end

  def test_fib_with_no_fib_key_says_so
    @c.fib
    assert_match(/no fib: key/, @out.string)
  end

  # ---- acting ---------------------------------------------------------

  # The mark of the configuration goes on a route made at the prompt.
  def test_originate_carries_the_mark
    c = console('mark' => { 'large_communities' => ['65000:1:1'] })
    r = c.originate('10.255.1.0/24', communities: ['65000:100'])
    assert_equal(true, r['marked'])
    row = c.api('show.routes', :prefix => '10.255.1.0/24')['rows'].first
    assert_equal(['65000:100'], row['communities'])
    assert_equal(['65000:1:1'], row['large_communities'])
  end

  def test_withdraw_answers_not_held_as_route_withdraw_does
    r = @c.withdraw('10.10.0.0/24')
    assert_equal([], r['withdrawn'])
    assert_equal(['10.10.0.0/24'], r['not_held'])
  end

  # With no session there is nothing to send a Cease on, so clear is
  # peer.clear alone.
  def test_clear_with_no_session_is_peer_clear
    r = @c.clear('10.0.0.2')
    assert_equal(true, r['cleared'])
    assert_equal('idle', r['state'])
  end

  def test_shutdown_stays_down_until_no_shutdown
    assert_equal(true, @c.shutdown('10.0.0.2')['shutdown'])
    assert_equal(false, @c.no_shutdown('10.0.0.2')['shutdown'])
  end

  # A verb with no peer goes to the only one configured or the only one
  # up, and otherwise says which there are rather than picking.
  def test_with_two_peers_and_none_up_a_verb_asks_which
    e = assert_raise(ArgumentError) { @c.clear }
    assert_match(/2 peers; name one. The peers are 10.0.0.2, 10.0.0.3/, e.message)
  end

  def test_with_one_peer_a_verb_needs_no_address
    c = console('neighbors' => [NEIGHBORS.first])
    assert_equal('10.0.0.2', c.clear['peer'])
    assert_equal('Idle', c.state)
  end

  def test_neighbor_with_no_session_says_so
    e = assert_raise(ArgumentError) { @c.n('10.0.0.2') }
    assert_match(/10.0.0.2 has no session yet/, e.message)
  end

  # Leaving sends a Cease to the peers that are up, and there are none.
  def test_stop_with_no_session_up_sends_nothing
    assert_equal(0, @c.stop)
  end

  # ---- the prompt -----------------------------------------------------

  def test_the_prompt_reads_bgp4rd
    assert_equal('bgp4rd', @c.to_s)
    assert_match(/self is the daemon/, @c.banner)
  end

  # An irb command wins over a method of the same name, so a verb with
  # one of those names could never be typed. Asked of irb itself when it
  # loads, and of a fixed list when it does not.
  def test_no_verb_is_an_irb_command
    names = %w[help ls next step delete info source exit cd edit measure history]
    begin
      BGP::Daemon::Console.load_irb
      require 'irb/command'
      names |= IRB::Command.commands.keys.collect(&:to_s)
    rescue LoadError, NameError
      nil
    end
    verbs = BGP::Daemon::Console.public_instance_methods(false).collect(&:to_s) +
            BGP::Prompt.public_instance_methods.collect(&:to_s)
    assert_empty(verbs & names)
  end

  def test_verbs_lists_every_verb
    @c.verbs
    %w[peers rib why adj_in adj_out fib originate announce withdraw clear shutdown
       no_shutdown refresh specimen fault replay ship resend api received last watch quiet
       state neighbor verbs guide].each do |v|
      assert_match(%r{^\s+(\S+(, | / ))?#{v}\b}, @out.string, v)
    end
  end

  # docs/console.md section 10 names the verbs, and each one it names
  # has to answer here.
  def test_every_verb_the_guide_names_is_here
    doc = File.read('docs/console.md', :encoding => 'UTF-8')
    # The three bullets that list the verbs, and not the notes after
    # them, which name the verbs 3b-iii has still to build.
    section = doc[/^\* \*\*Reading\*\*.*?(?=^Built, in bgp\/daemon\/console\.rb)/m]
    assert_not_nil(section, 'docs/console.md has the bgp4rd --interact verb list')
    named = section.scan(/`([a-z_]+)(?: [A-Z]+)*`/).flatten.uniq
    assert_operator(named.size, :>=, 15, "the guide names the verbs: #{named.inspect}")
    named.each { |v| assert(@c.respond_to?(v), "docs/console.md names #{v}") }
  end

  # The prompt must not load the injector: a daemon that wants a prompt
  # has no use for one.
  def test_it_loads_without_the_injector
    out = IO.popen([RbConfig.ruby, '-I.', '-e',
                    'require "bgp/daemon"; require "bgp/daemon/console"; p defined?(BGP::Sim::Injector).nil?'], &:read)
    assert_equal("true\n", out)
  end

end
