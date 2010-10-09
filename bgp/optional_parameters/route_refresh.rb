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

module BGP

class Route_refresh_capability < OPT_PARM::Capability 
  def initialize(code=OPT_PARM::CAP_ROUTE_REFRESH)
    super(code)
  end

  def encode
    super()
  end

  def to_s
    super + "\n    Route Refresh #{@code==128 ? "(Cisco) " : ""}(#{@code}), length: 2"
  end

  def to_hash
    super()
  end
end

end