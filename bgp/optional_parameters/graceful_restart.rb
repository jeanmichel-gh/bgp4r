#--
# Copyright 2010 Jean-Michel Esnault.
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

module BGP

class Graceful_restart_cap < Capability
  
  def initialize(*args)
    if args.size>1
      @restart_state, @restart_time = args
      @address_families = []
      super(OPT_PARM::CAP_GR)
    else
      parse(*args)
    end
  end
  
  def add(afi,safi,flags)
    @address_families << [afi, safi, flags]
  end

  def parse(s)
    @address_families = []
    o1, families = super(s).unpack('na*')
    @restart_state = o1 >> 12
    @restart_time = o1 & 0xfff
    while families.size>0
      @address_families << families.slice!(0,4).unpack('nCC')
    end
  end

  def encode
    s = []
    s << [(@restart_state << 12) + @restart_time].pack('n')
    s << @address_families.collect { |af| af.pack('nCC') }
    super s.join
  end
  def to_s
    super + "\n    Graceful Restart Extension (#{CAP_GR}), length: 4"
  end
  
end
end
