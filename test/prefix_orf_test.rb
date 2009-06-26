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

require 'bgp/prefix_orf'
require 'test/unit'
class Prefix_orf_Test < Test::Unit::TestCase
  include BGP
  def test_1
    assert_equal('000000000a0000080a', Prefix_entry.new(0,0,10,0,0,'10.0.0.0/8').to_shex)
    assert_equal('seq  10    add 10.0.0.0/8 permit', Prefix_entry.new(0,0,10,0,0,'10.0.0.0/8').to_s)
    assert_equal('seq  10    add 10.0.0.0/8 permit', Prefix_entry.add(0,10,0,0,'10.0.0.0/8').to_s)
    assert_equal('seq  10    add 10.0.0.0/8 permit', Prefix_entry.add_and_permit(10,0,0,'10.0.0.0/8').to_s)
    assert_equal('seq  10    add 10.0.0.0/8 permit', Prefix_entry.add_and_permit(10,'10.0.0.0/8').to_s)
    assert_equal('400000000a0000080a', Prefix_entry.new(1,0,10,0,0,'10.0.0.0/8').to_shex)
    assert_equal('seq  10 remove 10.0.0.0/8 permit', Prefix_entry.new(1,0,10,0,0,'10.0.0.0/8').to_s)
    assert_equal('600000000a0000080a', Prefix_entry.new(1,1,10,0,0,'10.0.0.0/8').to_shex)
    assert_equal('seq  10 remove 10.0.0.0/8 deny', Prefix_entry.new(1,1,10,0,0,'10.0.0.0/8').to_s)
    assert_equal('600000000a0000080a', Prefix_entry.new(1,1,10,0,0,'10.0.0.0/8').to_shex)
    assert_equal('seq  10 remove 10.0.0.0/8 deny', Prefix_entry.new(1,1,10,0,0,'10.0.0.0/8').to_s)
    assert_equal('seq  10 remove 10.0.0.0/8 deny', Prefix_entry.remove(1,10,0,0,'10.0.0.0/8').to_s)
    assert_equal('seq  10 remove 10.0.0.0/8 deny', Prefix_entry.remove_and_deny(10,0,0,'10.0.0.0/8').to_s)
    assert_equal('seq  10 remove 10.0.0.0/8 deny', Prefix_entry.remove_and_deny(10,'10.0.0.0/8').to_s)
    assert_equal('000000000a0000080a', Prefix_entry.new( Prefix_entry.new(0,0,10,0,0,'10.0.0.0/8').encode).to_shex)
    assert_equal(Prefix_entry, Prefix_entry.new( Prefix_entry.new(0,0,10,0,0,'10.0.0.0/8').encode).class)    
  end
  
  def test_2

    orf = Prefix_orf.new([
      Prefix_entry.add_and_permit(10,'10.0.0.0/8'),
      Prefix_entry.add_and_permit(20,'20.0.0.0/8'),
      Prefix_entry.add_and_permit(30,'30.0.0.0/8'),
      Prefix_entry.add_and_permit(40,'40.0.0.0/8'),
      Prefix_entry.add_and_permit(50,'50.0.0.0/8'),
    ])
        
    assert_equal(5,orf.entries.size)
    assert_equal('40002d000000000a0000080a000000001400000814000000001e0000081e000000002800000828000000003200000832', orf.to_shex)
    assert_equal(orf.encode, Prefix_orf.new(orf.encode).encode)
    assert_equal(orf.encode, Prefix_orf.new(orf).encode)
    
    orf1 = Prefix_orf.new
    orf1 << Prefix_entry.add_and_permit(10,'10.0.0.0/8')
    orf1 << Prefix_entry.add_and_permit(20,'20.0.0.0/8')
    orf1 << Prefix_entry.add_and_permit(30,'30.0.0.0/8')
    orf1 << Prefix_entry.add_and_permit(40,'40.0.0.0/8')
    orf1 << Prefix_entry.add_and_permit(50,'50.0.0.0/8')
    
    assert_equal(orf1.encode, orf.encode)

    orf2 = Prefix_orf.new([
      Prefix_entry.add_and_deny(1, '35.0.0.0/8'),
      Prefix_entry.add_and_permit(2,'2.2.2.2/32')])   
    assert_equal('400015200000000100000823000000000200002002020202', orf2.to_shex)
    orf2.cisco_prefix_entry_type
    assert_equal('820015200000000100000823000000000200002002020202', orf2.to_shex)

    assert_equal(orf2.encode, Prefix_orf.new(orf2.encode).encode)

  end
  
  def test_3
    orf = Prefix_orf.new([
      Prefix_entry.add_and_permit(10,'10.0.0.0/8'),
      Prefix_entry.add_and_permit(20,'20.0.0.0/8'),
      Prefix_entry.add_and_permit(30,'30.0.0.0/8'),
      Prefix_entry.add_and_permit(40,'40.0.0.0/8'),
      Prefix_entry.add_and_permit(50,'50.0.0.0/8'),
    ])
    assert_match(/BGP::Prefix_orf, 5 entries/, orf.to_s)
    assert_match(/\n  seq  10    add 10.0.0.0\/8 permit/, orf.to_s)
    assert_match(/\n  seq  20    add 20.0.0.0\/8 permit/, orf.to_s)
    assert_match(/\n  seq  30    add 30.0.0.0\/8 permit/, orf.to_s)
    assert_match(/\n  seq  40    add 40.0.0.0\/8 permit/, orf.to_s)
    assert_match(/\n  seq  50    add 50.0.0.0\/8 permit/, orf.to_s)
  end
  
end
