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

# What FRR reads when bgp4rd ends a session on purpose. No Docker, no
# zebra.
#
#   ruby -I. test/functional/lab/cease_frr_test.rb
#
# Omitted when FRR's bgpd is not installed, unless LAB_REQUIRE_FRR=1.
#
# bgp4rd sends a Cease before it closes a session it ends on purpose,
# with the RFC 4486 section 4 subcode for why: `peer.clear` 6/4
# Administrative Reset, `peer.stop` 6/2 Administrative Shutdown, and a
# `config.commit` that bounces the session 6/6 Other Configuration
# Change. test/functional/daemon_test.rb reads each off a bgp4r peer.
# This is the second implementation's reading: FRR's own
# `lastErrorCodeSubcode` and `lastNotificationReason` for the neighbor,
# and the reset cause `BGP Notification received`, which is what says
# the peer saw an administrative reset and not a dropped connection.
#
# The daemon runs in process and is driven through its control socket,
# the way routescope and bgp4r-cli drive it. FRR dials it, so a session
# that ends comes back on FRR's own connect timer.
#
# BGP:: names are written out in full, see Conventions in CLAUDE.md.

require 'test/unit'
require 'stringio'
require 'tmpdir'
require 'fileutils'
require 'bgp4r'
require 'bgp/daemon'
require_relative 'lab_helper'

class LabCeaseFrrTest < Test::Unit::TestCase
  include LabHelper

  OUR_AS = 65001
  THEIR_AS = 65002
  FRR = '127.0.0.2'
  F = LabHelper::Frr

  # 10.5.1 on the owner's VM on 2026-11-15: 3 tests, all passing, with
  # FRR_BGPD pointing at a copy of the binary for the AppArmor reason
  # capabilities_frr_test.rb gives. 8 is CI's 24.04 image and was not
  # run here, so its first CI run is its measurement.
  MEASURED = (8..10).freeze

  def setup
    unless F.available?
      flunk('FRR bgpd is not installed') if ENV['LAB_REQUIRE_FRR'] == '1'
      omit('FRR bgpd is not installed')
    end
    major = F.major
    unless F.measured?(MEASURED, major)
      omit("measured against FRR #{MEASURED}, found #{major.inspect}: re-measure before asserting")
    end
    @dir = Dir.mktmpdir('bgp4r-cease')
    port = LabHelper::Local.free_port
    @err = StringIO.new
    @server = BGP::Daemon::Server.new(StringIO.new, @err)
    config = BGP::Daemon::Server.with_defaults(
      'as' => OUR_AS, 'router_id' => '10.0.0.1',
      'listen_address' => '127.0.0.1', 'port' => port,
      'state_file' => File.join(@dir, 'state.json'),
      'neighbors' => [{ 'address' => FRR, 'as' => THEIR_AS }])
    assert_not_nil(@server.build(config, :socket => File.join(@dir, 'bgp4rd.sock')),
                   "bgp4rd did not start: #{@err.string}")
    @router = F.new(:local => FRR, :as => THEIR_AS, :router_id => '10.0.0.2',
                    :peer => '127.0.0.1', :peer_as => OUR_AS, :port => port)
    @router.up
    @client = BGP::Daemon::Client.new(File.join(@dir, 'bgp4rd.sock'))
    established
  end

  def teardown
    @router.down if @router
    @server.stop if @server
    unless passed?
      puts "\n== bgpd\n#{@router.log}" if @router
      puts "\n== bgp4rd\n#{@err.string}" if @err
    end
    FileUtils.remove_entry(@dir) if @dir
  end

  def test_peer_clear_is_read_as_administrative_reset
    r = @client.call('peer.clear', 'peer' => FRR)
    assert_equal('cease/administrative_reset', r['notification'])
    assert_frr_read('0604', 'Cease/Administrative Reset')
    established
  end

  def test_peer_stop_is_read_as_administrative_shutdown
    r = @client.call('peer.stop', 'peer' => FRR)
    assert_equal('cease/administrative_shutdown', r['notification'])
    assert_frr_read('0602', 'Cease/Administrative Shutdown')
    @client.call('peer.start', 'peer' => FRR)
    established
  end

  def test_a_bounce_is_read_as_other_configuration_change
    @client.call('config.load', 'lines' => ["set neighbors #{FRR} hold_time 90"])
    r = @client.call('config.commit')
    assert_equal(true, r['ok'], r.inspect)
    assert_match(/Cease 6\/6/, r['warnings'].first)
    assert_frr_read('0606', 'Cease/Other Configuration Change')
    established
  end

  private

  def established
    wait_for('the session with FRR to be established', timeout: 60) do
      @client.call('show.peers').first['state'] == 'established'
    end
  end

  # FRR's own record of the last reset, once the session has left
  # Established on its side.
  def assert_frr_read(code_subcode, reason)
    n = wait_for("FRR to record a NOTIFICATION #{code_subcode}") do
      x = @router.neighbor('127.0.0.1')
      x if x && x['lastErrorCodeSubcode'] == code_subcode
    end
    assert_equal(reason, n['lastNotificationReason'])
    assert_equal('BGP Notification received', n['lastResetDueTo'],
                 'FRR saw the session end some other way')
  end

end
