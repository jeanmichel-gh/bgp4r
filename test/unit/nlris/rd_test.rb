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

require 'bgp/nlris/rd'

require 'test/unit'
require 'stringio'
class Rd_Test < Test::Unit::TestCase
  include BGP
  def test_1
    assert_equal('RD=1:1 (0x01 0x0001)',Rd.new(1,1).to_s)
    assert_equal('0000000100000001',Rd.new(1,1).to_shex)
    assert_equal('RD=1.1.1.1:1 (0x1010101 0x01)',Rd.new('1.1.1.1',1).to_s)
    assert_equal('0001010101010001',Rd.new('1.1.1.1',1).to_shex)
    assert_equal('RD=1:257 (0x0001 0x101)', Rd.new(1,257,2).to_s)
    assert_equal('0002000000010101', Rd.new(1,257,2).to_shex)
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
  # RFC 4364 section 4.2 type 1: a 4 octet IPv4 administrator and a
  # 2 octet assigned number. The three argument form names the type.
  def test_type_1_with_an_explicit_encoding_type
    rd = Rd.new('10.0.0.1', 65535, 1)
    assert_equal 1, rd.encoding_type?
    assert_equal '10.0.0.1', rd.admin.to_s
    assert_equal 65535, rd.assign
    assert_equal '00010a000001ffff', rd.to_shex
    assert_equal 'RD=10.0.0.1:65535', rd.to_s(false)
    assert_equal({:rd=>['10.0.0.1', 65535]}, rd.to_hash)
    assert_equal rd.to_shex, Rd.new(rd.encode).to_shex
  end
  def test_explicit_encoding_types_match_the_inferred_ones
    assert_equal Rd.new(1, 1).to_shex, Rd.new(1, 1, 0).to_shex
    assert_equal Rd.new('1.1.1.1', 1).to_shex, Rd.new('1.1.1.1', 1, 1).to_shex
    assert_equal 0, Rd.new(1, 1).encoding_type?
    assert_equal 1, Rd.new('1.1.1.1', 1).encoding_type?
    # The two argument form no longer reads a String assigned number as an
    # inferred type 2, so type 2 is named: see the refusal test below.
    assert_equal 2, Rd.new(1, 257, 2).encoding_type?
    assert_equal 0, Rd.new.encoding_type?
  end
  def test_built_from_another_rd
    # Rd.new(Rd) goes through encode and parse, so the copy is byte for
    # byte what the original puts on the wire.
    [Rd.new(1, 1), Rd.new('1.1.1.1', 1), Rd.new(65536, 1, 2), Rd.new].each do |rd|
      copy = Rd.new(rd)
      assert_equal rd.to_shex, copy.to_shex
      assert_equal rd.encoding_type?, copy.encoding_type?
      assert_equal rd.to_s(false), copy.to_s(false)
      assert_equal rd.to_hash, copy.to_hash
    end
  end
  def test_terse_to_s
    assert_equal 'RD=1:1', Rd.new(1, 1).to_s(false)
    assert_equal 'RD=1.1.1.1:1', Rd.new('1.1.1.1', 1).to_s(false)
    assert_equal 'RD=1:1', Rd.new(1, 1, 2).to_s(false)
    assert_equal 'RD=65536:1', Rd.new(65536, 1, 2).to_s(false)
  end
  def test_zero_rd
    # The all zero RD, which an MP_REACH next hop carries ahead of the
    # address (RFC 4364 section 4.3.2).
    rd = Rd.new
    assert_equal '0000000000000000', rd.to_shex
    assert_equal({:rd=>[0, 0]}, rd.to_hash)
    assert_equal 'RD=0:0', rd.to_s(false)
    assert_equal 64, rd.bit_length
  end
  # RFC 4364 section 4.2 gives encoding type 0 a 2 octet administrator and a
  # 4 octet assigned number. The verbose form used to print the assigned
  # number in both places, so the administrator never showed.
  def test_type_0_verbose_to_s_prints_its_administrator
    assert_equal 'RD=7:9 (0x07 0x0009)', Rd.new(7, 9).to_s
    assert_equal 'RD=65535:65536 (0xffff 0x10000)', Rd.new(65535, 65536).to_s
  end
  # One line per encoding type, each printing its own two fields.
  def test_verbose_to_s_prints_each_types_own_fields
    assert_equal 'RD=7:9 (0x07 0x0009)', Rd.new(7, 9, 0).to_s
    assert_equal 'RD=1.1.1.1:9 (0x1010101 0x09)', Rd.new('1.1.1.1', 9, 1).to_s
    assert_equal 'RD=7:9 (0x0007 0x09)', Rd.new(7, 9, 2).to_s
  end
  # RFC 4364 section 4.2 gives encoding types 1 and 2 a 2 octet assigned
  # number, so a 32 bit address cannot go there. The constructor says so,
  # naming the field, instead of keeping a value its own encode cannot pack.
  def test_an_address_is_refused_as_an_assigned_number
    e = assert_raise(ArgumentError) { Rd.new(1, '1.1.1.1') }
    assert_match(/1\.1\.1\.1/, e.message)
    assert_match(/RFC 4364/, e.message)
  end
  # Refusing the String leaves every octet level route open.
  def test_a_type_2_assigned_number_can_still_be_built_and_agrees_with_its_bytes
    assert_equal '0002000000010101', Rd.new(1, 257, 2).to_shex
    wire = ['0002000000010101'].pack('H*')
    assert_equal '0002000000010101', Rd.new(wire).to_shex
    assert_equal 'RD=1:257', Rd.new(wire).to_s(false)
    rd = Rd.new(1, 257, 2)
    assert_equal rd.to_s(false), Rd.new(rd.encode).to_s(false)
  end
  # This test used to pin a bug: an encoding type RFC 4364 section 4.2 does
  # not define was refused by parse, so octets that arrived could not be read
  # back. They are kept now. The quiet part is what it always was: nothing is
  # printed.
  def test_unknown_type_parses_quietly
    out, $stdout = $stdout, StringIO.new
    rd = Rd.new(['0003000000010001'].pack('H*'))
    assert_equal '0003000000010001', rd.to_shex
    assert_equal('', $stdout.string)
  ensure
    $stdout = out
  end
  # RFC 4364 section 4.2 gives encoding type 2 a 4 octet administrator, and
  # type 0 a 2 octet one. The two values of the hash form cannot say which
  # type they came from, so to_hash carries the type when a build from the
  # two values would infer a different one.
  def test_to_hash_carries_the_encoding_type_when_the_values_cannot_say_it
    rd = Rd.new(1, 257, 2)
    assert_equal({:rd=>[1, 257, 2]}, rd.to_hash)
    assert_equal '0002000000010101', Rd.new(rd.to_hash).to_shex
    assert_equal 2, Rd.new(rd.to_hash).encoding_type?
  end
  # A type 2 RD whose administrator is above 65535 is what the two argument
  # form infers, so its hash stays the plain two element one.
  def test_to_hash_leaves_out_an_encoding_type_the_values_give_back
    rd = Rd.new(65536, 1, 2)
    assert_equal({:rd=>[65536, 1]}, rd.to_hash)
    assert_equal '0002000100000001', rd.to_shex
    assert_equal rd.to_shex, Rd.new(rd.to_hash).to_shex
  end
  # The hash of an ordinary RD does not change: types 0 and 1 are exactly
  # what the two values infer.
  def test_the_hash_of_a_type_0_or_type_1_rd_is_the_plain_two_element_one
    assert_equal({:rd=>[1, 1]}, Rd.new(1, 1).to_hash)
    assert_equal({:rd=>[1, 1]}, Rd.new(1, 1, 0).to_hash)
    assert_equal({:rd=>['1.1.1.1', 1]}, Rd.new('1.1.1.1', 1).to_hash)
    assert_equal({:rd=>['1.1.1.1', 1]}, Rd.new('1.1.1.1', 1, 1).to_hash)
    assert_equal({:rd=>[0, 0]}, Rd.new.to_hash)
  end
  # Every RD round trips through its own hash form, whatever its type.
  def test_every_encoding_type_round_trips_through_its_hash
    [Rd.new, Rd.new(1, 1), Rd.new('1.1.1.1', 1), Rd.new(1, 257, 2),
     Rd.new(65536, 1, 2), Rd.new(1, 1, 3), Rd.new(1, 1, 65535)].each do |rd|
      copy = Rd.new(rd.to_hash)
      assert_equal rd.to_shex, copy.to_shex
      assert_equal rd.encoding_type?, copy.encoding_type?
      assert_equal rd.to_hash, copy.to_hash
    end
  end
  # The hash form of an RD is one key, so Vpn#to_hash and Labeled#to_hash can
  # go on merging it into their own, and mp_reach's splat of n[:rd] reaches
  # the three argument form.
  def test_the_hash_form_stays_one_key_and_splats_back
    rd = Rd.new(1, 257, 2)
    assert_equal [:rd], rd.to_hash.keys
    assert_equal rd.to_shex, Rd.new(*rd.to_hash[:rd]).to_shex
  end
  # RFC 4364 section 4.2 makes the type 0 administrator a 2 octet AS and the
  # type 2 one a 4 octet AS, so an AS above 65535 is what type 2 is for. The
  # two argument form infers it rather than keep a value encode truncates.
  def test_an_administrator_above_65535_infers_encoding_type_2
    rd = Rd.new(65536, 1)
    assert_equal 2, rd.encoding_type?
    assert_equal 65536, rd.admin
    assert_equal '0002000100000001', rd.to_shex
    assert_equal 'RD=65536:1', rd.to_s(false)
    # The object and its own bytes say the same thing.
    assert_equal rd.to_s(false), Rd.new(rd.encode).to_s(false)
    assert_equal rd.to_shex, Rd.new(rd.encode).to_shex
    assert_equal 0, Rd.new(65535, 1).encoding_type?
    assert_equal 2, Rd.new(4294967295, 1).encoding_type?
  end
  # Where the type is named, the administrator has to fit the field that type
  # gives it. 65536 cannot be represented in 2 octets at all, so it is
  # refused rather than truncated by encode.
  def test_an_administrator_too_wide_for_the_named_type_is_refused
    e = assert_raise(ArgumentError) { Rd.new(65536, 1, 0) }
    assert_match(/65536/, e.message)
    assert_match(/RFC 4364/, e.message)
    assert_raise(ArgumentError) { Rd.new(4294967296, 1, 2) }
    assert_raise(ArgumentError) { Rd.new(4294967296, 1) }
    # And the assigned number, 2 octets in types 1 and 2.
    assert_raise(ArgumentError) { Rd.new(1, 65536, 2) }
    assert_raise(ArgumentError) { Rd.new('1.1.1.1', 65536) }
    assert_raise(ArgumentError) { Rd.new(1, 4294967296) }
    # A 2 octet type field.
    assert_raise(ArgumentError) { Rd.new(1, 1, 65536) }
    # The octet level route stays open.
    assert_equal '0000000100000001', Rd.new(['0000000100000001'].pack('H*')).to_shex
  end
  # Anything that fits still goes to the wire as given.
  def test_a_value_that_fits_its_field_is_never_checked
    assert_equal '0000ffffffffffff', Rd.new(65535, 4294967295).to_shex
    assert_equal '0002ffffffffffff', Rd.new(4294967295, 65535, 2).to_shex
    assert_equal '0001ffffffffffff', Rd.new('255.255.255.255', 65535).to_shex
  end
  # The three fields encode packs as numbers refuse what is not one. Each of
  # these used to build and then take encode down with a TypeError out of
  # Array#pack, "no implicit conversion of String into Integer", which named
  # neither the RD nor the field.
  def test_a_field_that_holds_a_number_refuses_what_encode_cannot_pack
    # The administrator of every encoding type but 1: an address String is
    # the one the three argument form invited, since the two argument form
    # reads the same String as a type 1 address.
    [0, 2, 7].each do |enc_type|
      e = assert_raise(ArgumentError) { Rd.new('1.1.1.1', 1, enc_type) }
      assert_match(/administrator/, e.message)
      assert_match(/1\.1\.1\.1/, e.message)
      assert_match(/RFC 4364/, e.message)
      # The message says which encoding type does take an address.
      assert_match(/type 1/, e.message)
    end
    # And anything else pack cannot take, where only a String was refused.
    assert_raise(ArgumentError) { Rd.new('100', 1, 0) }
    assert_raise(ArgumentError) { Rd.new(nil, 1, 0) }
    assert_raise(ArgumentError) { Rd.new([1, 1], 1, 0) }
    assert_raise(ArgumentError) { Rd.new(IPAddr.new('1.1.1.1'), 1, 2) }
    assert_raise(ArgumentError) { Rd.new(nil, 1) }
    # The assigned number, in both forms.
    assert_raise(ArgumentError) { Rd.new(1, nil, 0) }
    assert_raise(ArgumentError) { Rd.new(1, IPAddr.new('1.1.1.1')) }
    # And the encoding type, which encode packs as a number too.
    e = assert_raise(ArgumentError) { Rd.new(1, 1, 'x') }
    assert_match(/encoding type/, e.message)
    # The octet level route stays open.
    assert_equal '0000000101010101', Rd.new(['0000000101010101'].pack('H*')).to_shex
  end
  # RFC 4364 section 4.2 gives the type 1 administrator 4 of the value
  # field's 6 octets, so the address is IPv4. encode used to write all 16
  # octets of an IPv6 one, which made the RD 20 octets instead of 8: the Vpn
  # NLRI carrying it went out with a length field that disagreed with its own
  # octets, and to_hash gave back a different RD, since parse reads 8.
  def test_an_ipv6_administrator_is_refused_as_a_type_1_administrator
    e = assert_raise(ArgumentError) { Rd.new('2011:1::1', 1, 1) }
    assert_match(/2011:1::1/, e.message)
    assert_match(/RFC 4364/, e.message)
    assert_match(/IPv4/, e.message)
    # The two argument form reads an address String as a type 1, so it has
    # the same hole.
    assert_raise(ArgumentError) { Rd.new('2011:1::1', 1) }
    assert_raise(ArgumentError) { Rd.new(IPAddr.new('2011:1::1'), 1) }
    # Every RD that builds is the 8 octets section 4.2 gives it, which is
    # what bit_length says.
    [Rd.new, Rd.new(1, 1), Rd.new('1.1.1.1', 1), Rd.new(65536, 1, 2),
     Rd.new(1, 1, 7)].each do |rd|
      assert_equal 8, rd.encode.size
      assert_equal 64, rd.bit_length
    end
    # An RD of 8 octets built from octets is untouched, IPv6 looking or not.
    assert_equal '0001201100010000', Rd.new(['0001201100010000'].pack('H*')).to_shex
  end
  # The type 1 administrator is an address, so an IPAddr is one, and Rd#admin
  # gives one back. IPAddr.new cannot read an IPAddr: it raised
  # AddressFamilyError, "address family must be specified", which named
  # nothing the caller could act on. It is read the way the rest of bgp4r
  # reads an address now, through IPAddr.create.
  def test_a_type_1_administrator_can_be_an_ipaddr
    [Rd.new(IPAddr.new('1.1.1.1'), 1, 1), Rd.new(IPAddr.new('1.1.1.1'), 1)].each do |rd|
      assert_equal 1, rd.encoding_type?
      assert_equal Rd.new('1.1.1.1', 1).to_shex, rd.to_shex
      assert_equal 'RD=1.1.1.1:1', rd.to_s(false)
      assert_equal({:rd=>['1.1.1.1', 1]}, rd.to_hash)
      assert_equal rd.to_shex, Rd.new(rd.to_hash).to_shex
    end
    # The administrator an RD gives back builds the same RD again.
    rd = Rd.new('10.0.0.1', 65535, 1)
    assert_equal rd.to_shex, Rd.new(rd.admin, rd.assign, 1).to_shex
    # IPAddr.create reads the other address forms too, and refuses an
    # Integer that is no IPv4 address.
    assert_equal rd.to_shex, Rd.new([0x0a000001].pack('N').is_packed, 65535, 1).to_shex
    assert_raise(ArgumentError) { Rd.new(2**32, 1, 1) }
  end
  # RFC 4364 section 4.2 defines types 0, 1 and 2. The IANA Route
  # Distinguisher Type Field registry leaves 3 to 65534 unassigned and gives
  # 65535 to RFC 7524, for use only in certain Leaf A-D routes. bgp4r builds
  # and reads any of them: encode used to return nil, and parse used to raise.
  def test_an_undefined_encoding_type_builds_and_round_trips
    rd = Rd.new(1, 1, 3)
    assert_equal 3, rd.encoding_type?
    assert_equal '0003000000010001', rd.to_shex
    assert_equal 'RD=1:1', rd.to_s(false)
    assert_equal({:rd=>[1, 1, 3]}, rd.to_hash)
    assert_equal rd.to_shex, Rd.new(rd.encode).to_shex
    assert_equal rd.to_shex, Rd.new(rd.to_hash).to_shex
    assert_equal rd.to_shex, Rd.new(rd).to_shex
    assert_equal 64, rd.bit_length
  end
  # Type 65535, the RFC 7524 Leaf A-D one.
  def test_the_rfc_7524_leaf_a_d_encoding_type
    rd = Rd.new(1, 1, 65535)
    assert_equal 65535, rd.encoding_type?
    assert_equal 'ffff000000010001', rd.to_shex
    assert_equal 65535, Rd.new(rd.encode).encoding_type?
    assert_equal rd.to_shex, Rd.new(rd.encode).to_shex
  end
  # Whatever the 6 value octets of an undefined type are, they come back.
  def test_an_undefined_encoding_type_keeps_its_octets
    ['0003deadbeefcafe', 'ffffdeadbeefcafe', 'fffeffffffffffff',
     '0003000000000000'].each do |shex|
      wire = [shex].pack('H*')
      assert_equal shex, Rd.new(wire).to_shex
      assert_equal shex, Rd.new(Rd.new(wire).to_hash).to_shex
    end
  end
  # An undefined type says so when printed, so it is not read as a type 2.
  def test_the_verbose_to_s_of_an_undefined_encoding_type_names_it
    assert_equal 'RD=1:1 (type 3, 0x0001 0x01)', Rd.new(1, 1, 3).to_s
    assert_equal 'RD=1:1 (type 65535, 0x0001 0x01)', Rd.new(1, 1, 65535).to_s
  end
end
