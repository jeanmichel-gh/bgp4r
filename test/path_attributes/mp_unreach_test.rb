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
require 'test/unit'

class Mp_unreach_Test < Test::Unit::TestCase
  include BGP
  def test_1
    mpur = Mp_unreach.new(:safi=>1, :prefix=>['10.0.0.0/16', '10.1.0.0/16'])
    assert_raise(ArgumentError) { Mp_unreach.new }
  end
  
  def test_2
    mpur = Mp_unreach.new(:safi=>2, :prefix=>['192.168.1.0/24', '192.168.2.0/24'])
    assert_equal('800f0b00010218c0a80118c0a802', mpur.to_shex)
    
     mpur = Mp_unreach.new(:safi=>2, :prefix=>['2007:1::/64', '2007:2::/64','2007:3::/64'])
     assert_equal('800f1e000202402007000100000000402007000200000000402007000300000000', mpur.to_shex)

     #mpur = Mp_unreach.new(:safi=>2, :prefix=>['2007:1::/64, 101', '2007:2::/64,102','2007:3::/64, 103'])
     mpur = Mp_unreach.new(:safi=>4, :nlri=> [
       {:prefix=>'2007:1::/64', :label=> 101},
       {:prefix=>'2007:2::/64', :label=> 102},
       {:prefix=>'2007:3::/64', :label=> 103},])
    assert_equal('800f27000204580006512007000100000000580006612007000200000000580006712007000300000000', mpur.to_shex)
    assert_match(/^800f..000204/,mpur.to_shex)
    assert_match(/58000651200700010000000058/,mpur.to_shex)
    assert_match(/58000661200700020000000058/,mpur.to_shex)
    assert_match(/580006712007000300000000$/,mpur.to_shex)

    mpur = Mp_unreach.new(:safi=>128, :nlri=> [
      {:rd=> Rd.new(100,100), :prefix=> Prefix.new('192.168.1.0/24'), :label=>101},
      {:rd=> Rd.new(100,100), :prefix=> Prefix.new('192.168.2.0/24'), :label=>102},
      {:rd=> Rd.new(100,100), :prefix=> Prefix.new('192.168.3.0/24'), :label=>103},])
    assert_match(/^800f..000180/,mpur.to_shex)
    assert_equal("700006510000006400000064c0a801",mpur.nlris[0].to_shex)
    assert_equal("700006610000006400000064c0a802",mpur.nlris[1].to_shex)

  end
end