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
require 'bgp/optional_parameters/capability'

module BGP

class As4_capability < Capability
  def initialize(s)
    if s.is_a?(String) and s.is_packed?
      parse(s)
    else
      super(OPT_PARM::CAP_AS4)
      @as=s
    end
  end
  
  def encode
    super([@as].pack('N'))
  end

  def parse(s)
    @as = super(s).unpack('N')[0]
  end

  def to_s
    super + "\n    Capability(#{CAP_AS4}): 4-octet AS number: " + @as.to_s
  end

  def to_hash
    super({:as => @as})
  end
end
end