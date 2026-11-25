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
require 'bgp4r'
require 'bgp/daemon'
require 'test/functional/lab/lab_helper'

# bgp4r sends an EVPN route and FRR says what it made of it: the twin of
# evpn_gobgp_test.rb, and the second implementation that makes the first
# one's agreement worth something. Two bgp4r speakers agreeing proves
# only that they agree, which is how the inverted ADD-PATH field survived
# for years. No Docker and no zebra.
#
# **FRR reads more fields back by name than GoBGP does**, which is the
# reason to have both rather than one: its JSON carries `routeType`,
# `ethTag`, `macLen`, `mac`, `ipLen`, `ip` and `esi` as separate keys,
# where GoBGP renders route type 2 as one string. So the two tests check
# overlapping but different things, and neither is redundant.
#
# **FRR 8.4.4 implements route types 1 to 5, the same five as GoBGP**,
# and discards the other six in silence: no log line about the route, no
# error, no reset. A silent discard is the worse one to meet
# unknowingly, which is why it is asserted. docs/evpn.md section 9 has
# the table.
class EvpnFrrTest < Test::Unit::TestCase
  OUR_AS = 65001
  THEIR_AS = 65002

  E = BGP::Evpn
  F = LabHelper::Frr

  # The major versions these expectations were measured against, the same
  # shape and the same reason as flow_spec_frr_test.rb's.
  # 8.4.4, and 10.5.1 on the owner's VM on 2026-11-04 once the route
  # types 6 to 11 case counted UPDATEs rather than reading a debug line
  # 10.5.1 does not write: 9 tests, 55 assertions, all passing.
  MEASURED = (8..10).freeze

  # The cases of docs/design/evpn.md, pull request 5, a bgp4rd leaf and
  # FRR reading each other's types 2 and 3, were measured against 10.5.1
  # only, on the owner's VM on 2026-11-25.
  LEAF_MEASURED = (10..10).freeze

  # RFC 7432 section 5, a Type 0 ESI. FRR prints the ten octets as they
  # are, where GoBGP names the Type octet, so between them both readings
  # of the field are covered.
  ESI = '00:11:22:33:44:55:66:77:88:99'.freeze

  def setup
    unless F.available?
      flunk('FRR bgpd is not installed') if ENV['LAB_REQUIRE_FRR'] == '1'
      omit('FRR bgpd is not installed')
    end
    major = F.major
    unless F.measured?(MEASURED, major)
      omit("measured against FRR #{MEASURED}, found #{major.inspect}: " \
           're-measure before asserting')
    end
    @listeners = []
    @routers = []
  end

  def teardown
    @routers.each { |r| r.down }
    # On a failure the answer is in the router's own log: an OPEN it
    # refused, or what it made of an UPDATE.
    puts "\n== bgpd\n#{@routers.collect(&:log).join}" unless passed?
    @listeners.each do |server, neighbor, thread|
      thread.kill if thread
      neighbor.close
      server.close unless server.closed?
    end
  rescue IOError, SystemCallError
  end

  def session(more_peers: [])
    server = TCPServer.new('127.0.0.1', 0)
    n = BGP::Neighbor.new(4, OUR_AS, 180, '0.0.0.1', '127.0.0.2', '127.0.0.1')
    n.add_cap BGP::OPT_PARM::CAP::Mbgp.new(25, 70)
    thread = Thread.new do
      begin
        while (s = server.accept)
          n.start_session(s)
        end
      rescue IOError, SystemCallError
      end
    end
    @listeners << [server, n, thread]
    router = F.new(:local => '127.0.0.2', :as => THEIR_AS,
                   :router_id => '10.0.0.2', :peer => '127.0.0.1',
                   :peer_as => OUR_AS, :port => server.addr[1],
                   :ipv6 => false, :families => [F::EVPN], :more_peers => more_peers)
    @routers << router
    router.up
    assert(wait_for { n.is_established? }, "the session came up\n#{router.log}")
    [n, router]
  end

  def wait_for(timeout = 30)
    deadline = Time.now + timeout
    loop do
      return true if yield
      return false if Time.now > deadline
      sleep 0.2
    end
  end

  def announce(n, route, withdraw = false)
    nlri = BGP::Evpn.new(route)
    mp = if withdraw
           BGP::Mp_unreach.new(:safi => 70, :nlris => [nlri])
         else
           BGP::Mp_reach.new(:safi => 70, :nexthop => '10.0.0.1',
                             :nlris => [nlri])
         end
    n.send_update BGP::Update.new(
      BGP::Path_attribute.new(BGP::Origin.new(0),
                              BGP::As_path.new(OUR_AS), mp))
  end

  # The one route FRR holds in the EVPN table, as [key, path]. The key is
  # FRR's own rendering of the NLRI, which is the whole reason it is
  # worth asserting: it prints the fields back in the order and the shape
  # its own legend describes, so the key is a second implementation
  # reading our octets. Treat the exact text as FRR's and not
  # contractual, the way the flow spec keys are treated.
  def installed(router)
    rib = nil
    assert(wait_for { rib = router.evpn_rib; rib && rib.size == 1 },
           "FRR to hold one EVPN route, held #{rib && rib.size} " \
           "(waited 30s)\n#{router.log}")
    key, paths = rib.first
    [key, paths.find { |p| p['bestpath'] } || paths.first]
  end

  # Route type 1, RFC 7432 section 7.1. FRR's legend calls its fields
  # `[1]:[EthTag]:[ESI]:[IPlen]:[VTEP-IP]:[Frag-id]`.
  #
  # **Which JSON keys FRR carries is per route type, not uniform**, and
  # that is worth knowing before writing another of these: a route type 2
  # path has `ethTag`, `macLen`, `mac`, `ipLen`, `ip` and `esi` as
  # separate keys, and a route type 1 path has **none of them**. Its tag
  # and its ESI appear only inside the prefix key string. Measured on
  # 2026-10-30, after an assertion on `path['ethTag']` here answered nil.
  # So this reads them off the key, which is still FRR reading our octets
  # and not ours reading them back.
  def test_frr_reads_an_ethernet_ad_route_back
    n, router = session
    announce(n, E::Ethernet_ad.new([100, 200], E::Esi.new(ESI), 42, 100))
    key, path = installed(router)

    assert_equal("[1]:[42]:[#{ESI}]:[32]:[0.0.0.0]:[0]", key)
    assert_equal(1, path['routeType'])
    assert_equal('10.0.0.1', path['nexthops'].first['ip'])
    assert_nil(path['ethTag'], "FRR carries no ethTag key for this route type")
    assert_nil(path['esi'], 'nor an esi key, where route type 2 has both')
  end

  # Route type 2, RFC 7432 section 7.2, and **the case FRR reads back
  # better than GoBGP does**: every field under its own key, including
  # the two lengths section 14 fixes at 48 bits for the MAC and leaves
  # optional for the IP.
  def test_frr_reads_a_mac_ip_advertisement_route_field_by_field
    n, router = session
    announce(n, E::Mac_ip_advertisement.new([100, 200], E::Esi.new(ESI), 10,
                                            'aa:bb:cc:dd:ee:ff', '10.0.0.1', 100))
    key, path = installed(router)

    assert_equal('[2]:[10]:[48]:[aa:bb:cc:dd:ee:ff]:[32]:[10.0.0.1]', key)
    assert_equal(2, path['routeType'])
    assert_equal(10, path['ethTag'])
    # The two lengths are in bits, which is the detail memory reverses
    # and which section 14 states: "The MAC Address Length field is in
    # bits, and it is set to 48."
    assert_equal(48, path['macLen'])
    assert_equal('aa:bb:cc:dd:ee:ff', path['mac'])
    assert_equal(32, path['ipLen'])
    assert_equal('10.0.0.1', path['ip'])
    assert_equal(ESI, path['esi'])
  end

  # Route type 3, RFC 7432 section 7.3.
  def test_frr_reads_an_inclusive_multicast_route_back
    n, router = session
    announce(n, E::Inclusive_multicast.new([100, 200], 77, '10.0.0.1'))
    key, path = installed(router)

    assert_equal('[3]:[77]:[32]:[10.0.0.1]', key)
    assert_equal(3, path['routeType'])
    assert_equal(77, path['ethTag'])
  end

  # Route type 4, RFC 7432 section 7.4, whose key has no Ethernet Tag ID
  # because the layout has none.
  def test_frr_reads_an_ethernet_segment_route_back
    n, router = session
    announce(n, E::Ethernet_segment.new([100, 200], E::Esi.new(ESI), '10.0.0.1'))
    key, path = installed(router)

    assert_equal("[4]:[#{ESI}]:[32]:[10.0.0.1]", key)
    assert_equal(4, path['routeType'])
  end

  # Route type 5, RFC 9136 section 3.1, with the prefix length and the
  # prefix read back out of a field bgp4r does not pack down.
  #
  # **FRR cannot vouch for the GW IP Address and this test says so
  # rather than quietly not checking it.** Measured on 2026-10-30: FRR
  # 8.4.4's own debug line prints `gateway IP 2.0.0.0` for every non-zero
  # gateway we send, 10.0.0.9, 192.0.2.1, 1.2.3.4 and 255.255.255.255
  # alike, and prints no gateway at all when the field is zero. So it
  # reads the four octets well enough to tell zero from non-zero and then
  # renders the wrong thing; 2 is AF_INET, which is what a struct whose
  # first member is the family prints as an address. A display bug on
  # FRR's side, recorded and not filed, per the standing decision that
  # the job here is bgp4r catching up. `evpn_gobgp_test.rb` is the check
  # on those octets.
  def test_frr_reads_an_ip_prefix_route_back_but_not_its_gateway
    n, router = session
    announce(n, E::Ip_prefix_route.new([100, 200], E::Esi.new, 20,
                                       '10.0.0.0/8', '10.0.0.9', 500))
    key, path = installed(router)

    assert_equal('[5]:[20]:[8]:[10.0.0.0]', key)
    assert_equal(5, path['routeType'])
    assert_equal(20, path['ethTag'])
    # The label, which FRR logs as the whole 3-octet field exactly as
    # GoBGP does: 500 in the high 20 bits with the low bit set is
    # 0x1f41, 8001. Two implementations reading our Label the same way is
    # what makes that worth asserting.
    assert(wait_for(10) { router.log.to_s =~ /\[5\]:\[20\]:\[8\]:\[10\.0\.0\.0\].*label 8001/ },
           "FRR to log the label as 8001\n#{router.log}")
    # And the divergence, asserted so it cannot change without anyone
    # noticing. If a later FRR prints the real gateway, this is the line
    # to update and the note above is the one to strike.
    assert_match(/gateway IP 2\.0\.0\.0/, router.log.to_s,
                 'FRR 8.4.4 prints a constant gateway whatever we send')
  end

  # Several route types in one attribute, the RFC 7432 section 7 framing
  # under its own test, since one wrong Length desynchronises the list.
  def test_frr_reads_three_route_types_in_one_attribute
    n, router = session
    nlris = [E::Ethernet_ad.new([100, 200], E::Esi.new(ESI), 0, 100),
             E::Inclusive_multicast.new([100, 200], 5, '10.0.0.5'),
             E::Ip_prefix_route.new([100, 200], E::Esi.new, 7,
                                    '192.0.2.0/24', nil, 300)]
               .collect { |r| BGP::Evpn.new(r) }
    n.send_update BGP::Update.new(
      BGP::Path_attribute.new(
        BGP::Origin.new(0), BGP::As_path.new(OUR_AS),
        BGP::Mp_reach.new(:safi => 70, :nexthop => '10.0.0.1',
                          :nlris => nlris)))

    rib = nil
    assert(wait_for { rib = router.evpn_rib; rib && rib.size == 3 },
           "FRR to hold three EVPN routes, held #{rib && rib.size} " \
           "(waited 30s)\n#{router.log}")
    types = rib.values.collect { |paths| paths.first['routeType'] }.sort
    assert_equal([1, 3, 5], types, 'all three arrived whole')
    assert_equal(3, router.evpn_count, "FRR's own count agrees")
  end

  # A withdrawal, through the other parse loop on our side.
  def test_frr_drops_an_evpn_route_we_withdraw
    n, router = session
    route = E::Inclusive_multicast.new([100, 200], 0, '10.0.0.1')
    announce(n, route)
    installed(router)

    announce(n, route, true)
    assert(wait_for { router.evpn_count == 0 },
           "FRR to drop the route (waited 30s)\n#{router.log}")
    assert_equal({}, router.evpn_rib)
  end

  # **FRR 8.4.4 discards route types 6 to 11 in silence**, which is the
  # finding worth pinning: its log shows the UPDATE arriving and never a
  # line about the route, nothing reaches its table, and the session
  # stays up. GoBGP at least says `Unknown EVPN Route type: N`.
  #
  # A silent discard is the worse one to meet unknowingly, which is the
  # same reason flow spec part 5 asserted FRR's silent discard of a VPN
  # rule rather than leaving it as a note.
  def test_frr_discards_the_six_route_types_it_does_not_implement_in_silence
    n, router = session
    routes = [
      E::Selective_multicast.new([100, 200], 10, nil, '232.1.1.1', '10.0.0.1', :v2),
      E::Membership_report_synch.new([100, 200], E::Esi.new(ESI), 100, nil,
                                     '232.1.1.1', '10.0.0.9', [:v2]),
      E::Leave_synch.new([100, 200], E::Esi.new(ESI), 100, nil, '232.1.1.1',
                         '10.0.0.9', 100, [:v2]),
      E::Per_region_i_pmsi.new([100, 200], 100, '00090000fde80000'),
      E::S_pmsi.new([100, 200], 100, nil, '232.1.1.1', '10.0.0.9'),
      E::Leaf_a_d.new(BGP::Evpn.new(
        E::S_pmsi.new([100, 200], 100, nil, '232.1.1.1', '10.0.0.9')), '10.0.0.9'),
    ]
    routes.each { |route| announce(n, route) }
    sleep 3

    assert_equal(0, router.evpn_count, 'none of the six reached the table')
    assert(n.is_established?, 'and the session is still up')
    # The UPDATEs did arrive, so this is a discard and not a drop on our
    # side: without this the test would pass against a bgp4r that sent
    # nothing at all. Read from FRR's own counter and not its debug log,
    # which on 10.5.1 has no `rcvd UPDATE` line for these six at all.
    assert_equal(routes.size, router.updates_received,
                 'FRR counted every one of the UPDATEs arriving')
    # And said nothing about any of the six, where 8.4.4 names every
    # route type it does accept with a `rcvd RD ... l2vpn evpn` line.
    refute_match(/rcvd RD .* l2vpn evpn/, router.log.to_s,
                 'FRR named no route, which is the silent part')

    # A route type it does know still installs, so the family is not dead.
    announce(n, E::Inclusive_multicast.new([100, 200], 99, '10.0.0.99'))
    key, _path = installed(router)
    assert_equal('[3]:[99]:[32]:[10.0.0.99]', key)
  end

  # ---- A bgp4rd leaf and FRR: docs/design/evpn.md, pull request 5 ----
  #
  # **What bgp4r sends is built by bgp4rd's own exporter**,
  # Daemon::EvpnExporter#updates, so FRR reads the UPDATEs a leaf sends.
  # **What FRR sends is read by bgp4rd's own path**: the EVPN table's
  # Feed, then the MAC-VRFs, which say what they would write into
  # vtep4rd. The full leaf, vtep4rd and the data plane, is routescope's
  # lab 3, `evpn-vxlan-frr`.
  #
  # **FRR does not originate types 2 and 3 here.** It learns its VNIs and
  # MACs from zebra and the kernel's VXLAN, and these tests run bgpd
  # alone, so it has none. So the routes FRR sends bgp4rd are ones it
  # received from a leaf and passed on, on a second eBGP session: their
  # attributes are FRR's encoding, read back by bgp4rd, and their NLRI
  # are FRR's rebuild of them. What FRR itself puts in a type 3 route
  # (its PMSI Tunnel, its RD, ET:8) is in routescope's lab 3 fixtures.

  # The leaf: its VTEP address, an IP FRR accepts as a next hop (see
  # F::NEXT_HOP), its MAC-VRF and its AS.
  VTEP = F::NEXT_HOP
  # An odd VNI over 4095, so Label1's bottom bit and its upper octet
  # both carry part of it (RFC 8365 section 5.1.3).
  VNI = 10_001
  RD = "#{VTEP}:#{VNI}".freeze
  RT = '65000:100'.freeze
  HOST = '02:00:00:00:01:01'.freeze

  LeafSession = Struct.new(:address) do
    def ebgp? ; true ; end
    def local_ip ; VTEP ; end
  end
  LeafSpeaker = Struct.new(:peers, :my_as, :local_address, :router_id)

  def leaf_measured
    omit("measured against FRR #{LEAF_MEASURED}") unless F.measured?(LEAF_MEASURED, F.major)
  end

  def exporter
    BGP::Daemon::EvpnExporter.new(LeafSpeaker.new([], OUR_AS, VTEP, '10.0.0.1'))
  end

  # A leaf's type 3 for VNI and one local MAC, with MAC Mobility
  # sequence seq, as Rib::Macvrfs#exports gives them.
  def leaf_routes(seq: 3)
    x = BGP::Rib::Macvrfs::Export
    [x.new(VNI, RD, 3, nil, nil, [RT]), x.new(VNI, RD, 2, HOST, seq, [RT])]
  end

  # FRR's detailed view of one route, the path it chose. Its keys are
  # FRR's: `vni` on a type 2 path, `pmsi` on a type 3.
  def frr_detail(router, key)
    path = nil
    assert(wait_for do
             rd = (router.vty_json('show bgp l2vpn evpn route detail json') || {})[RD]
             path = rd && rd[key] && rd[key]['paths'].flatten.find { |p| p.dig('bestpath', 'overall') }
           end, "FRR to hold #{key} under #{RD}\n#{router.log}")
    path
  end

  # FRR reads the routes a bgp4rd leaf sends: RFC 7432 section 7.3 and
  # 11.2 for type 3, with RFC 8365 section 5.1.3's VNI in the PMSI
  # Tunnel's label; section 7.2 for type 2, the VNI in Label1 and section
  # 7.7's sequence; RFC 8365 section 5.1.3's Encapsulation, ET:8, on both.
  def test_frr_reads_what_a_bgp4rd_leaf_sends
    leaf_measured
    n, router = session
    exporter.updates(LeafSession.new('127.0.0.2'), leaf_routes, []).each { |u| n.send_update(u) }

    imet = frr_detail(router, "[3]:[0]:[32]:[#{VTEP}]")
    assert_equal({ 'tunnelType' => 'Ingress Replication', 'label' => VNI }, imet['pmsi'])
    assert_equal("RT:#{RT} ET:8", imet.dig('extendedCommunity', 'string'))
    assert_equal([VTEP], imet['nexthops'].collect { |h| h['ip'] })
    # The PMSI Tunnel's type as FRR read it off the wire: 6 is Ingress
    # Replication (RFC 6514 section 5). The JSON does not give the
    # tunnel identifier; this line is FRR's own account of the attribute.
    assert_match(/rcvd UPDATE w\/ attr: nexthop #{Regexp.escape(VTEP)}, extcommunity RT:#{RT} ET:8, pmsi tnltype 6/,
                 router.log.to_s)

    mac = frr_detail(router, "[2]:[0]:[48]:[#{HOST}]")
    assert_equal(VNI.to_s, mac['vni'], 'Label1 read as the whole 24-bit VNI')
    assert_equal("RT:#{RT} ET:8 MM:3", mac.dig('extendedCommunity', 'string'))
    assert_equal([VTEP], mac['nexthops'].collect { |h| h['ip'] })
  end

  # The leaf's sequence goes from 4294967295 to 0 and then it withdraws
  # its MAC: FRR takes each as the leaf sends it. A route from the same
  # peer replaces the one before whatever its sequence, so this says what
  # FRR reads, not which of two leaves' sequences it prefers; that is lab
  # 3's wraparound scenario (decision 4).
  def test_frr_follows_a_bgp4rd_leafs_sequence_and_withdrawal
    leaf_measured
    n, router = session
    leaf = LeafSession.new('127.0.0.2')
    x = exporter
    x.updates(leaf, leaf_routes(seq: 4_294_967_295), []).each { |u| n.send_update(u) }
    key = "[2]:[0]:[48]:[#{HOST}]"
    assert_equal("RT:#{RT} ET:8 MM:4294967295", frr_detail(router, key).dig('extendedCommunity', 'string'))
    x.updates(leaf, [leaf_routes(seq: 0).last], []).each { |u| n.send_update(u) }
    assert(wait_for { frr_detail(router, key).dig('extendedCommunity', 'string') == "RT:#{RT} ET:8 MM:0" },
           "FRR to take sequence 0\n#{router.log}")
    x.updates(leaf, [], [leaf_routes.last]).each { |u| n.send_update(u) }
    assert(wait_for { router.evpn_count == 1 }, "FRR to drop the MAC and keep type 3\n#{router.log}")
  end

  # bgp4rd reads what FRR sends: a leaf's routes passed on by FRR to a
  # second session, read by the EVPN table and imported by a MAC-VRF.
  # Every reason a MAC-VRF refuses a route (encapsulation, pmsi, vni,
  # esi) passes, so it would write the flood VTEP and the MAC into
  # vtep4rd.
  def test_bgp4rd_reads_the_evpn_routes_frr_sends
    leaf_measured
    server = TCPServer.new('127.0.0.3', 0)
    b = BGP::Neighbor.new(4, 65003, 180, '10.0.0.3', '127.0.0.2', '127.0.0.3')
    b.add_cap BGP::OPT_PARM::CAP::Mbgp.new(25, 70)
    table = BGP::Rib::EvpnTable.new(local_as: 65003, router_id: '10.0.0.3')
    table.attach(b)
    thread = Thread.new do
      begin
        while (s = server.accept)
          b.start_session(s)
        end
      rescue IOError, SystemCallError
      end
    end
    @listeners << [server, b, thread]
    n, router = session(more_peers: [{ address: '127.0.0.3', as: 65003, port: server.addr[1] }])
    assert(wait_for { b.is_established? }, "the second session came up\n#{router.log}")
    exporter.updates(LeafSession.new('127.0.0.2'), leaf_routes, []).each { |u| n.send_update(u) }

    assert(wait_for { table.size == 2 }, "bgp4r to hold both routes from FRR, held #{table.size}\n#{router.log}")
    rows = table.rows.collect do |r|
      r.values_at('route_type', 'rd', 'mac', 'originator', 'vni', 'next_hop', 'route_targets', 'encap', 'seq', 'pmsi', 'as_path')
    end
    assert_equal([[2, RD, HOST, '10.0.0.2', VNI, VTEP, [RT], 'VXLAN', 3, nil, "65002 #{OUR_AS}"],
                  [3, RD, nil, VTEP, VNI, VTEP, [RT], 'VXLAN', nil,
                   { 'type' => 'ingress_replication', 'id' => VTEP }, "65002 #{OUR_AS}"]], rows)

    vtep = Recorder.new
    macvrfs = BGP::Rib::Macvrfs.new(table: table, vtep: vtep, address: '10.0.0.3',
                                    macvrfs: BGP::Rib::Macvrf.list([{ 'vni' => VNI, 'import' => [RT] }],
                                                                   address: '10.0.0.3', as: 65003))
    macvrfs.sync!
    assert_equal([['vni.flood.add', { 'vni' => VNI, 'vtep' => VTEP }],
                  ['mac.add', { 'vni' => VNI, 'mac' => HOST, 'vtep' => VTEP, 'seq' => 3 }]],
                 vtep.orders.sort_by(&:first).reverse)
  end

  # vtep4rd as the MAC-VRFs see it (vtep4r vxlan/daemon/api.rb): VNI
  # in evpn mode, no MACs, and every order recorded.
  class Recorder
    attr_reader :orders

    def initialize ; @orders = [] ; end

    def call(method, params)
      case method
      when 'show.vnis' then [{ 'vni' => VNI, 'mode' => 'evpn', 'remote_vteps' => [] }]
      when 'show.macs' then []
      else @orders << [method, params] ; {}
      end
    end
  end

  # Nothing validates on the way out, per Conventions: a Length that
  # disagrees with its body crosses the socket and the router decides.
  #
  # **And this is the best result the EVPN lab gives, because it is
  # corroboration of a decision bgp4r had to make with no RFC naming
  # it.** FRR answers a malformed EVPN NLRI with `3/9 (UPDATE Message
  # Error/Optional Attribute Error)` and resets, which is exactly the
  # subcode and the action part 9 reports for the same octets. That
  # choice was derived rather than copied: RFC 7432 and RFC 9572 say
  # nothing about error handling, RFC 9251 section 9.7 asks for a session
  # reset without naming a subcode, and the 9 came from RFC 7606 section
  # 7.11 as the two MP_REACH findings already there do. An independent
  # implementation landing on both halves is worth more than either
  # reading on its own.
  #
  # **The two routers disagree here, and bgp4r is with FRR.** GoBGP keeps
  # the session up and holds nothing, which `evpn_gobgp_test.rb` asserts.
  # One router agreeing is not a quorum, so this is recorded as what each
  # does and not as a verdict on either.
  def test_frr_resets_with_3_9_on_a_route_no_rfc_allows
    n, router = session
    body = '00000064000000c8' + '00112233445566778899' + '00000064' + '00'
    liar = BGP::Evpn.new(['0118' + body].pack('H*').is_packed)
    assert_equal(24, liar.declared_len, 'bgp4r built the lie')
    n.send_update BGP::Update.new(
      BGP::Path_attribute.new(
        BGP::Origin.new(0), BGP::As_path.new(OUR_AS),
        BGP::Mp_reach.new(:safi => 70, :nexthop => '10.0.0.1',
                          :nlris => [liar])))

    assert(wait_for(15) { router.log.to_s =~ /NOTIFICATION: sent to neighbor \S+ 3\/9/ },
           "FRR to send 3/9 (waited 15s)\n#{router.log}")
    assert_match(/\[Error\] Error parsing NLRI/, router.log.to_s,
                 'and to say what it could not parse')
    assert_equal(0, router.evpn_count, 'nothing reached its table')
    # And bgp4r reports the same thing about the same octets, which is
    # the half this test exists to compare against.
    hex = '800e' + format('%02x', 9 + liar.to_shex.size / 2) +
          '001946' + '04' + '0a000001' + '00' + liar.to_shex
    pa = BGP::Path_attribute.new([hex].pack('H*').is_packed)
    assert_equal(1, pa.errors.size)
    assert_equal([9, :session_reset],
                 [pa.errors.first.subcode, pa.errors.first.action],
                 'part 9 chose the subcode and the action FRR sends')
  end

end
