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

# **This file measures an absence, and that is the whole of it.** Every
# other lab test here asks a router what it made of something bgp4r
# sent. GoBGP 3.23.0 has no MCAST-VPN family, SAFI 5, so there is
# nothing to ask: what this asserts is that the family is absent, how
# GoBGP says so, and what it does with an MCAST-VPN UPDATE sent anyway.
#
# **It exists because that absence is load bearing elsewhere.** The
# scope of the MCAST-VPN validation work and the weakness of
# `test/functional/mcast_vpn_test.rb` both rest on it: with no router
# carrying the family, bgp4r's wire format for it is checked only
# against the field widths RFC 6514 and RFC 6515 state, and the loopback
# functional test proves the wiring sites agree with each other and
# nothing more. A fact nothing checks reads as verified, which is the
# lesson the hand-measured conformance table taught, so the absence is
# asserted rather than written down. If a later GoBGP grows the family,
# these cases fail and say to come back.
#
# `docs/mcast-vpn.md` section 9 has the measurements. FRR 8.4.4 has no
# such family either and answers differently, which is in
# `mcast_vpn_frr_test.rb`: GoBGP keeps the session and FRR tears it
# down.
#
# Every case gets a session of its own, which is the fault matrix's
# shape. It is not tidiness here either: one case below leaves GoBGP
# having dropped the family from its own neighbor output, so nothing
# after it on a shared session would read the same.
class McastVpnGobgpTest < Test::Unit::TestCase

  OUR_AS = 65001
  THEIR_AS = 65002
  G = LabHelper::Gobgpd

  # RFC 6514 section 4 gives "an Address Family Identifier (AFI) of 1 or
  # 2 and a Subsequent AFI (SAFI) of MCAST-VPN" and leaves the number to
  # IANA, whose registry says 5. bgp4r has it as IANA::SAFI::MCAST_VPN.
  AFI = 1
  SAFI = 5

  # What GoBGP calls the pair it does not know, in its own packing: it
  # prints `UnknownFamily(65541)`, which is afi << 16 | safi. Derived
  # rather than written as 65541 so the test says where the number comes
  # from, and asserted below against the text GoBGP really prints.
  UNKNOWN_FAMILY = (AFI << 16) | SAFI

  # Names a reader might reach for. None is a family name GoBGP knows,
  # and the first case asserts that its config parser refuses each one.
  # They are guesses rather than anything a document gives: GoBGP's own
  # vocabulary has `l3vpn-ipv4-multicast` for SAFI 129 and
  # `ipv4-multicast` for SAFI 2, and neither is this family.
  GUESSES = %w[mcast-vpn ipv4-mcast-vpn l3vpn-ipv4-mcast-vpn mvpn].freeze

  # A prefix in a family GoBGP does carry, sent the same way the
  # MCAST-VPN route is, so a case can prove the session and our encoder
  # are good before scoring a verdict about SAFI 5. That discipline is
  # fault_matrix_scenario.rb's test_the_rib_answer_was_usable, and the
  # first measurement written for this file needed it: see the note on
  # is_established? below.
  CONTROL = '198.51.100.0/24'.freeze

  # The version these expectations were measured against. The text GoBGP
  # prints is its own and a release may reword it, so a case that turns
  # on the wording omits itself elsewhere rather than failing.
  MEASURED_MAJOR = 3

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

  # A bgp4r speaker offering AFI 1 SAFI 1 and AFI 1 SAFI 5, with a
  # gobgpd configured for unicast only dialling it. Offering a family
  # the router has no config name for is the only way to put the
  # question to it, since the other direction cannot be configured.
  #
  # The state changes and the NOTIFICATIONs are collected from the
  # moment the session comes up, because **is_established? cannot answer
  # whether a router reset us**: it reconnects, and a read a few seconds
  # later sees the new session and says true. The first reading taken
  # for this file was wrong that way, and for FRR it was wrong in the
  # verdict too. Phase 2 of the RIB work put on_state_change on Neighbor
  # for exactly this, since a message observer cannot see a drop.
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
    router = G.new(:local => '127.0.0.2', :as => THEIR_AS,
                   :router_id => '10.0.0.2', :peer => '127.0.0.1',
                   :peer_as => OUR_AS, :port => server.addr[1])
    @routers << router
    router.up
    assert(wait_for { n.is_established? }, "the session came up\n#{router.log}")
    drops, notes = [], []
    n.on_state_change { |now, was| drops << [was, now] }
    n.add_observer(Catcher.new(notes))
    [n, router, drops, notes]
  end

  # Collects NOTIFICATIONs as [code, subcode]. A class rather than a
  # block because Observable wants an object answering update, and the
  # full BGP:: name because a nested class does not see an include in
  # the class around it.
  #
  # The pair comes out of to_hash, which is how lab/fault_matrix.rb
  # reads it: Notification keeps @code and @subcode with no readers.
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
  # hop and the AS_PATH constant and varies only the SAFI, so a discard
  # below cannot be GoBGP objecting to MP_REACH or to our encoding of
  # it.
  def announce_control(n)
    n.send_update BGP::Update.new(
      BGP::Path_attribute.new(BGP::Origin.new(0),
                              BGP::As_path.new(OUR_AS),
                              BGP::Mp_reach.new(:safi => 1,
                                                :nexthop => '10.0.0.1',
                                                :nlris => [CONTROL])))
  end

  # One MCAST-VPN route, RFC 6514 section 4.1, in an MP_REACH_NLRI. The
  # simplest layout in the family: a Route Distinguisher and the
  # Originating Router's IP Address.
  def announce_mcast_vpn(n)
    nlri = BGP::Mcast_vpn.new(
      BGP::Mcast_vpn::Intra_as_i_pmsi.new([100, 200], '10.0.0.1'))
    n.send_update BGP::Update.new(
      BGP::Path_attribute.new(BGP::Origin.new(0),
                              BGP::As_path.new(OUR_AS),
                              BGP::Mp_reach.new(:safi => SAFI,
                                                :nexthop => '10.0.0.1',
                                                :nlris => [nlri])))
  end

  # The `multiprotocol:` block of `gobgp neighbor <addr>`, as a Hash of
  # the family GoBGP names to what it says about it. Parsed out of the
  # human readable form rather than the JSON one, because the JSON
  # carries `remote_cap` as base64 protobuf and so repeats the octets we
  # sent, where this text is GoBGP's own verdict on them. Treat the
  # exact words as GoBGP's and not contractual, the way the flow spec
  # keys are treated.
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

  # GoBGP's config parser has no name for the family, which is the
  # cheapest and strongest form of the absence: the daemon will not
  # start. Gobgpd#up raises with the log, which names the key it
  # rejected, and only a port conflict is retried, so a raise here is
  # the config and not the harness.
  #
  # No session and no peer, so this is the one case that costs a second
  # rather than ten.
  def test_gobgp_has_no_config_name_for_the_family
    GUESSES.each do |name|
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

  # The live half: a session comes up with the capability offered, and
  # GoBGP records the pair as received and as a family it cannot name.
  # So the absence is the router's own statement and not an inference
  # from its config vocabulary.
  #
  # **Read before any MCAST-VPN UPDATE**, which is a measurement and not
  # an ordering preference: the next case shows the line going away. The
  # second read here, after a wait, is the control that says the line
  # persists on its own.
  def test_gobgp_receives_the_capability_and_cannot_name_the_family
    omit("the wording is GoBGP #{MEASURED_MAJOR}'s") unless G.major == MEASURED_MAJOR
    _n, router, _drops, _notes = session

    families = multiprotocol(router)
    assert_equal('advertised and received', families['ipv4-unicast'],
                 'the family both ends have is negotiated')
    assert_equal('received', families["UnknownFamily(#{UNKNOWN_FAMILY})"],
                 "GoBGP to call AFI #{AFI} SAFI #{SAFI} an unknown family, " \
                 "received and not negotiated, in #{families.inspect}")
    assert_nil(families.keys.find { |k| k =~ /mcast|mvpn/i },
               "GoBGP to have no name for it at all, in #{families.keys.inspect}")

    sleep 3
    assert_equal('received', multiprotocol(router)["UnknownFamily(#{UNKNOWN_FAMILY})"],
                 'the line stays while no UPDATE in that family arrives, ' \
                 'which is the control for the next case')
  end

  # What GoBGP does with an MCAST-VPN UPDATE on a session that never
  # negotiated the family: it discards the message and keeps the
  # session. Four readings, because no one of them says it alone.
  #
  # The control route goes first and is asserted twice, before and
  # after, so the case cannot pass by our having sent nothing usable and
  # cannot report a discard that was really a reset.
  def test_an_mcast_vpn_update_is_discarded_and_the_session_survives
    omit("the wording is GoBGP #{MEASURED_MAJOR}'s") unless G.major == MEASURED_MAJOR
    n, router, drops, notes = session

    announce_control(n)
    assert(wait_for { router.path(CONTROL) },
           "GoBGP to install #{CONTROL}, so the session is usable\n#{router.log}")
    # The control is itself an UPDATE, so the Updates count is already 1
    # here. Read it rather than expecting a number, so what the
    # assertion below says is that the MCAST-VPN one did not raise it.
    updates = messages(router, 'Updates')[1]

    announce_mcast_vpn(n)
    assert(wait_for { messages(router, 'Discarded')[1] == 1 },
           "GoBGP to count the MCAST-VPN UPDATE as discarded, counted " \
           "#{messages(router, 'Discarded').inspect}\n#{router.log}")

    assert_equal([], drops,
                 'GoBGP not to reset the session over it')
    assert_equal([], notes, 'nor to send a NOTIFICATION')
    assert_equal(updates, messages(router, 'Updates')[1],
                 'the UPDATE reaches no family, so it is counted as a ' \
                 'discard and not as an UPDATE')
    assert(router.path(CONTROL),
           "#{CONTROL} is still there, so the discard took the message and " \
           'not the session')
    assert_match(/unknown route family. AFI: #{AFI}, SAFI: #{SAFI}/,
                 router.log,
                 'GoBGP to name the family it discarded it for')
  end

  # And the measurement that makes the reading order above matter:
  # GoBGP stops listing the family once an UPDATE in it arrives, logging
  # "Capability was disabled". So a test reading the capability after
  # sending would find nothing and could conclude it was never received.
  #
  # Worth being exact about that log line, because EVPN part 10 recorded
  # it overstating what GoBGP did: there an unknown EVPN route type
  # disabled the capability by that message and a route type 3 still
  # installed on the same session afterwards. Here the family really is
  # dropped from the neighbor output, and the session still survives, so
  # what the line never means either way is that the session is over.
  def test_an_update_in_the_family_makes_gobgp_drop_it_from_the_neighbor
    omit("the wording is GoBGP #{MEASURED_MAJOR}'s") unless G.major == MEASURED_MAJOR
    n, router, drops, _notes = session

    key = "UnknownFamily(#{UNKNOWN_FAMILY})"
    assert_equal('received', multiprotocol(router)[key], 'listed to begin with')

    announce_mcast_vpn(n)
    assert(wait_for { multiprotocol(router)[key].nil? },
           "GoBGP to stop listing #{key}, still at " \
           "#{multiprotocol(router)[key].inspect}\n#{router.log}")
    assert_match(/Capability was disabled/, router.log,
                 'which is the message GoBGP logs for it')
    assert_equal([], drops, 'and the session is still the same one')
  end

end
