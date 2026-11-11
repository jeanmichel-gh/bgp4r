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

  # A Client that answers a stream: the result line, one event, and a
  # keepalive.
  class StreamingClient < FakeClient
    attr_reader :streams

    def initialize ; super ; @streams = [] ; end

    def stream(method, params = {})
      @streams << [method, params]
      [{ 'id' => 1, 'result' => { 'seq' => 0, 'replayed' => 0, 'kinds' => nil } },
       { 'event' => { 'seq' => 1, 'kind' => 'session', 'peer' => '10.0.0.2' } },
       { 'keepalive' => 1, 'seq' => 1 }].each { |line| yield line }
      nil
    end

    def unsubscribe ; nil ; end
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

  # `input` is not a terminal unless a test says so, so the suite never
  # opens a prompt when it is run from one.
  def run_cli(argv, answers = ANSWERS, env = {}, input = StringIO.new)
    out, err = StringIO.new, StringIO.new
    client = FakeClient.new(answers)
    status = BGP::Daemon::CLI.new(out, err, client, input).start(argv, env)
    [status, out.string, err.string, client]
  end

  # A StringIO that says it is a terminal, for the prompt.
  def tty(text)
    io = StringIO.new(text)
    io.define_singleton_method(:tty?) { true }
    io
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

  # ====================================================================
  # The write side

  # docs/daemon.md gives `clear bgp 10.0.10.1` as an example a person
  # types, so the command exists; the rest of the write side is the
  # method form, because `peer.stop` and `route.originate` take
  # parameters a one line grammar would have to invent a syntax for.
  def test_clear_bgp_resets_one_session
    answers = ANSWERS.merge('peer.clear' => { 'peer' => '10.0.10.1', 'was' => 'established',
                                              'state' => 'idle', 'cleared' => true })
    status, out, err, client = run_cli(['-c', 'clear bgp 10.0.10.1'], answers)
    assert_equal(0, status, err)
    assert_equal([['peer.clear', { 'peer' => '10.0.10.1' }]], client.calls)
    assert_match(/Cleared 10\.0\.10\.1: was established, now idle/, out)
  end

  def test_clear_bgp_with_no_peer_is_not_one_of_the_commands
    status, _out, err = run_cli(['-c', 'clear bgp'])
    assert_equal(1, status)
    assert_match(/clear bgp PEER/, err)
  end

  # `show fib` reads every page, so a table larger than one page prints
  # whole, and prints what was skipped and refused beside the routes.
  def test_show_fib_reads_every_page_and_prints_what_was_not_installed
    info = { 'configured' => true, 'backend' => 'ip route, table 254, proto bgp', 'total' => 2,
             'skipped' => [{ 'prefix' => '10.255.0.2/32', 'reason' => 'originated' }],
             'failed' => [{ 'prefix' => '10.9.0.0/16', 'error' => 'Nexthop has invalid gateway' }] }
    pages = [{ 'rows' => [{ 'prefix' => '10.255.0.1/32', 'next_hop' => '10.200.1.1' }],
               'next_offset' => 1, 'fib' => info },
             { 'rows' => [{ 'prefix' => '10.255.0.4/32', 'next_hop' => '10.200.4.2' }],
               'next_offset' => nil, 'fib' => info }]
    client = FakeClient.new
    client.define_singleton_method(:call) { |m, p = {}| @calls << [m, p] ; pages.shift }
    out, err = StringIO.new, StringIO.new
    status = BGP::Daemon::CLI.new(out, err, client).start(['-c', 'show fib'], {})
    assert_equal(0, status, err.string)
    assert_equal([['show.fib', { 'offset' => 0 }], ['show.fib', { 'offset' => 1 }]], client.calls)
    assert_match(/table 254, proto bgp, 2 route\(s\) installed/, out.string)
    assert_match(%r{^10\.255\.0\.1/32 +10\.200\.1\.1$}, out.string)
    assert_match(%r{^10\.255\.0\.4/32 +10\.200\.4\.2$}, out.string)
    assert_match(%r{Not installed:\n10\.255\.0\.2/32 +originated$}, out.string)
    assert_match(%r{Refused by the kernel:\n10\.9\.0\.0/16 +Nexthop has invalid gateway$}, out.string)
  end

  def test_show_fib_says_when_nothing_installs
    answers = { 'show.fib' => { 'rows' => [], 'next_offset' => nil,
                                'fib' => { 'configured' => false, 'skipped' => [], 'failed' => [] } } }
    status, out = run_cli(['-c', 'show fib'], answers)
    assert_equal(0, status)
    assert_match(/no fib: block/, out)
  end

  def test_the_commands_list_names_clear
    assert_include(BGP::Daemon::CLI::COMMANDS, 'clear bgp PEER')
  end

  # `show configuration` asks for **set lines**, where the method form
  # with no `format` answers YAML: a person typing an operator command
  # wants the form a driver diffs, one leaf per line, and the file is
  # what `bgp4r-cli show.configuration` gives them.
  def test_show_configuration_asks_for_the_set_lines
    answers = { 'show.configuration' => "set as 65000\n" }
    status, out, _e, client = run_cli(['-c', 'show configuration'], answers)
    assert_equal(0, status)
    assert_equal("set as 65000\n", out)
    assert_equal([['show.configuration', { 'format' => 'set' }]], client.calls)
  end

  def test_show_configuration_candidate_asks_for_the_candidate
    answers = { 'show.configuration' => "set as 65001\n" }
    _s, _o, _e, client = run_cli(['-c', 'show configuration candidate'], answers)
    assert_equal([['show.configuration', { 'format' => 'set', 'candidate' => true }]],
                 client.calls)
  end

  def test_the_commands_list_names_both_configuration_forms
    assert_include(BGP::Daemon::CLI::COMMANDS, 'show configuration')
    assert_include(BGP::Daemon::CLI::COMMANDS, 'show configuration candidate')
  end

  # **The client's stream list is inside the server's**, so the two
  # cannot disagree about a name. It is a list of its own because this
  # file requires only the client, so `bgp4r-cli` loads a socket and a
  # JSON parser rather than the whole library.
  def test_the_stream_list_is_inside_the_servers
    require 'bgp/daemon/api'
    BGP::Daemon::CLI::STREAMS.each do |m|
      assert_include(BGP::Daemon::Api::STREAM_METHODS, m)
    end
  end

  # A stream method prints every line as it arrives rather than one
  # result and nothing, which is what a person watching a lab wants.
  def test_a_stream_method_prints_every_line
    out, err = StringIO.new, StringIO.new
    client = StreamingClient.new
    status = BGP::Daemon::CLI.new(out, err, client).start(['events.subscribe'], {})
    assert_equal(0, status, err.string)
    assert_equal([['events.subscribe', {}]], client.streams)
    lines = out.string.lines
    assert_equal(3, lines.size)
    assert_equal(0, JSON.parse(lines[0])['result']['replayed'],
                 'the result line is printed too, so a reader sees where the stream starts')
    assert_equal('session', JSON.parse(lines[1])['event']['kind'])
    assert_equal(1, JSON.parse(lines[2])['keepalive'])
  end

  # Every connection is closed, however the command ended, so a client
  # run in a loop does not leak one per call.
  def test_the_connection_is_closed_whatever_happened
    [['show.peers'], ['show.nonsense'], ['-c', 'show bgp summary']].each do |argv|
      _s, _o, _e, client = run_cli(argv)
      assert_equal(true, client.closed?, "#{argv.inspect} must close its connection")
    end
  end

  # `show link-state` reads every page of `show.link_state` and prints
  # one line per route, with `-` for the routes this daemon sent.
  def test_show_link_state_reads_every_page_and_prints_one_line_per_route
    row = { 'type' => 'node', 'protocol_id' => 1, 'identifier' => 0, 'local' => '0000.0001.0101.00',
            'remote' => nil, 'prefix' => nil, 'name' => 'r1c1', 'flags' => ['overload'],
            'areas' => ['49.0001'], 'metric' => nil, 'since' => '2026-11-09T10:00:00.000Z' }
    pages = [{ 'rows' => [row.merge('peer' => nil)], 'next_offset' => 1 },
             { 'rows' => [row.merge('peer' => '10.2.0.1', 'type' => 'link', 'name' => nil, 'flags' => [],
                                    'areas' => [], 'remote' => '0000.0001.0102.00', 'metric' => 10)],
               'next_offset' => nil }]
    client = FakeClient.new
    client.define_singleton_method(:call) { |m, p = {}| @calls << [m, p] ; pages.shift }
    out, err = StringIO.new, StringIO.new
    status = BGP::Daemon::CLI.new(out, err, client).start(['-c', 'show link-state'], {})
    assert_equal(0, status, err.string)
    assert_equal([['show.link_state', { 'offset' => 0 }], ['show.link_state', { 'offset' => 1 }]], client.calls)
    assert_match(/^2 BGP-LS route\(s\)$/, out.string)
    assert_match(/^Peer +Type +Proto +Area +Local +Remote or prefix +Metric +Node$/, out.string)
    assert_match(/^- +node +L1 +- +0000\.0001\.0101\.00 +r1c1 overload 49\.0001$/, out.string)
    assert_match(/^10\.2\.0\.1 +link +L1 +- +0000\.0001\.0101\.00 +0000\.0001\.0102\.00 +10$/, out.string)
  end

  # OSPF rows: Proto OSPF, the area, the route type first in Node, and a
  # pseudonode as DR:address.
  def test_show_link_state_with_ospf_rows
    base = { 'peer' => '10.2.0.5', 'protocol_id' => 3, 'identifier' => 1, 'name' => nil, 'flags' => [],
             'areas' => [], 'remote' => nil, 'prefix' => nil, 'metric' => nil, 'route_type' => nil,
             'forwarding' => nil, 'since' => '2026-11-10T10:00:00.000Z' }
    rows = [base.merge('type' => 'node', 'area' => '0.0.0.1', 'local' => '10.255.0.2', 'flags' => ['abr']),
            base.merge('type' => 'link', 'area' => '0.0.0.1', 'local' => '10.255.0.3',
                       'remote' => '10.255.0.2:10.0.23.1', 'metric' => 10),
            base.merge('type' => 'prefix', 'area' => nil, 'local' => '10.255.0.3', 'prefix' => '192.0.2.0/24',
                       'metric' => 20, 'route_type' => 'external_2')]
    status, out = run_cli(['-c', 'show link-state'], 'show.link_state' => { 'rows' => rows, 'next_offset' => nil })
    assert_equal(0, status)
    assert_match(/^10\.2\.0\.5 +node +OSPF +0\.0\.0\.1 +10\.255\.0\.2 +abr$/, out)
    assert_match(/^10\.2\.0\.5 +link +OSPF +0\.0\.0\.1 +10\.255\.0\.3 +10\.255\.0\.2:10\.0\.23\.1 +10$/, out)
    assert_match(%r{^10\.2\.0\.5 +prefix +OSPF +- +10\.255\.0\.3 +192\.0\.2\.0/24 +20 external_2$}, out)
  end

  def test_show_link_state_says_when_there_is_none
    status, out = run_cli(['-c', 'show link-state'], 'show.link_state' => { 'rows' => [], 'next_offset' => nil })
    assert_equal(0, status)
    assert_equal("No BGP-LS routes.\n", out)
  end

  # ====================================================================
  # Bare words and the prompt: docs/design/bgp4r-cli-shell.md

  # The words of a command need no quotes: a first word without a dot
  # is a command, and runs as `-c` would.
  def test_bare_words_are_an_operator_command
    status, out, err, client = run_cli(%w[show bgp 10.0.0.0/8])
    assert_equal(0, status, err)
    assert_equal("a table\n", out)
    assert_equal([['show.text', { 'style' => 'ios', 'prefix' => '10.0.0.0/8' }]], client.calls)
  end

  def test_bare_words_take_the_options_around_them
    _s, _o, _e, client = run_cli(%w[--style junos sh b])
    assert_equal([['show.text', { 'style' => 'junos' }]], client.calls)
  end

  def test_bare_words_and_c_are_not_mixed
    status, _o, err = run_cli(['-c', 'show bgp', 'show', 'fib'])
    assert_equal(1, status)
    assert_match(/Usage: bgp4r-cli/, err)
  end

  def test_a_bare_command_refused_is_status_one_with_the_list
    status, out, err = run_cli(%w[show everything])
    assert_equal(1, status)
    assert_equal('', out)
    assert_match(/bgp4r-cli: "show everything" is not one of: /, err)
  end

  # `?` on the command line is help, and help is a success.
  def test_a_question_mark_on_the_command_line_lists_what_follows
    status, out, err = run_cli(%w[show ?])
    assert_equal(0, status, err)
    assert_match(/^  bgp +the Loc-RIB/, out)
    assert_match(/^  fib /, out)
  end

  # No command and no method on a terminal is the prompt; on anything
  # else it is the usage and status 1, which test_no_arguments_is_the_
  # usage_and_a_failure holds.
  def test_no_arguments_on_a_terminal_opens_the_prompt
    status, out, err, client = run_cli([], ANSWERS, {}, tty("show bgp\nexit\nshow fib\n"))
    assert_equal(0, status, err)
    assert_equal('', err)
    assert_equal("a table\n", out)
    assert_equal([['show.text', { 'style' => 'ios' }]], client.calls, 'nothing after exit runs')
    assert_equal(true, client.closed?)
  end

  # The config commands from the command line: a refused commit is
  # status 1, so a script can tell.
  def test_a_config_command_without_quotes_and_its_refusal
    answers = { 'config.load' => { 'errors' => [] },
                'config.commit' => { 'ok' => false, 'errors' => ['as needs a restart'] } }
    status, out, err, client = run_cli(%w[config set neighbors 10.0.10.1 hold_time 60], answers)
    assert_equal([0, '', ''], [status, out, err])
    assert_equal([['config.load', { 'lines' => ['set neighbors 10.0.10.1 hold_time 60'] }]], client.calls)
    status, _o, err = run_cli(['-c', 'config commit'], answers)
    assert_equal(1, status)
    assert_equal("bgp4r-cli: commit refused: as needs a restart\n", err)
  end
end
