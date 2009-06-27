#--
# Copyright 2008, 2009 Jean-Michel Esnault.
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


require 'bgp/attributes'

module BGP

  class Path_attribute
    include BGP::ATTR
    def initialize(*args)
      if args.size <= 2 and args[0].is_a?(String) and args[0].is_packed?
        s = args[0]
        @attributes=[]
        while s.size>0
          @attributes << Attr.factory(s)
        end
      else
        add(*args)
      end
    end
    def add(*args)
      @attributes ||=[]
      args.each { |arg| @attributes << arg if arg.is_a?(BGP::Attr) }
      self
    end
    alias << add
    
    def to_ary
      @attributes
    end
    
    def to_s(method=:default,as4byte=false)
      "Path Attributes:" + ([""] + @attributes.collect { |a|
        if as4byte and a.is_a?(As_path)
          a.to_s(method, as4byte)
        else
          a.to_s(method)
        end
      }).join("\n  ")
    end
    
    def find(klass)
      @attributes.find { |a| a.is_a?(klass) }
    end
    
    def size
      @attributes.size
    end
    
    def [](type)
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
      when  COMMUNITIES, :communities
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
        find(As4_aggregator)
      end
    end
    
    def has?(klass=nil)
      if klass
        @attributes.find { |a| a.is_a?(klass) }.nil? ? false : true
      else
        @attributes.collect { |attr| attr.class }
      end
    end
    
    def encode(as4byte=false)
      [@attributes.compact.collect { |x| as4byte ? x.encode4 : x.encode }.join].pack('a*')
    end
    
    def insert(*args)
      for arg in args
        next unless arg.is_a?(Attr)
        to_ary.insert(0,arg)
      end
      self
    end
    
    def append(*args)
      for arg in args
        next unless arg.is_a?(Attr)
        to_ary << (arg)
      end
      self
    end
    
    def replace(*args)
      for arg in args
        next unless arg.is_a?(Attr)
        attr = to_ary.find { |x| x.class == arg.class }
        if attr.nil?
          append(arg)
        else
          index = to_ary.index(attr)
          to_ary[index] = arg
        end
      end
      self
    end
    
    def delete(*klasses)
      for klass in klasses
        next unless klass.is_a?(Class)
        to_ary.delete_if { |x| x.class == klass }
      end
      self
    end
    
  end
  
end

module BGP

  class Attr
    include BGP::ATTR
    def self.factory(s)
      flags, type = s.unpack('CC')
      case type
      when ORIGIN
        Origin.new(s)
      when AS_PATH
        As_path.new(s)
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
        Mp_reach.new(s)
      when MP_UNREACH
        Mp_unreach.new(s)
      when EXTENDED_COMMUNITY
        Extended_communities.new(s)
      else
        if flags & 0x10==1
          len = s.slice!(0,2).unpack("n")[0]
        else 
          len = s.slice!(0,1).unpack('C')[0]
        end
        s.slice!(0,len)
        raise RuntimeError, "factory for #{type} to be implemented soon"
        nil
      end
    end

  end
  
end

load "../test/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
