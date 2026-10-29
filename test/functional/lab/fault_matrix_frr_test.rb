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

# The RFC 7606 fault matrix against FRR's bgpd on loopback, no Docker and
# no zebra. The same checks as the two GoBGP runs; see
# fault_matrix_scenario.rb for what they are.
#
#   ruby -I. test/functional/lab/fault_matrix_frr_test.rb
#
# Omitted when bgpd is not installed, unless LAB_REQUIRE_FRR=1. FRR_BGPD
# and VTYSH name the binaries when they are not where a distribution
# package puts them, so one machine can answer for more than one version:
#
#   FRR_BGPD=/opt/frr10/bgpd VTYSH=/opt/frr10/vtysh \
#     ruby -I. test/functional/lab/fault_matrix_frr_test.rb
#
# **Why a second router, and why this one.** The FRR column in
# docs/protocol-testing.md was measured by hand against 8.4.4 and never
# re-run, exactly like the GoBGP column whose `attr_overrun` row turned
# out to be wrong for the version it named. The docs also only claimed the
# session level outcomes for FRR, because the hand measurement had no way
# to read its RIB. Both halves are asserted here now, so the column is
# measured rather than remembered.
#
# And a second implementation is the point of the lab. Two bgp4r speakers
# agreeing proves nothing, which is how the inverted ADD-PATH Send/Receive
# field survived for years (see #115 and #153). GoBGP agreeing with FRR on
# a row says the row is about the RFC; the two disagreeing says it is
# about the router.
#
# It takes a few minutes: every catalog case gets its own session, and the
# router has to be given time to answer each one.

require 'test/unit'
require 'json'
require 'open3'
require 'rbconfig'
require 'timeout'
require 'tmpdir'
require 'fileutils'
require_relative 'lab_helper'
require_relative 'fault_matrix_scenario'

class LabFaultMatrixFrrTest < Test::Unit::TestCase
  include FaultMatrixScenario

  # Versions whose answers have been measured. A version outside this is
  # not asserted against, because choosing its expectations would mean
  # guessing which of its answers are bugs. Same rule as the GoBGP test's
  # MEASURED, and the same reason.
  MEASURED = (8..8).freeze

  def self.startup
    @@results, @@status, @@output, @@error = nil, nil, '', nil
    return unless LabHelper::Frr.available?
    @@major = LabHelper::Frr.major
    return unless @@major && MEASURED.cover?(@@major)
    @@router = LabHelper::Frr.new(:ipv6 => false)
    @@dir = Dir.mktmpdir('bgp4r-fault-matrix-frr')
    json = File.join(@@dir, 'fault-matrix.json')
    begin
      @@router.up
      @@output, @@status = run_matrix(@@router, json)
      @@results = JSON.parse(File.read(json))
    rescue StandardError => e
      @@results = nil
      @@error = "#{e.class}: #{e.message}"
    ensure
      # The router's own log says what it made of each UPDATE, in its
      # words, and it goes with the daemon, so take it while it is there.
      @@router.down
      @@output = "#{LabHelper::Frr.version}\n#{@@output}\n== bgpd\n#{@@router.log}"
    end
  end

  # The matrix in a process of its own, which is also how a person runs
  # it. Its exit status is part of the answer, so a non-zero one is never
  # raised on here.
  def self.run_matrix(router, json)
    out = nil
    status = Timeout.timeout(900) do
      o, s = Open3.capture2e(RbConfig.ruby, '-I.',
                             File.join(LabHelper::ROOT, 'lab', 'fault_matrix.rb'),
                             '--peer', router.local,
                             '--peer-as', router.as.to_s,
                             '--listen', router.peer,
                             '--port', router.port.to_s,
                             '--my-as', router.peer_as.to_s,
                             # Not router.peer, which is what the GoBGP
                             # runs pass. FRR drops a route whose next hop
                             # is a loopback address; see Frr::NEXT_HOP.
                             '--next-hop', LabHelper::Frr::NEXT_HOP,
                             '--settle', ENV.fetch('FAULT_SETTLE', '2'),
                             '--rib-command', router.rib_command,
                             '--json', json,
                             chdir: LabHelper::ROOT)
      out = o
      s.exitstatus
    end
    [out, status]
  end

  def self.shutdown
    @@router.down if defined?(@@router)
    FileUtils.rm_rf(@@dir) if defined?(@@dir)
  end

  def setup
    unless LabHelper::Frr.available?
      flunk('FRR bgpd is not installed') if ENV['LAB_REQUIRE_FRR'] == '1'
      omit('FRR bgpd is not installed')
    end
    unless defined?(@@major) && @@major && MEASURED.cover?(@@major)
      omit("#{LabHelper::Frr.version} has not been measured, so there is " \
           'nothing here to assert against it')
    end
    unless @@results
      flunk("no results from the matrix: #{@@error}\n#{@@output}")
    end
  end

  def results ; @@results ; end
  def output ; @@output ; end
  def exit_status ; @@status ; end

  def installed_divergences ; FaultMatrixScenario::FRR_8_INSTALLED ; end
  def reset_divergences ; FaultMatrixScenario::FRR_8_RESETS ; end
  def reset_subcode_overrides ; FaultMatrixScenario::FRR_8_SUBCODES ; end

  # FRR 8.4.4 gets every treat_as_withdraw case wrong, so the derived test
  # for that category has nothing left to check and says so rather than
  # passing while asserting nothing. See wholesale_divergences.
  def wholesale_divergences ; [:treat_as_withdraw] ; end

end
