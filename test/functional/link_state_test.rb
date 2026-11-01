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

# A BGP-LS UPDATE over a real session, RFC 9552, AFI 16388 SAFI 71 and
# 72.
#
# **This is the only test that proves the wiring sites agree with each
# other**, for the reason flow_spec_test.rb, evpn_test.rb,
# rt_constrain_test.rb and mcast_vpn_test.rb all record: both sides are
# pure, so every unit test on the build side reads octets it wrote
# itself and every one on the parse side is handed octets the test
# wrote. Neither can say that what `Mp_reach#encode` puts on a socket is
# what `Mp_reach#parse` takes off it.
#
# Four sites, the EVPN and MCAST-VPN count: the framing in `nlri_size`,
# the two dispatch gates, and the next hop.
#
# **Two cases at the end are not about a wiring site**, since the BGP-LS
# Attribute of section 5.3 goes through `Attr.register` rather than
# either gate. They are here because this is the only place the two
# halves of the family travel together over a socket: the NLRI and the
# attribute that describes it, in one UPDATE, read off the far side.
#
# **Two of them are this family's own and no earlier family has either.**
#
# The SAFI is a parse-time input. Figures 5 and 6 of section 5.2 differ
# by the 8-octet Route Distinguisher of a VPN NLRI and by nothing a
# reader can see in the octets, so the same capture is a valid NLRI read
# either way and only the attribute's SAFI decides. EVPN, RT-constrain
# and MCAST-VPN each pass none, having one layout apiece; flow spec
# passes the AFI, for a different reason. `nlri_size` still needs
# nothing, because section 5.2 says the Total NLRI Length "also includes
# the length of the Route Distinguisher".
#
# And the next hop rule is **three-way** where EVPN's, RT-constrain's
# and MCAST-VPN's are two-way. Section 5.5: "If the next-hop length is
# 4, then the next hop is an IPv4 address; if the next-hop length is 16,
# then it is a global IPv6 address; and if the next-hop length is 32,
# then there is one global IPv6 address followed by an IPv6 link-local
# address." For SAFI 72 one all-zero Route Distinguisher is prepended to
# the whole next hop rather than one per address, so the lengths are 12,
# 24 and 40 where RFC 8950 gives SAFI 128 and 129 24 or 48. The 32 and
# 40 cases below are the only place that pair is sent over a socket.
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
# which is RT-constrain's lesson. The last NLRI in an attribute has
# nothing behind it to over-read into, so a framing slip can pass every
# single-NLRI case. This family's Total NLRI Length sits inside a body
# the loop re-reads, as flow spec's, EVPN's and MCAST-VPN's do, so the
# measured signature is theirs rather than RT-constrain's; the cases are
# kept anyway, because that is the cover that would catch another slip.
#
# **No interoperability is claimed here.** GoBGP 3.23.0 does carry SAFI
# 71, so part 7 can measure that; it has no SAFI 72 at all, and FRR
# 8.4.4 has neither. See `docs/bgp-ls.md` section 11.
#
# BGP:: names are written out in full, see Conventions in CLAUDE.md.
# That includes the nested catcher, which does not see an include in the
# class around it, and which matters more here than usual: Neighbor logs
# an exception from an observer rather than raising it, so a wrong
# constant in one shows up as "nothing arrived" and says nothing about
# the name.
class LinkStateSessionTest < Test::Unit::TestCase
  include BGP::TestHelpers

  SERVER_AS = 100
  CLIENT_AS = 200

  # RFC 9552 section 5.2: "AFI 16388 / SAFI 71 is used for BGP-LS", and
  # SAFI 72 for the VPN application.
  AFI      = 16388
  SAFI     = 71
  SAFI_VPN = 72

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
  # advertised by both sides, and an observer on the server. One Mbgp
  # capability carries one (AFI, SAFI) pair, and this family has two
  # SAFIs, so a VPN case asks for its own.
  def session(safi = SAFI)
    cap = BGP::OPT_PARM::CAP::Mbgp.new(AFI, safi)
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
  # errors defaults to 0. Section 8.2.2 lists what a BGP-LS Propagator
  # must check and `validation.rb` has none of it yet, which is part 6,
  # so every case here expects none and a later case that wants one has
  # to say so.
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

  def reach(nlris, nexthop = '10.0.0.1', safi = SAFI)
    BGP::Update.new(
      BGP::Path_attribute.new(
        BGP::Origin.new(0),
        BGP::As_path.new(CLIENT_AS),
        BGP::Mp_reach.new(:safi => safi, :nexthop => [nexthop].flatten,
                          :nlris => nlris)))
  end

  def mpr(got)
    a = got.path_attribute.find(BGP::Mp_reach)
    assert_not_nil(a, 'an Mp_reach, not an Attr::Raw')
    a
  end

  # One Local Node Descriptors TLV holding one Autonomous System
  # sub-TLV, which section 5.2.1.2 calls "a mandatory TLV in all three
  # types of NLRIs".
  def local(asn = 65000)
    { :local_node_descriptors => [{ :autonomous_system => asn }] }
  end

  # --- NLRI type 1, the Node NLRI, section 5.2 figure 7 ---------------

  def test_a_node_nlri_crosses_a_session
    session
    got = crosses(reach([{ :node => { :protocol_id => 2, :identifier => 7,
                                      :tlvs => [local] } }]))

    a = mpr(got)
    assert_equal(AFI, a.afi)
    assert_equal(SAFI, a.safi)
    assert_equal([BGP::Link_state], a.nlris.collect(&:class))

    ls = a.nlris.first
    assert_equal(false, ls.vpn?)
    assert_nil(ls.rd)
    n = ls.nlri
    assert_instance_of(BGP::Link_state::Node, n)
    assert_equal(2, n.protocol_id)
    assert_equal('IS-IS Level 2', n.protocol)
    assert_equal(7, n.identifier)
    assert_equal(65000, n.local_node_descriptors.sub_tlvs.first.value)
    # 1 + 8 for the head, 12 for the descriptor TLV.
    assert_equal(21, ls.length)
  end

  # Section 5.2.1.4's node type rule needs the sub-TLV's width and the
  # NLRI's Protocol-ID, so it is the one thing in this family that a
  # single level cannot answer. Across a socket, both halves survive.
  def test_the_node_type_rule_survives_the_socket
    session
    got = crosses(reach([{ :node =>
                           { :protocol_id => 1, :identifier => 0,
                             :tlvs => [{ :local_node_descriptors =>
                                         [{ :igp_router_id =>
                                            '1921.6800.1001.02' }] }] } }]))
    n = mpr(got).nlris.first.nlri
    assert_equal(:pseudonode, n.node_type,
                 'a 7 octet IGP Router-ID under Protocol-ID 1')
  end

  # --- NLRI type 2, the Link NLRI, section 5.2 figure 8 --------------

  def test_a_link_nlri_crosses_a_session
    session
    got = crosses(reach([{ :link =>
                           { :protocol_id => 2, :identifier => 0,
                             :tlvs => [local,
                                       { :remote_node_descriptors =>
                                         [{ :autonomous_system => 65001 }] },
                                       { :link_local_remote_identifiers =>
                                         { :local => 1, :remote => 2 } },
                                       { :ipv4_interface_address =>
                                         '10.0.0.1' },
                                       { :ipv4_neighbor_address =>
                                         '10.0.0.2' }] } }]))

    n = mpr(got).nlris.first.nlri
    assert_instance_of(BGP::Link_state::Link, n)
    assert_equal(65001, n.remote_node_descriptors.sub_tlvs.first.value)
    ids = n.tlv(BGP::Link_state::Tlv::Link_local_remote_identifiers.type)
    assert_equal([1, 2], [ids.local, ids.remote])
    assert_equal('10.0.0.1',
                 n.tlv(BGP::Link_state::Tlv::Ipv4_interface_address.type
                      ).address.to_s)
    assert_equal(5, n.tlvs.size)
  end

  # Section 5.2.2 says of four of the link descriptors "This sub-TLV can
  # occur multiple times", so two of a type in one NLRI is ordinary
  # traffic here. That is also the only shape for which section 5.1's
  # Length and Value tiebreakers exist, so it is worth a socket.
  def test_a_repeated_link_descriptor_crosses_a_session
    session
    got = crosses(reach([{ :link =>
                           { :protocol_id => 2, :identifier => 0,
                             :tlvs => [{ :ipv4_interface_address =>
                                         '10.0.0.1' },
                                       { :ipv4_interface_address =>
                                         '10.0.0.3' }] } }]))
    n = mpr(got).nlris.first.nlri
    assert_equal(2, n.tlvs.size)
    assert_equal(['10.0.0.1', '10.0.0.3'],
                 n.tlvs.collect { |t| t.address.to_s })
  end

  # --- NLRI types 3 and 4, the Prefix NLRIs, section 5.2 figure 9 ----

  # **One layout and two type numbers, and the family is the NLRI
  # type's.** Figure 9: types 3 and 4 "use the same format". Section
  # 5.2.3.2's IP Reachability Information TLV holds a Prefix Length in
  # bits and the octets and nothing that says which family they are, so
  # the same value octets are two different prefixes under the two
  # types. Both are sent here, in one UPDATE each, and read back.
  def test_the_two_prefix_nlris_cross_a_session
    session
    reach_tlv = { :ip_reachability => { :bitlen => 24, :octets => 'c00002' } }
    [[:ipv4_prefix, BGP::Link_state::Ipv4_prefix, '192.0.2.0/24'],
     [:ipv6_prefix, BGP::Link_state::Ipv6_prefix, 'c000:200::/24']].each do |key, klass, prefix|
      got = crosses(reach([{ key => { :protocol_id => 3, :identifier => 0,
                                      :tlvs => [local, reach_tlv] } }]))
      n = mpr(got).nlris.first.nlri
      assert_instance_of(klass, n)
      assert_equal(prefix, n.prefix, "#{key} reads its own family")
      assert_equal('c00002', n.ip_reachability.octets.unpack1('H*'),
                   'and both carry the same value octets')
    end
  end

  def test_a_prefix_nlri_carries_an_ospf_route_type
    session
    got = crosses(reach([{ :ipv4_prefix =>
                           { :protocol_id => 3, :identifier => 0,
                             :tlvs => [local,
                                       { :ospf_route_type => 'Inter-Area' },
                                       { :ip_reachability =>
                                         '192.0.2.0/24' }] } }]))
    n = mpr(got).nlris.first.nlri
    assert_equal('Inter-Area',
                 n.tlv(BGP::Link_state::Tlv::Ospf_route_type.type).name)
    assert_equal('192.0.2.0/24', n.prefix)
  end

  # --- the framing across several NLRIs ------------------------------

  # **The case the framing rests on.** Four NLRIs of four types in one
  # attribute, so every one but the last has something behind it to
  # over-read into. A slip in `nlri_size` that a single-NLRI case would
  # survive fails here.
  def test_all_four_nlri_types_in_one_attribute
    session
    got = crosses(reach([{ :node => { :protocol_id => 2, :identifier => 1,
                                      :tlvs => [local] } },
                         { :link => { :protocol_id => 2, :identifier => 2,
                                      :tlvs => [local] } },
                         { :ipv4_prefix =>
                           { :protocol_id => 3, :identifier => 3,
                             :tlvs => [{ :ip_reachability =>
                                         '192.0.2.0/24' }] } },
                         { :ipv6_prefix =>
                           { :protocol_id => 6, :identifier => 4,
                             :tlvs => [{ :ip_reachability =>
                                         '2001:db8::/32' }] } }]))
    a = mpr(got)
    assert_equal(4, a.nlris.size)
    assert_equal([1, 2, 3, 4], a.nlris.collect { |n| n.nlri.type })
    assert_equal([1, 2, 3, 4], a.nlris.collect { |n| n.nlri.identifier })
  end

  # An NLRI type with no class reads back as a Link_state::Unknown and
  # replays, which section 5.2 asks for outright: "An implementation
  # MUST handle unknown Link-State NLRI types as opaque objects and MUST
  # preserve and propagate them." Sent beside a type that does have a
  # class, so the framing has to walk past it.
  def test_an_unknown_nlri_type_crosses_beside_a_known_one
    session
    ls = BGP::Link_state.new(:unknown => { :type => 60123,
                                           :value => 'deadbeef' })
    got = crosses(reach([{ :node => { :protocol_id => 2, :identifier => 1,
                                      :tlvs => [local] } },
                         ls]))
    a = mpr(got)
    assert_equal([BGP::Link_state::Node, BGP::Link_state::Unknown],
                 a.nlris.collect { |n| n.nlri.class })
    assert_equal('deadbeef', a.nlris.last.nlri.value.unpack1('H*'))
  end

  # A TLV type with no class is the same rule one level down, and
  # section 5.1 is just as explicit: unknown types "MUST be preserved
  # and propagated within both the NLRI and the BGP-LS Attribute", and
  # their presence "MUST NOT result in the NLRI or the BGP-LS Attribute
  # being considered malformed". So no finding either.
  def test_an_unknown_tlv_inside_an_nlri_crosses_a_session
    session
    hex = '01000008020000040000fde8' + '00ff0004deadbeef'
    node = BGP::Link_state::Node.new(
      ['02' + '0000000000000000' + hex].pack('H*').is_packed)
    got = crosses(reach([BGP::Link_state.new(node)]))
    n = mpr(got).nlris.first.nlri
    assert_equal([BGP::Link_state::Tlv::Local_node_descriptors,
                  BGP::Link_state::Tlv::Unknown],
                 n.tlvs.collect(&:class))
    assert_equal('deadbeef', n.tlvs.last.value.unpack1('H*'))
  end

  # --- the next hop, section 5.5 -------------------------------------

  # **All three lengths of the non-VPN rule, over a socket.** 4, 16 and
  # 32, where the third is RFC 2545's two-address form and is the first
  # time bgp4r reads it under an AFI other than 1.
  def test_the_three_next_hop_lengths
    session
    nlri = [{ :node => { :protocol_id => 2, :identifier => 0,
                         :tlvs => [local] } }]
    { ['10.0.0.1'] => [4, ['10.0.0.1']],
      ['2001:db8::1'] => [16, ['2001:db8::1']],
      ['2001:db8::1', 'fe80::1'] => [32, ['2001:db8::1', 'fe80::1']]
    }.each do |nh, (len, addresses)|
      got = crosses(reach(nlri, nh))
      a = mpr(got)
      assert_equal(len, next_hop_field(a).size,
                   "section 5.5 gives #{addresses.size} address(es) as " \
                   "#{len} octets")
      # Mp_reach#nexthops answers a joined String for to_s, so the
      # addresses are read out of the field itself, which is the
      # stronger assertion anyway: it is the octets that crossed.
      assert_equal(addresses, next_hop_addresses(a))
    end
  end

  # --- SAFI 72, the VPN application ----------------------------------

  # **Two things are VPN specific and both are in this case.** The
  # section 5.2 Route Distinguisher inside the NLRI, which the Total
  # NLRI Length counts, and the one all-zero RD section 5.5 prepends to
  # the next hop.
  def test_a_vpn_nlri_crosses_a_session
    session(SAFI_VPN)
    got = crosses(reach([{ :rd => [100, 200],
                           :node => { :protocol_id => 2, :identifier => 0,
                                      :tlvs => [local] } }],
                        '10.0.0.1', SAFI_VPN))
    a = mpr(got)
    assert_equal(SAFI_VPN, a.safi)
    ls = a.nlris.first
    assert_equal(true, ls.vpn?, 'the SAFI is what says the RD is there')
    assert_equal('RD=100:200', ls.rd.to_s(false))
    assert_instance_of(BGP::Link_state::Node, ls.nlri)
    # 8 for the RD and 21 for the NLRI, which section 5.2 puts in one
    # count: "For VPN applications, it also includes the length of the
    # Route Distinguisher."
    assert_equal(29, ls.length)
    # And one zero RD in front of the next hop, so 8 + 4.
    assert_equal(12, next_hop_field(a).size)
    assert_equal('00' * 8 + '0a000001', next_hop_field(a).unpack1('H*'))
  end

  # The 40-octet form, which is the one length in this family no other
  # family produces: one RD and two addresses, where RFC 8950 would give
  # 48 for SAFI 128 and 129 by repeating the RD.
  def test_the_vpn_next_hop_prepends_one_route_distinguisher
    session(SAFI_VPN)
    got = crosses(reach([{ :rd => [1, 2],
                           :node => { :protocol_id => 2, :identifier => 0,
                                      :tlvs => [local] } }],
                        ['2001:db8::1', 'fe80::1'], SAFI_VPN))
    a = mpr(got)
    assert_equal(40, next_hop_field(a).size)
    assert_equal('00' * 8, next_hop_field(a)[0, 8].unpack1('H*'),
                 'one all-zero RD, not one per address')
    assert_equal(['2001:db8::1', 'fe80::1'],
                 next_hop_addresses(a, 8))
  end

  # **The SAFI is a parse-time input, and this is what that means.** The
  # same value octets read under SAFI 71 are a Node NLRI with no RD and
  # under SAFI 72 a Node NLRI with one, because figures 5 and 6 differ
  # by nothing a reader can see. So a capture is only as good as the
  # SAFI it is read with, and nothing in the octets catches a mix-up.
  def test_the_same_octets_read_two_ways_under_the_two_safis
    value = '00000064000000c8' + '02' + '0000000000000000' +
            '01000008020000040000fde8'
    hex = '0001' + format('%04x', value.size / 2) + value
    octets = [hex].pack('H*')
    non_vpn = BGP::Link_state.new_ntop(octets.dup, SAFI)
    vpn     = BGP::Link_state.new_ntop(octets.dup, SAFI_VPN)
    assert_equal(hex, non_vpn.to_shex)
    assert_equal(hex, vpn.to_shex, 'both replay the same octets')
    assert_equal(false, non_vpn.vpn?)
    assert_equal(true, vpn.vpn?)
    assert_nil(non_vpn.rd)
    assert_equal('RD=100:200', vpn.rd.to_s(false))
    # And they read different Protocol-IDs out of the same octets, which
    # is how plainly wrong the other reading is.
    assert_equal(0, non_vpn.nlri.protocol_id)
    assert_equal(2, vpn.nlri.protocol_id)
  end

  # --- MP_UNREACH ----------------------------------------------------

  # **The withdrawal is the only cover the second parse loop has.**
  # `Mp_reach#parse` and `Mp_unreach#parse` are independent copies, so
  # reverting one leaves the other working, and every case above goes
  # through the reach loop alone. Several NLRIs, for the framing reason
  # the header records.
  def test_a_withdrawal_crosses_a_session
    session
    sent = BGP::Update.new(
      BGP::Path_attribute.new(
        BGP::Mp_unreach.new(
          :safi => SAFI,
          :nlris => [{ :node => { :protocol_id => 2, :identifier => 1,
                                  :tlvs => [local] } },
                     { :ipv4_prefix =>
                       { :protocol_id => 3, :identifier => 2,
                         :tlvs => [{ :ip_reachability =>
                                     '192.0.2.0/24' }] } }])))
    got = crosses(sent)
    a = got.path_attribute.find(BGP::Mp_unreach)
    assert_not_nil(a, 'an Mp_unreach, not an Attr::Raw')
    assert_equal(AFI, a.afi)
    assert_equal(2, a.nlris.size)
    assert_equal([1, 3], a.nlris.collect { |n| n.nlri.type })
    assert_equal('192.0.2.0/24', a.nlris.last.nlri.prefix)
  end

  def test_a_vpn_withdrawal_crosses_a_session
    session(SAFI_VPN)
    sent = BGP::Update.new(
      BGP::Path_attribute.new(
        BGP::Mp_unreach.new(
          :safi => SAFI_VPN,
          :nlris => [{ :rd => [100, 200],
                       :node => { :protocol_id => 2, :identifier => 0,
                                  :tlvs => [local] } },
                     { :rd => [1, 2],
                       :node => { :protocol_id => 2, :identifier => 1,
                                  :tlvs => [local] } }])))
    got = crosses(sent)
    a = got.path_attribute.find(BGP::Mp_unreach)
    assert_not_nil(a, 'an Mp_unreach, not an Attr::Raw')
    assert_equal([true, true], a.nlris.collect(&:vpn?))
    assert_equal(['RD=100:200', 'RD=1:2'],
                 a.nlris.collect { |n| n.rd.to_s(false) })
  end

  # --- nothing validates ---------------------------------------------

  # An NLRI no RFC allows crosses a session and is reported as nothing,
  # because `validation.rb` knows nothing of this family yet and because
  # section 8.2.2 narrows what it ever will: it names "presence of a
  # mandatory TLV" and "whether a TLV is valid with a given NLRI type"
  # among the semantic validations a BGP-LS Propagator should **not**
  # perform. So a Node NLRI with no Local Node Descriptors, a Link NLRI
  # carrying a prefix descriptor and descending TLV order all travel.
  def test_an_nlri_no_rfc_allows_crosses_a_session
    session
    got = crosses(reach([{ :node => { :protocol_id => 0, :identifier => 0,
                                      :tlvs => [] } },
                         { :link =>
                           { :protocol_id => 2, :identifier => 0,
                             :tlvs => [{ :ip_reachability =>
                                         '192.0.2.0/24' }] } }]))
    a = mpr(got)
    assert_equal(2, a.nlris.size)
    assert_nil(a.nlris.first.nlri.local_node_descriptors,
               'section 5.2.1.2 calls that TLV mandatory')
    assert_equal(0, a.nlris.first.nlri.protocol_id,
                 'and Protocol-ID 0 is Reserved')
    assert_equal(BGP::Link_state::Tlv::Ip_reachability,
                 a.nlris.last.nlri.tlvs.first.class,
                 'a prefix descriptor inside a Link NLRI')
  end

  # --- the BGP-LS Attribute, section 5.3 -------------------------------

  # **The only place the two halves of this family travel together.**
  # The attribute is not one of the four wiring sites, since it goes
  # through `Attr.register` rather than either gate, so what this adds
  # over the unit tests is narrow and worth stating: an UPDATE carrying
  # the NLRI and the attribute that describes it, read off a socket,
  # with the attribute set holding both and claiming neither a protocol
  # error nor a coverage gap.
  def test_the_attribute_crosses_a_session_beside_its_nlri
    session
    attr29 = BGP::Link_state_attribute.new(
      BGP::Link_state::Tlv::Node_flag_bits.new(:overload, :attached),
      BGP::Link_state::Tlv::Node_name.new('router1'),
      BGP::Link_state::Tlv::Isis_area_id.new(['490001'].pack('H*')),
      BGP::Link_state::Tlv::Ipv4_local_router_id.new('10.0.0.1'))
    sent = BGP::Update.new(
      BGP::Path_attribute.new(
        BGP::Origin.new(0),
        BGP::As_path.new(CLIENT_AS),
        BGP::Mp_reach.new(:safi => SAFI,
                          :nexthop => ['10.0.0.1'],
                          :nlris => [{ :node => { :protocol_id => 2,
                                                  :identifier => 7,
                                                  :tlvs => [local] } }]),
        attr29))
    got = crosses(sent)
    a = got.path_attribute.find(BGP::Link_state_attribute)
    assert_not_nil(a, 'a Link_state_attribute, not an Attr::Unknown')
    assert_equal([1024, 1026, 1027, 1028], a.tlvs.collect { |t| t.type })
    assert_equal('router1', a.tlv(1026).name)
    assert_equal('10.0.0.1', a.tlv(1028).address.to_s)
    assert(a.tlv(1024).overload?)
    assert(a.ordered?, 'section 5.1 asks a sender for ascending type order')
    assert_equal(BGP::Link_state, mpr(got).nlris.first.class,
                 'and the NLRI beside it still parses')
  end

  # Section 5.1's keep-and-echo MUST, inside the attribute and over a
  # socket: "Unknown and unsupported types MUST be preserved and
  # propagated within both the NLRI and the BGP-LS Attribute", and their
  # presence "MUST NOT result in the NLRI or the BGP-LS Attribute being
  # considered malformed". 1101 is the Adjacency SID of RFC 9085, which
  # is what GoBGP really sends in this attribute and which no part of
  # this plan implements, so the example cannot expire.
  def test_an_unknown_tlv_inside_the_attribute_crosses_a_session
    session
    sent = BGP::Update.new(
      BGP::Path_attribute.new(
        BGP::Origin.new(0),
        BGP::As_path.new(CLIENT_AS),
        BGP::Mp_reach.new(:safi => SAFI,
                          :nexthop => ['10.0.0.1'],
                          :nlris => [{ :node => { :protocol_id => 2,
                                                  :identifier => 7,
                                                  :tlvs => [local] } }]),
        BGP::Link_state_attribute.new(
          BGP::Link_state::Tlv::Node_flag_bits.new(:overload),
          BGP::Link_state::Tlv::Unknown.new(1101,
                                            ['0100000003e8'].pack('H*')))))
    got = crosses(sent)
    a = got.path_attribute.find(BGP::Link_state_attribute)
    assert_equal([BGP::Link_state::Tlv::Node_flag_bits,
                  BGP::Link_state::Tlv::Unknown],
                 a.tlvs.collect { |t| t.class })
    assert_equal('0100000003e8', a.tlvs.last.value.unpack1('H*'))
  end

  # Table 8's link attribute TLVs beside the Link NLRI they describe,
  # which is the pairing section 5.3.2 is about: "Link Attribute TLVs
  # are TLVs that may be encoded in the BGP-LS Attribute with a Link
  # NLRI." Four of the thirteen, picked for the four shapes that are
  # this table's own rather than shared: a float, eight floats, a
  # two-octet bitfield and the variable-width metric.
  def test_the_link_attribute_tlvs_cross_a_session
    session
    attr29 = BGP::Link_state_attribute.new(
      BGP::Link_state::Tlv::Ipv4_remote_router_id.new('10.0.0.2'),
      BGP::Link_state::Tlv::Administrative_group.new(0x80000001),
      BGP::Link_state::Tlv::Maximum_link_bandwidth.new(1_250_000.0),
      BGP::Link_state::Tlv::Unreserved_bandwidth.new(
        *(1..8).collect { |i| i * 1000.0 }),
      BGP::Link_state::Tlv::Link_protection_type.new(:shared, :enhanced),
      BGP::Link_state::Tlv::Igp_metric.new(10, 1),
      BGP::Link_state::Tlv::Link_name.new('to-core-1'))
    sent = BGP::Update.new(
      BGP::Path_attribute.new(
        BGP::Origin.new(0),
        BGP::As_path.new(CLIENT_AS),
        BGP::Mp_reach.new(:safi => SAFI,
                          :nexthop => ['10.0.0.1'],
                          :nlris => [{ :link =>
                                       { :protocol_id => 2, :identifier => 7,
                                         :tlvs => [local] } }]),
        attr29))
    got = crosses(sent)
    a = got.path_attribute.find(BGP::Link_state_attribute)
    assert_not_nil(a, 'a Link_state_attribute, not an Attr::Unknown')
    assert_equal([1030, 1088, 1089, 1091, 1093, 1095, 1098],
                 a.tlvs.collect { |t| t.type })
    assert(a.ordered?, 'section 5.1 asks a sender for ascending type order')
    # The four shapes, each read back off the socket by its own reader.
    assert_equal([0, 31], a.tlv(1088).groups)
    assert_equal(1_250_000.0, a.tlv(1089).value)
    assert_equal(8000.0, a.tlv(1091).at(7), 'priority 7 is last')
    assert_equal([:shared, :enhanced], a.tlv(1093).names)
    assert_equal([10, 1], [a.tlv(1095).metric, a.tlv(1095).width],
                 'and the width survives, which only this family carries')
    assert_equal('to-core-1', a.tlv(1098).name)
  end

  # **Table 10's six beside a Prefix NLRI**, which is the pairing section
  # 5.3.3 names: these attributes go with "Prefix NLRI types 3 and 4".
  # So this is the third attribute case here and the only one whose NLRI
  # is a prefix, which matters because the IP Reachability TLV inside it
  # holds no family and the NLRI type is what says which one it is.
  #
  # Every shape in the table is here: the flags octet, both widths of
  # integer list, the 32-bit metric, the two-width address and the
  # opaque envelope.
  def test_the_prefix_attribute_tlvs_cross_a_session
    session
    attr29 = BGP::Link_state_attribute.new(
      BGP::Link_state::Tlv::Igp_flags.new(:down, :propagate_nssa),
      BGP::Link_state::Tlv::Igp_route_tag.new(100, 200),
      BGP::Link_state::Tlv::Igp_extended_route_tag.new(1, 2**63),
      BGP::Link_state::Tlv::Prefix_metric.new(4242),
      BGP::Link_state::Tlv::Ospf_forwarding_address.new('2001:db8::1'),
      BGP::Link_state::Tlv::Opaque_prefix_attribute
        .new(['deadbeef'].pack('H*')))
    sent = BGP::Update.new(
      BGP::Path_attribute.new(
        BGP::Origin.new(0),
        BGP::As_path.new(CLIENT_AS),
        BGP::Mp_reach.new(:safi => SAFI,
                          :nexthop => ['10.0.0.1'],
                          :nlris => [{ :ipv4_prefix =>
                                       { :protocol_id => 2, :identifier => 7,
                                         :tlvs => [local] } }]),
        attr29))
    got = crosses(sent)
    a = got.path_attribute.find(BGP::Link_state_attribute)
    assert_not_nil(a, 'a Link_state_attribute, not an Attr::Unknown')
    assert_equal([1152, 1153, 1154, 1155, 1156, 1157],
                 a.tlvs.collect { |t| t.type })
    assert(a.ordered?, 'section 5.1 asks a sender for ascending type order')
    assert_equal([:down, :propagate_nssa], a.tlv(1152).names)
    assert_equal([100, 200], a.tlv(1153).values)
    # **The assertion that says 1154's element is 8 octets and not 4**,
    # which is the one thing a reader carrying 1153's shape across gets
    # wrong, and the only place it is checked over a socket.
    assert_equal([1, 2**63], a.tlv(1154).values)
    assert_equal(4242, a.tlv(1155).value)
    # The IPv6 width, which Table 10's Length column does not admit and
    # section 5.3.3.5 does.
    assert_equal('2001:db8::1', a.tlv(1156).address.to_s)
    assert_equal(:ipv6, a.tlv(1156).family)
    assert_equal('deadbeef', a.tlv(1157).value.unpack1('H*'))
    # The NLRI it describes crossed with it, which is the whole reason
    # this case is here rather than in the unit file. `Link_state` is
    # the NLRI and `#nlri` is the typed layout inside it, so the type
    # assertion goes one level down.
    nlri = got.path_attribute.find(BGP::Mp_reach).nlris.first
    assert_instance_of(BGP::Link_state, nlri)
    assert_equal(3, nlri.type)
    assert_instance_of(BGP::Link_state::Ipv4_prefix, nlri.nlri)
  end

  # Not a test method: a helper, kept below every test and with no
  # `private` above it, because a test method after `private` never runs
  # and nothing says so.
  #
  # The Next Hop field of an encoded MP_REACH: flags, type and length,
  # then the AFI and SAFI, then a length octet and that many octets.
  def next_hop_field(a)
    s = a.encode.dup
    s.slice!(0, 3)
    s.slice!(0, 3)
    n = s.slice!(0, 1).unpack1('C')
    s.slice!(0, n)
  end

  # The addresses in that field, read the way section 5.5 says to: by
  # the length of what is left. skip is the 8 octets of a VPN Route
  # Distinguisher, which is prepended once and not per address.
  def next_hop_addresses(a, skip = 0)
    s = next_hop_field(a)[skip..-1]
    w = (s.size % 16).zero? ? 16 : 4
    s.scan(/.{#{w}}/m).collect { |x| IPAddr.new_ntoh(x).to_s }
  end

end
