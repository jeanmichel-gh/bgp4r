#--
# Copyright 2008, 2009, 2011, 2026 Jean-Michel Esnault.
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

  def test_to_ary_round_trips_with_path_ids
    nlri = Nlri.new([100, '77.0.0.0/17'], '78.0.0.0/8')
    nlri2 = Nlri.new(*nlri.to_ary)
    assert_equal(nlri.to_ary, nlri2.to_ary)
    assert_equal(nlri.to_shex, nlri2.to_shex)
    w = Withdrawn.new([5, '10.0.0.0/8'])
    assert_equal(5, Withdrawn.new(*w.to_ary).nlris[0].path_id)
  end

  def test_empty
    nlri = Nlri.new
    assert(nlri.empty?)
    assert_equal(0, nlri.size)
    assert_equal('', nlri.to_shex)
    nlri << '10.0.0.0/8'
    assert( ! nlri.empty?)
    assert_equal(1, nlri.size)
    assert(Withdrawn.new.empty?)
  end

  def test_an_empty_field_parses_to_an_empty_collection
    # An UPDATE with a zero length Withdrawn Routes field (RFC 4271
    # section 4.3) hands the parser nothing to read.
    w = Withdrawn.new([''].pack('H*'))
    assert(w.empty?)
    assert_equal(0, w.size)
    assert_equal([], w.nlris)
    assert_equal('', w.to_shex)
    assert_equal('0000', w.to_shex(true))
  end

  def test_to_hash_round_trips
    # Each collection names its own key, and what comes out goes back in.
    nlri = Nlri.new('20.0.0.0/15', '20.0.0.0/16', '20.0.0.0/24', '10.1.2.3/32')
    assert_equal({:nlris=>['20.0.0.0/15', '20.0.0.0/16', '20.0.0.0/24', '10.1.2.3/32']},
                 nlri.to_hash)
    assert_equal(nlri.to_shex, Nlri.new(*nlri.to_hash[:nlris]).to_shex)
    w = Withdrawn.new('101.0.0.0/8', '102.0.0.0/8')
    assert_equal({:withdrawns=>['101.0.0.0/8', '102.0.0.0/8']}, w.to_hash)
    assert_equal(w.to_shex, Withdrawn.new(*w.to_hash[:withdrawns]).to_shex)
    # A Path Identifier (RFC 7911 section 3) survives the hash form too.
    ext = Nlri.new([100, '77.0.0.0/17'], '78.0.0.0/8')
    assert_equal({:nlris=>['ID=100, 77.0.0.0/17', '78.0.0.0/8']}, ext.to_hash)
    assert_equal(ext.to_shex, Nlri.new(*ext.to_hash[:nlris]).to_shex)
  end

  def test_prefix_lengths_round_trip_on_and_off_a_byte_boundary
    # RFC 4271 section 4.3: the prefix is padded with trailing bits to the
    # next octet boundary, so a /15 and a /17 take 2 and 3 octets.
    nlri = Nlri.new('0.0.0.0/1', '20.0.0.0/15', '20.0.0.0/16', '20.0.0.0/17', '10.1.2.3/32')
    assert_equal('0100' + '0f1400' + '101400' + '11140000' + '200a010203', nlri.to_shex)
    assert_equal(nlri.to_ary, Nlri.new_ntop(nlri.encode).to_ary)
    assert_equal(nlri.to_shex, Nlri.new_ntop(nlri.encode).to_shex)
  end

  def test_add_rejects_what_it_cannot_read
    # A Hash must carry a Path Identifier, an Array must start with one,
    # and anything else is not a prefix at all.
    assert_raise(RuntimeError) { Nlri.new(:prefix=>'10.0.0.0/8') }
    assert_raise(RuntimeError) { Nlri.new(['10.0.0.0/8']) }
    e = assert_raise(ArgumentError) { Nlri.new(42) }
    assert_match(/Invalid argument Integer 42/, e.message)
    assert_raise(ArgumentError) { Withdrawn.new(:sym) }
  end

  def test_factory_refuses_an_unsupported_safi
    s = ['0865'].pack('H*')
    e = assert_raise(RuntimeError) { Nlri.factory(s, 1, 3) }
    assert_equal('Afi 1 Safi 3 not supported!', e.message)
    e = assert_raise(RuntimeError) { Nlri.factory(['200a010203'].pack('H*'), 2, 77) }
    assert_equal('Afi 2 Safi 77 not supported!', e.message)
  end
end
