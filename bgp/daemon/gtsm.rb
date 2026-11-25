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

    # The Generalized TTL Security Mechanism, RFC 5082, for a neighbor
    # with `ttl_security: HOPS`. docs/design/bgp-operations.md, section
    # 5, is the design.
    #
    # RFC 5082 section 3: "The TTL field in all IP packets used for
    # transmission of messages associated with GTSM-enabled protocol
    # sessions MUST be set to 255", and on receipt a packet of the
    # session whose TTL is outside the expected range is "Dangerous" and
    # "MAY" be dropped. The kernel does both: `IP_TTL` (or
    # `IPV6_UNICAST_HOPS`) sets what we send, and `IP_MINTTL` (or
    # `IPV6_MINHOPCOUNT`) drops what arrives below a minimum, counted in
    # `/proc/net/netstat` as `TCPMinTTLDrop`. A peer HOPS away sends with
    # 255 and arrives with 256 - HOPS, which is the minimum.
    #
    # Measured on Linux 7.0, 2026-11-25, over loopback, as an
    # unprivileged user, and held by test/functional/gtsm_test.rb:
    #
    # * a minimum on a listening socket drops a SYN below it;
    # * an accepted socket starts with its listener's minimum, and a
    #   minimum set on it after `accept` holds for every later segment;
    # * the SYN-ACK goes out with the **listener's** TTL, so a listener
    #   with a GTSM peer sends at 255, or a peer whose own minimum is 255
    #   drops our answer to its SYN;
    # * a dual-stack IPv6 listener filters IPv4 clients by `IP_MINTTL`,
    #   so an IPv6 socket gets both levels set;
    # * -1 puts the TTL back to the kernel's default.
    module Gtsm

      # What a GTSM session sends with, RFC 5082 section 3.
      TTL = 255

      # Ruby 3.3 and 3.4 do not define it. Linux's value, from
      # /usr/include/linux/in6.h.
      IPV6_MINHOPCOUNT = Socket.const_defined?(:IPV6_MINHOPCOUNT) ? Socket::IPV6_MINHOPCOUNT : 73

      # The hops a neighbor may be. 1 is directly connected. 255 would be
      # a minimum of 1, which checks nothing, so it is not taken; FRR's
      # `ttl-security hops` stops at 254 too.
      HOPS = (1..254).freeze

      module_function

      # The lowest TTL a packet from a peer `hops` away arrives with.
      def minimum(hops)
        256 - hops
      end

      # Refuses a `ttl_security` value that is not a whole number of hops
      # in HOPS. nil is no GTSM.
      def check(value, address)
        return if value.nil?
        return if value.is_a?(Integer) && HOPS.cover?(value)
        raise ArgumentError,
              "neighbor #{address}: ttl_security is a number of hops, #{HOPS.min} to #{HOPS.max}, got #{value.inspect}"
      end

      # The minimum of a listener whose passive peers have these hops, nil
      # for each one without `ttl_security`. One listener serves every
      # passive peer, so it can drop only what **every** one of them would:
      #
      # * all GTSM: the lowest minimum any needs, so a peer allowed fewer
      #   hops is checked at the looser value until its connection is
      #   accepted, and `accepted` tightens it then;
      # * any peer without GTSM: none, since its SYN arrives with the
      #   sender's default TTL (64 on Linux) less its hops, and a minimum
      #   would drop it. GTSM peers are then checked from the accept on.
      #
      # nil when there is nothing to drop.
      def listener_minimum(hops)
        return nil if hops.empty? || hops.include?(nil)
        hops.map { |h| minimum(h) }.min
      end

      # A socket of a GTSM session: send at 255, and drop below `min` when
      # one is given. For a dialling socket, before `connect`; for a
      # listener, before any peer dials, so its SYN-ACK goes at 255 too.
      def secure(sock, min)
        each_level(sock) do |level, ttl, min_opt|
          sock.setsockopt(level, ttl, [TTL].pack('i'))
          sock.setsockopt(level, min_opt, [min].pack('i')) if min
        end
        sock
      end

      # An accepted socket, matched to its peer, on a listener `secure`
      # set up. A GTSM peer gets its own minimum. Any other peer gets none,
      # and the kernel's default TTL back, so it runs as if no neighbor
      # had `ttl_security`. Set before the OPEN is read.
      def accepted(sock, hops)
        if hops
          secure(sock, minimum(hops))
        else
          each_level(sock) do |level, ttl, min_opt|
            sock.setsockopt(level, min_opt, [0].pack('i'))
            sock.setsockopt(level, ttl, [-1].pack('i'))
          end
          sock
        end
      end

      # Yields the option names for each IP level the socket's family
      # reads. An IPv6 socket also carries IPv4-mapped connections, which
      # the IPv4 options govern.
      def each_level(sock)
        levels = [[Socket::IPPROTO_IP, Socket::IP_TTL, Socket::IP_MINTTL]]
        if sock.local_address.ipv6?
          levels.unshift([Socket::IPPROTO_IPV6, Socket::IPV6_UNICAST_HOPS, IPV6_MINHOPCOUNT])
        end
        levels.each { |l| yield(*l) }
      end
    end
  end
end
