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

# The injected logger: a callable an object logs through, with the
# process-wide Log as the fallback.
#
#   ruby -I. test/unit/logging_test.rb

require 'test/unit'
require 'stringio'
require 'bgp/logging'

class BGP_Logging_Test < Test::Unit::TestCase

  # A plain object that logs, which is every class that includes the
  # module: Neighbor, Events, Daemon::Speaker, Rib::Table, Sim::Injector
  # and the two BGP::IO threads.
  class Thing
    include BGP::Logging
  end

  def setup
    @lines = []
    @thing = Thing.new
  end

  # Saved and restored the way test/unit/common_test.rb does it, since
  # @@logger is process-wide and every other test file shares it.
  def save_log_state
    [Log.class_variable_get(:@@logger),
     (Log.class_variable_get(:@@time) if Log.class_variable_defined?(:@@time))]
  end

  def restore_log_state(state)
    Log.class_variable_set(:@@logger, state[0])
    Log.class_variable_set(:@@time, state[1]) if state[1]
  end

  def collector
    ->(level, message) { @lines << [level, message] }
  end

  # ---- the callable ----

  def test_an_object_with_a_logger_calls_it
    @thing.logger = collector
    @thing.log(:info, 'a line')
    assert_equal([[:info, 'a line']], @lines)
  end

  # Every level reaches the callable, including :debug. **Filtering is the
  # logger's business and not #log's**, which is what ospfv2's ospfd does
  # in the lambda it builds and what Log.level does for the two Server
  # classes here. Filtering in both places would let a line be dropped
  # twice and enabled once.
  def test_every_level_reaches_the_callable_unfiltered
    @thing.logger = collector
    BGP::Logging::LEVELS.each { |l| @thing.log(l, "at #{l}") }
    assert_equal(BGP::Logging::LEVELS, @lines.collect(&:first))
  end

  def test_the_logger_can_be_read_and_replaced
    assert_nil(@thing.logger, 'nil until something sets one')
    first = collector
    @thing.logger = first
    assert_same(first, @thing.logger)
    @thing.logger = nil
    assert_nil(@thing.logger)
  end

  # Nothing here rescues, which ospfv2 does not either and neither do the
  # four places in this tree that already hold an injected logger. A
  # logger that raises is a bug in the program that supplied it, and a
  # rescue would hide a typo'd callable doing nothing forever.
  def test_a_logger_that_raises_is_not_swallowed
    @thing.logger = ->(_l, _m) { raise 'from the logger' }
    assert_raise(RuntimeError) { @thing.log(:info, 'a line') }
  end

  # ---- the fallback ----

  def test_an_object_with_no_logger_writes_to_the_process_log
    state = save_log_state
    io = StringIO.new
    Log.class_variable_set(:@@logger, nil)
    Log.start(io)
    Log.level = Logger::DEBUG
    BGP::Logging::LEVELS.each { |l| @thing.log(l, "line at #{l}") }
    %w[DEBUG INFO WARN ERROR FATAL].each do |name|
      assert_match(/#{name} -- : line at #{name.downcase}$/, io.string)
    end
  ensure
    restore_log_state(state)
  end

  # With no logger anywhere nothing is written and nothing breaks, which
  # is Log's own behaviour: every one of its five writers is
  # `@@logger.x(txt) unless @@logger.nil?`.
  def test_with_no_logger_and_no_process_log_nothing_raises
    state = save_log_state
    Log.class_variable_set(:@@logger, nil)
    BGP::Logging::LEVELS.each { |l| assert_nothing_raised { @thing.log(l, 'nowhere') } }
  ensure
    restore_log_state(state)
  end

  # ---- the dispatch ----

  # **A case and not Log.send(level, message)**, which is what the two
  # Server classes built before this. A send of a Symbol onto Log reaches
  # every method it has, and Log.clear deletes the log file, so a level
  # ever spelled wrong would be a destructive call rather than an error.
  def test_a_level_log_does_not_have_is_refused_and_not_sent
    state = save_log_state
    Log.class_variable_set(:@@logger, nil)
    Log.start(StringIO.new)
    assert_raise(ArgumentError) { @thing.log(:clear, 'not a level') }
    assert_raise(ArgumentError) { BGP::Logging.write(:trace, 'not a level') }
    e = assert_raise(ArgumentError) { BGP::Logging.write(:verbose, 'x') }
    assert_match(/:verbose/, e.message)
    assert_match(/:debug, :info, :warn, :error, :fatal/, e.message,
                 'the refusal names what it does take')
  ensure
    restore_log_state(state)
  end

  def test_the_levels_are_the_five_the_process_log_has
    assert_equal(%i[debug info warn error fatal], BGP::Logging::LEVELS)
    BGP::Logging::LEVELS.each { |l| assert_respond_to(Log, l) }
    assert_equal(true, BGP::Logging::LEVELS.frozen?)
  end

  # to_log is what both Server classes hand down, so the dispatch above is
  # theirs too rather than a second copy in each.
  def test_to_log_answers_a_callable_that_writes_to_the_process_log
    state = save_log_state
    io = StringIO.new
    Log.class_variable_set(:@@logger, nil)
    Log.start(io)
    logger = BGP::Logging.to_log
    assert_respond_to(logger, :call)
    logger.call(:error, 'through the callable')
    assert_match(/ERROR -- : through the callable$/, io.string)
    assert_raise(ArgumentError) { logger.call(:clear, 'x') }
  ensure
    restore_log_state(state)
  end

  # ---- who includes it ----

  # The library's own logging goes through #log now, so a Log call left
  # behind would be a line a program cannot redirect. **One is left on
  # purpose**: Path_attribute has no owner to take a logger from, and its
  # own comment says so. This guard is what makes that a decision rather
  # than an oversight, and it fails when a new one appears.
  ALLOWED_PROCESS_LOG = ['bgp/common.rb',                     # Log itself
                         'bgp/logging.rb',                    # the fallback
                         'bgp/path_attributes/path_attribute.rb',
                         'bgp/daemon/log_ring.rb',            # comments only
                         'bgp/daemon/server.rb',              # setup_log
                         'bgp/daemon/candidate.rb',           # Log.level
                         'bgp/sim/server.rb',                 # setup_log
                         'bgp/sim/routegen.rb',               # setup_log
                         'bgp/daemon/speaker.rb'].freeze      # setup_log

  def test_no_other_library_file_logs_through_the_process_log
    root = File.expand_path('../..', __dir__)
    offenders = Dir.glob(File.join(root, 'bgp', '**', '*.rb')).sort.reject do |path|
      ALLOWED_PROCESS_LOG.include?(path.sub("#{root}/", ''))
    end.select do |path|
      # A write, not a mention: Log.create, Log.level and Log.set_filename
      # are a program configuring its destination and are not lines.
      File.readlines(path).any? { |l| l =~ /^\s*Log\.(debug|info|warn|error|fatal)\b/ }
    end
    assert_equal([], offenders.collect { |p| p.sub("#{root}/", '') },
                 'log(level, message) rather than Log, so a program can redirect it')
  end

  # The classes the wiring put it on, so a later refactor that drops an
  # include fails here rather than in whatever could not find #log.
  def test_the_objects_that_hold_sessions_log_through_it
    require 'bgp4r'
    require 'bgp/rib'
    require 'bgp/daemon/speaker'
    require 'bgp/sim/injector'
    [BGP::Neighbor, BGP::Events, BGP::IO::Input, BGP::IO::Output,
     BGP::Rib::Table, BGP::Daemon::Speaker, BGP::Sim::Injector].each do |klass|
      assert(klass.include?(BGP::Logging), "#{klass} must include BGP::Logging")
    end
  end

  # These three are handed the Table and read its logger, so a program
  # cannot give one of them a destination the other two do not have.
  def test_the_three_rib_objects_delegate_to_the_table
    require 'bgp/rib'
    [BGP::Rib::Router, BGP::Rib::PeerFeed, BGP::Rib::FibInstaller].each do |klass|
      assert(klass.instance_method(:log).owner == klass,
             "#{klass} defines its own #log, delegating to the table")
      assert_equal(false, klass.include?(BGP::Logging),
                  "#{klass} must not carry a logger of its own")
    end
  end

end
