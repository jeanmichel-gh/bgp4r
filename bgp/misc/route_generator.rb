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

require 'bgp4r'
require 'socket'

module BGP
  # Generates many consecutive prefixes of the same length and packs them
  # into UPDATE messages that share one set of path attributes.
  #
  #   pa  = Path_attribute.new(Origin.new(0), Next_hop.new('10.0.0.1'), As_path.new(100))
  #   gen = RouteGenerator.new('11.0.0.0/28', 1000, 127, pa)
  #   gen.each_update { |u| neighbor.send_message u }
  #
  # The first prefix is start itself: 11.0.0.0/28, then 11.0.0.16/28, and so
  # on. Updates are built one at a time, so a large count never sits in
  # memory at once.
  #
  # Options, as keywords after path_attribute:
  #
  # nexthop::  next hop for MP_REACH_NLRI. Required for IPv6 and with mp_reach.
  #            IPv4 prefixes can take an IPv6 next hop (RFC 8950). The peer
  #            must then have the Extended Next Hop Encoding capability.
  # mp_reach:: true to send IPv4 prefixes in MP_REACH_NLRI instead of plain
  #            NLRI. IPv6 prefixes always go in MP_REACH_NLRI.
  # path_id::  an add-path path ID (RFC 7911) put in front of every prefix.
  #
  #   gen = RouteGenerator.new('2001:db8::/48', 1000, 100, pa, nexthop: '2001:db8::1')
  #   gen = RouteGenerator.new('11.0.0.0/24', 1000, 100, pa, path_id: 0x100)
  #
  # With MP_REACH_NLRI, each Update gets a copy of path_attribute with its
  # MP_REACH_NLRI attribute replaced, or added if it had none. The given
  # path_attribute is not changed. Other attributes, NEXT_HOP included, are
  # kept as given.
  class RouteGenerator
    # RFC 4271 section 4: a BGP message is at most 4096 octets.
    MAX_MESSAGE_SIZE = 4096

    # RFC 7911 section 3: the Path Identifier is four octets.
    MAX_PATH_ID = 0xffffffff

    attr_reader :count, :per_update, :path_attribute, :nexthop, :path_id, :afi

    def initialize(start, count, per_update=1, path_attribute=nil, nexthop: nil, mp_reach: nil, path_id: nil)
      @first = begin
        IPAddr.new(start.to_s)
      rescue IPAddr::Error => e
        raise ArgumentError, "invalid start prefix #{start.inspect}: #{e.message}"
      end
      @mlen = @first.prefix
      if @first.ipv4?
        @afi, @bits, @family = IANA::AFI::IPv4, 32, Socket::AF_INET
      else
        @afi, @bits, @family = IANA::AFI::IPv6, 128, Socket::AF_INET6
      end
      @step = 2**(@bits - @mlen)
      @count, @per_update = Integer(count), Integer(per_update)
      raise ArgumentError, "count must be at least 1, got #{@count}" if @count < 1
      raise ArgumentError, "per_update must be at least 1, got #{@per_update}" if @per_update < 1
      if @first.to_i + (@count - 1) * @step > 2**@bits - 1
        raise ArgumentError, "#{@count} prefixes from #{start} run past #{IPAddr.new(2**@bits - 1, @family)}"
      end
      @path_attribute = path_attribute
      @mp_reach = set_mp_reach(start, mp_reach)
      @nexthop = set_nexthop(nexthop)
      @path_id = set_path_id(path_id)
    end

    # True when prefixes go in MP_REACH_NLRI, false for plain NLRI.
    def mp_reach? ; @mp_reach ; end

    # The first prefix, as "a.b.c.d/len" or "x:x::/len".
    def start ; prefix(0) ; end

    # The last prefix.
    def last ; prefix(@count - 1) ; end

    # The i-th prefix, counting from 0.
    def prefix(i)
      raise IndexError, "prefix #{i} is outside 0..#{@count - 1}" unless (0...@count) === i
      "#{IPAddr.new(@first.to_i + i * @step, @family)}/#{@mlen}"
    end

    def each_prefix
      return enum_for(:each_prefix) { @count } unless block_given?
      @count.times { |i| yield prefix(i) }
    end

    # How many UPDATE messages each_update yields.
    def update_count
      (@count + @per_update - 1) / @per_update
    end

    # Yields one Update per batch of per_update prefixes. The last one may
    # hold fewer. Raises ArgumentError if a full batch would not fit in one
    # BGP message. Pass the session info (Neighbor#session_info) to size
    # the messages as the session will encode them, with 4 byte ASes.
    def each_update(session_info=nil)
      return enum_for(:each_update, session_info) { update_count } unless block_given?
      (0...@count).step(@per_update) do |i|
        n = [@per_update, @count - i].min
        u = build_update((i...i + n).map { |j| prefix(j) })
        # Every prefix has the same length, so the first batch is the largest.
        check_size(u, session_info) if i == 0
        yield u
      end
    end

    private

    def build_update(prefixes)
      if @mp_reach
        # RFC 4760 section 3: MP_REACH_NLRI carries the AFI, the SAFI, the
        # next hop and the NLRI. SAFI 1 is unicast. With add-path, each NLRI
        # gets the Path Identifier in front (RFC 7911 section 3).
        h = { :afi => @afi, :safi => IANA::SAFI::UNICAST, :nexthop => @nexthop, :nlris => prefixes }
        h[:path_id] = @path_id if @path_id
        pa = Path_attribute.new(*(@path_attribute ? @path_attribute.attributes : []))
        Update.new(pa.replace(Mp_reach.new(h)))
      else
        # RFC 4271 section 4.3: plain NLRI, IPv4 unicast only. RFC 7911
        # section 3: with add-path, each one starts with its Path Identifier.
        nlri = @path_id ? Nlri.new(*prefixes.map { |p| [@path_id, p] }) : Nlri.new(*prefixes)
        Update.new(@path_attribute, nlri)
      end
    end

    def set_mp_reach(start, mp_reach)
      if @afi == IANA::AFI::IPv6
        if mp_reach == false
          raise ArgumentError, "#{start}: plain NLRI carries only IPv4 (RFC 4271 section 4.3); " \
                               "IPv6 prefixes go in MP_REACH_NLRI (RFC 4760 section 3)"
        end
        true
      else
        mp_reach ? true : false
      end
    end

    def set_nexthop(nexthop)
      unless @mp_reach
        raise ArgumentError, "nexthop is only used with MP_REACH_NLRI; set mp_reach: true" if nexthop
        return nil
      end
      if nexthop.nil?
        if @afi == IANA::AFI::IPv6
          raise ArgumentError, "#{@first}/#{@mlen}: plain NLRI carries only IPv4 (RFC 4271 section 4.3); " \
                               "IPv6 prefixes go in MP_REACH_NLRI and need a nexthop"
        end
        raise ArgumentError, "MP_REACH_NLRI needs a nexthop"
      end
      begin
        IPAddr.new(nexthop.to_s)
      rescue IPAddr::Error => e
        raise ArgumentError, "invalid nexthop #{nexthop.inspect}: #{e.message}"
      end
      # An IPv4 next hop for AFI 1 is 4 octets. For AFI 2 it is 16, and an
      # IPv4 one is sent as an IPv4-mapped IPv6 address. An IPv6 next hop
      # for IPv4 NLRI is 16 octets (RFC 8950 section 3). The session must
      # have the Extended Next Hop Encoding capability (RFC 8950 section 4).
      nexthop.to_s
    end

    def set_path_id(path_id)
      return nil if path_id.nil?
      id = begin
        Integer(path_id)
      rescue ArgumentError, TypeError
        raise ArgumentError, "path_id must be an integer, got #{path_id.inspect}"
      end
      unless (0..MAX_PATH_ID) === id
        raise ArgumentError, "path_id #{id} does not fit in 4 octets (RFC 7911 section 3)"
      end
      id
    end

    def check_size(update, session_info)
      size = (session_info ? update.encode(session_info) : update.encode).bytesize
      return if size <= MAX_MESSAGE_SIZE
      raise ArgumentError, "#{@per_update} prefixes per UPDATE make a #{size} byte message; " \
                           "BGP allows #{MAX_MESSAGE_SIZE} (RFC 4271 section 4). Use a smaller per_update."
    end
  end
end
