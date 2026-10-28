#--
# Copyright 2026 Jean-Michel Esnault.
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

# BGP routing information bases and the decision process (RFC 4271
# section 9). Not loaded by bgp4r.rb: require 'bgp/rib' to use it.

require 'bgp/rib/route'
require 'bgp/rib/decision'
require 'bgp/rib/adj_rib_in'
require 'bgp/rib/loc_rib'
require 'bgp/rib/adj_rib_out'
require 'bgp/rib/export'
require 'bgp/rib/update_builder'
require 'bgp/rib/mrai'
require 'bgp/rib/table'
require 'bgp/rib/peer_adapter'
require 'bgp/rib/peer_feed'
require 'bgp/rib/router'
require 'bgp/rib/show'
