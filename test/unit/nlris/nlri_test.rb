#--
# Copyright 2008, 2009, 2011 Jean-Michel Esnault.
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

class Nlri_Test < Test::Unit::TestCase
  include BGP

  def test_nlri
    nlri1 = Nlri.new
    nlri1 << '20.0.0.0/15'
    nlri1 << '20.0.0.0/17'
    nlri1 << '20.0.0.0/24'
    s = '0f140010140011140000'
    nlri2 = Nlri.new_ntop([s].pack('H*'))
    assert_equal('0f140010140011140000', nlri2.to_shex)
    assert_equal('000a0f140010140011140000', nlri2.to_shex(true))
    assert_equal(3,nlri2.nlris.size)
  end
  def test_nlris
    nlri = Nlri.new
    nlri << [101, '101.0.0.0/8']
    nlri << [102, '102.0.0.0/8']
    nlri << [103, '103.0.0.0/8']
    nlri << { :path_id=> 104, :nlri=> '104.0.0.0/8' }
    nlri << { :path_id=> 105, :nlri=> '105.0.0.0/8' }
    assert_match(/ID=102, 102.0/, nlri.to_s)
    assert_match(/ID=104, 104.0/, nlri.to_s)
    assert_match(/ID=105, 105.0/, nlri.to_s)
    
    nlri2 = Nlri.new(
      [101, '101.0.0.0/8'],
      [102, '102.0.0.0/8'],
      [103, '103.0.0.0/8'],
      [104, '104.0.0.0/8'],
      [105, '105.0.0.0/8']
    )
    assert_equal(nlri.to_shex, nlri2.to_shex)
  end
  def test_withdrawns_ext
    nlri = Withdrawn.new
    nlri << [101, '101.0.0.0/8']
    nlri << [102, '102.0.0.0/8']
    nlri << [103, '103.0.0.0/8']
    nlri << { :path_id=> 104, :nlri=> '104.0.0.0/8' }
    nlri << { :path_id=> 105, :nlri=> '105.0.0.0/8' }
    assert_match(/ID=102, 102.0/, nlri.to_s)
    assert_match(/ID=104, 104.0/, nlri.to_s)
    assert_match(/ID=105, 105.0/, nlri.to_s)
  end
  def test_withdrawns
    nlri = Withdrawn.new
    nlri << '101.0.0.0/8'
    nlri << '102.0.0.0/8'
    nlri << '103.0.0.0/8'
    assert_equal('086508660867', nlri.to_shex)
    assert_match(/102.0/, nlri.to_s)
    assert_match(/103.0/, nlri.to_s)
    nlri1 = Withdrawn.new_ntop nlri.encode[2..-1]
    nlri2 = Nlri.factory nlri.encode[2..-1], 1, 1
    assert_equal(nlri1.to_shex, nlri2.to_shex)

    # 16d403741755c68816d40830
  end

  def test_nlri_factory
    s = '07640766076607680869'
    nlri =  Nlri.factory([s].pack('H*'),1,1)
    s = '0f140010140011140000'
    nlri =  Nlri.factory([s].pack('H*'),1,1)
    assert_equal("20.0.0.0/15\n20.0.0.0/16\n20.0.0.0/17", nlri.to_s)
    assert_equal(s, nlri.to_shex)
  end
  #
  def test_nlri_factory_extended 
    s = '000000650764000000660766000000670766000000680768000000690869'
    nlri =  Nlri.factory([s].pack('H*'),1,1,true)
    assert_match(/ID=102, 102.0/, nlri.to_s)
    assert_match(/ID=104, 104.0/, nlri.to_s)
    assert_match(/ID=105, 105.0/, nlri.to_s)
    assert_equal(s, nlri.to_shex)
  end
end
