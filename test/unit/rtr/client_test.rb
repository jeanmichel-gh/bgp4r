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
require 'bgp/rtr/client'
require 'bgp/rtr/cache'

# The router's side of RTR against RFC 8210, on a manual clock, with no
# socket: by hand, and against Rtr::Cache in memory.
# docs/design/bgp-operations.md 7c.
class TestRtrClient < Test::Unit::TestCase
  include BGP::Rtr

  A = { 'prefix' => '192.0.2.0/24', 'asn' => 65_001 }.freeze
  B = { 'prefix' => '2001:db8::/32', 'max_length' => 48, 'asn' => 65_002 }.freeze
  C = { 'prefix' => '10.0.0.0/8', 'asn' => 1 }.freeze

  # A cache's session, kept in memory.
  class Wire
    def write(o) ; o.bytesize ; end
    def closed? ; false ; end
    def close ; end
  end

  def setup
    @now = 0.0
    @changes = 0
    @events = []
    @client = Client.new({ 'address' => '127.0.0.1', 'port' => 3323 }, :clock => -> { @now },
                         :events => ->(what, _msg, data) { @events << [what, data] })
    @client.on_change { @changes += 1 }
    @cache = Cache.new({ 'session_id' => 7, 'refresh' => 30, 'retry' => 10, 'expire' => 600, 'vrps' => [A, B] },
                       :clock => -> { @now })
    @session = Cache::Session.new('127.0.0.1:1', Wire.new)
  end

  # What the client sends goes to the cache, and what the cache answers
  # comes back, until neither has more. Returns whether either closed.
  def converse(octets)
    queue = Array(octets)
    until queue.empty?
      back, close = @cache.receive(@session, queue.shift)
      return :cache_closed if close
      back.each do |o|
        out, shut = @client.receive(o, @now)
        queue.concat(out)
        return :client_closed if shut
      end
    end
    nil
  end

  def pdus(list) ; list.collect { |o| Pdu.factory(o) } ; end

  # Section 8.1: a Reset Query, the whole table, the timers of section 6
  # from the End of Data.
  def test_a_reset_query_loads_the_table
    out = @client.connected(@now)
    assert_equal([Reset_query], pdus(out).collect(&:class))
    assert_nil(converse(out))
    assert_equal([['192.0.2.0', 24, 24, 65_001], ['2001:db8::', 32, 48, 65_002]], @client.vrps.to_a.sort)
    h = @client.to_h
    assert_equal(['up', 1, 7, 1, 1, 1, 30, 10, 600], h.values_at(:state, :version, :session_id, :serial, :vrps_v4, :vrps_v6, :refresh, :retry, :expire))
    assert_equal(1, @changes)
    assert(@client.synced?)
    assert_equal(%w[connected up synced], @events.collect(&:first))
  end

  # Section 6: a Serial Query at the Refresh Interval, the changes since,
  # and the data dropped at the Expire Interval with no answer.
  def test_refresh_and_expire
    converse(@client.connected(@now))
    @cache.change(announce: [C], withdraw: [A])
    @now += 29
    assert_equal([], @client.tick(@now))
    @now += 1
    q = @client.tick(@now)
    assert_equal([[Serial_query], 7, 1], [pdus(q).collect(&:class), pdus(q).first.session_id, pdus(q).first.serial])
    converse(q)
    assert_equal([['10.0.0.0', 8, 8, 1], ['2001:db8::', 32, 48, 65_002]], @client.vrps.to_a.sort)
    assert_equal([2, 2], [@client.serial, @changes])
    @client.closed('gone', @now)
    assert_equal('down', @client.to_h[:state])
    assert_equal(2, @client.vrps.size, 'kept while down (section 6)')
    @now += 599
    @client.tick(@now)
    assert_equal(2, @client.vrps.size)
    @now += 1
    @client.tick(@now)
    assert_equal([0, 3, false], [@client.vrps.size, @changes, @client.synced?], 'gone at Expire')
    assert_includes(@events.collect(&:first), 'expired')
    assert_equal([Reset_query], pdus(@client.connected(@now)).collect(&:class), 'nothing left: a Reset Query')
  end

  # Section 8.1: back with data unexpired, a Serial Query from the serial.
  def test_back_with_data_asks_from_the_serial
    converse(@client.connected(@now))
    @client.closed('gone', @now)
    assert_equal(@now + 10, @client.connect_at, 'the Retry Interval')
    q = pdus(@client.connected(@now))
    assert_equal([Serial_query, 1], [q.first.class, q.first.serial])
  end

  # Section 8.2: a Serial Notify brings a Serial Query at once; one before
  # negotiation is ignored (section 7).
  def test_serial_notify
    assert_equal([[], false], @client.receive(Serial_notify.new(7, 9).encode, @now))
    converse(@client.connected(@now))
    out, = @client.receive(Serial_notify.new(7, 2).encode, @now)
    assert_equal([Serial_query], pdus(out).collect(&:class))
    out, = @client.receive(Serial_notify.new(99, 2).encode, @now)
    assert_equal([], out, 'another Session ID: not this cache')
  end

  # Section 8.3: a Cache Reset, then a Reset Query.
  def test_a_cache_reset
    converse(@client.connected(@now))
    out, close = @client.receive(Cache_reset.new.encode, @now)
    assert_equal([[Reset_query], false], [pdus(out).collect(&:class), close])
  end

  # Section 8.4: No Data Available keeps the session and the data, and
  # asks again at the Retry Interval.
  def test_no_data_available
    converse(@client.connected(@now))
    @now += 30
    q = @client.tick(@now)
    @cache.behaviour('name' => 'rtr_no_data', 'away' => 100)
    assert_nil(converse(q))
    assert_equal(2, @client.vrps.size)
    assert_match(/No Data Available \(2\)/, @client.to_h[:last_error])
    @now += 9
    assert_equal([], @client.tick(@now))
    @now += 1
    assert_equal([Serial_query], pdus(@client.tick(@now)).collect(&:class))
  end

  # Section 7: a version 0 cache. A version 0 answer downgrades; a
  # version 0 Error Report 4 reconnects in version 0 at once.
  def test_a_version_0_cache
    out = @client.connected(@now)
    v0 = ->(p) { p.tap { |x| x.version = 0 }.encode }
    assert_equal([[], false], @client.receive(v0.(Cache_response.new(5)), @now))
    @client.receive(v0.(Ipv4_prefix.new('10.0.0.0/8', 8, 1)), @now)
    @client.receive(v0.(End_of_data.new(5, 3)), @now)
    assert_equal([0, 3, 1, 3600], @client.to_h.values_at(:version, :serial, :vrps_v4, :refresh), 'no intervals in version 0')
    assert(out)
    other = Client.new({ 'address' => '127.0.0.1' }, :clock => -> { @now })
    other.connected(@now)
    assert_equal([[], true], other.receive(Error_report.new(4).tap { |p| p.version = 0 }.encode, @now))
    assert_equal([0, @now], [pdus(other.connected(@now)).first.version, other.connect_at])
  end

  # Section 12: the router's Error Reports, each fatal.
  def test_what_the_router_refuses
    cases = {
      :rtr_unknown_pdu => 5, :rtr_bad_version => 8, :rtr_unexpected_version => 8,
      :rtr_withdraw_unknown => 6, :rtr_duplicate_announce => 7, :rtr_corrupt_length => 0,
    }
    cases.each do |name, code|
      c = Client.new({ 'address' => '127.0.0.1' }, :clock => -> { @now })
      @session = Cache::Session.new('127.0.0.1:1', Wire.new)
      converse(c.connected(@now).tap { @client = c })
      got = nil
      BGP::Fault.rtr(name, 7).each do |o|
        out, close = c.receive(o, @now)
        next if out.empty?
        got = [Pdu.factory(out.first).code, close]
        break
      end
      assert_equal([code, true], got, name.to_s)
      assert_equal(2, c.vrps.size, "#{name}: the data is kept until Expire")
    end
  end

  # Section 5.1: another Session ID answering a Serial Query is Corrupt
  # Data, and the data from that cache goes.
  def test_a_session_id_that_changed
    converse(@client.connected(@now))
    @client.receive(Serial_notify.new(7, 1).encode, @now)
    out, close = @client.receive(Cache_response.new(8).encode, @now)
    assert_equal([0, true], [Pdu.factory(out.first).code, close])
    assert_equal([0, false, 2], [@client.vrps.size, @client.synced?, @changes])
  end

  # Section 5.1: a cache that restarted answers the Serial Query with
  # Corrupt Data; the router flushes and asks with a Reset Query next.
  # Code 0 for a Reset Query flushes nothing.
  def test_corrupt_data_for_a_serial_query
    converse(@client.connected(@now))
    @client.receive(Serial_notify.new(7, 1).encode, @now)
    assert_equal([[], true], @client.receive(Error_report.new(0, '', 'Session ID').encode, @now))
    assert_equal([0, false, 2], [@client.vrps.size, @client.synced?, @changes])
    assert_equal([Reset_query], pdus(@client.connected(@now)).collect(&:class))
    @client.receive(Error_report.new(0).encode, @now)
    assert_equal(2, @changes, 'after a Reset Query there is nothing to flush')
  end

  def test_what_comes_outside_an_answer
    converse(@client.connected(@now))
    [Ipv4_prefix.new('10.0.0.0/8', 8, 1), End_of_data.new(7, 1), Serial_query.new(7, 1)].each do |p|
      out, close = @client.receive(p.encode, @now)
      assert_equal([0, true], [Pdu.factory(out.first).code, close], p.class.name)
    end
    @client.receive(Serial_notify.new(7, 1).encode, @now)
    @client.receive(Cache_response.new(7).encode, @now)
    out, = @client.receive(Cache_response.new(7).encode, @now)
    assert_equal(0, Pdu.factory(out.first).code, 'a Cache Response inside an answer')
    @client.receive(Serial_notify.new(7, 1).encode, @now)
    @client.receive(Cache_response.new(7).encode, @now)
    out, = @client.receive(End_of_data.new(8, 2).encode, @now)
    assert_equal(0, Pdu.factory(out.first).code, "an End of Data with another Session ID than its answer's")
  end

  # Within one answer: an announcement then its withdrawal leaves nothing;
  # a withdrawal then the announcement is a change of nothing.
  def test_changes_within_one_answer
    converse(@client.connected(@now))
    @client.receive(Serial_notify.new(7, 1).encode, @now)
    v = Ipv4_prefix.new('10.0.0.0/8', 8, 1)
    a = Ipv4_prefix.new('192.0.2.0/24', 24, 65_001)
    [Cache_response.new(7), v, Ipv4_prefix.new('10.0.0.0/8', 8, 1, false),
     Ipv4_prefix.new('192.0.2.0/24', 24, 65_001, false), a, End_of_data.new(7, 2)].each do |p|
      assert_equal([[], false], @client.receive(p.encode, @now), p.to_s)
    end
    assert_equal(2, @client.vrps.size)
    assert_equal(1, @changes, 'nothing changed')
  end

  # No Data Available for the first Reset Query: at the Retry Interval,
  # a Reset Query again, since there is no serial to ask from.
  def test_no_data_before_any_data
    @cache.behaviour('name' => 'rtr_no_data', 'away' => 100)
    converse(@client.connected(@now))
    @now += 600
    assert_equal([Reset_query], pdus(@client.tick(@now)).collect(&:class))
  end

  # The Refresh Interval while an answer is still coming asks nothing:
  # here a Cache Response the cache sent unasked, a second before it.
  def test_no_query_inside_an_answer
    converse(@client.connected(@now))
    @now += 29
    @client.receive(Cache_response.new(7).encode, @now)
    @now += 1
    assert_equal([], @client.tick(@now))
  end

  # Section 7: a Serial Notify while the version is not agreed is
  # ignored, even with this cache's Session ID.
  def test_notify_while_negotiating
    converse(@client.connected(@now))
    @client.closed('gone', @now)
    @client.connected(@now)
    assert_nil(@client.to_h[:version], 'not agreed again yet')
    assert_equal([[], false], @client.receive(Serial_notify.new(7, 2).encode, @now))
  end

  # Router Keys are BGPsec's: read past, not refused.
  def test_a_router_key_is_read_past
    converse(@client.connected(@now))
    @client.receive(Serial_notify.new(7, 1).encode, @now)
    @client.receive(Cache_response.new(7).encode, @now)
    assert_equal([[], false], @client.receive(Router_key.new("\x11" * 20, 1, "\x30\x00").encode, @now))
  end

  # Section 5.5: a Reset Query's answer is the whole table; what it does
  # not name goes. Corrupt Data then flushes nothing.
  def test_a_reset_answer_replaces_the_table
    converse(@client.connected(@now))
    @cache.change(withdraw: [A])
    out, = @client.receive(Cache_reset.new.encode, @now)
    converse(out)
    assert_equal([['2001:db8::', 32, 48, 65_002]], @client.vrps.to_a)
    @client.receive(Cache_reset.new.encode, @now)
    @client.receive(Error_report.new(0).encode, @now)
    assert_equal(1, @client.vrps.size, 'Corrupt Data for a Reset Query flushes nothing')
  end

  def test_the_cache_entry
    assert_raise(ArgumentError) { Client.check('port' => 1) }
    assert_raise_message('rpki: a cache needs an address') { Client.check('port' => 1) }
    assert_raise(ArgumentError) { Client.check('address' => 'nope') }
    assert_raise(ArgumentError) { Client.check('address' => '10.0.0.1', 'port' => 0) }
    assert_raise(ArgumentError) { Client.check('address' => '10.0.0.1', 'retry' => 0) }
    assert_raise(ArgumentError) { Client.check('address' => '10.0.0.1', 'prefer' => 1) }
    assert_raise(ArgumentError) { Client.check(['10.0.0.1']) }
    c = Client.new('address' => '2001:db8::9', 'retry' => 5, 'preference' => 3)
    assert_equal(['[2001:db8::9]:323', 3, 5, 'idle'], [c.name, c.preference, c.retry, c.state])
  end
end
