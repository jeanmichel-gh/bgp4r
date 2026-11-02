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

# Log is the destination an object with no logger falls back to.
require 'bgp/common'

module BGP

  # Where one object writes its log lines.
  #
  # A logger is a plain callable, +->(level, message)+, with level one of
  # LEVELS. An object that has one calls it; an object that has none falls
  # back to Log, which is the process-wide singleton this library has
  # always used. So nothing outside the library moves and a program that
  # wants its sessions apart hands each of them its own callable.
  #
  #   speaker = BGP::Daemon::Speaker.new(config, :logger => mine)
  #   neighbor.logger = mine
  #   mine = ->(level, message) { io.puts "#{level} #{message}" }
  #
  # **What this fixes, which is the one thing worth stating.** Log holds
  # +@@logger+ behind +private_class_method :new+, with process-wide
  # +Log.level+ and +Log.filename+, so two speakers in one process could
  # not log apart however they were configured. A multi-node harness is
  # exactly two speakers in one process, and so are +bgp4rd+,
  # +bgp4r-sim+ and +lab/speaker.rb+. That is item 7 of
  # docs/routescope-labs.md section 6.
  #
  # **Two designs rejected, and the mechanism for each.**
  #
  # A logger beside Log, with the library still calling +Log.warn+ from
  # inside a session, would not have fixed anything: a Speaker handed a
  # logger would still write its sessions' lines to the process-wide
  # destination, which is the whole of the complaint. It is the cheaper
  # diff and it clears no bar.
  #
  # A logger threaded as a new argument through every constructor was the
  # other half of the choice, and it turned out not to be needed. The
  # objects that hold sessions already take an options Hash that reaches
  # them: +Neighbor#set+ reads +:events+ out of one and now reads
  # +:logger+ beside it, +BGP::Events+ has +check_options+, and
  # +Rib::Router+, +Rib::PeerFeed+ and +Rib::FibInstaller+ are each handed
  # the Table, so they read its logger and no signature moved. Where
  # nothing was handed down the object sets it afterwards, which
  # +Neighbor+ does for the two +BGP::IO+ threads. So the per-object state
  # that actually fixes the bar cost no constructor change.
  #
  # **The level is the logger's business and not this method's.** ospfv2's
  # +ospfd+ drops a debug line in the lambda it builds, and the two
  # +Server+ classes here set +Log.level+ and let Log drop it. Filtering
  # in both places would mean a line could be dropped twice and enabled
  # once, so +log+ hands every level over and the destination decides.
  #
  # **Logging is observation: installing a logger must not change
  # behaviour.** +test/functional/lab/speaker_test.rb+ runs the same
  # session twice, once with a logger at debug and once with none, and
  # compares every message the far side received.
  #
  # Be exact about what that covers, because the wider reading is
  # tempting and wrong. The argument to +log+ is built by the caller, so
  # it is evaluated whether or not a logger is installed: +log_debug
  # "Send #{m.to_s}"+ calls +to_s+ either way. A side effect in the
  # argument expression therefore changes **both** runs identically and
  # that comparison is blind to it, which a sabotage proved by passing.
  # It is still a defect; it is just not one this guard finds. What the
  # guard does find is behaviour that depends on whether a logger is
  # there, which is the class this file brings in.
  #
  # Nothing here rescues. ospfv2 does not, and the four places in this
  # tree that already hold an injected logger, +Daemon::Api+,
  # +Daemon::Candidate+, +Daemon::Server+ and +Sim::Http+, do not either:
  # a logger that raises is a bug in the program that supplied it, and a
  # rescue here would hide a typo'd callable doing nothing forever.
  module Logging

    # The levels a logger is called with, which are Log's five.
    LEVELS = %i[debug info warn error fatal].freeze

    # One line to the process-wide Log. This is the fallback #log
    # uses with no logger set, and it is what both Server classes hand
    # down as their logger, so the dispatch is here once.
    #
    # It is a +case+ and not +Log.send(level, message)+, which is what
    # those two built before this. A +send+ of a Symbol onto Log reaches
    # every method it has, and +Log.clear+ deletes the log file, so a
    # level ever spelled wrong would be a destructive call rather than
    # an error.
    def self.write(level, message)
      case level
      when :debug then Log.debug(message)
      when :info  then Log.info(message)
      when :warn  then Log.warn(message)
      when :error then Log.error(message)
      when :fatal then Log.fatal(message)
      else
        raise ArgumentError,
              "log level #{level.inspect}: one of #{LEVELS.collect(&:inspect).join(', ')}"
      end
    end

    # A logger that writes to the process-wide Log, for a program
    # that has to hand one to something which takes a callable.
    def self.to_log
      ->(level, message) { Logging.write(level, message) }
    end

    # The callable this object logs through, or nil for Log.
    #
    # It is an +attr_accessor+ and not a constructor argument on purpose,
    # for the reason +Neighbor+ already gives +attr_accessor :events+: an
    # object on its own is useful with none, and a program with several
    # sets the same one on each.
    attr_accessor :logger

    # One line. +level+ is one of LEVELS and +message+ is for a person.
    #
    # **The +return+ is load bearing**: a logger *replaces* the process
    # log rather than writing beside it. Dropping it is the ordinary
    # slip, and it would leave a program that redirected its logs also
    # filling the destination it redirected them away from, which for
    # two speakers in one process is the whole thing being fixed.
    # +test_a_logger_replaces_the_process_log_rather_than_writing_beside_it+
    # is what fails on it.
    def log(level, message)
      return @logger.call(level, message) if @logger
      Logging.write(level, message)
    end

  end
end
