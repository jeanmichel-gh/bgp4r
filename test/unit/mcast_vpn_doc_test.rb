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

# docs/mcast-vpn.md makes claims about the library. This asserts the
# load bearing ones, the way evpn_doc_test.rb and flow_spec_doc_test.rb
# guard the other two family guides, because a claim nothing checks
# reads as verified in a document as much as in a comment.
#
#   ruby -I. test/unit/mcast_vpn_doc_test.rb
#
# **The route type table is discovered, not listed.** That shape came
# from a sabotage on the flow spec guard: a fourteenth component type
# was added and the first version of that guard passed, because it
# compared the document against a list in the test rather than against
# the library. So this enumerates the Route subclasses the library
# actually defines and cross-checks them against both the table and
# Mcast_vpn::ROUTES, in either direction.
#
# **Three guards here are aimed at this part being the first of seven.**
# A document written while a family is half built goes stale the moment
# the next part lands, so the claims that are true only today are
# asserted as true only today: when a route type arrives, when the
# dispatch gates learn SAFI 5, and when a receive side check appears,
# the matching assertion fails and names what to update. That is what
# caught docs/evpn.md three times in one week.
#
# BGP:: names are written out in full, see Conventions in CLAUDE.md.

require 'test/unit'
require 'bgp/nlris/mcast_vpn'
require 'bgp/nlris/nlri'
require 'bgp/iana'
# The wiring part's guards reach the build gate and the next hop, which
# live here. Required explicitly, per Conventions: run_unit.rb requires
# every file before any test runs, so a file that leans on another's
# requires passes in the suite and fails on its own.
require 'bgp/path_attributes/mp_reach'
# And the validation part's guards build an attribute set to read its
# findings, which is where Attr::Check runs. Required explicitly for the
# same reason: this file passed in the suite and errored on its own when
# the wiring part's guards reached Mp_reach without saying so, and it
# did it again here.
require 'bgp/path_attributes/path_attribute'

class McastVpnDocTest < Test::Unit::TestCase

  DOC = 'docs/mcast-vpn.md'
  DOC_PATH = File.expand_path("../../#{DOC}", __dir__)

  # IANA's "BGP MCAST-VPN Route Types", read on 2026-10-31. The seven of
  # RFC 6514 section 4, then the three mLDP forms of RFC 7441 at 0x43,
  # 0x44 and 0x47.
  ASSIGNED = [1, 2, 3, 4, 5, 6, 7, 67, 68, 71].freeze

  # The three of those that are out of scope, because each carries an
  # mLDP FEC Element that RFC 7441 defers to RFC 6388 section 2.2.
  MLDP = [67, 68, 71].freeze

  def doc
    @doc ||= File.read(DOC_PATH, :encoding => 'UTF-8')
  end

  # Every Route subclass the library defines, Unknown excluded: it is in
  # no row and in no ROUTES entry on purpose, since no type number
  # reaches it.
  def implemented
    BGP::Mcast_vpn.constants.collect { |c| BGP::Mcast_vpn.const_get(c) }
                  .select { |k| k.is_a?(Class) && k < BGP::Mcast_vpn::Route }
                  .reject { |k| k == BGP::Mcast_vpn::Unknown }
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

  # Ten assigned values, which is the finding that reading only RFC 6514
  # would have missed.
  def test_the_table_has_a_row_for_each_assigned_route_type
    assert_equal(ASSIGNED, table.keys.sort,
                 "#{DOC} section 3 must have one row per assigned route type")
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

  # The half-wiring guard: a class added to mcast_vpn_route.rb and
  # forgotten in ROUTES parses as an Unknown however complete the class
  # is, and nothing else would say so.
  def test_every_route_class_is_registered_in_routes
    assert_equal(implemented.collect(&:type).sort,
                 BGP::Mcast_vpn::ROUTES.keys.sort,
                 'a Route subclass is missing from Mcast_vpn::ROUTES, or ' \
                 'vice versa')
    BGP::Mcast_vpn::ROUTES.each do |type, klass|
      assert_equal(type, klass.type,
                   "Mcast_vpn::ROUTES[#{type}] holds #{klass}, whose type " \
                   "is #{klass.type}")
    end
  end

  # The mLDP rows are a decision and not a backlog, so they must keep
  # saying no and the document must keep saying why.
  def test_the_mldp_rows_are_out_of_scope_and_say_so
    MLDP.each do |t|
      assert_equal('no', table[t],
                   "route type #{t} is an mLDP form and is out of scope")
    end
    assert_match(/mLDP FEC Element/, doc)
    assert_match(/section 2\.2 of RFC 6388/, doc)
    assert_match(/bgp4r has nothing of\s+LDP/, doc)
  end

  # Section 4: the Length counts the body alone, so an NLRI occupies
  # 2 + Length octets. This is the claim everything downstream rests on.
  def test_the_length_counts_the_body_alone
    assert_match(/the Length counts the body alone/, doc)
    assert_equal(2, BGP::Mcast_vpn::FRAMING)
    assert_equal(255, BGP::Mcast_vpn::MAX_LEN)
    assert_equal(14, BGP::Mcast_vpn.nlri_size(
      ['010c00000064000000c80a000001'].pack('H*')))
    assert_equal(2, BGP::Mcast_vpn.nlri_size(['0100'].pack('H*')))
  end

  def test_nlri_size_answers_nil_rather_than_guessing
    assert_match(/answers nil for octets too short to frame/, doc)
    assert_nil(BGP::Mcast_vpn.nlri_size(nil))
    assert_nil(BGP::Mcast_vpn.nlri_size(['01'].pack('H*')))
  end

  # Section 4 names no SAFI, so the number comes from the registry.
  def test_the_safi_is_five_and_the_rfc_does_not_say_so
    assert_match(/MCAST-VPN is SAFI 5/, doc)
    assert_match(/a Subsequent\s+AFI \(SAFI\) of MCAST-VPN/, doc)
    assert_equal(5, IANA::SAFI::MCAST_VPN)
    assert_equal('Multicast VPN', IANA.safi?(5))
  end

  # The two neighbours a reader will confuse with this family.
  def test_the_document_separates_safi_2_and_safi_129
    assert_match(/SAFI 2 is ordinary multicast forwarding NLRI/, doc)
    assert_match(/SAFI 129 is "Multicast for BGP\/MPLS IP VPNs"/, doc)
    assert_equal(2, IANA::SAFI::MULTICAST)
    assert_equal(129, IANA::SAFI::MPLS_VPN_Multicast)
  end

  # Section 4's table of primitive widths, and the fields that have none.
  def test_the_primitive_widths_are_what_the_table_says
    assert_equal(8, BGP::Mcast_vpn::RD_SIZE)
    assert_equal(8, BGP::Rd.new(100, 200).encode.size)
    assert_equal(4, BGP::Mcast_vpn::Source_as::WIDTH)
    assert_equal(4, BGP::Mcast_vpn::Source_as.new.encode.size)
    # The two that have no width of their own.
    assert_equal(1, BGP::Mcast_vpn::Addr.new.size, 'the length octet alone')
    assert_equal(0, BGP::Mcast_vpn::Originating_router.new.size)
  end

  # The claim the document calls the one memory reverses, with the
  # section 4.3 sentence quoted so a reader can check it without
  # opening the RFC.
  def test_the_document_says_the_lengths_are_in_bits
    assert_match(/\*\*The lengths are in bits\.\*\*/, doc)
    assert_match(/then the value of the Multicast Source Length field is\s+32/,
                 doc)
    assert_equal(32, BGP::Mcast_vpn::Addr.new('192.0.2.1').bitlen)
    assert_equal(128, BGP::Mcast_vpn::Addr.new('2001:db8::1').bitlen)
  end

  # Outside the scope is not malformed, which is why any length is
  # echoed rather than refused.
  def test_a_length_outside_the_scope_is_echoed
    assert_match(/outside the scope of this\s+document/, doc)
    assert_match(/Outside the scope is not malformed/, doc)
    a = BGP::Mcast_vpn::Addr.new(24, ['c00002'].pack('H*'))
    assert_equal('18c00002', a.to_shex)
    assert_nil(a.address)
  end

  # **This guard asserted that no document gives this field a width, and
  # RFC 6515 does.** Re-pointed at the new truth rather than weakened:
  # what is asserted now is the derivation RFC 6515 section 2 items 2 to
  # 4 give, and that bgp4r's what-is-left rule computes the same thing.
  # The 12-or-24 is the only octet count any document in this family
  # states, so it is worth holding against the classes.
  def test_the_originating_router_width_comes_from_the_nlri_length
    assert_match(/RFC 6515, which settles two things this document called unknown/,
                 doc)
    assert_match(/4 octets for IPv4 or\s+16 octets for IPv6/, doc)
    assert_match(/which will be either 12 or 24, respectively/, doc)
    assert_match(/MUST be of the same address family as/, doc)
    # And the counts RFC 6515 states are what the class encodes.
    v4 = BGP::Mcast_vpn::Intra_as_i_pmsi.new([100, 200], '10.0.0.1')
    v6 = BGP::Mcast_vpn::Intra_as_i_pmsi.new([100, 200], '2001:db8::1')
    assert_equal(12, v4.encode.size, "RFC 6515 section 2 item 2's 12")
    assert_equal(24, v6.encode.size, 'and its 24')
    o = BGP::Mcast_vpn::Originating_router.new(
      ['0a0000010a000002'].pack('H*').is_packed)
    assert_equal(8, o.size, 'it takes every octet it is handed')
    assert_nil(o.address, 'and the family comes from the width')
  end

  # Route type 4's split, which is a reading and not a rule. The
  # document has to keep saying which, and the recursion has to keep
  # working, since the route type rests on both.
  def test_the_leaf_a_d_split_is_recorded_as_a_reading
    assert_match(/the split that is not in the band/, doc)
    assert_match(/is set\s+to the NLRI of the received route/, doc)
    assert_match(/RFC 9572 needed its own terminology section to say "entire NLRI"/,
                 doc)
    assert_match(/takes that reading and says in the code that it is a reading/,
                 doc)
    inner = '010c' + '00000064000000c8' + '0a000001'
    assert_equal(14, BGP::Mcast_vpn.nlri_size([inner].pack('H*')))
  end

  # And what the replay check does and does not buy here, which both the
  # document and the class comment overstated in a first draft. The
  # claim is that the split is injective on the octets, so the two
  # counter-example bodies the document prints must really differ.
  def test_the_replay_check_says_nothing_about_the_reading
    assert_match(/What the replay check buys here, which is less than this section claimed/,
                 doc)
    assert_match(/\*\*The split is read from the nested Length octet, so it is injective on\s+the octets\.\*\*/,
                 doc)
    assert_match(/\*\*A sender using another rule is undetectable\.\*\*/, doc)
    assert_match(/\*\*A reader using another rule is undetectable too\*\*/, doc)
    one = '0101ff' + '0a000001'
    two = '0104ff0a0000' + '01'
    assert_equal(one.size, two.size, 'the document says same length')
    assert_not_equal(one, two, 'and different octets')
    [one, two].each do |hex|
      r = BGP::Mcast_vpn::Leaf_a_d.new([hex].pack('H*').is_packed)
      assert_equal(hex, r.encode.unpack1('H*'),
                   'so each reads back as itself, which is the injectivity')
    end
  end

  # The one class in mcast_vpn_route.rb that does not work against that
  # file alone. Every route type builds with no NLRI here, since
  # mcast_vpn.rb is loaded; what the document records is the split of
  # test files, and that is what this asserts, because the route file's
  # own test requiring the NLRI would make the claim vacuous.
  def test_only_the_leaf_a_d_route_needs_the_nlri
    assert_match(/reaches `Mcast_vpn` at call time and not at load time/, doc)
    BGP::Mcast_vpn::ROUTES.each do |t, k|
      assert_nothing_raised("route type #{t} should build") { k.new }
    end
    body = File.read(File.expand_path('nlris/mcast_vpn_route_test.rb', __dir__))
    assert(!body.include?("require 'bgp/nlris/mcast_vpn'"),
           'mcast_vpn_route_test.rb must not require the NLRI, or the other ' \
           'six route types are not proved to work without it')
    assert(!body.include?('Leaf_a_d'),
           "Leaf_a_d's tests belong in mcast_vpn_test.rb, beside the framing")
  end

  # Neither document names a malformed NLRI or a subcode, so there is
  # nothing for validation.rb to carry. **This assertion is true only
  # while that is true**: the day an MCAST-VPN check lands, it fails and
  # says to rewrite section 8.
  # **This guard asserted that validation.rb did not know about
  # MCAST-VPN, and the validation part made it fire**, which is the last
  # of part 1's four forward-looking guards to go and exactly what it
  # was for. Re-pointed at the new truth rather than weakened.
  #
  # What it holds now is the half of section 8 that cannot be read off
  # the table: that the subcode and the action are RFC 7606's rather
  # than invented, and that the document says so.
  def test_the_action_and_the_subcode_are_not_derived
    assert_match(/Error handling: four checks, and RFC 6515 is where all four come from/,
                 doc)
    assert_match(/Where the subcode and the action come from, which is not a derivation/,
                 doc)
    assert_match(/is considered malformed/, doc)
    assert_match(/have to have a length of 4 or 16/, doc)
    assert_match(/Inventing a subcode was the trap here\*\*/, doc)
    assert_match(/neither document references RFC 7606 for an NLRI at all/, doc)
    body = validation
    assert(body.include?('Mcast_vpn'),
           'validation.rb no longer knows about MCAST-VPN; section 8 of ' \
           "#{DOC} says it does")
    assert(body.include?('RFC 7606 section 7.11'),
           'the MCAST-VPN next hop finding must cite the section it reuses')
  end

  def validation
    File.read(File.expand_path('../../bgp/path_attributes/validation.rb',
                               __dir__))
  end

  # Section 8's table, as [what, action] per row.
  def check_rows
    doc.lines.each_with_object([]) do |l, a|
      m = l.match(/^\|\s*([a-z][^|]*?)\s*\|\s*item \d\s*\|\s*(session reset|treat as withdraw)\s*\|\s*$/)
      a << [m[1], m[2].tr(' ', '_').to_sym] if m
    end
  end

  # **The row count is discovered from the library, not from this test**,
  # the twin of `evpn_doc_test.rb`'s guard: every check is one
  # `Finding.new` in the MCAST-VPN block of validation.rb, so counting
  # them there and comparing against the table catches what a listed
  # table cannot, which is a check added with no row to describe it.
  #
  # The slice markers are asserted before the count so the slice cannot
  # silently become empty and make this vacuous.
  #
  # **What is counted is not `Finding.new` the way EVPN's guard counts
  # it, and the difference is the library's shape rather than a weaker
  # guard.** RFC 6515 section 2 states one sentence four times, so
  # `originator_finding` is one `Finding.new` reached by three route
  # types: counting findings gives 2 where the table has 4 rows. What
  # matches the rows one for one is the next hop check plus the arms of
  # `mcast_vpn_route_finding`'s case, and those are as discoverable from
  # the library as a finding is. Each arm names its route type through
  # the class, so they cannot drift from `Mcast_vpn::ROUTES` either.
  def test_section_8_has_one_row_per_rfc_6515_check_the_library_makes
    src = validation
    first = src.index('def mcast_vpn_next_hop_finding')
    last  = src.index('def flow_spec_component_size')
    assert(first, 'validation.rb has no mcast_vpn_next_hop_finding to count')
    assert(last && last > first,
           'the slice markers moved, so this guard is measuring nothing')
    block = src[first...last]
    arms = block.scan(/^\s*when ::BGP::Mcast_vpn::\w+\.type$/).size
    assert_equal(arms + 1, check_rows.size,
                 "#{DOC} section 8 does not have one row per RFC 6515 check: " \
                 "#{arms} route type arms plus the next hop")
    assert_equal(4, check_rows.size, 'one row per item of RFC 6515 section 2')
    # And the framing findings, which no MCAST-VPN RFC asks for and which
    # therefore have no row, are still there and still cite section 4.
    assert_equal(2, block.scan(/Finding\.new\([^)]*RFC 6514 section 4/m).size,
                 'the two framing findings')
  end

  # Every row's action against what the library answers for octets built
  # to trip it. The probes are octets rather than objects, because that
  # is what Attr::Check sees.
  def test_every_row_of_section_8_gets_the_action_it_claims
    rows = check_rows
    assert(rows.all? { |_, action| action == :session_reset },
           'every row claims a session reset')
    [['next hop', mp_reach(NLRI_RT1, 8)],
     ['route type 1', mp_reach(BAD_RT1)],
     ['route type 3', mp_reach(BAD_RT3)],
     ['route type 4', mp_reach(BAD_RT4)]].each do |what, hex|
      f = BGP::Path_attribute.new([hex].pack('H*').is_packed).errors
      assert_equal(1, f.size, "#{what} is reported once")
      assert_equal(9, f.first.subcode, "#{what} gets subcode 9")
      assert_equal(:session_reset, f.first.action,
                   "#{what} gets the action its row claims")
    end
  end

  # A clean route of every type reports nothing, which is the other half
  # of the claim and the half a wrong check would break.
  def test_a_clean_mcast_vpn_update_is_reported_nowhere
    [NLRI_RT1, NLRI_RT1_V6, NLRI_RT2, NLRI_RT3, NLRI_RT4, NLRI_MLDP].each do |n|
      [4, 16].each do |nh|
        a = BGP::Path_attribute.new([mp_reach(n, nh)].pack('H*').is_packed)
        assert_equal(0, a.errors.size,
                     "clean NLRI #{n} with a #{nh} octet next hop: " \
                     "#{a.errors.collect(&:reason).inspect}")
      end
    end
  end

  # RFC 6515 section 2 names MP_REACH_NLRI in all four items and never
  # MP_UNREACH_NLRI, so the same bad route withdrawn is reported nowhere
  # while the framing, which no item mentions, is reported in both.
  def test_the_four_checks_are_mp_reach_only
    assert_match(/MP_UNREACH is not checked, and that is the RFC's choice/, doc)
    [BAD_RT1, BAD_RT3, BAD_RT4].each do |n|
      a = BGP::Path_attribute.new([mp_unreach(n)].pack('H*').is_packed)
      assert_equal(0, a.errors.size,
                   "withdrawn #{n}: #{a.errors.collect(&:reason).inspect}")
    end
    %w[01 0114].each do |n|
      [mp_reach(n), mp_unreach(n)].each do |hex|
        a = BGP::Path_attribute.new([hex].pack('H*').is_packed)
        assert_equal(1, a.errors.size, "framing #{n} is reported either way")
      end
    end
  end

  RD           = '00000064000000c8'
  NLRI_RT1     = '010c' + RD + '0a000001'
  NLRI_RT1_V6  = '0118' + RD + '20010db8000000000000000000000009'
  NLRI_RT2     = '020c' + RD + '0000fde8'
  NLRI_RT3     = '0316' + RD + '200a010101' + '20e8010101' + '0a000001'
  NLRI_RT4     = '0412' + NLRI_RT2 + '0a000001'
  NLRI_MLDP    = '4305' + '0102030405'
  # One octet too few and too many for an address, per route type.
  BAD_RT1      = '0110' + RD + 'aabbccddeeff0011'
  BAD_RT3      = '031a' + RD + '200a010101' + '20e8010101' + 'aabbccddeeff0011'
  BAD_RT4      = '0410' + NLRI_RT2 + 'aabb'

  # RFC 4760 section 3: AFI, SAFI, the next hop length and the next hop,
  # a reserved octet, then the NLRI. Built here rather than through
  # Mp_reach so a next hop length no RFC allows can be written.
  def mp_reach(nlri, nh = 4)
    body = '0001' + '05' + format('%02x', nh) + ('aa' * nh) + '00' + nlri
    '800e' + format('%02x', body.size / 2) + body
  end

  # Section 4: AFI, SAFI, then the withdrawn NLRI. No next hop.
  def mp_unreach(nlri)
    body = '0001' + '05' + nlri
    '800f' + format('%02x', body.size / 2) + body
  end

  # RFC 6515 is the document the plan missed, so the guide has to name
  # it, carry its two load bearing sentences, and say how it was found.
  # The last of those is the part worth keeping: the rule that would
  # have caught it is one this repository already had.
  def test_the_document_records_rfc_6515_and_how_it_was_missed
    assert_match(/\*\*RFC 6515\*\*, "IPv4 and IPv6\s+Infrastructure Addresses in BGP Updates for Multicast VPN"/,
                 doc)
    assert_match(/MUST\s+NOT be inferred from the AFI field/, doc)
    assert_match(/read every RFC that\s+lists itself as updating the one you are implementing/, doc)
    assert_match(/So the rule\s+is not satisfied by applying it once/, doc)
  end

  # The next hop, which is the wiring site RFC 6515 decides. Both halves
  # are asserted from the library: an IPv6 next hop writes 16 octets
  # under either AFI, and an IPv4 one writes 4 under AFI 2 rather than
  # the mapped address RFC 4659 and RFC 4798 would have wanted.
  def test_the_next_hop_is_read_by_its_length_and_never_mapped
    assert_match(/it is always clear whether the address is an\s+IPv4 address \(length is 4\) or an IPv6 address \(length is 16\)/,
                 doc)
    assert_match(/This document does not use that approach/, doc)
    nlri = { :inter_as_i_pmsi => { :rd => [100, 200], :source_as => 65000 } }
    [[1, '10.0.0.1', 4], [2, '10.0.0.1', 4],
     [1, '2001:db8::1', 16], [2, '2001:db8::1', 16]].each do |afi, nh, len|
      a = BGP::Mp_reach.new(:afi => afi, :safi => 5, :nexthop => [nh],
                            :nlris => [nlri])
      assert_equal(len, a.to_shex[12, 2].to_i(16),
                   "AFI #{afi} with #{nh} writes a #{len}-octet next hop")
      back = BGP::Mp_reach.new(a.encode.is_packed)
      assert_equal(nh, back.nexthops, 'and it reads back as the same address')
    end
  end

  # Route type 4's split, which section 7 recorded as not being in the
  # band and RFC 6515 section 2 item 4 settles. The document has to say
  # both that it was a reading and that it is one no longer.
  def test_the_leaf_a_d_split_is_settled_by_rfc_6515
    assert_match(/A later document answered it, and the answer is the reading/,
                 doc)
    assert_match(/\*\*RFC 6515 section 2 item 4: "The Route Key has its own length field\."\*\*/,
                 doc)
    assert_match(/The code did not change/, doc)
  end

  # **This guard used to assert that nothing dispatched to SAFI 5**, and
  # the wiring part made it fail, which is the guard working as part 1
  # designed it. Re-pointed at the new truth rather than weakened, the
  # way #185, #191, #209 and #210 each re-pointed an expired example.
  #
  # Both AFIs now parse, which is the claim worth holding: RFC 6514
  # section 4 allows 1 and 2, nothing in the NLRI reads differently per
  # family, so the same octets must come back the same way under either.
  def test_both_afis_dispatch_to_safi_5
    assert_match(/Both dispatch gates know SAFI 5/, doc)
    hex = '010c00000064000000c80a000001'
    [1, 2].each do |afi|
      n = BGP::Nlri.factory([hex].pack('H*'), afi, 5)
      assert_instance_of(BGP::Mcast_vpn, n, "AFI #{afi} reads back")
      assert_instance_of(BGP::Mcast_vpn::Intra_as_i_pmsi, n.route)
      assert_equal(hex, n.to_shex, 'and replays byte for byte')
    end
  end

  # The weakest thing about this family, which has to be said rather
  # than implied.
  def test_the_document_says_there_is_no_outside_reference
    assert_match(/No outside reference/, doc)
    assert_match(/\*\*Neither router in the lab implements SAFI 5\.\*\*/, doc)
    assert_match(/\*\*The ATTR_SET trick does not transfer\*\*/, doc)
    assert_match(/Do not read the loopback functional test as interoperability/,
                 doc)
  end

  # No hex in either document, so the vectors are arithmetic and the
  # test files have to say so. This checks they do, because the claim
  # that a test is weaker than it looks is the kind that gets dropped.
  def test_the_test_files_say_their_vectors_are_arithmetic
    assert_match(/No worked example, so the vectors are arithmetic/, doc)
    %w[test/unit/nlris/mcast_vpn_route_test.rb
       test/unit/nlris/mcast_vpn_test.rb].each do |f|
      body = File.read(File.expand_path("../../#{f}", __dir__))
      assert_match(/reader's arithmetic/, body,
                   "#{f} must say its expectations are not the document's")
    end
  end

  # The primitives are this family's own, which is a decision with a
  # cost. The document records the mechanism and the cheaper sharing
  # shape, so the next reader does not re-derive either.
  def test_the_duplication_is_recorded_as_a_decision
    assert_match(/The primitives are this family's own and not EVPN's/, doc)
    assert_match(/identical to the S-PMSI A-D route as defined in \[RFC7117\]/,
                 doc)
    assert_match(/There is a cheaper\s+shape than that/, doc)
    # And both classes really are separate, which is what the decision
    # amounts to.
    assert_not_equal(BGP::Evpn::Addr, BGP::Mcast_vpn::Addr)
    assert(!(BGP::Mcast_vpn::Addr < BGP::Evpn::Addr))
  end

  # The claim that was true only in part 1. **It fired the moment route
  # types 1, 2 and 5 landed**, which is the guard working, so it is
  # re-pointed rather than removed: the sentence must be gone while any
  # route type is implemented, and must come back if ever none is.
  def test_the_document_says_no_route_type_is_implemented_while_that_holds
    if implemented.empty?
      assert_match(/Every row says no today/, doc,
                   "#{DOC} must say no route type is implemented yet")
    else
      assert(!doc.include?('Every row says no today'),
             "#{DOC} still says no route type is implemented, and " \
             "#{implemented.size} now are")
    end
  end

  # The octet counts of the layouts that are in. **None is in the
  # document**, so each is this reader's arithmetic and the table has to
  # agree with the library rather than the other way round.
  def test_the_layout_table_agrees_with_what_the_classes_encode
    assert_match(/\| 1 \| RD, Originating Router's IP Address \| 12 or 24 \|/,
                 doc)
    assert_match(/\| 2 \| RD, Source AS \| 12, always \|/, doc)
    assert_match(
      /\| 3 \| RD, source, group, Originating Router's IP Address \| 22 or 58 \|/,
      doc)
    assert_match(/\| 5 \| RD, source, group \| 18 or 42 \|/, doc)
    assert_match(/\| 6 and 7 \| RD, Source AS, source, group \| 22 or 46 \|/,
                 doc)
    rd = [100, 200]
    assert_equal(12, BGP::Mcast_vpn::Intra_as_i_pmsi
                       .new(rd, '10.0.0.1').encode.size)
    assert_equal(24, BGP::Mcast_vpn::Intra_as_i_pmsi
                       .new(rd, '2001:db8::1').encode.size)
    assert_equal(12, BGP::Mcast_vpn::Inter_as_i_pmsi
                       .new(rd, 65000).encode.size)
    assert_equal(12, BGP::Mcast_vpn::Inter_as_i_pmsi
                       .new(rd, 70013).encode.size)
    assert_equal(22, BGP::Mcast_vpn::S_pmsi
                       .new(rd, '192.0.2.1', '232.1.1.1', '10.0.0.1')
                       .encode.size)
    assert_equal(58, BGP::Mcast_vpn::S_pmsi
                       .new(rd, '2001:db8::1', 'ff3e::1', '2001:db8::2')
                       .encode.size)
    assert_equal(18, BGP::Mcast_vpn::Source_active
                       .new(rd, '192.0.2.1', '232.1.1.1').encode.size)
    assert_equal(42, BGP::Mcast_vpn::Source_active
                       .new(rd, '2001:db8::1', 'ff3e::1').encode.size)
    [BGP::Mcast_vpn::Shared_tree_join,
     BGP::Mcast_vpn::Source_tree_join].each do |k|
      assert_equal(22, k.new(rd, 65000, '192.0.2.1', '232.1.1.1').encode.size,
                   k.to_s)
      assert_equal(46, k.new(rd, 65000, '2001:db8::1', 'ff3e::1').encode.size,
                   k.to_s)
    end
  end

  # The two length collisions the table warns about, both real and both
  # something a reader comparing lengths would otherwise meet by
  # surprise.
  def test_both_length_collisions_are_real
    assert_match(/\*\*Two pairs collide on length\.\*\*/, doc)
    rd = [100, 200]
    assert_equal(BGP::Mcast_vpn::Inter_as_i_pmsi.new(rd, 1).encode.size,
                 BGP::Mcast_vpn::Intra_as_i_pmsi
                   .new(rd, '10.0.0.1').encode.size)
    assert_equal(BGP::Mcast_vpn::S_pmsi
                   .new(rd, '192.0.2.1', '232.1.1.1', '10.0.0.1').encode.size,
                 BGP::Mcast_vpn::Shared_tree_join
                   .new(rd, 65000, '192.0.2.1', '232.1.1.1').encode.size)
  end

  # The pair four layouts share, and the module-not-a-class rule that
  # keeps the discovery guard above from counting it as a route type.
  def test_the_shared_pair_is_a_module_and_four_types_use_it
    assert_match(/\*\*The Multicast Source and Multicast Group pair is in four of the seven\s+layouts\*\*/,
                 doc)
    assert_match(/\*\*module and not a base class\*\*/, doc)
    [BGP::Mcast_vpn::S_pmsi, BGP::Mcast_vpn::Source_active,
     BGP::Mcast_vpn::Shared_tree_join,
     BGP::Mcast_vpn::Source_tree_join].each do |k|
      assert(k.include?(BGP::Mcast_vpn::Source_and_group), k.to_s)
    end
    [BGP::Mcast_vpn::Source_and_group, BGP::Mcast_vpn::C_multicast].each do |m|
      assert(!m.is_a?(Class), "#{m} must be a module, not a Class")
      assert(!implemented.include?(m), "#{m} must not be discovered as a type")
    end
  end

  # Section 4.6 defines two route types with one layout, so the two
  # classes are identity and nothing else. The document says so and
  # this is what makes it true.
  def test_route_types_6_and_7_differ_only_in_identity
    assert_match(/\*\*identity and nothing else\*\*/, doc)
    rd = [100, 200]
    a = BGP::Mcast_vpn::Shared_tree_join.new(rd, 65000, '192.0.2.1', '232.1.1.1')
    b = BGP::Mcast_vpn::Source_tree_join.new(rd, 65000, '192.0.2.1', '232.1.1.1')
    assert_equal(a.encode, b.encode)
    assert_equal(6, a.type)
    assert_equal(7, b.type)
  end

  # Route type 3's ordering claim, which is what makes the layout
  # readable: two lengths first, then whatever is left is the address.
  def test_route_type_3_reads_its_lengths_before_the_trailing_address
    assert_match(/first layout with a variable field after a\s+variable field/,
                 doc)
    r = BGP::Mcast_vpn::S_pmsi.new([100, 200], '192.0.2.1', '232.1.1.1',
                                   '10.0.0.1')
    t = BGP::Mcast_vpn::Source_active.new([100, 200], '192.0.2.1', '232.1.1.1')
    assert_equal(t.to_shex + '0a000001', r.to_shex,
                 'route type 3 is route type 5 with the address behind it')
  end

  # Section 4.2's one sentence about a field's value rather than its
  # width, quoted so a reader can check it, and asserted because it
  # holds by construction rather than by code.
  def test_a_two_octet_as_sits_in_the_low_order_octets
    assert_match(/Two-octet ASNs are encoded in the two\s+low-order octets/,
                 doc)
    s = BGP::Mcast_vpn::Source_as.new(65000)
    assert_equal('0000fde8', s.to_shex)
  end

  # The two receive-side rules of section 4.5 that are not error
  # handling. The document has to keep saying **why** each is not a
  # validation.rb rule, since part 6 is where someone will look.
  def test_the_two_section_4_5_rules_are_recorded_with_their_reasons
    assert_match(/Two receive-side rules that are not error handling/, doc)
    assert_match(/Multicast Source Length\s+field of 0 is outside the scope/,
                 doc)
    assert_match(/MUST NOT be advertised by a router and MUST be discarded if received/,
                 doc)
    assert_match(/deferring to RFC 4607/, doc)
    assert_match(/"discarded" is not one of the actions RFC\s+7606 names/, doc)
    # And neither is enforced: both build.
    t = BGP::Mcast_vpn::Source_active.new([100, 200], nil, '232.1.1.1')
    assert(t.source.empty?, 'a wildcard source builds')
    assert_equal('232.1.1.1', t.group.address, 'an SSM group builds')
  end

end
