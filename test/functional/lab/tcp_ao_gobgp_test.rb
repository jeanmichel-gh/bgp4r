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
# TCP-AO, RFC 5925, between bgp4rd and GoBGP 4, both directions. No
# Docker.
#
#   GOBGPD=~/gobgp/4.10.0/gobgpd GOBGP=~/gobgp/4.10.0/gobgp \
#     ruby -I. test/functional/lab/tcp_ao_gobgp_test.rb
#
# Omitted when gobgpd is not installed, unless LAB_REQUIRE_GOBGPD=1, and
# on any major but 4: GoBGP 3.23.0 has no TCP-AO.
#
# bgp4rd's `tcp_ao` against GoBGP's keychain: the same key brings the
# session up whichever side dials, with either of RFC 5926's MACs, and
# another key keeps it down. FRR 10.7.1 has no TCP-AO, so GoBGP is the
# second implementation here. test/functional/tcp_auth_test.rb is the
# same against a bare socket.
#
# BGP:: names are written out in full, see Conventions in CLAUDE.md.

require 'test/unit'
require 'stringio'
require 'tmpdir'
require 'fileutils'
require 'bgp4r'
require 'bgp/daemon'
require_relative 'lab_helper'

class LabTcpAoGobgpTest < Test::Unit::TestCase
  include LabHelper

  OUR_AS = 65001
  THEIR_AS = 65002
  GOBGP = '127.0.0.2'
  G = LabHelper::Gobgpd
  KEY = 's3cret'

  # v4.10.0 on the owner's VM on 2026-11-28.
  MEASURED_MAJOR = 4

  def setup
    unless G.available?
      flunk('gobgpd is not installed') if ENV['LAB_REQUIRE_GOBGPD'] == '1'
      omit('gobgpd is not installed')
    end
    unless G.major == MEASURED_MAJOR
      omit("measured against GoBGP #{MEASURED_MAJOR}, found #{G.major.inspect}: re-measure before asserting")
    end
    @dir = Dir.mktmpdir('bgp4r-tcp-ao')
    @err = StringIO.new
  end

  def teardown
    @router.down if @router
    @server.stop if @server
    unless passed?
      puts "\n== gobgpd\n#{@router.log}" if @router
      puts "\n== bgp4rd\n#{@err.string}" if @err
    end
    FileUtils.remove_entry(@dir) if @dir
  end

  # GoBGP dials, bgp4rd's listener holds the key.
  def test_gobgp_dials_with_the_same_key
    start(ours: [[1, 1, KEY]], theirs: [[1, 1, KEY]])
    established
    assert_match(/TCP-AO keychain is bgp4r, send ID: 1/, @router.neighbor('127.0.0.1'))
  end

  # bgp4rd dials GoBGP's listener, its SYN signed before connect.
  def test_bgp4rd_dials_with_the_same_key
    start(ours: [[1, 1, KEY]], theirs: [[1, 1, KEY]], connect: true)
    established
  end

  # RFC 5926's other MAC, AES-128-CMAC-96: cmac(aes128) to the kernel.
  def test_aes_128_cmac_96_both_ways
    [false, true].each do |connect|
      start(ours: [[1, 1, KEY, 'cmac(aes128)']], theirs: [[1, 1, KEY, 'aes-128-cmac-96']], connect: connect)
      established
      stop
    end
  end

  # Two keys each side. GoBGP starts on its SendID 2, and bgp4rd's
  # listener answers with the key that KeyID names; bgp4rd starts on its
  # first key, 1, and GoBGP's listener takes it.
  def test_either_side_starts_on_a_key_the_other_holds
    ours = [[1, 1, 'one'], [2, 2, 'two']]
    start(ours: ours, theirs: ours, send_id: 2)
    established
    stop
    start(ours: ours, theirs: ours, send_id: 2, connect: true)
    established
  end

  # The control: another key never comes up, either way.
  def test_another_key_keeps_the_session_down
    [false, true].each do |connect|
      start(ours: [[1, 1, KEY]], theirs: [[1, 1, 'other']], connect: connect)
      sleep 8 # either side dials every 2 s
      assert_not_equal('established', state, "connect: #{connect}")
      stop
    end
  end

  private

  # ours: bgp4rd's keys as [send_id, recv_id, key, algorithm];
  # theirs: GoBGP's as [send_id, recv_id, key, algorithm], its own names.
  def start(ours:, theirs:, connect: false, send_id: 1)
    @router = G.new(:local => GOBGP, :as => THEIR_AS, :router_id => '10.0.0.2',
                    :peer => '127.0.0.1', :peer_as => OUR_AS, :ipv6 => false,
                    :port => LabHelper::Local.free_port, :passive => connect,
                    :tcp_ao => { :send_id => send_id, :keys => theirs })
    keys = ours.collect do |snd, rcv, key, alg|
      { 'send_id' => snd, 'recv_id' => rcv, 'key' => key }.merge(alg ? { 'algorithm' => alg } : {})
    end
    n = { 'address' => GOBGP, 'as' => THEIR_AS, 'tcp_ao' => { 'keys' => keys } }
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

  def stop
    @router.down
    @server.stop
    @router = @server = nil
    FileUtils.rm_f(File.join(@dir, 'state.json'))
  end

  def state
    @client.call('show.peers').first['state']
  end

  def established
    wait_for('the session with GoBGP to be established', timeout: 60) { state == 'established' }
    assert_equal('tcp-ao', @client.call('show.peers').first['auth'])
  end
end
