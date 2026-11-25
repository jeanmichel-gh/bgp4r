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

require 'socket'

module BGP
  module Daemon

    # TCP MD5, RFC 2385, for a neighbor with `password: KEY`.
    # docs/design/bgp-operations.md, section 6, is the design. TCP-AO,
    # RFC 5925, is its pull request 6b and comes here too.
    #
    # RFC 2385 section 2: every segment carries an MD5 digest of the
    # segment and a key both ends share, and "A failing comparison must
    # result in the segment being dropped and must not produce any
    # response back to the sender". The kernel does all of it, once a
    # socket has a key for the peer's address through `TCP_MD5SIG`. A
    # segment without a digest, or with a wrong one, is dropped and
    # counted in `/proc/net/netstat`: `TCPMD5NotFound` and
    # `TCPMD5Failure`.
    #
    # Measured on Linux 7.0, 2026-11-25, as an unprivileged user, and held
    # by test/functional/tcp_auth_test.rb:
    #
    # * a key set on a listener for a peer's address is the key of every
    #   connection accepted from that address, from the SYN on;
    # * a dialling socket needs its key before `connect`, since the SYN
    #   carries the digest;
    # * a dual-stack IPv6 listener needs an IPv4 peer's key under its
    #   IPv4-mapped address, ::ffff:a.b.c.d.
    #
    # And, as root in a network namespace, since a VRF device needs it: a
    # listener and a client bound to a VRF device take keys with no
    # ifindex, so a CE's session needs no `TCP_MD5SIG_EXT`. No test holds
    # that one; docs/design/bgp-operations.md section 6 has the steps.
    module TcpAuth

      # Linux's values, from /usr/include/linux/tcp.h. Ruby defines the
      # first and not the others.
      TCP_MD5SIG = Socket.const_defined?(:TCP_MD5SIG) ? Socket::TCP_MD5SIG : 14
      MAX_KEY = 80 # TCP_MD5SIG_MAXKEYLEN

      module_function

      # Refuses a `password` that is not a key of 1 to 80 octets. nil is
      # none. An Integer is taken as its digits, since YAML reads
      # `password: 1234` as one and so do set lines; a key with leading
      # zeros has to be quoted in YAML to keep them.
      def check(value, address)
        return if value.nil?
        key = value.to_s if value.is_a?(String) || value.is_a?(Integer)
        return if key && key.bytesize.between?(1, MAX_KEY)
        raise ArgumentError,
              "neighbor #{address}: password is a key of 1 to #{MAX_KEY} octets, " \
              "got #{value.is_a?(String) ? "#{value.bytesize} octets" : value.class}"
      end

      # `struct tcp_md5sig`, 216 octets: the peer's address in a 128-octet
      # sockaddr_storage, flags, prefix length, key length, ifindex, and an
      # 80-octet key. Flags, prefix length and ifindex are 0: one address,
      # any interface.
      def md5sig(address, key)
        key = key.to_s.b
        Socket.sockaddr_in(0, address).ljust(128, "\0") +
          [0, 0, key.bytesize, 0].pack('CCSl') + key.ljust(MAX_KEY, "\0")
      end

      # Gives `sock` the key for segments to and from `address`. On an
      # IPv6 socket an IPv4 address is written IPv4-mapped, which is how
      # such a peer's segments reach it.
      def md5(sock, address, key)
        if sock.local_address.ipv6? && !address.include?(':')
          address = "::ffff:#{address}"
        end
        sock.setsockopt(Socket::IPPROTO_TCP, TCP_MD5SIG, md5sig(address, key))
        sock
      end
    end
  end
end
