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

require 'bgp/nlris/rd'

require 'test/unit'
class Rd_Test < Test::Unit::TestCase
  include BGP
  def test_1
    assert_equal('RD=1:1 (0x01 0x0001)',Rd.new(1,1).to_s)
    assert_equal('0000000100000001',Rd.new(1,1).to_shex)
    assert_equal('RD=1.1.1.1:1 (0x1010101 0x01)',Rd.new('1.1.1.1',1).to_s)
    assert_equal('0001010101010001',Rd.new('1.1.1.1',1).to_shex)
    assert_equal('RD=1:16843009 (0x0001 0x1010101)', Rd.new(1,'1.1.1.1').to_s)
    assert_equal('0002000000010101', Rd.new(1,'1.1.1.1').to_shex)
    assert_equal('RD=1:1 (0x01 0x0001)',Rd.new(1,1,0).to_s)
    assert_equal('RD=1:1 (0x0001 0x01)',Rd.new(1,1,2).to_s)
    assert_equal('RD=1:1 (0x01 0x0001)',Rd.new(:rd=>[1,1]).to_s)
    assert_equal({:rd=>[1,1]},Rd.new(:rd=>[1,1]).to_hash)
  end
  def test_2
    assert_equal('0000000100000001', Rd.new(['0000000100000001'].pack('H*')).to_shex)
    assert_equal('0001010101010001', Rd.new(['0001010101010001'].pack('H*')).to_shex)
    assert_equal('0002000000010101', Rd.new(['0002000000010101'].pack('H*')).to_shex)
  end
end
