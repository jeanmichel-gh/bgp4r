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

# A flow spec rule from bgp4r, read back by FRR's bgpd. The twin of
# flow_spec_gobgp_test.rb, standalone on loopback, no Docker and no zebra.
#
# **Two routers is the point, because these two disagree on everything
# section 4.2 asks for.** Measured on 2026-10-30, FRR 8.4.4 against GoBGP
# 3.23.0:
#
#   case (RFC 8955 section 4.2)   GoBGP 3.23.0          FRR 8.4.4
#   components out of order       accepts, normalises   accepts, keeps our order
#   a component type twice        resets the session    accepts, keeps both
#   an unknown component type     accepts and installs  resets the session, 3/9
#
# The RFC asks for strict increasing order, each type at most once, and an
# unknown type to make the NLRI malformed. So each router enforces exactly
# one of the two enforceable rules, and a different one. That is worth
# having asserted before part 4 adds the checks to validation.rb, because
# it says bgp4r has to follow the RFC rather than either router, and
# Conventions already says bgp4r must still be able to send all three.
#
# **Each case gets its own session and its own daemon**, as the fault
# matrix does: one of these takes the session down and a reset must not
# void the next case.
#
# BGP:: names are written out in full, see Conventions in CLAUDE.md.
class FlowSpecFrrTest < Test::Unit::TestCase
  OUR_AS = 65001
  THEIR_AS = 65002

  FS = BGP::Flow_spec
  F = LabHelper::Frr

  # The major versions these expectations were measured against, the same
  # shape and the same reason as fault_matrix_frr_test.rb's MEASURED.
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

  # A bgp4r speaker listening on its own port, advertising the RFC 4760
  # capability for each pair given, with a bgpd configured for the
  # matching families dialling it.
  #
  # established: false where the point of the case is that the session
  # does not come up, so the caller asserts that itself.
  def session(caps, families, established: true)
    server = TCPServer.new('127.0.0.1', 0)
    n = BGP::Neighbor.new(4, OUR_AS, 180, '0.0.0.1', '127.0.0.2', '127.0.0.1')
    caps.each { |afi, safi| n.add_cap BGP::OPT_PARM::CAP::Mbgp.new(afi, safi) }
    notes = NotificationCatcher.new
    n.add_observer notes
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
                   :families => families)
    router.up
    @routers << router
    came_up = wait_for { n.is_established? }
    assert(came_up, 'the session came up') if established
    [n, router, notes]
  end

  def wait_for(timeout = 30)
    deadline = Time.now + timeout
    loop do
      return true if yield
      return false if Time.now > deadline
      sleep 0.2
    end
  end

  def announce(n, safi, rule, *extra)
    n.send_update BGP::Update.new(BGP::Path_attribute.new(
      BGP::Origin.new(0), BGP::As_path.new(OUR_AS), *extra,
      BGP::Mp_reach.new(:safi => safi, :nlris => [rule])))
  end

  # Waits for the router to hold a rule in that family. **The waiting is
  # the assertion**: a rule FRR dropped never reaches its RIB, so there
  # is nothing to compare and this is what catches it.
  def installed(router, family)
    found = nil
    assert(wait_for { found = router.only_rule(family) },
           "FRR to hold a #{family} rule (waited 30s)\n#{router.log}")
    found
  end

  # The rule of RFC 8955 section 4.3.1.
  #
  # **FRR's key carries the section 4.1 length**, the trailing /11 for
  # 0x0b, so this assertion checks our framing arithmetic through a
  # second implementation and not only our components. The spacing is
  # FRR's own, doubled where a value ends, so the string is its text and
  # a reworded release is a test to update.
  def test_frr_reads_an_ipv4_rule_back
    n, router = session([[1, 133]], [F::FS_IPV4])
    announce(n, 133,
             { :destination_prefix => '192.0.2.0/24',
               :ip_protocol => [[:eq, 6]], :port => [[:eq, 25]] })
    key, path = installed(router, F::FS_IPV4)

    assert_equal('to 192.0.2.0/24 proto = 6  port = 25 /11', key,
                 'the trailing 11 is the RFC 8955 section 4.1 length')
    assert_equal('192.0.2.0/24', path['to'])
    assert_equal('= 6 ', path['proto'], "FRR's rendering of our operator")
    assert_equal('= 25 ', path['port'])
    assert_equal('65001', path['path'], 'our AS_PATH')
    assert_equal('IGP', path['origin'])
    assert_equal(true, path['valid'])
  end

  # RFC 8956. The offset of section 3.1 is in the key too, as "off 0",
  # which is the field RFC 8955 has no equivalent for.
  def test_frr_reads_an_ipv6_rule_back
    n, router = session([[2, 133]], [F::FS_IPV6])
    announce(n, 133,
             { :destination_ipv6_prefix => { :prefix => '2001:db8::/32' },
               :upper_layer_protocol => [[:eq, 6]] })
    key, _path = installed(router, F::FS_IPV6)

    assert_equal('to 2001:db8::/32/off 0 proto = 6 /10', key,
                 'the offset and then the section 4.1 length')
  end

  # A traffic filtering action riding with the rule, RFC 8955 section 7.1.
  # The table form does not print it, so this reads the detail form, the
  # way rib_router_frr_test.rb has to for the RFC 4456 section 8
  # attributes: a value the table form omits answers nil there however
  # correct the UPDATE was, which is a wrong answer and not a missing one.
  def test_frr_reads_a_traffic_rate_action_back
    n, router = session([[1, 133]], [F::FS_IPV4])
    announce(n, 133, { :destination_prefix => '192.0.2.0/24' },
             BGP::Extended_communities.new(
               BGP::Traffic_rate_bytes.new(0, 1_000_000.0)))
    installed(router, F::FS_IPV4)

    detail = router.vty('show bgp ipv4 flowspec detail')
    assert_not_nil(detail, 'the detail command answered')
    assert_match(/Destination Address 192\.0\.2\.0\/24/, detail)
    assert_match(/FS:rate 1000000\.000000/, detail,
                 'the section 7.1 rate, in bytes per second')
  end

  def test_frr_drops_a_rule_we_withdraw
    n, router = session([[1, 133]], [F::FS_IPV4])
    rule = { :destination_prefix => '192.0.2.0/24', :port => [[:eq, 25]] }
    announce(n, 133, rule)
    installed(router, F::FS_IPV4)

    n.send_update BGP::Update.new(BGP::Path_attribute.new(
      BGP::Mp_unreach.new(:safi => 133, :nlris => [rule])))
    assert(wait_for { router.rib(F::FS_IPV4) == {} },
           "FRR to drop the rule (waited 30s)\n#{router.log}")
  end

  # Section 4.2's ordering MUST, which FRR does not enforce either.
  #
  # **Where GoBGP normalises, FRR keeps the order we sent**, so its key
  # shows port before the destination. Both accept the rule, and the two
  # renderings are the clearest demonstration that a router's view of a
  # rule is its own and not the wire's.
  def test_frr_accepts_an_out_of_order_rule_and_keeps_our_order
    n, router = session([[1, 133]], [F::FS_IPV4])
    rule = FS.new(FS::Port.new([:eq, 25]),
                  FS::Destination_prefix.new('198.51.100.0/24'))
    assert_equal('080481190118c63364', rule.to_shex,
                 'port first on the wire, which section 4.2 forbids')
    announce(n, 133, rule)
    key, _path = installed(router, F::FS_IPV4)

    assert_equal('port = 25  to 198.51.100.0/24/8', key,
                 'our order, where GoBGP prints the canonical one')
    assert(n.is_established?, 'and the session stayed up')
  end

  # Section 4.2's once-only rule, which **FRR does not enforce and GoBGP
  # resets on**. Both ports come back in the key, so FRR keeps a rule
  # that matches port 25 and port 80 at once.
  def test_frr_accepts_a_repeated_component_type
    n, router = session([[1, 133]], [F::FS_IPV4])
    rule = FS.new(FS::Destination_prefix.new('203.0.113.0/24'),
                  FS::Port.new([:eq, 25]), FS::Port.new([:eq, 80]))
    assert_equal('0b0118cb0071048119048150', rule.to_shex, 'port twice')
    announce(n, 133, rule)
    key, _path = installed(router, F::FS_IPV4)

    assert_equal('to 203.0.113.0/24 port = 25  port = 80 /11', key,
                 'both occurrences kept')
    assert(n.is_established?, 'and the session stayed up')
  end

  # Section 4.2 makes an unknown component type malformed, and **FRR is
  # the one that does that**, with NOTIFICATION 3/9, UPDATE Message Error
  # / Optional Attribute Error (RFC 4271 section 4.5). GoBGP installs the
  # same rule.
  #
  # So this is the case that justifies bgp4r putting an unknown type in
  # Path_attribute#errors rather than #undecoded when part 4 lands: the
  # RFC says malformed and one of the two routers agrees.
  def test_frr_resets_the_session_on_an_unknown_component_type
    n, router, notes = session([[1, 133]], [F::FS_IPV4])
    rule = FS.new(FS::Destination_prefix.new('192.0.2.128/25'),
                  FS::Unknown.new(99, [0x81, 0x05].pack('C*')))
    assert_equal('090119c0000280638105', rule.to_shex,
                 'type 99, which RFC 8956 section 8.1.2 leaves unassigned')
    announce(n, 133, rule)

    assert(wait_for { !n.is_established? },
           "FRR to reset the session (waited 30s)\n#{router.log}")
    note = notes.last
    assert_not_nil(note, 'it sent a NOTIFICATION rather than just closing')
    assert_equal(3, note.to_hash[:code], 'UPDATE Message Error')
    assert_equal(9, note.to_hash[:subcode], 'Optional Attribute Error')
    assert_equal({}, router.rib(F::FS_IPV4), 'and it holds no rule')
  end

  # **FRR 8.4.4 has no VPN flow spec family**, SAFI 134 of RFC 8955
  # section 8, which is why the VPN case lives in the GoBGP test alone.
  #
  # Measured rather than inferred from the absence of an address-family
  # command, and it fails two different ways depending on what else the
  # session carries. With SAFI 134 as the only family we advertise, FRR
  # refuses the session with NOTIFICATION 2/7, Unsupported Capability,
  # which is RFC 5492 section 5 and the subcode name #117 corrected.
  def test_frr_refuses_a_session_offering_vpn_flow_spec_alone
    n, _router, notes = session([[1, 134]], [F::FS_IPV4], :established => false)
    assert(wait_for(20) { notes.last }, 'FRR answered the OPEN')
    note = notes.last
    assert_equal(2, note.to_hash[:code], 'OPEN Message Error')
    assert_equal(7, note.to_hash[:subcode], 'Unsupported Capability')
    assert(!n.is_established?, 'and the session never came up')
  end

  # The other way it fails: with SAFI 133 alongside, the session comes up
  # and a SAFI 134 rule is discarded **in silence**, leaving nothing in
  # any RIB and sending no notification. That is the worse of the two for
  # anyone testing a router with bgp4r, so it is worth an assertion of
  # its own rather than a note.
  def test_frr_discards_a_vpn_flow_spec_rule_in_silence
    n, router, notes = session([[1, 133], [1, 134]], [F::FS_IPV4])
    announce(n, 134,
             { :rd => [100, 200], :destination_prefix => '198.51.100.0/24' })
    sleep 4

    assert(n.is_established?, 'the session stayed up')
    assert_nil(notes.last, 'and nothing was reported')
    assert_equal({}, router.rib(F::FS_IPV4), 'the rule is simply gone')
  end

  private

  # A full BGP:: name in a nested class, which does not see an include in
  # the class around it, and which matters doubly in an observer:
  # Neighbor logs an exception from one rather than raising it, so a
  # wrong constant here would read as "nothing arrived".
  class NotificationCatcher
    def initialize ; @notes = [] ; end
    def update(msg) ; @notes << msg if msg.is_a?(BGP::Notification) ; end
    def last ; @notes.last ; end
  end
end
