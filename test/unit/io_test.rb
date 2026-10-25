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

  def test_input_reports_close_after_a_partial_message
    @input.start
    @theirs.write BGP::Keepalive.new.encode[0, 10]
    @theirs.close
    ev, _ = @events.next_event(2)
    assert_equal(:ev_conn_reset, ev)
  end

end
