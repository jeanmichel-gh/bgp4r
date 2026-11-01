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

# docs/bgp-ls.md makes claims about the library. This asserts the load
# bearing ones, the way mcast_vpn_doc_test.rb, evpn_doc_test.rb and
# flow_spec_doc_test.rb guard the other three family guides, because a
# claim nothing checks reads as verified in a document as much as in a
# comment.
#
#   ruby -I. test/unit/bgp_ls_doc_test.rb
#
# **Both tables are discovered, not listed.** That shape came from a
# sabotage on the flow spec guard: a fourteenth component type was added
# and the first version of that guard passed, because it compared the
# document against a list in the test rather than against the library.
# So the NLRI type table is cross-checked against Link_state::TYPES in
# either direction, and the TLV registry against what the document says
# is in it.
#
# **Six guards here are aimed at claims that are true only today.** A
# document written while a family is half built goes stale the moment
# the next part lands, so each of those is asserted as true only today
# and names what to update when it fails: when a TLV type or an NLRI
# type arrives, when the dispatch gates learn SAFI 71, when a receive
# side check appears, when a lab test lands, when the undecodable
# examples have to move, and when the copy constructor bug in the four
# other families is fixed. All four of docs/mcast-vpn.md's
# forward-looking guards fired on time, which is the argument for
# writing them.
#
# **Patterns that read a source file as text are anchored at the start
# of a line of code**, never bare, because a guard that matches prose
# matches a comment naming the thing it is looking for. That was found
# by sabotage in MCAST-VPN part 7, where deleting a listener left the
# guard passing on the word in a comment.
#
# BGP:: names are written out in full, see Conventions in CLAUDE.md.

require 'test/unit'
require 'bgp/nlris/link_state'
require 'bgp/nlris/link_state_tlv'
require 'bgp/iana'
# The forward-looking guards read the dispatch gates and validation.rb
# as text, so they need no requires of their own. These two are reached
# as code. Required explicitly, per Conventions: run_unit.rb requires
# every file before any test runs, so a file that leans on another's
# requires passes in the suite and fails on its own, which is a trap
# this family's siblings fell into twice.
require 'bgp/nlris/evpn'
require 'bgp/nlris/mcast_vpn'

class BgpLsDocTest < Test::Unit::TestCase

  DOC = 'docs/bgp-ls.md'
  DOC_PATH = File.expand_path("../../#{DOC}", __dir__)

  # IANA's "BGP-LS NLRI Types", Table 12 of RFC 9552 section 7.1.1, read
  # on 2026-10-31. Four defined values; 0 is Reserved and 65000 to 65535
  # is Private Use.
  DEFINED = [1, 2, 3, 4].freeze

  def doc
    @doc ||= File.read(DOC_PATH, :encoding => 'UTF-8')
  end

  # One library file's body, by path under the repository root. Read as
  # text, the way the validation.rb guards in the sibling doc tests do.
  def source(path)
    File.read(File.expand_path("../../#{path}", __dir__))
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

  # --- section 3, the NLRI type table ---------------------------------

  def test_the_table_has_a_row_for_each_defined_nlri_type
    assert_equal(DEFINED, table.keys.sort,
                 "#{DOC} section 3 must have one row per NLRI type of " \
                 'RFC 9552 Table 1')
  end

  # The discovery guard. Both directions fail: a class in the library
  # whose row says no, and a row saying yes with no class behind it.
  def test_the_table_says_yes_for_exactly_what_the_library_implements
    built = BGP::Link_state::TYPES.keys.sort
    said = table.select { |_, v| v == 'yes' }.keys.sort
    assert_equal(built, said,
                 "#{DOC} section 3 and Link_state::TYPES disagree about " \
                 "which NLRI types are implemented: library #{built.inspect}, " \
                 "document #{said.inspect}")
  end

  # --- the framing numbers --------------------------------------------

  # Section 5.1 and section 5.2 both frame with four octets, two of type
  # and two of length, and the document says so of each.
  def test_both_levels_frame_with_four_octets
    assert_equal(4, BGP::Link_state::Tlv::FRAMING)
    assert_equal(4, BGP::Link_state::FRAMING)
    assert_equal(0xffff, BGP::Link_state::Tlv::MAX_LEN)
    assert_equal(0xffff, BGP::Link_state::MAX_LEN)
    assert_match(/Two octets each/, doc)
  end

  def test_the_route_distinguisher_is_eight_octets
    assert_equal(8, BGP::Link_state::RD_SIZE)
    assert_match(/Route Distinguisher \(8 octets\)/, doc)
  end

  # **The claim the document leads with**: the Total NLRI Length counts
  # the RD, so the same body is eight octets longer behind one. Asserted
  # against the library rather than quoted alone.
  def test_the_total_nlri_length_counts_the_route_distinguisher
    body = ['0102030405'].pack('H*')
    plain = BGP::Link_state.new(BGP::Link_state::Unknown.new(1, body))
    vpn = BGP::Link_state.new(:unknown => { :type => 1,
                                            :value => '0102030405' },
                              :rd => [100, 200])
    assert_equal(5, plain.length)
    assert_equal(13, vpn.length)
    assert_equal(plain.size + 8, vpn.size)
    assert_match(/it also includes the length of the Route\s+Distinguisher/, doc)
  end

  # **nlri_size takes no SAFI**, which the document states as section
  # 5.2's doing rather than a simplification. One argument, and it
  # frames both forms.
  def test_nlri_size_takes_no_safi
    assert_equal(1, BGP::Link_state.method(:nlri_size).arity)
    plain = ['0001' + '0005' + '0102030405'].pack('H*')
    vpn = ['0001' + '000d' + '00000064000000c8' + '0102030405'].pack('H*')
    assert_equal(plain.size, BGP::Link_state.nlri_size(plain))
    assert_equal(vpn.size, BGP::Link_state.nlri_size(vpn))
    assert_match(/\*\*takes no SAFI\*\*/, doc)
  end

  # And the SAFI is a parse-time input, which is the other half of that
  # pair: one capture, two readings, both replaying.
  def test_the_safi_is_a_parse_time_input
    hex = '0001' + '000d' + '00000064000000c8' + '0102030405'
    plain = BGP::Link_state.new_ntop([hex].pack('H*'))
    vpn = BGP::Link_state.new_ntop([hex].pack('H*'),
                                   IANA::SAFI::BGP_LS_VPN)
    assert_nil(plain.rd)
    assert_equal('RD=100:200', vpn.rd.to_s(false))
    assert_equal(hex, plain.to_shex)
    assert_equal(hex, vpn.to_shex)
    assert_match(/The SAFI is a parse-time input/, doc)
  end

  # --- the IANA numbers ------------------------------------------------

  def test_the_afi_and_the_two_safis
    assert_equal(16388, IANA::AFI::BGP_LS)
    assert_equal(71, IANA::SAFI::BGP_LS)
    assert_equal(72, IANA::SAFI::BGP_LS_VPN)
    assert_match(/AFI 16388 \/ SAFI 71/, doc)
    assert_match(/AFI 16388 \/ SAFI 72/, doc)
  end

  def test_the_two_private_use_ranges_are_what_the_tables_give
    assert_equal(65000..65535, BGP::Link_state::Unknown::PRIVATE_USE)
    assert_equal(65000..65535, BGP::Link_state::Tlv::Unknown::PRIVATE_USE)
    assert_match(/65000 to 65535/, doc)
  end

  # Table 17: "0-255 | Reserved (not to be allocated)". The document
  # calls it out because it is the one range no document will ever
  # define a TLV in, and such a type still parses and replays.
  def test_the_reserved_tlv_range_is_zero_to_255
    assert_equal(0..255, BGP::Link_state::Tlv::Unknown::RESERVED)
    assert_match(/Reserved \(not to be allocated\)/, doc)
    t = BGP::Link_state::Tlv.factory(['00ff0002abcd'].pack('H*').is_packed)
    assert_equal('00ff0002abcd', t.to_shex)
  end

  # --- the ordering rule lives in one place ---------------------------

  def test_the_ordering_rule_is_implemented_once
    assert(BGP::Link_state::Tlv.respond_to?(:ordered?),
           'the section 5.1 ordering rule belongs with the TLV, so part ' \
           '6 asks rather than reimplementing it')
    a = BGP::Link_state::Tlv::Unknown.new(256, ['7f'].pack('H*'))
    b = BGP::Link_state::Tlv::Unknown.new(256, ['80'].pack('H*'))
    assert(BGP::Link_state::Tlv.ordered?([a, b]))
    assert_equal(false, BGP::Link_state::Tlv.ordered?([b, a]))
    assert_match(/ordered lexicographically/, doc)
  end

  # The second level is the Length field and not the value's real size,
  # which the document calls out as the thing a readable implementation
  # gets wrong.
  def test_the_ordering_follows_the_length_field
    long = BGP::Link_state::Tlv.factory(['0100270f01'].pack('H*').is_packed)
    short = BGP::Link_state::Tlv::Unknown.new(256, ['0000'].pack('H*'))
    assert(BGP::Link_state::Tlv.ordered?([short, long]))
    assert_match(/the Length field and not the value's real\s+size/, doc)
  end

  # --- the two Unknowns ------------------------------------------------

  def test_there_is_one_unknown_per_level_and_they_are_distinct
    assert_not_equal(BGP::Link_state::Unknown, BGP::Link_state::Tlv::Unknown)
    assert_equal(BGP::Link_state::Type, BGP::Link_state::Unknown.superclass)
    assert_equal(BGP::Link_state::Tlv,
                 BGP::Link_state::Tlv::Unknown.superclass)
    assert_match(/^\| `Link_state::Unknown` \|/, doc)
    assert_match(/^\| `Link_state::Tlv::Unknown` \|/, doc)
  end

  # Section 5.2's word is "opaque objects", so the NLRI level Unknown
  # frames no TLVs out of a body that happens to be one.
  def test_an_unknown_nlri_type_keeps_opaque_octets
    body = '01000004c0000201'
    n = BGP::Link_state.new_ntop([format('ea60%04x', body.size / 2) +
                                  body].pack('H*'))
    assert_equal(body, n.nlri.value.unpack1('H*'))
    assert_equal(false, n.nlri.respond_to?(:tlvs))
    assert_match(/keeps opaque octets and reads no TLVs out of\s+them/, doc)
  end

  # --- section 5.4, where the Enterprise Code is read and where it is
  #     not ------------------------------------------------------------

  def test_the_enterprise_code_is_read_at_the_tlv_level_only
    t = BGP::Link_state::Tlv.factory(
      ['fde8000600000a4c0102'].pack('H*').is_packed)
    assert_equal(2636, t.enterprise_code)
    assert_equal(false,
                 BGP::Link_state::Unknown.new(65000, '').respond_to?(
                   :enterprise_code),
                 'the NLRI level reader is left out because section 5.4 ' \
                 'and figure 6 both claim the octets after the Total NLRI ' \
                 'Length and nothing settles which comes first')
    assert_match(/it collides with the RD/, doc)
  end

  # --- the registries --------------------------------------------------

  # **Forward-looking.** True only while part 1 is the only part in, and
  # the document says so in section 7. When a TLV class or an NLRI type
  # class lands, this fails and names the sentence to rewrite.
  def test_no_tlv_type_and_no_nlri_type_is_implemented_yet
    assert_equal({}, BGP::Link_state::Tlv::REGISTRY,
                 'a TLV type landed: rewrite the section 7 sentence and ' \
                 'this guard, and give the TLV table a row')
    assert_equal({}, BGP::Link_state::TYPES,
                 'an NLRI type landed: rewrite the section 7 sentence and ' \
                 'set its row in the section 3 table to yes')
    assert_match(/\*\*No TLV type and no NLRI type is implemented yet\*\*/,
                 doc)
  end

  def test_both_registries_refuse_a_type_already_taken
    [BGP::Link_state::Tlv, BGP::Link_state].each do |level|
      base = level == BGP::Link_state ? BGP::Link_state::Type : level
      a = Class.new(base) do
        const_set(:TYPE, 60123)
        const_set(:HASH_KEY, :doc_test_a)
      end
      b = Class.new(base) do
        const_set(:TYPE, 60123)
        const_set(:HASH_KEY, :doc_test_b)
      end
      begin
        level.register(a)
        assert_raise(ArgumentError) { level.register(b) }
      ensure
        (level == BGP::Link_state ? BGP::Link_state::TYPES :
           BGP::Link_state::Tlv::REGISTRY).delete(60123)
        (level == BGP::Link_state ? BGP::Link_state::BY_KEY :
           BGP::Link_state::Tlv::BY_KEY).delete(:doc_test_a)
      end
    end
    assert_match(/Both refuse a type or a hash key already taken/, doc)
  end

  # --- forward-looking: nothing dispatches to this family yet ----------

  # **Forward-looking.** Part 4 wires the two gates, and then these fail
  # and name what to rewrite. The patterns are anchored at the start of
  # a line of code so a comment naming the family cannot satisfy them,
  # which is what a sabotage caught in MCAST-VPN part 7.
  def test_the_dispatch_gates_know_nothing_of_the_family_yet
    ['bgp/nlris/nlri.rb', 'bgp/path_attributes/mp_reach.rb'].each do |f|
      body = source(f)
      assert_equal(nil, body[/^\s+when .*BGP_LS/],
                   "#{f} dispatches on BGP-LS now: that is part 4, so " \
                   "rewrite docs/bgp-ls.md section 7")
      assert_equal(nil, body[/^\s+Link_state\./],
                   "#{f} reaches Link_state now: that is part 4, so " \
                   "rewrite docs/bgp-ls.md section 7")
    end
    assert_match(/\*\*Nothing dispatches to either file\.\*\*/, doc)
  end

  # **Forward-looking.** Part 6 puts the first check in validation.rb,
  # and section 8 of the document says there is none yet.
  def test_validation_knows_nothing_of_the_family_yet
    body = source('bgp/path_attributes/validation.rb')
    assert_equal(nil, body[/^\s+def link_state/],
                 'a BGP-LS check landed in validation.rb: that is part 6, ' \
                 'so rewrite docs/bgp-ls.md section 8')
    assert_equal(nil, body[/^\s+Link_state\./],
                 'validation.rb reaches Link_state now: that is part 6, ' \
                 'so rewrite docs/bgp-ls.md section 8')
    assert_match(/^\*\*Not implemented\.\*\* Part 6/, doc)
  end

  # **Forward-looking.** Part 7 adds the lab test, and section 11 says
  # the family is not measured against a router yet.
  def test_no_lab_test_measures_the_family_yet
    found = Dir[File.expand_path('../functional/lab/*link_state*',
                                 __dir__)] +
            Dir[File.expand_path('../functional/lab/*bgp_ls*', __dir__)]
    assert_equal([], found,
                 'a BGP-LS lab test landed: that is part 7, so rewrite ' \
                 'docs/bgp-ls.md section 11 with what it measured, and ' \
                 'add the file to test/lab_groups.rb')
    assert_match(/^\*\*Not measured yet\.\*\* Part 7/, doc)
  end

  # **Forward-looking, and the one with nowhere left to go.** Three
  # tests use BGP-LS as their example of a family bgp4r cannot decode,
  # which is true only until part 4. When it fails, the examples need a
  # SAFI IANA has not assigned rather than another real family.
  def test_the_undecodable_example_is_still_this_family
    a = source('test/unit/path_attributes/mp_reach_test.rb')
    b = source('test/unit/path_attributes/path_attribute_test.rb')
    assert_not_equal(nil, a[/^\s+hex = '800e0e' \+ '400447'/],
                     'mp_reach_test.rb no longer uses AFI 16388 SAFI 71 ' \
                     'as its unimplemented family: re-point it, do not ' \
                     'weaken it, and rewrite docs/bgp-ls.md section 7')
    assert_not_equal(nil, b[/^\s+UNDECODABLE = '800e15 4004 47/],
                     'path_attribute_test.rb no longer uses AFI 16388 ' \
                     'SAFI 71 in UNDECODABLE: re-point it, do not weaken ' \
                     'it, and rewrite docs/bgp-ls.md section 7')
    assert_match(/there is nowhere left to point them/, doc)
  end

  # --- the copy constructor measurement -------------------------------

  # The document records a bug in four other families rather than
  # fixing it, so the measurement is asserted the way the fault matrix
  # asserts a router divergence: when someone fixes it, this fails and
  # says to strike the paragraph.
  def test_the_copy_constructor_bug_is_still_in_the_four_other_families
    [BGP::Evpn.new_ntop(
       ['030d00000064000000c800000000040a000001'].pack('H*'), 9),
     BGP::Mcast_vpn.new_ntop(
       ['020c00000064000000c80001117f'].pack('H*'), 9)].each do |a|
      b = a.class.new(a)
      assert_not_equal(a.to_shex, b.to_shex,
                       "#{a.class} copies an extended NLRI correctly now: " \
                       'strike the paragraph in docs/bgp-ls.md section 7')
    end
    assert_match(/answers garbage\s+for `Evpn`, `Mcast_vpn`, `Flow_spec` and `Rt_constrain`/,
                 doc)
  end

  # And Link_state itself does not have it, which is the other half of
  # that paragraph.
  def test_link_state_copies_an_extended_nlri_correctly
    a = BGP::Link_state.new_ntop(
      ['0001000d00000064000000c80102030405'].pack('H*'),
      IANA::SAFI::BGP_LS_VPN, 9)
    b = BGP::Link_state.new(a)
    assert_equal(a.to_shex, b.to_shex)
    assert_equal(9, b.path_id)
  end

  # --- the counts the document states ---------------------------------

  # 39 against 139 is the sentence that says why the breadth is the
  # expensive half, and the 39 is checkable against RFC 9552's own Table
  # 18 by anyone with the document. Kept as a document assertion
  # because the library has none of them yet; when part 5 lands, the
  # registry is what to measure against.
  def test_the_document_states_both_tlv_counts
    assert_match(/\*\*39 against 139\.\*\*/, doc)
    assert_match(/Table 18 defines 39 TLV code points/, doc)
  end

  def test_the_document_names_the_seven_parts
    (1..7).each do |n|
      assert_match(/^\| #{n} \| /, doc,
                   "#{DOC} section 7 must have a row for part #{n}")
    end
    assert_match(/^\| 1 \| the TLV primitive and the NLRI framing, pure \| \*\*done\*\* \|/,
                 doc)
  end

end
