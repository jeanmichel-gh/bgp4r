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
require 'test/functional/lab/lab_helper'

# bgp4r sends an EVPN route, AFI 25 SAFI 70, and GoBGP says what it made
# of it. The twin of flow_spec_gobgp_test.rb, and the same thing it is
# for: every bgp4r unit test reads octets bgp4r itself wrote, so none of
# them can say whether anyone else agrees. No Docker.
#
# **What a second implementation vouches for here, which no bgp4r test
# can**: the RFC 7432 section 7 framing, since a wrong Length
# desynchronises the whole list; the RD, Ethernet Tag ID, MAC and IP of
# each route type by name; the 10-octet ESI including its Type octet;
# the 3-octet MPLS Label field; RFC 9136's IP prefix and GW IP Address;
# the RFC 7432 section 14 next hop; and a withdrawal.
#
# **GoBGP 3.23.0 implements route types 1 to 5 and no more**, measured
# rather than assumed, so the five that a router will actually send are
# checked against it and the other six are checked for being ignored
# without the session dying. docs/evpn.md section 9 has the table.
class EvpnGobgpTest < Test::Unit::TestCase
  OUR_AS = 65001
  THEIR_AS = 65002

  E = BGP::Evpn
  G = LabHelper::Gobgpd

  # The version these expectations were measured against. GoBGP 4 was not
  # available here, and the route types it knows may differ, so a run
  # against another major says so rather than failing obscurely.
  MEASURED_MAJOR = 3

  # RFC 7432 section 5: the first octet of an ESI is its Type, so this is
  # a Type 0 ESI, "arbitrary", with 9 octets of value. GoBGP names the
  # type when it reads one back, which is what makes it worth sending a
  # non-zero one.
  ESI = '00:11:22:33:44:55:66:77:88:99'.freeze

  def setup
    unless G.available?
      flunk('gobgpd is not installed') if ENV['LAB_REQUIRE_GOBGPD'] == '1'
      omit('gobgpd is not installed')
    end
    @listeners = []
    @routers = []
  end

  def teardown
    @routers.each { |r| r.down }
    @listeners.each do |server, neighbor, thread|
      thread.kill if thread
      neighbor.close
      server.close unless server.closed?
    end
  rescue IOError, SystemCallError
  end

  # A bgp4r speaker listening on its own port, advertising AFI 25 SAFI 70
  # (RFC 4760), with a gobgpd configured for l2vpn-evpn dialling it.
  def session
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
    router = G.new(:local => '127.0.0.2', :as => THEIR_AS,
                   :router_id => '10.0.0.2', :peer => '127.0.0.1',
                   :peer_as => OUR_AS, :port => server.addr[1],
                   :ipv6 => false, :families => [G::EVPN])
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

  # One EVPN route in one MP_REACH, or an MP_UNREACH when withdrawing.
  def announce(n, route, withdraw = false)
    nlri = BGP::Evpn.new(route)
    mp = if withdraw
           BGP::Mp_unreach.new(:safi => 70, :nlris => [nlri])
         else
           # RFC 7432 section 14: the next hop is the advertising PE's
           # address, unlike flow spec where it must be absent.
           BGP::Mp_reach.new(:safi => 70, :nexthop => '10.0.0.1',
                             :nlris => [nlri])
         end
    n.send_update BGP::Update.new(
      BGP::Path_attribute.new(BGP::Origin.new(0),
                              BGP::As_path.new(OUR_AS), mp))
  end

  # The one route GoBGP holds in the EVPN family, as [key, path].
  def installed(router)
    found = nil
    assert(wait_for { found = router.only_rule(G::EVPN) },
           "GoBGP to hold an EVPN route (waited 30s)\n#{router.log}")
    found
  end

  # The nlri value of a path, which is where GoBGP puts the route type's
  # own fields, keyed by the names RFC 7432 and RFC 9136 use.
  def nlri(path)
    (path['nlri'] || {})['value'] || {}
  end

  def test_the_measured_version_is_the_one_running
    assert_equal(MEASURED_MAJOR, G.major,
                 'these expectations were measured against another major; ' \
                 'the route types a version knows may differ')
  end

  # Route type 1, RFC 7432 section 7.1: RD, ESI, Ethernet Tag ID, label.
  #
  # **The ESI reading is the part worth having.** GoBGP names the Type
  # octet, so `ESI_ARBITRARY` is a second implementation confirming that
  # our first octet is the RFC 7432 section 5 Type and the other nine are
  # its value, which nothing on our side can vouch for.
  def test_gobgp_reads_an_ethernet_ad_route_back
    n, router = session
    announce(n, E::Ethernet_ad.new([100, 200], E::Esi.new(ESI), 0, 100))
    key, path = installed(router)

    assert_equal('[type:A-D][rd:100:200][esi:ESI_ARBITRARY | ' \
                 '11:22:33:44:55:66:77:88:99][etag:0]', key)
    v = nlri(path)
    assert_equal(1, path['nlri']['type'])
    assert_equal({ 'type' => 0, 'admin' => 100, 'assigned' => 200 }, v['rd'])
    assert_equal(0, v['etag'])
    assert_equal('ESI_ARBITRARY | 11:22:33:44:55:66:77:88:99', v['esi'])
    # **The label comes back as the whole 3-octet field, not the 20-bit
    # label.** We sent label 100, which BGP::Label writes in the high 20
    # bits with the low bit set, so the field is 0x000641 and GoBGP reads
    # 1601. That makes this an assertion on our Label reuse down to the
    # bottom bit, and FRR reads the same number, so two implementations
    # agree. Do not "fix" it to 100.
    assert_equal(1601, v['label'])
  end

  # Route type 2, RFC 7432 section 7.2, the largest layout in the family:
  # an optional IP alongside the MAC, with section 14's field rules.
  def test_gobgp_reads_a_mac_ip_advertisement_route_back
    n, router = session
    announce(n, E::Mac_ip_advertisement.new([100, 200], E::Esi.new(ESI), 10,
                                            'aa:bb:cc:dd:ee:ff', '10.0.0.1', 100))
    key, path = installed(router)

    assert_equal('[type:macadv][rd:100:200][etag:10]' \
                 '[mac:aa:bb:cc:dd:ee:ff][ip:10.0.0.1]', key)
    v = nlri(path)
    assert_equal(2, path['nlri']['type'])
    assert_equal('aa:bb:cc:dd:ee:ff', v['mac'])
    assert_equal('10.0.0.1', v['ip'], 'the optional IP of section 14')
    assert_equal(10, v['etag'])
    # A list here and a scalar in route type 1, which is GoBGP's shape
    # for the one field that may appear twice (MPLS Label1 and Label2).
    assert_equal([1601], v['labels'])
  end

  # Route type 3, RFC 7432 section 7.3, the one of the five with no ESI.
  def test_gobgp_reads_an_inclusive_multicast_route_back
    n, router = session
    announce(n, E::Inclusive_multicast.new([100, 200], 77, '10.0.0.1'))
    key, path = installed(router)

    assert_equal('[type:multicast][rd:100:200][etag:77][ip:10.0.0.1]', key)
    assert_equal(3, path['nlri']['type'])
    assert_equal(77, nlri(path)['etag'])
    assert_equal('10.0.0.1', nlri(path)['ip'])
  end

  # Route type 4, RFC 7432 section 7.4, RD plus ESI plus an address and
  # no Ethernet Tag ID.
  def test_gobgp_reads_an_ethernet_segment_route_back
    n, router = session
    announce(n, E::Ethernet_segment.new([100, 200], E::Esi.new(ESI), '10.0.0.1'))
    key, path = installed(router)

    assert_equal('[type:esi][rd:100:200][esi:ESI_ARBITRARY | ' \
                 '11:22:33:44:55:66:77:88:99][ip:10.0.0.1]', key)
    assert_equal(4, path['nlri']['type'])
    assert_equal('10.0.0.1', nlri(path)['ip'])
    refute(nlri(path).key?('etag'), 'section 7.4 has no Ethernet Tag ID')
  end

  # Route type 5, RFC 9136 section 3.1, and **the one case where GoBGP
  # vouches for something FRR cannot**: the GW IP Address. FRR 8.4.4
  # prints a constant for it whatever we send, so this is the only check
  # on those four octets that is not bgp4r's own opinion. See
  # docs/evpn.md section 9.
  def test_gobgp_reads_an_ip_prefix_route_and_its_gateway_back
    n, router = session
    announce(n, E::Ip_prefix_route.new([100, 200], E::Esi.new, 20,
                                       '10.0.0.0/8', '10.0.0.9', 500))
    key, path = installed(router)

    assert_equal('[type:Prefix][rd:100:200][etag:20][prefix:10.0.0.0/8]', key)
    v = nlri(path)
    assert_equal(5, path['nlri']['type'])
    # Section 3.1: the prefix length "specifies the number of bits in the
    # prefix" while the prefix is a 4-octet field, so bgp4r does not pack
    # it down. GoBGP reading 10.0.0.0/8 back out of four octets and a
    # separate length is that layout confirmed.
    assert_equal('10.0.0.0/8', v['prefix'])
    assert_equal('10.0.0.9', v['gateway'], 'the GW IP Address of section 3.1')
    assert_equal(20, v['etag'])
    assert_equal(8001, v['label'], '500 in the high 20 bits, as for route type 1')
    # Section 3.1: the ESI "MUST be all bytes zero" when it is not an
    # Overlay Index, and GoBGP has its own word for that.
    assert_equal('single-homed', v['esi'])
  end

  # RFC 7432 section 14: "The Next Hop field of the MP_REACH_NLRI
  # attribute of the route MUST be set to the IPv4 or IPv6 address of the
  # advertising PE." Unlike flow spec, where section 4 makes the length
  # 0, so this is the family where the next hop is a real address and the
  # AFI cannot say which family it is.
  def test_gobgp_reads_the_section_14_next_hop_back
    n, router = session
    announce(n, E::Inclusive_multicast.new([100, 200], 0, '10.0.0.1'))
    _key, path = installed(router)

    mp = G.attrs(path)[14]
    assert_not_nil(mp, 'an MP_REACH_NLRI arrived')
    assert_equal(25, mp['afi'])
    assert_equal(70, mp['safi'])
    assert_equal('10.0.0.1', mp['nexthop'])
  end

  # Several route types in one attribute, which is what the RFC 7432
  # section 7 framing is for: each NLRI is sliced by its own Length and
  # nothing else separates them, so one wrong Length desynchronises the
  # rest of the list. Three types at once is the case where that shows.
  def test_gobgp_reads_three_route_types_in_one_attribute
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
    assert(wait_for { rib = router.rib_family(G::EVPN); rib && rib.size == 3 },
           "GoBGP to hold three EVPN routes, held #{rib && rib.size} " \
           "(waited 30s)\n#{router.log}")
    types = rib.values.collect { |paths| paths.first['nlri']['type'] }.sort
    assert_equal([1, 3, 5], types, 'all three arrived whole')
  end

  # A withdrawal, which goes through the other parse loop on our side.
  def test_gobgp_drops_an_evpn_route_we_withdraw
    n, router = session
    route = E::Inclusive_multicast.new([100, 200], 0, '10.0.0.1')
    announce(n, route)
    installed(router)

    announce(n, route, true)
    assert(wait_for { router.rib_family(G::EVPN) == {} },
           "GoBGP to drop the route (waited 30s)\n#{router.log}")
  end

  # **GoBGP 3.23.0 implements route types 1 to 5 and no more**, measured
  # on 2026-10-30 rather than assumed. Each of the other six is ignored
  # with `Unknown EVPN Route type: N` in its log, the session stays up,
  # and nothing reaches its RIB.
  #
  # **Its log also says "Capability was disabled", and that overstates
  # what it did.** Measured: after an unknown route type, a route type 3
  # sent on the same session still installs. So the message names a
  # consequence GoBGP did not carry out, and a test that trusted it would
  # give each case its own session for no reason. That is why this one
  # sends all six down one session and then checks the family still works.
  def test_gobgp_ignores_the_six_route_types_it_does_not_implement
    n, router = session
    [E::Selective_multicast.new([100, 200], 10, nil, '232.1.1.1', '10.0.0.1', :v2),
     E::Membership_report_synch.new([100, 200], E::Esi.new(ESI), 100, nil,
                                    '232.1.1.1', '10.0.0.9', [:v2]),
     E::Leave_synch.new([100, 200], E::Esi.new(ESI), 100, nil, '232.1.1.1',
                        '10.0.0.9', 100, [:v2]),
     E::Per_region_i_pmsi.new([100, 200], 100, '00090000fde80000'),
     E::S_pmsi.new([100, 200], 100, nil, '232.1.1.1', '10.0.0.9'),
     E::Leaf_a_d.new(BGP::Evpn.new(
       E::S_pmsi.new([100, 200], 100, nil, '232.1.1.1', '10.0.0.9')), '10.0.0.9')
    ].each_with_index do |route, i|
      announce(n, route)
      type = i + 6
      assert(wait_for(10) { router.log.to_s =~ /Unknown EVPN Route type: #{type}\b/ },
             "GoBGP to log route type #{type} as unknown\n#{router.log}")
    end
    assert_equal({}, router.rib_family(G::EVPN), 'and none of them is held')
    assert(n.is_established?, 'the session is still up')

    # The family still works afterwards, which is what says the
    # "Capability was disabled" line overstates.
    announce(n, E::Inclusive_multicast.new([100, 200], 99, '10.0.0.99'))
    key, _path = installed(router)
    assert_equal('[type:multicast][rd:100:200][etag:99][ip:10.0.0.99]', key,
                 'a route type GoBGP knows still installs after an unknown one')
  end

  # Nothing validates on the way out, per Conventions, and this is where
  # that is worth the most: a Length that disagrees with the body goes on
  # the wire and the router decides. GoBGP keeps the session up and holds
  # nothing, which is its answer and not ours.
  def test_a_route_no_rfc_allows_reaches_gobgp_and_the_session_survives
    n, router = session
    # Route type 1 declaring 24 octets with 23 behind it.
    body = '00000064000000c8' + '00112233445566778899' + '00000064' + '00'
    liar = BGP::Evpn.new(['0118' + body].pack('H*').is_packed)
    assert_equal(24, liar.declared_len, 'bgp4r built the lie')
    n.send_update BGP::Update.new(
      BGP::Path_attribute.new(
        BGP::Origin.new(0), BGP::As_path.new(OUR_AS),
        BGP::Mp_reach.new(:safi => 70, :nexthop => '10.0.0.1',
                          :nlris => [liar])))
    sleep 2
    assert(n.is_established?, "the session is still up\n#{router.log}")
    assert_equal({}, router.rib_family(G::EVPN), 'and GoBGP held nothing')
  end

end
