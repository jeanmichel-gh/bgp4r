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
    CAP_ROLE = 9 # RFC 9234 section 4.1
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

    # A one octet Parameter Type and a one octet Parameter Length
    # (RFC 4271 section 4.2), or the same type octet and a two octet
    # length when the enclosing OPEN uses the extended form of RFC 9072
    # section 2, Figure 2 "Extended Parameters Format": "The rules for
    # encoding Optional Parameters are unchanged with respect to those
    # given in [RFC4271], except that the Parameter Length field is
    # extended to be a two-octet unsigned integer."
    #
    # Which form is in use is a property of the enclosing OPEN and not
    # of the parameter, so Open#encode decides and passes it down. A
    # parameter encoded on its own is in the RFC 4271 form, as it has
    # always been.
    def encode(value, extended: false)
      if extended
        [@parm_type, value.size, value].pack('Cna*')
      else
        [@parm_type, value.size, value].pack('CCa*')
      end
    end

    def parse(s)
      @parm_type, len = s.slice!(0,2).unpack('CC')
      s.slice!(0,len).is_packed
    end

    # The size of the parameter header: two octets, or three in the
    # RFC 9072 section 2 extended form, where the Parameter Length is
    # two octets.
    def self.header_size(extended)
      extended ? 3 : 2
    end

    # The capabilities in the next optional parameter, as an Array. One
    # parameter can hold more than one capability, so this returns a
    # list rather than a single object.
    #
    # extended is true when the enclosing OPEN carries the RFC 9072
    # section 2 Extended Optional Parameters Length, in which case this
    # parameter's Length field is two octets wide, not one.
    def self.factory(s, extended: false)
      hdr = header_size(extended)
      parm_type, len = extended ? s.unpack('Cn') : s.unpack('CC')
      # RFC 4271 section 4.2 gives an optional parameter a 1 octet
      # Parameter Type and a 1 octet Parameter Length, and RFC 9072
      # section 2 widens the length to two, so fewer octets than that are
      # not a parameter: there is no Length to read and len is nil. nil
      # says so and leaves the octets where they are, for Open to keep as
      # its tail. len+hdr used to raise NoMethodError here and take the
      # parse of the whole OPEN with it.
      return nil if len.nil?
      opt_parm = s.slice!(0,len+hdr).is_packed
      case parm_type
      when CAPABILITY
        capabilities(opt_parm, :extended => extended)
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
    # That wrapper is always the RFC 4271 two octet header, whatever the
    # enclosing OPEN used, because it never reaches the wire: the
    # capability objects read it back through Optional_parameter#parse,
    # and Open#encode applies the form the message needs again when it
    # writes them out. Only the real parameter header this method skips
    # grows to three octets in the extended form.
    def self.capabilities(opt_parm, extended: false)
      hdr = header_size(extended)
      value = opt_parm.byteslice(hdr, opt_parm.size - hdr).to_s
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