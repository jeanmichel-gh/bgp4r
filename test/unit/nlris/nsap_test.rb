#--
# Copyright 2011 Jean-Michel Esnault.
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

require 'bgp/nlris/nsap'

require 'test/unit'

class Nsap_Test < Test::Unit::TestCase
  include BGP
  def test_new
    nsap = Nsap.new
    assert_equal(   '49.0000.0000.0000.0000.0000.0000.0000.0000.0000.00', nsap.to_s)
    assert_equal('4900000000000000000000000000000000000000', nsap.to_shex)

    nsap = Nsap.new('49.0102.0304.0506.0608.0910.1112.1314.1516.1718.bb/160')
    assert_equal('49.0102.0304.0506.0608.0910.1112.1314.1516.1718.bb', nsap.to_s)
    assert_equal('49010203040506060809101112131415161718bb', nsap.to_shex)

    nsap = Nsap.new('49.0102.0304.0506.0608.0910.1112.1314.1516.1718.00/152')
    assert_equal('49.0102.0304.0506.0608.0910.1112.1314.1516.1718.00', nsap.to_s)
    assert_equal('49010203040506060809101112131415161718', nsap.to_shex)

    nsap = Nsap.new('49.0102.0304.0506.0608.0910.1112.1314.1516.1718.00/96')
    assert_equal('49.0102.0304.0506.0608.0910.1100.0000.0000.0000.00', nsap.to_s)
    nsap = Nsap.new('49.0102.0304.0506.0608.0910.1112.1314.1516.1718.00/48')
    assert_equal('49.0102.0304.0500.0000.0000.0000.0000.0000.0000.00', nsap.to_s)
    nsap = Nsap.new('49.0102.0304.0506.0608.0910.1112.1314.1516.1718.00/24')
    assert_equal('490102', nsap.to_shex)
    assert_equal('49.0102.0000.0000.0000.0000.0000.0000.0000.0000.00', nsap.to_s)
    nsap = Nsap.new('49.0102.0304.0506.0608.0910.1112.1314.1516.1718.00/16')
    assert_equal('49.0100.0000.0000.0000.0000.0000.0000.0000.0000.00', nsap.to_s)
    
  end

  def test_new_ntoh
    nsap = Nsap.new_ntoh(Nsap.new.encode)
    assert_equal('49.0000.0000.0000.0000.0000.0000.0000.0000.0000.00', nsap.to_s)
    assert_equal('4900000000000000000000000000000000000000', nsap.to_shex)
    nsap = Nsap.new_ntoh(Nsap.new('49.0102.0304.0506.0608.0910.1112.1314.1516.1718.bb').encode)
    assert_equal('49.0102.0304.0506.0608.0910.1112.1314.1516.1718.bb', nsap.to_s)
    assert_equal('49010203040506060809101112131415161718bb', nsap.to_shex)
  end
  
  def test_new_nsap
    nsap = Nsap.new_nsap('49.0102.0304.0506.0608.0910.1112.1314.1516.1718.ff')
    assert_equal('49.0102.0304.0506.0608.0910.1112.1314.1516.1718.00', nsap.to_s)
    assert_equal(152, nsap.mlen)
    nsap = Nsap.new_nsap('49.0102.0304.0506.0608.0910.1112.1314.1516.1718.ff/160')
    assert_equal('49.0102.0304.0506.0608.0910.1112.1314.1516.1718.00', nsap.to_s)
    assert_equal(152, nsap.mlen)
  end
  
  def test_iso_ip_mapped
    addr = Iso_ip_mapped.new('10.0.0.1')
    assert_equal('470006010a00000100', addr.to_shex)
    assert_equal('10.0.0.1', addr.to_s)
    addr = Iso_ip_mapped.new('2011:13:11::64')
    assert_equal('3500002011001300110000000000000000006400', addr.to_shex)
    assert_equal('2011:13:11::64', addr.to_s)
  end  
end
