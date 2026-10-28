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
    # above 65535 under the route target or route origin sub-types
    # (RFC 4360 sections 4 and 5) gives the 4 octet AS specific one of
    # RFC 5668 section 2; anything else the 2 octet AS specific one.
    #
    # The constructor sets the type octet with this, and hash_type asks
    # it again over the values to_hash carries, so the two cannot drift
    # apart and say different things about the same community.
    def derived_structure(global, local)
      if global.is_a?(String) and local.is_a?(Integer)
        IPV4_ADDR
      elsif [ROUTE_TARGET, ROUTE_ORIGIN].include?(@subtype) and
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

  # RFC 9135 section 8.1, "EVPN Router's MAC Extended Community": the PE's
  # MAC address. That is the definition, and IANA gives RFC 9135 as the
  # reference for EVPN sub-type 0x03. RFC 9012 section 4.2 carries the same
  # title but defines nothing; it points here and says this community wins
  # over a MAC in a VXLAN or NVGRE encapsulation sub-TLV.
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
