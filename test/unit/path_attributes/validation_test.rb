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

  # **The order is RFC 7606 section 2's own and the section names the
  # direction**, read first hand on 2026-11-01: the approaches are
  # listed "from the one with the 'strongest' action to the one with the
  # 'weakest' action", which is session reset, AFI/SAFI disable,
  # treat-as-withdraw, attribute discard. `ACTIONS` is that reversed,
  # since `strongest` is `max_by` over the index.
  #
  # Asserted as the whole list rather than pairwise, because the thing
  # that would go wrong is an insertion in the wrong place, and that
  # moves a verdict for every family rather than for the one being
  # added to.
  def test_the_action_order_is_rfc_7606_section_2_reversed
    assert_equal([:nlri_discard, :attribute_discard, :treat_as_withdraw,
                  :afi_safi_disable, :session_reset],
                 Attr::ACTIONS)
    # Section 2's four, strongest first, as the section prints them.
    assert_equal([:session_reset, :afi_safi_disable, :treat_as_withdraw,
                  :attribute_discard],
                 (Attr::ACTIONS - [:nlri_discard]).reverse)
  end

  # **The three that existed keep their relative order**, which is what
  # says adding two moved no other family's verdict. Part 6a is a change
  # to machinery every family's findings go through, so this is the
  # assertion that bounds it.
  def test_adding_two_actions_moved_neither_of_the_other_three
    assert_equal([:attribute_discard, :treat_as_withdraw, :session_reset],
                 Attr::ACTIONS.select { |a|
                   [:attribute_discard, :treat_as_withdraw,
                    :session_reset].include?(a) })
  end

  # RFC 9552 section 8.2.2's two, which part 6b is the first caller of.
  # `:afi_safi_disable` outranks treat-as-withdraw and is outranked by a
  # session reset, which is section 2's order; `:nlri_discard` is the
  # weakest, which is **this library's decision and not the RFC's**,
  # since the RFC does not rank it: 8.2.2 makes it the case where the
  # router continues processing the rest of the UPDATE, as attribute
  # discard is, and it loses one NLRI where that loses every TLV of an
  # attribute.
  def test_the_two_new_actions_rank_where_they_should
    nd = Attr::Finding.new(29, nil, Attr::Check::NLRI_DISCARD, 'one nlri')
    ad = Attr::Finding.new(29, nil, DISCARD, 'the attribute')
    t  = Attr::Finding.new(1, 5, TAW, 'y')
    fd = Attr::Finding.new(14, 9, Attr::Check::AFI_DISABLE, 'the family')
    r  = Attr::Finding.new(14, 9, RESET, 'the session')
    assert_equal ad, Attr.strongest([nd, ad])
    assert_equal t,  Attr.strongest([nd, ad, t])
    assert_equal fd, Attr.strongest([nd, ad, t, fd])
    assert_equal r,  Attr.strongest([nd, ad, t, fd, r])
    assert_equal nd, Attr.strongest([nd]), 'and on its own it is the one'
  end

  # **A Finding whose action is not in `ACTIONS` crashes `strongest`**,
  # because `index` answers nil and `max_by` then compares nil against
  # an Integer. That is why an action is added to the list and not only
  # used, and it is worth pinning: the next one added to a Finding alone
  # fails here rather than in whatever reads the findings.
  def test_an_action_outside_the_list_cannot_be_ranked
    bogus = Attr::Finding.new(1, nil, :no_such_action, 'x')
    assert_raise_kind_of(StandardError) do
      Attr.strongest([bogus, Attr::Finding.new(1, nil, DISCARD, 'y')])
    end
  end

  # **Neither new action resets a session, and neither should.**
  # `Neighbor#rcv_malformed` keys on `:session_reset` by name, so this
  # is what says the vocabulary grew without the FSM's behaviour
  # changing. RFC 9552 section 8.2.2 reaches a reset through its own
  # branch, which part 6b reports as `:session_reset` like every other
  # family's framing finding.
  def test_only_a_session_reset_sends_a_notification
    body = File.read('bgp/neighbor/neighbor.rb')
    assert_not_equal(nil, body[/e\.action == :session_reset/],
                     'the FSM keys on :session_reset by name')
    [Attr::Check::NLRI_DISCARD, Attr::Check::AFI_DISABLE].each do |a|
      assert_not_equal(:session_reset, a)
      assert(Attr::ACTIONS.include?(a), "#{a} must be rankable")
    end
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

  # EVPN, AFI 25 SAFI 70. Every hex string below was built with the
  # library and read back before it was pasted here, rather than typed
  # from the layout.
  #
  # **Where the action and the subcode come from, because the route type
  # RFCs mostly do not say.** RFC 7432 and RFC 9572 carry no error
  # handling text at all. RFC 9251 section 9.7 is the only EVPN RFC that
  # does, and it agrees with what bgp4r already gives a malformed
  # MP_REACH: a route key that cannot be extracted means "the 'session
  # reset' procedure per [RFC7606]". Where a route type's own RFC names
  # treat-as-withdraw instead, that wins.

  # A well formed EVPN route is not reported, which is what the rest of
  # these are measured against. All eleven route types reach here and
  # only two have rules, so most of this list is the no-rules path.
  def test_good_evpn_routes_have_no_findings
    [ # route type 1, RFC 7432 section 7.1
      '800e24 001946 04 0a000001 00 0119 00000064000000c8 00000000000000000000 00000000 000641',
      # route type 5 with IPv4 addresses, RFC 9136 section 3.1
      '800e2d 001946 04 0a000001 00 0522 00000064000000c8 00000000000000000000 00000000 08 0a000000 00000000 001f41',
      # and with IPv6 ones, the 58 octet form
      '800e45 001946 04 0a000001 00 053a 00000064000000c8 00000000000000000000 00000000 20 20010db8000000000000000000000000 ' \
        '00000000000000000000000000000000 001f41',
      # route type 5 with an ESI and no GW IP, which section 3.2 allows
      '800e2d 001946 04 0a000001 00 0522 00000064000000c8 00000000000000000001 00000000 08 0a000000 00000000 001f41',
      # route type 6 with its v2 flag set, RFC 9251 section 9.1
      '800e23 001946 04 0a000001 00 0618 00000064000000c8 00000000 00 20 ef010101 20 0a000001 02',
      # route type 11, whose Route Key is an NLRI of its own
      '800e29 001946 04 0a000001 00 0b1e 0a17 0000000100000001 00000000 00 20 ef010101 20 0a000001 20 0a000002',
      # two routes in one attribute
      '800e69 001946 04 0a000001 00 0522 00000064000000c8 00000000000000000000 00000000 08 0a000000 00000000 001f41 ' \
        '053a 00000064000000c8 00000000000000000000 00000000 20 20010db8000000000000000000000000 ' \
        '00000000000000000000000000000000 001f41',
      # a withdrawal, which is the other parse loop
      '800f1d 001946 0618 00000064000000c8 00000000 00 20 ef010101 20 0a000001 02',
      # **and an unregistered route type, which is not an error.** No
      # EVPN RFC says a route type outside its own is malformed, where
      # RFC 8955 section 4.2 says exactly that about a flow spec
      # component type. Types 12 to 255 are unassigned, so reporting one
      # would call a correct router malformed the day IANA assigns it.
      '800e0f 001946 04 0a000001 00 0c04 01020304',
    ].each { |hex| assert_equal [], check(hex), hex }
  end

  # The RFC 7432 section 7 framing, which is Evpn.nlri_size rather than
  # a second copy of the rule.
  def test_evpn_nlri_framing
    short = '800e25 001946 04 0a000001 00 0119 00000064000000c8 00000000000000000000 00000000 000641 05'
    assert_equal [[9, RESET]], check(short)
    assert_equal '1 octet left, too few for an EVPN Route Type and Length (RFC 7432 section 7)',
                 reason(short)
    past = '800e24 001946 04 0a000001 00 01ff 00000064000000c8 00000000000000000000 00000000 000641'
    assert_equal [[9, RESET]], check(past)
    assert_equal 'EVPN NLRI of 257 octets runs past the attribute, 27 left (RFC 7432 section 7)',
                 reason(past)
    # and the same through MP_UNREACH, whose loop is a separate copy
    assert_equal [[9, RESET]],
                 check('800f1e 001946 01ff 00000064000000c8 00000000000000000000 00000000 000641')
  end

  # RFC 9136 section 3.1: "The Length field of the BGP EVPN NLRI for an
  # EVPN IP Prefix route MUST be either 34 (if IPv4 addresses are
  # carried) or 58 (if IPv6 addresses are carried)." The two sizes come
  # from the class, so they cannot drift from what it encodes.
  def test_an_evpn_ip_prefix_route_of_the_wrong_length
    hex = '800e2c 001946 04 0a000001 00 0521 00000064000000c8 00000000000000000000 00000000 08 0a000000 00000000 001f'
    assert_equal [[9, RESET]], check(hex)
    assert_equal 'EVPN IP Prefix route of 33 octets, must be 34 or 58 (RFC 9136 section 3.1)',
                 reason(hex)
    assert_equal [34, 58], [BGP::Evpn::Ip_prefix_route::SIZE_V4,
                            BGP::Evpn::Ip_prefix_route::SIZE_V6]
  end

  # RFC 9136 section 3.1: the IP prefix length "specifies the number of
  # bits in the prefix. The value MUST NOT be greater than 128." The
  # section names no receiver action, so the generic MP_REACH one
  # applies, and the prefix length is part of the route key, so this
  # fires on a withdrawal too.
  def test_an_evpn_ip_prefix_length_over_128
    hex = '800e2d 001946 04 0a000001 00 0522 00000064000000c8 00000000000000000000 00000000 c8 0a000000 00000000 001f41'
    assert_equal [[9, RESET]], check(hex)
    assert_equal 'IP prefix length 200, must not be greater than 128 (RFC 9136 section 3.1)',
                 reason(hex)
    assert_equal [[9, RESET]],
                 check('800f27 001946 0522 00000064000000c8 00000000000000000000 00000000 c8 0a000000 00000000 001f41')
  end

  # RFC 9136 section 3.2: "The ESI and GW IP fields may both be zero at
  # the same time. However, they MUST NOT both be non-zero at the same
  # time. A route containing a non-zero GW IP and a non-zero ESI (at the
  # same time) SHOULD be treat as withdraw [RFC7606]."
  def test_an_evpn_ip_prefix_route_with_both_an_esi_and_a_gw_ip
    hex = '800e2d 001946 04 0a000001 00 0522 00000064000000c8 00000000000000000001 00000000 08 0a000000 0a000009 001f41'
    assert_equal [[9, TAW]], check(hex)
    assert_equal 'a non-zero ESI and a non-zero GW IP at the same time (RFC 9136 section 3.2)',
                 reason(hex)
    # **Not on a withdrawal.** Section 3.1 says only "The RD, Ethernet
    # Tag ID, IP prefix length, and IP prefix are part of the route key",
    # so a withdrawal's ESI and GW IP are don't-care and reporting them
    # would be reporting a correct withdrawal.
    assert_equal [],
                 check('800f27 001946 0522 00000064000000c8 00000000000000000001 00000000 08 0a000000 0a000009 001f41')
  end

  # RFC 9251 section 4.1: "the received EVPN route MUST have at least one
  # version flag set. If all version flags are reset, it is an error
  # because the PE should have received an EVPN route withdraw for the
  # last version flag. An error MUST be considered as a BGP error, and
  # the PE MUST apply the 'treat-as-withdraw' procedure per [RFC7606]."
  def test_an_evpn_smet_route_with_no_version_flag
    hex = '800e23 001946 04 0a000001 00 0618 00000064000000c8 00000000 00 20 ef010101 20 0a000001 00'
    assert_equal [[9, TAW]], check(hex)
    assert_equal 'an EVPN SMET route with no IGMP version flag set (RFC 9251 section 4.1)',
                 reason(hex)
    # **Not on a withdrawal, and this one matters most.** Section 4.1
    # asks a PE to withdraw the route rather than re-advertise it with
    # the flags reset, and section 9.1 says the Flags octet is not part
    # of the prefix in the NLRI. So checking an MP_UNREACH here would
    # report the very withdrawal the RFC asked for.
    assert_equal [],
                 check('800f1d 001946 0618 00000064000000c8 00000000 00 20 ef010101 20 0a000001 00')
    # The flag mask is the class's own, so it cannot drift from what the
    # route encodes.
    assert_equal 0x07, BGP::Evpn::Flags::V1 | BGP::Evpn::Flags::V2 | BGP::Evpn::Flags::V3
  end

  # RFC 9251 section 9.7: a route key that cannot be extracted gets the
  # session reset procedure. Two ways an SMET route reaches that.
  def test_an_evpn_smet_route_too_short_for_its_route_key
    hex = '800e17 001946 04 0a000001 00 060c 00000064000000c8 00000000'
    assert_equal [[9, RESET]], check(hex)
    assert_equal 'EVPN SMET route of 12 octets, too few for its route key, which needs 16 (RFC 9251 section 9.7)',
                 reason(hex)
    # A length field claiming more octets than are left. 200 bits is at
    # least 25 octets under any reading of the bit count, which is what
    # makes this safe to report where ruling on the count itself would
    # not be: RFC 6514 section 4.3 gives 32 and 128 and calls other
    # values "outside the scope", so bgp4r echoes any of them.
    lying = '800e23 001946 04 0a000001 00 0618 00000064000000c8 00000000 c8 20 ef010101 20 0a000001 02'
    assert_equal [[9, RESET]], check(lying)
    assert_equal 'EVPN SMET route address 1 runs past the route, leaving no Flags octet (RFC 9251 section 9.7)',
                 reason(lying)
    assert_equal 16, BGP::Evpn::Selective_multicast::FIXED_SIZE
  end

  # The prefix families and flow spec must be untouched by all of the
  # above, and an EVPN route must not be flow spec checked either.
  def test_the_other_families_are_not_evpn_checked
    assert_equal [], check('800e0d 000101 04 0a000001 00 18c00002')
    assert_equal [], check('800f05 000102 18c00002')
    # AFI 25 with a SAFI that is not 70: these rules do not apply, so a
    # VPLS NLRI is not read as an EVPN route.
    assert_equal [], check('800f05 001941 18c00002')
    # and a flow spec rule is still flow spec checked, not EVPN checked
    assert_equal [[9, RESET]], check('800e0f 000185 0000 09 0119c00002 80638105')
    assert_equal 'unknown flow spec component type 99 (RFC 8955 section 4.2)',
                 reason('800e0f 000185 0000 09 0119c00002 80638105')
  end

  # Building a route no RFC allows must still work, per Conventions:
  # validation is receive side and nothing on the way out refuses this.
  def test_building_an_evpn_route_no_rfc_allows_still_works
    r = BGP::Evpn::Ip_prefix_route.new([100, 200], BGP::Evpn::Esi.new(1), 0,
                                       '10.0.0.0/8', '10.0.0.9', 500)
    assert_equal 34, r.encode.size
    s = BGP::Evpn::Selective_multicast.new([100, 200], 0, nil, '239.1.1.1', '10.0.0.1')
    assert_equal 0, s.flags.value
    # And the attribute carrying one replays byte for byte, so bgp4r
    # reports the fault without changing an octet.
    hex = '800e2d001946040a00000100052200000064000000c80000000000000000000100000000080a0000000a000009001f41'
    pa = BGP::Path_attribute.new([hex].pack('H*').is_packed)
    assert_equal hex, pa.to_shex
    assert_equal 1, pa.errors.size
    assert_equal [], pa.undecoded, 'the route decodes, so this is not a coverage gap'
  end

  # **RFC 8317 section 6.2: "Using the composite tunnel bit for Tunnel
  # Types 0x00 'no tunnel information present' and 0x06 'Ingress
  # Replication' is invalid"**, and such an attribute is treated "as
  # though all the routes contained in this Update had been withdrawn".
  # The subcode is the one the PMSI length finding already uses, since
  # the section names none.
  def test_a_composite_pmsi_tunnel_of_type_0_or_6_is_invalid
    { 0x80 => 0, 0x86 => 6 }.each do |octet, base|
      hex = 'c01609' + '00' + format('%02x', octet) + '000640' + '0a000001'
      assert_equal [[5, TAW]], check(hex), format('tunnel type 0x%02x', octet)
      assert_match(/composite tunnel bit with tunnel type #{base} /, reason(hex))
      assert_match(/RFC 8317 section 6\.2/, reason(hex))
      # And the octets survive, so a test can still put it on the wire
      # and watch a router decide.
      pa = BGP::Path_attribute.new(b(hex))
      assert_equal hex, pa.to_shex
      assert_equal [], pa.undecoded, 'the attribute decodes, so this is no gap'
    end
  end

  # **The bit on its own is not an error and must not become one.** Every
  # other composite tunnel type is valid, and RFC 8317 section 8.1
  # reserves 0x80 to 0xfa for Composite Tunnel, so reporting the bit
  # would make bgp4r call a correct router malformed.
  def test_every_other_composite_pmsi_tunnel_type_is_clean
    # 0x82 mLDP P2MP, 0x8b BIER, 0xff the wildcard transport tunnel
    # type of RFC 8338, whose base 0x7f is Reserved and not 0 or 6.
    [0x82, 0x83, 0x8b, 0xfa, 0xff,
     0x00, 0x06, 0x02].each do |octet|
      hex = 'c01609' + '00' + format('%02x', octet) + '000640' + '0a000001'
      assert_equal [], check(hex), format('tunnel type 0x%02x', octet)
    end
  end

  # ATTR_SET, RFC 6368 section 5. Well formed first, which is what the
  # three rules below are measured against. The second is the one that
  # matters most: section 5 fixes the AS size inside the set, so a
  # 4-octet nested AS_PATH is conformant and must not be reported, and
  # it is reported if attr_set_finding passes the session's as4byte
  # instead of true.
  def test_good_attr_sets_have_no_findings
    [ # the Origin AS alone, the 4 octet minimum
      'c0 80 04 0000fde8',
      # an ORIGIN and a LOCAL_PREF inside
      'c0 80 0f 0000fde8 40010100 40050400000064',
      # a 4-octet AS_PATH inside, which section 5 requires
      'c0 80 11 0000fde8 40020a 02020000fde90000fdea',
      # a 4-octet AGGREGATOR inside
      'c0 80 0f 0000fde8 c00708 fa56ea01 0a000001',
      # a set inside a set
      'c0 80 0f 0000fde8 c080080000fde940010100',
    ].each { |hex| assert_equal [], check(hex), hex }
  end

  # Section 5: the value is a 4-octet Origin AS then the attributes, so
  # a value below 4 octets cannot hold the one fixed field.
  def test_an_attr_set_shorter_than_its_origin_as
    assert_equal [[5, TAW]], check('c0 80 03 000000')
    assert_equal 'length 3, needs at least 4 for the Origin AS (RFC 6368 section 5)',
                 reason('c0 80 03 000000')
    assert_equal [[5, TAW]], check('c0 80 00')
  end

  # Section 5: the set "can carry any attribute that can appear in a BGP
  # UPDATE" except MP_REACH and MP_UNREACH.
  def test_an_attr_set_carrying_mp_reach_or_mp_unreach
    reach = 'c0 80 12 0000fde8 800e0b 0001 01 04 0a000001 00 0814'
    assert_equal [[9, TAW]], check(reach)
    assert_equal 'includes attribute 14, which RFC 6368 section 5 excludes',
                 reason(reach)
    unreach = 'c0 80 0c 0000fde8 800f05 0001 01 0814'
    assert_equal [[9, TAW]], check(unreach)
    assert_equal 'includes attribute 15, which RFC 6368 section 5 excludes',
                 reason(unreach)
  end

  # Section 5's third condition, and it is implemented by reusing
  # Attr::Check.attribute on each nested attribute rather than by
  # repeating any rule, so a rule added anywhere else reaches inside a
  # set the same day.
  def test_an_attr_set_whose_included_attribute_is_malformed
    # ORIGIN value 7, which RFC 7606 section 7.1 makes malformed
    bad_origin = 'c0 80 08 0000fde8 40010107'
    assert_equal [[9, TAW]], check(bad_origin)
    assert_match(/included attribute 1 is malformed/, reason(bad_origin))
    assert_match(/undefined ORIGIN value 7/, reason(bad_origin))
    # a nested length that runs past the end of the set
    cut = 'c0 80 07 0000fde8 400105'
    assert_equal [[9, TAW]], check(cut)
    assert_match(/included attribute is malformed/, reason(cut))
    # and nested one level deeper, through the recursion
    deep = 'c0 80 0f 0000fde8 c080080000fde940010107'
    assert_equal [[9, TAW]], check(deep)
  end

  # RFC 7606 section 7.16 replaces the final paragraph of RFC 6368
  # section 5 outright: "An UPDATE message with a malformed ATTR_SET
  # attribute SHALL be handled using the approach of 'treat as
  # withdraw'". So no ATTR_SET finding is a reset, whatever RFC 6368's
  # own superseded text said about Optional Attribute Error.
  def test_every_attr_set_finding_is_treat_as_withdraw
    [ 'c0 80 03 000000',
      'c0 80 12 0000fde8 800e0b 0001 01 04 0a000001 00 0814',
      'c0 80 08 0000fde8 40010107',
      'c0 80 07 0000fde8 400105',
    ].each do |hex|
      actions = check(hex).collect(&:last)
      assert_equal [TAW], actions.uniq, hex
    end
  end

  # RFC 6368 section 5 and RFC 7606 section 3 (c): optional transitive.
  def test_an_attr_set_with_the_wrong_flags
    assert_equal [[4, TAW]], check('80 80 04 0000fde8'), 'optional, not transitive'
    assert_equal [[4, TAW]], check('40 80 04 0000fde8'), 'transitive, not optional'
  end

  # MCAST-VPN, SAFI 5, AFI 1 or 2. Every clean hex string below was
  # built with the library and pasted, which is the rule this family
  # earned: RFC 6514 carries no worked example and no hex, and typing
  # one by hand has been wrong nine times across its six parts and the
  # library right every time. The malformed ones are hand built, because
  # the library will not encode them.
  #
  # **Where the action and the subcode come from, which is not a
  # derivation.** RFC 6514 and the bis draft carry no NLRI error
  # handling text at all. The four checks are RFC 6515 section 2's, one
  # per item, each saying the MP_REACH_NLRI attribute "MUST be
  # considered to be 'incorrect', and MUST be handled as specified in
  # Section 7 of [BGP-MP]". RFC 7606's header says `Updates: 4760` and
  # its section 7.11 states that generally: a next hop length
  # "inconsistent with that which was expected" is malformed, and
  # because the next hop precedes the NLRI the "session reset" approach
  # MUST be used. Its own example is RFC 6515's sentence from the other
  # end, "if [RFC5549] is in use, then the next hop would have to have a
  # length of 4 or 16". So subcode 9 with a reset, the same as the two
  # MP_REACH findings this file already asserts.

  # A well formed MCAST-VPN route is not reported, which is what the
  # rest of these are measured against. All seven route types reach
  # here and three have rules, so most of this list is the no-rules
  # path.
  def test_good_mcast_vpn_routes_have_no_findings
    [ # route type 1, RFC 6514 section 4.1, and the 12 octet NLRI length
      # RFC 6515 section 2 item 2 states
      '800e17 000105 04 0a000001 00 010c 00000064000000c8 0a000001',
      # the same with IPv6 throughout, which is its 24
      '800e2f 000105 10 20010db80000000000000000000000010001 1800000064000000c8' \
        '20010db8000000000000000000000009',
      # route type 2, section 4.2, which carries no address of its own
      '800e17 000105 04 0a000001 00 020c 00000064000000c8 0000fde8',
      # route type 3, section 4.3, with IPv6 source, group and originator
      '800e45 000105 04 0a000001 00 033a 00000064000000c8 8020010db8000000000000000000000001' \
        '80ff3e0000000000000000000000000001 20010db8000000000000000000000009',
      # route type 4, section 4.4, whose Route Key is an NLRI of its own
      '800e1d 000105 04 0a000001 00 0412 020c00000064000000c80000fde8 0a000001',
      # route types 5 and 6 in one attribute, neither of which carries an
      # Originating Router and so neither of which has a rule
      '800e35 000105 04 0a000001 00 0512 00000064000000c8 200a010101 20e8010101' \
        ' 0616 00000064000000c8 0000fde8 200a010101 20e8010101',
      # **an mLDP route type, which is not an error.** No MCAST-VPN RFC
      # says a route type outside its own is malformed, where RFC 8955
      # section 4.2 says exactly that about a flow spec component type.
      # 0x43 is assigned, as RFC 7441's form of route type 3, and out of
      # scope by decision, so reporting it would call a conformant mLDP
      # speaker malformed.
      '800e10 000105 04 0a000001 00 4305 0102030405',
      # a withdrawal, which is the other parse loop
      '800f1b 000105 0316 00000064000000c8 200a010101 20e8010101 0a000001',
      # and AFI 2, which RFC 6514 section 4 allows and nothing reads
      # differently
      '800e2f 000205 10 20010db80000000000000000000000010001 1800000064000000c8' \
        '20010db8000000000000000000000009',
    ].each { |hex| assert_equal [], check(hex), hex }
  end

  # RFC 6515 section 2 item 1, through RFC 7606 section 7.11: the next
  # hop length is 4 or 16 and nothing else. **This is the one next hop
  # length check in the library**, and the reason it is only this family
  # is which RFC names the error: RFC 7432 section 14 and RFC 4684
  # section 4 each state an expectation and no receiver action, where
  # RFC 6515 states both. See docs/mcast-vpn.md section 8.
  def test_an_mcast_vpn_next_hop_of_the_wrong_length
    { 8  => 'aaaaaaaaaaaaaaaa',
      12 => 'aaaaaaaaaaaaaaaaaaaaaaaa',
      0  => '' }.each do |len, nh|
      body = '000105' + format('%02x', len) + nh + '00' +
             '010c00000064000000c80a000001'
      hex = '800e' + format('%02x', body.size / 2) + body
      assert_equal [[9, RESET]], check(hex), "next hop of #{len} octets"
      assert_equal "MCAST-VPN next hop of #{len} octets, must be 4 or 16 " \
                   '(RFC 6515 section 2, RFC 7606 section 7.11)',
                   reason(hex)
    end
  end

  # The RFC 6514 section 4 framing, which is Mcast_vpn.nlri_size rather
  # than a second copy of the rule. No MCAST-VPN RFC asks for this, so
  # it takes the generic action for the reason above.
  def test_mcast_vpn_nlri_framing
    short = '800e18 000105 04 0a000001 00 010c 00000064000000c8 0a000001 05'
    assert_equal [[9, RESET]], check(short)
    assert_equal '1 octet left, too few for an MCAST-VPN Route Type and Length ' \
                 '(RFC 6514 section 4)', reason(short)
    past = '800e17 000105 04 0a000001 00 01ff 00000064000000c8 0a000001'
    assert_equal [[9, RESET]], check(past)
    assert_equal 'MCAST-VPN NLRI of 257 octets runs past the attribute, 14 left ' \
                 '(RFC 6514 section 4)', reason(past)
    # and the same through MP_UNREACH, whose loop is a separate copy
    assert_equal [[9, RESET]], check('800f11 000105 01ff 00000064000000c8 0a000001')
  end

  # RFC 6515 section 2 items 2, 3 and 4: the Originating Router's IP
  # Address is 4 or 16 octets, and its width is what the NLRI length
  # leaves over. One sentence stated three times, so the library answers
  # it in one place reached by three route types.
  def test_an_mcast_vpn_originating_router_of_the_wrong_width
    { # route type 1: 8 octets left after the RD
      1 => ['800e1b 000105 04 0a000001 00 0110 00000064000000c8 aabbccddeeff0011', 8],
      # route type 3: 8 left after the RD, source and group
      3 => ['800e25 000105 04 0a000001 00 031a 00000064000000c8 200a010101 20e8010101' \
            ' aabbccddeeff0011', 8],
      # route type 4: 2 left after the Route Key, whose own Length says
      # where it ends
      4 => ['800e1b 000105 04 0a000001 00 0410 020c00000064000000c80000fde8 aabb', 2],
    }.each do |rt, (hex, width)|
      assert_equal [[9, RESET]], check(hex), "route type #{rt}"
      assert_equal "MCAST-VPN route type #{rt} leaves #{width} octets for its " \
                   "Originating Router's IP Address, must be 4 or 16 " \
                   '(RFC 6515 section 2)', reason(hex)
    end
    # Nothing left at all is the same rule and not a special case.
    none = '800e13 000105 04 0a000001 00 0108 00000064000000c8'
    assert_equal [[9, RESET]], check(none)
    assert_match(/leaves 0 octets/, reason(none))
  end

  # **All four checks are MP_REACH only, and that is RFC 6515's choice
  # rather than a reading of the route key.** Every one of its section 2
  # items names the MP_REACH_NLRI attribute and none mentions
  # MP_UNREACH_NLRI. EVPN's two reach-only rules were derived from what
  # its RFCs call the route key; this one is simply what the document
  # says.
  def test_the_mcast_vpn_route_checks_are_mp_reach_only
    [ # route type 1 with an 8 octet originator, withdrawn
      '800f15 000105 0110 00000064000000c8 aabbccddeeff0011',
      # route type 3, withdrawn
      '800f1f 000105 031a 00000064000000c8 200a010101 20e8010101 aabbccddeeff0011',
      # route type 4, withdrawn
      '800f15 000105 0410 020c00000064000000c80000fde8 aabb',
    ].each { |hex| assert_equal [], check(hex), hex }
    # And the framing is reported either way, because octets that cannot
    # be split are not a question about which attribute holds them.
    assert_equal [[9, RESET]], check('800f06 000105 01ff 0a000001')
  end

  # --- BGP-LS, RFC 9552 section 8.2.2 ---------------------------------
  #
  # **Every vector here is built with the library and pasted**, which is
  # the rule these families have paid for seventeen times: RFC 9552
  # carries no worked example and no hex anywhere, so a hand written
  # expectation checks this reader's arithmetic and not the document.
  # Only the malformed ones are built by hand, because the library will
  # not encode those, and each says which octet it moved.
  #
  # NDL and NDR are a Local and a Remote Node Descriptors TLV, 256 and
  # 257, each holding one Autonomous System sub-TLV. ONE is a Node NLRI
  # carrying NDL; TWO carries both, in order.
  LS   = BGP::Link_state
  def self.nlri(*tlvs) ; LS.new(LS::Node.new(0, 1, *tlvs)).to_shex ; end
  def self.as(n) ; LS::Tlv::Autonomous_system.new(n) ; end
  NDL  = LS::Tlv::Local_node_descriptors.new(as(65000)).to_shex
  NDR  = LS::Tlv::Remote_node_descriptors.new(as(65001)).to_shex
  ONE  = nlri(LS::Tlv::Local_node_descriptors.new(as(65000)))
  TWO  = nlri(LS::Tlv::Local_node_descriptors.new(as(65000)),
              LS::Tlv::Remote_node_descriptors.new(as(65001)))
  DUP  = nlri(LS::Tlv::Local_node_descriptors.new(as(65000), as(65001)))
  # The same two descriptors with 257 written before 256. The head is 9
  # octets after the 4 framing ones, so the TLVs start at character 26.
  SWAP = TWO[0, 26] + TWO[50..] + TWO[26, 24]
  # ONE again under SAFI 72, where figure 6 puts a Route Distinguisher
  # before the head. The same octets read under SAFI 71 are a different
  # valid NLRI, which is why the SAFI is a parse-time input here.
  VPN  = LS.new(:rd => [100, 200],
                :node => { :protocol_id => 0, :identifier => 1,
                           :tlvs => [{ :local_node_descriptors =>
                                       [{ :autonomous_system => 65000 }] }] }
               ).to_shex

  # An MP_REACH or MP_UNREACH around one or more Link-State NLRIs:
  # AFI 16388, the SAFI, and for MP_REACH a next hop and the reserved
  # octet (RFC 4760 section 3).
  def ls_reach(nlri, safi = IANA::SAFI::BGP_LS, nh = '040a000001')
    v = '4004' + format('%02x', safi) + nh + '00' + nlri
    '800e' + format('%02x', v.size / 2) + v
  end

  def ls_unreach(nlri, safi = IANA::SAFI::BGP_LS)
    v = '4004' + format('%02x', safi) + nlri
    '800f' + format('%02x', v.size / 2) + v
  end

  def test_a_clean_bgp_ls_update_has_no_findings
    [ls_reach(ONE), ls_reach(TWO), ls_unreach(ONE), ls_unreach(TWO),
     # SAFI 72, where the NLRI carries a Route Distinguisher and the
     # next hop is 12, 24 or 40 octets.
     ls_reach(VPN, IANA::SAFI::BGP_LS_VPN, '0c' + '00' * 12),
     ls_unreach(VPN, IANA::SAFI::BGP_LS_VPN),
     # and the BGP-LS Attribute itself
     BGP::Link_state_attribute.new(LS::Tlv::Node_name.new('r1')).to_shex,
     BGP::Link_state_attribute.new(LS::Tlv::Node_flag_bits.new(:overload),
                                   LS::Tlv::Node_name.new('r1')).to_shex,
    ].each { |hex| assert_equal [], check(hex), hex }
  end

  # Bullets 1 and 2: "The sum of all TLV lengths found in the BGP
  # MP_REACH_NLRI attribute corresponds to the BGP MP_REACH_NLRI
  # length", and the same sentence for MP_UNREACH_NLRI. Broken framing
  # is the case where no other NLRI in the attribute is locatable, so it
  # is the non-skippable one and gets a session reset.
  def test_the_nlri_list_has_to_land_on_the_attributes_end
    short = ls_reach(ONE + '0001')
    assert_equal [[9, RESET]], check(short)
    assert_match(/too few for a Link-State NLRI Type and Total NLRI Length/,
                 reason(short))
    # Total NLRI Length 0xff15 where 0x0015 arrived.
    over = ls_reach('0001ff15' + ONE[8..])
    assert_equal [[9, RESET]], check(over)
    assert_match(/runs past the attribute, 25 left/, reason(over))
    # Both on a withdrawal too, since bullet 2 is bullet 1's sentence.
    assert_equal [[9, RESET]], check(ls_unreach(ONE + '0001'))
    assert_equal [[9, RESET]], check(ls_unreach('0001ff15' + ONE[8..]))
  end

  # Bullet 3, from the bottom: a body with no room for the Protocol-ID
  # and Identifier of figures 7 to 9 cannot have a TLV sum at all. The
  # outer framing is intact here, so the error is skippable.
  def test_a_body_too_short_for_its_head
    hex = ls_reach('000100050000000000')
    assert_equal [[9, Attr::Check::NLRI_DISCARD]], check(hex)
    assert_match(/has 5 octets, too few for its 9 octet header/, reason(hex))
    # SAFI 72 wants 8 more for the Route Distinguisher (figure 6), so
    # the same body is short there and says so with the larger number.
    vpn = ls_reach('0001000d' + '000000000000000000' + '00000064',
                   IANA::SAFI::BGP_LS_VPN, '0c' + '00' * 12)
    assert_equal [[9, Attr::Check::NLRI_DISCARD]], check(vpn)
    assert_match(/too few for its 17 octet header/, reason(vpn))
  end

  # Bullets 3 and 4, which are one walk: a Length that overruns its
  # container breaks the sum, and a remainder too short to frame a TLV
  # is the same failure from the other end.
  def test_a_tlv_length_that_overruns_its_container
    # TLV 256's own Length made 0xffff.
    tlv = ls_reach(ONE[0, 26] + '0100ffff' + ONE[34..])
    assert_equal [[9, Attr::Check::NLRI_DISCARD]], check(tlv)
    assert_match(/TLV type 256 of 65535 octets runs past NLRI type 1, 8 left/,
                 reason(tlv))
    # "when the TLV is recognized then, the length of its sub-TLVs":
    # sub-TLV 512 inside TLV 256, which is one of the two recognized
    # TLVs in this family that carry any.
    sub = ls_reach(ONE[0, 34] + '0200ffff' + ONE[42..])
    assert_equal [[9, Attr::Check::NLRI_DISCARD]], check(sub)
    assert_match(/TLV type 512 of 65535 octets runs past TLV type 256 in NLRI type 1/,
                 reason(sub))
    # A remainder too short to frame a TLV, which is two octets of tail
    # inside an NLRI whose own Total NLRI Length covers them.
    tail = ls_reach('00010017' + ONE[8..] + '0001')
    assert_equal [[9, Attr::Check::NLRI_DISCARD]], check(tail)
    assert_match(/2 octet left in NLRI type 1, too few for a TLV Type and Length/,
                 reason(tail))
  end

  # Bullet 6, and section 8.2.2 names this one as its own example of a
  # skippable error, so neither the action nor the citation is derived.
  def test_the_section_5_1_ordering_rule
    assert_equal [[9, Attr::Check::NLRI_DISCARD]], check(ls_reach(SWAP))
    assert_match(/has TLV types 257, 256, which are not in section 5\.1 order/,
                 reason(ls_reach(SWAP)))
    assert_equal [[9, Attr::Check::NLRI_DISCARD]], check(ls_unreach(SWAP))
  end

  # Bullet 7: "For NLRIs carrying either a Local or Remote Node
  # Descriptor TLV, there is not more than one instance of a sub-TLV
  # present."
  def test_a_node_descriptor_with_a_sub_tlv_twice
    assert_equal [[9, Attr::Check::NLRI_DISCARD]], check(ls_reach(DUP))
    assert_match(/TLV type 256 carries sub-TLV type 512 more than once/,
                 reason(ls_reach(DUP)))
    # Two different sub-TLV types is not a duplicate.
    ok = TestAttrCheck.nlri(LS::Tlv::Local_node_descriptors.new(
           LS::Tlv::Autonomous_system.new(65000),
           LS::Tlv::Bgp_ls_identifier.new(1)))
    assert_equal [], check(ls_reach(ok))
  end

  # Bullet 5, by way of bullet 5's own pointer: "The syntactic
  # correctness of the NLRI fields has been verified as per [RFC7606]",
  # RFC 7606 section 7.11 for the rule, RFC 9552 section 5.5 for the
  # expectation. Section 7.11 has the next hop precede the NLRI, so the
  # NLRI cannot be located and the action is a session reset.
  def test_the_next_hop_length
    [[IANA::SAFI::BGP_LS, [4, 16, 32], '4, 16 or 32', ONE],
     [IANA::SAFI::BGP_LS_VPN, [12, 24, 40], '12, 24 or 40', VPN]
    ].each do |safi, ok, words, nlri|
      ok.each do |len|
        hex = ls_reach(nlri, safi, format('%02x', len) + '00' * len)
        assert_equal [], check(hex), "#{safi} next hop of #{len}"
      end
      [0, 1, 5, 17, 31, 33, 48].each do |len|
        next if ok.include?(len)
        hex = ls_reach(nlri, safi, format('%02x', len) + '00' * len)
        assert_equal [[9, RESET]], check(hex), "#{safi} next hop of #{len}"
        assert_equal "BGP-LS next hop of #{len} octets, must be #{words} " \
                     '(RFC 9552 sections 5.5 and 8.2.2, RFC 7606 section 7.11)',
                     reason(hex)
      end
    end
    # RFC 8950's 48, which SAFI 128 and 129 allow by repeating the Route
    # Distinguisher per address, is wrong here: section 5.5 prepends one
    # to the whole field, so the two-address VPN form is 40.
    assert_match(/of 48 octets/,
                 reason(ls_reach(VPN, IANA::SAFI::BGP_LS_VPN, '30' + '00' * 48)))
  end

  # The BGP-LS Attribute's three bullets. Every finding is attribute
  # discard, because the non-skippable case is the attribute's own
  # length against the Path Attribute Length and that is next_attribute
  # and attribute, which answer it for every attribute already.
  def test_the_bgp_ls_attribute_tlv_lengths
    a = BGP::Link_state_attribute.new(LS::Tlv::Node_name.new('r1')).to_shex
    over = a[0, 10] + 'ff' + a[12..]
    assert_equal [[9, DISCARD]], check(over)
    assert_match(/TLV type 1026 of 65282 octets runs past the BGP-LS Attribute/,
                 reason(over))
    tail = '801d07' + a[6..] + 'ff'
    assert_equal [[9, DISCARD]], check(tail)
    assert_match(/1 octet left in the BGP-LS Attribute, too few for a TLV Type/,
                 reason(tail))
  end

  # The second attribute bullet, "the syntactic correctness of the
  # Attributes (including the BGP-LS Attribute) have been verified as
  # per [RFC7606]", which for this family is one FLAGS entry: section
  # 5.3 makes the attribute "optional, non-transitive".
  def test_the_bgp_ls_attribute_is_optional_non_transitive
    a = BGP::Link_state_attribute.new(LS::Tlv::Node_name.new('r1')).to_shex
    assert_equal '80', a[0, 2], 'what the library writes'
    assert_equal [[4, TAW]], check('c0' + a[2..]), 'transitive'
    assert_equal [[4, TAW]], check('e0' + a[2..]), 'transitive and partial'
    assert_equal [[4, TAW]], check('40' + a[2..]), 'well-known'
  end

  # **What section 8.2.2 says not to check**, which narrows this family
  # further than any other here. Each of these is a shape bgp4r reports
  # for EVPN or MCAST-VPN and must not report for BGP-LS, so this is the
  # instruction asserted rather than a gap.
  def test_the_semantic_checks_section_8_2_2_forbids
    # "the length of a fixed-length TLV is correct": TLV 1156 is 4 or 16
    # by section 5.3.3.5, and eight octets reads back as a Tlv::Unknown
    # with nothing reported.
    odd = '801d0c' + '04840008' + '00' * 8
    assert_equal [], check(odd)
    # "the values of TLV fields are valid or permissible": Protocol-ID 0
    # is Reserved in Table 2, which every vector in this block carries,
    # and a Node Flag Bits TLV with a bit outside DEFINED_BITS set.
    assert_equal 0, LS::Node.new([ONE].pack('H*')[4..].is_packed).protocol_id
    assert_equal [], check(ls_reach(ONE))
    bits = LS::Tlv::Node_flag_bits.new(['02'].pack('H*').is_packed)
    assert_equal({ :bits => 2 }, bits.to_hash[:node_flag_bits].first,
                 'a reserved bit arrived set and is kept')
    assert_equal [], check(BGP::Link_state_attribute.new(bits).to_shex)
    # "presence of a mandatory TLV": a Node NLRI with no Local Node
    # Descriptors, which section 5.2.1.2 calls mandatory.
    assert_equal [], check(ls_reach(TestAttrCheck.nlri))
    # "the inclusion and use of TLVs/sub-TLVs with specific Link-State
    # NLRI types": a prefix descriptor inside a Node NLRI.
    assert_equal [], check(ls_reach(TestAttrCheck.nlri(
      LS::Tlv::Ip_reachability.new('192.0.2.0/24'))))
  end

  # Section 5.1 twice over: an unknown TLV type and an unknown NLRI type
  # are both MUSTs to preserve, and "The presence of unknown or
  # unexpected TLVs MUST NOT result in the NLRI or the BGP-LS Attribute
  # being considered malformed".
  def test_unknown_types_are_never_malformed
    # An unknown NLRI type's body is opaque by section 5.2, so no TLV is
    # framed out of it and nothing in it can be reported.
    assert_equal [], check(ls_reach('00630004deadbeef'))
    assert_equal [], check(ls_reach('006300090000000000000000ff'))
    # An unknown TLV in an NLRI, written before 256 so the NLRI is in
    # section 5.1 order.
    unk = TestAttrCheck.nlri(LS::Tlv::Unknown.new(255, ['deadbeef'].pack('H*')),
                             LS::Tlv::Local_node_descriptors.new(
                               LS::Tlv::Autonomous_system.new(65000)))
    assert_equal [], check(ls_reach(unk))
    # And an unknown TLV in the attribute, which is where the lab meets
    # one: GoBGP sends TLV 1101, the Adjacency SID of RFC 9085.
    assert_equal [], check(BGP::Link_state_attribute.new(
      LS::Tlv::Unknown.new(1101, ['00' * 8].pack('H*'))).to_shex)
  end

  # **The attribute's own TLV ordering is a MUST NOT, not a check.**
  # Section 5.1: "The TLVs within the BGP-LS Attribute SHOULD be ordered
  # in ascending order by TLV type. The BGP-LS Attribute with unordered
  # TLVs MUST NOT be considered malformed." So reporting it would be an
  # error bgp4r invented.
  def test_unordered_attribute_tlvs_are_not_malformed
    a = BGP::Link_state_attribute.new(LS::Tlv::Node_name.new('r1'),
                                      LS::Tlv::Node_flag_bits.new(:overload))
    assert_equal [1026, 1024], a.tlvs.collect(&:type), 'descending'
    assert_equal [], check(a.to_shex)
  end

  # **And section 5.2.1.4's sub-TLV ordering rule is not in section
  # 8.2.2's list**, which is what keeps the one router that can
  # originate BGP-LS conformant here. Bullet 6 cites section 5.1, whose
  # rule is "all TLVs within the NLRI"; 5.2.1.4 states a separate
  # ascending-order MUST for a Node Descriptor's sub-TLVs, and 8.2.2
  # takes only the other half of that section, the once-only rule of
  # bullet 7. GoBGP 3.23.0 sends 512, 516, 513 on every route it
  # originates, so a check here would call it malformed on all of them.
  def test_unordered_node_descriptor_sub_tlvs_are_not_reported
    # 512, then an unknown 516, then 513: GoBGP's own order.
    subs = LS::Tlv::Autonomous_system.new(65000).to_shex +
           LS::Tlv::Unknown.new(516, ['0a000002'].pack('H*')).to_shex +
           LS::Tlv::Bgp_ls_identifier.new(1).to_shex
    nd = LS::Tlv::Local_node_descriptors.new([subs].pack('H*').is_packed)
    assert_equal [512, 516, 513], nd.sub_tlvs.collect(&:type)
    assert_equal false, nd.ordered?, 'section 5.2.1.4 is broken'
    assert_equal [], nd.duplicate_types, 'and the other rule holds'
    assert_equal [], check(ls_reach(TestAttrCheck.nlri(nd))),
                 'reported by Node_descriptors#ordered? and by nothing here'
  end

  # The reason of the one finding for hex, so a test can assert which
  # rule fired rather than only that something did.
  def reason(hex)
    f = Attr::Check.attribute(b(hex), false)
    f.size == 1 ? f.first.reason : f.collect(&:reason)
  end

end
