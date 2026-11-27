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
require 'json'
require 'stringio'
require 'bgp/bmp/station'

# Bmp::Station a message at a time, with no socket: the JSON lines, the
# peers and routes it keeps, and what closes a session.
# docs/design/bgp-operations.md 8b, docs/bmp.md section 5.
class TestBmpStation < Test::Unit::TestCase
  include BGP::Bmp

  FIXTURE = File.expand_path('../../fixtures/bmp/frr-10.5.1.bin', __dir__)
  T0 = Time.utc(2026, 11, 27, 10, 0, 0)

  def setup
    @io = StringIO.new
    @station = Station.new(:lines => @io, :clock => -> { T0 })
    @router = @station.open('192.0.2.1:40000')
  end

  def lines ; @io.string.lines.collect { |l| JSON.parse(l) } ; end
  def peer(type = 0, flags = 0, address = '192.0.2.2') ; Per_peer.new(address, 65_002, '192.0.2.2', type, flags) ; end
  def open(*caps) ; BGP::Open.new(4, 65_001, 180, '192.0.2.1', *caps) ; end
  def initiation ; Initiation.new({ :type => 1, :string => 'FRRouting 10.5.1' }, { :type => 2, :string => 'r1' }) ; end
  def up(p = peer, o = open(BGP::OPT_PARM::CAP::As4.new(65_001))) ; Peer_up.new(p, '192.0.2.1', 179, 1, o, o) ; end
  def take(*msgs) ; msgs.collect { |m| @station.receive(@router, m.encode) } ; end

  def update(prefixes, path = [65_002])
    BGP::Update.new(BGP::Path_attribute.new(BGP::Origin.new, BGP::As_path.new(*path), BGP::Next_hop.new('192.0.2.9')),
                    BGP::Nlri.new(*prefixes))
  end

  def withdraw(prefixes) ; BGP::Update.new(BGP::Withdrawn.new(*prefixes)) ; end
  def rm(u, p = peer) ; Route_monitoring.new(p, u) ; end
  def routes(params = {}) ; @station.routes(params)[:routes] ; end
  def prefixes(params = {}) ; routes(params).collect { |r| [r[:view], r[:nlri][:prefix]] } ; end

  def test_each_message_is_a_json_line
    take(initiation, up, rm(update(['10.0.0.0/8'])))
    l = lines
    assert_equal(%w[connected initiation peer_up route_monitoring], l.collect { |x| x['type'] })
    assert_equal([1, 2, 3, 4], l.collect { |x| x['seq'] })
    assert_equal(['2026-11-27T10:00:00.000Z'], l.collect { |x| x['time'] }.uniq)
    assert_equal(['192.0.2.1:40000'], l.collect { |x| x['router'] }.uniq)
    assert_equal([nil, 'r1', 'r1', 'r1'], l.collect { |x| x['sys_name'] }, 'sysName from the Initiation on')
    assert_equal(JSON.parse(JSON.generate(initiation.to_hash[:initiation])), l[1]['message'])
    assert_equal(['10.0.0.0/8'], l[3]['message']['update']['nlris'])
    assert_equal([[]], l.collect { |x| x['findings'] }.uniq)
    assert_false(l.any? { |x| x.key?('hex') })
  end

  def test_the_frr_capture
    rest, why = @station.feed(@router, File.binread(FIXTURE))
    assert_equal([0, nil], [rest.bytesize, why])
    assert_equal(43, lines.size, 'connected, then the 42 messages')
    assert_equal({ :reserved_flags => 1, :unknown_stat => 22 }, @router.findings, 'FRR 10.5.1, docs/bmp.md section 4')
    assert_equal([%w[loc_rib 203.0.113.0/24], %w[loc_rib 192.0.2.0/24]], prefixes)
    p = @station.peers[:peers].find { |x| x[:address] == '127.0.0.1' }
    assert_equal([false, 4, { 'pre_policy' => 0, 'post_policy' => 0, 'loc_rib' => 0 }], [p[:up], p[:down_reason], p[:routes]])
  end

  # RFC 7854 section 5: the L flag picks the Adj-RIB-In; RFC 9069 the
  # Loc-RIB.
  def test_three_views
    take(initiation, up, up(peer(3, 0, '0.0.0.0')),
         rm(update(['10.0.0.0/8'])), rm(update(['10.1.0.0/16']), peer(0, FLAG_L)),
         rm(update(['10.2.0.0/16']), peer(3, 0, '0.0.0.0')))
    assert_equal([%w[pre_policy 10.0.0.0/8], %w[post_policy 10.1.0.0/16], %w[loc_rib 10.2.0.0/16]], prefixes)
    assert_equal([%w[post_policy 10.1.0.0/16]], prefixes('view' => 'post_policy'))
    assert_equal([%w[loc_rib 10.2.0.0/16]], prefixes('peer' => '0.0.0.0'))
    r = routes('view' => 'pre_policy').first
    assert_equal({ :router => '192.0.2.1:40000', :sys_name => 'r1',
                   :peer => { :peer_type => 0, :distinguisher => '0000000000000000', :address => '192.0.2.2', :asn => 65_002, :bgp_id => '192.0.2.2' },
                   :view => 'pre_policy', :afi => 1, :safi => 1, :nlri => { :prefix => '10.0.0.0/8' }, :next_hop => '192.0.2.9',
                   :path_attributes => { :origin => :igp, :as_path => { :sequence => [65_002] }, :next_hop => '192.0.2.9' } }, r)
  end

  def test_routes_filters
    take(initiation, up, rm(update(['10.0.0.0/8'])))
    assert_equal(1, routes('router' => '192.0.2.1:40000').size)
    assert_equal(1, routes('router' => 'r1').size, 'by sysName too')
    assert_equal(0, routes('router' => 'r2').size)
    assert_equal(0, routes('peer' => '192.0.2.3').size)
    e = assert_raise(Refused) { routes('view' => 'adj_rib_out') }
    assert_match(/pre_policy, post_policy or loc_rib/, e.message)
    assert_equal(1, @station.peers('router' => 'r1')[:peers].size)
    assert_equal(0, @station.peers('router' => 'r2')[:peers].size)
  end

  def test_a_withdrawal_and_a_replacement
    take(initiation, up, rm(update(['10.0.0.0/8', '10.1.0.0/16'])), rm(withdraw(['10.0.0.0/8'])),
         rm(update(['10.1.0.0/16'], [65_002, 65_003])))
    assert_equal([%w[pre_policy 10.1.0.0/16]], prefixes)
    assert_equal({ :sequence => [65_002, 65_003] }, routes.first[:path_attributes][:as_path])
  end

  def test_mp_reach_and_unreach
    take(initiation, up)
    reach = BGP::Mp_reach.new(:afi => 2, :safi => 1, :nexthop => ['2001:db8::1'], :nlris => ['2001:db8:1::/48', '2001:db8:2::/48'])
    take(rm(BGP::Update.new(BGP::Path_attribute.new(BGP::Origin.new, BGP::As_path.new(65_002), reach))))
    r = routes.first
    assert_equal([2, 1, { :prefix => '2001:db8:1::/48' }, '2001:db8::1'], [r[:afi], r[:safi], r[:nlri], r[:next_hop]])
    assert_false(r[:path_attributes].key?(:mp_reach))
    take(rm(BGP::Update.new(BGP::Path_attribute.new(BGP::Mp_unreach.new(:afi => 2, :safi => 1, :nlris => ['2001:db8:1::/48'])))))
    assert_equal([%w[pre_policy 2001:db8:2::/48]], prefixes)
  end

  # RFC 8277 section 2.4: a withdrawal's label need not be the
  # announcement's.
  def test_a_vpn_route_is_withdrawn_whatever_its_label
    take(initiation, up)
    reach = BGP::Mp_reach.new(:afi => 1, :safi => 128, :nexthop => ['192.0.2.9'],
                              :nlris => [{ :rd => [100, 1], :prefix => '10.1.0.0/16', :label => 100 }])
    take(rm(BGP::Update.new(BGP::Path_attribute.new(BGP::Origin.new, BGP::As_path.new(65_002), reach))))
    assert_equal({ :label => 100, :rd => [100, 1], :prefix => '10.1.0.0/16' }, routes.first[:nlri])
    un = BGP::Mp_unreach.new(:afi => 1, :safi => 128, :nlris => [{ :rd => [100, 1], :prefix => '10.1.0.0/16', :label => 0x800000 }])
    take(rm(BGP::Update.new(BGP::Path_attribute.new(un))))
    assert_equal([], routes)
  end

  # RFC 4724 section 2: an empty UPDATE, or one with an empty
  # MP_UNREACH_NLRI.
  def test_end_of_rib
    take(initiation, up, rm(update(['10.0.0.0/8'])), rm(BGP::Update.new))
    take(rm(BGP::Update.new(BGP::Path_attribute.new(BGP::Mp_unreach.new(:afi => 2, :safi => 1, :nlris => [])))))
    take(rm(BGP::Update.new))
    p = @station.peers[:peers].first
    assert_equal([{ :afi => 1, :safi => 1 }, { :afi => 2, :safi => 1 }], p[:end_of_rib])
    assert_equal({ 'pre_policy' => 1, 'post_policy' => 0, 'loc_rib' => 0 }, p[:routes], 'the End-of-RIB withdraws nothing')
    ev = @station.events_view[:events].select { |e| e[:data][:event] == 'end_of_rib' }
    assert_equal([[1, 1], [2, 1], [1, 1]], ev.collect { |e| [e[:data][:afi], e[:data][:safi]] })
    assert_equal('end_of_rib: peer 192.0.2.2 End-of-RIB 1/1', ev.first[:message])
  end

  # A Route Monitoring is read with its peer's Peer Up: a session
  # without the four-octet AS capability has a two-octet AS_PATH, which
  # the A flag, clear, would read as four.
  def test_the_peer_up_gives_the_session
    o2 = BGP::Open.new(4, 65_001, 180, '192.0.2.1')
    info = BGP::Update::Info.new(false)
    octets = Per_peer.new('192.0.2.2', 65_002, '192.0.2.2').encode
    u = update(['10.0.0.0/8'], [65_002, 65_003])
    body = [VERSION, HEADER + octets.bytesize + u.encode(info).bytesize, 0].pack('CNC') + octets + u.encode(info)
    take(initiation, up(peer, o2))
    @station.receive(@router, body)
    assert_equal({ :sequence => [65_002, 65_003] }, routes.first[:path_attributes][:as_path])
  end

  def test_peer_down_and_up_clear_the_routes
    take(initiation, up, rm(update(['10.0.0.0/8'])), Peer_down.new(peer, 1, BGP::Notification.new(6, 2)))
    p = @station.peers[:peers].first
    assert_equal([false, 1, 0, '2026-11-27T10:00:00.000Z'], [p[:up], p[:down_reason], routes.size, p[:last_down]])
    take(rm(update(['10.0.0.0/8'])), up)
    assert_equal([true, 0], [@station.peers[:peers].first[:up], routes.size], 'a Peer Up starts the peer afresh')
    downs = @station.events_view[:events].select { |e| e[:data][:event] == 'peer_down' }
    assert_equal(['peer_down: peer 192.0.2.2 down, reason 1'], downs.collect { |e| e[:message] })
    assert_equal(1, downs.first[:data][:reason])
  end

  def test_stats_by_type_and_family
    take(initiation, up, Stats_report.new(peer, [7, 1], [0, 5]), Stats_report.new(peer, [0, 6], { :type => 9, :afi => 1, :safi => 1, :value => 3 },
                                                                                 { :type => 9, :afi => 2, :safi => 1, :value => 4 }))
    assert_equal([{ :type => 0, :value => 6 }, { :type => 7, :value => 1 },
                  { :type => 9, :value => 3, :afi => 1, :safi => 1 }, { :type => 9, :value => 4, :afi => 2, :safi => 1 }],
                 @station.peers[:peers].first[:stats])
  end

  # Section 4.5: "the monitoring station MUST close the TCP session after
  # receiving a termination message."
  def test_a_termination_closes
    assert_equal([true, false], take(initiation, Termination.new({ :type => 1, :code => 0 })))
    buffer = initiation.encode + Termination.new({ :type => 1, :code => 0 }).encode + initiation.encode
    assert_equal('termination', @station.feed(@router, buffer)[1])
  end

  def test_close
    take(initiation, up, rm(update(['10.0.0.0/8'])))
    @station.close(@router, 'end of stream')
    l = lines.last
    assert_equal(%w[closed end\ of\ stream], [l['type'], l['reason']])
    assert_equal([[], [], 0], [routes, @station.routers[:routers], @station.status[:routers]])
    n = lines.size
    @station.close(@router, 'again')
    assert_equal(n, lines.size, 'once')
    assert_equal('closed: BMP session closed: end of stream', @station.events_view[:events].last[:message])
  end

  # Section 4.1 defines the header for version 3 only, so another
  # version frames nothing: one line, then the session closes.
  def test_what_cannot_be_framed
    v0 = initiation.encode.tap { |o| o.setbyte(0, 0) }
    rest, why = @station.feed(@router, initiation.encode + v0)
    assert_equal(['version 0', v0], [why, rest])
    l = lines.last
    assert_equal(['undecoded', [{ 'name' => 'version', 'detail' => 'version 0, where 3 is BMP\'s' }], v0.unpack1('H*')],
                 [l['type'], l['findings'], l['hex']])
    assert_equal('Message Length 5', Station.frame([3, 5, 4].pack('CNC'))[2])
    assert_equal("Message Length #{Station::MAX_MESSAGE + 1}", Station.frame([3, Station::MAX_MESSAGE + 1, 4].pack('CNC'))[2])
    big = [3, 1000, 0].pack('CNC') + ("\0".b * 300)
    @station.feed(@router, [3, 5, 4].pack('CNC') + big)
    assert_equal(Station::MAX_HEX * 2, lines.last['hex'].size, 'the line keeps at most MAX_HEX octets')
    assert_equal([[], initiation.encode.byteslice(0, 10), nil], Station.frame(initiation.encode.byteslice(0, 10)), 'a part kept for later')
    assert_equal([[], 'xy'.b, nil], Station.frame('xy'), 'a part of a header kept too')
  end

  def test_a_message_the_codec_cannot_read
    octets = rm(update(['10.0.0.0/8'])).encode.tap { |o| o.setbyte(67, 0xff) }
    take(initiation)
    assert_true(@station.receive(@router, octets), 'the session goes on')
    l = lines.last
    assert_equal('undecoded', l['type'])
    assert_equal(octets.unpack1('H*'), l['hex'])
    assert_equal(%w[decode], l['findings'].collect { |f| f['name'] }, 'Validation reads the BGP header, not the UPDATE')
    assert_match(/\ANoMethodError: /, l['findings'].last['detail'])
  end

  # Section 3.3: the router "MUST begin by sending an Initiation
  # message". The station says so and reads on.
  def test_no_initiation
    take(up)
    assert_equal([{ 'name' => 'no_initiation', 'detail' => 'Message Type 3 before an Initiation' }], lines.last['findings'])
    assert_equal(1, @station.peers[:peers].size)
    take(initiation, up)
    assert_equal([], lines.last['findings'])
    f = @station.events_view[:events].find { |e| e[:data][:event] == 'findings' }
    assert_equal(['no_initiation'], f[:data][:findings])
    assert_equal({ :no_initiation => 1 }, @router.findings)
  end

  # Section 4.1: "MUST ignore unrecognized message types"; no event for
  # what is to be ignored.
  def test_an_unknown_type_is_a_line_and_nothing_else
    assert_equal([true, true], take(initiation, Unknown.new(99, "\0\0\0\0".b)))
    assert_equal(['unknown', { 'type' => 99, 'hex' => '00000000' }], [lines.last['type'], lines.last['message'].slice('type', 'hex')])
    assert_equal([], @station.events_view[:events].select { |e| e[:data][:event] == 'findings' })
  end

  def test_the_router
    take(initiation, up)
    assert_equal({ :router => '192.0.2.1:40000', :sys_name => 'r1', :sys_descr => 'FRRouting 10.5.1',
                   :connected_at => '2026-11-27T10:00:00.000Z', :messages => 2, :peers => 1, :up => 1, :findings => {} },
                 @station.routers[:routers].first)
    take(Termination.new({ :type => 1, :code => 0 }, { :type => 2, :string => 'r9' }))
    assert_equal('r9', @station.routers[:routers].first[:sys_name], 'a Termination may name the router too')
  end

  def test_lines_and_events_since
    take(initiation, up)
    assert_equal([2, 3], @station.lines('since' => '1')[:lines].collect { |l| l[:seq] })
    assert_equal(3, @station.lines[:seq])
    assert_equal(3, @station.lines[:lines].size)
    assert_equal(1, @station.events_view('since' => '1')[:events].size)
    assert_raise(Refused) { @station.lines('since' => 'x') }
    assert_raise(Refused) { @station.events_view('since' => '1x') }
  end

  def test_lines_kept_are_bounded
    s = Station.new(:keep_lines => 2)
    r = s.open('x')
    s.receive(r, initiation.encode)
    s.receive(r, initiation.encode)
    assert_equal([2, 3], s.lines[:lines].collect { |l| l[:seq] })
  end

  def test_status_and_act
    take(initiation, up)
    assert_equal({ :bgp4r => BGP::VERSION, :listen => nil, :routers => 1, :peers => 1, :lines => 3 }, @station.status)
    assert_raise(Refused) { @station.act('fault', {}) }
  end

  def test_a_buffer_tagged_utf8_is_read_the_same
    @station.feed(@router, File.binread(FIXTURE))
    want = lines
    setup
    @station.feed(@router, File.binread(FIXTURE).force_encoding('UTF-8'))
    assert_equal(want, lines)
  end

  def test_the_logger
    log = []
    s = Station.new(:logger => ->(level, message) { log << [level, message] })
    s.open('192.0.2.1:40000')
    assert_equal([[:info, 'bmp 192.0.2.1:40000 connected: BMP session up']], log)
  end

  # A peer first seen in a Route Monitoring is not up; a Peer Up says
  # when; a Peer Down empties its End-of-RIBs too; and the header is the
  # last one, as FRR 10.5.1's Peer Down with BGP ID 0.0.0.0 shows.
  def test_what_a_peer_holds
    take(initiation, rm(update(['10.0.0.0/8'])))
    assert_equal([false, nil], @station.peers[:peers].first.values_at(:up, :last_up))
    take(Peer_down.new(Per_peer.new('192.0.2.2', 65_002, '0.0.0.0'), 4), up, rm(BGP::Update.new))
    p = @station.peers[:peers].first
    assert_equal(['192.0.2.2', '2026-11-27T10:00:00.000Z', [{ :afi => 1, :safi => 1 }]], p.values_at(:bgp_id, :last_up, :end_of_rib))
    take(Peer_down.new(peer, 4))
    assert_equal([], @station.peers[:peers].first[:end_of_rib])
  end

  def test_what_cannot_be_framed_is_counted
    @station.feed(@router, initiation.encode.tap { |o| o.setbyte(0, 0) })
    assert_equal({ :version => 1 }, @router.findings)
  end

  def test_listen_gives_the_port
    s = Station.new
    port = s.listen('127.0.0.1', 0)
    assert_equal(s.port, port)
    assert_not_equal(0, port)
    other = s.listen('127.0.0.1', 0)
    assert_not_equal(port, other)
    assert_equal(port, s.port, 'the first')
  ensure
    s&.stop
  end

  # A router's socket, as a router has it, with the station's lines.
  def dialed_in
    @tcp = Station.new(:lines => (@tcp_io = StringIO.new))
    sock = TCPSocket.new('127.0.0.1', @tcp.listen('127.0.0.1', 0))
    wait { tcp_lines.size == 1 }
    sock
  end

  def tcp_lines ; @tcp_io.string.lines.collect { |l| JSON.parse(l) } ; end

  def wait(seconds = 5)
    deadline = Time.now + seconds
    sleep 0.02 until yield || Time.now > deadline
    assert(yield, 'in time')
  end

  # Section 4.5: "the monitoring station MUST close the TCP session after
  # receiving a termination message."
  def test_a_termination_closes_the_tcp_session
    sock = dialed_in
    sock.write(initiation.encode + Termination.new({ :type => 1, :code => 0 }).encode)
    assert(sock.wait_readable(5))
    assert_raise(EOFError) { sock.readpartial(10) }
    wait { tcp_lines.last['type'] == 'closed' }
    assert_equal('termination', tcp_lines.last['reason'])
  ensure
    @tcp&.stop
  end

  def test_a_reset_is_the_reason
    sock = dialed_in
    sock.setsockopt(Socket::SOL_SOCKET, Socket::SO_LINGER, [1, 0].pack('ii'))
    sock.close
    wait { tcp_lines.last['type'] == 'closed' }
    assert_equal('Connection reset by peer', tcp_lines.last['reason'])
  ensure
    @tcp&.stop
  end

  def test_stop
    sock = dialed_in
    port = @tcp.port
    assert_same(@tcp, @tcp.stop)
    assert_equal(%w[closed station\ stopped], tcp_lines.last.values_at('type', 'reason'))
    assert(sock.wait_readable(5))
    assert_raise(EOFError) { sock.readpartial(10) }
    assert_raise(Errno::ECONNREFUSED) { TCPSocket.new('127.0.0.1', port) }
  end

  # The station dials, backs off 30 s doubling while dials fail, and
  # starts again from 30 s after a session.
  def test_dialing_backs_off
    waits = Queue.new
    log = []
    s = Station.new(:sleep => ->(n) { waits << n ; sleep 0.05 }, :logger => ->(_, m) { log << m })
    closed = TCPServer.new('127.0.0.1', 0)
    port = closed.addr[1]
    closed.close
    s.connect('127.0.0.1', port)
    assert_equal([30, 60, 120], Array.new(3) { waits.pop })
    assert_match(/\Abmp dial 127\.0\.0\.1:#{port}: /, log.first)
    s.stop
    waits.clear
    sleep 0.3
    assert_true(waits.empty?, 'a stopped station dials no more')
  ensure
    s&.stop
  end

  def test_a_session_resets_the_backoff
    waits = Queue.new
    listener = TCPServer.new('127.0.0.1', 0)
    s = Station.new(:sleep => ->(n) { waits << n ; sleep 0.05 })
    s.connect('127.0.0.1', listener.addr[1])
    3.times { listener.accept.close }
    assert_equal([30, 30, 30], Array.new(3) { waits.pop })
  ensure
    s&.stop
    listener&.close
  end

  # Section 3.2: "a default initial backoff of 30 seconds and a maximum
  # of 720 seconds".
  def test_backoff
    assert_equal([30, 60, 120, 240, 480, 720, 720], (1..7).collect { |n| Station.backoff(n) })
  end

  def test_name_of
    assert_equal('192.0.2.1:179', Station.name_of(Addrinfo.tcp('192.0.2.1', 179)))
    assert_equal('[2001:db8::1]:179', Station.name_of(Addrinfo.tcp('2001:db8::1', 179)))
    assert_equal('192.0.2.1:179', Station.name_of(Addrinfo.tcp('::ffff:192.0.2.1', 179)))
  end
end
