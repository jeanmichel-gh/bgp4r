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
      next unless cells.last =~ /\A\w+\z/
      h[cells.first.to_i] = cells.last.downcase
    end
  end

  # The section 3 NLRI type table, as {type number => "In bgp4r"}.
  def table
    rows('3. The NLRI')
  end

  # The section 3b TLV code point table, same shape.
  # Every TLV the document claims, across the two sections that carry a
  # table of them: 3b for section 5.2.1's node descriptors and 3c for
  # sections 5.2.2 and 5.2.3. Merged rather than one table, so each
  # section's table is about its own part of the RFC, and a code point
  # in neither fails the guard below just the same.
  def tlv_table
    rows('3b. The node descriptors').merge(
      rows('3c. The link and prefix descriptors'))
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
                 "#{DOC} section 3b and Tlv::REGISTRY disagree about " \
                 "which TLV types are implemented: library " \
                 "#{built.inspect}, document #{said.inspect}")
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
    status = {}
    doc.scan(/^\| ([1-7]) \|[^|]*\|\s*(.+?)\s*\|\s*$/) do
      status[$1.to_i] = $2.delete('*')
    end
    assert_equal(7, status.size)
    assert_equal('done', status[1])
    assert_equal('done', status[2])
    # Part 3: all four of Table 1.
    assert_equal([1, 2, 3, 4], BGP::Link_state::TYPES.keys.sort)
    assert_equal('done', status[3],
                 'every NLRI type is registered, so part 3 is done')
    # Parts 4, 6 and 7 are what the forward-looking guards watch, so
    # their status here must agree with those still passing.
    assert_equal('to do', status[4])
    assert_equal('to do', status[6])
    assert_equal('to do', status[7])
  end

end
