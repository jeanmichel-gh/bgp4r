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
  class RouteGenerator
    # RFC 4271 section 4: a BGP message is at most 4096 octets.
    MAX_MESSAGE_SIZE = 4096

    attr_reader :count, :per_update, :path_attribute

    def initialize(start, count, per_update=1, path_attribute=nil)
      @first = IPAddr.new(start.to_s)
      # Plain NLRI in an UPDATE carries IPv4 unicast only (RFC 4271 section 4.3).
      raise ArgumentError, "only IPv4 prefixes are supported, got #{start}" unless @first.ipv4?
      @mlen = @first.prefix
      @step = 2**(32 - @mlen)
      @count, @per_update = Integer(count), Integer(per_update)
      raise ArgumentError, "count must be at least 1, got #{@count}" if @count < 1
      raise ArgumentError, "per_update must be at least 1, got #{@per_update}" if @per_update < 1
      if @first.to_i + (@count - 1) * @step > 0xffffffff
        raise ArgumentError, "#{@count} prefixes from #{start} run past 255.255.255.255"
      end
      @path_attribute = path_attribute
    end

    # The first prefix, as "a.b.c.d/len".
    def start ; prefix(0) ; end

    # The last prefix, as "a.b.c.d/len".
    def last ; prefix(@count - 1) ; end

    # The i-th prefix, counting from 0.
    def prefix(i)
      raise IndexError, "prefix #{i} is outside 0..#{@count - 1}" unless (0...@count) === i
      "#{IPAddr.new(@first.to_i + i * @step, Socket::AF_INET)}/#{@mlen}"
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
    # BGP message.
    def each_update(session_info=nil)
      return enum_for(:each_update, session_info) { update_count } unless block_given?
      (0...@count).step(@per_update) do |i|
        n = [@per_update, @count - i].min
        u = Update.new(@path_attribute, Nlri.new(*(i...i + n).map { |j| prefix(j) }))
        check_size(u, session_info) if i == 0
        yield u
      end
    end

    private

    def check_size(update, session_info)
      size = (session_info ? update.encode(session_info) : update.encode).bytesize
      return if size <= MAX_MESSAGE_SIZE
      raise ArgumentError, "#{@per_update} prefixes per UPDATE make a #{size} byte message; " \
                           "BGP allows #{MAX_MESSAGE_SIZE} (RFC 4271 section 4). Use a smaller per_update."
    end
  end
end
