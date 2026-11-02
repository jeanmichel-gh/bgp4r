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
    # **And the withdrawal path lists nothing either**, which is the
    # same rule as the announce path above. Sabotage caught this
    # missing: recording every generated prefix in `stream_withdraw`
    # passed the whole file, because the only assertion about rows was
    # on the other path.
    assert_equal([], inj.announced)
  end

  def test_a_generated_range_that_the_generator_refuses_is_a_refusal
    e = assert_raise(BGP::Sim::Injector::Refused) do
      injector.act('announce', 'generate' => { 'count' => 10 })
    end
    assert_match(/generate/, e.message)
  end

  # The documented gap, refused rather than ignored: Speaker#each_update
  # hands RouteGenerator no Path Identifier, so a path_id on a generate
  # block would be dropped in silence.
  def test_a_path_id_on_a_generated_announce_is_refused_rather_than_dropped
    e = assert_raise(BGP::Sim::Injector::Refused) do
      injector.act('announce', 'generate' => { 'start' => '11.0.0.0/28', 'count' => 2 },
                               'path_id' => 7)
    end
    assert_match(/path_id/, e.message)
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

end
