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

# bgp4r is the router and FRR is the far peer, so a **second** second
# implementation says what it makes of our export side. No Docker and no
# zebra: bgpd runs as a plain process on loopback.
#
#   ruby -I. test/functional/lab/rib_router_frr_test.rb
#
# Omitted when FRR's bgpd is not installed, unless LAB_REQUIRE_FRR=1.
#
# The twin of rib_router_gobgp_test.rb, and worth having for the reason
# that one exists twice over. Two bgp4r speakers agreeing proves only that
# they agree, which is how the inverted ADD-PATH field survived for years.
# One other router agreeing is much better; two others agreeing says the
# reading is the RFC's and not one vendor's habit. The fault matrix showed
# how far apart two routers can be, so the agreement here is worth
# recording rather than assumed.
#
# Three things differ from the GoBGP twin, all of them FRR's:
#
# **The next hop must not be a loopback address.** FRR keeps the session
# up and silently drops a route whose next hop is 127.0.0.1, where GoBGP
# installs it. So the transit case gives the router a next hop of its own
# with `advertise(next_hops:)` rather than letting it use the session's
# local address, and the reflected case has its source send one. See
# Frr::NEXT_HOP in lab_helper.rb for how that was measured.
#
# **FRR needs an address of its own**, not the peer's, or every route is
# rejected under RFC 4271 section 6.3 for a NEXT_HOP equal to the
# receiving speaker's own address.
#
# **Its JSON names attributes rather than numbering them**, where the
# gobgp client keys them by code point, so the assertions here read fields
# off FRR's own path object instead of a type-code hash. Same facts, named
# the way this router names them.
#
# BGP:: names are written out in full, see Conventions in CLAUDE.md.

require 'test/unit'
require 'socket'
require 'bgp4r'
require 'bgp/rib'
require_relative 'lab_helper'

class LabRibRouterFrrTest < Test::Unit::TestCase
  include LabHelper

  OUR_AS = 65001      # ours, the router in the middle
  THEIR_AS = 65002    # FRR, when the session is external
  SOURCE_AS = 65003   # the external peer a transit route comes from
  CLUSTER_ID = '7.7.7.7'
  REFLECTED = '198.51.100.0/24'
  TRANSIT = '203.0.113.0/24'
  OURS = '192.0.2.128/25'

  # Next hops FRR will accept, which a loopback address is not.
  OUR_NEXT_HOP = '192.0.2.9'
  SOURCE_NEXT_HOP = '192.0.2.10'

  def setup
    unless LabHelper::Frr.available?
      flunk('FRR bgpd is not installed') if ENV['LAB_REQUIRE_FRR'] == '1'
      omit('FRR bgpd is not installed')
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
    # names what it made of an UPDATE it would not install, and a silently
    # dropped route is the failure mode this file has to worry about.
    puts "\n== bgpd\n#{@routers.collect(&:log).join}" unless passed?
  end

  # A listening side of the router: its own Neighbor, its own port,
  # attached to the shared table.
  #
  # remote_addr has to differ per peer, because a BGP::Rib::Peer is
  # identified by its address and PeerAdapter builds it from the
  # Neighbor's configured remote_addr rather than from the accepted
  # socket. Two peers configured alike collapse into one Adj-RIB-Out and
  # then every route looks like it is going back to its sender.
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

  # An FRR that dials one of those ports. Its AS is what decides whether
  # the session is internal or external, which is the whole difference
  # between the reflection case and the transit case.
  def frr(port, as)
    router = LabHelper::Frr.new(:local => '127.0.0.2', :as => as,
                                :router_id => '10.0.0.2',
                                :peer => '127.0.0.1', :peer_as => OUR_AS,
                                :port => port, :ipv6 => false)
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

  # The router's reading of one prefix, waited for. Its absence is how FRR
  # reports that it would not install what we sent, so this is the
  # assertion that matters most in the file.
  def installed(router, prefix)
    wait_for("FRR to install #{prefix}", timeout: 30) do
      @rib.drain && router.path(prefix)
    end
  end

  def gone(router, prefix)
    wait_for("FRR to drop #{prefix}", timeout: 30) do
      @rib.drain && router.path(prefix).nil?
    end
  end

  # RFC 4456: a reflector passes an internal peer's route to another
  # client, with the two attributes of section 8 added and the AS_PATH and
  # NEXT_HOP left alone because the peer is internal (RFC 4271 sections
  # 5.1.2 and 5.1.3). FRR is the other client, and it has to accept the
  # route rather than drop it.
  def test_frr_accepts_our_reflected_route
    source_side, source_port = listener('127.0.0.3')
    client_side, client_port = listener('127.0.0.2')
    @rib = BGP::Rib::Table.new(:local_as => OUR_AS, :router_id => '0.0.0.1')
    @rib.attach(source_side)
    @rib.attach(client_side)
    reflector = BGP::Rib::Export.new(:local_as => OUR_AS, :router_id => '0.0.0.1',
                                     :route_reflector => true,
                                     :cluster_id => CLUSTER_ID)
    router = @rib.advertise(:export => reflector)

    far = frr(client_port, OUR_AS)
    source = client(OUR_AS, '0.0.0.4', source_port)
    established(source_side, client_side)

    # The source's next hop is left alone toward an internal peer, so it
    # is the one FRR has to accept: not a loopback address.
    source.send_update ibgp_update(REFLECTED, SOURCE_NEXT_HOP)
    path = installed(far, REFLECTED)

    assert_equal(SOURCE_NEXT_HOP, LabHelper::Frr.next_hop(path),
                 'NEXT_HOP left alone toward an internal peer, section 5.1.3')
    assert_equal([], LabHelper::Frr.as_path(path),
                 'AS_PATH left alone, and still empty, section 5.1.2')
    assert_equal(300, path['locPrf'],
                 'LOCAL_PREF is kept inside the AS, section 5.1.5')
    # RFC 4456 section 8, as FRR reads them back, and from the detail
    # form: its table form has no originatorId or clusterList key at all,
    # so reading them there answers nil however correct the UPDATE was.
    # FRR would drop the route outright if it saw its own router id in
    # either, so getting the route at all is half the assertion.
    d = far.detail(REFLECTED)
    assert_equal('0.0.0.4', d['originatorId'],
                 'ORIGINATOR_ID: the originator in the local AS')
    assert_equal([CLUSTER_ID], d['clusterList'] && d['clusterList']['list'],
                 'CLUSTER_LIST, with our cluster id in it')
    assert_equal(1, router.sent)
  end

  # A route from one external peer, re-advertised to another: our AS goes
  # on the front of the AS_PATH (RFC 4271 section 5.1.2) and the next hop
  # becomes ours (section 5.1.3). This is what a transit AS does, and FRR
  # is the far AS.
  def test_frr_accepts_our_transit_route
    source_side, source_port = listener('127.0.0.3')
    far_side, far_port = listener('127.0.0.2')
    @rib = BGP::Rib::Table.new(:local_as => OUR_AS, :router_id => '0.0.0.1')
    @rib.attach(source_side)
    @rib.attach(far_side)
    # Our own next hop for IPv4, instead of the session's local address,
    # which is 127.0.0.1 and which FRR drops in silence.
    router = @rib.advertise(:next_hops => { 1 => OUR_NEXT_HOP })

    far = frr(far_port, THEIR_AS)
    source = client(SOURCE_AS, '0.0.0.5', source_port)
    established(source_side, far_side)

    source.send_update ebgp_update(SOURCE_AS, TRANSIT, SOURCE_NEXT_HOP)
    path = installed(far, TRANSIT)

    assert_equal([OUR_AS, SOURCE_AS], LabHelper::Frr.as_path(path),
                 'our AS in front of theirs')
    assert_equal(OUR_NEXT_HOP, LabHelper::Frr.next_hop(path),
                 "ours, not the source's #{SOURCE_NEXT_HOP}")
    # RFC 4271 section 5.1.5: LOCAL_PREF never goes to an external peer.
    # FRR prints its own default for a path that arrived without one, so
    # the assertion is that it is the default and not the 300 an internal
    # peer would have seen.
    assert_not_equal(300, path['locPrf'],
                     'LOCAL_PREF never crosses to an external peer')
    # RFC 4456 section 8: neither attribute leaves the AS. Read from the
    # detail form, because the table form would answer nil either way and
    # so could not tell a missing attribute from a missing key.
    d = far.detail(TRANSIT)
    assert_nil(d['originatorId'], 'no ORIGINATOR_ID outside the AS')
    assert_nil(d['clusterList'], 'no CLUSTER_LIST outside the AS')
  end

  # rib.originate, and then the withdrawal. RFC 4271 section 5.1.2 gives
  # an originated route our AS as the only entry in the only segment once
  # it crosses to an external peer.
  def test_frr_takes_a_prefix_we_originate_and_drops_it_again
    far_side, far_port = listener('127.0.0.2')
    @rib = BGP::Rib::Table.new(:local_as => OUR_AS, :router_id => '0.0.0.1')
    @rib.attach(far_side)
    @rib.advertise(:next_hops => { 1 => OUR_NEXT_HOP })

    far = frr(far_port, THEIR_AS)
    established(far_side)

    @rib.originate(OURS)
    path = installed(far, OURS)
    assert_equal([OUR_AS], LabHelper::Frr.as_path(path),
                 'our AS, the only entry in the only segment, section 5.1.2')
    assert_equal(OUR_NEXT_HOP, LabHelper::Frr.next_hop(path),
                 'our own address, section 5.1.3')

    @rib.withdraw(@rib.local_peer, OURS)
    gone(far, OURS)
  end

end
