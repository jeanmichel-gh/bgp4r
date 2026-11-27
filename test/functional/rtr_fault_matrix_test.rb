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

require 'test/unit'
require 'bgp/daemon/speaker'
require 'bgp/daemon/views'
require 'bgp/rtr/cache'

# The RTR matrix against bgp4rd's client: each case of BGP::Fault::RTR
# and BGP::Fault::RTR_BEHAVIOURS sent by an Rtr::Cache over loopback, on
# a cache and a speaker of its own, and what bgp4rd did, read from the
# cache's events. docs/design/bgp-operations.md 7c, pull request 7c3;
# the table is in docs/protocol-testing.md.
class TestRtrFaultMatrix < Test::Unit::TestCase

  VRPS = [{ 'prefix' => '192.0.2.0/24', 'asn' => 65_001 },
          { 'prefix' => '198.51.100.0/22', 'max_length' => 24, 'asn' => 65_099 }].freeze

  # The clock bgp4rd's client runs on, moved by hand so Expire (RFC
  # 8210 section 6) comes without waiting ten minutes.
  class Clock
    def initialize ; @offset = 0 ; @lock = Mutex.new ; end
    def call ; Process.clock_gettime(Process::CLOCK_MONOTONIC) + @lock.synchronize { @offset } ; end
    def advance(seconds) ; @lock.synchronize { @offset += seconds } ; end
  end

  def setup
    @cache = BGP::Rtr::Cache.new('session_id' => 9, 'notify_every' => 0, 'retry' => 1, 'vrps' => VRPS)
    @cache.listen('127.0.0.1', 0)
    @ticker = Thread.new { loop { @cache.tick ; sleep 0.05 } }
    @clock = Clock.new
    @sp = BGP::Daemon::Speaker.new({ 'as' => 65_000, 'router_id' => '10.0.0.1', 'log_level' => 'error', 'neighbors' => [],
                                     'rpki' => { 'caches' => [{ 'address' => '127.0.0.1', 'port' => @cache.port, 'retry' => 1 }] } },
                                   :rpki_clock => @clock).start
    assert(wait_until { answers.size == 1 && vrps == 2 }, 'bgp4rd loaded the table')
  end

  def teardown
    @sp&.stop
    @ticker&.kill
    @cache&.stop
  end

  def wait_until(seconds = 5)
    deadline = Time.now + seconds
    until Time.now > deadline
      return true if yield
      sleep 0.05
    end
    false
  end

  def events(what, from = 0) ; @cache.events.since(from).select { |e| e.data[:event] == what } ; end
  def answers(from = 0) ; events('answer', from) ; end
  def vrps ; BGP::Daemon::Views.new(@sp).rpki_vrps[:total] ; end
  def client ; BGP::Daemon::Views.new(@sp).rpki[:rows].first ; end

  # RFC 8210 section 12: the code each fault expects, the session
  # dropped, the data kept (section 6 keeps it until Expire), and
  # bgp4rd back with a query once the cache's Retry has passed.
  def test_every_fault
    got = {}
    BGP::Fault.rtr_catalog.each do |c|
      setup unless @cache
      n = @cache.events.seq
      @cache.act('fault', 'name' => c[:name].to_s)
      assert(wait_until { events('error_received', n).any? && events('closed', n).any? }, "#{c[:name]}: an Error Report, closed")
      got[c[:name]] = events('error_received', n).first.data[:code]
      assert_equal(2, vrps, "#{c[:name]}: the data kept")
      assert(wait_until(5) { answers(n).any? }, "#{c[:name]}: back, and answered")
      teardown
      @cache = @sp = nil
    end
    assert_equal(BGP::Fault.rtr_catalog.to_h { |c| [c[:name], c[:expected]] }, got)
  end

  # Section 8.4: No Data Available is not fatal; the session and the
  # data stay, and bgp4rd asks again.
  def test_rtr_no_data
    n = @cache.events.seq
    @cache.act('behaviour', 'name' => 'rtr_no_data', 'away' => 30)
    @cache.change(announce: [{ 'prefix' => '10.0.0.0/8', 'asn' => 1 }])
    assert(wait_until { events('error_sent', n).any? }, 'No Data Available sent')
    assert_equal(2, events('error_sent', n).first.data[:code])
    assert(wait_until(4) { events('error_sent', n).size >= 2 }, 'asked again at the Retry Interval')
    assert_equal([[], 2, 'up'], [events('closed', n), vrps, client[:state]])
    @cache.act('behaviour', 'name' => 'rtr_no_data', 'away' => 0)
    assert(wait_until(4) { vrps == 3 }, 'the change, once the cache answers')
  end

  # Section 6: a cache that answers nothing; the data is used until
  # Expire, then goes, and every route is NotFound.
  def test_rtr_silent
    n = @cache.events.seq
    @cache.act('behaviour', 'name' => 'rtr_silent', 'away' => 3600)
    @clock.advance(client[:refresh] + 1)
    assert(wait_until { events('ignored', n).any? }, 'a query, not answered')
    assert_equal(2, vrps, 'kept before Expire')
    @clock.advance(client[:expire])
    assert(wait_until { vrps.zero? }, 'gone at Expire')
    assert(@sp.events.since.any? { |e| e.kind == :rpki && e.data[:event] == 'expired' })
  end

  # Section 8.3: after a Cache Reset, a Reset Query.
  def test_rtr_cache_reset
    n = @cache.events.seq
    @cache.act('behaviour', 'name' => 'rtr_cache_reset')
    assert(wait_until { events('cache_reset', n).any? }, 'Cache Reset sent')
    assert(wait_until { answers(n).any? { |e| e.message.include?('reset query') } }, 'a Reset Query')
    assert_equal(2, vrps)
  end
end
