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

require 'bgp/common'

module BGP
  class Label
    attr_reader :label
    def initialize(*args)
      @label, @exp = [0]*3
      if args.size==1 and args[0].is_a?(Hash)
        @label=args[0][:label] if args[0][:label]
        @exp=args[0][:exp] if args[0][:exp]
      elsif args.size==1 and args[0].is_a?(String) and args[0].is_packed?
        parse(args[0])
      else args[0].is_a?(Fixnum)
        @label, @exp = args + [0]
      end
    end
    def encode(bottom=1)
      n = (@label << 4) | ((@exp & 0x7)<< 1) |(bottom & 0x1)
      o1 = (n & 0xff0000) >> 16
      o2 = (n & 0x00ff00) >> 8
      o3 = (n & 0x0000ff)
      [o1,o2,o3].pack('CCC')
    end
    def parse(s)
      octets = s.slice!(0,3).unpack('CCC')
      n = (octets[0] << 16) + (octets[1] << 8) + octets[2]
      @exp = (n >> 1) & 0x7
      @label = (n >> 4)
    end
    def to_hash
      {:label=>@label, :exp=>@exp}
    end
  end
  class Label_stack
    def initialize(*args)
      @label_stack=[]
      if args.size==1 and args[0].is_a?(String) and args[0].is_packed?
        parse(args[0])
      else
        args.each { |arg| @label_stack << (arg.is_a?(Label) ? arg : Label.new(arg)) }
      end
    end
    def size
      @label_stack.size
    end
    def encode
      enc = @label_stack[0..-2].collect { |l| l.encode(0) }
      enc << @label_stack[-1].encode
      enc.join
    end
    def parse(s)
      while s.size>0
        bottom = s[2,1].unpack('C')[0]
        @label_stack << label = Label.new(s)
        break if bottom & 1 > 0
      end
    end
    def to_s
      if @label_stack.empty?
        "Label stack:(empty)"
      else
        "Label Stack=#{@label_stack.collect{ |l| l.label }.join(',')} (bottom)"
      end
    end
    def bit_length
      @label_stack.compact.size*24
    end
  end
end

load "../../test/nlris/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0

