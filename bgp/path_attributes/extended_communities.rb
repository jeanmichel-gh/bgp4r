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
require 'bgp/path_attributes/extended_community'

module BGP

  class Extended_communities < Attr

    class << self
      def new_hash(arg={})
        o = new
        arg.keys.each do |comm|
          case comm
          when :color           ; o << Color.new(*arg[comm])
          when :route_target    ; o << Route_target.new(*arg[comm])
          when :link_bandwidth  ; o << Link_bandwidth.new(*arg[comm])
          when :ospf_domain_id  ; o << Ospf_domain_id.new(*arg[comm])
          when :encapsulation   ; o << Encapsulation.new(*arg[comm])
          when :route_origin    ; o << Route_origin.new(*arg[comm])
          when :ospf_router_id  ; o << Ospf_router_id.new(arg[comm])
          else
            raise
          end 
        end
        o        
      end
    end

    attr_reader :communities

    def initialize(*args)
      @flags, @type = OPTIONAL_TRANSITIVE, EXTENDED_COMMUNITY

      if args[0].is_a?(String) and args[0].is_packed?
        parse(args[0])
      elsif args[0].is_a?(self.class)
        parse(args[0].encode, *args[1..-1])
      else
        add(*args)
      end
    end

    def add(*args)
      @communities ||=[]
      args.flatten.each do |arg|
        if arg.is_a?(String) and arg.split(' ').size>1
          arg.split.each { |v| @communities << Extended_community.factory(v) }
        elsif arg.is_a?(String) and arg.split(',').size>1
          arg.split(',').each { |v| @communities << Extended_community.factory(v) }
        elsif arg.is_a?(Extended_community)
          @communities << arg
        else
          @communities << Extended_community.factory(arg)
        end
      end
      self
    end
    alias << add

    def to_hash
      h = {}
      @communities.each { |c|  h = h.merge( { c.class.to_s.split('::').last.downcase.to_sym => c.instance_eval { value2 } }) }
      h
    end

    def extended_communities
      len = @communities.size*8
      s=[]
      s << ''
      s << "  Carried Extended communities"
      s <<  "     " + @communities.collect { |c| c.to_s }.join("\n     ")
      s.join("\n")
    end
    
    def to_s(method=:default)
      super(extended_communities, method)
    end

    def to_arr
      @communities.collect { |c| c.to_i }
    end

    def encode
      super(@communities.collect { |comm| comm.encode }.join)
    end

    def parse(s)
      @flags, @type, len, value=super(s)
      while value.size>0
        self << Extended_community.factory(value.slice!(0,8).is_packed)
      end
    end

    def sort
      Extended_communities.new(*to_arr.sort)
    end

    def sort!
      @communities = @communities.sort_by { |c| c.to_i }
      self
    end

    def <=>(other)
      sort.to_shex <=> other.sort.to_shex
    end

  end

end

load "../../test/unit/path_attributes/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
