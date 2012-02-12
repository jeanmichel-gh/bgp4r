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

  module ATTR
  end

  class Originator_id < Attr

    class << self
      def new_hash(arg={})
        new arg[:originator_id]
      end
    end


    def initialize(*args)
      @flags, @type = OPTIONAL, ORIGINATOR_ID
      if args[0].is_a?(String) and args[0].is_packed?
        parse(args[0])
      elsif args[0].is_a?(self.class)
        parse(args[0].encode, *args[1..-1])
      else
        self.originator_id=args[0]
      end
    end

    def to_i
      @origin_id.to_i
    end
    def parse(s)
      @flags, @type, len, value = super(s)
      @origin_id = IPAddr.create(value)
    end

    def encode
      super(@origin_id.encode)
    end

    def to_s(method=:default)
      super(@origin_id.to_s, method)
    end
    
    def originator_id
      @origin_id.to_s
    end
    
    def to_hash
      {:originator_id=> originator_id}
    end
    
    def originator_id=(val)
      @origin_id=IPAddr.create(val)
    end


  end

end

load "../../test/unit/path_attributes/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
