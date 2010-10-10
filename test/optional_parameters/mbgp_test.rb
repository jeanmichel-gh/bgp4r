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

require 'test/unit'
require 'bgp4r'

class Mbgp_cap_Test < Test::Unit::TestCase
  include BGP::OPT_PARM::CAP
  def test_1
    mbgp1 = Mbgp.new(1,1)
    mbgp2 = Mbgp.new(['0206010400010001'].pack('H*'))
    mbgp3 = Mbgp.new(mbgp1.encode)
    assert_equal(mbgp2.encode, mbgp3.encode)
    assert_equal "Option Capabilities Advertisement (2): [0206010400010001]\n    Multiprotocol Extensions (1), length: 4\n      AFI IPv4 (1), SAFI Unicast (1)", mbgp2.to_s
  end
end
