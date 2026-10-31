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
    SOURCE_AS = 9

    BGP_ORIGIN_VALIDATION_STATE = 0
    BGP_DATA_COLLECT = 8
    COLOR = 11
    ENCAPSULATION = 12
    DEFAULT_GATEWAY = 13

    IANA_AUTHORITY_BIT = 0x80
    TRANSITIVE = 0x0    
    NON_TRANSITIVE = 0x40    

    # The hash form key that carries the type octet.
    #
    # RFC 4360 section 2: the type octet says things no value says. Its
    # first two bits are the IANA authority bit and the T bit, which a
    # community keeps whatever its value is, and its low two bits are
    # the structure of the value. A build from field values hard codes
    # the first two and picks the last two from the values, so a
    # community that arrives with others has nowhere to keep them: the
    # hash form carried the values but not the octet, and to_hash is
    # supposed to return a hash that round trips through new.
    #
    # So to_hash carries the octet, under this key, beside the value
    # rather than inside it, and only when a build from the value would
    # give a different one. A community whose value says all there is to
    # say has no such key, so the hash of an ordinary community is the
    # plain one key hash it has always been and the hashes callers write
    # by hand mean what they always meant. That is how Attr::TAIL_KEY
    # carries octets a parser could not interpret, and the reason is the
    # same.
    #
    # Nothing is checked, here or in the writer: the octet a caller
    # gives is the octet that goes on the wire, as everywhere else in
    # the building path.
    TYPE_KEY = :type

    TWO_OCTET_AS = 0
    IPV4_ADDR = 1
    FOUR_OCTET_AS = 2
    OPAQUE = 3
    FLOAT = -1
    
    DEFAULT_OPAQUE_ENCODING = 'H12'

    def encode
      [@type, @subtype, _encoded_value_].pack('CCa6')
    end
    
    # RFC 4360 section 2: an extended community is 8 octets, a 1 octet
    # type, a 1 octet sub-type, then 6 octets of value. Both fields are
    # read where they lie. This used to start with s.slice!(0,2), which
    # handed back the type and the sub-type and left the caller's String
    # 2 octets shorter. The same wire bytes then built a community once
    # and raised TypeError from pack on every build after that, and
    # frozen wire bytes raised FrozenError on the first. Nothing depends
    # on the String being consumed: Extended_communities#parse does its
    # own slicing, over its own copy of the attribute value, and hands
    # each whole 8 octet slice on.
    def parse(s)
      @type, @subtype = s.unpack('CC')
      # byteslice gives nil past the end of a String shorter than the
      # type and sub-type, where slicing left ''. Short octets still
      # parse, as they must: a truncated community is one of the things
      # this library exists to put on the wire.
      v = s.byteslice(2, 6).to_s
      case community_structure
      when TWO_OCTET_AS ; @global, @local = v.unpack('nN')
      when IPV4_ADDR
        @global, @local = v.unpack('Nn')
      when FOUR_OCTET_AS
        # RFC 5668 section 2: 4 octet global admin (AS), 2 octet local admin.
        @global, @local = v.unpack('Nn')
      when OPAQUE
        case self
        when Color
          _,@global = v.unpack('nN')
        when Origin_validation_state
          _,@global = v.unpack('nN')
        else
          # unpack returns an Array. Keep the 12 hex digits themselves, the
          # form _encoded_value_ packs back with 'H12'.
          @global = v.unpack1('H12')
        end
      when FLOAT
        # RFC 10005 section 2, on RFC 4360 section 3.1: the 2 octet global
        # administrator is the advertising speaker's AS, the 4 octet local
        # administrator the bandwidth, in bytes per second. The AS used to
        # be read into nothing and written back as 0, so wire bytes that
        # carried one came back changed.
        @global, @local = v.unpack('ng')
      end
    end
    
    # RFC 4360 section 2: the structure of the community is the low 2 bits
    # of the type octet, and the RFC 10005 link bandwidth is the one
    # exception. community_structure is the single place that works it out,
    # and parse, value, value2 and _encoded_value_ all read it, so the
    # predicates read it too rather than the type octet again. A community
    # answers true to one structure only.
    def is_opaque?
      community_structure == OPAQUE
    end
    
    def is_ipv4_addr?
      community_structure == IPV4_ADDR
    end
    
    def is_two_octet_asn?
      community_structure == TWO_OCTET_AS
    end  
    
    # RFC 10005 section 2, on RFC 4360 section 3.1: the link bandwidth
    # community takes the 2 octet AS specific type, but its local
    # administrator is an IEEE 754 single precision number, not an integer.
    # That is the FLOAT structure, and this is its predicate.
    def is_float?
      community_structure == FLOAT
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
    
    # The type octet. A hash form carries it under TYPE_KEY when the
    # value alone cannot reproduce it, and the writer puts it back after
    # the value has built the community.
    attr_accessor :type

    # The one key hash form, plus the type octet when the value cannot
    # reproduce it (TYPE_KEY). Every community hashes through here,
    # Extended_community::Typed included, so the octet is carried in one
    # place and the same way.
    def to_hash
      h = { hash_key => hash_value }
      h[TYPE_KEY] = @type unless @type == hash_type
      h
    end

    # The type octet a build from the hash value gives back. The default
    # is the octet this community already has, so a class that does not
    # say otherwise never carries one and its hash does not change. A
    # class whose constructor hard codes the octet says so by overriding
    # this.
    def hash_type
      @type
    end

    private

    def hash_key
      self.class.to_s.split('::').last.downcase.to_sym
    end

    def hash_value
      value2
    end

    def value
      case community_structure
      when TWO_OCTET_AS, FOUR_OCTET_AS
        "#{@global}:#{@local}"
      when IPV4_ADDR
        "#{IPAddr.create(@global)}:#{@local}"
      when OPAQUE
        "#{@global}"
      when FLOAT
        # The same AS:value form as TWO_OCTET_AS, which is what this
        # community is, only its local administrator is a float.
        "#{@global}:#{bandwidth}"
      else
        # Not dead code, although it reads that way. community_structure
        # is @type & 3 when @type is an Integer, so the branches above,
        # with the FLOAT remap, cover every Integer type. A type that is
        # not an Integer but answers | and & escapes all of them:
        # Opaque.new takes the type octet it is given, and true | 3 is
        # true. Such a community cannot be encoded at all, so saying so
        # beats an empty value.
        raise RuntimeError, "bogus type: #{@type}"
      end
      
    end

    def value2
      case community_structure
      when FLOAT ; [@global, bandwidth]
      when IPV4_ADDR ;  ["#{IPAddr.create(@global)}",@local]
      else
        [@global, @local]
      end
    end

    # RFC 10005 section 2: the local administrator is an IEEE 754 single
    # precision number, in bytes per second, so what comes back is what
    # the 4 octets hold, not the Integer a caller may have passed. That is
    # the value the hash form carries, so the hash encodes the same octets.
    def bandwidth
      [@local].pack('g').unpack1('g')
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
        # RFC 4360 section 3.1 and RFC 10005 section 2: a 2 octet AS, then
        # the bandwidth as an IEEE 754 single.
        [@global, @local].pack('ng')
      else
        # Reached the same way as the else of value, by a type that is
        # not an Integer. Without it encode would raise TypeError from
        # pack on that same type, saying nothing about where it came
        # from. Every Integer type encodes, bogus ones included.
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
        case derived_structure(@global, @local)
        when IPV4_ADDR
          @type |= IPV4_ADDR
          @global = IPAddr.new(@global).to_i
        when FOUR_OCTET_AS
          # RFC 5668 section 2: an AS above 65535 needs the 4 octet AS
          # specific type octet (0x02, or 0x42 non-transitive), with a
          # 4 octet global admin and a 2 octet local admin.
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
    # RFC 4360 section 2: the low two bits of the type octet are the
    # structure of the value, and a build from field values picks them
    # from the values themselves. An IPv4 address with a 2 octet local
    # administrator gives the IPv4 address specific structure; an AS
    # above 65535 under the route target, route origin or source AS
    # sub-types (RFC 4360 sections 4 and 5, RFC 6514 section 6) gives
    # the 4 octet AS specific one of RFC 5668 section 2; anything else
    # the 2 octet AS specific one.
    #
    # The constructor sets the type octet with this, and hash_type asks
    # it again over the values to_hash carries, so the two cannot drift
    # apart and say different things about the same community.
    def derived_structure(global, local)
      if global.is_a?(String) and local.is_a?(Integer)
        IPV4_ADDR
      elsif [ROUTE_TARGET, ROUTE_ORIGIN, SOURCE_AS].include?(@subtype) and
            global.is_a?(Integer) and global > 0xffff
        FOUR_OCTET_AS
      else
        TWO_OCTET_AS
      end
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
    # RFC 4360 section 4: a route target is transitive, so a build from
    # values passes 0 and leaves the T bit clear, and the structure bits
    # come from the values. A non-transitive route target, and a 4 octet
    # AS specific one (RFC 5668 section 2) whose AS fits in 2 octets,
    # therefore need their type octet carried: nothing in [100, 1] says
    # which of the two AS specific forms it came from.
    def hash_type
      TRANSITIVE | derived_structure(*hash_value)
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
    # RFC 4360 section 5, and the same two cases as the route target.
    def hash_type
      TRANSITIVE | derived_structure(*hash_value)
    end
  end

  # RFC 6514 **section 6**, "Source AS Extended Community". The section
  # number is worth stating, because this file's own notes cited section
  # 4.5 in two places and 4.5 is "Source Active A-D Route": checked
  # against both rfc-editor.org and the datatracker on 2026-10-31.
  #
  # Section 6 gives two fields and nothing else. The Global
  # Administrator "MUST be set to the ASN of the PE" and the Local
  # Administrator "MUST be set to 0", and it calls the community
  # "AS-specific, of an extended type, and transitive across AS
  # boundaries". So it is the RFC 4360 section 3.1 shape with a fixed
  # Local Administrator, which is why this is a sibling of the route
  # target and not a class of its own shape.
  #
  # IANA assigns sub-type 0x09 in the Transitive Two-Octet AS-Specific
  # and Transitive Four-Octet AS-Specific registries and **in neither
  # IPv4-Address-Specific one**, read there on 2026-10-31, so only two
  # of the three structures are registered below. A build with an
  # address still encodes, because building never validates; it reads
  # back as an `Unknown`, since 0x0109 is a code point IANA has not
  # assigned and bgp4r must not name one.
  class Source_as < Extended_community
    def initialize(*args)
      if args[0].is_a?(String) and args[0].is_packed?
        super(*args)
      else
        # One argument is the ASN, with section 6's MUST supplying the 0,
        # which is what every correct sender writes. Two are both fields,
        # the form the hash carries and the one a test wanting a Local
        # Administrator no RFC allows passes.
        args = [args[0], 0] if args.size == 1
        super(*[0, SOURCE_AS, *args].flatten)
      end
    end
    # The same two cases as the route target: a non-transitive one, and a
    # 4 octet AS specific one whose AS fits in 2 octets, need their type
    # octet carried, since nothing in [100, 0] says which form it was.
    def hash_type
      TRANSITIVE | derived_structure(*hash_value)
    end
  end

  # RFC 4577 section 4.2.6: the OSPF domain ID carries the Domain
  # Identifier in the six octet value field, and its type "is 0005, 0105,
  # or 0205". Those three type octets give that field the three
  # structures of RFC 4360 section 3.1, RFC 4360 section 3.2 and RFC 5668
  # section 2: a 2 octet administrator and a 4 octet one, a 4 octet
  # address and a 2 octet one, or a 4 octet AS and a 2 octet one. parse
  # and encode read and write all three off the type octet already, so
  # the two fields are all this class has to carry.
  #
  # A build from field values passes the IPv4 address specific octet,
  # which is the form bgp4r builds and the one every caller here writes:
  # one argument is the domain ID as an address. Two are both fields,
  # the form the hash carries when the value octets hold more.
  class Ospf_domain_id < Extended_community
    def initialize(*args)
      if args[0].is_a?(String) and args[0].is_packed?
        return super(*args)
      end
      # An assignment hands its right hand side over as one Array:
      # ec.ospf_domain_id = '1.1.1.1', 9 arrives as [['1.1.1.1', 9]].
      # Route_target flattens for the same reason.
      args = args.flatten
      if args.size > 2
        raise ArgumentError,
          "invalid OSPF domain ID #{args.inspect}, expected the domain ID, " +
          "or the global and the local administrator"
      end
      # No argument is the all zero value field of RFC 4577 section
      # 4.2.6, the NULL domain, which is what it built before.
      super(IPV4_ADDR, OSPF_DOMAIN_ID, args.fetch(0, 0), args.fetch(1, 0))
    end
    # Both administrator fields, so no octet of the value is lost. The
    # exception is the IPv4 address specific form whose 2 octet local
    # administrator is 0: that is every domain ID bgp4r builds, and its
    # hash stays the plain address it has always been. RFC 4577 does not
    # say those 2 octets are zero, and section 4.2.8.1 reads all six as
    # the identifier, so when they are not 0 they are carried.
    def value2
      global, local = super
      is_ipv4_addr? && local.to_i.zero? ? global : [global, local]
    end
    # Every build from the hash value goes through the IPv4 address
    # specific octet the constructor passes: an address gives that
    # structure again (RFC 4360 section 3.2) and a pair of Integers
    # leaves it alone. So the 0005 and 0205 forms, and a non-transitive
    # one, carry their type octet under TYPE_KEY.
    def hash_type
      IPV4_ADDR
    end
  end

  # RFC 4577 section 4.2.6 gives the OSPF router ID the type 0107 alone,
  # so that is the only one in Extended_community::FACTORY, and the
  # router ID is "the first four bytes of the value field". The class
  # takes whatever octets it is handed, though, so it reads and hashes
  # them the same way the domain ID does.
  class Ospf_router_id < Extended_community
    def initialize(*args)
      if args[0].is_a?(String) and args[0].is_packed?
        return super(*args)
      end
      args = args.flatten
      if args.size > 2
        raise ArgumentError,
          "invalid OSPF router ID #{args.inspect}, expected the router ID, " +
          "or the global and the local administrator"
      end
      super(IPV4_ADDR, OSPF_ROUTER_ID, args.fetch(0, 0), args.fetch(1, 0))
    end
    def value2
      global, local = super
      is_ipv4_addr? && local.to_i.zero? ? global : [global, local]
    end
    def hash_type
      IPV4_ADDR
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
    # RFC 4384: the 2 octet AS specific community, transitive.
    def hash_type
      TRANSITIVE | TWO_OCTET_AS
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
    # RFC 10005 section 2, on RFC 4360 section 3.1: the 2 octet global
    # administrator is the advertising speaker's AS and the 4 octet local
    # administrator is the bandwidth, in bytes per second, not bits. The
    # 4 octet AS encoding is not supported, so a speaker whose AS does not
    # fit two octets sends AS_TRANS. Both are carried, so two
    # arguments are the AS and the bandwidth. One is the bandwidth alone,
    # with the AS left at 0, the form callers and tests already use. Any
    # other count has nowhere to go, so say so with what the caller
    # passed; it used to reach Extended_community#initialize with the
    # wrong number of arguments and report its own list, "invalid arg
    # [64, 4, 100, 1000, 0]" for two and "invalid argument [64, 4, 0]"
    # for none, which named nothing the caller had written.
    def initialize(*args)
      if args[0].is_a?(String) and args[0].is_packed?
        return super(*args)
      end
      # An assignment hands its right hand side over as one Array:
      # ec.link_bandwidth = 100, 1000 arrives as [[100, 1000]].
      # Route_target flattens for the same reason.
      args = args.flatten
      case args.size
      when 1 ; asn, bw = 0, args[0]
      when 2 ; asn, bw = args
      else
        raise ArgumentError,
          "invalid link bandwidth #{args.inspect}, expected one argument, " +
          "the bandwidth, or two, the AS and the bandwidth"
      end
      # RFC 4360 section 3.1 gives the global administrator 2 octets, and
      # pack('n') would quietly send a different AS. A value that cannot
      # be represented at all is the narrow case the conventions in
      # CLAUDE.md allow a constructor to refuse: nothing is taken away
      # from negative testing, since a link bandwidth with any octets in
      # it still comes from wire bytes, Attr::Raw or the BGP::Fault
      # helpers. Refusing a String here also keeps it away from the IPv4
      # address remapping of the parent constructor, which would turn the
      # community into something that is not a link bandwidth at all.
      unless asn.is_a?(Integer) and (0..0xffff).include?(asn)
        raise ArgumentError, "invalid AS #{asn.inspect}, expected 0 to 65535"
      end
      unless bw.is_a?(Numeric)
        raise ArgumentError, "invalid bandwidth #{bw.inspect}, expected a number"
      end
      super(NON_TRANSITIVE | TWO_OCTET_AS, LINK_BANDWIDTH, asn, bw)
    end
    # RFC 10005 section 2, on RFC 4360 section 3.1: the type octet is 0x00
    # transitive or 0x40 non-transitive, and IANA names sub-type 0x04
    # "Link Bandwidth" under both. bgp4r builds the non-transitive one,
    # and the constructor says so for every build from values. The FACTORY
    # masks the transitive bit off its key, so a 0x0004 community that
    # arrives is read as a link bandwidth too.
    def hash_type
      NON_TRANSITIVE | TWO_OCTET_AS
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
    # RFC 9012 section 4.3: the color is a transitive opaque community,
    # and the constructor passes TRANSITIVE for every build from values.
    def hash_type
      TRANSITIVE | OPAQUE
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
    # RFC 8097 section 2: the type octet is 0x43, non-transitive, and
    # the constructor passes NON_TRANSITIVE for every build from values.
    # One that arrives with the T bit clear, type 0x03, has nowhere else
    # to keep it.
    def hash_type
      NON_TRANSITIVE | OPAQUE
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
    # A Typed community hard codes its type octet, so a build from the
    # hash value always gives TYPE and one that arrived with anything
    # else, a cleared or set T bit among them, needs it carried.
    # Redirect picks its own from the value and says so there.
    def hash_type
      self.class::TYPE
    end
    private
    # All 48 bits of the value field, from the octets that arrived when
    # this community was parsed and from the octets a build would write
    # otherwise.
    def value_bits
      high, low = (@raw || value_octets).unpack('nN')
      (high << 32) | low
    end
    # True when the value carries a bit outside the fields this community
    # reads, which on a received community is a reserved bit the peer set.
    # DEFINED_BITS says which bits the class reads, each with its RFC; a
    # class without one reads all 48 and so never has any.
    def undefined_bits?
      mask = self.class.const_defined?(:DEFINED_BITS) ? self.class::DEFINED_BITS : ~0
      (value_bits & ~mask) > 0
    end
    # A hash that gave all 48 bits of the value: keep them as the value
    # octets and read the named fields back out of them, which is what the
    # wire path does. encode prefers these octets over value_octets, so the
    # community comes back byte for byte.
    #
    # The reserved bits are why this exists. encode kept them, because a
    # parsed community keeps its 6 octets, but hash_value carried only the
    # fields its RFC defines, so a build from the hash wrote them as 0 and
    # the hash did not round trip. Four classes did that.
    def keep_bits(bits)
      check('bits', bits, 0xffffffffffff)
      @raw = [bits >> 32, bits & 0xffffffff].pack('nN').b
      parse_value(@raw)
    end
    # `to_hash` nests a community's fields under the community's own key,
    # because that is the form `Extended_communities` reads, so a hash
    # build takes that form as well as the bare fields.
    #
    # **Why the unwrap exists**, which `Traffic_action` found: reading the
    # outer hash finds every field nil and builds a clean looking
    # community of zeros with no error at all, for every class whose
    # field defaults pass their own check. The ones that raise instead
    # are the lucky ones.
    #
    # **Why it has to happen before the shape is dispatched on**: what is
    # under the key is a list for most of these classes and a Hash only
    # when the community also carries reserved bits. `Multicast_flags`
    # unwrapped inside its own Hash branch and then read the list it got
    # back as a Hash, so `Multicast_flags.new(its own to_hash)` raised
    # TypeError. Unwrap, then dispatch.
    def unwrap(arg)
      arg.is_a?(Hash) && arg.key?(hash_key) ? arg[hash_key] : arg
    end
    # to_s names the reserved bits too, so what encode would write is
    # visible rather than only the fields the class reads.
    def with_bits(s)
      undefined_bits? ? s + format(', bits 0x%012x', value_bits) : s
    end
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
    # RFC 9012 section 4.1, Figure 14: Reserved (2 octets), Reserved (2
    # octets), Tunnel Type (2 octets), and "The last two octets of the
    # Value field encode a tunnel type". So the tunnel type is the low 16
    # bits and the 32 above it are the 4 reserved octets. The RFC does not
    # say what they are to be set to, so a build writes 0 and a community
    # that arrived with them set carries them in its hash.
    DEFINED_BITS = 0xffff
    attr_reader :tunnel_type
    def tunnel_name
      TUNNEL_TYPES.key(@tunnel_type)
    end
    private
    # The hash value, which is the tunnel type on its own or a Hash of it
    # and the reserved bits, arrives either as one argument or spelled out
    # as keywords.
    def build(arg = nil, tunnel_type: nil, bits: nil)
      arg, bits = arg[:tunnel_type], arg[:bits] if arg.is_a?(Hash)
      arg = tunnel_type if arg.nil?
      return keep_bits(bits) if bits
      @tunnel_type = TUNNEL_TYPES[arg] || check('tunnel type', arg, 0xffff)
    end
    def value_octets
      [0, @tunnel_type].pack('Nn')
    end
    def parse_value(v)
      @tunnel_type = v.unpack('Nn')[1]
    end
    def value_s
      with_bits((tunnel_name || @tunnel_type).to_s)
    end
    def hash_value
      name = tunnel_name || @tunnel_type
      undefined_bits? ? { :tunnel_type=> name, :bits=> value_bits } : name
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
    # **The T bit reads the opposite way round to its name, so do not
    # infer it.** RFC 8955 section 7.3, verbatim: "T Terminal Action (bit
    # 47): When this bit is set, the traffic filtering engine will
    # evaluate any subsequent Flow Specifications (as defined by the
    # ordering procedure Section 5.1). If not set, the evaluation of the
    # traffic filters stops when this Flow Specification is evaluated."
    #
    # So `terminal: true` means **carry on** to the next rule and
    # `terminal: false` means stop at this one, which is the reverse of
    # what the name suggests. The bit value here is right and nothing
    # needs changing; this is written down because a reader who assumes
    # from the name gets the semantics backwards, and bit 47 of a 48 bit
    # value is the least significant, which is why TERMINAL is 0x01.
    #
    # The two bits section 7.3 defines. The 46 above them are reserved,
    # and this class has always carried them, which is where the other
    # four got the shape.
    DEFINED_BITS = SAMPLE | TERMINAL
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
      # This is the community the unwrap in `Typed#unwrap` was found
      # on: reading only the outer hash found :sample, :terminal and
      # :bits all nil and built a clean looking community encoding
      # 8007000000000000, losing all 48 value bits with no error.
      arg = unwrap(arg)
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
      s << format('bits 0x%012x', @bits) if undefined_bits?
      s.empty? ? 'none' : s.join(', ')
    end
    def hash_value
      h = { :sample => sample?, :terminal => terminal? }
      h[:bits] = @bits if undefined_bits?
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
    # RFC 8955 section 7.4: the type octet follows the shape of the
    # value, the way build picks it, so the value reproduces it.
    def hash_type
      if @global.is_a?(String)
        0x81
      elsif @global.is_a?(Integer) and @global > 0xffff
        0x82
      else
        0x80
      end
    end
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
    # RFC 8955 section 7.5 marks "the corresponding value encoded in the 6
    # least significant bits of the Extended Community value", so the 42
    # bits above the DSCP are the reserved ones. The section says they
    # "MUST be set to 0 on encoding and MUST be ignored during decoding":
    # a build writes 0, and a community that arrived with them set is read
    # for its DSCP and keeps them, rather than losing them in its hash.
    DEFINED_BITS = 0x3f
    attr_reader :dscp
    private
    def build(arg = nil, dscp: nil, bits: nil)
      arg, bits = arg[:dscp], arg[:bits] if arg.is_a?(Hash)
      arg = dscp if arg.nil?
      return keep_bits(bits) if bits
      @dscp = check('DSCP', arg, 63)
    end
    def value_octets
      [0, 0, @dscp].pack('NCC')
    end
    def parse_value(v)
      @dscp = v.getbyte(5) & 0x3f
    end
    def value_s
      with_bits("DSCP #{@dscp}")
    end
    def hash_value
      undefined_bits? ? { :dscp=> @dscp, :bits=> value_bits } : @dscp
    end
  end

  # RFC 7432 section 7.7: MAC Mobility. Flags (low bit: sticky), a
  # reserved octet, a 4-octet sequence number.
  class Mac_mobility < Extended_community::Typed
    TYPE, SUBTYPE = 0x06, 0x00
    LABEL = 'MAC Mobility'
    # RFC 7432 section 7.7: "The low-order bit of the Flags octet is
    # defined as the "Sticky/static" flag", one reserved octet follows it,
    # and the Sequence Number is 4 octets. The sticky bit is bit 40 of the
    # value and the sequence its low 32, so the reserved ones are the 7
    # flag bits above sticky and the whole reserved octet.
    DEFINED_BITS = (1 << 40) | 0xffffffff
    attr_reader :sequence
    def sticky?
      @sticky
    end
    private
    def build(arg = nil, sequence: nil, sticky: false, bits: nil)
      arg, sticky, bits = arg[:sequence], arg[:sticky], arg[:bits] if arg.is_a?(Hash)
      arg = sequence if arg.nil?
      return keep_bits(bits) if bits
      @sequence, @sticky = check('sequence number', arg, 0xffffffff), sticky ? true : false
    end
    def value_octets
      [@sticky ? 1 : 0, 0, @sequence].pack('CCN')
    end
    def parse_value(v)
      flags, _, @sequence = v.unpack('CCN')
      @sticky = (flags & 1) > 0
    end
    def value_s
      with_bits("sequence #{@sequence}" + (@sticky ? ', sticky' : ''))
    end
    def hash_value
      return [@sequence, @sticky] unless undefined_bits?
      { :sequence=> @sequence, :sticky=> @sticky, :bits=> value_bits }
    end
  end

  # RFC 7432 section 7.5: ESI Label. Flags (low bit: single-active), two
  # reserved octets, a 3-octet label field. The MPLS label is its high
  # 20 bits.
  class Esi_label < Extended_community::Typed
    TYPE, SUBTYPE = 0x06, 0x01
    LABEL = 'ESI Label'
    # RFC 7432 section 7.5: "The low-order bit of the Flags octet is
    # defined as the "Single-Active" bit", then two reserved octets, then
    # the 3 octet ESI Label field. The section does not say where the
    # label sits inside that field; bgp4r reads it as the high 20 bits,
    # which is the MPLS label of RFC 5462 section 2, so the low 4 bits go
    # with the two reserved octets and the 7 flag bits above single-active.
    DEFINED_BITS = (1 << 40) | (0xfffff << 4)
    attr_reader :label
    def single_active?
      @single_active
    end
    private
    def build(arg = nil, label: nil, single_active: false, bits: nil)
      arg, single_active, bits = arg[:label], arg[:single_active], arg[:bits] if arg.is_a?(Hash)
      arg = label if arg.nil?
      return keep_bits(bits) if bits
      @label, @single_active = check('MPLS label', arg, 0xfffff), single_active ? true : false
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
      with_bits("label #{@label}" + (@single_active ? ', single-active' : ''))
    end
    def hash_value
      return [@label, @single_active] unless undefined_bits?
      { :label=> @label, :single_active=> @single_active, :bits=> value_bits }
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

  # RFC 9135 section 8.1, "EVPN Router's MAC Extended Community": the PE's
  # MAC address. That is the definition, and IANA gives RFC 9135 as the
  # reference for EVPN sub-type 0x03. RFC 9012 section 4.2 carries the same
  # title but defines nothing; it points here and says this community wins
  # over a MAC in a VXLAN or NVGRE encapsulation sub-TLV.
  class Router_mac < Es_import
    TYPE, SUBTYPE = 0x06, 0x03
    LABEL = "Router's MAC"
  end

  # RFC 9251 section 9.4: the Multicast Flags Extended Community, EVPN
  # sub-type 0x09. A 2-octet Flags field then 4 reserved octets.
  #
  #   | Type=0x06     |Sub-Type=0x09  |     Flags (2 Octets)      |M|I|
  #   |                           Reserved=0                          |
  #
  # **The two defined bits are the least significant of the Flags
  # field**, which the section says rather than leaving to the figure:
  # "Bit 15 (shown as I) defines IGMP Proxy Support" and "Bit 14 (shown
  # as M) defines MLD Proxy Support", numbered "0-15, from high order to
  # low order" by its section 12.3 registry. So I is the low bit of the
  # value's 6th-from-last... in 48-bit terms the Flags field is the top
  # two octets, so I is bit 32 and M is bit 33.
  #
  # "Bits 0 to 13 are reserved for the future. The sender MUST set it to
  # 0, and the receiver MUST ignore it", and the same for the 4 reserved
  # octets, so both come back as a `:bits` entry when a peer set one.
  #
  # Section 9.4 has a receive side rule this does not enforce, per
  # Conventions: "if both M and I flags are 0, the router MUST treat
  # this update as malformed". That belongs in `validation.rb` and is
  # EVPN part 9's work; building one is a negative test and must stay
  # possible, which `Multicast_flags.new` with no argument is.
  class Multicast_flags < Extended_community::Typed
    TYPE, SUBTYPE = 0x06, 0x09
    LABEL = 'Multicast Flags'
    # Bit 15 of the Flags field is bit 32 of the value, bit 14 is 33.
    IGMP_PROXY = 1 << 32
    MLD_PROXY  = 1 << 33
    DEFINED_BITS = IGMP_PROXY | MLD_PROXY
    def igmp_proxy?
      @igmp_proxy
    end
    def mld_proxy?
      @mld_proxy
    end
    private
    def build(arg = nil, igmp_proxy: false, mld_proxy: false, bits: nil)
      arg = unwrap(arg)
      if arg.is_a?(Hash)
        igmp_proxy, mld_proxy, bits =
          arg[:igmp_proxy], arg[:mld_proxy], arg[:bits]
      elsif arg.is_a?(Array)
        igmp_proxy = arg.include?(:igmp_proxy)
        mld_proxy  = arg.include?(:mld_proxy)
      end
      return keep_bits(bits) if bits
      @igmp_proxy, @mld_proxy = igmp_proxy ? true : false, mld_proxy ? true : false
    end
    def value_octets
      flags = (@igmp_proxy ? 1 : 0) | (@mld_proxy ? 2 : 0)
      [flags, 0].pack('nN')
    end
    def parse_value(v)
      flags, _ = v.unpack('nN')
      @igmp_proxy = (flags & 1) > 0
      @mld_proxy  = (flags & 2) > 0
    end
    def value_s
      names = []
      names << 'IGMP proxy' if @igmp_proxy
      names << 'MLD proxy' if @mld_proxy
      with_bits(names.empty? ? 'none' : names.join(', '))
    end
    def hash_value
      h = []
      h << :igmp_proxy if @igmp_proxy
      h << :mld_proxy if @mld_proxy
      return h unless undefined_bits?
      { :igmp_proxy => @igmp_proxy, :mld_proxy => @mld_proxy,
        :bits => value_bits }
    end
  end

  # RFC 9251 section 9.5: the EVI-RT Extended Communities, EVPN sub-types
  # 0x0A to 0x0D, which identify the EVI a route applies to "but do not
  # have any effect on the distribution of the route". Route types 7 and
  # 8 each "MUST carry exactly one EVI-RT EC".
  #
  #   | Type=0x06     |  Sub-Type=n   |       RT associated with EVI  |
  #   |             RT associated with the EVI  (cont.)               |
  #
  # **The value is copied from a Route Target and the sub-type says
  # which kind**, which is the whole design: section 9.5 says the value
  # field "is identical to the value field of RT1", and picks the
  # sub-type from RT1's own structure. So the six octets split the way
  # that structure splits them, 2 plus 4 for a Two-Octet AS-specific RT
  # and 4 plus 2 for the other two.
  #
  # Section 9.5 adds that "an EVI-RT EC is not a Route Target extended
  # community, is not visible to the RT Constrain mechanism [RFC4684],
  # and is not intended to influence the propagation of routes by BGP",
  # which is why these are their own classes and not `Route_target`
  # under another sub-type.
  #
  # Nothing validates. Section 9.5's "MUST carry exactly one" and its
  # treat-as-withdraw for none or several is a receive side rule for
  # `validation.rb`, EVPN part 9's work.
  class Evi_rt < Extended_community::Typed
    TYPE = 0x06
    # How the six octets split: the Global Administrator's width, with
    # the Local Administrator taking the rest. nil where the structure
    # does not fit, which is Type 3 alone.
    GLOBAL_WIDTH = 2
    # True where the Global Administrator is an IPv4 address rather than
    # an AS number.
    GLOBAL_IS_ADDR = false
    attr_reader :global, :local
    private
    def build(global = nil, local = nil, value: nil, bits: nil)
      global = unwrap(global)
      if global.is_a?(Hash)
        global, local, value = global[:global], global[:local], global[:value]
      elsif global.is_a?(Array)
        global, local = global
      end
      return keep_bits(bits) if bits
      return set_value(value) unless value.nil?
      return set_value(global) if local.nil? and global.is_a?(String) and
                                  !self.class::GLOBAL_IS_ADDR
      raise ArgumentError, "#{self.class::LABEL} has no field layout, " \
                           'build it from its six value octets' if width.nil?
      @global, @local = global, local.to_i
      check('local administrator', @local, local_max)
      check_global
    end
    def width
      self.class::GLOBAL_WIDTH
    end
    def local_max
      (1 << ((6 - width) * 8)) - 1
    end
    def check_global
      if self.class::GLOBAL_IS_ADDR
        @global = IPAddr.new(@global.to_s).to_s
      else
        check('global administrator', @global.to_i, (1 << (width * 8)) - 1)
        @global = @global.to_i
      end
    end
    # The six octets as they are, for a layout this class cannot split.
    def set_value(hex)
      h = hex.to_s.delete(':. ')
      unless h =~ /\A\h{12}\z/
        raise ArgumentError, "invalid value #{hex.inspect}, expected 12 hex digits"
      end
      @raw = [h].pack('H*').b
      parse_value(@raw)
    end
    def value_octets
      return @raw if width.nil?
      g = self.class::GLOBAL_IS_ADDR ? IPAddr.new(@global).hton :
          [@global].pack(width == 2 ? 'n' : 'N')
      g + [@local].pack(width == 2 ? 'N' : 'n')
    end
    def parse_value(v)
      if width.nil?
        @global, @local = nil, nil
        return
      end
      @global = self.class::GLOBAL_IS_ADDR ?
                IPAddr.new_ntoh(v.byteslice(0, 4)).to_s :
                v.byteslice(0, width).unpack1(width == 2 ? 'n' : 'N')
      @local = v.byteslice(width, 6 - width).unpack1(width == 2 ? 'N' : 'n')
    end
    def value_s
      return (@raw || value_octets).unpack1('H*') if width.nil?
      "#{@global}:#{@local}"
    end
    def hash_value
      return { :value => (@raw || value_octets).unpack1('H*') } if width.nil?
      [@global, @local]
    end
  end

  # Type 0, sub-type 0x0A: section 9.5 says its value comes from "a
  # Transitive Two-Octet AS-specific EC", whose value field is a 2-octet
  # Global Administrator and a 4-octet Local Administrator (RFC 4360
  # section 3.1).
  class Evi_rt_0 < Evi_rt
    SUBTYPE = 0x0a
    LABEL = 'EVI-RT Type 0'
    GLOBAL_WIDTH = 2
  end

  # Type 1, sub-type 0x0B: from "a Transitive IPv4-Address-specific EC",
  # whose value field is a 4-octet address and a 2-octet Local
  # Administrator (RFC 4360 section 3.2).
  class Evi_rt_1 < Evi_rt
    SUBTYPE = 0x0b
    LABEL = 'EVI-RT Type 1'
    GLOBAL_WIDTH = 4
    GLOBAL_IS_ADDR = true
  end

  # Type 2, sub-type 0x0C: from "a Transitive Four-Octet AS-specific
  # EC", whose value field is a 4-octet AS and a 2-octet Local
  # Administrator (RFC 5668 section 2).
  class Evi_rt_2 < Evi_rt
    SUBTYPE = 0x0c
    LABEL = 'EVI-RT Type 2'
    GLOBAL_WIDTH = 4
  end

  # Type 3, sub-type 0x0D, and **the one RFC 9251 contradicts itself
  # about**. Section 9.5 says its value field "is identical to the value
  # field of RT1" where RT1 is "a Transitive IPv6-Address-specific EC",
  # and RFC 5701 section 2 makes that community 20 octets with an
  # **18-octet** value field: 16 for the address and 2 for the Local
  # Administrator. An EVPN extended community has 6.
  #
  # The figure in that same section shows the 8-octet form, and section
  # 12.1 registers 0x0D in the "EVPN Extended Community Sub-Types"
  # subregistry, which is the 8-octet family. **bgp4r follows the figure
  # and the registry**, because that is where the code point lives: a
  # 20-octet community would need one in the IPv6-address-specific
  # registry, and IANA lists none. Checked on 2026-10-30: the IANA
  # registry gives 0x0D as "EVI-RT Type 3", reference RFC 9251, and
  # there is no erratum on RFC 9251 about it.
  #
  # So this class carries the six octets and does not split them, since
  # the layout it is told to copy does not fit in them. `new` takes 12
  # hex digits. If the 18-octet reading is ever settled as the right
  # one, this is the class to change and the hash key `:value` is what
  # would move.
  class Evi_rt_3 < Evi_rt
    SUBTYPE = 0x0d
    LABEL = 'EVI-RT Type 3'
    GLOBAL_WIDTH = nil
  end

  # RFC 8214 section 3.1: the EVPN Layer 2 Attributes Extended Community,
  # EVPN sub-type 0x04, "to be included with per-EVI Ethernet A-D routes"
  # and "mandatory if multihoming is enabled".
  #
  #   |  Type (0x06) / Sub-type (0x04) (2 octets) |
  #   |  Control Flags  (2 octets)                |
  #   |  L2 MTU (2 octets)                        |
  #   |  Reserved (2 octets)                      |
  #
  # **The three defined flags are the least significant of the Control
  # Flags field**, which its Figure 2 shows rather than says:
  # `|   MBZ                   |C|P|B|`, MBZ being "MUST Be Zero". So B
  # is the low bit of that 2-octet field, P the one above it and C the
  # one above that, which in the 48-bit value puts B at bit 32, P at 33
  # and C at 34.
  #
  # Section 3.1: "the remaining bits MUST be set to zero when sending and
  # MUST be ignored when receiving this community". Those 13 bits and the
  # 2 reserved octets come back as a `:bits` entry when a peer set one.
  class Layer2_attributes < Extended_community::Typed
    TYPE, SUBTYPE = 0x06, 0x04
    LABEL = 'Layer 2 Attributes'
    # The Control Flags field is the value's top two octets, so its own
    # low bit is bit 32 of the value.
    BACKUP       = 1 << 32
    PRIMARY      = 1 << 33
    CONTROL_WORD = 1 << 34
    # The flag names, in the order Figure 2 draws them.
    FLAGS = { :control_word=> CONTROL_WORD, :primary=> PRIMARY, :backup=> BACKUP }.freeze
    # The three flags and the whole L2 MTU, which is the value's middle
    # two octets. Everything else is MBZ or reserved.
    DEFINED_BITS = CONTROL_WORD | PRIMARY | BACKUP | (0xffff << 16)
    attr_reader :mtu
    def control_word?
      @control_word
    end
    def primary?
      @primary
    end
    def backup?
      @backup
    end
    private
    # Four ways to say it: `new(1500, primary: true)`, the hash value
    # `new([1500, [:primary]])`, the wrapped hash `to_hash` answers, and
    # the Hash of named fields a community with reserved bits hashes as.
    def build(arg = nil, mtu: nil, control_word: false, primary: false,
              backup: false, bits: nil)
      arg = unwrap(arg)
      if arg.is_a?(Hash)
        mtu, bits = arg[:mtu], arg[:bits]
        control_word, primary, backup =
          arg[:control_word], arg[:primary], arg[:backup]
      elsif arg.is_a?(Array)
        mtu, names = arg[0], arg[1] || []
        control_word, primary, backup =
          names.include?(:control_word), names.include?(:primary),
          names.include?(:backup)
      elsif !arg.nil?
        mtu = arg
      end
      return keep_bits(bits) if bits
      @mtu = check('L2 MTU', mtu.to_i, 0xffff)
      @control_word, @primary, @backup =
        control_word ? true : false, primary ? true : false, backup ? true : false
    end
    def value_octets
      flags = (@control_word ? 4 : 0) | (@primary ? 2 : 0) | (@backup ? 1 : 0)
      [flags, @mtu, 0].pack('nnn')
    end
    def parse_value(v)
      flags, @mtu, _ = v.unpack('nnn')
      @control_word = (flags & 4) > 0
      @primary      = (flags & 2) > 0
      @backup       = (flags & 1) > 0
    end
    def flag_names
      FLAGS.keys.select { |n| send("#{n}?") }
    end
    def value_s
      names = flag_names
      with_bits("MTU #{@mtu}" + (names.empty? ? '' : ', ' + names.join(', ')))
    end
    def hash_value
      return [@mtu, flag_names] unless undefined_bits?
      { :mtu=> @mtu, :control_word=> @control_word, :primary=> @primary,
        :backup=> @backup, :bits=> value_bits }
    end
  end

  # RFC 8317 section 6.1: the E-Tree Extended Community, EVPN sub-type
  # 0x05, "used for Leaf-Indication of known unicast and BUM traffic".
  #
  #   | Type=0x06     | Sub-Type=0x05 | Flags(1 Octet)|  Reserved=0   |
  #   |  Reserved=0   |           Leaf Label                          |
  #
  # The same layout as `Esi_label`: a Flags octet with one low bit, two
  # reserved octets, then a 3-octet label field. Flags is
  # `|     MBZ     |L|`, so Leaf-Indication is bit 40 of the value.
  #
  # Unlike `Esi_label`, this section does say where the label sits:
  # "The value of the 20-bit MPLS label is encoded in the high-order 20
  # bits of the Leaf label field". So the low 4 bits of that field are
  # undescribed and go with the reserved octets and the 7 MBZ bits.
  #
  # Nothing validates. Section 6.1 has two send side rules this does not
  # enforce, per Conventions, because a test has to be able to break
  # them: with a MAC/IP Advertisement route the flag "MUST be set to one"
  # and the label SHOULD be 0, and with an EAD-ES route the label "MUST
  # be set to a valid MPLS label" and the flag SHOULD be 0. Which route
  # a community travels with is not visible from the community.
  class E_tree < Extended_community::Typed
    TYPE, SUBTYPE = 0x06, 0x05
    LABEL = 'E-Tree'
    LEAF = 1 << 40
    DEFINED_BITS = LEAF | (0xfffff << 4)
    attr_reader :label
    def leaf?
      @leaf
    end
    private
    def build(arg = nil, label: nil, leaf: false, bits: nil)
      arg = unwrap(arg)
      if arg.is_a?(Hash)
        arg, leaf, bits = arg[:label], arg[:leaf], arg[:bits]
      elsif arg.is_a?(Array)
        arg, leaf = arg[0], arg[1]
      end
      arg = label if arg.nil?
      return keep_bits(bits) if bits
      @label, @leaf = check('leaf label', arg.to_i, 0xfffff), leaf ? true : false
    end
    def value_octets
      field = @label << 4
      [@leaf ? 1 : 0, 0, field >> 16, field & 0xffff].pack('CnCn')
    end
    def parse_value(v)
      flags, _, high, low = v.unpack('CnCn')
      @leaf  = (flags & 1) > 0
      @label = ((high << 16) | low) >> 4
    end
    def value_s
      with_bits("leaf label #{@label}" + (@leaf ? ', leaf' : ''))
    end
    def hash_value
      return [@label, @leaf] unless undefined_bits?
      { :label=> @label, :leaf=> @leaf, :bits=> value_bits }
    end
  end

  # RFC 8584 section 2.2: the DF Election Extended Community, EVPN
  # sub-type 0x06, by which "A PE can indicate its willingness to
  # support HRW and/or AC-DF". RFC 8584 gave it 3 reserved octets after
  # the Bitmap; **RFC 9785 section 3 takes the last two of them** and is
  # the layout written here:
  #
  #   | Type=0x06     | Sub-Type(0x06)| RSV |  DF Alg |    Bitmap     ~
  #   ~     Bitmap    |   Reserved    |   DF Preference (2 octets)    |
  #
  # So DF Alg is the low 5 bits of the value's first octet, the Bitmap is
  # its next two, one reserved octet follows and the DF Preference is the
  # last two. The RSV bits above DF Alg are "Reserved bits for
  # information that is specific to DF Alg".
  #
  # **Three RFCs define bits in that Bitmap and all three are read
  # here.** RFC 8584's own registry gives bit 1, AC-DF, and leaves bits 0
  # and 2 to 15 unassigned; RFC 9722 section 2.1 adds bit 3, Time
  # Synchronization; RFC 9785 section 3 adds bit 0, the D or "Don't
  # Preempt" bit. A mask covering only the first would report either of
  # the others as a reserved bit, which is what #190 shipped and this
  # fixed: **a bit one RFC leaves unassigned is a bit a later RFC can
  # fill**, so go by the registry and not by the defining RFC alone.
  # Each RFC numbers the Bitmap's bits from its high order end and states
  # where each lands in the whole community, which is the cross-check all
  # three were placed by: bit 0 is "Bit 24" of the community, bit 1 is
  # "Bit 25" and bit 3 is "Bit 27", and the community's third octet is
  # where its value begins.
  #
  # **The DF Preference is read whatever the algorithm, and named as a
  # preference only for the two it belongs to.** RFC 9785 section 3 gives
  # it a meaning under Highest-Preference and Lowest-Preference, where
  # "the default value MUST be 32767", and for any other algorithm says
  # only that "these 2 octets can be encoded differently". So the octets
  # are always read, so they always round trip, and `to_s` prints them as
  # a preference only where the RFC says they are one.
  class Df_election < Extended_community::Typed
    TYPE, SUBTYPE = 0x06, 0x06
    LABEL = 'DF Election'
    # The Bitmap is the value's second and third octets, numbered from
    # its high order end, so its bit n is bit 39 - n of the value, and
    # BITMAP_SHIFT is what turns one of these into the 16-bit field.
    BITMAP_SHIFT = 24
    DONT_PREEMPT = 1 << 39  # RFC 9785 section 3, Bitmap bit 0
    AC_DF        = 1 << 38  # RFC 8584 section 2.2, Bitmap bit 1
    TIME_SYNC    = 1 << 36  # RFC 9722 section 2.1, Bitmap bit 3
    # In Bitmap bit order, which is the order to_s lists them in.
    CAPABILITIES = { :dont_preempt=> DONT_PREEMPT, :ac_df=> AC_DF,
                     :time_sync=> TIME_SYNC }.freeze
    # The "DF Alg" registry RFC 8584 section 2.2 created. Type 0 is the
    # "Default DF election algorithm, or modulus-based algorithm as
    # defined in [RFC7432]" and 31 is "Reserved for Experimental Use";
    # **RFC 9785 section 6 allocated 2 and 3**, leaving 4 to 30
    # unassigned. Any number from 0 to 31 encodes.
    ALGORITHMS = { :default=> 0, :hrw=> 1, :highest_preference=> 2,
                   :lowest_preference=> 3, :experimental=> 31 }.freeze
    # The two the DF Preference field belongs to, RFC 9785 section 3:
    # "The Designated Forwarder Preference field is specific to Highest-
    # Preference and Lowest-Preference Algorithms, and this document does
    # not define any meaning for other algorithms."
    PREFERENCE_ALGORITHMS = [ALGORITHMS[:highest_preference],
                             ALGORITHMS[:lowest_preference]].freeze
    # "The allowed values are within the range 0-65535, and the default
    # value MUST be 32767. This value is the midpoint in the allowed
    # Preference range of values".
    DEFAULT_PREFERENCE = 32767
    DEFINED_BITS = (0x1f << 40) | DONT_PREEMPT | AC_DF | TIME_SYNC | 0xffff
    attr_reader :df_alg, :df_pref
    def alg_name
      ALGORITHMS.key(@df_alg)
    end
    # Whether the last two octets are a DF Preference at all.
    def preference_alg?
      PREFERENCE_ALGORITHMS.include?(@df_alg)
    end
    def dont_preempt?
      @dont_preempt
    end
    def ac_df?
      @ac_df
    end
    def time_sync?
      @time_sync
    end
    private
    def build(arg = nil, df_alg: nil, dont_preempt: false, ac_df: false,
              time_sync: false, df_pref: nil, bits: nil)
      arg = unwrap(arg)
      if arg.is_a?(Hash)
        arg, dont_preempt, ac_df, time_sync, df_pref, bits =
          arg[:df_alg], arg[:dont_preempt], arg[:ac_df], arg[:time_sync],
          arg[:df_pref], arg[:bits]
      elsif arg.is_a?(Array)
        names, df_pref, arg = arg[1] || [], arg[2], arg[0]
        dont_preempt = names.include?(:dont_preempt)
        ac_df, time_sync = names.include?(:ac_df), names.include?(:time_sync)
      end
      arg = df_alg if arg.nil?
      return keep_bits(bits) if bits
      @df_alg = ALGORITHMS[arg] || check('DF algorithm', arg.to_i, 0x1f)
      @dont_preempt = dont_preempt ? true : false
      @ac_df, @time_sync = ac_df ? true : false, time_sync ? true : false
      # Section 3's default is the preference algorithms' own. Under any
      # other algorithm these octets are RFC 8584's reserved ones, so
      # they default to 0, and a value given explicitly always wins.
      df_pref ||= preference_alg? ? DEFAULT_PREFERENCE : 0
      @df_pref = check('DF preference', df_pref.to_i, 0xffff)
    end
    def value_octets
      bitmap = CAPABILITIES.inject(0) do |m, (name, bit)|
        m | (send("#{name}?") ? bit >> BITMAP_SHIFT : 0)
      end
      [@df_alg, bitmap, 0, @df_pref].pack('CnCn')
    end
    def parse_value(v)
      alg, bitmap, _, pref = v.unpack('CnCn')
      @df_alg, @df_pref = alg & 0x1f, pref
      CAPABILITIES.each do |name, bit|
        instance_variable_set("@#{name}",
                              (bitmap & (bit >> BITMAP_SHIFT)) > 0)
      end
    end
    def capability_names
      CAPABILITIES.keys.select { |n| send("#{n}?") }
    end
    def value_s
      names = capability_names
      s = "alg #{alg_name || @df_alg}"
      s += ', ' + names.join(', ') unless names.empty?
      if preference_alg?
        s += ", pref #{@df_pref}"
      elsif @df_pref.to_i > 0
        # Not a preference under this algorithm, so do not call it one.
        s += format(', last octets 0x%04x', @df_pref)
      end
      with_bits(s)
    end
    def hash_value
      alg = alg_name || @df_alg
      unless undefined_bits?
        h = [alg, capability_names]
        # The preference rides along where it is a field, and otherwise
        # only when a peer put something in those octets, so an ordinary
        # DF Election community hashes as the pair it always did.
        h << @df_pref if preference_alg? || @df_pref.to_i > 0
        return h
      end
      { :df_alg=> alg, :dont_preempt=> @dont_preempt, :ac_df=> @ac_df,
        :time_sync=> @time_sync, :df_pref=> @df_pref, :bits=> value_bits }
    end
  end

  # RFC 9047 section 2: the EVPN ARP/ND Extended Community, EVPN sub-type
  # 0x08, "advertised along with EVPN MAC/IP Advertisement routes that
  # carry an IPv4 or IPv6 address".
  #
  #   | Type=0x06     | Sub-Type=0x08 |Flags (1 octet)| Reserved=0    |
  #   |                       Reserved=0                              |
  #
  # Flags is `|       |I| |O|R|`, and the section names each bit twice
  # over, once in the Flags octet and once in the whole community, which
  # is the cross-check all three were placed by: R is "Bit 7 of the Flags
  # field" and "Bit 23 of the Extended Community", O is bit 6 and bit 22,
  # I is bit 4 and bit 20. The community's third octet is where its value
  # begins, so those are bits 40, 41 and 43 of the value.
  #
  # "Bits 0-3 and 5 are not assigned by this document. They MUST be set
  # to zero and ignored on receipt", and the 5 reserved octets likewise,
  # so both come back as a `:bits` entry when a peer set one.
  class Arp_nd < Extended_community::Typed
    TYPE, SUBTYPE = 0x06, 0x08
    LABEL = 'ARP/ND'
    ROUTER    = 1 << 40  # R, Flags bit 7
    OVERRIDE  = 1 << 41  # O, Flags bit 6
    IMMUTABLE = 1 << 43  # I, Flags bit 4
    FLAGS = { :immutable=> IMMUTABLE, :override=> OVERRIDE, :router=> ROUTER }.freeze
    DEFINED_BITS = IMMUTABLE | OVERRIDE | ROUTER
    def router?
      @router
    end
    def override?
      @override
    end
    def immutable?
      @immutable
    end
    private
    def build(arg = nil, router: false, override: false, immutable: false, bits: nil)
      arg = unwrap(arg)
      if arg.is_a?(Hash)
        router, override, immutable, bits =
          arg[:router], arg[:override], arg[:immutable], arg[:bits]
      elsif arg.is_a?(Array)
        router    = arg.include?(:router)
        override  = arg.include?(:override)
        immutable = arg.include?(:immutable)
      end
      return keep_bits(bits) if bits
      @router, @override, @immutable =
        router ? true : false, override ? true : false, immutable ? true : false
    end
    def value_octets
      flags = (@immutable ? 8 : 0) | (@override ? 2 : 0) | (@router ? 1 : 0)
      # One Flags octet then 5 reserved: 1 + 4 + 1, not the 1 + 4 + 2 that
      # a CNn would write, which is 7 and made this community 9 octets.
      [flags, 0, 0].pack('CNC')
    end
    def parse_value(v)
      flags, _, _ = v.unpack('CNC')
      @immutable = (flags & 8) > 0
      @override  = (flags & 2) > 0
      @router    = (flags & 1) > 0
    end
    def flag_names
      FLAGS.keys.select { |n| send("#{n}?") }
    end
    def value_s
      names = flag_names
      with_bits(names.empty? ? 'none' : names.join(', '))
    end
    def hash_value
      return flag_names unless undefined_bits?
      { :router=> @router, :override=> @override, :immutable=> @immutable,
        :bits=> value_bits }
    end
  end

  # RFC 9722 section 2.1: the Service Carving Time, EVPN sub-type 0x0F,
  # which communicates "the SCT for each Ethernet Segment".
  #
  #   | Type = 0x06   | Sub-Type(0x0F)|      Timestamp Seconds        ~
  #   ~  Timestamp Seconds            |      Timestamp Fraction       |
  #
  # **The one EVPN community with no reserved bit anywhere**, so it has
  # no `DEFINED_BITS` and never grows a `:bits` entry: all 48 value bits
  # are fields it reads.
  #
  # The timestamp "uses the NTP prime epoch of 0 h 1 January 1900 UTC
  # [RFC5905] and an adapted form of the 64-bit NTP timestamp format":
  # 32 bits of seconds, then "The high-order 16 bits of the NTP
  # 'Fraction' field", whose low 16 "are set to 0" when the 64-bit form
  # is rebuilt. That makes each tick 2^-16 of a second.
  #
  # **No calendar date is printed, deliberately.** Section 2.2 says "The
  # NTP Era value is not exchanged", so the era is not in the community
  # and any date bgp4r named would be a guess about which 136 year window
  # the seconds count belongs to.
  class Service_carving_time < Extended_community::Typed
    TYPE, SUBTYPE = 0x06, 0x0f
    LABEL = 'Service Carving Time'
    attr_reader :seconds, :fraction
    private
    def build(arg = nil, fraction = nil, seconds: nil, bits: nil)
      arg = unwrap(arg)
      if arg.is_a?(Hash)
        arg, fraction, bits = arg[:seconds], arg[:fraction], arg[:bits]
      elsif arg.is_a?(Array)
        arg, fraction = arg[0], arg[1]
      end
      arg = seconds if arg.nil?
      return keep_bits(bits) if bits
      @seconds  = check('timestamp seconds', arg.to_i, 0xffffffff)
      @fraction = check('timestamp fraction', fraction.to_i, 0xffff)
    end
    def value_octets
      [@seconds, @fraction].pack('Nn')
    end
    def parse_value(v)
      @seconds, @fraction = v.unpack('Nn')
    end
    # Both fields as they are, and the fraction also as the seconds it
    # stands for, since 0x8000 is half a second and not 32768 of
    # anything. One tick is 2^-16 s, so six decimals is more than enough.
    def value_s
      format('seconds %d, fraction %d (%.6fs)', @seconds, @fraction,
             @fraction.to_f / 0x10000)
    end
    def hash_value
      [@seconds, @fraction]
    end
  end

  # RFC 7432 section 7.8: the Default Gateway Extended Community, "an
  # Extended Community of an Opaque Type", type 0x03 sub-type 0x0D.
  #
  # **The community with no fields at all**, which is why it is the one
  # of the eleven that is not an EVPN 0x06 sub-type and is invisible to
  # anyone counting that registry: "The Value field of this community is
  # reserved (set to 0 by the senders, ignored by the receivers)."
  #
  # So all 48 bits are reserved, `DEFINED_BITS` is 0, and the hash is an
  # empty list until a peer sets something in there, at which point it is
  # a `:bits` entry like any other reserved field. A build writes zeros,
  # which is what the section asks a sender for.
  class Default_gateway < Extended_community::Typed
    TYPE, SUBTYPE = OPAQUE, DEFAULT_GATEWAY
    LABEL = 'Default Gateway'
    DEFINED_BITS = 0
    private
    def build(arg = nil, bits: nil)
      arg = unwrap(arg)
      bits = arg[:bits] if arg.is_a?(Hash)
      keep_bits(bits) if bits
    end
    def value_octets
      [0, 0].pack('Nn')
    end
    def parse_value(v)
      v
    end
    def value_s
      with_bits('reserved')
    end
    def hash_value
      undefined_bits? ? { :bits=> value_bits } : []
    end
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
      # RFC 6514 section 6. IANA assigns 0x09 in the two transitive AS
      # specific registries only, so there is no IPV4_ADDR row here.
      [TWO_OCTET_AS,  SOURCE_AS]        => Source_as,
      [FOUR_OCTET_AS, SOURCE_AS]        => Source_as,
      [TWO_OCTET_AS,  LINK_BANDWIDTH]   => Link_bandwidth,    # RFC 10005 section 2
      # RFC 4577 section 4.2.6: the OSPF domain ID's type "is 0005, 0105,
      # or 0205", so all three are here. 0205 is the 4 octet AS specific
      # structure of RFC 5668 section 2, which parse and encode already
      # read and write; without it a PE that sent one got a community
      # with its octets but no name.
      [TWO_OCTET_AS,  OSPF_DOMAIN_ID]   => Ospf_domain_id,     # RFC 4577 section 4.2.6
      [IPV4_ADDR,     OSPF_DOMAIN_ID]   => Ospf_domain_id,
      [FOUR_OCTET_AS, OSPF_DOMAIN_ID]   => Ospf_domain_id,
      # RFC 4577 section 4.2.6 gives the router ID the type 0107 alone.
      [IPV4_ADDR,     OSPF_ROUTER_ID]   => Ospf_router_id,
      [TWO_OCTET_AS,  BGP_DATA_COLLECT] => Bgp_data_collect,   # RFC 4384
      [OPAQUE,        COLOR]            => Color,              # RFC 9012 section 4.3
      [OPAQUE,        BGP_ORIGIN_VALIDATION_STATE] => Origin_validation_state, # RFC 8097
      [OPAQUE,        ENCAPSULATION]    => Encapsulation,      # RFC 9012 section 4.1
      [OPAQUE,        DEFAULT_GATEWAY]  => Default_gateway,    # RFC 7432 section 7.8
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
      [0x06, 0x04] => Layer2_attributes,     # RFC 8214 section 3.1
      [0x06, 0x05] => E_tree,                # RFC 8317 section 6.1
      [0x06, 0x06] => Df_election,           # RFC 8584 section 2.2
      [0x06, 0x08] => Arp_nd,                # RFC 9047 section 2
      [0x06, 0x09] => Multicast_flags,       # RFC 9251 section 9.4
      [0x06, 0x0a] => Evi_rt_0,              # RFC 9251 section 9.5
      [0x06, 0x0b] => Evi_rt_1,
      [0x06, 0x0c] => Evi_rt_2,
      [0x06, 0x0d] => Evi_rt_3,
      [0x06, 0x0f] => Service_carving_time,  # RFC 9722 section 2.1
    }.freeze
  end

  
end



__END__


load "../../test/unit/path_attributes/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
