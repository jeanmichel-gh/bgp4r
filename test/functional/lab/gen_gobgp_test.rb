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

# BGP::Gen against a real router: a generated feed from bgp4r into a
# gobgpd on loopback, no Docker, and the router's RIB compared with the
# spec's `expected`.
#
#   ruby -I. test/functional/lab/gen_gobgp_test.rb
#
# Omitted when gobgpd is not installed, unless LAB_REQUIRE_GOBGPD=1.
#
# What this adds over test/functional/gen_test.rb is a reader that is not
# bgp4r. There, the receiver's parser is the one the generator's own
# tests use, so a fault in both halves passes. Here GoBGP reads the
# packing, the MP_REACH_NLRI framing, the Path Identifiers and every
# attribute, and holds what it read.
#
# BGP:: names are written out in full, see Conventions in CLAUDE.md.

require 'test/unit'
require 'socket'
require 'bgp4r'
require 'bgp/gen'
require 'bgp/sim'
require_relative 'lab_helper'

class LabGenGobgpTest < Test::Unit::TestCase
  include LabHelper

  OUR_AS = 65001
  THEIR_AS = 65002
  MED, LOCAL_PREF, COMMUNITIES, LARGE = 4, 5, 8, 32   # attribute type codes

  def setup
    unless LabHelper::Gobgpd.available?
      flunk('gobgpd is not installed') if ENV['LAB_REQUIRE_GOBGPD'] == '1'
      omit('gobgpd is not installed')
    end
  end

  def teardown
    @injector.stop if @injector
    @thread.kill if @thread
    @peer.close if @peer
    @server.close if @server && !@server.closed?
    if @router
      @router.down
      puts "\n== gobgpd\n#{@router.log}" unless passed?
    end
  end

  # A gobgpd that dials us, and a bgp4r speaker with 4-octet AS numbers,
  # IPv4 and IPv6 unicast, and add-path when asked.
  def session(add_path = false, families = [])
    @router = LabHelper::Gobgpd.new(:local => '127.0.0.2', :as => THEIR_AS,
                                    :router_id => '10.0.0.2',
                                    :peer => '127.0.0.1', :peer_as => OUR_AS, :families => families,
                                    :add_path => add_path ? { :receive => true, :send_max => 0 } : nil)
    @router.up
    @server = TCPServer.new('127.0.0.1', @router.port)
    @peer = BGP::Neighbor.new(4, OUR_AS, 180, '10.0.0.1', '127.0.0.2', '127.0.0.1')
    @peer.capability :as4_byte
    @peer.capability :mbgp, :ipv4, :unicast
    @peer.capability :mbgp, :ipv6, :unicast
    families.each { |f| @peer.capability :mbgp, *AFI_SAFI.fetch(f) }
    if add_path
      @peer.capability :add_path, :send, 1, 1
      @peer.capability :add_path, :send, 2, 1
    end
    @thread = Thread.new do
      begin
        while (socket = @server.accept)
          @peer.start_session(socket)
        end
      rescue IOError, SystemCallError
      end
    end
    @peer.wait_for_state(:Established, 40)
  end

  # The client takes `ipv6` here, and refuses `ipv6-unicast`, which is
  # the config file's name for the same family. Measured, the fourth
  # time the two have disagreed; see CLIENT_FAMILY in lab_helper.rb.
  FAMILY = { 1 => 'ipv4', 2 => 'ipv6' }

  G = LabHelper::Gobgpd
  AFI_SAFI = { G::LABELLED_IPV4 => [1, 4], G::LABELLED_IPV6 => [2, 4],
               G::MULTICAST_IPV4 => [1, 2], G::MULTICAST_IPV6 => [2, 2],
               G::VPN_IPV4 => [1, 128], G::VPN_IPV6 => [2, 128],
               G::VPN_MULTICAST_IPV4 => [1, 129],
               G::FS_IPV4 => [1, 133], G::FS_IPV6 => [2, 133], G::FS_VPN => [1, 134],
               G::EVPN => [25, 70] }

  def rib(afi)
    @router.rib_family(FAMILY[afi])
  end

  # How many paths the router holds, from `global rib summary`. The JSON
  # RIB is no use for counting a large feed: GoBGP prints each path's
  # MP_REACH_NLRI with every prefix of the UPDATE it came in, so 2000
  # IPv6 routes are tens of megabytes of JSON per poll.
  def path_count(afi)
    out, status = @router.client_run('global', 'rib', 'summary', '-a', FAMILY[afi])
    status.success? ? out[/Path: (\d+)/, 1].to_i : -1
  end

  # Announce, compare a sample with expected, withdraw, empty.
  def crosses(spec)
    g = BGP::Gen.new(spec)
    count = spec['count']
    g.updates.each { |u| @peer.send_message u }
    wait_for("GoBGP to hold #{count} routes", :timeout => 60) { path_count(g.afi) == count }
    held = rib(g.afi)
    rows = g.expected.to_a
    # Ten rows spread across the feed, the first and the last among them,
    # so a pattern's value is checked at more than one point of its cycle.
    (0..9).collect { |k| (rows.size - 1) * k / 9 }.uniq.each do |i|
      want = rows[i]
      paths = held[want['prefix']]
      assert_not_nil(paths, "GoBGP holds #{want['prefix']}")
      assert_equal(1, paths.size, 'one path per prefix')
      read(paths.first, want)
    end
    g.withdrawals.each { |u| @peer.send_message u }
    wait_for('GoBGP to hold nothing', :timeout => 60) { path_count(g.afi) == 0 }
    g
  end

  # What GoBGP read, against the row. Each attribute GoBGP prints is
  # compared, by its type code, the way rib_router_gobgp_test.rb does.
  def read(path, want)
    a = LabHelper::Gobgpd.attrs(path)
    assert_equal(want['as_path'], LabHelper::Gobgpd.as_path(path), want['prefix'])
    assert_equal(want['origin'], a[1]['value'], 'ORIGIN')
    nh = a[3] ? a[3]['nexthop'] : a[14]['nexthop']
    assert_equal(want['next_hop'], nh, 'the next hop, NEXT_HOP or inside MP_REACH_NLRI')
    assert_equal(want['med'], a[MED] && a[MED]['metric'], 'MULTI_EXIT_DISC')
    if want['communities']
      got = a[COMMUNITIES]['communities'].collect { |c| "#{c >> 16}:#{c & 0xffff}" }
      assert_equal(want['communities'], got, 'COMMUNITIES')
    end
    if want['large_communities']
      got = a[LARGE]['value'].collect { |c| "#{c['ASN']}:#{c['LocalData1']}:#{c['LocalData2']}" }
      assert_equal(want['large_communities'], got, 'LARGE_COMMUNITY')
    end
  end

  ATTRIBUTES = { 'origin' => 1, 'as_path' => [OUR_AS, 65010, 4200000000], 'med' => 70,
                 'communities' => ['65000:1', '65000:2'], 'large_communities' => ['65000:1:1', '65000:2:3'] }

  def test_ipv4_unicast
    session
    crosses('start' => '10.0.0.0/24', 'count' => 3000,
            'attributes' => ATTRIBUTES.merge('next_hop' => '192.0.2.1'))
  end

  def test_ipv6_unicast
    session
    crosses('start' => '2001:db8::/64', 'count' => 1500,
            'attributes' => ATTRIBUTES.merge('next_hop' => '2001:db8::1'))
  end

  # RFC 7911: GoBGP reads a Path Identifier before every prefix only if
  # the session negotiated one, so holding the routes at all says the
  # identifiers are where it expects them. **That is all it says**: the
  # client's JSON prints no Path Identifier, measured on 3.23.0, so a
  # wrong value in the right place would pass here. The value is
  # test/functional/gen_test.rb's, where the Adj-RIB-In is keyed on it.
  def test_a_path_id_on_every_prefix
    session(true)
    [['10.0.0.0/24', '192.0.2.1'], ['2001:db8::/64', '2001:db8::1']].each do |start, nh|
      crosses('start' => start, 'count' => 1000, 'path_id' => 77,
              'attributes' => { 'next_hop' => nh, 'as_path' => [OUR_AS] })
    end
  end

  # Phase 2: what GoBGP reads when the attributes change route to route.
  # A wrong set on a route, or two sets packed into one message, shows
  # as a sampled row that disagrees with its expected values.
  def test_patterns_and_a_group
    session
    crosses('start' => '10.0.0.0/24', 'count' => 2000, 'group' => 3, 'seed' => 21,
            'attributes' => {
              'origin' => { 'every' => { 'n' => 5, 'values' => [0, 2] } },
              'next_hop' => { 'step' => { 'start' => '192.0.2.1', 'by' => 1, 'wrap' => '192.0.2.200' } },
              'as_path' => { 'prepend' => { 'as' => OUR_AS, 'count' => { 'cycle' => [1, 2, 4] }, 'path' => [65010] } },
              'med' => { 'random' => { 'min' => 0, 'max' => 1000 } },
              'communities' => { 'count' => { 'base' => '65000:1', 'n' => { 'cycle' => [1, 3] } } },
              'large_communities' => { 'cycle' => [['65000:1:1'], ['65000:2:2', '65000:2:3']] } })
  end

  def test_ipv6_patterns
    session
    crosses('start' => '2001:db8::/64', 'count' => 1000, 'seed' => 22,
            'attributes' => {
              'next_hop' => { 'cycle' => %w[2001:db8::1 2001:db8::2 2001:db8::3] },
              'as_path' => { 'length' => { 'count' => { 'cycle' => [1, 3] }, 'min' => 64512, 'max' => 64600 } },
              'med' => { 'step' => { 'start' => 0, 'by' => 7 } } })
  end

  # ---- phase 3: through bgp4r-sim -------------------------------------

  # The same gobgpd dialling an injector instead of a bare Neighbor, so
  # the session rules come from the injector: our AS in front of the
  # path and our address as the next hop.
  def sim_session
    @router = LabHelper::Gobgpd.new(:local => '127.0.0.2', :as => THEIR_AS,
                                    :router_id => '10.0.0.2',
                                    :peer => '127.0.0.1', :peer_as => OUR_AS)
    @router.up
    @injector = BGP::Sim::Injector.new(
      'router_id' => '10.0.0.1', 'as' => OUR_AS,
      'listen_address' => '127.0.0.1', 'port' => @router.port,
      'neighbors' => [{ 'address' => '127.0.0.2', 'as' => THEIR_AS,
                        'capabilities' => ['as4_byte', { 'mbgp' => %w[ipv4 unicast] },
                                           { 'mbgp' => %w[ipv6 unicast] }] }])
    @injector.start
    wait_for('the injector session', :timeout => 40) { !@injector.speaker.established_peers.empty? }
  end

  # **The interop claim of phase 3**: what the injector's dry run says is
  # what a router that is not bgp4r holds after the injector sends the
  # spec, sampled across the feed, and nothing after the withdrawal.
  def plan_crosses(spec)
    rows = []
    offset = 0
    loop do
      p = @injector.plan('spec' => spec, 'offset' => offset, 'limit' => 1000)[:plans].first
      rows.concat(p[:rows])
      break unless p[:next_offset]
      offset = p[:next_offset]
    end
    assert_equal(spec['count'], rows.size)
    afi = spec['start'].include?(':') ? 2 : 1
    @injector.act('announce', { 'spec' => spec }, false)
    wait_for("GoBGP to hold #{spec['count']} routes", :timeout => 60) { path_count(afi) == spec['count'] }
    held = rib(afi)
    (0..9).collect { |k| (rows.size - 1) * k / 9 }.uniq.each do |i|
      want = rows[i].dup
      assert_equal(OUR_AS, want['as_path'].first, 'the plan has our AS in front')
      # An IPv4 next hop under AFI 2 goes out IPv4-mapped, and GoBGP
      # prints it back as the IPv4 address, so the plan's own form is the
      # one to compare. Measured on 3.23.0; sim_test.rb asserts the
      # octets.
      paths = held[want['prefix']]
      assert_not_nil(paths, "GoBGP holds #{want['prefix']}")
      read(paths.first, want)
    end
    @injector.act('withdraw', { 'spec' => spec }, false)
    wait_for('GoBGP to hold nothing', :timeout => 60) { path_count(afi) == 0 }
  end

  def test_the_router_holds_what_the_injector_planned
    sim_session
    plan_crosses('start' => '10.0.0.0/24', 'count' => 2000, 'group' => 4,
                 'attributes' => { 'as_path' => [65010], 'med' => { 'cycle' => [5, 50, 500] },
                                   'communities' => { 'count' => { 'base' => '65000:1',
                                                                   'n' => { 'cycle' => [1, 2] } } } })
    plan_crosses('start' => '2001:db8::/64', 'count' => 1000,
                 'attributes' => { 'med' => { 'step' => { 'start' => 1, 'by' => 3 } } })
  end


  # ---- phase 4a: labelled and multicast --------------------------------

  def count_in(family)
    out, status = @router.client_run('global', 'rib', 'summary', '-a', G.client_family(family))
    status.success? ? out[/Path: (\d+)/, 1].to_i : -1
  end

  # A labelled feed in GoBGP's own table for SAFI 4, which reads the
  # label of each prefix back as a list: so the label of a sampled row is
  # a second implementation's reading of the three octets RFC 8277
  # section 2.2 puts in front of the prefix, and of which route got which
  # label when a pattern steps them.
  def labelled_crosses(spec, family)
    g = BGP::Gen.new(spec)
    count = spec['count']
    g.updates.each { |u| @peer.send_message u }
    wait_for("GoBGP to hold #{count} labelled routes", :timeout => 60) { count_in(family) == count }
    held = @router.rib_family(family)
    rows = g.expected.to_a
    (0..9).collect { |k| (rows.size - 1) * k / 9 }.uniq.each do |i|
      want = rows[i]
      paths = held[want['prefix']]
      assert_not_nil(paths, "GoBGP holds #{want['prefix']}")
      assert_equal([want['label']], paths.first['nlri']['labels'], "the label of #{want['prefix']}")
      read(paths.first, want)
    end
    # RFC 8277 section 2.4: the withdrawals carry the Compatibility
    # field, 0x800000, where the label was, and GoBGP takes the route
    # out by its prefix.
    g.withdrawals.each { |u| @peer.send_message u }
    wait_for('GoBGP to hold nothing', :timeout => 60) { count_in(family) == 0 }
  end

  def test_ipv4_labelled
    session(false, [G::LABELLED_IPV4])
    labelled_crosses({ 'family' => 'labelled', 'start' => '10.0.0.0/24', 'count' => 2000, 'group' => 10,
                       'label' => { 'step' => { 'start' => 16, 'by' => 3, 'wrap' => 2**20 - 1 } },
                       'attributes' => { 'next_hop' => '192.0.2.1', 'as_path' => [OUR_AS],
                                         'med' => { 'cycle' => [1, 2, 3] } } }, G::LABELLED_IPV4)
  end

  def test_ipv6_labelled
    session(false, [G::LABELLED_IPV6])
    labelled_crosses({ 'family' => 'labelled', 'start' => '2001:db8::/64', 'count' => 1000, 'label' => 2**20 - 1,
                       'attributes' => { 'next_hop' => '2001:db8::1', 'as_path' => [OUR_AS] } }, G::LABELLED_IPV6)
  end

  # **GoBGP 3.23.0 files a multicast route in its unicast table**, which
  # is the finding of this case and recorded rather than filed, per the
  # standing decision that the job here is bgp4r catching up. Measured
  # on 2026-11-03:
  #
  # * the client has no multicast table at all, "unsupported address
  #   family" for both, though the session negotiates both;
  # * an IPv4 or IPv6 multicast route lands in that family's **unicast**
  #   table, with next hop "fictitious" and no attributes;
  # * one for a prefix the unicast table already holds **replaces** the
  #   unicast route, and withdrawing the multicast route then takes the
  #   prefix out of the unicast table altogether.
  #
  # RFC 4760 section 3 keys a route by AFI and SAFI, so SAFI 2 is not
  # SAFI 1's. A unicast control route of a different prefix keeps its
  # attributes throughout, which says the multicast UPDATE did not reset
  # anything or upset the session; and no session went down. So this
  # vouches for our framing, since GoBGP read the prefixes out of the
  # MP_REACH_NLRI and MP_UNREACH_NLRI, and for nothing about the
  # attributes, which it dropped. If a later GoBGP keeps a multicast
  # table, the first assertion fails and says to compare routes instead.
  def test_gobgp_files_multicast_routes_in_its_unicast_table
    session(false, [G::MULTICAST_IPV4, G::MULTICAST_IPV6])
    downs = 0
    @peer.on_state_change { |_now, _was| downs += 1 }
    [G::MULTICAST_IPV4, G::MULTICAST_IPV6].each do |f|
      out, = @router.client_run('global', 'rib', '-a', f)
      assert_match(/unsupported address family: #{f}/, out, 'GoBGP 3.23.0 has no table for it')
    end
    uni = BGP::Gen.new('start' => '10.0.0.0/24', 'count' => 2,
                       'attributes' => { 'next_hop' => '192.0.2.1', 'as_path' => [OUR_AS] })
    uni.updates.each { |u| @peer.send_message u }
    wait_for('the two unicast routes', :timeout => 30) { path_count(1) == 2 }
    [['10.0.0.0/24', '192.0.2.9', 1], ['2001:db8::/64', '2001:db8::9', 2]].each do |start, nh, afi|
      mc = BGP::Gen.new('family' => 'multicast', 'start' => start, 'count' => 1,
                        'attributes' => { 'next_hop' => nh, 'as_path' => [OUR_AS], 'med' => 5 })
      mc.updates.each { |u| @peer.send_message u }
      wait_for("the multicast #{start} in GoBGP's unicast table", :timeout => 30) do
        (rib(afi) || {})[start]
      end
      path = rib(afi)[start].first
      assert_nil(path['attrs'], "#{start}: no attributes, so no next hop and no MED")
      mc.withdrawals.each { |u| @peer.send_message u }
      wait_for("#{start} gone from the unicast table", :timeout => 30) { !(rib(afi) || {}).key?(start) }
    end
    # 10.0.0.0/24 was a unicast route and the multicast withdrawal took it
    # out; 10.0.1.0/24 was not touched and kept every attribute.
    held = rib(1)
    assert_nil(held['10.0.0.0/24'], 'the unicast route of that prefix went with the multicast one')
    assert_equal('192.0.2.1', LabHelper::Gobgpd.attrs(held['10.0.1.0/24'].first)[3]['nexthop'])
    assert_equal(0, downs, 'no session went down')
    assert(@peer.is_established?)
  end

  # ---- phase 4b: VPN ---------------------------------------------------

  # GoBGP's VPN table, by RD and prefix. Read from each path's NLRI and
  # not from the table's keys, which print a 4-octet AS RD in asdot.
  def vpn_held(family)
    held = {}
    (@router.rib_family(family) || {}).each_value do |paths|
      paths.each do |p|
        n = p['nlri']
        held[["#{n['rd']['admin']}:#{n['rd']['assigned']}", n['prefix']]] = p
      end
    end
    held
  end

  EXT_COMMUNITIES = 16

  # A VPN feed into GoBGP's table for SAFI 128. What it reads per sampled
  # row is the RD of RFC 4364 section 4.2 as type, administrator and
  # assigned number, the label, the route target that VRF carries, and
  # the attributes; and that the same prefix in every VRF is a route of
  # its own, since the count it holds is VRFs times the range.
  #
  # check, when given, is called with each sampled row and GoBGP's path,
  # for what a test states by hand rather than reads from expected.
  def vpn_crosses(spec, family, check = nil)
    g = BGP::Gen.new(spec)
    total = g.expected.size
    g.updates.each { |u| @peer.send_message u }
    wait_for("GoBGP to hold #{total} VPN routes", :timeout => 60) { count_in(family) == total }
    held = vpn_held(family)
    rows = g.expected.to_a
    (0..9).collect { |k| (rows.size - 1) * k / 9 }.uniq.each do |i|
      want = rows[i]
      path = held[[want['rd'], want['prefix']]]
      assert_not_nil(path, "GoBGP holds #{want['rd']} #{want['prefix']}")
      assert_equal([want['label']], path['nlri']['labels'], "the label of #{want['rd']} #{want['prefix']}")
      assert_equal(rd_type(want['rd']), path['nlri']['rd']['type'], 'the RD type, RFC 4364 section 4.2')
      if want['extended_communities']
        got = LabHelper::Gobgpd.attrs(path)[EXT_COMMUNITIES]['value'].collect { |c| c['value'] }
        assert_equal(want['extended_communities'].collect { |t| t.sub('route_target:', '') }, got,
                     'the route target of the VRF')
      end
      read(path, want)
      check.call(want, path) if check
    end
    g.withdrawals.each { |u| @peer.send_message u }
    wait_for('GoBGP to hold nothing', :timeout => 60) { count_in(family) == 0 }
  end

  # The type an RD's text says, by RFC 4364 section 4.2's layouts: an
  # IPv4 administrator is type 1, an AS past two octets type 2.
  def rd_type(text)
    admin = text[/\A[^:]+/]
    return 1 if admin.include?('.')
    admin.to_i > 0xffff ? 2 : 0
  end

  def test_ipv4_vpn
    session(false, [G::VPN_IPV4])
    vpn_crosses({ 'family' => 'vpn', 'start' => '10.0.0.0/24', 'count' => 600, 'vrfs' => 3,
                  'rd' => '65000:1', 'route_target' => '65000:100', 'group' => 7,
                  'label' => { 'step' => { 'start' => 16, 'by' => 1, 'wrap' => 2**20 - 1 } },
                  'attributes' => { 'next_hop' => '192.0.2.1', 'as_path' => [OUR_AS],
                                    'med' => { 'cycle' => [1, 2, 3] } } }, G::VPN_IPV4,
                ->(want, path) {
                  # VRF n carries 65000:n and route target 65000:99+n,
                  # stated here, since a generator that gave every VRF
                  # the first one's set would agree with its own expected.
                  n = want['rd'].split(':').last.to_i
                  rt = LabHelper::Gobgpd.attrs(path)[EXT_COMMUNITIES]['value'].collect { |c| c['value'] }
                  assert_equal(["65000:#{99 + n}"], rt, "the route target GoBGP read for #{want['rd']}")
                })
  end

  # The two other RD types, and RFC 4659's two next hops: an IPv6 one,
  # and an IPv4 one written IPv4-mapped, which GoBGP prints back as the
  # IPv4 address, so expected's own form is the one to compare.
  def test_ipv6_vpn
    session(false, [G::VPN_IPV6])
    vpn_crosses({ 'family' => 'vpn', 'start' => '2001:db8::/64', 'count' => 300, 'vrfs' => 2,
                  'rd' => '192.0.2.1:7', 'route_target' => '192.0.2.1:70', 'label' => 100,
                  'attributes' => { 'next_hop' => '2001:db8::1', 'as_path' => [OUR_AS] } }, G::VPN_IPV6)
    vpn_crosses({ 'family' => 'vpn', 'start' => '2001:db8::/64', 'count' => 300, 'vrfs' => 2,
                  'rd' => '4200000000:1', 'label' => 100,
                  'attributes' => { 'next_hop' => '192.0.2.1', 'as_path' => [OUR_AS] } }, G::VPN_IPV6)
  end

  # **GoBGP 3.23.0 negotiates SAFI 129 and then refuses its first
  # UPDATE**, recorded and not filed. The session lists
  # `l3vpn-ipv4-multicast` as advertised and received; the first
  # vpn_multicast UPDATE is logged as "unknown route family. AFI: 1,
  # SAFI: 129" and "Capability was disabled", and the session stays up.
  # A SAFI 128 control feed on the same session afterwards installs, so
  # the refusal is the family's and not our MP_REACH_NLRI's. This
  # vouches for nothing about our SAFI 129 octets, which nothing read;
  # test/functional/gen_test.rb is their only reader.
  def test_gobgp_refuses_vpn_multicast_after_negotiating_it
    session(false, [G::VPN_IPV4, G::VPN_MULTICAST_IPV4])
    downs = 0
    @peer.on_state_change { |_now, _was| downs += 1 }
    out, = @router.client_run('neighbor', '127.0.0.1')
    assert_match(/#{G::VPN_MULTICAST_IPV4}:\s+advertised and received/, out)
    mc = BGP::Gen.new('family' => 'vpn_multicast', 'start' => '10.9.0.0/24', 'count' => 10, 'rd' => '65000:1',
                      'label' => 100, 'attributes' => { 'next_hop' => '192.0.2.1', 'as_path' => [OUR_AS] })
    mc.updates.each { |u| @peer.send_message u }
    wait_for('GoBGP to refuse SAFI 129', :timeout => 30) do
      @router.log =~ /unknown route family\. AFI: 1, SAFI: 129/
    end
    assert_match(/Capability was disabled/, @router.log)
    vpn_crosses({ 'family' => 'vpn', 'start' => '10.0.0.0/24', 'count' => 50, 'rd' => '65000:1',
                  'label' => 100, 'attributes' => { 'next_hop' => '192.0.2.1', 'as_path' => [OUR_AS] } },
                G::VPN_IPV4)
    assert_equal(0, downs, 'no session went down')
    assert(@peer.is_established?)
  end


  # ---- phase 4c: flow spec ---------------------------------------------

  # GoBGP's flow spec table, by RD and destination, read from each path's
  # components rather than from the table's keys, which are GoBGP's text.
  def flow_held(family)
    held = {}
    (@router.rib_family(family) || {}).each_value do |paths|
      paths.each do |p|
        comps = G.components(p)
        dest = comps.find { |c| c['type'] == 1 }
        rd = p['nlri']['rd']
        held[[rd && "#{rd['admin']}:#{rd['assigned']}", dest['value']['prefix']]] = p
      end
    end
    held
  end

  # A flow spec feed into GoBGP. Per sampled row it reads the components
  # by their RFC 8955 section 4.2 type numbers with the operator octet
  # whole, the RD of section 8, and the actions of section 7 among the
  # extended communities, then withdraws and waits for an empty table.
  def flow_crosses(spec, family)
    g = BGP::Gen.new(spec)
    total = g.total
    g.updates.each { |u| @peer.send_message u }
    wait_for("GoBGP to hold #{total} flow spec rules", :timeout => 60) { count_in(family) == total }
    held = flow_held(family)
    rows = g.expected.to_a
    (0..9).collect { |k| (rows.size - 1) * k / 9 }.uniq.each do |i|
      want = rows[i]
      path = held[[want['rd'], want['destination']]]
      assert_not_nil(path, "GoBGP holds #{want['rd']} #{want['destination']}")
      comps = G.components(path).to_h { |c| [c['type'], c] }
      assert_equal(want['source'], comps[2] && comps[2]['value']['prefix'], 'the source, type 2')
      # 129 is 0x81: the end-of-list bit of section 4.2.1.1 and eq.
      assert_equal(want['protocol'] && [{ 'op' => 129, 'value' => want['protocol'] }],
                   comps[3] && comps[3]['value'], 'the protocol, type 3')
      # A two octet value sets the len bits as well, 0x91.
      op = want['destination_port'].to_i > 255 ? 145 : 129
      assert_equal(want['destination_port'] && [{ 'op' => op, 'value' => want['destination_port'] }],
                   comps[5] && comps[5]['value'], 'the destination port, type 5')
      a = G.attrs(path)
      # GoBGP prints a next hop of length 0 as its family's unspecified
      # address. Measured: '::' under AFI 2.
      assert_equal(g.afi == 2 ? '::' : '0.0.0.0', a[14]['nexthop'], 'RFC 8955 section 4: no next hop')
      assert_equal(want['as_path'], G.as_path(path))
      yield want, (a[EXT_COMMUNITIES] || {})['value'] if block_given?
    end
    g.withdrawals.each { |u| @peer.send_message u }
    wait_for('GoBGP to hold no rule', :timeout => 60) { count_in(family) == 0 }
    g
  end

  # The actions are stated by hand per group rather than read from
  # expected: a rate taken from the wrong group would agree with its own
  # expected.
  def test_ipv4_flow_spec
    session(false, [G::FS_IPV4])
    rates = [0, 125_000, 1_000_000]
    g = flow_crosses({ 'family' => 'flow_spec', 'start' => '10.0.0.0/24', 'count' => 900, 'group' => 100,
                       'protocol' => { 'cycle' => [6, 17] }, 'source' => '192.0.2.0/24',
                       'destination_port' => { 'step' => { 'start' => 80, 'by' => 50, 'wrap' => 65535 } },
                       'rate' => { 'cycle' => rates }, 'marking' => 46, 'redirect' => '65000:100',
                       'attributes' => { 'as_path' => [OUR_AS] } }, G::FS_IPV4) do |want, ext|
      n = want['destination'].split('.')[1].to_i * 256 + want['destination'].split('.')[2].to_i
      assert_include(ext, { 'type' => 128, 'subtype' => 6, 'as' => 0, 'rate' => rates[(n / 100) % 3] },
                     "the rate of rule #{n}")
      assert_equal(3, ext.size, 'rate, redirect and marking')
      # GoBGP's text for the other two. Its own words, so a reworded
      # release is a test to update and not a bgp4r bug.
      kinds = ext.collect { |e| [e['type'], e['subtype']] }
      assert_equal([[128, 6], [128, 8], [128, 9]], kinds.sort)
    end
    assert_equal(900, g.total)
  end

  def test_ipv6_flow_spec
    session(false, [G::FS_IPV6])
    flow_crosses({ 'family' => 'flow_spec', 'start' => '2001:db8::/48', 'count' => 300, 'protocol' => 58,
                   'source' => '2001:db8:ffff::/48', 'attributes' => { 'as_path' => [OUR_AS] } }, G::FS_IPV6)
  end

  # RFC 8955 section 8: one RD per VRF, which GoBGP reads back as its
  # type, administrator and assigned number; the route target per VRF is
  # stated by hand.
  def test_vpn_flow_spec
    session(false, [G::FS_VPN])
    flow_crosses({ 'family' => 'flow_spec_vpn', 'start' => '10.0.0.0/24', 'count' => 200, 'vrfs' => 3,
                   'rd' => '65000:1', 'route_target' => '65000:100', 'destination_port' => 443,
                   'attributes' => { 'as_path' => [OUR_AS] } }, G::FS_VPN) do |want, ext|
      n = want['rd'].split(':').last.to_i
      assert_equal(["65000:#{99 + n}"], ext.collect { |c| c['value'] }, "the route target of #{want['rd']}")
    end
  end

  # ---- phase 4d: EVPN ---------------------------------------------------

  # GoBGP's EVPN table, by RD and by the field that steps: the MAC of
  # route type 2, the originator of type 3, the prefix of type 5. Read
  # from each path's NLRI and not from the table's keys.
  def evpn_held
    held = {}
    (@router.rib_family(G::EVPN) || {}).each_value do |paths|
      paths.each do |p|
        v = p['nlri']['value']
        step = p['nlri']['type'] == 3 ? v['ip'] : (v['mac'] || v['prefix'])
        held[["#{v['rd']['admin']}:#{v['rd']['assigned']}", step]] = p
      end
    end
    held
  end

  # A label as GoBGP prints it, the whole three-octet field: the label in
  # the high 20 bits and the bottom of stack bit set, so 16 is 257. The
  # EVPN lab test records two routers reading it that way.
  def field(label) ; (label << 4) | 1 ; end

  # An EVPN feed into GoBGP. Per sampled row it reads the route type, the
  # RD, the Ethernet Tag ID and the fields of that type, the next hop of
  # RFC 7432 section 14 and the AS_PATH, then hands the row and the path
  # to a block, withdraws and waits for an empty table.
  def evpn_crosses(spec)
    g = BGP::Gen.new(spec)
    total = g.total
    g.updates.each { |u| @peer.send_message u }
    wait_for("GoBGP to hold #{total} EVPN routes", :timeout => 60) { count_in(G::EVPN) == total }
    held = evpn_held
    rows = g.expected.to_a
    (0..9).collect { |k| (rows.size - 1) * k / 9 }.uniq.each do |i|
      want = rows[i]
      path = held[[want['rd'], want['mac'] || want['originator'] || want['prefix']]]
      assert_not_nil(path, "GoBGP holds #{want.inspect}")
      v = path['nlri']['value']
      assert_equal(want['route_type'], path['nlri']['type'])
      assert_equal(want['ethernet_tag'], v['etag'])
      case want['route_type']
      when 2
        assert_equal([want['ip'], [field(want['label'])]], [v['ip'], v['labels']], "route #{i}")
      when 5
        assert_equal([want['gateway'], field(want['label'])], [v['gateway'], v['label']], "route #{i}")
      end
      a = G.attrs(path)
      assert_equal(want['next_hop'], a[14]['nexthop'], 'RFC 7432 section 14')
      assert_equal(want['as_path'], G.as_path(path))
      yield i, want, path, a if block_given?
    end
    g.withdrawals.each { |u| @peer.send_message u }
    wait_for('GoBGP to hold no EVPN route', :timeout => 60) { count_in(G::EVPN) == 0 }
    g
  end

  # 2000 MACs in two EVIs. The route target per EVI and the MAC Mobility
  # sequence number per hundred routes are stated by hand from the
  # route's number: a generator that put one EVI's or one group's value
  # on every route would agree with its own expected.
  def test_evpn_mac_ip_routes
    session(false, [G::EVPN])
    evpn_crosses('family' => 'evpn', 'route_type' => 2, 'start' => '00:11:22:00:00:00', 'count' => 1000,
                 'ip' => '10.0.0.1', 'label' => { 'step' => { 'start' => 16, 'by' => 1 } },
                 'ethernet_tag' => { 'cycle' => [10, 20] }, 'rd' => '65000:1', 'vrfs' => 2,
                 'route_target' => '65000:100', 'group' => 100,
                 'mac_mobility' => { 'step' => { 'start' => 1, 'by' => 1 } },
                 'router_mac' => '00:00:5e:00:53:01',
                 'attributes' => { 'as_path' => [OUR_AS], 'next_hop' => '192.0.2.1' }) do |i, want, path, a|
      assert_equal("65000:#{1 + i / 1000}", want['rd'])
      assert_equal('single-homed', path['nlri']['value']['esi'], 'RFC 7432 section 5: an ESI of zero')
      assert_equal([{ 'type' => 0, 'subtype' => 2, 'value' => "65000:#{100 + i / 1000}" },
                    { 'type' => 6, 'subtype' => 0, 'sequence' => 1 + i / 100, 'is_sticky' => false },
                    { 'type' => 6, 'subtype' => 3, 'mac' => '00:00:5e:00:53:01' }],
                   a[EXT_COMMUNITIES]['value'], "route #{i}")
    end
  end

  # 200 PEs, each with its PMSI Tunnel naming itself (RFC 7432 section
  # 11.2), so 200 messages. GoBGP prints the label field whole, and the
  # PMSI Tunnel's label has no bottom of stack bit, so 10 is 160.
  def test_evpn_inclusive_multicast_routes
    session(false, [G::EVPN])
    evpn_crosses('family' => 'evpn', 'route_type' => 3, 'start' => '10.9.0.1', 'count' => 200,
                 'rd' => '192.0.2.1:7', 'ethernet_tag' => 100, 'pmsi_label' => 10,
                 'attributes' => { 'as_path' => [OUR_AS], 'next_hop' => '192.0.2.1' }) do |i, want, path, a|
      assert_equal(IPAddr.new(IPAddr.new('10.9.0.1').to_i + i, Socket::AF_INET).to_s, path['nlri']['value']['ip'])
      assert_equal({ 'type' => 22, 'is-leaf-info-required' => false, 'tunnel-type' => 6, 'label' => 160,
                     'tunnel-id' => want['originator'] }, a[22])
    end
  end

  def test_evpn_ip_prefix_routes
    session(false, [G::EVPN])
    evpn_crosses('family' => 'evpn', 'route_type' => 5, 'start' => '10.1.0.0/24', 'count' => 1000,
                 'rd' => '65000:5', 'gateway' => '10.0.0.254', 'label' => 500,
                 'attributes' => { 'as_path' => [OUR_AS], 'next_hop' => '192.0.2.1' }) do |i, _want, path|
      assert_equal("#{IPAddr.new(IPAddr.new('10.1.0.0').to_i + i * 256, Socket::AF_INET)}/24",
                   path['nlri']['value']['prefix'], "route #{i}, stated by hand")
    end
    evpn_crosses('family' => 'evpn', 'route_type' => 5, 'start' => '2001:db8::/64', 'count' => 500,
                 'rd' => '65000:6', 'router_mac' => '00:00:5e:00:53:01', 'label' => 500,
                 'attributes' => { 'as_path' => [OUR_AS], 'next_hop' => '2001:db8::1' }) do |_i, _want, path, a|
      assert_equal('::', path['nlri']['value']['gateway'], 'RFC 9136 section 3.1: no gateway is zero')
      assert_equal([{ 'type' => 6, 'subtype' => 3, 'mac' => '00:00:5e:00:53:01' }], a[EXT_COMMUNITIES]['value'])
    end
  end
end
