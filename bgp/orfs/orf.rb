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


module BGP
  module ORF
    PREFIX = 64  #  rfc 5292
  end

  class Orf

    class Entry
    end
    
    attr_accessor :type, :entries

    def initialize(*args)
      @entries=[]
      if args[0].is_a?(String) and args.size==1
        parse(args[0])
      elsif args.size==1 and args[0].is_a?(self.class) and args[0].respond_to?(:encode)
        parse(args[0].encode)
      else
        @type, *arr = args
        arr.flatten.each { |e| add(e) }
      end
    end
    
    def add(e)
      raise ArgumentError, "invalid argument" unless e.is_a?(Entry)
      @entries << e
      self
    end
    alias << add

    def encode
      entries = @entries.collect { |e| e.encode }.join
      [@type, entries.size, entries].pack('Cna*')
    end
 
    def to_s
      "#{self.class}, #{@entries.size} entries:\n  " + @entries.collect { |e| e.to_s}.join("\n  ")
    end
    
  end

end

__END__

  
  an ORF as a type and entries
   
   +--------------------------------------------------+
   | ORF Type (1 octet)                               |
   +--------------------------------------------------+
   | Length of ORFs (2 octets)                        |
   +--------------------------------------------------+
   | First ORF entry (variable)                       |
   +--------------------------------------------------+
   | Second ORF entry (variable)                      |
   +--------------------------------------------------+
   | ...                                              |
   +--------------------------------------------------+
   | N-th ORF entry (variable)                        |
   +--------------------------------------------------+
  
  http://www.iana.org/assignments/bgp-parameters/bgp-parameters.xhtml#bgp-parameters-9
  
