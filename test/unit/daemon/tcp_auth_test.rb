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

  # ---- TCP-AO ----

  def ao(*keys)
    { 'keys' => keys.map.with_index { |k, i| { 'send_id' => i, 'recv_id' => i, 'key' => "k#{i}" }.merge(k) } }
  end

  def ao_speaker(tcp_ao, extra = {})
    speaker([{ 'address' => '10.0.0.2', 'as' => 65_001, 'tcp_ao' => tcp_ao }.merge(extra)])
  end

  def test_linux_tcp_ao_add_key_is_38
    assert_equal(38, A::TCP_AO_ADD_KEY)
  end

  # struct tcp_ao_add, /usr/include/linux/tcp.h: a 128-octet
  # sockaddr_storage, a 64-octet algorithm name, ifindex, the two flag
  # bits, padding, prefix, SendID, RecvID, MAC length, key flags, key
  # length and an 80-octet key: 288 octets.
  def test_the_ao_struct_is_laid_out_as_linux_reads_it
    key = { :send_id => 3, :recv_id => 4, :key => 'abc', :algorithm => 'cmac(aes128)', :mac_length => 12 }
    s = A.ao_add('10.0.0.2', key, 32)
    assert_equal(288, s.bytesize)
    assert_equal(Socket.sockaddr_in(0, '10.0.0.2'), s[0, 16])
    assert_equal("\0" * 112, s[16, 112])
    assert_equal('cmac(aes128)'.ljust(64, "\0"), s[128, 64])
    assert_equal([0, 0, 0, 32, 3, 4, 12, 0, 3], s[192, 16].unpack('lLSCCCCCC'))
    assert_equal('abc' + "\0" * 77, s[208, 80])
    assert_equal(0b11, A.ao_add('10.0.0.2', key, 32, current: true)[196, 4].unpack1('L'))
  end

  # The kernel's choices, measured: a dialling socket's first key is
  # current and RNext, or it signs with the last; a listening socket
  # refuses either flag. An IPv4 peer of an IPv6 socket is mapped, with
  # prefix 32, the only prefix the kernel takes for it.
  def test_ao_sets_each_key_with_the_flags_and_prefix_the_kernel_wants
    keys = A.ao_keys(ao({}, {}))
    [[:INET, '10.0.0.2', true, '10.0.0.2', 32, [3, 0]],
     [:INET, '10.0.0.2', false, '10.0.0.2', 32, [0, 0]],
     [:INET6, '10.0.0.2', true, '::ffff:10.0.0.2', 32, [3, 0]],
     [:INET6, '2001:db8::2', false, '2001:db8::2', 128, [0, 0]]].each do |family, peer, dial, address, prefix, bits|
      sock = Socket.new(family, :STREAM)
      got = []
      sock.define_singleton_method(:setsockopt) { |*a| got << a }
      A.ao(sock, peer, keys, dial: dial)
      assert_equal([[Socket::IPPROTO_TCP, 38]] * 2, got.map { |a| a[0, 2] })
      assert_equal(Socket.sockaddr_in(0, address), got[0][2][0, Socket.sockaddr_in(0, address).bytesize], peer)
      assert_equal([prefix] * 2, got.map { |a| a[2][202].ord }, peer)
      assert_equal(bits, got.map { |a| a[2][196, 4].unpack1('L') }, "#{family} #{peer} dial #{dial}")
    ensure
      sock&.close
    end
  end

  # RFC 5926: HMAC-SHA-1-96 is the default, and 96 bits is 12 octets.
  def test_ao_keys_fill_in_the_defaults_in_order
    keys = A.ao_keys(ao({ 'key' => 1234 }, { 'algorithm' => 'cmac(aes128)', 'mac_length' => 16 }))
    assert_equal([{ :send_id => 0, :recv_id => 0, :key => '1234', :algorithm => 'hmac(sha1)', :mac_length => 12 },
                  { :send_id => 1, :recv_id => 1, :key => 'k1', :algorithm => 'cmac(aes128)', :mac_length => 16 }],
                 keys)
  end

  def test_tcp_ao_that_reads_is_taken
    [ao({}), ao({ 'send_id' => 255, 'recv_id' => 0, 'key' => 'k' * 80 }, {}),
     ao({ 'algorithm' => 'cmac(aes128)', 'mac_length' => 1 }), ao({ 'mac_length' => 16 })].each do |v|
      assert_nothing_raised(v.inspect) { ao_speaker(v) }
    end
    assert_equal('k0', ao_speaker(ao({})).peer('10.0.0.2').tcp_ao.first[:key])
  end

  # Each refusal names the neighbor and never carries a key.
  def test_tcp_ao_that_does_not_read_is_refused_without_showing_a_key
    [[ao({}), { 'password' => 'kkkk' }, /password and tcp_ao together; RFC 5925 section 8/],
     [{ 'kees' => [] }, {}, /tcp_ao is \{keys: \[...\]\}, got kees/],
     [[1], {}, /tcp_ao is \{keys: \[...\]\}, got Array/],
     [{ 'keys' => [] }, {}, /keys is a list of one key or more/],
     [{ 'keys' => ['kkkk'] }, {}, /key 0 is a mapping of send_id, recv_id, key, algorithm, mac_length, got String/],
     [ao({ 'sendid' => 1 }), {}, /key 0: unknown key\(s\) sendid/],
     [ao({ 'send_id' => 256 }), {}, /key 0: send_id is 0 to 255, got 256/],
     [ao({ 'recv_id' => nil }), {}, /key 0: recv_id is 0 to 255, got nil/],
     [ao({ 'key' => '' }), {}, /key 0: key is 1 to 80 octets, got 0 octets/],
     [ao({ 'key' => 'k' * 81 }), {}, /key 0: key is 1 to 80 octets, got 81 octets/],
     [ao({ 'key' => true }), {}, /key 0: key is 1 to 80 octets, got TrueClass/],
     [ao({ 'algorithm' => 'hmac(sha256)' }), {}, /algorithm is hmac\(sha1\) or cmac\(aes128\), got "hmac\(sha256\)"/],
     [ao({ 'mac_length' => 0 }), {}, /mac_length is 1 to 16 octets, got 0/],
     [ao({ 'mac_length' => 17 }), {}, /mac_length is 1 to 16 octets, got 17/],
     [ao({}, { 'send_id' => 0 }), {}, /two keys have send_id 0; RFC 5925 section 3.1/],
     [ao({}, { 'recv_id' => 0 }), {}, /two keys have recv_id 0; RFC 5925 section 3.1/]].each do |v, extra, why|
      e = assert_raise(ArgumentError, v.inspect) { ao_speaker(v, extra) }
      assert_match(/\Aneighbor 10.0.0.2: /, e.message)
      assert_match(why, e.message)
      assert_no_match(/kkk/, e.message)
    end
  end

  def test_show_peers_says_tcp_ao_and_not_the_key
    sp = speaker([{ 'address' => '10.0.0.2', 'as' => 65_001, 'tcp_ao' => ao({ 'key' => 's3cret' }) }])
    row = BGP::Daemon::Views.new(sp).peers.first
    assert_equal('tcp-ao', row[:auth])
    assert_no_match(/s3cret/, row.inspect)
  end
end
