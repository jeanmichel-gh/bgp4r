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


require 'test/unit'
require 'bgp4r'

class Attr_raw_Test < Test::Unit::TestCase
  include BGP

  def test_new_from_values
    a = Attr::Raw.new(ATTR::OPTIONAL_TRANSITIVE, 99, "\x01\x02")
    assert_equal('c063020102', a.to_shex)
    assert_equal(0xc, a.flags)
    assert_equal(99, a.type)
    assert_equal("\x01\x02".b, a.value)
  end

  def test_new_from_wire
    s = ['c063020102'].pack('H*')
    a = Attr::Raw.new(s)
    assert_equal('c063020102', a.to_shex)
    assert_equal(99, a.type)
    assert_equal('', s)
  end

  def test_new_from_hash
    a = Attr::Raw.new(:flags=>0xc, :type=>99, :value=>'0102')
    assert_equal('c063020102', a.to_shex)
  end

  def test_to_hash_round_trip
    a = Attr::Raw.new(0x8, 200, "\xff\x00")
    h = {:unknown=>[{:flags=>8, :type=>200, :value=>'ff00'}]}
    assert_equal(h, a.to_hash)
    assert_equal(a.to_shex, Attr::Raw.new(h[:unknown][0]).to_shex)
    # And the whole hash, not just the entry inside it. Unwrapping by
    # hand was working around the bug: new read :flags, :type and :value
    # off the outer hash, found all three nil, and built 000000, a
    # different attribute, with no error at all.
    assert_equal(a.encode, BGP::Attr::Raw.new(a.to_hash).encode)
    u = BGP::Attr::Unknown.new(0xc, 99, 0, 'x')
    assert_equal(u.encode, BGP::Attr::Unknown.new(u.to_hash).encode)
  end

  def test_writes_flags_as_given
    # Any flags, even bogus ones for this type: bgp4r tests bad input.
    assert_equal('f0010000', Attr::Raw.new(0xf, 1, '').to_shex)
    assert_equal('00010178', Attr::Raw.new(0x0, 1, 'x').to_shex)
    # Extended Length bit given with a short value: two octet length.
    assert_equal('50010001' + '78', Attr::Raw.new(0x5, 1, 'x').to_shex)
  end

  def test_long_value_gets_extended_length
    # RFC 4271 section 4.3: a length over 255 needs the Extended Length bit.
    a = Attr::Raw.new(0xc, 99, 'x' * 300)
    assert_equal('d063012c', a.to_shex[0,8])
    assert_equal(304, a.encode.size)
  end

  def test_empty_value
    assert_equal('c06300', Attr::Raw.new(0xc, 99, '').to_shex)
  end

  def test_from_other_attr
    a = Attr::Raw.new(Origin.new(:egp))
    assert_equal('40010101', a.to_shex)
    assert_equal(1, a.type)
  end

  def test_value_kept_as_given_for_known_type
    # An Origin with a two octet value: Raw does not check it.
    assert_equal('4001020102', Attr::Raw.new(0x4, ATTR::ORIGIN, "\x01\x02").to_shex)
  end

  def test_partial
    a = Attr::Raw.new(ATTR::OPTIONAL_TRANSITIVE, 99, "\x01")
    assert_equal(false, a.partial?)
    assert_same(a, a.partial!)
    assert_equal(true, a.partial?)
    assert_equal('e0630101', a.to_shex)
  end

  def test_partial_ignored_when_not_optional_transitive
    a = Attr::Raw.new(ATTR::OPTIONAL_NON_TRANSITIVE, 99, "\x01")
    assert_equal('80630101', a.partial!.to_shex)
    assert_equal(false, a.partial?)
  end

  def test_override
    a = Attr::Raw.new(0xc, 99, "\x01\x02")
    assert_equal('c0630a0102', a.override(length: 10).to_shex)
    assert_equal('c063020102', a.override(length: nil).to_shex)
  end

  def test_bad_args
    assert_raise(ArgumentError) { Attr::Raw.new(1, 2) }
  end

end
