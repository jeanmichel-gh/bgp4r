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

# The RFC 7606 fault matrix checks, shared by the Docker Compose run and
# the native one. Every case in BGP::Fault::CATALOG is sent to a router,
# once each, on its own session, and this says what the answers must be.
#
# Two layers of assertion here.
#
# The session level answer first: which faults make a conformant router
# reset, with which NOTIFICATION subcode, and that the rest leave the
# session up. That is the half of RFC 7606 that needs no look at the
# router's RIB, so it holds for any router that implements the RFC, and
# no assertion in it names a router specific command.
#
# Then the route level answer, which needs the RIB, because
# treat-as-withdraw and attribute-discard both keep the session up. Each
# harness reads it with the gobgp client, so each fault also says whether
# the route was installed.
#
# The including class defines:
#
#   results               the matrix results, parsed from its JSON
#   output                the harness output, for a failure message
#   exit_status           the matrix process exit status
#   installed_divergences treat-as-withdraw cases this router installs anyway
#   reset_divergences     name => subcode, cases this router resets on
#
# The last two are where a router's own behaviour lives, because the
# answers are not the same on every version: see GOBGP_3 below.

require 'test/unit'
require 'bgp4r'
require_relative 'lab_helper'

module FaultMatrixScenario
  include LabHelper

  # RFC 4271 section 6.3 subcodes a conformant router must answer with.
  # Everything else in the catalog is treat-as-withdraw or
  # attribute-discard, and both keep the session up.
  CATALOG_RESETS = { 'unknown_wellknown'  => 2,   # unrecognized well-known attribute
                     'duplicate_mp_reach' => 1 }  # malformed attribute list

  # Every catalog case and the RFC 7606 action it expects, read from the
  # catalog itself so a case added later is covered the day it lands.
  ACTIONS = BGP::Fault.catalog.each_with_object({}) { |e, h|
    h[e[:name].to_s] = e[:action]
  }.freeze

  # Where a route expectation is hardcoded rather than derived.
  #
  # Both cases break the RFC 9012 section 13 framing rule: the final octet
  # of a tunnel TLV must also be the final octet of its last sub-TLV. That
  # section is a MUST and it asks for treat-as-withdraw, which is what the
  # catalog expects. GoBGP sees the malformed TLV, logs "Not all
  # TunnelEncapSubTLV bytes available", discards the attribute and installs
  # the route anyway. Measured on 3.23.0 and on 4.10.0. So the assertion
  # records what the router does, not what the RFC asks.
  #
  # bgp4r is right here and the router is not. If either of these ever
  # reports the route dropped, the router improved: drop the name from
  # this list and let it be derived with the other treat-as-withdraw
  # cases, and update the GoBGP notes in docs/protocol-testing.md.
  TUNNEL_ENCAP = %w[tunnel_encap_tlv tunnel_encap_sub_tlv].freeze

  # GoBGP 3 only, and the reason the two versions need telling apart.
  #
  # attr_overrun is an ORIGIN whose length field says 20 octets inside an
  # 18 octet attribute list, so the attribute overruns the list. RFC 7606
  # section 4, "Attribute Length Fields", names that as the first of "two
  # error cases in which the Total Attribute Length value can be in
  # conflict with the enclosed path attributes", where "the length of the
  # last encountered path attribute would cause the Total Attribute Length
  # to be exceeded", and then: "In either of these cases, an error
  # condition exists and the 'treat-as-withdraw' approach MUST be used"
  # (unless a more severe error dictates a stronger approach, and none
  # does here). GoBGP 3.23.0 logs "attribute type length is short" and
  # resets the session with subcode 5, Attribute Length Error. GoBGP
  # 4.10.0 treats it as a withdraw and keeps the session, which is what
  # the RFC asks.
  #
  # So this is a GoBGP 3 bug that GoBGP 4 fixed, not a bgp4r bug. It went
  # unrecorded because the hand measurement behind the table in
  # docs/protocol-testing.md was never re-run, and the only harness that
  # could re-run it needed Docker.
  GOBGP_3 = { 'attr_overrun' => 5 }.freeze

  # Every name this router is expected to answer differently from the
  # catalog, whether by installing the route or by resetting.
  def expected_divergences
    (installed_divergences + reset_divergences.keys).sort
  end

  # The catalog's own session resets, plus any this router adds.
  def expected_resets
    CATALOG_RESETS.merge(reset_divergences)
  end

  def result(name)
    results.find { |r| r['name'] == name.to_s } or
      flunk("the matrix reported nothing for #{name}\n#{output}")
  end

  # The catalog cases whose expected RFC 7606 action is this one.
  def names_for(action)
    ACTIONS.select { |_, a| a == action }.keys.sort
  end

  def test_every_catalog_fault_was_sent
    sent = results.collect { |r| r['name'] }.sort
    assert_equal BGP::Fault::CATALOG.collect { |e| e.first.to_s }.sort, sent,
                 "the matrix must send every catalog case\n#{output}"
  end

  # A session that never came back means the harness lost the router, not
  # that the router answered. Fail loudly rather than read the verdicts.
  def test_every_fault_got_a_session
    lost = results.select { |r| r['outcome'] == 'no_session' }.collect { |r| r['name'] }
    assert_equal [], lost, "no session for these faults\n#{output}"
  end

  def test_the_session_reset_cases_reset_with_the_right_subcode
    expected_resets.each do |name, subcode|
      r = result(name)
      assert_equal 'reset', r['outcome'], "#{name} must reset the session\n#{output}"
      assert_equal 3, r['code'], "#{name} NOTIFICATION code"
      assert_equal subcode, r['subcode'], "#{name} NOTIFICATION subcode"
    end
  end

  def test_no_other_fault_resets_the_session
    results.each do |r|
      next if expected_resets.key?(r['name'])
      assert_not_equal 'reset', r['outcome'],
                       "#{r['name']} (#{r['expected']}) must not reset the session\n#{output}"
    end
  end

  # Every route verdict below rests on this one. fault_matrix.rb sends a
  # plain route of its own before the first fault and only asks the router
  # about a faulty one once it has seen that plain route installed. When
  # the baseline fails, rib_usable is false, every kept row comes back with
  # installed nil and a verdict of "session only", and the route columns
  # mean nothing. Fail on that rather than read them.
  def test_the_rib_answer_was_usable
    unscored = results.select { |r| r['outcome'] == 'kept' && r['installed'].nil? }
                      .collect { |r| r['name'] }
    assert_equal [], unscored,
                 "no RIB answer for these faults, so no route verdict here means anything.\n" \
                 "The matrix only reads the RIB after it has seen the router install a\n" \
                 "plain route. Either --rib-command is wrong, or the gobgp client is\n" \
                 "not where the harness looked, or the router dropped the clean route\n" \
                 "too.\n#{output}"
  end

  # RFC 7606 treat-as-withdraw: the session stays up and the route does not
  # reach the RIB. Derived from the catalog, less the cases this router
  # gets wrong, which test_the_known_divergences covers.
  def test_the_treat_as_withdraw_cases_dropped_the_route
    names = names_for(:treat_as_withdraw) - expected_divergences
    assert_not_equal [], names, 'the catalog has no treat_as_withdraw case left to check'
    names.each do |name|
      assert_equal false, result(name)['installed'],
                   "#{name} is treat_as_withdraw, so the route must not be installed\n#{output}"
    end
  end

  # RFC 7606 attribute-discard: the attribute goes, the route stays.
  def test_the_attribute_discard_cases_kept_the_route
    names = names_for(:attribute_discard) - expected_divergences
    assert_not_equal [], names, 'the catalog has no attribute_discard case left to check'
    names.each do |name|
      assert_equal true, result(name)['installed'],
                   "#{name} is attribute_discard, so the route must stay installed\n#{output}"
    end
  end

  # Known divergences, not bgp4r bugs. See TUNNEL_ENCAP and GOBGP_3 above.
  def test_the_known_divergences
    installed_divergences.each do |name|
      r = result(name)
      assert_equal 'kept', r['outcome'], "#{name} must not reset the session\n#{output}"
      assert_equal true, r['installed'],
                   "#{name} installed=#{r['installed'].inspect}. This asserts what the\n" \
                   "router does, not what the RFC asks. See TUNNEL_ENCAP in\n" \
                   "fault_matrix_scenario.rb, which says what to do if the router\n" \
                   "improved.\n#{output}"
    end
  end

  # The matrix exits non-zero when any answer differs from the catalog, so
  # asserting the set, rather than that it is empty, keeps the catalog
  # honest about what the RFC asks while still failing if a new case
  # starts to differ.
  def test_the_only_disagreements_are_the_known_ones
    differs = results.select { |r| r['verdict'] == 'differs' }.collect { |r| r['name'] }.sort
    assert_equal expected_divergences, differs,
                 "the only answers expected to differ from the catalog are the ones\n" \
                 "described in TUNNEL_ENCAP and GOBGP_3 in fault_matrix_scenario.rb.\n" \
                 "Anything else here is a new divergence, and a shorter list than\n" \
                 "expected means the router improved and this test should be updated.\n" \
                 "#{output}"
    assert_equal(expected_divergences.empty? ? 0 : 1, exit_status,
                 "the matrix exited #{exit_status}. It exits non-zero on any\n" \
                 "disagreement with the catalog, so 1 is right while anything in\n" \
                 "expected_divergences still differs and 0 once nothing does.\n#{output}")
  end
end
