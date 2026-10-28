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

# These three are included into the test class and nowhere else. At the top
# level they went into Object, so every test file the suite loaded after
# this one saw those names too, and BGP::OPT_PARM::CAP won the ones it
# shares with BGP: a bare Orf meant the ORF capability rather than
# BGP::Orf, and the same for Route_refresh and Dynamic. A test written that
# way passed on its own and failed in the suite.
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
      port = start_server(0)
      @c = Neighbor.new(4, 100, 180, '0.0.0.2', '127.0.0.1', '127.0.0.1')
      @c.start :port=> port
      assert_equal('Established', @c.state)
      assert @s.wait_for_state(:Established, 2), "server did not reach Established"
      assert_equal('Established', @s.state)
    }
  rescue Timeout::Error
    assert false, "Timeout"
  end
  def test_start_no_blocking
    Timeout::timeout(4) {
      port = start_server(0)
      @c = Neighbor.new(4, 100, 180, '0.0.0.2', '127.0.0.1', '127.0.0.1')
      @c.start :port=> port, :no_blocking=>true
      assert_equal('OpenSent', @c.state)
    }
  rescue Timeout::Error
    assert false, "Timeout"
  end
  def test_start_blocking
    Timeout::timeout(4) {
      port = start_server(0)
      @c = Neighbor.new(4, 100, 180, '0.0.0.2', '127.0.0.1', '127.0.0.1')
      @c.start :port=> port, :no_blocking=>false
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
  # stop closes the output queue before it sets the state to Idle, so a
  # message the event thread is still handling can make the FSM answer on a
  # queue that is already gone. The event thread must survive that: it has
  # to outlive stop so start works again, and close joins it.
  #
  # Driven straight through Neighbor#update, the way IO::Input does, so the
  # ordering is forced instead of raced: state OpenConfirm, output queue
  # closed, then a KEEPALIVE arrives.
  def test_event_thread_survives_a_reply_on_a_closed_output_queue
    ours, theirs = UNIXSocket.pair
    n = Neighbor.new(:my_as=> 100, :id=> '1.1.1.1')
    n.start(:session=> ours, :no_blocking=> true)
    event_thread = n.instance_variable_get(:@event_thread)
    updates = Catcher.new(Update)
    n.add_observer updates
    n.new_state(:OpenConfirm, 'test')
    n.instance_variable_get(:@out).close
    # rcv_keepalive answers with a KEEPALIVE, and has nowhere to put it.
    n.update(:ev_msg, 4, Keepalive.new.encode)
    # Before the fix the event thread died on that one, so this never came.
    n.update(:ev_msg, 2, Update.new(Path_attribute.new(Origin.new(0), As_path.new(100),
                                                       Next_hop.new('127.0.0.1')),
                                    Nlri.new('10.0.0.0/8')).encode)
    assert updates.pop, 'the event thread stopped handling events'
    assert event_thread.alive?, 'the event thread must outlive a send on a closed queue'
    assert_nothing_raised { n.close }
    assert ! event_thread.alive?
  ensure
    n.close if n and not n.closed?
    [ours, theirs].each { |s| s.close unless s.closed? }
  end

  def test_send_message_on_a_closed_session_raises_session_closed
    ours, theirs = UNIXSocket.pair
    n = Neighbor.new(:my_as=> 100, :id=> '1.1.1.1')
    n.start(:session=> ours, :no_blocking=> true)
    n.stop
    e = assert_raise(Neighbor::SessionClosed) { n.send_message Keepalive.new }
    assert_match(/session closed/, e.message)
    # A send before start is another thing and must not be taken for it.
    before = Neighbor.new(:my_as=> 100)
    e2 = assert_raise(RuntimeError) { before.send_message Keepalive.new }
    assert ! e2.is_a?(Neighbor::SessionClosed), 'a send before start is not a closed session'
    before.close
  ensure
    n.close if n
    [ours, theirs].each { |s| s.close unless s.closed? }
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
      port = start_server(0, server_add_path_cap)
      @c = Neighbor.new(4, 100, 180, '0.0.0.2', '127.0.0.1', '127.0.0.1')
      @c.add_cap server_add_path_cap
      @c.start :port=> port    
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
      port = start_server(0, server_add_path_cap)
      @c = Neighbor.new(4, 100, 180, '0.0.0.2', '127.0.0.1', '127.0.0.1')
      @c.add_cap client_add_path_cap
      @c.start :port=> port    
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
      port = start_server(0, server_add_path_cap)
      @c = Neighbor.new(4, 100, 180, '0.0.0.2', '127.0.0.1', '127.0.0.1')
      @c.add_cap client_add_path_cap
      @c.start :port=> port    
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
      port = start_server(0, server_add_path_cap)
      @c = Neighbor.new(4, 100, 180, '0.0.0.2', '127.0.0.1', '127.0.0.1')
      @c.add_cap client_add_path_cap
      @c.start :port=> port    
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
  def test_add_extended_nexthop_capability
    neighbor = Neighbor.new(4,100,180,'0.0.0.2')
    neighbor.capability :extended_nexthop
    neighbor.capability :extended_nexthop, 1, 128, 2
    # RFC 8950 section 4: capability code 5, <AFI, SAFI, Nexthop AFI>.
    assert_match(/0208 0506 000100010002 0208 0506 000100800002\z/x, neighbor.open.to_shex)
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

  # The guard on Neighbor::CAPABILITIES. Every capability bgp4r implements
  # has to have a name, because the names used to live inside a case in
  # capability and a second list in method_missing, and both fell behind the
  # library: Role, Enhanced Route Refresh, ADD-PATH, ORF and Dynamic
  # Capability could not be asked for by name at all.
  #
  # CAP::Unknown is left out on purpose. It is what the factory builds for a
  # capability code bgp4r does not implement, so it is read off the wire and
  # carries its own code; there is nothing for a name to say.
  def test_every_capability_bgp4r_implements_has_a_name
    found, queue = [], [BGP::OPT_PARM::Capability]
    until queue.empty?
      queue.shift.subclasses.each { |kl| found << kl ; queue << kl }
    end
    implemented = found.select { |kl| kl.name.to_s.start_with?('BGP::OPT_PARM::CAP::') } -
                  [BGP::OPT_PARM::CAP::Unknown]
    # So a walk that found nothing cannot pass this test by default.
    assert_operator implemented.size, :>=, 10
    implemented.each do |kl|
      assert BGP::Neighbor::CAPABILITIES.value?(kl),
             "#{kl} has no name in Neighbor::CAPABILITIES, so no script and no " +
             "lab topology can ask for it"
    end
  end

  # Each name builds its own capability. The code is in the octets: 0x02 is
  # the optional parameter type, then its length, then the capability code.
  def test_each_capability_name_builds_its_own_capability
    { [:route_refresh]           => ['Route_refresh', '02020200'],
      [:rr]                      => ['Route_refresh', '02020200'],
      [:enhanced_route_refresh]  => ['Enhanced_route_refresh', '02024600'],
      [:mbgp, :ipv4, :unicast]   => ['Mbgp', '0206010400010001'],
      [:mbgp_ipv6_unicast]       => ['Mbgp', '0206010400020001'],
      [:as4]                     => ['As4', '0206410400000064'],
      [:four_byte_as]            => ['As4', '0206410400000064'],
      [:graceful_restart, 0, 180] => ['Graceful_restart', '0204400200b4'],
      [:extended_nexthop]        => ['Extended_nexthop', '02080506000100010002'],
      [:add_path, 1, 1, 3]       => ['Add_path', '0206450400010301'],
      [:role, :customer]         => ['Role', '0203090103'],
      [:orf]                     => ['Orf', '02020300'],
      [:dynamic]                 => ['Dynamic', '02024300'],
    }.each do |args, (klass, hex)|
      n = BGP::Neighbor.new(4, 100, 180, '0.0.0.2')
      n.capability(*args)
      cap = n.instance_eval { @opt_parms }.last
      assert_equal "BGP::OPT_PARM::CAP::#{klass}", cap.class.to_s, args.inspect
      assert_equal hex, cap.to_shex, args.inspect
      # A String name too, since a lab topology reads its names out of YAML.
      m = BGP::Neighbor.new(4, 100, 180, '0.0.0.2')
      m.capability(args[0].to_s, *args[1..-1])
      assert_equal hex, m.instance_eval { @opt_parms }.last.to_shex, args.inspect
    end
  end

  # The capability_<name> form used to run down four regular expressions
  # matched as substrings, and "enhanced_route_refresh" contains
  # "route_refresh": it built capability 2 where 70 was asked for, said
  # nothing, and the OPEN went out with the wrong capability in it. Both
  # forms go through the one table now.
  def test_the_capability_name_form_does_not_build_a_different_capability
    n = BGP::Neighbor.new(4, 100, 180, '0.0.0.2')
    n.capability_enhanced_route_refresh
    cap = n.instance_eval { @opt_parms }.last
    assert_equal BGP::OPT_PARM::CAP::Enhanced_route_refresh, cap.class
    assert_equal '02024600', cap.to_shex
    n.capability_add_path 1, 1, 3
    assert_equal '0206450400010301', n.instance_eval { @opt_parms }.last.to_shex
    n.add_capability_role :customer
    assert_equal '0203090103', n.instance_eval { @opt_parms }.last.to_shex
  end

  # A name no capability answers to says so, and says it in the right way:
  # an unknown name through method_missing is still a NoMethodError, where a
  # capability class refusing the arguments it was given is the
  # ArgumentError it raised. Those two used to be the same answer, so
  # capability_role with no Role to send would have read as a missing
  # method.
  def test_an_unknown_capability_name_says_so
    n = BGP::Neighbor.new(4, 100, 180, '0.0.0.2')
    e = assert_raise(BGP::Neighbor::UnknownCapability) { n.capability :nonesuch }
    assert_match(/nonesuch/, e.message)
    assert_match(/route_refresh/, e.message, 'the message lists the names')
    # Still an ArgumentError, so a caller that rescues one still catches it.
    assert_kind_of ArgumentError, e
    # An address family nothing names, and a method of Mbgp that is no
    # address family: the form this replaced sent both to Mbgp.send.
    assert_raise(BGP::Neighbor::UnknownCapability) { n.capability 'mbgp_nonesuch' }
    assert_raise(BGP::Neighbor::UnknownCapability) { n.capability 'mbgp_factory' }
    assert_raise(NoMethodError) { n.capability_nonesuch }
    assert_raise(NoMethodError) { n.capability_mbgp_factory }
    # Role takes a Role, so this is a missing argument and not a missing
    # method.
    e = assert_raise(ArgumentError) { n.capability_role }
    assert_match(/number of arguments/, e.message)
    # Neither form put anything in the OPEN.
    assert_equal 0, n.instance_eval { @opt_parms }.size
  end

  # BGP::Update in full, and it has to be: a nested class does not see the
  # include in the class around it, so this resolved Update only through
  # the top level include that used to be in this file. Worse, a NameError
  # here is invisible, because Neighbor logs an exception from an observer
  # rather than raising it, so the test failed as "server received no
  # UPDATE" and said nothing about the name.
  class UpdateCatcher
    def initialize; @q = Queue.new; end
    def update(msg); @q << msg if msg.is_a?(BGP::Update); end
    def pop(secs=3)
      Timeout.timeout(secs) { @q.pop }
    rescue Timeout::Error
      nil
    end
  end

  def as4_update
    Update.new(
      Path_attribute.new(Origin.new(0), As_path.new(100, 4200000001),
                         Next_hop.new('127.0.0.1'), Aggregator.new('2.2.2.2', 4200000001)),
      Nlri.new('10.0.0.0/8'))
  end

  def update_received_by_server(client, server_cap=nil)
    port = start_server(0, server_cap)
    catcher = UpdateCatcher.new
    @s.add_observer catcher
    @c = client
    assert @c.start(:port=> port), "no session: #{@c.last_error}"
    @c.send_message @sent = as4_update
    got = catcher.pop
    assert got, "server received no UPDATE"
    got.path_attribute
  end

  # The guard for what this file used to do. Three includes at the top level
  # of a test file go into Object, so every file the suite loads after it
  # sees those names, and BGP::OPT_PARM::CAP wins the ones it shares with
  # BGP: a bare Orf then means the ORF capability and not BGP::Orf, and a
  # bare Route_refresh the capability and not the message. A test written
  # that way passes on its own and fails in the suite, which is a long way
  # to go to find two missing words.
  #
  # run_unit.rb requires every test file before any test runs, so this
  # assertion catches a top level include in any file in the suite, not
  # only in this one.
  def test_no_test_file_leaks_bgp_names_into_object
    [BGP, BGP::OPT_PARM::CAP, BGP::TestHelpers].each do |m|
      assert !Object.include?(m),
             "#{m} is included into Object, so its names leak into every " \
             'test file the suite loads after whichever one included it. ' \
             'Include it into the test class instead.'
    end
  end

  def test_auto_as4_default_and_setter
    n = Neighbor.new(4, 100, 180, '0.0.0.2', '127.0.0.1', '127.0.0.1')
    assert n.auto_as4?
    n.auto_as4 = false
    assert ! n.auto_as4?
    assert ! Neighbor.new(:my_as=> 100, :auto_as4=> false).auto_as4?
  end

  # RFC 6793 section 4.2.2: to a peer without the 4-octet AS capability.
  def test_2_octet_session_sends_as_trans_and_as4_attributes
    Timeout::timeout(8) {
      pa = update_received_by_server(Neighbor.new(4, 100, 180, '0.0.0.2', '127.0.0.1', '127.0.0.1'))
      assert_equal '100 23456', pa[:as_path].as_path
      assert_equal '100 4200000001', pa[:as4_path].as_path
      assert_equal 23456, pa[:aggregator].asn
      assert_equal 4200000001, pa[:as4_aggregator].asn
      # The caller's Update is not changed.
      assert_equal '100 4200000001', @sent.path_attribute[:as_path].as_path
      assert @sent.path_attribute.has_no?(As4_path)
    }
  end

  def test_2_octet_session_with_auto_as4_off_sends_as_built
    Timeout::timeout(8) {
      c = Neighbor.new(:version=> 4, :my_as=> 100, :id=> '0.0.0.2', :remote_addr=> '127.0.0.1',
                       :local_addr=> '127.0.0.1', :auto_as4=> false)
      pa = update_received_by_server(c)
      assert_equal '100 59905', pa[:as_path].as_path   # 4200000001 cut to 0xea01
      assert pa.has_no?(As4_path)
      assert pa.has_no?(As4_aggregator)
    }
  end

  def test_4_octet_session_sends_no_as4_attributes
    Timeout::timeout(8) {
      c = Neighbor.new(4, 100, 180, '0.0.0.2', '127.0.0.1', '127.0.0.1')
      c.capability :as4_byte
      pa = update_received_by_server(c, As4.new(100))
      assert_equal '100 4200000001', pa[:as_path].as_path
      assert pa.has_no?(As4_path)
      assert pa.has_no?(As4_aggregator)
    }
  end

  class Catcher
    def initialize(klass); @klass, @q = klass, Queue.new; end
    def update(msg); @q << msg if msg.is_a?(@klass); end
    def pop(secs=3)
      Timeout.timeout(secs) { @q.pop }
    rescue Timeout::Error
      nil
    end
  end

  def test_policy_option
    assert_equal :lenient, Neighbor.new(4, 100, 180, '0.0.0.2').policy
    assert_equal :strict, Neighbor.new(:my_as=> 100, :policy=> :strict).policy
    assert_raise(ArgumentError) { Neighbor.new(:my_as=> 100, :policy=> :loose) }
  end

  def bad_update(*attrs)
    Update.new(Path_attribute.new(*attrs), Nlri.new('10.0.0.0/8')).encode
  end

  def strict_client_with_server
    port = start_server(0)
    @server_notifications = Catcher.new(Notification)
    @s.add_observer @server_notifications
    @c = Neighbor.new(:version=> 4, :my_as=> 100, :id=> '0.0.0.2', :remote_addr=> '127.0.0.1',
                      :local_addr=> '127.0.0.1', :policy=> :strict)
    @errors = Catcher.new(Malformed_attribute)
    @c.add_observer @errors
    assert @c.start(:port=> port), "no session: #{@c.last_error}"
    assert @s.wait_for_state(:Established, 2)
    assert_equal :strict, @c.session_info.policy
  end

  # RFC 7606 section 7.1: treat-as-withdraw, the session stays up.
  def test_strict_policy_reports_and_keeps_the_session
    Timeout::timeout(8) {
      strict_client_with_server
      origin = Attr::Raw.new(ATTR::WELL_KNOWN_MANDATORY, ATTR::ORIGIN, "\x00\x00".b)
      @s.send_message bad_update(origin, As_path.new(100), Next_hop.new('127.0.0.1'))
      e = @errors.pop
      assert_instance_of Malformed_attribute, e
      assert_equal [1, 5, :treat_as_withdraw], [e.type, e.subcode, e.action]
      sleep 0.2
      assert @c.is_established?
    }
  end

  # RFC 7606 section 3 (g): a second MP_REACH_NLRI resets the session.
  def test_strict_policy_resets_on_a_session_reset_error
    Timeout::timeout(8) {
      strict_client_with_server
      mp = Mp_reach.new(:afi=>2, :safi=>1, :nexthop=>'2001:db8::1', :nlris=>['2001:db8:1::/48'])
      @s.send_message Update.new(Path_attribute.new(Origin.new(0), As_path.new(100), mp, Mp_reach.new(mp.encode))).encode
      e = @errors.pop
      assert_equal :session_reset, e.action
      n = @server_notifications.pop
      assert n, "server got no NOTIFICATION"
      assert_equal [3, 1], n.to_hash.values_at(:code, :subcode)
      assert @c.wait_for_state(:Idle, 2)
    }
  end
end
