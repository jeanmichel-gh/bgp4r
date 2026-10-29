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
# The checks are in fault_matrix_scenario.rb, shared with
# fault_matrix_native_test.rb, which runs the same matrix against a
# native gobgpd and needs no Docker at all.

require 'test/unit'
require 'bgp4r'
require 'json'
require 'fileutils'
require_relative 'lab_helper'
require_relative 'fault_matrix_scenario'

class LabFaultMatrixComposeTest < Test::Unit::TestCase
  include FaultMatrixScenario

  # The compose file's default, which has to be known here because the
  # answers are not the same on every version: see GOBGP_3 in
  # fault_matrix_scenario.rb.
  DEFAULT_IMAGE = 'jauderho/gobgp:v4.10.0'

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

  def results ; @@results ; end
  def output ; @@output ; end
  def exit_status ; @@status ; end

  # GoBGP installs the route for both RFC 9012 section 13 cases, on every
  # version measured.
  def installed_divergences ; FaultMatrixScenario::TUNNEL_ENCAP ; end

  # GoBGP 3 resets on attr_overrun where RFC 7606 section 4 makes
  # treat-as-withdraw a MUST, and GoBGP 4 fixed it, so the expectation
  # follows the image. The compose file's default is a 4.x image;
  # GOBGP_IMAGE=jauderho/gobgp:v3.23.0 is what docs/protocol-testing.md
  # tells a reader to run to see the older answers, and that has to still
  # assert correctly.
  def reset_divergences
    image = ENV['GOBGP_IMAGE'] || DEFAULT_IMAGE
    image =~ /:v?3\./ ? FaultMatrixScenario::GOBGP_3 : {}
  end
end
