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
require 'bgp/daemon/speaker'

# GTSM, RFC 5082, through a real Speaker over loopback.
#
# **Loopback does not decrement the TTL**, so a packet arrives with the
# TTL it was sent with, and a peer "two hops away" is a client that sends
# with 254. Nothing here needs privilege: the options are a user's to set,
# measured as uid 1000 on 2026-11-25. The addresses 127.0.0.1 and
# 127.0.0.2 are both local on Linux, which is how one listener serves two
# peers here.
class TestGtsm < Test::Unit::TestCase

  def free_port
    s = TCPServer.new('127.0.0.1', 0)
    s.addr[1]
  ensure
    s&.close
  end

  def speaker(neighbors, port)
    BGP::Daemon::Speaker.new('as' => 65_000, 'router_id' => '10.0.0.1',
                             'listen_address' => '127.0.0.1', 'port' => port,
                             'log_level' => 'error', 'neighbors' => neighbors)
  end

  # A client socket from `from`, sending with `ttl`, dialled to the
  # speaker. Answers the socket once the handshake completes, or nil when
  # it does not within `wait` seconds.
  def dial(port, from:, ttl:, min: nil, wait: 2)
    s = Socket.new(:INET, :STREAM)
    s.bind(Addrinfo.tcp(from, 0))
    s.setsockopt(:IP, :TTL, [ttl].pack('i'))
    s.setsockopt(:IP, :MINTTL, [min].pack('i')) if min
    dest = Addrinfo.tcp('127.0.0.1', port)
    if s.connect_nonblock(dest, exception: false) == :wait_writable
      unless s.wait_writable(wait)
        s.close
        return nil
      end
      begin
        s.connect_nonblock(dest)
      rescue Errno::EISCONN
      end
    end
    s
  end

  # A BGP session on `sock`, as the peer with AS 65001.
  def neighbor(sock)
    n = BGP::Neighbor.new(:my_as => 65_001, :remote_addr => '127.0.0.1', :id => '10.0.0.9')
    Thread.new { n.start(:session => sock, :timeout => 5) rescue nil }
    n
  end

  def wait_until(seconds = 5)
    deadline = Time.now + seconds
    until Time.now > deadline
      return true if yield
      sleep 0.05
    end
    false
  end

  def min_ttl_drops
    lines = File.readlines('/proc/net/netstat').select { |l| l.start_with?('TcpExt:') }
    keys, values = lines.map(&:split)
    i = keys.index('TCPMinTTLDrop')
    i ? values[i].to_i : nil
  end

  def test_a_peer_one_hop_away_comes_up_at_ttl_255
    port = free_port
    sp = speaker([{ 'address' => '127.0.0.1', 'as' => 65_001, 'ttl_security' => 1 }], port).start
    sock = dial(port, from: '127.0.0.1', ttl: 255)
    assert_not_nil(sock, 'the handshake completed')
    n = neighbor(sock)
    assert_equal(true, wait_until { sp.peer('127.0.0.1').established? }, 'the session came up')
  ensure
    n&.stop
    sp&.stop
  end

  # RFC 5082 section 3: a packet of the session below the expected TTL is
  # "Dangerous" and "MAY" be dropped. Here the listener drops the SYN.
  def test_a_peer_whose_packets_arrive_below_255_is_never_heard
    port = free_port
    sp = speaker([{ 'address' => '127.0.0.1', 'as' => 65_001, 'ttl_security' => 1 }], port).start
    before = min_ttl_drops
    assert_nil(dial(port, from: '127.0.0.1', ttl: 254), 'the SYN was dropped')
    assert_operator(min_ttl_drops, :>, before, 'the kernel counted it') if before
  ensure
    sp&.stop
  end

  # The SYN-ACK goes out with the listener's TTL. A peer whose own minimum
  # is 255 drops anything less, so this is what lets it connect at all.
  def test_the_listener_answers_at_255
    port = free_port
    sp = speaker([{ 'address' => '127.0.0.1', 'as' => 65_001, 'ttl_security' => 1 }], port).start
    assert_not_nil(dial(port, from: '127.0.0.1', ttl: 255, min: 255), 'our SYN-ACK passed a minimum of 255')
  ensure
    sp&.stop
  end

  # The control: the same client against a listener with no GTSM peer
  # never connects, since its SYN-ACK goes at the default TTL. Without it
  # the test above could pass for a reason that is not ours.
  def test_without_ttl_security_the_listener_answers_at_the_default
    port = free_port
    sp = speaker([{ 'address' => '127.0.0.1', 'as' => 65_001 }], port).start
    assert_nil(dial(port, from: '127.0.0.1', ttl: 255, min: 255))
  ensure
    sp&.stop
  end

  # The shared listener, docs/design/bgp-operations.md section 5. Peers at
  # 1 and 3 hops: the listener's minimum is 253, so the 1-hop peer's
  # handshake at 254 completes, and the accepted socket, set to 255 for
  # that peer, drops its OPEN. The session never comes up.
  def test_on_a_shared_listener_each_peer_is_held_to_its_own_hops_after_accept
    port = free_port
    sp = speaker([{ 'address' => '127.0.0.1', 'as' => 65_001, 'ttl_security' => 1 },
                  { 'address' => '127.0.0.2', 'as' => 65_002, 'ttl_security' => 3 }], port).start
    assert_equal(253, sp.listener_minimum)
    before = min_ttl_drops
    sock = dial(port, from: '127.0.0.1', ttl: 254)
    assert_not_nil(sock, 'the handshake passed at the listener\'s 253')
    n = neighbor(sock)
    assert_equal(false, wait_until(2) { sp.peer('127.0.0.1').established? },
                 'the OPEN was dropped at the peer\'s own 255')
    assert_operator(min_ttl_drops, :>, before, 'the kernel counted the drop') if before
  ensure
    n&.stop
    sp&.stop
  end

  # A passive peer without GTSM beside one with it: the listener drops no
  # SYN, since this peer's arrive at the sender's default TTL, and its
  # accepted socket gets no minimum. It comes up at TTL 64.
  def test_a_peer_without_ttl_security_shares_the_listener_unharmed
    port = free_port
    sp = speaker([{ 'address' => '127.0.0.1', 'as' => 65_001, 'ttl_security' => 1 },
                  { 'address' => '127.0.0.2', 'as' => 65_001 }], port).start
    assert_nil(sp.listener_minimum, 'a listener with a non-GTSM peer drops nothing')
    sock = dial(port, from: '127.0.0.2', ttl: 64)
    assert_not_nil(sock)
    n = BGP::Neighbor.new(:my_as => 65_001, :remote_addr => '127.0.0.1', :id => '10.0.0.8')
    Thread.new { n.start(:session => sock, :timeout => 5) rescue nil }
    assert_equal(true, wait_until { sp.peer('127.0.0.2').established? })
    # And the GTSM peer is still held to 255 from the accept on.
    low = dial(port, from: '127.0.0.1', ttl: 254)
    assert_not_nil(low, 'its handshake passes too, the listener has no minimum')
    m = neighbor(low)
    assert_equal(false, wait_until(2) { sp.peer('127.0.0.1').established? })
  ensure
    n&.stop
    m&.stop
    sp&.stop
  end

  # The active side: bgp4rd's SYN already goes at 255, which a listener
  # with a minimum of 255 is the proof of. The listener answers at 255
  # too, as a GTSM peer does, since bgp4rd's own minimum of 255 drops a
  # SYN-ACK at the default TTL: that was this test's first failure. Its
  # control is the same peer without ttl_security, whose SYN goes at the
  # default and is dropped.
  def test_an_active_peer_dials_at_255
    [[1, true], [nil, false]].each do |hops, expect|
      port = free_port
      server = TCPServer.new('127.0.0.1', port)
      server.setsockopt(:IP, :MINTTL, [255].pack('i'))
      server.setsockopt(:IP, :TTL, [255].pack('i'))
      n = { 'address' => '127.0.0.1', 'as' => 65_001, 'connect' => true, 'port' => port, 'retry' => 30 }
      n['ttl_security'] = hops if hops
      sp = speaker([n], free_port).start
      got = server.wait_readable(3)
      assert_equal(expect, !!got, "ttl_security #{hops.inspect}")
    ensure
      sp&.stop
      server&.close
    end
  end
end
