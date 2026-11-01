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

require 'bgp/path_attributes/attribute'
require 'bgp/nlris/link_state_node_attribute'

module BGP

  # The BGP-LS Attribute of RFC 9552 section 5.3, code 29, read in the
  # RFC text on 2026-11-01.
  #
  # "The BGP-LS Attribute (assigned value 29 by IANA) is an optional,
  # non-transitive BGP Attribute that is used to carry link, node, and
  # prefix parameters and attributes. It is defined as a set of
  # Type/Length/Value (TLV) triplets, as described in the following
  # section."
  #
  # **So it is a path attribute and not an NLRI, which is why it reaches
  # neither dispatch gate.** It goes through `Attr.register`, the
  # registry Conventions calls the one that already works, and the TLVs
  # inside it are `Link_state::Tlv` unchanged. One flat registry covers
  # the NLRI's descriptors and these alike, which is IANA's doing: the
  # registry is "BGP-LS NLRI and Attribute TLVs", one space for both.
  # TLV 263 is in Table 4 and Table 6 and is one class.
  #
  # **"This attribute SHOULD only be included with Link-State NLRIs. The
  # use of this attribute for other address families is outside the
  # scope of this document."** Outside the scope is not an error, which
  # is the same shape RFC 7432 section 14 uses for an EVPN MAC length
  # and RFC 6514 section 4.3 for a multicast source length. Nothing here
  # looks at the NLRIs in the UPDATE, so this attribute can be sent
  # beside an IPv4 unicast prefix, which is a test somebody will want.
  #
  # **The ordering rule here is a SHOULD and its breach is explicitly
  # not malformed**, where the NLRI's is a MUST. Section 5.1 says both,
  # two sentences apart. So `ordered?` reports and refuses nothing, and
  # the validation part asks `Link_state::Tlv.ordered?` rather than
  # reimplementing it. Part 7 measured GoBGP 3.23.0 breaking the NLRI's
  # MUST on traffic it originates itself, so do not read either rule off
  # a router.
  #
  # **Nothing validates.** Any TLV, any order, any repetition, in an
  # attribute of any length, including TLVs no RFC puts in this
  # attribute at all. Section 5.3's own size rules are a BGP-LS
  # Producer's and a BGP-LS Propagator's, and the one RFC 7606 action it
  # names, 'Attribute Discard' when another attribute pushes the UPDATE
  # past the maximum message size, is a sender-side condition. So
  # neither is this class's and neither is `validation.rb`'s as it
  # stands.
  class Link_state_attribute < Attr

    # The TLVs, in the order they arrived or were given. **A list and
    # not a map keyed by type**, because section 5.3.1.2 says the IS-IS
    # Area Identifier repeats, section 5.3.1.4 says each auxiliary
    # Router-ID is "a separate TLV", and four of part 3's link
    # descriptors repeat too. `Path_attribute` had to bolt a
    # `:duplicates` key onto a hash keyed by type for the same reason;
    # here repetition is the design and a list carries it for free.
    attr_reader :tlvs

    def initialize(*args)
      @flags, @type = OPTIONAL_NON_TRANSITIVE, BGP_LS
      @tlvs = []
      if args[0].is_a?(String) and args[0].is_packed?
        parse(args[0])
      elsif args[0].is_a?(self.class)
        parse(args[0].encode, *args[1..-1])
      elsif args[0].is_a?(Hash) and args[0].has_key?(:link_state)
        # A Hash with no :link_state key is one TLV's own hash and goes
        # to add like any other value.
        add(*args[0][:link_state])
      else
        add(*args)
      end
    end

    # A TLV instance, or one TLV's hash, or several of either.
    #
    # A `{:tail=>hex}` entry sets the kept tail, which is `Attr::TAIL_KEY`
    # and the mechanism `Cluster_list` and five other attributes already
    # use, so a hash from a malformed attribute builds back.
    def add(*args)
      take_tail(args.flatten).each do |arg|
        if arg.is_a?(Link_state::Tlv)
          @tlvs << arg
        elsif arg.is_a?(Hash)
          @tlvs << Link_state::Tlv.from_hash(arg)
        else
          raise ArgumentError, "invalid argument: #{arg.inspect}, " \
                               'expected a BGP-LS TLV or its hash'
        end
      end
      self
    end
    alias << add

    # The first TLV of a type, or nil. A reader's convenience: a type
    # that repeats wants `tlvs` and a select of its own.
    def tlv(type)
      @tlvs.find { |t| t.type.to_i == type.to_i }
    end

    # Section 5.1's ordering, which for this attribute is a SHOULD:
    # "The TLVs within the BGP-LS Attribute SHOULD be ordered in
    # ascending order by TLV Type ... However, unordered TLVs in the
    # BGP-LS Attribute MUST NOT be considered as malformed."
    def ordered?
      Link_state::Tlv.ordered?(@tlvs)
    end

    def encode
      super(@tlvs.collect { |t| t.encode }.join + (@tail || ''))
    end

    # The TLV list, then whatever octets could not frame a TLV.
    #
    # **Octets are kept rather than repaired**, so `encode` gives back
    # what arrived. `Tlv.parse_list` leaves them where it stopped, which
    # is one octet to three, or any remainder behind a Length that
    # overran. Section 8.2.2 is where a finding for that belongs and
    # part 6 is where it goes; keeping the octets is not reporting them.
    def parse(s)
      @flags, @type, _, value = super(s)
      v = value.dup.b
      @tlvs = Link_state::Tlv.parse_list(v)
      @tail = v.b unless v.empty?
      self
    end

    # The TLVs' own hashes in order, plus a `{:tail=>hex}` entry when
    # octets were kept, so the hash of a malformed attribute round trips
    # byte for byte through `new`.
    def to_hash
      { :link_state => @tlvs.collect { |t| t.to_hash } + [tail_entry].compact }
    end

    def to_s(method = :default)
      s = @tlvs.collect { |t| t.to_s }.join(', ')
      s += ", tail #{@tail.unpack1('H*')}" if @tail
      super(s, method)
    end

  end

  Attr.register(ATTR::BGP_LS, Link_state_attribute, :link_state) { |v|
    Link_state_attribute.new(*v)
  }

end

load "../../test/unit/path_attributes/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
