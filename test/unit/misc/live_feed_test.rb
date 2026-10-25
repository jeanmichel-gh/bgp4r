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
    Thread.new do
      until data.empty?
        @client.write data.slice!(0, rand(1..40))
        sleep 0.001
      end
    end
    Timeout.timeout(5) do
      msgs.each { |m| assert_equal [m].pack('H*'), @feed.read }
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
