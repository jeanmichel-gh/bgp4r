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

# bgp4r is the router and GoBGP is the far peer, so a second implementation
# says what it makes of our export side. No Docker: gobgpd runs as a plain
# process on loopback.
#
#   ruby -I. test/functional/lab/rib_router_gobgp_test.rb
#
# Omitted when gobgpd is not installed, unless LAB_REQUIRE_GOBGPD=1.
#
# This is the part of RIB phase 3 that bgp4r cannot check on its own.
# test/functional/rib_router_test.rb runs the same arrangement between
# three bgp4r speakers and asserts far more, because it reads the UPDATE
# off the wire. What it cannot tell you is whether anyone else accepts
# what we send. Two bgp4r speakers agreeing proves only that they agree,
# which is exactly how the inverted ADD-PATH field survived for years.
#
# So every assertion here is about the router's own reading, taken from
# its RIB with the gobgp client, and the interesting outcome is not a
# value but the absence of a complaint: a route GoBGP dropped as a loop,
# or as a malformed attribute, never reaches its RIB at all.
#
# One Table with two Neighbors is what makes a router: a Neighbor holds
# one session, so a speaker with two peers has two of them, both attached
# to the same table.
#
# BGP:: names are written out in full, see Conventions in CLAUDE.md.

require 'test/unit'
require 'socket'
require 'bgp4r'
require 'bgp/rib'
require_relative 'lab_helper'

class LabRibRouterGobgpTest < Test::Unit::TestCase
  include LabHelper

  OUR_AS = 65001      # ours, the router in the middle
  THEIR_AS = 65002    # GoBGP, when the session is external
  SOURCE_AS = 65003   # the external peer a transit route comes from
  CLUSTER_ID = '7.7.7.7'
  REFLECTED = '198.51.100.0/24'
  TRANSIT = '203.0.113.0/24'
  OURS = '192.0.2.0/24'

  # Attribute type codes, so an assertion names the code point its RFC
  # does. 1, 2, 3 and 5 are RFC 4271 section 4.3; 9 and 10 are RFC 4456
  # section 8.
  ORIGIN, AS_PATH, NEXT_HOP, LOCAL_PREF = 1, 2, 3, 5
  ORIGINATOR_ID, CLUSTER_LIST = 9, 10

  def setup
    unless LabHelper::Gobgpd.available?
      flunk('gobgpd is not installed') if ENV['LAB_REQUIRE_GOBGPD'] == '1'
      omit('gobgpd is not installed')
    end
    @listeners = []
    @clients = []
    @routers = []
    @rib = nil
  end

  def teardown
    @rib.feed.stop if @rib
    @clients.each { |c| c.close }
    @listeners.each do |server, neighbor, thread|
      thread.kill if thread
      neighbor.close
      server.close unless server.closed?
    end
    @routers.each { |r| r.down }
    # The router's own log is where the answer to a failure here is: it
    # names what it made of an UPDATE it would not install.
    puts "\n== gobgpd\n#{@routers.collect(&:log).join}" unless passed?
  end

  # A listening side of the router: its own Neighbor, its own port,
  # attached to the shared table.
  #
  # remote_addr has to differ per peer. A BGP::Rib::Peer is identified by
  # its address, and PeerAdapter builds it from the Neighbor's configured
  # remote_addr rather than from the accepted socket, so two peers
  # configured alike collapse into one Adj-RIB-Out and then every route
  # looks like it is going back to its sender. GoBGP really does speak
  # from 127.0.0.2, so only the bgp4r client needs an address invented
  # for it.
  def listener(remote_addr)
    server = TCPServer.new('127.0.0.1', 0)
    n = BGP::Neighbor.new(4, OUR_AS, 180, '0.0.0.1', remote_addr, '127.0.0.1')
    thread = Thread.new do
      begin
        while (session = server.accept)
          n.start_session(session)
        end
      rescue IOError, SystemCallError
      end
    end
    @listeners << [server, n, thread]
    [n, server.addr[1]]
  end

  # A gobgpd that dials one of those ports. Its AS is what decides whether
  # the session is internal or external, which is the whole difference
  # between the reflection case and the transit case below.
  def gobgpd(port, as)
    router = LabHelper::Gobgpd.new(:local => '127.0.0.2', :as => as,
                                   :router_id => '10.0.0.2',
                                   :peer => '127.0.0.1', :peer_as => OUR_AS,
                                   :port => port)
    @routers << router
    router.up
  end

  # A bgp4r peer that connects to one of those ports and sends us a route.
  def client(as, id, port)
    c = BGP::Neighbor.new(4, as, 180, id, '127.0.0.1', '127.0.0.1')
    @clients << c
    c.start :port => port
    c
  end

  # RFC 4271 section 5.1.2 wants an empty AS_PATH attribute toward an
  # internal peer, which is not the same as leaving the attribute out.
  def ibgp_update(prefix, next_hop, local_pref = 300)
    BGP::Update.new(
      BGP::Path_attribute.new(BGP::Origin.new(0), BGP::Next_hop.new(next_hop),
                              BGP::As_path.new, BGP::Local_pref.new(local_pref)),
      BGP::Nlri.new(prefix))
  end

  def ebgp_update(as, prefix, next_hop)
    BGP::Update.new(
      BGP::Path_attribute.new(BGP::Origin.new(0), BGP::Next_hop.new(next_hop),
                              BGP::As_path.new(as)),
      BGP::Nlri.new(prefix))
  end

  def established(*sides)
    wait_for('the sessions to reach Established', timeout: 40) do
      sides.all? { |s| s.is_established? }
    end
  end

  # The router's reading of one prefix, waited for. Its absence is how
  # GoBGP reports that it would not install what we sent, so this is the
  # assertion that matters most in the file.
  def installed(router, prefix)
    path = wait_for("GoBGP to install #{prefix}", timeout: 30) do
      @rib.drain && router.path(prefix)
    end
    LabHelper::Gobgpd.attrs(path).merge(:path => path)
  end

  # RFC 4456: a reflector passes an internal peer's route to another
  # client, with the two attributes of section 8 added and the AS_PATH and
  # NEXT_HOP left alone because the peer is internal (RFC 4271 sections
  # 5.1.2 and 5.1.3). GoBGP is the other client, and it has to accept the
  # route rather than drop it.
  def test_gobgp_accepts_our_reflected_route_with_both_section_8_attributes
    source_side, source_port = listener('127.0.0.3')
    client_side, client_port = listener('127.0.0.2')
    @rib = BGP::Rib::Table.new(:local_as => OUR_AS, :router_id => '0.0.0.1')
    @rib.attach(source_side)
    @rib.attach(client_side)
    reflector = BGP::Rib::Export.new(:local_as => OUR_AS, :router_id => '0.0.0.1',
                                     :route_reflector => true,
                                     :cluster_id => CLUSTER_ID)
    router = @rib.advertise(:export => reflector)

    far = gobgpd(client_port, OUR_AS)
    source = client(OUR_AS, '0.0.0.4', source_port)
    established(source_side, client_side)

    source.send_update ibgp_update(REFLECTED, '10.4.4.4')
    a = installed(far, REFLECTED)

    # Section 8: the ORIGINATOR_ID carries "the BGP Identifier of the
    # originator of the route in the local AS", which is what the source
    # client put in its OPEN.
    assert_equal('0.0.0.4', a[ORIGINATOR_ID] && a[ORIGINATOR_ID]['value'],
                 'ORIGINATOR_ID, as GoBGP read it back')
    assert_equal([CLUSTER_ID], a[CLUSTER_LIST] && a[CLUSTER_LIST]['value'],
                 'CLUSTER_LIST, with our cluster id in it')
    assert_equal('10.4.4.4', a[NEXT_HOP]['nexthop'],
                 'NEXT_HOP left alone toward an internal peer, section 5.1.3')
    assert_equal([], LabHelper::Gobgpd.as_path(a[:path]),
                 'AS_PATH left alone, and still empty, section 5.1.2')
    assert_equal(300, a[LOCAL_PREF]['value'],
                 'LOCAL_PREF is kept inside the AS, section 5.1.5')
    assert_equal(1, router.sent)
  end

  # A route from one external peer, re-advertised to another: our AS goes
  # on the front of the AS_PATH (RFC 4271 section 5.1.2) and the next hop
  # becomes ours (section 5.1.3). This is what a transit AS does, and
  # GoBGP is the far AS.
  def test_gobgp_accepts_our_transit_route_with_our_as_and_our_next_hop
    source_side, source_port = listener('127.0.0.3')
    far_side, far_port = listener('127.0.0.2')
    @rib = BGP::Rib::Table.new(:local_as => OUR_AS, :router_id => '0.0.0.1')
    @rib.attach(source_side)
    @rib.attach(far_side)
    router = @rib.advertise

    far = gobgpd(far_port, THEIR_AS)
    source = client(SOURCE_AS, '0.0.0.5', source_port)
    established(source_side, far_side)

    source.send_update ebgp_update(SOURCE_AS, TRANSIT, '10.9.9.9')
    a = installed(far, TRANSIT)

    assert_equal([OUR_AS, SOURCE_AS], LabHelper::Gobgpd.as_path(a[:path]),
                 'our AS in front of theirs')
    # RFC 4271 section 4.3: segment type 2 is AS_SEQUENCE. A prepend makes
    # one of those and must not make an AS_SET, which would lose the order.
    assert_equal([2], a[AS_PATH]['as_paths'].collect { |s| s['segment_type'] },
                 'one AS_SEQUENCE segment')
    assert_equal('127.0.0.1', a[NEXT_HOP]['nexthop'], 'ours, not 10.9.9.9')
    assert_nil(a[LOCAL_PREF], 'LOCAL_PREF never goes to an external peer, section 5.1.5')
    # RFC 4456 section 8: neither attribute leaves the AS. GoBGP would
    # show them if we had sent them, as the reflection test proves.
    assert_nil(a[ORIGINATOR_ID], 'no ORIGINATOR_ID: this is not reflection')
    assert_nil(a[CLUSTER_LIST], 'no CLUSTER_LIST either')
    assert_equal(1, router.sent)
  end

  # A prefix of our own, RIB phase 3 part 6. Section 5.1.2 wants our AS as
  # the only entry of the only segment toward an external peer, and
  # section 5.1.3 our own address as the next hop.
  def test_gobgp_accepts_a_prefix_we_originate
    far_side, far_port = listener('127.0.0.2')
    @rib = BGP::Rib::Table.new(:local_as => OUR_AS, :router_id => '0.0.0.1')
    @rib.attach(far_side)
    @rib.advertise

    far = gobgpd(far_port, THEIR_AS)
    established(far_side)

    @rib.originate(OURS)
    a = installed(far, OURS)

    assert_equal([OUR_AS], LabHelper::Gobgpd.as_path(a[:path]),
                 'our AS alone, section 5.1.2')
    assert_equal([2], a[AS_PATH]['as_paths'].collect { |s| s['segment_type'] },
                 'as one AS_SEQUENCE segment')
    assert_equal('127.0.0.1', a[NEXT_HOP]['nexthop'], 'our own address, section 5.1.3')
    assert_equal(0, a[ORIGIN]['value'], 'ORIGIN defaults to IGP, section 5.1.1')
    assert_nil(a[LOCAL_PREF], 'not to an external peer')
  end

  # The half that is easy to leave out: a peer told about a route and never
  # told it went holds it for ever. GoBGP is the one that can say whether
  # our withdrawal actually removed it.
  def test_a_withdrawal_reaches_gobgp
    source_side, source_port = listener('127.0.0.3')
    far_side, far_port = listener('127.0.0.2')
    @rib = BGP::Rib::Table.new(:local_as => OUR_AS, :router_id => '0.0.0.1')
    @rib.attach(source_side)
    @rib.attach(far_side)
    @rib.advertise

    far = gobgpd(far_port, THEIR_AS)
    source = client(SOURCE_AS, '0.0.0.5', source_port)
    established(source_side, far_side)

    source.send_update ebgp_update(SOURCE_AS, TRANSIT, '10.9.9.9')
    installed(far, TRANSIT)

    source.send_update BGP::Update.new(BGP::Withdrawn.new(TRANSIT))
    # rib being non nil is what separates "GoBGP dropped the route" from
    # "the client could not be asked", which would otherwise pass here.
    wait_for("GoBGP to lose #{TRANSIT}", timeout: 30) do
      @rib.drain && far.rib && far.path(TRANSIT).nil?
    end
  end
end
