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
# What this guards is the session level answer: which faults make a
# conformant router reset, with which NOTIFICATION subcode, and that the
# rest leave the session up. That is the half of RFC 7606 that needs no
# look at the router's RIB, so it holds for any router that implements
# the RFC. Telling treat-as-withdraw from attribute-discard needs the
# RIB, which this topology does not read; docs/protocol-testing.md shows
# that run by hand.

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
    @@results.find { |r| r['name'] == name.to_s }
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

  # The matrix exits non-zero when any answer differs from the catalog.
  # Without a RIB read the two session reset cases are the only ones it
  # can score, so a conformant router gives 0 here.
  def test_the_matrix_run_agreed_with_the_catalog
    differs = @@results.select { |r| r['verdict'] == 'differs' }.collect { |r| r['name'] }
    assert_equal [], differs, "these answers differ from the catalog\n#{@@output}"
    assert_equal 0, @@status, "the matrix exited #{@@status}\n#{@@output}"
  end

end
