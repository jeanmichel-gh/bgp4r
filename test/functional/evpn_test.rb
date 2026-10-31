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
require 'test/helpers/server'

# An EVPN UPDATE over a real session, RFC 7432 section 7 and RFC 9136
# section 3.1 and RFC 9251 sections 9.1 to 9.3, AFI 25 with SAFI 70.
#
# **This is the only test that proves the wiring sites agree with each
# other**, which is the same thing `flow_spec_test.rb` is for and for the
# same reason. Parts 1 to 4 are pure: every build-side unit test reads
# octets it wrote itself, and every parse-side one hands `Nlri.factory`
# octets the test wrote. Neither can say that what `Mp_reach#encode` puts
# on a socket is what `Mp_reach#parse` takes off it, and the sites that
# can disagree are exactly the ones this part changed.
#
# **The assertion that matters in every case is the class, not the hex.**
# Before the wiring the same UPDATE crossed the socket intact and came
# back as an `Attr::Raw` with an `Attr::Gap`, which is #116 keeping octets
# it cannot interpret: the session stayed up and nothing looked wrong, so
# a test checking only the session or the octets would have passed against
# the unwired library. The flow spec sabotage measured exactly that.
#
# BGP:: names are written out in full, see Conventions in CLAUDE.md. That
# includes the nested catcher, which does not see an include in the class
# around it, and which matters more here than usual: Neighbor logs an
# exception from an observer rather than raising it, so a wrong constant
# shows up as "nothing arrived" and says nothing about the name.
class EvpnSessionTest < Test::Unit::TestCase
  include BGP::TestHelpers

  SERVER_AS = 100
  CLIENT_AS = 200

  AFI  = 25
  SAFI = 70

  ESI = '00:11:22:33:44:55:66:77:88:99'.freeze

  # Queues the UPDATEs the server's Neighbor parsed.
  class UpdateCatcher
    def initialize
      @q = Queue.new
    end

    def update(msg)
      @q << msg if msg.is_a?(BGP::Update)
    end

    def size
      @q.size
    end

    # The next UPDATE, or nil after timeout seconds.
    def shift(timeout = 5)
      deadline = Time.now + timeout
      loop do
        return @q.shift if @q.size > 0
        return nil if Time.now > deadline
        sleep 0.02
      end
    end
  end

  def teardown
    @c.close if @c
    stop_server
  end

  # Brings up a session with the multiprotocol capability of RFC 4760 for
  # AFI 25 SAFI 70, advertised by both sides, and an observer on the
  # server. One Mbgp capability carries one (AFI, SAFI) pair.
  def session
    cap = BGP::OPT_PARM::CAP::Mbgp.new(AFI, SAFI)
    @port = start_server(0, cap)
    @catcher = UpdateCatcher.new
    @s.add_observer @catcher
    @c = BGP::Neighbor.new(4, CLIENT_AS, 180, '0.0.0.2', '127.0.0.1', '127.0.0.1')
    @c.add_cap cap
    @c.start :port => @port
    assert(wait_for { @s.is_established? }, 'the session came up')
    @catcher
  end

  def wait_for(timeout = 5)
    deadline = Time.now + timeout
    loop do
      return true if yield
      return false if Time.now > deadline
      sleep 0.02
    end
  end

  # Sends one UPDATE carrying the given MP attribute and returns the
  # MP_REACH or MP_UNREACH the far side parsed, after asserting that it
  # is one rather than an Attr::Raw.
  def crosses(catcher, mp, klass = BGP::Mp_reach)
    sent = BGP::Update.new(
      BGP::Path_attribute.new(BGP::Origin.new(0),
                              BGP::As_path.new(CLIENT_AS),
                              mp))
    @c.send_update sent

    got = catcher.shift
    assert_not_nil(got, 'the server parsed an UPDATE')
    assert_equal(sent.to_shex, got.to_shex, 'byte for byte across the socket')

    attr = got.path_attribute.find(klass)
    assert_not_nil(attr, "a #{klass}, not an Attr::Raw")
    assert_equal(0, got.path_attribute.errors.size, 'no protocol error')
    assert_equal(0, got.path_attribute.undecoded.size, 'and no coverage gap')
    assert_equal(AFI, attr.afi)
    assert_equal(SAFI, attr.safi)
    attr
  end

  def reach(nlris, nexthop = '10.0.0.1')
    BGP::Mp_reach.new(:safi => SAFI, :nexthop => nexthop, :nlris => nlris)
  end

  # Route type 1, RFC 7432 section 7.1, the simplest fixed layout.
  def test_an_ethernet_ad_route_crosses_a_session
    mpr = crosses(session,
                  reach([BGP::Evpn.new(
                    BGP::Evpn::Ethernet_ad.new([100, 200], ESI, 100, 500))]))
    assert_equal([BGP::Evpn], mpr.nlris.collect(&:class))
    r = mpr.nlris.first.route
    assert_instance_of(BGP::Evpn::Ethernet_ad, r)
    assert_equal(1, mpr.nlris.first.type)
    assert_equal([100, 200], r.rd.to_hash[:rd])
    assert_equal(ESI, r.esi.to_s)
    assert_equal(100, r.ethernet_tag_id.value)
    assert_equal(500, r.label.label)
  end

  # Route type 2, the largest layout, with both optional fields present.
  # Each is decided by the octets rather than by a flag, so this is the
  # case where a framing slip shows as the wrong fields rather than as a
  # failure.
  def test_a_mac_ip_route_with_both_optional_fields_crosses_a_session
    mpr = crosses(session,
                  reach([BGP::Evpn.new(
                    BGP::Evpn::Mac_ip_advertisement.new(
                      [100, 200], ESI, 100, '00:11:22:33:44:55',
                      '192.0.2.1', 500, 501))]))
    r = mpr.nlris.first.route
    assert_instance_of(BGP::Evpn::Mac_ip_advertisement, r)
    assert_equal('00:11:22:33:44:55', r.mac.to_s)
    assert_equal('192.0.2.1', r.ip.address)
    assert_equal(500, r.label1.label)
    assert_equal(501, r.label2.label, 'the second label survived the socket')
  end

  # And the same route type with neither optional field, which is the
  # other end of the six lengths RFC 7432 section 14 allows. A framing
  # error that happens to work for 40 octets need not work for 33.
  def test_a_mac_ip_route_with_neither_optional_field_crosses_a_session
    mpr = crosses(session,
                  reach([BGP::Evpn.new(
                    BGP::Evpn::Mac_ip_advertisement.new(
                      [100, 200], ESI, 100, '00:11:22:33:44:55'))]))
    r = mpr.nlris.first.route
    assert_instance_of(BGP::Evpn::Mac_ip_advertisement, r)
    assert(r.ip.empty?, 'no IP, as the sender wrote it')
    assert_nil(r.label2)
    assert_equal(33, r.encode.size)
  end

  # Route type 5, RFC 9136 section 3.1, whose family comes from the body
  # size alone. Nothing inside the NLRI says IPv6, so this is the one
  # route type a framing slip can turn into the wrong family.
  def test_an_ipv6_ip_prefix_route_crosses_a_session
    mpr = crosses(session,
                  reach([BGP::Evpn.new(
                    BGP::Evpn::Ip_prefix_route.new(
                      [100, 200], ESI, 100, '2001:db8::/32',
                      '2001:db8::1', 500))]))
    r = mpr.nlris.first.route
    assert_instance_of(BGP::Evpn::Ip_prefix_route, r)
    assert(r.v6?, 'read back as IPv6, from the body size alone')
    assert_equal('2001:db8::/32', r.ip_prefix)
    assert_equal('2001:db8::1', r.gateway)
    assert_equal(58, r.encode.size)
  end

  # Several NLRIs in one attribute, which is what the framing is for:
  # each is sliced by its own Length and nothing else separates them.
  # Three different route types, so one wrong length desynchronises the
  # rest and the types come back wrong.
  def test_three_route_types_in_one_attribute_cross_a_session
    mpr = crosses(session,
                  reach([BGP::Evpn.new(BGP::Evpn::Ethernet_ad.new([1, 1], ESI,
                                                                  0, 500)),
                         BGP::Evpn.new(BGP::Evpn::Inclusive_multicast.new(
                           [1, 1], 0, '10.0.0.9')),
                         BGP::Evpn.new(BGP::Evpn::Ethernet_segment.new(
                           [1, 1], ESI, '10.0.0.8'))]))
    assert_equal(3, mpr.nlris.size)
    assert_equal([1, 3, 4], mpr.nlris.collect(&:type))
    assert_equal([BGP::Evpn::Ethernet_ad,
                  BGP::Evpn::Inclusive_multicast,
                  BGP::Evpn::Ethernet_segment],
                 mpr.nlris.collect { |n| n.route.class })
    assert_equal('10.0.0.9', mpr.nlris[1].route.ip.address)
    assert_equal('10.0.0.8', mpr.nlris[2].route.ip.address)
  end

  # RFC 7432 section 14: "The Next Hop field of the MP_REACH_NLRI
  # attribute of the route MUST be set to the IPv4 or IPv6 address of the
  # advertising PE." The AFI is 25 either way, so the length is the only
  # thing that says which, and both have to survive the socket.
  def test_both_next_hop_families_cross_a_session
    route = BGP::Evpn.new(BGP::Evpn::Ethernet_ad.new([1, 1], ESI, 0, 500))
    mpr = crosses(session, reach([route], '10.0.0.1'))
    assert_equal('10.0.0.1', mpr.nexthops)

    mpr6 = crosses(@catcher, reach([route], '2001:db8::1'))
    assert_equal('2001:db8::1', mpr6.nexthops,
                 'a 16 octet next hop under AFI 25 reads as IPv6')
    assert_instance_of(BGP::Evpn::Ethernet_ad, mpr6.nlris.first.route)
  end

  # A withdrawal, which goes through Mp_unreach's own parse loop. That
  # loop is an independent copy of Mp_reach's, which the flow spec
  # sabotage measured: reverting only it failed exactly the withdrawal
  # case. So this test is all that covers the second loop.
  def test_a_withdrawal_crosses_a_session
    catcher = session
    mpu = BGP::Mp_unreach.new(
      :safi => SAFI,
      :nlris => [BGP::Evpn.new(BGP::Evpn::Mac_ip_advertisement.new(
        [100, 200], ESI, 100, '00:11:22:33:44:55', '192.0.2.1', 500))])
    attr = crosses(catcher, mpu, BGP::Mp_unreach)
    r = attr.nlris.first.route
    assert_instance_of(BGP::Evpn::Mac_ip_advertisement, r)
    assert_equal('192.0.2.1', r.ip.address)
  end

  # A route type bgp4r does not implement still crosses and still reads
  # back as an Evpn, because the framing is the family's and does not
  # depend on the route type being known. It degrades to Evpn::Unknown
  # rather than to an Attr::Raw, which is the whole point of the
  # keep-what-you-cannot-read class.
  def test_an_unimplemented_route_type_crosses_as_unknown
    mpr = crosses(session,
                  reach([BGP::Evpn.new(
                    BGP::Evpn::Unknown.new(9, ['0011223344556677'].pack('H*')))]))
    assert_instance_of(BGP::Evpn::Unknown, mpr.nlris.first.route)
    assert_equal(9, mpr.nlris.first.type)
    assert_equal('0011223344556677',
                 mpr.nlris.first.route.value.unpack1('H*'))
  end

  # Nothing validates on the way out, per Conventions. A Length that
  # disagrees with the body crosses the socket and comes back as an
  # Evpn::Unknown that replays it, because the route type cannot
  # reproduce those octets. The session stays up, which is what a
  # negative test wants: the router under test decides, not bgp4r.
  def test_a_route_no_rfc_allows_crosses_a_session
    catcher = session
    # Route type 1 declaring 24 octets with 23 behind it.
    body = '00000064000000c8' + '00112233445566778899' + '00000064' + '00'
    liar = BGP::Evpn.new(['0118' + body].pack('H*').is_packed)
    assert_equal(24, liar.declared_len)

    mpr = crosses(catcher, reach([liar]))
    assert_instance_of(BGP::Evpn::Unknown, mpr.nlris.first.route)
    assert_equal('0118' + body, mpr.nlris.first.to_shex)
    assert(@s.is_established?, 'and the session is still up')
  end

  # Route type 6, RFC 9251 section 9.1. The first route type whose body
  # is variable in three independent places, so a framing slip here
  # shows as the wrong fields rather than as a failure.
  def test_a_selective_multicast_route_crosses_a_session
    mpr = crosses(session,
                  reach([BGP::Evpn.new(
                    BGP::Evpn::Selective_multicast.new(
                      [100, 200], 100, '192.0.2.1', '232.1.1.1',
                      '10.0.0.9', [:v3]))]))
    r = mpr.nlris.first.route
    assert_instance_of(BGP::Evpn::Selective_multicast, r)
    assert_equal(6, mpr.nlris.first.type)
    assert_equal('192.0.2.1', r.source.address)
    assert_equal('232.1.1.1', r.group.address)
    assert_equal('10.0.0.9', r.originator.address)
    assert(r.flags.v3?)
    refute(r.flags.v2?)
  end

  # The (*,G) form of the same route, section 9.1.1: "In case of a (*,G)
  # Membership Report, the Multicast Source Length is set to 0" and the
  # address field is not used. The body is four octets shorter than the
  # case above, so the length field in front of each address is what the
  # far side has to walk.
  def test_a_star_g_selective_multicast_route_crosses_a_session
    mpr = crosses(session,
                  reach([BGP::Evpn.new(
                    BGP::Evpn::Selective_multicast.new(
                      [100, 200], 100, nil, '232.1.1.1', '10.0.0.9',
                      [:v2]))]))
    r = mpr.nlris.first.route
    assert_instance_of(BGP::Evpn::Selective_multicast, r)
    assert(r.source.empty?, 'the absent source came back absent')
    assert_equal(0, r.source.bitlen)
    assert_equal('232.1.1.1', r.group.address)
    assert(r.flags.v2?)
  end

  # Route type 7, section 9.2: route type 6 with an ESI. A mixed family
  # triple, an IPv4 group with an IPv6 originator, because each address
  # carries its own length and nothing outside says which is which.
  def test_a_membership_report_synch_route_crosses_a_session
    mpr = crosses(session,
                  reach([BGP::Evpn.new(
                    BGP::Evpn::Membership_report_synch.new(
                      [100, 200], ESI, 100, nil, '232.1.1.1',
                      '2001:db8::9', [:v2, :v3]))]))
    r = mpr.nlris.first.route
    assert_instance_of(BGP::Evpn::Membership_report_synch, r)
    assert_equal(7, mpr.nlris.first.type)
    assert_equal(ESI, r.esi.to_s)
    assert_equal('232.1.1.1', r.group.address)
    assert_equal(32, r.group.bitlen)
    assert_equal('2001:db8::9', r.originator.address)
    assert_equal(128, r.originator.bitlen, 'the two families survived together')
  end

  # Route type 8, section 9.3, with both keep and echo cases set: a
  # reserved bit in the Flags octet and a non-zero 4-octet Reserved
  # field, which section 9.3.1 says a receiver "MUST propagate ...
  # unchanged". Built from the hash, because a build from field values
  # writes the Reserved field as zero.
  def test_a_leave_synch_route_crosses_a_session_with_its_reserved_fields
    mpr = crosses(session,
                  reach([BGP::Evpn.new(
                    BGP::Evpn::Leave_synch.new(
                      :rd => [100, 200], :esi => ESI,
                      :ethernet_tag_id => 100, :source => '192.0.2.1',
                      :group => '232.1.1.1', :originator => '10.0.0.9',
                      :reserved => 'deadbeef', :max_response_time => 100,
                      :flags => [:v2, { :bits => 0xf2 }]))]))
    r = mpr.nlris.first.route
    assert_instance_of(BGP::Evpn::Leave_synch, r)
    assert_equal(8, mpr.nlris.first.type)
    assert_equal(100, r.max_response_time)
    refute(r.reserved_zero?)
    assert_equal('deadbeef', r.reserved.unpack1('H*'))
    assert(r.flags.v2?)
    assert_equal(0xf0, r.flags.reserved_bits)
  end

end
