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

# The RTR matrix against FRR's bgpd as the router: each case of
# BGP::Fault::RTR and BGP::Fault::RTR_BEHAVIOURS sent by an Rtr::Cache
# over loopback, on a cache and a bgpd of their own, and what bgpd did,
# read from the cache's events, held to a table measured against
# 10.5.1 on the owner's VM. bgpd with `-M rpki`, no BGP peer, no zebra.
# docs/design/bgp-operations.md 7c, pull request 7c3.
#
#   ruby -I. test/functional/lab/rtr_fault_frr_test.rb
#
# Omitted when FRR's bgpd or its RPKI module is not installed, unless
# LAB_REQUIRE_FRR=1.
#
# BGP:: names are written out in full, see Conventions in CLAUDE.md.

require 'test/unit'
require 'stringio'
require 'bgp4r'
require 'bgp/rtr/cache'
require_relative 'lab_helper'

class LabRtrFaultFrrTest < Test::Unit::TestCase
  include LabHelper

  F = LabHelper::Frr

  # 10.5.1. Others were not run here; 10.7.1 answered the same codes by
  # hand (docs/rpki.md section 4).
  MEASURED = (10..10).freeze

  VRPS = [{ 'prefix' => '192.0.2.0/24', 'asn' => 65_001 },
          { 'prefix' => '198.51.100.0/22', 'max_length' => 24, 'asn' => 65_099 }].freeze

  # The cache's Retry Interval, which bgpd takes from the End of Data.
  RETRY = 5

  # What bgpd answered each fault with, measured on 2026-11-27.
  # rtr_unknown_pdu is not what RFC 8210 section 12 expects, 5: bgpd's
  # RTRlib reads the PDU's length before its type, and says "length
  # value in PDU is too small".
  FRR_DID = {
    :rtr_unknown_pdu        => 0,
    :rtr_bad_version        => 8,
    :rtr_unexpected_version => 8,
    :rtr_withdraw_unknown   => 6,
    :rtr_duplicate_announce => 7,
    :rtr_corrupt_length     => 0,
  }.freeze

  # After these two bgpd does not come back by itself: not in 25 s on
  # 10.5.1, and not in four minutes on 10.7.1, where `rpki reset` brought
  # it back. After the other four it is back at the Retry Interval. Why
  # is not known.
  FRR_STAYS_DOWN = %i[rtr_withdraw_unknown rtr_duplicate_announce].freeze

  def setup
    unless F.available? && F.rpki?
      flunk("FRR bgpd #{F.available? ? 'has no RPKI module' : 'is not installed'}") if ENV['LAB_REQUIRE_FRR'] == '1'
      omit("FRR bgpd #{F.available? ? 'has no RPKI module (frr-rpki-rtrlib)' : 'is not installed'}")
    end
    major = F.major
    unless F.measured?(MEASURED, major)
      omit("measured against FRR #{MEASURED}, found #{major.inspect}: re-measure before asserting")
    end
  end

  def teardown
    puts "\n== bgpd\n#{@router.log}" if @router && !passed?
    stop
  end

  # Section 12: each fault drops the session, and bgpd keeps the table
  # it had (section 6 keeps it until Expire).
  def test_every_fault
    got = {}
    BGP::Fault.rtr_names.each do |name|
      start
      n = @cache.events.seq
      @cache.act('fault', 'name' => name.to_s)
      assert(wait_until(10) { events('error_received', n).any? && events('closed', n).any? }, "#{name}: an Error Report, closed")
      got[name] = events('error_received', n).first.data[:code]
      assert_equal(2, table, "#{name}: the table kept")
      back = wait_until(RETRY + 3) { events('answer', n).any? }
      assert_equal(!FRR_STAYS_DOWN.include?(name), back, "#{name}: back at the Retry Interval")
      stop
    end
    assert_equal(FRR_DID, got)
  end

  # Section 8.4: No Data Available keeps the session and the table; bgpd
  # asks again at the Retry Interval, and loads the change once the
  # cache answers.
  def test_rtr_no_data
    start
    n = @cache.events.seq
    @cache.act('behaviour', 'name' => 'rtr_no_data', 'away' => 30)
    @cache.change(announce: [{ 'prefix' => '10.0.0.0/8', 'asn' => 1 }])
    assert(wait_until(RETRY * 2 + 2) { events('error_sent', n).size >= 2 }, 'asked again at the Retry Interval')
    assert_equal([[], 2], [events('closed', n), table])
    @cache.act('behaviour', 'name' => 'rtr_no_data', 'away' => 0)
    assert(wait_until(RETRY + 3) { table == 3 }, 'the change, once the cache answers')
  end

  # Section 6: a silent cache. bgpd keeps the table; Expire is at least
  # 600 s, so it going is bgp4rd's matrix's, on a manual clock.
  def test_rtr_silent
    start
    n = @cache.events.seq
    @cache.act('behaviour', 'name' => 'rtr_silent', 'away' => 3)
    @cache.change(announce: [{ 'prefix' => '10.0.0.0/8', 'asn' => 1 }])
    sleep 2
    assert_equal([[], 2], [events('answer', n), table], 'nothing answered, the table kept')
    assert(wait_until(5) { table == 3 }, 'the change, after it')
  end

  # Section 8.3: after a Cache Reset, a Reset Query.
  def test_rtr_cache_reset
    start
    n = @cache.events.seq
    @cache.act('behaviour', 'name' => 'rtr_cache_reset')
    assert(wait_until(5) { events('answer', n).any? { |e| e.message.include?('reset query') } }, 'a Reset Query')
    assert(wait_until(3) { table == 2 })
  end

  private

  def start
    @cache = BGP::Rtr::Cache.new('session_id' => 9, 'notify_every' => 0, 'retry' => RETRY, 'vrps' => VRPS)
    @cache.listen('127.0.0.1', 0)
    @ticker = Thread.new { loop { @cache.tick ; sleep 0.05 } }
    @router = F.new(:port => LabHelper::Local.free_port, :modules => ['rpki'],
                    :lines => ['rpki', " rpki retry_interval #{RETRY}",
                               " rpki cache tcp 127.0.0.1 #{@cache.port} preference 1", 'exit'])
    @router.up
    assert(wait_until(15) { events('answer').any? && table == 2 }, "bgpd loaded the table: #{@router.vty('show rpki cache-connection')}")
  end

  def stop
    @router&.down
    @ticker&.kill
    @cache&.stop
    @router = @cache = @ticker = nil
  end

  def events(what, from = 0) ; @cache.events.since(from).select { |e| e.data[:event] == what } ; end

  # How many IPv4 VRPs bgpd holds, or nil while it does not answer.
  def table ; (@router.vty_json('show rpki prefix-table json') || {})['ipv4PrefixCount'] ; end

  def wait_until(seconds)
    deadline = Time.now + seconds
    until Time.now > deadline
      return true if yield
      sleep 0.2
    end
    false
  end
end
