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

# **This file measures an absence**, the way mcast_vpn_frr_test.rb does.
# FRR 8.4.4 has no BGP-LS at all, neither SAFI 71 nor SAFI 72, so there
# is nothing to ask it about our octets: what this asserts is that the
# family is absent, how FRR says so, and what it does with a BGP-LS
# UPDATE sent anyway.
#
# **It is worth having because the two routers part company again.**
# GoBGP carries SAFI 71 and discards a SAFI 72 UPDATE with the session
# kept; FRR fails the whole UPDATE and tears the session down with no
# NOTIFICATION. That is the same split MCAST-VPN produced, from a
# different starting point: there neither router had the family, here
# one does.
#
# **And it reads differently from the MCAST-VPN absence in one place
# that is easy to miss.** For SAFI 5 FRR logged `afi/safi: IPv4/unknown`,
# naming the AFI and not the SAFI. Here it logs `bad-value/unknown`,
# because AFI 16388 is outside its table too, so it can name neither
# half of the pair. Asserted rather than assumed alike.
#
# `docs/bgp-ls.md` section 11 has the measurements and the table.
# `link_state_gobgp_test.rb` is the half that measures something.
class LinkStateFrrTest < Test::Unit::TestCase

  OUR_AS = 65001
  THEIR_AS = 65002
  F = LabHelper::Frr

  # Section 5.2: "AFI 16388 / SAFI 71 is used for BGP-LS" and SAFI 72
  # for the VPN application.
  AFI      = 16388
  SAFI     = 71
  SAFI_VPN = 72

  # Names a reader might reach for in FRR's `address-family` command.
  # Its grammar offers `ipv4 [<unicast|multicast|vpn|labeled-unicast|
  # flowspec>]`, the ipv6 twin and `l2vpn evpn`, so none of these is a
  # command. The first is what a **later** FRR uses, which is why it
  # leads the list: the family exists in FRR's own documentation now,
  # just not in 8.4.4, so this is the spelling that will one day make
  # this file fail and say to re-measure.
  GUESSES = ['link-state link-state', 'ipv4 link-state', 'linkstate',
             'ipv4 linkstate'].freeze

  # A prefix in a family FRR does carry, sent the same way the BGP-LS
  # route is, so the reset case can prove the session was usable at the
  # moment it sent the BGP-LS one and that nothing but the SAFI
  # differed. That discipline is fault_matrix_scenario.rb's
  # test_the_rib_answer_was_usable.
  CONTROL = '198.51.100.0/24'.freeze

  # The major version these expectations were measured against. Every
  # case here asserts FRR's own wording somewhere, so the gate is on the
  # whole file, which is the shape the other three FRR files use.
  #
  # **So a later FRR omits this file rather than failing it.**
  # `bgp_ls_doc_test.rb` holds this constant against the version in
  # docs/bgp-ls.md section 11, so bumping one without the other fails
  # the unit suite and the table cannot keep claiming a measurement
  # nothing ran.
  MEASURED = (8..8).freeze

  def setup
    unless F.available?
      flunk('FRR bgpd is not installed') if ENV['LAB_REQUIRE_FRR'] == '1'
      omit('FRR bgpd is not installed')
    end
    major = F.major
    unless major && MEASURED.cover?(major)
      omit("measured against FRR #{MEASURED}, found #{major.inspect}: " \
           're-measure before asserting')
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

  # A bgp4r speaker offering IPv4 unicast and **both** BGP-LS SAFIs,
  # with a bgpd configured for unicast only dialling it. Offering a
  # family the router has no config name for is the only way to put the
  # question to it, since the other direction cannot be configured.
  #
  # Both SAFIs in one session rather than a session each, which is a
  # measurement and not thrift: FRR cannot name AFI 16388, so the two
  # pairs produce the same line and one session reads both.
  def session
    server = TCPServer.new('127.0.0.1', 0)
    n = BGP::Neighbor.new(4, OUR_AS, 180, '0.0.0.1', '127.0.0.2', '127.0.0.1')
    n.add_cap BGP::OPT_PARM::CAP::Mbgp.new(1, 1)
    n.add_cap BGP::OPT_PARM::CAP::Mbgp.new(AFI, SAFI)
    n.add_cap BGP::OPT_PARM::CAP::Mbgp.new(AFI, SAFI_VPN)
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
                   :ipv6 => false)
    @routers << router
    router.up
    assert(wait_for { n.is_established? }, "the session came up\n#{router.log}")
    drops, notes = [], []
    n.on_state_change { |now, was| drops << [was, now] }
    n.add_observer(Catcher.new(notes))
    [n, router, drops, notes]
  end

  # Collects NOTIFICATIONs as [code, subcode], out of to_hash, which is
  # how lab/fault_matrix.rb reads them: Notification keeps @code and
  # @subcode with no readers. A class because Observable wants an object
  # answering update, and the full BGP:: name because a nested class
  # does not see an include in the class around it.
  class Catcher
    def initialize(list) ; @list = list ; end

    def update(message, *_)
      return unless message.is_a?(::BGP::Notification)
      h = message.to_hash
      @list << [h[:code], h[:subcode]]
    end
  end

  def wait_for(timeout = 30)
    deadline = Time.now + timeout
    loop do
      return true if yield
      return false if Time.now > deadline
      sleep 0.2
    end
  end

  # One IPv4 unicast route, carried in an MP_REACH_NLRI rather than in
  # the RFC 4271 section 4.3 fields. That is what makes it a control
  # worth having: it holds the attribute, the next hop and the AS_PATH
  # constant and varies only the SAFI, so a reset below cannot be FRR
  # objecting to MP_REACH or to our encoding of it.
  #
  # The next hop is Frr::NEXT_HOP and not a loopback address, because
  # FRR keeps the session up and silently drops a route whose next hop
  # is 127.0.0.1 where GoBGP accepts it. That is measured in three other
  # tests here and would fail this one as a reset for the wrong reason.
  def announce_control(n)
    n.send_update BGP::Update.new(
      BGP::Path_attribute.new(BGP::Origin.new(0),
                              BGP::As_path.new(OUR_AS),
                              BGP::Mp_reach.new(:safi => 1,
                                                :nexthop => F::NEXT_HOP,
                                                :nlris => [CONTROL])))
  end

  # One BGP-LS route, section 5.2 figure 7: the simplest NLRI in the
  # family, a Node NLRI carrying one Local Node Descriptors TLV with one
  # Autonomous System sub-TLV.
  def announce_link_state(n)
    nlris = [{ :node => { :protocol_id => 2, :identifier => 7,
                          :tlvs => [{ :local_node_descriptors =>
                                      [{ :autonomous_system => OUR_AS }] }] } }]
    n.send_update BGP::Update.new(
      BGP::Path_attribute.new(BGP::Origin.new(0),
                              BGP::As_path.new(OUR_AS),
                              BGP::Mp_reach.new(:safi => SAFI,
                                                :nexthop => F::NEXT_HOP,
                                                :nlris => nlris)))
  end

  # What the peer's multiprotocol capability came to, by FRR's own
  # reckoning, as the Hash its JSON gives: one key per family it both
  # knows and was offered.
  def negotiated(router)
    nb = (router.vty_json('show bgp neighbor 127.0.0.1 json') || {})['127.0.0.1']
    caps = (nb || {})['neighborCapabilities'] || {}
    [caps['multiprotocolExtensions'] || {}, (nb || {})['addressFamilyInfo'] || {}]
  end

  # FRR's grammar has no command for the family, which is the cheapest
  # form of the absence. Unlike gobgpd, which refuses its whole config
  # file and exits, bgpd logs the line it could not parse and comes up
  # without it, so the assertion is on the log and on the daemon being
  # alive afterwards.
  #
  # No peer, so this case costs seconds rather than a session each.
  def test_frr_has_no_grammar_for_the_family
    GUESSES.each do |name|
      router = F.new(:families => [name], :ipv6 => false)
      @routers << router
      router.up
      assert_match(/No such command on config line \d+:\s+address-family #{Regexp.escape(name)}/,
                   router.log,
                   "bgpd to reject `address-family #{name}`")
      assert(router.summary, 'and to come up all the same, without it')
    end
  end

  # The live half: the session comes up with both SAFIs offered, and FRR
  # records nothing for either. **The line it does log is the one thing
  # here that differs from the MCAST-VPN absence**: there the AFI was
  # IPv4 and only the SAFI was unknown, where AFI 16388 is outside FRR's
  # table, so it can name neither half.
  def test_frr_can_name_neither_half_of_the_pair
    _n, router, _drops, _notes = session

    assert_match(%r{MultiProtocol Extensions capability for afi/safi: IPv4/unicast},
                 router.log, 'the family both ends have')
    assert_match(%r{MultiProtocol Extensions capability for afi/safi: bad-value/unknown},
                 router.log,
                 "FRR to have no name for AFI #{AFI}, where for AFI 1 SAFI 5 " \
                 'it names the AFI and not the SAFI')
    assert_equal(2,
                 router.log.scan(%r{afi/safi: bad-value/unknown}).size,
                 'once per SAFI offered, so the two read alike and the ' \
                 'AFI is what it cannot name')

    caps, families = negotiated(router)
    assert_equal(['ipv4Unicast'], caps.keys,
                 'FRR to negotiate neither SAFI, which is why its ' \
                 'capability list has one key and not three')
    assert_equal(['ipv4Unicast'], families.keys,
                 'and to carry no address family for either')
  end

  # What FRR does with a BGP-LS UPDATE on a session that never
  # negotiated the family: it fails the whole UPDATE and drops the
  # session, which is where it parts company with GoBGP.
  #
  # The control route goes first, so a reset here cannot be our having
  # sent something else FRR disliked.
  #
  # **The reset is read from on_state_change and not from session
  # state**, because FRR dials back in within a second or two: a test
  # measuring it with is_established? would report that nothing
  # happened, which is what the first MCAST-VPN measurement did.
  # mcast_vpn_frr_test.rb keeps a case of its own for that lesson; here
  # the come-back is asserted at the end of this one, on the same
  # session.
  def test_a_bgp_ls_update_resets_the_session_with_no_notification
    n, router, drops, notes = session

    announce_control(n)
    assert(wait_for { router.path(CONTROL) },
           "FRR to install #{CONTROL}, so the session is usable and the " \
           "same attribute with SAFI 1 is fine\n#{router.log}")
    assert_equal([], drops, 'and the control route cost no session')

    announce_link_state(n)
    assert(wait_for { drops.any? { |was, _now| was == :Established } },
           "FRR to leave Established, saw #{drops.inspect}\n#{router.log}")

    assert_equal([], notes,
                 'with no NOTIFICATION, where RFC 4271 section 6 wants one ' \
                 'before a close')
    assert_match(/Attribute MP_REACH_NLRI, parse error/, router.log,
                 'FRR to call it a parse error on the attribute')
    assert_match(/BGP UPDATE receipt failed for peer/, router.log,
                 'and to fail the whole UPDATE over it')
    assert_match(/BGP_Stop \(Established->Clearing\)/, router.log,
                 'which is what takes the session down')

    assert(wait_for { n.is_established? },
           "and to come back, saw #{drops.inspect}\n#{router.log}")
    assert(drops.any? { |_was, now| now == :Established },
           "so the session really was rebuilt, in #{drops.inspect}")
  end

end
