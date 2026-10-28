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

module BGP

class UnknownBgpCapability < RuntimeError
end

module OPT_PARM

  unless const_defined? :CAPABILITY
    CAPABILITY = 2

    CAP_MBGP = 1
    CAP_ROUTE_REFRESH = 2
    CAP_ORF = 3
    CAP_EXTENDED_NEXTHOP = 5 # RFC 8950 section 4
    CAP_GR  = 64
    CAP_AS4 = 65
    CAP_DYNAMIC = 67
    CAP_ADD_PATH = 69
    CAP_ENHANCED_ROUTE_REFRESH = 70 # RFC 7313 section 3.1
    CAP_ROUTE_REFRESH_CISCO = 128
    CAP_ORF_CISCO = 130

    ORF_NLRI = 1
    ORF_COMMUNITIES = 2
    ORF_EXTENDED_COMMUNITIES = 3
    ORF_PREFIX_LIST = 129
  end

  class Optional_parameter

    def initialize(parm_type)
      @parm_type=parm_type
    end

    def encode(value)
      [@parm_type, value.size, value].pack('CCa*')
    end

    def parse(s)
      @parm_type, len = s.slice!(0,2).unpack('CC')
      s.slice!(0,len).is_packed
    end

    # The capabilities in the next optional parameter, as an Array. One
    # parameter can hold more than one capability, so this returns a
    # list rather than a single object.
    def self.factory(s)
      parm_type, len = s.unpack('CC')
      opt_parm = s.slice!(0,len+2).is_packed
      case parm_type
      when CAPABILITY
        capabilities(opt_parm)
      else
        raise RuntimeError, "Optional parameter type '#{parm_type}' not implemented"
      end
    end

    # RFC 5492 section 4: a Capabilities optional parameter carries one
    # or more capabilities, each a one octet code, a one octet length,
    # and that many value octets. GoBGP packs several into one
    # parameter; bgp4r sends one each. Both have to be read, and reading
    # only the first used to drop the rest in silence: against a peer
    # that packed 4-octet AS after another capability, bgp4r missed it,
    # kept the 2-octet default and sent an AS_PATH the peer could not
    # parse.
    #
    # Each capability is handed to Capability.factory wrapped in a
    # parameter header of its own, which is the shape that method takes.
    def self.capabilities(opt_parm)
      value = opt_parm.byteslice(2, opt_parm.size - 2).to_s
      caps, i = [], 0
      while i + 2 <= value.size
        len = value.getbyte(i + 1)
        break if i + 2 + len > value.size
        tlv = value.byteslice(i, 2 + len)
        caps << Capability.factory(([CAPABILITY, tlv.size].pack('CC') + tlv).is_packed)
        i += 2 + len
      end
      caps
    end

  end
end
end