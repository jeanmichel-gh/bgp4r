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
require 'json'
require 'socket'
require './test/functional/lab/lab_helper'

# A Route Target membership route from bgp4r, read back by GoBGP. RFC
# 4684, AFI 1 SAFI 132. No Docker.
#
# **What a second implementation vouches for here, which no bgp4r test
# can**: that the 96-bit prefix of section 4 splits where we say it does,
# since GoBGP prints the origin AS and the route target as separate
# fields; that the route target inside is a real one, since GoBGP renders
# all three RFC 4360 and RFC 5668 forms by their own structure, a
# four-octet AS in asdot among them; that the zero-length default is read
# as the default and not as a prefix of nothing; and that the framing
# holds across two NLRIs in one attribute.
#
# **This test sends only**, the same caveat the flow spec and EVPN lab
# tests record: it asserts a router's reading of what bgp4r put on the
# wire, so the parse direction belongs to
# `test/functional/rt_constrain_test.rb`.
#
# **Only GoBGP can carry this.** FRR 8.4.4 has no RT-constrain family at
# all: its `bgpd` has `bgp_nlri_parse_` functions for evpn, flowspec, ip,
# label and vpn and none for this, and its `address-family` grammar
# offers only the two unicast blocks, `ipv4`, `ipv6` and `l2vpn evpn`.
# Measured on 2026-10-31. So there is no `rt_constrain_frr_test.rb`
# twin, which makes this the second family after VPN flow spec with one
# reference rather than two.
#
# Every case gets a session of its own, which is the fault matrix's shape
# and is not tidiness here: one case below **kills the daemon**, so
# nothing after it on a shared session would mean anything.
class RtConstrainGobgpTest < Test::Unit::TestCase

  OUR_AS = 65001
  THEIR_AS = 65002
  G = LabHelper::Gobgpd

  # RFC 4684 section 4: "The [AFI, SAFI] value pair used to identify this
  # NLRI is (AFI=1, SAFI=132)."
  AFI = 1
  SAFI = 132

  # The version these expectations were measured against. GoBGP's
  # rendering of a prefix is its own and a release may reword it, and the
  # crash below is certainly version specific, so the cases that turn on
  # either omit themselves elsewhere rather than failing.
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
  # multiprotocol capability of RFC 4760 for AFI 1 SAFI 132, with a
  # gobgpd configured for the same family dialling it.
  def session
    server = TCPServer.new('127.0.0.1', 0)
    n = BGP::Neighbor.new(4, OUR_AS, 180, '0.0.0.1', '127.0.0.2', '127.0.0.1')
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
                   :peer_as => OUR_AS, :port => server.addr[1],
                   :families => [G::RTC])
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

  # Sends one or more membership prefixes with an ORIGIN and an AS_PATH in
  # front, which is the least a router will accept.
  def announce(n, *nlris)
    n.send_update BGP::Update.new(BGP::Path_attribute.new(
      BGP::Origin.new(0), BGP::As_path.new(OUR_AS),
      BGP::Mp_reach.new(:safi => SAFI, :nexthop => ['10.0.0.1'],
                        :nlris => nlris)))
  end

  def withdraw(n, *nlris)
    n.send_update BGP::Update.new(BGP::Path_attribute.new(
      BGP::Mp_unreach.new(:safi => SAFI, :nlris => nlris)))
  end

  # Waits for the router to hold exactly one membership route and answers
  # it as [key, path], or fails. **The waiting is the assertion**, as it
  # is in the other lab tests: a route the router rejected never reaches
  # its RIB, so there is nothing to compare and this is what catches it.
  def installed(router)
    found = nil
    assert(wait_for { found = router.only_rule(G::RTC) },
           'GoBGP to install the membership route (waited 30s)')
    found
  end

  # The whole prefix of section 4's figure, 96 bits, with a two-octet-AS
  # route target. **GoBGP prints the origin AS and the route target as
  # separate fields**, which is the assertion that matters: our 12 octets
  # split 4 and 8 where section 4 says, and a second implementation reads
  # them that way rather than taking our word for it.
  def test_a_whole_membership_prefix_is_read_back_field_by_field
    omit("rendering measured on GoBGP #{MEASURED_MAJOR}") unless measured?
    n, router = session
    announce(n, BGP::Rt_constrain.new(65001, [65001, 200]))

    key, path = installed(router)
    assert_equal('65001:65001:200', key,
                 'origin AS, then the route target by its own fields')
    assert_equal('65001:65001:200', (path['nlri'] || {})['prefix'])
    assert_equal([OUR_AS], G.as_path(path), 'and it came from us')
  end

  # Section 4's default route target, "encoded as a zero-length prefix".
  # It is the one length under 32 bits the RFC allows, and section 4 says
  # what for: "to indicate to a peer the willingness to receive all VPN
  # route advertisements such as, for instance, the case of a route
  # reflector speaking to one of its PE router clients."
  #
  # **GoBGP names it rather than printing an empty prefix**, which is the
  # check that one octet of 0x00 is read as the default and not as a
  # prefix that happens to carry nothing.
  def test_the_zero_length_default_is_read_as_the_default
    omit("rendering measured on GoBGP #{MEASURED_MAJOR}") unless measured?
    n, router = session
    announce(n, BGP::Rt_constrain.new)

    key, = installed(router)
    assert_equal('0:default', key)
  end

  # The other two route target forms of RFC 4360 and RFC 5668, each in a
  # 96-bit prefix. **This is the strongest thing in the file**, because
  # GoBGP renders each by its own structure and so reads our 8 route
  # target octets three different ways: a two-octet AS above, a
  # four-octet AS here, and an IPv4 address.
  #
  # The four-octet case is worth its own line: AS 70000 comes back as
  # `1.4464`, which is asdot, 70000 == 1 * 65536 + 4464. So GoBGP agrees
  # about the whole 4-octet field and not merely about its low half.
  def test_every_route_target_form_is_read_by_its_own_structure
    omit("rendering measured on GoBGP #{MEASURED_MAJOR}") unless measured?
    n, router = session
    announce(n, BGP::Rt_constrain.new(65002, BGP::Route_target.new(70000, 5)))
    key, = installed(router)
    assert_equal('65002:1.4464:5', key, 'a four-octet AS, in asdot')

    n2, router2 = session
    announce(n2, BGP::Rt_constrain.new(65003,
                                       BGP::Route_target.new('10.0.0.9', 7)))
    key2, = installed(router2)
    assert_equal('65003:10.0.0.9:7', key2, 'an IPv4-address-specific RT')
  end

  # Two prefixes in one attribute, which is what the framing is for: the
  # parse loop reads one length octet after another. **GoBGP holding both
  # is the only outside confirmation of that**, since the framing here is
  # the prefix arithmetic `nlri_size` already did and so has no arm of its
  # own to point at.
  def test_two_prefixes_in_one_attribute_both_arrive
    omit("rendering measured on GoBGP #{MEASURED_MAJOR}") unless measured?
    n, router = session
    announce(n, BGP::Rt_constrain.new(65001, [65001, 200]),
             BGP::Rt_constrain.new(65004, [65004, 400]))

    rib = nil
    assert(wait_for { rib = router.rib_family(G::RTC) ; rib && rib.size == 2 },
           'GoBGP to install both membership routes (waited 30s)')
    assert_equal(['65001:65001:200', '65004:65004:400'], rib.keys.sort)
  end

  # A withdrawal, over MP_UNREACH. The route installs, then goes.
  def test_a_withdrawal_removes_the_route
    n, router = session
    rtc = BGP::Rt_constrain.new(65001, [65001, 200])
    announce(n, rtc)
    installed(router)

    withdraw(n, rtc)
    assert(wait_for { (router.rib_family(G::RTC) || { 'x' => 1 }).empty? },
           'GoBGP to withdraw the membership route (waited 30s)')
    assert(n.is_established?, 'and the session stayed up')
  end

  # **GoBGP drops a partial prefix in silence**, which is a divergence
  # worth asserting rather than a hole in bgp4r.
  #
  # The 64-bit case is section 4's own motivating example: "a prefix would
  # encompass all route target extended communities assigned by a given
  # Global Administrator". The 32-bit case is the minimum the same section
  # names. GoBGP keeps the session up, logs nothing about either, and
  # installs neither, so the headline use of the family does not work on
  # 3.23.0.
  #
  # Recorded and not filed, per the standing decision that the job here is
  # bgp4r catching up. bgp4r sends what section 4 describes; what the
  # router does with it is the router's.
  def test_a_partial_prefix_is_dropped_in_silence
    omit("measured on GoBGP #{MEASURED_MAJOR}") unless measured?
    [[BGP::Rt_constrain.new(65000), '32 bits, the origin AS alone'],
     [BGP::Rt_constrain.new(65000, [65000, 100], 64),
      "64 bits, section 4's Global Administrator prefix"]].each do |rtc, what|
      n, router = session
      announce(n, rtc)
      # Nothing to wait for, so give it the same settle the other cases
      # take before reading the RIB.
      sleep 3
      assert_equal({}, router.rib_family(G::RTC),
                   "GoBGP installed nothing for #{what}")
      assert(n.is_established?, "and kept the session up for #{what}")
    end
  end

  # **GoBGP reads the prefix as `mlen / 8` octets, flooring, where RFC
  # 4684 section 4 points at the RFC 4760 encoding, which rounds up.**
  # Measured on 2026-10-31: a prefix declaring 96, 97 or 103 bits over
  # the same 12 octets reads back as the same membership route, because
  # all three floor to 12.
  #
  # **That is why this file cannot vouch for our length octet**, and it
  # is worth stating because the flow spec lab tests can vouch for
  # theirs: FRR puts the section 4.1 length in the rule's own name, so an
  # off-by-one there fails 7 of 9 cases. Here an off-by-one is invisible,
  # proved by sabotage: writing `@mlen + 1` leaves every case in this
  # file passing, the two-prefix one included. The length is covered by
  # `test/functional/rt_constrain_test.rb` instead, where it is caught by
  # the cases carrying more than one NLRI.
  #
  # The lengths section 4 actually produces are 0, 32, 64 and 96, all
  # multiples of 8, so flooring and rounding up agree on every
  # conformant prefix and this is reachable only by sending one no RFC
  # describes. Which is what bgp4r is for.
  def test_gobgp_floors_the_prefix_length_where_the_rfc_rounds_up
    omit("measured on GoBGP #{MEASURED_MAJOR}") unless measured?
    # Built from wire bytes so the library is not asked to write a length
    # that disagrees with its own value: 12 octets under a declared 103
    # bits, which would need 13 if rounded up and needs 12 floored.
    octets = ['67' + '0000fde90002fde9000000c8'].pack('H*')
    lying = BGP::Rt_constrain.new(octets.is_packed)
    assert_equal(103, lying.mlen, 'the length octet says 103')
    assert_equal(12, lying.encode.size - 1, 'over 12 octets of value')

    n, router = session
    announce(n, lying)
    key, = installed(router)
    assert_equal('65001:65001:200', key,
                 'read as the 96-bit route, so 103 floored to 12 octets')
    assert(n.is_established?, 'and the session stayed up')
  end

  # **A second GoBGP 3.23.0 crash, and this one a missing bounds check.**
  # A prefix whose length demands more octets than the NLRI holds panics
  # the daemon: 104 bits floors to 13 where only 12 are there. 103 is
  # fine, by the case above, so the boundary is exactly where the floored
  # byte count passes what arrived.
  #
  # Unlike the crash below this one needs a malformed NLRI, so it is
  # ordinary negative testing and bgp4r is doing its job: section 4 gives
  # 96 bits as the maximum, nothing validates on the way out per
  # Conventions, and a real router is watched handling it.
  #
  # Recorded, not filed, per the standing decision that the job here is
  # bgp4r catching up.
  def test_a_prefix_longer_than_its_octets_crashes_gobgp
    omit("crash measured on GoBGP #{MEASURED_MAJOR}") unless measured?
    octets = ['68' + '0000fde90002fde9000000c8'].pack('H*')
    lying = BGP::Rt_constrain.new(octets.is_packed)
    assert_equal(104, lying.mlen)

    n, router = session
    announce(n, lying)
    assert(wait_for { router.log.to_s.include?('panic:') },
           'GoBGP to panic on a prefix longer than its octets (waited 30s). ' \
           'If it did not, 3.23.0 has been fixed or the boundary has moved: ' \
           're-measure and rewrite this.')
  end

  # **GoBGP 3.23.0 crashes on a second membership route once the
  # zero-length default is in play**, deterministically, with a nil
  # pointer dereference in `propagateUpdate` and a SIGSEGV that takes the
  # daemon down. Found by this test being written, on 2026-10-31.
  #
  # Both routes bgp4r sends here are exactly what RFC 4684 describes, so
  # this is not negative testing: section 4 blesses the zero-length
  # default in so many words, and section 4's last paragraph makes it what
  # "a route reflector speaking to one of its PE router clients" sends.
  # Sending it and then one more membership route is the ordinary case.
  #
  # The trigger is narrower than any bad value, which is why it is stated
  # as a sequence. Measured: the default alone is fine, and two 96-bit
  # prefixes are fine, and a 32-bit prefix after the default is fine
  # because GoBGP drops it before it reaches that code. The default
  # followed by **any** membership route GoBGP accepts kills it, the
  # default sent twice included, and so does a 96-bit prefix followed by
  # the default.
  #
  # Asserted rather than left out, because a lab test that quietly avoids
  # the one sequence that breaks the router is the kind of unchecked claim
  # this project keeps getting burned by. If a later GoBGP fixes it this
  # case fails, which is the signal to re-measure and rewrite it.
  #
  # Recorded, not filed, per the standing decision above.
  def test_the_default_followed_by_a_second_route_crashes_gobgp
    omit("crash measured on GoBGP #{MEASURED_MAJOR}") unless measured?
    n, router = session
    announce(n, BGP::Rt_constrain.new)
    installed(router)

    announce(n, BGP::Rt_constrain.new(65001, [65001, 200]))
    assert(wait_for { router.log.to_s.include?('panic:') },
           'GoBGP to panic (waited 30s). If it did not, 3.23.0 has been ' \
           'fixed or the trigger has moved: re-measure and rewrite this.')
    assert_match(/nil pointer dereference|SIGSEGV/, router.log.to_s,
                 'and the panic is the nil pointer dereference measured')
    assert_match(/propagateUpdate/, router.log.to_s,
                 'in propagateUpdate, which is where it was measured')
  end

  private

  def measured?
    G.version.to_s[/\d+/].to_i == MEASURED_MAJOR
  end
end
