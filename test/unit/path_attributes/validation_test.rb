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

class TestAttrCheck < Test::Unit::TestCase
  include BGP

  def b(hex) [hex.delete(' ')].pack('H*').is_packed end

  # [subcode, action] of each finding for one attribute.
  def check(hex, as4byte = false)
    Attr::Check.attribute(b(hex), as4byte).collect { |f| [f.subcode, f.action] }
  end

  TAW, DISCARD, RESET = :treat_as_withdraw, :attribute_discard, :session_reset

  def test_good_attributes_have_no_findings
    [ '40 01 01 00', '40 02 06 0202 0064 0065', '40 03 04 0a000001', '80 04 04 00000064',
      '40 05 04 00000064', '40 06 00', 'c0 07 06 0064 01010101', 'c0 08 04 00640001',
      '80 09 04 01010101', '80 0a 04 01010101', 'c0 10 08 0002006400000001',
      '40 02 00', 'c0 11 06 0201 fa56ea01' ].each do |hex|
      assert_equal [], check(hex), hex
    end
    assert_equal [], check('c0 07 08 fa56ea01 01010101', true)
  end

  # RFC 7606 section 7, one rule each.
  def test_origin
    assert_equal [[5, TAW]], check('40 01 02 0000')
    assert_equal [[5, TAW]], check('40 01 00')
    assert_equal [[6, TAW]], check('40 01 01 03')
  end

  def test_as_path
    assert_equal [[11, TAW]], check('40 02 04 0501 0064')        # unknown segment type
    assert_equal [[11, TAW]], check('40 02 02 0200')             # zero length segment
    assert_equal [[11, TAW]], check('40 02 04 0202 0064')        # segment overruns
    assert_equal [[11, TAW]], check('40 02 05 0201 0064 02')     # one octet left
    assert_equal [[11, TAW]], check('40 02 06 0202 0064 0065', true)  # 2 AS of 4 octets need 8
  end

  def test_as4_path
    assert_equal [[11, DISCARD]], check('c0 11 06 0301 fa56ea01')   # confed (RFC 6793 section 6)
    assert_equal [[11, DISCARD]], check('c0 11 04 0201 0064')
  end

  def test_fixed_lengths
    assert_equal [[5, TAW]], check('40 03 00')
    assert_equal [[5, TAW]], check('80 04 03 000064')
    assert_equal [[5, TAW]], check('40 05 05 0000006400')
    assert_equal [[5, DISCARD]], check('40 06 01 00')
    assert_equal [[5, TAW]], check('80 09 03 010101')
  end

  def test_aggregator_length_follows_the_session
    assert_equal [], check('c0 07 06 0064 01010101')
    assert_equal [[5, DISCARD]], check('c0 07 06 0064 01010101', true)
    assert_equal [[5, DISCARD]], check('c0 07 08 fa56ea01 01010101')
    assert_equal [[5, DISCARD]], check('c0 12 06 0064 01010101', true)
  end

  def test_multiples
    assert_equal [[5, TAW]], check('c0 08 05 0102030405')
    assert_equal [[5, TAW]], check('c0 08 00')
    assert_equal [[5, TAW]], check('80 0a 06 010101010202')
    assert_equal [[5, TAW]], check('c0 10 09 000200640000000100')
  end

  def test_mp_reach_and_unreach
    assert_equal [[9, RESET]], check('80 0e 04 00010104')
    assert_equal [[9, RESET]], check('80 0e 06 000101040a00')    # next hop says 4, 2 there
    assert_equal [], check('80 0e 0a 000101040a000001 00 00')
    assert_equal [[9, RESET]], check('80 0f 02 0001')
  end

  # RFC 7606 section 3 (c).
  def test_flags
    assert_equal [[4, TAW]], check('c0 01 01 00')
    assert_equal [[4, TAW]], check('c0 04 04 00000064')
    assert_equal [], check('60 01 01 00')        # the Partial bit is not checked
    assert_equal [], check('50 01 0001 00')      # nor the Extended Length bit
  end

  # RFC 4271 section 6.3.
  def test_unknown_types
    assert_equal [[2, RESET]], check('40 fa 01 78')
    assert_equal [], check('c0 fa 01 78')
    assert_equal [], check('80 fa 01 78')
  end

  # RFC 7606 section 4.
  def test_next_attribute_splits_and_reports_cuts
    s = b('40010100 4003040a000001')
    a, f = Attr::Check.next_attribute(s)
    assert_equal '40010100', a.unpack1('H*')
    assert_nil f
    assert a.is_packed?

    s = b('40 03 08 0a000001')
    a, f = Attr::Check.next_attribute(s)
    assert_equal '4003080a000001', a.unpack1('H*')
    assert_equal [3, 1, TAW], [f.type, f.subcode, f.action]
    assert_match(/4 octets left/, f.reason)
    assert_equal 0, s.size

    a, f = Attr::Check.next_attribute(b('4001'))
    assert_equal [nil, 1, TAW], [f.type, f.subcode, f.action]
  end

  def test_exact_reports_a_short_length_field
    # Parsing never sees this: next_attribute cuts at the length field.
    assert_equal [], check('40 01 01 0000')
    findings = Attr::Check.attribute(b('40 01 01 0000'), false, exact: true)
    assert_equal 1, findings.size
    assert_match(/length 1 but 2/, findings.first.reason)
  end

  def test_duplicates
    assert_equal [1, DISCARD], [Attr::Check.duplicate_finding(1).subcode, Attr::Check.duplicate_finding(1).action]
    assert_equal RESET, Attr::Check.duplicate_finding(14).action
    assert_equal RESET, Attr::Check.duplicate_finding(15).action
  end

  # RFC 7606 section 3 (h).
  def test_strongest
    d = Attr::Finding.new(6, 5, DISCARD, 'x')
    t = Attr::Finding.new(1, 5, TAW, 'y')
    r = Attr::Finding.new(14, 1, RESET, 'z')
    n = Attr::Finding.new(2, nil, nil, 'note')
    assert_equal t, Attr.strongest([d, t, n])
    assert_equal r, Attr.strongest([d, r, t])
    assert_nil Attr.strongest([n])
  end

  def test_finding_notification
    f = Attr::Finding.new(1, 6, TAW, 'x')
    assert_equal [3, 6], f.notification.to_hash.values_at(:code, :subcode)
    assert_nil Attr::Finding.new(1, nil, nil, 'x').notification
    assert_equal 'attribute 1: x (treat_as_withdraw)', f.to_s
  end

  # A Gap says bgp4r could not read an attribute, which is not a thing
  # a peer did wrong: RFC 7606 section 7 says what makes each attribute
  # malformed and a reader's missing code is not on any of those lists.
  # So it is not a Finding and carries nothing the RFC 7606 machinery
  # could act on.
  def test_gap_is_not_a_finding
    g = Attr::Gap.new(14, 'cannot parse nexthop for safi 70', ArgumentError, nil)
    assert_equal 'attribute 14: bgp4r could not decode it: cannot parse nexthop for safi 70', g.to_s
    assert_equal 'attribute ?: bgp4r could not decode it: x', Attr::Gap.new(nil, 'x', nil, nil).to_s
    assert_not_kind_of Attr::Finding, g
    assert !g.respond_to?(:action)
    assert !g.respond_to?(:subcode)
    assert !g.respond_to?(:notification)
  end

  def test_malformed_attribute
    e = Malformed_attribute.new([Attr::Finding.new(6, 5, DISCARD, 'a'), Attr::Finding.new(1, 6, TAW, 'b')])
    assert_equal [1, 6, TAW], [e.type, e.subcode, e.action]
    assert_equal 2, e.findings.size
    assert_equal 'attribute 1: b (treat_as_withdraw)', e.message
  end

  # Flow spec, RFC 8955 section 4.2 and RFC 8956. SAFI 133 and 134 are
  # the only SAFIs with an NLRI these rules apply to.
  #
  # **The subcode and the action are not RFC 8955's and the comment on
  # flow_spec_finding says where they come from.** Section 10 is four
  # lines and defines neither: "Error handling according to [RFC7606]
  # and [RFC4760] applies to this specification." So a malformed rule
  # makes the attribute carrying it malformed and gets what bgp4r
  # already gives a malformed MP_REACH, 9 and a session reset.
  #
  # Every hex string below was built with the library and read back
  # before it was pasted here, rather than typed from the layout.

  # A rule that is well formed is not reported, which is the assertion
  # the three below are measured against.
  def test_good_flow_spec_rules_have_no_findings
    [ # RFC 8955 section 4.3.1, destination with a protocol and a port
      '800e11 000185 0000 0b 0118c00002 038106 048119',
      # RFC 8956, an IPv6 destination with an upper-layer protocol
      '800e10 000285 0000 0a 01200020010db8 038106',
      # SAFI 134, the section 8 Route Distinguisher in front
      '800e13 000186 0000 0d 00000064000000c8 0118c00002',
      # a withdrawal, which is the other parse loop
      '800f09 000185 05 0118c00002',
      # two rules in one attribute
      '800e11 000185 0000 05 0118c00002 05 0218cb0071',
    ].each { |hex| assert_equal [], check(hex), hex }
  end

  # Section 4.2: "Components MUST follow strict type ordering by
  # increasing numerical order."
  def test_flow_spec_components_out_of_order
    assert_equal [[9, RESET]], check('800e0e 000185 0000 08 048119 0118c63364')
    assert_equal 'flow spec component type 1 after type 4, which is not increasing (RFC 8955 section 4.2)',
                 reason('800e0e 000185 0000 08 048119 0118c63364')
    # and under RFC 8956, where type 13 exists and type 1 still sorts first
    assert_equal [[9, RESET]],
                 check('800e13 000285 0000 0d 0da100000007 01200020010db8')
  end

  # The other half of section 4.2: "A given component type MAY (exactly
  # once) be present in the Flow Specification." Equal is not increasing
  # either, so a repeat breaks both halves and gets its own words.
  def test_a_flow_spec_component_type_twice
    hex = '800e11 000185 0000 0b 0118cb0071 048119 048150'
    assert_equal [[9, RESET]], check(hex)
    assert_equal 'flow spec component type 4 appears more than once (RFC 8955 section 4.2)',
                 reason(hex)
  end

  # Section 4.2: an NLRI "not encoded as specified here, including an
  # NLRI that contains an unknown component type, is considered
  # malformed". Type 99 is Unassigned for both families in RFC 8956
  # section 8.1.2.
  #
  # **The known types come from Flow_spec::COMPONENTS**, so a component
  # class added to the library stops being unknown here on the same day
  # and this check cannot call a type unknown that bgp4r implements.
  def test_an_unknown_flow_spec_component_type
    hex = '800e0f 000185 0000 09 0119c00002 80638105'
    assert_equal [[9, RESET]], check(hex)
    assert_equal 'unknown flow spec component type 99 (RFC 8955 section 4.2)', reason(hex)
    # type 13 is Unassigned for IPv4 and Flow Label for IPv6, so the
    # same octets are malformed in one family and fine in the other
    v4 = '800e0c 000185 0000 06 0da100000007'
    v6 = '800e0c 000285 0000 06 0da100000007'
    assert_equal [[9, RESET]], check(v4), 'type 13 is Unassigned for IPv4'
    assert_equal 'unknown flow spec component type 13 (RFC 8955 section 4.2)', reason(v4)
    assert_equal [], check(v6), 'and Flow Label for IPv6'
  end

  # The section 4.1 framing, which is Flow_spec.nlri_size rather than a
  # second copy of the rule.
  def test_flow_spec_nlri_framing
    assert_equal [[9, RESET]], check('800e07 000185 0000 0b 01')
    assert_equal 'flow spec NLRI of 12 octets runs past the attribute, 2 left (RFC 8955 section 4.1)',
                 reason('800e07 000185 0000 0b 01')
    # 0xf0 opens the 2 octet form of section 4.1 and nothing follows it
    assert_equal [[9, RESET]], check('800e06 000185 0000 f0')
    assert_equal '1 octet left, too few for a flow spec NLRI length field (RFC 8955 section 4.1)',
                 reason('800e06 000185 0000 f0')
    # section 4.2 encodes the value as <[component]+>, one or more
    assert_equal [[9, RESET]], check('800e06 000185 0000 00')
    assert_equal 'flow spec NLRI with no component (RFC 8955 section 4.2)',
                 reason('800e06 000185 0000 00')
    # a component whose own fields run past the NLRI it sits in
    assert_equal [[9, RESET]], check('800e08 000185 0000 02 0118')
    # and the same through MP_UNREACH, whose loop is a separate copy
    assert_equal [[9, RESET]], check('800f06 000185 02 0118')
  end

  # RFC 8955 section 8: "The NLRI length field shall include both the 8
  # octets of the Route Distinguisher as well as the subsequent Flow
  # Specification NLRI value."
  def test_a_vpn_flow_spec_rule_too_short_for_its_route_distinguisher
    hex = '800e0a 000186 0000 04 01020304'
    assert_equal [[9, RESET]], check(hex)
    assert_equal '4 octets, a SAFI 134 rule needs 8 for its Route Distinguisher (RFC 8955 section 8)',
                 reason(hex)
  end

  # The prefix families must be untouched by all of the above, since
  # their NLRI is not a component list and none of these rules applies.
  def test_the_prefix_families_are_not_flow_spec_checked
    assert_equal [], check('800e0d 000101 04 0a000001 00 18c00002')
    assert_equal [], check('800f05 000101 18c00002')
    # SAFI 4, 128 and 129 likewise
    assert_equal [], check('800f05 000104 18c00002')
  end

  # The reason of the one finding for hex, so a test can assert which
  # rule fired rather than only that something did.
  def reason(hex)
    f = Attr::Check.attribute(b(hex), false)
    f.size == 1 ? f.first.reason : f.collect(&:reason)
  end

end
