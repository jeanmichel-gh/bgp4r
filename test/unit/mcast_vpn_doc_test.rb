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

  # The field neither document gives a width for. The claim is a
  # negative, so what is asserted is that the library takes the
  # what-is-left reading and that the document records the check.
  def test_the_originating_router_has_no_stated_width
    assert_match(/\*\*The Originating Router's IP Address has no width\s+anywhere\.\*\*/,
                 doc)
    assert_match(/MUST be of the same address family as/, doc)
    o = BGP::Mcast_vpn::Originating_router.new(
      ['0a0000010a000002'].pack('H*').is_packed)
    assert_equal(8, o.size, 'it takes every octet it is handed')
    assert_nil(o.address, 'and the family comes from the width')
  end

  # Route type 4's split, which is a reading and not a rule. The
  # document has to keep saying which, and the recursion has to keep
  # working, since part 4 rests on both.
  def test_the_leaf_a_d_split_is_recorded_as_a_reading
    assert_match(/the split that is not in the band/, doc)
    assert_match(/is set\s+to the NLRI of the received route/, doc)
    assert_match(/RFC 9572 needed its own terminology section to say "entire NLRI"/,
                 doc)
    assert_match(/takes that reading and does not assert it/, doc)
    inner = '010c' + '00000064000000c8' + '0a000001'
    assert_equal(14, BGP::Mcast_vpn.nlri_size([inner].pack('H*')))
  end

  # Neither document names a malformed NLRI or a subcode, so there is
  # nothing for validation.rb to carry. **This assertion is true only
  # while that is true**: the day an MCAST-VPN check lands, it fails and
  # says to rewrite section 8.
  def test_there_is_no_receive_side_check_yet_and_the_document_says_why
    assert_match(/Error handling: there is none to implement/, doc)
    assert_match(/neither document references RFC 7606 for an NLRI at all/, doc)
    body = File.read(File.expand_path('../../bgp/path_attributes/validation.rb',
                                      __dir__))
    assert(!body.include?('Mcast_vpn'),
           'validation.rb now knows about MCAST-VPN; rewrite section 8 of ' \
           "#{DOC}, which says there is nothing to check")
  end

  # Nothing dispatches to this family yet, which is what makes the whole
  # of this part pure. **True only today**: the wiring part makes this
  # fail, and the message says what to update.
  def test_nothing_dispatches_to_safi_5_yet
    assert_match(/Nothing dispatches to any of it yet/, doc)
    [1, 2].each do |afi|
      assert_raise(RuntimeError,
                   "AFI #{afi} SAFI 5 now parses; update section 9 and " \
                   "section 11 of #{DOC}") do
        BGP::Nlri.factory(['010c00000064000000c80a000001'].pack('H*'), afi, 5)
      end
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

  # The claim that is true only in this part. When a route type lands,
  # the sentence has to go, and this is what says so.
  def test_the_document_says_no_route_type_is_implemented_while_that_holds
    if implemented.empty?
      assert_match(/Every row says no today/, doc,
                   "#{DOC} must say no route type is implemented yet")
      assert_match(/\*\*Empty in this part\*\*/,
                   File.read(File.expand_path('../../bgp/nlris/mcast_vpn.rb',
                                              __dir__)))
    else
      assert(!doc.include?('Every row says no today'),
             "#{DOC} still says no route type is implemented, and " \
             "#{implemented.size} now are")
    end
  end

end
