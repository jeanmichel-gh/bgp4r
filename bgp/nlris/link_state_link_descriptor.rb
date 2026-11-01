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

  # The Link Descriptor TLVs of RFC 9552 section 5.2.2, Table 4, and the
  # Multi-Topology Identifier of section 5.2.2.1, registered with
  # `Link_state::Tlv.register`.
  #
  # `docs/bgp-ls.md` is the guide. Every RFC 9552 section number here
  # was read in the RFC text on 2026-11-01. Nothing dispatches to this
  # file yet: the NLRI gates are part 4.
  #
  # **Table 4 has no Length column where Table 5 does, so the widths of
  # 258 to 262 are not in RFC 9552 at all.** Section 5.2.2 sends a
  # reader elsewhere for them: "The format and semantics of the Value
  # fields in most Link Descriptor TLVs correspond to the format and
  # semantics of Value fields in IS-IS Extended IS Reachability
  # sub-TLVs, which are defined in [RFC5305], [RFC5307], and
  # [RFC6119]." So each width below is quoted from the document that
  # gives it, fetched on 2026-11-01 rather than written from memory,
  # and each class names the RFC it came from.
  #
  # **One consequence of reading those three: four of these TLVs can
  # repeat in one NLRI**, since each of the IS-IS sub-TLVs they
  # correspond to "can occur multiple times" and each BGP-LS TLV value
  # is one address. That is what section 5.1's Length and Value
  # tiebreakers are for, and it confirms part 2's reading from the
  # other side: a Node Descriptor needs no tiebreakers because its
  # once-only rule makes a repeat impossible, and a Link Descriptor has
  # no such rule.
  class Link_state

    class Tlv

      # A TLV whose whole value is one IP address of a fixed width, in
      # a 4 + WIDTH octet TLV. Four of Table 4's six are this shape and
      # differ only in the type number, the family and how each prints.
      #
      # A width other than WIDTH cannot be one of these: `Tlv.factory`
      # then finds the value does not reproduce itself and keeps the
      # octets as a `Tlv::Unknown`, which is part 1's rule.
      class Addr_tlv < Tlv

        attr_reader :address

        # new('10.0.0.1'), new(an_IPAddr), the wire value octets, this
        # class's own hash, or another instance.
        def initialize(*args)
          @address = nil
          if args.size == 1 and args[0].is_a?(String) and args[0].is_packed?
            parse(args[0])
          elsif args.size == 1 and args[0].is_a?(self.class)
            self.declared_len = args[0].declared_len
            @address = args[0].address
          elsif args.size == 1 and args[0].is_a?(Hash)
            from_hash(args[0])
          elsif args.size == 1
            @address = coerce(args[0])
          elsif args.empty?
            # The all zeroes address, which no RFC describes as a link
            # descriptor and which builds, per Conventions.
            @address = coerce(self.class.width == 4 ? '0.0.0.0' : '::')
          else
            raise ArgumentError, "invalid argument: #{args.inspect}"
          end
          self
        end

        def self.width
          self::WIDTH
        end

        def self.label
          self::LABEL
        end

        # **Exactly WIDTH octets, and refusing anything else is what
        # keeps the family honest.** `IPAddr.new_ntoh` reads 4 octets
        # as an IPv4 address and 16 as an IPv6 one, and `hton` gives
        # back whatever it was handed, so without this check a 4-octet
        # value in TLV 261 parsed into an `Ipv6_interface_address`
        # holding an IPv4 address and reproduced its own octets, which
        # is how it passed part 3's first run. Raising sends it to
        # `Tlv::Unknown` through `read_tlv`'s rescue, which keeps the
        # octets whole and claims nothing about them.
        def parse(s)
          w = self.class.width
          unless s.size == w
            raise ArgumentError,
              "#{self.class} is #{w} octets and this value is #{s.size}"
          end
          @address = IPAddr.new_ntoh(s.slice!(0, w))
          self
        end

        def encode_value
          @address.hton
        end

        def value_hash
          @address.to_s
        end

        def to_s
          "#{self.class.label} #{@address}"
        end

        private

        # **An address of the other family is refused, and that is the
        # one kind of refusal Conventions allows rather than a
        # judgement about validity**: a 4-octet field cannot represent
        # a 16-octet address, so the alternative is writing a 16-octet
        # value in a TLV whose class says 4 and calling it an IPv4
        # interface address.
        #
        # The octet level route stays open and is the one to use for a
        # value no RFC allows: `Tlv::Unknown.new(259, sixteen_octets)`
        # builds it, encodes it and replays it. The message says so.
        def coerce(v)
          a = v.is_a?(IPAddr) ? v : IPAddr.new(v.to_s)
          w = self.class.width
          unless a.hton.size == w
            raise ArgumentError,
              "#{self.class} is #{w} octets and #{a} is #{a.hton.size}; " \
              "for a value no RFC allows use " \
              "Link_state::Tlv::Unknown.new(#{self.class.type}, octets)"
          end
          a
        end

        def from_hash(h)
          read_declared_len(h)
          h = self.class.unwrap(h)
          @address = coerce(h)
        end

      end

      # TLV 259, Table 4, which cites RFC 5305 section 3.2. That
      # section, fetched on 2026-11-01: "Sub-TLV 6: IPv4 Interface
      # Address ... This sub-TLV contains a 4-octet IPv4 address for
      # the interface described by the (main) TLV", and "This sub-TLV
      # can occur multiple times."
      class Ipv4_interface_address < Addr_tlv
        TYPE = 259
        HASH_KEY = :ipv4_interface_address
        WIDTH = 4
        LABEL = 'IPv4 interface'
      end
      register Ipv4_interface_address

      # TLV 260, Table 4, which cites RFC 5305 section 3.3: "Sub-TLV 8:
      # IPv4 Neighbor Address ... This sub-TLV contains a single IPv4
      # address for a neighboring router on this link", and "This
      # sub-TLV can occur multiple times." The width is 4, which that
      # section's own summary table gives and its prose leaves to the
      # word "IPv4".
      class Ipv4_neighbor_address < Addr_tlv
        TYPE = 260
        HASH_KEY = :ipv4_neighbor_address
        WIDTH = 4
        LABEL = 'IPv4 neighbor'
      end
      register Ipv4_neighbor_address

      # TLV 261, Table 4, which cites RFC 6119 section 4.2. That
      # section, fetched on 2026-11-01: the sub-TLV "has sub-TLV type
      # 12", "It contains a 16-octet IPv6 address for the interface
      # described by the containing Extended IS Reachability TLV", and
      # "This sub-TLV MUST NOT contain an IPv6 link-local address."
      #
      # RFC 9552 section 5.2.2 says the same of the BGP-LS TLV, for all
      # four of 259 to 262: "IPv4/IPv6 link-local addresses MUST NOT be
      # carried in the IPv4/IPv6 interface/neighbor address TLVs
      # (259/260/261/262) as descriptors of a link since they are not
      # considered unique." Nothing here refuses one, because building
      # never validates; it is a part 6 candidate and
      # `docs/bgp-ls.md` records it as one.
      class Ipv6_interface_address < Addr_tlv
        TYPE = 261
        HASH_KEY = :ipv6_interface_address
        WIDTH = 16
        LABEL = 'IPv6 interface'
      end
      register Ipv6_interface_address

      # TLV 262, Table 4, which cites RFC 6119 section 4.3: sub-TLV
      # type 13, "a 16-octet IPv6 address for a neighboring router on
      # the link described by the (main) TLV", with the same link-local
      # MUST NOT.
      class Ipv6_neighbor_address < Addr_tlv
        TYPE = 262
        HASH_KEY = :ipv6_neighbor_address
        WIDTH = 16
        LABEL = 'IPv6 neighbor'
      end
      register Ipv6_neighbor_address

      # TLV 258, Table 4, which cites RFC 5307 section 1.1. That
      # section, fetched on 2026-11-01, is the only one of the three
      # that states a total: "The type of this sub-TLV is 4, and the
      # length is 8 octets", and "The value field of this sub-TLV
      # contains 4 octets of Link Local Identifier followed by 4 octets
      # of Link Remote Identifier."
      #
      # It also gives the one value rule any of them gives: "If the
      # Link Remote Identifier is unknown, it is set to 0." So a zero
      # remote identifier is a statement and not a missing field, which
      # is why `remote` answers 0 rather than nil.
      class Link_local_remote_identifiers < Tlv

        TYPE = 258
        HASH_KEY = :link_local_remote_identifiers
        WIDTH = 8

        attr_reader :local, :remote

        # new(local, remote), new(local), the wire value octets, this
        # class's own hash, or another instance.
        def initialize(*args)
          @local, @remote = 0, 0
          if args.size == 1 and args[0].is_a?(String) and args[0].is_packed?
            parse(args[0])
          elsif args.size == 1 and args[0].is_a?(self.class)
            self.declared_len = args[0].declared_len
            @local, @remote = args[0].local, args[0].remote
          elsif args.size == 1 and args[0].is_a?(Hash)
            from_hash(args[0])
          elsif (1..2).include?(args.size) and args[0].is_a?(Integer)
            @local = args[0]
            @remote = args[1].to_i
          elsif args.empty?
            # Both unknown, which section 1.1 describes for the remote
            # one and for the local one describes not at all.
          else
            raise ArgumentError, "invalid argument: #{args.inspect}"
          end
          self
        end

        def parse(s)
          @local, @remote = s.slice!(0, WIDTH).unpack('NN')
          self
        end

        def encode_value
          [@local, @remote].pack('NN')
        end

        def value_hash
          { :local => @local, :remote => @remote }
        end

        def to_s
          r = @remote.zero? ? 'unknown' : @remote.to_s
          "Link IDs local #{@local} remote #{r}"
        end

        private

        def from_hash(h)
          read_declared_len(h)
          h = self.class.unwrap(h)
          @local = h[:local].to_i
          @remote = h[:remote].to_i
        end

      end
      register Link_local_remote_identifiers

      # TLV 263, section 5.2.2.1, the Multi-Topology Identifier.
      #
      #    0                   1
      #    0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5
      #   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
      #   |R R R R|  Multi-Topology ID 1  |  ... n of these
      #   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
      #
      # "The Type is 263, the length is 2*n, and n is the number of
      # MT-IDs carried in the TLV." So the value is a list of 16-bit
      # words, of which the low 12 bits are the identifier.
      #
      # **The first BGP-LS TLV with a reserved field, so the
      # keep-and-echo rule arrives here.** Section 5.2.2.1: "When used
      # as a Link or Prefix Descriptor for IS-IS, the Bits R are
      # reserved and MUST be set to 0 (as per Section 7.2 of [RFC5120])
      # when originated and ignored on receipt." Ignored on receipt is
      # not a licence to drop them: an R nibble arriving set is
      # somebody's test and this library has to be able to send it
      # back. So the words are kept whole and the hash carries them
      # verbatim **only** when an R nibble is non-zero, which is the
      # same no-reserved-bit-no-key rule `Attr::Typed` uses for
      # `:bits` and `Node_descriptors` uses for `:tail`.
      #
      # **R is four bits here and not always**, which is the detail to
      # hold: the same section says that in the BGP-LS Attribute of a
      # Node NLRI "the Bits R are set as per Section 7.1 of [RFC5120]",
      # so there they carry meaning. One class either way, since the
      # octets are the same and only what a reader may conclude
      # changes.
      class Multi_topology_id < Tlv

        TYPE = 263
        HASH_KEY = :multi_topology_id

        # Section 5.2.2.1's figure: four R bits then twelve of
        # identifier, in each 16-bit word.
        ID_MASK = 0x0fff
        R_MASK = 0xf000

        attr_reader :words

        # new(0), new(0, 2, 4), the wire value octets, this class's own
        # hash, or another instance.
        def initialize(*args)
          @words = []
          if args.size == 1 and args[0].is_a?(String) and args[0].is_packed?
            parse(args[0])
          elsif args.size == 1 and args[0].is_a?(self.class)
            self.declared_len = args[0].declared_len
            @words = args[0].words.dup
          elsif args.size == 1 and args[0].is_a?(Hash)
            from_hash(args[0])
          else
            @words = args.collect { |a| a.to_i }
          end
          self
        end

        # Two octets at a time. An odd trailing octet cannot be a word,
        # so the value does not reproduce itself and `Tlv.factory` keeps
        # the octets as a `Tlv::Unknown`: a length of 2*n+1 is a value
        # section 5.2.2.1 does not describe, and part 1's rule is what
        # answers it.
        def parse(s)
          @words = s.slice!(0, (s.size / 2) * 2).unpack('n*')
          self
        end

        def encode_value
          @words.pack('n*')
        end

        # The identifiers, the low twelve bits of each word.
        def ids
          @words.collect { |w| w & ID_MASK }
        end

        # The R nibble of each word, which section 5.2.2.1 reserves for
        # a Link or Prefix Descriptor.
        def reserved
          @words.collect { |w| (w & R_MASK) >> 12 }
        end

        def reserved_set?
          reserved.any? { |r| !r.zero? }
        end

        # The plain list of identifiers, and the words verbatim when an
        # R nibble arrived set. No reserved bit set, no second shape,
        # so an ordinary MT-ID TLV hashes as the list it has always
        # been.
        def value_hash
          reserved_set? ? { :words => @words } : ids
        end

        def to_s
          s = "MT-ID #{ids.join(', ')}"
          s += " (R #{reserved.join(', ')})" if reserved_set?
          s
        end

        private

        def from_hash(h)
          read_declared_len(h)
          h = self.class.unwrap(h)
          if h.is_a?(Hash) and h.has_key?(:words)
            @words = h[:words].collect { |w| w.to_i }
          else
            @words = [h].flatten(1).collect { |w| w.to_i }
          end
        end

      end
      register Multi_topology_id

    end

  end

end

load "../../test/unit/nlris/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
