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
# A reflector, s1 (10.255.0.2, AS 65000), for l1 and l2, its clients,
# and nc, a non-client: docs/design/evpn.md, pull request 4.
class TestBgpDaemonEvpnReflector < Test::Unit::TestCase

  # A session, as the reflector sees one.
  class Session
    attr_reader :address, :remote_as, :sent, :neighbor
    attr_accessor :up, :session_info, :vrf

    def initialize(address, remote_as: 65000, evpn: true)
      @address, @remote_as = address, remote_as
      caps = [BGP::OPT_PARM::CAP::Mbgp.new(1, 1)]
      caps << BGP::OPT_PARM::CAP::Mbgp.new(25, 70) if evpn
      @session_info = BGP::Neighbor::Capabilities.new(BGP::Open.new(4, 65000, 180, '10.255.0.2', *caps),
                                                      BGP::Open.new(4, remote_as, 180, address, *caps))
      @neighbor = Struct.new(:rmt_bgp_id).new(address)
      @up = true
      @sent = []
    end

    def established? ; @up ; end
    def ebgp? ; @remote_as != 65000 ; end
    def send_message(m) ; @sent << BGP::Update.new(m.encode) ; end

    # Each UPDATE as a receiving leaf reads it: [:announce, key, next
    # hop, vni, originator id, cluster list, route targets, encap, seq,
    # pmsi, path id] or [:withdraw, key].
    def read
      peer = BGP::Rib::Peer.new(:address => '10.255.0.2', :remote_as => 65000, :router_id => '10.255.0.2', :local_as => 65000)
      @sent.flat_map do |u|
        BGP::Rib::PeerAdapter.evpn_operations(u, peer).collect do |op, a|
          next [op, a[0..-2]] if op == :withdraw
          r = a.route
          [op, a.decision_key, r.next_hop, a.vni, r.originator_id, r.cluster_list, a.route_targets, a.encap,
           (a.mobility if a.route_type == 2), (a.pmsi_row if a.route_type == 3), a.path_id]
        end
      end
    end
  end

  Speaker = Struct.new(:peers, :my_as)

  def setup
    @l1 = Session.new('10.255.0.11')
    @l2 = Session.new('10.255.0.12')
    @nc = Session.new('10.255.0.9')
    @table = BGP::Rib::EvpnTable.new(local_as: 65000, router_id: '10.255.0.2')
    export = BGP::Rib::Export.new(:local_as => 65000, :router_id => '10.255.0.2', :route_reflector => true,
                                  :clients => ['10.255.0.11', '10.255.0.12'])
    @log = []
    @rr = BGP::Daemon::EvpnReflector.new(Speaker.new([@l1, @l2, @nc], 65000), @table, export,
                                         logger: ->(level, msg) { @log << [level, msg] })
  end

  # What a leaf sends, as EvpnExporter builds it: its loopback as next
  # hop and PMSI Tunnel identifier, the VNI in Label1 or the PMSI label,
  # its RT, VXLAN, and MAC Mobility when given.
  def receive(from, type, vni: 100, rd: [from, vni], mac: '00:00:00:00:00:02', seq: nil, rt: [65000, 100], attrs: [],
              path_id: nil)
    nlri = if type == 3
             { :inclusive_multicast => { :rd => rd, :ethernet_tag_id => 0, :ip => from } }
           else
             { :mac_ip_advertisement => { :rd => rd, :ethernet_tag_id => 0, :mac => mac,
                                          :label1 => { :label => vni >> 4, :exp => (vni >> 1) & 7, :bottom => vni & 1 } } }
           end
    nlri[:path_id] = path_id if path_id
    ecs = [BGP::Route_target.new(*rt), BGP::Encapsulation.new(:vxlan)]
    ecs << BGP::Mac_mobility.new(sequence: seq) if seq
    pa = BGP::Path_attribute.new(BGP::Origin.new(0), BGP::As_path.new, BGP::Local_pref.new(100),
                                 BGP::Mp_reach.new(:afi => 25, :safi => 70, :nexthop => [from], :nlris => [nlri]),
                                 BGP::Extended_communities.new(*ecs), *attrs)
    if type == 3
      pa << BGP::Pmsi_tunnel.new(:tunnel_type => :ingress_replication, :identifier => from, :label_bits => vni)
    end
    # Read back from the wire, as a session reads it; a Path Identifier
    # needs ADD-PATH to parse, so that route is kept as built.
    u = path_id ? BGP::Update.new(pa) : BGP::Update.new(BGP::Update.new(pa).encode)
    peer = BGP::Rib::Peer.new(:address => from, :remote_as => 65000, :router_id => from, :local_as => 65000)
    ops = BGP::Rib::PeerAdapter.evpn_operations(u, peer)
    assert_not_empty(ops)
    @table.apply(from, ops)
  end

  # RFC 4456 section 6: a client's route goes to the other client and to
  # the non-client, not back. Section 8: ORIGINATOR_ID and CLUSTER_LIST.
  # The next hop, the VNI, the PMSI Tunnel and the communities as they
  # came, so l2 floods to l1 itself.
  def test_a_clients_type_3_route_is_reflected_to_every_other_peer
    receive('10.255.0.11', 3)
    @rr.refresh
    want = [[:announce, ['10.255.0.11:100', 3, 0, '10.255.0.11'], '10.255.0.11', 100, '10.255.0.11', ['10.255.0.2'],
             ['65000:100'], 'VXLAN', nil, { 'type' => 'ingress_replication', 'id' => '10.255.0.11' }, nil]]
    assert_equal(want, @l2.read)
    assert_equal(want, @nc.read)
    assert_equal([], @l1.sent, 'not back to the leaf that sent it')
  end

  # Type 2 keeps its MAC Mobility sequence (RFC 7432 section 15: the
  # leaves decide on it) and its Label1.
  def test_a_type_2_route_keeps_its_vni_and_sequence
    receive('10.255.0.12', 2, vni: 4_000_001, rd: ['10.255.0.12', 1], seq: 7)
    @rr.refresh
    want = [[:announce, ['10.255.0.12:1', 2, 0, '00:00:00:00:00:02', nil], '10.255.0.12', 4_000_001,
             '10.255.0.12', ['10.255.0.2'], ['65000:100'], 'VXLAN', [7, false], nil, nil]]
    assert_equal(want, @l1.read)
  end

  # A non-client's route goes to clients only.
  def test_a_non_clients_route_goes_to_clients_only
    receive('10.255.0.9', 3)
    @rr.refresh
    assert_equal(1, @l1.read.size)
    assert_equal(1, @l2.read.size)
    assert_equal([], @nc.sent)
  end

  # The table keeps every route, so the reflector sends them all: no
  # Route Target filter.
  def test_every_route_target_is_reflected
    receive('10.255.0.11', 3, vni: 100, rt: [65000, 100])
    receive('10.255.0.11', 3, vni: 200, rt: [65000, 200])
    @rr.refresh
    assert_equal([['65000:100'], ['65000:200']], @l2.read.collect { |o| o[6] }.sort)
  end

  # Only to a session whose two OPENs carried L2VPN EVPN.
  def test_only_to_a_session_that_negotiated_evpn
    @nc.session_info = Session.new('10.255.0.9', evpn: false).session_info
    receive('10.255.0.11', 3)
    @rr.refresh
    assert_equal([], @nc.sent)
    assert_equal(1, @l2.read.size)
  end

  # A route that came with a Path Identifier goes on without one.
  def test_the_path_identifier_is_not_sent_on
    receive('10.255.0.11', 2, path_id: 5)
    assert_equal([5], @table.winners.collect(&:path_id))
    @rr.refresh
    assert_equal([nil], @l2.read.collect(&:last))
  end

  # The leaf withdraws: so does the reflector. Then nothing more.
  def test_a_withdrawn_route_is_withdrawn
    receive('10.255.0.11', 2)
    @rr.refresh
    @l2.sent.clear
    @table.apply('10.255.0.11', [[:withdraw, ['10.255.0.11:100', 2, 0, '00:00:00:00:00:02', nil, nil]]])
    @rr.refresh
    assert_equal([[:withdraw, ['10.255.0.11:100', 2, 0, '00:00:00:00:00:02', nil]]], @l2.read)
    @l2.sent.clear
    @rr.refresh
    assert_equal([], @l2.sent, 'nothing changed, nothing sent')
  end

  # A new sequence is a changed route, sent again.
  def test_a_changed_route_is_sent_again
    receive('10.255.0.11', 2, seq: 1)
    @rr.refresh
    @l2.sent.clear
    receive('10.255.0.11', 2, seq: 2)
    @rr.refresh
    assert_equal([[2, false]], @l2.read.collect { |o| o[8] })
    @l2.sent.clear
    @rr.refresh
    assert_equal([], @l2.sent, 'nothing changed, nothing sent')
  end

  def test_a_session_coming_up_gets_everything
    receive('10.255.0.11', 3)
    @rr.refresh
    @l2.up = false
    @rr.refresh
    assert_equal(0, @rr.size('10.255.0.12'), 'a session that went down was sent nothing')
    @l2.up = true
    @l2.sent.clear
    @rr.session_up(@l2)
    @rr.refresh
    assert_equal(1, @l2.read.size)
    assert_equal(1, @rr.size('10.255.0.12'))
  end

  # A session that went down and came back between two refreshes: the
  # reflector never saw it down, and still sends it everything.
  def test_a_session_that_flapped_between_refreshes_gets_everything
    receive('10.255.0.11', 3)
    @rr.refresh
    @l2.sent.clear
    @rr.session_up(@l2)
    @rr.refresh
    assert_equal(1, @l2.read.size)
  end

  # A CE in a VRF and an external peer get none of it, and nothing is
  # tried: no warning.
  def test_ces_and_external_peers_get_nothing
    @nc.vrf = 'A'
    ext = Session.new('192.0.2.9', remote_as: 65009)
    @rr.instance_variable_get(:@speaker).peers << ext
    receive('10.255.0.11', 3)
    @rr.refresh
    assert_equal([], @nc.sent)
    assert_equal([], ext.sent)
    assert_equal([], @log.select { |level, _| level == :warn })
  end

  # RFC 4456 section 8: a route carrying our CLUSTER_ID looped back. The
  # EVPN table's decision process does not choose it, so it is not sent.
  def test_a_looped_route_is_not_reflected
    receive('10.255.0.11', 3, attrs: [BGP::Originator_id.new('10.255.0.7'), BGP::Cluster_list.new('10.255.0.2')])
    @rr.refresh
    assert_equal([], @l2.sent)
  end

  # Export calls, as [peer address, MAC or originator], from here on.
  def count_exports
    calls = []
    export = @rr.instance_variable_get(:@export)
    export.define_singleton_method(:for) do |route, peer, **kw|
      calls << peer.address
      super(route, peer, **kw)
    end
    calls
  end

  # A refresh exports only the winners that changed since the last one.
  # Exporting all of them on every poke cost 0.9 s of CPU a refresh at
  # 1000 routes (2026-11-26), and a poke comes with each UPDATE.
  def test_a_refresh_exports_only_what_changed
    calls = count_exports
    receive('10.255.0.11', 2, mac: '00:00:00:00:00:02')
    receive('10.255.0.11', 2, mac: '00:00:00:00:00:03')
    @rr.refresh
    assert_equal((%w[10.255.0.11 10.255.0.12 10.255.0.9] * 2).sort, calls.sort, 'each route to each peer, l1 refused')
    calls.clear
    @l2.sent.clear
    @rr.refresh
    assert_equal([[], []], [calls, @l2.sent], 'nothing changed: nothing exported, nothing sent')
    receive('10.255.0.11', 2, mac: '00:00:00:00:00:03', seq: 1)
    @rr.refresh
    assert_equal(%w[10.255.0.11 10.255.0.12 10.255.0.9], calls.sort, 'the changed route only')
    assert_equal([[1, false]], @l2.read.collect { |o| o[8] })
  end

  # A route refused to a peer is not exported to it again, and a new
  # winner for the key is: l1's own route was refused to l1, and l2's for
  # the same key, once l1 withdraws, goes to l1.
  def test_a_refusal_is_kept_until_the_winner_changes
    calls = count_exports
    receive('10.255.0.11', 2, rd: ['10.255.0.11', 100])
    @rr.refresh
    calls.clear
    @rr.refresh
    assert_equal([], calls)
    receive('10.255.0.12', 2, rd: ['10.255.0.11', 100])
    @table.apply('10.255.0.11', [[:withdraw, ['10.255.0.11:100', 2, 0, '00:00:00:00:00:02', nil, nil]]])
    @l1.sent.clear
    @rr.refresh
    assert_equal([['10.255.0.11:100', 2, 0, '00:00:00:00:00:02', nil]], @l1.read.collect { |o| o[1] })
    assert_equal('10.255.0.12', @l1.read.first[2])
  end

  # A session that comes up again is exported everything again, what was
  # refused to it before included.
  def test_a_session_coming_up_is_exported_everything_again
    calls = count_exports
    receive('10.255.0.11', 2)
    @rr.refresh
    calls.clear
    @rr.session_up(@l1)
    @rr.session_up(@l2)
    @rr.refresh
    assert_equal(%w[10.255.0.11 10.255.0.12], calls.sort)
    assert_equal(1, @rr.size('10.255.0.12'))
  end
end
