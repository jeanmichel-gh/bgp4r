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

# What a PE sends of EVPN: docs/design/evpn.md, pull request 3,
# "Exporting". Each UPDATE is read back as a receiving PE reads it, through
# PeerAdapter.evpn_operations, so the test asserts what arrives.
# BGP:: names are written out in full here, see Conventions in CLAUDE.md.
class TestBgpDaemonEvpnExporter < Test::Unit::TestCase

  Export = BGP::Rib::Macvrfs::Export
  H1 = '02:00:00:00:01:01'

  class FakePeer
    attr_reader :address, :sent
    attr_accessor :up, :session_info, :remote_as

    def initialize(address, remote_as, session_info)
      @address, @remote_as, @session_info = address, remote_as, session_info
      @up = true
      @sent = []
    end

    def established? ; @up ; end
    def ebgp? ; @remote_as != 65000 ; end
    def local_ip ; '10.0.12.1' ; end
    def send_message(m) ; @sent << m ; end

    # [:announce, EvpnRoute] and [:withdraw, key], off the wire.
    def operations
      peer = BGP::Rib::Peer.new(:address => @address, :remote_as => @remote_as,
                                :router_id => '10.255.0.1', :local_as => 65000)
      @sent.flat_map { |u| BGP::Rib::PeerAdapter.evpn_operations(BGP::Update.new(u.encode), peer) }
    end

    def announced
      operations.select { |op, _| op == :announce }.collect(&:last)
    end
  end

  Speaker = Struct.new(:peers, :my_as, :local_address, :router_id)

  def session_info(evpn)
    caps = [BGP::OPT_PARM::CAP::Mbgp.new(25, evpn ? 70 : 1)]
    BGP::Neighbor::Capabilities.new(BGP::Open.new(4, 65000, 180, '10.255.0.12', *caps),
                                    BGP::Open.new(4, 65000, 180, '10.255.0.1', *caps))
  end

  def setup
    @rr = FakePeer.new('10.255.0.1', 65000, session_info(true))
    @plain = FakePeer.new('10.255.0.4', 65000, session_info(false))
    @speaker = Speaker.new([@rr, @plain], 65000, '10.255.0.12', '10.255.0.12')
    @x = BGP::Daemon::EvpnExporter.new(@speaker)
  end

  def type3 ; Export.new(100, '10.255.0.12:100', 3, nil, nil, ['65000:100']) ; end
  def type2(seq = nil) ; Export.new(100, '10.255.0.12:100', 2, H1, seq, ['65000:100']) ; end

  # Exporting, step 1: RFC 7432 section 11.2's PMSI Tunnel, Ingress
  # Replication to local_address, the VNI as its label (RFC 8365 section
  # 5.1.3), the Encapsulation community VXLAN and the Route Targets.
  def test_the_type_3_route
    @x.refresh([type3])
    r = @rr.announced.first
    assert_equal(['10.255.0.12:100', 3, 0, '10.255.0.12', 100, 'VXLAN', ['65000:100'], '10.255.0.12'],
                 [r.rd, r.route_type, r.eth_tag, r.originator, r.vni, r.encap, r.route_targets, r.route.next_hop])
    assert_equal({ 'type' => 'ingress_replication', 'id' => '10.255.0.12' }, r.pmsi_row)
    assert_equal([], @plain.sent, 'a session without EVPN gets none')
  end

  # Exporting, step 2: ESI 0, no IP, the VNI in Label1, and MAC Mobility
  # only when the MAC has a sequence (RFC 7432 section 15).
  def test_the_type_2_route
    @x.refresh([type2])
    r = @rr.announced.first
    assert_equal([2, H1, nil, 100, '00:00:00:00:00:00:00:00:00:00', nil, nil],
                 [r.route_type, r.mac, r.ip, r.vni, r.esi, r.mobility, r.pmsi])
    @x.refresh([type2(3)])
    assert_equal([3, false], @rr.announced.last.mobility)
  end

  # Only what changed is sent; what went is withdrawn; a session that
  # comes up gets everything.
  def test_changes_withdrawals_and_a_session_up
    @x.refresh([type3, type2])
    n = @rr.sent.size
    @x.refresh([type3, type2])
    assert_equal(n, @rr.sent.size)
    @x.refresh([type3])
    assert_equal([:withdraw, ['10.255.0.12:100', 2, 0, H1, nil, nil]], @rr.operations.last)
    late = FakePeer.new('10.255.0.5', 65000, session_info(true))
    @x.session_up(late)
    assert_equal([3], late.announced.collect(&:route_type))
    assert_equal(1, @x.sent_count(@rr))
    assert_equal(0, @x.sent_count(@plain))
  end

  # RFC 4271 section 5.1.2: our AS toward an external peer, and no
  # LOCAL_PREF.
  def test_an_external_peer
    @rr.remote_as = 65001
    @x.refresh([type3])
    pa = @rr.sent.first.path_attribute
    assert_equal('65000', pa[BGP::As_path].as_path)
    assert_false(pa.has?(BGP::Local_pref))
  end

  def test_the_rows
    @x.refresh([type3, type2(2)])
    assert_equal([[3, nil, nil, 'local', { 'type' => 'ingress_replication', 'id' => '10.255.0.12' }],
                  [2, H1, 2, 'local', nil]],
                 @x.rows.collect { |r| r.values_at('route_type', 'mac', 'seq', 'reason', 'pmsi') })
  end
end
