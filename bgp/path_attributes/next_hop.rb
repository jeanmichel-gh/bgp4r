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

  class Next_hop < Attr

    # class << self
    #   def new_hash(arg={})
    #     if arg.has_key?(:next_hop)
    #       new( arg[:next_hop])
    #     elsif arg.has_key?(:nexthop)
    #       new( arg[:nexthop])
    #     end
    #   end
    # end

    def initialize(*args)
      @flags, @type = WELL_KNOWN_MANDATORY, NEXT_HOP
      if args[0].is_a?(String) and args[0].is_packed?
        parse(args[0])
      elsif args[0].is_a?(self.class)
        parse(args[0].encode, *args[1..-1])
      elsif args[0].is_a?(Hash)
        if args[0].has_key?(:next_hop)
          @next_hop = IPAddr.create(args[0][:next_hop])
        elsif arg.has_key?(:nexthop)
          @next_hop = IPAddr.create(args[0][:nexthop])
        end
      else
        @next_hop = IPAddr.create(*args)
      end
    end

    def next_hop
      @next_hop.to_s
    end
    def to_s(method=:default)
      super(next_hop, method)
    end
    
    def to_hash
      {:next_hop=> next_hop }
    end

    def to_i
      @next_hop.to_i
    end
    def parse(s)
      @flags, @type, len, value = super(s)
      @next_hop = IPAddr.new_ntoh(value[0,4])
    end

    def encode
      super(@next_hop.encode)
    end

  end

end
load "../../test/unit/path_attributes/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
