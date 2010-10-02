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
  
  module ATTR
    
    ### http://www.iana.org/assignments/bgp-parameters/bgp-parameters.xhtml#bgp-parameters-2
    
    ORIGIN = 1
    AS_PATH = 2
    NEXT_HOP = 3
    MULTI_EXIT_DISC = 4
    LOCAL_PREF = 5
    ATOMIC_AGGREGATE = 6
    AGGREGATOR = 7
    COMMUNITIES = 8
    ORIGINATOR_ID = 9
    CLUSTER_LIST = 10
    
    MP_REACH = 14
    MP_UNREACH = 15
    EXTENDED_COMMUNITY = 16
    AS4_PATH = 17
    AS4_AGGREGATOR = 18
    
    SET = 1
    SEQUENCE = 2
    CONFED_SEQUENCE = 3
    CONFED_SET = 4
    
    OPTIONAL = 0x8
    TRANSITIVE = 0x4
    PARTIAL = 0x2
    EXTENDED_LENGTH = 0x1 
    NONE = 0x0
    
    WELL_KNOWN_MANDATORY     = TRANSITIVE
    WELL_KNOWN_DISCRETIONARY = TRANSITIVE
    OPTIONAL_TRANSITIVE      = OPTIONAL | TRANSITIVE
    OPTIONAL_NON_TRANSITIVE  = OPTIONAL
    
    def encode(value='',value_fmt=nil)
      len, len_fmt = value.size, 'C'
      if len>255
        @flags |= EXTENDED_LENGTH
        len_fmt='n'
      end
      if value_fmt
        [@flags<<4, @type, len, *value].pack("CC#{len_fmt}#{value_fmt}")
      else
        ([@flags<<4, @type, len].pack("CC#{len_fmt}") + value).is_packed
      end
    end
    
    def parse(*args)
      _parse_(*args)
    end
    
    def _parse_(s,vf=nil)
      value, arr = '', []
      flags = s.unpack('C')[0]
      if flags & 0x10>0
        arr = s.unpack("CCn")
        len = arr[2]
        if vf
          value = s[4..-1].unpack(vf)
        else
          value = s[4..-1].unpack("a#{len}")
        end
        s.slice!(0,arr[2]+4).is_packed
      else
        arr = s.unpack("CCC")
        len = arr[2]
        if vf
          value = s[3..-1].unpack(vf)
        else
          value = s[3..-1].unpack("a#{len}")
        end
        s.slice!(0,arr[2]+3).is_packed
      end
      arr[0]= arr[0] >>4
      value[0].is_packed unless vf
      arr + value
    end
    
    def name
      self.class.to_s.split('::').last
    end
    
    def flags
      flags = @flags
      s ="["
      (flags&8>0) ? s +="O" : s += "w"
      (flags&4>0) ? s +="T" : s += "n"
      (flags&2>0) ? s +="P" : s += "c"
      (flags&1>0) ? s +="E" : s += "r"
      s +="]"
    end
    
    def flags_short
      flags = @flags
      s ="["
      s +="O" if (flags&8>0)
      s +="T" if (flags&4>0)
      s +="P" if (flags&2>0)
      s +="E" if (flags&1>0)
      s +="]"
    end
    
    def attribute_name
      name.split('_').collect { |w| w.capitalize }.join(' ')
    end
    
    def to_s(value='', mode=:tcpdump, as4byte=false)
      
      shex = as4byte ? to_shex4_len(20) : to_shex_len(20)
      
      mode = :brief unless [:tcpdump, :brief, :hexlify].include?(mode)
      
      case mode
      when :brief
        sprintf "%s %4s %10s: [%s]%s", flags, "(#{@type})", attribute_name, shex, "#{value.size>0 ? " '#{value}'" :''}"
      when :hexlify
        s = sprintf "%s %4s %10s: [%s]%s", flags, "(#{@type})", attribute_name, shex, "#{value.size>0 ? " '#{value}" :''}"
        s +="\n\n"
        if as4byte
          s += self.encode4.hexlify.join("\n")
        else
          s += self.encode.hexlify.join("\n")
        end
      when :tcpdump
        if as4byte
          f, t, len, enc_value = _parse_(self.encode4, nil)
        else
          f, t, len, enc_value = _parse_(self.encode, nil)
        end
        s = sprintf "%s (%d), length: %d, Flags %s: %s", attribute_name, @type, len, flags_short, value
        s += enc_value.hexlify.join(("\n   "))
      end
    end
    
  end

  class Attr
    
    include ATTR
    include Comparable
    
    attr_reader :type
    
    def method_missing(name, *args, &block)
      if name == :encode4
        send :encode, *args, &block
      else
        super
      end
    end 

  end

end
