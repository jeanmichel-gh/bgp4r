#--
# Copyright 2008, 2009, 2026 Jean-Michel Esnault.
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

require 'bgp/path_attributes/cluster_list'
require 'bgp/path_attributes/path_attribute'
require 'test/unit'
class Cluster_list_Test < Test::Unit::TestCase
  include BGP
  def wire(hex) [hex].pack('H*').is_packed end
  def findings(hex)
    Path_attribute.new(wire(hex)).errors.collect { |f| [f.type, f.subcode, f.action, f.reason] }
  end
  def test_1
    clist1 = Cluster_list.new('192.168.0.1','10.0.0.1')
    clist2 = Cluster_list.new('192.168.0.1 10.0.0.1')
    assert_equal('800a08c0a800010a000001', clist1.to_shex)
    assert_equal(clist1.to_shex, clist2.to_shex)
    assert_equal('192.168.0.1 10.0.0.1',clist1.cluster_list)
    assert_equal("[Oncr] (10) Cluster List: [800a08c0a800010a00000...] '192.168.0.1 10.0.0.1'", clist1.to_s)
    clist3 = Cluster_list.new(['800a08c0a800010a000001'].pack('H*'))
    assert_equal(clist1.encode, clist3.encode)
    clist4 = Cluster_list.new(clist3)
    assert_equal(clist3.encode, clist4.encode)
  end
  def test_2
    cids = ['1.1.1.1', '2.2.2.2', '3.3.3.3']
    clist1 = Cluster_list.new :cluster_list=> cids
    assert_equal( cids, clist1.to_hash[:cluster_list])
  end
  def test_cluster_ids
    assert_equal(['1.1.1.1', '2.2.2.2'], Cluster_list.new('1.1.1.1', '2.2.2.2').cluster_ids)
    cl = Cluster_list.new(Cluster_list.new('1.1.1.1', '2.2.2.2').encode)
    assert_equal(['1.1.1.1', '2.2.2.2'], cl.cluster_ids)
  end

  # RFC 4456 section 8: a CLUSTER_ID is 4 octets. Octets past the last
  # whole one are kept, so encode gives back what was received, length
  # field included.
  def test_a_tail_is_kept
    { '800a050101010102'         => ['1.1.1.1'],
      '800a060101010102ff'       => ['1.1.1.1'],
      '800a070101010102ff00'     => ['1.1.1.1'],
      '800a090101010102020202ff' => ['1.1.1.1', '2.2.2.2'],
    }.each do |hex, ids|
      cl = Cluster_list.new(wire(hex))
      assert_equal(hex, cl.to_shex, hex)
      assert_equal(ids, cl.cluster_ids, hex)
      assert_equal(hex, Cluster_list.new(cl).to_shex, hex)
      assert_equal(hex, Path_attribute.new(wire(hex)).to_shex, hex)
    end
  end

  # A tail with no whole CLUSTER_ID at all.
  def test_a_tail_alone_is_kept
    cl = Cluster_list.new(wire('800a02ffff'))
    assert_equal('800a02ffff', cl.to_shex)
    assert_equal([], cl.cluster_ids)
  end

  # RFC 7606 section 7.10: a length that is not a non-zero multiple of 4
  # is malformed, treat-as-withdraw. Keeping the octets does not change
  # what Path_attribute#errors reports.
  def test_findings_are_unchanged
    [['800a050101010102', 5], ['800a060101010102ff', 6], ['800a070101010102ff00', 7],
     ['800a02ffff', 2], ['800a090202020201010101ff', 9]].each do |hex, len|
      assert_equal([[10, 5, :treat_as_withdraw,
                     "length #{len}, must be a non-zero multiple of 4 (RFC 7606 section 7.10)"]],
                   findings(hex), hex)
    end
  end

  # A well formed attribute is unaffected.
  def test_a_well_formed_attribute_is_unaffected
    hex = '800a08c0a800010a000001'
    cl = Cluster_list.new(wire(hex))
    assert_equal(hex, cl.to_shex)
    assert_equal(['192.168.0.1', '10.0.0.1'], cl.cluster_ids)
    assert_equal([], findings(hex))
    assert_equal([], findings('800a0401010101'))
  end

  # sort and to_hash used to drop the kept octets, so a malformed
  # attribute came back byte for byte through encode but not through a
  # hash. The tail travels as a {:tail=>hex} entry at the end of the
  # list, which new takes back.
  def test_sort_and_to_hash_keep_a_tail
    { '800a050101010102'         => ['1.1.1.1', {:tail=>'02'}],
      '800a090202020201010101ff' => ['2.2.2.2', '1.1.1.1', {:tail=>'ff'}],
      '800a02ffff'               => [{:tail=>'ffff'}],
    }.each do |hex, list|
      cl = Cluster_list.new(wire(hex))
      assert_equal({:cluster_list=>list}, cl.to_hash, hex)
      assert_equal(hex, Cluster_list.new(cl.to_hash).to_shex, hex)
      assert_equal(cl.to_hash, Cluster_list.new(cl.to_hash).to_hash, hex)
      assert_equal(hex, Path_attribute.new(Path_attribute.new(wire(hex)).to_hash).to_shex, hex)
      # sort and sort! change the order of the ids, never the tail.
      assert_equal(hex.size, cl.sort.to_shex.size, hex)
      assert_equal(hex.size, Cluster_list.new(wire(hex)).sort!.to_shex.size, hex)
    end
    cl = Cluster_list.new(wire('800a090202020201010101ff'))
    assert_equal('800a090101010102020202ff', cl.sort.to_shex)
    assert_equal(['1.1.1.1', '2.2.2.2', {:tail=>'ff'}], cl.sort.to_hash[:cluster_list])
    assert_equal('800a090101010102020202ff', cl.sort!.to_shex)
    cl = Cluster_list.new(wire('800a02ffff'))
    assert_equal('800a02ffff', cl.sort.to_shex)
    assert_equal('800a02ffff', cl.sort!.to_shex)
  end

  # The hash of a well formed attribute is the plain list it was.
  def test_a_well_formed_hash_is_unchanged
    cl = Cluster_list.new('2.2.2.2', '1.1.1.1')
    assert_nil(cl.tail)
    assert_equal({:cluster_list=>['2.2.2.2', '1.1.1.1']}, cl.to_hash)
    assert_equal({:cluster_list=>['1.1.1.1', '2.2.2.2']}, cl.sort.to_hash)
    assert_equal({:cluster_list=>['1.1.1.1', '2.2.2.2']}, cl.sort!.to_hash)
    assert_equal(cl.encode, Cluster_list.new(cl.to_hash).encode)
  end
  # An Integer address is packed into four octets, so one that does not fit
  # is refused by IPAddr.create rather than truncated. It used to come back
  # as a different address: the low 32 bits only.
  def test_an_integer_that_does_not_fit_is_refused
    assert_raise(ArgumentError) { BGP::Cluster_list.new(2**32) }
    assert_raise(ArgumentError) { BGP::Cluster_list.new(0x01010101, -1) }
    assert_equal('800a0401010101', BGP::Cluster_list.new(0x01010101).to_shex)
  end

end
