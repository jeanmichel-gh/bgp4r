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
        o = new
        o.add(*communities_from_hash(args.size == 1 ? args[0] : args))
        o
      end

      # True for every hash shape communities_from_hash takes: a bare
      # hash of community names such as {:route_target=>[1,2]}, the hash
      # to_hash returns, and the list of one key hashes it holds under
      # :extended_communities.
      #
      # new used to take none of them, while the registration built with
      # new_hash, so Path_attribute.new took a hash that the
      # extended_communities= setter refused. Both go through here now.
      def hash_form?(arg)
        case arg
        when Hash
          return true if arg.has_key?(:extended_communities)
          ! arg.empty? and arg.keys.all? { |k|
            HASH_BUILDERS.has_key?(k) or k == Attr::TAIL_KEY or
              k == Extended_community::TYPE_KEY }
        when Array
          ! arg.empty? and arg.all? { |e| hash_form?(e) }
        else
          false
        end
      end

      # The communities a hash describes, in order. A {:tail=>hex} entry
      # is passed through for add to keep.
      #
      # A :type key (Extended_community::TYPE_KEY) is the type octet of
      # the community the same hash describes, which to_hash carries
      # when the value alone cannot reproduce it. It is written over the
      # octet the value gave, after the value has built the community,
      # so the build path is the one it has always been and the octet
      # is the one that arrived. It is optional: a hash without it
      # builds exactly what it built before.
      def communities_from_hash(arg)
        arg = [arg] if arg.is_a?(Hash)
        raise ArgumentError, "invalid argument #{arg.inspect}" unless arg.is_a?(Array)
        out = []
        arg.each do |h|
          raise ArgumentError, "invalid extended community #{h.inspect}" unless h.is_a?(Hash)
          type = h[Extended_community::TYPE_KEY]
          h.each do |comm, v|
            if comm == Extended_community::TYPE_KEY
              next
            elsif comm == :extended_communities
              out.concat(communities_from_hash([v].flatten(1)))
            elsif comm == Attr::TAIL_KEY
              out << { comm=> v }
            else
              build = HASH_BUILDERS[comm]
              raise ArgumentError, "unknown extended community #{comm.inspect}" unless build
              ec = build.call(v)
              ec.type = type unless type.nil?
              out << ec
            end
          end
        end
        out
      end
    end

    # The to_hash key of each community, and how to build it back.
    HASH_BUILDERS = {
      :color                   => ->(v) { Color.new(*v) },
      :route_target            => ->(v) { Route_target.new(*v) },
      :route_origin            => ->(v) { Route_origin.new(*v) },
      :source_as               => ->(v) { Source_as.new(*v) },
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
      # These two hash as a list of their named fields, and as a Hash when
      # the community also carries reserved bits, which the list has
      # nowhere to put. Both forms go to the one constructor.
      :mac_mobility            => ->(v) { v.is_a?(Hash) ? Mac_mobility.new(v) : Mac_mobility.new(v[0], sticky: v[1]) },
      :esi_label               => ->(v) { v.is_a?(Hash) ? Esi_label.new(v) : Esi_label.new(v[0], single_active: v[1]) },
      :es_import               => ->(v) { Es_import.new(v) },
      :router_mac              => ->(v) { Router_mac.new(v) },
      # RFC 9251 section 9.4. Its list form is the flag names that are
      # set, so the empty list is a community with neither, and the Hash
      # form carries the reserved bits as the two above do.
      :multicast_flags         => ->(v) { Multicast_flags.new(v) },
      # RFC 9251 section 9.5. Types 0, 1 and 2 hash as the [global,
      # local] pair their RT structure splits into; type 3 hashes as a
      # Hash holding its six octets, because the structure it is told to
      # copy does not fit in them. Both forms go to the one constructor.
      :evi_rt_0                => ->(v) { Evi_rt_0.new(v) },
      :evi_rt_1                => ->(v) { Evi_rt_1.new(v) },
      :evi_rt_2                => ->(v) { Evi_rt_2.new(v) },
      :evi_rt_3                => ->(v) { Evi_rt_3.new(v) },
      # The last six EVPN communities. Each hashes as the list of its own
      # fields, or as a Hash of them when the value also carries a
      # reserved bit, and both forms go to the one constructor. The
      # Default Gateway has no fields at all, so its list is empty.
      :layer2_attributes       => ->(v) { Layer2_attributes.new(v) },
      :e_tree                  => ->(v) { E_tree.new(v) },
      :df_election             => ->(v) { Df_election.new(v) },
      :arp_nd                  => ->(v) { Arp_nd.new(v) },
      :service_carving_time    => ->(v) { Service_carving_time.new(v) },
      :default_gateway         => ->(v) { Default_gateway.new(v) },
    }.freeze

    attr_reader :communities

    def initialize(*args)
      @flags, @type = OPTIONAL_TRANSITIVE, EXTENDED_COMMUNITY

      if args[0].is_a?(String) and args[0].is_packed?
        parse(args[0])
        return
      elsif args[0].is_a?(self.class)
        parse(args[0].encode, *args[1..-1])
      elsif self.class.hash_form?(args[0])
        add(*self.class.communities_from_hash(args[0]))
      else
        add(*args)
      end
      yield(self) if block_given?
    end

    def add(*args)
      @communities ||=[]
      take_tail(args.flatten).each do |arg|
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

    # The communities, plus a {:tail=>hex} entry when octets were kept
    # (Attr::TAIL_KEY), so the hash of a malformed attribute round trips
    # byte for byte through new.
    def to_hash
      {:extended_communities=> @communities.collect  { |c| c.to_hash } + [tail_entry].compact}
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
      source_as
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
      super(@communities.collect { |comm| comm.encode }.join + (@tail || ''))
    end

    # RFC 4360 section 2: an extended community is 8 octets. Only whole
    # ones go to the factory; octets past the last whole one are kept, so
    # encode gives back what was received. A shorter slice used to reach
    # the factory, and a known type and subtype pair gave a community
    # with nil fields whose encode raised. RFC 7606 section 7.14 makes
    # such an attribute malformed; Path_attribute#errors reports it.
    def parse(s)
      @flags, @type, _, value=super(s)
      @communities ||= []
      while value.size>=8
        self << Extended_community.factory(value.slice!(0,8).is_packed)
      end
      @tail = value.b if value.size>0
    end

    def sort
      Extended_communities.new(*to_arr.sort, *[tail_entry].compact)
    end

    def sort!
      @communities = @communities.sort_by { |c| c.to_i }
      self
    end

    def <=>(other)
      sort.to_shex <=> other.sort.to_shex
    end

  end

  # The value goes to new_hash whole, not splatted: a splatted Hash
  # arrives as its pairs, so Path_attribute.new used to refuse the bare
  # {:route_target=>[1,2]} that new_hash itself takes. A list of
  # community hashes, the shape to_hash returns, reads the same either
  # way.
  # No builder block: the default one calls new, which since it learned
  # the hash shapes takes everything new_hash takes and everything else
  # besides, so the :extended_communities key accepts what the
  # constructor accepts. A block calling new_hash made the key narrower
  # than the class, and refused the plain forms:
  # Path_attribute.new(:extended_communities => ['0002000100000001']).
  Attr.register(ATTR::EXTENDED_COMMUNITY, Extended_communities, :extended_communities, :extended_community)

end

load "../../test/unit/path_attributes/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
