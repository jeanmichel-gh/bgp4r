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

# The load-bearing claims in docs/building-objects.md, asserted.
#
#   ruby -I. test/unit/building_objects_test.rb
#
# That document is the primer for anyone changing a constructor or
# chasing an object that will not come back, and a primer nothing checks
# goes stale. That is not a hypothetical here: the prose half of
# docs/to-hash-round-trips.md drifted into listing work that two pull
# requests had already finished, while its tables stayed true the whole
# time because a test compares them against the catalog row by row. The
# enforced half held and the unenforced half did not.
#
# So this covers the few claims that would make the primer actively
# misleading if they stopped holding, and not its prose. A reader who
# trusts a wrong primer loses more time than one with no primer at all.
class BuildingObjectsTest < Test::Unit::TestCase

  DOC = 'docs/building-objects.md'
  DOC_PATH = File.expand_path("../../#{DOC}", __dir__)

  # bgp/common.rb patches Array#pack to mark its result. This is the one
  # tell that separates wire bytes from a String that is a field value,
  # and the primer leads with it because nothing in the resulting error
  # mentions it.
  def test_array_pack_marks_its_result_and_a_literal_does_not
    assert(['40010102'].pack('H*').is_packed?, 'Array#pack must mark its result')
    assert(!"\x40\x01\x01\x02".is_packed?, 'a literal must not be marked')
    # The parens matter: +"s".is_packed.is_packed? parses as +("s"...),
    # unary plus on true. +'' is here because CI runs the suite with
    # --enable-frozen-string-literal and is_packed sets an ivar.
    assert((+"\x40\x01\x01\x02").is_packed.is_packed?, 'is_packed must mark in place')
  end

  # Marked octets take the wire branch. The same octets unmarked do not,
  # and the message says nothing about the mark.
  def test_wire_bytes_are_recognised_only_by_the_mark
    assert_equal('40010102', BGP::Origin.new(['40010102'].pack('H*')).to_shex)
    assert_raise(ArgumentError) { BGP::Origin.new(+"\x40\x01\x01\x02") }
  end

  # parse reads with slice!, so the String a constructor is handed comes
  # back empty. Hand it a dup if you need it afterwards. This is per
  # class and not a rule: Nlri leaves its argument alone, so neither
  # behaviour can be relied on.
  def test_a_constructor_may_consume_the_string_it_is_handed
    octets = ['40010102'].pack('H*')
    BGP::Origin.new(octets)
    assert_equal(0, octets.size, 'Origin consumes its argument')
    nlri = ['18c0000018c00001'].pack('H*')
    BGP::Nlri.new(nlri)
    assert_equal(8, nlri.size, 'Nlri does not')
  end

  # The three ways are not the same three everywhere. Prefix has no wire
  # branch at all: its String argument is a prefix, and wire octets go to
  # the collection that slices them, Nlri or Withdrawn. Binary handed to
  # Prefix dies inside IPAddr, marked or not, which is the furthest a
  # build gets from naming its own mistake.
  def test_not_every_class_reads_wire_bytes
    assert_equal('18c00000', BGP::Prefix.new('192.0.0.0/24').to_shex)
    assert_raise(IPAddr::InvalidAddressError) { BGP::Prefix.new(['18c00002'].pack('H*')) }
    assert_equal('18c0000018c00001', BGP::Nlri.new(['18c0000018c00001'].pack('H*')).to_shex)
  end

  # Attr.register puts each attribute in the registry under its hash
  # keys, so Path_attribute never names an attribute class.
  def test_the_registry_turns_a_hash_key_into_a_class
    assert_equal(BGP::Origin, BGP::Attr.by_key(:origin).klass)
    assert_equal('40010102', BGP::Path_attribute.new(:origin => 2).to_shex)
    assert_nil(BGP::Attr.by_key(:nonesuch))
  end

  def test_an_unregistered_hash_key_says_so
    e = assert_raise(ArgumentError) { BGP::Path_attribute.new(:nonesuch => 1) }
    assert_match(/not implemented/, e.message)
  end

  # The whole contract in one assertion, for a class that takes all four:
  # field values, a hash, wire bytes, and another instance of itself,
  # which is re-parsed through its own encode rather than copied field by
  # field.
  # Compared as hex, and each wire build gets its own copy, because the
  # constructor above empties what it is handed.
  def test_the_four_build_paths_agree
    from_values = BGP::Aggregator.new('10.0.0.1', 100)
    hex = from_values.to_shex
    assert_equal(hex, BGP::Aggregator.new(:address => '10.0.0.1', :asn => 100).to_shex)
    assert_equal(hex, BGP::Aggregator.new(from_values.encode).to_shex)
    assert_equal(hex, BGP::Aggregator.new(from_values).to_shex)
  end

  # :tail, :bits and :duplicates appear only when something unusual
  # arrived, so an ordinary object hashes as it always did and nothing
  # reading these hashes has to change. The three unusual cases are
  # asserted where they belong, in each class's own test file and in the
  # to_hash catalog; this is the ordinary case the rule protects.
  def test_an_ordinary_object_gains_no_extra_key
    assert_equal({ :communities => ['1:1'] }, BGP::Communities.new('1:1').to_hash)
    assert_equal({ :origin => :incomplete, :next_hop => '10.0.0.1' },
                 BGP::Path_attribute.new(BGP::Origin.new(2),
                                         BGP::Next_hop.new('10.0.0.1')).to_hash)
  end

  # The primer only works if a session finds it without being told, which
  # is what the CLAUDE.md pointers are for. A rename that leaves them
  # behind puts the whole mechanism back to someone remembering.
  def test_claude_md_points_at_the_primer
    assert(File.exist?(DOC_PATH), "#{DOC} must exist")
    # UTF-8 named: CLAUDE.md is not ASCII and the default external
    # encoding here is US-ASCII, where a match raises on the first byte
    # above 127.
    claude_md = File.read(File.expand_path('../../CLAUDE.md', __dir__),
                          :encoding => 'UTF-8')
    assert_match(/building-objects\.md/, claude_md,
                 "CLAUDE.md must point at #{DOC}")
  end

end
