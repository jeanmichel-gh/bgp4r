#--
# Copyright 2026 Jean-Michel Esnault.
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

require "test/unit"
require "bgp4r"

class TestOtc < Test::Unit::TestCase
  include BGP

  def wire(hex) [hex].pack('H*').is_packed end

  # RFC 9234 section 5: type 35, optional transitive, a 4-octet AS number.
  def test_from_values
    o = Otc.new(64512)
    assert_equal 'c023040000fc00', o.to_shex
    assert_equal 64512, o.asn
    assert o.is_optional?
    assert o.is_transitive?
    assert_equal 'c02304fa56ea01', Otc.new(4200000001).to_shex
  end

  def test_bad_values_raise
    [nil, -1, 4294967296, '64512', 1.5].each do |v|
      assert_raise(ArgumentError, v.inspect) { Otc.new(v) }
    end
  end

  def test_from_wire
    o = Otc.new(wire('c023040000fc00'))
    assert_equal 64512, o.asn
    assert_equal 'c023040000fc00', o.to_shex
    assert_instance_of Otc, Attr.factory(wire('c023040000fc00'))
  end

  def test_hash_round_trip
    o = Otc.new(64512)
    assert_equal({:otc => 64512}, o.to_hash)
    assert_equal o.encode, Otc.new(o.to_hash).encode
    pa = Path_attribute.new(:origin => :igp, :otc => 64512)
    assert_equal 64512, pa[:otc].asn
    assert_equal 64512, pa[ATTR::ONLY_TO_CUSTOMER].asn
    assert_equal pa.encode, Path_attribute.new(pa.to_hash).encode
  end

  # RFC 9234 section 5: malformed unless the length is 4, treat-as-withdraw.
  # The octets are kept as received.
  def test_bad_length
    %w{ c0230200fc c02300 c023050000fc0001 }.each do |hex|
      pa = Path_attribute.new(wire(hex))
      assert_equal [[35, 5, :treat_as_withdraw]], pa.errors.collect { |f| [f.type, f.subcode, f.action] }, hex
      assert_equal hex, pa.encode.unpack1('H*'), hex
      assert_nil pa[:otc].asn
    end
    assert_equal [], Path_attribute.new(wire('c023040000fc00')).errors
  end

  def test_flags_are_checked
    pa = Path_attribute.new(wire('80230400 00fc00'.delete(' ')))
    assert_equal [[35, 4, :treat_as_withdraw]], pa.errors.collect { |f| [f.type, f.subcode, f.action] }
  end

  # A test can send what RFC 9234 forbids, such as a length of 2.
  def test_bad_length_can_be_built
    assert_equal 'c0230200fc', Otc.new(wire('c0230200fc')).to_shex
    assert_equal 'c023020000fc00', Otc.new(64512, length: 2).to_shex
  end

  def test_to_s
    assert_equal "[OTcr] (35)        OTC: [c023040000fc00] '64512'", Otc.new(64512).to_s(:brief)
    assert_match(/malformed, 2 octets/, Otc.new(wire('c0230200fc')).to_s(:brief))
  end

end
