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
require 'bgp/daemon'

# BGP:: names are written out in full here, see Conventions in CLAUDE.md.
# A reflector, rr (10.255.0.2, AS 65000), for pe1 and pe2, its clients,
# and nc, a non-client: docs/design/l3vpn-pe.md, pull request 6.
class TestBgpDaemonVpnReflector < Test::Unit::TestCase

  # A session, as the reflector sees one.
  class Session
    attr_reader :address, :remote_as, :sent, :neighbor
    attr_accessor :up, :session_info, :vrf

    def initialize(address, remote_as: 65000, vpn6: false)
      @address, @remote_as = address, remote_as
      caps = [BGP::OPT_PARM::CAP::Mbgp.new(1, 128)]
      caps << BGP::OPT_PARM::CAP::Mbgp.new(2, 128) if vpn6
      @session_info = BGP::Neighbor::Capabilities.new(BGP::Open.new(4, 65000, 180, '10.255.0.2', *caps),
                                                      BGP::Open.new(4, remote_as, 180, address, *caps))
      @neighbor = Struct.new(:rmt_bgp_id).new(address)
      @up = true
      @sent = []
    end

    def established? ; @up ; end
    def ebgp? ; @remote_as != 65000 ; end
    def send_message(m) ; @sent << BGP::Update.new(m.encode) ; end

    # Each UPDATE as a receiving PE reads it: [:announce, rd, prefix,
    # labels, next hop, originator, cluster list, route targets] or
    # [:withdraw, rd, prefix].
    def read
      peer = BGP::Rib::Peer.new(:address => '10.255.0.2', :remote_as => 65000, :router_id => '10.255.0.2', :local_as => 65000)
      @sent.flat_map do |u|
        BGP::Rib::PeerAdapter.vpn_operations(u, peer).collect do |op, *a|
          next [op, a[0], a[1]] if op == :withdraw
          v = a.first
          r = v.route
          [op, v.rd, v.prefix, v.labels, r.next_hop, r.originator_id, r.cluster_list, v.route_targets]
        end
      end
    end
  end

  Speaker = Struct.new(:peers, :my_as)

  def setup
    @pe1 = Session.new('10.255.0.1')
    @pe2 = Session.new('10.255.0.3', vpn6: true)
    @nc = Session.new('10.255.0.9')
    @table = BGP::Rib::VpnTable.new(local_as: 65000, router_id: '10.255.0.2')
    export = BGP::Rib::Export.new(:local_as => 65000, :router_id => '10.255.0.2', :route_reflector => true,
                                  :clients => ['10.255.0.1', '10.255.0.3'])
    @rr = BGP::Daemon::VpnReflector.new(Speaker.new([@pe1, @pe2, @nc], 65000), @table, export)
  end

  # What a PE sends: its loopback as next hop, its label and its RT.
  def receive(from, prefix, rd:, label:, rt: [65000, 100], afi: 1, nh: from, attrs: [])
    pa = BGP::Path_attribute.new(BGP::Origin.new(0), BGP::As_path.new, BGP::Local_pref.new(100),
                                 BGP::Mp_reach.new(:afi => afi, :safi => 128, :nexthop => [nh],
                                                   :nlris => [{ :prefix => prefix, :rd => rd, :label => label }]),
                                 BGP::Extended_communities.new(BGP::Route_target.new(*rt)), *attrs)
    u = BGP::Update.new(BGP::Update.new(pa).encode)
    peer = BGP::Rib::Peer.new(:address => from, :remote_as => 65000, :router_id => from, :local_as => 65000)
    @table.apply(from, BGP::Rib::PeerAdapter.vpn_operations(u, peer))
  end

  # RFC 4456 section 6: a client's route goes to the other client and to
  # the non-client, not back. Section 8: ORIGINATOR_ID and CLUSTER_LIST.
  # RFC 4271 section 5.1.3: next hop, RD and label as they came.
  def test_a_clients_route_is_reflected_to_every_other_peer
    receive('10.255.0.1', '192.168.1.0/24', rd: [65000, 1], label: 24000)
    @rr.refresh
    want = [[:announce, '65000:1', '192.168.1.0/24', [24000], '10.255.0.1', '10.255.0.1', ['10.255.0.2'], ['65000:100']]]
    assert_equal(want, @pe2.read)
    assert_equal(want, @nc.read)
    assert_equal([], @pe1.sent, 'not back to the PE that sent it')
  end

  # Per peer and per family, for show.peers.
  def test_sent_counts_are_per_peer_and_per_family
    receive('10.255.0.1', '192.168.1.0/24', rd: [65000, 1], label: 24000)
    receive('10.255.0.1', '2001:db8:1::/64', rd: [65000, 1], label: 24000, afi: 2, nh: '::ffff:10.255.0.1')
    @rr.refresh
    assert_equal({ 'vpn-ipv4' => 1, 'vpn-ipv6' => 1 }, @rr.sent_counts('10.255.0.3'))
    assert_equal({ 'vpn-ipv4' => 1 }, @rr.sent_counts('10.255.0.9'))
    assert_equal({}, @rr.sent_counts('10.255.0.1'))
  end

  # A non-client's route goes to clients only.
  def test_a_non_clients_route_goes_to_clients_only
    receive('10.255.0.9', '192.168.9.0/24', rd: [65000, 9], label: 24900)
    @rr.refresh
    assert_equal(['192.168.9.0/24'], @pe1.read.collect { |o| o[2] })
    assert_equal(['192.168.9.0/24'], @pe2.read.collect { |o| o[2] })
    assert_equal([], @nc.sent)
  end

  # The reflector keeps every route: no Route Target filter (RFC 4364
  # section 4.3.3, the second way).
  def test_every_route_target_is_reflected
    receive('10.255.0.1', '192.168.1.0/24', rd: [65000, 1], label: 24000, rt: [65000, 100])
    receive('10.255.0.1', '192.168.1.0/24', rd: [65000, 2], label: 24001, rt: [65000, 200])
    @rr.refresh
    assert_equal([['65000:1', ['65000:100']], ['65000:2', ['65000:200']]],
                 @pe2.read.collect { |o| [o[1], o[7]] }.sort)
  end

  # RFC 4659: VPN-IPv6 only to a session that negotiated it.
  def test_vpn_ipv6_only_where_it_was_negotiated
    receive('10.255.0.1', '2001:db8:1::/64', rd: [65000, 1], label: 24000, afi: 2, nh: '::ffff:10.255.0.1')
    @rr.refresh
    assert_equal([[:announce, '65000:1', '2001:db8:1::/64', [24000], '::ffff:10.255.0.1']], @pe2.read.collect { |o| o.first(5) })
    assert_equal([], @nc.sent)
  end

  # RFC 8277 section 2.4: a withdrawal's label field is 0x800000.
  def test_a_withdrawn_route_is_withdrawn
    receive('10.255.0.1', '192.168.1.0/24', rd: [65000, 1], label: 24000)
    @rr.refresh
    @pe2.sent.clear
    @table.apply('10.255.0.1', [[:withdraw, '65000:1', '192.168.1.0/24', nil]])
    @rr.refresh
    assert_equal([[:withdraw, '65000:1', '192.168.1.0/24']], @pe2.read)
    assert_match(/800000/, @pe2.sent.first.path_attribute[BGP::Mp_unreach].nlris.first.encode.unpack1('H*'))
    @pe2.sent.clear
    @rr.refresh
    assert_equal([], @pe2.sent, 'nothing changed, nothing sent')
  end

  def test_a_session_coming_up_gets_everything
    receive('10.255.0.1', '192.168.1.0/24', rd: [65000, 1], label: 24000)
    @rr.refresh
    @pe2.up = false
    @rr.refresh
    @pe2.up = true
    @pe2.sent.clear
    @rr.session_up(@pe2)
    @rr.refresh
    assert_equal(['192.168.1.0/24'], @pe2.read.collect { |o| o[2] })
  end

  # drain answers once a refresh has run after it, so what session_up
  # asked for has been sent: what Speaker#send_end_of_rib waits on
  # before its markers. With no worker it answers at once.
  def test_drain_waits_for_the_refresh_session_up_asked_for
    assert_equal(true, @rr.drain(1), 'no worker, nothing to wait for')
    receive('10.255.0.1', '192.168.1.0/24', rd: [65000, 1], label: 24000)
    @rr.start
    @rr.session_up(@pe2)
    assert_equal(true, @rr.drain(5))
    assert_equal(['192.168.1.0/24'], @pe2.read.collect { |o| o[2] })
    @rr.stop
    assert_equal(true, @rr.drain(1), 'a stopped worker, nothing to wait for')
  end

  # A route refresh for one VPN family: what the peer had of that AFI
  # goes again on the next refresh, and nothing of the other.
  def test_resend_sends_one_family_again
    receive('10.255.0.1', '192.168.1.0/24', rd: [65000, 1], label: 24000)
    receive('10.255.0.1', '2001:db8:1::/48', rd: [65000, 1], label: 24001, afi: 2, nh: '::ffff:10.255.0.1')
    @rr.refresh
    @pe2.sent.clear
    @rr.resend(@pe2, 1)
    @rr.refresh
    assert_equal(['192.168.1.0/24'], @pe2.read.collect { |o| o[2] })
  end

  # A CE in a VRF and an external peer get none of it.
  def test_ces_and_external_peers_get_nothing
    @nc.vrf = 'A'
    ext = Session.new('192.0.2.9', remote_as: 65009)
    @rr.instance_variable_get(:@speaker).peers << ext
    receive('10.255.0.1', '192.168.1.0/24', rd: [65000, 1], label: 24000)
    @rr.refresh
    assert_equal([], @nc.sent)
    assert_equal([], ext.sent)
  end

  # RFC 4456 section 8: a route carrying our CLUSTER_ID looped back. The
  # VPN table's decision process does not choose it, so it is not sent.
  def test_a_looped_route_is_not_reflected
    receive('10.255.0.1', '192.168.1.0/24', rd: [65000, 1], label: 24000,
            attrs: [BGP::Originator_id.new('10.255.0.7'), BGP::Cluster_list.new('10.255.0.2')])
    @rr.refresh
    assert_equal([], @pe2.sent)
  end

  # Export calls, as the peer address of each, from here on.
  def count_exports
    calls = []
    export = @rr.instance_variable_get(:@export)
    export.define_singleton_method(:for) do |route, peer, **kw|
      calls << peer.address
      super(route, peer, **kw)
    end
    calls
  end

  # A refresh exports only the winners that changed since the last one,
  # as the EVPN reflector does. A poke comes with each UPDATE received.
  def test_a_refresh_exports_only_what_changed
    calls = count_exports
    receive('10.255.0.1', '192.168.1.0/24', rd: [65000, 1], label: 24000)
    receive('10.255.0.1', '192.168.2.0/24', rd: [65000, 1], label: 24000)
    @rr.refresh
    assert_equal((%w[10.255.0.1 10.255.0.3 10.255.0.9] * 2).sort, calls.sort, 'each route to each peer, pe1 refused')
    calls.clear
    @pe2.sent.clear
    @rr.refresh
    assert_equal([[], []], [calls, @pe2.sent], 'nothing changed: nothing exported, nothing sent')
    receive('10.255.0.1', '192.168.2.0/24', rd: [65000, 1], label: 24002)
    @rr.refresh
    assert_equal(%w[10.255.0.1 10.255.0.3 10.255.0.9], calls.sort, 'the changed route only')
    assert_equal([['192.168.2.0/24', [24002]]], @pe2.read.collect { |o| [o[2], o[3]] })
  end

  # A route refused to a peer is not exported to it again, and a new
  # winner for the key is: pe1's own route was refused to pe1, and nc's
  # for the same key, once pe1 withdraws, goes to pe1.
  def test_a_refusal_is_kept_until_the_winner_changes
    calls = count_exports
    receive('10.255.0.1', '192.168.1.0/24', rd: [65000, 1], label: 24000)
    @rr.refresh
    calls.clear
    @rr.refresh
    assert_equal([], calls)
    receive('10.255.0.9', '192.168.1.0/24', rd: [65000, 1], label: 24900)
    @table.apply('10.255.0.1', [[:withdraw, '65000:1', '192.168.1.0/24', nil]])
    @pe1.sent.clear
    @rr.refresh
    assert_equal([['192.168.1.0/24', [24900], '10.255.0.9']], @pe1.read.collect { |o| [o[2], o[3], o[4]] })
  end

  # A session that comes up again is exported everything again, what was
  # refused to it before included.
  def test_a_session_coming_up_is_exported_everything_again
    calls = count_exports
    receive('10.255.0.1', '192.168.1.0/24', rd: [65000, 1], label: 24000)
    @rr.refresh
    calls.clear
    @rr.session_up(@pe1)
    @rr.session_up(@pe2)
    @rr.refresh
    assert_equal(%w[10.255.0.1 10.255.0.3], calls.sort)
    assert_equal(1, @rr.size('10.255.0.3'))
  end
end
