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

require 'bgp4r'

module BGP::OPT_PARM::CAP

class Orf < BGP::OPT_PARM::Capability

  class Entry
    
    def initialize(*args)
      if args.size==1 and args[0].is_a?(String) and args[0].is_packed?
        parse(args[0])
      elsif args[0].is_a?(Hash) 
      else
        @afi, @safi, *@types = *args
      end
    end
    
    def encode
      [@afi, 0, @safi, @types.size,@types.collect { |e| e.pack('CC')}.join].pack('nCCCa*')
    end
    
    def parse(s)
      @afi, __, @safi, n = s.slice!(0,5).unpack('nCCC')
      @types=[]
      types = s.slice!(0, 2*n)
      while types.size>0
        @types<< types. slice!(0,2).unpack('CC')
      end
    end
    
    def to_s
      "AFI #{IANA.afi(@afi)} (#{@afi}), SAFI #{IANA.safi(@safi)} (#{@safi}): #{@types.inspect}"
    end
  end

  def initialize(*args)
    @entries=[]
    if args.size==1 and args[0].is_a?(String) and args[0].is_packed?
      parse(args[0])
    else
      super(OPT_PARM::CAP_ORF)
    end
  end

  def add(entry)
    @entries << entry
  end

  def encode
    super(@entries.collect { |e| e.encode }.join)
  end

  def parse(s)
    entries = super(s)
    while entries.size>0
      @entries << Entry.new(entries)
    end
  end

  def to_s
    super + "\n    Outbound Route Filtering (#{@code}), length: #{encode.size}" +
    (['']+@entries.collect { |e| e.to_s }).join("\n      ")
  end

end
end

load "../../test/optional_parameters/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
