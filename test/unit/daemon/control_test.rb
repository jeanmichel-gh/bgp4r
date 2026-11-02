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

end
