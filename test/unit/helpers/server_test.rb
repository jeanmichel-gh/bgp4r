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
