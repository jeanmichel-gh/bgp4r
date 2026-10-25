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

require 'test/unit'
require 'socket'
require 'bgp4r'

class TestBgpIo < Test::Unit::TestCase

  class Events
    def initialize ; @q = Queue.new ; end
    def update(*args) ; @q << args ; end
    def next_event(timeout)
      deadline = Time.now + timeout
      while Time.now < deadline
        return @q.pop(true) rescue sleep(0.05)
      end
      nil
    end
  end

  def setup
    @ours, @theirs = UNIXSocket.pair
    @events = Events.new
    @input = BGP::IO::Input.new(@ours, 30, @events)
  end

  def teardown
    [@ours, @theirs].each { |s| s.close unless s.closed? }
    @input.thread.kill if @input.thread
  end

  def test_input_delivers_a_message
    @input.start
    @theirs.write BGP::Keepalive.new.encode
    ev, type, msg = @events.next_event(2)
    assert_equal(:ev_msg, ev)
    assert_equal(4, type)
    assert_equal(BGP::Keepalive.new.encode, msg)
  end

  def test_input_reports_peer_close_at_once
    # RFC 4271 section 8.2.2: the TCP connection closing is an error event
    # (TcpConnectionFails), not something to wait out until the hold timer.
    # Before the fix, Input spun on recv returning "" until hold time ran out.
    @input.start
    @theirs.close
    ev, err = @events.next_event(2)
    assert_equal(:ev_conn_reset, ev, 'peer close not reported within 2 seconds')
    assert_kind_of(EOFError, err)
    @input.thread.join(1)
    assert(!@input.thread.alive?, 'Input thread should exit after the peer closes')
  end

  def test_output_queue_has_a_default_limit
    assert_equal(BGP::IO::Output::DEFAULT_MAX, BGP::IO::Output.new(@ours, 30).max)
    assert_equal(256, BGP::IO::Output::DEFAULT_MAX)
  end

  def test_output_queue_is_bounded
    # A peer that does not read: the socket buffer fills, then the queue,
    # then the producer waits instead of piling messages up in memory.
    out = BGP::IO::Output.new(@ours, 30, @events)
    out.max = 4
    out.start
    blob = 'x' * 4000
    producer = Thread.new { 300.times { out.enq blob } ; :done }
    sleep 1
    assert(producer.alive?, 'producer should wait while the queue is full')
    assert_operator(out.size, :<=, 4)
    drain = Thread.new { loop { @theirs.readpartial(65536) } rescue nil }
    assert_equal(:done, producer.join(10) && producer.value, 'producer finishes once the peer reads')
  ensure
    drain.kill if drain
    producer.kill if producer && producer.alive?
    out.thread.kill if out && out.thread
  end

  def test_close_wakes_a_waiting_producer
    out = BGP::IO::Output.new(@ours, 30)
    out.max = 1
    out.enq 'first'
    t = Thread.new { begin ; out.enq 'second' ; :sent ; rescue ClosedQueueError ; :closed ; end }
    sleep 0.2
    assert(t.alive?, 'enq should wait on a full queue')
    out.close
    assert_equal(:closed, t.join(2) && t.value)
  end

  def test_input_reports_close_after_a_partial_message
    @input.start
    @theirs.write BGP::Keepalive.new.encode[0, 10]
    @theirs.close
    ev, _ = @events.next_event(2)
    assert_equal(:ev_conn_reset, ev)
  end

  def test_input_delivers_a_short_message_after_a_long_one_at_once
    # A long UPDATE and a short KEEPALIVE arrive in one write. Before the
    # fix, Input compared the buffer with the long message's length, so it
    # waited for more bytes before it handed over the KEEPALIVE.
    pa = BGP::Path_attribute.new(BGP::Origin.new(0), BGP::Next_hop.new('10.0.0.1'), BGP::As_path.new(1))
    long = BGP::Update.new(pa, BGP::Nlri.new('11.0.0.0/28', '11.0.0.16/28', '11.0.0.32/28')).encode
    @input.start
    @theirs.write long + BGP::Keepalive.new.encode
    assert_equal(long, @events.next_event(2)[2])
    ev, type, msg = @events.next_event(2)
    assert_equal(:ev_msg, ev, 'the KEEPALIVE should not wait for more bytes')
    assert_equal(4, type)
    assert_equal(BGP::Keepalive.new.encode, msg)
  end

end
