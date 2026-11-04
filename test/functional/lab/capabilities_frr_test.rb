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


# Capabilities against FRR: which ones FRR's OPEN carries that bgp4r now
# names, and what FRR makes of the ones bgp4r sends. No Docker, no zebra.
#
#   ruby -I. test/functional/lab/capabilities_frr_test.rb
#
# Omitted when FRR's bgpd is not installed, unless LAB_REQUIRE_FRR=1.
#
# Why FRR: in lab/routescope/bgp4r-lab, on 2026-11-03, bgp4r read two of
# the capabilities real peers sent as Unknown that have an RFC, code 6
# (RFC 8654) and code 71 (RFC 9494). FRR 8.4.4 sends both here too,
# and both are named now.
# GoBGP 3.23.0 sends neither, measured on 2026-11-04, so there is no
# GoBGP twin; GoBGP 4.10.0 does send code 6.
#
# BGP:: names are written out in full, see Conventions in CLAUDE.md.

require 'test/unit'
require 'socket'
require 'bgp4r'
require_relative 'lab_helper'

class LabCapabilitiesFrrTest < Test::Unit::TestCase

  OUR_AS = 65001
  THEIR_AS = 65002
  F = LabHelper::Frr

  # The major version this was measured against, the shape and the
  # reason fault_matrix_frr_test.rb's MEASURED has.
  MEASURED = (8..8).freeze

  def setup
    unless F.available?
      flunk('FRR bgpd is not installed') if ENV['LAB_REQUIRE_FRR'] == '1'
      omit('FRR bgpd is not installed')
    end
    major = F.major
    unless major && MEASURED.cover?(major)
      omit("measured against FRR #{MEASURED}, found #{major.inspect}: re-measure before asserting")
    end
  end

  def teardown
    @thread.kill if @thread
    @peer.close if @peer
    @server.close if @server && !@server.closed?
    if @router
      @router.down
      puts "\n== bgpd\n#{@router.log}" unless passed?
    end
  end

  # Every OPEN the peer sends.
  class OpenCatcher
    attr_reader :opens
    def initialize ; @opens = [] ; end
    def update(msg) ; @opens << msg if msg.is_a?(BGP::Open) ; end
  end

  # A bgp4r speaker offering the capabilities named, and a bgpd dialling
  # it. Answers FRR's OPEN.
  def session(*caps)
    @server = TCPServer.new('127.0.0.1', 0)
    @peer = BGP::Neighbor.new(4, OUR_AS, 180, '10.0.0.1', '127.0.0.2', '127.0.0.1')
    @peer.capability :as4_byte
    caps.each { |c| @peer.capability(*Array(c)) }
    catcher = OpenCatcher.new
    @peer.add_observer catcher
    @thread = Thread.new do
      begin
        while (socket = @server.accept)
          @peer.start_session(socket)
        end
      rescue IOError, SystemCallError
      end
    end
    # No IPv6 family. Nothing here needs one, and FRR 10.5.1 refuses the
    # OPEN when IPv6 unicast is activated over an IPv4 session with no
    # zebra: it logs "No local IPv6 address, and zebra does not support
    # V6 routing with v4 nexthops" and sends Cease 6/0. FRR 8.4.4 only
    # warned. Measured on 2026-11-04.
    @router = F.new(:local => '127.0.0.2', :as => THEIR_AS, :router_id => '10.0.0.2',
                    :peer => '127.0.0.1', :peer_as => OUR_AS, :port => @server.addr[1],
                    :ipv6 => false)
    @router.up
    wait_for('the session') { @peer.is_established? }
    catcher.opens.last
  end

  def wait_for(what, timeout = 30)
    deadline = Time.now + timeout
    until yield
      flunk "#{what} (waited #{timeout}s)" if Time.now > deadline
      sleep 0.2
    end
  end

  # FRR's own report of one capability, from `show bgp neighbors json`.
  def frr_says(key)
    ((@router.neighbor('127.0.0.1') || {})['neighborCapabilities'] || {})[key]
  end

  # ---- RFC 8654, the BGP Extended Message Capability ------------------

  # FRR's OPEN carries code 6 with no value, and bgp4r reads it by name
  # and writes it back octet for octet.
  def test_frr_sends_the_extended_message_capability
    open = session
    caps = open.opt_parms.select { |c| c.is_a?(BGP::OPT_PARM::CAP::Extended_message) }
    assert_equal 1, caps.size, 'one Extended Message capability in FRR\'s OPEN'
    assert_equal '02020600', caps.first.to_shex
    assert_equal open.to_shex, BGP::Message.factory(open.encode).to_shex
  end

  # FRR's reading of what we sent, which is the half no bgp4r test can
  # give: "advertisedAndReceived" when we offer code 6 and "advertised"
  # when we do not. The second is the control, so the first is our
  # octets and not FRR's default.
  def test_frr_reads_the_extended_message_capability_we_send
    session(:extended_message)
    wait_for('FRR to report the capability') { frr_says('extendedMessage') }
    assert_equal 'advertisedAndReceived', frr_says('extendedMessage')
  end

  def test_frr_reports_none_received_when_we_do_not_send_it
    session
    wait_for('FRR to report the capability') { frr_says('extendedMessage') }
    assert_equal 'advertised', frr_says('extendedMessage')
  end

  # ---- RFC 9494, the Long-Lived Graceful Restart Capability -----------

  LLGR = BGP::OPT_PARM::CAP::Long_lived_graceful_restart

  # Graceful Restart listing IPv4 and IPv6 unicast, and both offered
  # through MBGP. FRR has only IPv4 activated, so IPv6 is the family it
  # must ignore. FRR reads an LLGR tuple only for a family that is both
  # negotiated and in the peer's Graceful Restart capability, which is
  # bgp_capability_llgr in bgpd/bgp_open.c at stable/8.4.
  def gr_with_families
    gr = BGP::OPT_PARM::CAP::Graceful_restart.new(0, 120)
    gr.add(1, 1, 0x80)
    gr.add(2, 1, 0)
    [[:mbgp, :ipv4, :unicast], [:mbgp, :ipv6, :unicast], gr]
  end

  # The stale times FRR logged reading our LLGR capability, one per
  # family, from debug bgp neighbor-events, which LabHelper::Frr turns on.
  def frr_read_stale_times
    @router.log.scan(/Addr-family (\S+)\(afi\/safi\) Long-lived Graceful Restart capability stale time (\d+) sec/)
  end

  # FRR's OPEN carries code 71: one tuple per family it has activated,
  # here IPv4 unicast alone, with the F bit set and a stale time of 0,
  # which is FRR's default llgr stale time. bgp4r reads
  # it by name and writes it back octet for octet.
  def test_frr_sends_the_llgr_capability
    open = session
    caps = open.opt_parms.select { |c| c.is_a?(LLGR) }
    assert_equal 1, caps.size, 'one LLGR capability in FRR\'s OPEN'
    assert_equal '0209470700010180000000', caps.first.to_shex
    assert_equal [[1, 1, 0x80, 0]], caps.first.tuples
    assert_equal open.to_shex, BGP::Message.factory(open.encode).to_shex
  end

  # FRR's reading of our tuples, which is the half no bgp4r test can
  # give. The IPv4 stale time fills all 24 bits with three different
  # octets, 0xabcdef, so a field written short, long or in the wrong
  # order reads back as a different number. The IPv6 tuple is for a
  # family FRR has not activated, so FRR ignores it, which is the rule
  # bgp_capability_llgr applies per family.
  #
  # FRR's JSON says "advertisedAndReceived" and nothing per family:
  # longLivedGracefulRestartByPeer tests PEER_CAP_ENHE_AF_RCV, the
  # extended next hop flag, where it means PEER_CAP_LLGR_AF_RCV, so it is
  # empty unless RFC 8950 was negotiated too. bgp_vty.c at stable/8.4.
  # A display bug, recorded and not filed. The log is what reads the
  # values, so the log is what this asserts.
  def test_frr_reads_the_stale_times_we_send
    llgr = LLGR.new(1, 1, 0x80, 0xabcdef).add(2, 1, 0, 3600)
    session(*gr_with_families, llgr)
    wait_for('FRR to report the capability') { frr_says('longLivedGracefulRestart') }
    assert_equal 'advertisedAndReceived', frr_says('longLivedGracefulRestart')
    wait_for('FRR to log the stale time') { frr_read_stale_times.size == 1 }
    assert_equal [['IPv4/unicast', '11259375']], frr_read_stale_times
    assert_match(%r{IPv6/unicast\(afi/safi\) not enabled\. Ignore the Long-lived Graceful Restart capability},
                 @router.log)
    assert_equal({}, frr_says('longLivedGracefulRestartByPeer'),
                 'FRR fixed its LLGR JSON: re-measure and assert the families')
  end

  # RFC 9494 sections 4.1 and 4.5: LLGR without Graceful Restart is to be
  # disregarded. FRR still reports it received and ignores every family,
  # which is section 4.1's rule. bgp4r sends it alone because nothing
  # here validates.
  def test_frr_ignores_llgr_without_graceful_restart
    session(LLGR.new(1, 1, 0x80, 3600))
    wait_for('FRR to report the capability') { frr_says('longLivedGracefulRestart') }
    assert_equal 'advertisedAndReceived', frr_says('longLivedGracefulRestart')
    wait_for('FRR to log the family') { @router.log =~ /Ignore the Long-lived Graceful Restart/ }
    assert_match(%r{IPv4/unicast\(afi/safi\) not enabled\. Ignore the Long-lived Graceful Restart capability},
                 @router.log)
    assert_equal [], frr_read_stale_times
  end

  # The control: with no LLGR from us FRR reports only its own.
  def test_frr_reports_llgr_advertised_only_when_we_do_not_send_it
    session
    wait_for('FRR to report the capability') { frr_says('longLivedGracefulRestart') }
    assert_equal 'advertised', frr_says('longLivedGracefulRestart')
  end
end
