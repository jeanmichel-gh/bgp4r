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

# bgp4r-sim's ten actions, with a fake peer in place of a session.
#
#   ruby -I. test/unit/sim/injector_test.rb
#
# **The assertion in most cases is the hex**, which is Testing in
# CLAUDE.md: an object is its encoded value, and what this file is really
# asking is whether an action produces the octets it says it does. A fake
# peer that keeps what it was handed is all that needs, and it is what
# lets every refusal and every message be reached with no socket at all.
# `test/functional/sim_test.rb` is the other half, over a real session
# and the real HTTP API.
#
# BGP:: names are written out in full, see Conventions in CLAUDE.md,
# including in the nested fake, which does not see an include in the
# class around it.
require 'test/unit'
require 'bgp/sim/injector'

class BGP_Sim_Injector_Test < Test::Unit::TestCase

  # A peer with no session: it keeps what it was handed instead of
  # writing it, and answers the handful of questions the Injector asks
  # of a Peer.
  class FakePeer
    attr_reader :address, :remote_as, :sent, :config
    attr_accessor :established, :down

    def initialize(address, remote_as, my_as, config = {})
      @address, @remote_as, @my_as = address, remote_as, my_as
      @config = { 'address' => address, 'as' => remote_as }.merge(config)
      @sent = []
      @established = true
      @down = false
    end

    def ebgp? ; @remote_as != @my_as ; end
    def active? ; @config.fetch('connect', false) ; end
    def description ; @config['description'] ; end
    def established? ; @established && !@down ; end
    def state ; established? ? 'Established' : 'Idle' ; end
    def session_info ; nil ; end
    def local_ip ; '10.0.0.1' ; end
    def shutdown? ; @down ; end
    def admin_stop ; @down = true ; self ; end
    def admin_start ; @down = false ; self ; end
    def recorder ; @recorder ||= BGP::Daemon::Recorder.new ; end

    # Speaker#stop calls it on every peer.
    def stop ; @established = false ; self ; end

    def send_message(msg)
      raise BGP::Daemon::NoSession, "no established session to #{@address}" unless established?
      @sent << msg
      msg
    end

    # The hex of each message, which is how a test reads what went out.
    def hex
      @sent.collect { |m| m.is_a?(String) ? m.unpack1('H*') : m.to_shex }
    end

    def updates
      @sent.select { |m| m.is_a?(BGP::Update) }
    end
  end

  CONFIG = { 'router_id' => '10.0.0.1', 'as' => 65_001,
             'neighbors' => [{ 'address' => '10.0.10.2', 'as' => 65_000 }] }.freeze

  # An injector whose peers are fakes, so an action sends somewhere a
  # test can read. The Speaker's own peers Array is replaced in place,
  # which is the one seam a unit test needs: everything else about the
  # Injector is reached through it.
  def injector(config = {}, peers = nil)
    inj = BGP::Sim::Injector.new(CONFIG.merge(config))
    @peers = peers || [FakePeer.new('10.0.10.2', 65_000, 65_001)]
    inj.speaker.peers.clear
    @peers.each { |p| inj.speaker.peers << p }
    inj
  end

  def peer ; @peers.first ; end

  # ---- the node file -------------------------------------------------

  # The first row of docs/daemon.md's two-programs table: an injector
  # holds no Loc-RIB. A node file asking for one is refused by name
  # rather than quietly deciding routes inside an injector.
  def test_a_router_key_is_refused_and_names_the_daemon
    BGP::Sim::Injector::ROUTER_KEYS.each do |key|
      e = assert_raise(BGP::Sim::Injector::Refused) do
        BGP::Sim::Injector.new(CONFIG.merge(key => true))
      end
      assert_match(/#{key}/, e.message)
      assert_match(/bgp4rd/, e.message, "#{key}: the refusal says which program has it")
    end
  end

  def test_an_unknown_configuration_key_is_refused_and_names_the_ones_it_reads
    e = assert_raise(BGP::Sim::Injector::Refused) do
      BGP::Sim::Injector.new(CONFIG.merge('announcement' => []))
    end
    assert_match(/announcement/, e.message)
    assert_match(/router_id/, e.message)
  end

  # The injector builds its sessions through the daemon's Peer, so a
  # neighbor typo is refused here too, before any session starts.
  def test_an_unknown_neighbor_key_is_refused
    neighbors = CONFIG['neighbors'].map { |n| n.merge('hold_tme' => 30) }
    e = assert_raise(ArgumentError) { BGP::Sim::Injector.new(CONFIG.merge('neighbors' => neighbors)) }
    assert_match(/unknown key\(s\) hold_tme/, e.message)
  end

  # An injector holds no Loc-RIB, so it has nothing to reflect.
  def test_a_route_reflector_client_flag_is_refused
    neighbors = CONFIG['neighbors'].map { |n| n.merge('route_reflector_client' => true) }
    e = assert_raise(BGP::Sim::Injector::Refused) { BGP::Sim::Injector.new(CONFIG.merge('neighbors' => neighbors)) }
    assert_match(/route_reflector_client: an injector reflects nothing/, e.message)
  end

  def test_a_configuration_that_is_not_a_mapping_is_refused
    assert_raise(BGP::Sim::Injector::Refused) { BGP::Sim::Injector.new([]) }
  end

  def test_no_table_is_built_for_a_node_file_with_no_router_key
    assert_nil(injector.speaker.rib)
  end

  # **It starts silent**, and this is where that comes from: with no
  # announce block there is nothing for Peer#announce to send on
  # establishment, so a scenario's baseline really is empty.
  def test_it_starts_silent_and_a_config_block_is_the_one_waiver
    assert_equal(0, injector.speaker.announcements.size)
    inj = injector('announce' => [{ 'prefixes' => ['10.1.0.0/24'] }])
    assert_equal(1, inj.speaker.announcements.size,
                 'a node file that asks for a feed at start-up is the documented waiver')
  end

  # ---- announce ------------------------------------------------------

  def test_an_announce_carries_all_three_kinds_of_community
    inj = injector
    inj.act('announce', 'prefixes' => ['10.1.0.0/24'],
                        'communities' => ['65001:7'],
                        'extended_communities' => ['route_target:65001:9', 'route_origin:10.0.0.1:3'],
                        'large_communities' => ['65001:1:2'])
    pa = peer.updates.first.path_attribute
    assert_equal('65001:7', pa[:communities].communities)
    assert_equal([{ :route_target => [65001, 9] }, { :route_origin => ['10.0.0.1', 3] }],
                 pa[:extended_communities].to_hash[:extended_communities])
    assert_equal(['65001:1:2'], pa[:large_communities].communities.collect(&:to_s))
  end

  def test_an_extended_community_that_is_not_kind_and_value_is_refused
    assert_raise(ArgumentError) do
      injector.act('announce', 'prefixes' => ['10.1.0.0/24'], 'extended_communities' => ['65001'])
    end
  end

  def test_the_extended_community_text_is_the_hash_spelled_flat_both_ways
    k = BGP::Daemon::CommunityKeys
    ['route_target:65000:7', 'route_origin:10.0.0.1:3'].each do |t|
      assert_equal(t, k.extended_community_text(k.extended_community_hash(t)))
    end
  end

  def test_an_announce_sends_one_update_with_the_blocks_attributes
    inj = injector
    r = inj.act('announce', 'prefixes' => ['10.1.0.0/24'], 'med' => 100,
                            'communities' => ['65001:7'])
    assert_equal(1, r[:updates])
    assert_equal(['10.0.10.2'], r[:peers])
    assert_equal(1, peer.updates.size)
    u = peer.updates.first
    assert_equal(['10.1.0.0/24'], u.nlri.to_ary)
    assert_equal(100, u.path_attribute[:multi_exit_disc].to_i)
    assert_equal('65001:7', u.path_attribute[:communities].communities)
    # eBGP, so our own AS goes in front and NEXT_HOP is ours: the
    # attributes are Speaker#path_attribute's, which is the whole reason
    # the body keys are the node file's keys.
    assert_equal('65001', u.path_attribute[:as_path].as_path)
    assert_equal('10.0.0.1', u.path_attribute[:next_hop].next_hop)
  end

  # The one way to send an AS_PATH whose leftmost AS is not ours on an
  # external session, which RFC 4271 section 6.3 makes a receive check.
  def test_as_path_literal_sends_the_path_as_written
    inj = injector
    inj.act('announce', 'prefixes' => ['10.1.0.0/24'], 'as_path' => [65_020, 65_030],
                        'as_path_literal' => true)
    assert_equal('65020 65030', peer.updates.last.path_attribute[:as_path].as_path)
    # With nothing in as_path the AS_PATH goes out empty, which is not
    # what an external peer expects either.
    inj.act('announce', 'prefixes' => ['10.2.0.0/24'], 'as_path_literal' => true)
    assert_equal('empty', peer.updates.last.path_attribute[:as_path].as_path)
  end

  def test_as_path_literal_false_is_the_default
    inj = injector
    inj.act('announce', 'prefixes' => ['10.1.0.0/24'], 'as_path' => [65_020], 'as_path_literal' => false)
    assert_equal('65001 65020', peer.updates.last.path_attribute[:as_path].as_path)
  end

  def test_as_path_literal_that_is_not_a_boolean_is_refused
    %w[true yes].push(1).each do |v|
      e = assert_raise(BGP::Sim::Injector::Refused) {
        injector.act('announce', 'prefixes' => ['10.1.0.0/24'], 'as_path_literal' => v)
      }
      assert_match(/as_path_literal must be true or false/, e.message)
    end
    assert_equal(0, peer.updates.size, 'nothing went out')
  end

  # attribute re-announces with the named keys changed, so it can turn
  # the literal path on for a prefix already announced.
  def test_attribute_can_turn_as_path_literal_on
    inj = injector
    inj.act('announce', 'prefixes' => ['10.1.0.0/24'], 'as_path' => [65_020])
    assert_equal('65001 65020', peer.updates.last.path_attribute[:as_path].as_path)
    inj.act('attribute', 'prefixes' => ['10.1.0.0/24'], 'as_path_literal' => true)
    assert_equal('65020', peer.updates.last.path_attribute[:as_path].as_path)
  end

  def test_an_announce_with_no_prefixes_and_no_generate_is_refused
    e = assert_raise(BGP::Sim::Injector::Refused) { injector.act('announce', 'med' => 1) }
    assert_match(/exactly one of prefixes, generate/, e.message)
  end

  def test_an_announce_with_both_selectors_is_refused
    assert_raise(BGP::Sim::Injector::Refused) do
      injector.act('announce', 'prefixes' => ['10.1.0.0/24'],
                               'generate' => { 'start' => '11.0.0.0/28', 'count' => 1 })
    end
  end

  def test_an_unknown_body_key_is_refused_and_names_the_keys_it_reads
    e = assert_raise(BGP::Sim::Injector::Refused) do
      injector.act('announce', 'prefixes' => ['10.1.0.0/24'], 'nexthop' => '10.0.0.9')
    end
    assert_match(/nexthop/, e.message)
    assert_match(/next_hop/, e.message)
  end

  # **A 200 that sent nothing is the wrong answer a scenario cannot
  # see**, and the commonest thing to meet is a session still coming up.
  def test_an_action_with_no_session_is_refused_and_says_what_state_it_is_in
    inj = injector
    peer.established = false
    e = assert_raise(BGP::Daemon::NoSession) do
      inj.act('announce', 'prefixes' => ['10.1.0.0/24'])
    end
    assert_match(/no established session/, e.message)
    assert_match(/10\.0\.10\.2 idle/, e.message)
  end

  def test_a_peer_key_sends_to_that_session_only
    two = [FakePeer.new('10.0.10.2', 65_000, 65_001),
           FakePeer.new('10.0.11.2', 65_000, 65_001)]
    inj = injector({}, two)
    inj.act('announce', 'prefixes' => ['10.1.0.0/24'], 'peer' => '10.0.11.2')
    assert_equal(0, two[0].sent.size)
    assert_equal(1, two[1].sent.size)
  end

  def test_an_address_that_is_not_a_configured_peer_is_refused
    e = assert_raise(BGP::Sim::Injector::Refused) do
      injector.act('announce', 'prefixes' => ['10.1.0.0/24'], 'peer' => '10.9.9.9')
    end
    assert_match(/not a configured peer/, e.message)
    assert_match(/10\.0\.10\.2/, e.message)
  end

  # ---- withdraw ------------------------------------------------------

  def test_a_withdraw_sends_the_withdrawn_routes_field
    inj = injector
    inj.act('announce', 'prefixes' => ['10.1.0.0/24'])
    r = inj.act('withdraw', 'prefixes' => ['10.1.0.0/24'])
    assert_equal(1, r[:updates])
    u = peer.updates.last
    assert_equal(['10.1.0.0/24'], u.withdrawn.to_ary)
    assert_nil(u.nlri)
    assert_equal([], inj.announced, 'a withdrawn prefix is forgotten')
  end

  # A withdrawal of something this injector never announced is ordinary
  # BGP and a test somebody will want, so nothing refuses it.
  def test_a_withdrawal_of_something_never_announced_still_goes
    injector.act('withdraw', 'prefixes' => ['10.99.0.0/24'])
    assert_equal(['10.99.0.0/24'], peer.updates.first.withdrawn.to_ary)
  end

  def test_a_withdrawal_carries_a_path_identifier_when_asked
    injector.act('withdraw', 'prefixes' => ['10.1.0.0/24'], 'path_id' => 7)
    assert_match(/ID=7/, peer.updates.first.withdrawn.to_ary.first)
  end

  def test_a_path_id_that_is_not_an_integer_is_refused
    assert_raise(BGP::Sim::Injector::Refused) do
      injector.act('withdraw', 'prefixes' => ['10.1.0.0/24'], 'path_id' => 'seven')
    end
  end

  # ---- attribute -----------------------------------------------------

  # It re-announces, which is what BGP does: the prefix keeps what it was
  # announced with and only the named key changes.
  def test_an_attribute_change_keeps_the_rest_of_the_announcement
    inj = injector
    inj.act('announce', 'prefixes' => ['10.1.0.0/24'], 'med' => 100,
                        'communities' => ['65001:7'])
    inj.act('attribute', 'prefixes' => ['10.1.0.0/24'], 'med' => 7)
    u = peer.updates.last
    assert_equal(7, u.path_attribute[:multi_exit_disc].to_i)
    assert_equal('65001:7', u.path_attribute[:communities].communities,
                 'the communities it was announced with are still there')
    assert_equal(7, inj.announced.first[:med], 'and the record moved with it')
  end

  def test_an_attribute_change_to_a_prefix_never_announced_is_refused
    e = assert_raise(BGP::Sim::Injector::Refused) do
      injector.act('attribute', 'prefixes' => ['10.77.0.0/24'], 'med' => 1)
    end
    assert_match(/10\.77\.0\.0\/24/, e.message)
    assert_match(/Announce it first/, e.message)
  end

  def test_an_attribute_change_with_nothing_to_change_is_refused
    inj = injector
    inj.act('announce', 'prefixes' => ['10.1.0.0/24'])
    assert_raise(BGP::Sim::Injector::Refused) do
      inj.act('attribute', 'prefixes' => ['10.1.0.0/24'])
    end
  end

  # Prefixes announced by two different blocks keep their own
  # attributes, so one UPDATE per block and not one for the lot.
  def test_prefixes_from_two_announcements_are_changed_in_two_updates
    inj = injector
    inj.act('announce', 'prefixes' => ['10.1.0.0/24'], 'med' => 1)
    inj.act('announce', 'prefixes' => ['10.2.0.0/24'], 'med' => 2)
    peer.sent.clear
    r = inj.act('attribute', 'prefixes' => ['10.1.0.0/24', '10.2.0.0/24'],
                             'local_pref' => 200)
    assert_equal(2, r[:updates])
    assert_equal([1, 2], peer.updates.collect { |u| u.path_attribute[:multi_exit_disc].to_i }.sort)
  end

  # ---- fault ---------------------------------------------------------

  # The octets are Fault.update's, which lab/fault_matrix.rb sends too,
  # so one catalog name is one set of octets for both programs.
  def test_a_fault_sends_the_catalogs_own_octets
    inj = injector
    inj.act('fault', 'case' => 'origin_length', 'prefixes' => ['203.0.113.0/24'],
                     'next_hop' => '10.0.0.1')
    want = BGP::Fault.update(:origin_length, :my_as => 65_001, :next_hop => '10.0.0.1',
                                             :prefixes => ['203.0.113.0/24']).to_shex
    assert_equal(want, peer.updates.first.to_shex)
  end

  def test_every_catalog_case_can_be_injected
    BGP::Fault.names.each do |name|
      inj = injector
      inj.act('fault', 'case' => name.to_s, 'prefixes' => ['203.0.113.0/24'])
      assert_equal(1, peer.updates.size, "#{name} sent nothing")
    end
  end

  def test_an_unknown_fault_case_is_refused_and_names_the_catalog
    e = assert_raise(BGP::Sim::Injector::Refused) do
      injector.act('fault', 'case' => 'no_such_fault')
    end
    assert_match(/no_such_fault/, e.message)
    assert_match(/origin_length/, e.message, 'the refusal names the catalog')
  end

  def test_a_fault_with_no_case_is_refused
    assert_raise(BGP::Sim::Injector::Refused) { injector.act('fault', {}) }
  end

  # An internal peer gets an empty AS_PATH and an external one gets our
  # AS, which is what this injector's own announce does: a fault case
  # that differed there would be testing AS_PATH rather than the case.
  def test_a_fault_toward_an_internal_peer_carries_an_empty_as_path
    ibgp = [FakePeer.new('10.0.10.2', 65_001, 65_001)]
    inj = injector({}, ibgp)
    inj.act('fault', 'case' => 'med_length', 'prefixes' => ['203.0.113.0/24'])
    assert_equal('empty', ibgp.first.updates.first.path_attribute[:as_path].as_path)
  end

  # ---- replay --------------------------------------------------------

  def test_a_replay_puts_the_octets_on_the_wire_unchanged
    hex = 'ffffffffffffffffffffffffffffffff001d020000000400010203'
    r = injector.act('replay', 'hex' => hex)
    assert_equal(11, r[:octets] - 16) # the marker plus five
    assert_equal([hex], peer.hex)
    assert_equal(String, peer.sent.first.class,
                 'a String, so nothing in the library re-encodes it')
  end

  def test_a_replay_takes_whitespace_out_so_a_pasted_dump_works
    injector.act('replay', 'hex' => "ffffffff ffffffff\nffffffff ffffffff 001704")
    assert_equal(['ffffffffffffffffffffffffffffffff001704'], peer.hex)
  end

  # The one refusal: an odd number of hex digits is not octets at all,
  # which is the kind Conventions allows. Nothing about the Marker, the
  # Length or the Type is looked at.
  def test_hex_that_is_not_octets_is_refused
    ['abc', 'nothex', ''].each do |bad|
      assert_raise(BGP::Sim::Injector::Refused) { injector.act('replay', 'hex' => bad) }
    end
  end

  def test_a_replayed_message_with_a_wrong_length_and_a_wrong_marker_still_goes
    # No Marker, a Length of 2 and a Type of 99: nothing an RFC allows.
    injector.act('replay', 'hex' => '00000000000000000000000000000000000263')
    assert_equal(['00000000000000000000000000000000000263'], peer.hex)
  end

  # ---- notification --------------------------------------------------

  def test_a_notification_carries_any_code_subcode_and_data
    r = injector.act('notification', 'code' => 199, 'subcode' => 254, 'data' => 'deadbeef')
    assert_equal(199, r[:code])
    assert_equal('deadbeef', r[:data])
    n = peer.sent.first
    assert_equal(BGP::Notification, n.class)
    assert_equal({ :code => 199, :subcode => 254, :data => ['deadbeef'].pack('H*') },
                 n.to_hash)
  end

  def test_a_notification_needs_a_code
    assert_raise(BGP::Sim::Injector::Refused) { injector.act('notification', 'subcode' => 1) }
  end

  def test_a_code_that_is_not_one_octet_is_refused
    e = assert_raise(BGP::Sim::Injector::Refused) do
      injector.act('notification', 'code' => 300)
    end
    assert_match(/one octet/, e.message)
  end

  # ---- sessions ------------------------------------------------------

  def test_session_stop_and_start_move_the_administrative_flag
    inj = injector
    inj.act('session.stop', {})
    assert_equal(true, peer.shutdown?)
    inj.act('session.start', {})
    assert_equal(false, peer.shutdown?)
  end

  # A session action reaches every **configured** peer, not every
  # established one: a session that is down is what session.start is for.
  def test_a_session_action_reaches_a_peer_that_is_down
    inj = injector
    peer.established = false
    assert_equal(['10.0.10.2'], inj.act('session.stop', {})[:peers])
  end

  def test_session_start_says_which_peers_it_cannot_dial
    inj = injector
    assert_equal(['10.0.10.2'], inj.act('session.start', {})[:passive],
                 'a passive peer comes back on the peer timer, not ours')
  end

  # It answers before it has finished, which is what keeps a POST out of
  # a driver's HTTP timeout.
  def test_a_flap_answers_at_once_and_runs_behind
    inj = injector
    r = inj.act('session.flap', 'count' => 2, 'interval' => 0.01)
    assert_equal(2, r[:count])
    assert_equal(true, r[:running])
    deadline = Time.now + 5
    sleep 0.01 until peer.shutdown? || Time.now > deadline
    assert_equal(true, peer.shutdown?, 'the flap really took it down')
    sleep 0.01 until !peer.shutdown? || Time.now > deadline
    assert_equal(false, peer.shutdown?, 'and let it back up')
    inj.stop
  end

  def test_a_flap_count_below_one_is_refused
    assert_raise(BGP::Sim::Injector::Refused) do
      injector.act('session.flap', 'count' => 0)
    end
  end

  def test_an_interval_that_is_not_a_number_is_refused
    assert_raise(BGP::Sim::Injector::Refused) do
      injector.act('session.flap', 'interval' => 'soon')
    end
  end

  # ---- refresh -------------------------------------------------------

  def test_a_route_refresh_carries_the_family_and_the_subtype
    r = injector.act('refresh', 'afi' => 1, 'safi' => 1, 'subtype' => 1)
    assert_equal(1, r[:subtype])
    msg = peer.sent.first
    assert_equal(BGP::Route_refresh, msg.class)
    assert_equal(1, msg.subtype)
  end

  def test_a_route_refresh_defaults_to_ipv4_unicast
    injector.act('refresh', {})
    assert_equal('ffffffffffffffffffffffffffffffff00170500010001', peer.hex.first)
  end

  def test_an_afi_that_is_not_an_integer_is_refused
    e = assert_raise(BGP::Sim::Injector::Refused) { injector.act('refresh', 'afi' => 'ipv4') }
    assert_match(/afi must be an integer/, e.message)
  end

  # ---- generate ------------------------------------------------------

  def test_a_generated_range_streams_one_update_at_a_time
    inj = injector
    inj.act('announce',
            { 'generate' => { 'start' => '11.0.0.0/28', 'count' => 10,
                              'per_update' => 4 }, 'med' => 100 },
            false)
    assert_equal(3, peer.updates.size, '10 prefixes, 4 per UPDATE, is 3 messages')
    assert_equal(%w[11.0.0.0/28 11.0.0.16/28 11.0.0.32/28 11.0.0.48/28],
                 peer.updates.first.nlri.to_ary)
    assert_equal(10, inj.sent.summary[:prefixes_sent])
    assert_equal(3, inj.sent.summary[:updates_sent])
  end

  # **A feed is counted and not listed**, which is what makes a million
  # prefixes possible: there is no Adj-RIB-Out here.
  def test_a_generated_range_is_a_feed_record_and_not_rows
    inj = injector
    inj.act('announce',
            { 'generate' => { 'start' => '11.0.0.0/28', 'count' => 10, 'per_update' => 4 } },
            false)
    assert_equal([], inj.announced, 'a generated range is not announced rows')
    feed = inj.sent.feeds.first
    assert_equal('11.0.0.0/28 x 10', feed[:range])
    assert_equal(10, feed[:prefixes_sent])
    assert_equal(false, feed[:running])
  end

  # The prefixes are regenerated rather than read back from a list,
  # which is the other half of having no Adj-RIB-Out.
  def test_a_generated_range_is_withdrawn_by_regenerating_it
    inj = injector
    inj.act('withdraw',
            { 'generate' => { 'start' => '11.0.0.0/28', 'count' => 10, 'per_update' => 4 } },
            false)
    assert_equal(3, peer.updates.size)
    assert_equal(%w[11.0.0.0/28 11.0.0.16/28 11.0.0.32/28 11.0.0.48/28],
                 peer.updates.first.withdrawn.to_ary)
    assert_nil(peer.updates.first.nlri)
    assert_equal(10, inj.sent.summary[:prefixes_withdrawn])
    # **And nothing is listed afterwards.** Be exact about what this
    # proves, because sabotage showed it is less than it looks: making
    # `stream_withdraw` record every prefix it sends passes this file,
    # since `withdraw` forgets the whole range immediately afterwards
    # and the end state is the same. What the no-rows rule protects on
    # this path is the memory a feed holds **while** it runs, which no
    # assertion from outside can see. The announce path's version of
    # this assertion does catch its own sabotage.
    assert_equal([], inj.announced)
  end

  def test_a_generated_range_that_the_generator_refuses_is_a_refusal
    e = assert_raise(BGP::Sim::Injector::Refused) do
      injector.act('announce', 'generate' => { 'count' => 10 })
    end
    assert_match(/generate/, e.message)
  end

  # A path_id on a generate block goes in front of every prefix of the
  # range (RFC 7911 section 3). This used to be refused, because
  # Speaker#each_update dropped it; phase 0 of docs/route-generation.md
  # carries it through, so the refusal is gone and this is what replaced
  # it. Every prefix is checked, not the first, since a range that lost
  # the identifier after its first UPDATE would pass a first-only check.
  def test_a_path_id_on_a_generated_announce_reaches_every_prefix
    inj = injector
    inj.act('announce',
            { 'generate' => { 'start' => '11.0.0.0/28', 'count' => 5, 'per_update' => 2 },
              'path_id' => 7 },
            false)
    assert_equal(3, peer.updates.size)
    nlris = peer.updates.flat_map { |u| u.nlri.nlris }
    assert_equal(5, nlris.size)
    assert_equal([7] * 5, nlris.collect(&:path_id))
  end

  # The withdrawal of the same range names the same Path Identifier, so
  # an add-path test can take back one path of a generated range and
  # leave another. That half already worked; it is asserted beside the
  # announce half so the pair is read together.
  def test_a_path_id_on_a_generated_withdrawal_reaches_every_prefix
    inj = injector
    inj.act('withdraw',
            { 'generate' => { 'start' => '11.0.0.0/28', 'count' => 5, 'per_update' => 2 },
              'path_id' => 7 },
            false)
    assert_equal([7] * 5, peer.updates.flat_map { |u| u.withdrawn.nlris }.collect(&:path_id))
  end

  # Refused before the feed starts, so a bad value is a 400 and not a
  # feed that failed on a thread nobody is watching.
  def test_a_path_id_that_is_not_four_octets_is_refused_before_the_feed
    inj = injector
    ['seven', -1, 2**32].each do |bad|
      e = assert_raise(BGP::Sim::Injector::Refused, bad.inspect) do
        inj.act('announce', 'generate' => { 'start' => '11.0.0.0/28', 'count' => 2 },
                            'path_id' => bad)
      end
      assert_match(/path_id/, e.message)
    end
    assert_equal([], peer.updates, 'nothing went out')
    assert_equal([], inj.sent.feeds, 'no feed was started')
  end

  # Our arithmetic, checked once, which is the half of the packing
  # requirement that is not arithmetic. It is not a check on what a
  # caller asked for: see the test below it.
  def test_a_packing_slip_of_ours_raises_rather_than_reaching_the_wire
    assert_raise(BGP::Sim::Injector::Refused) do
      BGP::Sim::Injector.check_size(BGP::Update.new(BGP::Withdrawn.new(
        *Array.new(1500) { |i| "#{BGP::Sim::Injector}" && "11.#{i / 256}.#{i % 256}.0/24" })),
                                    nil, 1500)
    end
  end

  # ---- nothing validates ---------------------------------------------

  # **Conventions' first rule, which is this program's product.** Each of
  # these is something no RFC allows and each one goes out.
  def test_nothing_validates
    inj = injector
    # A Path Identifier on a session that negotiated no ADD-PATH: four
    # unexpected octets in front of every prefix.
    inj.act('announce', 'prefixes' => ['10.1.0.0/24'], 'path_id' => 7)
    assert_match(/ID=7/, peer.updates.last.nlri.to_ary.first)
    # An ORIGIN value RFC 4271 section 5.1.1 does not define.
    inj.act('announce', 'prefixes' => ['10.2.0.0/24'], 'origin' => 3)
    assert_equal(3, peer.updates.last.path_attribute[:origin].to_i)
    # A NOTIFICATION with a code and a subcode RFC 4271 section 4.5 does
    # not define.
    inj.act('notification', 'code' => 199, 'subcode' => 254)
    assert_equal(199, peer.sent.last.to_hash[:code])
    # A ROUTE-REFRESH Message Subtype RFC 7313 section 3.2 reserves.
    inj.act('refresh', 'subtype' => 255)
    assert_equal(255, peer.sent.last.subtype)
    # An AS_PATH with our own AS in it twice, which a receiver must
    # treat as a loop.
    inj.act('announce', 'prefixes' => ['10.3.0.0/24'], 'as_path' => [65_001, 65_001])
    assert_equal('65001 65001 65001', peer.updates.last.path_attribute[:as_path].as_path)
    # And a well-known attribute type RFC 4271 section 4.3 does not
    # define, which is what the catalog is for.
    inj.act('fault', 'case' => 'unknown_wellknown', 'prefixes' => ['10.4.0.0/24'])
    assert_equal(4, peer.updates.size, 'four UPDATEs no RFC allows')
    assert_equal(6, peer.sent.size, 'and two other messages beside them')
  end

  # ---- what it says about itself --------------------------------------

  # routescope's bgp_routes row is
  # `prefix next_hop as_path origin med local_pref from paths best`, and
  # `best` is nil rather than false because an injector runs no decision
  # process: false would claim a comparison it never made.
  def test_an_announced_row_is_routescopes_shape_with_a_nil_best
    inj = injector
    inj.act('announce', 'prefixes' => ['10.1.0.0/24'], 'med' => 100, 'as_path' => [90, 80])
    row = inj.announced.first
    %i[prefix next_hop as_path origin med local_pref from paths best].each do |k|
      assert(row.key?(k), "#{k} is missing from an announced row")
    end
    assert_equal('10.1.0.0/24', row[:prefix])
    assert_equal('90 80', row[:as_path])
    assert_equal('igp', row[:origin])
    assert_equal(100, row[:med])
    assert_nil(row[:best])
  end

  def test_the_topology_says_what_it_can_be_told_to_do
    t = injector.topology
    assert_equal('10.0.0.1', t[:router_id])
    assert_equal(65_001, t[:as])
    assert_equal(BGP::Sim::Injector::ACTIONS, t[:actions])
    assert_equal(BGP::Fault.names.collect(&:to_s), t[:faults])
    assert_equal('10.0.10.2', t[:neighbors].first[:address])
    assert_equal(:ebgp, t[:neighbors].first[:type])
  end

  def test_an_unknown_action_is_refused_and_names_the_ten
    e = assert_raise(BGP::Sim::Injector::Refused) { injector.act('link.down', {}) }
    assert_match(/unknown action/, e.message)
    BGP::Sim::Injector::ACTIONS.each_key { |a| assert_match(/#{Regexp.escape(a)}/, e.message) }
  end

  def test_a_body_that_is_not_an_object_is_refused
    assert_raise(BGP::Sim::Injector::Refused) { injector.act('announce', []) }
  end

  # The ten actions of docs/daemon.md's table, and no more.
  def test_the_action_table_is_the_documented_ten
    assert_equal(%w[announce withdraw attribute fault replay notification
                    session.stop session.start session.flap refresh],
                 BGP::Sim::Injector::ACTIONS.keys)
  end

  # ---- events ---------------------------------------------------------

  # The two kinds this program declares, through register_kind rather
  # than by editing the list in bgp/events.rb.
  def test_it_declares_its_own_event_kinds
    assert_include(BGP::Events::KINDS, :route)
    assert_include(BGP::Events::KINDS, :fault)
  end

  def test_an_action_publishes_an_event_a_program_can_switch_on
    inj = injector
    inj.act('announce', 'prefixes' => ['10.1.0.0/24'])
    inj.act('fault', 'case' => 'med_length', 'prefixes' => ['10.2.0.0/24'])
    kinds = inj.speaker.events.since(0).collect(&:kind)
    assert_include(kinds, :route)
    assert_include(kinds, :fault)
    fault = inj.speaker.events.since(0).find { |e| e.kind == :fault }
    assert_equal('med_length', fault.data['case'],
                 'the catalog name is data and not something to parse out of a message')
  end

  # ---- re-announcing -------------------------------------------------

  # **What a config announce block gets for free and an action does
  # not.** Without this a session.flap would lose everything a scenario
  # had announced, and the scenario would read as a convergence failure.
  def test_what_was_announced_goes_again_when_a_session_comes_back
    inj = injector
    inj.act('announce', 'prefixes' => ['10.1.0.0/24'], 'med' => 100)
    peer.sent.clear
    inj.speaker.session_established(peer)
    assert_equal(1, peer.updates.size)
    assert_equal(['10.1.0.0/24'], peer.updates.first.nlri.to_ary)
    assert_equal(100, peer.updates.first.path_attribute[:multi_exit_disc].to_i)
  end

  def test_an_announcement_aimed_at_one_peer_stays_aimed_at_it
    two = [FakePeer.new('10.0.10.2', 65_000, 65_001),
           FakePeer.new('10.0.11.2', 65_000, 65_001)]
    inj = injector({}, two)
    inj.act('announce', 'prefixes' => ['10.1.0.0/24'], 'peer' => '10.0.11.2')
    two.each { |p| p.sent.clear }
    inj.speaker.session_established(two[0])
    assert_equal(0, two[0].sent.size, 'it was never for this peer')
    inj.speaker.session_established(two[1])
    assert_equal(1, two[1].sent.size)
  end

  def test_a_withdrawn_prefix_does_not_come_back
    inj = injector
    inj.act('announce', 'prefixes' => ['10.1.0.0/24'])
    inj.act('withdraw', 'prefixes' => ['10.1.0.0/24'])
    peer.sent.clear
    inj.speaker.session_established(peer)
    assert_equal(0, peer.sent.size)
  end

  # A listener must not be able to kill the session it is listening to,
  # which is Neighbor#on_state_change's rule: the session thread runs
  # this, so a raise there would take the session with it.
  def test_a_resend_that_cannot_send_does_not_raise_into_the_session
    inj = injector
    inj.act('announce', 'prefixes' => ['10.1.0.0/24'])
    peer.established = false
    assert_nothing_raised { inj.speaker.session_established(peer) }
  end


  # ---- a BGP::Gen spec ------------------------------------------------

  SPEC = { 'start' => '11.0.0.0/24', 'count' => 10, 'per_update' => 4,
           'attributes' => { 'as_path' => [65_020], 'med' => { 'cycle' => [10, 20] } } }.freeze

  def sender(peer, literal = false)
    { 'as' => 65_001, 'ebgp' => peer.ebgp?, 'next_hop' => peer.local_ip,
      'as_path_literal' => literal }
  end

  # The octets are the library's own with this session's sender, which
  # is the claim: the injector adds the session and nothing else.
  def test_a_spec_sends_what_the_library_generates_for_this_session
    inj = injector
    inj.act('announce', { 'spec' => SPEC }, false)
    want = BGP::Gen.new(SPEC, sender(peer)).updates.collect(&:to_shex)
    assert_equal(want, peer.updates.collect(&:to_shex))
    assert_equal('65001 65020', peer.updates.first.path_attribute[:as_path].as_path)
    assert_equal(10, inj.sent.summary[:prefixes_sent])
  end

  def test_a_spec_takes_as_path_literal
    inj = injector
    inj.act('announce', { 'spec' => SPEC, 'as_path_literal' => true }, false)
    assert_equal('65020', peer.updates.first.path_attribute[:as_path].as_path)
  end

  # A feed, counted and not listed, as a generated range is.
  def test_a_spec_is_a_feed_record_and_not_rows
    inj = injector
    r = inj.act('announce', { 'spec' => SPEC }, false)
    feed = r[:feeds].first
    assert_equal('unicast 11.0.0.0/24 x 10', feed[:range])
    assert_equal(10, feed[:prefixes_sent])
    assert_equal([], inj.announced)
  end

  def test_a_spec_is_withdrawn_by_regenerating_it
    inj = injector
    inj.act('withdraw', { 'spec' => SPEC }, false)
    assert_equal(BGP::Gen.new(SPEC).withdrawals.collect(&:to_shex), peer.updates.collect(&:to_shex))
    assert_equal(10, inj.sent.summary[:prefixes_withdrawn])
  end

  # A prefix `prefixes` announced, then withdrawn by a spec whose range
  # covers it, is no longer listed and is not resent after a flap.
  def test_a_spec_withdrawal_forgets_what_prefixes_announced
    inj = injector
    inj.act('announce', 'prefixes' => ['11.0.1.0/24'])
    inj.act('withdraw', { 'spec' => SPEC }, false)
    assert_equal([], inj.announced)
  end

  # `prefixes` announces unicast, so a spec in another family withdraws
  # another route and the unicast one stays listed and resent.
  def test_a_spec_withdrawal_in_another_family_keeps_what_prefixes_announced
    inj = injector
    inj.act('announce', 'prefixes' => ['11.0.1.0/24'])
    [SPEC.merge('family' => 'multicast'),
     SPEC.merge('family' => 'labelled', 'label' => 100),
     SPEC.merge('family' => 'vpn', 'label' => 100, 'rd' => '65000:1')].each do |s|
      inj.act('withdraw', { 'spec' => s }, false)
      assert_equal(['11.0.1.0/24'], inj.announced.collect { |r| r[:prefix] }, s['family'])
    end
  end

  # Read before anything starts, so a 400 now and not a failed feed.
  def test_a_spec_the_library_refuses_is_a_refusal_before_the_feed
    inj = injector
    [{ 'family' => 'ipv4', 'start' => '11.0.0.0/24', 'count' => 1 },
     { 'start' => '11.0.0.0/24', 'count' => 1, 'colour' => 1 },
     { 'start' => 'nowhere', 'count' => 1 }].each do |bad|
      e = assert_raise(BGP::Sim::Injector::Refused, bad.inspect) { inj.act('announce', 'spec' => bad) }
      assert_match(/\Aspec: /, e.message)
    end
    assert_equal([], peer.updates)
    assert_equal([], inj.sent.feeds)
  end

  # A spec carries its own attributes, so an announce key beside it
  # would change nothing in silence.
  def test_an_announce_key_beside_a_spec_is_refused
    e = assert_raise(BGP::Sim::Injector::Refused) do
      injector.act('announce', 'spec' => SPEC, 'med' => 5)
    end
    assert_match(/med do\(es\) not go with spec/, e.message)
    assert_raise(BGP::Sim::Injector::Refused) do
      injector.act('withdraw', 'spec' => SPEC, 'path_id' => 1)
    end
  end

  def test_a_spec_beside_another_selector_is_refused
    assert_raise(BGP::Sim::Injector::Refused) do
      injector.act('announce', 'spec' => SPEC, 'prefixes' => ['10.1.0.0/24'])
    end
  end

  # A set that grows too large halfway is a failed feed with its reason,
  # since it cannot be known at the start: see bgp/gen/unicast.rb.
  # ---- specs named in the node file -----------------------------------

  def test_a_named_spec_sends_what_the_spec_itself_sends
    inj = injector('specs' => { 'ten' => SPEC })
    inj.act('announce', { 'spec' => 'ten' }, false)
    want = BGP::Gen.new(SPEC, sender(peer)).updates.collect(&:to_shex)
    assert_equal(want, peer.updates.collect(&:to_shex))
  end

  def test_a_named_spec_withdraws_and_plans_and_churns
    inj = injector('specs' => { 'ten' => SPEC })
    assert_equal(10, inj.plan('spec' => 'ten')[:plans].first[:total])
    inj.act('withdraw', { 'spec' => 'ten' }, false)
    assert_equal(BGP::Gen.new(SPEC).withdrawals.collect(&:to_shex), peer.updates.collect(&:to_shex))
    churn = { 'events' => 4, 'routes' => 4, 'withdraw' => 1.0, 'seed' => 1 }
    by_name = inj.plan('spec' => 'ten', 'churn' => churn)[:plans].first
    by_value = inj.plan('spec' => SPEC, 'churn' => churn)[:plans].first
    assert_equal(by_value[:churn], by_name[:churn])
    assert_operator(by_name[:total], :<, 10, 'the churn withdrew something')
  end

  # Naming traffic sends none of it: the node still starts silent.
  def test_a_specs_block_sends_nothing_at_start
    inj = injector('specs' => { 'ten' => SPEC })
    assert_equal([], peer.updates)
    assert_equal(0, inj.sent.summary[:prefixes_sent])
    assert_equal(['ten'], inj.topology[:specs])
  end

  def test_an_unknown_spec_name_is_refused_with_the_names_there_are
    inj = injector('specs' => { 'ten' => SPEC })
    %w[announce withdraw].each do |action|
      e = assert_raise(BGP::Sim::Injector::Refused) { inj.act(action, 'spec' => 'eleven') }
      assert_match(/eleven/, e.message)
      assert_match(/names ten/, e.message)
    end
    e = assert_raise(BGP::Sim::Injector::Refused) { inj.plan('spec' => 'eleven') }
    assert_match(/names ten/, e.message)
    e = assert_raise(BGP::Sim::Injector::Refused) { injector.act('announce', 'spec' => 'ten') }
    assert_match(/names none/, e.message)
    assert_equal([], peer.updates)
  end

  # A spec the library cannot read stops the node at start-up, naming
  # the spec, rather than failing the first scenario that sends it.
  def test_a_specs_block_is_read_at_start_up
    [[[], /mapping of name/],
     [{ 'ten' => 5 }, /ten is not a mapping/],
     [{ 'a b' => SPEC }, /not a name/],
     [{ 'bad' => SPEC.merge('family' => 'nosuch') }, /bad: unknown family/]].each do |specs, why|
      e = assert_raise(BGP::Sim::Injector::Refused, specs.inspect) do
        BGP::Sim::Injector.new(CONFIG.merge('specs' => specs))
      end
      assert_match(why, e.message)
    end
  end

  def test_a_spec_that_stops_halfway_is_a_failed_feed
    spec = { 'start' => '11.0.0.0/24', 'count' => 3, 'per_update' => 1,
             'attributes' => { 'communities' => { 'count' => { 'base' => '1:1',
                                                  'n' => { 'cycle' => [1, 1100] } } } } }
    inj = injector
    inj.act('announce', { 'spec' => spec }, false)
    feed = inj.sent.feeds.first
    assert_match(/Unpackable/, feed[:error].to_s)
    assert_equal(1, peer.updates.size, 'the first set went out before the second was reached')
  end

  # ---- plan ------------------------------------------------------------

  # The rows are `expected` for this session, and nothing is sent.
  def test_a_plan_is_expected_for_each_peer_and_sends_nothing
    inj = injector
    r = inj.plan('spec' => SPEC)
    assert_equal([], peer.sent)
    plan = r[:plans].first
    assert_equal('10.0.10.2', plan[:peer])
    assert_equal(BGP::Gen.new(SPEC, sender(peer)).expected.to_a, plan[:rows])
    assert_equal([65_001, 65_020], plan[:rows].first['as_path'])
    assert_equal(10, plan[:total])
    assert_nil(plan[:next_offset])
  end

  # A VPN spec makes `count` routes once per VRF, so the plan's total
  # and its pages count all of them and not the range. It read
  # spec['count'] until phase 4b, which would have ended the paging a
  # VRF early.
  def test_a_vpn_plan_counts_every_vrf
    inj = injector
    spec = SPEC.merge('family' => 'vpn', 'rd' => '65000:1', 'vrfs' => 3, 'label' => 100)
    plan = inj.plan('spec' => spec, 'offset' => 25, 'limit' => 4)[:plans].first
    assert_equal(30, plan[:total])
    assert_equal(29, plan[:next_offset])
    assert_equal(%w[65000:3 65000:3 65000:3 65000:3], plan[:rows].collect { |r| r['rd'] })
    assert_equal([], peer.sent)
  end

  # Phase 4c. A flow spec rule over eBGP gets the prepend and no next
  # hop: RFC 8955 section 4 makes its length 0, so the session's address
  # is not filled in, and the plan says the same.
  def test_a_flow_spec_rule_goes_out_with_no_next_hop
    inj = injector
    spec = { 'family' => 'flow_spec', 'start' => '11.0.0.0/24', 'count' => 3, 'protocol' => 6, 'rate' => 0 }
    inj.act('announce', { 'spec' => spec }, false)
    mp = peer.updates.first.path_attribute[:mp_reach]
    assert_equal([1, 133, ''], [mp.afi, mp.safi, mp.nexthops])
    assert_equal('65001', peer.updates.first.path_attribute[:as_path].as_path)
    row = inj.plan('spec' => spec)[:plans].first[:rows].first
    assert_equal({ 'destination' => '11.0.0.0/24', 'protocol' => 6, 'origin' => 0, 'as_path' => [65_001],
                   'extended_communities' => ['traffic_rate_bytes:0:0.0'] }, row)
    inj.act('withdraw', { 'spec' => spec }, false)
    assert_equal(3, inj.sent.summary[:prefixes_withdrawn])
  end

  # Phase 4d. An EVPN route's next hop is the session's own address,
  # RFC 7432 section 14, which the Sender fills in as for unicast.
  def test_an_evpn_route_goes_out_with_the_sessions_next_hop
    inj = injector
    spec = { 'family' => 'evpn', 'route_type' => 3, 'start' => '10.9.0.1', 'count' => 2, 'rd' => '65001:7' }
    inj.act('announce', { 'spec' => spec }, false)
    mp = peer.updates.first.path_attribute[:mp_reach]
    assert_equal([25, 70, '10.0.0.1'], [mp.afi, mp.safi, mp.nexthops])
    row = inj.plan('spec' => spec)[:plans].first[:rows].last
    assert_equal({ 'route_type' => 3, 'rd' => '65001:7', 'originator' => '10.9.0.2', 'ethernet_tag' => 0,
                   'origin' => 0, 'as_path' => [65_001], 'next_hop' => '10.0.0.1' }, row)
    inj.act('withdraw', { 'spec' => spec }, false)
    assert_equal(2, inj.sent.summary[:prefixes_withdrawn])
  end

  # Phase 4d2. A Leaf A-D route goes out with its Route Key inside it,
  # and the plan names the group, the triggering originator and the
  # leaf's own address.
  def test_an_evpn_leaf_a_d_route_goes_out
    inj = injector
    spec = { 'family' => 'evpn', 'route_type' => 11, 'start' => '239.1.1.1', 'count' => 2, 'rd' => '65001:7',
             'originator' => '10.9.0.1', 'leaf' => '10.9.0.99' }
    inj.act('announce', { 'spec' => spec }, false)
    n = peer.updates.first.path_attribute[:mp_reach].nlris
    assert_equal([11, 11], n.collect { |x| x.type })
    assert_equal(10, n.first.route.route_key.type, 'the Route Key is an S-PMSI A-D route')
    assert_equal({ 'route_type' => 11, 'rd' => '65001:7', 'group' => '239.1.1.2', 'originator' => '10.9.0.1',
                   'leaf' => '10.9.0.99', 'origin' => 0, 'as_path' => [65_001], 'next_hop' => '10.0.0.1' },
                 inj.plan('spec' => spec)[:plans].first[:rows].last)
    inj.act('withdraw', { 'spec' => spec }, false)
    assert_equal(2, inj.sent.summary[:prefixes_withdrawn])
  end

  # Phase 4f. An MCAST-VPN route goes out in SAFI 5 with the session's
  # next hop, 4 octets under AFI 2 too (RFC 6515 section 1.1), and the
  # AFI is the group's family.
  def test_an_mcast_vpn_route_goes_out
    inj = injector
    spec = { 'family' => 'mcast_vpn', 'route_type' => 7, 'start' => 'ff3e::1', 'count' => 2, 'rd' => '65001:7',
             'source_as' => 65_001, 'source' => '2001:db8::9' }
    inj.act('announce', { 'spec' => spec }, false)
    mp = peer.updates.first.path_attribute[:mp_reach]
    assert_equal([2, 5, '10.0.0.1'], [mp.afi, mp.safi, mp.nexthops])
    assert_equal([7, 7], mp.nlris.collect(&:type))
    assert_equal({ 'route_type' => 7, 'rd' => '65001:7', 'source_as' => 65_001, 'source' => '2001:db8::9',
                   'group' => 'ff3e::2', 'origin' => 0, 'as_path' => [65_001], 'next_hop' => '10.0.0.1' },
                 inj.plan('spec' => spec)[:plans].first[:rows].last)
    inj.act('withdraw', { 'spec' => spec }, false)
    assert_equal(2, inj.sent.summary[:prefixes_withdrawn])
  end

  # Phase 4e. A membership route goes out in SAFI 132 with the session's
  # next hop, and the plan names its route target as ADMIN:N.
  def test_a_route_target_membership_route_goes_out
    inj = injector
    spec = { 'family' => 'rt_constrain', 'start' => '65001:7', 'count' => 2, 'origin_as' => 65_001,
             'default' => true }
    inj.act('announce', { 'spec' => spec }, false)
    mp = peer.updates.first.path_attribute[:mp_reach]
    assert_equal([1, 132, '10.0.0.1', 3], [mp.afi, mp.safi, mp.nexthops, mp.nlris.size])
    rows = inj.plan('spec' => spec)[:plans].first[:rows]
    assert_equal([true, nil, nil], rows.collect { |r| r['default'] })
    assert_equal({ 'origin_as' => 65_001, 'route_target' => '65001:8', 'prefix_length' => 96,
                   'origin' => 0, 'as_path' => [65_001], 'next_hop' => '10.0.0.1' }, rows.last)
    inj.act('withdraw', { 'spec' => spec }, false)
    assert_equal(3, inj.sent.summary[:prefixes_withdrawn])
  end

  # Phase 4g: a BGP-LS topology through the injector, the session's own
  # address as the section 5.5 next hop, and a plan row per NLRI.
  def test_a_link_state_topology_goes_out
    inj = injector
    spec = { 'family' => 'bgp_ls', 'start' => '10.0.0.1', 'count' => 3, 'igp_metric' => 10 }
    inj.act('announce', { 'spec' => spec }, false)
    nlris = peer.updates.flat_map { |u| u.path_attribute[:mp_reach].nlris }
    mp = peer.updates.first.path_attribute[:mp_reach]
    assert_equal([16388, 71, '10.0.0.1'], [mp.afi, mp.safi, mp.nexthops])
    assert_equal([1, 1, 1, 2, 2, 2, 2, 2, 2], nlris.collect(&:type))
    rows = inj.plan('spec' => spec)[:plans].first[:rows]
    assert_equal(%w[node node node link link link link link link], rows.collect { |r| r['nlri'] })
    assert_equal({ 'nlri' => 'link', 'node' => '10.0.0.1', 'remote' => '10.0.0.2', 'link' => 1,
                   'protocol_id' => 3, 'identifier' => 0, 'origin' => 0, 'as_path' => [65_001],
                   'next_hop' => '10.0.0.1', 'igp_metric' => 10 }, rows[3])
    inj.act('withdraw', { 'spec' => spec }, false)
    assert_equal(9, inj.sent.summary[:prefixes_withdrawn])
  end

  # One spec, two sessions, two answers: the prepend and LOCAL_PREF
  # differ between an external and an internal peer.
  def test_a_plan_answers_per_peer
    two = [FakePeer.new('10.0.10.2', 65_000, 65_001), FakePeer.new('10.0.11.2', 65_001, 65_001)]
    inj = injector({}, two)
    a, b = inj.plan('spec' => SPEC)[:plans].collect { |p| p[:rows].first }
    assert_equal([65_001, 65_020], a['as_path'])
    assert_equal([65_020], b['as_path'])
    assert_equal(100, b['local_pref'])
    # A LOCAL_PREF the spec asks for reaches the internal peer and not
    # the external one (RFC 4271 section 5.1.5).
    spec = SPEC.merge('attributes' => SPEC['attributes'].merge('local_pref' => 300))
    a, b = inj.plan('spec' => spec)[:plans].collect { |p| p[:rows].first }
    assert_nil(a['local_pref'])
    assert_equal(300, b['local_pref'])
  end

  # Paged with the daemon's envelope, so a million rows is never one
  # answer.
  def test_a_plan_is_paged
    inj = injector
    p1 = inj.plan('spec' => SPEC, 'limit' => 4)[:plans].first
    assert_equal(%w[11.0.0.0/24 11.0.1.0/24 11.0.2.0/24 11.0.3.0/24], p1[:rows].collect { |r| r['prefix'] })
    assert_equal(4, p1[:next_offset])
    last = inj.plan('spec' => SPEC, 'offset' => 8, 'limit' => 4)[:plans].first
    assert_equal(%w[11.0.8.0/24 11.0.9.0/24], last[:rows].collect { |r| r['prefix'] })
    assert_nil(last[:next_offset])
    big = inj.plan('spec' => SPEC, 'limit' => 10**9)[:plans].first
    assert_equal(BGP::Daemon::Views::MAX_LIMIT, big[:limit])
  end

  def test_a_plan_refuses_what_it_does_not_read
    inj = injector
    assert_raise(BGP::Sim::Injector::Refused) { inj.plan({}) }
    e = assert_raise(BGP::Sim::Injector::Refused) { inj.plan('spec' => SPEC, 'med' => 1) }
    assert_match(/med/, e.message)
    assert_raise(BGP::Sim::Injector::Refused) { inj.plan('spec' => SPEC, 'as_path_literal' => 'yes') }
    assert_raise(BGP::Sim::Injector::Refused) { inj.plan('spec' => { 'count' => 1 }) }
  end

  def test_a_plan_with_no_session_is_no_session
    inj = injector
    peer.established = false
    assert_raise(BGP::Daemon::NoSession) { inj.plan('spec' => SPEC) }
  end

  # ---- churn, phase 5 ---------------------------------------------------

  CHURN = { 'events' => 40, 'routes' => 4, 'withdraw' => 0.3, 'seed' => 5,
            'attributes' => { 'med' => { 'step' => { 'start' => 1, 'by' => 1 } } } }.freeze

  # A churn rides on announce beside a spec, and sends one UPDATE per
  # event, each a withdrawal or an announcement of one of the spec's
  # routes, with our AS in front over eBGP.
  def test_a_churn_sends_one_update_per_event
    inj = injector
    answer = inj.act('announce', { 'spec' => SPEC, 'churn' => CHURN }, false)
    assert_equal('announce', answer[:action])
    assert_equal(40, peer.updates.size)
    kinds = answer[:summary]['kinds']
    assert_equal(40, kinds.values.sum)
    withdrawals = peer.updates.count { |u| u.withdrawn && !u.withdrawn.to_ary.empty? }
    assert_equal(kinds['withdraw'], withdrawals)
    peer.updates.reject(&:withdrawn).each do |u|
      assert_equal(1, u.nlri.to_ary.size)
      assert_match(/\A11\.0\.[0-3]\.0\/24\z/, u.nlri.to_ary.first)
      assert_equal('65001 65020', u.path_attribute[:as_path].as_path)
    end
    feed = inj.sent.feeds.first
    assert_equal(['churn', 40, 40], [feed[:action], feed[:updates_sent], feed[:prefixes_sent]])
    s = inj.sent.summary
    assert_equal(kinds['withdraw'], s[:prefixes_withdrawn])
    assert_equal(40 - kinds['withdraw'], s[:prefixes_sent])
  end

  # The plan with the same churn answers what the peer holds afterwards,
  # which is the state the events leave and not the spec's.
  def test_a_plan_with_a_churn_answers_the_state_after_it
    inj = injector
    plan = inj.plan('spec' => SPEC, 'churn' => CHURN)[:plans].first
    inj.act('announce', { 'spec' => SPEC, 'churn' => CHURN }, false)
    held = inj.plan('spec' => SPEC)[:plans].first[:rows].to_h { |r| [r['prefix'], r['med']] }
    peer.updates.each do |u|
      u.withdrawn.to_ary.each { |p| held.delete(p) } if u.withdrawn
      u.nlri.to_ary.each { |p| held[p] = u.path_attribute[:multi_exit_disc].to_i } if u.nlri
    end
    assert_equal(held.size, plan[:total])
    assert_equal(held.keys.sort, plan[:rows].collect { |r| r['prefix'] }.sort)
    plan[:rows].each { |r| assert_equal(held[r['prefix']], r['med'], r['prefix']) }
    assert_equal(held.size, plan[:churn]['held'])
  end

  def test_a_churn_is_paced_at_its_rate
    inj = injector
    t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    inj.act('announce', { 'spec' => SPEC, 'churn' => { 'events' => 6, 'rate' => 20 } }, false)
    took = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t
    assert_equal(6, peer.updates.size)
    # Five gaps of 50 ms: at least the gaps, and not much past them.
    assert_operator(took, :>=, 0.25)
    assert_operator(took, :<, 2)
  end

  def test_a_churn_is_refused_where_it_cannot_go
    inj = injector
    e = assert_raise(BGP::Sim::Injector::Refused) { inj.act('announce', 'prefixes' => ['10.0.0.0/8'], 'churn' => CHURN) }
    assert_match(/churn goes with a spec/, e.message)
    e = assert_raise(BGP::Sim::Injector::Refused) { inj.act('announce', 'spec' => SPEC, 'churn' => { 'events' => 0 }) }
    assert_match(/churn: churn.events is at least 1/, e.message)
    e = assert_raise(BGP::Sim::Injector::Refused) { inj.act('announce', 'spec' => SPEC, 'churn' => CHURN, 'med' => 1) }
    assert_match(/med/, e.message)
    assert_raise(BGP::Sim::Injector::Refused) { inj.act('withdraw', 'spec' => SPEC, 'churn' => CHURN) }
    assert_raise(BGP::Sim::Injector::Refused) { inj.plan('spec' => SPEC, 'churn' => { 'bogus' => 1 }) }
    assert_equal([], peer.sent)
  end

  # ---- mp_reach, mp_unreach and specimen ------------------------------

  MP = { 'afi' => 2, 'safi' => 1, 'nexthop' => ['2001:db8::1'],
         'nlris' => ['2001:db8:1::/48', '2001:db8:2::/48'] }.freeze

  # One MP_REACH_NLRI in Fault.wrap's envelope: ORIGIN and our AS toward
  # an external peer, and no NEXT_HOP attribute (RFC 4760 section 3).
  def test_mp_reach_is_one_message_in_the_fault_envelope
    inj = injector
    r = inj.act('announce', 'mp_reach' => MP)
    u = peer.updates.last
    want = BGP::Fault.wrap(BGP::Mp_reach.new(:afi => 2, :safi => 1, :nexthop => ['2001:db8::1'],
                                             :nlris => ['2001:db8:1::/48', '2001:db8:2::/48']),
                           :my_as => 65_001)
    assert_equal(want.to_shex, u.to_shex)
    assert_equal(false, u.path_attribute.has?(BGP::Next_hop))
    assert_equal(2, r[:prefixes])
    assert_equal(2, inj.sent.summary[:prefixes_sent])
  end

  # Nested NLRI hashes read too, since JSON keys are strings at every
  # depth: an EVPN route is the one with the deepest nesting.
  def test_mp_reach_reads_nested_json_keys
    evpn = { 'afi' => 25, 'safi' => 70, 'nexthop' => ['10.0.0.1'],
             'nlris' => [{ 'inclusive_multicast' => { 'rd' => [100, 200], 'tag' => 0,
                                                      'originator' => '10.0.0.1' } }] }
    injector.act('announce', 'mp_reach' => evpn)
    assert_kind_of(BGP::Evpn, peer.updates.last.path_attribute[:mp_reach].nlris.first)
  end

  def test_mp_unreach_is_an_update_with_nothing_else
    inj = injector
    inj.act('withdraw', 'mp_unreach' => MP.reject { |k, _| k == 'nexthop' })
    u = peer.updates.last
    assert_equal([BGP::Mp_unreach], u.path_attribute.attributes.collect(&:class))
    assert_equal(2, inj.sent.summary[:prefixes_withdrawn])
  end

  def test_mp_reach_the_library_cannot_build_is_a_refusal
    inj = injector
    e = assert_raise(BGP::Sim::Injector::Refused) do
      inj.act('announce', 'mp_reach' => MP.merge('safi' => 255))
    end
    assert_match(/\Amp_reach: /, e.message)
    assert_raise(BGP::Sim::Injector::Refused) { inj.act('announce', 'mp_reach' => [1]) }
    assert_raise(BGP::Sim::Injector::Refused) { inj.act('announce', 'mp_reach' => MP, 'med' => 1) }
    assert_equal([], peer.updates)
  end

  # A specimen by name in Specimen.update's envelope, so the same octets
  # the library answers for that name and this session.
  def test_a_specimen_is_sent_by_name
    inj = injector
    inj.act('announce', 'specimen' => 'large_communities', 'prefixes' => ['11.0.0.0/24'])
    want = BGP::Specimen.update(:large_communities, :my_as => 65_001, :next_hop => '10.0.0.1',
                                                    :prefixes => ['11.0.0.0/24'])
    assert_equal(want.to_shex, peer.updates.last.to_shex)
    assert_equal('65001', peer.updates.last.path_attribute[:as_path].as_path, 'our AS to an external peer')
    assert_equal('10.0.0.1', peer.updates.last.path_attribute[:next_hop].next_hop, 'our address')
  end

  # A family specimen needs no prefixes, and gets no NEXT_HOP without
  # them (RFC 4760 section 3).
  def test_a_family_specimen_needs_no_prefixes
    injector.act('announce', 'specimen' => 'bgp_ls')
    u = peer.updates.last
    assert_nil(u.nlri)
    assert_equal(false, u.path_attribute.has?(BGP::Next_hop))
    assert(u.path_attribute.has?(BGP::Mp_reach))
  end

  def test_an_unknown_specimen_is_refused_and_names_the_catalog
    e = assert_raise(BGP::Sim::Injector::Refused) { injector.act('announce', 'specimen' => 'nope') }
    assert_match(/large_communities/, e.message)
    assert_raise(BGP::Sim::Injector::Refused) do
      injector.act('announce', 'specimen' => 'origin', 'med' => 1)
    end
  end

  def test_the_topology_says_what_can_be_generated_and_specimens
    t = injector.topology
    assert_equal(BGP::Specimen.names.collect(&:to_s), t[:specimens])
    assert_equal(BGP::Gen::GENERATORS.keys, t[:generators])
    assert_equal(BGP::Sim::Injector::PLAN_KEYS, t[:plan])
  end

end
