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


require 'bgp/path_attributes/aggregator'
require 'test/unit'
class Aggregator_Test < Test::Unit::TestCase
  include BGP
  def test_1
    aggregator = Aggregator.new('10.0.0.1',100)
    aggregator.encode4
    assert_equal(aggregator.encode4, aggregator.encode)
    assert_equal('10.0.0.1, 100', aggregator.aggregator)
    assert_equal('c0070600640a000001', aggregator.to_shex)
    assert_equal('c00708000000640a000001', aggregator.to_shex(true))
    assert_equal(aggregator.to_shex, Aggregator.new(aggregator.encode).to_shex)
    assert_equal("[OTcr]  (7) Aggregator: [c0070600640a000001] '10.0.0.1, 100'", aggregator.to_s)
  end
  def test_2
    aggregator = Aggregator.new('10.0.0.1',100)
    assert_equal('10.0.0.1, 0.100', aggregator.aggregator(true))
    aggregator = Aggregator.new('10.0.0.1',0xdeadbeef)
    assert_equal('10.0.0.1, 57005.48879', aggregator.aggregator(true))
    assert_equal('c00708deadbeef0a000001', aggregator.to_shex(true))
    aggregator = Aggregator.new(aggregator.encode(true),true)
    assert_equal('10.0.0.1, 3735928559', aggregator.aggregator)
    assert_equal(0xdeadbeef, aggregator.as)
  end
  def test3
    ag2 = Aggregator.new('10.0.0.1',100)
    ag4 = As4_aggregator.new('10.0.0.1',100)
    assert_equal('c01208000000640a000001', ag4.to_shex)
    assert_not_equal(ag2.to_shex(true), ag4.to_shex)
    assert_equal('10.0.0.1, 0.100',ag4.aggregator)
    assert_equal("[OTcr] (18) As4 Aggregator: [c01208000000640a00000...] '10.0.0.1, 0.100'",ag4.to_s)
    assert_equal(ag4.to_shex,As4_aggregator.new(ag4.encode).to_shex)
  end
  def test4
    ag2 = Aggregator.new('10.0.0.1',100)
    ag = Aggregator.new(ag2)
    assert_equal(ag2.encode, ag.encode)
    ag4 = As4_aggregator.new('10.0.0.1',100)
    ag = As4_aggregator.new(ag4)
    assert_raise(ArgumentError) {As4_aggregator.new(ag2)}
    assert_equal(ag4.encode, ag.encode)
  end
  def test5
    ag1 = Aggregator.new('10.0.0.1', 100)
    ag2 = Aggregator.new :asn=> 100, :address=> '10.0.0.1'
    assert_equal(ag1.encode,ag2.encode)
    assert_equal({:asn=>100, :address=>"10.0.0.1"}, ag2.to_hash[:aggregator])
  end
  def test6
    ag1 = Aggregator.new('10.0.0.1', 100)
    ag1.asn=200
    ag1.address='11.0.0.2'
    assert_equal(200, ag1.asn)
    assert_equal('11.0.0.2', ag1.address)
    assert_equal({:asn=>200, :address=>"11.0.0.2"}, ag1.to_hash[:aggregator])
  end 
end