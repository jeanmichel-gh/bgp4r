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

require 'test/unit'  
require 'bgp/nlris/nlris'

#FIXME: rename nlri_test nlris_test

class Nlri_Test < Test::Unit::TestCase
  include BGP
  def test_1
    nlri1 = Nlri.new
    nlri1 << Nlri::Ip4.new('20.0.0.0/15')
    nlri1 << '20.0.0.0/17'
    nlri1 << '20.0.0.0/24'
    s = '0f140010140011140000'
    nlri2 = Nlri.new([s].pack('H*'))
    assert_equal('0f140010140011140000', nlri2.to_shex)
    assert_raise(ArgumentError)  { nlri2.to_shex(true) }
    assert_equal(3,nlri2.nlris.size)
  end
end
