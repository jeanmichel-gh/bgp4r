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

require 'bgp/common'
require 'bgp/io'
require 'bgp/neighbor'
require 'bgp/messages/message'
require 'bgp/version'
require 'bgp/path_attributes/attributes'
require 'bgp/path_attributes/attribute'
require 'bgp/nlris/nlris'

#TODO move in messages/messages.rb file ... same as attributes

BGP.autoload :Update,            'bgp/messages/update'
BGP.autoload :Keepalive,         'bgp/messages/keepalive'
BGP.autoload :Open,              'bgp/messages/open'
BGP.autoload :Notification,      'bgp/messages/notification'
BGP.autoload :Route_refresh,     'bgp/messages/route_refresh'
BGP.autoload :Orf_route_refresh, 'bgp/messages/route_refresh'
BGP.autoload :Prefix_orf,        'bgp/orfs/prefix_orf'

