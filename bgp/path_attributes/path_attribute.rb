#--
# Copyright 2008-2009, 2011 Jean-Michel Esnault.
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
require 'bgp/neighbor/add_path_cap'

module BGP

  class Path_attribute
    include BGP::ATTR
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
        @attributes = []
        @attributes = args[0].keys.collect { |attr|  
          case attr
          when :next_hop, :nexthop     ; Next_hop.new(args[0][attr])
          when :local_pref             ; Local_pref.new(args[0][attr])
          when :med, :multi_exit_disc  ; Multi_exit_disc.new(args[0][attr])
          when :mp_reach               ; Mp_reach.new(args[0][attr])
          when :mp_unreach             ; Mp_unreach.new(args[0][attr])
          when :as_path                ; As_path.new_hash(args[0][attr])
          when :as4_path               ; As4_path.new_hash(args[0][attr])
          when :origin                 ; Origin.new(args[0][attr])
          when :originator_id          ; Originator_id.new(args[0][attr])
          when :cluster_list           ; Cluster_list.new(*args[0][attr])
          when :aggregator             ; Aggregator.new(args[0][attr])
          when :as4_aggregator         ; As4_aggregator.new(args[0][attr])
          when :originator_id          ; Originator_id.new(args[0][attr])
          when :communities, :community; Communities.new(args[0][attr])
          when :aigp                   ; Aigp.new(args[0][attr])
          when :extended_communities, :extended_community
            Extended_communities.new_hash(*args[0][attr])
          when :atomic_aggregate       ; Atomic_aggregate.new
            # FIXME: add other attr here ...
          else 
            puts "#{attr} to be implemented!"
          end
          }.compact
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
          p e 
          p a.class
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
    
    def [](type)
      if type.is_a?(Fixnum)
        return find_by_type(type)
      end
      case type
      when  ORIGIN, :origin
        find(Origin)
      when  AS_PATH, :as_path
        find(As_path)
      when  NEXT_HOP, :next_hop
        find(Next_hop)
      when  MULTI_EXIT_DISC, :multi_exit_disc
        find(Multi_exit_disc)
      when  LOCAL_PREF, :local_pref
        find(Local_pref)
      when  ATOMIC_AGGREGATE, :atomic_aggregate
        find(Atomic_aggregate)
      when  AGGREGATOR, :aggregator
        find(Aggregator)
      when  COMMUNITIES, :communities, :community
        find(Communities)
      when ORIGINATOR_ID, :originator_id
        find(Originator_id)
      when CLUSTER_LIST, :cluster_list
        find(Cluster_list)
      when MP_REACH, :mp_reach
        find(Mp_reach)
      when MP_UNREACH, :mp_unreach
        find(Mp_unreach)
      when EXTENDED_COMMUNITY, :extended_community
        find(Extended_communities)
      when AS4_PATH, :as4_path
        find(As4_path)
      when AS4_AGGREGATOR, :as4_aggregator
      else
        find(type)
      end
    end
    
    def has?(arg=nil)
      if arg
        case arg
        when Class
          @attributes.find { |a| a.is_a?(arg) }.nil? ? false : true
        when Fixnum
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

    %w{ 
      origin 
      next_hop 
      local_pref 
      multi_exit_disc 
      as_path 
      communities 
      aggregator 
      atomic_aggregate 
      originator_id 
      cluster_list 
      mp_reach 
      mp_unreach 
      extended_communities 
    }.each do |attr|
      define_method("has_a_#{attr}_attr?") do
        has? BGP.const_get(attr.capitalize)
      end
      define_method("#{attr}") do
        k = BGP.const_get(attr.capitalize)
        @attributes.find { |a| a.is_a?(k) }
      end
      eval "alias :has_an_#{attr}? :has_a_#{attr}_attr?" if (attr =~ /^[aeiou]/)
      
      define_method("#{attr}=") do |*args|
        k = BGP.const_get(attr.capitalize)
        replace(k.new(*args))
      end
            
    end
    
    def to_hash
      h = {}
      @attributes.each { |att| 
        _h = att.to_hash
        h = h.merge(_h)  if _h
      }
      h
    end
    
    private

    def att_sym_to_klass(sym)
      case sym
      when :communities, :community ; Communities
      end
    end
    
    def method_missing(name, *args, &block)
      if name.to_s == 'med='
        multi_exit_disc(*args, &block)
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
      Unknown = Class.new(Attr) do
        attr_reader :type, :flags, :value
        def initialize(*args)
          if args.size>1
            @flags, @type, len, @value=args
          else
            parse(*args)
          end
        end
        def encode
          super(@value)
        end
        def parse(s)
          @flags, @type, len, @value = super
        end
      end
    end
    include BGP::ATTR
    def self.factory(s, arg=nil)
      #FIXME:
      
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
      
      flags, type = s.unpack('CC')
      case type
      when ORIGIN
        Origin.new(s)
      when AS_PATH
        As_path.new(s,as4byte_flag)
      when NEXT_HOP
        Next_hop.new(s)
      when MULTI_EXIT_DISC
        Multi_exit_disc.new(s)
      when LOCAL_PREF
        Local_pref.new(s)
      when ATOMIC_AGGREGATE
        Atomic_aggregate.new(s)
      when AGGREGATOR
        Aggregator.new(s)
      when COMMUNITIES
        Communities.new(s)
      when ATOMIC_AGGREGATE
        Atomic_aggregate.new(s)
      when ORIGINATOR_ID
        Originator_id.new(s)
      when CLUSTER_LIST
        Cluster_list.new(s)
      when MP_REACH
        Mp_reach.new(s,path_id_flag)
      when MP_UNREACH
        Mp_unreach.new(s,path_id_flag)
      when EXTENDED_COMMUNITY
        Extended_communities.new(s)
      else
        #FIXME: raise UnknownPathAttributeError() ....
        p s
        Unknown.new(s)
      end
    end
    
  end

  # require 'bgp/path_attributes/local_pref'
  # require 'bgp/path_attributes/next_hop'
  # require 'bgp/path_attributes/multi_exit_disc'
  #   
  # p = Path_attribute.new :local_pref=>100, :next_hop => '10.0.0.1', :med=>300
  # # p p
  # puts p   
  
end
load "../../test/unit/path_attributes/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
