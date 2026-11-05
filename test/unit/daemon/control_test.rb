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

# What `bgp4rd` can be told to do: the `peer.` and `route.` methods.
#
#   ruby -I. test/unit/daemon/control_test.rb
#
# No socket and no session: a Speaker with a table is enough for the
# `route.` half, and the `peer.` half is about the administrative state
# of a Peer, which needs no connection either. What needs a session is
# `peer.refresh`, which puts a message on one, and that is
# test/functional/daemon_test.rb's.
#
# BGP:: names are written out in full here, see Conventions in CLAUDE.md.

require 'test/unit'
require 'bgp/daemon/control'

class BGP_Daemon_Control_Test < Test::Unit::TestCase

  NEIGHBORS = [{ 'address' => '10.0.0.2', 'as' => 65_001, 'description' => 'inj1' },
               { 'address' => '10.0.0.3', 'as' => 65_000 }].freeze

  def speaker(extra = {})
    s = BGP::Daemon::Speaker.new({ 'as' => 65_000, 'router_id' => '10.0.0.1',
                                   'rib' => true, 'neighbors' => NEIGHBORS }.merge(extra))
    s.start_rib
    s
  end

  def control(extra = {}) ; BGP::Daemon::Control.new(speaker(extra)) ; end

  # ====================================================================
  # route.originate and route.withdraw

  def test_originate_puts_a_prefix_of_ours_in_the_loc_rib
    c = control
    r = c.route_originate('prefix' => '10.255.0.0/24')
    assert_equal(['10.255.0.0/24'], r[:originated])
    assert_equal(1, r[:total])
    assert_equal(1, r[:rib])
    assert_equal(true, c.speaker.rib.best('10.255.0.0/24').local?)
  end

  def test_originate_takes_a_list
    r = control.route_originate('prefixes' => %w[10.255.0.0/24 10.255.1.0/24])
    assert_equal(2, r[:total])
    assert_equal(2, r[:rib])
  end

  # **The body keys are the node file's `originate:` keys**, so a prefix
  # originated here and one originated at start-up carry the same
  # attributes built by the same method.
  def test_the_attributes_are_the_configuration_blocks_own_keys
    c = control
    c.route_originate('prefix' => '10.255.0.0/24', 'med' => 42, 'local_pref' => 150,
                      'origin' => 2, 'communities' => ['65000:1'], 'as_path' => [65_100])
    row = c.speaker.rib.view.routes('10.255.0.0/24').first
    assert_equal(42, row[:med])
    assert_equal(150, row[:local_pref])
    assert_equal(:incomplete, row[:origin])
    assert_equal('65100', row[:as_path])
  end

  # Conventions: building never validates, and the library exists to be
  # able to put octets on the wire no RFC allows. An ORIGIN of 7 is one
  # of those: RFC 4271 section 5.1.1 defines 0, 1 and 2.
  def test_nothing_validates_what_is_originated
    c = control
    assert_nothing_raised { c.route_originate('prefix' => '10.255.0.0/24', 'origin' => 7) }
    assert_equal(7, c.speaker.rib.best('10.255.0.0/24').origin)
  end

  # **A route the decision process will not install still originates**,
  # and the difference is worth pinning: our own AS in the AS_PATH is an
  # AS loop (RFC 4271 section 9.1.2), so the route never becomes a best
  # route, and that is the decision process doing its job rather than a
  # refusal here. It is in the Adj-RIB-In either way, which is what says
  # the origination was not validated.
  def test_a_route_the_decision_process_drops_still_originates
    c = control
    assert_nothing_raised do
      c.route_originate('prefix' => '10.255.9.0/24', 'as_path' => [65_000])
    end
    rib = c.speaker.rib
    assert_nil(rib.best('10.255.9.0/24'), 'an AS loop never becomes a best route')
    assert_equal(['10.255.9.0/24'],
                 rib.adj_rib_in(rib.local_peer).prefixes,
                 'and it is in our own Adj-RIB-In all the same')
  end

  def test_withdraw_takes_one_back
    c = control
    c.route_originate('prefixes' => %w[10.255.0.0/24 10.255.1.0/24])
    r = c.route_withdraw('prefix' => '10.255.0.0/24')
    assert_equal(['10.255.0.0/24'], r[:withdrawn])
    assert_equal([], r[:not_held])
    assert_equal(1, r[:rib])
    assert_nil(c.speaker.rib.best('10.255.0.0/24'))
  end

  # **Answered and not refused.** Withdrawing a route nobody has is not
  # an error, and a caller walking a list wants to know which ones did
  # nothing.
  def test_withdrawing_what_we_never_originated_says_so
    c = control
    c.route_originate('prefix' => '10.255.0.0/24')
    r = c.route_withdraw('prefixes' => %w[10.255.0.0/24 192.0.2.0/24])
    assert_equal(['10.255.0.0/24'], r[:withdrawn])
    assert_equal(['192.0.2.0/24'], r[:not_held])
    assert_equal(1, r[:total])
  end

  # **Membership is read before the withdrawal and not inferred from the
  # change list**, which is ambiguous: a prefix another peer also
  # advertises can be withdrawn by us and leave the Loc-RIB unchanged,
  # because that peer's route then wins. Without reading first this would
  # answer not_held for a prefix it really did take back.
  def test_a_withdrawal_that_changes_no_best_route_is_still_a_withdrawal
    c = control
    peer = BGP::Rib::Peer.new(:address => '10.0.0.2', :remote_as => 65_001,
                              :router_id => '2.2.2.2', :local_as => 65_000)
    # Theirs wins on LOCAL_PREF, so ours is in the table and not best.
    pa = BGP::Path_attribute.new(BGP::Origin.new(0), BGP::As_path.new,
                                 BGP::Next_hop.new('10.0.0.2'), BGP::Local_pref.new(500))
    c.speaker.rib.announce(BGP::Rib::Route.new('10.255.0.0/24', pa, peer))
    c.route_originate('prefix' => '10.255.0.0/24')
    assert_equal(false, c.speaker.rib.best('10.255.0.0/24').local?)
    r = c.route_withdraw('prefix' => '10.255.0.0/24')
    assert_equal(['10.255.0.0/24'], r[:withdrawn])
    assert_equal([], r[:not_held])
    assert_equal(0, r[:changes], 'the other path still wins, so the Loc-RIB did not change')
  end

  # A method that acted on every prefix when told none would be the worst
  # possible default for a withdrawal.
  def test_a_prefix_is_required
    c = control
    assert_raise(ArgumentError) { c.route_originate }
    e = assert_raise(ArgumentError) { c.route_withdraw }
    assert_match(/prefix or prefixes is required/, e.message)
  end

  # `rib: false` is a deliberate configuration, so it is named rather
  # than answered as though the origination worked.
  def test_a_speaker_with_no_table_says_why_it_originates_nothing
    c = BGP::Daemon::Control.new(
      BGP::Daemon::Speaker.new('as' => 65_000, 'router_id' => '10.0.0.1',
                               'neighbors' => NEIGHBORS))
    e = assert_raise(ArgumentError) { c.route_originate('prefix' => '10.255.0.0/24') }
    assert_match(/no table/, e.message)
    assert_match(/rib: false/, e.message)
  end

  # **An ignored body key is a wrong answer and not a missing one**, which
  # is the rule Speaker#export_options already applies to a node file: a
  # typo that silently drops the MED is the worst of both.
  def test_a_parameter_name_it_does_not_read_is_refused_by_name
    c = control
    e = assert_raise(ArgumentError) { c.route_originate('prefix' => '10.0.0.0/8', 'metric' => 1) }
    assert_match(/metric/, e.message)
    assert_match(/med/, e.message, 'the refusal names what it does take')
  end

  def test_symbol_keys_work_too
    assert_equal(1, control.route_originate(:prefix => '10.255.0.0/24')[:total])
  end

  # ====================================================================
  # peer.clear, peer.stop, peer.start

  def test_an_unknown_peer_is_refused_and_the_ones_there_are_named
    c = control
    e = assert_raise(ArgumentError) { c.peer_clear('peer' => '192.0.2.1') }
    assert_match(/192\.0\.2\.1/, e.message)
    assert_match(/10\.0\.0\.2, 10\.0\.0\.3/, e.message)
  end

  def test_a_peer_is_required
    e = assert_raise(ArgumentError) { control.peer_stop }
    assert_match(/peer is required/, e.message)
  end

  # **peer.stop and peer.clear are different things, and the shutdown
  # flag is the whole difference.** Without it the reconnect loop dials
  # again after the retry interval and a `peer.stop` reads as a session
  # that flapped.
  def test_stop_shuts_a_peer_down_and_clear_does_not
    c = control
    peer = c.speaker.peer('10.0.0.2')
    assert_equal(false, peer.shutdown?)
    assert_equal(true, c.peer_stop('peer' => '10.0.0.2')[:shutdown])
    assert_equal(true, peer.shutdown?)
    assert_equal(false, c.peer_start('peer' => '10.0.0.2')[:shutdown])
    assert_equal(false, peer.shutdown?)
    assert_equal(false, c.peer_clear('peer' => '10.0.0.2')[:shutdown],
                 'a clear resets the session and leaves the configuration alone')
    assert_equal(false, peer.shutdown?)
  end

  # Idempotent, so a console that sends one twice is not an error.
  def test_stopping_twice_and_starting_twice_are_not_errors
    c = control
    2.times { assert_equal(true, c.peer_stop('peer' => '10.0.0.2')[:shutdown]) }
    2.times { assert_equal(false, c.peer_start('peer' => '10.0.0.2')[:shutdown]) }
  end

  # The states are routescope's closed lowercase list, as every peer row
  # is: a value outside it is dropped there, so it shows as an empty peer
  # list rather than as an error.
  def test_the_states_answered_are_lowercase
    c = control
    allowed = %w[idle connect active opensent openconfirm established]
    %w[peer_clear peer_stop peer_start].each do |m|
      r = c.send(m, 'peer' => '10.0.0.2')
      assert_include(allowed, r[:state], m)
    end
  end

  # ====================================================================
  # peer.refresh

  # The session is not up here, so this is the refusal. The message on
  # the wire is test/functional/daemon_test.rb's.
  def test_refresh_refuses_a_session_that_is_not_established
    e = assert_raise(ArgumentError) { control.peer_refresh('peer' => '10.0.0.2') }
    assert_match(/not established/, e.message)
    assert_match(/idle/, e.message)
  end

  def test_refresh_refuses_a_parameter_it_does_not_read
    e = assert_raise(ArgumentError) { control.peer_refresh('peer' => '10.0.0.2', 'family' => 1) }
    assert_match(/family/, e.message)
  end

  # RFC 7313 section 3.2's subtype takes the RFC's numbers and the three
  # names Route_refresh answers to. Read through the private helper
  # because the public path needs a session; what reaches the wire is the
  # functional test's.
  def test_a_subtype_takes_a_number_or_a_name
    c = control
    assert_equal(1, c.send(:subtype, 1))
    assert_equal(1, c.send(:subtype, '1'))
    assert_equal(:borr, c.send(:subtype, 'borr'))
    assert_equal(:eorr, c.send(:subtype, :eorr))
    assert_nil(c.send(:subtype, nil))
    e = assert_raise(ArgumentError) { c.send(:subtype, []) }
    assert_match(/normal, borr, eorr/, e.message)
  end

  # Any octet value encodes, so a router can be watched handling a
  # subtype the RFC does not define. 255 is Reserved and 200 unassigned.
  def test_nothing_validates_a_subtype
    c = control
    assert_equal(255, c.send(:subtype, 255))
    assert_equal(200, c.send(:subtype, 200))
  end

  # ====================================================================
  # mark: the communities a route made by hand carries

  MARK = { 'large_communities' => ['65000:1:1'] }.freeze

  # The mark goes on beside the route's own communities, in each of the
  # three lists, and the answer says it did.
  def test_the_mark_is_added_to_a_route_originated_by_hand
    c = control('mark' => MARK.merge('communities' => ['65000:9']))
    r = c.route_originate('prefix' => '10.255.0.0/24', 'communities' => ['65000:100'])
    assert_equal(true, r[:marked])
    row = c.speaker.rib.view.routes('10.255.0.0/24').first
    assert_equal(%w[65000:9 65000:100].sort, row[:communities].sort)
    assert_equal(['65000:1:1'], row[:large_communities])
  end

  def test_with_no_mark_nothing_is_added
    c = control
    r = c.route_originate('prefix' => '10.255.0.0/24')
    assert_equal(false, r[:marked])
    assert_equal([], c.speaker.rib.view.routes('10.255.0.0/24').first[:large_communities])
  end

  # An originate: block in the file is not made by hand, so it carries
  # no mark.
  def test_an_originate_block_in_the_file_is_not_marked
    s = speaker('mark' => MARK, 'originate' => [{ 'prefixes' => ['10.254.0.0/24'] }])
    assert_equal([], s.rib.view.routes('10.254.0.0/24').first[:large_communities])
  end

  # Read on each call, so a commit that changes the mark applies to the
  # next route.
  def test_the_mark_is_read_from_the_running_configuration_on_each_call
    c = control
    c.speaker.reconfigure(c.speaker.config.merge('mark' => MARK))
    c.route_originate('prefix' => '10.255.0.0/24')
    assert_equal(['65000:1:1'], c.speaker.rib.view.routes('10.255.0.0/24').first[:large_communities])
  end

  def test_a_mark_key_it_does_not_read_is_refused_by_name
    e = assert_raise(ArgumentError) { BGP::Daemon::Control.mark('mark' => { 'large' => ['1:1:1'] }) }
    assert_match(/mark: unknown key\(s\) large: it takes communities, extended_communities, large_communities/,
                 e.message)
  end

  def test_a_mark_that_is_not_a_mapping_is_refused
    e = assert_raise(ArgumentError) { BGP::Daemon::Control.mark('mark' => ['65000:1:1']) }
    assert_match(/\Amark takes/, e.message)
  end

  def test_a_mark_community_that_does_not_parse_is_refused_and_says_mark
    e = assert_raise(ArgumentError) do
      BGP::Daemon::Control.mark('mark' => { 'extended_communities' => ['route_target'] })
    end
    assert_match(/\Amark: an extended community is KIND:VALUE/, e.message)
  end

  def test_no_mark_is_an_empty_mark
    assert_equal({}, BGP::Daemon::Control.mark({}))
    assert_equal({}, BGP::Daemon::Control.mark(nil))
  end


  # ====================================================================
  # Sending by hand: peer.specimen, peer.fault, peer.replay, peer.resend

  # A Peer that says its session is up and keeps what it was asked to
  # send. A real session crossing these is test/functional/daemon_test.rb's.
  def up(c, address = '10.0.0.2')
    p = c.speaker.peer(address)
    sent = []
    p.define_singleton_method(:established?) { true }
    p.define_singleton_method(:send_message) { |m| sent << m }
    p.define_singleton_method(:local_ip) { '10.0.0.1' }
    sent
  end

  def test_a_specimen_goes_to_the_named_peer_and_is_listed_not_written
    c = control
    sent = up(c)
    r = c.peer_specimen('name' => 'large_communities', 'prefix' => '10.30.0.0/24',
                        'peer' => '10.0.0.2')
    assert_equal('large_communities', r[:specimen])
    assert_equal([{ :peer => '10.0.0.2', :prefixes => ['10.30.0.0/24'] }], r[:sent])
    assert_equal(1, sent.size)
    assert_kind_of(BGP::Large_communities, sent.first.path_attribute[BGP::Large_communities])
    assert_equal('65000', sent.first.path_attribute[BGP::As_path].as_path, 'our AS toward an external peer')
    rows = c.speaker.hand.rows('10.0.0.2')
    assert_equal(['10.30.0.0/24'], rows.collect { |x| x[:prefix] })
    assert_equal(['specimen large_communities'], rows.collect { |x| x[:verb] })
    assert_equal(0, c.speaker.rib.loc_rib.size, 'it never enters the Loc-RIB')
  end

  # The mark goes into the specimen's own attribute of that type, so the
  # UPDATE carries one of each, and is appended where there is none.
  def test_a_specimen_carries_the_mark
    mark = { 'mark' => { 'large_communities' => ['65000:1:1'], 'communities' => ['65000:9'] } }
    c = control(mark)
    sent = up(c)
    r = c.peer_specimen('name' => 'large_communities', 'peer' => '10.0.0.2')
    assert_equal(true, r[:marked])
    pa = sent.first.path_attribute
    assert_equal(1, pa.attributes.count { |a| a.is_a?(BGP::Large_communities) })
    assert_include(pa[BGP::Large_communities].large_communities.split, '65000:1:1')
    assert_equal('65000:9', pa[BGP::Communities].communities)
  end

  # A fault is the message under test, so nothing is added to it.
  def test_a_fault_is_never_marked
    c = control('mark' => { 'communities' => ['65000:9'] })
    sent = up(c)
    r = c.peer_fault('case' => 'origin_value', 'prefix' => '10.10.0.0/24', 'peer' => '10.0.0.2')
    assert_equal('origin_value', r[:case])
    assert(!sent.first.path_attribute.has?(BGP::Communities))
    assert_equal(BGP::Fault.update(:origin_value, :my_as => 65_000, :next_hop => '10.0.0.1',
                                   :prefixes => ['10.10.0.0/24']).encode,
                 sent.first.encode, 'the catalog octets, unchanged')
    assert_equal(['fault origin_value'], c.speaker.hand.rows('10.0.0.2').collect { |x| x[:verb] })
  end

  def test_replay_sends_octets_unchanged_and_reads_them_back
    c = control
    sent = up(c)
    hex = BGP::Update.new(BGP::Path_attribute.new(BGP::Origin.new(0), BGP::As_path.new(65_000),
                                                  BGP::Next_hop.new('10.0.0.1')),
                          BGP::Nlri.new('10.40.0.0/24')).to_shex
    r = c.peer_replay('hex' => hex, 'peer' => '10.0.0.2')
    assert_equal([hex].pack('H*'), sent.first)
    assert_equal(hex.size / 2, r[:octets])
    assert_equal(['10.40.0.0/24'], c.speaker.hand.prefixes('10.0.0.2'))
    c.peer_replay('hex' => 'ff 00', 'peer' => '10.0.0.2')
    assert_include(c.speaker.hand.rows('10.0.0.2').collect { |x| x[:prefix] }, nil,
                   'octets that are not a message list the whole peer')
  end

  # With no peer named, every session that is up, as bgp4r-sim does.
  def test_with_no_peer_named_every_session_that_is_up
    c = control
    a = up(c, '10.0.0.2')
    b = up(c, '10.0.0.3')
    c.peer_fault('case' => 'origin_value', 'prefix' => '10.10.0.0/24')
    assert_equal([1, 1], [a.size, b.size])
    assert_equal('empty', b.first.path_attribute[BGP::As_path].as_path, 'empty toward an internal peer')
  end

  # A send that would go nowhere is refused, never an answer that sent
  # nothing.
  def test_a_send_with_no_session_is_refused
    c = control
    e = assert_raise(ArgumentError) { c.peer_fault('case' => 'origin_value') }
    assert_match(/no established session: 10.0.0.2 idle, 10.0.0.3 idle/, e.message)
    e = assert_raise(ArgumentError) { c.peer_replay('hex' => '00', 'peer' => '10.0.0.2') }
    assert_match(/10.0.0.2 has no established session/, e.message)
  end

  def test_the_send_refusals_name_what_is_wrong
    c = control
    up(c)
    assert_raise_message(/name: is required; the catalog has/) { c.peer_specimen({}) }
    assert_raise_message(/unknown specimen "nope"/) { c.peer_specimen('name' => 'nope') }
    assert_raise_message(/case: is required/) { c.peer_fault({}) }
    assert_raise_message(/unknown case "nope"/) { c.peer_fault('case' => 'nope') }
    assert_raise_message(/not a non-empty, even number of hex digits/) { c.peer_replay('hex' => 'abc') }
    assert_raise_message(/not a non-empty, even number of hex digits/) { c.peer_replay({}) }
    assert_raise_message(/unknown parameter\(s\) med/) { c.peer_fault('case' => 'origin_value', 'med' => 1) }
  end

  # With no Router, which is no export: block, the daemon advertises
  # nothing, so its answer for every prefix is a withdrawal.
  def test_resend_with_no_router_withdraws_every_prefix
    c = control
    sent = up(c)
    c.speaker.hand.record('10.0.0.2', BGP::Fault.update(:origin_value, :prefixes => %w[10.10.0.0/24]), 'fault origin_value')
    sent.clear
    r = c.peer_resend('peer' => '10.0.0.2')
    assert_equal({ :peer => '10.0.0.2', :resent => [], :withdrawn => ['10.10.0.0/24'], :hand => 0 }, r)
    assert_equal(['10.10.0.0/24'], sent.flat_map { |m| m.withdrawn.to_ary })
  end

  # A row resend has no answer for is kept and named.
  def test_resend_keeps_what_it_cannot_answer
    c = control
    up(c)
    c.speaker.hand.record('10.0.0.2', "\xff".b, 'replay')
    r = c.peer_resend('peer' => '10.0.0.2')
    assert_equal(1, r[:hand])
    assert_equal([nil], r[:kept].collect { |x| x[:prefix] })
  end

  def test_resend_needs_a_peer_that_is_up
    c = control
    assert_raise_message(/peer is required/) { c.peer_resend({}) }
    assert_raise_message(/10.0.0.2 has no established session/) { c.peer_resend('peer' => '10.0.0.2') }
  end

end
