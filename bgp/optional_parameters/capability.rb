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

require 'bgp/optional_parameters/optional_parameter'
require 'bgp4r'

module BGP

class UnknownBgpCapability < RuntimeError
end

class Capability < OPT_PARM::Optional_parameter
  include OPT_PARM
  def initialize(code)
    super(OPT_PARM::CAPABILITY)
    @code=code
  end
  def encode(value='')
    super([@code,value.size, value].pack('CCa*'))
  end
  def parse(_s)
    s = super(_s)
    @code, len = s.slice!(0,2).unpack('CC')
    s.slice!(0,len).is_packed
  end
  def to_s
    "Option Capabilities Advertisement (#{@parm_type}): [#{to_shex}]"
  end
  def self.factory(s)
    code = s.slice(2,1).unpack('C')[0]
    case code
    when CAP_AS4
      As4_cap.new(s)
    when CAP_MBGP
      Mbgp_cap.new(s)
    when CAP_ROUTE_REFRESH, CAP_ROUTE_REFRESH_CISCO
      Route_refresh_cap.new(code)
    when CAP_ORF,CAP_ORF_CISCO
      Orf_cap.new(s)
    else
      raise UnknownBgpCapability, "Capability (#{code}), length: #{s.size} not implemented: [#{s.unpack('H*')[0]}]" 
    end
  end
  def to_hash(h={})
    if h.empty?
      {:code=> @code}
    else
      {:code=> @code, :capability=> h}
    end
  end
end

end