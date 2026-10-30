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
require 'bgp/nlris/rd'
require 'bgp/nlris/flow_spec_component'

module BGP

  # One Flow Specification NLRI: the 2-tuple of RFC 8955 section 4,
  # Figure 1, holding the component list of section 4.2 and, for SAFI
  # 134, the Route Distinguisher of section 8.
  #
  # `docs/flow-spec.md` is the guide, and every section number here was
  # read in the RFC text. Nothing dispatches to this class yet: the two
  # gates in `mp_reach.rb` and `Nlri.factory` come next, the way #125
  # landed the export rules and #156 the FIB planner before anything
  # called either.
  #
  # **The NLRI owns its own framing, and that is the point.** A prefix
  # family's length is in bits and one octet wide, so `Mp_reach#parse`
  # has always worked out how many octets to slice with
  # `(blen+7)/8+1` and handed that slice down. Section 4.1's length is
  # in **octets** and is 1 or 2 octets wide, so that arithmetic is wrong
  # here twice over. `Flow_spec.nlri_size` answers the question for this
  # family, so the loops can ask rather than calculate.
  #
  # **Nothing validates.** Any component type, any order, any
  # repetition, any length. Section 4.2's "Components MUST follow strict
  # type ordering by increasing numerical order. A given component type
  # MAY (exactly once) be present" binds a sender as much as a reader,
  # so building out of order is a deliberate deviation from a MUST and
  # the receive side check belongs in `validation.rb`.
  class Flow_spec

    # RFC 8955 section 4.1: "If the NLRI length is smaller than 240
    # (0xf0 hex) octets, the length field can be encoded as a single
    # octet. Otherwise, it is encoded as an extended-length 2-octet
    # value in which the most significant nibble has the hex value 0xf."
    # And: "The highest value that can be represented with this encoding
    # is 4095."
    ONE_OCTET_MAX = 239
    EXTENDED      = 0xf0
    MAX_LEN       = 4095

    # RFC 8955 section 8: "a fixed-length Route Distinguisher field (8
    # octets) followed by the Flow Specification NLRI value".
    RD_SIZE = 8

    # One key per component type, as Path_attribute hashes one key per
    # attribute. These four keys are the collection's own and are never
    # read as a component.
    DUP_KEY  = :duplicates
    TAIL_KEY = :tail
    RESERVED_KEYS = [:rd, :path_id, DUP_KEY, TAIL_KEY, :length].freeze

    # The component registry, RFC 8955 section 4.2.2 and RFC 8956
    # section 3, which section 8.1.2 of RFC 8956 keeps as one registry
    # with an IPv4 and an IPv6 name per type value.
    #
    # Six type numbers mean a different class per family: 1 and 2 have a
    # different layout, and 3, 7, 8 and 12 the same octets under another
    # name. Type 13 is in the IPv6 table only, because section 8.1.2
    # gives its IPv4 name as Unassigned, so a type 13 in an IPv4 flow
    # spec is an unknown type and section 4.2 makes that malformed.
    V4 = {
      1  => Destination_prefix, 2  => Source_prefix,
      3  => Ip_protocol,        4  => Port,
      5  => Destination_port,   6  => Source_port,
      7  => Icmp_type,          8  => Icmp_code,
      9  => Tcp_flags,          10 => Packet_length,
      11 => Dscp,               12 => Fragment,
    }.freeze

    V6 = V4.merge(
      1  => Destination_ipv6_prefix, 2 => Source_ipv6_prefix,
      3  => Upper_layer_protocol,    7 => Icmpv6_type,
      8  => Icmpv6_code,            12 => Ipv6_fragment,
      13 => Flow_label
    ).freeze

    COMPONENTS = { IANA::AFI::IPv4 => V4, IANA::AFI::IPv6 => V6 }.freeze

    # Hash key back to class, for the hash build path. The key also says
    # which family, since the six shared type numbers have a key each
    # per family, so a hash carries its own AFI.
    # Unknown is in here and in neither table above, which is the whole
    # point of it: no type number reaches it, and a hash that carries
    # one has to be able to build it back.
    BY_KEY = (V4.values + V6.values + [Unknown]).uniq
             .each_with_object({}) { |k, h| h[k.hash_key] = k }.freeze

    # Which classes mean IPv6, so a build from component objects can
    # work the AFI out rather than being told. Compared by exact class
    # and not with is_a?, because four of them subclass their IPv4
    # namesake and would match it.
    V6_ONLY = [Destination_ipv6_prefix, Source_ipv6_prefix,
               Upper_layer_protocol, Icmpv6_type, Icmpv6_code,
               Ipv6_fragment, Flow_label].freeze

    attr_reader :components, :rd, :path_id, :afi, :safi

    # The Length that arrived, when it is not the number of octets that
    # came with it, so encode writes back what the peer sent rather than
    # what is really there. nil on anything built from values.
    attr_reader :declared_len

    # Octets inside the NLRI value that could not be read as a
    # component, kept whole so encode gives back what arrived.
    attr_reader :tail

    # Four ways in, as Conventions asks:
    #
    #   Flow_spec.new(Flow_spec::Destination_prefix.new('192.0.2.0/24'),
    #                 Flow_spec::Port.new(:eq, 25))
    #   Flow_spec.new(:destination_prefix=>'192.0.2.0/24', :port=>[[:eq, 25]])
    #   Flow_spec.new(wire_bytes, afi, safi)
    #   Flow_spec.new(another_flow_spec)
    #
    # The AFI is a parse time question only, since on the way out the
    # components are already objects that know their own octets. On the
    # way in it decides which of the six shared type numbers to read, so
    # it defaults to IPv4 and `new_ntop` takes it.
    def initialize(*args)
      @components, @rd, @path_id = [], nil, nil
      @declared_len, @tail = nil, nil
      @afi, @safi = IANA::AFI::IPv4, IANA::SAFI::FLOW_SPEC_RULES_1
      if args[0].is_a?(String) and args[0].is_packed?
        s, afi, safi = args
        @afi = afi || IANA::AFI::IPv4
        @safi = safi || IANA::SAFI::FLOW_SPEC_RULES_1
        parse(s)
      elsif args.size == 1 and args[0].is_a?(Flow_spec)
        @afi, @safi = args[0].afi, args[0].safi
        parse(args[0].encode.is_packed)
      elsif args.size == 1 and args[0].is_a?(Hash)
        from_hash(args[0])
      else
        args.flatten.compact.each { |c| add(c) }
        @afi = IANA::AFI::IPv6 if @components.any? { |c| V6_ONLY.include?(c.class) }
      end
      self
    end

    def self.new_ntop(s, afi = IANA::AFI::IPv4, safi = IANA::SAFI::FLOW_SPEC_RULES_1,
                      path_id = nil)
      fs = new(s.is_packed, afi, safi)
      fs.path_id = path_id if path_id
      fs
    end

    attr_writer :path_id

    # RFC 7911 section 3 prepends a Path Identifier to the NLRI, so an
    # extended one is four octets longer. Named as Prefix names it.
    def extended?
      !@path_id.nil?
    end

    def add(c)
      raise ArgumentError, "invalid argument: #{c.inspect}, expected a " \
                           'Flow_spec component' unless c.is_a?(Component)
      @components << c
      self
    end
    alias << add

    # How many octets the next Flow Specification NLRI occupies,
    # including its own length field and any Path Identifier already
    # taken off. This is what `Mp_reach#parse` and `Mp_unreach#parse`
    # need in place of the prefix families' `(blen+7)/8+1`, and it lives
    # here so the family owns its framing.
    #
    # Answers nil for octets too short to hold a length field, so a
    # caller can stop rather than loop.
    def self.nlri_size(s)
      return nil if s.nil? || s.empty?
      b = s.getbyte(0)
      if (b & EXTENDED) == EXTENDED
        return nil if s.size < 2
        2 + (((b & 0x0f) << 8) | s.getbyte(1))
      else
        1 + b
      end
    end

    # Section 4.1's own examples: "the length value of 239 is encoded as
    # 0xef (single octet), while 240 is encoded as 0xf0f0 (2 octets)".
    # A length above 4095 cannot be represented at all, which is the one
    # refusal Conventions allows a constructor, since the alternative is
    # silently writing a different length.
    def self.encode_length(n)
      raise ArgumentError, "length #{n} does not fit in 12 bits, the " \
                           "most RFC 8955 section 4.1 can encode is #{MAX_LEN}" if
        n > MAX_LEN || n < 0
      n <= ONE_OCTET_MAX ? [n].pack('C') : [EXTENDED << 8 | n].pack('n')
    end

    # The value octets: the RD for SAFI 134, then the components, then
    # anything kept whole.
    def encode_value
      s = +''
      s << @rd.encode if @rd
      @components.each { |c| s << c.encode }
      s << @tail if @tail
      s
    end

    # The whole 2-tuple, with the Path Identifier in front of it when
    # there is one.
    def encode
      v = encode_value
      s = +''
      s << [@path_id].pack('N') if @path_id
      s << self.class.encode_length(@declared_len || v.size)
      s << v
      s
    end

    def to_shex
      encode.unpack1('H*')
    end

    def parse(s)
      @components, @tail = [], nil
      len = self.class.nlri_size(s)
      raise ArgumentError, 'too short for a Flow Specification NLRI length ' \
                           'field' if len.nil?
      b = s.getbyte(0)
      hdr = (b & EXTENDED) == EXTENDED ? 2 : 1
      declared = len - hdr
      octets = s.slice!(0, [len, s.size].min)
      value = octets[hdr..-1].to_s
      # A Length longer than the octets that followed it. encode writes
      # back the length that arrived, so a capture that lied can be sent
      # again, which is what Orf keeps declared_len for.
      @declared_len = declared if declared != value.size
      @rd = Rd.new(value.slice!(0, RD_SIZE).is_packed) if
        @safi == IANA::SAFI::FLOW_SPEC_RULES_2 && value.size >= RD_SIZE
      parse_components(value)
      self
    end

    def to_hash
      h = {}
      h[:path_id] = @path_id if @path_id
      h[:rd] = @rd.to_hash[:rd] if @rd
      dups = []
      @components.each do |c|
        ch = c.to_hash
        if ch.keys.any? { |k| h.key?(k) }
          dups << ch
        else
          h = h.merge(ch)
        end
      end
      h[DUP_KEY] = dups unless dups.empty?
      h[:length] = @declared_len if @declared_len
      h[TAIL_KEY] = @tail.unpack1('H*') if @tail
      h
    end

    def to_s
      s = +"Flow spec"
      s << ", ID=#{@path_id}" if @path_id
      s << ", #{@rd}" if @rd
      s << ":\n  " << @components.collect(&:to_s).join("\n  ")
      s << "\n  tail [#{@tail.unpack1('H*')}]" if @tail
      s
    end

    def size
      @components.size
    end

    def empty?
      @components.empty?
    end

    private

    # The component table for this NLRI's family. An AFI with no table
    # reads nothing, so every component is unknown, which is what
    # section 4.2 asks for.
    def table
      COMPONENTS[@afi] || {}
    end

    # RFC 8955 section 4.2.2: "The encoding of each of the components
    # begins with a type field (1 octet) followed by a variable length
    # parameter." A component carries no length of its own, so each
    # class consumes exactly what it understands and the walk is bounded
    # only by this NLRI's value octets.
    #
    # A type with no class keeps the type octet and **everything left**,
    # because an unknown type's parameter length cannot be known, so
    # nothing after it can be read either. See Component::Unknown.
    # **A component is kept only if it can give its own octets back.**
    # That is stricter than catching an exception and it has to be,
    # because the classes do not all raise on octets they cannot read.
    # `Prefix` pads a truncated prefix out to the number of octets its
    # length octet demands and reports the fault through
    # `syntactically_correct?` rather than raising, which is deliberate
    # and long predates this file: in the prefix families
    # `Mp_reach#parse` slices exactly the right number of octets, so the
    # padding only shows on a malformed NLRI. Here the component list
    # has no such guarantee, so `01 18 c0` would come back as
    # `01 18 c0 00 00`, three octets longer than arrived.
    #
    # So each component is parsed on a **copy**, and the consumption is
    # committed only when its `encode` matches the octets it ate. When
    # it does not, those octets are kept whole and the walk stops, which
    # is the keep-what-you-cannot-read rule in Conventions. This also
    # covers a class that consumes nothing, so there is no separate
    # guard against a walk that cannot finish.
    def parse_components(value)
      until value.empty?
        type = value.getbyte(0)
        klass = table[type]
        if klass.nil?
          @components << Unknown.new(value.slice!(0, value.size).is_packed)
          break
        end
        probe = value.dup
        probe.slice!(0, 1)
        c = begin
              klass.new(probe.is_packed)
            rescue StandardError
              nil
            end
        consumed = c.nil? ? 0 : value.size - probe.size
        if c.nil? || consumed.zero? || c.encode != value[0, consumed]
          @tail = value.slice!(0, value.size)
          break
        end
        value.slice!(0, consumed)
        @components << c
      end
    end

    def from_hash(h)
      h = h.dup
      @path_id = h.delete(:path_id)
      rd = h.delete(:rd)
      @rd = rd.is_a?(Rd) ? rd : Rd.new(*[rd].flatten) if rd
      @safi = IANA::SAFI::FLOW_SPEC_RULES_2 if @rd
      @declared_len = h.delete(:length)
      @tail = [h.delete(TAIL_KEY).to_s].pack('H*') if h.key?(TAIL_KEY)
      dups = h.delete(DUP_KEY)
      components_from_hash(h)
      [dups].flatten.compact.each { |d| components_from_hash(d) }
      @afi = IANA::AFI::IPv6 if @components.any? { |c| V6_ONLY.include?(c.class) }
    end

    # One key per component, so the key picks the class and, for the six
    # shared type numbers, the family too. A key that is not a
    # component's is a caller mistake and says so, rather than being
    # dropped where nobody would see it.
    def components_from_hash(h)
      h.each do |k, v|
        next if RESERVED_KEYS.include?(k)
        klass = BY_KEY[k]
        raise ArgumentError, "#{k.inspect} is not a Flow Specification " \
                             "component key, one of #{BY_KEY.keys.inspect}" if
          klass.nil?
        @components << klass.new(k => v)
      end
    end

  end

end
