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

require 'bgp/common'
require 'bgp/iana'
require 'bgp/nlris/link_state'

module BGP

  # The Prefix Descriptor TLVs of RFC 9552 section 5.2.3, Table 5:
  # the OSPF Route Type of section 5.2.3.1 and the IP Reachability
  # Information of section 5.2.3.2. The third row of Table 5 is TLV
  # 263, the Multi-Topology Identifier, which section 5.2.2.1 defines
  # and `link_state_link_descriptor.rb` holds.
  #
  # `docs/bgp-ls.md` is the guide. Every section number here was read
  # in the RFC text on 2026-11-01. Nothing dispatches to this file yet:
  # the NLRI gates are part 4.
  #
  # **Table 5 gives a Length column where Table 4 does not**, so unlike
  # the link descriptors these two widths are RFC 9552's own: 1 for the
  # OSPF Route Type and variable for the IP Reachability Information.
  class Link_state

    class Tlv

      # TLV 264, section 5.2.3.1, one octet.
      #
      #   +-+-+-+-+-+-+-+-+
      #   |  Route Type   |
      #   +-+-+-+-+-+-+-+-+
      #
      # "The Route Type field follows the route types defined in the
      # OSPF protocol and can be one of the following: Intra-Area
      # (0x1), Inter-Area (0x2), External 1 (0x3), External 2 (0x4),
      # NSSA 1 (0x5), NSSA 2 (0x6)."
      #
      # The section names six values and no range, so 0 and 7 to 255
      # are values it does not describe. They build and parse and print
      # as the number, which is the house answer: an unnamed value is
      # not an error this document names.
      class Ospf_route_type < Tlv

        TYPE = 264
        HASH_KEY = :ospf_route_type
        WIDTH = 1

        # Section 5.2.3.1's own list, in its own order.
        ROUTE_TYPES = {
          1 => 'Intra-Area',
          2 => 'Inter-Area',
          3 => 'External 1',
          4 => 'External 2',
          5 => 'NSSA 1',
          6 => 'NSSA 2',
        }.freeze

        attr_reader :route_type

        # new(1), new('Intra-Area'), the wire value octets, this
        # class's own hash, or another instance.
        def initialize(*args)
          @route_type = 0
          if args.size == 1 and args[0].is_a?(String) and args[0].is_packed?
            parse(args[0])
          elsif args.size == 1 and args[0].is_a?(self.class)
            self.declared_len = args[0].declared_len
            @route_type = args[0].route_type
          elsif args.size == 1 and args[0].is_a?(Hash)
            from_hash(args[0])
          elsif args.size == 1
            @route_type = coerce(args[0])
          elsif args.empty?
            # Route type 0, which the section does not name and the
            # OSPFv2 Extended Prefix TLV does carry: section 5.2.3.1
            # says "the route type value 0" may be there and tells a
            # producer to look at another LSA, so a peer can send it.
          else
            raise ArgumentError, "invalid argument: #{args.inspect}"
          end
          self
        end

        def parse(s)
          @route_type = s.slice!(0, WIDTH).unpack1('C').to_i
          self
        end

        def encode_value
          [@route_type].pack('C')
        end

        # Section 5.2.3.1's name for this value, or the number for one
        # it does not name.
        def name
          ROUTE_TYPES[@route_type] || @route_type.to_s
        end

        def value_hash
          @route_type
        end

        def to_s
          "OSPF route type #{name}"
        end

        private

        def coerce(v)
          return v.to_i if v.is_a?(Integer)
          k = ROUTE_TYPES.key(v.to_s)
          return k if k
          sym = v.to_s.downcase.gsub(/[^a-z0-9]/, '')
          found = ROUTE_TYPES.find do |_, n|
            n.downcase.gsub(/[^a-z0-9]/, '') == sym
          end
          return found[0] if found
          raise ArgumentError,
            "unknown OSPF route type #{v.inspect}; section 5.2.3.1 names " \
            "#{ROUTE_TYPES.values.join(', ')}, or pass a number"
        end

        def from_hash(h)
          read_declared_len(h)
          h = self.class.unwrap(h)
          @route_type = h.is_a?(Hash) ? 0 : coerce(h)
        end

      end
      register Ospf_route_type

      # TLV 265, section 5.2.3.2, the IP Reachability Information.
      #
      #   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
      #   | Prefix Length | IP Prefix (variable)                     //
      #   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
      #
      # "The Prefix Length field contains the length of the prefix in
      # bits. The IP Prefix field contains an IP address prefix
      # followed by the minimum number of trailing bits needed to make
      # the end of the field fall on an octet boundary. Any trailing
      # bits MUST be set to 0. Thus, the IP Prefix field contains the
      # most significant octets of the prefix, i.e., 1 octet for prefix
      # length 1 up to 8, 2 octets for prefix length 9 up to 16, 3
      # octets for prefix length 17 up to 24, 4 octets for prefix
      # length 25 up to 32, etc."
      #
      # So the width is `(bits + 7) / 8`, which is the prefix
      # arithmetic every other family in this library already does, and
      # the section spells the first four cases out rather than leaving
      # them to be derived.
      #
      # **The family is not in the TLV, and that is the second
      # cross-level read in this family.** Nothing here says whether 24
      # bits of prefix are IPv4 or IPv6: the NLRI type does, 3 for IPv4
      # and 4 for IPv6, so `Link_state::Prefix_nlri#prefix` combines
      # them and this class holds the halves. `Igp_router_id` and
      # `Headed#node_type` are the same shape one section earlier, and
      # the reason is the same: the octets replay without the family,
      # and a class that accepted one would eventually use it.
      #
      # **Trailing bits are echoed rather than re-masked.** "Any
      # trailing bits MUST be set to 0" binds a sender, so a peer that
      # sent something else sent a value no RFC allows and this library
      # has to be able to send it back. `trailing_bits_set?` reports
      # it; part 6 is where a receive side check reads that.
      class Ip_reachability < Tlv

        TYPE = 265
        HASH_KEY = :ip_reachability

        attr_reader :bitlen, :octets

        # new('10.0.0.0/8'), new(8, octets), the wire value octets,
        # this class's own hash, or another instance.
        def initialize(*args)
          @bitlen, @octets = 0, +''
          if args.size == 1 and args[0].is_a?(String) and args[0].is_packed?
            parse(args[0])
          elsif args.size == 1 and args[0].is_a?(self.class)
            self.declared_len = args[0].declared_len
            @bitlen, @octets = args[0].bitlen, args[0].octets.dup
          elsif args.size == 1 and args[0].is_a?(Hash)
            from_hash(args[0])
          elsif args.size == 2 and args[0].is_a?(Integer)
            @bitlen, @octets = args[0], args[1].to_s.b
          elsif args.size == 1
            from_text(args[0])
          elsif args.empty?
            # The default route, prefix length 0 and no octets, which
            # the section's arithmetic gives and which an IGP does
            # advertise.
          else
            raise ArgumentError, "invalid argument: #{args.inspect}"
          end
          self
        end

        # The octets a prefix of _bits_ bits occupies, which section
        # 5.2.3.2 states for 1 to 32 and leaves as "etc." above.
        def self.octets_for(bits)
          (bits + 7) / 8
        end

        # **`.to_i` and not `unpack1('C')` alone**, because a value can
        # run out exactly where the Prefix Length should be and
        # `unpack1` answers nil there. The same bug was found in
        # `Evpn::Sized` by probing and is not repeated.
        def parse(s)
          @bitlen = s.slice!(0, 1).unpack1('C').to_i
          n = [self.class.octets_for(@bitlen), s.size].min
          @octets = s.slice!(0, n)
          self
        end

        def encode_value
          [@bitlen, @octets].pack('Ca*')
        end

        # The prefix as a person writes it, for a family the caller
        # names: 1 for IPv4 and 2 for IPv6, which is what the NLRI type
        # decides. nil where the octets cannot make an address of that
        # family, which covers a Prefix Length wider than the family
        # and a value cut short.
        def prefix(afi)
          width = afi == IANA::AFI::IPv6 ? 16 : 4
          return nil if @bitlen > width * 8
          return nil if @octets.size != self.class.octets_for(@bitlen)
          padded = @octets + ([0].pack('C') * (width - @octets.size))
          "#{IPAddr.new_ntoh(padded)}/#{@bitlen}"
        end

        # Section 5.2.3.2: "Any trailing bits MUST be set to 0." A
        # sender's rule, so this reports rather than refusing.
        def trailing_bits_set?
          return false if @octets.empty?
          spare = @octets.size * 8 - @bitlen
          return false if spare <= 0 or spare > 8
          !(@octets.getbyte(@octets.size - 1) & ((1 << spare) - 1)).zero?
        end

        # The `{:bitlen, :octets}` pair, because the prefix string
        # needs a family this class does not have and a hash that
        # carried one would be inventing it.
        def value_hash
          { :bitlen => @bitlen, :octets => @octets.unpack1('H*') }
        end

        def to_s
          "prefix #{@octets.unpack1('H*')}/#{@bitlen}"
        end

        private

        # A prefix string, whose own family fixes the octets. The
        # family is not kept: the NLRI type is what says it on the
        # wire, so keeping a second copy here would let the two
        # disagree.
        def from_text(t)
          ip = IPAddr.new(t.to_s)
          @bitlen = ip.prefix
          @octets = ip.hton[0, self.class.octets_for(@bitlen)]
        end

        def from_hash(h)
          read_declared_len(h)
          h = self.class.unwrap(h)
          return from_text(h) unless h.is_a?(Hash)
          @bitlen = h[:bitlen].to_i
          @octets = [h[:octets].to_s].pack('H*')
        end

      end
      register Ip_reachability

    end

  end

end

load "../../test/unit/nlris/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
