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

require 'bgp4r'
# require 'bgp/path_attributes/origin'
require 'test/unit'  
class Origin_Test < Test::Unit::TestCase
  include BGP
  def test_1
    assert_equal("40010100", Origin.new.to_shex)
    assert_equal("40010100", Origin.new(:igp).to_shex)
    assert_equal("40010101", Origin.new(:egp).to_shex)
    assert_equal("40010102", Origin.new(:incomplete).to_shex)
  end
  def test_2
    assert_equal("40010100", Origin.new(0).to_shex)
    assert_equal("40010101", Origin.new(1).to_shex)
    assert_equal("40010102", Origin.new(2).to_shex)
  end
  def test_3
    assert_equal("40010100", Origin.new(:origin =>  0 ).to_shex)
    assert_equal("40010101", Origin.new(:origin =>  1 ).to_shex)
    assert_equal("40010102", Origin.new(:origin =>  2 ).to_shex)
  end
  def test_4
    assert_equal("40010100", Origin.new( Origin.new.encode).to_shex)
  end
  def test_5
    assert_equal("igp", Origin.new.origin)
    assert_equal("igp", Origin.new(:igp).origin)
    assert_equal("egp", Origin.new(:egp).origin)
    assert_equal("incomplete", Origin.new(:incomplete).origin)
  end
  def test_6
    assert_equal("[wTcr]  (1)     Origin: [40010100] 'igp'", Origin.new.to_s)
    assert_equal("[wTcr]  (1)     Origin: [40010100] 'igp'", Origin.new(:igp).to_s)
    assert_equal("Origin (1), length: 1, Flags [T]: igp\n   0x0000:  00", Origin.new.to_s(:tcpdump))
    assert_equal({:origin=>:egp}, Origin.new(:egp).to_hash)
  end
  # The hash carries the word, so new has to translate it the way it
  # already translates a bare Symbol. It assigned the Symbol raw, which
  # left @origin holding one and encode then raised in pack, so the class
  # could not read back its own to_hash.
  def test_to_hash_round_trips
    BGP::Origin::CODES.each_key do |sym|
      o = BGP::Origin.new(sym)
      assert_equal({:origin=>sym}, o.to_hash)
      assert_equal(o.encode, BGP::Origin.new(o.to_hash).encode)
      assert_equal(o.encode, BGP::Path_attribute.new(o.to_hash).encode)
    end
  end
  # RFC 4271 section 5.1.1 defines 0, 1 and 2 only, and to_sym answers
  # :undefined for every other value alike, so the hash carries the code
  # itself rather than a word that cannot be read back. Such a value can
  # only arrive off the wire, and a conformance tool has to be able to
  # send it again.
  def test_an_origin_the_rfc_does_not_define_round_trips
    o = BGP::Origin.new(['40010105'].pack('H*').is_packed)
    assert_equal(:undefined, o.to_sym)
    assert_equal({:origin=>5}, o.to_hash)
    assert_equal('40010105', o.to_shex)
    assert_equal(o.encode, BGP::Origin.new(o.to_hash).encode)
    assert_equal(o.encode, BGP::Path_attribute.new(o.to_hash).encode)
  end
  # Conventions: a constructor refuses only what it cannot represent.
  # The value is one octet, so every octet builds, and 256 does not.
  def test_any_octet_builds_and_more_does_not
    assert_equal('40010105', BGP::Origin.new(5).to_shex)
    assert_equal('400101ff', BGP::Origin.new(255).to_shex)
    assert_raise(ArgumentError) { BGP::Origin.new(256) }
  end
end
