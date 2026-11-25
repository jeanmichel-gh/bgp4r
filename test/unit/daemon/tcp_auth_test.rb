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

# TCP MD5's struct and its configuration. What the kernel does with the
# key is test/functional/tcp_auth_test.rb, over loopback.
class TestDaemonTcpAuth < Test::Unit::TestCase

  A = BGP::Daemon::TcpAuth

  def speaker(neighbors)
    BGP::Daemon::Speaker.new('as' => 65_000, 'router_id' => '10.0.0.1', 'neighbors' => neighbors)
  end

  def test_linux_tcp_md5sig_is_14
    assert_equal(14, A::TCP_MD5SIG)
  end

  # struct tcp_md5sig, /usr/include/linux/tcp.h: a 128-octet
  # sockaddr_storage, flags, prefix length, key length, ifindex, and an
  # 80-octet key.
  def test_the_struct_is_laid_out_as_linux_reads_it
    s = A.md5sig('10.0.0.2', 'abc')
    assert_equal(216, s.bytesize)
    assert_equal(Socket.sockaddr_in(0, '10.0.0.2'), s[0, 16])
    assert_equal("\0" * 112, s[16, 112])
    assert_equal([0, 0, 3, 0], s[128, 8].unpack('CCSl'))
    assert_equal('abc' + "\0" * 77, s[136, 80])
    assert_equal(Socket.sockaddr_in(0, '2001:db8::2'), A.md5sig('2001:db8::2', 'abc')[0, 28])
  end

  # The kernel refuses an IPv4 address on an IPv6 socket (EINVAL,
  # measured), so md5 writes it IPv4-mapped there.
  def test_an_ipv4_peer_of_an_ipv6_socket_is_keyed_mapped
    sock = Socket.new(:INET6, :STREAM)
    got = nil
    sock.define_singleton_method(:setsockopt) { |*a| got = a }
    A.md5(sock, '10.0.0.2', 'k')
    assert_equal(Socket.sockaddr_in(0, '::ffff:10.0.0.2'), got[2][0, 28])
  ensure
    sock&.close
  end

  def test_keys_of_1_to_80_octets_are_taken
    ['k', 'k' * 80, 1234, 'é' * 40].each do |v|
      assert_nothing_raised(v.inspect) { speaker([{ 'address' => '10.0.0.2', 'as' => 65_001, 'password' => v }]) }
    end
  end

  # Anything else is refused at start, by name, and the message never
  # carries the key.
  def test_anything_else_is_refused_without_showing_it
    [['', /got 0 octets/], ['k' * 81, /got 81 octets/], [true, /got TrueClass/],
     [['k'], /got Array/], [1.5, /got Float/]].each do |v, why|
      e = assert_raise(ArgumentError, v.inspect) do
        speaker([{ 'address' => '10.0.0.2', 'as' => 65_001, 'password' => v }])
      end
      assert_match(/neighbor 10.0.0.2: password is a key of 1 to 80 octets, /, e.message)
      assert_match(why, e.message)
      assert_no_match(/kkk/, e.message)
    end
  end

  def test_the_peer_reads_an_integer_key_as_its_digits
    sp = speaker([{ 'address' => '10.0.0.2', 'as' => 65_001, 'password' => 1234 }])
    assert_equal('1234', sp.peer('10.0.0.2').password)
  end

  # A peer row says `auth: md5` and never the key, and only where a key
  # is set, so every other row reads as it always has.
  def test_show_peers_says_md5_and_not_the_key
    sp = speaker([{ 'address' => '10.0.0.2', 'as' => 65_001, 'password' => 's3cret' },
                  { 'address' => '10.0.0.3', 'as' => 65_001 }])
    rows = BGP::Daemon::Views.new(sp).peers.to_h { |r| [r[:address], r] }
    assert_equal('md5', rows['10.0.0.2'][:auth])
    assert_equal(false, rows['10.0.0.3'].key?(:auth))
    assert_no_match(/s3cret/, rows.inspect)
  end
end
