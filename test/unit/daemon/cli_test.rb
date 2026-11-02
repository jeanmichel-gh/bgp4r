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

# bgp4r-cli's two forms, against a client that answers from a Hash. The
# class takes its output IOs and its client, as BGP::Capture::CLI takes
# its IOs, so a test reads a String rather than capturing a process.
#
#   ruby -I. test/unit/daemon/cli_test.rb

require 'test/unit'
require 'json'
require 'stringio'
require 'bgp/daemon/cli'

class BGP_Daemon_CLI_Test < Test::Unit::TestCase

  # A Client that answers from a Hash and records what it was asked.
  class FakeClient
    attr_reader :calls

    def initialize(answers = {})
      @answers = answers
      @calls = []
      @closed = false
    end

    def call(method, params = {})
      @calls << [method, params]
      raise BGP::Daemon::Client::Error, "unknown method #{method.inspect}" unless @answers.key?(method)
      @answers[method]
    end

    def close ; @closed = true ; end
    def closed? ; @closed ; end
  end

  STATUS = { 'router_id' => '10.0.0.1', 'as' => 65_000,
             'summary' => { 'peers' => 2, 'established' => 1, 'rib' => 7 },
             'peers' => [{ 'address' => '10.0.0.2', 'remote_as' => 65_001, 'state' => 'established',
                           'description' => 'inj1', 'uptime' => 380, 'received' => 4, 'sent' => 2 },
                         { 'address' => '10.0.0.3', 'remote_as' => 65_000, 'state' => 'idle',
                           'description' => nil, 'uptime' => nil, 'received' => 0, 'sent' => 0 }] }.freeze

  ANSWERS = { 'show.status' => STATUS,
              'show.peers'  => STATUS['peers'],
              'show.text'   => "a table\n",
              'show.rib'    => { 'rows' => [], 'total' => 0 } }.freeze

  def run_cli(argv, answers = ANSWERS, env = {})
    out, err = StringIO.new, StringIO.new
    client = FakeClient.new(answers)
    status = BGP::Daemon::CLI.new(out, err, client).start(argv, env)
    [status, out.string, err.string, client]
  end

  # The method form: a method name and optional JSON, answered as JSON,
  # which is what a script and a driver read.
  def test_a_method_prints_its_result_as_json
    status, out, err, client = run_cli(['show.peers'])
    assert_equal(0, status)
    assert_equal('', err)
    assert_equal([['show.peers', {}]], client.calls)
    assert_equal(STATUS['peers'], JSON.parse(out))
  end

  def test_a_method_takes_its_parameters_as_one_json_object
    _s, _o, _e, client = run_cli(['show.rib', '{"prefix":"10.0.0.0/8"}'])
    assert_equal([['show.rib', { 'prefix' => '10.0.0.0/8' }]], client.calls)
  end

  def test_pretty_indents_the_json
    _s, plain, = run_cli(['show.status'])
    _s, pretty, = run_cli(['show.status', '--pretty'])
    assert_equal(JSON.parse(plain), JSON.parse(pretty))
    assert_operator(pretty.lines.size, :>, plain.lines.size)
  end

  def test_parameters_that_are_not_json_say_so
    status, out, err = run_cli(['show.rib', '{nope'])
    assert_equal(1, status)
    assert_equal('', out)
    assert_match(/not JSON/, err)
  end

  def test_parameters_that_are_not_an_object_say_so
    status, _o, err = run_cli(['show.rib', '[1,2]'])
    assert_equal(1, status)
    assert_match(/JSON object/, err)
  end

  # The daemon's own refusal reaches the person, rather than a backtrace.
  def test_the_daemons_error_is_printed_and_the_status_is_one
    status, out, err = run_cli(['show.nonsense'])
    assert_equal(1, status)
    assert_equal('', out)
    assert_match(/unknown method "show\.nonsense"/, err)
  end

  # The text form. `show bgp` and `show bgp PREFIX` ask the daemon for
  # the text, because bgp/rib/show.rb takes a Rib::Table and the Table is
  # in the daemon: a second renderer here would be two copies of three
  # vendor styles.
  def test_show_bgp_asks_the_daemon_for_the_text
    status, out, _e, client = run_cli(['-c', 'show bgp'])
    assert_equal(0, status)
    assert_equal("a table\n", out)
    assert_equal([['show.text', { 'style' => 'ios' }]], client.calls)
  end

  def test_show_bgp_prefix_passes_the_prefix
    _s, _o, _e, client = run_cli(['-c', 'show bgp 10.0.0.0/8'])
    assert_equal([['show.text', { 'style' => 'ios', 'prefix' => '10.0.0.0/8' }]], client.calls)
  end

  def test_the_style_switches_which_one_the_daemon_renders
    _s, _o, _e, client = run_cli(['-c', 'show bgp', '--style', 'junos'])
    assert_equal([['show.text', { 'style' => 'junos' }]], client.calls)
  end

  def test_an_unknown_style_is_refused_with_the_usage
    status, _o, err = run_cli(['-c', 'show bgp', '--style', 'cisco'])
    assert_equal(1, status)
    assert_match(/Usage: bgp4r-cli/, err)
  end

  # `show bgp summary` is rendered here, because bgp/rib/show.rb has no
  # summary form at all: there is no vendor sample behind one. The
  # columns are this file's own, so this asserts the numbers and the
  # peers and not the layout.
  def test_show_bgp_summary_prints_the_router_and_a_row_per_peer
    status, out, _e, client = run_cli(['-c', 'show bgp summary'])
    assert_equal(0, status)
    assert_equal([['show.status', {}]], client.calls)
    assert_match(/10\.0\.0\.1/, out)
    assert_match(/65000/, out)
    assert_match(/1 established/, out)
    assert_match(/^10\.0\.0\.2\s+65001\s+established\s+380s\s+4\s+2 inj1$/, out)
    assert_match(/^10\.0\.0\.3\s+65000\s+idle\s+never\s+0\s+0/, out)
  end

  def test_an_unknown_command_names_the_ones_there_are
    status, _o, err = run_cli(['-c', 'show everything'])
    assert_equal(1, status)
    BGP::Daemon::CLI::COMMANDS.each { |c| assert_match(/#{Regexp.escape(c)}/, err) }
  end

  # Extra spaces are a person typing, not an error.
  def test_a_command_is_read_past_its_spacing
    _s, _o, _e, client = run_cli(['-c', '  show   bgp  summary '])
    assert_equal([['show.status', {}]], client.calls)
  end

  def test_the_two_forms_are_not_mixed
    status, _o, err = run_cli(['-c', 'show bgp', 'show.peers'])
    assert_equal(1, status)
    assert_match(/Usage: bgp4r-cli/, err)
  end

  def test_no_arguments_is_the_usage_and_a_failure
    status, out, err = run_cli([])
    assert_equal(1, status)
    assert_equal('', out)
    assert_match(/Usage: bgp4r-cli/, err)
  end

  def test_help_is_the_usage_and_a_success
    status, out, err = run_cli(['--help'])
    assert_equal(0, status)
    assert_equal('', err)
    assert_match(/Usage: bgp4r-cli/, out)
    assert_match(/show\.rib/, out)
  end

  def test_version_prints_the_library_version_and_nothing_else
    status, out, err = run_cli(['--version'])
    assert_equal(0, status)
    assert_equal('', err)
    assert_equal("#{BGP::VERSION}\n", out)
  end

  # Every connection is closed, however the command ended, so a client
  # run in a loop does not leak one per call.
  def test_the_connection_is_closed_whatever_happened
    [['show.peers'], ['show.nonsense'], ['-c', 'show bgp summary']].each do |argv|
      _s, _o, _e, client = run_cli(argv)
      assert_equal(true, client.closed?, "#{argv.inspect} must close its connection")
    end
  end

end

