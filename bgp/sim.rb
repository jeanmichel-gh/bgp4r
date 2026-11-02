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

# `bgp4r-sim`, the route injector, and `bgp4r routegen`. Not loaded by
# bgp4r.rb: require 'bgp/sim' to use it, the same arrangement
# bgp/daemon.rb, bgp/rib.rb and bgp/capture.rb have.
#
# docs/daemon.md is the design and the guide, from its `bgp4r-sim, the
# injector` heading on.

require 'bgp/sim/sent'
require 'bgp/sim/injector'
require 'bgp/sim/views'
require 'bgp/sim/http'
require 'bgp/sim/server'
require 'bgp/sim/routegen'
