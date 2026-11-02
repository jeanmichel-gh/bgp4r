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
require 'timeout'
require 'bgp4r'
require 'test/helpers/server'

class TestBgpTestHelpersServer < Test::Unit::TestCase
  include BGP
  include BGP::TestHelpers

  def teardown
    stop_server
    @busy.close if @busy && ! @busy.closed?
  end

  # **One connection must not take the listener with it.**
  # `start_session` runs on the accept loop's own thread, so anything it
  # raises ends the loop, and every later test that expects this server to
  # answer then hangs until its own timeout with nothing saying why.
  #
  # That is how the `Neighbor` lifecycle race read in CI: one
  # `Could not SendOpen: session closed` out of `start_session`, the
  # listener thread gone with it, and a 60 second wait for a session
  # nobody was listening for. The race is fixed in `bgp/neighbor`; this is
  # the half that turned it into a stall rather than a retry.
  def test_one_bad_connection_does_not_end_the_accept_loop
    Timeout::timeout(15) {
      port = start_server
      calls = 0
      ok = @s.method(:start_session)
      @s.define_singleton_method(:start_session) do |s|
        calls += 1
        raise 'the peer vanished between accept and send' if calls == 1
        ok.call(s)
      end
      TCPSocket.new('127.0.0.1', port).close
      sleep 0.3 while calls.zero?
      assert @thread.alive?, 'the listener died with the connection'
      @c = Neighbor.new(4, 100, 180, '0.0.0.2', '127.0.0.1', '127.0.0.1')
      assert @c.start(:port=> port, :timeout=> 5), 'a later session must still establish'
      @c.close
    }
  end

  def test_start_server_raises_on_a_busy_port
    # Before the fix a bare rescue hid the error: start_server returned nil
    # and the test failed later when the client could not connect.
    @busy = TCPServer.new('127.0.0.1', 0)
    port = @busy.addr[1]
    e = assert_raise(RuntimeError) { start_server(port) }
    assert_match(/cannot listen on 127\.0\.0\.1 port #{port}/, e.message)
  end

  def test_start_server_returns_a_free_port
    port = start_server
    assert_kind_of(Integer, port)
    assert_operator(port, :>, 0)
    Timeout.timeout(4) do
      @c = Neighbor.new(4, 100, 180, '0.0.0.2', '127.0.0.1', '127.0.0.1')
      @c.start :port=> port
      assert_equal('Established', @c.state)
      assert @s.wait_for_state(:Established, 2), "server did not reach Established"
    end
  end

  def test_stop_server_twice
    start_server
    assert_nothing_raised { stop_server ; stop_server }
    assert(@server.closed?)
  end

  def test_stop_server_raises_unexpected_errors
    # Before the fix a bare rescue swallowed every error, bugs included.
    start_server
    @c = Object.new
    def @c.stop ; raise ArgumentError, 'a bug' ; end
    assert_raise(ArgumentError) { stop_server }
    assert(@server.closed?, 'the listener is closed even when stop raises')
    @c = nil
  end

  def test_stop_server_ignores_a_socket_already_gone
    start_server
    @c = Object.new
    def @c.stop ; raise Errno::ECONNRESET ; end
    assert_nothing_raised { stop_server }
    @c = nil
  end
end
