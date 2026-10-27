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

module BGP
  
  module ATTR
    
    ### http://www.iana.org/assignments/bgp-parameters/bgp-parameters.xhtml#bgp-parameters-2
    
    ORIGIN = 1
    AS_PATH = 2
    NEXT_HOP = 3
    MULTI_EXIT_DISC = 4
    LOCAL_PREF = 5
    ATOMIC_AGGREGATE = 6
    AGGREGATOR = 7
    COMMUNITIES = 8
    ORIGINATOR_ID = 9
    CLUSTER_LIST = 10
    
    MP_REACH = 14
    MP_UNREACH = 15
    EXTENDED_COMMUNITY = 16
    AS4_PATH = 17
    AS4_AGGREGATOR = 18
    
    PMSI_TUNNEL = 22               # RFC 6514 section 5
    TUNNEL_ENCAP = 23              # RFC 9012 section 2
    IPV6_EXTENDED_COMMUNITY = 25   # RFC 5701 section 3
    ACCUMULATED_IGP_METRIC = 26
    LARGE_COMMUNITY = 32           # RFC 8092 section 3
    ONLY_TO_CUSTOMER = 35          # RFC 9234 section 5
    PREFIX_SID = 40                # RFC 8669 section 3

    # RFC 6793 section 9: AS_TRANS stands in for a 4-octet AS number
    # in a 2-octet field.
    AS_TRANS = 23456
    
    SET = 1
    SEQUENCE = 2
    CONFED_SEQUENCE = 3
    CONFED_SET = 4
    
    OPTIONAL = 0x8
    TRANSITIVE = 0x4
    PARTIAL = 0x2
    EXTENDED_LENGTH = 0x1 
    NONE = 0x0
    
    WELL_KNOWN_MANDATORY     = TRANSITIVE
    WELL_KNOWN_DISCRETIONARY = TRANSITIVE
    OPTIONAL_TRANSITIVE      = OPTIONAL | TRANSITIVE
    OPTIONAL_NON_TRANSITIVE  = OPTIONAL
    
    def len_fmt(len)
      if len>255
        @flags |= EXTENDED_LENGTH
        @_len_fmt='n'
      else
        @_len_fmt = 'C'
        @flags &= ~EXTENDED_LENGTH
      end
    end
    
    def encode(value='',value_fmt=nil)
      len = value.size
      value = [*value].pack(value_fmt) if value_fmt
      (encode_header(len) + value).is_packed
    end

    # The flags to write for a value of len octets. Sets the Extended
    # Length bit when the length needs two octets (RFC 4271 section 4.3).
    def header_flags(len)
      len_fmt(len)
      @flags
    end

    # RFC 4271 section 4.3: Attribute Flags, Attribute Type Code, then
    # the Attribute Length, one octet, or two when the Extended Length
    # bit is set.
    #
    # Overrides set with Attr#override are written as they are, never
    # checked: bgp4r must be able to send any header. A length override
    # changes the length field only, the value octets stay the same.
    # With a flags override, its Extended Length bit picks the size of
    # the length field. Without one, the length written picks it.
    def encode_header(len)
      o = (defined?(@_override) && @_override) || {}
      type = o.fetch(:type, @type)
      len  = o.fetch(:length, len)
      flags = o.key?(:flags) ? o[:flags] : header_flags(len)
      len_fmt = (flags & EXTENDED_LENGTH) > 0 ? 'n' : 'C'
      [flags<<4, type, len].pack("CC#{len_fmt}")
    end
    
    def parse(*args)
      _parse_(*args)
    end
    
    def _parse_(s,vf=nil)
      value, arr = '', []
      flags = s.unpack('C')[0]
      if flags & 0x10>0
        arr = s.unpack("CCn")
        len = arr[2]
        if vf
          value = s[4..-1].unpack(vf)
        else
          value = s[4..-1].unpack("a#{len}")
        end
        s.slice!(0,arr[2]+4).is_packed
      else
        arr = s.unpack("CCC")
        len = arr[2]
        if vf
          value = s[3..-1].unpack(vf)
        else
          value = s[3..-1].unpack("a#{len}")
        end
        s.slice!(0,arr[2]+3).is_packed
      end
      arr[0]= arr[0] >>4
      value[0].is_packed unless vf
      arr + value
    end
    
    def name
      self.class.to_s.split('::').last
    end
    
    def flags
      flags = @flags
      s ="["
      (flags&8>0) ? s +="O" : s += "w"
      (flags&4>0) ? s +="T" : s += "n"
      (flags&2>0) ? s +="P" : s += "c"
      (flags&1>0) ? s +="E" : s += "r"
      s +="]"
    end
    
    def flags_short
      flags = @flags
      s ="["
      s +="O" if (flags&8>0)
      s +="T" if (flags&4>0)
      s +="P" if (flags&2>0)
      s +="E" if (flags&1>0)
      s +="]"
    end
    
    def is_optional?
       (@flags&8>0)
    end
    
    def is_transitive?
      (@flags&4>0)
    end
    
    def attribute_name
      name.split('_').collect { |w| w.capitalize }.join(' ')
    end
    
    def to_s(value='', mode=:tcpdump, as4byte=false)
      
      shex = as4byte ? to_shex4_len(20) : to_shex_len(20)
      
      mode = :brief unless [:tcpdump, :brief, :hexlify].include?(mode)
      
      case mode
      when :brief
        sprintf "%s %4s %10s: [%s]%s", flags, "(#{@type})", attribute_name, shex, "#{value.size>0 ? " '#{value}'" : ''}"
      when :hexlify
        s = sprintf "%s %4s %10s: [%s]%s", flags, "(#{@type})", attribute_name, shex, "#{value.size>0 ? " '#{value}" : ''}"
        s +="\n\n"
        if as4byte
          s += self.encode4.hexlify.join("\n")
        else
          s += self.encode.hexlify.join("\n")
        end
      when :tcpdump
        if as4byte
          _, _, len, enc_value = _parse_(self.encode4, nil)
        else
          _, _, len, enc_value = _parse_(self.encode, nil)
        end
        s = sprintf "%s (%d), length: %d, Flags %s: %s", attribute_name, @type, len, flags_short, value
        s += enc_value.hexlify.join(("\n   "))
      end
    end
    
  end

  class Attr
    
    include ATTR
    include Comparable
    
    attr_reader :type
    
    def <=>(o)
      type <=> o.type
    end

    OVERRIDE_KEYS = [:flags, :type, :length].freeze

    class << self
      # Header overrides can be given as trailing options to any
      # attribute, for example Origin.new(:igp, flags: ATTR::OPTIONAL).
      # A trailing Hash is taken as options only when all its keys are
      # :flags, :type or :length, so the from hash forms are not
      # affected. To combine a hash form and options, pass the options
      # apart: Mp_reach.new({...}, flags: 0xc).
      def new(*args, &block)
        opts = nil
        last = args.last
        if last.is_a?(Hash) and ! last.empty? and (last.keys - OVERRIDE_KEYS).empty?
          opts = args.pop
        end
        o = super(*args, &block)
        o.override(**opts) if opts
        o
      end
    end

    # Sets header fields to write instead of the computed ones:
    # flags: (the 4 bit flags, as ATTR::OPTIONAL), type:, length:.
    # A nil value removes that override. Nothing is checked, so the
    # header may lie on purpose. Returns self.
    def override(**opts)
      bad = opts.keys - OVERRIDE_KEYS
      raise ArgumentError, "unknown override #{bad.inspect}, use #{OVERRIDE_KEYS.inspect}" unless bad.empty?
      @_override = overrides
      opts.each { |k, v| v.nil? ? @_override.delete(k) : @_override[k] = v }
      self
    end

    # The overrides set, as a Hash. Empty when there are none.
    def overrides
      ((defined?(@_override) && @_override) || {}).dup
    end

    # RFC 4271 section 5: an unrecognized optional transitive attribute
    # passed on to other peers MUST have its Partial bit set. Sets the
    # bit only when the attribute is optional transitive (section 4.3
    # says the bit MUST be 0 otherwise). Use override(flags: ...) to
    # write any other flags. Returns self.
    def partial!
      @flags |= PARTIAL if is_optional? and is_transitive?
      self
    end

    def partial?
      (@flags & PARTIAL) > 0
    end
    
    def method_missing(name, *args, &block)
      if name == :encode4
        send :encode, *args, &block
      else
        super
      end
    end 

    # Octets that parsing could not interpret are kept in @tail, so that
    # encode gives back what arrived (see each attribute's parse). The
    # hash forms carry them as one {:tail=>hex} entry at the end of the
    # value list, so sort, sort! and to_hash keep them too. An attribute
    # with no tail has no such entry, so its hash is the plain list it
    # has always been.
    #
    # Nothing is checked here: the octets a caller gives are the octets
    # sent, as everywhere else in the building path.
    TAIL_KEY = :tail

    # True for a {:tail=>hex} entry of a hash form value list.
    def self.tail_entry?(arg)
      arg.is_a?(Hash) and arg.size == 1 and arg.has_key?(TAIL_KEY)
    end

    # The octets kept past the last whole value, or nil.
    def tail
      (defined?(@tail) && @tail) || nil
    end

    # The {:tail=>hex} entry for the end of a to_hash value list, or nil
    # when there is no tail.
    def tail_entry
      { TAIL_KEY => tail.unpack1('H*') } if tail
    end

    # Keeps the octets of the {:tail=>hex} entries in args, and returns
    # the arguments that are left. The last entry wins.
    def take_tail(args)
      tails, rest = args.partition { |arg| Attr.tail_entry?(arg) }
      @tail = [tails.last[TAIL_KEY].to_s].pack('H*') unless tails.empty?
      rest
    end

    # Keeps the octets of a hash form's :tail key, for the attributes
    # that hash under a nested hash rather than a value list, so the
    # key sits in that hash instead of ending a list. Prefix_sid and
    # Pmsi_tunnel are the two.
    def take_tail_key(hash)
      take_tail([{ TAIL_KEY => hash[TAIL_KEY] }]) unless hash[TAIL_KEY].nil?
    end

    # One registered path attribute class.
    # session is nil, :as4byte or :path_id: the session info that
    # Attr.factory passes to new when it parses wire bytes.
    Registration = Struct.new(:type, :klass, :keys, :session, :builder) do
      def name
        keys.first
      end
      def build(value)
        builder.call(value)
      end
    end

    class << self

      # Registers a path attribute class. Each attribute file does this
      # once, after its class:
      #
      #   Attr.register(ORIGIN, Origin, :origin)
      #
      # type is the attribute type code (RFC 4271 section 4.3).
      # keys are the Path_attribute hash keys. The first one is the
      # canonical name, used by Registration#name. Every key gets its own
      # Path_attribute accessors, so pa.med works as well as
      # pa.multi_exit_disc.
      # session: :as4byte or :path_id when parsing needs session info.
      # The block builds the attribute from a hash value. The default
      # is klass.new(value).
      def register(type, klass, *keys, session: nil, &builder)
        if registered_types[type] && registered_types[type].klass != klass
          raise ArgumentError, "attribute type #{type} already registered"
        end
        builder ||= ->(value) { klass.new(value) }
        reg = Registration.new(type, klass, keys, session, builder)
        registered_types[type] = reg
        keys.each { |key| registered_keys[key] = reg }
        keys.each { |key| Attr_accessors.define(key, type, klass) }
        reg
      end

      # The Registration for a type code, or nil.
      def by_type(type)
        registered_types[type]
      end

      # The Registration for a hash key, or nil.
      def by_key(key)
        registered_keys[key]
      end

      def registrations
        registered_types.values
      end

      private

      def registered_types
        @registered_types ||= {}
      end

      def registered_keys
        @registered_keys ||= {}
      end

    end

  end

  # Accessors for Path_attribute, one set per registered key:
  # has_a_origin_attr?, has_an_origin?, origin and origin=.
  # A key that is an alias of another gets its own set, so pa.med and
  # pa.multi_exit_disc both reach attribute 4.
  # They match on the type code, so an As4_path is not an as_path.
  module Attr_accessors
    def self.define(name, type, klass)
      define_method("has_a_#{name}_attr?") { has?(type) }
      alias_method "has_an_#{name}?", "has_a_#{name}_attr?" if name =~ /\A[aeiou]/
      define_method(name) { find_by_type(type) }
      define_method("#{name}=") { |*args| replace(klass.new(*args)) }
    end
  end

end
