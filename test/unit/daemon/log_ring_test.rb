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

# The ring of log lines `show.log` answers from.
#
#   ruby -I. test/unit/daemon/log_ring_test.rb
#
# **The one assertion that matters is the one through `Log`**, because
# that is the whole claim: a ring in front of the real destination sees
# every line the library formats, wherever in the library it was written.
# Every other test here is about the ring behaving as an IO while it does
# that.

require 'test/unit'
require 'stringio'
require 'bgp/daemon/log_ring'
# `Log` is the library's logger and `bgp/common.rb` defines it. The ring
# itself does not reach it, so the file under test does not require it;
# this file does, because the one assertion that matters goes through it.
# Without this the file passes in the suite, where something earlier has
# required it, and errors on its own, which is the load order trap
# Conventions records.
require 'bgp/common'

class BGP_Daemon_LogRing_Test < Test::Unit::TestCase

  def test_a_line_is_kept_and_passed_on
    io = StringIO.new
    ring = BGP::Daemon::LogRing.new(io)
    ring.write("first\n")
    ring.write("second\n")
    assert_equal(['first', 'second'], ring.lines)
    assert_equal("first\nsecond\n", io.string, 'and the real destination got them too')
  end

  def test_the_newline_is_not_part_of_a_line
    ring = BGP::Daemon::LogRing.new
    ring.write("a line\n")
    assert_equal(['a line'], ring.lines)
  end

  # Logger writes one formatted message per call, but nothing says a
  # write is one line, so both shapes are kept as lines.
  def test_one_write_may_carry_several_lines_or_none
    ring = BGP::Daemon::LogRing.new
    ring.write("a\nb\nc\n")
    ring.write('no newline yet')
    ring.write('')
    assert_equal(%w[a b c], ring.lines.first(3))
    assert_equal('no newline yet', ring.lines.last,
                 'a write with no newline is still a line: one nobody flushed would never be answered')
    assert_equal(4, ring.size)
  end

  # **Bounded, which is the point of a ring**: a daemon that ran for a
  # week must not be holding a week of log in memory.
  def test_the_oldest_lines_fall_off
    ring = BGP::Daemon::LogRing.new(nil, :keeps => 3)
    6.times { |i| ring.write("line #{i}\n") }
    assert_equal(3, ring.size)
    assert_equal(['line 3', 'line 4', 'line 5'], ring.lines)
    assert_equal(3, ring.keeps)
  end

  def test_lines_answers_the_last_n_oldest_first
    ring = BGP::Daemon::LogRing.new
    5.times { |i| ring.write("line #{i}\n") }
    assert_equal(['line 3', 'line 4'], ring.lines(2))
    assert_equal(5, ring.lines(99).size)
  end

  # Clamped rather than refused, because the answer crosses a socket: a
  # caller asking for a million lines is asking for something this
  # cannot answer.
  def test_a_count_is_clamped
    ring = BGP::Daemon::LogRing.new
    (BGP::Daemon::LogRing::MAX_COUNT + 10).times { |i| ring.write("line #{i}\n") }
    assert_equal(BGP::Daemon::LogRing::MAX_COUNT, ring.lines(1_000_000).size)
    assert_equal(1, ring.lines(0).size)
    assert_equal(1, ring.lines(-5).size)
  end

  def test_a_ring_with_no_destination_keeps_the_lines_anyway
    ring = BGP::Daemon::LogRing.new
    assert_nothing_raised { ring.write("alone\n") }
    assert_equal(['alone'], ring.lines)
  end

  # A write that reaches the real destination is what matters, so the
  # ring's own copy must not be able to lose it and the destination's
  # failure must not be able to lose the copy.
  def test_a_destination_that_raises_still_leaves_the_line_in_the_ring
    ring = BGP::Daemon::LogRing.new(Exploding.new)
    assert_raise(RuntimeError) { ring.write("kept anyway\n") }
    assert_equal(['kept anyway'], ring.lines)
  end

  def test_clear_empties_it
    ring = BGP::Daemon::LogRing.new
    ring.write("a\n")
    assert_equal(1, ring.size)
    ring.clear
    assert_equal([], ring.lines)
  end

  # **The claim this class exists for.** `Log.set_filename` takes
  # anything answering write and close, so the ring sees what Logger
  # formatted, whichever part of the library wrote it. The IO underneath
  # gets the same text, so `--log FILE` still works.
  def test_it_is_an_io_as_far_as_the_library_logger_is_concerned
    io = StringIO.new
    ring = BGP::Daemon::LogRing.new(io)
    # A logger before this one, so set_filename is replacing something
    # rather than creating the first: that is the state a long lived
    # process is in, and it is where Log.create would have done nothing.
    Log.create(StringIO.new)
    begin
      Log.set_filename(ring)
      Log.level = Logger::INFO
      Log.info('a line from the library')
      Log.debug('and one it should not keep at this level')
      assert_equal(1, ring.size)
      assert_match(/a line from the library/, ring.lines.first)
      assert_match(/a line from the library/, io.string)
    ensure
      Log.set_filename(STDERR)
    end
  end

  # Standard output is not this object's to close, and Logger closes its
  # device when it is replaced: closing it here would take a container's
  # log away on the next `Log.set_filename`.
  def test_close_leaves_standard_output_alone
    ring = BGP::Daemon::LogRing.new($stdout)
    assert_nothing_raised { ring.close }
    assert_equal(false, $stdout.closed?)
  end

  def test_close_closes_a_file_and_keeps_the_lines
    io = StringIO.new
    ring = BGP::Daemon::LogRing.new(io)
    ring.write("before\n")
    ring.close
    assert_equal(true, io.closed?)
    assert_equal(['before'], ring.lines,
                 'a reader asking for the log after the file closed wants what was in it')
  end

  # It is written from every session thread and read from a control
  # socket thread, so it takes its own lock.
  def test_concurrent_writers_lose_no_line
    ring = BGP::Daemon::LogRing.new(nil, :keeps => 10_000)
    threads = 8.times.collect do |t|
      Thread.new { 200.times { |i| ring.write("t#{t} #{i}\n") } }
    end
    threads.each(&:join)
    assert_equal(1600, ring.size)
  end

  private

  class Exploding
    def write(_s) ; raise 'the log device went away' ; end
  end

end
