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
require 'net/http'
require 'json'
require 'bgp/rtr/server'

# bgp4r-rtr over loopback: a router's session, the node file changed
# under it, the HTTP API, and a fault ending the session.
# docs/design/bgp-operations.md 7b.
class TestRtrCacheServer < Test::Unit::TestCase
  include BGP::Rtr

  def setup
    @dir = Dir.mktmpdir('rtr')
    @file = File.join(@dir, 'rtr.yml')
    write_vrps([['192.0.2.0/24', 65_001]])
    @server = Server.new(@log = StringIO.new, @err = StringIO.new)
    assert_equal(0, @server.start([@file, '--listen', '127.0.0.1:0', '--api', '127.0.0.1:0'], wait: false), @err.string)
    assert_equal(0.1, @server.watch)
  end

  def teardown
    @router&.close
    @server&.stop
    FileUtils.rm_rf(@dir)
  end

  def write_vrps(list)
    vrps = list.collect { |p, asn| "  - { prefix: #{p}, asn: #{asn} }" }.join("\n")
    File.write(@file, "session_id: 77\nnotify_every: 0\nwatch: 0.1\nvrps:\n#{vrps}\n")
  end

  def connect
    @router = TCPSocket.new('127.0.0.1', @server.cache.port)
    @buffer = ''.b
  end

  # The PDUs read until the last one is a `last`, or nil at the end of
  # the connection.
  def read_until(last, timeout = 5)
    got = []
    deadline = Time.now + timeout
    loop do
      list, @buffer = BGP::Rtr.pdus(@buffer)
      got.concat(list)
      return got if got.last.is_a?(last)
      left = deadline - Time.now
      flunk("no #{last} in #{timeout} s: #{got.collect(&:class)}") if left <= 0
      next unless @router.wait_readable(left)
      @buffer << @router.readpartial(4096)
    end
  rescue EOFError
    got.empty? ? nil : got
  end

  def post(path, body, header = true)
    uri = URI("#{@server.http.url}#{path}")
    req = Net::HTTP::Post.new(uri)
    req['X-BGP4R'] = 'routescope' if header
    req.body = JSON.generate(body)
    res = Net::HTTP.start(uri.host, uri.port) { |h| h.request(req) }
    [res.code.to_i, JSON.parse(res.body)]
  end

  def test_a_router_follows_the_file
    connect
    @router.write(Reset_query.new.encode)
    got = read_until(End_of_data)
    assert_equal([77, 1, ['192.0.2.0', 24, 24, 65_001]], [got.first.session_id, got.last.serial, got[1].key])
    write_vrps([['192.0.2.0/24', 65_001], ['198.51.100.0/24', 65_002]])
    File.utime(Time.now + 5, Time.now + 5, @file)
    notify = read_until(Serial_notify)
    assert_equal([77, 2], [notify.last.session_id, notify.last.serial], 'a Serial Notify after the file changed')
    @router.write(Serial_query.new(77, 1).encode)
    got = read_until(End_of_data)
    assert_equal([Cache_response, Ipv4_prefix, End_of_data], got.collect(&:class))
    assert_equal('198.51.100.0/24', got[1].prefix)
    status, = post('/api/vrps', { 'withdraw' => [{ 'prefix' => '192.0.2.0/24', 'asn' => 65_001 }] })
    assert_equal(200, status)
    assert_equal(3, read_until(Serial_notify).last.serial, 'and after the API changed it')
    assert_equal(1, JSON.parse(Net::HTTP.get(URI("#{@server.http.url}/api/routers")))['routers'].size)
  end

  # A file that no longer reads keeps the table, and says so.
  def test_a_broken_file_keeps_the_table
    File.write(@file, "vrps:\n  - { prefix: nonsense, asn: 1 }\n")
    File.utime(Time.now + 5, Time.now + 5, @file)
    deadline = Time.now + 5
    sleep 0.1 until @log.string.include?('the VRPs are as they were') || Time.now > deadline
    assert_match(/nonsense.*the VRPs are as they were/, @log.string)
    assert_equal(1, @server.cache.vrp_keys.size)
  end

  # A fault from the API answers the router's next query; the router's
  # Error Report closes the session (section 12, code 5 is fatal).
  def test_a_fault_and_the_routers_answer
    connect
    @router.write(Reset_query.new.encode)
    read_until(End_of_data)
    assert_equal(403, post('/api/fault', { 'name' => 'rtr_unknown_pdu' }, false).first)
    status, body = post('/api/fault', { 'name' => 'rtr_unknown_pdu' })
    assert_equal([200, 'rtr_unknown_pdu'], [status, body['fault']])
    read_until(Serial_notify)
    @router.write(Serial_query.new(77, 1).encode)
    pdu = read_until(Unknown).last
    assert_equal(99, pdu.type)
    @router.write(Error_report.new(5, pdu, 'type 99').encode)
    assert_nil(read_until(End_of_data), 'the cache closes the session')
    kinds = @server.cache.events.since.collect { |e| e.data[:event] }
    assert_equal(%w[fault notify fault_sent error_received closed], kinds.last(5))
  end

  # A Length a router never sends: Corrupt Data, and the session goes
  # without the cache waiting for the octets.
  def test_a_length_too_long
    connect
    @router.write([1, 2, 0, 1 << 20].pack('CCnN'))
    got = read_until(Error_report)
    assert_equal(0, got.last.code)
    assert_nil(read_until(End_of_data))
  end
end
