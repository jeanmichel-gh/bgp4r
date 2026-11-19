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
class TestBgpDaemonVpnExporter < Test::Unit::TestCase

  Export = BGP::Rib::L3vpn::Export

  # A session, as the exporter sees one: what it was sent, decoded back
  # into VPN operations as a receiving PE would read them.
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

    # What a PE reading these UPDATEs would do: [:announce, rd, prefix,
    # labels, route targets, next hop] and [:withdraw, rd, prefix].
    def operations
      peer = BGP::Rib::Peer.new(:address => @address, :remote_as => @remote_as,
                                :router_id => '10.255.0.3', :local_as => 65000)
      @sent.flat_map do |u|
        u = BGP::Update.new(u.encode) # on the wire and back
        BGP::Rib::PeerAdapter.vpn_operations(u, peer).collect do |op, *a|
          # IPv4 and IPv6 alike; the test reads the family off the prefix.
          next [op, *a.first(2)] if op == :withdraw
          v = a.first
          [op, v.rd, v.prefix, v.labels, v.route_targets, v.route.next_hop]
        end
      end
    end
  end

  Speaker = Struct.new(:peers, :my_as, :local_address)

  def session_info(vpn, vpn6: false)
    caps = [BGP::OPT_PARM::CAP::Mbgp.new(1, vpn ? 128 : 1)]
    caps << BGP::OPT_PARM::CAP::Mbgp.new(2, 128) if vpn6
    BGP::Neighbor::Capabilities.new(BGP::Open.new(4, 65000, 180, '10.255.0.1', *caps),
                                    BGP::Open.new(4, 65000, 180, '10.255.0.3', *caps))
  end

  def setup
    @pe2 = FakePeer.new('10.255.0.3', 65000, session_info(true))
    @plain = FakePeer.new('10.255.0.4', 65000, session_info(false))
    @speaker = Speaker.new([@pe2, @plain], 65000, '10.255.0.1')
    @exporter = BGP::Daemon::VpnExporter.new(@speaker)
  end

  def a1 ; Export.new('A', '65000:1', '192.168.1.0/30', 24000, ['65000:100']) ; end
  def a2 ; Export.new('A', '65000:1', '172.16.1.0/24', 24000, ['65000:100']) ; end
  def b1 ; Export.new('B', '10.255.0.1:2', '192.168.1.0/30', 24001, ['65000:200', '65000:201']) ; end

  # Section 4.3.2: next hop our loopback, the VRF's RD and label, and its
  # Export Targets as Route Targets.
  def test_a_vpn_peer_gets_the_vrfs_routes
    @exporter.refresh([a1, a2, b1])
    assert_equal([[:announce, '65000:1', '192.168.1.0/30', [24000], ['65000:100'], '10.255.0.1'],
                  [:announce, '65000:1', '172.16.1.0/24', [24000], ['65000:100'], '10.255.0.1'],
                  [:announce, '10.255.0.1:2', '192.168.1.0/30', [24001], ['65000:200', '65000:201'], '10.255.0.1']],
                 @pe2.operations)
    assert_equal(2, @pe2.sent.size, 'one UPDATE per VRF, since the Route Targets differ')
  end

  # Section 4.3.4: only a session that negotiated AFI 1 / SAFI 128.
  def test_a_session_without_the_vpn_family_gets_nothing
    @exporter.refresh([a1])
    assert_equal([], @plain.sent)
  end

  # The receiver filters (the spec's "Who filters: the receiver"): a peer
  # gets every VRF's routes, whatever its import targets.
  def test_the_sender_does_not_filter_by_route_target
    @exporter.refresh([a1, b1])
    assert_equal(['65000:1', '10.255.0.1:2'], @pe2.operations.collect { |o| o[1] })
  end

  def test_a_refresh_sends_only_the_difference
    @exporter.refresh([a1, a2])
    @pe2.sent.clear
    changed = Export.new('A', '65000:1', '172.16.1.0/24', 24000, ['65000:100', '65000:101'])
    @exporter.refresh([a1, changed, b1])
    assert_equal([[:announce, '65000:1', '172.16.1.0/24', [24000], ['65000:100', '65000:101'], '10.255.0.1'],
                  [:announce, '10.255.0.1:2', '192.168.1.0/30', [24001], ['65000:200', '65000:201'], '10.255.0.1']],
                 @pe2.operations)
    @pe2.sent.clear
    @exporter.refresh([a1, changed, b1])
    assert_equal([], @pe2.sent, 'nothing changed, nothing sent')
  end

  # RFC 8277 section 2.4: a withdrawal's label field is 0x800000.
  def test_a_gone_route_is_withdrawn_with_the_compatibility_field
    @exporter.refresh([a1, a2])
    @pe2.sent.clear
    @exporter.refresh([a1])
    assert_equal([[:withdraw, '65000:1', '172.16.1.0/24']], @pe2.operations)
    nlri = @pe2.sent.first.path_attribute[BGP::Mp_unreach].nlris.first
    assert_match(/800000/, nlri.encode.unpack1('H*'))
  end

  def test_a_session_coming_up_gets_every_route
    @pe2.up = false
    @exporter.refresh([a1, b1])
    assert_equal([], @pe2.sent)
    @pe2.up = true
    @exporter.session_up(@pe2)
    assert_equal(2, @pe2.operations.size)
    @exporter.session_up(@plain)
    assert_equal([], @plain.sent)
  end

  # RFC 4271 section 5.1.2 and 5.1.5.
  def test_ibgp_and_ebgp_attributes
    @exporter.refresh([a1])
    pa = @pe2.sent.first.path_attribute
    assert_equal([0, 100], [pa[BGP::Origin].to_i, pa[BGP::Local_pref].to_i])
    assert_equal('empty', pa[BGP::As_path].as_path.to_s)
    ebgp = FakePeer.new('192.168.1.2', 65101, session_info(true))
    @speaker.peers << ebgp
    @exporter.session_up(ebgp)
    pa = ebgp.sent.first.path_attribute
    assert(!pa.has?(BGP::Local_pref))
    assert_equal('65000', pa[BGP::As_path].as_path.to_s)
  end

  # The speaker's logger is a ->(level, message), not a Logger.
  def test_it_logs_through_the_speakers_callable
    log = []
    exporter = BGP::Daemon::VpnExporter.new(@speaker, logger: ->(level, msg) { log << [level, msg] })
    exporter.refresh([a1, a2])
    exporter.refresh([a1])
    assert_equal([[:info, 'l3vpn: 2 VPN route(s) to announce, 0 to withdraw'],
                  [:info, 'l3vpn: 0 VPN route(s) to announce, 1 to withdraw']], log)
  end

  # --- IPv6, pull request 5 ----------------------------------------------

  def a6 ; Export.new('A', '65000:1', '2001:db8:1::/64', 24000, ['65000:100']) ; end

  # RFC 4659 section 3.2.1.2: our IPv4 address, IPv4-mapped, as next
  # hop; AFI 2 in its own UPDATE beside the IPv4 one.
  def test_an_ipv6_prefix_goes_as_afi_2_with_a_mapped_next_hop
    @pe2.session_info = session_info(true, vpn6: true)
    @exporter.refresh([a1, a6])
    assert_equal([[:announce, '65000:1', '192.168.1.0/30', [24000], ['65000:100'], '10.255.0.1'],
                  [:announce, '65000:1', '2001:db8:1::/64', [24000], ['65000:100'], '::ffff:10.255.0.1']],
                 @pe2.operations)
    assert_equal([1, 2], @pe2.sent.collect { |u| u.path_attribute[BGP::Mp_reach].afi })
    nh = @pe2.sent.last.path_attribute[BGP::Mp_reach].encode.unpack1('H*')
    assert_match(/000280 18 0{16} 0{20}ffff0aff0001/x, nh, 'AFI 2, SAFI 128, length 24: RD 0, then ::ffff:10.255.0.1')
  end

  # Section 3.4: a session that did not negotiate AFI 2 gets none of it.
  def test_ipv6_goes_only_where_it_was_negotiated
    @exporter.refresh([a1, a6])
    assert_equal(['192.168.1.0/30'], @pe2.operations.collect { |o| o[2] })
    v6only = FakePeer.new('10.255.0.5', 65000, BGP::Neighbor::Capabilities.new(
      BGP::Open.new(4, 65000, 180, '10.255.0.1', BGP::OPT_PARM::CAP::Mbgp.new(2, 128)),
      BGP::Open.new(4, 65000, 180, '10.255.0.5', BGP::OPT_PARM::CAP::Mbgp.new(2, 128))))
    @exporter.session_up(v6only)
    assert_equal(['2001:db8:1::/64'], v6only.operations.collect { |o| o[2] })
  end

  def test_an_ipv6_withdrawal_is_afi_2
    @pe2.session_info = session_info(true, vpn6: true)
    @exporter.refresh([a1, a6])
    @pe2.sent.clear
    @exporter.refresh([a1])
    assert_equal([[:withdraw, '65000:1', '2001:db8:1::/64']], @pe2.operations)
    assert_equal(2, @pe2.sent.first.path_attribute[BGP::Mp_unreach].afi)
  end

  # --- CE routes, pull request 7 -----------------------------------------

  # A CE's route keeps the CE's AS_PATH and ORIGIN, and its Site of Origin
  # rides as a Route Origin beside the Route Targets (RFC 4360 section 5).
  def test_a_ce_route_carries_its_path_origin_and_site_of_origin
    ce = Export.new('A', '65000:1', '172.16.1.0/24', 24000, ['65000:100'], [65101], 2, '65000:11')
    @exporter.refresh([a1, ce])
    assert_equal(2, @pe2.sent.size, 'apart from the PE\'s own route, whose path is empty')
    pa = @pe2.sent.last.path_attribute
    assert_equal(['65101', 2], [pa[BGP::As_path].as_path.to_s, pa[BGP::Origin].to_i])
    ecs = pa[BGP::Extended_communities]
    assert_equal([[65000, 100]], ecs.find_all(BGP::Route_target).collect { |c| c.to_hash[:route_target] })
    assert_equal([[65000, 11]], ecs.find_all(BGP::Route_origin).collect { |c| c.to_hash[:route_origin] })
  end

  def test_with_no_local_address_the_sessions_address_is_the_next_hop
    @speaker.local_address = nil
    @exporter.refresh([a1])
    assert_equal('10.0.12.1', @pe2.operations.first.last)
  end

  def test_rows_are_what_this_pe_sends
    @exporter.refresh([a1, b1])
    rows = @exporter.rows.sort_by { |r| r['rd'] }
    assert_equal([['10.255.0.1:2', '192.168.1.0/30', nil, '10.255.0.1', [24001], 'local', 'B'],
                  ['65000:1', '192.168.1.0/30', nil, '10.255.0.1', [24000], 'local', 'A']],
                 rows.collect { |r| r.values_at('rd', 'prefix', 'peer', 'next_hop', 'labels', 'reason', 'vrf') })
    assert_equal(2, @exporter.size)
    assert_equal([[nil, nil, []], [nil, nil, []]], rows.collect { |r| r.values_at('soo', 'originator_id', 'cluster_list') })
  end

  def test_a_ce_routes_row_carries_its_site_of_origin
    ce = Export.new('A', '65000:1', '172.16.1.0/24', 24000, ['65000:100'], [65101], 2, '65000:11')
    @exporter.refresh([ce])
    assert_equal('65000:11', @exporter.rows.first['soo'])
  end

  # The row says what the UPDATE carries: the CE's AS_PATH and ORIGIN, or
  # an empty path and IGP for the PE's own route.
  def test_a_rows_path_and_origin_are_what_the_update_carries
    ce = Export.new('A', '65000:1', '172.16.1.0/24', 24000, ['65000:100'], [65101], 2, '65000:11')
    @exporter.refresh([a1, ce])
    rows = @exporter.rows.sort_by { |r| r['prefix'] }
    assert_equal([['172.16.1.0/24', '65101', 2], ['192.168.1.0/30', 'empty', 0]],
                 rows.collect { |r| r.values_at('prefix', 'as_path', 'origin') })
  end

  # Per family, what each session was sent: a VRF's routes go to every
  # established session that negotiated their family.
  def test_sent_counts_are_per_family_and_per_session
    @pe2.session_info = session_info(true, vpn6: true)
    @exporter.refresh([a1, a2, a6])
    assert_equal({ 'vpn-ipv4' => 2, 'vpn-ipv6' => 1 }, @exporter.sent_counts(@pe2))
    assert_equal({}, @exporter.sent_counts(@plain))
    @pe2.up = false
    assert_equal({}, @exporter.sent_counts(@pe2))
  end
end
