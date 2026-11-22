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
require 'socket'
require './test/functional/lab/lab_helper'

# The Segment Routing TLVs of RFC 9085 and RFC 9086 in BGP-LS, against
# GoBGP 4.10.0. `docs/bgp-ls.md` section 13 has the classes and section
# 11 the measurements.
#
# GoBGP 4.10.0 has types for 1034, 1035, 1036, 1161, 1099, 1158, 516,
# 517 and the three Peering SIDs. It has none for 1100. Measured on
# 2026-11-22 from its source and against its binary.
#
# * **Receive.** GoBGP originates Link NLRIs with Protocol-ID 7 and a
#   Peering SID, and Node NLRIs with an SR Algorithm TLV. bgp4r reads
#   each TLV as its class from octets it did not write.
# * **Send.** bgp4r sends each SR TLV and GoBGP's RIB names the values
#   back, each from its own field.
# * **Negative.** A malformed SR TLV, and semantic faults RFC 9552
#   section 8.2.2 says not to check. Each is compared with what bgp4r's
#   `validation.rb` reports for the same octets.
#
# **Three faults in GoBGP, recorded and not filed**, each asserted:
# its client's `sid-type adj` loses the flags and the weight; its RIB
# shows no prefix attribute TLV at all, the Prefix-SID included; and it
# discards the whole BGP-LS Attribute for an Adjacency SID of a length
# it does not expect, a check RFC 9552 section 8.2.2 says not to make.
#
# Every case gets a session of its own, as in `link_state_gobgp_test.rb`.
class LinkStateSrGobgpTest < Test::Unit::TestCase

  OUR_AS = 65001
  THEIR_AS = 65002
  G = LabHelper::Gobgpd
  T = BGP::Link_state::Tlv

  AFI  = 16388
  SAFI = 71

  # The version these cases were measured against. GoBGP 3.23.0 has the
  # older client grammar `link_state_gobgp_test.rb` uses, and other
  # wording, so this file omits itself on any other major.
  MEASURED_MAJOR = 4

  # A Link NLRI with Protocol-ID 7, what RFC 9086 section 4 describes:
  # AS and BGP Router-ID on both ends (section 4.2), and the
  # confederation members of section 4.3. The SID keywords are added
  # per case. GoBGP 4.10.0's grammar, from `parseLsLinkNLRIType`.
  EPE_ARGS = %w[
    link protocol 7 identifier 0
    local-asn 65002 local-bgp-router-id 10.0.0.2
    local-bgp-confederation-member 65102
    remote-asn 65001 remote-bgp-router-id 10.0.0.1
    remote-bgp-confederation-member 65101
    ipv4-interface-address 192.0.2.1 ipv4-neighbor-address 192.0.2.2
  ].freeze

  LOCAL = { :local_node_descriptors =>
            [{ :autonomous_system => OUR_AS },
             { :igp_router_id => '0000.0000.0001' }] }.freeze
  REMOTE = { :remote_node_descriptors =>
             [{ :autonomous_system => OUR_AS },
              { :igp_router_id => '0000.0000.0002' }] }.freeze
  NODE = { :node => { :protocol_id => 2, :identifier => 0,
                      :tlvs => [LOCAL] } }.freeze
  LINK = { :link => { :protocol_id => 2, :identifier => 0,
                      :tlvs => [LOCAL, REMOTE,
                                { :ipv4_interface_address => '192.0.2.1' }] } }.freeze
  EPE = { :link => { :protocol_id => 7, :identifier => 0,
                     :tlvs => [{ :local_node_descriptors =>
                                 [{ :autonomous_system => OUR_AS },
                                  { :bgp_router_id => '10.0.0.1' }] },
                               { :remote_node_descriptors =>
                                 [{ :autonomous_system => THEIR_AS },
                                  { :bgp_router_id => '10.0.0.2' }] }] } }.freeze

  def setup
    unless G.available?
      flunk('gobgpd is not installed') if ENV['LAB_REQUIRE_GOBGPD'] == '1'
      omit('gobgpd is not installed')
    end
    unless G.major == MEASURED_MAJOR
      omit("measured against GoBGP #{MEASURED_MAJOR}, found " \
           "#{G.major.inspect}: re-measure before asserting")
    end
    @listeners = []
    @routers = []
  end

  # Both lists are nil when setup omitted the case.
  def teardown
    (@routers || []).each { |r| r.down }
    (@listeners || []).each do |server, neighbor, thread|
      thread.kill if thread
      neighbor.close
      server.close unless server.closed?
    end
  rescue IOError, SystemCallError
  end

  # Queues the UPDATEs the bgp4r side parsed. The full BGP:: name, since
  # a nested class does not see an include around it.
  class UpdateCatcher
    def initialize ; @q = Queue.new ; end

    def update(message, *_)
      @q << message if message.is_a?(::BGP::Update)
    end

    def shift(timeout = 20)
      deadline = Time.now + timeout
      loop do
        return @q.shift if @q.size > 0
        return nil if Time.now > deadline
        sleep 0.05
      end
    end
  end

  # A bgp4r speaker offering IPv4 unicast and SAFI 71, with a gobgpd for
  # the `ls` family dialling it. Answers [neighbor, router, updates,
  # drops], where drops collects the state changes from the moment the
  # session is up.
  def session
    server = TCPServer.new('127.0.0.1', 0)
    n = BGP::Neighbor.new(4, OUR_AS, 180, '0.0.0.1', '127.0.0.2', '127.0.0.1')
    n.add_cap BGP::OPT_PARM::CAP::Mbgp.new(1, 1)
    n.add_cap BGP::OPT_PARM::CAP::Mbgp.new(AFI, SAFI)
    updates = UpdateCatcher.new
    n.add_observer updates
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
                   :families => [G::LS])
    @routers << router
    router.up
    assert(wait_for { n.is_established? }, "the session came up\n#{router.log}")
    drops = []
    n.on_state_change { |now, was| drops << [was, now] }
    [n, router, updates, drops]
  end

  def wait_for(timeout = 30)
    deadline = Time.now + timeout
    loop do
      return true if yield
      return false if Time.now > deadline
      sleep 0.2
    end
  end

  # One UPDATE: one NLRI and a BGP-LS Attribute holding the TLVs.
  def announce(n, nlri, tlvs)
    n.send_update BGP::Update.new(
      BGP::Path_attribute.new(BGP::Origin.new(0),
                              BGP::As_path.new(OUR_AS),
                              BGP::Mp_reach.new(:safi => SAFI,
                                                :nexthop => ['10.0.0.1'],
                                                :nlris => [nlri]),
                              BGP::Link_state_attribute.new(*tlvs)))
  end

  # GoBGP originates; answers the UPDATE bgp4r parsed, after the checks
  # every receive case shares: no protocol error, no coverage gap, and
  # the UPDATE replays byte for byte.
  def originate(router, updates, args)
    out, status = router.client_run(*%w[global rib add -a ls], *args)
    assert(status.success?, "the client to add it: #{out}")
    got = updates.shift
    assert_not_nil(got, "an UPDATE from GoBGP\n#{router.log}")
    assert_equal([], got.path_attribute.errors.collect(&:reason))
    assert_equal(0, got.path_attribute.undecoded.size, 'no coverage gap')
    assert_equal(got.to_shex,
                 BGP::Update.new([got.to_shex].pack('H*').is_packed).to_shex,
                 'and it replays byte for byte')
    got
  end

  def ls_attribute(update)
    a = update.path_attribute.find(BGP::Link_state_attribute)
    assert_not_nil(a, 'a Link_state_attribute')
    a
  end

  # The one route GoBGP holds, as [key, the BGP-LS Attribute's JSON],
  # or nil. The attribute is nil when GoBGP discarded it.
  def only_route(router)
    key, path = router.only_rule(G::LS)
    return nil unless key
    [key, path['attrs'].find { |a| a['type'] == 29 }]
  end

  # --- receive: GoBGP's octets, bgp4r's classes -------------------------

  # RFC 9086 section 5, the PeerNode SID, with the node descriptors of
  # section 4.1. `sid-type node` with the V and L flags and a weight.
  def test_a_peer_node_sid_from_gobgp_reads_as_its_class
    _n, router, updates, _drops = session
    got = originate(router, updates,
                    EPE_ARGS + %w[sid 24000 sid-type node v-flag l-flag weight 1])
    sid = ls_attribute(got).tlvs
    assert_equal([T::Peer_node_sid], sid.collect(&:class))
    assert_equal([0xc0, 1, 24000], [sid[0].flags, sid[0].weight, sid[0].label])
    assert_equal([:value, :local], sid[0].names)
    assert(sid[0].label?, 'GoBGP sends the 3-octet label form, length 7')

    link = got.path_attribute.find(BGP::Mp_reach).nlris.first.nlri
    assert_equal(7, link.protocol_id, 'Protocol-ID 7, BGP')
    local = link.local_node_descriptors
    assert_equal([T::Autonomous_system, T::Bgp_ls_identifier,
                  T::Bgp_router_id, T::Bgp_confederation_member],
                 local.sub_tlvs.collect(&:class))
    assert_equal('10.0.0.2', local.sub_tlvs[2].router_id)
    assert_equal(65102, local.sub_tlvs[3].value)
  end

  # GoBGP 3.23.0 sent 512, 516, 513 (docs/bgp-ls.md section 11). 4.10.0
  # sends them in the ascending order section 5.2.1.4 asks for.
  def test_gobgp_4_sends_node_descriptor_sub_tlvs_in_order
    _n, router, updates, _drops = session
    got = originate(router, updates, EPE_ARGS + %w[sid 24000 sid-type node])
    local = got.path_attribute.find(BGP::Mp_reach).nlris.first.nlri
               .local_node_descriptors
    assert_equal([512, 513, 516, 517], local.sub_tlvs.collect(&:type))
    assert(local.ordered?)
  end

  def test_a_peer_set_sid_from_gobgp_reads_as_its_class
    _n, router, updates, _drops = session
    got = originate(router, updates,
                    EPE_ARGS + %w[sid 24001 sid-type set v-flag weight 2])
    sid = ls_attribute(got).tlvs.first
    assert_instance_of(T::Peer_set_sid, sid)
    assert_equal([0x80, 2, 24001], [sid.flags, sid.weight, sid.label])
  end

  # **A fault in GoBGP.** `sid-type adj` makes RFC 9085's Adjacency SID,
  # 1099, not RFC 9086's PeerAdj SID, 1102, and it arrives with flags 0
  # and weight 0 whatever was asked. Its client builds the TLV with the
  # flags and the weight, and `NewLsTLVAdjacencySID` on the daemon side
  # takes the SID alone. bgp4r reads exactly what arrived.
  def test_gobgps_adjacency_sid_loses_its_flags_and_weight
    _n, router, updates, _drops = session
    got = originate(router, updates,
                    EPE_ARGS + %w[sid 24001 sid-type adj v-flag weight 2])
    sid = ls_attribute(got).tlvs.first
    assert_instance_of(T::Adjacency_sid, sid)
    assert_equal([0, 0, 24001], [sid.flags, sid.weight, sid.label],
                 'GoBGP 4.10.0 drops the V flag and weight 2 asked for')
  end

  # RFC 9085 section 2.1.3, from a Node NLRI GoBGP originates.
  def test_an_sr_algorithm_from_gobgp_reads_as_its_class
    _n, router, updates, _drops = session
    got = originate(router, updates,
                    %w[node protocol 2 identifier 0
                       local-igp-router-id 0000.0000.0001 sr-algorithm 0 1])
    sid = ls_attribute(got).tlvs.first
    assert_instance_of(T::Sr_algorithm, sid)
    assert_equal([0, 1], sid.values)
  end

  # --- send: bgp4r's octets, GoBGP's reading -----------------------------

  # RFC 9085 section 2.1: SR Capabilities, SR Algorithm and SR Local
  # Block. GoBGP prints a range as its first label and first label plus
  # size, and the IS-IS I and V flags by name.
  def test_the_sr_node_tlvs_reach_the_router
    n, router, _updates, _drops = session
    announce(n, NODE, [T::Sr_capabilities.new(0xc0, [[8000, 16000]]),
                       T::Sr_algorithm.new(0, 1),
                       T::Sr_local_block.new(0, [[1000, 15000]])])
    assert(wait_for { only_route(router) }, "GoBGP to install it\n#{router.log}")
    _key, attr = only_route(router)
    node = attr['node']
    assert_equal({ 'ipv4_supported' => true, 'ipv6_supported' => true,
                   'ranges' => [{ 'begin' => 16000, 'end' => 24000 }] },
                 node['sr_capabilities'])
    assert_equal([0, 1], node['sr_algorithms'].unpack1('m').bytes,
                 'GoBGP prints the octets in base64')
    assert_equal([{ 'begin' => 15000, 'end' => 16000 }],
                 node['sr_local_block']['ranges'])
  end

  # RFC 9085 section 2.2.1. GoBGP names our SID, and **shows flags 0
  # and weight 0 where 0x30 and 5 were sent**, the same loss as the
  # receive case above, on its API side. GoBGP has no type for the LAN
  # Adjacency SID beside it, which it keeps quietly.
  def test_an_adjacency_sid_reaches_the_router
    n, router, _updates, _drops = session
    announce(n, LINK, [T::Adjacency_sid.new(0x30, 5, 24001),
                       T::Lan_adjacency_sid.new(0x30, 0, '0000.0000.0003', 24002)])
    assert(wait_for { only_route(router) }, "GoBGP to install it\n#{router.log}")
    _key, attr = only_route(router)
    assert_equal(24001, attr['link']['adjacency_sid'])
    assert_equal([{ 'flags' => 0, 'weight' => 0, 'sid' => 24001 }],
                 attr['link']['sr_adjacency_sids'],
                 'GoBGP 4.10.0 loses the flags and weight on its API side')
  end

  # RFC 9086 section 5, all three Peering SIDs, one of them an index.
  # GoBGP names each flag, so this checks bgp4r's bit positions:
  # 0x30 is B and P (Figure 3).
  def test_the_peering_sids_reach_the_router
    n, router, _updates, _drops = session
    announce(n, EPE, [T::Peer_node_sid.new(0xc0, 1, 24000),
                      T::Peer_adj_sid.new(0x30, 2, 24010),
                      T::Peer_set_sid.new(0x80, 3, 9, 4)])
    assert(wait_for { only_route(router) }, "GoBGP to install it\n#{router.log}")
    key, attr = only_route(router)
    assert_match(/LOCAL_NODE: 10\.0\.0\.1 REMOTE_NODE: 10\.0\.0\.2/, key,
                 'and GoBGP reads 516 on both ends')
    assert_match(/BGP:0/, key, 'Protocol-ID 7')
    seg = attr['bgp_peer_segment']
    flags = lambda do |v, l, b, p|
      { 'value' => v, 'local' => l, 'backup' => b, 'persistent' => p }
    end
    assert_equal({ 'flags' => flags[true, true, false, false],
                   'weight' => 1, 'sid' => 24000 }, seg['bgp_peer_node_sid'])
    assert_equal({ 'flags' => flags[false, false, true, true],
                   'weight' => 2, 'sid' => 24010 }, seg['bgp_peer_adjacency_sid'])
    assert_equal({ 'flags' => flags[true, false, false, false],
                   'weight' => 3, 'sid' => 9 }, seg['bgp_peer_set_sid'])
  end

  # **A gap in GoBGP.** Its RIB shows no prefix attribute TLV on a
  # Prefix NLRI, RFC 9552's own Prefix Metric included, so our
  # Prefix-SID cannot be read back here. The route installs with the
  # attribute, and its `prefix` object is empty. The unit and functional
  # tests are the cover for 1158.
  def test_gobgp_shows_no_prefix_attribute_tlv
    n, router, _updates, _drops = session
    nlri = { :ipv6_prefix => { :protocol_id => 2, :identifier => 0,
                               :tlvs => [LOCAL, { :ip_reachability => '2001:db8::/32' }] } }
    announce(n, nlri, [T::Prefix_metric.new(10), T::Prefix_sid.new(0x40, 0, 5, 4)])
    assert(wait_for { only_route(router) }, "GoBGP to install it\n#{router.log}")
    _key, attr = only_route(router)
    assert_not_nil(attr, 'the attribute is kept')
    assert_equal({}, attr['prefix'], 'and GoBGP 4.10.0 shows nothing in it')
  end

  # --- negative: the same octets judged by both -------------------------

  # A SID/Label sub-TLV whose Length runs past its 1034. bgp4r reports
  # attribute discard (RFC 9552 section 8.2.2, its third attribute
  # bullet), and GoBGP does exactly that: the route installs without the
  # attribute and the session stays up.
  def test_a_malformed_sr_capabilities_is_attribute_discard_at_both_ends
    n, router, _updates, drops = session
    bad = T::Sr_capabilities.new(:flags => 0, :ranges => [
            { :size => 8000, :length => 9, :sid_label => { :label => 16000 } }])
    a = BGP::Link_state_attribute.new(bad)
    ours = BGP::Attr::Check.attribute(a.encode.is_packed)
    assert_equal([:attribute_discard], ours.collect(&:action))
    announce(n, NODE, [bad])
    assert(wait_for { only_route(router) }, "GoBGP to install it\n#{router.log}")
    _key, attr = only_route(router)
    assert_nil(attr, 'GoBGP discarded the BGP-LS Attribute')
    assert_match(/Some attributes were discarded.*LS TLV malformed/, router.log)
    assert_equal([], drops, 'and kept the session')
  end

  # **A fault in GoBGP.** An Adjacency SID of 9 octets: RFC 9552 section
  # 8.2.2 lists "the length of a fixed-length TLV is correct" among the
  # checks not to make, and bgp4r reports nothing. GoBGP discards the
  # whole BGP-LS Attribute, which section 8.2.2 also says loses every
  # other TLV in it: the Node Name beside it goes too.
  def test_gobgp_discards_the_attribute_for_an_adjacency_sid_it_does_not_expect
    n, router, _updates, drops = session
    tlvs = [T::Node_name.new('r1'),
            T::Unknown.new(1099, ['300000000000000001'].pack('H*'))]
    ours = BGP::Attr::Check.attribute(BGP::Link_state_attribute.new(*tlvs).encode.is_packed)
    assert_equal([], ours, 'bgp4r: no finding')
    announce(n, LINK, tlvs)
    assert(wait_for { only_route(router) }, "GoBGP to install it\n#{router.log}")
    _key, attr = only_route(router)
    assert_nil(attr, 'GoBGP 4.10.0 discarded the whole attribute')
    assert_match(/Incorrect Adjacency SID length/, router.log)
    assert_equal([], drops)
  end

  # Semantic faults both ends ignore: a non-zero Reserved octet, and an
  # index where RFC 9085 section 2.1.2 says only a label is valid. GoBGP
  # reads the SRGB from each.
  def test_semantic_faults_in_sr_capabilities_are_ignored_at_both_ends
    [T::Sr_capabilities.new(:flags => 0xc0, :reserved => 0xff,
                            :ranges => [{ :size => 8000, :sid_label => { :label => 16000 } }]),
     T::Sr_capabilities.new(0xc0, [[8000, T::Sid_label.new(16000, 4)]])].each do |t|
      ours = BGP::Attr::Check.attribute(BGP::Link_state_attribute.new(t).encode.is_packed)
      assert_equal([], ours)
      n, router, _updates, _drops = session
      announce(n, NODE, [t])
      assert(wait_for { only_route(router) }, "GoBGP to install it\n#{router.log}")
      _key, attr = only_route(router)
      assert_equal([{ 'begin' => 16000, 'end' => 24000 }],
                   attr['node']['sr_capabilities']['ranges'], t.to_s)
      teardown
      @routers, @listeners = [], []
    end
  end

end
