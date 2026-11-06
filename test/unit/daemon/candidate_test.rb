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

# `bgp/daemon/candidate.rb`: the candidate configuration and what a
# commit does with it.
#
#   ruby -I. test/unit/daemon/candidate_test.rb
#
# **The answer shapes are routescope's and not this file's**, read in
# `Drivers::Ospfd` at routescope `7eabde1`: `config.changed` is a bare
# boolean, `config.compare` an Array of lines, `config.replace` a Hash
# with an `errors` key, and `config.commit` one with `ok`, `errors`,
# `warnings` and `changes`. A driver reads each of those directly, so a
# wrong shape here is a wrong answer in a console rather than a missing
# one, and that is what the first tests assert.
#
# It opens no socket and dials nothing: a Speaker with one passive
# neighbor nobody connects to is enough to bounce a session that was
# never up and to watch a table originate.

require 'test/unit'
require 'stringio'
require 'tmpdir'
require 'bgp/daemon'

class BGP_Daemon_Candidate_Test < Test::Unit::TestCase

  # A port nothing dials. The sessions here are never established; what
  # is under test is the configuration.
  PORT = 17_921

  def setup
    Log.create(StringIO.new)
    @config = BGP::Daemon::Server.with_defaults(
      'as' => 65_000, 'router_id' => '10.0.0.1', 'log_level' => 'info',
      'listen_address' => '127.0.0.1', 'port' => PORT,
      'state_file' => File.join(Dir.tmpdir, 'bgp4r-candidate-test.json'),
      'neighbors' => [{ 'address' => '127.0.0.9', 'as' => 65_001, 'hold_time' => 30,
                        'description' => 'inj1' }],
      'originate' => [{ 'prefixes' => ['10.255.0.0/24'], 'med' => 10 }])
    @speaker = BGP::Daemon::Speaker.new(@config)
    @speaker.start
    @candidate = BGP::Daemon::Candidate.new(@speaker, @config)
  end

  def teardown
    @speaker.stop if @speaker
  end

  # ---- the shapes a driver reads ----

  def test_changed_is_a_boolean_and_not_a_hash
    assert_equal(false, @candidate.changed?)
    @candidate.load('lines' => ['set neighbors 127.0.0.9 hold_time 60'])
    assert_equal(true, @candidate.changed?)
  end

  def test_compare_is_an_array_of_lines
    @candidate.load('lines' => ['set neighbors 127.0.0.9 hold_time 60'])
    assert_equal(['set neighbors 127.0.0.9 hold_time 60'], @candidate.compare)
  end

  def test_replace_answers_errors_and_an_empty_array_is_success
    r = @candidate.replace('lines' => BGP::Daemon::Config.to_set(@config))
    assert_equal({ :errors => [] }, r)
    assert_equal(false, @candidate.changed?)
  end

  def test_commit_answers_the_four_keys
    @candidate.load('lines' => ['set neighbors 127.0.0.9 description two'])
    r = @candidate.commit('check' => true)
    assert_equal([:ok, :errors, :warnings, :changes].sort, r.keys.sort)
    assert_equal(true, r[:ok])
    assert_kind_of(Array, r[:changes])
  end

  def test_configuration_answers_set_lines_when_asked_and_yaml_otherwise
    require 'yaml'
    text = @candidate.configuration('format' => 'set')
    assert_match(/^set router_id 10\.0\.0\.1$/, text)
    assert_equal(@config['as'], YAML.safe_load(@candidate.configuration)['as'])
  end

  def test_configuration_answers_the_candidate_when_asked
    @candidate.load('lines' => ['set neighbors 127.0.0.9 description two'])
    assert_match(/description inj1/, @candidate.configuration('format' => 'set'))
    assert_match(/description two/,
                 @candidate.configuration('format' => 'set', 'candidate' => true))
  end

  # ---- replace and load ----

  # A text it cannot read leaves the candidate as it was, because a
  # half-loaded candidate is the one outcome nobody can act on.
  def test_a_text_it_cannot_read_is_errors_and_changes_nothing
    r = @candidate.replace('lines' => ['set as 65000', 'nonsense'])
    assert_equal(1, r[:errors].size)
    assert_match(/line 2/, r[:errors].first)
    assert_equal(false, @candidate.changed?)
  end

  def test_load_changes_one_key_and_leaves_the_rest
    @candidate.load('lines' => ['set neighbors 127.0.0.9 hold_time 60'])
    assert_equal(['set neighbors 127.0.0.9 hold_time 60'], @candidate.compare)
  end

  def test_discard_puts_the_candidate_back
    @candidate.load('lines' => ['set neighbors 127.0.0.9 hold_time 60'])
    assert_equal({ :discarded => true, :changed => false }, @candidate.discard)
    assert_equal(false, @candidate.changed?)
  end

  def test_an_unknown_parameter_is_refused_naming_what_it_takes
    assert_raise(ArgumentError) { @candidate.commit('nonsense' => 1) }
    assert_raise(ArgumentError) { @candidate.replace('line' => []) }
    e = assert_raise(ArgumentError) { @candidate.compare('format' => 'set') }
    assert_match(/unknown parameter/, e.message)
  end

  # ---- what a commit does ----

  def test_nothing_to_commit_is_ok_and_does_nothing
    r = @candidate.commit
    assert_equal(true, r[:ok])
    assert_equal([], r[:changes])
    assert_equal([], @candidate.history)
  end

  def test_a_live_key_is_applied_and_bounces_nothing
    @candidate.load('lines' => ['set log_level debug'])
    r = @candidate.commit
    assert_equal(true, r[:ok])
    assert_equal(['log_level is debug now'], r[:warnings])
    assert_match(/DEBUG/, Log.level)
  ensure
    Log.level = Logger::INFO
  end

  def test_a_neighbors_description_is_live
    @candidate.load('lines' => ['set neighbors 127.0.0.9 description two'])
    assert_equal([], @candidate.commit('check' => true)[:warnings])
    assert_equal(true, @candidate.commit[:ok])
    assert_equal('two', @speaker.peer('127.0.0.9').description)
  end

  # The session is bounced and the warning says so, which is the channel
  # docs/daemon.md names for it.
  def test_a_bounce_key_reaches_the_peer_and_is_a_warning
    @candidate.load('lines' => ['set neighbors 127.0.0.9 hold_time 90'])
    assert_match(/will be bounced to pick up hold_time/,
                 @candidate.commit('check' => true)[:warnings].first)
    r = @candidate.commit
    assert_equal(true, r[:ok])
    assert_match(/was bounced/, r[:warnings].first)
    assert_equal(90, @speaker.peer('127.0.0.9').config['hold_time'])
    assert_equal(false, @speaker.peer('127.0.0.9').shutdown?)
  end

  # A passive peer comes back when the peer dials, which is the same
  # thing `peer.start` reports, so the notice says it rather than
  # implying the session is up again.
  def test_a_passive_peer_is_told_apart_in_the_notice
    @candidate.load('lines' => ['set neighbors 127.0.0.9 hold_time 90'])
    assert_match(/passive peer/, @candidate.commit('check' => true)[:warnings].first)
  end

  def test_an_originate_change_reaches_the_table
    @candidate.load('lines' => ['set originate 0 med 55'])
    r = @candidate.commit
    assert_equal(['originated 10.255.0.0/24'], r[:warnings])
    @speaker.rib.drain
    assert_equal([55], @speaker.rib.view.routes.map { |x| x[:med] })
  end

  def test_a_prefix_taken_out_of_originate_is_withdrawn
    @candidate.load('lines' => ['delete originate 0 prefixes',
                                'set originate 0 prefixes 10.255.9.0/24'])
    r = @candidate.commit
    @speaker.rib.drain
    assert_include(r[:warnings], 'withdrew 10.255.0.0/24')
    assert_equal(['10.255.9.0/24'], @speaker.rib.view.routes.map { |x| x[:prefix] })
  end

  # The mark is live: `route.originate` reads it from the running
  # configuration on each call, so a commit needs to do nothing else and
  # the next route made by hand carries it.
  def test_a_mark_change_is_live_and_reaches_the_next_route
    @candidate.load('lines' => ['set mark large_communities 65000:1:1'])
    r = @candidate.commit
    assert_equal(true, r[:ok], r[:errors].inspect)
    BGP::Daemon::Control.new(@speaker).route_originate('prefix' => '10.255.7.0/24')
    @speaker.rib.drain
    row = @speaker.rib.view.routes('10.255.7.0/24').first
    assert_equal(['65000:1:1'], row[:large_communities])
  end

  # The same check bgp4rd makes when it reads the file, so a commit
  # cannot put a mark in place that the next route.originate refuses.
  def test_a_mark_that_does_not_read_is_refused_by_the_commit
    @candidate.load('lines' => ['set mark large 65000:1:1'])
    r = @candidate.commit
    assert_equal(false, r[:ok])
    assert_match(/mark: unknown key\(s\) large/, r[:errors].join)
    assert_nil(@speaker.config['mark'], 'the running configuration changed')
  end

  # ---- what a commit refuses ----

  # **The commit is refused and the running configuration stays true**,
  # which is the decision the class comment argues: recording a key that
  # was not applied would make `show.configuration` describe a speaker
  # that does not exist.
  def test_a_restart_key_is_refused_and_nothing_changes
    @candidate.load('lines' => ['set router_id 9.9.9.9'])
    check = @candidate.commit('check' => true)
    assert_equal(false, check[:ok])
    assert_match(/router_id cannot change while bgp4rd runs/, check[:errors].first)
    assert_match(/restart bgp4rd/, check[:errors].first)
    r = @candidate.commit
    assert_equal(false, r[:ok])
    assert_equal('10.0.0.1', @candidate.running['router_id'])
    assert_equal('10.0.0.1', @speaker.router_id)
  end

  # Each group says **why** rather than only that it cannot, because a
  # later reader has to be able to tell whether the reason still holds.
  # One of them stopped holding and that is what this test is for: both
  # `export` and `fib` used to read "Table#on_change cannot take a
  # listener off", and that is fixed. Their reasons now differ from each
  # other, `export`'s being in the library and `fib`'s in this daemon.
  def test_every_restart_group_refuses_with_its_mechanism
    { 'set export route_reflector true' => /replacement Router starts with an empty Adj-RIB-Out/,
      'set fib table 101' => /Speaker#reconfigure does not read it/,
      'set rib false' => /built in Speaker#initialize/,
      'set as 65001' => /carries it in its OPEN/,
      'set listen_address 127.0.0.2' => /read once, when bgp4rd starts/,
      'set neighbors 127.0.0.9 record count' => /Recorder is built once/ }.each do |line, want|
      @candidate.discard
      @candidate.load('lines' => [line])
      r = @candidate.commit('check' => true)
      assert_equal(false, r[:ok], line)
      assert_match(want, r[:errors].join(' '), line)
    end
  end

  def test_a_neighbor_added_or_taken_away_is_refused
    @candidate.load('lines' => ['set neighbors 127.0.0.8 as 65002'])
    assert_match(/cannot be added while bgp4rd runs \(127\.0\.0\.8\)/,
                 @candidate.commit('check' => true)[:errors].first)
    @candidate.discard
    @candidate.load('lines' => ['delete neighbors 127.0.0.9'])
    assert_match(/cannot be taken away while bgp4rd runs \(127\.0\.0\.9\)/,
                 @candidate.commit('check' => true)[:errors].first)
  end

  # **A dry run of `Peer#new_neighbor` and not a list of rules**, so the
  # refusal is exactly what the session would have raised and carries
  # `Neighbor#capability`'s own message, which names every name there is.
  def test_a_configuration_a_session_cannot_be_built_from_is_refused
    @candidate.load('lines' => ['set neighbors 127.0.0.9 capabilities nonsense'])
    e = @candidate.commit('check' => true)[:errors].first
    assert_match(/neighbor 127\.0\.0\.9/, e)
    assert_match(/no capability is named "nonsense"/, e)
    @candidate.discard
    @candidate.load('lines' => ['delete neighbors 127.0.0.9 as'])
    assert_match(/key not found/, @candidate.commit('check' => true)[:errors].first)
  end

  # A typo in a neighbor key is refused by name, through the same
  # throwaway Peer the dry run builds, rather than only as a key that
  # cannot change while bgp4rd runs.
  def test_an_unknown_neighbor_key_is_refused_by_name
    @candidate.load('lines' => ['set neighbors 127.0.0.9 hold_tme 60'])
    errors = @candidate.commit('check' => true)[:errors]
    assert(errors.any? { |e| e =~ /neighbor 127\.0\.0\.9: unknown key\(s\) hold_tme/ },
           errors.inspect)
  end

  # A client flag becomes Export's client list, so it is restart class
  # with export's own reason rather than the generic one.
  def test_a_route_reflector_client_flag_cannot_change_while_running
    @candidate.load('lines' => ['set neighbors 127.0.0.9 route_reflector_client true'])
    errors = @candidate.commit('check' => true)[:errors]
    assert(errors.any? { |e| e =~ /route_reflector_client cannot change while bgp4rd runs: it becomes Export's client list/ },
           errors.inspect)
  end

  def test_a_log_level_no_logger_takes_is_refused
    @candidate.load('lines' => ['set log_level shouting'])
    assert_match(/log_level: log level "shouting"/,
                 @candidate.commit('check' => true)[:errors].first)
  end

  # ---- history and rollback ----

  def test_a_commit_goes_in_the_history_newest_first
    @candidate.load('lines' => ['set neighbors 127.0.0.9 description one'])
    @candidate.commit('comment' => 'first')
    @candidate.load('lines' => ['set neighbors 127.0.0.9 description two'])
    @candidate.commit('comment' => 'second')
    h = @candidate.history
    assert_equal(%w[second first], h.map { |c| c[:comment] })
    assert_equal([1, 1], h.map { |c| c[:changes] })
    assert_match(/\A\d{4}-\d\d-\d\dT/, h.first[:time])
  end

  # `history[i]` describes rollback `i`, which is what
  # `Drivers::Ospfd#rollbacks` relies on when it labels each row with its
  # index. So rollback 0 is the running configuration and rollback 1 is
  # what was running before the newest commit.
  def test_rollback_zero_is_the_running_configuration
    @candidate.load('lines' => ['set neighbors 127.0.0.9 description one'])
    @candidate.commit
    @candidate.load('lines' => ['set neighbors 127.0.0.9 description two'])
    assert_equal({ :rollback => 0, :changed => false }, @candidate.rollback)
    assert_equal(false, @candidate.changed?)
  end

  def test_rollback_one_is_what_was_running_before_the_last_commit
    @candidate.load('lines' => ['set neighbors 127.0.0.9 description one'])
    @candidate.commit
    assert_equal({ :rollback => 1, :changed => true }, @candidate.rollback('number' => 1))
    assert_equal(['set neighbors 127.0.0.9 description inj1'], @candidate.compare)
    # And it is a candidate like any other, so it has to be committed.
    assert_equal(true, @candidate.commit[:ok])
    assert_equal('inj1', @speaker.peer('127.0.0.9').description)
  end

  def test_a_rollback_that_does_not_exist_is_refused_naming_what_does
    e = assert_raise(ArgumentError) { @candidate.rollback('number' => 7) }
    assert_match(/rollback 7 does not exist/, e.message)
    assert_match(/only 0, the running configuration/, e.message)
  end

  def test_the_oldest_rollback_is_the_file_as_it_was_read
    3.times do |i|
      @candidate.load('lines' => ["set neighbors 127.0.0.9 description d#{i}"])
      @candidate.commit
    end
    assert_equal(3, @candidate.history.size)
    @candidate.rollback('number' => 3)
    assert_match(/description inj1/,
                 @candidate.configuration('format' => 'set', 'candidate' => true))
  end

  def test_the_history_is_bounded
    keep = BGP::Daemon::Candidate::ROLLBACKS
    (keep + 3).times do |i|
      @candidate.load('lines' => ["set neighbors 127.0.0.9 description d#{i}"])
      @candidate.commit
    end
    assert_equal(keep, @candidate.history.size)
    assert_raise(ArgumentError) { @candidate.rollback('number' => keep + 1) }
  end

  # ---- the classification itself ----

  def test_every_key_of_the_node_file_is_classified
    e = BGP::Daemon::Candidate::Plan
    assert_equal(BGP::Daemon::Candidate::LIVE, e.effect(%w[log_level]))
    assert_equal(BGP::Daemon::Candidate::LIVE, e.effect(%w[originate 0 med]))
    assert_equal(BGP::Daemon::Candidate::LIVE, e.effect(%w[neighbors 1.1.1.1 description]))
    assert_equal(BGP::Daemon::Candidate::BOUNCE_ALL, e.effect(%w[announce 0 prefixes]))
    BGP::Daemon::Candidate::NEIGHBOR_BOUNCE_KEYS.each do |k|
      assert_equal(BGP::Daemon::Candidate::BOUNCE, e.effect(['neighbors', '1.1.1.1', k]), k)
    end
    %w[router_id as rib socket state_file listen_address port local_address].each do |k|
      assert_equal(BGP::Daemon::Candidate::RESTART, e.effect([k]), k)
    end
    assert_equal(BGP::Daemon::Candidate::RESTART, e.effect(%w[export mrai ebgp]))
    assert_equal(BGP::Daemon::Candidate::RESTART, e.effect(%w[fib table]))
    assert_equal(BGP::Daemon::Candidate::RESTART, e.effect(%w[neighbors 1.1.1.1 record]))
  end

  # A key nobody has thought of is restart class, which is the safe
  # default: it refuses rather than claiming to have applied something.
  def test_a_key_nobody_classified_is_restart_class
    assert_equal(BGP::Daemon::Candidate::RESTART,
                 BGP::Daemon::Candidate::Plan.effect(%w[something_new]))
  end

end
