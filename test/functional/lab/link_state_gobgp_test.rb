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

# BGP-LS against GoBGP, RFC 9552, AFI 16388 SAFI 71 and 72.
#
# **This is the first lab test here where the router encodes the family
# under test, so its own octets feed bgp4r's decoder.** Every lab test
# since flow spec sends only: it asserts a router's reading of what
# bgp4r put on the wire, and records in its own comments that the parse
# direction is covered by the loopback functional test alone. GoBGP
# 3.23.0 can **originate** a BGP-LS route.
#
# Be exact about that first, because `attr_set_gobgp_test.rb` is the
# nearest precedent and is not this. There a gobgpd sits between two
# bgp4r speakers and the far one parses an UPDATE GoBGP built, so its
# ORIGIN, AS_PATH, next hop and NLRI are GoBGP's; but attribute 128,
# the thing under test, is copied verbatim and never parsed by the
# router, so those octets are still ours. Here GoBGP builds the NLRI
# itself.
#
# `docs/bgp-ls.md` section 11 has the measurements and the table. The
# short version of what each direction buys:
#
# * **Receive.** The octets are GoBGP's, so the framing of section 5.2,
#   the node and link descriptors of 5.2.1 and 5.2.2 and the next hop
#   of 5.5 are read from something this reader did not write. It is also
#   where the keep-and-echo MUST of section 5.1 meets real traffic:
#   GoBGP sends sub-TLV 516, which is RFC 9086's and not in bgp4r, and
#   the NLRI still replays byte for byte.
# * **Send.** GoBGP names our Autonomous System, BGP-LS Identifier, IGP
#   Router-ID, Protocol-ID, link addresses, OSPF route type and prefix
#   back, each from its own field.
#
# **Two measurements here are about GoBGP being wrong, and both are
# recorded rather than filed**, per the standing decision that the job
# is bgp4r catching up: it requires a sub-TLV RFC 9552 does not, and its
# client crashes rendering a prefix wider than one octet. The first is
# the one that matters to bgp4r, because it is a check section 8.2.2
# tells a BGP-LS Propagator **not** to make, so it is an argument for
# part 6 following the RFC rather than the one router available.
#
# SAFI 72 has no reference at all: GoBGP has no config name for it and
# reads the pair back as an unknown family, which is the VPN flow spec
# shape, one SAFI of a pair checkable and the other not. FRR 8.4.4 has
# neither SAFI; that absence is `link_state_frr_test.rb`.
#
# **What neither direction here can check, measured by sabotage.** The
# receive cases cannot catch a parse-side framing slip: GoBGP originates
# one NLRI per UPDATE, and the only NLRI in an attribute has nothing
# behind it to over-read into, so `Link_state.nlri_size` wrong by a
# constant leaves every case here passing. That is RT-constrain's lesson
# arriving from the receive side, and it is why the multi-NLRI cases in
# `test/functional/link_state_test.rb` must not be thinned out: they are
# the only cover the framing has. The send cases do catch an encode-side
# slip, because GoBGP reads the length and a wrong one sends the UPDATE
# to RFC 7606 rather than to its RIB.
#
# **Every case gets a session of its own.** Not tidiness: two cases
# below leave GoBGP having dropped the family from its own neighbor
# output, and one leaves its RIB in a state the client cannot print, so
# nothing after either on a shared session would read the same.
class LinkStateGobgpTest < Test::Unit::TestCase

  OUR_AS = 65001
  THEIR_AS = 65002
  G = LabHelper::Gobgpd

  # Section 5.2: "AFI 16388 / SAFI 71 is used for BGP-LS" and SAFI 72
  # for the VPN application.
  AFI      = 16388
  SAFI     = 71
  SAFI_VPN = 72

  # What GoBGP calls a pair it does not know, in its own packing:
  # `UnknownFamily(afi << 16 | safi)`. Derived rather than written as a
  # number so the test says where it comes from, and asserted below
  # against the text GoBGP really prints.
  UNKNOWN_VPN = (AFI << 16) | SAFI_VPN

  # Names a reader might reach for for SAFI 72. None is a family name
  # GoBGP knows, and the first case asserts its config parser refuses
  # each one. They are guesses rather than anything a document gives:
  # GoBGP's own vocabulary pairs a VPN family with `l3vpn-`, as in
  # `l3vpn-ipv4-flowspec`, so the list tries both orders.
  VPN_GUESSES = %w[ls-vpn linkstate-vpn l3vpn-ls vpn-ls ls-l3vpn].freeze

  # A prefix in a family GoBGP does carry, sent the same way a BGP-LS
  # route is, so a case can prove the session and our encoder are good
  # before scoring a verdict about SAFI 72. That discipline is
  # fault_matrix_scenario.rb's test_the_rib_answer_was_usable.
  CONTROL = '198.51.100.0/24'.freeze

  # The version these expectations were measured against. The text GoBGP
  # prints is its own and a release may reword it, so the whole file
  # omits itself elsewhere rather than failing, which is the shape the
  # FRR files use. `bgp_ls_doc_test.rb` holds this against the version
  # in docs/bgp-ls.md section 11, so the table cannot keep claiming a
  # measurement nothing ran.
  MEASURED_MAJOR = 3

  # The client's own grammar for originating a Link NLRI, measured on
  # 2026-11-01 and the first step of this part, because nothing
  # documents it here: `gobgp global rib add -a ls link` answers "26
  # args required at least" and `node` and `prefix` are refused outright
  # with "invalid nlriType. expect [link]". So type 2 is the only one
  # GoBGP can be made to originate, and these sixteen keyword and value
  # pairs are what it wants: every one is read without a presence check,
  # so leaving any out is an error rather than a default.
  #
  # Treat the token list as GoBGP's and not contractual. If a release
  # reworks it the add fails, the case says so with the client's words,
  # and that is a test to update.
  LINK_ARGS = %w[
    identifier 7
    local-asn 65002 local-bgp-ls-id 1 local-bgp-router-id 10.0.0.2
    local-bgp-confederation-member 0
    remote-asn 65001 remote-bgp-ls-id 2 remote-bgp-router-id 10.0.0.1
    remote-bgp-confederation-member 0
    ipv4-interface-address 192.0.2.1 ipv4-neighbor-address 192.0.2.2
    ipv6-interface-address 2001:db8::1 ipv6-neighbor-address 2001:db8::2
    sid 1000 sid-type node weight 1
  ].freeze

  # One Local Node Descriptors TLV, section 5.2.1.2, "a mandatory TLV in
  # all three types of NLRIs", holding three of the four sub-TLVs of
  # section 5.2.1.4. The IGP Router-ID is in it because **GoBGP refuses
  # a node descriptor without one**; see the case on that below.
  LOCAL = { :local_node_descriptors =>
            [{ :autonomous_system => OUR_AS },
             { :bgp_ls_identifier => 1 },
             { :igp_router_id => '1921.6800.1001' }] }.freeze

  # And the remote one, section 5.2.1.3, "a mandatory TLV for Link
  # NLRIs".
  REMOTE = { :remote_node_descriptors =>
             [{ :autonomous_system => THEIR_AS },
              { :igp_router_id => '1921.6800.2002' }] }.freeze

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

  def teardown
    @routers.each { |r| r.down }
    @listeners.each do |server, neighbor, thread|
      thread.kill if thread
      neighbor.close
      server.close unless server.closed?
    end
  rescue IOError, SystemCallError
  end

  # Queues the UPDATEs the bgp4r side parsed, which is how the receive
  # direction is read. A class rather than a block because Observable
  # wants an object answering update, and the full BGP:: name because a
  # nested class does not see an include in the class around it: Neighbor
  # logs an exception from an observer rather than raising it, so a wrong
  # constant here shows up as "nothing arrived".
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

  # Collects NOTIFICATIONs as [code, subcode], out of to_hash, which is
  # how lab/fault_matrix.rb reads them: Notification keeps @code and
  # @subcode with no readers.
  class Catcher
    def initialize(list) ; @list = list ; end

    def update(message, *_)
      return unless message.is_a?(::BGP::Notification)
      h = message.to_hash
      @list << [h[:code], h[:subcode]]
    end
  end

  # A bgp4r speaker offering IPv4 unicast and one BGP-LS SAFI, with a
  # gobgpd configured for the `ls` family dialling it.
  #
  # The state changes are collected from the moment the session comes
  # up, because **is_established? cannot answer whether a router reset
  # us**: it reconnects, and a read a few seconds later sees the new
  # session and says true. That is the mistake the first MCAST-VPN
  # measurement made.
  def session(safi = SAFI, families = [G::LS])
    server = TCPServer.new('127.0.0.1', 0)
    n = BGP::Neighbor.new(4, OUR_AS, 180, '0.0.0.1', '127.0.0.2', '127.0.0.1')
    n.add_cap BGP::OPT_PARM::CAP::Mbgp.new(1, 1)
    n.add_cap BGP::OPT_PARM::CAP::Mbgp.new(AFI, safi)
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
                   :families => families)
    @routers << router
    router.up
    assert(wait_for { n.is_established? }, "the session came up\n#{router.log}")
    drops, notes = [], []
    n.on_state_change { |now, was| drops << [was, now] }
    n.add_observer(Catcher.new(notes))
    [n, router, updates, drops, notes]
  end

  def wait_for(timeout = 30)
    deadline = Time.now + timeout
    loop do
      return true if yield
      return false if Time.now > deadline
      sleep 0.2
    end
  end

  # One UPDATE carrying one MP_REACH_NLRI for this family.
  def announce(n, nlris, safi = SAFI, nexthop = '10.0.0.1')
    n.send_update BGP::Update.new(
      BGP::Path_attribute.new(BGP::Origin.new(0),
                              BGP::As_path.new(OUR_AS),
                              BGP::Mp_reach.new(:safi => safi,
                                                :nexthop => [nexthop],
                                                :nlris => nlris)))
  end

  # One IPv4 unicast route, in an MP_REACH_NLRI rather than in the RFC
  # 4271 section 4.3 fields. That is what makes it a control worth
  # having: it holds the attribute, the next hop and the AS_PATH
  # constant and varies only the SAFI, so a discard below cannot be
  # GoBGP objecting to MP_REACH or to our encoding of it.
  def announce_control(n)
    n.send_update BGP::Update.new(
      BGP::Path_attribute.new(BGP::Origin.new(0),
                              BGP::As_path.new(OUR_AS),
                              BGP::Mp_reach.new(:safi => 1,
                                                :nexthop => '10.0.0.1',
                                                :nlris => [CONTROL])))
  end

  # The `multiprotocol:` block of `gobgp neighbor <addr>`, as a Hash of
  # the family GoBGP names to what it says about it. Parsed out of the
  # human readable form rather than the JSON one, because the JSON
  # carries `remote_cap` as base64 protobuf and so repeats the octets we
  # sent, where this text is GoBGP's own verdict on them. Treat the
  # exact words as GoBGP's, the way the flow spec keys are treated.
  def multiprotocol(router)
    out = router.neighbor('127.0.0.1').to_s
    block = out[/^\s*multiprotocol:\n((?:\s{8}\S.*\n)+)/, 1].to_s
    block.lines.to_h do |line|
      name, verdict = line.strip.split(/:\s*/, 2)
      [name, verdict.to_s.strip]
    end
  end

  # One row of the `Message statistics:` table, as [sent, received], or
  # [nil, nil] while the client is not answering, so a caller can read
  # the received count inside a wait_for without a guard of its own.
  def messages(router, kind)
    m = router.neighbor('127.0.0.1').to_s.match(/^\s*#{kind}:\s+(\d+)\s+(\d+)/)
    m ? [m[1].to_i, m[2].to_i] : [nil, nil]
  end

  # The one BGP-LS route in the router's RIB, as [key, path], or nil
  # when it holds none. Every case here sends or originates exactly one,
  # which saves each test spelling a key the router's way.
  def only_route(router)
    router.only_rule(G::LS)
  end

  # The one Link_state NLRI out of an UPDATE's MP_REACH_NLRI.
  def received_nlri(update)
    a = update.path_attribute.find(BGP::Mp_reach)
    assert_not_nil(a, 'an Mp_reach, not an Attr::Raw')
    assert_equal(AFI, a.afi)
    assert_equal(SAFI, a.safi)
    assert_equal(1, a.nlris.size)
    a.nlris.first
  end

  # --- The receive direction, which no other family here has ----------

  # GoBGP originates a Link NLRI and bgp4r reads it: the section 5.2
  # framing, the Protocol-ID and Identifier of figure 8, both node
  # descriptors and five of the six link descriptors of section 5.2.2.
  #
  # **What the replay says and what it does not.** Every field read
  # below is read by code this reader wrote against the document, so the
  # replay is the one assertion here that is not about this reader's
  # understanding: bgp4r's decode of GoBGP's octets re-encodes to those
  # octets, so nothing was dropped, padded or normalised on the way
  # through.
  #
  # It is **not** a check on the framing arithmetic, which is the thing
  # it most looks like. `Link_state.nlri_size` wrong by a constant
  # leaves this case passing, because GoBGP sends one NLRI per UPDATE
  # and the only NLRI in an attribute has nothing behind it to
  # over-read into. Measured by sabotage; the file comment has it.
  def test_a_link_nlri_from_gobgp_parses_and_replays
    _n, router, updates, _drops, _notes = session
    out, status = router.client_run(*%w[global rib add -a ls link], *LINK_ARGS)
    assert(status.success?,
           "the client to originate a Link NLRI: #{out}\n#{router.log}")

    got = updates.shift
    assert_not_nil(got, "an UPDATE from GoBGP\n#{router.log}")
    ls = received_nlri(got)

    assert_equal(false, ls.vpn?, 'SAFI 71, so no Route Distinguisher')
    assert_nil(ls.rd)
    assert_instance_of(BGP::Link_state::Link, ls.nlri,
                       'NLRI Type 2, section 5.2 figure 8')
    assert_equal(133, ls.length,
                 'the Total NLRI Length GoBGP wrote, which is the one ' \
                 'number here neither side computed from the other')
    assert_equal(7, ls.nlri.identifier, 'the Identifier we asked it for')

    # Protocol-ID 7 is RFC 9086's and is not in Table 2 of section 5.2.
    # bgp4r answered 'Unassigned' here until this test was written, read
    # the registry and found three more; see Headed::PROTOCOLS.
    assert_equal(7, ls.nlri.protocol_id)
    assert_equal('BGP', ls.nlri.protocol,
                 'the registry name for the Protocol-ID a real router sends')

    assert_equal([256, 257, 258, 259, 260, 261, 262],
                 ls.nlri.tlvs.collect(&:type),
                 'both node descriptors and five link descriptors')
    assert_equal([], ls.nlri.tlvs.grep(BGP::Link_state::Tlv::Unknown),
                 'all of which bgp4r implements')

    { 259 => '192.0.2.1', 260 => '192.0.2.2',
      261 => '2001:db8::1', 262 => '2001:db8::2' }.each do |type, address|
      assert_equal(address, ls.nlri.tlv(type).address.to_s,
                   "the address in TLV #{type}, section 5.2.2")
    end
    ids = ls.nlri.tlv(258)
    assert_equal([0, 0], [ids.local, ids.remote],
                 'and TLV 258, which GoBGP always writes and always zeroes')

    assert_equal(ls.to_shex,
                 BGP::Link_state.new_ntop([ls.to_shex].pack('H*').is_packed,
                                          SAFI).to_shex,
                 'the NLRI replays byte for byte')
    a = got.path_attribute.find(BGP::Mp_reach)
    assert_equal(a.to_shex,
                 BGP::Mp_reach.new([a.to_shex].pack('H*').is_packed).to_shex,
                 'and so does the whole attribute, next hop included')
  end

  # The one sub-TLV GoBGP sends that bgp4r does not implement, which is
  # the keep-and-echo MUST of section 5.1 meeting real traffic rather
  # than a test's own hex: "Unknown and unsupported types MUST be
  # preserved and propagated within both the NLRI and the BGP-LS
  # Attribute", and their presence "MUST NOT result in the NLRI or the
  # BGP-LS Attribute being considered malformed".
  #
  # 516 is the BGP Router Identifier of RFC 9086 section 4.1, which part
  # 2 left out because the four sub-TLVs of Table 3 are RFC 9552's.
  def test_the_unimplemented_sub_tlv_is_kept_and_reported_as_no_error
    _n, router, updates, _drops, _notes = session
    router.client_run(*%w[global rib add -a ls link], *LINK_ARGS)
    got = updates.shift
    assert_not_nil(got, "an UPDATE from GoBGP\n#{router.log}")
    ls = received_nlri(got)

    # **Asserted before reaching for a descriptor**, because the keep is
    # enforced twice and the outer one fires first: an `Unknown` that
    # dropped its octets would make the NLRI fail `read_route`'s
    # encode-matches rule, so the whole thing would come back as a
    # `Link_state::Unknown` and the assertions below would die on a
    # missing method rather than naming the claim. Measured by
    # sabotaging `Tlv::Unknown#encode_value`.
    assert_instance_of(BGP::Link_state::Link, ls.nlri,
                       'the route type still reads as a Link, so nothing ' \
                       'under it lost octets')

    local = ls.nlri.local_node_descriptors
    assert_equal([512, 516, 513], local.sub_tlvs.collect(&:type))
    unknown = local.sub_tlvs.find { |t| t.type == 516 }
    assert_instance_of(BGP::Link_state::Tlv::Unknown, unknown)
    assert_equal('020400040a000002', unknown.to_shex,
                 'kept whole, so the BGP Router-ID we asked for is still ' \
                 'in the octets')

    assert_equal(0, got.path_attribute.errors.size,
                 'and no protocol error, which section 5.1 requires: ' \
                 "#{got.path_attribute.errors.collect(&:reason).inspect}")
    assert_equal(0, got.path_attribute.undecoded.size,
                 'nor a coverage gap, since the NLRI decoded')
  end

  # **GoBGP's own node descriptors are not in ascending sub-TLV order**,
  # 512 then 516 then 513, where section 5.2.1.4 says "The sub-TLVs
  # within a Node Descriptor MUST be arranged in ascending order by
  # sub-TLV type".
  #
  # This is the measurement that bears on part 6. bgp4r **reports** the
  # order and refuses nothing, which is what `Node_descriptors#ordered?`
  # is for, and the only router available here breaks the rule on
  # traffic it originates itself. So a check that made unordered
  # sub-TLVs a protocol error would call GoBGP malformed on every route
  # it sends, which is a reason to read section 8.2.2 before writing
  # one rather than a reason to copy the router.
  def test_gobgps_node_descriptors_break_the_ascending_order_must
    _n, router, updates, _drops, _notes = session
    router.client_run(*%w[global rib add -a ls link], *LINK_ARGS)
    got = updates.shift
    assert_not_nil(got, "an UPDATE from GoBGP\n#{router.log}")
    ls = received_nlri(got)

    local = ls.nlri.local_node_descriptors
    assert_equal(false, local.ordered?,
                 'section 5.2.1.4 ascending order, which GoBGP breaks: ' \
                 "#{local.sub_tlvs.collect(&:type).inspect}")
    assert_equal([], local.duplicate_types,
                 'while the other rule of that section holds, so the two ' \
                 'are reported separately and one failing is not the other')
    assert_equal(0, got.path_attribute.errors.size,
                 'and bgp4r reports no protocol error for it, which is ' \
                 'the decision part 6 has to make and not unmake here')

    assert(BGP::Link_state::Tlv.ordered?(ls.nlri.tlvs),
           'the NLRI\'s own TLVs are in order, so the breach is one level ' \
           'down and not everywhere')
  end

  # A withdrawal from GoBGP, which is the other half of the receive
  # direction: the same NLRI under MP_UNREACH_NLRI, with no next hop.
  def test_a_withdrawal_from_gobgp_parses_and_replays
    _n, router, updates, _drops, _notes = session
    router.client_run(*%w[global rib add -a ls link], *LINK_ARGS)
    assert_not_nil(updates.shift, "the announcement\n#{router.log}")

    out, status = router.client_run(*%w[global rib del -a ls link], *LINK_ARGS)
    assert(status.success?, "the client to withdraw it: #{out}")

    got = updates.shift
    assert_not_nil(got, "a withdrawal from GoBGP\n#{router.log}")
    a = got.path_attribute.find(BGP::Mp_unreach)
    assert_not_nil(a, 'an Mp_unreach, not an Attr::Raw')
    assert_equal(AFI, a.afi)
    assert_equal(SAFI, a.safi)
    assert_equal(1, a.nlris.size)
    assert_instance_of(BGP::Link_state::Link, a.nlris.first.nlri)
    assert_equal(a.to_shex,
                 BGP::Mp_unreach.new([a.to_shex].pack('H*').is_packed).to_shex,
                 'and it replays byte for byte')
  end

  # The BGP-LS Attribute, code 29, arrives with the route.
  #
  # **This case has fired once and is re-pointed rather than
  # weakened.** Until part 5a the attribute came back as an
  # `Attr::Unknown` with no error and no gap, which was #116 working one
  # level up, and the comment here said part 5 would give it meaning.
  # It has: the attribute parses now, and what it carries is one TLV of
  # type **1101**, the Adjacency SID of RFC 9085. Measured on
  # 2026-11-01 against gobgpd 3.23.0.
  #
  # **So this is the keep-and-echo MUST of section 5.1 met inside the
  # attribute**, where the NLRI case above meets it in the descriptors:
  # 1101 is not in RFC 9552's Table 18 at all, so no part of this plan
  # will implement it and the example cannot expire. Parts 5b and 5c
  # add Table 8's and Table 10's TLVs, and 1101 is in neither.
  #
  # What the case pins either way is that an attribute carrying a TLV
  # bgp4r has no class for is not a protocol error, which is the claim
  # part 6 has to keep rather than rediscover.
  def test_the_attribute_arrives_and_is_kept_without_being_an_error
    _n, router, updates, _drops, _notes = session
    router.client_run(*%w[global rib add -a ls link], *LINK_ARGS)
    got = updates.shift
    assert_not_nil(got, "an UPDATE from GoBGP\n#{router.log}")

    pa = got.path_attribute
    assert_equal([1, 2, 14, 29], pa.attributes.collect(&:type),
                 'ORIGIN, AS_PATH, MP_REACH_NLRI and the BGP-LS Attribute')
    attr29 = pa.attributes.find { |x| x.type == 29 }
    assert_instance_of(BGP::Link_state_attribute, attr29,
                       'part 5a gave code 29 a class of its own')
    assert_equal([1101], attr29.tlvs.collect { |t| t.type },
                 "the Adjacency SID of RFC 9085, which is what GoBGP " \
                 "sends for `sid 1000 sid-type node weight 1`\n#{router.log}")
    assert_equal([BGP::Link_state::Tlv::Unknown],
                 attr29.tlvs.collect { |t| t.class },
                 'kept and echoed, since 1101 is in no table of RFC 9552')
    assert_equal(0, pa.errors.size,
                 'a TLV bgp4r cannot read is not the peer\'s fault, which ' \
                 'section 5.1 requires in so many words')
    assert_equal(0, pa.undecoded.size,
                 'and is not an Attr::Gap either, since the attribute ' \
                 'decoded and the TLV inside it is a first-class object')
    assert_equal(attr29.to_shex,
                 BGP::Link_state_attribute.new(attr29.encode.is_packed).to_shex,
                 'and the attribute replays on its own as well as in the ' \
                 'UPDATE below')
    assert_equal(got.to_shex,
                 BGP::Update.new([got.to_shex].pack('H*').is_packed).to_shex,
                 'so the whole UPDATE replays, attribute 29 included')
  end

  # --- The send direction ---------------------------------------------

  # A Node NLRI, section 5.2 figure 7, read back by the router. Four
  # fields in one key, each from a different place in the octets: the
  # Autonomous System and BGP-LS Identifier sub-TLVs, the IGP Router-ID
  # sub-TLV, and the Protocol-ID octet of the head.
  #
  # **The IGP Router-ID is the one worth having.** Part 4 found that
  # `Igp_router_id#from_hash` packed the dotted form with `pack('H*')`,
  # which maps a separator by its low nibble, so `1921.6800.1001` became
  # nine octets instead of six. GoBGP printing the ISO form back is the
  # only check on those six octets that is not bgp4r's own arithmetic.
  def test_a_node_nlri_reaches_the_router
    n, router, _updates, _drops, _notes = session
    announce(n, [{ :node => { :protocol_id => 2, :identifier => 7,
                              :tlvs => [LOCAL] } }])

    assert(wait_for { only_route(router) },
           "GoBGP to install the Node NLRI\n#{router.log}")
    key, path = only_route(router)
    assert_match(/NODE/, key, "GoBGP to call it a node: #{key}")
    assert_match(/AS:#{OUR_AS}/, key, 'our Autonomous System sub-TLV')
    assert_match(/BGP-LS ID:1/, key, 'our BGP-LS Identifier sub-TLV')
    assert_match(/1921\.6800\.1001/, key,
                 'and our IGP Router-ID, in the ISO form, which is the ' \
                 'field part 4 had to fix')
    assert_match(/ISIS-L2:7/, key,
                 'with the Protocol-ID and Identifier of the head')
    assert_equal(1, path['nlri']['type'], 'NLRI Type 1')
  end

  # A Link NLRI, figure 8, with both node descriptors and two of the
  # link descriptors of section 5.2.2. GoBGP renders the pair as one
  # arrow, which is its reading of TLV 259 and TLV 260 by their own
  # types.
  def test_a_link_nlri_reaches_the_router
    n, router, _updates, _drops, _notes = session
    announce(n, [{ :link =>
                   { :protocol_id => 2, :identifier => 0,
                     :tlvs => [LOCAL, REMOTE,
                               { :ipv4_interface_address => '192.0.2.5' },
                               { :ipv4_neighbor_address => '192.0.2.6' },
                               { :link_local_remote_identifiers =>
                                 { :local => 11, :remote => 22 } }] } }])

    # **TLV 258 is in the input and nothing below asserts it**, which is
    # deliberate: GoBGP decodes it, since it has a case for
    # LS_TLV_LINK_ID, and renders none of it, so the only reading
    # available is that the route still installs with it there. The
    # receive direction is where its octets are read, off GoBGP's own
    # route.
    assert(wait_for { only_route(router) },
           "GoBGP to install the Link NLRI\n#{router.log}")
    key, path = only_route(router)
    assert_match(/LINK/, key, "GoBGP to call it a link: #{key}")
    assert_match(/LOCAL_NODE: 1921\.6800\.1001/, key)
    assert_match(/REMOTE_NODE: 1921\.6800\.2002/, key,
                 'so both node descriptors are read, and apart')
    assert_match(/LINK: 192\.0\.2\.5->192\.0\.2\.6/, key,
                 'and the two IPv4 link descriptors, each by its own type')
    assert_equal(2, path['nlri']['type'], 'NLRI Type 2')
  end

  # An IPv4 Prefix NLRI, figure 9, with the two prefix descriptors of
  # section 5.2.3. The OSPF Route Type comes back as a name, which is
  # GoBGP reading the one octet of TLV 264 against the same six values
  # section 5.2.3.1 lists.
  #
  # **The prefix is a /8 for a reason**, and it is GoBGP's: a prefix
  # wider than one octet crashes its client. See the case below.
  def test_an_ipv4_prefix_nlri_reaches_the_router
    n, router, _updates, _drops, _notes = session
    announce(n, [{ :ipv4_prefix =>
                   { :protocol_id => 3, :identifier => 0,
                     :tlvs => [LOCAL, { :ospf_route_type => 2 },
                               { :ip_reachability => '10.0.0.0/8' }] } }])

    assert(wait_for { only_route(router) },
           "GoBGP to install the IPv4 Prefix NLRI\n#{router.log}")
    key, path = only_route(router)
    assert_match(/PREFIXv4/, key, "GoBGP to call it an IPv4 prefix: #{key}")
    assert_match(/PREFIX: \[10\.0\.0\.0\/8\]/, key,
                 'the IP Reachability TLV, length in bits and prefix packed ' \
                 'down, read back as a prefix')
    assert_match(/OSPF_ROUTE_TYPE:INTER-AREA/, key,
                 'and route type 2 of section 5.2.3.1, by name')
    # The same value, named by bgp4r out of its own table, so the two
    # implementations are read side by side on one octet rather than
    # one of them being taken on trust.
    assert_equal('OSPF route type Inter-Area',
                 BGP::Link_state::Tlv::Ospf_route_type.new(2).to_s,
                 'which is what bgp4r calls it too, from Table 5')
    assert_equal(3, path['nlri']['type'], 'NLRI Type 3')
  end

  # **A GoBGP bug, recorded and not filed**, per the standing decision
  # that the job here is bgp4r catching up: its client panics rendering
  # an IP Reachability TLV whose prefix is more than one octet.
  #
  # The daemon accepts and stores the route either way, and the /8 case
  # above renders, so this is the renderer and not the parser. It is
  # deterministic: /16, /24 and /32 all panic and /8 does not.
  #
  # Asserted rather than avoided, because a lab test that quietly sends
  # only the shape that works is the unchecked claim this repository
  # keeps getting burned by. If a later GoBGP fixes it, this fails and
  # says to re-measure.
  def test_the_client_panics_rendering_a_prefix_wider_than_one_octet
    n, router, _updates, _drops, notes = session
    announce(n, [{ :ipv4_prefix =>
                   { :protocol_id => 3, :identifier => 0,
                     :tlvs => [LOCAL,
                               { :ip_reachability => CONTROL }] } }])

    out = nil
    assert(wait_for { out = router.client_run('global', 'rib', '-a', 'ls')[0]
                      out =~ /panic: runtime error/ },
           "the client to panic reading the RIB, answered #{out.inspect}\n" \
           "#{router.log}")
    assert_match(/index out of range \[1\] with length 1/, out,
                 'in ToIPNet, which copies one octet per eight bits of ' \
                 'declared prefix length out of a shorter slice')
    assert_equal([], notes,
                 'while the daemon itself sends no NOTIFICATION over it')
    assert(wait_for { messages(router, 'Updates')[1] == 1 },
           'and counts the UPDATE as an UPDATE, so it took the route: ' \
           "#{messages(router, 'Updates').inspect}")
  end

  # **The measurement that matters most to part 6: GoBGP requires a
  # sub-TLV RFC 9552 does not, and refusing it costs the whole
  # family.**
  #
  # Section 5.2.1.4 makes the IGP Router-ID "a mandatory TLV when
  # originating information from IS-IS, OSPF, 'Direct', or 'Static
  # configuration'", which binds an **originator** and names no receiver
  # action, and the Autonomous System sub-TLV is "an optional TLV".
  # GoBGP requires every node descriptor to carry either an IGP
  # Router-ID or both a BGP Router-ID and an Autonomous System,
  # whatever the Protocol-ID, and answers a descriptor holding only an
  # Autonomous System with "Required TLV missing" and
  # `Capability was disabled`.
  #
  # Section 8.2.2 names "presence of a mandatory TLV" among the semantic
  # validations a BGP-LS Propagator "should not perform". So this is one
  # implementation doing what this family's own RFC says not to, which
  # is the clearest argument there is for part 6 following the RFC: one
  # router agreeing or disagreeing is not a quorum, and here it
  # disagrees with the document.
  #
  # The session survives, and that is worth separating from the family
  # surviving: the capability goes and the route never arrives.
  def test_gobgp_requires_a_sub_tlv_rfc_9552_does_not
    n, router, _updates, drops, notes = session

    announce_control(n)
    assert(wait_for { router.path(CONTROL) },
           "GoBGP to install #{CONTROL}, so the session is usable\n" \
           "#{router.log}")
    assert_equal('advertised and received', multiprotocol(router)[G::LS],
                 'and the family is negotiated to begin with')

    # The same Link NLRI as the case above, with the IGP Router-ID taken
    # out of the remote node descriptor and nothing else changed.
    announce(n, [{ :link =>
                   { :protocol_id => 2, :identifier => 0,
                     :tlvs => [LOCAL,
                               { :remote_node_descriptors =>
                                 [{ :autonomous_system => THEIR_AS }] },
                               { :ipv4_interface_address => '192.0.2.5' },
                               { :ipv4_neighbor_address => '192.0.2.6' }] } }])

    # **What "disabled" comes to here is narrower than for a family
    # GoBGP cannot name**, which is worth the separate reading: for SAFI
    # 72 the whole `UnknownFamily(...)` line goes away, where this one
    # loses its "received" half and stays listed as advertised. So the
    # neighbor output says the router will no longer take this family
    # from us, and says it in a form a test looking for a missing line
    # would miss.
    assert(wait_for { multiprotocol(router)[G::LS] == 'advertised' },
           'GoBGP to stop listing the family as received, still at ' \
           "#{multiprotocol(router)[G::LS].inspect}\n#{router.log}")
    assert_match(/"Error":"Required TLV missing"/, router.log,
                 'naming the check it made')
    assert_match(/"Cap":"ls".*Capability was disabled/, router.log,
                 'and what it cost, which is this family and not another')
    assert_nil(only_route(router), 'so the route is nowhere')

    assert_equal([], drops, 'the session itself survives')
    assert_equal([], notes, 'with no NOTIFICATION')
    assert(router.path(CONTROL),
           "and #{CONTROL} is still there, so what went is the family and " \
           'not the peer')
  end

  # --- SAFI 72, which has no reference at all -------------------------

  # GoBGP's config parser has no name for SAFI 72, which is the cheapest
  # and strongest form of the absence: the daemon will not start.
  # Gobgpd#up raises with the log, which names the key it rejected, and
  # only a port conflict is retried, so a raise here is the config and
  # not the harness.
  #
  # No session and no peer, so this case costs a second rather than ten.
  def test_gobgp_has_no_config_name_for_the_vpn_safi
    VPN_GUESSES.each do |name|
      router = G.new(:families => [name])
      @routers << router
      error = assert_raise(RuntimeError, "gobgpd to refuse #{name}") do
        router.up(:timeout => 10)
      end
      assert_match(/#{Regexp.escape(name)} isn't a valid route family name/,
                   error.message,
                   "gobgpd to name #{name} as the family it does not know")
    end
  end

  # The live half of that absence: a session comes up with SAFI 72
  # offered, GoBGP records the pair as received and as a family it
  # cannot name, and an UPDATE in it is discarded with the session kept.
  #
  # **Read the capability before sending anything in the family**, which
  # is a measurement and not an ordering preference: the line goes away
  # once an UPDATE arrives, so a test reading it afterwards would find
  # nothing and could conclude it was never received.
  def test_the_vpn_safi_is_an_unknown_family_and_its_update_is_discarded
    n, router, _updates, drops, notes = session(SAFI_VPN)

    families = multiprotocol(router)
    assert_equal('received', families["UnknownFamily(#{UNKNOWN_VPN})"],
                 "GoBGP to call AFI #{AFI} SAFI #{SAFI_VPN} an unknown " \
                 "family, received and not negotiated, in #{families.inspect}")
    assert_equal('advertised', families[G::LS],
                 'while SAFI 71 is advertised and not received, since this ' \
                 'session offered the other one')

    announce_control(n)
    assert(wait_for { router.path(CONTROL) },
           "GoBGP to install #{CONTROL}, so the session is usable\n" \
           "#{router.log}")
    updates = messages(router, 'Updates')[1]

    # One Node NLRI with the section 5.2 Route Distinguisher in front of
    # it, which is figure 6 and the only thing that distinguishes the
    # two SAFIs on the wire.
    announce(n, [{ :node => { :protocol_id => 2, :identifier => 1,
                              :rd => [100, 200], :tlvs => [LOCAL] } }],
             SAFI_VPN)

    assert(wait_for { messages(router, 'Discarded')[1] == 1 },
           'GoBGP to count the SAFI 72 UPDATE as discarded, counted ' \
           "#{messages(router, 'Discarded').inspect}\n#{router.log}")
    assert_match(/unknown route family. AFI: #{AFI}, SAFI: #{SAFI_VPN}/,
                 router.log, 'naming the family it discarded it for')
    assert_equal(updates, messages(router, 'Updates')[1],
                 'so it reaches no family and is not counted as an UPDATE')
    assert_equal([], drops, 'the session survives')
    assert_equal([], notes, 'with no NOTIFICATION')
    assert(router.path(CONTROL), "and #{CONTROL} is still there")
  end

end
