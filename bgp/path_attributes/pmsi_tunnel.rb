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

module BGP

  # PMSI Tunnel, attribute 22, RFC 6514 section 5: an optional
  # transitive attribute saying which provider tunnel carries a
  # customer's multicast traffic.
  #
  #   Pmsi_tunnel.new(:ingress_replication, '10.0.0.1', :label => 100)
  #   Pmsi_tunnel.new(:pim_ssm, ['10.0.0.1', '232.1.1.1'], :leaf_info_required => true)
  #   Pmsi_tunnel.new(:no_tunnel)
  #   Pmsi_tunnel.new(wire_bytes)
  #   Path_attribute.new(:pmsi_tunnel => {:tunnel_type => :ingress_replication,
  #                                       :identifier => '10.0.0.1', :label => 100})
  #
  # The tunnel identifier is kept as octets whatever the type, so a type
  # bgp4r has no shape for still round trips. Nothing is checked when
  # building: a test can send any type with any identifier.
  class Pmsi_tunnel < Attr

    # RFC 6514 section 5 defines tunnel types 0 to 7, and five more are
    # assigned. The whole of IANA's "P-Multicast Service Interface Tunnel
    # (PMSI Tunnel) Tunnel Types" registry, read there on 2026-10-31, and
    # its column is headed Meaning rather than Name:
    #
    #   0x00 no tunnel information present   RFC 6514
    #   0x01 RSVP-TE P2MP LSP                RFC 6514
    #   0x02 mLDP P2MP LSP                   RFC 6514
    #   0x03 PIM-SSM Tree                    RFC 6514
    #   0x04 PIM-SM Tree                     RFC 6514
    #   0x05 BIDIR-PIM Tree                  RFC 6514
    #   0x06 Ingress Replication             RFC 6514
    #   0x07 mLDP MP2MP LSP                  RFC 6514
    #   0x08 Transport Tunnel                RFC 7524
    #   0x09 Unassigned
    #   0x0a Assisted Replication Tunnel     RFC 9574
    #   0x0b BIER                            RFC 8556
    #   0x0c SR-MPLS P2MP Tree               RFC 10018
    #   0x0d SRv6 P2MP Tree                  RFC 10018
    #   0x0e to 0x7a Unassigned
    #   0x7b to 0x7e Reserved for Experimental Use   RFC 8317
    #   0x7f Reserved                                RFC 8317
    #   0x80 to 0xfa Reserved for Composite Tunnel   RFC 8317 (see COMPOSITE)
    #   0xfb to 0xfe Reserved for Experimental Use   RFC 7385
    #   0xff wildcard transport tunnel type          RFC 8338 (see WILDCARD)
    #
    # The symbols drop the generic trailing noun the way the original
    # eight do, so "PIM-SSM Tree" is `:pim_ssm` and "Assisted Replication
    # Tunnel" is `:assisted_replication`. An unnamed type still round
    # trips: pass its number to send it.
    NO_TUNNEL            = 0
    RSVP_TE_P2MP         = 1
    MLDP_P2MP            = 2
    PIM_SSM              = 3
    PIM_SM               = 4
    BIDIR_PIM            = 5
    INGRESS_REPLICATION  = 6
    MLDP_MP2MP           = 7
    TRANSPORT            = 8
    ASSISTED_REPLICATION = 10
    BIER                 = 11
    SR_MPLS_P2MP         = 12
    SRV6_P2MP            = 13

    TYPES = {
      :no_tunnel            => NO_TUNNEL,
      :rsvp_te_p2mp         => RSVP_TE_P2MP,
      :mldp_p2mp            => MLDP_P2MP,
      :pim_ssm              => PIM_SSM,
      :pim_sm               => PIM_SM,
      :bidir_pim            => BIDIR_PIM,
      :ingress_replication  => INGRESS_REPLICATION,
      :mldp_mp2mp           => MLDP_MP2MP,
      :transport            => TRANSPORT,
      :assisted_replication => ASSISTED_REPLICATION,
      :bier                 => BIER,
      :sr_mpls_p2mp         => SR_MPLS_P2MP,
      :srv6_p2mp            => SRV6_P2MP,
    }

    # **0xff is not a 7 bit type and so is not in TYPES**, because its
    # high bit is the composite tunnel bit: `tunnel_type` answers 0x7f
    # for it and `composite?` answers true. That is not an accident of
    # this reader, it is what RFC 8317 section 8.1 anticipated when it
    # reserved 0x7f, in its own words "The value 0x7F, which is the
    # mirror image of (0xFF), is reserved in this document." So the
    # whole octet is what names the wildcard, and `wildcard?` reads it.
    WILDCARD = 0xff

    # **The composite tunnel bit, RFC 8317 section 6.2**, which is why
    # `tunnel_type` answers 7 bits and not the whole octet. Section 8.1
    # "updates [RFC7385] by changing the previously unassigned values"
    # so that 0x80 to 0xfa are "Reserved for Composite Tunnel", and
    # section 6.2 says what the bit means: "When receiver Ingress
    # Replication labels are needed, the high-order bit of the Tunnel
    # Type field (composite tunnel bit) is set while the remaining
    # low-order seven bits indicate the Tunnel Type as before (for the
    # existing Tunnel Types)."
    #
    # It is a **layout change and not only a name**, which is the part
    # to know: "When this composite tunnel bit is set, the 'tunnel
    # identifier' field begins with a three-octet label, followed by the
    # actual tunnel identifier for the transmit tunnel." That leading
    # label is `ir_label` here, and the Tunnel Identifier `identifier`
    # answers is what follows it.
    #
    # Section 6.2 also records why the bit lives in this field rather
    # than in the Flags octet, which is worth keeping because it is a
    # deliberate interoperability choice: "PEs that don't understand the
    # new meaning of the high-order bit treat the Tunnel Type as an
    # undefined Tunnel Type and treat the PMSI Tunnel attribute as a
    # malformed attribute [RFC6514]. That is why the composite tunnel
    # bit is allocated in the Tunnel Type field rather than the Flags
    # field."
    COMPOSITE = 0x80

    # The only flag RFC 6514 section 5 defines, and the only one bgp4r
    # names. RFC 7902 made the field a registry, "P-Multicast Service
    # Interface (PMSI) Tunnel Attribute Flags", and numbers its 8 bits
    # left to right 0 to 7, so bit 7 is this one, value 0x01. Five more
    # entries are assigned above it, and the rest of the octet is not
    # reserved any more: bit 1 Extension, 0x40 (RFC 7902); bit 2 Leaf
    # Information Required per-Flow (LIR-pF), 0x20 (RFC 8534); bits 3 to 4
    # Assisted Replication Type (T), 0x18 (RFC 9574); bit 5 Broadcast and
    # Multicast (BM), 0x04 (RFC 9574); bit 6 Unknown (U), 0x02 (RFC 9574).
    # Only bit 0, 0x80, is still unassigned. Pass :flags to set any of
    # them; nothing is checked when building.
    LEAF_INFO_REQUIRED = 0x01

    attr_reader :tunnel_type, :identifier, :pmsi_flags

    def initialize(*args)
      @flags, @type = OPTIONAL_TRANSITIVE, PMSI_TUNNEL
      if args[0].is_a?(String) and args[0].is_packed?
        parse(args[0])
      elsif args[0].is_a?(self.class)
        parse(args[0].encode)
      elsif args.size == 1 and args[0].is_a?(Hash)
        h = args[0]
        take_tail_key(h)
        # A hash from a value too short to hold the fixed part carries
        # the kept octets and nothing else, so the fields start at zero.
        build(h[:tunnel_type] || (tail && NO_TUNNEL), h[:identifier],
              :label => h[:label], :label_bits => h[:label_bits],
              :composite => h[:composite],
              :ir_label => h[:ir_label], :ir_label_bits => h[:ir_label_bits],
              :flags => h[:flags],
              :leaf_info_required => h[:leaf_info_required])
      else
        type, identifier = args
        opts = args.last.is_a?(Hash) ? args.last : {}
        identifier = nil if identifier.is_a?(Hash)
        build(type, identifier, opts)
      end
    end

    # The 20 bit label sits in the high 20 bits of the 3 octet field, so
    # these are the 4 bits below it. RFC 6514 section 5 names the field
    # "MPLS Label" and describes no layout for those 4 bits, the same
    # shape RFC 7432 section 7.1 has for its own 3 octet label, so they
    # are **kept and echoed** rather than read: an encoder that wrote
    # them back as 0 could not replay a capture, which Conventions makes
    # the one thing this library must always do.
    DEFINED_LABEL_BITS = 0xfffff0

    # The MPLS label, in the high 20 bits of the 3 octet field, or nil
    # when the whole field is zero (RFC 6514 section 5).
    def label
      @label
    end

    # All 24 bits of the label field, which is what encode writes. Read
    # it when undefined_label_bits? says the field holds more than the
    # label; `label` alone cannot rebuild it then.
    def label_bits
      @label_field
    end

    # Whether a bit below the 20 bit label arrived set, which is what
    # puts a :label_bits key in the hash.
    def undefined_label_bits?
      (@label_field.to_i & ~DEFINED_LABEL_BITS) > 0
    end

    # Whether the composite tunnel bit of RFC 8317 section 6.2 is set.
    def composite?
      @composite
    end

    # Whether the whole Tunnel Type octet is RFC 8338's wildcard, which
    # is the composite bit over the 0x7f RFC 8317 reserved for it.
    def wildcard?
      @composite && @tunnel_type == (WILDCARD & ~COMPOSITE)
    end

    # The leading 3 octet label a composite tunnel puts in front of the
    # Tunnel Identifier, its high 20 bits, or nil when there is no such
    # field. **Absent is a real answer**, and not only for a
    # non-composite attribute: a composite one whose body leaves fewer
    # than 3 octets after the fixed part has nowhere to put it, and
    # bgp4r keeps those octets in `identifier` and replays them rather
    # than inventing a field. So this answers 0 for a zero field, where
    # `label` answers nil, because there nil has to mean absent.
    def ir_label
      @ir_label
    end

    # All 24 bits of that field, or nil when there is none.
    def ir_label_bits
      @ir_label_field
    end

    def undefined_ir_label_bits?
      !@ir_label_field.nil? &&
        (@ir_label_field & ~DEFINED_LABEL_BITS) > 0
    end

    def leaf_info_required?
      (@pmsi_flags & LEAF_INFO_REQUIRED) > 0
    end

    def tunnel_name
      TYPES.key(@tunnel_type)
    end

    def to_s(method=:default)
      super("#{type_s}: #{identifier_s}" \
            "#{@label ? ", label #{@label}" : ''}" \
            "#{@ir_label ? ", ir label #{@ir_label}" : ''}" \
            "#{leaf_info_required? ? ', leaf info required' : ''}", method)
    end

    # The fields, or just a :tail key (Attr::TAIL_KEY) holding the octets
    # kept from a value too short to read, so the hash of a malformed
    # attribute round trips byte for byte through new. The key sits in
    # the nested hash, where the attributes that hash a value list carry
    # a {:tail=>hex} entry instead.
    def to_hash
      return { :pmsi_tunnel => tail_entry } if tail
      h = { :tunnel_type => tunnel_name || @tunnel_type }
      # RFC 8317 section 6.2's bit and its leading label, each only when
      # present, so a non-composite attribute hashes as it always did.
      h[:composite] = true if @composite
      h[:identifier] = identifier_hash unless @identifier.empty?
      h[:label] = @label if @label
      # :ir_label carries 0 where :label is omitted for a zero field, and
      # the reason is that this field is **optional**: the fixed part
      # always has a label field, so omitting the key says zero, while
      # the leading label may be absent entirely and the key is the only
      # thing that says whether it is there.
      h[:ir_label] = @ir_label if @ir_label_field
      h[:ir_label_bits] = @ir_label_field if undefined_ir_label_bits?
      # Only when the field holds more than the label, so an ordinary
      # attribute hashes as it always did. Same rule as :tail and :bits.
      h[:label_bits] = @label_field if undefined_label_bits?
      # Whenever the octet holds a bit other than the one named below, so
      # flags 0x41 carry both keys and the RFC 7902 Extension bit is not
      # lost behind :leaf_info_required. The two are not exclusive.
      h[:flags] = @pmsi_flags if (@pmsi_flags & ~LEAF_INFO_REQUIRED) > 0
      h[:leaf_info_required] = true if leaf_info_required?
      { :pmsi_tunnel => h }
    end

    # RFC 6514 section 5: flags, tunnel type, 3 octet label, identifier.
    # A value too short to hold the fixed part is written back as it came.
    def encode
      return super(tail) if tail
      # RFC 8317 section 6.2 puts the composite bit back on the Tunnel
      # Type octet, and its leading label back in front of the Tunnel
      # Identifier. No ir_label means none is written, so a composite
      # attribute whose body had no room for one replays as it came.
      octet = @tunnel_type | (@composite ? COMPOSITE : 0)
      super([@pmsi_flags, octet, @label_field >> 16,
             @label_field & 0xffff].pack('CCCn') +
            (@ir_label_field ? label_octets(@ir_label_field) : ''.b) +
            @identifier)
    end

    private

    # The wildcard names the whole octet, so it is not "composite type
    # 127"; anything else is the 7 bit type with the bit said in front.
    def type_s
      return 'wildcard transport tunnel type' if wildcard?
      "#{@composite ? 'composite ' : ''}#{tunnel_name || "type #{@tunnel_type}"}"
    end

    # Two addresses for the PIM trees, one for ingress replication,
    # octets otherwise. **The five types named since RFC 6514 print
    # hex**, because none of their shapes has been read here: RFC 7524,
    # RFC 8556, RFC 9574 and RFC 10018 are not in hand, and inventing a
    # shape would print a confident wrong answer where hex is honest.
    def identifier_s
      case @tunnel_type
      when PIM_SSM, PIM_SM, BIDIR_PIM
        @identifier.size == 8 ? ip(0) + ' -> ' + ip(4) : hex
      when INGRESS_REPLICATION
        @identifier.size == 4 ? ip(0) : hex
      else
        hex
      end
    end

    def identifier_hash
      case @tunnel_type
      when PIM_SSM, PIM_SM, BIDIR_PIM
        @identifier.size == 8 ? [ip(0), ip(4)] : hex
      when INGRESS_REPLICATION
        @identifier.size == 4 ? ip(0) : hex
      else
        hex
      end
    end

    def ip(offset)
      IPAddr.new_ntoh(@identifier.byteslice(offset, 4)).to_s
    end

    def hex
      @identifier.unpack1('H*')
    end

    def build(type, identifier, opts = {})
      raw = type.is_a?(Symbol) ? TYPES[type] : type
      raise ArgumentError, "unknown tunnel type #{type.inspect}" if raw.nil?
      unless raw.is_a?(Integer) and (0..255).include?(raw)
        raise ArgumentError, "invalid tunnel type #{type.inspect}, expected 0 to 255"
      end
      # A number with the high bit set is a composite tunnel, RFC 8317
      # section 6.2, so a caller already passing 0x82 gets the octets it
      # always did while tunnel_type answers the 7 bit registry number.
      # :composite asks for the bit with a plain type.
      @composite = (raw & COMPOSITE) > 0 || opts[:composite] ? true : false
      @tunnel_type = raw & ~COMPOSITE
      @pmsi_flags = opts[:flags].to_i
      @pmsi_flags |= LEAF_INFO_REQUIRED if opts[:leaf_info_required]
      @label = opts[:label]
      if @label and not (@label.is_a?(Integer) and @label >= 0 and @label <= 0xfffff)
        raise ArgumentError, "invalid MPLS label #{@label.inspect}, expected 0 to 1048575"
      end
      # :label_bits is the whole 24 bit field and wins where it is given,
      # since it is the only way to say what the 4 bits below the label
      # hold. Without it the field is the label shifted into place, which
      # is what an encoder is asked for.
      bits = opts[:label_bits]
      if bits and not (bits.is_a?(Integer) and bits >= 0 and bits <= 0xffffff)
        raise ArgumentError, "invalid label field #{bits.inspect}, expected 0 to 16777215"
      end
      @label_field = bits || (@label ? @label << 4 : 0)
      @label ||= @label_field.zero? ? nil : (@label_field >> 4)
      # RFC 8317 section 6.2's leading label, the same pair of options
      # one level down. **Nothing is inserted when neither is given**,
      # even with the composite bit set: building never validates, so
      # bgp4r writes the fields it was asked for and a test can put a
      # composite tunnel with no leading label on the wire. Pass
      # :ir_label => 0 for the zero field a correct encoder writes.
      ir = opts[:ir_label]
      if ir and not (ir.is_a?(Integer) and ir >= 0 and ir <= 0xfffff)
        raise ArgumentError, "invalid IR label #{ir.inspect}, expected 0 to 1048575"
      end
      ir_bits = opts[:ir_label_bits]
      if ir_bits and not (ir_bits.is_a?(Integer) and ir_bits >= 0 and ir_bits <= 0xffffff)
        raise ArgumentError,
              "invalid IR label field #{ir_bits.inspect}, expected 0 to 16777215"
      end
      @ir_label_field = ir_bits || (ir ? ir << 4 : nil)
      @ir_label = @ir_label_field && (@ir_label_field >> 4)
      @identifier = pack_identifier(identifier)
    end

    def pack_identifier(identifier)
      case identifier
      when nil    then ''.b
      when Array  then identifier.collect { |a| IPAddr.new(a.to_s).hton }.join.b
      when String
        if identifier =~ /\A(\h\h)+\z/ and identifier !~ /\A\d+\.\d+\.\d+\.\d+\z/
          [identifier].pack('H*')
        else
          begin
            IPAddr.new(identifier).hton.b
          rescue IPAddr::Error
            identifier.b
          end
        end
      else
        raise ArgumentError, "invalid tunnel identifier #{identifier.inspect}"
      end
    end

    # A value shorter than the 5 octet fixed part is kept in @tail as it
    # came, so encode gives back what was received. RFC 6514 section 5
    # makes such an attribute malformed; Path_attribute#errors reports it.
    def parse(s)
      @flags, @type, _, value = super(s)
      if value.size < 5
        @tail = value.b
        @pmsi_flags, @tunnel_type, @label, @identifier = 0, 0, nil, ''.b
        @label_field = 0
        return
      end
      @pmsi_flags, octet = value.unpack('CC')
      # RFC 8317 section 6.2: the high bit is the composite tunnel bit
      # and "the remaining low-order seven bits indicate the Tunnel Type
      # as before", so the registry's number is what tunnel_type answers.
      @composite, @tunnel_type = (octet & COMPOSITE) > 0, octet & ~COMPOSITE
      # The whole field is kept, so encode replays it whatever is in the
      # 4 bits below the label.
      @label_field = label_field_at(value, 2)
      @label = @label_field.zero? ? nil : (@label_field >> 4)
      rest = value.byteslice(5, value.size - 5).to_s.b
      # And when the bit is set "the 'tunnel identifier' field begins
      # with a three-octet label, followed by the actual tunnel
      # identifier". A body with no room for one keeps its octets where
      # they are rather than being given a field it did not carry.
      if @composite and rest.size >= 3
        @ir_label_field = label_field_at(rest, 0)
        @ir_label = @ir_label_field >> 4
        rest = rest.byteslice(3, rest.size - 3).to_s.b
      end
      @identifier = rest
    end

    # One 3 octet label field, read at an offset.
    def label_field_at(s, at)
      (s.getbyte(at) << 16) | s.byteslice(at + 1, 2).unpack1('n')
    end

    def label_octets(field)
      [field >> 16, field & 0xffff].pack('Cn')
    end

  end

  Attr.register(ATTR::PMSI_TUNNEL, Pmsi_tunnel, :pmsi_tunnel) { |v| Pmsi_tunnel.new(v) }

end

load "../../test/unit/path_attributes/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
