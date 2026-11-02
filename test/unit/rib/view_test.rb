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

require 'test/unit'
require 'json'
require 'bgp/rib'

# The view: the table's state as plain data.
#
# **The assertions that matter are the ones about lost_at**, since why a
# path lost is the one answer no other implementation in a lab can give
# about itself. LOSSES below is one scenario per value the decision
# process can file, and test_every_decision_step_has_a_scenario holds
# that table against Decision::STEPS and Decision::INELIGIBLE rather
# than against a list written here, so a step added to the decision
# process with no scenario and no words fails this file.
#
# BGP:: names are written out in full here, see Conventions in CLAUDE.md.
class TestBgpRibView < Test::Unit::TestCase

  LOCAL_AS = 65001
  ROUTER_ID = '1.1.1.1'
  P = '10.1.0.0/16'

  # A Neighbor that keeps what it was asked to send instead of writing it
  # to a socket, so router mode can be driven with no session. Copied from
  # router_test.rb, which is where the router itself is tested.
  class Recording < BGP::Neighbor
    def sent ; @sent ||= [] ; end
    def send_update(u) ; sent << u ; end
  end

  def setup
    @rib = table
    @neighbors = []
  end

  def teardown
    @rib.feed.stop if @rib
    @neighbors.each { |n| n.close }
  end

  def table(**options)
    BGP::Rib.new(:local_as => LOCAL_AS, :router_id => ROUTER_ID, **options)
  end

  def peer(address, remote_as, router_id)
    BGP::Rib::Peer.new(:address => address, :remote_as => remote_as,
                       :router_id => router_id, :local_as => LOCAL_AS)
  end

  E1 = BGP::Rib::Peer.new(:address => '10.0.0.2', :remote_as => 65002,
                          :router_id => '2.2.2.2', :local_as => LOCAL_AS)
  E2 = BGP::Rib::Peer.new(:address => '10.0.0.3', :remote_as => 65003,
                          :router_id => '3.3.3.3', :local_as => LOCAL_AS)
  I1 = BGP::Rib::Peer.new(:address => '10.0.0.4', :remote_as => LOCAL_AS,
                          :router_id => '4.4.4.4', :local_as => LOCAL_AS)
  I2 = BGP::Rib::Peer.new(:address => '10.0.0.5', :remote_as => LOCAL_AS,
                          :router_id => '5.5.5.5', :local_as => LOCAL_AS)

  # One route. next_hop: nil leaves NEXT_HOP out altogether, which is what
  # makes a route ineligible for want of a next hop.
  def route(p, prefix = P, origin: 0, med: nil, local_pref: nil, as_path: nil,
            next_hop: :peer, originator_id: nil, cluster_list: nil, path_id: nil)
    attrs = [BGP::Origin.new(origin)]
    nh = next_hop == :peer ? p.address : next_hop
    attrs << BGP::Next_hop.new(nh) if nh
    segments = as_path || (p.ebgp? ? [p.remote_as] : [])
    attrs << (segments.empty? ? BGP::As_path.new : BGP::As_path.new(*segments))
    attrs << BGP::Multi_exit_disc.new(med) if med
    attrs << BGP::Local_pref.new(local_pref) if local_pref
    attrs << BGP::Originator_id.new(originator_id) if originator_id
    attrs << BGP::Cluster_list.new(*cluster_list) if cluster_list
    BGP::Rib::Route.new(prefix, BGP::Path_attribute.new(*attrs), p, :path_id => path_id)
  end

  # A reflected route (RFC 4456 section 8). Both paths of the two
  # scenarios that use it carry the same ORIGINATOR_ID, so the step before
  # theirs ties on it, and neither its cluster IDs nor its ORIGINATOR_ID
  # is ours, which would make it ineligible instead.
  REFLECTED = { :local_pref => 100, :as_path => [65050],
                :originator_id => '9.9.9.9', :cluster_list => ['2.2.2.2'] }.freeze

  # One scenario per reason a path can lose: the winner, the loser, and
  # any option the table needs for the step to be reached. Each pair is
  # built so that every earlier step of Decision::STEPS ties, which is the
  # only way to land on the step under test.
  LOSSES = {
    # The ten tie breaks, in Decision::STEPS order.
    :local_pref => {
      :winner => [:I1, { :local_pref => 250 }],
      :loser  => [:I2, { :local_pref => 100 }] },
    :as_path_length => {
      :winner => [:E1, { :as_path => [65002] }],
      :loser  => [:E2, { :as_path => [65003, 65004] }] },
    :origin => {
      :winner => [:E1, { :origin => 0 }],
      :loser  => [:E2, { :origin => 2 }] },
    # Both from AS 65002, so RFC 4271 section 9.1.2.2 c) compares them.
    :med => {
      :winner => [:E1,  { :med => 10 }],
      :loser  => [:E1b, { :med => 20, :as_path => [65002] }] },
    # One external and one internal, with everything before this step
    # tied: the internal route carries an AS_PATH of its own so that the
    # lengths match and the MEDs are not compared across one AS.
    :ebgp_over_ibgp => {
      :winner => [:E1, {}],
      :loser  => [:I1, { :local_pref => 100, :as_path => [65050] }] },
    # The only step that needs a resolver, since with none every next hop
    # costs 0 and this step can never decide anything.
    :igp_cost => {
      :table  => { :resolver => ->(nh) { nh == '10.0.0.2' ? 1 : 5 } },
      :winner => [:E1, {}],
      :loser  => [:E2, {}] },
    :router_id => {
      :winner => [:E1, {}],
      :loser  => [:E2, {}] },
    # Both reflected and carrying the same ORIGINATOR_ID, so the step
    # before this one ties on it (RFC 4456 section 9).
    :cluster_list_length => {
      :winner => [:I1, REFLECTED],
      :loser  => [:I2, REFLECTED.merge(:cluster_list => ['2.2.2.2', '3.3.3.3'])] },
    :peer_address => {
      :winner => [:I1, REFLECTED],
      :loser  => [:I2, REFLECTED] },
    # Two paths from one peer, which is what add-path is (RFC 7911).
    :path_id => {
      :winner => [:I1, { :local_pref => 100, :path_id => 1 }],
      :loser  => [:I1, { :local_pref => 100, :path_id => 2 }] },
    # The four of Decision::INELIGIBLE, each set aside before any
    # comparison, so each loser is paired with a plain winner.
    :next_hop_unreachable => {
      :winner => [:E1, {}],
      :loser  => [:E2, { :next_hop => nil }] },
    :as_loop => {
      :winner => [:E1, {}],
      :loser  => [:E2, { :as_path => [65003, LOCAL_AS] }] },
    :originator_id_loop => {
      :winner => [:E1, {}],
      :loser  => [:I2, { :local_pref => 100, :originator_id => ROUTER_ID }] },
    :cluster_list_loop => {
      :winner => [:E1, {}],
      :loser  => [:I2, { :local_pref => 100, :cluster_list => [ROUTER_ID] }] }
  }.freeze

  # E1b is a second peer in E1's own AS, which is what the MED step needs.
  PEERS = { :E1 => E1, :E2 => E2, :I1 => I1, :I2 => I2,
            :E1b => BGP::Rib::Peer.new(:address => '10.0.0.9', :remote_as => 65002,
                                       :router_id => '9.9.9.9', :local_as => LOCAL_AS) }.freeze

  # The table of one scenario, the winner announced first.
  def loss_table(step)
    s = LOSSES.fetch(step)
    rib = table(**(s[:table] || {}))
    [s[:winner], s[:loser]].each do |(name, options)|
      rib.announce(route(PEERS.fetch(name), P, **options))
    end
    rib
  end

  def paths_of(rib, prefix = P)
    rows = rib.view.rib(prefix)
    assert_equal(1, rows.size, "one row for #{prefix}")
    rows.first[:paths]
  end

  # Turns router mode on and advertises what the table holds to one peer
  # at 10.0.0.2, so the Adj-RIB-Out exists. Answers that peer's row.
  # The neighbor is the recording one, so nothing reaches a socket, and
  # the route being advertised has to come from somewhere else: a third
  # peer, so it is not refused as going back to its sender, and external,
  # so it is not refused as iBGP to iBGP either (RFC 4456 section 4).
  def advertise_to_a_peer
    n = Recording.new(:my_as => LOCAL_AS, :remote_addr => '10.0.0.2',
                      :local_addr => '10.0.0.1', :id => ROUTER_ID)
    n.instance_variable_set(:@rmt_as, 65002)
    n.instance_variable_set(:@rmt_bgp_id, '2.2.2.2')
    n.instance_variable_set(:@state, :Established)
    @neighbors << n
    @rib.attach(n)
    @rib.advertise(:next_hops => { 1 => '10.0.0.1' })
    @rib.drain
    @rib.view.status[:peers].find { |p| p[:address] == '10.0.0.2' }
  end

  # ====================================================================
  # Why a path lost, which is the whole point of the rib view.

  # Every scenario in LOSSES: the winner is the best path with no lost_at,
  # and the loser carries the step it lost at, in words.
  def test_every_scenario_reports_the_step_its_path_lost_at
    LOSSES.each_key do |step|
      rib = loss_table(step)
      paths = paths_of(rib)
      assert_equal(2, paths.size, "two paths for #{step}")
      best, lost = paths
      assert_equal(true, best[:best], "the first path is the best one for #{step}")
      assert_nil(best[:lost_at], "the best path lost at nothing for #{step}")
      assert_equal(false, lost[:best], "the second path is not best for #{step}")
      assert_equal(step, lost[:lost_at], "lost_at for #{step}")
      assert_equal(BGP::Rib::View::LOST_WORDS[step], lost[:reason], "reason for #{step}")
      # A step is a comparison a valid route lost; an INELIGIBLE reason is
      # a route that never took part (RFC 4271 section 9.1.2).
      assert_equal(!BGP::Rib::Decision::INELIGIBLE.include?(step), lost[:usable],
                   "usable for #{step}")
    end
  end

  # The guard: the scenarios are measured against the decision process
  # rather than listed, so a step added to Decision::STEPS without a
  # scenario here fails, as does one with no words of its own.
  def test_every_decision_step_has_a_scenario
    expected = BGP::Rib::Decision::STEPS + BGP::Rib::Decision::INELIGIBLE
    assert_equal(expected.sort, LOSSES.keys.sort,
                 'a scenario is missing for a reason the decision process can file')
    assert_equal(14, expected.size, 'ten tie breaks and four ineligible reasons')
  end

  def test_every_reason_the_decision_can_file_has_words
    reasons = BGP::Rib::Decision::STEPS + BGP::Rib::Decision::INELIGIBLE + [:duplicate]
    assert_equal([], reasons - BGP::Rib::View::LOST_WORDS.keys,
                 'these can be filed and have no words')
    assert_equal([], BGP::Rib::View::LOST_WORDS.keys - reasons,
                 'these have words and cannot be filed')
    BGP::Rib::View::LOST_WORDS.each do |step, words|
      assert(words.size > 12, "#{step} says too little")
    end
  end

  # docs/daemon.md said lost_at is one of fourteen values until this was
  # measured. There is a fifteenth, :duplicate, which Decision#best files
  # when only identical routes are left. It cannot be reached through a
  # Table, because an imported route is keyed by its peer and Path
  # Identifier and a Peer is its address, so the second announcement below
  # replaces the first rather than joining it.
  def test_duplicate_is_a_fifteenth_value_that_no_table_can_show
    r1 = route(I1, P, :local_pref => 100)
    r2 = route(I1, P, :local_pref => 100)
    result = @rib.decision.best([r1, r2])
    assert_equal(:duplicate, result.reason)
    assert_equal([:duplicate], result.eliminated.values)
    assert(BGP::Rib::View::LOST_WORDS.key?(:duplicate))
    @rib.announce(r1)
    @rib.announce(r2)
    assert_equal(1, paths_of(@rib).size, 'one path, since the key is the same')
  end

  # docs/daemon.md lists the lost_at values, and that list is the one part
  # of it with code behind it: the rest designs two programs that do not
  # exist. The code is the view's, so the guard is here, and it is read
  # out of the document rather than written down twice.
  #
  # The counts are asserted before the names, so a pattern that stops
  # matching fails loudly instead of comparing two empty lists.
  def test_the_daemon_design_lists_the_values_the_library_can_file
    doc = File.read('docs/daemon.md')
    # From the paragraph that introduces the list, so a code block
    # somewhere else in the document cannot be read as one of these two.
    from = doc.index('`lost_at` is one of')
    assert(from, 'the document no longer introduces the list')
    steps, ineligible = doc[from..].scan(/^```\n([a-z_ \n]+)\n```$/).map { |(b)| b.split }
    assert_equal(10, steps.size, 'the ten tie breaks')
    assert_equal(4, ineligible.size, 'the four ineligible reasons')
    assert_equal(BGP::Rib::Decision::STEPS.map(&:to_s), steps,
                 'the document lists the steps in Decision::STEPS order')
    assert_equal(BGP::Rib::Decision::INELIGIBLE.map(&:to_s), ineligible)
    assert_match(/one of \*\*fifteen\*\* values/, doc, 'and says how many there are')
    assert_match(/^And `duplicate`, the fifteenth/, doc)
  end

  # The step that decided the prefix is on the prefix, which is
  # Decision::Result#reason, and the best path's own reason says it in
  # words. docs/daemon.md puts the step in the best path's reason field
  # instead; see the comment on View for why that is not what this does.
  def test_the_prefix_says_which_step_decided_it
    rib = loss_table(:med)
    row = rib.view.rib(P).first
    assert_equal(:med, row[:decided_by])
    assert_equal('best path, decided at the med step', row[:paths].first[:reason])
    assert_equal(:med, rib.view.routes(P).first[:decided_by])
  end

  def test_the_only_usable_path_says_so
    @rib.announce(route(E1))
    row = @rib.view.rib(P).first
    assert_equal(:only_route, row[:decided_by])
    assert_equal('best path, the only usable path', row[:paths].first[:reason])
  end

  # A prefix with one usable path and one ineligible one is decided as
  # :only_route, and the ineligible path is still reported beside it.
  def test_an_ineligible_path_is_reported_beside_the_only_usable_one
    rib = loss_table(:as_loop)
    row = rib.view.rib(P).first
    assert_equal(:only_route, row[:decided_by])
    assert_equal([true, false], row[:paths].map { |p| p[:usable] })
    assert_equal(:as_loop, row[:paths].last[:lost_at])
  end

  # The Loc-RIB is what is walked, and it holds only prefixes that have a
  # best route, so a prefix whose every path is ineligible is in neither
  # view. Show has the same blind spot, from the same line.
  def test_a_prefix_with_no_usable_path_is_in_neither_view
    @rib.announce(route(E1, '10.7.0.0/16', :next_hop => nil))
    assert_equal(1, @rib.candidates('10.7.0.0/16').size, 'the candidate is there')
    assert_nil(@rib.best('10.7.0.0/16'))
    assert_equal([], @rib.view.rib)
    assert_equal([], @rib.view.routes)
  end

  # ====================================================================
  # The three shapes.

  def test_the_views_are_the_three_the_daemon_answers
    assert_equal(%i[status routes rib], BGP::Rib::View::VIEWS)
  end

  def test_the_table_answers_a_view_and_it_is_the_same_one
    assert_kind_of(BGP::Rib::View, @rib.view)
    assert_same(@rib.view, @rib.view)
    assert_same(@rib, @rib.view.table)
  end

  def test_a_routes_row_carries_the_best_path_of_one_prefix
    rib = loss_table(:med)
    rows = rib.view.routes
    assert_equal(1, rows.size)
    assert_equal({ :prefix => P, :from => '10.0.0.2', :next_hop => '10.0.0.2',
                   :as_path => '65002', :origin => :igp, :local_pref => nil,
                   :med => 10, :path_id => nil, :local => false, :paths => 2,
                   :best => true, :decided_by => :med }, rows.first)
  end

  def test_a_rib_path_carries_the_decision_as_well
    rib = loss_table(:med)
    assert_equal({ :from => '10.0.0.9', :next_hop => '10.0.0.9', :as_path => '65002',
                   :origin => :igp, :local_pref => nil, :med => 20, :path_id => nil,
                   :local => false, :best => false, :usable => true, :lost_at => :med,
                   :reason => 'higher MED from the same neighbouring AS' },
                 paths_of(rib).last)
  end

  def test_status_names_the_router_and_counts_the_table
    rib = loss_table(:local_pref)
    rib.originate('10.9.0.0/16')
    s = rib.view.status
    assert_equal(ROUTER_ID, s[:router_id])
    assert_equal(LOCAL_AS, s[:as])
    assert_equal({ :peers => 2, :rib => 2, :paths => 3, :originated => 1 }, s[:summary])
  end

  # A peer is a BGP peer. Table#originate keeps our own routes in an
  # Adj-RIB-In keyed by LocalPeer, so we are in Table#peers, and we have
  # no session with ourselves.
  def test_we_are_not_one_of_our_own_peers
    @rib.originate('10.9.0.0/16')
    @rib.announce(route(E1))
    assert_equal(2, @rib.peers.size, 'the table holds an Adj-RIB-In for us')
    assert_equal(['10.0.0.2'], @rib.view.status[:peers].map { |p| p[:address] })
    assert_equal(1, @rib.view.status[:summary][:peers])
    assert_equal(1, @rib.view.status[:summary][:originated])
  end

  def test_a_peer_row_counts_what_it_sent_and_what_won
    rib = loss_table(:local_pref)
    rows = rib.view.status[:peers]
    assert_equal([{ :address => '10.0.0.4', :remote_as => LOCAL_AS, :router_id => '4.4.4.4',
                    :type => :ibgp, :received => 1, :best => 1 },
                  { :address => '10.0.0.5', :remote_as => LOCAL_AS, :router_id => '5.5.5.5',
                    :type => :ibgp, :received => 1, :best => 0 }], rows)
  end

  def test_an_external_peer_is_named_as_one
    @rib.announce(route(E1))
    assert_equal(:ebgp, @rib.view.status[:peers].first[:type])
  end

  # sent is the Adj-RIB-Out, which belongs to a Router and not to a Table,
  # so the key is absent until router mode is on rather than present and
  # wrong.
  def test_the_sent_count_is_there_only_in_router_mode
    # From a third peer, so the route is not refused as going back to the
    # peer that sent it, and external, so it is not refused as iBGP to
    # iBGP either (RFC 4456 section 4).
    @rib.announce(route(peer('10.9.9.9', 65009, '9.9.9.9'), P, :as_path => [65009]))
    assert(!@rib.view.status[:peers].first.key?(:sent), 'no router, no key')
    row = advertise_to_a_peer
    # It has sent us nothing, so it has no Adj-RIB-In and is in the list
    # only because the Router has an Adj-RIB-Out for it.
    assert_equal({ :address => '10.0.0.2', :remote_as => 65002, :router_id => '2.2.2.2',
                   :type => :ebgp, :received => 0, :best => 0, :sent => 1 }, row)
    assert_equal(2, @rib.view.status[:summary][:peers], 'both directions')
    # And reading must not change what it reads: Table#adj_rib_in creates
    # an Adj-RIB-In on first use, so asking this peer for its received
    # count the obvious way would have given it one.
    assert(@rib.peers.none? { |p| p.address == '10.0.0.2' },
           'reading status gave it an Adj-RIB-In')
  end

  # ====================================================================
  # The contracts the two design documents give, read out of them.
  #
  # docs/routescope-labs.md section 12 asks for exactly this guard and
  # calls it the one worth writing early, "because a driver in another
  # repository will depend on it and nothing else will tell us we broke
  # it". Section 4 carries routescope's own two table row shapes,
  # verbatim from its drivers.rb, so the columns come out of the document
  # rather than being listed here.

  # The columns of one of section 4's two row shapes.
  def columns(row)
    doc = File.read('docs/routescope-labs.md')
    m = doc.match(/^#{row}\s+(\S.*)$/)
    assert(m, "section 4 no longer carries the #{row} row shape")
    names = m[1].split.map(&:to_sym)
    assert(names.size > 5, "#{row} has suspiciously few columns")
    names
  end

  def test_the_routes_view_answers_every_column_of_the_bgp_routes_row
    cols = columns('bgp_routes')
    @rib.announce(route(E1, P, :med => 10))
    row = @rib.view.routes.first
    assert_equal([], cols - row.keys,
                 'a column of routescope bgp_routes row that the view cannot answer')
    assert_equal(%i[path_id local decided_by], row.keys - cols,
                 'and what the view adds beyond it')
  end

  # Four of the seven columns, and the three it cannot answer are
  # session facts: a Neighbor has them and a Table does not. The driver
  # merges them, which is why the keys here are routescope's own.
  def test_the_status_view_answers_the_session_free_half_of_the_peer_row
    cols = columns('bgp_peers')
    @rib.announce(route(peer('10.9.9.9', 65009, '9.9.9.9'), P, :as_path => [65009]))
    row = advertise_to_a_peer
    assert_equal(%i[address remote_as received sent], cols & row.keys)
    assert_equal(%i[state description uptime], cols - row.keys,
                 'what a session owns and a Table does not')
    assert_equal(%i[router_id type best], row.keys - cols)
  end

  # Section 4 also gives the shape of the state method a driver answers,
  # Base#bgp(container). established is the fifth session fact.
  def test_the_status_view_is_the_state_method_shape_less_the_session
    @rib.announce(route(E1))
    s = @rib.view.status
    assert_equal(%i[router_id as summary peers], s.keys)
    assert_equal(%i[peers rib], s[:summary].keys & %i[established peers rib])
    assert(!s[:summary].key?(:established), 'a session fact, and the daemon adds it')
    doc = File.read('docs/routescope-labs.md')
    assert_match(/summary: \{ established:, peers:, rib: \}/, doc,
                 'section 4 no longer gives that shape')
  end

  # ====================================================================
  # The values, and where they differ from what Show prints.

  # Show prints 0 in the Metric column for a route with no
  # MULTI_EXIT_DISC, because that is what a router prints. A route with no
  # MED is not a route with a MED of 0, so the view says nil.
  def test_an_absent_med_is_nil_and_not_zero
    @rib.announce(route(E1))
    assert_nil(@rib.view.routes.first[:med])
    assert_nil(@rib.best(P).med)
    assert_match(/ 0 /, @rib.show, 'where Show prints zero')
  end

  # LOCAL_PREF from an external peer is dropped on import (RFC 4271
  # section 5.1.5), so the view says nil there too.
  def test_an_external_peers_local_pref_is_nil
    @rib.announce(route(E1, P, :local_pref => 250))
    assert_nil(@rib.view.routes.first[:local_pref])
  end

  # RFC 4271 section 5.1.1: 0 IGP, 1 EGP, 2 INCOMPLETE, spelled out in
  # lower case, which is docs/daemon.md's shape.
  def test_the_origin_is_a_word
    { 0 => :igp, 1 => :egp, 2 => :incomplete }.each do |value, word|
      rib = table
      rib.announce(route(E1, P, :origin => value))
      assert_equal(word, rib.view.routes.first[:origin], "origin #{value}")
    end
    assert_equal({ 0 => :igp, 1 => :egp, 2 => :incomplete }, BGP::Rib::View::ORIGINS)
  end

  # Route#as_path answers the word "empty" when there is no AS_PATH, which
  # is a thing to print and not a value.
  def test_an_empty_as_path_is_an_empty_string
    @rib.announce(route(I1, P, :local_pref => 100))
    assert_equal('empty', @rib.best(P).as_path)
    assert_equal('', @rib.view.routes.first[:as_path])
  end

  def test_an_originated_route_says_it_is_ours
    @rib.originate('10.9.0.0/16')
    row = @rib.view.routes.first
    assert_equal(true, row[:local])
    assert_equal(ROUTER_ID, row[:from])
  end

  def test_a_learned_route_is_not_ours
    @rib.announce(route(E1))
    assert_equal(false, @rib.view.routes.first[:local])
  end

  # RFC 7911 section 3: the Path Identifier a path arrived with.
  def test_a_path_identifier_is_carried
    rib = loss_table(:path_id)
    assert_equal([1, 2], paths_of(rib).map { |p| p[:path_id] })
    assert_equal(1, rib.view.routes(P).first[:path_id])
  end

  # ====================================================================
  # Which prefixes, in what order.

  # The IPv6 default route is in there because it is the one prefix that
  # tells a sort key carrying the address family from one that does not:
  # its integer is 0, so without the family it would sort before every
  # IPv4 prefix. Every IPv6 address a lab actually uses has an integer
  # far above any IPv4 one, which is why this cannot be checked with
  # 2001:db8::/32.
  def test_prefixes_come_out_in_a_stable_order_with_ipv4_first
    %w[192.168.0.0/24 2001:db8::/32 ::/0 10.1.0.0/16 10.0.0.0/8].each do |p|
      @rib.announce(route(E1, p))
    end
    seen = @rib.view.routes.map { |r| r[:prefix] }
    assert_equal(%w[10.0.0.0/8 10.1.0.0/16 192.168.0.0/24 ::/0 2001:db8::/32], seen)
    assert_equal(seen, @rib.view.rib.map { |r| r[:prefix] }, 'both views agree')
    assert_equal(seen, @rib.view.prefixes)
    assert_equal(0, IPAddr.new('::/0').to_i, 'which is what makes this a test')
  end

  def test_one_prefix_can_be_asked_for
    @rib.announce(route(E1, '10.1.0.0/16'))
    @rib.announce(route(E1, '10.2.0.0/16'))
    assert_equal(['10.1.0.0/16'], @rib.view.routes('10.1.0.0/16').map { |r| r[:prefix] })
    assert_equal(['10.1.0.0/16'], @rib.view.rib('10.1.0.0/16').map { |r| r[:prefix] })
  end

  # A prefix is normalized as it is everywhere else in bgp/rib/, so a
  # spelling with host bits set reaches the same row.
  def test_a_prefix_is_normalized
    @rib.announce(route(E1, '10.1.0.0/16'))
    assert_equal(1, @rib.view.rib('10.1.2.3/16').size)
  end

  def test_a_prefix_the_table_does_not_have_is_no_rows
    @rib.announce(route(E1))
    assert_equal([], @rib.view.rib('172.16.0.0/12'))
    assert_equal([], @rib.view.routes('172.16.0.0/12'))
  end

  def test_an_empty_table_answers_empty
    assert_equal([], @rib.view.routes)
    assert_equal([], @rib.view.rib)
    assert_equal([], @rib.view.prefixes)
    assert_equal({ :peers => 0, :rib => 0, :paths => 0, :originated => 0 },
                 @rib.view.status[:summary])
    assert_equal([], @rib.view.status[:peers])
  end

  # ====================================================================
  # JSON, which is a thin layer over the data above.

  def test_json_is_the_same_data_with_string_keys
    rib = loss_table(:med)
    parsed = JSON.parse(rib.view.json(:rib))
    assert_equal(1, parsed.size)
    assert_equal(P, parsed.first['prefix'])
    assert_equal('med', parsed.first['decided_by'])
    assert_equal([nil, 'med'], parsed.first['paths'].map { |p| p['lost_at'] })
    assert_equal([true, false], parsed.first['paths'].map { |p| p['best'] })
    assert_equal('higher MED from the same neighbouring AS',
                 parsed.first['paths'].last['reason'])
  end

  # Every view answers as JSON, and a Symbol comes back as a String,
  # which is the point of the format.
  def test_json_answers_every_view
    rib = loss_table(:med)
    status = JSON.parse(rib.view.json(:status))
    assert_equal(rib.view.status.keys.map(&:to_s), status.keys)
    assert_equal(ROUTER_ID, status['router_id'])
    assert_equal(%w[10.0.0.2 10.0.0.9], status['peers'].map { |p| p['address'] })
    assert_equal('ebgp', status['peers'].first['type'], 'a Symbol value is a String')
    routes = JSON.parse(rib.view.json(:routes))
    assert_equal(rib.view.routes.first.keys.map(&:to_s), routes.first.keys)
    assert_equal('igp', routes.first['origin'])
    assert_equal(%w[prefix decided_by paths], JSON.parse(rib.view.json(:rib)).first.keys)
  end

  def test_json_defaults_to_the_rib_and_takes_a_prefix
    @rib.announce(route(E1, '10.1.0.0/16'))
    @rib.announce(route(E1, '10.2.0.0/16'))
    assert_equal(@rib.view.json(:rib), @rib.view.json)
    assert_equal(['10.1.0.0/16'],
                 JSON.parse(@rib.view.json(:rib, '10.1.0.0/16')).map { |r| r['prefix'] })
  end

  def test_json_can_be_asked_for_pretty
    @rib.announce(route(E1))
    assert_match(/\n/, @rib.view.json(:rib, nil, :pretty => true))
    assert_no_match(/\n/, @rib.view.json(:rib))
  end

  # json is required inside View#json and not at the top of the file, so
  # that a Ruby where it is a bundled gem rather than a default one cannot
  # kill the require of the whole library. This asserts both halves in a
  # fresh process, since this one has json loaded already: requiring
  # bgp/rib does not load it, and asking for JSON works anyway.
  #
  # The shape is common_test.rb's and observable_test.rb's.
  def test_the_json_require_is_not_at_the_top_of_the_file
    code = <<~RUBY
      require 'bgp/rib'
      print defined?(::JSON) ? 'loaded' : 'absent'
      rib = BGP::Rib.new(:local_as => 65001, :router_id => '1.1.1.1')
      rib.originate('10.0.0.0/8')
      print rib.view.json(:routes).include?('10.0.0.0/8') ? ' ok' : ' bad'
    RUBY
    out = IO.popen([RbConfig.ruby, '-W0', "-I#{Dir.pwd}", '-e', code],
                   :err => [:child, :out], &:read)
    assert_equal('absent ok', out)
  end

  def test_a_view_name_that_is_not_one_is_refused
    e = assert_raise(ArgumentError) { @rib.view.json(:peers) }
    assert_match(/unknown view/, e.message)
  end

  def test_status_takes_no_prefix
    e = assert_raise(ArgumentError) { @rib.view.json(:status, P) }
    assert_match(/no prefix/, e.message)
  end

  # ====================================================================
  # What Show shares with the view, so the two cannot drift.

  # Show reads prefixes, paths and usable? from here, so there is one
  # definition of the paths to a prefix and why each one lost. These three
  # answer Route objects and are not part of the JSON surface.
  def test_show_reads_its_paths_from_the_view
    rib = loss_table(:med)
    paths = rib.view.paths(P)
    assert_equal(2, paths.size)
    assert_kind_of(BGP::Rib::Route, paths.first.first)
    assert_nil(paths.first.last, 'the best path lost at nothing')
    assert_equal(:med, paths.last.last)
    assert_match(/Inactive reason: med/, rib.show(:junos, P),
                 'and Show prints that same step')
  end

  def test_usable_is_false_only_for_an_ineligible_reason
    BGP::Rib::Decision::INELIGIBLE.each { |r| assert(!@rib.view.usable?(r), r.to_s) }
    BGP::Rib::Decision::STEPS.each { |r| assert(@rib.view.usable?(r), r.to_s) }
    assert(@rib.view.usable?(nil), 'the best path')
  end

  def test_paths_of_a_prefix_with_no_best_route_is_empty
    assert_equal([], @rib.view.paths('172.16.0.0/12'))
  end

  # ====================================================================
  # The three views of another object's state: an Adj-RIB-In, a Router's
  # Adj-RIB-Outs and a Fib.

  # **The Adj-RIB-In is as received, which is what makes it worth a view
  # of its own.** RFC 4271 section 5.1.5 says a LOCAL_PREF from an
  # external peer must be ignored, and Table#import drops it, so the
  # value is in this row and nowhere else: a route the decision process
  # never saw as sent is otherwise invisible.
  def test_adj_in_answers_the_route_as_received_before_import
    @rib.announce(route(E1, P, :local_pref => 250))
    row = @rib.view.adj_in(E1.address).first
    assert_equal(P, row[:prefix])
    assert_equal(250, row[:local_pref], 'as the peer sent it')
    assert_nil(@rib.view.routes(P).first[:local_pref],
               'and import dropped it from everything downstream')
  end

  def test_adj_in_says_which_of_a_peers_paths_won
    @rib.announce(route(E1, P, :as_path => [65002]))
    @rib.announce(route(E2, P, :as_path => [65003, 65004]))
    assert_equal([true], @rib.view.adj_in(E1.address).collect { |r| r[:best] })
    assert_equal([false], @rib.view.adj_in(E2.address).collect { |r| r[:best] })
  end

  def test_adj_in_narrows_to_one_prefix_and_lists_its_prefixes_sorted
    %w[10.2.0.0/16 10.1.0.0/16].each { |pfx| @rib.announce(route(E1, pfx)) }
    assert_equal(%w[10.1.0.0/16 10.2.0.0/16], @rib.view.adj_in_prefixes(E1.address))
    assert_equal(['10.2.0.0/16'], @rib.view.adj_in('10.0.0.2', '10.2.0.0/16').collect { |r| r[:prefix] })
  end

  # **A read must not change what it reads**, and Table#adj_rib_in makes
  # an Adj-RIB-In on first use, so an address nobody ever peered with
  # would otherwise leave an empty RIB behind in the table and make that
  # peer appear in Table#peers.
  def test_asking_about_a_peer_the_table_never_saw_creates_nothing
    @rib.announce(route(E1, P))
    before = @rib.peers.size
    assert_equal([], @rib.view.adj_in('192.0.2.77'))
    assert_equal([], @rib.view.adj_in_prefixes('192.0.2.77'))
    assert_equal(before, @rib.peers.size, 'no Adj-RIB-In was created by reading one')
  end

  # **The Adj-RIB-Out carries what went out and not what the Loc-RIB
  # holds**, which is the point: the export rules rewrite AS_PATH and
  # NEXT_HOP per peer (RFC 4271 section 5.1.2 and 5.1.3), so this is the
  # only place to see what the peer was really told.
  def test_adj_out_answers_the_attributes_that_went_out
    @rib.announce(route(E2, P, :as_path => [65003]))
    advertise_to_a_peer
    row = @rib.view.adj_out('10.0.0.2').first
    assert_equal(P, row[:prefix])
    assert_equal("#{LOCAL_AS} 65003", row[:as_path], 'our AS prepended toward an external peer')
    assert_equal('10.0.0.1', row[:next_hop], 'ours, and not the one it arrived with')
    assert_equal(:igp, row[:origin])
    assert_equal([P], @rib.view.adj_out_prefixes('10.0.0.2'))
  end

  def test_adj_out_has_no_from_and_no_local_because_it_holds_no_route
    @rib.announce(route(E2, P, :as_path => [65003]))
    advertise_to_a_peer
    row = @rib.view.adj_out('10.0.0.2').first
    assert_equal(false, row.has_key?(:from))
    assert_equal(false, row.has_key?(:local))
  end

  def test_adj_out_is_empty_with_no_router_and_for_an_unknown_peer
    @rib.announce(route(E1, P))
    assert_nil(@rib.router, 'router mode is off until asked for')
    assert_equal([], @rib.view.adj_out(E1.address))
    assert_equal([], @rib.view.adj_out_prefixes(E1.address))
    advertise_to_a_peer
    assert_equal([], @rib.view.adj_out('192.0.2.77'))
  end

  # Why a prefix was not advertised, which is the answer Router#skipped
  # exists for: a route silently not advertised is the hardest kind of
  # bug to see from outside. Here the route came from the peer it would
  # go back to, which Export refuses.
  def test_skipped_says_why_a_prefix_did_not_go_to_a_peer
    @rib.announce(route(E1, P))
    advertise_to_a_peer
    rows = @rib.view.skipped('10.0.0.2')
    assert_equal([P], rows.collect { |r| r[:prefix] })
    assert_equal('back_to_sender', rows.first[:reason])
    assert_equal([], @rib.view.skipped('192.0.2.77'))
  end

  # :configured is what tells a table that installs nothing from one
  # whose forwarding table happens to be empty. Both answer no rows.
  def test_fib_says_whether_anything_is_installing_at_all
    f = @rib.view.fib
    assert_equal(false, f[:configured])
    assert_nil(f[:backend])
    assert_equal(0, f[:total])
    assert_equal([], f[:failed])
    assert_equal([], @rib.view.fib_prefixes)
    assert_equal([], @rib.view.fib_routes)
  end

  # With a backend that records instead of running a command, so no
  # kernel and no privilege is involved: the real one is
  # test/functional/lab/fib_test.rb.
  def test_fib_answers_what_it_believes_is_installed
    @rib.announce(route(E1, '10.2.0.0/16'))
    @rib.announce(route(E1, '10.1.0.0/16'))
    @rib.install(:backend => Backend.new)
    @rib.drain
    f = @rib.view.fib
    assert_equal(true, f[:configured])
    assert_equal('a recording backend', f[:backend])
    assert_equal(2, f[:total])
    assert_equal(%w[10.1.0.0/16 10.2.0.0/16], @rib.view.fib_prefixes)
    assert_equal([{ :prefix => '10.1.0.0/16', :next_hop => '10.0.0.2' }],
                 @rib.view.fib_routes('10.1.0.0/16'))
  end

  def test_fib_names_what_the_kernel_refused
    @rib.announce(route(E1, P))
    @rib.install(:backend => Backend.new(:fail => true))
    @rib.drain
    f = @rib.view.fib
    assert_equal(0, f[:total], 'an install that failed is not believed')
    assert_equal([P], f[:failed].collect { |r| r[:prefix] })
    assert_match(/refused/, f[:failed].first[:error])
  end

  # A backend that records an operation rather than running it. Its own
  # Result shape is what FibInstaller#apply reads: ok? and to_s.
  class Backend
    Result = Struct.new(:ok, :text) do
      def ok? ; ok ; end
      def to_s ; text ; end
    end

    def initialize(arg = {}) ; @fail = arg[:fail] ; end
    def run(_op) ; Result.new(!@fail, @fail ? 'the kernel refused it' : 'ok') ; end
    def flush(_arg = {}) ; Result.new(true, 'ok') ; end
    def to_s ; 'a recording backend' ; end
  end

end
