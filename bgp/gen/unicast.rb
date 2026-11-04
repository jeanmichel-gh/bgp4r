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
require 'bgp/gen/vary'

module BGP
  class Gen
    # IPv4 and IPv6 unicast, SAFI 1: `count` consecutive prefixes of one
    # length from `start`, with attributes that may vary from route to
    # route through the patterns of bgp/gen/vary.rb.
    #
    # IPv4 goes in the NLRI and Withdrawn Routes fields of RFC 4271
    # section 4.3, IPv6 in MP_REACH_NLRI and MP_UNREACH_NLRI (RFC 4760
    # sections 3 and 4), which is what `RouteGenerator` does without its
    # `mp_reach` option.
    #
    # **The attributes are sent as written** unless a `Sender` says what
    # session they go out on: the library knows nothing of sessions, so
    # on its own it puts no AS in front of `as_path` and fills in no
    # next hop. bgp/gen/sender.rb is the other case. ORIGIN and AS_PATH
    # are always there, IGP and empty by default, because those are
    # what every other block in bgp4r writes; NEXT_HOP, MULTI_EXIT_DISC,
    # LOCAL_PREF and the communities are there only when the spec gives
    # them. So a spec with no `next_hop` sends an IPv4 UPDATE with no
    # NEXT_HOP, or an IPv6 one whose MP_REACH_NLRI next hop is empty. No
    # RFC allows either, and nothing here refuses them.
    #
    # **Attribute patterns run on the group number and the Path
    # Identifier on the route number.** `group: N` makes route i's
    # attributes those of i / N, so N routes share a set and can share a
    # message; the Path Identifier is part of the route and not of its
    # attributes, so grouping does not hold it.
    #
    # **Routes travel together only when their attributes are identical**
    # (RFC 4271 section 4.3: one UPDATE, one set of path attributes), so
    # a message ends when the set changes as well as when it is full.
    # Each distinct set has a packer of its own, and the first message
    # of each set is measured against it. Sets are kept in a cache of
    # SETS, cleared when it fills, so a feed whose every route differs
    # costs memory for SETS sets and no more; a set seen again after a
    # clear is measured again, which costs one encode.
    #
    # **A set too large for one route is refused when it is reached.**
    # The first is checked at `new`. A pattern can make a later one
    # larger, a community count that grows say, and finding the largest
    # would mean building every set up front, which for a million
    # routes that each differ is the cost this is built to avoid. So a
    # spec like that can stop with Unpackable after messages have gone.
    class Unicast
      SAFI = IANA::SAFI::UNICAST

      # The session info every message is measured with. A 4 octet AS
      # encodes at least as long as a 2 octet one, so a message that
      # fits here fits on any session.
      SIZING = BGP::Update::Info.new(true)

      # How many distinct attribute sets are kept before the cache is
      # cleared. Big enough that a cycle or an `every` of any reasonable
      # length is built once.
      SETS = 1024

      # One distinct attribute set: what it sends, how its messages pack,
      # what `expected` says of it, and whether a message of it has been
      # measured. It answers the packer's three questions itself, so it
      # is what Packer.batches is handed and what it yields back: a set
      # stays reachable from its own batch after the cache has let go of
      # it, which a lookup from packer to set did not, and that is the
      # bug the cache test found.
      Set = Struct.new(:path_attribute, :next_hop, :packer, :expected, :measured) do
        def fits?(octets) ; packer.fits?(octets) ; end
        def size(octets) ; packer.size(octets) ; end
        def per_update ; packer.per_update ; end
      end

      attr_reader :afi, :count, :per_update, :group

      def initialize(spec, sender = nil)
        @sender = sender
        @count, @per_update = spec['count'], spec['per_update']
        @group = spec['group'] || 1
        @patterns = Spec.patterns(spec)
        @path_id = @patterns.delete('path_id')
        read_start(spec['start'])
        if spec['afi'] && spec['afi'] != @afi
          raise SpecError, "afi #{spec['afi']} disagrees with start #{spec['start']}, which is AFI #{@afi}"
        end
        @sets = {}
        # A spec whose first attribute set leaves no room for one route
        # is refused here, and not halfway through a feed.
        Packer.batches([[nil, route_octets, set_for(row_at(set_key(0)))]]) { }
      end

      def ipv4? ; @afi == IANA::AFI::IPv4 ; end

      # True for IPv4 unicast, the one family RFC 4271 section 4.3's own
      # NLRI and Withdrawn Routes fields carry. Every other one goes in
      # MP_REACH_NLRI and MP_UNREACH_NLRI (RFC 4760 sections 3 and 4),
      # IPv4 multicast included.
      def classic? ; ipv4? && safi == IANA::SAFI::UNICAST ; end

      def safi ; self.class::SAFI ; end

      # True when every route carries a Path Identifier (RFC 7911).
      def add_path? ; !@path_id.nil? ; end

      # The i-th prefix, from 0, as "a.b.c.d/len" or "x:x::/len".
      def prefix(i)
        "#{IPAddr.new(@first + i * @step, @family)}/#{@mlen}"
      end

      # The i-th route's Path Identifier, or nil without add-path.
      def path_id(i) ; @path_id && @path_id.at(i) ; end

      # What the i-th route is to a message: the prefix and its Path
      # Identifier. A family whose NLRI carries more, a label say, adds
      # it here, and its mp_nlris reads it.
      def route(i) ; [prefix(i), path_id(i)] ; end

      # How many routes the spec makes. `count` for unicast; a family
      # that repeats the range, as VPN does once per VRF, answers more.
      def total ; @count ; end

      # Which attribute set route i takes, as a key: the group number
      # here, and anything else a family varies its attributes on beside
      # it. A new key is a new set looked up, which ends a message only
      # when the set differs.
      def set_key(i) ; i / @group ; end

      # The attribute row for a key `set_key` gave.
      def row_at(key) ; row(key) ; end

      # The i-th route's key fields as an `expected` row starts them.
      def route_row(i)
        r = { 'prefix' => prefix(i) }
        r['path_id'] = path_id(i) if add_path?
        r
      end

      # The octets one route takes: RFC 4271 section 4.3's Length octet
      # and enough octets for the prefix, and with add-path the 4 octet
      # Path Identifier in front (RFC 7911 section 3).
      def route_octets
        1 + (@mlen + 7) / 8 + (add_path? ? 4 : 0)
      end

      # The attribute values of group g, plain data, defaults filled in,
      # and the sender's rules applied when there is a sender.
      def row(g)
        r = { 'origin' => 0, 'as_path' => [] }
        @patterns.each { |k, p| r[k] = p.at(g) }
        @sender ? @sender.apply(r) : r
      end

      # The UPDATEs that announce every route, as an Enumerator, so a
      # large count is built one message at a time.
      def updates
        items = Enumerator.new do |y|
          len, last_k, set = route_octets, nil, nil
          total.times do |i|
            k = set_key(i)
            set = set_for(row_at(k)) unless k == last_k
            last_k = k
            y << [route(i), len, set]
          end
        end
        Enumerator.new do |out|
          Packer.batches(items) do |batch, octets, set|
            m = build_update(set, batch)
            unless set.measured
              measure(m, set.size(octets))
              set.measured = true
            end
            out << m
          end
        end
      end

      # The UPDATEs that withdraw exactly the routes #updates announced.
      # A withdrawal carries no attributes, so one packer does for all.
      def withdrawals
        packer = withdraw_packer
        len = route_octets
        items = Enumerator.new { |y| total.times { |i| y << [route(i), len] } }
        Enumerator.new do |out|
          first = true
          packer.each_batch(items) do |batch, octets|
            m = build_withdrawal(batch)
            measure(m, packer.size(octets)) if first
            first = false
            out << m
          end
        end
      end

      # One row per route, as plain data: what the spec meant to send.
      # The communities are spelled the way the attribute reads them back,
      # so `no_export` is 65535:65281, which is what a RIB will show.
      def expected
        Enumerator.new(total) do |y|
          last_k, attrs = nil, nil
          total.times do |i|
            k = set_key(i)
            attrs = set_for(row_at(k)).expected unless k == last_k
            last_k = k
            y << route_row(i).merge(attrs)
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

      def set_for(r)
        set = @sets[r]
        return set if set
        @sets.clear if @sets.size >= SETS
        set = Set.new(build_attributes(r), r['next_hop'])
        set.expected = expected_attributes(r, set.path_attribute)
        set.packer = announce_packer(set)
        set.measured = false
        @sets[r] = set
      end

      def build_attributes(a)
        attrs = [BGP::Origin.new(a['origin'])]
        attrs << BGP::Next_hop.new(a['next_hop']) if a['next_hop'] && classic?
        attrs << BGP::As_path.new(*a['as_path'])
        attrs << BGP::Multi_exit_disc.new(a['med']) if a['med']
        attrs << BGP::Local_pref.new(a['local_pref']) if a['local_pref']
        # An empty community list, which a `count` pattern gives at 0,
        # sends no attribute rather than an empty one: `Communities`
        # cannot be built from an empty string, and an attribute of
        # length 0 is a fault case, which BGP::Fault already sends.
        lists = a.reject { |k, v| v.is_a?(Array) && v.empty? && k != 'as_path' }
        attrs.concat(Daemon::CommunityKeys.community_attributes(lists))
        BGP::Path_attribute.new(*attrs)
      end

      def expected_attributes(a, pa)
        row = { 'origin' => a['origin'], 'as_path' => a['as_path'] }
        row['next_hop'] = a['next_hop'] if a['next_hop']
        row['med'] = a['med'] if a['med']
        row['local_pref'] = a['local_pref'] if a['local_pref']
        pa.attributes.each do |attr|
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

      # A batch is [prefix, path_id] pairs. The RFC 4271 fields take the
      # [id, prefix] form and the MP attributes a Hash per prefix, which
      # is how each carries a Path Identifier that can differ per route.
      def ipv4_nlris(batch)
        batch.collect { |p, id| id ? [id, p] : p }
      end

      def mp_nlris(batch)
        batch.collect { |p, id| id ? { :path_id => id, :prefix => p } : p }
      end

      # What MP_UNREACH_NLRI carries for a batch, which is mp_nlris here
      # and differs where a withdrawal's NLRI is not the announcement's.
      def mp_withdrawn_nlris(batch) ; mp_nlris(batch) ; end

      # The next hop as it goes in MP_REACH_NLRI. As given here: for
      # SAFI 1, 2 and 4 `Mp_reach` maps an IPv4 one under AFI 2 itself.
      # VPN does not get that from `Mp_reach` and overrides this.
      def wire_next_hop(nh) ; nh ; end

      def reach(set, batch)
        h = { :afi => @afi, :safi => safi, :nlris => mp_nlris(batch) }
        h[:nexthop] = [wire_next_hop(set.next_hop)] if set.next_hop
        BGP::Mp_reach.new(h)
      end

      def unreach(batch)
        BGP::Mp_unreach.new(:afi => @afi, :safi => safi, :nlris => mp_withdrawn_nlris(batch))
      end

      def build_update(set, batch)
        if classic?
          BGP::Update.new(set.path_attribute, BGP::Nlri.new(*ipv4_nlris(batch)))
        else
          pa = BGP::Path_attribute.new(*set.path_attribute.attributes)
          BGP::Update.new(pa.add(reach(set, batch)))
        end
      end

      def build_withdrawal(batch)
        if classic?
          BGP::Update.new(BGP::Withdrawn.new(*ipv4_nlris(batch)))
        else
          BGP::Update.new(BGP::Path_attribute.new(unreach(batch)))
        end
      end

      def announce_packer(set)
        empty = build_update(set, []).encode(SIZING).bytesize
        mp = classic? ? nil : reach(set, []).encode.bytesize - 3
        Packer.new(empty, :mp_value => mp, :per_update => @per_update)
      end

      def withdraw_packer
        empty = build_withdrawal([]).encode(SIZING).bytesize
        mp = classic? ? nil : unreach([]).encode.bytesize - 3
        Packer.new(empty, :mp_value => mp, :per_update => @per_update)
      end

      def measure(message, size)
        got = message.encode(SIZING).bytesize
        return if got == size
        raise PackingError, "bgp4r computed #{size} octets for a message that encodes to #{got}"
      end
    end
  end
end
