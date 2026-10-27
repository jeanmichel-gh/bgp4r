#--
# Copyright 2008, 2009, 2026 Jean-Michel Esnault.
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
require 'bgp/path_attributes/attribute'

module BGP

  module ATTR::XTENDED_COMMUNITY

    ROUTE_TARGET = 2
    ROUTE_ORIGIN = 3
    LINK_BANDWIDTH = 4
    OSPF_DOMAIN_ID = 5
    OSPF_ROUTER_ID = 7

    BGP_ORIGIN_VALIDATION_STATE = 0
    BGP_DATA_COLLECT = 8
    COLOR = 11
    ENCAPSULATION = 12

    IANA_AUTHORITY_BIT = 0x80
    TRANSITIVE = 0x0    
    NON_TRANSITIVE = 0x40    

    TWO_OCTET_AS = 0
    IPV4_ADDR = 1
    FOUR_OCTET_AS = 2
    OPAQUE = 3
    FLOAT = -1
    
    DEFAULT_OPAQUE_ENCODING = 'H12'

    def encode
      [@type, @subtype, _encoded_value_].pack('CCa6')
    end
    
    def parse(s)
      @type, @subtype = s.slice!(0,2).unpack('CC')
      case community_structure
      when TWO_OCTET_AS ; @global, @local = s.unpack('nN')
      when IPV4_ADDR
        @global, @local = s.unpack('Nn')
      when FOUR_OCTET_AS
        # RFC 5668 section 2: 4 octet global admin (AS), 2 octet local admin.
        @global, @local = s.unpack('Nn')
      when OPAQUE
        case self
        when Color
          _,@global = s.unpack('nN')
        when Origin_validation_state
          _,@global = s.unpack('nN')
        else
          # unpack returns an Array. Keep the 12 hex digits themselves, the
          # form _encoded_value_ packs back with 'H12'.
          @global = s.unpack1('H12')
        end
      when FLOAT
        _, @global = s.unpack('ng')
      end
    end
    
    # RFC 4360 section 2: the structure of the community is the low 2 bits
    # of the type octet. Each predicate compares those bits, so a community
    # answers true to one structure only.
    def is_opaque?
      @type & 3 == OPAQUE
    end
    
    def is_ipv4_addr?
      @type & 3 == IPV4_ADDR
    end
    
    def is_two_octet_asn?
      @type & 3 == TWO_OCTET_AS
    end  
    
    def two_octet
      @type &= ~3
    end
    
    def ipv4_addr
      @type &= ~3
      @type |= 1
    end
    
    def opaque
      @type |= 3
    end
    
    def non_transitive
      @type |= 0x40
    end
    
    def transitive
      @type &= ~0x40
    end
    
    def is_transitive? 
      @type & 0x40 == 0
    end
    
    def non_transitive? 
      not is_transitive?
    end
    
    def to_i
      encode.unpack('H*')[0].to_i(16)
    end
    
    def <=>(other)
      to_i <=> other.to_i
    end
    
    def name
      self.class.to_s.split('::').last.gsub('_',' ')
    end
    def to_s
      "#{name}: #{value}"
    end
    
    def to_hash
      { self.class.to_s.split('::').last.downcase.to_sym => value2 }
    end

    private

    def value
      case community_structure
      when TWO_OCTET_AS, FOUR_OCTET_AS
        "#{@global}:#{@local}"
      when IPV4_ADDR
        "#{IPAddr.create(@global)}:#{@local}"
      when OPAQUE
        "#{@global}"
      when FLOAT
        "#{[@global].pack('g').unpack('g')[0]}"
      else
        raise RuntimeError, "bogus type: #{@type}"
      end
      
    end

    def value2
      case community_structure
      when FLOAT ; @global
      when IPV4_ADDR ;  ["#{IPAddr.create(@global)}",@local]
      else 
        [@global, @local]
      end
    end

    def community_structure
      cs = @type & 3
      cs = FLOAT if cs == TWO_OCTET_AS and @subtype == LINK_BANDWIDTH
      return cs
    end

    def _encoded_value_
      case community_structure
      when TWO_OCTET_AS
        [@global, @local].pack('nN')
      when IPV4_ADDR, FOUR_OCTET_AS
        [@global, @local].pack('Nn')
      when OPAQUE
        case self
        when BGP::Color
          [0,@global].pack('nN')
        when BGP::Origin_validation_state
          [0,@global].pack('nN')
        else
          [@global].pack('H12')
        end
      when FLOAT
        [0,@global].pack('ng')
      else
        raise RuntimeError, "bogus type: #{@type}"
      end
    end
    
  end
  

  class Extended_community
    include ATTR::XTENDED_COMMUNITY
    include Comparable

    # The largest value the Integer form can hold: RFC 4360 section 2
    # makes an extended community 8 octets.
    MAX_VALUE = 0xffffffffffffffff

    # The 8 octets of an Integer form.
    #
    # A value outside 0..MAX_VALUE cannot be represented in 8 octets, and
    # format('%16.16x') gives 17 digits for one too large and a leading
    # '..' for a negative, either of which packs into a different
    # community than the caller asked for. Sending the wrong community in
    # silence is worse than refusing, which is the narrow case the
    # conventions in CLAUDE.md allow a constructor to refuse. It takes
    # nothing away from negative testing: a malformed extended community
    # of any length still comes from wire bytes, from Attr::Raw, or from
    # the BGP::Fault helpers.
    def self.octets(n)
      unless n.is_a?(Integer) and (0..MAX_VALUE).include?(n)
        raise ArgumentError,
          "invalid extended community #{n.inspect}, expected 0 to #{MAX_VALUE}"
      end
      [format('%16.16x', n)].pack('H*')
    end

    def self.factory(_s)
      if _s.is_a?(Integer)
        s = octets(_s)
      else
        s = _s
      end
      type, subtype, _ = s.unpack('CCa6')
      # RFC 4360 section 2: the type (high octet) and the subtype (low octet)
      # together say what the community is. The transitive bit (0x40) is
      # masked. The IANA authority bit (0x80) is kept, so 0x80xx types do not
      # alias 0x00xx types.
      klass = FACTORY[[type & ~NON_TRANSITIVE, subtype]]
      if klass
        klass.new(s)
      else
        # RFC 4360 sections 2 and 4, RFC 7606 section 7.14: an unknown type
        # or subtype is not an error. Keep it as is.
        Unknown.new(s)
      end
    end

    def initialize(*args)
      @type=TWO_OCTET_AS
      if args.size==1 and args[0].is_a?(String) and args[0].is_packed?
        parse(args[0])
      elsif args.size==3
        @type, @subtype, value = args
        raise ArgumentError, "invalid argument #{args.inspect}"  unless is_a?(Opaque)
        @type |= OPAQUE
        @global, @local=value, nil
        
      elsif args.size==4
        raise  ArgumentError, "This is a base class and should not be instanciated"  if instance_of?(Extended_community)
        @type, @subtype, @global, @local = args
        if @global.is_a?(String) and @local.is_a?(Integer)
          @type |= IPV4_ADDR
          @global = IPAddr.new(@global).to_i
        elsif four_octet_as_specific?
          # RFC 5668 section 2: an AS above 65535 needs the 4 octet AS
          # specific type (0x02), with a 2 octet local admin.
          raise ArgumentError, "local admin #{@local} does not fit in 2 octets" if @local.to_i > 0xffff
          @type |= FOUR_OCTET_AS
        end
      elsif args.size==1 and args[0].is_a?(Integer)
        # RFC 4360 section 2: a community is 8 octets. An Integer is those
        # octets as one number, the form to_i gives back. A number outside
        # that range has no 8 octet form: refuse it rather than wrap it
        # into a different community.
        parse(Extended_community.octets(args[0]))
      elsif args.empty?
        @type, @subtype, @global, @local = 0,0,0,0
      else
        raise ArgumentError, "invalid arg #{args.inspect}"
      end
    end
  end

  class Extended_community
    private
    def four_octet_as_specific?
      [ROUTE_TARGET, ROUTE_ORIGIN].include?(@subtype) and
        @type & 3 == TWO_OCTET_AS and @global.is_a?(Integer) and @global > 0xffff
    end
  end

  class Route_target < Extended_community
    def initialize(*args)
      if args[0].is_a?(String) and args[0].is_packed?
        super(*args)
      else
        super(*[0, ROUTE_TARGET, *args].flatten)
      end
    end
  end

  class Route_origin < Extended_community
    def initialize(*args)
      if args[0].is_a?(String) and args[0].is_packed?
        super(*args)
      else
        super(*[0,ROUTE_ORIGIN,*args].flatten)
      end
    end
  end

  class Ospf_domain_id < Extended_community
    def initialize(*args)
      if args[0].is_a?(String) and args[0].is_packed?
        super(*args)
      else
        args += [0]
        super(1,OSPF_DOMAIN_ID,*args)
      end
    end
    def value2
      "#{IPAddr.create(@global)}"
    end
  end

  class Ospf_router_id < Extended_community
    def initialize(*args)
      if args[0].is_a?(String) and args[0].is_packed?
        super(*args)
      else
        args += [0]
        super(1,OSPF_ROUTER_ID,*args)
      end
    end
    def value2
      "#{IPAddr.create(@global)}"
    end
  end

  class Bgp_data_collect < Extended_community
    def initialize(*args)
      if args[0].is_a?(String) and args[0].is_packed?
        super(*args)
      else
        super(0,BGP_DATA_COLLECT,*args)
      end
    end
  end

  class Opaque < Extended_community
    def initialize(*args)
      if args[0].is_a?(String) and args[0].is_packed?
        super(*args)
      else
        super(*args)
      end
    end
  end
  
  class Link_bandwidth < Extended_community
    def initialize(*args)
      if args[0].is_a?(String) and args[0].is_packed?
        super(*args)
      else
        args += [0]
        super(NON_TRANSITIVE | TWO_OCTET_AS, LINK_BANDWIDTH, *args)
      end
    end
    def value2
      @global
    end
  end

  class Color < Opaque
    def initialize(*args)
      args = 0 if args.empty?
      if args[0].is_a?(String) and args[0].is_packed?
        super(*args)
      else        
        super(TRANSITIVE, COLOR, *args)
      end
    end
    def value2
      @global
    end
  end

  class Origin_validation_state < Opaque
    def initialize(*args)
      args = 0 if args.empty?
      if args[0].is_a?(String) and args[0].is_packed?
        super(*args)
      else
        raise  ArgumentError, "Too many arguments." if args.length>1
        value = 0
        case args[0]
        when :valid
          value=0
        when :not_found
          value=1
        when :invalid
          value=2
        else
          value=args[0]
        end
        super(NON_TRANSITIVE, BGP_ORIGIN_VALIDATION_STATE, value)
      end
    end
    def validation_state
      case value2
      when 0; :valid
      when 1; :not_found
      when 2; :invalid
      else
        # RFC 8097 section 2 defines 0, 1 and 2. Anything else is bogus.
        raise RuntimeError, "bogus validation state: #{value2}"
      end
    end
    def value2
      @global
    end

  end
  
  # RFC 4360 section 2, RFC 7606 section 7.14: a community of a type or
  # subtype we do not know. The 8 octets are kept and sent back unchanged.
  class Extended_community::Unknown < Extended_community
    def initialize(*args)
      if args.size==1 and args[0].is_a?(String) and args[0].is_packed?
        @raw = args[0].dup
      elsif args.size==1 and args[0].is_a?(String)
        # The String form is the 8 octets as hex, spaces allowed. Ruby's
        # pack('H16') turns anything else into octets of its own choosing
        # rather than complaining, so 'rt=1:1' used to build
        # bdd1a10000000000 and 'zzzz' 3333000000000000: a community the
        # caller did not ask for, with no sign that anything was wrong.
        # There is no 'rt=1:1' notation here, and inventing a community
        # from a string that cannot be one is the silent kind of wrong
        # the conventions single out, so it is refused. Octets of any
        # shape still go through the wire form, Attr::Raw and BGP::Fault.
        hex = args[0].delete(' ')
        unless hex =~ /\A\h{16}\z/
          raise ArgumentError,
            "invalid extended community #{args[0].inspect}, expected 16 hex digits"
        end
        @raw = [hex].pack('H16')
      elsif args.size==1 and args[0].is_a?(Integer)
        @raw = Extended_community.octets(args[0])
      else
        raise ArgumentError, "invalid arg #{args.inspect}"
      end
      @type, @subtype = @raw.unpack('CC')
    end
    def encode
      @raw
    end
    def to_s
      format("Unknown extended community: type 0x%02x, subtype 0x%02x, %s",
             @type, @subtype, @raw.unpack('H*')[0])
    end
    def to_hash
      { :unknown => @raw.unpack('H*')[0] }
    end
  end


  # A community whose 6 value octets have a fixed layout of their own.
  # Subclasses set TYPE and SUBTYPE and write value_octets and
  # parse_value. A community parsed from the wire keeps its 6 octets, so
  # reserved bits come back unchanged; one built from values encodes them
  # as 0, as the RFCs ask.
  class Extended_community::Typed < Extended_community
    def initialize(*args, **opts)
      if args.size == 1 and opts.empty? and args[0].is_a?(String) and args[0].is_packed?
        @type, @subtype = args[0].unpack('CC')
        @raw = args[0].byteslice(2, 6).b
        parse_value(@raw)
      else
        @type, @subtype = self.class::TYPE, self.class::SUBTYPE
        @raw = nil
        build(*args, **opts)
      end
    end
    def encode
      [@type, @subtype].pack('CC') + (@raw || value_octets)
    end
    def name
      self.class::LABEL
    end
    def to_s
      "#{name}: #{value_s}"
    end
    def to_hash
      { hash_key => hash_value }
    end
    def hash_key
      self.class.to_s.split('::').last.downcase.to_sym
    end
    private
    def mac_s(octets)
      octets.unpack('C6').collect { |b| format('%02x', b) }.join(':')
    end
    def mac_octets(mac)
      unless mac.to_s =~ /\A\h\h([:-]?\h\h){5}\z/
        raise ArgumentError, "invalid MAC address #{mac.inspect}"
      end
      [mac.to_s.delete(':-')].pack('H12')
    end
    def check(name, val, max)
      unless val.is_a?(Integer) and val >= 0 and val <= max
        raise ArgumentError, "invalid #{name} #{val.inspect}, expected 0 to #{max}"
      end
      val
    end
  end

  # RFC 9012 section 4.1: Encapsulation, type 0x03, sub-type 0x0c.
  # Value: 4 reserved octets, then a 2-octet Tunnel Type.
  class Encapsulation < Extended_community::Typed
    TYPE, SUBTYPE = OPAQUE, ENCAPSULATION
    LABEL = 'Encapsulation'
    # RFC 9012 tunnel types. Any other number from 0 to 65535 works too.
    TUNNEL_TYPES = { :l2tpv3 => 1, :gre => 2, :vxlan => 8, :nvgre => 9, :mpls_in_gre => 11 }
    attr_reader :tunnel_type
    def tunnel_name
      TUNNEL_TYPES.key(@tunnel_type)
    end
    private
    def build(tunnel_type)
      @tunnel_type = TUNNEL_TYPES[tunnel_type] || check('tunnel type', tunnel_type, 0xffff)
    end
    def value_octets
      [0, @tunnel_type].pack('Nn')
    end
    def parse_value(v)
      @tunnel_type = v.unpack('Nn')[1]
    end
    def value_s
      (tunnel_name || @tunnel_type).to_s
    end
    def hash_value
      tunnel_name || @tunnel_type
    end
  end

  # RFC 8955 sections 7.1 and 7.2: a 2-octet ID (informational), then an
  # IEEE 754 single precision rate, in bytes or in packets per second.
  # A rate of 0 discards the traffic.
  class Traffic_rate_bytes < Extended_community::Typed
    TYPE, SUBTYPE = 0x80, 0x06
    LABEL = 'Traffic rate bytes'
    attr_reader :id, :rate
    private
    def build(id, rate)
      @id = check('ID', id, 0xffff)
      raise ArgumentError, "invalid rate #{rate.inspect}" unless rate.is_a?(Numeric)
      @rate = rate.to_f
    end
    def value_octets
      [@id, @rate].pack('ng')
    end
    def parse_value(v)
      @id, @rate = v.unpack('ng')
    end
    def value_s
      "#{@rate} (ID #{@id})"
    end
    def hash_value
      [@id, @rate]
    end
  end

  class Traffic_rate_packets < Traffic_rate_bytes
    TYPE, SUBTYPE = 0x80, 0x0c
    LABEL = 'Traffic rate packets'
  end

  # RFC 8955 section 7.3: only the two low bits of the last octet are
  # defined: S, sample (0x02), and T, terminal action (0x01).
  class Traffic_action < Extended_community::Typed
    TYPE, SUBTYPE = 0x80, 0x07
    LABEL = 'Traffic action'
    SAMPLE, TERMINAL = 0x02, 0x01
    def sample?
      (@bits & SAMPLE) > 0
    end
    def terminal?
      (@bits & TERMINAL) > 0
    end
    # All 48 bits of the value, reserved ones included.
    attr_reader :bits
    private
    def build(arg = nil, sample: false, terminal: false, bits: nil)
      if arg.is_a?(Hash)
        sample, terminal, bits = arg[:sample], arg[:terminal], arg[:bits]
      elsif arg
        raise ArgumentError, "invalid traffic action #{arg.inspect}, use sample: and terminal:"
      end
      @bits = bits ? check('bits', bits, 0xffffffffffff) : ((sample ? SAMPLE : 0) | (terminal ? TERMINAL : 0))
    end
    def value_octets
      [@bits >> 32, @bits & 0xffffffff].pack('nN')
    end
    def parse_value(v)
      high, low = v.unpack('nN')
      @bits = (high << 32) | low
    end
    def value_s
      s = []
      s << 'sample' if sample?
      s << 'terminal' if terminal?
      s << format('bits 0x%012x', @bits) if (@bits & ~(SAMPLE | TERMINAL)) > 0
      s.empty? ? 'none' : s.join(', ')
    end
    def hash_value
      h = { :sample => sample?, :terminal => terminal? }
      h[:bits] = @bits if (@bits & ~(SAMPLE | TERMINAL)) > 0
      h
    end
  end

  # RFC 8955 section 7.4: redirect to the VRF that imports this route
  # target. Type 0x80 (2-octet AS, 4-octet value), 0x81 (IPv4 address,
  # 2-octet value) or 0x82 (4-octet AS, 2-octet value), sub-type 0x08.
  class Redirect < Extended_community::Typed
    TYPE, SUBTYPE = 0x80, 0x08
    LABEL = 'Redirect'
    attr_reader :global, :local
    private
    def build(global, local)
      if global.is_a?(String)
        @type, @global = 0x81, IPAddr.new(global).to_s
        @local = check('local value', local, 0xffff)
      elsif global.is_a?(Integer) and global > 0xffff
        @type, @global = 0x82, check('AS', global, 0xffffffff)
        @local = check('local value', local, 0xffff)
      else
        @type, @global = 0x80, check('AS', global, 0xffff)
        @local = check('local value', local, 0xffffffff)
      end
    end
    def value_octets
      case @type & ~NON_TRANSITIVE
      when 0x81 ; IPAddr.new(@global).hton + [@local].pack('n')
      when 0x82 ; [@global, @local].pack('Nn')
      else      ; [@global, @local].pack('nN')
      end
    end
    def parse_value(v)
      case @type & ~NON_TRANSITIVE
      when 0x81 ; @global, @local = IPAddr.new_ntoh(v.byteslice(0, 4)).to_s, v.byteslice(4, 2).unpack1('n')
      when 0x82 ; @global, @local = v.unpack('Nn')
      else      ; @global, @local = v.unpack('nN')
      end
    end
    def value_s
      "#{@global}:#{@local}"
    end
    def hash_value
      [@global, @local]
    end
  end

  # RFC 8955 section 7.5: the 6 low bits of the last octet are the DSCP.
  class Traffic_marking < Extended_community::Typed
    TYPE, SUBTYPE = 0x80, 0x09
    LABEL = 'Traffic marking'
    attr_reader :dscp
    private
    def build(dscp)
      @dscp = check('DSCP', dscp, 63)
    end
    def value_octets
      [0, 0, @dscp].pack('NCC')
    end
    def parse_value(v)
      @dscp = v.getbyte(5) & 0x3f
    end
    def value_s
      "DSCP #{@dscp}"
    end
    def hash_value
      @dscp
    end
  end

  # RFC 7432 section 7.7: MAC Mobility. Flags (low bit: sticky), a
  # reserved octet, a 4-octet sequence number.
  class Mac_mobility < Extended_community::Typed
    TYPE, SUBTYPE = 0x06, 0x00
    LABEL = 'MAC Mobility'
    attr_reader :sequence
    def sticky?
      @sticky
    end
    private
    def build(sequence, sticky: false)
      @sequence, @sticky = check('sequence number', sequence, 0xffffffff), sticky ? true : false
    end
    def value_octets
      [@sticky ? 1 : 0, 0, @sequence].pack('CCN')
    end
    def parse_value(v)
      flags, _, @sequence = v.unpack('CCN')
      @sticky = (flags & 1) > 0
    end
    def value_s
      "sequence #{@sequence}" + (@sticky ? ', sticky' : '')
    end
    def hash_value
      [@sequence, @sticky]
    end
  end

  # RFC 7432 section 7.5: ESI Label. Flags (low bit: single-active), two
  # reserved octets, a 3-octet label field. The MPLS label is its high
  # 20 bits.
  class Esi_label < Extended_community::Typed
    TYPE, SUBTYPE = 0x06, 0x01
    LABEL = 'ESI Label'
    attr_reader :label
    def single_active?
      @single_active
    end
    private
    def build(label, single_active: false)
      @label, @single_active = check('MPLS label', label, 0xfffff), single_active ? true : false
    end
    def value_octets
      field = @label << 4
      [@single_active ? 1 : 0, 0, field >> 16, field & 0xffff].pack('CnCn')
    end
    def parse_value(v)
      flags, _, high, low = v.unpack('CnCn')
      @single_active = (flags & 1) > 0
      @label = ((high << 16) | low) >> 4
    end
    def value_s
      "label #{@label}" + (@single_active ? ', single-active' : '')
    end
    def hash_value
      [@label, @single_active]
    end
  end

  # RFC 7432 section 7.6: ES-Import Route Target, a 6-octet MAC address.
  class Es_import < Extended_community::Typed
    TYPE, SUBTYPE = 0x06, 0x02
    LABEL = 'ES-Import'
    attr_reader :mac
    private
    def build(mac)
      @mac = mac_s(mac_octets(mac))
    end
    def value_octets
      mac_octets(@mac)
    end
    def parse_value(v)
      @mac = mac_s(v)
    end
    def value_s
      @mac
    end
    def hash_value
      @mac
    end
  end

  # RFC 9135 section 8.1: the PE's MAC address.
  class Router_mac < Es_import
    TYPE, SUBTYPE = 0x06, 0x03
    LABEL = "Router's MAC"
  end

  class Extended_community
    # RFC 4360 section 2 and the IANA "BGP Extended Communities" registry.
    # Key: [type with the transitive bit masked, subtype].
    FACTORY = {
      [TWO_OCTET_AS,  ROUTE_TARGET]     => Route_target,       # RFC 4360 section 4
      [IPV4_ADDR,     ROUTE_TARGET]     => Route_target,
      [FOUR_OCTET_AS, ROUTE_TARGET]     => Route_target,       # RFC 5668 section 2
      [TWO_OCTET_AS,  ROUTE_ORIGIN]     => Route_origin,       # RFC 4360 section 5
      [IPV4_ADDR,     ROUTE_ORIGIN]     => Route_origin,
      [FOUR_OCTET_AS, ROUTE_ORIGIN]     => Route_origin,       # RFC 5668 section 2
      [TWO_OCTET_AS,  LINK_BANDWIDTH]   => Link_bandwidth,
      [TWO_OCTET_AS,  OSPF_DOMAIN_ID]   => Ospf_domain_id,     # RFC 4577 section 4
      [IPV4_ADDR,     OSPF_DOMAIN_ID]   => Ospf_domain_id,
      [IPV4_ADDR,     OSPF_ROUTER_ID]   => Ospf_router_id,
      [TWO_OCTET_AS,  BGP_DATA_COLLECT] => Bgp_data_collect,   # RFC 4384
      [OPAQUE,        COLOR]            => Color,              # RFC 9012 section 4.3
      [OPAQUE,        BGP_ORIGIN_VALIDATION_STATE] => Origin_validation_state, # RFC 8097
      [OPAQUE,        ENCAPSULATION]    => Encapsulation,      # RFC 9012 section 4.1
      [0x80, 0x06] => Traffic_rate_bytes,    # RFC 8955 section 7.1
      [0x80, 0x0c] => Traffic_rate_packets,  # RFC 8955 section 7.2
      [0x80, 0x07] => Traffic_action,        # RFC 8955 section 7.3
      [0x80, 0x08] => Redirect,              # RFC 8955 section 7.4
      [0x81, 0x08] => Redirect,
      [0x82, 0x08] => Redirect,
      [0x80, 0x09] => Traffic_marking,       # RFC 8955 section 7.5
      [0x06, 0x00] => Mac_mobility,          # RFC 7432 section 7.7
      [0x06, 0x01] => Esi_label,             # RFC 7432 section 7.5
      [0x06, 0x02] => Es_import,             # RFC 7432 section 7.6
      [0x06, 0x03] => Router_mac,            # RFC 9135 section 8.1
    }.freeze
  end

  
end



__END__


load "../../test/unit/path_attributes/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
