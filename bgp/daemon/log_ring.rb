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

module BGP
  module Daemon

    # The last lines `bgp4rd` logged, kept so `show.log` can answer them.
    #
    # It is an IO as far as `Logger` is concerned: `Log.set_filename` takes
    # anything answering `write` and `close`, so one of these in front of
    # the real destination sees every line the library formats and passes
    # it on unchanged. That is the whole of it. A line is kept as text,
    # because that is what `Logger` produced and what a person means by
    # the last N lines.
    #
    #   ring = LogRing.new($stdout)
    #   Log.set_filename(ring)
    #   ring.lines(20)
    #
    # **Why a ring of text and not the event stream, which is the obvious
    # thing and is what ospfv2 does.** ospfv2's `show.log` is its kept
    # event list with the debug entries dropped, and it can be, because in
    # ospfv2 every non-debug log line is published as an event. bgp4r is
    # not built that way: `bgp/events.rb` is published from two places, a
    # session's state changes and a NOTIFICATION, and every other line in
    # the library goes straight to `Log` from wherever it happened. So the
    # same implementation here would answer three entries where the log
    # holds three hundred and call that the log, which is a wrong answer
    # rather than a missing one. Making it true the ospfv2 way means
    # routing every `Log` call in the library through an injected logger
    # that publishes as well, which is a real piece of work and is item 7
    # of `docs/routescope-labs.md` section 6.
    #
    # **Two more things rejected.** Reading the `--log` file back, which
    # cannot work for the default: `--log -` is standard output, which is
    # not seekable, and a container's log is the thing a person already
    # has. And publishing each line into `BGP::Events` as a `:log` event,
    # which would push the events people look for out of a backlog bounded
    # at 2000 entries, the reason `bgp/events.rb` already records for
    # keeping debug lines out of it.
    #
    # So `show.log` answers text and `events.subscribe` answers structure,
    # and the difference is deliberate: a log line is for a person, an
    # event carries a kind and a data Hash a program switches on.
    #
    # It takes its own lock, because `Log` is written from every session
    # thread and read from a control socket thread.
    class LogRing

      # Lines kept, and the most `show.log` will answer at once. 2000 is
      # ospfv2's number for the same job, and its `show.log` clamps a
      # request the same way.
      KEEP      = 2000
      MAX_COUNT = 2000

      attr_reader :io, :keeps

      # :keeps overrides KEEP. io is where the lines go on to, and nil
      # keeps them here only, which is what a test wants.
      def initialize(io = nil, arg = {})
        @io    = io
        @keeps = arg[:keeps] || KEEP
        @lines = []
        @lock  = Mutex.new
      end

      # Logger writes whole formatted lines here. A write that reaches the
      # real IO is what matters, so it goes first: an exception from the
      # ring must not be able to lose a log line, and one from the IO must
      # not be able to lose the ring's copy either.
      def write(text)
        s = text.to_s
        begin
          @io.write(s) if @io
        ensure
          keep(s)
        end
        s.bytesize
      end

      # Logger does not use these, but an IO does and something else may.
      def <<(text) ; write(text) ; self ; end
      def sync ; @io.respond_to?(:sync) ? @io.sync : true ; end
      def sync=(v) ; @io.sync = v if @io.respond_to?(:sync=) ; end
      def flush ; @io.flush if @io.respond_to?(:flush) ; self ; end

      # Closes the destination, and keeps the lines: a reader asking for
      # the log after the log file was closed wants what was in it.
      #
      # `$stdout` is not this object's to close, and `Logger` closes its
      # device when it is replaced, so closing standard output here would
      # take the container's log away on a second `Log.set_filename`.
      def close
        @io.close if @io && @io != $stdout && @io != $stderr && @io.respond_to?(:close)
        nil
      end

      # The last n lines, oldest first, each without its newline. n above
      # MAX_COUNT is clamped, since the answer crosses a socket.
      def lines(n = 100)
        count = Integer(n).clamp(1, MAX_COUNT)
        @lock.synchronize { @lines.last(count).dup }
      end

      # How many lines are kept.
      def size ; @lock.synchronize { @lines.size } ; end

      def clear ; @lock.synchronize { @lines.clear } ; self ; end

      private

      # One write may carry several lines, or part of one. Logger writes a
      # whole formatted message per call and bgp4r's format ends in a
      # newline, so splitting on it is right; a write with no newline is
      # kept as a line of its own rather than held, because a log line
      # nobody ever flushed would otherwise never be answered.
      def keep(text)
        return if text.empty?
        @lock.synchronize do
          text.split("\n").each { |line| @lines << line unless line.empty? }
          @lines.shift(@lines.size - @keeps) if @lines.size > @keeps
        end
      end

    end

  end
end
