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

# The guard for docs/flow-spec.md.
#
#   ruby -I. test/unit/flow_spec_doc_test.rb
#
# Shaped on building_objects_test.rb, which guards
# docs/building-objects.md for the same reason: a claim nothing checks
# reads as verified, and docs/to-hash-round-trips.md was retired for
# being half enforced and half prose with nobody able to tell which was
# which. The enforced half of that document stayed true across four pull
# requests and the prose beside it did not.
#
# So this asserts the document's numbers against the library in both
# directions. Every table that a test can reach is checked, and each
# check also asserts the document still prints the value, so neither
# side can drift without the suite saying so.
#
# **This is named after the document and not after a source file**, which
# departs from the one-file-per-source-file rule in Conventions on
# purpose. docs/flow-spec.md is the subject, the way the primer is
# building_objects_test.rb's subject. The `_doc_` in the name also keeps
# it clear of test/unit/nlris/flow_spec_test.rb, which belongs to
# bgp/nlris/flow_spec.rb when that is written.
#
# What this file cannot assert is the prose. Keep the prose to what the
# RFCs say, and attribute anything else.
#
# BGP:: names are written out in full, see Conventions in CLAUDE.md.

require 'test/unit'
require 'bgp4r'
require 'bgp/nlris/flow_spec_component'

class FlowSpecDocTest < Test::Unit::TestCase

  DOC = File.expand_path('../../docs/flow-spec.md', __dir__)

  def doc
    @doc ||= File.read(DOC)
  end

  def wire(hex)
    [hex].pack('H*').is_packed
  end

  def test_the_document_is_there
    assert(File.exist?(DOC), 'docs/flow-spec.md is gone')
    assert(doc.size > 4000, 'docs/flow-spec.md looks truncated')
  end

  # Section 1's claim, and the reason the work splits the way it does.
  # RFC 8955 defines no attribute type code, so nothing in the library
  # should ever register one for flow spec.
  def test_no_path_attribute_type_code_is_registered_for_flow_spec
    assert_match(/no new path attribute/i, doc)
    names = BGP::Attr::FACTORY.values.collect { |v| v.to_s } rescue []
    assert_equal([], names.grep(/Flow_spec/),
                 'something registered a flow spec path attribute; ' \
                 'docs/flow-spec.md section 1 says there is no type code')
  end

  # Section 6's table of type numbers, both columns, against the class
  # constants. The document is the only place the two names for one type
  # number sit side by side.
  TYPES = {
    1  => [BGP::Flow_spec::Destination_prefix, BGP::Flow_spec::Destination_ipv6_prefix],
    2  => [BGP::Flow_spec::Source_prefix,      BGP::Flow_spec::Source_ipv6_prefix],
    3  => [BGP::Flow_spec::Ip_protocol,        BGP::Flow_spec::Upper_layer_protocol],
    4  => [BGP::Flow_spec::Port],
    5  => [BGP::Flow_spec::Destination_port],
    6  => [BGP::Flow_spec::Source_port],
    7  => [BGP::Flow_spec::Icmp_type,          BGP::Flow_spec::Icmpv6_type],
    8  => [BGP::Flow_spec::Icmp_code,          BGP::Flow_spec::Icmpv6_code],
    9  => [BGP::Flow_spec::Tcp_flags],
    10 => [BGP::Flow_spec::Packet_length],
    11 => [BGP::Flow_spec::Dscp],
    12 => [BGP::Flow_spec::Fragment,           BGP::Flow_spec::Ipv6_fragment],
    13 => [BGP::Flow_spec::Flow_label],
  }.freeze

  def test_every_component_type_number_matches_the_library
    TYPES.each do |type, klasses|
      klasses.each do |k|
        assert_equal(type, k.type,
                     "docs/flow-spec.md section 6 puts #{k} at type #{type}")
      end
    end
  end

  # Every concrete component the library defines, found rather than
  # listed. A class carrying a TYPE is concrete; the abstract bases and
  # Unknown have none, since Unknown takes its type from the octets.
  #
  # `const_defined?` searching the ancestors is **wanted** here, unlike
  # the trap Conventions records: Upper_layer_protocol, Icmpv6_type,
  # Icmpv6_code and Ipv6_fragment are real components that inherit their
  # TYPE from the IPv4 class they subclass, and `false` would drop all
  # four.
  def self.concrete_components
    BGP::Flow_spec.constants(false)
                  .collect { |c| BGP::Flow_spec.const_get(c) }
                  .select { |k| k.is_a?(Class) && k < BGP::Flow_spec::Component }
                  .select { |k| k.const_defined?(:TYPE) }
  end

  # The anti-staleness guard, and the reason the test above is not
  # enough on its own. TYPES is hand written, so it only ever agrees
  # with itself: a component class can join the library and the document
  # never hears about it.
  #
  # **Found by sabotage.** A fourteenth type was added to
  # flow_spec_component.rb and this file passed, which is what
  # "check that the proof proved something" in Rules for agents is
  # about: the sabotage landed and the guard was weak.
  def test_no_component_class_is_missing_from_the_document
    found = self.class.concrete_components
    assert(found.size >= 19, "only found #{found.size} component classes")
    assert_equal(TYPES.keys.sort, found.collect(&:type).uniq.sort,
                 'the library defines component types that ' \
                 'docs/flow-spec.md section 6 does not tabulate, or the ' \
                 'other way round')
    found.each do |k|
      assert(TYPES[k.type].include?(k),
             "#{k} is type #{k.type} and is not in this file's TYPES, so " \
             'docs/flow-spec.md section 6 has not been told about it')
    end
  end

  # The set of type numbers the document tabulates has to be the set the
  # library implements. Matching the *names* was tried and is the wrong
  # test: the document prints the RFC's names and the classes carry
  # bgp4r's, and for type 12 those genuinely differ, since RFC 8956
  # calls it Fragment where the class is Ipv6_fragment.
  #
  # Only section 6's table has a bare number in its first column, so
  # that is what this scans.
  def test_the_documented_type_numbers_are_the_implemented_ones
    # Down to the first subheading only. Section 6 goes on to print the
    # two fragment figures, whose rows begin "| 0 |", and those are
    # bits and not type numbers.
    section = doc[/^## 6\. The components$(.*?)^### /m, 1]
    assert_not_nil(section, 'docs/flow-spec.md lost its section 6 heading')
    rows = section.lines.collect { |l| l[/\A\| *(\d+) *\|/, 1] }.compact.collect(&:to_i)
    assert_equal(TYPES.keys.sort, rows.sort,
                 'docs/flow-spec.md section 6 and the library disagree ' \
                 'about which component types exist')
    assert_match(/\| 0 and type 255 are Reserved|Type 0 and type 255 are Reserved/, doc)
  end

  # Section 5's two mask tables, RFC 8955 sections 4.2.1.1 and 4.2.1.2.
  MASKS = {
    'e'   => [0x80, BGP::Flow_spec::Pair::EOL],
    'a'   => [0x40, BGP::Flow_spec::Pair::AND],
    'len' => [0x30, BGP::Flow_spec::Pair::LEN_MASK],
  }.freeze

  def test_the_operator_masks_match_the_library
    MASKS.each do |field, (want, got)|
      assert_equal(want, got, "the #{field} mask moved")
    end
    assert_equal(0x08, BGP::Flow_spec::Numeric_pair::RESERVED,
                 'RFC 8955 section 4.2.1.1 reserves bit 4 only')
    assert_equal(0x0c, BGP::Flow_spec::Bitmask_pair::RESERVED,
                 'RFC 8955 section 4.2.1.2 reserves bits 4 and 5')
    assert_equal(4, BGP::Flow_spec::Pair::LEN_SHIFT)
  end

  def test_the_document_prints_those_masks
    ['0x80', '0x40', '0x30', '0x08', '0x0c', '0x02', '0x01'].each do |hex|
      assert(doc.include?(hex), "docs/flow-spec.md section 5 omits #{hex}")
    end
  end

  # Section 5's Table 1, RFC 8955 section 4.2.1.1, as the low three bits.
  def test_the_numeric_operator_table_matches_the_library
    { 0 => :false, 1 => :eq, 2 => :gt, 3 => :ge,
      4 => :lt, 5 => :le, 6 => :ne, 7 => :true }.each do |bits, sym|
      assert_equal(sym, BGP::Flow_spec::Numeric_pair::OPS[bits],
                   "docs/flow-spec.md Table 1 reads #{bits} as #{sym}")
    end
    { 0 => :any, 1 => :match, 2 => :not_any, 3 => :not_match }.each do |bits, sym|
      assert_equal(sym, BGP::Flow_spec::Bitmask_pair::OPS[bits],
                   "docs/flow-spec.md section 5 reads #{bits} as #{sym}")
    end
  end

  # Section 6's fragment table, RFC 8955 Figure 4 and RFC 8956 Figure 1.
  def test_the_fragment_bits_match_the_library
    frag = BGP::Flow_spec::Fragment
    assert_equal(0x01, frag::DF)
    assert_equal(0x02, frag::ISF)
    assert_equal(0x04, frag::FF)
    assert_equal(0x08, frag::LF)
    assert_equal(0x0f, frag::DEFINED_BITS)
    # IPv6 reserves the bit IPv4 gives to DF, so three of the four.
    assert_equal(0x0e, BGP::Flow_spec::Ipv6_fragment::DEFINED_BITS)
    assert_match(/\| DF \| 0x01 \|/, doc)
    assert_match(/\| LF \| 0x08 \|/, doc)
  end

  # Section 7's vector table. Every row is built from values and
  # compared, and the document is checked to still print it, so the
  # table cannot drift from the library in either direction.
  VECTORS = {
    '0118c00002' => lambda { BGP::Flow_spec::Destination_prefix.new('192.0.2.0/24') },
    '038106'     => lambda { BGP::Flow_spec::Ip_protocol.new(:eq, 6) },
    '048119'     => lambda { BGP::Flow_spec::Port.new(:eq, 25) },
    '0218cb0071' => lambda { BGP::Flow_spec::Source_prefix.new('203.0.113.0/24') },
    '040389458b911f90' =>
      lambda { BGP::Flow_spec::Port.new([:ge, 137], [:and_le, 139], [:eq, 8080]) },
    '0120c0000201' => lambda { BGP::Flow_spec::Destination_prefix.new('192.0.2.1/32') },
    '0c8005' => lambda do
      BGP::Flow_spec::Fragment.new(:any, BGP::Flow_spec::Fragment::DF |
                                         BGP::Flow_spec::Fragment::FF)
    end,
    '01200020010db8' =>
      lambda { BGP::Flow_spec::Destination_ipv6_prefix.new('2001:db8::/32') },
    '026840123456789a' =>
      lambda { BGP::Flow_spec::Source_ipv6_prefix.new('::1234:5678:9a00:0/104', 64) },
    '0268412468acf134' =>
      lambda { BGP::Flow_spec::Source_ipv6_prefix.new('::1234:5678:9a00:0/65-104') },
  }.freeze

  def test_every_documented_vector_is_what_the_library_builds
    VECTORS.each do |hex, build|
      assert_equal(hex, build.call.to_shex,
                   "docs/flow-spec.md section 7 prints #{hex}")
    end
  end

  def test_the_document_prints_every_vector
    VECTORS.each_key do |hex|
      assert(doc.include?(hex),
             "docs/flow-spec.md section 7 no longer prints #{hex}")
    end
  end

  # The class comes from the recipe rather than from the octets. Sniffing
  # the hex was tried and is not possible: 0120c0000201 is the IPv4
  # destination prefix for 192.0.2.1/32 and 01200020010db8 is the IPv6
  # one for 2001:db8::/32, and both begin 0120, since 0x20 is a 32 bit
  # length in one and 32 bits with a zero offset in the other.
  def test_every_documented_vector_parses_back_to_its_own_octets
    VECTORS.each do |hex, build|
      k = build.call.class
      o = k.new([hex].pack('H*')[1..-1].is_packed)
      assert_equal(hex, o.to_shex, "#{k} did not give back #{hex}")
    end
  end

  # The erratum. Without this the next reader opens RFC 8956 Table 1,
  # sees 0d bb, and "fixes" a correct vector.
  def test_the_erratum_is_cited_where_the_vector_is
    assert_match(/7571/, doc, 'docs/flow-spec.md drops the errata ID')
    assert_match(/0d bb/, doc, 'docs/flow-spec.md drops what the RFC prints')
    component = File.read(
      File.expand_path('nlris/flow_spec_component_test.rb', __dir__))
    assert_match(/7571/, component,
                 'the test file that uses the corrected vector no longer ' \
                 'cites the erratum')
  end

  # Section 8, RFC 8955 Table 8: seven type and sub-type combinations
  # for five action kinds. Both numbers have been written alone here and
  # each was wrong on its own.
  ACTIONS = {
    [0x80, 0x06] => 'traffic-rate-bytes',
    [0x80, 0x0c] => 'traffic-rate-packets',
    [0x80, 0x07] => 'traffic-action',
    [0x80, 0x08] => 'rt-redirect',
    [0x81, 0x08] => 'rt-redirect',
    [0x82, 0x08] => 'rt-redirect',
    [0x80, 0x09] => 'traffic-marking',
  }.freeze

  def test_every_documented_action_code_point_is_registered
    ACTIONS.each_key do |key|
      assert(BGP::Extended_community::FACTORY.key?(key),
             format('docs/flow-spec.md section 8 lists 0x%02x%02x and ' \
                    'extended_community.rb does not register it', *key))
    end
    assert_equal(7, ACTIONS.size)
    assert_equal(5, ACTIONS.values.uniq.size,
                 'five action kinds, three of them one action with three ' \
                 'encodings')
    assert_equal(3, ACTIONS.values.count('rt-redirect'))
  end

  def test_the_document_prints_every_action_code_point
    ACTIONS.each_key do |tt, ss|
      assert(doc.include?(format('0x%02x%02x', tt, ss)),
             format('docs/flow-spec.md section 8 omits 0x%02x%02x', tt, ss))
    end
    assert_match(/seven type and sub-type/i, doc)
    assert_match(/five action kinds/i, doc)
  end

  # Section 8's warning. The masks are right in the library and the
  # sentence they mean was missing from it until this was written down.
  def test_the_traffic_action_masks_and_the_t_bit_warning
    assert_equal(0x01, BGP::Traffic_action::TERMINAL)
    assert_equal(0x02, BGP::Traffic_action::SAMPLE)
    assert_equal(0x03, BGP::Traffic_action::DEFINED_BITS)
    assert_match(/T does not mean stop/i, doc)
    src = File.read(File.expand_path(
      '../../bgp/path_attributes/extended_community.rb', __dir__))
    assert_match(/opposite way round to its name/i, src,
                 'the T bit semantics are no longer in extended_community.rb')
  end

  # Section 8's IPv6 action. 20 octets and not 8, which is the thing a
  # reader is most likely to assume wrongly.
  def test_the_ipv6_address_specific_community_is_twenty_octets
    k = BGP::Ipv6_extended_communities::Ipv6_extended_community
    e = k.new(:route_target, '2001:db8::1', 100).encode
    assert_equal(20, e.size)
    assert_equal('0002', e[0, 2].unpack1('H*'))
    assert_equal('20010db8000000000000000000000001', e[2, 16].unpack1('H*'))
    assert_equal('0064', e[18, 2].unpack1('H*'))
    assert_match(/20 octets/, doc)
    assert_match(/0x000d/, doc)
  end

  # Section 11's claim that rt-redirect-ipv6 is missing. If somebody
  # adds it, this fails and the table has to be struck, which is the
  # same one way rule to_hash_round_trip_test.rb enforces: a gap may
  # stay a gap, but a closed one must not keep reading as open.
  def test_rt_redirect_ipv6_is_still_missing
    k = BGP::Ipv6_extended_communities::Ipv6_extended_community
    assert(!k::NAMES.key?(0x0d),
           'rt-redirect-ipv6 is implemented now; strike it from the table ' \
           'in docs/flow-spec.md section 11')
    assert_match(/`rt-redirect-ipv6`, type 0x000d \| missing/, doc)
  end

  # Section 3's length encoding, with the two values the RFC itself
  # names and the document repeats. The bound matters as much: section
  # 4.1 says 4095 is "The highest value that can be represented with
  # this encoding", so above it a constructor has to refuse rather than
  # write a different length.
  def test_the_documented_length_encoding_matches_the_library
    assert_equal('ef', BGP::Flow_spec.encode_length(239).unpack1('H*'))
    assert_equal('f0f0', BGP::Flow_spec.encode_length(240).unpack1('H*'))
    assert_equal('ffff', BGP::Flow_spec.encode_length(4095).unpack1('H*'))
    assert_raise(ArgumentError) { BGP::Flow_spec.encode_length(4096) }
    assert_equal(239, BGP::Flow_spec::ONE_OCTET_MAX)
    assert_equal(4095, BGP::Flow_spec::MAX_LEN)
    assert_equal(0xf0, BGP::Flow_spec::EXTENDED)
    assert_equal(8, BGP::Flow_spec::RD_SIZE)
    %w[0xef 0xf0f0 4095 240 239].each do |v|
      assert(doc.include?(v), "docs/flow-spec.md section 3 omits #{v}")
    end
  end

  # Section 3's other claim: the family owns its framing now, so the
  # loops can ask instead of calculating. The document prints this
  # method's name, so it has to exist and answer.
  def test_the_family_answers_the_framing_question
    assert_match(/Flow_spec\.nlri_size/, doc)
    assert_equal(12, BGP::Flow_spec.nlri_size(wire('0b0118c00002038106048119')))
    assert_equal(242, BGP::Flow_spec.nlri_size(wire('f0f0') + 'x' * 240))
    assert_nil(BGP::Flow_spec.nlri_size(wire('f0')))
  end

  # Section 3's claim about where the framing lives, which is a pointer
  # into the source and so moves when the source does.
  #
  # **It did move, and this guard is what noticed.** Until the wiring,
  # both loops worked the prefix arithmetic out themselves and this test
  # asserted exactly that, with a message saying the document needed
  # updating. Changing the loops failed it on the next run, which is the
  # whole job: a claim that a test cannot make goes stale silently, and
  # one a test does make cannot.
  def test_the_parse_loops_ask_the_family_how_long_an_nlri_is
    %w[mp_reach mp_unreach].each do |f|
      src = File.read(File.expand_path(
        "../../bgp/path_attributes/#{f}.rb", __dir__))
      assert_match(/nlri_size/, src,
                   "#{f}.rb no longer asks the family how long an NLRI is; " \
                   'docs/flow-spec.md section 3 needs updating')
      assert_not_match(/\(blen\+7\)\/8\+1/, src,
                       "#{f}.rb still works the prefix arithmetic out inline")
    end
    # and the answers, which is the half a grep cannot give. The prefix
    # families give a length in bits in one octet, RFC 4271 section 4.3;
    # flow spec gives octets in one or two, RFC 8955 section 4.1.
    [BGP::Mp_reach, BGP::Mp_unreach].each do |k|
      assert_equal(4, k.nlri_size(wire('180a0000'), 1, 1), "#{k}: a /24")
      assert_equal(1, k.nlri_size(wire('00'), 1, 1), "#{k}: a default route")
      assert_equal(12, k.nlri_size(wire('0b0118c00002038106048119'), 1, 133),
                   "#{k}: RFC 8955 section 4.3.1")
      assert_equal(242, k.nlri_size(wire('f0f0') + 'x' * 240, 1, 133),
                   "#{k}: the two octet length form")
      assert_nil(k.nlri_size(wire(''), 1, 1))
    end
    assert_match(/nlri_size/, doc)
  end

  # Section 10 of the document says what a malformed rule is reported
  # as, and why that answer is not RFC 8955's to give: its own section
  # 10 defers to RFC 7606 and RFC 4760 and names no subcode, so bgp4r
  # reuses the verdict it already gives a malformed MP_REACH.
  #
  # This asserts the library against that prose, because the subcode is
  # the one number in this document a reader could act on and get wrong.
  # The three rules themselves are asserted in
  # test/unit/path_attributes/validation_test.rb; what is checked here
  # is only that the document and the library still agree on what comes
  # out.
  def test_the_documented_subcode_is_what_the_library_reports
    # one rule per section 4.2 sentence, each built by the library
    bad = {
      'out of order' => BGP::Flow_spec.new(
        BGP::Flow_spec::Port.new([:eq, 25]),
        BGP::Flow_spec::Destination_prefix.new('192.0.2.0/24')),
      'a type twice' => BGP::Flow_spec.new(
        BGP::Flow_spec::Destination_prefix.new('192.0.2.0/24'),
        BGP::Flow_spec::Port.new([:eq, 25]),
        BGP::Flow_spec::Port.new([:eq, 80])),
      'an unknown type' => BGP::Flow_spec.new(
        BGP::Flow_spec::Destination_prefix.new('192.0.2.0/24'),
        BGP::Flow_spec::Unknown.new(99, [0x81, 0x05].pack('C*'))),
    }
    bad.each do |what, rule|
      attr = BGP::Mp_reach.new(:safi => 133, :nlris => [rule])
      findings = BGP::Attr::Check.attribute(attr.encode.is_packed, false)
      assert_equal(1, findings.size, "#{what}: one finding")
      f = findings.first
      assert_equal(9, f.subcode, "#{what}: the subcode section 10 leads to")
      assert_equal(:session_reset, f.action, "#{what}: the action")
      assert_match(/RFC 8955 section 4\.2/, f.reason, "#{what}: cites the rule")
      # and the NOTIFICATION that subcode names
      assert_equal('UPDATE msg error (3), Optional Attribute Error (9)',
                   f.notification.to_s[/UPDATE.*/].strip,
                   "#{what}: the NOTIFICATION")
    end
    # a well formed rule is reported as nothing, which is what makes the
    # three above mean something
    ok = BGP::Mp_reach.new(
      :safi => 133,
      :nlris => [{ :destination_prefix => '192.0.2.0/24',
                   :ip_protocol => [[:eq, 6]], :port => [[:eq, 25]] }])
    assert_equal([], BGP::Attr::Check.attribute(ok.encode.is_packed, false))
    # and the document still says both numbers
    assert_match(/subcode 9 with a session reset/, doc)
    assert_match(/RFC 7606 section 7\.11/, doc)
  end

  # RFC 9117 updates RFC 8955's validation procedure, and nothing in
  # RFC 8955 or RFC 8956 points forward to it, so the document says so.
  # Nothing in the library implements it, which is why this only guards
  # the mention: an audit that reads two of the three RFCs would
  # otherwise conclude the section 6 procedure stands as written.
  def test_the_document_names_the_rfc_that_updates_the_validation_procedure
    assert_match(/RFC 9117/, doc)
    assert_match(/Revised Validation Procedure/, doc)
  end

  def test_claude_md_points_at_the_document
    md = File.read(File.expand_path('../../CLAUDE.md', __dir__),
                   :encoding => 'UTF-8')
    assert_match(%r{docs/flow-spec\.md|flow-spec\.md}, md,
                 'CLAUDE.md no longer points at docs/flow-spec.md')
  end

  # Section 12 of the document names the test that asserts each
  # interoperability row, so a reader can check a claim about GoBGP or
  # FRR by running the one test rather than the lab.
  #
  # **This guard only checks that every name it cites still exists**,
  # which is the half a unit test can reach: the rows themselves are
  # asserted by the lab tests, and those need two routers installed.
  # What it catches is the ordinary way such a table rots, which is a
  # test renamed or deleted while the document goes on citing it, and
  # that is worth catching because a row pointing at a method nobody can
  # find reads exactly like a row nobody measured.
  def test_the_interop_rows_name_tests_that_exist
    doc = File.read(File.expand_path('../../docs/flow-spec.md', __dir__),
                    :encoding => 'UTF-8')
    cited = doc.scan(/`(test_(?:gobgp|frr|\*)_[a-z0-9_*]+)`/).flatten.uniq
    assert(cited.size >= 6,
           "section 12 cites #{cited.size} test names, expected the table")
    files = {
      'gobgp' => 'flow_spec_gobgp_test.rb',
      'frr'   => 'flow_spec_frr_test.rb',
    }
    bodies = files.transform_values do |f|
      File.read(File.expand_path("../functional/lab/#{f}", __dir__),
                :encoding => 'UTF-8')
    end
    cited.each do |name|
      # A name written with a * stands for both routers, as the table
      # writes test_*_reads_an_ipv6_rule_back for the pair.
      wanted = name.include?('*') ? files.keys : [name[/test_(gobgp|frr)_/, 1]]
      wanted.each do |which|
        real = name.sub('*', which)
        assert_match(/^\s*def #{Regexp.escape(real)}\b/, bodies[which],
                     "docs/flow-spec.md section 12 cites #{real}, which " \
                     "#{files[which]} does not define")
      end
    end
  end

end
