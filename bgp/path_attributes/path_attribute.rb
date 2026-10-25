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
require 'bgp/neighbor/add_path_cap'

module BGP

  class Path_attribute
    include BGP::ATTR
    include Attr_accessors
    attr_reader :attributes

    def initialize(*args)
      if args.size <= 2 and args[0].is_a?(String) and args[0].is_packed?
        s = args[0]
        @attributes=[]
        while s.size>0
          @attributes << Attr.factory(*args)
          @attributes
        end
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
      [@attributes.compact.collect { |x| as4byte ? x.encode4 : x.encode }.join].pack('a*')
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

    def method_missing(name, *args, &block)
      if name.to_s == 'med='
        #multi_exit_disc= *args
      elsif name.to_s =~ /^as_path_(.+)=$/
        replace(As_path, As_path.send("new_#{$1}", *args))
      else
        super
      end
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
    def self.factory(s, arg=nil)
      if arg.is_a?(Neighbor::Capabilities)
        as4byte_flag = arg.as4byte?
        path_id_flag = arg
      elsif arg.is_a?(Hash)
        as4byte_flag=arg[:as4byte]
        path_id_flag=arg[:path_id]
      elsif arg.is_a?(TrueClass)
        as4byte_flag=true
        path_id_flag=nil
      elsif arg.respond_to? :as4byte?
        as4byte_flag = arg.as4byte?
        path_id_flag = arg
      else
        as4byte_flag=nil
        path_id_flag=nil
      end
      
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
