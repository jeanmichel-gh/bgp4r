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
require 'bgp/daemon/api'

# bgp4rd's rpki: key: its checks, the VRPs chosen from the caches by
# preference, the states on route rows, and the events. The caches are
# fed by hand, with no socket. docs/design/bgp-operations.md 7c.
class TestDaemonRpki < Test::Unit::TestCase
  include BGP

  CACHES = [{ 'address' => '127.0.0.1', 'port' => 3323, 'preference' => 1 },
            { 'address' => '127.0.0.2', 'port' => 3323, 'preference' => 2 }].freeze

  def speaker(rpki = { 'caches' => CACHES })
    Daemon::Speaker.new('as' => 65_000, 'router_id' => '10.0.0.1', 'log_level' => 'error',
                        'neighbors' => [], 'rpki' => rpki)
  end

  # A cache's whole answer to a Reset Query, given its VRPs.
  def load(client, sid, *vrps)
    client.connected
    out = [Rtr::Cache_response.new(sid), *vrps.collect { |p, max, asn| Rtr::Ipv4_prefix.new(p, max, asn) },
           Rtr::End_of_data.new(sid, 1)]
    out.each { |pdu| client.receive(pdu.encode) }
  end

  def announce(sp, prefix, *path)
    peer = Rib::Peer.new(address: '10.0.0.2', remote_as: 65_001, router_id: '2.2.2.2', local_as: 65_000)
    pa = Path_attribute.new(Origin.new(0), Next_hop.new('10.0.0.2'), As_path.new(*path))
    sp.rib.announce(Rib::Route.new(prefix, pa, peer))
  end

  def test_the_key_is_checked
    [nil, [], { 'caches' => [] }, { 'caches' => [{ 'port' => 1 }] }, { 'caches' => CACHES, 'cache' => 1 },
     { 'caches' => CACHES, 'invalid' => 'drop' }, { 'caches' => CACHES, 'mark_ibgp' => 'yes' },
     { 'caches' => [CACHES[0], CACHES[0]] }].each do |bad|
      assert_raise(ArgumentError, bad.inspect) { Daemon::Rpki.check(bad) }
    end
    assert_equal('accept', speaker('caches' => CACHES, 'invalid' => 'accept', 'mark_ibgp' => false).rpki.invalid)
    %w[prefer_less reject].each { |mode| assert_equal(mode, speaker('caches' => CACHES, 'invalid' => mode).rpki.invalid) }
    assert_equal([true, false], [speaker('caches' => CACHES, 'mark_ibgp' => true).rpki.mark_ibgp?, speaker.rpki.mark_ibgp?])
    assert_raise(ArgumentError) { speaker('caches' => 'x') }
    assert_nil(Daemon::Speaker.new('as' => 1, 'router_id' => '1.1.1.1', 'neighbors' => []).rpki)
  end

  # An rpki: key alone is a speaker with a table, whose routes have a
  # state.
  def test_rpki_makes_a_table
    sp = speaker
    assert(sp.rib)
    assert_same(sp.rpki, sp.rib.validator)
  end

  # RFC 8210 sections 4 and 10: the most preferred caches with data; the
  # next when those have none.
  def test_the_vrps_come_from_the_preferred_caches
    sp = speaker
    one, two = sp.rpki.clients
    load(two, 2, ['10.0.0.0/8', 8, 2])
    assert_equal([['10.0.0.0', 8, 8, 2]], sp.rpki.vrps.to_a, 'only the second has data')
    load(one, 1, ['10.0.0.0/8', 8, 1])
    assert_equal([['10.0.0.0', 8, 8, 1]], sp.rpki.vrps.to_a, 'the first, preferred')
    three = Daemon::Rpki.new(sp, 'caches' => [CACHES[0], CACHES[1].merge('preference' => 1)])
    a, b = three.clients
    load(a, 1, ['10.0.0.0/8', 8, 1])
    load(b, 2, ['10.0.0.0/8', 8, 2])
    assert_equal(2, three.vrps.size, 'two at one preference: both')
    n = sp.events.seq
    two.receive(Rtr::Serial_notify.new(2, 2).encode)
    [Rtr::Cache_response.new(2), Rtr::Ipv4_prefix.new('172.16.0.0/12', 12, 2), Rtr::End_of_data.new(2, 2)].each { |p| two.receive(p.encode) }
    assert_equal(%w[synced], sp.events.since(n).select { |e| e.kind == :rpki }.collect { |e| e.data[:event] },
                 'the second changed, the VRPs used did not')
  end

  def test_the_states_on_the_rows
    sp = speaker
    announce(sp, '192.0.2.0/24', 65_001)
    announce(sp, '198.51.100.0/24', 65_001, 65_099)
    announce(sp, '203.0.113.0/24', 65_001)
    load(sp.rpki.clients.first, 1, ['192.0.2.0/24', 24, 65_001], ['198.51.100.0/24', 24, 65_001])
    v = Daemon::Views.new(sp)
    assert_equal({ '192.0.2.0/24' => 'valid', '198.51.100.0/24' => 'invalid', '203.0.113.0/24' => 'notfound' },
                 v.routes[:rows].to_h { |r| [r[:prefix], r[:validation]] })
    assert_equal('invalid', v.rib('prefix' => '198.51.100.0/24')[:rows].first[:paths].first[:validation])
    assert_equal({ :caches => 2, :synced => 1, :vrps_v4 => 2, :vrps_v6 => 0, :invalid => 'accept', :mark_ibgp => false },
                 v.status[:rpki])
    assert_equal(['127.0.0.1', 'up', 1, 2], v.rpki[:rows].first.values_at(:address, :state, :serial, :vrps_v4))
    assert_equal(2, v.rpki[:total])
    assert_equal({ :prefix => '192.0.2.0/24', :max_length => 24, :asn => 65_001 }, v.rpki_vrps[:rows].first)
    assert_equal(1, v.rpki_vrps('limit' => 1)[:rows].size)
    assert(%w[show.rpki show.rpki_vrps].all? { |m| Daemon::Api::METHODS.key?(m) })
  end

  # RFC 6811 section 2: other families SHOULD be NotFound; the rows say
  # nobody looked.
  def test_other_families_are_not_validated
    v = Daemon::Views.new(speaker)
    assert_equal([{ 'rd' => '1:1', 'validation' => 'notfound', 'validated' => false }], v.not_validated([{ 'rd' => '1:1' }]))
    sp = speaker
    def sp.vpn_rows ; [{ 'rd' => '1:1' }] ; end
    def sp.evpn_rows ; [{ 'rd' => '1:2' }] ; end
    def sp.vrf_route_rows(_vrf) ; [{ 'rd' => '1:3' }] ; end
    v = Daemon::Views.new(sp)
    [v.vpn, v.evpn, v.vrf].each { |page| assert_equal([false, 'notfound'], page[:rows].first.values_at('validated', 'validation')) }
    plain = Daemon::Views.new(Daemon::Speaker.new('as' => 1, 'router_id' => '1.1.1.1', 'neighbors' => [], 'rib' => true))
    assert_equal([{ 'rd' => '1:1' }], plain.not_validated([{ 'rd' => '1:1' }]))
    assert_equal({}, plain.rpki_status)
    assert_equal([], plain.rpki[:rows])
    assert_equal([], plain.rpki_vrps[:rows])
    assert_equal(nil, plain.routes[:rows].first&.dig(:validation))
  end

  # RFC 6811 section 4: a VRP change, and the routes it moved.
  def test_the_events
    sp = speaker
    announce(sp, '192.0.2.0/24', 65_001)
    announce(sp, '10.0.0.0/8', 65_001)
    client = sp.rpki.clients.first
    load(client, 1, ['192.0.2.0/24', 24, 65_002])
    ev = sp.events.since.select { |e| e.kind == :rpki }.collect(&:data)
    assert_equal(%w[connected up synced vrps routes], ev.collect { |d| d[:event] })
    assert_equal({ :event => 'routes', :changed => 1,
                   :routes => [{ :prefix => '192.0.2.0/24', :from => '10.0.0.2', :was => 'notfound', :now => 'invalid' }] }, ev.last)
    assert_equal({ :event => 'vrps', :vrps => 1, :added => 1, :removed => 0 }, ev[-2])
    n = sp.events.seq
    client.receive(Rtr::Serial_notify.new(1, 2).encode)
    [Rtr::Cache_response.new(1), Rtr::Ipv4_prefix.new('172.16.0.0/12', 12, 1), Rtr::End_of_data.new(1, 2)].each { |p| client.receive(p.encode) }
    ev = sp.events.since(n).select { |e| e.kind == :rpki }.collect { |e| e.data[:event] }
    assert_equal(%w[synced vrps], ev, 'a VRP that covers no route moves none')
    n = sp.events.seq
    client.receive(Rtr::Serial_notify.new(1, 3).encode)
    [Rtr::Cache_response.new(1), Rtr::Ipv4_prefix.new('192.0.2.0/24', 24, 65_003), Rtr::End_of_data.new(1, 3)].each { |p| client.receive(p.encode) }
    ev = sp.events.since(n).select { |e| e.kind == :rpki }.collect { |e| e.data[:event] }
    assert_equal(%w[synced vrps], ev, 'a VRP that covers a route and leaves it Invalid moves none')
  end

  # RFC 6811 section 4: a VRP change decides the prefixes again, so
  # prefer_less and reject follow it. LOCAL_PREF would pick 10.0.0.4.
  def test_a_vrp_change_decides_again
    { 'prefer_less' => '10.0.0.2', 'reject' => '10.0.0.2' }.each do |mode, after|
      sp = speaker('caches' => CACHES, 'invalid' => mode)
      ext = Rib::Peer.new(address: '10.0.0.2', remote_as: 65_001, router_id: '2.2.2.2', local_as: 65_000)
      int = Rib::Peer.new(address: '10.0.0.4', remote_as: 65_000, router_id: '4.4.4.4', local_as: 65_000)
      sp.rib.announce(Rib::Route.new('192.0.2.0/24', Path_attribute.new(Origin.new(0), Next_hop.new('10.0.0.2'), As_path.new(65_001)), ext))
      sp.rib.announce(Rib::Route.new('192.0.2.0/24', Path_attribute.new(Origin.new(0), Next_hop.new('10.0.0.4'), As_path.new(65_009),
                                                                        Local_pref.new(300)), int))
      assert_equal('10.0.0.4', sp.rib.best('192.0.2.0/24').peer.address, "#{mode}: no VRPs, all NotFound")
      client = sp.rpki.clients.first
      load(client, 1, ['192.0.2.0/24', 24, 65_001])
      assert_equal(after, sp.rib.best('192.0.2.0/24').peer.address, "#{mode}: 65009 is Invalid")
      lost = Daemon::Views.new(sp).rib('prefix' => '192.0.2.0/24')[:rows].first[:paths].last
      assert_equal(mode == 'reject' ? :rpki_reject : :rpki_invalid, lost[:lost_at])
      client.receive(Rtr::Serial_notify.new(1, 2).encode)
      [Rtr::Cache_response.new(1), Rtr::Ipv4_prefix.new('192.0.2.0/24', 24, 65_001, false), Rtr::End_of_data.new(1, 2)].each { |p| client.receive(p.encode) }
      assert_equal('10.0.0.4', sp.rib.best('192.0.2.0/24').peer.address, "#{mode}: the VRP withdrawn, it is back")
    end
  end

  # mark_ibgp: a VRP change sends internal peers again the prefixes
  # whose best route stayed and changed state; the Router sends those
  # whose best changed. A failure is logged, and the rest still go.
  def test_mark_ibgp_resends
    [true, false].each do |mark|
      logged = []
      sp = Daemon::Speaker.new('as' => 65_000, 'router_id' => '10.0.0.1', 'log_level' => 'error', 'neighbors' => [],
                               'rpki' => { 'caches' => CACHES, 'invalid' => 'reject', 'mark_ibgp' => mark })
      sp.rpki.instance_variable_set(:@logger, ->(level, message) { logged << [level, message] })
      peers = [['10.0.0.4', 65_000], ['10.0.0.2', 65_001], ['10.0.0.5', 65_000]].collect do |a, as|
        Rib::Peer.new(address: a, remote_as: as, router_id: a, local_as: 65_000)
      end
      sent = []
      router = Struct.new(:peers).new(peers)
      sp.rib.define_singleton_method(:router) { router }
      sp.rib.define_singleton_method(:resend) do |address, prefixes|
        sent << [address, prefixes]
        raise Timeout::Error, 'no answer' if address == '10.0.0.4'
      end
      announce(sp, '192.0.2.0/24', 65_001)
      announce(sp, '198.51.100.0/24', 65_001)
      load(sp.rpki.clients.first, 1, ['192.0.2.0/24', 24, 65_001], ['198.51.100.0/24', 24, 65_009])
      if mark
        assert_equal([['10.0.0.4', ['192.0.2.0/24']], ['10.0.0.5', ['192.0.2.0/24']]], sent,
                     'internal peers only, and not the prefix reject withdrew')
        assert_equal([[:warn, 'bgp4r: rpki: resend to 10.0.0.4: no answer']], logged)
      else
        assert_equal([], sent)
      end
    end
    sp = speaker('caches' => CACHES, 'mark_ibgp' => true)
    announce(sp, '192.0.2.0/24', 65_001)
    load(sp.rpki.clients.first, 1, ['192.0.2.0/24', 24, 65_001])
    assert_equal('valid', sp.rib.validation(sp.rib.best('192.0.2.0/24')), 'no Router: nothing to send')
  end

  # The event names ten routes, and counts them all.
  def test_the_event_names_ten
    sp = speaker
    12.times { |i| announce(sp, "10.#{i}.0.0/16", 65_001) }
    load(sp.rpki.clients.first, 1, ['10.0.0.0/8', 16, 65_002])
    ev = sp.events.since.select { |e| e.kind == :rpki }.last.data
    assert_equal([12, 10], [ev[:changed], ev[:routes].size])
  end
end
