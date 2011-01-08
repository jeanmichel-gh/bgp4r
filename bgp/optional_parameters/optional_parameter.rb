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

class UnknownBgpCapability < RuntimeError
end

module OPT_PARM

  unless const_defined? :CAPABILITY
    CAPABILITY = 2

    CAP_MBGP = 1
    CAP_ROUTE_REFRESH = 2
    CAP_ORF = 3
    CAP_GR  = 64
    CAP_AS4 = 65
    CAP_DYNAMIC = 67
    CAP_ADD_PATH = 69
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

    def self.factory(s)
      parm_type, len = s.unpack('CC')
      opt_parm = s.slice!(0,len+2).is_packed
      case parm_type
      when CAPABILITY
        Capability.factory(opt_parm)
      else
        raise RuntimeError, "Optional parameter type '#{parm_type}' not implemented"
      end
    end

  end
end
end