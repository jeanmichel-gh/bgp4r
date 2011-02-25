#--
# Copyright 2008, 2009, 2010 Jean-Michel Esnault.
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

require 'test/unit'
require 'bgp4r'
require 'bgp/messages/markers'
require 'bgp/nlris/nlris'
class End_of_rib_markers_Test < Test::Unit::TestCase
  include BGP
  def test_end_of_rib_maker_messages
    assert_match(/(ff){16}00170200000000/, Update.end_of_rib_marker.to_shex)
    assert_match(/(ff){16}001d0200000006800f03000104/, Update.end_of_rib_marker(:afi=>1, :safi=>4).to_shex)
    assert_match(/(ff){16}001d0200000006800f03000180/, Update.end_of_rib_marker(:afi=>1, :safi=>128).to_shex)
  end
end
