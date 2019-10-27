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
  
  class Origin < Attr

    def initialize(arg=0)
      @type=ORIGIN
      @flags=WELL_KNOWN_MANDATORY
      if arg.is_a?(String) and arg.packed?
        parse(arg)
      elsif arg.is_a?(self.class)
        parse(arg.encode)
      elsif arg.is_a?(Hash) and arg[:origin]
        @origin = arg[:origin]
      elsif arg.is_a?(Integer) and (0..2)===arg
        @origin=arg
      elsif arg.is_a?(Symbol)
        case arg
        when :igp
          @origin=0
        when :egp
          @origin=1
        when :incomplete
          @origin=2
        end
      else
        raise ArgumentError, "invalid argument, #{arg.class} (#{arg})"
      end
    end

    def encode
      super([@origin].pack('C'))
    end

    def to_i
      @origin
    end
    
    def to_sym
      case @origin
      when 1 ; :egp
      when 2 ; :incomplete
      when 0 ; :igp
      else
        :undefined
      end
    end
    
    def to_hash
      {:origin=> to_sym}
    end

    def origin
      case to_i
      when 0 ; 'igp'
      when 1 ; 'egp'
      when 2 ; 'incomplete'
      else
        'bogus'
      end
    end

    def to_s(method=:default)
      super(origin, method)
    end

    private

    def parse(s)
      @flags, @type, _, @origin=super(s, 'C')
    end

  end

end

load "../../test/unit/path_attributes/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0

