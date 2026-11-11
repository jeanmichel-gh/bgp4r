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

# bgp4r-cli's operator commands and prompt, against a client that
# answers from a Hash. docs/design/bgp4r-cli-shell.md is the design.
# cli_test.rb holds what each command prints; this file holds how a
# line is read: abbreviations, `?` and `help`, completion, the loop.
#
#   ruby -I. test/unit/daemon/shell_test.rb

require 'test/unit'
require 'stringio'
require 'json'
require 'bgp/daemon/shell'

class BGP_Daemon_Shell_Test < Test::Unit::TestCase
  Shell = BGP::Daemon::Shell

  class FakeClient
    attr_reader :calls, :closes

    def initialize(answers)
      @answers = answers
      @calls = []
      @closes = 0
    end

    def call(method, params = {})
      @calls << [method, params]
      raise BGP::Daemon::Client::Error, "unknown method #{method.inspect}" unless @answers.key?(method)
      @answers[method]
    end

    def close ; @closes += 1 ; end

    # A stream: the result line, an event, a keepalive, then what
    # `then_` says: :end, or :interrupt for Ctrl-C.
    attr_accessor :then_
    attr_reader :streams, :unsubscribes

    def stream(method, params = {})
      (@streams ||= []) << [method, params]
      [{ 'id' => 1, 'result' => { 'seq' => 0 } },
       { 'event' => { 'seq' => 1, 'time' => '2026-11-11T03:58:53.215Z', 'kind' => 'session',
                      'peer' => '10.2.0.2', 'message' => 'OpenConfirm -> Established' } },
       { 'keepalive' => 1, 'seq' => 1 }].each { |l| yield l }
      raise Interrupt if then_ == :interrupt
      nil
    end

    def unsubscribe ; @unsubscribes = (@unsubscribes || 0) + 1 ; nil ; end
  end

  ANSWERS = { 'show.text' => "a table\n",
              'show.peers' => [{ 'address' => '10.0.10.1' }, { 'address' => '10.0.20.1' }],
              'show.configuration' => "set as 65000\n",
              'peer.clear' => { 'peer' => '10.0.10.1', 'was' => 'established', 'state' => 'idle' } }.freeze

  def setup
    @client = FakeClient.new(ANSWERS)
    @shell = Shell.new(@client, :hostname => 'r1')
  end

  def run_line(line) = @shell.execute(line)

  def test_the_prompt_is_the_hostname
    assert_equal('r1> ', @shell.prompt)
  end

  # ====================================================================
  # Words

  def test_a_word_may_be_any_unique_prefix_of_a_keyword
    r = run_line('sh b')
    assert_nil(r.error)
    assert_equal("a table\n", r.text)
    run_line('sh conf c')
    assert_equal([['show.text', { 'style' => 'ios' }],
                  ['show.configuration', { 'format' => 'set', 'candidate' => true }]], @client.calls)
  end

  # Where a node takes a keyword and an argument, the keyword is tried
  # first, so `s` is the summary and a prefix is the argument.
  def test_a_keyword_wins_over_an_argument_and_anything_else_is_the_argument
    run_line('show bgp 10.0.0.0/8')
    assert_equal([['show.text', { 'style' => 'ios', 'prefix' => '10.0.0.0/8' }]], @client.calls)
    r = Shell.new(FakeClient.new({}), :hostname => 'r1').execute('sh b s')
    assert_match(/show\.status/, r.error, 'the summary asked for show.status')
  end

  def test_the_style_reaches_the_daemon
    Shell.new(@client, :style => 'iosxr').execute('show bgp')
    assert_equal([['show.text', { 'style' => 'iosxr' }]], @client.calls)
  end

  def test_an_ambiguous_prefix_names_the_choices
    grammar = Shell.kw('', '', nil, [Shell.kw('show', 'h', nil, [Shell.kw('bgp', 'h', :x), Shell.kw('bfd', 'h', :x)])])
    r = Shell.new(@client, :grammar => grammar).execute('show b')
    assert_equal('"show b" is ambiguous: bgp, bfd', r.error)
    assert_equal([], @client.calls)
  end

  # An unknown word is refused with what fits where it is, not with
  # every command: there are 37 of them.
  def test_an_unknown_word_says_what_fits_there
    assert_equal('"show everything" is not a command. After "show" comes bgp, ip, fib, link-state, ' \
                 'configuration, log', run_line('show everything').error)
    assert_match(/\A"frobnicate" is not a command. A command starts with show, clear, enable, disable, monitor, config, or is a method name with a dot/,
                 run_line('frobnicate').error)
  end

  # PEER and PREFIX are checked before anything is sent, so a word that
  # is neither is refused with what fits, not with the daemon's error.
  def test_a_word_that_is_not_an_address_is_refused_before_it_is_sent
    assert_equal('"clear bgp bob" is not a command, and "bob" is not an address. After "clear bgp" comes PEER',
                 run_line('clear bgp bob').error)
    assert_equal('"clear bgp 10.0.0.0/8" is not a command, and "10.0.0.0/8" is not an address. ' \
                 'After "clear bgp" comes PEER', run_line('clear bgp 10.0.0.0/8').error)
    assert_match(/"nonsense" is not a prefix\. After "show bgp" comes summary, neighbors, PREFIX/,
                 run_line('show bgp nonsense').error)
    assert_equal([], @client.calls)
    run_line('show bgp 2001:db8::/32')
    run_line('show bgp 10.0.0.1')
    assert_equal(%w[2001:db8::/32 10.0.0.1], @client.calls.collect { |_m, p| p['prefix'] })
  end

  def test_words_that_are_not_yet_a_command_say_how_they_go_on
    r = run_line('clear bgp')
    assert_equal('"clear bgp" is not a whole command. After it comes PEER', r.error)
    assert_equal('"show" is not a whole command. After it comes bgp, ip, fib, link-state, configuration, log',
                 run_line('show').error)
  end

  def test_the_daemons_refusal_is_an_error_and_not_an_exception
    r = Shell.new(FakeClient.new({})).execute('show fib')
    assert_equal('unknown method "show.fib"', r.error)
  end

  def test_an_empty_line_and_a_comment_do_nothing
    ['', '   ', '# a note'].each do |l|
      r = run_line(l)
      assert_equal(['', nil, nil], [r.text, r.error, r.exit], l.inspect)
    end
    assert_equal([], @client.calls)
  end

  def test_exit_and_quit_leave
    assert_equal(true, run_line('exit').exit)
    assert_equal(true, run_line(' quit ').exit)
  end

  # ====================================================================
  # `?` and `help` mean the same, at every level

  def test_question_mark_and_help_are_the_same_at_every_level
    [['?', 'help'], ['show ?', 'show help'], ['clear ?', 'clear help'],
     ['show bgp ?', 'show bgp help'], ['show configuration ?', 'sh conf help']].each do |q, h|
      a, b = run_line(q), run_line(h)
      assert_nil(a.error, q)
      assert_not_equal('', a.text, q)
      assert_equal(a.text, b.text, "#{q} and #{h}")
    end
    assert_equal([], @client.calls, 'help asks the daemon nothing')
  end

  def test_the_top_level_lists_the_groups_and_the_builtins
    text = run_line('?').text
    %w[show clear help exit quit].each { |w| assert_match(/^  #{w} /, text) }
  end

  def test_help_lists_keywords_arguments_and_cr
    text = run_line('show bgp ?').text
    assert_match(/^  summary +the router, and one line per neighbor$/, text)
    assert_match(/^  PREFIX +one prefix, in detail$/, text)
    assert_match(/^  neighbors +every neighbor, in detail$/, text)
    assert_match(/^  <cr> +run it$/, text)
    assert_equal(4, text.lines.size)
    assert_no_match(/<cr>/, run_line('clear bgp ?').text, 'clear bgp alone is not a command')
  end

  # `?` against a word lists what that word may be the start of.
  def test_a_question_mark_against_a_word_lists_what_it_starts
    assert_equal("  show  what the daemon holds\n", run_line('sh?').text)
    assert_match(/\A  configuration /, run_line('show c?').text)
    assert_match(/nothing here starts with "z"/, run_line('show z?').error)
  end

  # `help` cannot be an address, so where only an address fits it is
  # help. Where it could be the argument, as N could be anything the
  # daemon reads, it is the argument and `?` asks.
  def test_help_is_help_where_it_cannot_be_the_argument
    assert_equal(run_line('clear bgp ?').text, run_line('clear bgp help').text)
    assert_match(/^  PEER +reset the session/, run_line('clear bgp help').text)
    assert_equal([], @client.calls)
    sh = Shell.new(@client = FakeClient.new('config.rollback' => { 'rollback' => 0 }))
    sh.execute('config rollback help')
    assert_equal([['config.rollback', { 'number' => 'help' }]], @client.calls)
  end

  def test_help_after_a_whole_command_says_cr
    assert_equal("  <cr>  run it\n", run_line('show fib help').text)
  end

  # ====================================================================
  # Tab

  def test_tab_completes_keywords_and_builtins
    assert_equal(%w[show], @shell.completions('', 's'))
    assert_equal(%w[show clear enable disable monitor config help exit quit], @shell.completions('', ''))
    assert_equal(%w[configuration], @shell.completions('sh ', 'c'))
    assert_equal(%w[summary neighbors], @shell.completions('show bgp ', ''), 'a prefix is not completed')
  end

  def test_tab_completes_peers_from_the_daemon
    assert_equal(%w[10.0.10.1], @shell.completions('clear bgp ', '10.0.1'))
    assert_equal([['show.peers', {}]], @client.calls)
  end

  def test_tab_after_words_that_are_not_a_command_offers_nothing
    assert_equal([], @shell.completions('show nonsense ', ''))
    assert_equal([], Shell.new(FakeClient.new({})).completions('clear bgp ', ''), 'the daemon refused')
  end

  # ====================================================================
  # The loop, on input that is not a terminal

  def test_the_loop_prints_answers_and_errors_and_stops_at_exit
    out = StringIO.new
    @shell.interactive(StringIO.new("show bgp\nshow nonsense\nclear ?\nexit\nshow bgp\n"), out)
    lines = out.string.lines
    assert_equal("a table\n", lines[0])
    assert_match(/\A% "show nonsense" is not a command\. After "show" comes /, lines[1])
    assert_match(/\A  bgp +a BGP session$/, lines[2])
    assert_match(/\A  ip +the IOS form/, lines[3])
    assert_equal(4, lines.size, 'nothing after exit runs')
    assert_equal(1, @client.calls.size)
  end

  # After an error the connection is dropped and the next command opens
  # a new one, so a reply that never came cannot answer the next call.
  def test_an_error_drops_the_connection
    @shell.interactive(StringIO.new("show nonsense\n"), StringIO.new)
    assert_equal(1, @client.closes)
  end

  def test_the_loop_ends_at_the_end_of_input
    out = StringIO.new
    @shell.interactive(StringIO.new("show bgp\n"), out)
    assert_equal("a table\n", out.string)
  end

  # Ctrl-C stops the command, not the prompt.
  def test_an_interrupt_drops_the_connection_and_the_prompt_goes_on
    input = StringIO.new("show bgp\nshow bgp\n")
    first = true
    input.define_singleton_method(:gets) do |*a|
      if first
        first = false
        raise Interrupt
      end
      super(*a)
    end
    out = StringIO.new
    @shell.interactive(input, out)
    assert_equal(1, @client.closes)
    assert_equal("\na table\na table\n", out.string)
  end

  # ====================================================================
  # config: docs/design/bgp4r-cli-shell.md section 4a

  def config_shell(answers)
    @client = FakeClient.new(answers)
    Shell.new(@client)
  end

  # A set or delete line goes to the daemon as typed, all its words, for
  # bgp/daemon/config.rb to read. It prints nothing when it works.
  def test_config_set_and_delete_load_one_line_each
    sh = config_shell('config.load' => { 'errors' => [] })
    r = sh.execute('config set neighbors 10.0.10.1 hold_time 60')
    assert_equal(['', nil], [r.text, r.error])
    sh.execute('conf del neighbors 10.0.10.1 hold_time')
    assert_equal([['config.load', { 'lines' => ['set neighbors 10.0.10.1 hold_time 60'] }],
                  ['config.load', { 'lines' => ['delete neighbors 10.0.10.1 hold_time'] }]], @client.calls)
  end

  def test_config_set_refused_by_the_daemon_is_an_error
    sh = config_shell('config.load' => { 'errors' => ['line 1: unknown key "nope"'] })
    assert_equal('line 1: unknown key "nope"', sh.execute('config set nope 1').error)
  end

  # After set, the words are the line's, so `help` and keywords are
  # words of the line and `?` is the way to ask.
  def test_words_after_set_are_the_line_even_help_and_keywords
    sh = config_shell('config.load' => { 'errors' => [] })
    sh.execute('config set description show help')
    assert_equal([['config.load', { 'lines' => ['set description show help'] }]], @client.calls)
    assert_match(/^  PATH\.\.\. VALUE +as in show configuration/, sh.execute('config set ?').text)
    assert_match(/^  PATH\.\.\. VALUE +more words$/, sh.execute('config set neighbors ?').text)
    assert_match(/^  <cr> +run it$/, sh.execute('config set neighbors ?').text)
  end

  def test_config_set_with_nothing_after_it_is_not_a_whole_command
    sh = config_shell({})
    assert_equal('"config set" is not a whole command. After it comes PATH... VALUE',
                 sh.execute('config set').error)
    assert_equal([], @client.calls)
  end

  def test_config_compare_prints_the_lines_or_says_there_are_none
    assert_equal("set as 65001\n", config_shell('config.compare' => ['set as 65001']).execute('config compare').text)
    assert_match(/\ANo changes/, config_shell('config.compare' => []).execute('config compare').text)
  end

  def test_config_check_asks_for_a_check_and_prints_what_a_commit_would_do
    sh = config_shell('config.commit' => { 'ok' => true, 'errors' => [],
                                           'warnings' => ['the session with 10.0.10.1 will be bounced'],
                                           'changes' => ['set neighbors 10.0.10.1 hold_time 60'] })
    r = sh.execute('config check')
    assert_equal([['config.commit', { 'check' => true }]], @client.calls)
    assert_equal("Check passed: 1 change(s) to commit.\n  set neighbors 10.0.10.1 hold_time 60\n" \
                 "Note: the session with 10.0.10.1 will be bounced\n", r.text)
  end

  # A commit the daemon refuses is an error, so -c answers status 1.
  def test_a_refused_commit_is_an_error
    sh = config_shell('config.commit' => { 'ok' => false, 'errors' => ['as needs a restart'],
                                           'warnings' => [], 'changes' => [] })
    assert_equal('commit refused: as needs a restart', sh.execute('config check').error)
    assert_equal('commit refused: as needs a restart', sh.execute('config commit').error)
  end

  def test_config_commit_takes_a_comment_of_many_words
    sh = config_shell('config.commit' => { 'ok' => true, 'errors' => [], 'warnings' => [],
                                           'changes' => ['set as 65001'] })
    r = sh.execute('config commit comment hold time 60')
    sh.execute('config commit')
    assert_equal([['config.commit', { 'comment' => 'hold time 60' }], ['config.commit', {}]], @client.calls)
    assert_equal("Committed 1 change(s).\n  set as 65001\n", r.text)
  end

  def test_config_commit_with_nothing_to_commit_says_so
    sh = config_shell('config.commit' => { 'ok' => true, 'errors' => [], 'warnings' => [], 'changes' => [] })
    assert_match(/\ANothing to commit/, sh.execute('config commit').text)
  end

  def test_config_discard
    sh = config_shell('config.discard' => { 'discarded' => true, 'changed' => false })
    assert_match(/\ADiscarded/, sh.execute('config discard').text)
    assert_equal([['config.discard', {}]], @client.calls)
  end

  # Row i of config.history is rollback i, so the rows are numbered
  # from 0.
  def test_config_history_numbers_the_rows_as_rollback_takes_them
    rows = [{ 'time' => '2026-11-02T03:18:31.004Z', 'comment' => 'hold time', 'changes' => 1 },
            { 'time' => '2026-11-01T10:00:00.000Z', 'comment' => nil, 'changes' => 3 }]
    text = config_shell('config.history' => rows).execute('config history').text
    assert_match(/^# +Time +Changes +Comment$/, text)
    assert_match(/^0 +2026-11-02T03:18:31\.004Z +1 +hold time$/, text)
    assert_match(/^1 +2026-11-01T10:00:00\.000Z +3$/, text)
    assert_equal("No commits yet.\n", config_shell('config.history' => []).execute('config history').text)
  end

  def test_config_rollback_sends_a_number
    sh = config_shell('config.rollback' => { 'rollback' => 1, 'changed' => true })
    r = sh.execute('config rollback 1')
    assert_equal([['config.rollback', { 'number' => 1 }]], @client.calls)
    assert_match(/\ARollback 1 is the candidate now: it differs/, r.text)
  end

  # What is not a number is the daemon's to refuse, so its message names
  # what was typed.
  def test_config_rollback_passes_what_is_not_a_number_as_typed
    sh = config_shell('config.rollback' => { 'rollback' => 0, 'changed' => false })
    sh.execute('config rollback x')
    assert_equal([['config.rollback', { 'number' => 'x' }]], @client.calls)
  end

  def test_config_show_is_show_configuration
    sh = config_shell('show.configuration' => "set as 65000\n")
    assert_equal("set as 65000\n", sh.execute('config show').text)
    sh.execute('config show candidate')
    assert_equal([['show.configuration', { 'format' => 'set' }],
                  ['show.configuration', { 'format' => 'set', 'candidate' => true }]], @client.calls)
  end

  # `config` brings words that share a start, so a prefix can be
  # ambiguous now, where the step 1 table had none.
  def test_prefixes_that_config_makes_ambiguous_name_the_choices
    sh = config_shell({})
    assert_equal('"c" is ambiguous: clear, config', sh.execute('c bgp 10.0.10.1').error)
    assert_equal('"config co" is ambiguous: compare, commit', sh.execute('config co').error)
    assert_equal('"config s" is ambiguous: show, set', sh.execute('config s').error)
    assert_equal([], @client.calls)
  end

  def test_config_help_and_question_mark_list_the_config_commands
    sh = config_shell({})
    text = sh.execute('config ?').text
    assert_equal(text, sh.execute('config help').text)
    %w[show set delete compare check commit discard history rollback].each do |w|
      assert_match(/^  #{w} /, text)
    end
  end

  # ====================================================================
  # show ip bgp, the IOS form, is show bgp

  def test_show_ip_bgp_is_show_bgp
    %w[show\ ip\ bgp sh\ ip\ b show\ ip\ bgp\ 10.0.0.0/8].each { |l| assert_nil(run_line(l).error, l) }
    assert_equal([['show.text', { 'style' => 'ios' }], ['show.text', { 'style' => 'ios' }],
                  ['show.text', { 'style' => 'ios', 'prefix' => '10.0.0.0/8' }]], @client.calls)
    assert_equal(run_line('show bgp ?').text, run_line('show ip bgp ?').text)
    assert_equal(run_line('clear bgp ?').text, run_line('clear ip bgp ?').text)
  end

  def test_show_ip_bgp_summary_asks_for_the_status
    r = Shell.new(@client = FakeClient.new({})).execute('show ip bgp summary')
    assert_equal('unknown method "show.status"', r.error, 'the summary asked for show.status')
  end

  # Every form the IOS words bring is in COMMANDS, so the guide lists it.
  def test_every_show_bgp_command_has_its_ip_form
    bgp = Shell::COMMANDS.grep(/\Ashow bgp/)
    assert_equal(bgp.collect { |c| c.sub('show bgp', 'show ip bgp') }, Shell::COMMANDS.grep(/\Ashow ip bgp/))
    assert_operator(bgp.size, :>=, 6)
  end

  # ====================================================================
  # Neighbors

  PEERS = [{ 'address' => '10.2.0.2', 'remote_as' => 65_100, 'type' => 'ebgp', 'state' => 'established',
             'description' => 'col', 'uptime' => 1034, 'flaps' => 0, 'held' => nil,
             'capabilities' => [{ 'name' => 'As4', 'code' => 65, 'capability' => { 'as' => 65_100 } },
                                { 'name' => 'Route_refresh', 'code' => 2 }] },
           { 'address' => '10.2.0.3', 'remote_as' => 65_000, 'type' => 'ibgp', 'state' => 'idle',
             'uptime' => nil }].freeze

  def test_show_bgp_neighbors_prints_every_field_of_every_neighbor
    text = Shell.new(FakeClient.new('show.peers' => PEERS)).execute('show bgp neighbors').text
    assert_match(/^BGP neighbor 10\.2\.0\.2, remote AS 65100, ebgp, established$/, text)
    assert_match(/^  description +col$/, text)
    assert_match(/^  uptime +1034s$/, text)
    assert_match(/^  held +-$/, text)
    assert_match(/^  capabilities +As4 as=65100, Route_refresh$/, text)
    assert_match(/^BGP neighbor 10\.2\.0\.3, remote AS 65000, ibgp, idle$/, text)
    assert_no_match(/^  (address|remote_as|type|state) /, text, 'the head line has those')
  end

  def test_show_bgp_neighbors_peer_is_that_one_and_an_unknown_one_is_refused
    sh = Shell.new(FakeClient.new('show.peers' => PEERS))
    text = sh.execute('show ip bgp neighbors 10.2.0.3').text
    assert_match(/\ABGP neighbor 10\.2\.0\.3,/, text)
    assert_no_match(/10\.2\.0\.2/, text)
    assert_equal('no neighbor "10.9.9.9" is configured; this bgp4rd has 10.2.0.2, 10.2.0.3',
                 sh.execute('show bgp neighbors 10.9.9.9').error)
  end

  ROUTE = { 'prefix' => '10.30.0.0/24', 'next_hop' => '10.2.0.2', 'as_path' => '65100 65200',
            'origin' => 'igp', 'local_pref' => 100, 'med' => 0, 'best' => true }.freeze

  # Every page is read, and `*>` marks the best path.
  def test_received_routes_reads_every_page_of_adj_in
    pages = [{ 'rows' => [ROUTE], 'next_offset' => 1 },
             { 'rows' => [ROUTE.merge('prefix' => '10.31.0.0/24', 'best' => false, 'as_path' => '',
                                      'origin' => 'incomplete', 'med' => nil)], 'next_offset' => nil }]
    client = FakeClient.new({})
    client.define_singleton_method(:call) { |m, p = {}| @calls << [m, p] ; pages.shift }
    text = Shell.new(client).execute('show bgp neighbors 10.2.0.2 received-routes').text
    assert_equal([['show.adj_in', { 'peer' => '10.2.0.2', 'offset' => 0 }],
                  ['show.adj_in', { 'peer' => '10.2.0.2', 'offset' => 1 }]], client.calls)
    assert_match(/\A2 path\(s\) received from 10\.2\.0\.2$/, text)
    assert_match(/^ +Network +Next Hop +Metric +LocPrf +Path$/, text)
    assert_match(%r{^\*> 10\.30\.0\.0/24 +10\.2\.0\.2 +0 +100 65100 65200 i$}, text)
    assert_match(%r{^\*  10\.31\.0\.0/24 +10\.2\.0\.2 +100 \?$}, text)
  end

  def test_advertised_routes_prints_what_was_not_sent_and_what_went_by_hand
    page = { 'rows' => [ROUTE], 'next_offset' => nil,
             'skipped' => { 'total' => 1, 'rows' => [{ 'prefix' => '10.40.0.0/24', 'reason' => 'no_export' }] },
             'hand' => { 'total' => 1, 'rows' => [{ 'prefix' => '10.50.0.0/24', 'verb' => 'fault',
                                                    'at' => '2026-11-11T04:00:00.000Z' }] } }
    sh = Shell.new(@client = FakeClient.new('show.adj_out' => page))
    text = sh.execute('sh ip b n 10.2.0.2 a').text
    assert_equal([['show.adj_out', { 'peer' => '10.2.0.2', 'offset' => 0 }]], @client.calls)
    assert_match(/\A1 path\(s\) advertised to 10\.2\.0\.2$/, text)
    assert_match(%r{^   10\.30\.0\.0/24 +10\.2\.0\.2 +0 +100 65100 65200 i$}, text)
    assert_match(%r{^Not advertised:\n  10\.40\.0\.0/24 +no_export$}, text)
    assert_match(%r{^Sent by hand, not in the Adj-RIB-Out:\n  10\.50\.0\.0/24 +fault +2026-11-11T04:00:00\.000Z$}, text)
  end

  # ====================================================================
  # Sessions

  def test_clear_soft_in_is_a_route_refresh
    sh = Shell.new(@client = FakeClient.new('peer.refresh' => { 'peer' => '10.2.0.2', 'afi' => 1, 'safi' => 1,
                                                                'subtype' => 0, 'sent' => true }))
    r = sh.execute('clear ip bgp 10.2.0.2 soft in')
    assert_equal([['peer.refresh', { 'peer' => '10.2.0.2' }]], @client.calls)
    assert_equal("Asked 10.2.0.2 to send its routes again (ROUTE-REFRESH, AFI 1 SAFI 1)\n", r.text)
  end

  def test_disable_and_enable_are_peer_stop_and_peer_start
    sh = Shell.new(@client = FakeClient.new(
      'peer.stop' => { 'peer' => '10.2.0.2', 'was' => 'established', 'state' => 'idle', 'shutdown' => true },
      'peer.start' => { 'peer' => '10.2.0.2', 'state' => 'idle', 'shutdown' => false, 'connect' => false }))
    assert_match(/\ADisabled 10\.2\.0\.2: was established, now idle, and it stays down/,
                 sh.execute('disable bgp 10.2.0.2').text)
    assert_equal("Enabled 10.2.0.2: now idle, and it is passive, so it comes back when the peer dials\n",
                 sh.execute('en b 10.2.0.2').text)
    assert_equal([['peer.stop', { 'peer' => '10.2.0.2' }], ['peer.start', { 'peer' => '10.2.0.2' }]], @client.calls)
  end

  def test_show_log_prints_the_lines
    sh = Shell.new(@client = FakeClient.new('show.log' => { 'lines' => %w[one two], 'kept' => 2 }))
    assert_equal("one\ntwo\n", sh.execute('show log').text)
    assert_equal('"show l" is ambiguous: link-state, log', sh.execute('show l').error)
  end

  # ====================================================================
  # Streams

  # `monitor events` prints each event on one line as it comes, and
  # neither the result line nor a keepalive.
  def test_monitor_events_prints_one_line_per_event
    out = StringIO.new
    sh = Shell.new(@client = FakeClient.new({}), :out => out)
    r = sh.execute('monitor events')
    assert_equal(['', nil], [r.text, r.error])
    assert_equal([['events.subscribe', {}]], @client.streams)
    assert_equal("Watching events. Ctrl-C stops.\n" \
                 "2026-11-11T03:58:53.215Z session 10.2.0.2 OpenConfirm -> Established\n", out.string)
  end

  # Ctrl-C ends the stream with events.unsubscribe and drops the
  # connection, and the prompt goes on.
  def test_ctrl_c_ends_a_stream_and_the_prompt_goes_on
    out = StringIO.new
    sh = Shell.new(@client = FakeClient.new(ANSWERS), :out => out)
    @client.then_ = :interrupt
    sh.interactive(StringIO.new("monitor events\nshow bgp\n"), out)
    assert_equal(1, @client.unsubscribes)
    assert_equal(1, @client.closes)
    assert_match(/Established\na table\n\z/, out.string)
  end

  # ====================================================================
  # Methods at the prompt

  def test_a_method_takes_key_value_words_and_prints_indented_json
    sh = Shell.new(@client = FakeClient.new('show.rib' => { 'rows' => [] }))
    r = sh.execute('show.rib prefix=10.0.0.0/8 limit=5 detail=true')
    assert_equal([['show.rib', { 'prefix' => '10.0.0.0/8', 'limit' => 5, 'detail' => true }]], @client.calls)
    assert_equal({ 'rows' => [] }, JSON.parse(r.text))
    assert_match(/\A\{\n  "rows"/, r.text, 'indented')
  end

  def test_a_method_takes_json_with_spaces_in_it
    sh = Shell.new(@client = FakeClient.new('route.originate' => {}))
    sh.execute('route.originate {"prefixes": ["10.255.0.0/24"], "med": 50}')
    assert_equal([['route.originate', { 'prefixes' => ['10.255.0.0/24'], 'med' => 50 }]], @client.calls)
  end

  def test_key_value_converts_numbers_booleans_null_and_json_and_keeps_the_rest
    assert_equal({ 'a' => 1, 'b' => -2, 'c' => true, 'd' => false, 'e' => nil, 'f' => [1, 2],
                   'g' => '10.0.0.1', 'h' => 'x=y' },
                 Shell.params(%w[a=1 b=-2 c=true d=false e=null f=[1,2] g=10.0.0.1 h=x=y]))
  end

  def test_a_word_that_is_not_key_value_is_refused
    r = Shell.new(@client = FakeClient.new({})).execute('peer.stop 10.0.10.1')
    assert_equal('"10.0.10.1" is not key=value', r.error)
    assert_equal('the parameters are not JSON: ' , Shell.new(@client).execute('show.rib {nope').error[0, 29])
    assert_equal([], @client.calls)
  end

  def test_a_stream_method_at_the_prompt_prints_every_line_as_json
    out = StringIO.new
    Shell.new(@client = FakeClient.new({}), :out => out).execute('events.subscribe kinds=["session"]')
    assert_equal([['events.subscribe', { 'kinds' => ['session'] }]], @client.streams)
    assert_equal(3, out.string.lines.size)
    assert_equal({ 'keepalive' => 1, 'seq' => 1 }, JSON.parse(out.string.lines[2]))
  end

  def test_the_top_level_help_names_methods
    assert_match(/^  METHOD +a method by name, as show\.peers/, run_line('?').text)
  end
end
