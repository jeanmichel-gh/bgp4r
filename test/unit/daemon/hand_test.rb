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

# The list of what bgp4rd sent a peer by hand, on its own: what a
# message is read back as, and the three ways a row clears. The sends
# that fill it are control_test.rb's and console_test.rb's, the Router
# half is test/unit/rib/router_test.rb's, and a session crossing all of
# it is test/functional/daemon_test.rb's.
#
#   ruby -I. test/unit/daemon/hand_test.rb
#
# BGP:: names are written out in full here, see Conventions in CLAUDE.md.

require 'test/unit'
require 'bgp/daemon/speaker'

class BGP_Daemon_Hand_Test < Test::Unit::TestCase

  P = '10.0.0.2'.freeze

  def setup
    @h = BGP::Daemon::Hand.new
  end

  def update(*prefixes, mp: nil, withdrawn: nil)
    attrs = [BGP::Origin.new(0), BGP::As_path.new(65_000), BGP::Next_hop.new('10.0.0.1')]
    attrs << mp if mp
    if withdrawn
      BGP::Update.new(BGP::Withdrawn.new(*withdrawn), BGP::Path_attribute.new(*attrs),
                      (prefixes.empty? ? nil : BGP::Nlri.new(*prefixes)))
    else
      BGP::Update.new(BGP::Path_attribute.new(*attrs), BGP::Nlri.new(*prefixes))
    end
  end

  # ---- reading a message back -------------------------------------------

  def test_an_update_is_read_for_every_unicast_prefix_it_touches
    mp = BGP::Mp_reach.new(:afi => 2, :safi => 1, :nexthop => ['2001:db8::1'],
                           :nlris => ['2001:db8:1::/48'])
    u = update('10.40.0.0/24', mp: mp, withdrawn: ['10.41.0.0/24'])
    assert_equal(%w[10.41.0.0/24 10.40.0.0/24 2001:db8:1::/48],
                 BGP::Daemon::Hand.read_back(u).collect { |r| r[:prefix] })
  end

  def test_an_mp_unreach_of_safi_1_is_a_prefix_too
    mp = BGP::Mp_unreach.new(:afi => 2, :safi => 1, :nlris => ['2001:db8:2::/48'])
    u = BGP::Update.new(BGP::Path_attribute.new(mp))
    assert_equal([{ :prefix => '2001:db8:2::/48' }], BGP::Daemon::Hand.read_back(u))
  end

  # Octets are read as a message first, so `replay` and a String handed
  # to `ship` list what they carry.
  def test_octets_that_read_as_an_update_are_read_for_their_prefixes
    octets = update('10.40.0.0/24').encode
    assert_equal([{ :prefix => '10.40.0.0/24' }], BGP::Daemon::Hand.read_back(octets))
  end

  # The daemon cannot say what octets that are not a message touched.
  def test_octets_that_do_not_read_as_a_message_are_the_whole_peer
    assert_equal([{ :prefix => nil }], BGP::Daemon::Hand.read_back("\xff\x00".b))
  end

  # A KEEPALIVE changes no route, and a NOTIFICATION ends the session,
  # which clears the list anyway.
  def test_a_message_that_is_not_an_update_touches_nothing
    assert_equal([], BGP::Daemon::Hand.read_back(BGP::Keepalive.new))
    assert_equal([], BGP::Daemon::Hand.read_back(BGP::Keepalive.new.encode))
    assert_equal([], BGP::Daemon::Hand.read_back(BGP::Notification.new(6, 2)))
  end

  # An NLRI of a family the daemon holds no table for is listed with its
  # family, since resend has no answer of its own for it.
  def test_another_family_is_listed_with_its_family
    u = BGP::Specimen.update(:bgp_ls, :my_as => 65_000)
    rows = BGP::Daemon::Hand.read_back(u)
    assert_equal(['16388/71'], rows.collect { |r| r[:family] }.uniq)
    assert(rows.all? { |r| r[:prefix].is_a?(String) && !r[:prefix].empty? })
  end

  # ---- the list -----------------------------------------------------------

  def test_record_lists_each_prefix_with_its_verb_and_time
    at = Time.utc(2026, 11, 4, 14, 13, 5)
    @h.record(P, update('10.30.0.0/24'), 'specimen large_communities', nil, at)
    assert_equal([{ :prefix => '10.30.0.0/24', :verb => 'specimen large_communities',
                    :at => '2026-11-04T14:13:05.000Z' }], @h.rows(P))
    assert_equal(1, @h.count(P))
    assert_equal(['10.30.0.0/24'], @h.prefixes(P))
    assert_equal([], @h.rows('10.0.0.3'), 'per peer')
    assert_equal(0, @h.count('10.0.0.3'))
  end

  # The same prefix sent by hand twice is one row, the later one.
  def test_a_prefix_sent_twice_is_one_row_with_the_later_verb
    @h.record(P, update('10.30.0.0/24'), 'specimen x', nil, Time.utc(2026, 1, 1))
    @h.record(P, update('10.30.0.0/24'), 'fault y', nil, Time.utc(2026, 1, 2))
    assert_equal(['fault y'], @h.rows(P).collect { |r| r[:verb] })
  end

  def test_rows_are_oldest_first
    @h.record(P, update('10.2.0.0/24'), 'b', nil, Time.utc(2026, 1, 2))
    @h.record(P, update('10.1.0.0/24'), 'a', nil, Time.utc(2026, 1, 1))
    assert_equal(%w[a b], @h.rows(P).collect { |r| r[:verb] })
  end

  # Only the unicast rows are prefixes resend can answer.
  def test_prefixes_leave_out_another_family_and_the_whole_peer
    @h.record(P, update('10.1.0.0/24'), 'ship')
    @h.record(P, "\xff".b, 'replay')
    @h.record(P, BGP::Specimen.update(:bgp_ls, :my_as => 65_000), 'specimen bgp_ls')
    assert_equal(['10.1.0.0/24'], @h.prefixes(P))
    assert_equal(3, @h.count(P))
  end

  # The first way a row clears: the daemon sent the prefix the normal way.
  def test_a_prefix_sent_the_normal_way_clears_and_nothing_else_does
    @h.record(P, update('10.1.0.0/24', '10.2.0.0/24'), 'ship')
    @h.sent(P, ['10.1.0.0/24'])
    assert_equal(['10.2.0.0/24'], @h.prefixes(P))
    @h.sent('10.0.0.3', ['10.2.0.0/24'])
    assert_equal(['10.2.0.0/24'], @h.prefixes(P), 'another peer clears nothing here')
  end

  # A prefix is matched in the form Rib::Route keys it.
  def test_sent_matches_a_prefix_in_any_spelling
    mp = BGP::Mp_reach.new(:afi => 2, :safi => 1, :nexthop => ['2001:db8::1'], :nlris => ['2001:db8:1::/48'])
    @h.record(P, BGP::Update.new(BGP::Path_attribute.new(BGP::Origin.new(0), mp)), 'ship')
    @h.sent(P, ['2001:DB8:1:0::/48'])
    assert_equal(0, @h.count(P))
  end

  # The second: the session ended.
  def test_reset_clears_one_peer
    @h.record(P, update('10.1.0.0/24'), 'ship')
    @h.record('10.0.0.3', update('10.1.0.0/24'), 'ship')
    @h.reset(P)
    assert_equal(0, @h.count(P))
    assert_equal(1, @h.count('10.0.0.3'))
  end

  # The Speaker owns one, which the Views and Control read.
  def test_a_speaker_has_one
    s = BGP::Daemon::Speaker.new('as' => 65_000, 'router_id' => '10.0.0.1',
                                 'neighbors' => [{ 'address' => P, 'as' => 65_001 }])
    assert_kind_of(BGP::Daemon::Hand, s.hand)
  end

end
