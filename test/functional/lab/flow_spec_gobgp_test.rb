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

# A flow spec rule from bgp4r, read back by GoBGP. RFC 8955 and RFC 8956,
# no Docker.
#
# **What this asserts that `test/functional/flow_spec_test.rb` cannot.**
# That one proves bgp4r's two sides agree with each other over a socket.
# Two bgp4r speakers agreeing proves only that they agree, which is how
# the inverted ADD-PATH Send/Receive field survived for years, so this is
# the part a second implementation has to say: that a real router reads
# our components, our operator octets, our section 4.1 length, our
# RFC 8956 offset and our section 8 Route Distinguisher back as we meant
# them, and that it understands a withdrawal that names one.
#
# **Each case gets its own session and its own daemon**, as the fault
# matrix does, because three of these rules take the session down on one
# router or the other and a reset in one case must not void the next.
#
# **Every expectation here is per version.** They were measured against
# GoBGP 3.23.0 on 2026-10-30. GoBGP 4 fixed one RFC 7606 case the fault
# matrix measures, so a major this file has not been run against is not
# assumed to answer alike: the cases that turn on it omit themselves and
# say so, rather than guess.
#
# BGP:: names are written out in full, see Conventions in CLAUDE.md.
class FlowSpecGobgpTest < Test::Unit::TestCase
  OUR_AS = 65001
  THEIR_AS = 65002

  FS = BGP::Flow_spec
  G = LabHelper::Gobgpd

  # The version these expectations were measured against.
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

  # A bgp4r speaker listening on its own port, advertising the
  # multiprotocol capability of RFC 4760 for one pair, with a gobgpd
  # configured for the matching family dialling it. Returns both once the
  # session is up.
  def session(afi, safi, family)
    server = TCPServer.new('127.0.0.1', 0)
    n = BGP::Neighbor.new(4, OUR_AS, 180, '0.0.0.1', '127.0.0.2', '127.0.0.1')
    n.add_cap BGP::OPT_PARM::CAP::Mbgp.new(afi, safi)
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
                   :families => [family])
    @routers << router
    router.up
    assert(wait_for { n.is_established? }, 'the session came up')
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

  # Sends one rule with an ORIGIN and an AS_PATH in front of it, which is
  # the least a router will accept.
  def announce(n, safi, rule, *extra)
    n.send_update BGP::Update.new(BGP::Path_attribute.new(
      BGP::Origin.new(0), BGP::As_path.new(OUR_AS), *extra,
      BGP::Mp_reach.new(:safi => safi, :nlris => [rule])))
  end

  # Waits for the router to hold a rule in that family and answers it as
  # [key, path], or fails. **The waiting is the assertion**, as it is in
  # rib_router_gobgp_test.rb: a rule the router rejected never reaches
  # its RIB, so there is nothing to compare and this is what catches it.
  def installed(router, family)
    found = nil
    assert(wait_for { found = router.only_rule(family) },
           "GoBGP to hold a #{family} rule (waited 30s)\n#{router.log}")
    found
  end

  # The rule of RFC 8955 section 4.3.1: destination 192.0.2.0/24, with
  # protocol 6 and port 25. The document's own worked example, and the
  # one whose octets the unit tests take from the RFC.
  def test_gobgp_reads_an_ipv4_rule_back
    n, router = session(1, 133, G::FS_IPV4)
    announce(n, 133,
             { :destination_prefix => '192.0.2.0/24',
               :ip_protocol => [[:eq, 6]], :port => [[:eq, 25]] })
    key, path = installed(router, G::FS_IPV4)

    # GoBGP's own rendering of our components, protocol 6 spelled tcp.
    # Its text, so this is the one brittle assertion here; a reworded
    # release is a test to update and not a bgp4r bug.
    assert_equal('[destination: 192.0.2.0/24][protocol: ==tcp][port: ==25]', key)

    # The components by their RFC 8955 section 4.2 type numbers.
    comps = G.components(path)
    assert_equal([1, 3, 4], comps.collect { |c| c['type'] })
    assert_equal('192.0.2.0/24', comps[0]['value']['prefix'])

    # **The operator octet comes back whole**, which is the assertion
    # worth having: 129 is 0x81, the end-of-list bit of section 4.2.1
    # plus eq. Nothing else here checks a second implementation's
    # reading of that octet.
    assert_equal([{ 'op' => 129, 'value' => 6 }], comps[1]['value'])
    assert_equal([{ 'op' => 129, 'value' => 25 }], comps[2]['value'])

    # Section 4: the Length of the Next-Hop Network Address MUST be 0,
    # and GoBGP takes that without complaint rather than rejecting the
    # attribute for having no next hop.
    assert_equal('0.0.0.0', G.attrs(path)[14]['nexthop'])
    assert_equal(133, G.attrs(path)[14]['safi'])
  end

  # RFC 8956 section 3.8.1's flow, cut to what matters here. The offset
  # of section 3.1 is the field RFC 8955 has no equivalent for, so a
  # router reading it back is what says our IPv6 encoding is right and
  # not merely self consistent.
  def test_gobgp_reads_an_ipv6_rule_back
    n, router = session(2, 133, G::FS_IPV6)
    announce(n, 133,
             { :destination_ipv6_prefix => { :prefix => '2001:db8::/32' },
               :upper_layer_protocol => [[:eq, 6]] })
    key, path = installed(router, G::FS_IPV6)

    assert_equal('[destination: 2001:db8::/32/0][protocol: ==tcp]', key,
                 'the trailing 0 is the offset')
    comps = G.components(path)
    assert_equal([1, 3], comps.collect { |c| c['type'] })
    assert_equal('2001:db8::/32', comps[0]['value']['prefix'])
    assert_equal(0, comps[0]['offset'], 'RFC 8956 section 3.1')
    assert_equal([{ 'op' => 129, 'value' => 6 }], comps[1]['value'])
    assert_equal(2, G.attrs(path)[14]['afi'])
  end

  # RFC 8955 section 8: SAFI 134 prepends an 8 octet Route Distinguisher,
  # and "The NLRI length field shall include both the 8 octets of the
  # Route Distinguisher as well as the subsequent Flow Specification NLRI
  # value." A router that reads the RD back has agreed with both halves,
  # since a length one octet out would have left it reading the RD as a
  # component.
  def test_gobgp_reads_a_vpn_rule_and_its_route_distinguisher_back
    n, router = session(1, 134, G::FS_VPN)
    announce(n, 134,
             { :rd => [100, 200], :destination_prefix => '192.0.2.0/24',
               :ip_protocol => [[:eq, 6]] })
    key, path = installed(router, G::FS_VPN)

    assert_equal('[rd: 100:200][destination: 192.0.2.0/24][protocol: ==tcp]', key)
    rd = (path['nlri'] || {})['rd']
    assert_equal({ 'type' => 0, 'admin' => 100, 'assigned' => 200 }, rd)
    assert_equal([1, 3], G.components(path).collect { |c| c['type'] })
    assert_equal(134, G.attrs(path)[14]['safi'])
  end

  # A traffic filtering action riding with the rule, RFC 8955 section
  # 7.1. These communities were in bgp4r years before the NLRI they
  # filter, so until the wiring of #177 the two could not travel
  # together and nothing had ever read the pair back.
  def test_gobgp_reads_a_traffic_rate_action_back
    n, router = session(1, 133, G::FS_IPV4)
    announce(n, 133, { :destination_prefix => '192.0.2.0/24' },
             BGP::Extended_communities.new(
               BGP::Traffic_rate_bytes.new(0, 1_000_000.0)))
    _key, path = installed(router, G::FS_IPV4)

    ext = G.attrs(path)[16]
    assert_not_nil(ext, 'the extended communities attribute arrived')
    # Section 7.1 gives a 2 octet ID then an IEEE 754 single precision
    # rate, in bytes per second, under type 0x80 sub-type 0x06.
    assert_equal([{ 'type' => 128, 'subtype' => 6, 'as' => 0,
                    'rate' => 1_000_000 }],
                 ext['value'])
  end

  # The withdrawal, which is the second of bgp4r's two parse loops on the
  # way out and MP_UNREACH_NLRI on the way in. The RIB emptying is the
  # assertion.
  def test_gobgp_drops_a_rule_we_withdraw
    n, router = session(1, 133, G::FS_IPV4)
    rule = { :destination_prefix => '192.0.2.0/24', :port => [[:eq, 25]] }
    announce(n, 133, rule)
    installed(router, G::FS_IPV4)

    n.send_update BGP::Update.new(BGP::Path_attribute.new(
      BGP::Mp_unreach.new(:safi => 133, :nlris => [rule])))
    assert(wait_for { router.rib_family(G::FS_IPV4) == {} },
           "GoBGP to drop the rule (waited 30s)\n#{router.log}")
  end

  # Section 4.2: "Components MUST follow strict type ordering by
  # increasing numerical order."
  #
  # **GoBGP does not enforce that MUST, it normalises.** We send port
  # before destination and the router accepts the rule and prints it in
  # canonical order, so its rendering says nothing about what order
  # arrived. That is a divergence from a MUST and it is recorded rather
  # than worked around: bgp4r has to be able to put the rule on the wire
  # (Conventions), and what a router then does with it is a measurement.
  def test_gobgp_accepts_an_out_of_order_rule_and_normalises_it
    omit_unless_measured
    n, router = session(1, 133, G::FS_IPV4)
    rule = FS.new(FS::Port.new([:eq, 25]),
                  FS::Destination_prefix.new('198.51.100.0/24'))
    assert_equal('080481190118c63364', rule.to_shex,
                 'port first on the wire, which section 4.2 forbids')
    announce(n, 133, rule)
    key, path = installed(router, G::FS_IPV4)

    assert_equal('[destination: 198.51.100.0/24][port: ==25]', key)
    assert_equal([1, 4], G.components(path).collect { |c| c['type'] },
                 'read back in increasing order, not the order we sent')
    assert(n.is_established?, 'and the session stayed up')
  end

  # The other half of section 4.2: "A given component type MAY (exactly
  # once) be present in the Flow Specification."
  #
  # **GoBGP enforces this one, by resetting the session**, and its own
  # log says under which rule: "ipv4-flowspec nlri violate strict type
  # ordering". So the two halves of section 4.2 are one check to GoBGP,
  # and a repeated type is not increasing.
  #
  # The NOTIFICATION it sends is **code 0 subcode 0**, which RFC 4271
  # section 4.5 does not define and GoBGP's own log calls "code
  # 0(undefined) subcode 0(undefined)". That is recorded, not filed: the
  # job here is bgp4r catching up, and bgp4r reads the undefined code
  # back correctly as Reserved (0).
  def test_gobgp_resets_the_session_on_a_repeated_component_type
    omit_unless_measured
    n, router = session(1, 133, G::FS_IPV4)
    notes = NotificationCatcher.new
    n.add_observer notes
    rule = FS.new(FS::Destination_prefix.new('203.0.113.0/24'),
                  FS::Port.new([:eq, 25]), FS::Port.new([:eq, 80]))
    assert_equal('0b0118cb0071048119048150', rule.to_shex, 'port twice')
    announce(n, 133, rule)

    assert(wait_for { !n.is_established? },
           "GoBGP to reset the session (waited 30s)\n#{router.log}")
    assert_equal({}, router.rib_family(G::FS_IPV4), 'and to hold no rule')
    note = notes.last
    assert_not_nil(note, 'it sent a NOTIFICATION rather than just closing')
    assert_equal({ :code => 0, :subcode => 0, :data => '' }, note.to_hash,
                 'an error code RFC 4271 section 4.5 does not define')
    assert_match(/violate strict type ordering/, router.log,
                 'and it says which rule it was applying')
  end

  # Section 4.2 again: an unknown component type makes the NLRI
  # malformed, which is why bgp4r files that one in
  # Path_attribute#errors rather than #undecoded.
  #
  # **GoBGP does not do that either: it keeps the unknown component and
  # installs the rule.** Recorded as a divergence from the RFC's own
  # word. FRR is the other way round on this one, which is the whole
  # argument for having two routers in the lab.
  #
  # It renders the unknown component in the rule's name and then gives
  # back nothing else: both `nlri` and `attrs` come out **null**, so the
  # key is the only thing the client will say about such a rule. That is
  # measured, not inferred from an empty list, and it is why this case
  # asserts the key and the session rather than the components.
  def test_gobgp_keeps_an_unknown_component_type
    omit_unless_measured
    n, router = session(1, 133, G::FS_IPV4)
    rule = FS.new(FS::Destination_prefix.new('192.0.2.128/25'),
                  FS::Unknown.new(99, [0x81, 0x05].pack('C*')))
    assert_equal('090119c0000280638105', rule.to_shex,
                 'type 99, which RFC 8956 section 8.1.2 leaves unassigned')
    announce(n, 133, rule)
    key, path = installed(router, G::FS_IPV4)

    assert_equal('[destination: 192.0.2.128/25][unknown:[99 129 5]]', key,
                 'the type octet and the operator pair, as it read them')
    assert(n.is_established?, 'and the session stayed up')
    assert_nil(path['nlri'], 'but it serialises no component list at all')
    assert_nil(path['attrs'], 'nor any path attribute')
  end

  private

  # Queues the NOTIFICATIONs the session received. A full BGP:: name in a
  # nested class, which does not see an include in the class around it,
  # and which matters doubly in an observer: Neighbor logs an exception
  # from one rather than raising it, so a wrong constant here would read
  # as "nothing arrived".
  class NotificationCatcher
    def initialize ; @notes = [] ; end
    def update(msg) ; @notes << msg if msg.is_a?(BGP::Notification) ; end
    def last ; @notes.last ; end
  end

  # The three section 4.2 cases are this router's answers at one major
  # version. On any other, omit rather than assert something measured
  # elsewhere: a caller that cannot name the version must not guess.
  def omit_unless_measured
    major = G.major
    return if major == MEASURED_MAJOR
    omit("measured against GoBGP #{MEASURED_MAJOR}, found " \
         "#{major.inspect}: re-measure before asserting")
  end
end
