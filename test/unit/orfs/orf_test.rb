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


require 'bgp4r'
require 'bgp/orfs/orf'
require 'test/unit'

class Orf_Test < Test::Unit::TestCase
  include BGP

  # BGP::Orf and BGP::ORF are written out in full here on purpose.
  # test/unit/neighbor/neighbor_test.rb includes BGP::OPT_PARM::CAP into
  # Object, which puts a second Orf in the chain, and it is loaded before
  # this file by test/run_unit.rb. A bare Orf then means the capability in
  # the whole suite and this class in one file, which is worse than long
  # names. Prefix_orf and Prefix_entry have no namesake, so they stay short.

  # RFC 5291 section 4: an ORF is an ORF Type (1 octet), a Length of ORF
  # entries (2 octets) and that many octets of entries. Orf reads that much
  # without knowing the type, and keeps the entry octets.
  def test_orf_is_built_from_wire_bytes
    wire = ['410002aabb'].pack('H*')
    orf = BGP::Orf.new(wire)
    assert_equal(0x41, orf.type)
    assert_equal('aabb', orf.value.unpack('H*')[0])
    assert_equal('410002aabb', orf.to_shex)
    # the octets it read are consumed, so the next ORF in a field is next
    assert_equal(0, wire.size)
  end

  # An ORF built from another one copies it through its own octets.
  def test_orf_is_built_from_another_orf
    orf = BGP::Orf.new(['410002aabb'].pack('H*'))
    assert_equal(orf.to_shex, BGP::Orf.new(orf).to_shex)
    assert_equal('aabb', BGP::Orf.new(orf).value.unpack('H*')[0])
  end

  # An ORF carries ORF entries. Something that is not one at all has no field
  # to go in, so it is refused rather than dropped to no effect.
  def test_orf_add_refuses_anything_that_is_not_an_entry
    orf = BGP::Orf.new(BGP::ORF::PREFIX)
    err = assert_raise(ArgumentError) { orf.add('not an entry') }
    assert_equal('invalid argument: "not an entry", expected an ORF entry', err.message)
    assert_raise(ArgumentError) { orf << 42 }
    assert_raise(ArgumentError) { orf << nil }
    assert_equal(0, orf.entries.size)
    assert_raise(ArgumentError) { BGP::Orf.new(BGP::ORF::PREFIX, 'not an entry') }
  end

  # RFC 5291 section 4 for the layout, and section 7 leaves the ORF-Type
  # values 128 through 255 to vendors, so an ORF with no class of its own is
  # a thing that arrives. Its octets are kept and written back.
  def test_unknown_orf_three_build_paths
    wire = ['410002aabb'].pack('H*')
    from_wire = BGP::Orf::Unknown.new(wire.dup.is_packed)
    from_values = BGP::Orf::Unknown.new(0x41, ['aabb'].pack('H*'))
    from_hash = BGP::Orf::Unknown.new(:type=>0x41, :value=>'aabb')
    [from_wire, from_values, from_hash].each do |orf|
      assert_equal('410002aabb', orf.to_shex)
      assert_equal(0x41, orf.type)
      assert_equal('aabb', orf.value.unpack('H*')[0])
      assert_equal({:type=>0x41, :value=>'aabb'}, orf.to_hash)
    end
    # and from another one of its own
    assert_equal('410002aabb', BGP::Orf::Unknown.new(from_wire).to_shex)
  end

  def test_unknown_orf_to_s_and_an_empty_value
    orf = BGP::Orf::Unknown.new(0x41, ['aabb'].pack('H*'))
    assert_equal('BGP::Orf::Unknown, ORF type 65, 2 entry octets: [aabb]', orf.to_s)
    empty = BGP::Orf::Unknown.new(0x41)
    assert_equal('410000', empty.to_shex)
    assert_equal({:type=>0x41}, empty.to_hash)
    assert_equal('BGP::Orf::Unknown, ORF type 65, 0 entry octets: []', empty.to_s)
    assert_equal('410000', BGP::Orf::Unknown.new(empty.to_hash).to_shex)
  end

  # Building and encoding are never validated. Any ORF Type, any length, any
  # octets, including the types RFC 5291 section 7 reserves and the vendor
  # range it does not assign.
  def test_unknown_orf_encodes_any_type_and_any_octets
    assert_equal('000000', BGP::Orf::Unknown.new(0).to_shex)
    assert_equal('ff0001ff', BGP::Orf::Unknown.new(0xff, ["\xff"].pack('a*')).to_shex)
    long = BGP::Orf::Unknown.new(0x7f, 'a' * 0x10000)
    assert_equal(0x10000, long.value.size)
    # the Length of ORF entries field is two octets, so encode truncates it
    # rather than refusing the octets. Nothing is checked on the way out.
    assert_equal('7f0000', long.to_shex[0,6])
  end

  def test_unknown_orf_refuses_an_argument_it_cannot_read
    err = assert_raise(ArgumentError) { BGP::Orf::Unknown.new('not packed') }
    assert_match(/expected \(type, value\), wire bytes or a hash/, err.message)
    assert_raise(ArgumentError) { BGP::Orf::Unknown.new }
  end

  # RFC 5291 section 4: the ORF Type picks the class, on the wire and in the
  # hash form alike.
  def test_factory_and_from_hash_dispatch_on_the_orf_type
    prefix = ['400009000000000a0000080a'].pack('H*')
    assert_equal(Prefix_orf, BGP::Orf.factory(prefix.dup.is_packed).class)
    cisco = ['820009000000000a0000080a'].pack('H*')
    assert_equal(Prefix_orf, BGP::Orf.factory(cisco.dup.is_packed).class)
    assert_equal(BGP::ORF::PREFIX_CISCO, BGP::Orf.factory(cisco.dup.is_packed).type)
    assert_equal(BGP::Orf::Unknown, BGP::Orf.factory(['410002aabb'].pack('H*').is_packed).class)
    assert_equal(Prefix_orf, BGP::Orf.from_hash({}).class)
    assert_equal(Prefix_orf, BGP::Orf.from_hash(:type=>BGP::ORF::PREFIX).class)
    assert_equal(Prefix_orf, BGP::Orf.from_hash(:type=>BGP::ORF::PREFIX_CISCO).class)
    assert_equal(BGP::Orf::Unknown, BGP::Orf.from_hash(:type=>0x41, :value=>'aabb').class)
  end

  # RFC 5291 section 7: "ORF-Type values 128 through 255 are vendor-specific,
  # and values in this range are not to be assigned by IANA." 130 is the
  # vendor code point bgp4r sends for a Cisco style prefix ORF; no RFC
  # describes it. RFC 5292 section 3 assigns 64 to the Address Prefix ORF.
  def test_the_orf_type_constants
    assert_equal(64, BGP::ORF::PREFIX)
    assert_equal(130, BGP::ORF::PREFIX_CISCO)
  end

end
