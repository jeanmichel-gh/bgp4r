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

# Reading BGP off a wire: a pcap reader, a dissector, the TCP reassembly
# that frames messages out of a stream, and the `bgp4r` command.
#
# Not loaded by bgp4r.rb: require 'bgp/capture' to use it, which is the
# same arrangement bgp/rib.rb has. A script that drives a session has no
# use for a dissector, and this pulls in json, time and optparse when the
# command runs.

require 'bgp/capture/pcap'
require 'bgp/capture/dissect'
require 'bgp/capture/stream'
require 'bgp/capture/cli'
