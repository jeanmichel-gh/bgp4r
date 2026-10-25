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

require "test/unit"
require "timeout"
require "bgp/misc/live_feed"

class TestBgpMiscLiveFeedUnit < Test::Unit::TestCase
  def setup
    @server = TCPServer.new('127.0.0.1', 0)
    @port = @server.addr[1]
  end
  def teardown
    @feed.close if @feed
    @client.close if @client && ! @client.closed?
    @server.close unless @server.closed?
  end
  def octets(hex)
    "<OCTETS length=\"#{hex.size/2}\">#{hex}</OCTETS>\n"
  end
  def open_feed
    Timeout.timeout(3) do
      @feed = LiveFeed.open(:host => '127.0.0.1', :port => @port, :timeout => 2)
      @client = @server.accept
    end
  end
  def test_open_raises_on_closed_port
    @server.close
    Timeout.timeout(3) do
      assert_raise_kind_of(SystemCallError) do
        LiveFeed.open(:host => '127.0.0.1', :port => @port, :timeout => 1)
      end
    end
  end
  def test_connect_timeout_on_unroutable_address
    t0 = Time.now
    assert_raise_kind_of(SystemCallError, IO::TimeoutError) do
      Timeout.timeout(5) do
        LiveFeed.open(:host => '10.255.255.1', :port => 50001, :timeout => 0.5)
      end
    end
    assert Time.now - t0 < 3, "connect took #{Time.now - t0}s"
  end
  def test_read_messages
    open_feed
    msgs = (1..50).map { |i| 'ff' * 16 + '0013' + '04' + format('%02x', i) }
    data = msgs.map { |m| octets(m) }.join
    # The writer keeps its own reference to the socket, and the test waits
    # for it. The feed can return the last message before the writer has
    # sent the closing tag, and test-unit clears instance variables once a
    # test ends, so @client may be nil by then.
    client = @client
    writer = Thread.new do
      until data.empty?
        client.write data.slice!(0, rand(1..40))
        sleep 0.001
      end
    end
    Timeout.timeout(5) do
      msgs.each { |m| assert_equal [m].pack('H*'), @feed.read }
      writer.join
    end
  end
  def test_parser_does_not_busy_loop
    open_feed
    @client.write "<OCTETS length=\"19\">ffff"
    sleep 0.1
    t0 = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID)
    sleep 0.5
    cpu = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID) - t0
    assert cpu < 0.2, "parser used #{cpu}s of CPU while idle"
  end
  def test_read_returns_nil_after_eof
    open_feed
    @client.write octets('ff' * 16 + '001304')
    @client.close
    Timeout.timeout(5) do
      assert_equal ['ff' * 16 + '001304'].pack('H*'), @feed.read
      assert_nil @feed.read
    end
  end
  def test_close_on_a_feed_never_opened
    # Before the fix close used @lock, which open sets, so it raised
    # NoMethodError on nil. No network: open is never called.
    feed = LiveFeed.new
    assert_nothing_raised { feed.close }
    assert_nothing_raised { feed.close }
  end
  def test_close_after_a_failed_open
    # Before the fix @feed was nil after a failed connect, so close raised.
    @server.close
    feed = LiveFeed.new
    Timeout.timeout(3) do
      assert_raise_kind_of(SystemCallError) do
        feed.open(:host => '127.0.0.1', :port => @port, :timeout => 1)
      end
    end
    assert_nothing_raised { feed.close }
    assert_nothing_raised { feed.close }
  end
  def test_close_unblocks_read
    open_feed
    th = Thread.new { @feed.read }
    sleep 0.1
    assert th.alive?, "read should block while the feed is silent"
    Timeout.timeout(3) do
      @feed.close
      assert_nil th.value
    end
    assert_nil @feed.read
    assert_nothing_raised { @feed.close }
  ensure
    th.kill if th
  end
end
