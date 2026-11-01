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

require 'bgp/nlris/link_state'
require 'bgp/nlris/link_state_link_descriptor'

module BGP

  # The Node Attribute TLVs of RFC 9552 section 5.3.1, Table 6,
  # registered with `Link_state::Tlv.register` so both parse and the
  # hash build path find them.
  #
  # `docs/bgp-ls.md` is the guide. Every RFC 9552 section number here
  # was read in the RFC text on 2026-11-01.
  #
  # **Table 6 has seven rows and six classes, because 263 is already
  # in.** The Multi-Topology Identifier is in Table 4 as a link
  # descriptor and in Table 6 as a node attribute, one code point and
  # one class, registered in `link_state_link_descriptor.rb` by part 3.
  # That is the flat registry paying for itself rather than a shortcut:
  # section 5.3.1's row for it cites section 5.2.2.1, its own
  # definition, so the RFC says they are one TLV as plainly as IANA
  # does.
  #
  # **Which TLVs may appear is not this file's business.** Section 5.3
  # says these "may be encoded in the BGP-LS Attribute associated with a
  # Node NLRI", and section 5.3.1.2 says the IS-IS Area Identifier "may
  # be present in the BGP-LS Attribute only when advertised in the
  # Link-State Node NLRI". Both are semantics, and section 8.2.2 names
  # "whether a TLV is valid with a given NLRI type" among the checks a
  # BGP-LS Propagator should not make. So nothing here looks at the
  # NLRI, and a node attribute TLV in a link attribute set builds and
  # encodes.
  #
  # **The shared bases live with their first user**, so `Addr_tlv` comes
  # from `link_state_link_descriptor.rb`, which is why this file
  # requires it. Lifting `Addr_tlv` and `Opaque32` into
  # `link_state_tlv.rb`, where the framing is, is the obvious tidy and
  # is deliberately not done here: the move changes no constant path,
  # since every one of these files reopens `BGP::Link_state::Tlv`, so it
  # costs nothing to do later and it is a second topic today. Part 5b
  # wants `Opaque32` as well, which is when the need is real.
  #
  # **Nothing validates.** Any flag bit, any width, any value, in any
  # order, repeated as often as a caller likes.
  class Link_state

    class Tlv

      # A TLV whose whole value is opaque octets of no fixed width.
      # Table 6 has two, 1025 and 1027, and they differ only in the type
      # number, the hash key and how each prints.
      #
      # **The field form takes raw octets and the hash form takes hex**,
      # which is `Tlv::Unknown`'s split and is kept here so the family
      # reads one way. Each path round trips through itself, and a
      # caller holding hex writes `['0102'].pack('H*')`, which is the
      # library's own idiom.
      #
      # **There is no `is_packed?` branch and no `parse` here, which is
      # the one place this family's constructor shape does not apply.**
      # For a fixed-width class that test tells a wire value from a
      # field value, because the wire branch slices its own octets and
      # leaves the rest. A variable-width value **is** the octets: both
      # branches would take everything and reach the same value, and
      # the only thing left for the test to decide is whether the
      # caller's String is consumed. Two branches differing in that and
      # in nothing else is a trap rather than a feature, especially
      # since `Array#pack` marks its result packed, so almost every
      # octet string a caller holds would take the consuming one
      # without the caller choosing it. So one branch, and it copies,
      # which is what `Tlv::Unknown` does with the same kind of
      # argument. Do not add a `parse` here without a caller for it.
      class Opaque_tlv < Tlv

        attr_reader :value

        # new, new(octets), this class's own hash, or another instance.
        # Wire octets are the `new(octets)` form, marked or not.
        def initialize(*args)
          @value = String.new
          if args.size == 1 and args[0].is_a?(self.class)
            self.declared_len = args[0].declared_len
            @value = args[0].value.dup
          elsif args.size == 1 and args[0].is_a?(Hash)
            from_hash(args[0])
          elsif args.size == 1 and args[0].is_a?(String)
            @value = args[0].dup.b
          elsif args.empty?
            # The empty value, which section 5.1 permits outright: "a
            # TLV with no value portion would have a length of zero".
          else
            raise ArgumentError, "invalid argument: #{args.inspect}"
          end
          self
        end

        # A copy, so building from an instance cannot empty the instance
        # it is copying: the list reader reads with `slice!`.
        def encode_value
          @value.dup
        end

        def value_hash
          @value.unpack1('H*')
        end

        def self.label
          self::LABEL
        end

        def to_s
          s = "#{self.class.label} #{@value.size} octets"
          s += " [#{@value.unpack1('H*')}]" unless @value.empty?
          s
        end

        private

        def from_hash(h)
          read_declared_len(h)
          h = self.class.unwrap(h)
          @value = [h.to_s].pack('H*')
        end

      end

      # TLV 1024, section 5.3.1.1: "The Node Flag Bits TLV carries a
      # bitmask describing node attributes. The value is a
      # 1-octet-length bit array of flags, where each bit represents a
      # node-operational state or attribute."
      #
      # **Figure 15 and Table 7 disagree, and the erratum settles it.**
      # The figure prints `|O|T|E|B|R|V|   |` where Table 7 of the same
      # section defines O Overload, **A Attached**, E External, B ABR, R
      # Router and V V6. RFC 9552 **erratum ID 7789**, Technical, is
      # that one letter: the figure's T should read A. Confirmed in the
      # text on 2026-11-01. Same shape as RFC 8956's wrong flow spec
      # vector, which `docs/flow-spec.md` records along with what it
      # cost to explain such a thing some other way: **read the errata
      # before disbelieving a document's own figure.**
      #
      # **Keep and echo the undefined bits**, which is the rule
      # Conventions records for `Traffic_action`, `Prefix_entry` and
      # `Evpn::Flags`, and which the section asks for in so many words:
      # "The bits that are not defined MUST be set to 0 by the
      # originator and MUST be ignored by the receiver." So
      # `DEFINED_BITS` says which bits this class reads, a build from
      # names writes the other two as 0, and the hash gains a
      # `{:bits => n}` entry only when one arrived set.
      class Node_flag_bits < Tlv

        TYPE = 1024
        HASH_KEY = :node_flag_bits

        WIDTH = 1
        MAX_VALUE = 0xff

        # Table 7, high to low, which is the order Figure 15 prints
        # them in: bit 0 is the most significant octet bit.
        OVERLOAD = 0x80   # 'O', ISO 10589
        ATTACHED = 0x40   # 'A', ISO 10589, the erratum's letter
        EXTERNAL = 0x20   # 'E', RFC 2328
        ABR      = 0x10   # 'B', RFC 2328
        ROUTER   = 0x08   # 'R', RFC 5340
        V6       = 0x04   # 'V', RFC 5340

        BITS = {
          :overload => OVERLOAD,
          :attached => ATTACHED,
          :external => EXTERNAL,
          :abr      => ABR,
          :router   => ROUTER,
          :v6       => V6,
        }.freeze

        DEFINED_BITS = BITS.values.inject(0) { |a, b| a | b }

        # The entry that carries the whole octet when the readable list
        # cannot, as `Evpn::Flags::BITS_KEY` does one family over.
        BITS_KEY = :bits

        attr_reader :value

        def self.bits_entry?(h)
          h.is_a?(Hash) and h.has_key?(BITS_KEY)
        end

        # new, no bit set
        # new(:overload, :attached) or new([:overload, :attached])
        # new(0x81), the whole octet, undefined bits included
        # new([:overload, { :bits => 0x81 }]), this class's own hash
        # the wire value octet, or another instance.
        def initialize(*args)
          @value = 0
          args = args[0] if args.size == 1 and args[0].is_a?(Array)
          if args.size == 1 and args[0].is_a?(String) and args[0].is_packed?
            parse(args[0])
          elsif args.size == 1 and args[0].is_a?(self.class)
            self.declared_len = args[0].declared_len
            @value = args[0].value
          elsif args.size == 1 and args[0].is_a?(Hash) and
                !self.class.bits_entry?(args[0])
            from_hash(args[0])
          elsif args.size == 1 and args[0].is_a?(Integer)
            refuse_a_value_the_field_cannot_hold(args[0])
            @value = args[0]
          elsif args.all? { |a| a.is_a?(Symbol) or self.class.bits_entry?(a) }
            # An empty list lands here too, which is the no-bit-set TLV.
            args.each { |a| set_one(a) }
          else
            raise ArgumentError, "invalid argument: #{args.inspect}, " \
                                 'expected bit names, an octet or a hash'
          end
          self
        end

        # **Exactly one octet, and refusing anything else is what sends
        # a wider value to `Tlv::Unknown`.** Without the check a 2-octet
        # value would read its first octet and answer `encode_value`
        # with one, so `Tlv.factory`'s encode-matches rule would reject
        # it anyway; raising here says why rather than leaving the
        # rejection to look like a coincidence.
        def parse(s)
          unless s.size == WIDTH
            raise ArgumentError,
              "#{self.class} is #{WIDTH} octet and this value is #{s.size}"
          end
          @value = s.slice!(0, WIDTH).unpack1('C').to_i
          self
        end

        def encode_value
          [@value].pack('C')
        end

        def set?(name)
          !(@value & BITS.fetch(name)).zero?
        end

        def overload? ; set?(:overload) ; end
        def attached? ; set?(:attached) ; end
        def external? ; set?(:external) ; end
        def abr?      ; set?(:abr)      ; end
        def router?   ; set?(:router)   ; end
        def v6?       ; set?(:v6)       ; end

        # The two bits outside the six Table 7 defines, in place.
        def undefined_bits
          @value & ~DEFINED_BITS & 0xff
        end

        def undefined_bits?
          !undefined_bits.zero?
        end

        def names
          BITS.keys.select { |n| set?(n) }
        end

        # The names that are set, and the whole octet behind them only
        # when an undefined bit is set, so an ordinary TLV hashes to the
        # plain list.
        def value_hash
          h = names
          h += [{ BITS_KEY => @value }] if undefined_bits?
          h
        end

        def to_s
          s = 'Node flags '
          s += names.empty? ? 'none' : names.join(',')
          s += format(', undefined bits %02b', undefined_bits) if
            undefined_bits?
          s
        end

        private

        def set_one(arg)
          if self.class.bits_entry?(arg)
            v = arg[BITS_KEY].to_i
            refuse_a_value_the_field_cannot_hold(v)
            @value = v
          else
            @value |= BITS.fetch(arg) do
              raise ArgumentError, "unknown node flag #{arg.inspect}, " \
                                   "have #{BITS.keys.join(', ')}"
            end
          end
        end

        def from_hash(h)
          read_declared_len(h)
          h = self.class.unwrap(h)
          [*h].each { |a| set_one(a) }
        end

        # The kind of refusal Conventions allows: a value the one-octet
        # field cannot hold cannot be written at all, so packing it
        # would put a different value on the wire than the caller asked
        # for.
        def refuse_a_value_the_field_cannot_hold(v)
          return if v >= 0 and v <= MAX_VALUE
          raise ArgumentError,
            "Node Flag Bits is one octet and #{v} does not fit it"
        end

      end
      register Node_flag_bits

      # TLV 1025, section 5.3.1.5: "The Opaque Node Attribute TLV is an
      # envelope that transparently carries optional Node Attribute TLVs
      # advertised by a router." The section's last line is the whole
      # layout: "The Type is as specified in Table 6. The length is
      # variable."
      #
      # **Transparently is the word, so nothing here reads inside it.**
      # What is in there is whatever the IGP named in the NLRI's
      # Protocol-ID put there, so framing it as BGP-LS TLVs would invent
      # structure. That is the same call `Pdu::Unknown` makes one
      # protocol over and `Evpn::Unknown` makes in this library: an
      # extent you can read without understanding the contents is the
      # licence to frame, and this has no such extent.
      class Opaque_node_attribute < Opaque_tlv
        TYPE = 1025
        HASH_KEY = :opaque_node_attribute
        LABEL = 'Opaque node attribute'
      end
      register Opaque_node_attribute

      # TLV 1026, section 5.3.1.3: "The Value field identifies the
      # symbolic name of the router node. This symbolic name can be the
      # Fully Qualified Domain Name (FQDN) for the router, a substring
      # of the FQDN (e.g., a hostname), or any string that an operator
      # wants to use for the router."
      #
      # **Text, so this is the one class in the family whose field form
      # and hash form are the same String.** Its siblings 1025 and 1027
      # take raw octets and hash as hex, because neither is text.
      #
      # **Two of the section's rules are deviated from on purpose**, per
      # Conventions. "The Value field is encoded in 7-bit ASCII", so a
      # name carrying a high octet is a deliberately wrong TLV and
      # builds; `ascii?` reports it. And "The maximum length of the Node
      # Name TLV is 255 octets", which **does not say whether the four
      # framing octets are in that count**: 255 of value or 251 of value
      # and 255 of TLV are both readings of that sentence and the
      # section settles neither. So nothing here enforces either, and a
      # longer name builds, which the 2-octet Length field can carry.
      class Node_name < Tlv

        TYPE = 1026
        HASH_KEY = :node_name
        LABEL = 'Node name'

        # The section's number, kept as the figure it gives rather than
        # as a check. Which of the two readings it means is open, above.
        MAX_LEN = 255

        attr_reader :name

        # new('router1'), this class's own hash, or another instance.
        # No `is_packed?` branch and no `parse`, for the reason
        # `Opaque_tlv`'s comment gives: the value is the octets.
        def initialize(*args)
          @name = String.new
          if args.size == 1 and args[0].is_a?(self.class)
            self.declared_len = args[0].declared_len
            @name = args[0].name.dup
          elsif args.size == 1 and args[0].is_a?(Hash)
            from_hash(args[0])
          elsif args.size == 1 and args[0].is_a?(String)
            @name = args[0].dup.b
          elsif args.empty?
            # The empty name, which section 5.1's zero-length value
            # permits and which the section calls optional.
          else
            raise ArgumentError, "invalid argument: #{args.inspect}"
          end
          self
        end

        def encode_value
          @name.dup
        end

        # True when every octet is in the 7-bit ASCII the section asks
        # for. A reader only: nothing refuses a name that is not.
        def ascii?
          @name.each_byte.all? { |b| b < 0x80 }
        end

        # The name as text, for a reader. Binary on the wire, so the
        # encoding is forced rather than guessed, and a name that is not
        # ASCII still comes back whole.
        def value_hash
          @name.dup.force_encoding(Encoding::UTF_8)
        end

        def to_s
          "#{LABEL} '#{@name}'"
        end

        private

        def from_hash(h)
          read_declared_len(h)
          h = self.class.unwrap(h)
          @name = h.to_s.dup.b
        end

      end
      register Node_name

      # TLV 1027, section 5.3.1.2: "An IS-IS node can be part of only a
      # single IS-IS area. However, a node can have multiple synonymous
      # area addresses. Each of these area addresses is carried in the
      # IS-IS Area Identifier TLV. If multiple area addresses are
      # present, multiple TLVs are used to encode them."
      #
      # **So this is the first TLV in the family an RFC says to repeat**
      # in so many words, where part 3's four link descriptors each
      # inherit a repeat rule from the IS-IS sub-TLV they correspond to.
      # Nothing here needs to know: a TLV list is a list, which is the
      # shape the attribute's hash keeps, and section 5.1's Length and
      # Value tiebreakers are what order two of them.
      #
      # **The dotted form routers print is a convention and is
      # deliberately not parsed here.** The section gives the value as
      # "IS-IS Area Identifier (variable)" and nothing else, so a
      # presentation form for it would be bgp4r's invention and nothing
      # could check it. Octets in, hex out, and `['490001'].pack('H*')`
      # is how an area address from a router dump gets in.
      class Isis_area_id < Opaque_tlv
        TYPE = 1027
        HASH_KEY = :isis_area_id
        LABEL = 'IS-IS area'
      end
      register Isis_area_id

      # TLV 1028 and 1029, section 5.3.1.4: "The local IPv4/IPv6
      # Router-ID TLVs are used to describe auxiliary Router-IDs that
      # the IGP might be using, e.g., for TE and migration purposes such
      # as correlating a Node-ID between different protocols. If there
      # is more than one auxiliary Router-ID of a given type, then each
      # one is encoded as a separate TLV."
      #
      # **Table 6 gives the widths and neither is RFC 9552's own**: 4
      # octets citing RFC 5305 section 4.3 and 16 citing RFC 6119
      # section 4.1. Part 3's Table 4 situation, one table over, and the
      # reason each class names the document the width came from.
      #
      # **Both rows are in Table 6 and Table 8**, since a local
      # Router-ID is a node attribute and a link attribute both, which
      # is why they are here rather than waiting for part 5b. Table 8's
      # own two rows, 1030 and 1031, are the **remote** ones and are
      # 5b's.
      class Ipv4_local_router_id < Addr_tlv
        TYPE = 1028
        HASH_KEY = :ipv4_local_router_id
        WIDTH = 4
        LABEL = 'Local IPv4 Router-ID'
      end
      register Ipv4_local_router_id

      class Ipv6_local_router_id < Addr_tlv
        TYPE = 1029
        HASH_KEY = :ipv6_local_router_id
        WIDTH = 16
        LABEL = 'Local IPv6 Router-ID'
      end
      register Ipv6_local_router_id

    end

  end

end

load "../../test/unit/nlris/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
