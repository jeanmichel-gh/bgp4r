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
require 'test/helpers/server'

# A Route Target membership UPDATE over a real session, RFC 4684, AFI 1
# SAFI 132.
#
# **This is the only test that proves the wiring sites agree with each
# other**, for the reason flow_spec_test.rb and evpn_test.rb record: both
# sides are pure, so every unit test on the build side reads octets it
# wrote itself and every one on the parse side is handed octets the test
# wrote. Neither can say that what `Mp_reach#encode` puts on a socket is
# what `Mp_reach#parse` takes off it.
#
# **There are three sites here and not five**, which is what makes this
# family the cheapest of the four in phase 4. Flow spec and EVPN each
# needed an arm in `nlri_size`, because section 4.1 counts octets and RFC
# 7432 section 7 counts a body; RFC 4684 section 4 says its NLRI is "a
# prefix of 0 to 96 bits, encoded as defined in Section 4 of [5]", which
# is the prefix arithmetic `nlri_size` already did. So the sites are the
# two dispatch gates and the next hop.
#
# The assertion that matters in every case is that the attribute arrives
# as an `Mp_reach` or `Mp_unreach` whose NLRIs read back. Before the
# wiring the same UPDATE crossed the socket intact and came back as an
# `Attr::Raw` with an `Attr::Gap`, which is #116 keeping octets it cannot
# interpret: the session stayed up and nothing looked wrong, so a test
# that only checked the session or the hex would have passed against the
# unwired library.
#
# **Five sabotages, and the fourth is why this file has cases carrying
# more than one NLRI.** Deleting the parse gate's arm fails all 9;
# making the build gate's arm unreachable errors all 9; removing SAFI
# 132 from the next hop arm errors 8 and spares exactly the withdrawal,
# which carries no next hop, the same signature #185 measured for EVPN;
# and not skipping the AFI inference errors all 9.
#
# The framing is the one that is more forgiving here than in the other
# two families, so it needs saying. `nlri_size` off by one is caught by
# only 3 of the 9, and they are precisely the three that carry two or
# more NLRIs: the last NLRI in an attribute has nothing behind it to
# over-read into, so every single-prefix case passes against arithmetic
# that is wrong by a constant. Flow spec and EVPN both failed all their
# cases on the same slip, because their length fields sit inside a body
# the loop then re-reads. So do not thin the multi-prefix cases down to
# one: they are the only cover the framing has.
#
# BGP:: names are written out in full, see Conventions in CLAUDE.md. That
# includes the nested catcher, which does not see an include in the class
# around it, and which matters more here than usual: Neighbor logs an
# exception from an observer rather than raising it, so a wrong constant
# in one shows up as "nothing arrived" and says nothing about the name.
class RtConstrainSessionTest < Test::Unit::TestCase
  include BGP::TestHelpers

  SERVER_AS = 100
  CLIENT_AS = 200

  # RFC 4684 section 4: "The [AFI, SAFI] value pair used to identify this
  # NLRI is (AFI=1, SAFI=132)."
  AFI  = 1
  SAFI = 132

  # Queues the UPDATEs the server's Neighbor parsed.
  class UpdateCatcher
    def initialize
      @q = Queue.new
    end

    def update(msg)
      @q << msg if msg.is_a?(BGP::Update)
    end

    def size
      @q.size
    end

    # The next UPDATE, or nil after timeout seconds.
    def shift(timeout = 5)
      deadline = Time.now + timeout
      loop do
        return @q.shift if @q.size > 0
        return nil if Time.now > deadline
        sleep 0.02
      end
    end
  end

  def teardown
    @c.close if @c
    stop_server
  end

  # Brings up a session with the multiprotocol capability of RFC 4760,
  # advertised by both sides, and an observer on the server. Returns the
  # catcher. One Mbgp capability carries one (AFI, SAFI) pair.
  def session
    cap = BGP::OPT_PARM::CAP::Mbgp.new(AFI, SAFI)
    @port = start_server(0, cap)
    @catcher = UpdateCatcher.new
    @s.add_observer @catcher
    @c = BGP::Neighbor.new(4, CLIENT_AS, 180, '0.0.0.2', '127.0.0.1', '127.0.0.1')
    @c.add_cap cap
    @c.start :port => @port
    assert(wait_for { @s.is_established? }, 'the session came up')
    @catcher
  end

  def wait_for(timeout = 5)
    deadline = Time.now + timeout
    loop do
      return true if yield
      return false if Time.now > deadline
      sleep 0.02
    end
  end

  # Sends one UPDATE carrying the given attributes and returns what the
  # server parsed, with the two channels of #116 checked: errors means
  # what the peer got wrong, undecoded means a gap in bgp4r.
  #
  # errors defaults to 0 rather than being asserted zero inline, because
  # RFC 4684 names no malformed NLRI anywhere in its text, so every case
  # here expects none and a case that wants one has to say so.
  def crosses(sent, errors = 0)
    @c.send_update sent
    got = @catcher.shift
    assert_not_nil(got, 'the server parsed an UPDATE')
    assert_equal(sent.to_shex, got.to_shex, 'byte for byte across the socket')
    assert_equal(errors, got.path_attribute.errors.size,
                 "findings: #{got.path_attribute.errors.collect(&:reason).inspect}")
    assert_equal(0, got.path_attribute.undecoded.size, 'no coverage gap')
    got
  end

  def reach(nlris, nexthop = '10.0.0.1')
    BGP::Update.new(
      BGP::Path_attribute.new(
        BGP::Origin.new(0),
        BGP::As_path.new(CLIENT_AS),
        BGP::Mp_reach.new(:safi => SAFI, :nexthop => [nexthop],
                          :nlris => nlris)))
  end

  # The whole prefix of section 4's figure: an origin AS and a complete
  # route target, 96 bits, which section 4 gives as the maximum.
  def test_a_membership_prefix_crosses_a_session
    session
    got = crosses(reach([BGP::Rt_constrain.new(65000, [65000, 100])]))

    mpr = got.path_attribute.find(BGP::Mp_reach)
    assert_not_nil(mpr, 'an Mp_reach, not an Attr::Raw')
    assert_equal(AFI, mpr.afi)
    assert_equal(SAFI, mpr.safi)
    assert_equal([BGP::Rt_constrain], mpr.nlris.collect(&:class))

    rtc = mpr.nlris.first
    assert_equal(96, rtc.mlen)
    assert_equal(65000, rtc.origin_as, 'the origin AS read back')
    assert_equal('Route target: 65000:100', rtc.route_target.to_s,
                 'and the whole route target inside it')
    assert_equal({ :origin_as => 65000,
                   :route_target => { :route_target => [65000, 100] } },
                 rtc.to_hash)
  end

  # Section 4's default route target, a zero-length prefix. **This is the
  # framing edge of the family**: the NLRI is one octet, the length field
  # and nothing else, so an off-by-one in the arithmetic either eats the
  # next NLRI or reads a value that is not there.
  def test_the_zero_length_default_crosses_a_session
    session
    got = crosses(reach([BGP::Rt_constrain.new]))

    rtc = got.path_attribute.find(BGP::Mp_reach).nlris.first
    assert_instance_of(BGP::Rt_constrain, rtc)
    assert_equal(0, rtc.mlen)
    assert(rtc.default?, "section 4's default route target")
    assert_nil(rtc.origin_as, 'no origin AS to read out of no octets')
    assert_equal({ :mlen => 0 }, rtc.to_hash)
  end

  # Section 4's own motivating sentence: "a prefix would encompass all
  # route target extended communities assigned by a given Global
  # Administrator". A two-octet-AS route target is type, sub-type, a
  # 2-octet Global Administrator and a 4-octet Local Administrator (RFC
  # 4360 section 3.1), so that prefix is 64 bits and carries 4 of the
  # community's 8 octets.
  #
  # **So the family's headline use case is the one whose hash is the
  # length and the octets rather than the two fields**, because the route
  # target in it is half absent and a class that decoded one anyway would
  # invent the other half. That is part 1's decision showing through, and
  # it is asserted here rather than left to look like a defect.
  def test_a_global_administrator_prefix_crosses_a_session
    session
    got = crosses(reach([BGP::Rt_constrain.new(65000, [65000, 100], 64)]))

    rtc = got.path_attribute.find(BGP::Mp_reach).nlris.first
    assert_equal(64, rtc.mlen)
    assert_equal(65000, rtc.origin_as, 'the origin AS is whole, so it reads')
    assert_nil(rtc.route_target, 'the route target is not, so it does not')
    assert_equal({ :mlen => 64, :value => '0000fde80002fde8' }, rtc.to_hash)
  end

  # Four prefixes of four different lengths in one attribute, which is
  # what the framing is for: the parse loop reads one length octet after
  # another, and getting that wrong loses the prefixes behind it rather
  # than raising. Mixed lengths on purpose, since equal ones would pass
  # against arithmetic that was wrong by a constant.
  def test_several_prefixes_in_one_update_cross_a_session
    session
    got = crosses(reach([BGP::Rt_constrain.new,
                         BGP::Rt_constrain.new(65000),
                         BGP::Rt_constrain.new(65000, [65000, 100], 64),
                         BGP::Rt_constrain.new(65001, [65001, 200])]))

    mpr = got.path_attribute.find(BGP::Mp_reach)
    assert_not_nil(mpr, 'an Mp_reach, not an Attr::Raw')
    assert_equal(4, mpr.nlris.size, 'all four, so the framing agreed')
    assert_equal([0, 32, 64, 96], mpr.nlris.collect(&:mlen))
    assert_equal([nil, 65000, 65000, 65001], mpr.nlris.collect(&:origin_as))
    assert_equal('Route target: 65001:200', mpr.nlris.last.route_target.to_s)
  end

  # A withdrawal, which is the second parse loop: MP_UNREACH has its own
  # copy of the framing in mp_unreach.rb, so a fix to one does not fix the
  # other and this is what says so. Flow spec and EVPN each measured the
  # same signature, where reverting only that loop fails exactly this one
  # case.
  def test_a_membership_withdrawal_crosses_a_session
    session
    sent = BGP::Update.new(
      BGP::Path_attribute.new(
        BGP::Mp_unreach.new(:safi => SAFI,
                            :nlris => [BGP::Rt_constrain.new(65000, [65000, 100]),
                                       BGP::Rt_constrain.new])))
    got = crosses(sent)

    mpu = got.path_attribute.find(BGP::Mp_unreach)
    assert_not_nil(mpu, 'an Mp_unreach, not an Attr::Raw')
    assert_equal(AFI, mpu.afi)
    assert_equal(SAFI, mpu.safi)
    assert_equal(2, mpu.nlris.size)
    assert_equal([96, 0], mpu.nlris.collect(&:mlen))
    assert_equal('Route target: 65000:100', mpu.nlris.first.route_target.to_s)
  end

  # **The next hop, and the case that is unique to this family.** Section
  # 4: the field "shall be interpreted as an IPv4 address whenever the
  # length of NextHop address is 4 octets, and as a IPv6 address whenever
  # the length of the NextHop address is 16 octets."
  #
  # The AFI here is 1, so without its own arm the by-AFI case in
  # parse_next_hops reads every next hop as IPv4 and a 16-octet field as
  # four of them. Nothing else in the library has that shape: EVPN reads
  # by length too, but because its AFI is 25 and cannot say, where this
  # one could say and the RFC says to use the length anyway. So this is
  # the assertion that the length rule is RFC 4684's and not RFC 8950
  # arriving at the same answer, since ipv6_nexthop_length? answers false
  # for SAFI 132.
  def test_an_ipv6_next_hop_under_afi_1_crosses_a_session
    session
    got = crosses(reach([BGP::Rt_constrain.new(65000, [65000, 100])],
                        '2001:db8::1'))

    mpr = got.path_attribute.find(BGP::Mp_reach)
    assert_not_nil(mpr, 'an Mp_reach, not an Attr::Raw')
    assert_equal(AFI, mpr.afi, 'still AFI 1, which is the whole point')
    # Mp_reach#nexthops joins them with ", ", so one address and no comma
    # is the assertion that the 16 octets were read as one IPv6 next hop
    # and not as four IPv4 ones.
    assert_equal('2001:db8::1', mpr.nexthops,
                 'one IPv6 next hop, not four IPv4 ones')
    assert_equal(96, mpr.nlris.first.mlen, 'and the NLRI behind it still read')
  end

  # The IPv4 half of the same sentence, so the two are asserted together
  # rather than one standing in for the other.
  def test_an_ipv4_next_hop_crosses_a_session
    session
    got = crosses(reach([BGP::Rt_constrain.new(65000)], '10.0.0.1'))

    mpr = got.path_attribute.find(BGP::Mp_reach)
    assert_equal('10.0.0.1', mpr.nexthops)
    assert_equal(32, mpr.nlris.first.mlen)
  end

  # **Nothing validates, per Conventions, and this is that over a real
  # session.** Section 4 gives 32 bits as the minimum, "as the origin-as
  # field cannot be interpreted as a prefix", and 96 as the maximum. Both
  # are deviated from here on purpose, because a test has to be able to
  # put a prefix no RFC allows on the wire and watch a router decide.
  #
  # **And nothing reports it, which is the honest answer rather than a
  # hole.** RFC 4684 says nothing about a malformed NLRI anywhere in its
  # text, measured by reading it, so what a receiver should answer with is
  # not this RFC's to give and bgp4r does not invent one. That is the RFC
  # 7432 and RFC 9572 situation again, not the RFC 8955 one, where
  # section 4.2 calls an unknown component type malformed in so many
  # words and validation.rb reports it.
  def test_a_prefix_no_rfc_allows_crosses_a_session
    session
    got = crosses(reach([BGP::Rt_constrain.new(65000, nil, 16),
                         BGP::Rt_constrain.new(65000, [65000, 100], 200)]))

    mpr = got.path_attribute.find(BGP::Mp_reach)
    assert_not_nil(mpr, 'an Mp_reach, not an Attr::Raw')
    assert_equal(2, mpr.nlris.size, 'both, so the framing held either side')
    assert_equal([16, 200], mpr.nlris.collect(&:mlen),
                 'the lengths arrived as written, below and above section 4')
    # crosses already asserted no finding and no gap. Said again here
    # because it is this case's subject rather than its background.
    assert_equal(0, got.path_attribute.errors.size,
                 'no finding, because RFC 4684 gives no verdict to report')
    assert(@s.is_established?, 'and the session stayed up')
  end

  # The Path Identifier of RFC 7911 section 3, which the parse loop reads
  # off the front of each NLRI before the family sees it. Nothing else
  # carries one into this family, and getting it wrong shifts every length
  # octet by four.
  def test_a_path_identifier_crosses_a_session
    cap = BGP::OPT_PARM::CAP::Mbgp.new(AFI, SAFI)
    # (send_recv, afi, safi), which is what CAP::Add_path#add takes. Three
    # arguments and not an Array: one Array argument falls to the bare
    # raise in initialize, which is how this was found.
    add_path = BGP::OPT_PARM::CAP::Add_path.new(:send_and_receive, AFI, SAFI)
    # start_server takes one capability, so the second goes on afterwards.
    # Both sides need both, and a Neighbor reads its capabilities when it
    # builds the OPEN rather than when it is constructed, so adding one
    # before the client connects is in time.
    @port = start_server(0, cap)
    @s.add_cap add_path
    @catcher = UpdateCatcher.new
    @s.add_observer @catcher
    @c = BGP::Neighbor.new(4, CLIENT_AS, 180, '0.0.0.2', '127.0.0.1', '127.0.0.1')
    @c.add_cap cap
    @c.add_cap add_path
    @c.start :port => @port
    assert(wait_for { @s.is_established? }, 'the session came up')

    one = BGP::Rt_constrain.new(65000, [65000, 100])
    one.path_id = 7
    got = crosses(reach([one]))

    mpr = got.path_attribute.find(BGP::Mp_reach)
    assert_not_nil(mpr, 'an Mp_reach, not an Attr::Raw')
    assert_equal(7, mpr.nlris.first.path_id, 'the Path Identifier read back')
    assert_equal(96, mpr.nlris.first.mlen, 'and the length octet behind it')
  end
end
