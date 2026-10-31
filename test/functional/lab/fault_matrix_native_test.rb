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

# The RFC 7606 fault matrix against a native gobgpd on loopback, no
# Docker. Same checks as fault_matrix_test.rb, which runs the Compose
# topology; see fault_matrix_scenario.rb for what they are.
#
#   ruby -I. test/functional/lab/fault_matrix_native_test.rb
#
# Omitted when gobgpd is not installed, unless LAB_REQUIRE_GOBGPD=1.
# GOBGPD and GOBGP name the binaries when they are not on PATH, so one
# machine can answer for more than one version:
#
#   GOBGPD=/opt/gobgp4/gobgpd GOBGP=/opt/gobgp4/gobgp \
#     ruby -I. test/functional/lab/fault_matrix_native_test.rb
#
# Why this exists next to the Compose test. The GoBGP column in
# docs/protocol-testing.md was measured by hand and then never re-run,
# because the only harness that could re-run it needed a Docker daemon.
# One row of it was wrong for the version it named. A conformance claim
# that nothing checks is the same mistake as an unread RFC citation, and
# this is the harness that needs nothing but the binary.
#
# It takes a few minutes: every catalog case gets its own session, and
# the router has to be given time to answer each one.

require 'test/unit'
require 'json'
require 'open3'
require 'rbconfig'
require 'timeout'
require 'tmpdir'
require 'fileutils'
require_relative 'lab_helper'
require_relative 'fault_matrix_scenario'

class LabFaultMatrixNativeTest < Test::Unit::TestCase
  include FaultMatrixScenario

  # Versions whose answers have been measured. A version outside this is
  # not asserted against, because choosing its expectations would mean
  # guessing which of its answers are bugs.
  MEASURED = (3..4).freeze

  def self.startup
    @@results, @@status, @@output, @@error = nil, nil, '', nil
    return unless LabHelper::Gobgpd.available?
    @@major = LabHelper::Gobgpd.major
    return unless @@major && MEASURED.cover?(@@major)
    @@router = LabHelper::Gobgpd.new
    @@dir = Dir.mktmpdir('bgp4r-fault-matrix-native')
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
      @@output = "#{LabHelper::Gobgpd.version}\n#{@@output}\n== gobgpd\n#{@@router.log}"
    end
  end

  # The matrix in a process of its own, which is also how a person runs
  # it. Its exit status is part of the answer, so a non-zero one is
  # never raised on here.
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
                             '--next-hop', router.peer,
                             '--settle', ENV.fetch('FAULT_SETTLE', '2'),
                             # We dial the router, rather than waiting for
                             # it to dial us. Each case needs a session of
                             # its own and GoBGP takes 10 to 14s to come
                             # back, whatever its timers are set to, where
                             # it accepts one from us in under 3s.
                             '--dial', router.listen_port.to_s,
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
    unless LabHelper::Gobgpd.available?
      flunk('gobgpd is not installed') if ENV['LAB_REQUIRE_GOBGPD'] == '1'
      omit('gobgpd is not installed')
    end
    unless defined?(@@major) && @@major && MEASURED.cover?(@@major)
      omit("#{LabHelper::Gobgpd.version} has not been measured, so there is " \
           'nothing here to assert against it')
    end
    unless @@results
      flunk("no results from the matrix: #{@@error}\n#{@@output}")
    end
  end

  def results ; @@results ; end
  def output ; @@output ; end
  def exit_status ; @@status ; end

  # GoBGP installs the route for both RFC 9012 section 13 cases, on every
  # version measured.
  def installed_divergences ; FaultMatrixScenario::TUNNEL_ENCAP ; end

  # GoBGP 3 resets on attr_overrun where RFC 7606 section 4 makes
  # treat-as-withdraw a MUST. GoBGP 4 fixed it.
  def reset_divergences
    @@major == 3 ? FaultMatrixScenario::GOBGP_3 : {}
  end

end
