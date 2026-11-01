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
# **Six guards here were aimed at claims that were true only today, and
# four have now fired.** A document written while a family is half built
# goes stale the moment the next part lands, so each was asserted as
# true only today and named what to update when it failed: when a TLV
# type or an NLRI type arrives, when the dispatch gates learn SAFI 71,
# when a lab test lands, and when the undecodable examples have to move.
# All four fired on time and were re-pointed rather than weakened, which
# is what all four of docs/mcast-vpn.md's did too and is the argument
# for writing them. **Two are still waiting**: when a receive side check
# appears, which is part 6, and when the copy constructor bug in the
# four other families is fixed.
#
# **Patterns that read a source file as text are anchored at the start
# of a line of code**, never bare, because a guard that matches prose
# matches a comment naming the thing it is looking for. That was found
# by sabotage in MCAST-VPN part 7, where deleting a listener left the
# guard passing on the word in a comment.
#
# BGP:: names are written out in full, see Conventions in CLAUDE.md.

require 'test/unit'
require 'bgp/iana'
# **Every file that registers into the two registries, and that is a
# requirement rather than tidiness.** The tables here are discovered
# from `Link_state::Tlv::REGISTRY` and `Link_state::TYPES`, which are
# mutable and filled by `register` calls spread across files, so a
# discovery that loaded only some of them measures a subset and says
# so with confidence. Part 1 required `link_state` and
# `link_state_tlv` alone, and when part 2 landed its two
# forward-looking guards **passed standalone and failed in the suite**,
# because the suite had loaded the registering file and this run had
# not.
#
# That is the load order trap in Conventions in a third shape. The two
# it records fail in opposite directions and are about constants; this
# one is about global mutable state, so the answer is not "run it both
# ways" but "require everything that writes to what you read".
# `evpn_doc_test.rb` and `mcast_vpn_doc_test.rb` do not have it,
# because each of those discovers from a frozen hash literal that one
# file defines.
require 'bgp/nlris/link_state'
require 'bgp/nlris/link_state_tlv'
require 'bgp/nlris/link_state_descriptor'
require 'bgp/nlris/link_state_nlri'
# Part 5a's node attribute TLVs register into the same two hashes, so
# this is the fourth file the paragraph above is about. The attribute
# itself comes with it, since `link_state_attribute.rb` requires the
# TLVs, but it is named anyway: the guards below use it as code and a
# require that arrives by accident is one a later edit can remove.
require 'bgp/nlris/link_state_node_attribute'
require 'bgp/path_attributes/link_state_attribute'
# Required explicitly, per Conventions: run_unit.rb requires every file
# before any test runs, so a file that leans on another's requires
# passes in the suite and fails on its own. This family's siblings fell
# into that twice and this file fell into it again in #219, when the
# wiring guards stopped reading the gates as text and started calling
# through them: BGP::Nlri and BGP::Mp_reach were suddenly needed as
# code and the file errored standalone while the suite stayed green.
require 'bgp/nlris/evpn'
require 'bgp/nlris/mcast_vpn'
require 'bgp/nlris/nlri'
require 'bgp/path_attributes/mp_reach'
require 'bgp/path_attributes/path_attribute'
# Part 7's guard reads which CI group the two lab files are in. Required
# here and not inside the test, since `require './test/lab_groups'`
# works only from the repo root and this file has to pass standalone
# from anywhere, which is the load order trap one more time.
require 'test/lab_groups'

class BgpLsDocTest < Test::Unit::TestCase

  DOC = 'docs/bgp-ls.md'
  DOC_PATH = File.expand_path("../../#{DOC}", __dir__)

  # IANA's "BGP-LS NLRI Types", Table 12 of RFC 9552 section 7.1.1, read
  # on 2026-10-31. Four defined values; 0 is Reserved and 65000 to 65535
  # is Private Use.
  DEFINED = [1, 2, 3, 4].freeze

  # Every TLV code point RFC 9552's own Table 18 defines, read in the
  # document on 2026-10-31: 14 on the NLRI side and 25 attribute TLVs,
  # 39 in all. Listed here because it is the **document's** table and
  # not the library's, so there is nothing to discover it from; what is
  # discovered is which of them bgp4r implements.
  TABLE_18 = ([256, 257, 258, 259, 260, 261, 262, 263, 264, 265] +
              (512..515).to_a + (1024..1031).to_a + (1088..1098).to_a +
              (1152..1157).to_a).freeze

  def doc
    @doc ||= File.read(DOC_PATH, :encoding => 'UTF-8')
  end

  # One library file's body, by path under the repository root. Read as
  # text, the way the validation.rb guards in the sibling doc tests do.
  def source(path)
    File.read(File.expand_path("../../#{path}", __dir__))
  end

  # One section of the document, from its heading to the next one.
  #
  # **Scoped rather than global, and part 2 is why.** The section 3
  # table and the section 3b table are both four columns beginning with
  # a number, so one regexp over the whole document reads the rows of
  # each into the other's answer. Part 1's helper was global and would
  # have done exactly that, silently.
  def section(heading)
    body = doc[/^## #{Regexp.escape(heading)}.*?(?=^## |\z)/m]
    assert_not_nil(body, "#{DOC} must have a section #{heading}")
    body
  end

  # The four-column rows of one section, as {number => the last cell}.
  # A code point table's rows, read as the first cell and the last,
  # whatever is between them. **Column count on purpose**: section 3's
  # table has four columns and 3c's have five, because Table 4 of the
  # RFC has no Length column and each width needs its own citation, so
  # a regexp with a fixed number of groups would have read one table
  # and silently skipped the other. First cell is the code point, last
  # is the yes or no.
  def rows(heading)
    section(heading).lines.each_with_object({}) do |l, h|
      next unless l.start_with?('|')
      # `strip` the line before splitting: the newline after the last
      # `|` is a field of its own, so without it the last cell is
      # always empty and every row is skipped in silence.
      cells = l.strip.split('|').collect { |c| c.strip }
      cells.shift
      next unless cells.size >= 2 and cells.first =~ /\A\d+\z/
      # **Exactly yes or no, where this was `\A\w+\z`, and this is
      # defensive rather than load bearing.** Part 5 put a bit-mask
      # table in section 10 whose rows are `| 0 | Overload | 0x80 | ISO
      # 10589 |`: a digit in the first cell and a word in the last, so
      # the looser form came within one character of reading bit
      # numbers as code points and was saved by the space in "ISO
      # 10589". Measured: loosening this back passes the whole suite
      # today, because every Reference cell in that table has a space
      # in it. It is kept because the next table somebody adds may not,
      # and that is the fragility part 2 and part 4 each paid for once
      # already. Saying what the cell has to be is cheaper than scoping
      # around every table.
      next unless cells.last =~ /\A(?:yes|no)\z/i
      h[cells.first.to_i] = cells.last.downcase
    end
  end

  # The section 3 NLRI type table, as {type number => "In bgp4r"}.
  def table
    rows('3. The NLRI')
  end

  # The section 3b TLV code point table, same shape.
  # Every TLV the document claims, across the three sections that carry
  # a table of them: 3b for section 5.2.1's node descriptors, 3c for
  # sections 5.2.2 and 5.2.3, and 10 for the three attribute tables of
  # section 5.3. Merged rather than one table, so each section's table
  # is about its own part of the RFC, and a code point in none of them
  # fails the guard below just the same.
  #
  # **Section 10 carries three tables and `section` slices to the next
  # `## `, so one call reads all three**, since 10a, 10b and 10c are
  # `###` subheadings. TLV 263 and 1028 and 1029 each have a row in two
  # of them, which `merge` collapses to one answer; the guard below
  # asserts the rows agree so a yes in one table and a no in another
  # cannot pass.
  def tlv_table
    rows('3b. The node descriptors').merge(
      rows('3c. The link and prefix descriptors')).merge(
        rows('10. The attribute'))
  end

  # Every "In bgp4r" row the document has, as a list of [code point,
  # answer] pairs rather than a Hash, so a code point with a row in more
  # than one table appears more than once and a disagreement between
  # them is visible. **A Hash cannot do this**, and that is the point:
  # `rows` collapses section 3c's two tables to 8 keys where they have 9
  # rows, because 263 is in both.
  def tlv_row_pairs(heading)
    section(heading).lines.each_with_object([]) do |l, a|
      next unless l.start_with?('|')
      cells = l.strip.split('|').collect { |c| c.strip }
      cells.shift
      next unless cells.size >= 2 and cells.first =~ /\A\d+\z/
      # Same test as `rows`, and the comment there says why.
      next unless cells.last =~ /\A(?:yes|no)\z/i
      a << [cells.first.to_i, cells.last.downcase]
    end
  end

  TABLE_SECTIONS = ['3b. The node descriptors',
                    '3c. The link and prefix descriptors',
                    '10. The attribute'].freeze

  def tlv_rows_with_duplicates
    TABLE_SECTIONS.flat_map { |h| tlv_row_pairs(h) }
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

  # **The TLV level stands on its own**, which is what makes it a
  # primitive rather than half of a pair, and is the same independence
  # `mcast_vpn_route_test.rb` keeps by putting `Leaf_a_d`'s tests in
  # the NLRI file. Read as text, anchored at the start of a line of
  # code so a comment naming the NLRI level cannot satisfy it.
  def test_the_tlv_test_file_stays_independent_of_the_nlri_level
    body = source('test/unit/nlris/link_state_tlv_test.rb')
    assert_equal(nil, body[/^\s*require 'bgp\/nlris\/link_state'/],
                 'link_state_tlv_test.rb requires the NLRI level now, so ' \
                 'it no longer says the TLV is a primitive. Move the ' \
                 'cross-level case to link_state_test.rb instead')
    assert_equal(nil, body[/^\s+assert.*BGP::Link_state::(Unknown|Type)\b/],
                 'link_state_tlv_test.rb asserts on the NLRI level now: ' \
                 'same thing, move the case')
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
  # **Part 1's version of this guard said both registries were empty,
  # and part 2 is where it fired**, which is what it was for. It is a
  # discovery in both directions now rather than an emptiness claim, so
  # it keeps saying something for parts 3 and 5.
  #
  # The section 3b table is read the same way section 3's is: a row
  # saying yes with no class behind it, and a class with a row saying
  # no, both fail.
  def test_the_tlv_table_says_yes_for_exactly_what_the_library_implements
    built = BGP::Link_state::Tlv::REGISTRY.keys.sort
    said = tlv_table.select { |_, v| v == 'yes' }.keys.sort
    assert_equal(built, said,
                 "#{DOC} sections 3b, 3c and 10 and Tlv::REGISTRY " \
                 "disagree about which TLV types are implemented: " \
                 "library #{built.inspect}, document #{said.inspect}")
  end

  # **The row count, asserted before anything is read out of it.** A
  # guard that reads a document has to say how many rows it expected, or
  # a pattern that stops matching measures a subset and passes: part 3's
  # octet count guard did exactly that and survived four sabotages.
  # Section 3b is Table 3's six; section 3c is Table 4's six and Table
  # 5's three; section 10 is Table 6's seven, Table 8's fifteen and
  # Table 10's six.
  def test_each_code_point_table_has_the_rows_it_should
    assert_equal(6, tlv_row_pairs('3b. The node descriptors').size)
    assert_equal(9, tlv_row_pairs('3c. The link and prefix descriptors').size)
    assert_equal(28, tlv_row_pairs('10. The attribute').size)
    assert_equal(43, tlv_rows_with_duplicates.size)
  end

  # **The document's 43 rows cover Table 18's 39 code points exactly**,
  # which says the three sections together are the whole of RFC 9552's
  # own TLV space with nothing missing and nothing invented.
  def test_the_three_tables_cover_table_18_once_over
    assert_equal(TABLE_18.sort, tlv_table.keys.sort)
  end

  # Three code points have a row in more than one table, which the
  # RFC's own tables do too: 263 is a link descriptor, a prefix
  # descriptor and a node attribute, so three rows, and 1028 and 1029
  # are node attributes and link attributes, so two each. A yes in one
  # and a no in another would read as either and `merge` would hide it,
  # so the rows have to agree.
  def test_a_code_point_in_two_tables_answers_the_same_in_both
    seen = {}
    repeats = []
    tlv_rows_with_duplicates.each do |type, answer|
      if seen.key?(type)
        repeats << type
        assert_equal(seen[type], answer,
                     "#{DOC} answers both ways for TLV #{type}")
      end
      seen[type] = answer
    end
    assert_equal([263, 263, 1028, 1029], repeats.sort,
                 "#{DOC} should repeat 263 twice and 1028 and 1029 once")
  end

  # And every row of it is a code point RFC 9552's own Table 18 defines,
  # so a class registered at a number this document has no row for
  # fails above rather than being written in quietly.
  def test_every_row_of_the_tlv_table_is_an_rfc_9552_code_point
    assert_equal([], tlv_table.keys - TABLE_18,
                 "#{DOC} section 3b has a row for a code point RFC 9552 " \
                 'Table 18 does not define')
  end

  # Both registries are reachable by hash key as well as by number, so
  # a class cannot be half wired: `register` writes both and refuses a
  # key already taken, and this is what says it was called rather than
  # one hash edited by hand.
  def test_every_registered_class_is_in_both_lookups
    BGP::Link_state::Tlv::REGISTRY.each do |t, k|
      assert_equal(k, BGP::Link_state::Tlv::BY_KEY[k.hash_key],
                   "TLV type #{t} is in REGISTRY and not in BY_KEY")
    end
    BGP::Link_state::TYPES.each do |t, k|
      assert_equal(k, BGP::Link_state::BY_KEY[k.hash_key],
                   "NLRI type #{t} is in TYPES and not in BY_KEY")
    end
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

  # --- section 5.2.1, what part 2 claims -------------------------------

  # Table 18 is 39 code points, which section 4 of the document states
  # as the half of "39 against 139" a reader can check against the RFC.
  def test_table_18_is_thirty_nine_code_points
    assert_equal(39, TABLE_18.size)
    assert_equal(TABLE_18.sort, TABLE_18, 'keep the list in order')
  end

  # **The rule that needs two levels**, section 5.2.1.4: "The TLV size
  # in combination with the protocol identifier enables the decoder to
  # determine the type of the node." The width half is the sub-TLV's
  # and the Protocol-ID half is the NLRI's, so the combining is on the
  # NLRI and the document says where.
  def test_the_node_type_rule_needs_both_halves
    assert_equal(false,
                 BGP::Link_state::Tlv::Igp_router_id.method_defined?(
                   :node_type),
                 'the width alone cannot name a node, so the sub-TLV must ' \
                 'not answer this')
    assert(BGP::Link_state::Headed.method_defined?(:node_type))
    iso = BGP::Link_state::Tlv::Igp_router_id.new('1921.6800.1001')
    d = BGP::Link_state::Tlv::Local_node_descriptors.new(iso)
    # IS-IS Level 1 with a 6-octet ISO System-ID is a non-pseudonode.
    assert_equal(:non_pseudonode,
                 BGP::Link_state::Node.new(1, 0, d).node_type)
    # The same octets under 'Direct', where the section describes no
    # node kind at all.
    assert_nil(BGP::Link_state::Node.new(4, 0, d).node_type)
    assert_match(/\*\*nil is an answer and not a\s+failure\*\*/, doc)
  end

  # **The four widths, discovered from `SHAPES` and read out of the
  # document**, both directions, so neither can move without the other.
  # Each row is width, the Protocol-IDs, the node kind and the octets.
  def test_the_four_igp_router_id_widths
    shapes = BGP::Link_state::Tlv::Igp_router_id::SHAPES
    said = {}
    section('3b. The node descriptors').lines.each do |l|
      m = l.match(/^\|\s*(\d)\s*\|\s*([\d, ]+?)\s*\|\s*(\w+)\s*\|/)
      next if m.nil?
      said[m[1].to_i] = [m[2].split(/,\s*/).collect(&:to_i), m[3].to_sym]
    end
    assert_equal(shapes.keys.sort, said.keys.sort,
                 "#{DOC} section 3b and Igp_router_id::SHAPES disagree " \
                 'about which widths section 5.2.1.4 describes')
    shapes.each do |w, row|
      assert_equal([row[0], row[1]], said[w],
                   "#{DOC} section 3b and SHAPES disagree about width #{w}")
    end
  end

  # Section 5.2.1.4's two rules, and the document's claim about why the
  # ordering one has no tiebreakers: the once-only rule means two
  # sub-TLVs never share a type, so `Tlv.ordered?` is enough.
  def test_the_two_rules_of_section_5_2_1_4_are_reported_not_refused
    a = BGP::Link_state::Tlv::Autonomous_system.new(1)
    b = BGP::Link_state::Tlv::Autonomous_system.new(2)
    c = BGP::Link_state::Tlv::Igp_router_id.new('0a000001')
    d = BGP::Link_state::Tlv::Local_node_descriptors.new(a, b)
    assert_equal([512], d.duplicate_types)
    assert_equal(16 + 4, d.size, 'and it still encodes')
    assert_equal(false,
                 BGP::Link_state::Tlv::Local_node_descriptors.new(
                   c, a).ordered?)
    assert_match(/with its tiebreakers made\s+unnecessary/, doc)
  end

  # One flat registry for TLVs and sub-TLVs, which is IANA's doing: a
  # node descriptor and a node descriptor sub-TLV are both in
  # `Tlv::REGISTRY` and there is no second lookup anywhere.
  def test_one_registry_covers_tlvs_and_sub_tlvs
    assert_equal(BGP::Link_state::Tlv::Local_node_descriptors,
                 BGP::Link_state::Tlv::REGISTRY[256])
    assert_equal(BGP::Link_state::Tlv::Autonomous_system,
                 BGP::Link_state::Tlv::REGISTRY[512])
    assert_match(/One flat registry covers TLVs and sub-TLVs alike/, doc)
  end

  # The expiring-example lesson, which part 2 paid for: both part 1 test
  # files now use a type that cannot acquire a class, and each names the
  # choice in a constant.
  def test_the_part_1_examples_cannot_expire
    tlv = source('test/unit/nlris/link_state_tlv_test.rb')
    nlri = source('test/unit/nlris/link_state_test.rb')
    assert_not_equal(nil, tlv[/^  UNREGISTERED = (\d+)$/],
                     'link_state_tlv_test.rb must name its unregistered ' \
                     'type in a constant')
    assert(BGP::Link_state::Tlv::Unknown::RESERVED.include?($1.to_i),
           'that type must be in the range Table 17 reserves')
    assert_not_equal(nil, nlri[/^  NO_CLASS = (\d+)$/],
                     'link_state_test.rb must name its unregistered NLRI ' \
                     'type in a constant')
    assert_nil(BGP::Link_state::TYPES[$1.to_i],
               'that NLRI type must have no registered class')
    assert_match(/cannot expire/, doc)
  end

  # --- part 3, sections 5.2.2 and 5.2.3 --------------------------------

  # The six widths of section 3c's first table, discovered from the
  # classes. **Table 4 of the RFC has no Length column**, which is the
  # fact this guard protects: each width came from a different document,
  # so a wrong one here cannot be caught by reading RFC 9552 and the
  # citation beside it is the only thing a later reader can check.
  def test_the_link_descriptor_widths
    said = {}
    section('3c. The link and prefix descriptors').lines.each do |l|
      m = l.match(/^\|\s*(25[89]|26[0-3])\s*\|[^|]*\|\s*(\d+|2\*n)\s*\|/)
      said[m[1].to_i] = m[2] if m
    end
    built = {}
    BGP::Link_state::Tlv::REGISTRY.each do |t, k|
      next unless (258..262).include?(t)
      built[t] = k::WIDTH.to_s
    end
    built[263] = '2*n'
    assert_equal(built.keys.sort, said.keys.sort,
                 "#{DOC} section 3c and the library disagree about which " \
                 'link descriptor types exist')
    built.each do |t, w|
      assert_equal(w, said[t],
                   "#{DOC} section 3c and TLV #{t} disagree about its width")
    end
  end

  # TLV 263 is in both of the RFC's tables and is **one class**, so it
  # has a row in each of section 3c's tables and one entry in the
  # registry. A second class would be two entries, which `register`
  # refuses, so this is really a guard on the document saying so.
  def test_the_mt_id_tlv_is_one_class_in_two_tables
    assert_equal(BGP::Link_state::Tlv::Multi_topology_id,
                 BGP::Link_state::Tlv::REGISTRY[263])
    assert_match(/TLV 263 appears in both tables and is one class/, doc)
  end

  # **One layout and two type numbers**, which the document claims and
  # which is checked by encoding the same content under both: the value
  # octets are identical and only the framing's NLRI Type differs.
  def test_the_two_prefix_nlris_are_one_layout
    r = BGP::Link_state::Tlv::Ip_reachability.new(24, ['c00002'].pack('H*'))
    a = BGP::Link_state::Ipv4_prefix.new(2, 0, r)
    b = BGP::Link_state::Ipv6_prefix.new(2, 0, r)
    assert_equal(a.to_shex, b.to_shex,
                 'figure 9 says types 3 and 4 use the same format')
    assert_not_equal(BGP::Link_state.new(a).to_shex,
                     BGP::Link_state.new(b).to_shex,
                     'and the framing is where they differ')
    assert_match(/NLRI types 3 and 4 are one layout and two type numbers/,
                 doc)
  end

  # The shared base is **registered nowhere**, so it cannot read as a
  # fifth NLRI type. MCAST-VPN part 3 chose modules over base classes
  # because its doc test discovers from subclasses; here discovery is
  # from the registry, and this is what says a base class is therefore
  # free.
  def test_the_shared_prefix_base_is_not_a_type
    assert_equal(false, BGP::Link_state::TYPES.values.include?(
      BGP::Link_state::Prefix_nlri))
    assert_equal(false,
                 BGP::Link_state::Prefix_nlri.const_defined?(:TYPE, false))
    assert_match(/shared base is \*\*registered nowhere\*\*/, doc)
  end

  # **The second cross-level read**: the family is the NLRI type's and
  # the TLV has none, so the same octets are two prefixes. Both halves
  # asserted, since a class that quietly acquired a family would pass
  # the first half alone.
  def test_the_prefix_family_comes_from_the_nlri_type_and_not_the_tlv
    r = BGP::Link_state::Tlv::Ip_reachability.new(24, ['c00002'].pack('H*'))
    assert_equal('192.0.2.0/24', r.prefix(IANA::AFI::IPv4))
    assert_equal('c000:200::/24', r.prefix(IANA::AFI::IPv6))
    assert_equal(false, r.respond_to?(:afi),
                 'the TLV must not carry a family of its own')
    assert_equal('192.0.2.0/24',
                 BGP::Link_state::Ipv4_prefix.new(2, 0, r).prefix)
    assert_equal('c000:200::/24',
                 BGP::Link_state::Ipv6_prefix.new(2, 0, r).prefix)
    assert_match(/cross-level read/, doc)
  end

  # Section 5.2.3.2's own four cases, which it states rather than
  # leaving to be derived, read out of the document's quotation of them.
  # **The count is asserted first**, because the first draft of this
  # guard used a literal space in `prefix length (\d+)` and the wrapped
  # document put a newline there, so it measured three of the four cases
  # and passed. A guard that reads a document has to say how many rows
  # it expected to find, or it goes quiet the next time the prose
  # rewraps. Every `\s+` below is for the same reason.
  def test_the_octet_counts_section_5_2_3_2_states
    said = doc[/1 octet for prefix length 1 up\s+to 8.*?etc\./m]
    assert_not_nil(said, "#{DOC} must quote section 5.2.3.2's own list")
    found = said.scan(
      /(\d+)\s+octets?\s+for\s+prefix\s+length\s+(\d+)\s+up\s+to\s+(\d+)/)
    assert_equal(4, found.size,
                 'section 5.2.3.2 states four cases and the document must ' \
                 "quote all four; found #{found.inspect}")
    found.each do |octets, from, to|
      [from.to_i, to.to_i].each do |bits|
        assert_equal(octets.to_i,
                     BGP::Link_state::Tlv::Ip_reachability.octets_for(bits),
                     "section 5.2.3.2 says #{bits} bits is #{octets} octets")
      end
    end
  end

  # Section 5.2.2 says four of the link descriptors "can occur multiple
  # times", which is what section 5.1's Length and Value tiebreakers are
  # for. So two of a type is ordinary here, where the once-only rule of
  # section 5.2.1.4 makes those tiebreakers unreachable one section
  # earlier. Both halves, because the document claims the contrast.
  def test_a_repeated_link_descriptor_is_ordinary
    two = [BGP::Link_state::Tlv::Ipv4_interface_address.new('10.0.0.1'),
           BGP::Link_state::Tlv::Ipv4_interface_address.new('10.0.0.3')]
    assert(BGP::Link_state::Tlv.ordered?(two),
           'two of a type in ascending Value order is ordered')
    assert_equal(false, BGP::Link_state::Tlv.ordered?(two.reverse))
    assert_match(/This sub-TLV can occur multiple\s+times/, doc)
    assert_match(/tiebreakers.*unreachable/m, doc)
  end

  # --- every octet buffer in the family is BINARY -----------------------

  # **The buffers and not `encode`, and the difference is what makes
  # this guard worth anything.** Every empty buffer in this family was
  # `(+'')`, which is US-ASCII, and only one of the eight sites showed
  # it: `Ip_reachability#prefix` handed the default route's empty octets
  # to `IPAddr.new_ntoh`, which Ruby 3.3 accepts and 3.4, 4.0 and head
  # refuse with "invalid encoding (given UTF-8, expected BINARY)". CI
  # failed on three Rubies and passed on the one this was written
  # against.
  #
  # **The first draft of this guard asserted `encode.encoding` and
  # caught none of the other seven**, because `encode` goes through
  # `pack`, which forces BINARY on its result whatever went in. It
  # passed against four sabotages. So it reads the buffers through their
  # own accessors instead, which is where a US-ASCII string can sit
  # unnoticed: `String#<<` with an Integer appends a **codepoint** on a
  # non-BINARY buffer, so a value above 0x7f becomes two octets and
  # `bytesize` stops agreeing with `size`.
  def test_every_octet_buffer_is_binary
    # The two Unknowns are built with no value, since passing one
    # overwrites the buffer this is about, and they are not in
    # `REGISTRY` so the loops below do not reach them. **Their own
    # `String.new` defaults are unreachable either way**, which
    # sabotage showed: every branch of each constructor assigns
    # `@value`, and the one-argument form goes through `nil.to_s.b`,
    # so putting `(+'')` back there changes nothing. Kept and recorded
    # as unreachable, the way `Fib`'s `:no_next_hop` branch and
    # `Rt_constrain#origin_as`'s length guard are.
    objects = [BGP::Link_state::Tlv::Unknown.new(999),
               BGP::Link_state::Unknown.new(999),
               BGP::Link_state::Tlv::Ip_reachability.new]
    BGP::Link_state::Tlv::REGISTRY.each_value do |k|
      objects << (k.new rescue next)
    end
    BGP::Link_state::TYPES.each_value { |k| objects << k.new(1, 0) }
    checked = 0
    objects.each do |o|
      [:value, :tail, :octets].each do |m|
        next unless o.respond_to?(m)
        s = o.send(m)
        next unless s.is_a?(String)
        checked += 1
        assert_equal(Encoding::BINARY, s.encoding,
                     "#{o.class}##{m} must be a BINARY buffer")
      end
    end
    # The count, so a renamed accessor cannot make this guard vacuous
    # the way its first draft was. 11 today, and the floor is the
    # number of reachable buffers rather than a round figure.
    assert_operator(checked, :>=, 11,
                    'this guard must reach every octet buffer in the ' \
                    "family; it found #{checked}")
  end

  # --- forward-looking: nothing dispatches to this family yet ----------

  # **Forward-looking.** Part 4 wires the two gates, and then these fail
  # and name what to rewrite. The patterns are anchored at the start of
  # a line of code so a comment naming the family cannot satisfy them,
  # which is what a sabotage caught in MCAST-VPN part 7.
  # **This guard was forward-looking and has fired.** Until #219 it
  # asserted that neither file named BGP_LS or reached Link_state, and
  # that the document said so. All four sites are wired now, so it
  # asserts the new truth instead of being weakened: each gate names
  # the family and reaches it, and the document no longer claims
  # otherwise. Each pattern is anchored at the start of a line of code,
  # so a comment naming the family cannot satisfy it, which is the
  # lesson mcast_vpn_doc_test.rb paid for.
  def test_all_four_dispatch_sites_are_wired
    nlri = source('bgp/nlris/nlri.rb')
    mp = source('bgp/path_attributes/mp_reach.rb')
    assert_not_equal(nil, nlri[/^\s+when IANA::SAFI::BGP_LS, IANA::SAFI::BGP_LS_VPN$/],
                     'the parse gate must dispatch on both BGP-LS SAFIs')
    assert_not_equal(nil, nlri[/^\s+Link_state\.new_ntop\(s\.is_packed, safi, path_id\)$/],
                     'and must pass the SAFI down, since nothing in the ' \
                     'octets says whether the section 5.2 RD is there')
    assert_not_equal(nil, mp[/^\s+Link_state\.nlri_size\(s\)$/],
                     'nlri_size must ask the family for the framing')
    assert_not_equal(nil, mp[/^\s+@afi \|\|= IANA::AFI::BGP_LS$/],
                     'the build gate must set AFI 16388 rather than infer it')
    assert_equal(3, mp.scan(/^\s+when IANA::SAFI::BGP_LS, IANA::SAFI::BGP_LS_VPN$/).size,
                 'mp_reach.rb has three such arms: set, nlri_size and ' \
                 'parse_next_hops. nexthop_klass is the one that splits ' \
                 'the two SAFIs, because section 5.5 prepends a Route ' \
                 'Distinguisher for one of them, so it does not match ' \
                 'this pattern')
    assert_not_equal(nil, mp[/^\s+when IANA::SAFI::BGP_LS_VPN$/],
                     'nexthop_klass must split the two SAFIs: section 5.5 ' \
                     'prepends one RD to a VPN next hop')
    assert_equal(nil, doc[/\*\*Nothing dispatches to either file\.\*\*/],
                 'docs/bgp-ls.md section 7 still says nothing dispatches ' \
                 'to the family: rewrite it, part 4 is done')
    # And the gates really work, which reading the files cannot say.
    ls = BGP::Link_state.new(BGP::Link_state::Node.new(1, 0))
    [IANA::SAFI::BGP_LS, IANA::SAFI::BGP_LS_VPN].each do |safi|
      m = BGP::Mp_reach.new(:safi => safi, :nexthop => '10.0.0.1',
                            :nlris => [ls])
      assert_equal(IANA::AFI::BGP_LS, m.afi)
      assert_equal(m.to_shex, BGP::Mp_reach.new(m.encode.is_packed).to_shex)
      assert_equal(BGP::Link_state,
                   BGP::Mp_reach.new(m.encode.is_packed).nlris.first.class)
    end
  end

  # --- section 2's shared bases, part 5b-i -----------------------------

  # The table in section 2 names the shared bases and where each was
  # first used. Read out of the document and held against the library,
  # both ways, so a new base or a renamed one fails here. **It has fired
  # once already**, when part 5c lifted `Int_list_tlv` out of `Srlg`.
  def test_the_shared_bases_table_matches_the_library
    said = []
    section('2. The TLV').scan(/^\| `(\w+)` \| /) { said << $1 }
    assert_equal(%w[Addr_tlv Int_list_tlv Opaque32 Opaque_tlv Text_tlv],
                 said.sort,
                 "#{DOC} section 2 must name the five shared bases")
    # **Two things this guard cannot do, each found by trying.**
    # Inheriting `Tlv` directly is not what makes a class a base: six
    # concrete classes do too, among them `Node_flag_bits` and
    # `Ospf_route_type`. A base is a class with no identity, so no
    # TYPE. And **`constants(false)` cannot say which file defined
    # one**, because every file in this family reopens `class Tlv`, so
    # `Node_descriptors` is in that list from
    # `link_state_descriptor.rb`. That is the same fact that made the
    # move free, arriving as a limit on checking it: the file placement
    # is held by the text guard below and nothing else can hold it.
    bases = BGP::Link_state::Tlv.constants(false).select do |c|
      k = BGP::Link_state::Tlv.const_get(c)
      next false unless k.is_a?(Class) and k <= BGP::Link_state::Tlv
      next false if k == BGP::Link_state::Tlv::Unknown
      !k.const_defined?(:TYPE)
    end.collect(&:to_s).sort
    assert_equal(%w[Addr_tlv Float32_tlv Int_list_tlv Node_descriptors
                    Opaque32 Opaque_tlv Text_tlv],
                 bases,
                 'the abstract TLV bases in the library')
    # **Two of the seven are not shared, and that is the line part 5b-i
    # drew**: shared means more than one of the RFC's tables, not merely
    # abstract. `Node_descriptors` serves Table 3's 256 and 257 and
    # `Float32_tlv` serves Table 8's 1089 and 1090, so each stays with
    # its own table and section 2 names neither. Each one's registered
    # subclasses are asserted below, so a third table reaching for one
    # fails here and says to move it.
    single_table = %w[Float32_tlv Node_descriptors]
    assert_equal(said.sort, (bases - single_table).sort,
                 "#{DOC} section 2 names every shared base and nothing else")
    assert_equal([256, 257],
                 BGP::Link_state::Tlv::REGISTRY.select { |_, k|
                   k < BGP::Link_state::Tlv::Node_descriptors }.keys.sort,
                 'Node_descriptors serves Table 3 and nothing else')
    assert_equal([1089, 1090],
                 BGP::Link_state::Tlv::REGISTRY.select { |_, k|
                   k < BGP::Link_state::Tlv::Float32_tlv }.keys.sort,
                 'Float32_tlv serves Table 8 and nothing else')
    # And the one that earned its place in section 2 by being used from
    # two tables: 1096 is Table 8's and 1153 and 1154 are Table 10's. A
    # base reaching only one table belongs with that table, so this is
    # the assertion that would send it back.
    serves = BGP::Link_state::Tlv::REGISTRY.select { |_, k|
      k < BGP::Link_state::Tlv::Int_list_tlv }.keys.sort
    assert_equal([1096, 1153, 1154], serves)
    assert(serves.any? { |t| t < 1152 } && serves.any? { |t| t >= 1152 },
           'Int_list_tlv is shared only while two tables use it')
    # **`PACK` and no `WIDTH`**, which is where each subclass states its
    # element width, once. Part 5b-ii found a `WIDTH` beside it saying
    # the same thing and nothing reading it.
    serves.each do |t|
      k = BGP::Link_state::Tlv::REGISTRY[t]
      assert(k.const_defined?(:PACK, false), "#{k} must state its PACK")
      assert(!k.const_defined?(:WIDTH, false),
             "#{k} states its element width twice")
    end
  end

  # **And each really is in `link_state_tlv.rb` and not in one of the
  # table files**, which reading the document cannot say. Part 5b-i
  # moved four there and part 5c a fifth; the point is that requiring
  # the framing file alone is enough for any of them.
  def test_each_shared_base_is_defined_with_the_framing
    shared = %w[Opaque32 Addr_tlv Opaque_tlv Text_tlv Int_list_tlv]
    body = source('bgp/nlris/link_state_tlv.rb')
    shared.each do |name|
      assert_not_equal(nil, body[/^\s+class #{name} < Tlv$/],
                       "link_state_tlv.rb must define #{name}")
    end
    ['bgp/nlris/link_state_descriptor.rb',
     'bgp/nlris/link_state_link_descriptor.rb',
     'bgp/nlris/link_state_node_attribute.rb',
     'bgp/nlris/link_state_link_attribute.rb',
     'bgp/nlris/link_state_prefix_attribute.rb'].each do |path|
      shared.each do |name|
        assert_equal(nil, source(path)[/^\s+class #{name} < Tlv$/],
                     "#{path} must not define #{name} any more")
      end
    end
    assert_match(/the first four moved\s+here in part 5b-i/, doc)
    assert_match(/`Int_list_tlv` came out of `Srlg` in part 5c/, doc)
  end

  # --- section 5.3, what part 5 claims ---------------------------------

  # The attribute is a path attribute, so what says it works is that it
  # reads back out of an attribute set with no protocol error and no
  # coverage gap. Before part 5a it came back as an `Attr::Unknown` with
  # an `Attr::Gap`, which part 7 measured against a real router.
  def test_the_attribute_is_registered_and_reads_back_out_of_a_set
    assert_equal(29, BGP::ATTR::BGP_LS)
    assert_equal(BGP::Link_state_attribute, BGP::Attr.by_type(29).klass)
    assert_equal(BGP::Link_state_attribute, BGP::Attr.by_key(:link_state).klass)
    a = BGP::Link_state_attribute.new(
      BGP::Link_state::Tlv::Node_flag_bits.new(:overload),
      BGP::Link_state::Tlv::Node_name.new('r1'))
    pa = BGP::Path_attribute.new(a)
    back = BGP::Path_attribute.new(pa.encode.is_packed)
    assert_equal(pa.to_shex, back.to_shex)
    assert_equal([BGP::Link_state_attribute],
                 back.attributes.collect { |x| x.class })
    assert_equal(0, back.errors.size)
    assert_equal(0, back.undecoded.size)
  end

  # Section 5.3: "an optional, non-transitive BGP Attribute". The flags
  # octet is the only place that can be checked, and the document says
  # it in prose.
  def test_the_attribute_is_optional_and_non_transitive
    assert_equal(0x80, BGP::Link_state_attribute.new.encode.unpack1('C'))
    assert_match(/optional, non-transitive BGP Attribute/, doc)
  end

  # **The hash is a list and not a map keyed by type**, which is the one
  # thing this attribute does differently from `Path_attribute`'s own
  # hash. The RFC gives the reason twice, and the test is that two TLVs
  # of one type survive the round trip, which a map could not carry.
  def test_the_attribute_hash_is_a_list
    a = BGP::Link_state_attribute.new(
      BGP::Link_state::Tlv::Isis_area_id.new(['490001'].pack('H*')),
      BGP::Link_state::Tlv::Isis_area_id.new(['490002'].pack('H*')))
    assert_equal(2, a.to_hash[:link_state].size)
    assert_equal(a.to_shex, BGP::Link_state_attribute.new(a.to_hash).to_shex)
    assert_match(/multiple TLVs are used to encode them/, doc)
  end

  # **Erratum 7789, which the document records and the library
  # follows.** The mask table in section 10a is held against the class,
  # both ways, so a bit renamed or moved in either place fails. The
  # names come out of the document and the masks out of `BITS`, which is
  # what makes this a check and not a restatement.
  def test_the_node_flag_bits_follow_the_erratum_and_not_the_figure
    assert_match(/Erratum ID 7789/, doc)
    assert_match(/the figure's T should read A/, doc)
    said = {}
    section('10. The attribute').scan(
      /^\| [0-5] \| (\w+) \| (0x[0-9a-f]{2}) \|/) { said[$1.downcase.to_sym] =
                                                      Integer($2, 16) }
    assert_equal(6, said.size, "#{DOC} section 10a must give six masks")
    assert_equal(BGP::Link_state::Tlv::Node_flag_bits::BITS, said)
    assert_equal(:attached, said.keys[1],
                 'the second bit is Attached, not the figure\'s T')
    assert_equal(0xfc, BGP::Link_state::Tlv::Node_flag_bits::DEFINED_BITS)
  end

  # Table 8 has no Length column, which is Table 4's situation again, so
  # five of its rows cite another RFC for a width that is nowhere in RFC
  # 9552. Those five citations are the only place each width lives, so
  # the document has to carry them and a reader has to be told which
  # five.
  def test_the_five_link_attribute_widths_that_are_elsewhere
    # **The width is asserted beside the citation**, and that half is
    # the one that matters: these five are the rows with no width
    # anywhere in RFC 9552, so the citation is where each lives and a
    # reader checking it needs the number it is meant to support. 1091
    # at 32 and 1093 at 2 are the two that memory gives as 4.
    { 1088 => [4, 'RFC 5305 section 3.1'],
      1089 => [4, 'RFC 5305 section 3.4'],
      1090 => [4, 'RFC 5305 section 3.5'],
      1091 => [32, 'RFC 5305 section 3.6'],
      1093 => [2, 'RFC 5307 section 1.2'] }.each do |type, (width, where)|
      assert_match(/^\| #{type} \|[^|]*\| #{width}, #{Regexp.escape(where)} \|/,
                   section('10. The attribute'),
                   "#{DOC} section 10b must give TLV #{type} as #{width} " \
                   "octets citing #{where}")
    end
    # And the library agrees about the two that surprise.
    assert_equal(32, BGP::Link_state::Tlv::Unreserved_bandwidth
                       .new(*([0.0] * 8)).encode_value.size)
    assert_equal(2, BGP::Link_state::Tlv::Link_protection_type
                      .new.encode_value.size)
    assert_match(/\*\*Table 8 has no Length column\*\*/, doc)
  end

  # The third self contradiction in RFC 9552, recorded with the erratum
  # check that rules out an erratum covering it.
  #
  # **This asserted only the document's prose until part 5c, which is
  # weaker than it looks**: the phrase was one this guide's own author
  # controls, so rewording the section failed the guard without anything
  # about the claim changing, which is what happened. Now the class
  # exists, so the substance is held against the **library** as well,
  # which is the half a reader cares about: bgp4r follows the section
  # and the figure rather than the table.
  def test_the_1156_disagreement_is_recorded
    assert_match(/1156 is 4; section 5\.3\.3\.5 says/, doc)
    # `\s+` and not a literal space: the phrase wraps in the document
    # and a literal space misses it, which #218 recorded and #219 met
    # again one pull request later.
    assert_match(/the\s+two verified ones\s+are 7789 and 8766/, doc)
    # The table's own row says both widths rather than the 4 the RFC's
    # table gives, so a reader of the guide is not sent to the wrong one.
    assert_match(/^\| 1156 \|[^|]*\| 4 or 16, see below \|/,
                 section('10. The attribute'))
    # And the library takes both, which is the reading the section and
    # Figure 29 give. A class following Table 10 would refuse the second.
    { '10.0.0.1' => 4, '2001:db8::1' => 16 }.each do |addr, width|
      t = BGP::Link_state::Tlv::Ospf_forwarding_address.new(addr)
      assert_equal(width, t.encode_value.size,
                   "1156 must carry #{addr}, which section 5.3.3.5 allows")
    end
  end

  # **This guard has fired twice and been re-pointed both times rather
  # than weakened.** It said Table 6 was in and Tables 8 and 10 were
  # not; part 5b-ii made that the Table 8 half, and part 5c the rest. So
  # it asserts the finished state: **all 25 of RFC 9552's own attribute
  # TLV code points**, across all three tables of section 5.3, with
  # nothing forward-looking left in it.
  #
  # It is the count that makes it worth keeping now that nothing is
  # outstanding: a class deleted or a type number changed fails it and
  # names which table and part to look at.
  def test_all_three_attribute_tlv_tables_are_in
    built = BGP::Link_state::Tlv::REGISTRY.keys
    { '6 (part 5a)'    => (1024..1029).to_a,
      '8 (part 5b-ii)' => (1030..1031).to_a + (1088..1098).to_a,
      '10 (part 5c)'   => (1152..1157).to_a }.each do |table, types|
      types.each do |t|
        assert(built.include?(t),
               "TLV #{t} is Table #{table} and is not registered")
      end
    end
    # 263 is Table 4's and Table 6's both, registered once in part 3,
    # and 1028 and 1029 are Table 6's and Table 8's both, so the 28
    # rows of the three tables are 25 distinct code points of their own
    # plus that one. Counted from the document rather than added up.
    own = ((1024..1031).to_a + (1088..1098).to_a + (1152..1157).to_a)
    assert_equal(25, own.size)
    assert_equal([], own - built)
    assert(built.include?(263), 'TLV 263 is in Table 6 as well as Table 4')
  end

  # **Forward-looking, and it has now fired twice.** It said validation
  # knew nothing of this family; part 6a landed the action vocabulary
  # and part 6b the checks, so both halves are in and the guard is
  # two-sided rather than retired.
  #
  # Every half is tied to an observation rather than to a phrase, which
  # is what this file has paid for three times: the vocabulary out of
  # `Attr::ACTIONS`, the checks out of `validation.rb`'s own text, and
  # the wiring by calling through it.
  def test_the_action_vocabulary_and_the_checks_are_both_in
    body = source('bgp/path_attributes/validation.rb')
    # Patterns anchored at the start of a line of code, so a comment
    # naming the family cannot match: the file names `Link_state` in its
    # prose as well.
    assert_not_nil(body[/^\s+def link_state_finding/],
                   "part 6b's NLRI checks left validation.rb: strike the " \
                   "table in #{DOC} section 8")
    assert_not_nil(body[/^\s+def link_state_attribute_finding/],
                   "part 6b's attribute check left validation.rb")
    assert_not_nil(body[/^\s+def link_state_next_hop_finding/],
                   "part 6b's next hop check left validation.rb")
    # 6a: both of section 8.2.2's actions are rankable.
    [:nlri_discard, :afi_safi_disable].each do |a|
      assert(BGP::Attr::ACTIONS.include?(a),
             "#{a} is RFC 9552 section 8.2.2's and part 6a adds it")
    end
    assert_equal(:nlri_discard, BGP::Attr::ACTIONS.first,
                 'the weakest, for the reason section 8 records')
    assert_match(/^\*\*Both halves are done\.\*\*/, doc)
    assert_match(/### The checks bgp4r makes, part 6b/, doc)
    assert_match(/### The action vocabulary, part 6a/, doc)
  end

  # **One row per place the library can report, discovered from the
  # library.** Every row of section 8's table is one `Finding.new` in
  # the BGP-LS block of validation.rb, so counting them there catches
  # what a listed table cannot, which is a check added with no row to
  # describe it.
  #
  # The slice markers are asserted before the count so the slice cannot
  # silently become empty and make this vacuous, which is the lesson
  # the flow spec and EVPN guards each learned by sabotage.
  #
  # **The block is at the end of `Check` and not beside the families it
  # resembles**, because the two sibling doc tests slice this same file
  # by method name: EVPN from `def evpn_finding` to `def nonzero?`, and
  # MCAST-VPN from `def mcast_vpn_next_hop_finding` to `def
  # flow_spec_component_size`. A BGP-LS check written in either window
  # is counted as that family's and fails its guard. `validation.rb`
  # says so where the block starts.
  def test_section_8_has_one_row_per_check_the_library_makes
    src = source('bgp/path_attributes/validation.rb')
    first = src.index('def link_state_next_hop_finding')
    last  = src.index('class Malformed_attribute')
    assert(first, 'validation.rb has no link_state_next_hop_finding to count')
    assert(last && last > first,
           'the slice markers moved, so this guard is measuring nothing')
    block = src[first...last]
    assert_equal(block.scan('Finding.new(').size, check_rows.size,
                 "#{DOC} section 8 does not have one row per check in the " \
                 'BGP-LS block of validation.rb')
    assert_operator(check_rows.size, :>=, 8, 'not vacuous either way')
  end

  # The two rows whose walk is shared answer attribute discard when it
  # is reached from the BGP-LS Attribute instead of from an NLRI, which
  # is the one place in section 8's table where the action depends on
  # the caller. The Action column gives the NLRI side, so the document
  # has to say that and the library has to agree.
  def test_the_shared_walk_answers_attribute_discard_from_the_attribute
    shared = check_rows.select { |r| r[1].include?('attr') }
    assert_equal(2, shared.size,
                 "#{DOC} section 8 should have two rows naming an attribute " \
                 'bullet, which are the walk the two levels share')
    assert_equal(['nlri discard'], shared.collect { |r| r[2] }.uniq,
                 'the Action column is the NLRI side')
    assert_match(/answer \*\*attribute discard\*\* when the same walk is/, doc)
    a = BGP::Link_state_attribute.new(
          BGP::Link_state::Tlv::Node_name.new('r1')).to_shex
    { 'runs past the BGP-LS Attribute' => a[0, 10] + 'ff' + a[12..],
      'too few for a TLV Type'         => '801d07' + a[6..] + 'ff',
    }.each do |phrase, hex|
      f = BGP::Attr::Check.attribute([hex].pack('H*').is_packed)
      assert_equal(1, f.size, f.collect(&:reason).inspect)
      assert_equal(:attribute_discard, f.first.action, phrase)
      assert_match(/#{Regexp.escape(phrase)}/, f.first.reason)
    end
  end

  # Every bullet section 8.2.2 lists is answered by at least one row,
  # and every row names a bullet that exists. The NLRI list has seven
  # and the attribute three, and the attribute's second is a FLAGS entry
  # rather than a row, so the table names nine of the ten and the
  # tenth is asserted below.
  def test_every_bullet_of_section_8_2_2_is_named_by_a_row
    named = check_rows.collect { |r| r[1] }.join(' ')
    (1..7).each do |n|
      assert_match(/nlri [\d, ]*#{n}/, named,
                   "no row of #{DOC} section 8 answers NLRI bullet #{n}")
    end
    [1, 3].each do |n|
      assert_match(/attr [\d, ]*#{n}/, named,
                   "no row answers attribute bullet #{n}")
    end
    # The attribute's second bullet is one FLAGS entry rather than a
    # row, so the document has to say that and the library has to have
    # the entry. The library half is the one that matters: part 5c
    # recorded that a guard asserting only this guide's own prose fails
    # on a rewording with nothing about the claim changing, so the
    # phrase match is deliberately loose.
    # `\s+` and not a literal space: the document wraps, and a phrase
    # straddling a line break is the trap #218 and #219 each paid for.
    assert_match(/one `FLAGS`\s+entry/, doc)
    assert_equal(BGP::ATTR::OPTIONAL,
                 BGP::Attr::Check::FLAGS[BGP::ATTR::BGP_LS],
                 'section 5.3: optional, non-transitive')
  end

  # Each row's Action cell against what the library answers for octets
  # built to trip it. The probes are keyed by a distinctive phrase of
  # the row's own first cell, so a reworded row fails loudly rather
  # than quietly matching nothing.
  def test_every_row_of_section_8_gets_the_action_it_claims
    one = ls_nlri
    a   = BGP::Link_state_attribute.new(
            BGP::Link_state::Tlv::Node_name.new('r1')).to_shex
    probes = {
      'too few octets for an NLRI Type' => ls_reach(one + '0001'),
      'runs past the attribute'         => ls_reach('0001ff15' + one[8..]),
      'too short for its Protocol-ID'   => ls_reach('000100050000000000'),
      'too short to frame a TLV'        => ls_reach('00010017' + one[8..] + '0001'),
      'runs past its container'         => ls_reach(one[0, 26] + '0100ffff' + one[34..]),
      'sub-TLV type twice'              => ls_reach(ls_dup),
      'not in section 5.1 order'        => ls_reach(ls_swap),
      'next hop that is not'            => ls_reach(one, 71, '050000000000'),
    }
    assert_equal(check_rows.size, probes.size,
                 'one probe per row of section 8')
    check_rows.each do |cell, _bullet, action, _cite|
      key = probes.keys.find { |k| cell.include?(k) }
      assert(key, "no probe for #{DOC} section 8 row #{cell.inspect}")
      f = BGP::Attr::Check.attribute([probes[key].delete(' ')].pack('H*').is_packed)
      assert_equal(1, f.size, "#{cell}: #{f.collect(&:reason).inspect}")
      assert_equal(action.tr(' ', '_').to_sym, f.first.action, cell)
      assert_equal(9, f.first.subcode, cell)
    end
  end

  # And the four semantic shapes section 8.2.2 says not to check, which
  # is the half of this part that is an instruction rather than code.
  # The document has to name all four, and the library has to report
  # none of them.
  def test_the_forbidden_semantic_checks_are_recorded_and_not_made
    body = doc[/### What is deliberately not checked.*?\n### /m]
    assert(body, "#{DOC} section 8 has no 'not checked' subsection")
    ['presence of a mandatory TLV', "fixed-length TLV's length is correct",
     'TLV field values are permissible',
     'valid with a particular NLRI type'].each do |phrase|
      assert_match(/#{Regexp.escape(phrase)}/i, body,
                   "section 8 does not record that #{phrase.inspect} is " \
                   'forbidden')
    end
    # A Node NLRI with no descriptors, Protocol-ID 0, and a prefix
    # descriptor in it: three of the four shapes in one NLRI.
    bare = BGP::Link_state.new(BGP::Link_state::Node.new(
             0, 1, BGP::Link_state::Tlv::Ip_reachability.new('192.0.2.0/24'))
           ).to_shex
    assert_equal([], BGP::Attr::Check.attribute(
      [ls_reach(bare)].pack('H*').is_packed).collect(&:reason))
    # And an off-width TLV 1156, the fourth.
    odd = '801d0c' + '04840008' + '00' * 8
    assert_equal([], BGP::Attr::Check.attribute(
      [odd].pack('H*').is_packed).collect(&:reason))
  end

  # **This guard has fired and is re-pointed rather than weakened**, the
  # fourth in this file to do so. It used to assert that no BGP-LS lab
  # test existed and that section 11 said the family was unmeasured.
  # Part 7 landed both, so now it asserts the measurement is there and
  # holds the two routers' versions against the tests' own constants.
  #
  # **Why the versions matter more than they look.** Both lab files omit
  # themselves on a version they were not measured against, so a reader
  # bumping a pin in one place would see this table and no failure. That
  # is the shape `mcast_vpn_doc_test.rb` settled on for the same reason.
  def test_the_lab_measures_the_family_in_both_directions
    gobgp = source('test/functional/lab/link_state_gobgp_test.rb')
    frr = source('test/functional/lab/link_state_frr_test.rb')

    assert_match(/Measured on 2026-11-01 against GoBGP 3\.23\.0 and FRR 8\.4\.4/,
                 doc, 'section 11 says when and against what')
    assert_equal(nil, doc[/^\*\*Not measured yet\.\*\*/],
                 'and no longer says it is pending')

    # The versions, out of the tests' own constants and the document.
    assert_match(/^\s+MEASURED_MAJOR = 3$/, gobgp)
    assert_match(/^\s+MEASURED = \(8\.\.8\)/, frr)
    assert_match(/GoBGP 3\.23\.0/, doc)
    assert_match(/FRR 8\.4\.4/, doc)

    # Both files are assigned to a CI group, which is what
    # lab_groups_test.rb enforces in general and what this one names, so
    # the message points at the right file if it ever drifts.
    assigned = LabGroups::GROUPS.values.flatten
    %w[link_state_gobgp_test link_state_frr_test].each do |f|
      assert(assigned.include?(f), "#{f} must be in a group in test/lab_groups.rb")
    end
  end

  # **The receive direction is the claim this family's lab makes that no
  # other family's does**, so it is asserted on the code and not only on
  # the prose: the one case that gets GoBGP to originate, and the replay
  # that is the only assertion in it that cannot pass for the wrong
  # reason.
  #
  # Every pattern is anchored at the start of a line of code, because a
  # guard that reads a test file as text matches its prose as readily as
  # its calls, which is how the first draft of the MCAST-VPN one passed
  # a sabotage.
  def test_the_gobgp_test_measures_both_directions
    body = source('test/functional/lab/link_state_gobgp_test.rb')

    assert_match(/^\s+LINK_ARGS = %w\[/, body,
                 'the client grammar the receive direction needs')
    assert_match(/^\s+out, status = router\.client_run\(\*%w\[global rib add -a ls link\]/,
                 body, 'and the call that makes GoBGP originate')
    assert_match(/^[^#]*\brouter\.client_run\(\*%w\[global rib del -a ls link\]/,
                 body, 'with the withdrawal, which is the other half')
    assert_match(/^\s+BGP::Link_state\.new_ntop\(\[ls\.to_shex\]/, body,
                 'the NLRI replay')
    assert_match(/^\s+BGP::Mp_reach\.new\(\[a\.to_shex\]/, body,
                 'and the attribute replay')
    assert_match(/^\s+n\.on_state_change\b/, body,
                 'a reset is watched for rather than read off session state')

    # And the two faults, each named in the document and asserted in the
    # test, so neither can be dropped from one without the other.
    assert_match(/It requires a sub-TLV RFC 9552 does not/, doc)
    assert_match(/^\s+assert_match\(\/"Error":"Required TLV missing"\//, body)
    assert_match(/Its client panics rendering an IP Reachability TLV/, doc)
    assert_match(/^\s+assert_match\(\/index out of range/, body)
  end

  # Section 11's finding about part 6, held in both places: the document
  # has to state it and the test has to measure it. This is the one
  # thing part 7 was taken early for, so it is the one most worth not
  # losing when part 6 rewrites section 8.
  def test_the_ordering_finding_is_recorded_and_measured
    body = source('test/functional/lab/link_state_gobgp_test.rb')

    assert_match(/GoBGP's own node descriptors are not in ascending sub-TLV\s+order/,
                 doc, 'section 11 states it')
    assert_match(/\*\*part 6 follows the\s+RFC and not the router\*\*/, doc,
                 'and says what it decides')
    assert_match(/^\s+assert_equal\(false, local\.ordered\?,/, body,
                 'and the lab test measures it')
  end

  # **Forward-looking, and the one with nowhere left to go.** Three
  # tests use BGP-LS as their example of a family bgp4r cannot decode,
  # which is true only until part 4. When it fails, the examples need a
  # SAFI IANA has not assigned rather than another real family.
  # **The twin of the guard above, and it has fired too.** It used to
  # assert that the three undecodable examples were still this family.
  # They have moved to SAFI 255, which IANA has Reserved, so now it
  # asserts that they are **not** this family and cannot come back:
  # three moves is enough, and a reserved SAFI is the first choice that
  # cannot expire.
  def test_the_undecodable_examples_have_moved_off_this_family
    a = source('test/unit/path_attributes/mp_reach_test.rb')
    b = source('test/unit/path_attributes/path_attribute_test.rb')
    assert_equal(nil, a[/^\s+hex = '800e0e' \+ '400447'/],
                 'mp_reach_test.rb still uses AFI 16388 SAFI 71 as its ' \
                 'unimplemented family, which decodes now')
    assert_equal(nil, b[/^\s+UNDECODABLE = '800e15 4004 47/],
                 'path_attribute_test.rb still uses AFI 16388 SAFI 71 in ' \
                 'UNDECODABLE, which decodes now')
    assert_not_equal(nil, b[/^\s+UNDECODABLE_SAFI = (\d+)$/],
                     'path_attribute_test.rb must name the SAFI it uses ' \
                     'in a constant, so the choice can be asserted')
    safi = $1.to_i
    assert_nil(IANA.safi?(safi),
               "SAFI #{safi} has a name in iana.rb, so it is a family " \
               'bgp4r is behind on rather than one it can never read')
    # **`['01'].pack('H*')` and not `'x'.is_packed`.** `is_packed` sets
    # an instance variable, so it is a mutation, and CI runs the suite
    # with `--enable-frozen-string-literal`, where a literal cannot
    # take one: the call raised FrozenError before reaching the gate,
    # so under that flag this asserted nothing about the claim. It
    # passed locally and for the right reason, which is why only CI
    # caught it. `Array#pack` marks its result packed already, so the
    # library's own route needs no mutation.
    assert_raise(RuntimeError) { BGP::Nlri.factory(['01'].pack('H*'), 1, safi) }
    # `\s+` and not a literal space, because the document wraps and the
    # phrase straddles a line break. #218 recorded that rule for a guard
    # that had silently measured three of four rows; this one failed
    # outright instead, which is the better of the two outcomes.
    assert_match(/no\s+unimplemented\s+family\s+left\s+to\s+point\s+at/, doc)
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

  # **The status of the three parts that can be observed is tied to the
  # observation and not to a word in the table.** Part 3 is done when
  # every NLRI type is registered, part 4 when the gates dispatch, and
  # parts 6 and 7 are the subject of the forward-looking guards above.
  # So a part marked done with nothing behind it fails here, which is
  # the same discipline as the two "In bgp4r" columns.
  def test_the_document_names_the_seven_parts
    (1..7).each do |n|
      assert_match(/^\| #{n} \| /, doc,
                   "#{DOC} section 7 must have a row for part #{n}")
    end
    # **Scoped to section 7, and the unscoped form was wrong.** This
    # scanned the whole document until #219 added the section 9 next hop
    # table, whose rows are three columns starting with a digit as these
    # are: `| 4 | 12 | IPv4 |` overwrote part 4's status with "IPv4".
    # Part 2 fixed exactly this for the code point tables and the lesson
    # did not carry: a table parser that reads a whole document reads
    # every table in it.
    status = {}
    section('7. What is in bgp4r today').scan(
      /^\| ([1-7]) \|[^|]*\|\s*(.+?)\s*\|\s*$/) do
      status[$1.to_i] = $2.delete('*')
    end
    assert_equal(7, status.size)
    assert_equal('done', status[1])
    assert_equal('done', status[2])
    # Part 3: all four of Table 1.
    assert_equal([1, 2, 3, 4], BGP::Link_state::TYPES.keys.sort)
    assert_equal('done', status[3],
                 'every NLRI type is registered, so part 3 is done')
    # Part 4: both gates dispatch and the framing asks the family.
    assert_not_equal(nil, BGP::Link_state.nlri_size(
      ['0001000902000000000000000000'].pack('H*')))
    assert_equal('done', status[4],
                 'the dispatch gates are wired, so part 4 is done')
    # Part 5: tied to all three of section 5.3's tables being
    # registered, which `test_all_three_attribute_tlv_tables_are_in`
    # holds against the library. **This has been re-pointed twice**,
    # once per sub-part that landed, and each time the observation moved
    # with it rather than the phrase being edited to match: that is what
    # the paragraph above this method asks for.
    assert_equal([], ((1024..1031).to_a + (1088..1098).to_a +
                      (1152..1157).to_a) -
                     BGP::Link_state::Tlv::REGISTRY.keys,
                 'every attribute TLV of section 5.3 is registered')
    assert_match(/\Adone\b/, status[5],
                 'all three tables of section 5.3 are registered, so ' \
                 'part 5 is done')
    # Part 6: tied to the same observation the validation guard watches,
    # so the two cannot disagree. **Re-pointed twice**, once when 6a
    # landed and once when 6b did.
    assert(BGP::Attr::ACTIONS.include?(:nlri_discard),
           "part 6a's vocabulary is in")
    assert_not_nil(source('bgp/path_attributes/validation.rb')[
                     /^\s+def link_state_finding/],
                   "part 6b's checks are in")
    assert_equal('done', status[6],
                 'both halves are in, so part 6 is done')
    # **Part 7's row was stale and so was this line.** #220 landed the
    # lab, rewrote section 11 and left both the table row and this
    # assertion saying "to do", and nothing caught it because the two
    # agreed with each other. Tied to the observation now, which is
    # what the paragraph above this method asks for: the lab files
    # exist and are in a CI group.
    assert_equal(2, LabGroups.present.count { |f| f =~ /\Alink_state_\w+_test\z/ },
                 'the two BGP-LS lab files are on disk')
    assert_equal('done', status[7],
                 'the lab is measured, so part 7 is done')
  end

  # Section 8's check table: the first cell, the bullets it answers, the
  # action and the citation. Read out of the document, so a row added or
  # reworded moves what the three guards above measure.
  # **Not written with /x.** Free-spacing mode drops the literal spaces
  # inside `nlri discard` as well as the ones between the pieces, so the
  # action alternation never matched and the table read as empty. The
  # three guards above then passed nothing and failed on their own floor
  # assertions, which is why those floors are there.
  ACTION = /nlri discard|attribute discard|session reset/

  def check_rows
    doc[/### The checks bgp4r makes, part 6b.*?\n### /m]
      .to_s.each_line.inject([]) do |a, l|
        m = l.match(/^\|\s*([a-z][^|]*?)\s*\|\s*((?:nlri|attr)[^|]*?)\s*\|\s*(#{ACTION})\s*\|\s*([^|]+?)\s*\|\s*$/)
        a << [m[1], m[2], m[3], m[4]] if m
        a
      end
  end

  # A clean Node NLRI, built with the library: RFC 9552 carries no hex
  # anywhere, so a hand written vector here would check this reader's
  # arithmetic and not the document.
  def ls_nlri(*tlvs)
    tlvs = [BGP::Link_state::Tlv::Local_node_descriptors.new(
              BGP::Link_state::Tlv::Autonomous_system.new(65000))] if tlvs.empty?
    BGP::Link_state.new(BGP::Link_state::Node.new(0, 1, *tlvs)).to_shex
  end

  # The same NLRI with one sub-TLV type twice, and with its two Node
  # Descriptor TLVs written 257 before 256. The head is 9 octets after
  # the 4 framing ones, so the TLVs start at character 26.
  def ls_dup
    ls_nlri(BGP::Link_state::Tlv::Local_node_descriptors.new(
              BGP::Link_state::Tlv::Autonomous_system.new(65000),
              BGP::Link_state::Tlv::Autonomous_system.new(65001)))
  end

  def ls_swap
    two = ls_nlri(BGP::Link_state::Tlv::Local_node_descriptors.new(
                    BGP::Link_state::Tlv::Autonomous_system.new(65000)),
                  BGP::Link_state::Tlv::Remote_node_descriptors.new(
                    BGP::Link_state::Tlv::Autonomous_system.new(65001)))
    two[0, 26] + two[50..] + two[26, 24]
  end

  # An MP_REACH around one Link-State NLRI: AFI 16388, the SAFI, a next
  # hop and the reserved octet (RFC 4760 section 3).
  def ls_reach(nlri, safi = IANA::SAFI::BGP_LS, nh = '040a000001')
    v = '4004' + format('%02x', safi) + nh + '00' + nlri
    '800e' + format('%02x', v.size / 2) + v
  end

end
