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
require 'bgp/daemon/views'

# TCP MD5, RFC 2385, through a real Speaker over loopback.
#
# Nothing here needs privilege: TCP_MD5SIG is a user's to set, measured
# as uid 1000 on 2026-11-25. The addresses 127.0.0.1 and 127.0.0.2 are
# both local on Linux, which is how one listener serves two peers here.
# Each refusal is checked twice: no session, and the kernel's counter
# that says why, which is what routescope shows for one.
class TestTcpAuth < Test::Unit::TestCase

  A = BGP::Daemon::TcpAuth

  def free_port
    s = TCPServer.new('127.0.0.1', 0)
    s.addr[1]
  ensure
    s&.close
  end

  def speaker(neighbors, port, listen = '127.0.0.1')
    BGP::Daemon::Speaker.new('as' => 65_000, 'router_id' => '10.0.0.1',
                             'listen_address' => listen, 'port' => port,
                             'log_level' => 'error', 'neighbors' => neighbors)
  end

  # A client socket from `from`, signing with `key` when given, dialled
  # to the speaker. Answers the socket once the handshake completes, or
  # nil when it does not within `wait` seconds.
  def dial(port, from:, key: nil, ao: nil, wait: 2)
    s = Socket.new(:INET, :STREAM)
    s.bind(Addrinfo.tcp(from, 0))
    A.md5(s, '127.0.0.1', key) if key
    A.ao(s, '127.0.0.1', A.ao_keys(ao), dial: true) if ao
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

  # A BGP session on `sock`, as a peer with AS `as`.
  def neighbor(sock, as = 65_001, id = '10.0.0.9')
    n = BGP::Neighbor.new(:my_as => as, :remote_addr => '127.0.0.1', :id => id)
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

  def counter(name)
    lines = File.readlines('/proc/net/netstat').select { |l| l.start_with?('TcpExt:') }
    keys, values = lines.map(&:split)
    i = keys.index(name)
    i ? values[i].to_i : nil
  end

  # Asserts the block grows the kernel counter `name`, where it exists,
  # and answers what the block did.
  def assert_counted(name)
    before = counter(name)
    got = yield
    assert_operator(counter(name), :>, before, "the kernel counted #{name}") if before
    got
  end

  def test_a_peer_with_the_same_key_comes_up
    port = free_port
    sp = speaker([{ 'address' => '127.0.0.1', 'as' => 65_001, 'password' => 's3cret' }], port).start
    sock = dial(port, from: '127.0.0.1', key: 's3cret')
    assert_not_nil(sock, 'the handshake completed')
    n = neighbor(sock)
    assert_equal(true, wait_until { sp.peer('127.0.0.1').established? }, 'the session came up')
  ensure
    n&.stop
    sp&.stop
  end

  # RFC 2385 section 2: a segment that fails is dropped with no response,
  # so the client sees a timeout and not a reset.
  def test_a_peer_without_a_key_is_never_heard
    port = free_port
    sp = speaker([{ 'address' => '127.0.0.1', 'as' => 65_001, 'password' => 's3cret' }], port).start
    assert_counted('TCPMD5NotFound') { assert_nil(dial(port, from: '127.0.0.1'), 'the SYN was dropped') }
  ensure
    sp&.stop
  end

  def test_a_peer_with_another_key_is_never_heard
    port = free_port
    sp = speaker([{ 'address' => '127.0.0.1', 'as' => 65_001, 'password' => 's3cret' }], port).start
    assert_counted('TCPMD5Failure') { assert_nil(dial(port, from: '127.0.0.1', key: 'other')) }
  ensure
    sp&.stop
  end

  # The other way round: a peer signs and we have no key for it.
  def test_a_signed_segment_where_we_have_no_key_is_dropped
    port = free_port
    sp = speaker([{ 'address' => '127.0.0.1', 'as' => 65_001 }], port).start
    assert_counted('TCPMD5Unexpected') { assert_nil(dial(port, from: '127.0.0.1', key: 's3cret')) }
  ensure
    sp&.stop
  end

  # The listener holds keys per address, so a passive peer without one
  # shares it unharmed, and the keyed peer beside it is still held to
  # its key.
  def test_a_peer_without_a_password_shares_the_listener_unharmed
    port = free_port
    sp = speaker([{ 'address' => '127.0.0.1', 'as' => 65_001, 'password' => 's3cret' },
                  { 'address' => '127.0.0.2', 'as' => 65_002 }], port).start
    sock = dial(port, from: '127.0.0.2')
    assert_not_nil(sock)
    n = neighbor(sock, 65_002, '10.0.0.8')
    assert_equal(true, wait_until { sp.peer('127.0.0.2').established? })
    assert_nil(dial(port, from: '127.0.0.1'), 'the keyed peer without its key')
  ensure
    n&.stop
    sp&.stop
  end

  # A dual-stack IPv6 listener keys an IPv4 peer under its IPv4-mapped
  # address. Unmapped, the kernel refuses the key with EINVAL and the
  # speaker would not start. Only the handshake is checked: the listener
  # matches an accepted connection by `remote_address`, which is
  # ::ffff:127.0.0.1 there, so no IPv4 peer's session comes up on a
  # dual-stack listener, key or none (measured on master, 2026-11-25).
  def test_an_ipv4_peer_of_a_dual_stack_listener_is_keyed
    port = free_port
    sp = speaker([{ 'address' => '127.0.0.1', 'as' => 65_001, 'password' => 's3cret' }], port, '::').start
    assert_not_nil(dial(port, from: '127.0.0.1', key: 's3cret'), 'its key is taken')
    assert_counted('TCPMD5Failure') do
      assert_nil(dial(port, from: '127.0.0.1', key: 'other'), 'and checked')
    end
  ensure
    sp&.stop
  end

  # The active side signs its SYN, which a listener keyed for it is the
  # proof of. Its control is the same peer without a password, whose
  # unsigned SYN that listener drops.
  def test_an_active_peer_dials_with_its_key
    [['s3cret', true], [nil, false]].each do |key, expect|
      port = free_port
      server = Socket.new(:INET, :STREAM)
      server.setsockopt(:SOCKET, :REUSEADDR, true)
      server.bind(Addrinfo.tcp('127.0.0.1', port))
      server.listen(4)
      A.md5(server, '127.0.0.1', 's3cret')
      n = { 'address' => '127.0.0.1', 'as' => 65_001, 'connect' => true, 'port' => port, 'retry' => 30 }
      n['password'] = key if key
      sp = speaker([n], free_port).start
      got = server.wait_readable(3)
      assert_equal(expect, !!got, "password #{key.inspect}")
    ensure
      sp&.stop
      server&.close
    end
  end

  # ---- TCP-AO, RFC 5925 ----

  # A `tcp_ao` of one key per [send_id, recv_id, key].
  def ao(*keys)
    { 'keys' => keys.map { |snd, rcv, key| { 'send_id' => snd, 'recv_id' => rcv, 'key' => key } } }
  end

  def ao_peer(tcp_ao, address = '127.0.0.1')
    { 'address' => address, 'as' => 65_001, 'tcp_ao' => tcp_ao }
  end

  def test_tcp_ao_a_peer_with_the_same_key_comes_up
    port = free_port
    sp = speaker([ao_peer(ao([1, 1, 's3cret']))], port).start
    sock = assert_counted('TCPAOGood') { dial(port, from: '127.0.0.1', ao: ao([1, 1, 's3cret'])) }
    assert_not_nil(sock, 'the handshake completed')
    n = neighbor(sock)
    assert_equal(true, wait_until { sp.peer('127.0.0.1').established? }, 'the session came up')
    assert_equal('tcp-ao', BGP::Daemon::Views.new(sp).peers.first[:auth])
  ensure
    n&.stop
    sp&.stop
  end

  # Section 7.5 step 2: a segment whose MAC differs is silently
  # discarded, so the client sees a timeout and not a reset. One without
  # TCP-AO, from a peer that has keys, is dropped too (TCPAORequired),
  # and an MD5 one is a digest the kernel has no MD5 key for
  # (TCPMD5Unexpected).
  def test_tcp_ao_a_peer_without_its_key_is_never_heard
    port = free_port
    sp = speaker([ao_peer(ao([1, 1, 's3cret']))], port).start
    assert_counted('TCPAOBad') { assert_nil(dial(port, from: '127.0.0.1', ao: ao([1, 1, 'other']))) }
    assert_counted('TCPAORequired') { assert_nil(dial(port, from: '127.0.0.1'), 'no key') }
    assert_counted('TCPMD5Unexpected') { assert_nil(dial(port, from: '127.0.0.1', key: 's3cret'), 'an MD5 key') }
    assert_counted('TCPAOKeyNotFound') { assert_nil(dial(port, from: '127.0.0.1', ao: ao([2, 1, 's3cret'])), 'another KeyID') }
  ensure
    sp&.stop
  end

  # Linux drops a signed SYN it has no key for, and counts it
  # TCPAOKeyNotFound. Section 7.5 step 1.a.i would take it and remove
  # TCP-AO, "this presumes that connections that do not match any MKT
  # should be silently accepted"; the kernel does not, measured.
  def test_tcp_ao_a_signed_segment_where_we_have_no_key_is_dropped
    port = free_port
    sp = speaker([{ 'address' => '127.0.0.1', 'as' => 65_001 }], port).start
    assert_counted('TCPAOKeyNotFound') { assert_nil(dial(port, from: '127.0.0.1', ao: ao([1, 1, 's3cret']))) }
  ensure
    sp&.stop
  end

  # The listener holds every key of a peer and answers with the one the
  # peer's KeyID names, so a peer that starts on the second key comes up.
  def test_tcp_ao_the_listener_answers_with_the_key_the_peer_names
    port = free_port
    sp = speaker([ao_peer(ao([1, 1, 'one'], [2, 2, 'two']))], port).start
    sock = dial(port, from: '127.0.0.1', ao: ao([2, 2, 'two']))
    assert_not_nil(sock)
    n = neighbor(sock)
    assert_equal(true, wait_until { sp.peer('127.0.0.1').established? })
  ensure
    n&.stop
    sp&.stop
  end

  # One listener, three peers: MD5, TCP-AO and none. Each is held to its
  # own, and none harms the others.
  def test_tcp_ao_md5_and_no_key_share_one_listener
    port = free_port
    sp = speaker([ao_peer(ao([1, 1, 's3cret'])),
                  { 'address' => '127.0.0.2', 'as' => 65_002, 'password' => 'md5key' },
                  { 'address' => '127.0.0.3', 'as' => 65_003 }], port).start
    assert_not_nil(dial(port, from: '127.0.0.1', ao: ao([1, 1, 's3cret'])), 'TCP-AO')
    assert_not_nil(dial(port, from: '127.0.0.2', key: 'md5key'), 'MD5')
    assert_not_nil(dial(port, from: '127.0.0.3'), 'none')
    assert_counted('TCPMD5Unexpected') { assert_nil(dial(port, from: '127.0.0.1', key: 's3cret'), 'MD5 where TCP-AO is set') }
    assert_counted('TCPAOKeyNotFound') { assert_nil(dial(port, from: '127.0.0.2', ao: ao([1, 1, 'md5key'])), 'TCP-AO where MD5 is set') }
  ensure
    sp&.stop
  end

  # Keyed IPv4-mapped with prefix 32: with 128 the kernel refuses the key
  # with EINVAL, and the speaker would not start.
  def test_tcp_ao_an_ipv4_peer_of_a_dual_stack_listener_is_keyed
    port = free_port
    sp = speaker([ao_peer(ao([1, 1, 's3cret']))], port, '::').start
    assert_not_nil(dial(port, from: '127.0.0.1', ao: ao([1, 1, 's3cret'])), 'its key is taken')
    assert_counted('TCPAOBad') { assert_nil(dial(port, from: '127.0.0.1', ao: ao([1, 1, 'other'])), 'and checked') }
  ensure
    sp&.stop
  end

  # The active side starts on its first key. A listener holding only the
  # first key takes its SYN; one holding only the second does not, which
  # the last key added would have been without the current flag.
  def test_tcp_ao_an_active_peer_dials_with_its_first_key
    [[[1, 1, 'one'], true], [[2, 2, 'two'], false]].each do |held, expect|
      port = free_port
      server = Socket.new(:INET, :STREAM)
      server.setsockopt(:SOCKET, :REUSEADDR, true)
      server.bind(Addrinfo.tcp('127.0.0.1', port))
      server.listen(4)
      A.ao(server, '127.0.0.1', A.ao_keys(ao(held)))
      n = ao_peer(ao([1, 1, 'one'], [2, 2, 'two'])).merge('connect' => true, 'port' => port, 'retry' => 30)
      sp = speaker([n], free_port).start
      got = server.wait_readable(3)
      assert_equal(expect, !!got, "the listener holds #{held.first(2).inspect}")
    ensure
      sp&.stop
      server&.close
    end
  end
end
