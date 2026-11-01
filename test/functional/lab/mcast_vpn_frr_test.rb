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

# The twin of mcast_vpn_gobgp_test.rb: FRR 8.4.4 has no MCAST-VPN
# family, SAFI 5, and this asserts the absence rather than leaving it
# written down. No Docker and no zebra. `docs/mcast-vpn.md` section 9
# has the measurements, and that file's header has why an absence is
# worth a test here at all.
#
# **The two routers answer differently, and that is the finding.** GoBGP
# discards the MCAST-VPN UPDATE and keeps the session. FRR calls it
# `Attribute MP_REACH_NLRI, parse error`, fails the whole UPDATE, and
# **tears the session down with no NOTIFICATION**, then reconnects. So
# this is not a second router agreeing; it is a second router
# disagreeing about what to do with a family it does not have, and
# neither behaviour is bgp4r's to copy.
#
# RFC 4271 section 6 wants a NOTIFICATION before a close, and FRR's path
# here sends none. Recorded and not filed, per the standing decision
# that the job here is bgp4r catching up.
#
# **is_established? cannot see that reset**, which is the trap this file
# was written through: FRR comes back within a second or two, so a read
# a few seconds after the send finds a session established and says
# nothing happened. The first measurement taken for this family said
# exactly that and was wrong. Every case below watches
# on_state_change instead, which is what phase 2 of the RIB work put on
# Neighbor for.
class McastVpnFrrTest < Test::Unit::TestCase

  OUR_AS = 65001
  THEIR_AS = 65002
  F = LabHelper::Frr

  # RFC 6514 section 4 gives "an Address Family Identifier (AFI) of 1 or
  # 2 and a Subsequent AFI (SAFI) of MCAST-VPN" and leaves the number to
  # IANA, whose registry says 5.
  AFI = 1
  SAFI = 5

  # Names a reader might reach for in FRR's `address-family` command.
  # Its grammar offers `ipv4 [<unicast|multicast|vpn|labeled-unicast|
  # flowspec>]`, the ipv6 twin and `l2vpn evpn`, so none of these is a
  # command: `ipv4 multicast` is SAFI 2 and `ipv4 vpn` is SAFI 128.
  GUESSES = ['ipv4 mcast-vpn', 'ipv4 mvpn', 'ipv4 multicast-vpn'].freeze

  # A prefix in a family FRR does carry, sent the same way the
  # MCAST-VPN route is, so the reset case can prove the session was
  # usable at the moment it sent the MCAST-VPN one and that nothing but
  # the SAFI differed. That discipline is fault_matrix_scenario.rb's
  # test_the_rib_answer_was_usable, and it is what keeps a reset being
  # reported for the right reason.
  CONTROL = '198.51.100.0/24'.freeze

  # The major version these expectations were measured against. Every
  # case here asserts FRR's own wording somewhere, so the gate is on the
  # whole file, which is the shape evpn_frr_test.rb and
  # flow_spec_frr_test.rb use.
  #
  # **So a later FRR omits this file rather than failing it**, and that
  # is worth knowing before trusting the plan's "if a router grows the
  # family, this says to come back". What makes it say so is
  # `mcast_vpn_doc_test.rb`, which holds this constant against the
  # version in `docs/mcast-vpn.md` section 9: bumping one without the
  # other fails the unit suite, so the table cannot keep claiming a
  # measurement nothing ran.
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

  # A bgp4r speaker offering AFI 1 SAFI 1 and AFI 1 SAFI 5, with a bgpd
  # configured for unicast only dialling it. Offering a family the
  # router has no config name for is the only way to put the question to
  # it.
  def session
    server = TCPServer.new('127.0.0.1', 0)
    n = BGP::Neighbor.new(4, OUR_AS, 180, '0.0.0.1', '127.0.0.2', '127.0.0.1')
    n.add_cap BGP::OPT_PARM::CAP::Mbgp.new(AFI, 1)
    n.add_cap BGP::OPT_PARM::CAP::Mbgp.new(AFI, SAFI)
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
  # the RFC 4271 section 4.3 fields. That is deliberate and is what
  # makes it a control worth having: it holds the attribute, the next
  # hop and the AS_PATH constant and varies only the SAFI, so a reset
  # below cannot be FRR objecting to MP_REACH, to our encoding of it, or
  # to anything else we send. Measured: FRR installs this and stays up.
  #
  # The next hop is Frr::NEXT_HOP and not a loopback address, because
  # FRR keeps the session up and silently drops a route whose next hop
  # is 127.0.0.1 where GoBGP accepts it. That is measured in two other
  # tests here and would fail this one as a reset for the wrong reason.
  def announce_control(n)
    n.send_update BGP::Update.new(
      BGP::Path_attribute.new(BGP::Origin.new(0),
                              BGP::As_path.new(OUR_AS),
                              BGP::Mp_reach.new(:safi => 1,
                                                :nexthop => F::NEXT_HOP,
                                                :nlris => [CONTROL])))
  end

  # One MCAST-VPN route, RFC 6514 section 4.1, in an MP_REACH_NLRI: the
  # simplest layout in the family, a Route Distinguisher and the
  # Originating Router's IP Address.
  def announce_mcast_vpn(n)
    nlri = BGP::Mcast_vpn.new(
      BGP::Mcast_vpn::Intra_as_i_pmsi.new([100, 200], F::NEXT_HOP))
    n.send_update BGP::Update.new(
      BGP::Path_attribute.new(BGP::Origin.new(0),
                              BGP::As_path.new(OUR_AS),
                              BGP::Mp_reach.new(:safi => SAFI,
                                                :nexthop => F::NEXT_HOP,
                                                :nlris => [nlri])))
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

  # The live half: the session comes up with the capability offered, and
  # FRR records nothing for it. Three readings, because its silence
  # shows in three places and in one of them it is not silent at all:
  # the log names the AFI and cannot name the SAFI.
  def test_frr_receives_the_capability_and_negotiates_nothing_for_it
    _n, router, _drops, _notes = session

    assert_match(%r{MultiProtocol Extensions capability for afi/safi: IPv4/unicast},
                 router.log, 'the family both ends have')
    assert_match(%r{MultiProtocol Extensions capability for afi/safi: IPv4/unknown},
                 router.log,
                 "FRR to read AFI #{AFI} SAFI #{SAFI} and have no name for the SAFI")

    caps, families = negotiated(router)
    assert_equal(['ipv4Unicast'], caps.keys,
                 "FRR to negotiate nothing for SAFI #{SAFI}, which is why its " \
                 'capability list has one key and not two')
    assert_equal(['ipv4Unicast'], families.keys,
                 'and to carry no address family for it either')
  end

  # What FRR does with an MCAST-VPN UPDATE on a session that never
  # negotiated the family: it fails the UPDATE and drops the session,
  # which is the one place the two routers part company.
  #
  # The control route goes first, so a reset here cannot be our having
  # sent something else FRR disliked, and `drops` is cleared after it
  # for the same reason.
  def test_an_mcast_vpn_update_resets_the_session_with_no_notification
    n, router, drops, notes = session

    announce_control(n)
    assert(wait_for { router.path(CONTROL) },
           "FRR to install #{CONTROL}, so the session is usable and the " \
           "same attribute with SAFI 1 is fine\n#{router.log}")
    assert_equal([], drops, 'and the control route cost no session')

    announce_mcast_vpn(n)
    assert(wait_for { drops.any? { |was, now| was == :Established } },
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
  end

  # And the reason the case above does not read the session state
  # directly: FRR dials back in at once, so by the time anything is
  # asserted there is a session established again. A test that measured
  # the reset with is_established? would report that nothing happened,
  # which is what the first measurement of this family did.
  def test_frr_comes_back_so_the_session_state_cannot_show_the_reset
    n, router, drops, _notes = session

    announce_mcast_vpn(n)
    assert(wait_for { drops.any? { |was, now| was == :Established } },
           "FRR to leave Established, saw #{drops.inspect}\n#{router.log}")
    assert(wait_for { n.is_established? },
           "and to come back, saw #{drops.inspect}\n#{router.log}")
    assert(drops.any? { |was, now| now == :Established },
           "so the session really was rebuilt, in #{drops.inspect}")
  end

end
