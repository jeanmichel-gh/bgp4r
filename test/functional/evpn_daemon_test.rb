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
require 'fileutils'
require 'socket'
require 'json'
require 'bgp/daemon'
require 'bgp/gen/evpn_routes'
require 'bgp/gen/sender'

# A bgp4rd and a library BGP::Neighbor on loopback, the neighbor sending
# EVPN routes (AFI 25 / SAFI 70) as bgp4r-sim does, from the generator:
# docs/design/evpn.md, pull request 1. The daemon dials, so the session
# takes run_session, where the EVPN table is attached.
class BGP_Evpn_Daemon_Functional_Test < Test::Unit::TestCase

  PORT = 17_943

  def setup
    @dir = Dir.mktmpdir
    @listener = TCPServer.new('127.0.0.1', PORT)
  end

  def teardown
    @peer.close if @peer
    @server.stop if @server
    @vtep.stop if @vtep
  ensure
    @listener.close if @listener
    FileUtils.remove_entry(@dir) if @dir
  end

  # vtep4rd's socket as bgp4rd sees it (vtep4r vxlan/daemon/api.rb): JSON
  # lines, show.vnis and show.macs answered from its tables, and every
  # other request recorded and applied. One VNI, 100, in evpn mode.
  class FakeVtep
    attr_reader :orders, :flood, :macs

    def initialize(path)
      @path = path
      @orders = Queue.new
      @flood = []
      @macs = {}
      @lock = Mutex.new
      @streams = []
      @server = UNIXServer.new(path)
      @clients = []
      @thread = Thread.new { loop { c = @server.accept; @clients << c; Thread.new(c) { |s| serve(s) } } }
    end

    # As vtep4rd going away: its listener and every connection closed.
    def stop
      @thread.kill
      @server.close
      @clients.each { |c| c.close rescue nil }
      File.delete(@path) if File.exist?(@path)
    end

    # A MAC heard on a port, and its `mac` event to every stream, as
    # vtep4rd's MacTable#learn and its event (vtep4r #15).
    def learn(mac, port)
      @lock.synchronize do
        was = @macs[mac]
        @macs[mac] = { 'mac' => mac, 'type' => 'local', 'port' => port, 'origin' => 'learned', 'seq' => 0 }
        data = { 'type' => was ? 'moved' : 'learned', 'vni' => 100, 'mac' => mac, 'port' => port }
        data['from_vtep'] = was['vtep'] if was && was['vtep']
        ev = JSON.generate('event' => { 'kind' => 'mac', 'data' => data })
        @streams.each { |s| s.write("#{ev}\n") rescue nil }
      end
    end

    def serve(sock)
      while (line = sock.gets)
        req = JSON.parse(line)
        if req['method'] == 'events.subscribe'
          sock.write("#{JSON.generate('id' => req['id'], 'result' => { 'seq' => 0, 'replayed' => 0, 'kinds' => ['mac'] })}\n")
          @lock.synchronize { @streams << sock }
          next
        end
        sock.write("#{JSON.generate('id' => req['id'], 'result' => answer(req['method'], req['params']))}\n")
      end
    rescue IOError, SystemCallError
      nil
    end

    def answer(method, p)
      @lock.synchronize do
        case method
        when 'show.vnis' then [{ 'vni' => 100, 'mode' => 'evpn', 'remote_vteps' => @flood.dup }]
        when 'show.macs' then @macs.values.collect(&:dup)
        else
          @orders << [method, p]
          case method
          when 'vni.flood.add' then @flood |= [p['vtep']]
          when 'vni.flood.del' then @flood -= [p['vtep']]
          when 'mac.add'
            @macs[p['mac']] = { 'mac' => p['mac'], 'type' => 'remote', 'vtep' => p['vtep'], 'origin' => 'api', 'seq' => p['seq'] }
          when 'mac.del' then @macs.delete(p['mac'])
          end
          {}
        end
      end
    end
  end

  def daemon(caps, extra = {})
    err = StringIO.new
    @server = BGP::Daemon::Server.new(StringIO.new, err)
    config = BGP::Daemon::Server.with_defaults(
      { 'as' => 65_000, 'router_id' => '10.255.0.12', 'state_file' => File.join(@dir, 'state.json'),
        'neighbors' => [{ 'address' => '127.0.0.1', 'as' => 65_000, 'connect' => true, 'port' => PORT,
                          'retry' => 1, 'description' => 's1', 'capabilities' => caps }] }.merge(extra))
    assert_not_nil(@server.build(config, :socket => File.join(@dir, 'bgp4rd.sock')),
                   "bgp4rd did not start: #{err.string}")
  end

  # watch: record what bgp4rd sends from the first UPDATE, since it
  # sends its own EVPN routes as soon as the session is up.
  def peer(evpn: true, watch: false)
    sock = @listener.accept
    @peer = BGP::Neighbor.new(:my_as => 65_000, :id => '10.0.9.2',
                              :remote_addr => '127.0.0.1', :local_addr => '127.0.0.1')
    @peer.capability :as4_byte
    @peer.capability :mbgp_l2vpn_evpn if evpn
    watch_sent if watch
    Thread.new { @peer.start(:session => sock, :timeout => 10) }
    wait_for('the session to come up') { @peer.is_established? }
  end

  def call(method, params = {})
    c = BGP::Daemon::Client.new(@server.api.path)
    c.call(method, params)
  ensure
    c.close if c
  end

  def wait_for(what, timeout = 10)
    deadline = Time.now + timeout
    until yield
      flunk("timed out waiting for #{what}") if Time.now > deadline
      sleep 0.05
    end
  end

  # What lab 3's inject scenario sends: a type 3 route for 10.0.9.2 and
  # MACs behind it, with the VNI whole and the encapsulation VXLAN.
  def spec(type, start, count = 1)
    { 'family' => 'evpn', 'route_type' => type, 'start' => start, 'count' => count, 'rd' => '10.0.9.2:100',
      'route_target' => '65000:100', 'vni' => 100,
      'attributes' => { 'extended_communities' => ['encapsulation:vxlan'] } }
  end

  # The generator's UPDATEs, with the next hop and LOCAL_PREF its
  # Sender gives an internal peer (bgp/gen/sender.rb), as bgp4r-sim's.
  def send_spec(s, withdraw: false)
    sender = BGP::Gen::Sender.read('as' => 65_000, 'next_hop' => '10.0.9.2')
    BGP::Gen::Evpn_routes.new(s, sender).updates.each do |u|
      if withdraw
        nlris = u.path_attribute[BGP::Mp_reach].nlris.collect(&:to_hash)
        u = BGP::Update.new(BGP::Path_attribute.new(BGP::Mp_unreach.new(:afi => 25, :safi => 70, :nlris => nlris)))
      end
      @peer.send_message(u)
    end
  end

  def rows(params = {})
    call('show.evpn', { 'limit' => 1000 }.merge(params))['rows']
  end

  def test_the_evpn_routes_a_peer_sends_are_in_show_evpn
    daemon(%w[as4_byte mbgp_l2vpn_evpn])
    peer
    send_spec(spec(3, '10.0.9.2'))
    send_spec(spec(2, '02:00:00:99:00:00', 10))
    wait_for('eleven EVPN routes') { call('show.evpn')['total'] == 11 }
    imet = rows('route_type' => 3).first
    assert_equal(['10.0.9.2:100', '10.0.9.2', 100, 'VXLAN', { 'type' => 'ingress_replication', 'id' => '10.0.9.2' }, true],
                 imet.values_at('rd', 'originator', 'vni', 'encap', 'pmsi', 'best'))
    macs = rows('route_type' => 2)
    assert_equal(10, macs.size)
    assert_equal(['02:00:00:99:00:00', nil, 100, '10.0.9.2', '127.0.0.1', ['65000:100']],
                 macs.first.values_at('mac', 'ip', 'vni', 'next_hop', 'peer', 'route_targets'))
    assert_equal(['02:00:00:99:00:05'], rows('mac' => '02:00:00:99:00:05').collect { |r| r['mac'] })
    assert_equal(0, call('show.rib')['total'], 'and none of it is unicast')
    evpn = call('show.peers').first['families'].find { |f| f['family'] == 'evpn' }
    assert_equal({ 'family' => 'evpn', 'received' => 11, 'sent' => 0, 'other_types' => 0 }, evpn)

    send_spec(spec(2, '02:00:00:99:00:00', 10), withdraw: true)
    wait_for('the withdrawal') { call('show.evpn')['total'] == 1 }

    @peer.close
    @peer = nil
    wait_for('the closed session to take its routes (RFC 4271 section 6)') { call('show.evpn')['total'] == 0 }
  end

  # RFC 4760 section 8: both speakers must advertise the capability.
  def test_a_peer_that_did_not_send_the_capability_is_not_read
    daemon(%w[as4_byte mbgp_l2vpn_evpn])
    peer(evpn: false)
    send_spec(spec(3, '10.0.9.2'))
    sleep 1
    assert_equal(0, call('show.evpn')['total'])
    assert_nil(call('show.peers').first['families'])
  end

  def vtep_socket
    File.join(@dir, 'vtep4rd.sock')
  end

  def macvrf_daemon
    daemon(%w[as4_byte mbgp_l2vpn_evpn],
           'macvrfs' => [{ 'vni' => 100 }], 'evpn' => { 'vtep' => vtep_socket })
  end

  # docs/design/evpn.md, pull request 2: the routes lab 3's injector sends,
  # imported into MAC-VRF 100 and written into vtep4rd. The type 3 route
  # floods to 10.0.9.2, each type 2 route puts a MAC behind it, and a
  # withdrawal takes them away.
  def test_a_macvrf_writes_what_it_imports_into_vtep4rd
    @vtep = FakeVtep.new(vtep_socket)
    macvrf_daemon
    peer
    send_spec(spec(3, '10.0.9.2'))
    send_spec(spec(2, '02:00:00:99:00:00', 3))
    wait_for('the flood VTEP and three MACs') { @vtep.flood == ['10.0.9.2'] && @vtep.macs.size == 3 }
    assert_equal({ 'mac' => '02:00:00:99:00:01', 'type' => 'remote', 'vtep' => '10.0.9.2', 'origin' => 'api', 'seq' => 0 },
                 @vtep.macs['02:00:00:99:00:01'])
    row = call('show.macvrfs')['rows'].first
    assert_equal([100, '10.255.0.12:100', ['65000:100'], 'ok', ['10.0.9.2'], 3],
                 row.values_at('vni', 'rd', 'import', 'vtep_state', 'flood', 'macs_remote'))
    macs = call('show.macvrf', 'vni' => 100)['rows']
    assert_equal([['02:00:00:99:00:00', 'remote', '10.0.9.2']], macs.first(1).collect { |r| r.values_at('mac', 'place', 'vtep') })
    assert_equal([[100], true, nil], rows('route_type' => 3).find { |r| r['peer'] }.values_at('imported', 'valid', 'invalid'))
    assert_equal({ 'vtep' => vtep_socket, 'macvrfs' => 1, 'errors' => [] }, call('show.status')['evpn'])

    send_spec(spec(2, '02:00:00:99:00:00', 3), withdraw: true)
    wait_for('the MACs to go') { @vtep.macs.empty? }
    @peer.close
    @peer = nil
    wait_for('the flood VTEP to go with the session') { @vtep.flood.empty? }
  end

  # A vtep4rd that is not there yet: show.status says so, and the next
  # change after it comes finds it.
  def test_a_vtep4rd_that_starts_later
    macvrf_daemon
    peer
    send_spec(spec(3, '10.0.9.2'))
    wait_for('the error') { call('show.status')['evpn']['errors'].any? }
    assert_match(/\Avni 100: vtep4rd: .*No such file or directory/, call('show.status')['evpn']['errors'].first)
    assert_equal('down', call('show.macvrfs')['rows'].first['vtep_state'])
    @vtep = FakeVtep.new(vtep_socket)
    send_spec(spec(2, '02:00:00:99:00:00'))
    wait_for('both routes in vtep4rd') { @vtep.flood == ['10.0.9.2'] && @vtep.macs.size == 1 }
    assert_equal([], call('show.status')['evpn']['errors'])
  end

  # A vtep4rd that restarts loses what bgp4rd wrote. The next sync finds
  # the old connection dead, opens a new one and writes it all again.
  def test_a_vtep4rd_that_restarts
    @vtep = FakeVtep.new(vtep_socket)
    macvrf_daemon
    peer
    send_spec(spec(3, '10.0.9.2'))
    wait_for('the flood VTEP') { @vtep.flood == ['10.0.9.2'] }
    @vtep.stop
    @vtep = FakeVtep.new(vtep_socket)
    send_spec(spec(2, '02:00:00:99:00:00'))
    wait_for('the flood VTEP and the MAC, in the new vtep4rd', 5) { @vtep.flood == ['10.0.9.2'] && @vtep.macs.size == 1 }
  end

  def test_show_macvrf_wants_a_configured_vni
    @vtep = FakeVtep.new(vtep_socket)
    macvrf_daemon
    e = assert_raise(BGP::Daemon::Client::Error) { call('show.macvrf', 'vni' => 200) }
    assert_match('no MAC-VRF for VNI 200; this bgp4rd has 100', e.message)
  end

  # Hidden until configured: no evpn in show.status, no MAC-VRF columns.
  def test_without_macvrfs
    daemon(%w[as4_byte mbgp_l2vpn_evpn])
    assert_nil(call('show.status')['evpn'])
    assert_equal(0, call('show.macvrfs')['total'])
  end

  # The EVPN routes the library neighbor is sent: [type, mac, seq] for
  # each announced, [:withdrawn, type, mac] for each withdrawn, and the
  # UPDATEs themselves.
  def watch_sent
    @got = Queue.new
    got = @got
    @peer.add_observer(Class.new { define_method(:update) { |m| got << m if m.is_a?(BGP::Update) } }.new)
  end

  def sent_routes(updates)
    updates.flat_map do |u|
      pa = u.path_attribute
      if pa.has?(BGP::Mp_reach) && pa[BGP::Mp_reach].afi == 25
        mm = pa.has?(BGP::Extended_communities) && pa[BGP::Extended_communities].find_all(BGP::Mac_mobility).first
        pa[BGP::Mp_reach].nlris.collect { |n| r = n.route; [r.is_a?(BGP::Evpn::Mac_ip_advertisement) ? 2 : 3, (r.mac.to_s if r.respond_to?(:mac)), mm ? mm.sequence : nil] }
      elsif pa.has?(BGP::Mp_unreach) && pa[BGP::Mp_unreach].afi == 25
        pa[BGP::Mp_unreach].nlris.collect { |n| r = n.route; [:withdrawn, r.is_a?(BGP::Evpn::Mac_ip_advertisement) ? 2 : 3, (r.mac.to_s if r.respond_to?(:mac))] }
      else
        []
      end
    end
  end

  def wait_sent(what, want)
    seen = []
    @all_updates ||= []
    wait_for(what) do
      @all_updates << @got.pop until @got.empty?
      seen = sent_routes(@all_updates)
      want.all? { |w| seen.include?(w) }
    end
  rescue Test::Unit::AssertionFailedError
    flunk("#{what}: sent #{seen.inspect}")
  end

  # docs/design/evpn.md, pull request 3. A local MAC vtep4rd holds is
  # sent as type 2 beside the MAC-VRF's type 3. A route with a higher
  # sequence takes it away: ours is withdrawn and vtep4rd told. The host
  # heard on the port again, vtep4rd's event brings ours back, one
  # higher (RFC 7432 section 15).
  def test_a_local_mac_is_sent_and_moves
    h1 = '02:00:00:00:01:01'
    @vtep = FakeVtep.new(vtep_socket)
    @vtep.learn(h1, 'eth1')
    macvrf_daemon
    peer(watch: true)
    wait_sent('type 3 and type 2', [[3, nil, nil], [2, h1, nil]])
    u = @all_updates.find { |x| sent_routes([x]).include?([3, nil, nil]) }
    pmsi = u.path_attribute[BGP::Pmsi_tunnel].to_hash[:pmsi_tunnel]
    assert_equal(['ingress_replication', '10.255.0.12', 100], pmsi.values_at(:tunnel_type, :identifier, :label_bits).collect { |v| v.is_a?(Symbol) ? v.to_s : v })
    assert_equal(['65000:100'], u.path_attribute[BGP::Extended_communities].find_all(BGP::Route_target).collect { |rt| Array(rt.to_hash[:route_target]).join(':') })
    assert_equal(8, u.path_attribute[BGP::Extended_communities].find_all(BGP::Encapsulation).first.tunnel_type)
    local = rows.select { |r| r['reason'] == 'local' }
    assert_equal([[3, nil], [2, h1]], local.collect { |r| r.values_at('route_type', 'mac') }.sort_by { |t, _| -t })
    evpn = call('show.peers').first['families'].find { |f| f['family'] == 'evpn' }
    assert_equal(2, evpn['sent'])

    s = spec(2, h1)
    s['mac_mobility'] = 1
    send_spec(s)
    wait_sent('ours withdrawn', [[:withdrawn, 2, h1]])
    wait_for('vtep4rd to put h1 behind 10.0.9.2') { (m = @vtep.macs[h1]) && m['vtep'] == '10.0.9.2' && m['seq'] == 1 }

    @vtep.learn(h1, 'eth1')
    wait_sent('ours back, sequence 2', [[2, h1, 2]])
    moved = call('show.macvrf', 'vni' => 100)['rows'].find { |r| r['mac'] == h1 }
    assert_equal(['local', 2, 2], moved.values_at('place', 'seq', 'moves'))
  end

  def test_clear_duplicate_over_the_api
    @vtep = FakeVtep.new(vtep_socket)
    macvrf_daemon
    e = assert_raise(BGP::Daemon::Client::Error) { call('evpn.clear_duplicate', 'vni' => 100, 'mac' => '02:00:00:00:01:01') }
    assert_match('vni 100: 02:00:00:00:01:01 is not marked duplicate', e.message)
    e = assert_raise(BGP::Daemon::Client::Error) { call('evpn.clear_duplicate', 'mac' => '02:00:00:00:01:01') }
    assert_match('vni is required', e.message)
  end
end
