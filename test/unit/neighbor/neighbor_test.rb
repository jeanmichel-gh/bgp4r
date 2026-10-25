#--
# Copyright 2008, 2009, 2026 Jean-Michel Esnault.
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
require 'bgp4r'
require 'test/helpers/server'
require 'timeout'
include BGP
include BGP::OPT_PARM::CAP
include BGP::TestHelpers


class TestBgpNeighbor < Test::Unit::TestCase
  include BGP
  include BGP::OPT_PARM::CAP
  include BGP::TestHelpers
  def setup
    # Don't work with jruby: skip
    skip if RUBY_PLATFORM=='java'
    super
  end
  def teardown
    stop_server
  end
  def test_open_msg
    neighbor = Neighbor.new \
    :version=> 4, 
    :my_as=> 100, 
    :remote_addr => '192.168.1.200',
    :local_addr => '192.168.1.5', 
    :id=> '1.1.1.1', 
    :holdtime=> 20
    neighbor.capability Mbgp.ipv4_unicast
    neighbor.capability Mbgp.ipv4_multicast
    neighbor.capability Route_refresh.new
    neighbor.capability Route_refresh.new 128
    neighbor.capability As4.new(100)
    open_msg = neighbor.open
    assert_equal(5,open_msg.opt_parms.size)
    assert_equal(4,open_msg.version)
    assert_equal(20,open_msg.holdtime)
    assert_equal(100,open_msg.local_as)
  end
  def test_neighbor_state_methods
    neighbor = Neighbor.new \
    :version=> 4, 
    :my_as=> 100, 
    :remote_addr => '192.168.1.200', 
    :local_addr => '192.168.1.5', 
    :id=> '1.1.1.1', 
    :holdtime=> 20
    assert neighbor.is_idle?
    assert ! neighbor.is_established?
    assert ! neighbor.is_openrecv?
    assert ! neighbor.is_openconfirm?
  end
  def test_send_message_waits_on_a_full_queue_and_fails_cleanly_on_stop
    ours, theirs = UNIXSocket.pair
    n = Neighbor.new(:my_as=>100, :id=>'1.1.1.1', :send_queue_limit=>2)
    n.start(:session=>ours, :no_blocking=>true)
    assert_equal(2, n.send_queue_limit)
    # The peer never reads, so the socket buffer and then the queue fill up.
    sender = Thread.new do
      begin
        500.times { n.send_message('x' * 4000) }
        :all_sent
      rescue RuntimeError => e
        e.message
      end
    end
    sleep 1
    assert(sender.alive?, 'send_message should wait while the send queue is full')
    assert_operator(n.send_queue_size, :<=, 2)
    n.stop
    result = sender.join(3) && sender.value
    assert_match(/session closed/, result.to_s, 'a waiting send_message must not hang after stop')
  ensure
    sender.kill if sender && sender.alive?
    [ours, theirs].each { |s| s.close unless s.closed? }
  end
  def test_send_message_before_start_raises
    n = Neighbor.new(4, 100, 180, '0.0.0.2', '127.0.0.1', '127.0.0.1')
    e = assert_raise(RuntimeError) { n.send_message Keepalive.new }
    assert_match(/not started/, e.message)
    assert n.is_idle?
  end
  def test_start
    Timeout::timeout(4) {
      start_server(3456)
      @c = Neighbor.new(4, 100, 180, '0.0.0.2', '127.0.0.1', '127.0.0.1')
      @c.start :port=> 3456
      assert_equal('Established', @c.state)
      assert @s.wait_for_state(:Established, 2), "server did not reach Established"
      assert_equal('Established', @s.state)
    }
  rescue Timeout::Error
    assert false, "Timeout"
  end
  def test_start_no_blocking
    Timeout::timeout(4) {
      start_server(3333)
      @c = Neighbor.new(4, 100, 180, '0.0.0.2', '127.0.0.1', '127.0.0.1')
      @c.start :port=> 3333, :no_blocking=>true
      assert_equal('OpenSent', @c.state)
    }
  rescue Timeout::Error
    assert false, "Timeout"
  end
  def test_start_blocking
    Timeout::timeout(4) {
      start_server(3333)
      @c = Neighbor.new(4, 100, 180, '0.0.0.2', '127.0.0.1', '127.0.0.1')
      @c.start :port=> 3333, :no_blocking=>false
      assert_equal('Established', @c.state)
      assert @s.wait_for_state(:Established, 2), "server did not reach Established"
      assert_match(/Established/, @s.state)
    }
  rescue Timeout::Error
    assert false, "Timeout"
  end
  def test_start_waitfor_timeout
    # Peer accepts the TCP connection but never speaks BGP.
    @server = TCPServer.new('127.0.0.1', 0)
    port = @server.addr[1]
    @thread = Thread.new { loop { @server.accept } rescue nil }
    Timeout::timeout(4) {
      @c = Neighbor.new(4, 100, 180, '0.0.0.2', '127.0.0.1', '127.0.0.1')
      t0 = Time.now
      @c.start :port=> port, :timeout=> 0.5
      assert_operator(Time.now - t0, :<, 2)
      assert_equal('Idle', @c.state)
    }
  rescue Timeout::Error
    assert false, "Timeout"
  end
  def test_start_with_session
    # Hand an already connected socket to start via :session.
    @server = TCPServer.new('127.0.0.1', 0)
    peer = TCPSocket.new('127.0.0.1', @server.addr[1])
    session = @server.accept
    Timeout::timeout(4) {
      @c = Neighbor.new(4, 100, 180, '0.0.0.2', '127.0.0.1', '127.0.0.1')
      @c.start :session=> session, :no_blocking=>true
      assert_equal('OpenSent', @c.state)
      assert_same(session, @c.socket)
      # The OPEN must go out on the session socket: 16 byte marker, length, type 1.
      header = peer.read(19)
      assert_equal('ff'*16, header[0,16].unpack('H*')[0])
      assert_equal(1, header[18].unpack('C')[0])
    }
  rescue Timeout::Error
    assert false, "Timeout"
  ensure
    peer.close if peer and not peer.closed?
  end
  # A port nothing listens on: bind a free one, then close it.
  def closed_port
    s = TCPServer.new('127.0.0.1', 0)
    port = s.addr[1]
    s.close
    port
  end
  # A peer that answers like a BGP speaker, on a free port.
  def start_free_server
    @server = TCPServer.new('127.0.0.1', 0)
    @s = Neighbor.new(4, 100, 180, '0.0.0.1', '127.0.0.1', '127.0.0.1')
    @thread = Thread.new do
      begin
        while (session = @server.accept)
          @s.start_session(session)
        end
      rescue IOError
      end
    end
    @server.addr[1]
  end
  def test_start_on_closed_port_returns_false_and_keeps_error
    @c = Neighbor.new(4, 100, 180, '0.0.0.2', '127.0.0.1', '127.0.0.1')
    assert_nil(@c.last_error)
    assert_equal(false, @c.start(:port=> closed_port, :timeout=> 2))
    assert_kind_of(Errno::ECONNREFUSED, @c.last_error)
    assert @c.is_idle?
  end
  def test_start_with_raise_reraises_after_cleanup
    @c = Neighbor.new(4, 100, 180, '0.0.0.2', '127.0.0.1', '127.0.0.1')
    assert_raise(Errno::ECONNREFUSED) { @c.start(:port=> closed_port, :timeout=> 2, :raise=> true) }
    assert_kind_of(Errno::ECONNREFUSED, @c.last_error)
    assert @c.is_idle?
  end
  def test_start_waitfor_timeout_with_raise
    @server = TCPServer.new('127.0.0.1', 0)
    port = @server.addr[1]
    @thread = Thread.new { loop { @server.accept } rescue nil }
    @c = Neighbor.new(4, 100, 180, '0.0.0.2', '127.0.0.1', '127.0.0.1')
    e = assert_raise(RuntimeError) { @c.start(:port=> port, :timeout=> 0.5, :raise=> true) }
    assert_match(/timeout/, e.message)
    assert_same(e, @c.last_error)
    assert @c.is_idle?
  end
  def test_good_start_returns_true
    Timeout::timeout(4) {
      port = start_free_server
      @c = Neighbor.new(4, 100, 180, '0.0.0.2', '127.0.0.1', '127.0.0.1')
      assert_equal(true, @c.start(:port=> port))
      assert_nil(@c.last_error)
      assert @c.is_established?
    }
  end
  def test_good_start_no_blocking_returns_true
    Timeout::timeout(4) {
      port = start_free_server
      @c = Neighbor.new(4, 100, 180, '0.0.0.2', '127.0.0.1', '127.0.0.1')
      assert_equal(true, @c.start(:port=> port, :no_blocking=> true))
      assert_nil(@c.last_error)
    }
  end
  def test_failed_start_then_good_start_clears_last_error
    Timeout::timeout(4) {
      @c = Neighbor.new(4, 100, 180, '0.0.0.2', '127.0.0.1', '127.0.0.1')
      assert_equal(false, @c.start(:port=> closed_port))
      port = start_free_server
      assert_equal(true, @c.start(:port=> port))
      assert_nil(@c.last_error)
    }
  end
  def test_close_ends_the_event_thread
    n = Neighbor.new(4, 100, 180, '0.0.0.2', '127.0.0.1', '127.0.0.1')
    event_thread = n.instance_variable_get(:@event_thread)
    assert event_thread.alive?
    n.close
    assert n.closed?
    # Check this neighbor's own thread. A count of all threads is not
    # reliable here: threads left by earlier tests may end at any time.
    assert ! event_thread.alive?, 'close must end the event thread'
    # start after close is refused: start logs the error and stays Idle.
    n.start(:port=> 1)
    assert n.is_idle?
    assert_nil(n.socket)
    n.close # twice is fine
  end
  def test_many_neighbors_do_not_leak_threads
    threads = 50.times.map do
      n = Neighbor.new(4, 100, 180, '0.0.0.2', '127.0.0.1', '127.0.0.1')
      t = n.instance_variable_get(:@event_thread)
      n.close
      t
    end
    assert_equal([], threads.select(&:alive?), 'every closed neighbor ends its event thread')
  end
  def test_close_stops_an_established_session
    Timeout::timeout(4) {
      port = start_free_server
      @c = Neighbor.new(4, 100, 180, '0.0.0.2', '127.0.0.1', '127.0.0.1')
      @c.start :port=> port
      assert @c.is_established?
      threads = [@c.instance_variable_get(:@event_thread), @c.in, @c.out]
      @c.close
      assert @c.is_idle?
      assert @c.socket.closed?
      threads.each { |t| assert ! t.alive?, "#{t['name']} still alive after close" }
    }
  end
  def test_start_stop_start_again
    Timeout::timeout(6) {
      port = start_free_server
      @c = Neighbor.new(4, 100, 180, '0.0.0.2', '127.0.0.1', '127.0.0.1')
      @c.start :port=> port
      assert @c.is_established?
      @c.stop
      assert @c.is_idle?
      @s.stop
      @c.start :port=> port
      assert @c.is_established?, 'start after stop must still work'
      assert @s.wait_for_state(:Established, 2)
      @c.close
    }
  end
  def test_send_and_receive_path_id_afi_1_safi_1
    Timeout::timeout(4) {
      server_add_path_cap = BGP::OPT_PARM::CAP::Add_path.new
      server_add_path_cap.add(:send_and_recv, 1, 1)
      start_server(3456, server_add_path_cap)
      @c = Neighbor.new(4, 100, 180, '0.0.0.2', '127.0.0.1', '127.0.0.1')
      @c.add_cap server_add_path_cap
      @c.start :port=> 3456    
      assert @s.wait_for_state(:Established, 2), "server did not reach Established"
      assert @s.session_info.recv_inet_unicast?, 
      "Should have the capability to recv inet unicast reachability path info."
      assert @s.session_info.send_inet_unicast?, 
      "Should have the capability to send inet unicast reachability path info."
      assert @c.session_info.recv_inet_unicast?, 
      "Should have the capability to recv inet unicast reachability path info."
      assert @c.session_info.send_inet_unicast?, 
      "Should have the capability to send inet unicast reachability path info."
    }
  rescue Timeout::Error
    assert false, "timeout"
  end
  def test_send_path_id_afi_1_safi_1
    Timeout::timeout(4) {
      server_add_path_cap = BGP::OPT_PARM::CAP::Add_path.new
      server_add_path_cap.add(:send, 1, 1)
      client_add_path_cap = BGP::OPT_PARM::CAP::Add_path.new
      client_add_path_cap.add(:recv, 1, 1)
      start_server(3456, server_add_path_cap)
      @c = Neighbor.new(4, 100, 180, '0.0.0.2', '127.0.0.1', '127.0.0.1')
      @c.add_cap client_add_path_cap
      @c.start :port=> 3456    
      assert @s.wait_for_state(:Established, 2), "server did not reach Established"
      assert ! @s.session_info.recv_inet_unicast?, 
      "Should NOT have the capability to recv inet unicast reachability path info."
      assert   @s.session_info.send_inet_unicast?, 
      "Should have the capability to send inet unicast reachability path info."
      assert @c.session_info.recv_inet_unicast?, 
      "Should have the capability to recv inet unicast reachability path info."
      assert ! @c.session_info.send_inet_unicast?, 
      "Should NOT have the capability to send inet unicast reachability path info."
    }
  rescue Timeout::Error
    assert false, "timeout"

  end
  def test_recv_path_id_afi_1_safi_1
    Timeout::timeout(4) {
      server_add_path_cap = BGP::OPT_PARM::CAP::Add_path.new
      server_add_path_cap.add(:recv, 1, 1)
      client_add_path_cap = BGP::OPT_PARM::CAP::Add_path.new
      client_add_path_cap.add(:send, 1, 1)
      start_server(3456, server_add_path_cap)
      @c = Neighbor.new(4, 100, 180, '0.0.0.2', '127.0.0.1', '127.0.0.1')
      @c.add_cap client_add_path_cap
      @c.start :port=> 3456    
      assert @s.wait_for_state(:Established, 2), "server did not reach Established"
      assert  @s.session_info.recv_inet_unicast?, 
      "Should have the capability to recv inet unicast reachability path info."
      assert !  @s.session_info.send_inet_unicast?, 
      "Should NOT have the capability to send inet unicast reachability path info."
      assert ! @c.session_info.recv_inet_unicast?, 
      "Should NOT have the capability to recv inet unicast reachability path info."
      assert  @c.session_info.send_inet_unicast?, 
      "Should have the capability to send inet unicast reachability path info."
    }
  rescue Timeout::Error
    assert false, "timeout"

  end
  def test_nor_recv_nor_send_path_id_afi_1_safi_1
    Timeout::timeout(4) {
      server_add_path_cap = BGP::OPT_PARM::CAP::Add_path.new
      server_add_path_cap.add(:recv, 1, 1)
      client_add_path_cap = BGP::OPT_PARM::CAP::Add_path.new
      client_add_path_cap.add(:recv, 1, 1)
      start_server(3456, server_add_path_cap)
      @c = Neighbor.new(4, 100, 180, '0.0.0.2', '127.0.0.1', '127.0.0.1')
      @c.add_cap client_add_path_cap
      @c.start :port=> 3456    
      assert @s.wait_for_state(:Established, 2), "server did not reach Established"
      assert ! @s.session_info.recv_inet_unicast?, 
      "Should NOT have the capability to recv inet unicast reachability path info."
      assert !  @s.session_info.send_inet_unicast?, 
      "Should NOT have the capability to send inet unicast reachability path info."
      assert ! @c.session_info.recv_inet_unicast?, 
      "Should NOT have the capability to recv inet unicast reachability path info."
      assert ! @c.session_info.send_inet_unicast?, 
      "Should have the capability to send inet unicast reachability path info."
    }
  rescue Timeout::Error
    assert false, "timeout"
  end
  def test_add_capabilities_using_sym
    neighbor = Neighbor.new(4,100,180,'0.0.0.2')
    neighbor.capability :as4_byte
    neighbor.capability :route_refresh
    neighbor.capability :route_refresh, 128
    neighbor.capability :mbgp, :ipv4, :unicast
    neighbor.capability :mbgp, :ipv4, :multicast
    assert_equal('ffffffffffffffffffffffffffffffff003d0104006400b400000002200206410400000064020202000202800002060104000100010206010400010002', neighbor.open.to_shex)
    assert_equal(5, neighbor.instance_eval { @opt_parms}.size)
  end
  def test_add_capabilities_using_method_missing
    n = Neighbor.new(4,100,180,'0.0.0.2')
    n.capability_mbgp_ipv4_unicast
    n.capability_mbgp_ipv4_multicast
    n.capability_mbgp_ipv4_mpls_vpn_unicast
    n.capability_mbgp_ipv6_mpls_vpn_multicast
    n.capability_mbgp_nsap_mpls_vpn_unicast
    n.capability_mbgp_nsap_unicast
    n.capability_route_refresh
    n.capability_route_refresh 128
    n.capability_four_byte_as
    assert_equal(9, n.instance_eval { @opt_parms }.size )
    assert_equal('ffffffffffffffffffffffffffffffff005d0104006400b4000000024002060104000100010206010400010002020601040001008002060104000200810206010400030080020601040003000102020200020280000206410400000064', n.open.to_shex)
  end
end
