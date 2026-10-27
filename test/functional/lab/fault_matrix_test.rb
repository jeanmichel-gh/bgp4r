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

# lab/topologies/fault-matrix in Docker Compose: every RFC 7606 case in
# BGP::Fault::CATALOG sent to GoBGP, once each, on its own session.
#
#   ruby -I. test/functional/lab/fault_matrix_test.rb
#
# Skipped when docker compose is not available.
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
# treat-as-withdraw and attribute-discard both keep the session up. The
# topology reads it with the gobgp client, so each fault also says
# whether the route was installed. Those rows are router specific, and
# GoBGP 3.23 does not agree on all of them: see TUNNEL_ENCAP below.

require 'test/unit'
require 'bgp4r'
require 'json'
require 'fileutils'
require_relative 'lab_helper'

class LabFaultMatrixComposeTest < Test::Unit::TestCase
  include LabHelper

  # RFC 4271 section 6.3 subcodes a conformant router must answer with.
  # Everything else in the catalog is treat-as-withdraw or
  # attribute-discard, and both keep the session up.
  RESETS = { 'unknown_wellknown'  => 2,   # unrecognized well-known attribute
             'duplicate_mp_reach' => 1 }  # malformed attribute list

  # Every catalog case and the RFC 7606 action it expects, read from the
  # catalog itself so a case added later is covered the day it lands.
  ACTIONS = BGP::Fault.catalog.each_with_object({}) { |e, h|
    h[e[:name].to_s] = e[:action]
  }.freeze

  # The one place a route expectation is hardcoded rather than derived.
  #
  # Both cases break the RFC 9012 section 13 framing rule: the final octet
  # of a tunnel TLV must also be the final octet of its last sub-TLV. That
  # section is a MUST and it asks for treat-as-withdraw, which is what the
  # catalog expects. GoBGP 3.23 sees the malformed TLV, logs "Not all
  # TunnelEncapSubTLV bytes available", discards the attribute and installs
  # the route anyway. So the assertion below records what the router does,
  # not what the RFC asks.
  #
  # bgp4r is right here and the router is not. If either of these ever
  # reports the route dropped, the router improved: move the name out of
  # this list and let it be derived with the other treat-as-withdraw cases.
  TUNNEL_ENCAP = %w[tunnel_encap_tlv tunnel_encap_sub_tlv].freeze

  def self.startup
    return unless LabHelper::Compose.available?
    @@lab = LabHelper::Compose.new('fault-matrix')
    @@lab.down
    @@output, @@status = @@lab.up_until_exit('matrix')
    @@dir = Dir.mktmpdir('bgp4r-fault-matrix')
    begin
      @@lab.cp('matrix', '/tmp/fault-matrix.json', @@dir)
      @@results = JSON.parse(File.read(File.join(@@dir, 'fault-matrix.json')))
    rescue StandardError => e
      @@results = nil
      @@error = "#{e.class}: #{e.message}"
    end
  end

  def self.shutdown
    @@lab.down if defined?(@@lab)
    FileUtils.rm_rf(@@dir) if defined?(@@dir)
  end

  def setup
    unless defined?(@@lab)
      flunk('docker compose is not available') if ENV['LAB_REQUIRE_DOCKER'] == '1'
      omit('docker compose is not available')
    end
    unless @@results
      flunk("no results from the matrix: #{@@error}\n#{@@output}")
    end
  end

  def result(name)
    @@results.find { |r| r['name'] == name.to_s } or
      flunk("the matrix reported nothing for #{name}\n#{@@output}")
  end

  # The catalog cases whose expected RFC 7606 action is this one.
  def names_for(action)
    ACTIONS.select { |_, a| a == action }.keys.sort
  end

  def test_every_catalog_fault_was_sent
    sent = @@results.collect { |r| r['name'] }.sort
    assert_equal BGP::Fault::CATALOG.collect { |e| e.first.to_s }.sort, sent,
                 "the matrix must send every catalog case\n#{@@output}"
  end

  # A session that never came back means the harness lost the router, not
  # that the router answered. Fail loudly rather than read the verdicts.
  def test_every_fault_got_a_session
    lost = @@results.select { |r| r['outcome'] == 'no_session' }.collect { |r| r['name'] }
    assert_equal [], lost, "no session for these faults\n#{@@output}"
  end

  def test_the_two_session_reset_cases_reset_with_the_right_subcode
    RESETS.each do |name, subcode|
      r = result(name)
      assert_equal 'reset', r['outcome'], "#{name} must reset the session\n#{@@output}"
      assert_equal 3, r['code'], "#{name} NOTIFICATION code"
      assert_equal subcode, r['subcode'], "#{name} NOTIFICATION subcode"
    end
  end

  def test_no_other_fault_resets_the_session
    @@results.each do |r|
      next if RESETS.key?(r['name'])
      assert_not_equal 'reset', r['outcome'],
                       "#{r['name']} (#{r['expected']}) must not reset the session\n#{@@output}"
    end
  end

  # Every route verdict below rests on this one. fault_matrix.rb sends a
  # plain route of its own before the first fault and only asks the router
  # about a faulty one once it has seen that plain route installed. When
  # the baseline fails, rib_usable is false, every kept row comes back with
  # installed nil and a verdict of "session only", and the route columns
  # mean nothing. Fail on that rather than read them.
  def test_the_rib_answer_was_usable
    unscored = @@results.select { |r| r['outcome'] == 'kept' && r['installed'].nil? }
                        .collect { |r| r['name'] }
    assert_equal [], unscored,
                 "no RIB answer for these faults, so no route verdict here means anything.\n" \
                 "The matrix only reads the RIB after it has seen the router install a\n" \
                 "plain route. Either --rib-command is wrong, or the gobgp client is\n" \
                 "missing from the matrix image, or the router dropped the clean route\n" \
                 "too.\n#{@@output}"
  end

  # RFC 7606 treat-as-withdraw: the session stays up and the route does not
  # reach the RIB. Derived from the catalog, less the two cases GoBGP 3.23
  # gets wrong, which the next test covers.
  def test_the_treat_as_withdraw_cases_dropped_the_route
    names = names_for(:treat_as_withdraw) - TUNNEL_ENCAP
    assert_not_equal [], names, 'the catalog has no treat_as_withdraw case left to check'
    names.each do |name|
      assert_equal false, result(name)['installed'],
                   "#{name} is treat_as_withdraw, so the route must not be installed\n#{@@output}"
    end
  end

  # RFC 7606 attribute-discard: the attribute goes, the route stays.
  def test_the_attribute_discard_cases_kept_the_route
    names = names_for(:attribute_discard)
    assert_not_equal [], names, 'the catalog has no attribute_discard case left to check'
    names.each do |name|
      assert_equal true, result(name)['installed'],
                   "#{name} is attribute_discard, so the route must stay installed\n#{@@output}"
    end
  end

  # A known divergence, not a bgp4r bug. See TUNNEL_ENCAP above.
  def test_the_tunnel_encap_cases_record_a_known_gobgp_divergence
    TUNNEL_ENCAP.each do |name|
      r = result(name)
      assert_equal 'kept', r['outcome'], "#{name} must not reset the session\n#{@@output}"
      assert_equal true, r['installed'],
                   "#{name} installed=#{r['installed'].inspect}. This asserts what GoBGP\n" \
                   "3.23 does, not what the RFC asks. RFC 9012 section 13 is a MUST and\n" \
                   "asks for treat-as-withdraw; GoBGP discards the attribute and installs\n" \
                   "the route. bgp4r is right here and the router is not.\n" \
                   "If this now reports the route dropped, the router improved: drop\n" \
                   "#{name} from TUNNEL_ENCAP so it is derived with the other\n" \
                   "treat-as-withdraw cases, and update the GoBGP notes in\n" \
                   "docs/protocol-testing.md.\n#{@@output}"
    end
  end

  # The matrix exits non-zero when any answer differs from the catalog, so
  # with the RIB read it exits 1 against GoBGP 3.23: the two tunnel
  # encapsulation cases differ and nothing else does. Asserting the set,
  # rather than that it is empty, keeps the catalog honest about what the
  # RFC asks while still failing if a third case starts to differ.
  def test_the_only_disagreements_are_the_tunnel_encap_cases
    differs = @@results.select { |r| r['verdict'] == 'differs' }.collect { |r| r['name'] }.sort
    assert_equal TUNNEL_ENCAP.sort, differs,
                 "the only answers expected to differ from the catalog are the two\n" \
                 "RFC 9012 section 13 cases described in TUNNEL_ENCAP above. Anything\n" \
                 "else here is a new divergence, and an empty list means the router\n" \
                 "improved and this test should be updated.\n#{@@output}"
    assert_equal 1, @@status,
                 "the matrix exited #{@@status}. 1 is right while the tunnel encapsulation\n" \
                 "cases differ, because the matrix exits non-zero on any disagreement.\n#{@@output}"
  end

end
