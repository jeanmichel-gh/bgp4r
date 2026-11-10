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

# What bgp4rd answers, as data. No socket and no session: a Speaker with
# a table and a prefix of its own is enough, which is the point of
# keeping Views a reader of two objects rather than a server.
#
#   ruby -I. test/unit/daemon/views_test.rb

require 'test/unit'
require 'bgp/daemon/views'

class BGP_Daemon_Views_Test < Test::Unit::TestCase

  NEIGHBORS = [{ 'address' => '10.0.0.2', 'as' => 65_001, 'description' => 'inj1' },
               { 'address' => '10.0.0.3', 'as' => 65_000 }].freeze

  def speaker(extra = {})
    s = BGP::Daemon::Speaker.new({ 'as' => 65_000, 'router_id' => '10.0.0.1',
                                   'neighbors' => NEIGHBORS }.merge(extra))
    s.start_rib
    s
  end

  # One table with prefixes of ours in it, which needs no session: see
  # #130, where rib.originate landed with the export rules.
  def loaded(count = 3, extra = {})
    s = speaker({ 'rib' => true }.merge(extra))
    count.times { |i| s.rib.originate("10.#{i}.0.0/16", :path_attribute => pa) }
    s.rib.drain
    s
  end

  def views(speaker) ; BGP::Daemon::Views.new(speaker) ; end

  def test_status_names_the_router_and_counts_its_peers
    v = views(loaded)
    s = v.status
    assert_equal('10.0.0.1', s[:router_id])
    assert_equal(65_000, s[:as])
    assert_kind_of(Integer, s[:uptime])
    assert_equal(3, s[:summary][:rib])
    assert_equal(0, s[:summary][:established])
  end

  # ---- the reflector role, RFC 4456 ----

  CLIENT = { 'address' => '10.0.0.4', 'as' => 65_000, 'route_reflector_client' => true }.freeze

  # A speaker that reflects nothing says so and adds no per peer key, so
  # its rows read as they always have.
  def test_a_speaker_that_reflects_nothing_says_so
    v = views(loaded)
    assert_equal([false, nil], v.status.values_at(:route_reflector, :cluster_id))
    assert(v.peers.none? { |r| r.has_key?(:route_reflector_client) })
  end

  # The same with a router that advertises and does not reflect, which
  # is the case that needs Export#route_reflector? asked: a speaker with
  # no export block has no router at all.
  def test_a_router_that_does_not_reflect_says_so
    v = views(loaded(1, 'export' => { 'next_hops' => { 1 => '10.0.0.1' } }))
    assert_not_nil(v.speaker.router)
    assert_equal([false, nil], v.status.values_at(:route_reflector, :cluster_id))
    assert(v.peers.none? { |r| r.has_key?(:route_reflector_client) })
  end

  # The flag is the client list: the flagged internal peer is a client,
  # the other internal peer is not, and an external peer never is.
  def test_a_reflector_names_its_clients
    v = views(loaded(1, 'neighbors' => NEIGHBORS + [CLIENT]))
    assert_equal([true, '10.0.0.1'], v.status.values_at(:route_reflector, :cluster_id),
                 'the cluster ID defaults to the router ID')
    assert_equal({ '10.0.0.2' => false, '10.0.0.3' => false, '10.0.0.4' => true },
                 v.peers.to_h { |r| [r[:address], r[:route_reflector_client]] })
  end

  def test_the_cluster_id_is_the_one_configured
    v = views(loaded(1, 'neighbors' => NEIGHBORS + [CLIENT], 'export' => { 'cluster_id' => '7.7.7.7' }))
    assert_equal('7.7.7.7', v.status[:cluster_id])
  end

  # With route_reflector and no client list every internal peer is a
  # client, which is the single cluster case of RFC 4456 section 6. The
  # row says what Export decides and not only what was flagged.
  def test_with_no_client_list_every_internal_peer_is_a_client
    v = views(loaded(1, 'export' => { 'route_reflector' => true }))
    assert_equal({ '10.0.0.2' => false, '10.0.0.3' => true },
                 v.peers.to_h { |r| [r[:address], r[:route_reflector_client]] })
  end

  # **The configured count and not the table's.** rib.view counts the
  # peers the table has seen, which for a daemon whose neighbors are
  # down is zero, and a peer table that hides the peers that are down
  # hides the interesting ones.
  def test_summary_peers_is_the_configured_count
    v = views(loaded)
    assert_equal(2, v.status[:summary][:peers])
    assert_equal([], v.speaker.rib.view.status[:peers],
                 'the table has seen none of them, which is what this key corrects')
  end

  def test_every_configured_peer_is_a_row
    rows = views(loaded).peers
    assert_equal(%w[10.0.0.2 10.0.0.3], rows.collect { |r| r[:address] })
    assert_equal('inj1', rows[0][:description])
    assert_nil(rows[1][:description])
    assert_equal([:ebgp, :ibgp], rows.collect { |r| r[:type] })
  end

  # routescope validates a state against a closed lowercase list and
  # **drops** a value outside it, so a capitalised state shows as an
  # empty peer list rather than as an error.
  def test_a_peer_state_is_lowercase_and_one_routescope_accepts
    allowed = %w[idle connect active opensent openconfirm established]
    views(loaded).peers.each { |r| assert_include(allowed, r[:state]) }
  end

  # Every state bgp4r's FSM reaches, downcased, is in that list.
  # Measured rather than assumed: bgp4r never enters :Connect, going
  # straight to :Active when it opens the socket, and :OpenRecv is in
  # Neighbor's is_*? helpers and is never set.
  def test_every_state_the_fsm_reaches_is_in_that_list
    allowed = %w[idle connect active opensent openconfirm established]
    reached = File.read(File.expand_path('../../../bgp/neighbor/neighbor.rb', __dir__))
                  .scan(/new_state\(?\s*:(\w+)/).flatten
    assert_operator(reached.size, :>=, 5)
    (reached + ['Idle']).uniq.each { |s| assert_include(allowed, s.downcase) }
  end

  # A peer the table has never seen answers 0 rather than leaving the
  # key out: it holds no routes, which is a known answer.
  def test_a_peer_with_no_session_still_answers_its_counts
    rows = views(loaded).peers
    rows.each do |r|
      assert_equal(0, r[:received])
      assert_equal(0, r[:best])
      assert_nil(r[:uptime])
      assert_equal(0, r[:flaps])
      # No Neighbor, so no queues: nil, which is an answer that says it
      # cannot say, where 0 would claim the session had nothing to do.
      assert_nil(r[:inq])
      assert_nil(r[:outq])
    end
  end

  # held is router mode's, and a speaker with no router has nothing to
  # hold, so it is nil there and a count with one.
  def test_held_is_a_count_in_router_mode_and_nil_without_it
    with = views(loaded(1, 'export' => { 'next_hops' => { 1 => '10.0.0.1' } }))
    assert_equal(0, with.peers.first[:held])
    assert_nil(views(loaded).peers.first[:held])
  end

  def test_sent_is_there_in_router_mode_and_absent_without_it
    with = views(loaded(1, 'export' => { 'next_hops' => { 1 => '10.0.0.1' } }))
    assert_equal(0, with.peers.first[:sent])
    assert_equal(false, views(loaded).peers.first.has_key?(:sent),
                 'a speaker that advertises nothing has no Adj-RIB-Out to count')
  end

  def test_routes_answers_one_row_per_prefix_in_a_page
    page = views(loaded).routes
    assert_equal(3, page[:total])
    assert_equal(3, page[:rows].size)
    assert_equal(0, page[:offset])
    assert_nil(page[:next_offset])
    assert_equal(%w[10.0.0.0/16 10.1.0.0/16 10.2.0.0/16], page[:rows].collect { |r| r[:prefix] })
    assert_equal(true, page[:rows].first[:best])
  end

  def test_rib_answers_the_decision_beside_the_paths
    row = views(loaded).rib[:rows].first
    assert_equal('10.0.0.0/16', row[:prefix])
    assert_equal(:only_route, row[:decided_by])
    assert_equal(1, row[:paths].size)
    assert_equal('best path, the only usable path', row[:paths].first[:reason])
  end

  # **The scale requirement, which is the reason the envelope exists.**
  # A full table is about a million prefixes and no endpoint may build a
  # million element array, so a caller walks it with offset and
  # next_offset, and next_offset nil is what says the walk is over.
  def test_a_page_says_where_the_next_one_starts
    v = views(loaded(5))
    first = v.routes('limit' => 2)
    assert_equal(5, first[:total])
    assert_equal(2, first[:rows].size)
    assert_equal(2, first[:next_offset])
    second = v.routes('limit' => 2, 'offset' => first[:next_offset])
    assert_equal(%w[10.2.0.0/16 10.3.0.0/16], second[:rows].collect { |r| r[:prefix] })
    last = v.routes('limit' => 2, 'offset' => 4)
    assert_equal(1, last[:rows].size)
    assert_nil(last[:next_offset], 'the last page says the walk is over')
  end

  # **A read sees one coherent snapshot rather than a RIB that is
  # deciding in between.** `Table#synchronize` is reentrant and public
  # for exactly this, so the whole page is built inside one, and the
  # view's own synchronize nests inside it.
  #
  # Matched as code, because that is the only way to say a file **does**
  # something: a test with a concurrent writer would be a test whose
  # bound is machine timing, which CLAUDE.md records slipping under
  # load. The pattern is anchored at the start of a line of code so a
  # comment naming the method cannot match it, which is the lesson
  # mcast_vpn_doc_test.rb's first draft paid for.
  def test_a_page_is_built_inside_one_table_lock
    src = File.read(File.expand_path('../../../bgp/daemon/views.rb', __dir__))
    body = src[/^      def keyed\(params, keys_fn\)\n(.*?)^      end$/m, 1]
    assert_not_nil(body, 'Views#keyed must still be there: every paged view goes through it')
    assert_match(/^        snapshot do$/, body)
    assert_match(/^          keys = keys_fn\.call$/, body,
                 'the key list is read inside the lock, not handed in from outside it')
    lock = src[/^      def snapshot\n(.*?)^      end$/m, 1]
    assert_not_nil(lock, 'Views#snapshot must still be there')
    assert_match(/^        @speaker\.rib\.synchronize \{ yield \}$/, lock)
  end

  # **One envelope and one window, read by every paged view**, so a
  # second set of rules about what next_offset nil means cannot grow
  # beside the first. Matched as code for the reason above.
  def test_one_envelope_builder_serves_every_paged_view
    src = File.read(File.expand_path('../../../bgp/daemon/views.rb', __dir__))
    assert_equal(1, src.scan(/:next_offset =>/).size,
                 'the page envelope is built in one place')
    assert_equal(1, src.scan(/^      def window\(params\)$/).size)
    assert_equal(1, src.scan(/^      def envelope\(/).size)
  end

  def test_the_page_keys_are_the_same_for_both_views
    v = views(loaded(2))
    assert_equal(v.routes.keys.sort, v.rib.keys.sort)
    assert_equal(%i[limit next_offset offset rows total], v.rib.keys.sort)
  end

  # A caller naming a prefix is asking a question with one answer, so
  # offset does not apply to it.
  def test_a_prefix_answers_that_one_row
    page = views(loaded).routes('prefix' => '10.1.0.0/16')
    assert_equal(1, page[:total])
    assert_equal('10.1.0.0/16', page[:rows].first[:prefix])
    assert_nil(page[:next_offset])
  end

  def test_a_prefix_the_table_does_not_hold_answers_no_rows
    page = views(loaded).routes('prefix' => '192.0.2.0/24')
    assert_equal(0, page[:total])
    assert_equal([], page[:rows])
  end

  # Clamped rather than refused, and the answer carries the limit it
  # used, so a caller can see what it got.
  def test_a_limit_is_clamped_and_reported
    v = views(loaded(2))
    assert_equal(1, v.routes('limit' => 0)[:limit])
    assert_equal(1, v.routes('limit' => -5)[:limit])
    assert_equal(BGP::Daemon::Views::MAX_LIMIT, v.routes('limit' => 1_000_000)[:limit])
    assert_equal(BGP::Daemon::Views::PAGE_LIMIT, v.routes[:limit])
    assert_equal(0, v.routes('offset' => -1)[:offset])
  end

  def test_an_offset_past_the_end_answers_no_rows
    page = views(loaded(2)).routes('offset' => 99)
    assert_equal(2, page[:total])
    assert_equal([], page[:rows])
  end

  def test_a_limit_that_is_not_a_number_is_refused_by_name
    e = assert_raise(ArgumentError) { views(loaded).routes('limit' => 'lots') }
    assert_match(/limit/, e.message)
  end

  # A Symbol key works as well as a String one, because a test calls
  # these directly and the socket hands them Strings.
  def test_symbol_keys_work_too
    assert_equal(1, views(loaded(3)).routes(:limit => 1)[:rows].size)
    assert_equal('10.1.0.0/16', views(loaded).routes(:prefix => '10.1.0.0/16')[:rows].first[:prefix])
  end

  def test_text_is_the_loc_rib_the_way_a_router_prints_it
    v = views(loaded)
    assert_match(/10\.0\.0\.0\/16/, v.text)
    assert_match(/Network/, v.text('style' => 'ios'))
    assert_not_equal(v.text('style' => 'ios'), v.text('style' => 'junos'))
  end

  # **The refusal is Rib::Show's and there is no second one here.** A
  # guard in Views against Show::STYLES passed every sabotage aimed at
  # it, because Show.new already refuses and names the styles: it was a
  # second statement of a check the library makes, which is #223's dead
  # constant one file over. So this asserts the refusal, wherever it
  # comes from, and the style list is in one place.
  def test_an_unknown_style_names_the_ones_there_are
    e = assert_raise(ArgumentError) { views(loaded).text('style' => 'cisco') }
    assert_match(/ios/, e.message)
    assert_match(/junos/, e.message)
    assert_equal([], File.read(File.expand_path('../../../bgp/daemon/views.rb', __dir__))
                          .scan(/^\s*unless Rib::Show::STYLES/),
                 'one place refuses a style, and it is Rib::Show')
  end

  # rib: false is a deliberate configuration and the answer is an empty
  # page rather than a failure, which is the honest answer for a speaker
  # with no table.
  def test_a_speaker_with_no_table_answers_empty_rather_than_failing
    v = views(BGP::Daemon::Speaker.new('as' => 65_000, 'router_id' => '10.0.0.1',
                                       'neighbors' => NEIGHBORS))
    assert_nil(v.speaker.rib)
    assert_equal([], v.routes[:rows])
    assert_equal(0, v.rib[:total])
    assert_equal('', v.text)
    assert_equal('10.0.0.1', v.status[:router_id])
    assert_equal(2, v.status[:summary][:peers])
    assert_equal(2, v.peers.size)
  end

  # ====================================================================
  # show.adj_in, show.adj_out, show.fib, show.log

  # **A per peer view with no peer has no sensible default**: the first
  # configured neighbor would be an answer about a peer nobody asked
  # about, and every peer at once is what the page envelope exists to
  # prevent.
  def test_a_per_peer_view_requires_a_peer_and_names_the_ones_there_are
    v = views(loaded)
    %i[adj_in adj_out].each do |m|
      e = assert_raise(ArgumentError) { v.send(m) }
      assert_match(/peer is required/, e.message, m.to_s)
      e = assert_raise(ArgumentError) { v.send(m, 'peer' => '192.0.2.1') }
      assert_match(/10\.0\.0\.2, 10\.0\.0\.3/, e.message, m.to_s)
    end
  end

  # A configured peer that has never come up holds nothing, which is an
  # answer and not a failure.
  def test_a_peer_with_no_session_answers_an_empty_page
    v = views(loaded)
    page = v.adj_in('peer' => '10.0.0.2')
    assert_equal([], page[:rows])
    assert_equal(0, page[:total])
    assert_nil(page[:next_offset])
  end

  # Both carry the page envelope, which is what a caller walks a million
  # prefixes with, and adj_out carries skipped beside it because a
  # skipped prefix is by definition not among the ones the page walks.
  def test_the_two_per_peer_views_are_paged_and_adj_out_carries_skipped
    v = views(loaded)
    assert_equal(%i[limit next_offset offset rows total], v.adj_in('peer' => '10.0.0.2').keys.sort)
    out = v.adj_out('peer' => '10.0.0.2')
    assert_equal(%i[limit next_offset offset rows skipped total], out.keys.sort)
    assert_equal({ :total => 0, :rows => [] }, out[:skipped])
  end

  # **hand rides beside the page only when there is something in it**,
  # so every answer reads as it did until something is sent by hand. It
  # is never written into the rows: those still say what the daemon last
  # sent the normal way.
  def test_adj_out_lists_what_was_sent_by_hand_beside_the_rows
    s = loaded
    v = views(s)
    rows = v.adj_out('peer' => '10.0.0.2')[:rows]
    u = BGP::Update.new(BGP::Path_attribute.new(BGP::Origin.new(0)), BGP::Nlri.new('10.30.0.0/24'))
    s.hand.record('10.0.0.2', u, 'specimen large_communities', nil, Time.utc(2026, 11, 4, 14, 13, 5))
    out = v.adj_out('peer' => '10.0.0.2')
    assert_equal({ :total => 1, :rows => [{ :prefix => '10.30.0.0/24', :verb => 'specimen large_communities',
                                           :at => '2026-11-04T14:13:05.000Z' }] }, out[:hand])
    assert_equal(rows, out[:rows], 'the rows are not patched')
    assert_equal(false, v.adj_out('peer' => '10.0.0.3').key?(:hand), 'per peer')
    s.hand.record('10.0.0.2', BGP::Update.new(BGP::Path_attribute.new(BGP::Origin.new(0)),
                                              BGP::Nlri.new('10.31.0.0/24')), 'ship')
    capped = v.adj_out('peer' => '10.0.0.2', 'limit' => 1)[:hand]
    assert_equal([2, 1], [capped[:total], capped[:rows].size], 'capped like skipped, with its own total')
  end

  # A peer row gains a count, again only when there is one.
  def test_a_peer_row_counts_what_was_sent_by_hand
    s = loaded
    v = views(s)
    assert(v.peers.none? { |r| r.key?(:hand) })
    s.hand.record('10.0.0.3', BGP::Update.new(BGP::Path_attribute.new(BGP::Origin.new(0)),
                                              BGP::Nlri.new('10.1.0.0/24', '10.2.0.0/24')), 'ship')
    assert_equal({ '10.0.0.2' => nil, '10.0.0.3' => 2 }, v.peers.to_h { |r| [r[:address], r[:hand]] })
    assert_equal(2, v.status[:peers].find { |r| r[:address] == '10.0.0.3' }[:hand])
  end

  # **fib.configured is what tells a daemon with no fib: in its
  # configuration from one whose table happens to be empty.** Both
  # answer no rows, so without that key the two are the same answer.
  def test_fib_says_whether_anything_is_installing_at_all
    page = views(loaded).fib
    assert_equal([], page[:rows])
    assert_equal(0, page[:total])
    assert_equal(false, page[:fib][:configured])
    assert_equal([], page[:fib][:failed])
  end

  def test_fib_is_paged_with_its_own_facts_beside_the_page
    assert_equal(%i[fib limit next_offset offset rows total],
                 views(loaded).fib.keys.sort)
  end

  # A Views with no table answers the same keys, so a reader does not
  # have to branch on rib: false.
  def test_a_speaker_with_no_table_answers_the_same_fib_keys
    v = views(BGP::Daemon::Speaker.new('as' => 65_000, 'router_id' => '10.0.0.1',
                                       'neighbors' => NEIGHBORS))
    assert_equal(%i[fib limit next_offset offset rows total], v.fib.keys.sort)
    assert_equal(false, v.fib[:fib][:configured])
    assert_equal([], v.adj_in('peer' => '10.0.0.2')[:rows])
  end

  # **Text and not structure**, which is where show.log parts company
  # with ospfv2's: bgp/daemon/log_ring.rb has the decision and what it
  # rejected. keeps says whether anything is kept at all.
  def test_log_answers_the_last_lines_as_text
    ring = BGP::Daemon::LogRing.new
    3.times { |i| ring.write("line #{i}\n") }
    v = BGP::Daemon::Views.new(loaded, :log => ring)
    assert_equal(['line 0', 'line 1', 'line 2'], v.log[:lines])
    assert_equal(3, v.log[:kept])
    assert_equal(BGP::Daemon::LogRing::KEEP, v.log[:keeps])
    assert_equal(['line 2'], v.log('count' => 1)[:lines])
  end

  def test_a_views_with_no_ring_keeps_nothing_and_says_so
    v = views(loaded)
    assert_equal([], v.log[:lines])
    assert_equal(0, v.log[:keeps], 'keeps 0 says nothing is kept at all')
  end

  def test_a_log_count_that_is_not_a_number_is_refused_by_name
    e = assert_raise(ArgumentError) { views(loaded).log('count' => 'lots') }
    assert_match(/count/, e.message)
  end

  private

  def pa
    BGP::Path_attribute.new(BGP::Origin.new(0), BGP::As_path.new,
                            BGP::Next_hop.new('10.0.0.1'))
  end

  # `show.link_state`: one page of BGP-LS rows, in the envelope of every
  # other paged view. The table is outside the RIB. A speaker that holds
  # none answers an empty page.
  def test_link_state_answers_a_page_of_rows
    s = speaker
    v = views(s)
    assert_equal({ :rows => [], :total => 0, :offset => 0, :limit => 500, :next_offset => nil },
                 v.link_state)
    ls = ->(id) {
      BGP::Link_state.new(:node => { :protocol_id => 1, :identifier => 0,
                                     :tlvs => [{ :local_node_descriptors => [{ :igp_router_id => id }] }] })
    }
    s.link_state.announce('10.0.0.2', ls.call('000000010101'), nil)
    s.link_state.announce('10.0.0.2', ls.call('000000010102'), nil)
    page = v.link_state('limit' => 1)
    assert_equal(2, page[:total])
    assert_equal(1, page[:next_offset])
    assert_equal('0000.0001.0101.00', page[:rows].first['local'])
    assert_equal('10.0.0.2', page[:rows].first['peer'])
    assert_equal('0000.0001.0102.00', v.link_state('offset' => 1)[:rows].first['local'])
  end
end
