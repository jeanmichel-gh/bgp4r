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
require 'stringio'
require 'tmpdir'
require 'bgp/rtr/server'

# The RTR cache's answers, driven without a socket, on a manual clock.
# docs/design/bgp-operations.md 7b, RFC 8210 sections 5 to 8 and 12.
class TestRtrCache < Test::Unit::TestCase
  include BGP::Rtr

  # What a session writes, kept.
  class Wire
    attr_reader :written
    def initialize ; @written = [] ; end
    def write(o) ; @written << o ; o.bytesize ; end
    def closed? ; false ; end
    def close ; end
    def pdus ; @written.collect { |o| BGP::Rtr::Pdu.factory(o) } ; end
  end

  A = { 'prefix' => '192.0.2.0/24', 'asn' => 65_001 }.freeze
  B = { 'prefix' => '2001:db8::/32', 'max_length' => 48, 'asn' => 65_002 }.freeze
  C = { 'prefix' => '10.0.0.0/8', 'asn' => 1 }.freeze

  def setup
    @now = 1000.0
    @cache = Cache.new({ 'session_id' => 0x1234, 'vrps' => [A, B] }, :clock => -> { @now })
  end

  def session(version = nil)
    Cache::Session.new('10.0.0.1:1000', Wire.new).tap { |s| s.version = version }
  end

  def ask(s, pdu)
    out, close = @cache.receive(s, pdu.is_a?(Pdu) ? pdu.encode : pdu)
    [out.collect { |o| Pdu.factory(o) }, close]
  end

  def v0(pdu) ; pdu.tap { |p| p.version = 0 } ; end

  # Section 8.1: a Reset Query is answered with a Cache Response, every
  # VRP announced (5.5: "MUST have the value 1"), and an End of Data.
  def test_a_reset_query_gets_the_whole_table
    s = session
    out, close = ask(s, Reset_query.new)
    assert_equal(false, close)
    assert_equal([Cache_response, Ipv4_prefix, Ipv6_prefix, End_of_data], out.collect(&:class).sort_by { |k| k::TYPE })
    assert_equal([0x1234, 1], [out.first.session_id, out.last.serial])
    assert(out[1..-2].all?(&:announce?))
    assert_equal([['192.0.2.0', 24, 24, 65_001], ['2001:db8::', 32, 48, 65_002]].sort, out[1..-2].collect(&:key).sort)
    assert_equal([3600, 600, 7200], [out.last.refresh, out.last.retry, out.last.expire])
    assert_equal([1, 1], [s.version, s.serial])
  end

  # Section 5.3: the minimum set of changes since the serial, a change
  # undone between them not mentioned; withdrawals before announcements.
  def test_a_serial_query_gets_the_merged_changes
    s = session
    ask(s, Reset_query.new)
    @cache.change(announce: [C])                # serial 2
    @cache.change(withdraw: [A])                # serial 3
    @cache.change(withdraw: [C])                # serial 4: C came and went
    out, = ask(s, Serial_query.new(0x1234, 1))
    assert_equal([Cache_response, Ipv4_prefix, End_of_data], out.collect(&:class))
    assert_equal([false, ['192.0.2.0', 24, 24, 65_001]], [out[1].announce?, out[1].key])
    assert_equal(4, out.last.serial)
    @cache.change(announce: [C])
    @cache.change(announce: [A], withdraw: [B])
    out, = ask(s, Serial_query.new(0x1234, 4))
    assert_equal([false, true, true], out[1..-2].collect(&:announce?), 'the withdrawal first')
    out, = ask(s, Serial_query.new(0x1234, 6))
    assert_equal([Cache_response, End_of_data], out.collect(&:class), 'nothing new is a null answer (section 4)')
  end

  # Sections 5.3 and 8.3: a serial not kept is answered with a Cache
  # Reset, one never reached as well as one gone from the history.
  def test_a_serial_not_kept_gets_a_cache_reset
    cache = Cache.new({ 'session_id' => 7, 'history' => 2, 'vrps' => [A] }, :clock => -> { @now })
    s = session(1)
    cache.change(announce: [B])
    cache.change(announce: [C])
    assert_equal([Cache_reset], cache.receive(s, Serial_query.new(7, 1).encode).first.collect { |o| Pdu.factory(o).class })
    assert_equal([Cache_reset], cache.receive(s, Serial_query.new(7, 99).encode).first.collect { |o| Pdu.factory(o).class })
    assert_equal(Cache_response, Pdu.factory(cache.receive(s, Serial_query.new(7, 2).encode).first.first).class)
    assert_equal('cache_reset', cache.events.since.collect { |e| e.data[:event] }.grep('cache_reset').first)
  end

  # Section 5.1: a Session ID that differs is Corrupt Data, and the
  # session goes.
  def test_a_session_id_that_differs_is_corrupt_data
    out, close = ask(session, Serial_query.new(0x9999, 1))
    assert_equal([Error_report], out.collect(&:class))
    assert_equal([0, true], [out.first.code, close])
    assert_match(/Session ID 39321, where this cache's is 4660/, out.first.text)
  end

  # Section 7: a version 0 query downgrades the session; section 5.1: a
  # Session ID of its own; RFC 6810 5.7: a 12-octet End of Data.
  def test_version_0_is_answered_in_version_0
    s = session
    out, = ask(s, v0(Reset_query.new))
    assert_equal([0], out.collect(&:version).uniq)
    assert_equal([0x1235, 12], [out.first.session_id, out.last.encode.bytesize])
    out, = ask(s, v0(Serial_query.new(0x1235, 1)))
    assert_equal([Cache_response, End_of_data], out.collect(&:class))
    out, close = ask(s, Serial_query.new(0x1235, 1))
    assert_equal([8, 0, true], [out.first.code, out.first.version, close], 'version 1 after 0: code 8, in version 0')
  end

  # Section 7: a version neither 0 nor 1 is answered with code 4 and the
  # connection ends; the report is in version 1, the one this cache has.
  def test_an_unknown_version_is_refused
    s = session
    out, close = ask(s, Reset_query.new.tap { |p| p.version = 9 })
    assert_equal([4, 1, true, nil], [out.first.code, out.first.version, close, s.version])
  end

  # Section 7: a router starts with a query, and sends only queries; a
  # type not known is code 5, a cache's PDU code 3.
  def test_what_a_router_does_not_send
    out, close = ask(session, Unknown.new(99))
    assert_equal([5, true], [out.first.code, close])
    out, close = ask(session, Ipv4_prefix.new('10.0.0.0/8', 8, 1))
    assert_equal([3, true], [out.first.code, close])
    assert_match(/not PDU type 4/, out.first.text)
    out, = ask(session, Ipv4_prefix.new('10.0.0.0/24', 16, 1))
    assert_equal(0, out.first.code, 'a finding of Rtr::Validation comes first')
  end

  # Section 5.11: no Error Report for an Error Report; a fatal one, or
  # one that is itself wrong, drops the session.
  def test_an_error_report_from_the_router
    assert_equal([[], true], ask(session(1), Error_report.new(6, '', 'never announced')))
    assert_equal([[], false], ask(session(1), Error_report.new(2)))
    bad = Error_report.new(2).encode
    bad = bad.byteslice(0, 8) + [99].pack('N') + bad.byteslice(12..)
    assert_equal([[], true], ask(session(1), bad), 'an Error Report whose inner Length overruns')
    e = @cache.events.since.collect(&:data).find { |d| d[:event] == 'error_received' }
    assert_equal([6, 'Withdrawal of Unknown Record', 'never announced', true], e.values_at(:code, :name, :text, :fatal))
  end

  # Section 8.2: a Serial Notify to every router when the serial
  # changes, no more than one a minute; one sent to no router does not
  # count.
  def test_serial_notify_is_held_to_one_a_minute
    @cache.tick
    s = session
    @cache.instance_variable_get(:@sessions) << s
    ask(s, Reset_query.new)
    @cache.change(announce: [C])
    @cache.tick
    assert_equal([Serial_notify], s.socket.pdus.collect(&:class), 'the first change: at once')
    assert_equal([0x1234, 2], [s.socket.pdus.last.session_id, s.socket.pdus.last.serial])
    @cache.change(withdraw: [C])
    @now += 59
    @cache.tick
    assert_equal(1, s.socket.written.size, 'held under a minute')
    @now += 1
    @cache.tick
    assert_equal([2, 3], [s.socket.written.size, s.socket.pdus.last.serial])
    @now += 100
    @cache.tick
    assert_equal(2, s.socket.written.size, 'nothing changed, nothing sent')
  end

  # A change while no router is there sends nothing, and does not hold
  # back the notify of the next change.
  def test_a_notify_to_nobody_does_not_count
    @cache.change(announce: [C])
    @cache.tick
    s = session(1)
    @cache.instance_variable_get(:@sessions) << s
    @now += 1
    @cache.change(withdraw: [C])
    @cache.tick
    assert_equal([Serial_notify], s.socket.pdus.collect(&:class))
  end

  # Section 7: "Caches SHOULD NOT send Serial Notify PDUs before version
  # negotiation completes."
  def test_no_notify_before_a_version_is_agreed
    s = session
    @cache.instance_variable_get(:@sessions) << s
    @cache.change(announce: [C])
    @cache.tick
    assert_equal([], s.socket.written)
  end

  # Section 8.4: No Data Available, code 2, is not fatal; the behaviour
  # ends at its time, or at away 0.
  def test_rtr_no_data
    s = session
    assert_equal({ :behaviour => 'rtr_no_data', :away => 30.0 }, @cache.behaviour('name' => 'rtr_no_data', 'away' => 30))
    out, close = ask(s, Reset_query.new)
    assert_equal([[Error_report], 2, false], [out.collect(&:class), out.first.code, close])
    assert_equal(Reset_query.new.encode, out.first.pdu, 'the query it answers, encapsulated')
    assert_equal('rtr_no_data', @cache.status[:behaviour])
    @now += 30
    out, = ask(s, Reset_query.new)
    assert_equal(Cache_response, out.first.class, 'at its time it is over')
    @cache.behaviour('name' => 'rtr_no_data')
    @now += Cache::AWAY - 1
    assert_equal(Error_report, ask(s, Reset_query.new).first.first.class, "AWAY when away isn't given")
    @cache.behaviour('name' => 'rtr_no_data', 'away' => 0)
    assert_equal(Cache_response, ask(s, Reset_query.new).first.first.class, 'away 0 ends it')
  end

  # Section 6: a silent cache answers nothing and sends no Serial Notify;
  # the notify waits for it to end.
  def test_rtr_silent
    s = session
    @cache.instance_variable_get(:@sessions) << s
    ask(s, Reset_query.new)
    @cache.behaviour('name' => 'rtr_silent', 'away' => 10)
    assert_equal([[], false], ask(s, Serial_query.new(0x1234, 1)))
    @cache.change(announce: [C])
    @cache.tick
    assert_equal([], s.socket.written)
    @now += 10
    @cache.tick
    assert_equal([Serial_notify], s.socket.pdus.collect(&:class))
    assert_includes(@cache.events.since.collect { |e| e.data[:event] }, 'behaviour_end')
  end

  # Section 8.3: the next Serial Query gets a Cache Reset; a Serial
  # Notify brings it on; after it, answers are as before.
  def test_rtr_cache_reset
    s = session
    @cache.instance_variable_get(:@sessions) << s
    ask(s, Reset_query.new)
    r = @cache.behaviour('name' => 'rtr_cache_reset')
    assert_equal(['10.0.0.1:1000'], r[:routers])
    assert_equal([Serial_notify], s.socket.pdus.collect(&:class))
    assert_equal([Cache_reset], ask(s, Serial_query.new(0x1234, 1)).first.collect(&:class))
    assert_equal(Cache_response, ask(s, Serial_query.new(0x1234, 1)).first.first.class, 'once')
    @cache.behaviour('name' => 'rtr_cache_reset')
    assert_equal(Cache_response, ask(s, Reset_query.new).first.first.class)
    assert_equal(Cache_response, ask(s, Serial_query.new(0x1234, 1)).first.first.class, 'a Reset Query clears it')
  end

  # BGP::Fault::RTR to the routers that agreed version 1, as the answer
  # to their next query, with a Serial Notify to bring it on.
  def test_a_fault_answers_the_next_query
    assert_raise(Refused) { @cache.fault('name' => 'rtr_unknown_pdu') }
    s = session
    @cache.instance_variable_get(:@sessions) << s << session(0)
    ask(s, Reset_query.new)
    assert_equal({ :fault => 'rtr_duplicate_announce', :routers => ['10.0.0.1:1000'] },
                 @cache.fault('name' => 'rtr_duplicate_announce'))
    assert_equal([Serial_notify], s.socket.pdus.collect(&:class))
    assert_equal(:rtr_duplicate_announce, s.to_h[:fault])
    out, close = @cache.receive(s, Serial_query.new(0x1234, 1).encode)
    assert_equal([BGP::Fault.rtr(:rtr_duplicate_announce, 0x1234), false], [out, close])
    assert_equal([Cache_response, End_of_data], ask(s, Serial_query.new(0x1234, 1)).first.collect(&:class), 'once')
    assert_raise(Refused) { @cache.fault('name' => 'rtr_unknown_pdu', 'router' => '10.9.9.9:1') }
    assert_equal(['10.0.0.1:1000'], @cache.fault('name' => 'rtr_unknown_pdu', 'router' => '10.0.0.1:1000')[:routers])
    assert_raise(Refused) { @cache.fault('name' => 'nope') }
    assert_raise(Refused) { @cache.fault({}) }
    assert_raise(Refused) { @cache.behaviour('name' => 'nope') }
    assert_raise(Refused) { @cache.behaviour({}) }
  end

  # No router has the table at the start, so none is told of it.
  def test_no_notify_for_the_table_at_the_start
    s = session(1)
    @cache.instance_variable_get(:@sessions) << s
    @cache.tick
    assert_equal([], s.socket.written)
  end

  def test_the_table
    assert_equal({ :serial => 1, :announced => 0, :withdrawn => 0 }, @cache.load([B, A]), 'the same table is no new serial')
    assert_equal({ :serial => 2, :announced => 1, :withdrawn => 2 }, @cache.load([C]))
    assert_equal(['10.0.0.0', 8, 8, 1], Cache.vrp('prefix' => '10.1.2.3/8', 'asn' => 1), 'the host bits go')
    assert_equal(['2001:db8::', 32, 32, 2], Cache.vrp(:prefix => '2001:db8::/32', :asn => 2))
    [{ 'prefix' => '10.0.0.0/8' }, { 'asn' => 1 }, { 'prefix' => '10.0.0.0/33', 'asn' => 1 },
     { 'prefix' => '10.0.0.0/24', 'max_length' => 16, 'asn' => 1 }, { 'prefix' => '10.0.0.0/24', 'max_length' => 33, 'asn' => 1 },
     { 'prefix' => '10.0.0.0/8', 'asn' => 1 << 32 }, { 'prefix' => 'ten/8', 'asn' => 1 },
     { 'prefix' => '10.0.0.0/8', 'asn' => 1, 'maxlen' => 9 }].each do |bad|
      assert_raise(Refused, bad.inspect) { Cache.vrp(bad) }
    end
    @cache.instance_variable_set(:@serial, 0xffff_ffff)
    assert_equal(0, @cache.load([A])[:serial], 'RFC 1982: the serial wraps')
  end

  def test_the_node_file
    assert_raise(Refused) { Cache.new('vrp' => []) }
    w = Cache.new('refresh' => 0, 'retry' => 7201, 'expire' => 100, 'notify_every' => 1).timing_warnings
    assert_equal(5, w.size, w.inspect)
    assert_equal([], Cache.new.timing_warnings)
    assert_equal([0x1234, 0x1235], [@cache.session_id_for(1), @cache.session_id_for(0)])
    assert_equal(0, Cache.new('session_id' => 0xffff).session_id_for(0), 'the v0 Session ID wraps')
    assert_equal(0x1234, Cache.new('session_id' => 0x1_1234).session_id, '16 bits')
    assert_includes(0..0xffff, Cache.new.session_id)
  end

  def test_the_router_names
    assert_equal('10.0.0.1:179', Cache.router_name(Addrinfo.tcp('10.0.0.1', 179)))
    assert_equal('10.0.0.1:179', Cache.router_name(Addrinfo.tcp('::ffff:10.0.0.1', 179)))
    assert_equal('[2001:db8::1]:179', Cache.router_name(Addrinfo.tcp('2001:db8::1', 179)))
  end

  # The HTTP API: bgp4r-sim's server with the cache's paths.
  def test_the_http_api
    http = Http.new(@cache, @cache)
    header = { 'x-bgp4r' => 'routescope' }
    status, body = http.handle('GET', '/api/vrps')
    assert_equal([200, 1, 2], [status, body[:serial], body[:vrps].size])
    assert_equal({ :prefix => '192.0.2.0/24', :max_length => 24, :asn => 65_001 }, body[:vrps].first)
    assert_equal(403, http.handle('POST', '/api/vrps', {}, '{"vrps":[]}').first)
    assert_equal([200, { :serial => 2, :announced => 1, :withdrawn => 0 }],
                 http.handle('POST', '/api/vrps', header, '{"announce":[{"prefix":"10.0.0.0/8","asn":1}]}'))
    assert_equal([200, { :serial => 3, :announced => 0, :withdrawn => 3 }], http.handle('POST', '/api/vrps', header, '{"vrps":[]}'))
    assert_equal(400, http.handle('POST', '/api/vrps', header, '{"add":[]}').first)
    assert_equal(400, http.handle('POST', '/api/fault', header, '{"name":"rtr_unknown_pdu"}').first)
    assert_equal(403, http.handle('POST', '/api/fault', {}, '{"name":"rtr_unknown_pdu"}').first)
    assert_equal(200, http.handle('POST', '/api/behaviour', header, '{"name":"rtr_silent"}').first)
    assert_equal(405, http.handle('GET', '/api/fault').first)
    assert_equal(404, http.handle('GET', '/api/peers').first)
    assert_equal([200, 0], http.handle('GET', '/api/routers').then { |st, b| [st, b[:routers].size] })
    assert_equal(4660, http.handle('GET', '/api/status').last[:session_id])
    st, b = http.handle('GET', '/api/events?since=2')
    assert_equal([200, [3, 4]], [st, b[:events].collect { |e| e[:seq] }])
    assert_equal(400, http.handle('GET', '/api/events?since=soon').first)
    assert_equal(%w[/api/behaviour /api/fault /api/vrps], http.handle('GET', '/api').last[:actions].keys)
    assert_equal(404, http.handle('POST', '/api/announce', header, '{}').first, "bgp4r-sim's paths are not the cache's")
  end

  # An empty node file is a cache with no VRPs. The file is read again
  # only when its time changes.
  def test_the_node_file_on_disk
    Dir.mktmpdir do |dir|
      file = File.join(dir, 'rtr.yml')
      File.write(file, '')
      server = Server.new(StringIO.new, StringIO.new)
      assert_equal({}, server.load_config(file))
      File.write(file, "vrps:\n  - { prefix: 10.0.0.0/8, asn: 1 }\n")
      assert(server.build(server.load_config(file), :config => file, :listen => '127.0.0.1:0', :api => '127.0.0.1:0'))
      begin
        assert_equal(1.0, server.watch)
        mtime = File.mtime(file)
        File.write(file, "vrps: []\n")
        File.utime(mtime, mtime, file)
        server.reread
        assert_equal(1, server.cache.vrp_keys.size, 'the same time: not read')
        File.utime(mtime + 5, mtime + 5, file)
        server.reread
        assert_equal(0, server.cache.vrp_keys.size)
      ensure
        server.stop
      end
    end
  end

  def test_the_command_line
    out, err = StringIO.new, StringIO.new
    assert_equal(1, Server.new(out, err).start([]))
    assert_match(/Usage: bgp4r-rtr FILE/, err.string)
    assert_equal(0, Server.new(out, err).start(['-h']))
    assert_equal(1, Server.new(out, err).start(%w[a b]))
    assert_match(/unknown argument "b"/, err.string)
    assert_equal(1, Server.new(out, err).start(['/no/such/file']))
    assert_match(/no such file/, err.string)
    assert_equal({ :bind => '0.0.0.0', :port => 323 }, Server.listen_address('323'))
    assert_equal({ :bind => '::', :port => 323 }, Server.listen_address('[::]:323'))
  end
end
