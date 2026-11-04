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
require 'bgp/daemon/community_keys'
require 'bgp/gen/spec'
require 'bgp/gen/packer'

module BGP
  class Gen
    # IPv4 and IPv6 unicast, SAFI 1: `count` consecutive prefixes of one
    # length from `start`, every one carrying the same attributes.
    #
    # IPv4 goes in the NLRI and Withdrawn Routes fields of RFC 4271
    # section 4.3, IPv6 in MP_REACH_NLRI and MP_UNREACH_NLRI (RFC 4760
    # sections 3 and 4), which is what `RouteGenerator` does without its
    # `mp_reach` option.
    #
    # **The attributes are sent as written.** This is the library, which
    # knows nothing of sessions, so unlike `Daemon::Speaker` it puts no AS
    # in front of `as_path` and fills in no next hop. ORIGIN and AS_PATH
    # are always there, IGP and empty by default, because those are
    # what every other block in bgp4r writes; NEXT_HOP, MULTI_EXIT_DISC,
    # LOCAL_PREF and the communities are there only when the spec gives
    # them. So a spec with no `next_hop` sends an IPv4 UPDATE with no
    # NEXT_HOP, or an IPv6 one whose MP_REACH_NLRI next hop is empty. No
    # RFC allows either, and nothing here refuses them.
    class Unicast
      SAFI = IANA::SAFI::UNICAST

      # The session info every message is measured with. A 4 octet AS
      # encodes at least as long as a 2 octet one, so a message that
      # fits here fits on any session.
      SIZING = BGP::Update::Info.new(true)

      attr_reader :afi, :count, :per_update, :path_id, :attributes

      def initialize(spec)
        @count, @per_update, @path_id = spec['count'], spec['per_update'], spec['path_id']
        @attributes = spec['attributes']
        read_start(spec['start'])
        if spec['afi'] && spec['afi'] != @afi
          raise SpecError, "afi #{spec['afi']} disagrees with start #{spec['start']}, which is AFI #{@afi}"
        end
        @path_attribute = build_attributes
        # A spec whose attributes leave no room for one route is refused
        # here, and not halfway through a feed that has started sending.
        announce_packer.each_batch([[nil, route_octets]]) { }
      end

      def ipv4? ; @afi == IANA::AFI::IPv4 ; end

      # The i-th prefix, from 0, as "a.b.c.d/len" or "x:x::/len".
      def prefix(i)
        "#{IPAddr.new(@first + i * @step, @family)}/#{@mlen}"
      end

      # The octets one route takes: RFC 4271 section 4.3's Length octet
      # and enough octets for the prefix, and with add-path the 4 octet
      # Path Identifier in front (RFC 7911 section 3).
      def route_octets
        1 + (@mlen + 7) / 8 + (@path_id ? 4 : 0)
      end

      # The UPDATEs that announce every route, as an Enumerator, so a
      # large count is built one message at a time.
      def updates
        messages(announce_packer) { |batch| build_update(batch) }
      end

      # The UPDATEs that withdraw exactly the routes #updates announced.
      def withdrawals
        messages(withdraw_packer) { |batch| build_withdrawal(batch) }
      end

      # One row per route, as plain data: what the spec meant to send.
      # The communities are spelled the way the attribute reads them back,
      # so `no_export` is 65535:65281, which is what a RIB will show.
      def expected
        Enumerator.new(@count) do |y|
          row = expected_attributes
          @count.times do |i|
            r = { 'prefix' => prefix(i) }
            r['path_id'] = @path_id if @path_id
            y << r.merge(row)
          end
        end
      end

      private

      def read_start(start)
        a = begin
          IPAddr.new(start)
        rescue IPAddr::Error => e
          raise SpecError, "start #{start.inspect} is not a prefix: #{e.message}"
        end
        @mlen = a.prefix
        if a.ipv4?
          @afi, bits, @family = IANA::AFI::IPv4, 32, Socket::AF_INET
        else
          @afi, bits, @family = IANA::AFI::IPv6, 128, Socket::AF_INET6
        end
        @first, @step = a.to_i, 2**(bits - @mlen)
        if @first + (@count - 1) * @step > 2**bits - 1
          raise SpecError, "#{@count} prefixes from #{start} run past the end of the address space"
        end
      end

      def build_attributes
        a = @attributes
        attrs = [BGP::Origin.new(a.fetch('origin', 0))]
        attrs << BGP::Next_hop.new(a['next_hop']) if a['next_hop'] && ipv4?
        attrs << BGP::As_path.new(*a.fetch('as_path', []))
        attrs << BGP::Multi_exit_disc.new(a['med']) if a['med']
        attrs << BGP::Local_pref.new(a['local_pref']) if a['local_pref']
        attrs.concat(Daemon::CommunityKeys.community_attributes(a))
        BGP::Path_attribute.new(*attrs)
      end

      def expected_attributes
        a = @attributes
        row = { 'origin' => a.fetch('origin', 0), 'as_path' => a.fetch('as_path', []) }
        row['next_hop'] = a['next_hop'] if a['next_hop']
        row['med'] = a['med'] if a['med']
        row['local_pref'] = a['local_pref'] if a['local_pref']
        @path_attribute.attributes.each do |attr|
          case attr
          when BGP::Communities then row['communities'] = attr.communities.split
          when BGP::Large_communities then row['large_communities'] = attr.large_communities.split
          when BGP::Extended_communities
            row['extended_communities'] = attr.to_hash[:extended_communities].collect { |h|
              Daemon::CommunityKeys.extended_community_text(h)
            }
          end
        end
        row
      end

      def nlris(prefixes)
        @path_id ? prefixes.collect { |p| [@path_id, p] } : prefixes
      end

      def reach(prefixes)
        h = { :afi => @afi, :safi => SAFI, :nlris => prefixes }
        h[:nexthop] = [@attributes['next_hop']] if @attributes['next_hop']
        h[:path_id] = @path_id if @path_id
        BGP::Mp_reach.new(h)
      end

      def unreach(prefixes)
        h = { :afi => @afi, :safi => SAFI, :nlris => prefixes }
        h[:path_id] = @path_id if @path_id
        BGP::Mp_unreach.new(h)
      end

      def build_update(prefixes)
        if ipv4?
          BGP::Update.new(@path_attribute, BGP::Nlri.new(*nlris(prefixes)))
        else
          pa = BGP::Path_attribute.new(*@path_attribute.attributes)
          BGP::Update.new(pa.add(reach(prefixes)))
        end
      end

      def build_withdrawal(prefixes)
        if ipv4?
          BGP::Update.new(BGP::Withdrawn.new(*nlris(prefixes)))
        else
          BGP::Update.new(BGP::Path_attribute.new(unreach(prefixes)))
        end
      end

      def announce_packer
        empty = build_update([]).encode(SIZING).bytesize
        mp = ipv4? ? nil : reach([]).encode.bytesize - 3
        Packer.new(empty, :mp_value => mp, :per_update => @per_update)
      end

      def withdraw_packer
        empty = build_withdrawal([]).encode(SIZING).bytesize
        mp = ipv4? ? nil : unreach([]).encode.bytesize - 3
        Packer.new(empty, :mp_value => mp, :per_update => @per_update)
      end

      # The routes are numbered rather than listed, so the batches cost
      # nothing until one is asked for. The first message is measured
      # against the packer's arithmetic, once, and a difference raises.
      # Every prefix has one length, so the first message is the largest.
      def messages(packer, &build)
        len = route_octets
        items = Enumerator.new { |y| @count.times { |i| y << [prefix(i), len] } }
        Enumerator.new do |out|
          first = true
          packer.each_batch(items) do |batch, octets|
            m = build.call(batch)
            if first
              measure(m, packer.size(octets))
              first = false
            end
            out << m
          end
        end
      end

      def measure(message, size)
        got = message.encode(SIZING).bytesize
        return if got == size
        raise PackingError, "bgp4r computed #{size} octets for a message that encodes to #{got}"
      end
    end
  end
end
