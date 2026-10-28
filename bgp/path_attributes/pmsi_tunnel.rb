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

    # RFC 6514 section 5 defines tunnel types 0 to 7, and these are they.
    # IANA's "P-Multicast Service Interface Tunnel (PMSI Tunnel) Tunnel
    # Types" registry has since assigned five more, which bgp4r does not
    # name: 8 Transport Tunnel (RFC 7524), 10 Assisted Replication Tunnel
    # (RFC 9574), 11 BIER (RFC 8556), 12 SR-MPLS P2MP Tree and 13 SRv6
    # P2MP Tree (both RFC 10018). 9 is unassigned, 0x7b to 0x7e and 0xfb
    # to 0xfe are experimental, 0x7f is reserved, 0x80 to 0xfa are
    # reserved for Composite Tunnel and 0xff is the wildcard transport
    # tunnel type (RFC 8338). An unnamed type still round trips: pass its
    # number to send it.
    NO_TUNNEL            = 0
    RSVP_TE_P2MP         = 1
    MLDP_P2MP            = 2
    PIM_SSM              = 3
    PIM_SM               = 4
    BIDIR_PIM            = 5
    INGRESS_REPLICATION  = 6
    MLDP_MP2MP           = 7

    TYPES = {
      :no_tunnel            => NO_TUNNEL,
      :rsvp_te_p2mp         => RSVP_TE_P2MP,
      :mldp_p2mp            => MLDP_P2MP,
      :pim_ssm              => PIM_SSM,
      :pim_sm               => PIM_SM,
      :bidir_pim            => BIDIR_PIM,
      :ingress_replication  => INGRESS_REPLICATION,
      :mldp_mp2mp           => MLDP_MP2MP,
    }

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
              :label => h[:label], :flags => h[:flags],
              :leaf_info_required => h[:leaf_info_required])
      else
        type, identifier = args
        opts = args.last.is_a?(Hash) ? args.last : {}
        identifier = nil if identifier.is_a?(Hash)
        build(type, identifier, opts)
      end
    end

    # The MPLS label, in the high 20 bits of the 3 octet field, or nil
    # when the field is zero (RFC 6514 section 5).
    def label
      @label
    end

    def leaf_info_required?
      (@pmsi_flags & LEAF_INFO_REQUIRED) > 0
    end

    def tunnel_name
      TYPES.key(@tunnel_type)
    end

    def to_s(method=:default)
      super("#{tunnel_name || "type #{@tunnel_type}"}: #{identifier_s}" \
            "#{@label ? ", label #{@label}" : ''}" \
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
      h[:identifier] = identifier_hash unless @identifier.empty?
      h[:label] = @label if @label
      h[:flags] = @pmsi_flags if @pmsi_flags != 0 and not leaf_info_required?
      h[:leaf_info_required] = true if leaf_info_required?
      { :pmsi_tunnel => h }
    end

    # RFC 6514 section 5: flags, tunnel type, 3 octet label, identifier.
    # A value too short to hold the fixed part is written back as it came.
    def encode
      return super(tail) if tail
      field = @label ? (@label << 4) : 0
      super([@pmsi_flags, @tunnel_type, field >> 16, field & 0xffff].pack('CCCn') + @identifier)
    end

    private

    # Two addresses for the PIM trees, one for ingress replication,
    # octets otherwise.
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
      @tunnel_type = type.is_a?(Symbol) ? TYPES[type] : type
      raise ArgumentError, "unknown tunnel type #{type.inspect}" if @tunnel_type.nil?
      unless @tunnel_type.is_a?(Integer) and (0..255).include?(@tunnel_type)
        raise ArgumentError, "invalid tunnel type #{type.inspect}, expected 0 to 255"
      end
      @pmsi_flags = opts[:flags].to_i
      @pmsi_flags |= LEAF_INFO_REQUIRED if opts[:leaf_info_required]
      @label = opts[:label]
      if @label and not (@label.is_a?(Integer) and @label >= 0 and @label <= 0xfffff)
        raise ArgumentError, "invalid MPLS label #{@label.inspect}, expected 0 to 1048575"
      end
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
        return
      end
      @pmsi_flags, @tunnel_type = value.unpack('CC')
      field = (value.getbyte(2) << 16) | value.byteslice(3, 2).unpack1('n')
      @label = field.zero? ? nil : (field >> 4)
      @identifier = value.byteslice(5, value.size - 5).to_s.b
    end

  end

  Attr.register(ATTR::PMSI_TUNNEL, Pmsi_tunnel, :pmsi_tunnel) { |v| Pmsi_tunnel.new(v) }

end

load "../../test/unit/path_attributes/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
