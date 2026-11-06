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

# lab/speaker.rb as a router, driven from node files. No Docker, no router
# binary, no privilege.
#
#   ruby -I. test/functional/lab/speaker_router_test.rb
#
# Two halves, and they answer different questions.
#
# The loopback half runs three speakers as processes and watches a route
# cross the middle one. That is the thing being added: the protocol
# behaviour is already proved by test/functional/rib_router_test.rb, which
# builds its speakers in Ruby and reads the UPDATE off the wire, so what is
# new here is that a **node file** reaches it. Keep the two in step: a key
# added here that changes what goes on the wire is worth a case there.
#
# The in process half reads the keys with no socket at all, which is where
# a wrong key name or a silently ignored block shows up. It is also the only
# half that can say a node file with none of these keys builds no table,
# which is what keeps every topology written before this one unchanged.
#
# BGP:: names are written out in full, see Conventions in CLAUDE.md.

require 'test/unit'
require_relative 'lab_helper'
require 'lab/speaker'

class LabSpeakerRouterLoopbackTest < Test::Unit::TestCase
  include LabHelper

  PORT = LabHelper::Local.free_port

  MIDDLE_AS = 100
  LEFT_AS = 200
  RIGHT_AS = 300

  LEFT_ROUTE = '10.1.0.0/16'
  OURS = '10.100.0.0/24'

  # Three nodes on loopback. The middle one listens and the other two dial
  # it, each from an address of its own.
  #
  # **Each peer needs its own 127.0.0.x and that is not cosmetic.** A
  # BGP::Rib::Peer is identified by its address, and PeerAdapter builds one
  # from the Neighbor's configured remote_addr rather than from the accepted
  # socket, so two peers both reached at 127.0.0.1 are one Peer as far as
  # the table is concerned: the two Adj-RIB-Outs collapse into one and every
  # route looks like it is going back to its sender. On a real network two
  # peers have two addresses; over loopback they have to be given them.
  def self.nodes
    { 'r2' => { 'router_id' => '0.0.0.2', 'as' => MIDDLE_AS,
                'listen_address' => '127.0.0.1', 'port' => PORT,
                # No next_hops and **no local_address**, which is the
                # ordinary container case: one address, nothing to
                # configure. An IPv4 route takes our own address on each
                # session, which is what RFC 4271 section 5.1.3 asks for,
                # and the speaker reads it off the socket. The next hop
                # assertions below are the only cover that fallback has.
                'export' => {},
                'originate' => [{ 'prefixes' => [OURS], 'med' => 7 }],
                'neighbors' => [{ 'address' => '127.0.0.2', 'as' => LEFT_AS, 'hold_time' => 30 },
                                { 'address' => '127.0.0.3', 'as' => RIGHT_AS, 'hold_time' => 30 }] },
      'r1' => { 'router_id' => '0.0.0.1', 'as' => LEFT_AS,
                'local_address' => '127.0.0.2',
                'neighbors' => [{ 'address' => '127.0.0.1', 'as' => MIDDLE_AS, 'port' => PORT,
                                  'connect' => true, 'retry' => 0.5, 'hold_time' => 30 }],
                'announce' => [{ 'prefixes' => [LEFT_ROUTE] }] },
      'r3' => { 'router_id' => '0.0.0.3', 'as' => RIGHT_AS,
                'local_address' => '127.0.0.3',
                'neighbors' => [{ 'address' => '127.0.0.1', 'as' => MIDDLE_AS, 'port' => PORT,
                                  'connect' => true, 'retry' => 0.5, 'hold_time' => 30 }] } }
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

  def teardown
    puts "\n#{@lab.logs}" unless passed?
  end

  # One best route per prefix in the middle speaker's own state file, by
  # prefix.
  def loc_rib(node = 'r2')
    s = @lab.state(node)
    rows = s && s['loc_rib']
    rows && rows.to_h { |r| [r['prefix'], r] }
  end

  def wait_loc_rib(prefixes, timeout: 30)
    wait_for("r2 Loc-RIB to hold #{prefixes.join(', ')}", timeout: timeout) do
      rows = loc_rib
      rows if rows && (prefixes - rows.keys).empty?
    end
  end

  def test_1_the_route_crosses_the_router_with_the_export_rules_applied
    wait_established(@lab, 'r2', '127.0.0.2')
    wait_established(@lab, 'r2', '127.0.0.3')
    n = wait_routes(@lab, 'r3', '127.0.0.1', [LEFT_ROUTE])
    r = n['received'][LEFT_ROUTE]
    assert_equal("#{MIDDLE_AS} #{LEFT_AS}", r['as_path'],
                 'RFC 4271 section 5.1.2: our AS in front of theirs')
    assert_equal('127.0.0.1', r['next_hop'],
                 'RFC 4271 section 5.1.3: ours on that session, not r1 address')
    assert_nil(r['local_pref'], 'LOCAL_PREF does not go to an external peer')
  end

  # The same route in the router's own Loc-RIB, as plain data rather than
  # as the text of a show command.
  def test_2_the_loc_rib_is_in_the_state_file_as_data
    row = wait_loc_rib([LEFT_ROUTE])[LEFT_ROUTE]
    assert_equal(LEFT_ROUTE, row['prefix'])
    assert_equal('127.0.0.2', row['from'], 'the peer it came from, by address')
    assert_equal(LEFT_AS.to_s, row['as_path'], 'as received, before export prepends ours')
    assert_equal('igp', row['origin'])
    assert_equal(1, row['paths'], 'one path to it, so nothing to choose between')
    assert_equal(true, row['best'])
  end

  # An originate block goes through the Loc-RIB and out with the export
  # rules applied, where an announce block goes straight onto the session.
  # RFC 4271 section 5.1.2 wants our AS alone toward an external peer, and
  # the empty AS_PATH the block starts with is what gives that.
  def test_3_an_originate_block_reaches_the_peer_through_the_rib
    n = wait_routes(@lab, 'r3', '127.0.0.1', [OURS])
    r = n['received'][OURS]
    assert_equal(MIDDLE_AS.to_s, r['as_path'], 'our AS alone, one segment')
    assert_equal('127.0.0.1', r['next_hop'])

    row = wait_loc_rib([OURS])[OURS]
    assert_equal('0.0.0.2', row['from'], 'the local peer, which carries our router ID')
    assert_equal('', row['as_path'], 'empty in the Loc-RIB: export is what prepends')
    assert_equal(7, row['med'], 'the med key of the originate block')
  end

  # **The med key of an originate block does not reach an external peer**,
  # and that is Rib::Export's decision rather than a hole here. RFC 4271
  # section 5.1.4 is about a MED received from a neighboring AS, so an
  # originating speaker may legitimately set one toward its own external
  # peer, and bgp4r deletes it for every external peer alike: the comment
  # on that line reads "A speaker may set a MED of its own toward this
  # peer; that is the policy block's business, not a rule". So the key is
  # worth having, because the Loc-RIB above carries it and so does
  # anything downstream of the Loc-RIB, and a reader of docs/daemon.md's
  # originate example has to know where it stops. My first version of
  # this file asserted the opposite and the library was right.
  def test_3a_the_med_of_an_originate_block_stops_at_an_external_peer
    n = wait_routes(@lab, 'r3', '127.0.0.1', [OURS])
    assert_nil(n['received'][OURS]['med'])
  end

  # A route is not sent back to the peer it came from, and the state file
  # says so per peer. A route silently not advertised is the hardest kind of
  # bug to see from outside, which is why this is asserted and not left to
  # the count of what arrived.
  def test_4_the_state_file_says_what_was_advertised_and_what_was_not
    wait_routes(@lab, 'r3', '127.0.0.1', [LEFT_ROUTE, OURS])
    right = wait_for('r2 to record two routes advertised to r3') do
      n = neighbor(@lab, 'r2', '127.0.0.3')
      n if n && n['advertised'] == 2
    end
    assert_equal([], right['skipped'], 'nothing refused toward r3')

    left = neighbor(@lab, 'r2', '127.0.0.2')
    assert_equal(1, left['advertised'], 'r1 gets what we originate and nothing else')
    assert_equal([{ 'prefix' => LEFT_ROUTE, 'reason' => 'back_to_sender' }], left['skipped'])

    s = @lab.state('r2')
    assert_equal(true, s['router']['advertising'])
    assert_operator(s['router']['updates_sent'], :>=, 2)
    assert_nil(s['fib'], 'no fib block, so nothing claims to be installed')
  end

  # The other half of a transit router, and the half easiest to leave out:
  # a peer told about a route and never told it went holds it for ever.
  def test_5_the_withdrawal_crosses_when_the_far_session_drops
    wait_routes(@lab, 'r3', '127.0.0.1', [LEFT_ROUTE])
    @lab.stop('r1')
    wait_for('r3 to lose the route r1 originated', timeout: 20) do
      n = neighbor(@lab, 'r3', '127.0.0.1')
      n && n['state'] == 'Established' && !n['received'].key?(LEFT_ROUTE)
    end
    assert(neighbor(@lab, 'r3', '127.0.0.1')['received'].key?(OURS),
           'and keeps what the router originated itself')
    wait_for('r2 Loc-RIB to drop it too') { !loc_rib.key?(LEFT_ROUTE) }
  end
end

# One session at a time, in process, over a real socket. This is here for
# one claim the loopback lab cannot make: that a reconnect leaves one
# adapter in the feed and not one per session.
#
# **The detach in Peer#run_session is hygiene and not what removes the
# peer's routes**, which is worth knowing before anyone deletes it as
# redundant. PeerAdapter#state_change queues :peer_down the moment a
# session leaves Established, so RFC 4271 section 6 is answered either
# way: deleting the detach failed nothing in the loopback lab, which is a
# sabotage missing rather than a weak test, and this class is what the
# claim needed instead. A Neighbor per session is an adapter per session,
# and PeerFeed#adapters is what Router#run_changes walks, so a speaker
# reconnecting every retry seconds to a peer that is down would
# accumulate one for every attempt.
class LabSpeakerRouterFlapTest < Test::Unit::TestCase

  def setup
    @server = TCPServer.new('127.0.0.1', 0)
    @far = nil
    @speaker = Lab::Speaker.new('as' => 65001, 'router_id' => '0.0.0.1',
                                'local_address' => '127.0.0.1', 'rib' => true,
                                'neighbors' => [{ 'address' => '127.0.0.2', 'as' => 65002 }])
    @speaker.start_rib
    @acceptor = Thread.new do
      loop { @speaker.peers.first.accept(@server.accept) }
    rescue IOError, SystemCallError
    end
  end

  def teardown
    @far.stop if @far
    @acceptor.kill if @acceptor
    @server.close unless @server.closed?
    @speaker.stop_rib
  end

  def wait_for(timeout = 5)
    deadline = Time.now + timeout
    loop do
      return true if yield
      return false if Time.now > deadline
      sleep 0.02
    end
  end

  # The far speaker dials in from 127.0.0.2, which is the address the node
  # file names, so the adapter builds the Peer the table expects.
  def connect
    @far = BGP::Neighbor.new(4, 65002, 180, '0.0.0.2', '127.0.0.1', '127.0.0.2')
    @far.start(:port => @server.addr[1])
    assert(wait_for { @far.is_established? }, 'the far side came up')
    assert(wait_for { @speaker.rib.feed.adapters.size >= 1 })
  end

  def test_a_reconnect_leaves_one_adapter_in_the_feed
    connect
    @far.send_update BGP::Update.new(
      BGP::Path_attribute.new(BGP::Origin.new(0), BGP::Next_hop.new('10.9.9.9'),
                              BGP::As_path.new(65_002)),
      BGP::Nlri.new('10.1.0.0/16'))
    assert(wait_for { @speaker.rib.drain && @speaker.rib.loc_rib.size == 1 },
           'the table took the route')

    @far.stop
    assert(wait_for { @speaker.rib.drain && @speaker.rib.loc_rib.empty? },
           'and the session going down took it back, which is PeerAdapter and not the detach')
    connect

    assert_equal(1, @speaker.rib.feed.adapters.size,
                 'one adapter after two sessions, which is what the detach is for')
  end
end

# The node file keys with no session, no process and no table thread. This
# is where a key name that does not reach bgp/rib/ shows up.
class LabSpeakerRouterConfigTest < Test::Unit::TestCase

  def speaker(extra = {})
    Lab::Speaker.new({ 'as' => 65001, 'router_id' => '10.0.0.1',
                       'local_address' => '10.0.0.1',
                       'neighbors' => [{ 'address' => '10.0.0.2', 'as' => 65002 }] }.merge(extra))
  end

  # The whole of what keeps every topology written before this unchanged:
  # with none of the four keys nothing builds a table and nothing starts a
  # thread.
  def test_a_node_file_with_no_router_keys_builds_no_table
    assert_nil(speaker.rib)
    assert_equal(false, speaker.rib?)
  end

  # rib: on its own is a speaker that decides what its peers send and
  # advertises nothing, which is the case the other three keys cannot
  # express.
  def test_rib_on_its_own_builds_a_table_that_advertises_nothing
    s = speaker('rib' => true)
    assert_instance_of(BGP::Rib::Table, s.rib)
    s.start_rib
    assert_nil(s.router, 'no export block, so no router mode')
  ensure
    s.stop_rib
  end

  def test_each_of_the_other_three_keys_implies_a_table
    [{ 'export' => {} },
     { 'originate' => [{ 'prefixes' => ['10.1.0.0/16'] }] },
     { 'fib' => { 'table' => 100 } }].each do |extra|
      assert_equal(true, speaker(extra).rib?, "#{extra.keys.first} implies a table")
    end
  end

  # The export keys reach Rib::Router and Rib::Export, which is the only
  # thing a node file can do about reflection.
  def test_the_export_block_becomes_router_and_export_options
    o = speaker('export' => { 'next_hops' => { 1 => '10.0.0.1', '2' => '2001:db8::1' },
                              'route_reflector' => true, 'clients' => ['10.0.0.2'],
                              'cluster_id' => '7.7.7.7',
                              'mrai' => { 'ebgp' => 30, 'ibgp' => 5 } }).export_options
    assert_equal({ 1 => '10.0.0.1', 2 => '2001:db8::1' }, o[:next_hops],
                 'an AFI from YAML may be a string, and Export keys on the number')
    assert_equal({ :ebgp => 30, :ibgp => 5 }, o[:mrai])
    assert_equal(true, o[:export].route_reflector?)
    assert_equal('7.7.7.7', o[:export].cluster_id)
    assert_equal(true, o[:export].client?(BGP::Rib::Peer.new(:address => '10.0.0.2',
                                                             :remote_as => 65001,
                                                             :router_id => '10.0.0.2',
                                                             :local_as => 65001)))
  end

  # RFC 4271 section 9.2.1.1 off by default, which is the recorded decision:
  # a script driving a router through a sequence of UPDATEs wants each one on
  # the wire when it says so.
  def test_mrai_is_off_unless_the_node_file_asks_for_it
    s = speaker('export' => {})
    assert_nil(s.export_options[:mrai])
    s.start_rib
    assert_equal(true, s.router.mrai.off?)
    assert_equal(false, s.router.pacing?, 'and no timer thread')
  ensure
    s.stop_rib
  end

  # An export block with no policy key leaves Router to build the plain
  # Export from the table's own AS and router ID, so nothing here invents
  # a reflector.
  def test_an_empty_export_block_builds_no_export_object
    assert_nil(speaker('export' => {}).export_options[:export])
  end

  # A typo in a node file that quietly turned reflection off would be the
  # worst of both, so an unknown key says so. Lab.main turns an
  # ArgumentError into abort, which is what an operator sees.
  def test_an_unknown_export_key_names_itself_and_the_keys_there_are
    e = assert_raise(ArgumentError) { speaker('export' => { 'reflector' => true }).export_options }
    assert_match(/reflector/, e.message)
    assert_match(/route_reflector/, e.message, 'and lists the names there are')
  end

  def test_an_unknown_fib_key_names_itself
    e = assert_raise(ArgumentError) { speaker('fib' => { 'table' => 1, 'tabel' => 2 }).fib_options }
    assert_match(/tabel/, e.message)
  end

  # table has no default in Rib::Fib::IpRoute and none here: a route in the
  # main table changes where the machine sends its own traffic, so nobody
  # reaches it without naming it.
  def test_a_fib_block_with_no_table_is_refused
    e = assert_raise(ArgumentError) { speaker('fib' => { 'netns' => 'lab' }).fib_options }
    assert_match(/table/, e.message)
  end

  def test_the_fib_keys_become_ip_route_options
    assert_equal({ :table => 100, :netns => 'lab', :proto => 'bgp', :dev => 'eth0' },
                 speaker('fib' => { 'table' => 100, 'netns' => 'lab',
                                    'proto' => 'bgp', 'dev' => 'eth0' }).fib_options)
  end

  # An originate block's attributes are not an announce block's, and the two
  # differences are RFC 4271 section 5.1's. AS_PATH is empty, because
  # section 5.1.2 wants an empty one toward an internal peer and ours alone
  # toward an external one, and the export step gives both from an empty
  # attribute. NEXT_HOP is a placeholder, because section 5.1.3 makes it
  # ours on each session.
  def test_an_originate_block_starts_with_an_empty_as_path
    pa = speaker.originate_attribute('prefixes' => ['10.1.0.0/16'])
    assert_equal('empty', pa[BGP::As_path].as_path)
    assert_equal('10.0.0.1', pa[BGP::Next_hop].next_hop, 'our router ID, which export replaces')
    assert_equal(0, pa[BGP::Origin].to_i)
    assert(!pa.has?(BGP::Local_pref), 'no local_pref key, so none is sent')
  end

  def test_an_originate_block_carries_its_own_attributes
    pa = speaker.originate_attribute('prefixes' => ['10.1.0.0/16'], 'med' => 10,
                                     'local_pref' => 200, 'origin' => 2,
                                     'communities' => ['65001:1', '65001:2'])
    assert_equal(10, pa[BGP::Multi_exit_disc].to_i)
    assert_equal(200, pa[BGP::Local_pref].to_i)
    assert_equal(2, pa[BGP::Origin].to_i)
    assert_equal('65001:1 65001:2', pa[BGP::Communities].communities)
  end

  # Nothing validates, per Conventions: an AS_PATH on a route we originate
  # is a route claiming to have crossed an AS it never did, which is a test
  # a topology has to be able to run.
  def test_an_originate_block_may_name_an_as_path_no_rfc_allows
    pa = speaker.originate_attribute('prefixes' => ['10.1.0.0/16'], 'as_path' => [64_999])
    assert_equal('64999', pa[BGP::As_path].as_path)
  end

  def test_originate_puts_its_prefixes_in_the_loc_rib
    s = speaker('originate' => [{ 'prefixes' => ['10.1.0.0/16', '10.2.0.0/16'] },
                                { 'prefixes' => ['10.3.0.0/16'], 'med' => 1 }])
    s.start_rib
    assert_equal(['10.1.0.0/16', '10.2.0.0/16', '10.3.0.0/16'], s.rib.originated.sort)
    assert_equal(1, s.rib.best('10.3.0.0/16').med)
  ensure
    s.stop_rib
  end

  # The state file's row shape is docs/daemon.md's show.routes, as data: a
  # driver reads this file, and the three styles of bgp/rib/show.rb are
  # vendor presentation that nothing has been diffed against a real device.
  def test_the_loc_rib_in_the_state_file_is_data_and_not_show_text
    s = speaker('originate' => [{ 'prefixes' => ['10.1.0.0/16'], 'med' => 4 }])
    s.start_rib
    rows = s.state['loc_rib']
    assert_equal(1, rows.size)
    assert_equal(%w[prefix next_hop as_path origin med local_pref from paths best].sort,
                 rows.first.keys.sort)
    assert_equal('10.1.0.0/16', rows.first['prefix'])
    assert_equal(4, rows.first['med'])
    assert_equal('igp', rows.first['origin'])
    assert_equal(rows, JSON.parse(JSON.generate(rows)),
                 'what is recorded and what is written are the same data')
  ensure
    s.stop_rib
  end

  def test_a_speaker_with_no_table_writes_no_rib_keys
    s = speaker
    assert_equal(false, s.state.key?('loc_rib'))
    assert_equal(false, s.state.key?('router'))
    assert_equal(false, s.state.key?('fib'))
    assert_equal(false, s.state['neighbors']['10.0.0.2'].key?('advertised'),
                 'and no neighbor claims anything was advertised to it')
  end

  # Installing needs CAP_NET_ADMIN and the lab speaker runs as the non-root
  # user bgp, so a node file asking for a table it cannot write is an
  # ordinary thing to meet and has to say why rather than taking the
  # speaker down with it. A namespace that does not exist is the same
  # question with a reproducible answer: every command fails, and each
  # failure is a row in the state file rather than an exception out of the
  # worker thread.
  #
  # The route is announced into the table directly rather than through
  # originate, because a prefix we originate is never installed and so
  # never runs a command to fail. That skip is the second assertion.
  def test_a_fib_command_that_fails_is_a_row_in_the_state_file
    s = speaker('originate' => [{ 'prefixes' => ['10.9.0.0/16'] }],
                'fib' => { 'table' => 100, 'netns' => 'bgp4r-no-such-netns' })
    s.start_rib
    peer = BGP::Rib::Peer.new(:address => '10.0.0.2', :remote_as => 65002,
                              :router_id => '2.2.2.2', :local_as => 65001)
    pa = BGP::Path_attribute.new(BGP::Origin.new(0), BGP::As_path.new(65002),
                                 BGP::Next_hop.new('10.0.0.2'))
    s.rib.announce(BGP::Rib::Route.new('10.1.0.0/16', pa, peer))
    s.rib.drain
    assert_equal(:originated, s.rib.fib.skipped['10.9.0.0/16'],
                 'our own prefix ran no command')
    fib = s.state['fib']
    assert_equal('100', fib['table'])
    assert_equal(0, fib['installed'], 'nothing is claimed to be in the table')
    assert_equal(['10.1.0.0/16'], fib['failed'].collect { |f| f['prefix'] })
    assert_match(/ip/, fib['failed'].first['error'], 'and the command that failed')
  ensure
    s.stop_rib
  end
end
