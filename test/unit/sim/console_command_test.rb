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


# `bgp4r console`'s command line, with no session and no irb:
# test/functional/console_test.rb runs the program.
#
#   ruby -I. test/unit/sim/console_command_test.rb

require 'test/unit'
require 'stringio'
require 'bgp4r'
require 'bgp/sim/console_command'
require 'bgp/sim/routegen'

class BGP_Sim_ConsoleCommand_Test < Test::Unit::TestCase

  # What the command does with the Console it builds.
  class FakeConsole
    attr_reader :connects
    def initialize ; @connects = [] ; end
    def connect(addr, **kw) ; @connects << [addr, kw] ; { :address => addr, :state => @state || 'Established' } ; end
    def stop ; @stopped = true ; end
    def stopped? ; @stopped ; end
    attr_writer :state
  end

  # **No test here may reach irb**: it reads standard input, so a refusal
  # that fell through to it would hang the suite. The prompt is a lambda
  # that records, and the log goes nowhere.
  def setup
    @out = StringIO.new
    @err = StringIO.new
    @fake = FakeConsole.new
    @prompts = []
    @cmd = BGP::Sim::ConsoleCommand.new(@out, @err,
                                        :console => -> { @fake },
                                        :interact => ->(c) { @prompts << c },
                                        :load_irb => false)
  end

  def teardown
    Log.set_filename(STDERR)
  end

  def test_no_peer_opens_the_prompt_on_no_session
    assert_equal(0, @cmd.start(['-l', File::NULL]))
    assert_equal([@fake], @prompts)
    assert_empty(@fake.connects)
    assert(@fake.stopped?, 'exit stops what the prompt opened')
  end

  def test_peer_connects_before_the_prompt
    assert_equal(0, @cmd.start(['--peer', '10.0.0.2', '--peer-as', '65002', '-l', File::NULL]))
    assert_equal([['10.0.0.2', { :remote_as => 65_002, :local_as => 65_001,
                                 :router_id => '10.0.0.1', :wait => 30.0 }]], @fake.connects)
    assert_match(/session to 10\.0\.0\.2 is established$/, @out.string)
    assert_equal([@fake], @prompts)
  end

  def test_a_session_not_up_still_opens_the_prompt
    @fake.state = 'Active'
    assert_equal(0, @cmd.start(['--peer', '10.0.0.2', '--peer-as', '65002', '-l', File::NULL]))
    assert_match(/session to 10\.0\.0\.2 is active, still trying/, @out.string)
    assert_equal(1, @prompts.size)
  end

  def test_the_log_goes_to_a_file_it_names_unless_l_says
    @cmd.start([])
    assert_match(%r{console: logging to .*bgp4r-console-\d+\.log}, @out.string)
  ensure
    path = @out.string[/logging to (\S+)/, 1]
    File.delete(path) if path && File.exist?(path)
  end

  def test_help
    assert_equal(0, @cmd.start(['--help']))
    assert_match(/^Usage: bgp4r console/, @out.string)
    assert_equal('', @err.string)
  end

  # Every flag the parser takes is in the usage, so the two cannot drift.
  def test_the_usage_names_every_flag
    src = File.read(File.expand_path('../../../bgp/sim/console_command.rb', __dir__))
    flags = src.scan(/o\.on\((?:'-\w', )?'(--[\w-]+)/).flatten
    assert_operator(flags.size, :>=, 10)
    flags.each { |f| assert_match(/^\s+(-\w, )?#{f}\b/, BGP::Sim::ConsoleCommand::USAGE, f) }
  end

  def test_no_peer_means_no_session
    assert_nil(@cmd.connect_args({}))
  end

  def test_peer_and_peer_as_go_together
    assert_equal(1, @cmd.start(['--peer-as', '100']))
    assert_match(/--peer-as needs --peer/, @err.string)
    assert_equal(1, @cmd.start(['--peer', '10.0.0.2']))
    assert_match(/--peer needs --peer-as/, @err.string)
    assert_nil(@cmd.console, 'no console was built on a bad flag')
    assert_empty(@prompts, 'no prompt opened on a bad flag')
  end

  def test_a_word_where_a_number_goes_is_refused
    assert_equal(1, @cmd.start(['--peer', '10.0.0.2', '--peer-as', 'abc']))
    assert_match(/invalid value for Integer/, @err.string)
  end

  def test_an_unexpected_argument_is_refused
    assert_equal(1, @cmd.start(['10.0.0.2']))
    assert_match(/unexpected 10\.0\.0\.2/, @err.string)
  end

  def test_an_unknown_flag_is_refused
    assert_equal(1, @cmd.start(['--count', '3']))
    assert_match(/invalid option: --count/, @err.string)
  end

  def test_the_flags_become_connect_arguments
    addr, kw = @cmd.connect_args(:peer => '10.0.0.2', :peer_as => '65002', :my_as => '65010',
                                 :id => '10.9.9.9', :port => '1179', :local_address => '10.0.0.1',
                                 :timeout => '5')
    assert_equal('10.0.0.2', addr)
    assert_equal({ :remote_as => 65_002, :local_as => 65_010, :router_id => '10.9.9.9',
                   :wait => 5.0, :port => 1179, :local_address => '10.0.0.1' }, kw)
  end

  # The console and routegen open a session with the same defaults, so
  # `routegen --interact` and `console --peer` are the same session.
  def test_the_defaults_are_routegens
    _, kw = @cmd.connect_args(:peer => '10.0.0.2', :peer_as => '65002')
    assert_equal(BGP::Sim::Routegen::DEFAULT_AS, kw[:local_as])
    assert_equal(BGP::Sim::Routegen::DEFAULT_ID, kw[:router_id])
    assert_equal(BGP::Sim::ConsoleCommand::DEFAULT_TIMEOUT, kw[:wait])
    assert_equal(BGP::Sim::Routegen::DEFAULT_AS, BGP::Sim::Console::DEFAULT_AS)
    assert_equal(BGP::Sim::Routegen::DEFAULT_ID, BGP::Sim::Console::DEFAULT_ID)
  end

end
