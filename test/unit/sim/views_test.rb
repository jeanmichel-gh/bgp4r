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

# What bgp4r-sim answers, as data. No socket and no session: an Injector
# with no table is enough, which is the point of keeping the views a
# reader of two objects rather than a server.
#
#   ruby -I. test/unit/sim/views_test.rb

require 'test/unit'
require 'bgp/sim/views'

class BGP_Sim_Views_Test < Test::Unit::TestCase

  NEIGHBORS = [{ 'address' => '10.0.10.2', 'as' => 65_000, 'description' => 'rtr' },
               { 'address' => '10.0.11.2', 'as' => 65_001 }].freeze

  def injector(extra = {})
    @injector ||= BGP::Sim::Injector.new({ 'router_id' => '10.255.10.1', 'as' => 65_001,
                                           'neighbors' => NEIGHBORS }.merge(extra))
  end

  def views(extra = {}) ; BGP::Sim::Views.new(injector(extra)) ; end

  # **The shape is `bgp4rd`'s, inherited and not rewritten**, which is
  # the read table's own requirement: "the same shape bgp4rd answers, so
  # one driver reads both".
  def test_it_is_the_daemons_views
    assert_kind_of(BGP::Daemon::Views, views)
  end

  def test_status_names_the_router_and_its_sessions
    s = views.status
    assert_equal('10.255.10.1', s[:router_id])
    assert_equal(65_001, s[:as])
    assert_kind_of(Integer, s[:uptime])
    assert_equal(2, s[:peers].size)
    assert_equal(%w[10.0.10.2 10.0.11.2], s[:peers].collect { |p| p[:address] })
    assert_equal([:ebgp, :ibgp], s[:peers].collect { |p| p[:type] })
  end

  # routescope's state contract is
  # `summary: { established:, peers:, rib: }`, and an injector holds no
  # Loc-RIB: zero routes in a table it does not have is true, where
  # leaving the key out would make a console show a blank and putting
  # the announced count there would call a list of what it sent a RIB.
  def test_the_summary_answers_rib_as_zero_and_announced_beside_it
    s = views.status[:summary]
    assert_equal(0, s[:rib])
    assert_equal(2, s[:peers])
    assert_equal(0, s[:established])
    assert_equal(0, s[:announced])
    assert_equal(0, s[:sent])
  end

  # routescope validates a state against a closed lowercase list and
  # **drops** a value outside it, so a capitalised state shows as an
  # empty peer list rather than as an error.
  def test_a_peer_state_is_lowercase_and_one_routescope_accepts
    allowed = %w[idle connect active opensent openconfirm established]
    views.peers.each { |r| assert_include(allowed, r[:state]) }
  end

  # The row routescope's `bgp_peers` table wants:
  # `address remote_as state description uptime received sent`.
  def test_a_peer_row_carries_routescopes_columns
    row = views.peers.first
    %i[address remote_as state description uptime received].each do |k|
      assert(row.key?(k), "#{k} is missing from a peer row")
    end
  end

  # ---- sent ----------------------------------------------------------

  def test_sent_is_the_counters_the_feeds_and_the_rows
    s = views.sent
    assert_equal(%i[summary feeds routes], s.keys)
    assert_equal(0, s[:summary][:prefixes_sent])
    assert_equal([], s[:feeds])
    assert_equal([], s[:routes][:rows])
    assert_equal(0, s[:routes][:total])
  end

  # The rows are paged in `bgp4rd`'s page envelope, so a caller walks
  # them the same way, and `next_offset` is the cursor: a caller handed
  # a short list cannot tell the end of a table from a truncated answer.
  def test_the_rows_are_paged_with_a_cursor
    v = views
    5.times { |i| remember(v, "10.#{i}.0.0/24") }
    first = v.sent('limit' => '2')[:routes]
    assert_equal(5, first[:total])
    assert_equal(2, first[:rows].size)
    assert_equal(2, first[:next_offset])
    last = v.sent('limit' => '2', 'offset' => '4')[:routes]
    assert_equal(1, last[:rows].size)
    assert_nil(last[:next_offset])
  end

  def test_a_limit_is_clamped_rather_than_refused
    v = views
    assert_equal(1, v.sent('limit' => '0')[:routes][:limit])
    assert_equal(BGP::Daemon::Views::MAX_LIMIT, v.sent('limit' => '99999')[:routes][:limit])
    assert_equal(0, v.sent('offset' => '-3')[:routes][:offset])
  end

  def test_a_limit_that_is_not_a_number_is_refused_and_names_the_key
    e = assert_raise(ArgumentError) { views.sent('limit' => 'lots') }
    assert_match(/limit must be an integer/, e.message)
  end

  # ---- topology ------------------------------------------------------

  def test_topology_is_what_it_can_be_told_to_do
    t = views.topology
    assert_equal('10.255.10.1', t[:router_id])
    assert_equal(2, t[:neighbors].size)
    assert_equal(BGP::Sim::Injector::ACTIONS, t[:actions])
    assert_include(t[:faults], 'origin_length')
    assert_equal(0, t[:announce_at_start], 'it starts silent')
  end

  def test_topology_says_when_a_node_file_asked_for_a_feed_at_start_up
    v = views('announce' => [{ 'prefixes' => ['10.1.0.0/24'] }])
    assert_equal(1, v.topology[:announce_at_start])
  end

  # ---- events --------------------------------------------------------

  # **bgp4r's own `Event#to_h` shape and not ospfv2's**, which is a
  # correction to docs/daemon.md's read table: all seven fields, with a
  # full ISO 8601 time, so a driver has one rename to do and nothing to
  # invent.
  def test_an_event_carries_all_seven_fields_of_bgp4rs_own_shape
    v = views
    v.speaker.events.publish(:kind => :route, :peer => '10.0.10.2',
                             :message => 'announced 1 prefix(es)',
                             :data => { 'prefixes' => ['10.1.0.0/24'] })
    answer = v.events('since' => '0')
    assert_equal(1, answer[:seq])
    assert_include(answer[:kinds], 'route')
    event = answer[:events].first
    %i[seq time level kind peer message data].each do |k|
      assert(event.key?(k), "#{k} is missing from an event")
    end
    assert_equal('route', event[:kind])
    assert_equal('10.0.10.2', event[:peer])
    assert_equal({ 'prefixes' => ['10.1.0.0/24'] }, event[:data])
    assert_match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z\z/, event[:time],
                 'a full ISO 8601 time, which is what ospfv2 makes a driver rebuild')
  end

  def test_since_is_where_a_reader_resumes_from
    v = views
    3.times { |i| v.speaker.events.publish(:kind => :log, :message => "line #{i}") }
    assert_equal(3, v.events('since' => '0')[:events].size)
    assert_equal(1, v.events('since' => '2')[:events].size)
    assert_equal(3, v.events({})[:events].size)
  end

  def test_a_since_that_is_not_a_number_is_refused
    assert_raise(ArgumentError) { views.events('since' => 'soon') }
  end

  private

  # One announced prefix, through the action, with a fake session is
  # more than this file needs: the rows come from `Injector#announced`,
  # so the record is what matters and `injector_test.rb` is where the
  # sending is asserted.
  def remember(v, prefix)
    v.injector.send(:remember, [prefix], { 'prefixes' => [prefix], 'med' => 1 })
  end

end
