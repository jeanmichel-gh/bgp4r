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


require 'bgp/path_attributes/attribute'
require 'bgp/path_attributes/extended_community'

module BGP

  class Extended_communities < Attr

    class << self
      def new_hash(*args)
        raise unless args[0].is_a?(Hash)
        o = new
        args.each do |arg|
          arg.keys.each do |comm|
            if comm == :extended_communities
              o = new_hash(*args[0][:extended_communities])
              next
            end
            build = HASH_BUILDERS[comm]
            raise ArgumentError, "unknown extended community #{comm.inspect}" unless build
            o << build.call(arg[comm])
          end
        end
        o
      end
    end

    # The to_hash key of each community, and how to build it back.
    HASH_BUILDERS = {
      :color                   => ->(v) { Color.new(*v) },
      :route_target            => ->(v) { Route_target.new(*v) },
      :route_origin            => ->(v) { Route_origin.new(*v) },
      :link_bandwidth          => ->(v) { Link_bandwidth.new(*v) },
      :ospf_domain_id          => ->(v) { Ospf_domain_id.new(*v) },
      :ospf_router_id          => ->(v) { Ospf_router_id.new(*v) },
      :bgp_data_collect        => ->(v) { Bgp_data_collect.new(*v) },
      :origin_validation_state => ->(v) { Origin_validation_state.new(v) },
      :unknown                 => ->(v) { Extended_community::Unknown.new(v) },
      :encapsulation           => ->(v) { Encapsulation.new(v) },
      :traffic_rate_bytes      => ->(v) { Traffic_rate_bytes.new(*v) },
      :traffic_rate_packets    => ->(v) { Traffic_rate_packets.new(*v) },
      :traffic_action          => ->(v) { Traffic_action.new(v) },
      :redirect                => ->(v) { Redirect.new(*v) },
      :traffic_marking         => ->(v) { Traffic_marking.new(v) },
      :mac_mobility            => ->(v) { Mac_mobility.new(v[0], sticky: v[1]) },
      :esi_label               => ->(v) { Esi_label.new(v[0], single_active: v[1]) },
      :es_import               => ->(v) { Es_import.new(v) },
      :router_mac              => ->(v) { Router_mac.new(v) },
    }.freeze

    attr_reader :communities

    def initialize(*args)
      @flags, @type = OPTIONAL_TRANSITIVE, EXTENDED_COMMUNITY

      if args[0].is_a?(String) and args[0].is_packed?
        parse(args[0])
        return
      elsif args[0].is_a?(self.class)
        parse(args[0].encode, *args[1..-1])
      else
        add(*args)
      end
      yield(self) if block_given?
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
      {:extended_communities=> @communities.collect  { |c| c.to_hash }}
    end

    def extended_communities
      s=[]
      s << ''
      s << "  Carried Extended communities"
      s <<  "     " + @communities.collect { |c| c.to_s }.join("\n     ")
      s.join("\n")
    end
    
    def insert(*args)
      for arg in args
        next unless arg.is_a?(Extended_community)
        communities.insert(0,arg)
      end
      self
    end
    
    def append(*args)
      for arg in args
        next unless arg.is_a?(Extended_community)
        communities << (arg)
      end
      self
    end
    
    def replace(*args)
      for arg in args
        next unless arg.is_a?(Extended_community)
        ind = communities.find_index { |x| x.class == arg.class }
        if ind
          communities[ind] = arg
        else
          append(arg)
        end
      end
      self
    end

    def find(klass)
      communities.find { |c| c.is_a?(klass) }
    end

    def find_all(klass)
      communities.find_all { |c| c.is_a?(klass) }
    end
    
    %w{ 
      color
      route_target
      link_bandwidth
      ospf_domain_id
      encapsulation
      route_origin
      ospf_router_id      
    }.each do |ecom|
      define_method("#{ecom}") do
        ecs = find_all(BGP.const_get(ecom.capitalize))
        ecs.size==1 ? ecs[0] : ecs
      end
      define_method("#{ecom}=") do |*args|
        k = BGP.const_get(ecom.capitalize)
        replace(k.new(*args))
      end
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
      @flags, @type, _, value=super(s)
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

  Attr.register(ATTR::EXTENDED_COMMUNITY, Extended_communities, :extended_communities, :extended_community) { |v| Extended_communities.new_hash(*v) }

end

load "../../test/unit/path_attributes/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
