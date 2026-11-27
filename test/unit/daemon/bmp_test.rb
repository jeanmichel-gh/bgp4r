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
require 'bgp/daemon/api'

# bgp4rd's bmp: key, without a socket: what it refuses, the backoff, the
# per-peer flags and each Peer Down reason. docs/design/bgp-operations.md 8c.
class TestDaemonBmp < Test::Unit::TestCase
  M = BGP::Daemon::BmpMonitor

  def ok ; { 'stations' => [{ 'address' => '127.0.0.1', 'port' => 5000 }] } ; end

  def refused(config, pattern)
    e = assert_raise(ArgumentError) { M.check(config) }
    assert_match(pattern, e.message)
  end

  def test_what_it_refuses
    assert_equal(ok, M.check(ok))
    refused([], /a mapping/)
    refused(ok.merge('bogus' => 1), /unknown key\(s\) bogus/)
    refused({}, /at least one station/)
    refused({ 'stations' => [] }, /at least one station/)
    refused({ 'stations' => ['x'] }, /a station is a mapping/)
    refused({ 'stations' => [{ 'address' => '127.0.0.1', 'host' => 'x' }] }, /not host/)
    refused({ 'stations' => [{ 'port' => 5000 }] }, /needs an address/)
    refused({ 'stations' => [{ 'address' => 'nowhere' }] }, /\Abmp: /)
    refused({ 'stations' => [{ 'address' => '127.0.0.1', 'port' => 0 }] }, /port 0 is not 1 to 65535/)
    refused({ 'stations' => [{ 'address' => '127.0.0.1', 'retry' => 'soon' }] }, /\Abmp: /)
    refused({ 'stations' => [{ 'address' => '127.0.0.1' }, { 'address' => '127.0.0.1', 'port' => 5000 }] }, /listed twice/)
    refused(ok.merge('monitor' => %w[pre_policy loc_rib]), /monitor loc_rib: this bgp4rd monitors pre_policy only/)
    refused(ok.merge('stats_interval' => 0), /stats_interval 0.0 is not positive/)
  end

  def test_a_bad_key_stops_bgp4rd_at_start
    e = assert_raise(ArgumentError) do
      BGP::Daemon::Speaker.new('as' => 65_000, 'router_id' => '10.0.0.3', 'bmp' => { 'stations' => [] }, 'neighbors' => [])
    end
    assert_match(/bmp: stations/, e.message)
  end

  # Section 3.2: 30 s doubling to 720 s, or from the station's retry.
  def test_the_backoff
    s = M::Station.new('address' => '127.0.0.1')
    assert_equal([30, 60, 120, 240, 480, 720, 720], (1..7).collect { |n| s.backoff(n) })
    assert_equal([0.5, 1.0], [1, 2].collect { |n| M::Station.new('address' => '::1', 'retry' => 0.5).backoff(n) })
    assert_equal('127.0.0.1:5000', s.name)
    assert_equal('[2001:db8::1]:5001', M::Station.new('address' => '2001:db8::1', 'port' => 5001).name)
    assert_equal({ :station => '127.0.0.1:5000', :state => 'connecting', :sessions => 0, :messages => 0,
                   :connected_at => nil, :last_error => nil }, s.to_h)
  end

  Info = Struct.new(:four) do
    def as4byte? ; four ; end
  end

  def monitor
    speaker = BGP::Daemon::Speaker.new('as' => 65_000, 'router_id' => '10.0.0.3', 'neighbors' => [], 'bmp' => ok)
    speaker.bmp
  end

  # Section 4.2: V for an IPv6 peer, A for a two-octet AS_PATH.
  def test_the_flags
    m = monitor
    assert_equal(0, m.send(:flags_for, '192.0.2.1', Info.new(true)))
    assert_equal(BGP::Bmp::FLAG_V, m.send(:flags_for, '2001:db8::1', Info.new(true)))
    assert_equal(BGP::Bmp::FLAG_A, m.send(:flags_for, '192.0.2.1', Info.new(false)))
  end

  Neighbor = Struct.new(:down_cause)

  # Section 4.9's reasons, from what the session saw.
  def test_each_peer_down_reason
    m = monitor
    peer = ->(cause, n = nil, sent = false) do
      M::Peer.new('192.0.2.1', Neighbor.new(cause)).tap { |p| p.notification, p.notification_sent = n, sent }
    end
    cease = BGP::Notification.new(6, 4)
    assert_equal([1, cease], m.send(:down_reason, peer.(:notification, cease, true)))
    assert_equal([3, cease], m.send(:down_reason, peer.(:notification, cease)))
    assert_equal([4, nil], m.send(:down_reason, peer.(:tcp)))
    assert_equal([2, 10], m.send(:down_reason, peer.(:hold_time)), 'HoldTimer_Expires, RFC 4271 section 8.1.3')
    assert_equal([2, 2], m.send(:down_reason, peer.(nil)), 'ManualStop, RFC 4271 section 8.1.2')
  end

  def test_the_initiation
    m = BGP::Daemon::BmpMonitor.new(nil, ok.merge('sys_name' => 'r1', 'sys_descr' => 'lab'))
    assert_equal(['lab', 'r1'], m.send(:initiation).then { |i| [i.sys_descr, i.sys_name] })
    m = BGP::Daemon::BmpMonitor.new(nil, ok)
    assert_equal(["bgp4r #{BGP::VERSION}", Socket.gethostname], m.send(:initiation).then { |i| [i.sys_descr, i.sys_name] })
    assert_equal(60.0, m.stats_interval)
    assert_equal(0, m.send(:termination).reason, 'Session administratively closed')
  end

  T0 = Time.utc(2026, 11, 27, 10, 0, 0, 250)

  def with_clock(arg = {})
    speaker = BGP::Daemon::Speaker.new('as' => 65_000, 'router_id' => '10.0.0.3', 'neighbors' => [])
    [speaker, BGP::Daemon::BmpMonitor.new(speaker, ok, { :clock => -> { T0 } }.merge(arg))]
  end

  # A peer as peer_up leaves it.
  def up_peer(m, address = '192.0.2.1')
    o = BGP::Open.new(4, 65_001, 180, '192.0.2.1', BGP::OPT_PARM::CAP::As4.new(65_001),
                      BGP::OPT_PARM::CAP::Mbgp.new(1, 1), BGP::OPT_PARM::CAP::Mbgp.new(2, 1))
    p = M::Peer.new(address, Neighbor.new(:tcp))
    p.header = BGP::Bmp::Per_peer.new(address, 65_001, '10.0.0.1')
    p.session_info = BGP::Neighbor::Capabilities.new(o, o)
    p.local_address, p.local_port, p.remote_port = '192.0.2.3', 179, 40_000
    m.instance_variable_get(:@peers)[address] = p
    p
  end

  # Each message carries the time it was made, not the Peer Up's.
  def test_each_message_is_stamped
    _, m = with_clock
    p = up_peer(m)
    p.header.seconds = 1
    h = m.send(:stamped, p)
    assert_equal([T0.to_i, 250], [h.seconds, h.microseconds])
    assert_equal(1, p.header.seconds, 'the peer keeps its own')
  end

  Ev = Struct.new(:kind, :peer, :data)

  # The first NOTIFICATION wins, sent or received; one for a peer that
  # is not up is no matter.
  def test_notification_events
    _, m = with_clock
    p = up_peer(m)
    m.notification_event(Ev.new(:session, '192.0.2.1', {}))
    assert_nil(p.notification)
    m.notification_event(Ev.new(:notification, '192.0.2.9', { :direction => 'send', :code => 6, :subcode => 4 }))
    m.notification_event(Ev.new(:notification, '192.0.2.1', { :direction => 'receive', :code => 6, :subcode => 2, :octets => '01' }))
    m.notification_event(Ev.new(:notification, '192.0.2.1', { :direction => 'send', :code => 6, :subcode => 4 }))
    assert_equal([BGP::Notification.new(6, 2, "\x01".b).encode, false], [p.notification.encode, p.notification_sent])
  end

  # An UPDATE on a session that is not the peer's now is not kept.
  def test_an_old_session_is_not_reported
    _, m = with_clock
    old = M::Peer.new('192.0.2.1', Neighbor.new(:tcp))
    up_peer(m)
    m.received(old, BGP::Update.new(BGP::Path_attribute.new(BGP::Origin.new, BGP::As_path.new(65_001), BGP::Next_hop.new('192.0.2.9')),
                                    BGP::Nlri.new('10.0.0.0/8')))
    assert_equal({}, old.routes)
    m.peer_down(old)
    assert_equal(['192.0.2.1'], m.instance_variable_get(:@peers).keys, 'nor taken down')
  end

  # The dump is the routes as they are now: an IPv6 route with its next
  # hop, a withdrawal, and treat-as-withdraw of a route already kept.
  def test_the_dump
    _, m = with_clock
    p = up_peer(m)
    pa = ->(*x) { BGP::Path_attribute.new(BGP::Origin.new, BGP::As_path.new(65_001), *x) }
    v4 = BGP::Update.new(pa.(BGP::Next_hop.new('192.0.2.9')), BGP::Nlri.new('10.0.0.0/8', '10.1.0.0/16', '10.2.0.0/16'))
    v6 = BGP::Update.new(pa.(BGP::Mp_reach.new(:afi => 2, :safi => 1, :nexthop => ['2001:db8::1'], :nlris => ['2001:db8:1::/48'])))
    [v4, v6, BGP::Update.new(BGP::Withdrawn.new('10.1.0.0/16'))].each { |u| m.received(p, u) }
    taw = BGP::Update.new(pa.(BGP::Next_hop.new('192.0.2.9')), BGP::Nlri.new('10.2.0.0/16')).encode
    taw = BGP::Update.new(taw.sub("\x40\x01\x01\x00".b, "\x40\x01\x01\x09".b).is_packed, p.session_info)
    m.received(p, taw)
    assert_equal([1, 1], [p.treat_as_withdraw_updates, p.treat_as_withdraw_prefixes])
    got = m.send(:dump, p).collect { |o| BGP::Bmp::Message.factory(o, p.session_info).update.to_hash }
    assert_equal([{ :path_attributes => { :origin => :igp, :as_path => { :sequence => [65_001] }, :next_hop => '192.0.2.9' }, :nlris => ['10.0.0.0/8'] },
                  { :path_attributes => { :origin => :igp, :as_path => { :sequence => [65_001] },
                                          :mp_reach => { :safi => 1, :afi => 2, :nlris => '2001:db8:1::/48', :nexthop => ['2001:db8::1'] } } },
                  {}, { :path_attributes => { :mp_unreach => { :safi => 1, :afi => 2, :nlris => [] } } }], got)
  end

  # Section 3.2: retry doubling while dials fail, and from retry again
  # after a session; each failure logged.
  def test_dialing
    waits = Queue.new
    log = []
    _, m = with_clock(:sleep => ->(n) { waits << n ; sleep 0.05 }, :logger => ->(_, msg) { log << msg })
    closed = TCPServer.new('127.0.0.1', 0)
    port = closed.addr[1]
    closed.close
    s = M::Station.new('address' => '127.0.0.1', 'port' => port, 'retry' => 0.5)
    t = Thread.new { m.send(:dial, s) }
    assert_equal([0.5, 1.0, 2.0], Array.new(3) { waits.pop })
    assert_match(/\Abgp4r: bmp: 127\.0\.0\.1:#{port}: /, log.first)
    assert_not_nil(s.last_error)
    t.kill
    listener = TCPServer.new('127.0.0.1', port)
    waits.clear
    t = Thread.new { m.send(:dial, s) }
    3.times { listener.accept.close }
    assert_equal([0.5, 0.5, 0.5], Array.new(3) { waits.pop })
    assert_nil(s.last_error, 'a session clears it')
  ensure
    t&.kill
    listener&.close
  end

  def test_closing_a_station
    speaker, m = with_clock
    a, b = UNIXSocket.pair
    s = m.stations.first
    s.socket, s.queue, s.state = a, Queue.new, 'up'
    m.send(:close_station, s, 'why')
    m.send(:close_station, s, 'again')
    assert_equal([true, nil, 'connecting'], [a.closed?, s.queue, s.state])
    downs = speaker.events.since(0).select { |e| e.kind == :bmp }
    assert_equal(['BMP station 127.0.0.1:5000 down: why'], downs.collect(&:message), 'once')
  ensure
    b&.close
  end

  # Section 4.5: after the Termination bgp4rd closes the session, if the
  # station does not.
  def test_stop_closes_what_the_station_keeps_open
    listener = TCPServer.new('127.0.0.1', 0)
    speaker = BGP::Daemon::Speaker.new('as' => 65_000, 'router_id' => '10.0.0.3', 'neighbors' => [])
    m = BGP::Daemon::BmpMonitor.new(speaker, { 'stations' => [{ 'address' => '127.0.0.1', 'port' => listener.addr[1] }] }).start
    sock = listener.accept
    got = ''.b
    got << sock.readpartial(4096) until BGP::Bmp.slices(got)[0].size == 1
    m.stop
    got << sock.read
    assert_equal([BGP::Bmp::Initiation, BGP::Bmp::Termination], BGP::Bmp.messages(got)[0].collect(&:class), 'then the end of the stream')
  ensure
    sock&.close
    listener&.close
  end

  def test_start_and_stop
    speaker, m = with_clock(:sleep => ->(_) { sleep 0.05 })
    listeners = speaker.events.instance_variable_get(:@listeners)
    n = listeners.size
    assert_same(m, m.start)
    assert_equal(n + 1, listeners.size)
    threads = m.instance_variable_get(:@threads)
    assert_same(m, m.stop)
    assert_equal(n, listeners.size, 'the listener goes')
    assert(threads.all? { |t| t.join(1) && !t.alive? }, 'and every thread')
  end

  def test_show_bmp
    assert(BGP::Daemon::Api::METHODS.key?('show.bmp'))
    speaker = BGP::Daemon::Speaker.new('as' => 65_000, 'router_id' => '10.0.0.3', 'neighbors' => [])
    assert_nil(speaker.bmp)
    assert_equal([], BGP::Daemon::Views.new(speaker).bmp[:rows])
    m = monitor
    assert_equal(['127.0.0.1:5000'], m.rows.collect { |r| r[:station] })
  end
end
