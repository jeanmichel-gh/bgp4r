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
require 'base64'
require 'bgp4r'
require 'test/functional/lab/lab_helper'

# An ATTR_SET from bgp4r carried through a real router. RFC 6368
# attribute 128, no Docker.
#
# **This is the only lab test here that runs a router in the middle**,
# and the reason is what the attribute is for. RFC 6368 section 5 exists
# so a customer's path attributes survive the provider network: the set
# is an optional transitive attribute, so a provider router that does not
# implement it must still carry it and hand it on. A router with one peer
# can only say what it made of what we sent. Only a router with two can
# say whether the octets come out the far side.
#
# **Measured on 2026-10-31 against GoBGP 3.23.0, and GoBGP does not
# implement attribute 128 at all.** `strings` on the binary finds
# PMSI_TUNNEL, TUNNEL_ENCAP, LARGE_COMMUNITY, AIGP, PREFIX_SID and
# AGGREGATOR and no ATTR_SET; FRR 8.4.4 has no such attribute either, so
# there is no FRR twin, which makes this the third case after VPN flow
# spec and RT-constrain with one reference rather than two.
#
# **So be exact about what a second implementation vouches for here, and
# what it does not.** GoBGP stores the value opaquely and re-emits it, so
# it never parses the attributes inside. This test therefore does **not**
# corroborate the meaning of the 4-octet AS rule of section 5; nothing
# but another ATTR_SET implementation could. What it does corroborate is
# the half no bgp4r test can reach: that the attribute's own framing is
# well formed enough for a real router to accept the UPDATE rather than
# apply RFC 7606 to it, that the value is stored unmangled, and that the
# transit property the attribute exists for actually holds across an
# implementation that is not ours.
#
# BGP:: names are written out in full, see Conventions in CLAUDE.md.
class AttrSetGobgpTest < Test::Unit::TestCase

  NEAR_AS = 65001          # the bgp4r speaker that originates
  MID_AS  = 65002          # gobgpd in the middle
  FAR_AS  = 65003          # the bgp4r speaker that receives
  CUST_AS = 65000          # the Origin AS inside the set

  G = LabHelper::Gobgpd

  # The version these expectations were measured against. GoBGP 4 has not
  # been run against this file, and the fault matrix already shows the two
  # majors do not answer alike, so a different major omits rather than
  # guesses.
  MEASURED_MAJOR = 3

  # Collects the UPDATEs a Neighbor receives. Nothing in a Neighbor
  # observer may raise: `dispatch_event` logs an exception rather than
  # raising it, deliberately, so a wrong signature here shows up as
  # "nothing arrived" and says nothing about the cause. `update` takes
  # one argument, which is what `notify_observers(msg)` passes. Writing
  # two cost a probe run.
  class Catcher
    def updates ; @updates ||= [] ; end
    def update(msg) ; updates << msg if msg.is_a?(BGP::Update) ; end
  end

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

  # One bgp4r speaker listening on its own address, which gobgpd dials.
  # Each gets a 127.0.0.x of its own: a router cannot hold two neighbors
  # at one address, and the two speakers are two autonomous systems.
  def speaker(address, as, router_id, catcher = nil)
    server = TCPServer.new(address, 0)
    n = BGP::Neighbor.new(4, as, 180, router_id, '127.0.0.2', address)
    n.add_observer(catcher) if catcher
    thread = Thread.new do
      begin
        while (s = server.accept)
          n.start_session(s)
        end
      rescue IOError, SystemCallError
      end
    end
    @listeners << [server, n, thread]
    [n, server.addr[1]]
  end

  # Two bgp4r speakers with a gobgpd between them, both sessions up.
  def transit
    far_catcher = Catcher.new
    near, near_port = speaker('127.0.0.1', NEAR_AS, '0.0.0.1')
    far, far_port = speaker('127.0.0.3', FAR_AS, '0.0.0.3', far_catcher)
    router = G.new(:local => '127.0.0.2', :as => MID_AS,
                   :router_id => '10.0.0.2', :peer => '127.0.0.1',
                   :peer_as => NEAR_AS, :port => near_port, :ipv6 => false,
                   :peer2 => { :address => '127.0.0.3', :as => FAR_AS,
                               :port => far_port })
    @routers << router
    router.up
    assert(wait_for { near.is_established? && far.is_established? },
           "both sessions came up\n#{router.log}")
    [near, far, far_catcher, router]
  end

  def wait_for(timeout = 30)
    deadline = Time.now + timeout
    loop do
      return true if yield
      return false if Time.now > deadline
      sleep 0.2
    end
  end

  # The set used by every case: an Origin AS, an ORIGIN, and an
  # AGGREGATOR carrying a 4-octet AS. The AGGREGATOR is the field that
  # matters, since section 5 requires the 4-octet form inside and a
  # 2-octet encoding would cut 4200000001 to 59905.
  def attr_set
    BGP::Attr_set.new(CUST_AS,
                      BGP::Origin.new(:igp),
                      BGP::Aggregator.new('10.0.0.1', 4200000001))
  end

  def announce(n, prefix, *extra)
    n.send_update BGP::Update.new(
      BGP::Path_attribute.new(BGP::Origin.new(0), BGP::As_path.new(NEAR_AS),
                              BGP::Next_hop.new('192.0.2.9'), *extra),
      BGP::Nlri.new(prefix))
  end

  # The one ATTR_SET in whatever the far speaker has received, or nil.
  def received_set(catcher)
    catcher.updates.each do |u|
      next unless u.path_attribute
      found = u.path_attribute.attributes.find { |a| a.type == 128 }
      return found if found
    end
    nil
  end

  def skip_other_majors
    return if G.major == MEASURED_MAJOR
    omit("measured against GoBGP #{MEASURED_MAJOR}, this is #{G.major}")
  end

  # **The waiting is the assertion.** An UPDATE GoBGP rejected under RFC
  # 7606 never reaches its RIB, so a route that never installs is how a
  # malformed attribute header shows up here, exactly as in
  # rib_router_gobgp_test.rb.
  def test_a_route_carrying_an_attr_set_is_accepted_and_installed
    skip_other_majors
    near, _far, _catcher, router = transit
    announce(near, '198.51.100.0/24', attr_set)
    assert(wait_for { router.path('198.51.100.0/24') },
           "GoBGP to install 198.51.100.0/24 (waited 30s)\n#{router.log}")
    assert(near.is_established?, 'and the session survived it')
  end

  # GoBGP does not implement attribute 128, so it keeps the value whole
  # and base64 encodes it in the client's JSON. That is what lets this
  # test compare octets: the value it hands back must be exactly the
  # value we encoded, which is the framing check.
  def test_gobgp_keeps_the_value_octet_for_octet
    skip_other_majors
    near, _far, _catcher, router = transit
    sent = attr_set
    announce(near, '198.51.100.0/24', sent)
    assert(wait_for { router.path('198.51.100.0/24') },
           "GoBGP to install the route\n#{router.log}")
    a = G.attrs(router.path('198.51.100.0/24'))[128]
    assert_not_nil(a, "GoBGP to report attribute 128\n#{router.log}")
    # 0xc0: optional and transitive, which is what RFC 6368 section 5
    # calls for and what our header writes.
    assert_equal(0xc0, a['flags'], 'read as optional transitive')
    assert_equal(128, a['type'])
    value = Base64.strict_decode64(a['value']).unpack1('H*')
    # The attribute minus its 3 octet header, which is the value field.
    assert_equal(sent.to_shex[6..-1], value,
                 'the value GoBGP stored is the value we encoded')
    # And the 4-octet AGGREGATOR is in there, which is what a 2-octet
    # encoding would have shortened by two octets.
    four = BGP::Path_attribute.new(BGP::Aggregator.new('10.0.0.1', 4200000001))
    assert(value.include?(four.encode(true).unpack1('H*')),
           'with the 4-octet AGGREGATOR of section 5 intact')
  end

  # **The case this file exists for.** RFC 6368 section 5 makes the set
  # optional transitive so it crosses a provider network, and this is the
  # only test anywhere that says it does: the octets go into a router
  # that has never heard of attribute 128 and come out the far side.
  def test_the_set_crosses_the_router_octet_for_octet
    skip_other_majors
    near, _far, catcher, router = transit
    sent = attr_set
    announce(near, '198.51.100.0/24', sent)
    assert(wait_for { received_set(catcher) },
           "the far speaker to receive an ATTR_SET (waited 30s)\n#{router.log}")
    got = received_set(catcher)
    assert_equal(sent.to_shex, got.to_shex, 'byte for byte, header included')
    # And it reads back as the attribute rather than as something that
    # merely has the same octets.
    assert_instance_of(BGP::Attr_set, got)
    assert_equal(CUST_AS, got.origin_as)
    agg = got.attributes.attributes.find { |a| a.is_a?(BGP::Aggregator) }
    assert_not_nil(agg, 'the nested AGGREGATOR survived')
    assert_equal(4200000001, agg.asn, 'and its 4-octet AS was not cut to 59905')
  end

  # **A measurement, recorded rather than filed.** GoBGP propagates the
  # attribute with the Partial bit clear, flags 0xc0 rather than 0xe0,
  # on an attribute it does not recognize. RFC 4271 does describe the
  # Partial bit as saying whether an optional transitive attribute's
  # information is complete, and the obvious reading is that a speaker
  # that cannot recognize an attribute should set it when passing it on.
  # **That reading is not first hand here**: RFC 4271 section 9 is the
  # part that would settle it and CLAUDE.md records that both fetchable
  # sources truncate the document before it. So this asserts what was
  # measured and claims nothing about conformance. If a later GoBGP sets
  # the bit, this fails and says to re-measure, which is the point.
  def test_gobgp_propagates_it_with_the_partial_bit_clear
    skip_other_majors
    near, _far, catcher, router = transit
    announce(near, '198.51.100.0/24', attr_set)
    assert(wait_for { received_set(catcher) },
           "the far speaker to receive an ATTR_SET\n#{router.log}")
    got = received_set(catcher)
    assert(got.is_optional?, 'optional')
    assert(got.is_transitive?, 'transitive')
    assert(!got.partial?, 'and Partial clear, which is the measurement')
    assert_equal('c0', got.to_shex[0, 2])
  end

  # A withdrawal crosses too, which every other lab test here asserts
  # and which says the route was really in the router's table rather
  # than merely logged.
  def test_a_withdrawal_crosses_the_router
    skip_other_majors
    near, _far, _catcher, router = transit
    announce(near, '198.51.100.0/24', attr_set)
    assert(wait_for { router.path('198.51.100.0/24') },
           "GoBGP to install the route\n#{router.log}")
    near.send_update BGP::Update.new(BGP::Withdrawn.new('198.51.100.0/24'))
    assert(wait_for { router.path('198.51.100.0/24').nil? },
           "GoBGP to drop the route again\n#{router.log}")
  end

  # Nothing validates on build, per Conventions, so a set carrying an
  # MP_REACH is sendable even though RFC 6368 section 5 excludes it. What
  # a router does with one is its business; what matters here is that
  # bgp4r can put it on the wire and that the session's fate is recorded
  # rather than assumed.
  def test_a_set_no_rfc_allows_reaches_the_router
    skip_other_majors
    near, _far, _catcher, router = transit
    inner = BGP::Mp_reach.new(:afi => 1, :safi => 1,
                              :nexthop => ['10.0.0.1'],
                              :nlris => ['20.0.0.0/8'])
    announce(near, '203.0.113.0/24', BGP::Attr_set.new(CUST_AS, inner))
    # Measured: GoBGP installs the route and keeps the session, because
    # it never looks inside the value. Asserted so a version that starts
    # checking shows up as a failure here.
    assert(wait_for { router.path('203.0.113.0/24') },
           "GoBGP to install the route anyway (waited 30s)\n#{router.log}")
    assert(near.is_established?, 'and keep the session up')
  end

end
