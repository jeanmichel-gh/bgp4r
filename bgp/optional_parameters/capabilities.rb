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

require 'bgp/optional_parameters/capability'

%w{ mbgp orf route_refresh as4 graceful_restart dynamic }.each do |c|
    BGP::OPT_PARM::CAP.autoload  "#{c}".capitalize.to_sym,"bgp/optional_parameters/#{c}"
end

module BGP::OPT_PARM
  module DYN_CAP
    BGP::OPT_PARM::CAP.constants.each do |kl|
      const_set(kl, Class.new(::BGP::OPT_PARM::CAP.const_get(kl)))
    end
  end
end
