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

  def test_an_unknown_word_lists_every_command
    r = run_line('show everything')
    assert_match(/\A"show everything" is not one of: /, r.error)
    Shell::COMMANDS.each { |c| assert_include(r.error, c) }
  end

  def test_words_that_are_not_yet_a_command_say_how_they_go_on
    r = run_line('clear bgp')
    assert_equal('"clear bgp" is not a whole command. It goes on as: clear bgp PEER', r.error)
    assert_match(/goes on as: show bgp, show bgp summary, show bgp PREFIX, show fib/, run_line('show').error)
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
    assert_match(/^  <cr> +run it$/, text)
    assert_equal(3, text.lines.size)
    assert_no_match(/<cr>/, run_line('clear bgp ?').text, 'clear bgp alone is not a command')
  end

  # `?` against a word lists what that word may be the start of.
  def test_a_question_mark_against_a_word_lists_what_it_starts
    assert_equal("  show  what the daemon holds\n", run_line('sh?').text)
    assert_match(/\A  configuration /, run_line('show c?').text)
    assert_match(/nothing here starts with "z"/, run_line('show z?').error)
  end

  # Where the grammar wants only an argument, `help` is that argument:
  # it may be a peer's name one day. `?` still asks.
  def test_help_where_only_an_argument_fits_is_the_argument
    run_line('clear bgp help')
    assert_equal([['peer.clear', { 'peer' => 'help' }]], @client.calls)
    assert_match(/^  PEER +reset the session/, run_line('clear bgp ?').text)
  end

  def test_help_after_a_whole_command_says_cr
    assert_equal("  <cr>  run it\n", run_line('show fib help').text)
  end

  # ====================================================================
  # Tab

  def test_tab_completes_keywords_and_builtins
    assert_equal(%w[show], @shell.completions('', 's'))
    assert_equal(%w[show clear help exit quit], @shell.completions('', ''))
    assert_equal(%w[configuration], @shell.completions('sh ', 'c'))
    assert_equal(%w[summary], @shell.completions('show bgp ', ''), 'a prefix is not completed')
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
    assert_match(/\A% "show nonsense" is not one of: /, lines[1])
    assert_match(/\A  bgp +a BGP session$/, lines[2])
    assert_equal(3, lines.size, 'nothing after exit runs')
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
end
