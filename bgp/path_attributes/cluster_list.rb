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


require 'bgp/path_attributes/attribute'

module BGP

  class Cluster_list < Attr

    ##########################################################
    # CLUSTER ID                                             #
    ##########################################################
    class Id
      def initialize(id)
        @id = IPAddr.create(id)
      end
      def to_s
        @id.to_s
      end
      def to_i
        @id.to_i
      end
      def encode
        @id.hton
      end
    end

    ##########################################################
    # CLUSTER_LIST ATTRIBUTE                                 #
    ##########################################################

    def initialize(*args)
      @flags, @type = OPTIONAL, CLUSTER_LIST
      if args[0].is_a?(String) and args[0].is_packed?
        parse(args[0])
      elsif args[0].is_a?(self.class)
        parse(args[0].encode, *args[1..-1])
      elsif args[0].is_a?(Hash)
        add *args[0][:cluster_list]
      else
        add(*args)
      end
    end

    def add(*args)
      @cluster_ids ||=[]
      args.flatten.each do |arg|
        if arg.is_a?(String) and arg.split(' ').size>1
          arg.split.each { |v| @cluster_ids << Id.new(v) }
        elsif arg.is_a?(String) and arg.split(',').size>1
          arg.split(',').each { |v| @cluster_ids << Id.new(v) }
        elsif arg.is_a?(Id)
          @cluster_ids << arg
        else
          @cluster_ids << Id.new(arg)
        end
      end
    end
    alias << add
    
    def cluster_list
      @cluster_ids.collect { |comm| comm.to_s }.join(' ')
    end
    
    def to_s(method=:default)
      super(cluster_list, method)
    end

    def to_ary
      @cluster_ids.collect { |c| c.to_i }
    end

    def encode
      super(@cluster_ids.collect { |comm| comm.encode }.join)
    end

    def parse(s)
      @flags, @type, len, value=super(s)
      self << value.unpack("N#{len/4}")
    end

    def sort
      Cluster_list.new(to_ary.sort)
    end
    
    def to_hash
      {:cluster_list=>@cluster_ids.collect { |c| c.to_s  }}
    end
      
    def sort!
      @cluster_ids = @cluster_ids.sort_by { |c| c.to_i }
      self
    end

    def <=>(other)
      self.sort.to_shex <=> other.sort.to_shex
    end

  end
  
end

load "../../test/unit/path_attributes/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
