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


require 'bgp/attribute'

module BGP

  class Multi_exit_disc < Attr

    def initialize(arg=0)
      @flags, @type=OPTIONAL, MULTI_EXIT_DISC
      if arg.is_a?(String) and arg.is_packed?
        parse(arg)
      elsif arg.is_a?(self.class)
        parse(arg.encode)
      elsif arg.is_a?(Integer)
        @med = arg
      elsif arg.is_a?(Hash) and arg[:multi_exit_disc] or arg[:med]
        self.med = arg[:med] if arg[:med]
        self.med = arg[:multi_exit_disc] if arg[:multi_exit_disc]
      else
        raise ArgumentError, "invalid argument, #{arg.inspect}"
      end
    end

    def med=(val)
      raise ArgumentError, "invalid argument" unless val.is_a?(Integer)
      @med=val
    end

    def to_i
      @med
    end

    def encode
      super([to_i].pack('N'))
    end
    
    def multi_exit_disc
      format("(0x%4.4x) %d", to_i, to_i)
    end

    def to_s(method=:default)
      super(multi_exit_disc, method)
    end

    private

    def parse(s)
      @flags, @type, len, @med=super(s,'N')
    end

  end

end
load "../test/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
