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
# TCP MD5, RFC 2385, between bgp4rd and FRR's bgpd, both directions. No
# Docker, no zebra.
#
#   ruby -I. test/functional/lab/md5_frr_test.rb
#
# Omitted when FRR's bgpd is not installed, unless LAB_REQUIRE_FRR=1.
#
# bgp4rd's `password` against FRR's `neighbor X password`: the same key
# brings the session up whichever side dials, and another key keeps it
# down. test/functional/tcp_auth_test.rb is the same against a bare
# socket; this is the second implementation's reading of our digest.
#
# BGP:: names are written out in full, see Conventions in CLAUDE.md.

require 'test/unit'
require 'stringio'
require 'tmpdir'
require 'fileutils'
require 'bgp4r'
require 'bgp/daemon'
require_relative 'lab_helper'

class LabMd5FrrTest < Test::Unit::TestCase
  include LabHelper

  OUR_AS = 65001
  THEIR_AS = 65002
  FRR = '127.0.0.2'
  F = LabHelper::Frr
  KEY = 's3cret'

  # 10.5.1 on the owner's VM on 2026-11-25. 8 is CI's 24.04 image and
  # was not run here, so its first CI run is its measurement.
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
    @dir = Dir.mktmpdir('bgp4r-md5')
    @err = StringIO.new
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

  # FRR dials, bgp4rd's listener holds the key.
  def test_frr_dials_with_the_same_key
    start(our_key: KEY, their_key: KEY)
    established
  end

  # bgp4rd dials FRR's listener, its SYN signed before connect.
  def test_bgp4rd_dials_with_the_same_key
    start(our_key: KEY, their_key: KEY, connect: true)
    established
  end

  # The control: the same pair with two keys never comes up, either way.
  def test_another_key_keeps_the_session_down
    start(our_key: KEY, their_key: 'other')
    sleep 8 # FRR dials every 2 s
    assert_not_equal('established', state)
    assert_not_equal('Established', @router.neighbor('127.0.0.1')&.dig('bgpState'))
  end

  private

  def start(our_key:, their_key:, connect: false)
    @router = F.new(:local => FRR, :as => THEIR_AS, :router_id => '10.0.0.2',
                    :peer => '127.0.0.1', :peer_as => OUR_AS,
                    :port => LabHelper::Local.free_port, :password => their_key)
    n = { 'address' => FRR, 'as' => THEIR_AS, 'password' => our_key }
    n.merge!('connect' => true, 'port' => @router.listen_port, 'retry' => 2) if connect
    config = BGP::Daemon::Server.with_defaults(
      'as' => OUR_AS, 'router_id' => '10.0.0.1',
      'listen_address' => '127.0.0.1', 'port' => @router.port,
      'state_file' => File.join(@dir, 'state.json'),
      'neighbors' => [n])
    @server = BGP::Daemon::Server.new(StringIO.new, @err)
    assert_not_nil(@server.build(config, :socket => File.join(@dir, 'bgp4rd.sock')),
                   "bgp4rd did not start: #{@err.string}")
    @router.up
    @client = BGP::Daemon::Client.new(File.join(@dir, 'bgp4rd.sock'))
  end

  def state
    @client.call('show.peers').first['state']
  end

  def established
    wait_for('the session with FRR to be established', timeout: 60) { state == 'established' }
    assert_equal('md5', @client.call('show.peers').first['auth'])
  end
end
