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
require 'socket'
require 'stringio'
require 'bgp/daemon/speaker'
require 'bgp/daemon/views'
require 'bgp/daemon/control'

# Graceful restart, RFC 4724 section 4.2's Receiving Speaker, through a
# real Speaker over loopback. A library Neighbor from 127.0.0.2 is the
# peer that restarts: its GR capability lists IPv4 unicast, and a stop
# of its own is a TCP close with no NOTIFICATION, which is a restart to
# bgp4rd. A second Neighbor, from 127.0.0.3, watches what bgp4rd
# advertises. docs/design/bgp-operations.md, section 3, pull request 3a.
class TestGracefulRestart < Test::Unit::TestCase

  class Catcher
    attr_reader :withdrawn, :announced
    def initialize ; @withdrawn = Queue.new ; @announced = Queue.new ; end
    def update(msg)
      return unless msg.is_a?(BGP::Update)
      msg.withdrawn.to_ary.each { |p| @withdrawn << p } if msg.withdrawn
      msg.nlri.to_ary.each { |p| @announced << p } if msg.nlri
    end
  end

  ROUTES = %w[10.1.0.0/16 10.2.0.0/16].freeze

  def free_port
    s = TCPServer.new('127.0.0.1', 0)
    s.addr[1]
  ensure
    s&.close
  end

  def setup
    Log.set_filename(StringIO.new)
    Log.level = Logger::WARN
  end

  def teardown
    [@peer, @watcher].each { |n| n&.stop rescue nil }
    @sp&.stop
  end

  def speaker(gr = { 'restart_time' => 0 })
    @port = free_port
    peer = { 'address' => '127.0.0.2', 'as' => 65_001 }
    peer['graceful_restart'] = gr if gr
    @sp = BGP::Daemon::Speaker.new('as' => 65_000, 'router_id' => '10.0.0.1', 'rib' => true,
                                   'listen_address' => '127.0.0.1', 'port' => @port, 'log_level' => 'error',
                                   'export' => { 'next_hops' => { 1 => '192.0.2.1' } },
                                   'neighbors' => [peer, { 'address' => '127.0.0.3', 'as' => 65_003 }]).start
    @events = Queue.new
    @sp.events.on_event { |e| @events << e if e.kind == :gr }
    @catcher = Catcher.new
    @watcher = dial('127.0.0.3', 65_003, nil)
    @watcher.add_observer(@catcher)
  end

  # A Neighbor from address, with a GR capability listing IPv4 unicast,
  # its F bit as given; nil for none.
  # n_bit: RFC 8538's N in its Restart Flags.
  def dial(address, as, f = true, restart_time: 120, n_bit: false)
    n = BGP::Neighbor.new(:my_as => as, :remote_addr => '127.0.0.1', :id => address)
    n.capability :as4_byte
    unless f.nil?
      gr = BGP::OPT_PARM::CAP::Graceful_restart.new(n_bit ? BGP::Daemon::GracefulRestart::N_BIT : 0, restart_time)
      gr.add(1, 1, f ? 0x80 : 0)
      n.capability gr
    end
    sock = Socket.tcp('127.0.0.1', @port, address)
    Thread.new { n.start(:session => sock, :timeout => 5) rescue nil }
    assert_equal(true, wait_until { n.is_established? }, "#{address} came up")
    n
  end

  def announce(n, prefixes)
    pa = BGP::Path_attribute.new(BGP::Origin.new(0), BGP::As_path.new(65_001), BGP::Next_hop.new('127.0.0.2'))
    n.send_message(BGP::Update.new(pa, BGP::Nlri.new(*prefixes)))
  end

  def end_of_rib(n) ; n.send_message(BGP::Update.end_of_rib_marker) ; end

  def wait_until(seconds = 5)
    deadline = Time.now + seconds
    until Time.now > deadline
      return true if yield
      sleep 0.05
    end
    false
  end

  # The peer's Adj-RIB-In as { prefix => stale reason or nil }.
  def adj_in
    BGP::Daemon::Views.new(@sp).adj_in('peer' => '127.0.0.2')[:rows].to_h { |r| [r[:prefix], r[:stale]] }
  end

  def gr_row ; BGP::Daemon::Views.new(@sp).peers.find { |r| r[:address] == '127.0.0.2' }[:graceful_restart] ; end

  def up_with_routes(f = true, **opts)
    @peer = dial('127.0.0.2', 65_001, f, **opts)
    @notified = Queue.new
    catcher = Object.new
    q = @notified
    catcher.define_singleton_method(:update) { |m| q << m if m.is_a?(BGP::Notification) }
    @peer.add_observer(catcher)
    announce(@peer, ROUTES)
    assert_equal(true, wait_until { adj_in.size == 2 }, 'two routes in')
    assert_equal(true, wait_until { @catcher.announced.size == 2 }, 'and sent on to the watcher')
  end

  # Section 4.2: kept stale through the restart, nothing withdrawn from
  # the watcher; back with F set, one route sent again and End-of-RIB:
  # the other goes.
  def test_a_restart_keeps_the_routes_and_end_of_rib_ends_it
    speaker
    up_with_routes
    @peer.stop
    assert_equal(true, wait_until { adj_in == ROUTES.to_h { |p| [p, 'restart'] } }, "kept stale: #{adj_in}")
    assert_equal('restarting', gr_row[:state])
    sleep 0.5
    assert_equal(0, @catcher.withdrawn.size, 'nothing withdrawn from the watcher while kept')
    @peer = dial('127.0.0.2', 65_001, true)
    assert_equal('helper', gr_row[:state])
    announce(@peer, ROUTES.first(1))
    assert_equal(true, wait_until { adj_in['10.1.0.0/16'].nil? && adj_in.key?('10.1.0.0/16') }, 'sent again, fresh')
    end_of_rib(@peer)
    assert_equal(true, wait_until { adj_in.keys == ROUTES.first(1) }, "the stale one went: #{adj_in}")
    assert_equal(true, wait_until { @catcher.withdrawn.size == 1 }, 'and was withdrawn from the watcher')
    assert_equal(nil, gr_row[:state])
  end

  # Section 4.2: back with F clear, or the family missing, and the stale
  # routes go at once.
  def test_back_with_f_clear_removes_them_at_once
    speaker
    up_with_routes
    @peer.stop
    assert_equal(true, wait_until { adj_in.values.uniq == ['restart'] })
    @peer = dial('127.0.0.2', 65_001, false)
    assert_equal(true, wait_until { adj_in.empty? }, "removed at once: #{adj_in}")
  end

  def test_back_with_no_capability_removes_them_at_once
    speaker
    up_with_routes
    @peer.stop
    assert_equal(true, wait_until { adj_in.values.uniq == ['restart'] })
    @peer = dial('127.0.0.2', 65_001, nil)
    assert_equal(true, wait_until { adj_in.empty? }, "removed at once: #{adj_in}")
  end

  # Section 4.2: "within the "Restart Time" that the peer advertised".
  def test_the_restart_time_removes_them
    speaker
    up_with_routes(true, restart_time: 1)
    @peer.stop
    assert_equal(true, wait_until { adj_in.values.uniq == ['restart'] })
    assert_equal(true, wait_until(5) { adj_in.empty? }, 'the Restart Time ran out')
    e = nil
    wait_until { (e = @events.pop(:timeout => 1)) && e.data[:purged] }
    assert_equal({ :purged => { :afi => 1, :safi => 1, :removed => 2 }, :reason => 'Restart Time' }, e.data)
  end

  # The stale timer: back, and no End-of-RIB.
  def test_the_stale_time_removes_them_without_end_of_rib
    speaker('stale_time' => 1)
    up_with_routes
    @peer.stop
    assert_equal(true, wait_until { adj_in.values.uniq == ['restart'] })
    @peer = dial('127.0.0.2', 65_001, true)
    assert_equal(true, wait_until(5) { adj_in.empty? }, 'stale_time ran out')
  end

  # Section 4: a NOTIFICATION takes the RFC 4271 path.
  def test_a_notification_flushes
    speaker
    up_with_routes
    @peer.send_message(BGP::Notification.new(6, 2))
    assert_equal(true, wait_until { adj_in.empty? }, 'flushed')
    assert_equal(true, wait_until { @catcher.withdrawn.size == 2 })
  end

  # Without the key, RFC 4271: flushed, though the peer advertised GR.
  def test_without_the_key_a_restart_flushes
    speaker(nil)
    up_with_routes
    @peer.stop
    assert_equal(true, wait_until { adj_in.empty? }, 'flushed')
    assert_equal(nil, BGP::Daemon::Views.new(@sp).peers.find { |r| r[:address] == '127.0.0.2' }[:graceful_restart])
  end

  # Section 4.2: "a route (from the peer) previously marked as stale
  # MUST be deleted" at the next restart.
  def test_consecutive_restarts_delete_what_was_stale
    speaker
    up_with_routes
    @peer.stop
    assert_equal(true, wait_until { adj_in.values.uniq == ['restart'] })
    @peer = dial('127.0.0.2', 65_001, true)
    announce(@peer, ROUTES.first(1))
    assert_equal(true, wait_until { adj_in['10.1.0.0/16'].nil? && adj_in.size == 2 })
    @peer.stop
    assert_equal(true, wait_until { adj_in == { '10.1.0.0/16' => 'restart' } }, "the twice stale one went: #{adj_in}")
  end

  # Sections 4.2 and 5: a new connection while the old session is up
  # closes the old one with no NOTIFICATION, and the routes are kept.
  def test_a_new_connection_replaces_the_session
    speaker
    up_with_routes
    notified = Queue.new
    @sp.events.on_event { |e| notified << e if e.kind == :notification }
    second = dial('127.0.0.2', 65_001, true)
    assert_equal(true, wait_until { !@peer.is_established? }, 'the old session ended')
    assert_equal(0, notified.size, 'with no NOTIFICATION')
    assert_equal(ROUTES.to_h { |p| [p, 'restart'] }, adj_in)
    old, @peer = @peer, second
    end_of_rib(@peer)
    assert_equal(true, wait_until { adj_in.empty? }, 'End-of-RIB, nothing sent again: they go')
    old.close rescue nil
  end

  # Every table that holds a peer's routes keeps its family through the
  # restart: VPN-IPv4, EVPN, BGP-LS and the unreachability SAFI, each
  # marked 'restart', and End-of-RIB for each ends it.
  def test_every_table_keeps_its_family
    fams = [[1, 128], [25, 70], [16388, 71], [1, 81]]
    @port = free_port
    caps = ['as4_byte', 'mbgp_ipv4_mpls_vpn_unicast', 'mbgp_l2vpn_evpn', { 'mbgp' => [16388, 71] }, { 'mbgp' => [1, 81] }]
    @sp = BGP::Daemon::Speaker.new('as' => 65_000, 'router_id' => '10.0.0.1', 'rib' => true,
                                   'listen_address' => '127.0.0.1', 'port' => @port, 'log_level' => 'error',
                                   'neighbors' => [{ 'address' => '127.0.0.2', 'as' => 65_001, 'capabilities' => caps,
                                                     'graceful_restart' => true }]).start
    dial_all = lambda do
      n = BGP::Neighbor.new(:my_as => 65_001, :remote_addr => '127.0.0.1', :id => '127.0.0.2')
      n.capability :as4_byte
      n.capability :mbgp_ipv4_mpls_vpn_unicast
      n.capability :mbgp_l2vpn_evpn
      n.capability BGP::OPT_PARM::CAP::Mbgp.new(16388, 71)
      n.capability BGP::OPT_PARM::CAP::Mbgp.new(1, 81)
      gr = BGP::OPT_PARM::CAP::Graceful_restart.new(0, 120)
      fams.each { |afi, safi| gr.add(afi, safi, 0x80) }
      n.capability gr
      Thread.new { n.start(:session => Socket.tcp('127.0.0.1', @port, '127.0.0.2'), :timeout => 5) rescue nil }
      assert_equal(true, wait_until { n.is_established? }, 'up')
      n
    end
    @peer = dial_all.()
    base = [BGP::Origin.new(0), BGP::As_path.new(65_001), BGP::Local_pref.new(100)]
    rt = BGP::Extended_communities.new(BGP::Route_target.new(65_000, 100))
    @peer.send_message(BGP::Update.new(BGP::Path_attribute.new(*base, rt,
      BGP::Mp_reach.new(:safi => 128, :nexthop => ['127.0.0.2'],
                        :nlris => [{ :prefix => '192.168.2.0/30', :rd => [65_000, 1], :label => 24_001 }]))))
    @peer.send_message(BGP::Update.new(BGP::Path_attribute.new(*base, rt,
      BGP::Mp_reach.new(:afi => 25, :safi => 70, :nexthop => ['127.0.0.2'],
                        :nlris => [{ :inclusive_multicast => { :rd => ['127.0.0.2', 100], :ethernet_tag_id => 0, :ip => '127.0.0.2' } }]))))
    ls = BGP::Link_state.new(:node => { :protocol_id => 1, :identifier => 0,
                                         :tlvs => [{ :local_node_descriptors => [{ :igp_router_id => '000000010101' }] }] })
    @peer.send_message(BGP::Update.new(BGP::Path_attribute.new(*base,
      BGP::Mp_reach.new(:afi => 16388, :safi => 71, :nexthop => ['127.0.0.2'], :nlris => [ls]))))
    @peer.send_message(BGP::Update.new(BGP::Path_attribute.new(*base, BGP::Fault.unreach_reach(BGP::Fault.unreach_nlri))))
    tables = lambda do
      [@sp.vpn_rows, @sp.evpn_rows, @sp.link_state_rows, @sp.unreachability_rows.select { |r| r['peer'] }]
        .collect { |rows| rows.collect { |r| r['stale'] } }
    end
    assert_equal(true, wait_until { tables.() == [[nil]] * 4 }, "one route in each: #{tables.()}")
    @peer.stop
    assert_equal(true, wait_until { tables.() == [['restart']] * 4 }, "each kept: #{tables.()}")
    @peer = dial_all.()
    fams.each { |afi, safi| @peer.send_message(BGP::Update.end_of_rib_marker(:afi => afi, :safi => safi)) }
    assert_equal(true, wait_until { tables.() == [[]] * 4 }, "each End-of-RIB ended its family: #{tables.()}")
  end

  # What bgp4rd advertises: the capability, R clear, no families.
  def test_the_capability_we_advertise
    speaker('restart_time' => 30)
    @peer = dial('127.0.0.2', 65_001, true)
    ours = BGP::Daemon::GracefulRestart.received(@peer.session_info.peer)
    assert_equal({ :restart_state => 0, :restart_time => 30, :families => [] }, ours)
  end

  # ---- RFC 8538, pull request 3b ------------------------------------

  N = { 'restart_time' => 0, 'notification' => true }.freeze

  # Section 4: with N exchanged, a NOTIFICATION other than a Hard Reset
  # keeps the routes, as a restart does.
  def test_under_n_a_graceful_cease_keeps_the_routes
    speaker(N)
    up_with_routes(true, n_bit: true)
    @peer.send_message(BGP::Notification.new(6, 6))
    assert_equal(true, wait_until { adj_in == ROUTES.to_h { |p| [p, 'restart'] } }, "kept: #{adj_in}")
    assert_equal(true, gr_row[:notification])
    sleep 0.5
    assert_equal(0, @catcher.withdrawn.size)
  end

  # Section 3.2: a Hard Reset ends it as RFC 4271 does.
  def test_under_n_a_hard_reset_flushes
    speaker(N)
    up_with_routes(true, n_bit: true)
    @peer.send_message(BGP::Notification.new(6, 9, "\x06\x02"))
    assert_equal(true, wait_until { adj_in.empty? }, "flushed: #{adj_in}")
    assert_equal(true, wait_until { @catcher.withdrawn.size == 2 })
  end

  # Section 4: "The BGP speaker generating the BGP NOTIFICATION message
  # MUST also follow the rules for the Receiving Speaker". peer.clear is
  # Administrative Reset, graceful by section 5.1.
  def test_under_n_our_peer_clear_keeps_the_routes
    speaker(N)
    up_with_routes(true, n_bit: true)
    r = BGP::Daemon::Control.new(@sp).peer_clear('peer' => '127.0.0.2')
    assert_equal('cease/administrative_reset', r[:notification])
    assert_equal(true, wait_until { adj_in == ROUTES.to_h { |p| [p, 'restart'] } }, "kept: #{adj_in}")
    n = @notified.pop(:timeout => 2)
    assert_equal([6, 4], n.to_hash.values_at(:code, :subcode))
  end

  # peer.stop is Administrative Shutdown, hard by section 5.1: a Hard
  # Reset carrying 6/2, and the routes flushed; peer.clear with hard too.
  def test_under_n_our_peer_stop_sends_a_hard_reset
    speaker(N)
    up_with_routes(true, n_bit: true)
    r = BGP::Daemon::Control.new(@sp).peer_stop('peer' => '127.0.0.2')
    assert_equal('cease/hard_reset/administrative_shutdown', r[:notification])
    n = @notified.pop(:timeout => 2)
    assert_equal([6, 9, "\x06\x02".b], n.to_hash.values_at(:code, :subcode, :data))
    assert_equal(true, wait_until { adj_in.empty? }, "flushed: #{adj_in}")
  end

  # hard: false keeps peer.stop graceful: 6/2 alone, and the routes kept.
  def test_under_n_a_graceful_peer_stop_keeps_the_routes
    speaker(N)
    up_with_routes(true, n_bit: true)
    r = BGP::Daemon::Control.new(@sp).peer_stop('peer' => '127.0.0.2', 'hard' => false)
    assert_equal('cease/administrative_shutdown', r[:notification])
    assert_equal(true, wait_until { adj_in == ROUTES.to_h { |p| [p, 'restart'] } }, "kept: #{adj_in}")
  end

  def test_under_n_a_hard_peer_clear_flushes
    speaker(N)
    up_with_routes(true, n_bit: true)
    r = BGP::Daemon::Control.new(@sp).peer_clear('peer' => '127.0.0.2', 'hard' => true)
    assert_equal('cease/hard_reset/administrative_reset', r[:notification])
    assert_equal(true, wait_until { adj_in.empty? }, "flushed: #{adj_in}")
  end

  # Section 4.1: with N, routes stale from one restart are kept at the
  # next.
  def test_under_n_consecutive_restarts_keep_what_was_stale
    speaker(N)
    up_with_routes(true, n_bit: true)
    @peer.stop
    assert_equal(true, wait_until { adj_in.values.uniq == ['restart'] })
    @peer = dial('127.0.0.2', 65_001, true, n_bit: true)
    @peer.stop
    sleep 0.5
    assert_equal(ROUTES.to_h { |p| [p, 'restart'] }, adj_in, 'both kept')
  end

  # N on our side only is not exchanged: a Cease flushes, as RFC 4724.
  def test_n_on_one_side_only_is_not_exchanged
    speaker(N)
    up_with_routes(true)
    @peer.send_message(BGP::Notification.new(6, 6))
    assert_equal(true, wait_until { adj_in.empty? }, "flushed: #{adj_in}")
    assert_equal(false, gr_row[:notification])
  end
end
