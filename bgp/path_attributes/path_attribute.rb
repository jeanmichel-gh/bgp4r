#--
# Copyright 2008-2009, 2011, 2026 Jean-Michel Esnault.
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
require 'bgp/path_attributes/raw'
require 'bgp/path_attributes/validation'
require 'bgp/neighbor/add_path_cap'

module BGP

  class Path_attribute
    include BGP::ATTR
    include Attr_accessors
    attr_reader :attributes

    # Receive policies for attributes parsed from wire bytes. Building
    # and encoding never check anything, whatever the policy.
    #
    #   :lenient  the default: decode as before and list problems in
    #             errors. An attribute bgp4r cannot decode is kept as
    #             Attr::Raw instead of raising.
    #   :strict   the same, then raise Malformed_attribute when errors is
    #             not empty
    #   :raw      decode the headers only: every attribute is an Attr::Raw,
    #             so encode gives back the octets received
    #
    # The policy comes with the session argument: a Hash such as
    # {:as4byte=>true, :policy=>:strict}, or an object with a policy
    # method, such as the session info of a Neighbor.
    POLICIES = [:lenient, :strict, :raw]

    def initialize(*args)
      @errors = []
      if args.size <= 2 and args[0].is_a?(String) and args[0].is_packed?
        parse_wire(*args)
      elsif args.size ==1 and args[0].is_a?(Hash)
        @attributes = args[0].collect { |key, value|
          # Attr::Unknown has no type code of its own, so it is not in
          # the registry. Its hash value is a list of attributes.
          next [value].flatten.collect { |h| Attr::Unknown.new(h) } if key == :unknown
          reg = Attr.by_key(key)
          raise ArgumentError, "#{key} not implemented" unless reg
          reg.build(value)
        # Splice the :unknown lists. Not flatten: Cluster_list has to_ary.
        }.inject([]) { |a, x| x.instance_of?(Array) ? a + x : a << x }.compact
      else
        add(*args)
      end
      
      yield(self) if block_given?
      
    end

    def add(*args)
      @attributes ||=[]
      args.each { |arg| @attributes << arg if arg.is_a?(BGP::Attr) }
      self
    end
    alias << add
    
    def to_s(method=:default,as4byte=false)
      "Path Attributes:" + ([""] + @attributes.collect { |a|
        if as4byte and a.is_a?(As_path)
          a.to_s(method, as4byte)
        else
          begin
            a.to_s(method)
          rescue => e
            Log.error "#{a.class}#to_s: #{e}"
            a.class
          end
        end
      }).join("\n  ")
    end
    
    def find(klass)
      @attributes.find { |a| a.is_a?(klass) }
    end

    def find_by_type(type)
      @attributes.find { |a| a.type == type }
    end
   
    def size
      @attributes.size
    end
    
    # Looks up an attribute by type code, hash key or class:
    # pa[ATTR::ORIGIN], pa[:origin] or pa[Origin].
    def [](type)
      case type
      when Integer
        find_by_type(type)
      when Symbol
        # By type code, so :as_path never finds an As4_path subclass.
        reg = Attr.by_key(type)
        find_by_type(reg.type) if reg
      else
        find(type)
      end
    end
    
    def has?(arg=nil)
      if arg
        case arg
        when Class
          @attributes.find { |a| a.is_a?(arg) }.nil? ? false : true
        when Integer
          @attributes.find { |a| a.type == arg }.nil? ? false : true
        end
      else
        @attributes.collect { |attr| attr.class }
      end
    end
    
    def has_no?(arg)
      ! has?(arg)
    end
    
    def encode(as4byte=false)
      [@attributes.compact.collect { |x| as4byte ? x.encode4 : x.encode }.join + (@tail || '')].pack('a*')
    end

    # Problems found when these attributes were parsed from wire bytes,
    # as Attr::Finding objects. Empty for attributes built from values.
    def errors
      @errors ||= []
    end

    # The strongest RFC 7606 action among errors (section 3 (h)), or nil.
    def action
      f = Attr.strongest(errors)
      f && f.action
    end

    # Runs the receive checks on these attributes as they would be sent,
    # without raising. Returns a list of Attr::Finding. bgp4r builds and
    # sends anything; validate tells a test whether what it built is
    # wrong, and in which way.
    def validate(as4byte=false)
      out, seen = [], {}
      @attributes.compact.each do |a|
        bytes = as4byte ? a.encode4 : a.encode
        type = bytes.getbyte(1)
        out.concat Attr::Check.attribute(bytes, as4byte, exact: true)
        out << Attr::Check.duplicate_finding(type) if seen[type]
        seen[type] = true
        next if as4byte
        # A raw or malformed attribute has no segments or asn to look at.
        large = (type == AS_PATH and a.respond_to?(:segments) and As4.large?(a)) ||
                (type == AGGREGATOR and a.respond_to?(:asn) and a.asn.to_i > 0xffff)
        if large
          out << Attr::Finding.new(type, nil, nil,
            "AS number above 65535 cut to 16 bits in a 2-octet encoding, see as4_fixup (RFC 6793 section 4.2.2)")
        end
      end
      out << Attr::Finding.new(nil, 1, :treat_as_withdraw, "#{@tail.size} octets left over after the last attribute") if @tail
      out
    end
    
    def insert(*args)
      for arg in args
        next unless arg.is_a?(Attr)
        attributes.insert(0,arg)
      end
      self
    end
    
    def append(*args)
      for arg in args
        next unless arg.is_a?(Attr)
        attributes << (arg)
      end
      self
    end
    
    def replace(*args)
      for arg in args
        next unless arg.is_a?(Attr)
        ind = attributes.find_index { |x| x.class == arg.class }
        if ind
          attributes[ind] = arg
        else
          append(arg)
        end
      end
      self
    end
    
    def sort
      attributes.sort { |a,b| a.type <=> b.type }
      Path_attribute.new(*attributes.sort { |a,b| a.type <=> b.type })
    end

    def sort!
      attributes.sort! { |a,b| a.type <=> b.type }
      self
    end

    def <=>(other)
      self.sort.to_shex <=> other.sort.to_shex
    end
    
    def delete(*klasses)
      for klass in klasses
        next unless klass.is_a?(Class)
        attributes.delete_if { |x| x.class == klass }
      end
      self
    end

    def to_hash
      h = {}
      @attributes.each { |att| 
        _h = att.to_hash
        next unless _h
        # Several unknown attributes each give an :unknown array: join
        # them, a plain merge would keep only the last one.
        if _h.key?(:unknown) and h.key?(:unknown)
          _h = _h.merge(:unknown => h[:unknown] + _h[:unknown])
        end
        h = h.merge(_h)
      }
      h
    end
    
    private

    # Splits the attribute list, checks each attribute, and decodes it
    # as the policy says (RFC 7606 sections 3 and 4).
    def parse_wire(s, arg=nil)
      as4byte, _ = Attr.session_args(arg)
      policy = Attr.policy_of(arg)
      raise ArgumentError, "unknown receive policy #{policy.inspect}, use #{POLICIES.inspect}" unless POLICIES.include?(policy)
      @attributes, @errors, seen = [], [], {}
      while s.size > 0
        bytes, cut = Attr::Check.next_attribute(s)
        if cut
          @errors << cut
          @attributes << cut_attribute(bytes)
          next
        end
        type = bytes.getbyte(1)
        @errors.concat Attr::Check.attribute(bytes, as4byte)
        @errors << Attr::Check.duplicate_finding(type) if seen[type]
        seen[type] = true
        @attributes << decode_attribute(bytes, arg, policy)
      end
      @attributes.compact!
      raise Malformed_attribute.new(@errors, self) if policy == :strict and not @errors.empty?
    end

    def decode_attribute(bytes, arg, policy)
      return Attr::Raw.new(bytes) if policy == :raw
      Attr.factory(bytes.dup.is_packed, arg)
    rescue StandardError => e
      @errors << Attr::Finding.new(bytes.getbyte(1), nil, nil, "bgp4r could not decode it: #{e.message}")
      Attr::Raw.new(bytes)
    end

    # An attribute cut short. Kept so that encode gives the same octets:
    # an Attr::Raw whose length field still says what was received, or,
    # when even the header is cut, octets appended after the list.
    def cut_attribute(bytes)
      flags = bytes.getbyte(0)
      hdr = (flags & 0x10) > 0 ? 4 : 3
      if bytes.size < hdr
        @tail = (@tail || ''.b) + bytes
        return nil
      end
      len = hdr == 4 ? bytes.unpack('xxn')[0] : bytes.getbyte(2)
      Attr::Raw.new(flags >> 4, bytes.getbyte(1), bytes.byteslice(hdr, bytes.size - hdr)).override(flags: flags >> 4, length: len)
    end

    # pa.as_path_sequence=, pa.as_path_set=, and so on, one per
    # As_path.new_* builder. Every other name falls through to
    # NoMethodError. There used to be a 'med=' branch here with an empty
    # body, which made pa.med=10 a silent no-op; med= is now a real
    # accessor, defined from the :med registration key.
    def method_missing(name, *args, &block)
      if name.to_s =~ /^as_path_(.+)=$/
        replace(As_path, As_path.send("new_#{$1}", *args))
      else
        super
      end
    end

    # The names method_missing resolves, and no others. It sends
    # new_<x> to As_path, so As_path is the one that knows which names
    # those are: as_path_bogus= matches the pattern but raises
    # NoMethodError on the send, and answers false here with it. Every
    # accessor the registry defines, pa.origin and pa.origin= among
    # them, is a real method and never reaches this.
    def respond_to_missing?(name, include_private = false)
      m = /^as_path_(.+)=$/.match(name.to_s)
      # send reaches a private singleton method, so respond_to? here does too.
      return true if m and As_path.respond_to?("new_#{m[1]}", true)
      super
    end

  end
end

module BGP

  class Attr
    unless const_defined? :Unknown
      # An attribute that Attr.factory does not know. A Raw that keeps
      # the old forms: Unknown.new(flags, type, length, value), where the
      # length is ignored, and Unknown.new(wire bytes). Unlike Raw, it
      # sets or clears the Extended Length bit from the value size.
      Unknown = Class.new(Raw) do
        def initialize(*args)
          if args.size == 4
            @flags, @type, _, @value = args
          else
            super
          end
        end
        def header_flags(len)
          len_fmt(len)
          @flags
        end
      end
    end
    include BGP::ATTR
    # The session argument of factory and Path_attribute.new, as
    # [as4byte, path_id]: a Neighbor::Capabilities or any object with
    # as4byte?, a Hash with :as4byte and :path_id, or true for 4-octet AS.
    def self.session_args(arg)
      if arg.is_a?(Neighbor::Capabilities)
        [arg.as4byte?, arg]
      elsif arg.is_a?(Hash)
        [arg[:as4byte], arg[:path_id]]
      elsif arg.is_a?(TrueClass)
        [true, nil]
      elsif arg.respond_to? :as4byte?
        [arg.as4byte?, arg]
      else
        [nil, nil]
      end
    end

    # The receive policy in the session argument, :lenient by default.
    def self.policy_of(arg)
      policy = if arg.is_a?(Hash)
        arg[:policy]
      elsif arg.respond_to?(:policy)
        arg.policy
      end
      policy || :lenient
    end

    def self.factory(s, arg=nil)
      as4byte_flag, path_id_flag = session_args(arg)
      
      # Look the type code up in the registry (RFC 4271 section 4.3).
      # Types nobody registered come back as Attr::Unknown.
      _, type = s.unpack('CC')
      reg = by_type(type)
      case reg && reg.session
      when nil      ; reg ? reg.klass.new(s) : Unknown.new(s)
      when :as4byte ; reg.klass.new(s, as4byte_flag)
      when :path_id ; reg.klass.new(s, path_id_flag)
      end
    end
    
  end
  
end
load "../../test/unit/path_attributes/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
