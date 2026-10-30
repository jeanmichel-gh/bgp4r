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

# docs/evpn.md makes claims about the library. This asserts the load
# bearing ones, the way building_objects_test.rb guards the other
# primer, because a claim nothing checks reads as verified in a document
# as much as in a comment.
#
#   ruby -I. test/unit/evpn_doc_test.rb
#
# **The route type table is discovered, not listed.** That shape came
# from a sabotage on the flow spec guard: a fourteenth component type
# was added and the first version of that guard passed, because it
# compared the document against a list in the test rather than against
# the library. So this enumerates the Route subclasses the library
# actually defines and cross-checks them against both the table and
# Evpn::ROUTES, which catches a class added to one and forgotten in the
# other, in either direction.
#
# BGP:: names are written out in full, see Conventions in CLAUDE.md.

require 'test/unit'
require 'bgp/nlris/evpn'
require 'bgp/path_attributes/extended_community'

class EvpnDocTest < Test::Unit::TestCase

  DOC = 'docs/evpn.md'
  DOC_PATH = File.expand_path("../../#{DOC}", __dir__)

  def doc
    @doc ||= File.read(DOC_PATH, :encoding => 'UTF-8')
  end

  # Every Route subclass the library defines, Unknown excluded: it is in
  # no row and in no ROUTES entry on purpose, since no type number
  # reaches it.
  def implemented
    BGP::Evpn.constants.collect { |c| BGP::Evpn.const_get(c) }
             .select { |k| k.is_a?(Class) && k < BGP::Evpn::Route }
             .reject { |k| k == BGP::Evpn::Unknown }
  end

  # The section 3 table, as {type number => the "In bgp4r" cell}.
  def table
    doc.lines.each_with_object({}) do |l, h|
      m = l.match(/^\|\s*(\d+)\s*\|([^|]*)\|([^|]*)\|\s*(\w+)\s*\|\s*$/)
      h[m[1].to_i] = m[4].downcase if m
    end
  end

  def test_the_document_exists
    assert(File.exist?(DOC_PATH), "#{DOC} must exist")
    assert_operator(doc.size, :>, 2000, "#{DOC} looks truncated")
  end

  # RFC 9572 section 3 Table 1 and Table 2 give eleven between them, so
  # the table has a row per type and no more.
  def test_the_table_has_a_row_for_each_of_the_eleven_route_types
    assert_equal((1..11).to_a, table.keys.sort,
                 "#{DOC} section 3 must have one row per route type, 1 to 11")
  end

  # The discovery guard. Both directions fail: a class in the library
  # whose row says no, and a row saying yes with no class behind it.
  def test_the_table_says_yes_for_exactly_what_the_library_implements
    built = implemented.collect(&:type).sort
    table.each do |type, cell|
      if built.include?(type)
        assert_equal('yes', cell,
                     "#{DOC} says #{cell.inspect} for route type #{type}, " \
                     'which the library implements')
      else
        assert_equal('no', cell,
                     "#{DOC} says #{cell.inspect} for route type #{type}, " \
                     'which the library does not implement')
      end
    end
  end

  # The half-wiring guard: a class added to evpn_route.rb and forgotten
  # in ROUTES parses as an Unknown however complete the class is, and
  # nothing else would say so.
  def test_every_route_class_is_registered_in_routes
    assert_equal(implemented.collect(&:type).sort, BGP::Evpn::ROUTES.keys.sort,
                 'a Route subclass is missing from Evpn::ROUTES, or vice versa')
    BGP::Evpn::ROUTES.each do |type, klass|
      assert_equal(type, klass.type,
                   "Evpn::ROUTES[#{type}] holds #{klass}, whose type is " \
                   "#{klass.type}")
    end
  end

  # RFC 7432 section 7: the Length counts the body alone, so an NLRI
  # occupies 2 + Length octets. The document says so in section 2 and
  # this is the claim everything downstream rests on.
  def test_the_length_counts_the_body_alone
    assert_match(/counts the body alone/, doc)
    assert_equal(2, BGP::Evpn::FRAMING)
    assert_equal(10, BGP::Evpn.nlri_size(['09080011223344556677'].pack('H*')))
    assert_equal(2, BGP::Evpn.nlri_size(['0900'].pack('H*')))
    assert_equal(255, BGP::Evpn::MAX_LEN)
  end

  def test_nlri_size_answers_nil_rather_than_guessing
    assert_match(/answers nil for octets too short to frame/, doc)
    assert_nil(BGP::Evpn.nlri_size(nil))
    assert_nil(BGP::Evpn.nlri_size(['09'].pack('H*')))
  end

  # Section 4's table of primitive widths.
  def test_the_primitive_widths_are_what_the_table_says
    assert_equal(10, BGP::Evpn::Esi::WIDTH)
    assert_equal(10, BGP::Evpn::Esi.new.encode.size)
    assert_equal(4, BGP::Evpn::Ethernet_tag_id::WIDTH)
    assert_equal(4, BGP::Evpn::Ethernet_tag_id.new.encode.size)
    assert_equal(6, BGP::Evpn::Mac_addr::WIDTH)
    assert_equal(48, BGP::Evpn::Mac_addr::BITS)
  end

  # RFC 7432 section 5's two reserved values, quoted in section 4.
  def test_the_two_reserved_esi_values
    assert_match(/ESI 0 denotes a single-homed\s+site/, doc)
    assert_match(/MAX-ESI/, doc)
    assert(BGP::Evpn::Esi.new.single_homed?)
    assert(BGP::Evpn::Esi.new(['ff' * 10].pack('H*').is_packed).max?)
  end

  # The claim the document calls the one memory reverses, with its four
  # citations. Each is quoted, so a reader can check it without opening
  # the RFC.
  def test_the_document_says_the_lengths_are_in_bits
    assert_match(/Both the IP and MAC address lengths are in\s+bits/, doc)
    assert_match(/The IP address length\s+is in bits/, doc)
    assert_match(/specifies the number of\s+bits in the prefix/, doc)
    assert_match(/RFC 9251 says it of all three lengths/, doc)
  end

  # And the one RFC that does not say, recorded as open rather than
  # guessed. If part 7 reads RFC 7117 this claim changes and the test
  # with it; what must not happen is the open question going quiet.
  def test_the_document_records_rfc_9572_as_silent_on_the_units
    assert_match(/RFC 9572 is the one that does not say/, doc)
    assert_match(/RFC 7117/, doc)
    assert_match(/has not been read here/, doc)
  end

  # The difference between the two fields on consecutive lines of one
  # figure, which is the subtlety most likely to be coded wrong.
  def test_the_mac_width_does_not_follow_its_length_and_the_ip_does
    assert_match(/`Mac_addr` always takes 6/, doc)
    assert_match(/Its width follows its length/, doc)
    mac = BGP::Evpn::Mac_addr.new(['18001122334455'].pack('H*').is_packed)
    assert_equal(24, mac.bitlen)
    assert_equal(6, mac.value.size, 'the MAC stays six octets')
    addr = BGP::Evpn::Addr.new(['18c00002'].pack('H*').is_packed)
    assert_equal(24, addr.bitlen)
    assert_equal(3, addr.value.size, 'the IP follows its length')
    assert(BGP::Evpn::Addr.new.empty?, 'and a length of 0 is the absent field')
  end

  # Section 6's arithmetic, both sums, against RFC 9136 section 3.1's
  # "MUST be either 34 ... or 58".
  def test_the_route_type_5_lengths_add_up
    assert_match(/8 \+ 10 \+ 4 \+ 1 \+ 4 \+ 4 \+ 3 = 34/, doc)
    assert_match(/8 \+ 10 \+ 4 \+ 1 \+ 16 \+ 16 \+ 3 = 58/, doc)
    assert_equal(34, 8 + 10 + 4 + 1 + 4 + 4 + 3)
    assert_equal(58, 8 + 10 + 4 + 1 + 16 + 16 + 3)
  end

  # Section 7's count, and the community that makes it eleven. The
  # Opaque claim is read out of FACTORY rather than taken on trust,
  # which is what caught an earlier draft of this document saying bgp4r
  # registered no 0x03 sub-types at all.
  def test_the_default_gateway_community_is_opaque_and_missing
    assert_match(/type 0x03 sub-type 0x0d/, doc)
    assert_match(/\*\*eleven\*\* added, not ten/, doc)
    f = BGP::Extended_community::FACTORY
    refute(f.has_key?([0x03, 0x0d]),
           'Default Gateway is implemented, so the document is stale')
    [[0x03, 0x00], [0x03, 0x0b], [0x03, 0x0c]].each do |k|
      assert(f.has_key?(k),
             "#{DOC} says #{k.inspect} is registered and it is not")
    end
    assert_equal(4, f.keys.count { |k| k[0] == 0x06 },
                 "#{DOC} says four 0x06 sub-types are registered")
  end

  # Conventions' first bullet, as it applies here.
  def test_nothing_validates_on_the_way_out
    assert_match(/Nothing validates on the way out/, doc)
    assert_equal('fe00',
                 BGP::Evpn.new(BGP::Evpn::Unknown.new(0xfe, '')).to_shex)
    liar = BGP::Evpn.new(['09140011223344556677'].pack('H*').is_packed)
    assert_equal(20, liar.declared_len)
    assert_equal('09140011223344556677', liar.to_shex,
                 'a Length that lies must replay byte for byte')
  end

  # The two refusals the document says exist, and that they are the only
  # ones: a value the field cannot hold, never a combination merely
  # wrong by the RFC.
  def test_the_two_constructor_refusals
    assert_match(/80 bits or more/, doc)
    assert_raise(ArgumentError) { BGP::Evpn::Esi.new(1 << 80) }
    assert_raise(ArgumentError) { BGP::Evpn::Ethernet_tag_id.new(1 << 32) }
    assert_nothing_raised do
      BGP::Evpn::Esi.new(0xfe, '001122334455667788')
      BGP::Evpn::Ethernet_tag_id.new(0xffffffff)
    end
  end

  # Interoperability is not measured yet and the document must not
  # pretend otherwise. The flow spec table names its asserting test per
  # row; until this one can, it says so.
  def test_interoperability_is_recorded_as_unmeasured
    assert_match(/Not measured yet/, doc)
  end

  def test_claude_md_points_at_the_document
    md = File.read(File.expand_path('../../CLAUDE.md', __dir__),
                   :encoding => 'UTF-8')
    assert_match(%r{docs/evpn\.md|evpn\.md}, md,
                 "CLAUDE.md no longer points at #{DOC}")
  end

end
