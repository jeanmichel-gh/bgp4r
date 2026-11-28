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

    # TCP MD5, RFC 2385, for a neighbor with `password: KEY`, and TCP-AO,
    # RFC 5925, for one with `tcp_ao: {keys: [...]}`.
    # docs/design/bgp-operations.md, section 6, is the design: pull
    # requests 6a and 6b.
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
      MAX_KEY = 80 # TCP_MD5SIG_MAXKEYLEN, and TCP_AO_MAXKEYLEN too
      TCP_AO_ADD_KEY = 38

      # RFC 5926 section 3.2's two MACs, by the kernel's names for them:
      # HMAC-SHA-1-96 and AES-128-CMAC-96. The first is the default, as
      # section 3.1.1.3 asks of a UI.
      ALGORITHMS = %w[hmac(sha1) cmac(aes128)].freeze
      MAC_LENGTH = 12 # 96 bits, RFC 5926 section 3.2
      # What the kernel takes for both, measured: 17 and over is
      # EMSGSIZE. 0 is taken too, and is refused here as meaningless.
      MAC_LENGTHS = (1..16).freeze
      AO_KEYS = %w[send_id recv_id key algorithm mac_length].freeze

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

      # ---- TCP-AO, RFC 5925 ----
      #
      # A neighbor's `tcp_ao` is a list of Master Key Tuples (section
      # 3.1), each a SendID, a RecvID, a master key and a MAC algorithm.
      # The kernel does the rest: traffic keys, the MACs, and dropping
      # what fails. Measured on Linux 7.0, 2026-11-28, as uid 1000, and
      # held by test/functional/tcp_auth_test.rb:
      #
      # * as for MD5, a listener holds keys per peer address, and a
      #   dialling socket needs its keys before `connect`;
      # * a listening socket refuses `set_current` and `set_rnext`
      #   (EINVAL); a socket before `listen` or `connect` takes them;
      # * a dialling socket with several keys signs with the last one
      #   added unless the first has both flags, so the first key gets
      #   them and is the one a session starts on;
      # * a listener answers with the key the peer's KeyID names, from
      #   those it holds for that peer;
      # * the kernel refuses two keys for one peer that share a SendID or
      #   a RecvID (EEXIST), which is section 3.1's "The IDs of MKTs MUST
      #   NOT overlap";
      # * one listener holds MD5 keys for some peers and TCP-AO keys for
      #   others; one socket refuses TCP-AO for a peer it has an MD5 key
      #   for (EKEYREJECTED), which is section 8's "MUST NOT use both";
      # * a dual-stack IPv6 listener takes an IPv4 peer's key under its
      #   IPv4-mapped address with prefix 32, and refuses 128 (EINVAL);
      # * which counter grows tells why a session is not up: a peer that
      #   signs with a KeyID we have no key for, TCPAOKeyNotFound; one
      #   that does not sign, TCPAORequired; another key, TCPAOBad; an MD5
      #   digest where we hold TCP-AO keys, TCPMD5Unexpected;
      # * a SYN signed where we have no key is dropped (TCPAOKeyNotFound),
      #   where section 7.5 step 1.a.i would take it without TCP-AO.
      #
      # As root in a network namespace: a listener and a client bound to
      # VRF devices take keys with no ifindex, as for MD5.

      # Refuses a `tcp_ao` that does not read, naming the neighbor and
      # never showing a key. `password` is the neighbor's MD5 key: RFC
      # 5925 section 8, "A TCP implementation MUST NOT use both TCP-AO
      # and TCP MD5 for a particular TCP connection".
      def check_ao(value, address, password = nil)
        return if value.nil?
        where = "neighbor #{address}: tcp_ao"
        raise ArgumentError, "neighbor #{address}: password and tcp_ao together; RFC 5925 section 8 allows one" if password
        unless value.is_a?(Hash) && value.keys.map(&:to_s) == ['keys']
          raise ArgumentError, "#{where} is {keys: [...]}, got #{value.is_a?(Hash) ? value.keys.join(', ') : value.class}"
        end
        keys = value.values.first
        raise ArgumentError, "#{where} keys is a list of one key or more" unless keys.is_a?(Array) && !keys.empty?
        keys.each_with_index { |k, i| check_ao_key(k, "#{where} key #{i}") }
        %w[send_id recv_id].each do |id|
          ids = keys.map { |k| k[id] }
          dup = ids.find { |x| ids.count(x) > 1 }
          raise ArgumentError, "#{where}: two keys have #{id} #{dup}; RFC 5925 section 3.1, IDs MUST NOT overlap" if dup
        end
      end

      def check_ao_key(k, where)
        raise ArgumentError, "#{where} is a mapping of #{AO_KEYS.join(', ')}, got #{k.class}" unless k.is_a?(Hash)
        unknown = k.keys.map(&:to_s) - AO_KEYS
        raise ArgumentError, "#{where}: unknown key(s) #{unknown.join(', ')}: a key takes #{AO_KEYS.join(', ')}" unless unknown.empty?
        %w[send_id recv_id].each do |id|
          next if k[id].is_a?(Integer) && k[id].between?(0, 255)
          raise ArgumentError, "#{where}: #{id} is 0 to 255, got #{k[id].inspect}"
        end
        v = k['key']
        key = v.to_s if v.is_a?(String) || v.is_a?(Integer)
        unless key && key.bytesize.between?(1, MAX_KEY)
          raise ArgumentError, "#{where}: key is 1 to #{MAX_KEY} octets, " \
                               "got #{v.is_a?(String) ? "#{v.bytesize} octets" : v.class}"
        end
        alg = k.fetch('algorithm', ALGORITHMS.first)
        raise ArgumentError, "#{where}: algorithm is #{ALGORITHMS.join(' or ')}, got #{alg.inspect}" unless ALGORITHMS.include?(alg)
        mac = k.fetch('mac_length', MAC_LENGTH)
        return if mac.is_a?(Integer) && MAC_LENGTHS.cover?(mac)
        raise ArgumentError, "#{where}: mac_length is #{MAC_LENGTHS.min} to #{MAC_LENGTHS.max} octets, got #{mac.inspect}"
      end

      # The keys of a checked `tcp_ao`, defaults filled in, in order.
      def ao_keys(value)
        value.values.first.map do |k|
          { :send_id => k['send_id'], :recv_id => k['recv_id'], :key => k['key'].to_s,
            :algorithm => k.fetch('algorithm', ALGORITHMS.first), :mac_length => k.fetch('mac_length', MAC_LENGTH) }
        end
      end

      # `struct tcp_ao_add`, 288 octets: the peer's address in a 128-octet
      # sockaddr_storage, a 64-octet algorithm name, ifindex, the
      # set_current and set_rnext bits, padding, prefix, SendID, RecvID,
      # MAC length, key flags, key length, and an 80-octet key. ifindex
      # and key flags are 0: any interface, options in the MAC (section
      # 3.1's option flag, its default).
      def ao_add(address, key, prefix, current: false)
        k = key[:key].b
        bits = current ? 0b11 : 0
        Socket.sockaddr_in(0, address).ljust(128, "\0") + key[:algorithm].ljust(64, "\0") +
          [0, bits, 0, prefix, key[:send_id], key[:recv_id], key[:mac_length], 0, k.bytesize].pack('lLSCCCCCC') +
          k.ljust(MAX_KEY, "\0")
      end

      # Gives `sock` the keys for segments to and from `address`. A
      # dialling socket (`dial: true`) starts on the first key: it is
      # current and the one asked of the peer as RNext. A listener holds
      # them all with no flags, which is all it takes.
      def ao(sock, address, keys, dial: false)
        prefix = address.include?(':') ? 128 : 32
        address = "::ffff:#{address}" if sock.local_address.ipv6? && !address.include?(':')
        keys.each_with_index do |key, i|
          sock.setsockopt(Socket::IPPROTO_TCP, TCP_AO_ADD_KEY, ao_add(address, key, prefix, current: dial && i.zero?))
        end
      end
    end
  end
end
