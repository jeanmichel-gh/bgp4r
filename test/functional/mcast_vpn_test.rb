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

# An MCAST-VPN UPDATE over a real session, RFC 6514, SAFI 5.
#
# **This is the only test that proves the wiring sites agree with each
# other**, for the reason flow_spec_test.rb, evpn_test.rb and
# rt_constrain_test.rb all record: both sides are pure, so every unit
# test on the build side reads octets it wrote itself and every one on
# the parse side is handed octets the test wrote. Neither can say that
# what `Mp_reach#encode` puts on a socket is what `Mp_reach#parse` takes
# off it.
#
# **It is not interoperability and must not be read as one.** Neither
# GoBGP 3.23.0 nor FRR 8.4.4 carries SAFI 5, measured with `strings`, so
# this family has no outside reference at all and the loopback test
# proves only that the two ends of bgp4r agree. See
# `docs/mcast-vpn.md` section 9.
#
# Four sites, the EVPN count rather than RT-constrain's three: the
# framing in `nlri_size`, the two dispatch gates, and the next hop.
#
# **The next hop is the one site this family did not have to guess at**,
# and the document that settles it is one the plan for this family had
# missed. RFC 6515, "IPv4 and IPv6 Infrastructure Addresses in BGP
# Updates for Multicast VPN", February 2012, header `Updates: 6514`.
# Section 1.1: the PE address family "MUST NOT be inferred from the AFI
# field". Section 2 item 1: "it is always clear whether the address is
# an IPv4 address (length is 4) or an IPv6 address (length is 16)." So
# SAFI 5 joins the length-only arm EVPN and RT-constrain share, and with
# the strongest of the three citations, since the other two say to use
# the length where this one forbids using the AFI.
#
# The assertion that matters in every case is that the attribute arrives
# as an `Mp_reach` or `Mp_unreach` whose NLRIs read back. Before the
# wiring the same UPDATE crossed the socket intact and came back as an
# `Attr::Raw` with an `Attr::Gap`, which is #116 keeping octets it
# cannot interpret: the session stayed up and nothing looked wrong, so a
# test that only checked the session or the hex would have passed
# against the unwired library.
#
# **The multi-NLRI cases are load bearing and must not be thinned out**,
# which is RT-constrain's lesson arriving here. The last NLRI in an
# attribute has nothing behind it to over-read into, so a framing slip
# can pass every single-NLRI case. This family's Length does sit inside
# a body the loop re-reads, as flow spec's and EVPN's do, so the
# measured signature below is theirs rather than RT-constrain's; the
# cases are kept anyway, because that is the cover that would catch a
# different slip.
#
# BGP:: names are written out in full, see Conventions in CLAUDE.md.
# That includes the nested catcher, which does not see an include in the
# class around it, and which matters more here than usual: Neighbor logs
# an exception from an observer rather than raising it, so a wrong
# constant in one shows up as "nothing arrived" and says nothing about
# the name.
class McastVpnSessionTest < Test::Unit::TestCase
  include BGP::TestHelpers

  SERVER_AS = 100
  CLIENT_AS = 200

  # RFC 6514 section 4 takes "an Address Family Identifier (AFI) of 1 or
  # 2 and a Subsequent AFI (SAFI) of MCAST-VPN". Section 4 names no
  # number for the SAFI and neither does the bis draft; IANA says 5.
  AFI  = 1
  SAFI = 5

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

  # Brings up a session with the multiprotocol capability of RFC 4760,
  # advertised by both sides, and an observer on the server. Returns the
  # catcher. One Mbgp capability carries one (AFI, SAFI) pair, and this
  # family has two AFIs, so a case needing AFI 2 asks for it.
  def session(afi = AFI)
    cap = BGP::OPT_PARM::CAP::Mbgp.new(afi, SAFI)
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

  # Sends one UPDATE carrying the given attributes and returns what the
  # server parsed, with the two channels of #116 checked: errors means
  # what the peer got wrong, undecoded means a gap in bgp4r.
  #
  # errors defaults to 0 rather than being asserted zero inline. Neither
  # RFC 6514 nor the bis draft names a malformed MCAST-VPN NLRI anywhere
  # in its text, and RFC 6515's one rule is about a next hop length
  # neither 4 nor 16, which no case here sends. So every case expects
  # none and a case that wants one has to say so.
  def crosses(sent, errors = 0)
    @c.send_update sent
    got = @catcher.shift
    assert_not_nil(got, 'the server parsed an UPDATE')
    assert_equal(sent.to_shex, got.to_shex, 'byte for byte across the socket')
    assert_equal(errors, got.path_attribute.errors.size,
                 "findings: #{got.path_attribute.errors.collect(&:reason).inspect}")
    assert_equal(0, got.path_attribute.undecoded.size, 'no coverage gap')
    got
  end

  def reach(nlris, nexthop = '10.0.0.1', afi = nil)
    h = { :safi => SAFI, :nexthop => [nexthop], :nlris => nlris }
    h[:afi] = afi if afi
    BGP::Update.new(
      BGP::Path_attribute.new(
        BGP::Origin.new(0),
        BGP::As_path.new(CLIENT_AS),
        BGP::Mp_reach.new(h)))
  end

  def mpr(got)
    a = got.path_attribute.find(BGP::Mp_reach)
    assert_not_nil(a, 'an Mp_reach, not an Attr::Raw')
    a
  end

  # Route type 1, RFC 6514 section 4.1: an RD and the trailing address
  # with no length of its own, so it is the smallest case that exercises
  # the what-is-left rule across a socket.
  def test_an_intra_as_i_pmsi_route_crosses_a_session
    session
    got = crosses(reach([{ :intra_as_i_pmsi =>
                           { :rd => [100, 200], :originator => '10.0.0.1' } }]))

    a = mpr(got)
    assert_equal(AFI, a.afi)
    assert_equal(SAFI, a.safi)
    assert_equal([BGP::Mcast_vpn], a.nlris.collect(&:class))

    r = a.nlris.first.route
    assert_instance_of(BGP::Mcast_vpn::Intra_as_i_pmsi, r)
    assert_equal('RD=100:200', r.rd.to_s(false))
    assert_equal('10.0.0.1', r.originator.address)
    # RFC 6515 section 2 item 2 gives this route's own total, the one
    # octet count any document in this family states: the NLRI length
    # field "will be either 12 or 24, respectively".
    assert_equal(12, a.nlris.first.length)
  end

  # Route type 2, section 4.2, which is the fixed-width one and carries
  # the only sentence in section 4 constraining a value rather than a
  # width: "Two-octet ASNs are encoded in the two low-order octets of
  # the Source AS field, with the two high-order octets set to zero."
  def test_an_inter_as_i_pmsi_route_crosses_a_session
    session
    got = crosses(reach([{ :inter_as_i_pmsi =>
                           { :rd => [100, 200], :source_as => 65000 } }]))

    r = mpr(got).nlris.first.route
    assert_instance_of(BGP::Mcast_vpn::Inter_as_i_pmsi, r)
    assert_equal(65000, r.source_as.value)
    assert_equal('0000fde8', r.source_as.encode.unpack1('H*'),
                 'a two-octet ASN in the low-order octets, section 4.2')
  end

  # Route type 5, section 4.5: the Multicast Source and Group pair, the
  # first case whose body is variable in two places at once.
  def test_a_source_active_route_crosses_a_session
    session
    got = crosses(reach([{ :source_active =>
                           { :rd => [100, 200], :source => '10.1.1.1',
                             :group => '232.1.1.1' } }]))

    r = mpr(got).nlris.first.route
    assert_instance_of(BGP::Mcast_vpn::Source_active, r)
    assert_equal('10.1.1.1', r.source.address)
    assert_equal('232.1.1.1', r.group.address)
    assert_equal(32, r.source.bitlen, 'section 4.3 states the length by value')
  end

  # Route type 3, section 4.3: the pair with the trailing address behind
  # it, so three variable fields in a row and the only one where a
  # length that lies eats the field behind it.
  def test_an_s_pmsi_route_crosses_a_session
    session
    got = crosses(reach([{ :s_pmsi =>
                           { :rd => [100, 200], :source => '10.1.1.1',
                             :group => '232.1.1.1',
                             :originator => '10.0.0.1' } }]))

    r = mpr(got).nlris.first.route
    assert_instance_of(BGP::Mcast_vpn::S_pmsi, r)
    assert_equal('10.1.1.1', r.source.address)
    assert_equal('232.1.1.1', r.group.address)
    assert_equal('10.0.0.1', r.originator.address,
                 'the trailing address is what is left after the two lengths')
  end

  # Route types 6 and 7, section 4.6, which share one layout and differ
  # only in identity. Both cross in one attribute, which is also the
  # test that the two are told apart by their Route Type octet alone.
  def test_both_c_multicast_route_types_cross_in_one_attribute
    session
    got = crosses(reach([{ :shared_tree_join =>
                           { :rd => [100, 200], :source_as => 65000,
                             :source => '10.1.1.1', :group => '232.1.1.1' } },
                         { :source_tree_join =>
                           { :rd => [100, 200], :source_as => 65000,
                             :source => '10.1.1.1', :group => '232.1.1.1' } }]))

    a = mpr(got)
    assert_equal([BGP::Mcast_vpn::Shared_tree_join,
                  BGP::Mcast_vpn::Source_tree_join],
                 a.nlris.collect { |n| n.route.class })
    assert_equal([6, 7], a.nlris.collect(&:type))
    # One layout, so the bodies are identical and only the type differs.
    assert_equal(a.nlris[0].route.encode, a.nlris[1].route.encode)
  end

  # Route type 4, section 4.4, the recursive one. **This is the only
  # case that puts an NLRI inside an NLRI over a socket**, and the only
  # place the nested read runs on octets that crossed one rather than
  # ones a test wrote. RFC 6515 section 2 item 4 is what makes the
  # reading more than a reading: "The Route Key has its own length
  # field."
  def test_a_leaf_a_d_route_carries_a_whole_nested_nlri_across_a_session
    session
    rk = BGP::Mcast_vpn::S_pmsi.new([100, 200], '192.0.2.1', '232.1.1.1',
                                    '10.0.0.1')
    got = crosses(reach([BGP::Mcast_vpn.new(
                           BGP::Mcast_vpn::Leaf_a_d.new(rk, '10.0.0.2'))]))

    r = mpr(got).nlris.first.route
    assert_instance_of(BGP::Mcast_vpn::Leaf_a_d, r)
    assert_instance_of(BGP::Mcast_vpn::S_pmsi, r.route_key.route)
    # The field values and not the class, which is the only thing that
    # pins the split: see docs/mcast-vpn.md section 7.
    assert_equal('192.0.2.1', r.route_key.route.source.address)
    assert_equal('10.0.0.1', r.route_key.route.originator.address,
                 'the Route Key ends where its own Length says')
    assert_equal('10.0.0.2', r.originator.address,
                 'and the address is what is behind it')
  end

  # Two Leaf A-D routes in one attribute, which is what says the
  # recursion does not over-read: the first route's nested NLRI must not
  # eat into the second route.
  def test_two_leaf_a_d_routes_cross_in_one_attribute
    session
    one = BGP::Mcast_vpn::Leaf_a_d.new(
            BGP::Mcast_vpn::Inter_as_i_pmsi.new([100, 200], 65000), '10.0.0.2')
    two = BGP::Mcast_vpn::Leaf_a_d.new(
            BGP::Mcast_vpn::Intra_as_i_pmsi.new([1, 2], '10.9.9.9'), '10.0.0.3')
    got = crosses(reach([BGP::Mcast_vpn.new(one), BGP::Mcast_vpn.new(two)]))

    a = mpr(got)
    assert_equal(2, a.nlris.size, 'the first route did not eat the second')
    assert_equal([BGP::Mcast_vpn::Inter_as_i_pmsi,
                  BGP::Mcast_vpn::Intra_as_i_pmsi],
                 a.nlris.collect { |n| n.route.route_key.route.class })
    assert_equal(['10.0.0.2', '10.0.0.3'],
                 a.nlris.collect { |n| n.route.originator.address })
  end

  # **The next hop read by its length, which is RFC 6515's rule.** An
  # IPv6 next hop under AFI 1: section 1.1 says the PE address family
  # "MUST NOT be inferred from the AFI field", so this has to come back
  # as IPv6 even though the AFI says 1. Without the arm the SAFI 1 and 2
  # case would have read 16 octets as four IPv4 addresses.
  def test_an_ipv6_next_hop_under_afi_1_crosses_a_session
    session
    got = crosses(reach([{ :inter_as_i_pmsi =>
                           { :rd => [100, 200], :source_as => 65000 } }],
                        '2001:db8::1'))

    a = mpr(got)
    assert_equal(1, a.afi, 'the AFI still says 1')
    assert_equal('2001:db8::1', a.nexthops,
                 'and the next hop is IPv6 because its length is 16')
  end

  # The other half of the same rule, and the half RFC 6515 section 1.1
  # singles out: an IPv4 next hop under AFI 2 stays a plain 4-octet
  # address. RFC 4659 and RFC 4798 would have written an IPv4-mapped
  # IPv6 address there, and section 1.1 says of that approach: "This
  # document does not use that approach."
  def test_an_ipv4_next_hop_under_afi_2_is_not_mapped
    session(2)
    got = crosses(reach([{ :inter_as_i_pmsi =>
                           { :rd => [100, 200], :source_as => 65000 } }],
                        '10.0.0.1', 2))

    a = mpr(got)
    assert_equal(2, a.afi)
    assert_equal('10.0.0.1', a.nexthops)
    # The length octet itself, since that is the whole of the rule. It
    # sits after the two AFI octets and the SAFI octet of RFC 4760
    # section 3, which the attribute header's three octets precede.
    assert_equal(4, a.to_shex[12, 2].to_i(16),
                 'four octets, not the sixteen a mapped address needs')
  end

  # A withdrawal, which is the only thing covering Mp_unreach's own
  # parse loop: it is an independent copy of Mp_reach's, which is what
  # the sabotage signature in this file's header measures.
  def test_a_withdrawal_crosses_a_session
    session
    sent = BGP::Update.new(
             BGP::Path_attribute.new(
               BGP::Mp_unreach.new(
                 :safi => SAFI,
                 :nlris => [{ :source_active =>
                              { :rd => [100, 200], :source => '10.1.1.1',
                                :group => '232.1.1.1' } }])))
    got = crosses(sent)

    a = got.path_attribute.find(BGP::Mp_unreach)
    assert_not_nil(a, 'an Mp_unreach, not an Attr::Raw')
    assert_equal(SAFI, a.safi)
    r = a.nlris.first.route
    assert_instance_of(BGP::Mcast_vpn::Source_active, r)
    assert_equal('232.1.1.1', r.group.address)
  end

  # An mLDP route type, 0x43, which IANA assigns and bgp4r leaves out of
  # scope by decision: RFC 7441 defers its FEC Element to RFC 6388
  # section 2.2, which is LDP and not BGP. So it crosses as an Unknown
  # that replays byte for byte, and **no protocol error is reported**,
  # because no MCAST-VPN RFC calls an unknown route type malformed. The
  # same decision EVPN part 9 recorded for its types 12 to 255.
  def test_an_out_of_scope_route_type_crosses_as_an_unknown
    session
    got = crosses(reach([{ :unknown =>
                           { :type => 0x43, :value => '0102030405' } }]))

    r = mpr(got).nlris.first.route
    assert_instance_of(BGP::Mcast_vpn::Unknown, r)
    assert_equal(0x43, r.type)
    assert_equal('0102030405', r.value.unpack1('H*'))
  end

  # **The one case where a receive side check runs on octets that
  # crossed a socket** rather than ones a test wrote. RFC 6515 section 2
  # item 2: route type 1's Originating Router's IP Address is what the
  # NLRI length leaves over, and "If the inferred length ... is neither
  # 4 nor 16, the MP_REACH_NLRI attribute MUST be considered to be
  # 'incorrect'". Eight octets here, so one finding, subcode 9 and a
  # session reset per RFC 7606 section 7.11.
  #
  # The session stays up because this test's receive policy is not
  # `:strict`; what is asserted is the verdict, not a reset.
  def test_an_originating_router_of_the_wrong_width_is_reported
    session
    hex = '0110' + '00000064000000c8' + 'aabbccddeeff0011'
    got = crosses(reach([BGP::Mcast_vpn.new([hex].pack('H*').is_packed)]), 1)

    f = got.path_attribute.errors.first
    assert_equal(9, f.subcode)
    assert_equal(:session_reset, f.action)
    assert_match(/leaves 8 octets for its Originating Router's IP Address/,
                 f.reason)
    # And the attribute still parsed, which is what says the two channels
    # of #116 are independent: a protocol error is not a coverage gap.
    assert_instance_of(BGP::Mcast_vpn::Intra_as_i_pmsi,
                       mpr(got).nlris.first.route)
  end

  # **A route no RFC allows crosses too**, per Conventions: building and
  # encoding never validate, so a test can put a Length that disagrees
  # with its body on the wire and watch the far side.
  #
  # **What comes back is a real route type 1 and not an Unknown**, which
  # is worth stating because the first draft of this case asserted the
  # opposite and the library was right. `read_route`'s rule is that a
  # route type is kept only if it can reproduce **its body**, and the
  # body here is a perfectly good route type 1: an RD and a trailing
  # address. What lied is the NLRI's own Length field, which sits
  # outside the body, and `declared_len` echoes that so `encode` gives
  # the peer's octets back. Only a body a registered type cannot
  # reproduce falls back to Unknown, which the unit tests cover.
  #
  # **The expected finding count was 0 when the wiring part wrote this
  # case, and the validation part made it 1**, which is that part
  # working rather than this case breaking: a Length that overruns the
  # attribute is the framing check `mcast_vpn_finding` now makes. The
  # count is re-pointed and the reason asserted, which is stronger than
  # the zero it replaced. The two channels stay independent either way:
  # a protocol error in `errors` and no coverage gap in `undecoded`.
  def test_a_route_no_rfc_allows_crosses_a_session
    session
    # Route type 1 with a Length of 20 over a 12-octet body.
    hex = '0114' + '00000064000000c8' + '0a000001'
    got = crosses(reach([BGP::Mcast_vpn.new([hex].pack('H*').is_packed)]), 1)

    assert_match(/runs past the attribute/,
                 got.path_attribute.errors.first.reason)
    n = mpr(got).nlris.first
    assert_equal(1, n.type)
    assert_instance_of(BGP::Mcast_vpn::Intra_as_i_pmsi, n.route,
                       'the body reproduces itself, so the route is kept')
    assert_equal(20, n.length, 'and the Length that lied is echoed')
    assert_equal(20, n.declared_len, 'which is what declared_len records')
  end
end
