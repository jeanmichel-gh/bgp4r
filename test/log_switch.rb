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

require 'bgp/common'

# `BGP4R_LOG=debug ruby test/run_unit.rb` turns the library's log on for
# a test run, so a failure can be read rather than bisected.
#
# **Nothing did this before.** Every other switch in the tree is about a
# binary a lab test needs, `LAB_LOG_LEVEL` reaches only the speakers a
# lab test spawns as child processes, and a test running in process got
# no log at all: `Log` starts with `@@logger` nil, so every `Log.info` in
# the library was a silent no-op. A person who wanted to see what a
# functional test did had to edit the test. ospfv2 and isis4r both have
# this switch; this is that, named for this library.
#
# It writes to **standard error**, so a run can be read and redirected
# apart from test-unit's own output on standard out:
#
#   BGP4R_LOG=debug ruby test/run_unit.rb 2> /tmp/bgp4r.log
#
# **Two limits, both worth knowing before trusting it.** A test that
# silences the log itself wins, because `Log.set_filename` replaces the
# logger where `Log.create` only ensures one: `test/functional/sim_test.rb`
# and `test/unit/daemon/candidate_test.rb` do exactly that, on purpose,
# and this switch does not override them. And an object handed its own
# logger through `bgp/logging.rb` writes there instead, which is what
# that file is for, so a `Neighbor` built with `:logger` is not affected
# either.
module LogSwitch

  # The three levels `Daemon::Speaker` accepts, so one vocabulary covers
  # the node files, `LAB_LOG_LEVEL` and this. The numbers are the two a
  # person actually types.
  LEVELS = {
    'debug' => Logger::DEBUG, '2' => Logger::DEBUG,
    'info'  => Logger::INFO,  '1' => Logger::INFO,
    'warn'  => Logger::WARN,
  }.freeze

  VAR = 'BGP4R_LOG'

  module_function

  # Reads the variable and installs a logger, or does nothing. Answers
  # the level it set, or nil. An unknown value warns and does nothing
  # rather than guessing: a typo that silently logs nothing is the same
  # wrong answer as a typo that silently logs everything.
  def install(env = ENV, io = STDERR)
    name = env[VAR].to_s.strip.downcase
    return nil if name.empty?
    level = LEVELS[name]
    unless level
      warn "#{VAR}=#{name.inspect}: use one of #{LEVELS.keys.join(', ')}"
      return nil
    end
    Log.create(io)
    Log.level = level
    level
  end

end
