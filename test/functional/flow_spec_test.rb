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

# A flow spec UPDATE over a real session, RFC 8955 and RFC 8956.
#
# **This is the only test that proves the four wiring sites agree with each
# other.** The unit tests drive each side on its own, because both are pure:
# one builds an attribute and reads its own octets back, the other hands
# `Nlri.factory` octets it wrote itself. Neither can tell you that what
# `Mp_reach#encode` puts on a socket is what `Mp_reach#parse` takes off it,
# and the two sites that can disagree are exactly the two this family
# changed: the length framing the parse loops use, and the gates that pick
# the class.
#
# The assertion that matters in every case is that the attribute arrives as
# an `Mp_reach` or `Mp_unreach` with components that read back. Before the
# wiring the same UPDATE crossed the socket intact and came back as an
# `Attr::Raw` with an `Attr::Gap`, which is #116 keeping octets it cannot
# interpret: the session stayed up and nothing looked wrong, so a test that
# only checked the session or the hex would have passed against the
# unwired library.
#
# BGP:: names are written out in full, see Conventions in CLAUDE.md. That
# includes the nested catcher, which does not see an include in the class
# around it, and which matters more here than usual: Neighbor logs an
# exception from an observer rather than raising it, so a wrong constant in
# one shows up as "nothing arrived" and says nothing about the name.
class FlowSpecSessionTest < Test::Unit::TestCase
  include BGP::TestHelpers

  SERVER_AS = 100
  CLIENT_AS = 200

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
  # catcher. One Mbgp capability carries one (AFI, SAFI) pair, so a pair
  # is one capability.
  def session(afi, safi)
    cap = BGP::OPT_PARM::CAP::Mbgp.new(afi, safi)
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

  # The rule of RFC 8955 section 4.3.1, destination 192.0.2.0/24 with
  # protocol 6 and port 25, which is the document's own worked example.
  def test_an_ipv4_flow_spec_rule_crosses_a_session
    catcher = session(1, 133)
    sent = BGP::Update.new(
      BGP::Path_attribute.new(
        BGP::Origin.new(0),
        BGP::As_path.new(CLIENT_AS),
        BGP::Mp_reach.new(
          :safi => 133,
          :nlris => [{ :destination_prefix => '192.0.2.0/24',
                       :ip_protocol => [[:eq, 6]],
                       :port => [[:eq, 25]] }])))
    @c.send_update sent

    got = catcher.shift
    assert_not_nil(got, 'the server parsed an UPDATE')
    assert_equal(sent.to_shex, got.to_shex, 'byte for byte across the socket')

    mpr = got.path_attribute.find(BGP::Mp_reach)
    assert_not_nil(mpr, 'an Mp_reach, not an Attr::Raw')
    assert_equal(0, got.path_attribute.errors.size, 'no protocol error')
    assert_equal(0, got.path_attribute.undecoded.size, 'and no coverage gap')

    assert_equal(1, mpr.afi)
    assert_equal(133, mpr.safi)
    assert_equal([BGP::Flow_spec], mpr.nlris.collect(&:class))
    rule = mpr.nlris.first
    assert_equal(3, rule.size, 'three components')
    assert_equal({ :destination_prefix => '192.0.2.0/24',
                   :ip_protocol => [[:eq, 6]],
                   :port => [[:eq, 25]] },
                 rule.to_hash)
  end

  # RFC 8956 section 3. The AFI decides what the shared type numbers mean,
  # and here it has to survive the socket for the components to read back:
  # type 7 is Icmp_type in an IPv4 rule and Icmp_type in an IPv6 one, but
  # type 3 is Ip_protocol against IPv4 and Upper_layer_protocol against
  # IPv6, so a rule parsed under the wrong AFI comes back with the wrong
  # keys rather than failing.
  def test_an_ipv6_flow_spec_rule_crosses_a_session
    catcher = session(2, 133)
    sent = BGP::Update.new(
      BGP::Path_attribute.new(
        BGP::Origin.new(0),
        BGP::As_path.new(CLIENT_AS),
        BGP::Mp_reach.new(
          :safi => 133,
          :nlris => [{ :destination_ipv6_prefix => { :prefix => '2001:db8::/32' },
                       :upper_layer_protocol => [[:eq, 6]] }])))
    @c.send_update sent

    got = catcher.shift
    assert_not_nil(got, 'the server parsed an UPDATE')
    assert_equal(sent.to_shex, got.to_shex)
    mpr = got.path_attribute.find(BGP::Mp_reach)
    assert_not_nil(mpr, 'an Mp_reach, not an Attr::Raw')
    assert_equal(2, mpr.afi, 'the AFI came off the wire')
    # no :offset key, because the class carries one only when it is not
    # 0, the same extra-key-only-when-unusual rule as :tail and :bits
    assert_equal({ :destination_ipv6_prefix => { :prefix => '2001:db8::/32' },
                   :upper_layer_protocol => [[:eq, 6]] },
                 mpr.nlris.first.to_hash)
  end

  # RFC 8955 section 8: SAFI 134 prepends an 8 octet Route Distinguisher,
  # and "The NLRI length field shall include both the 8 octets of the Route
  # Distinguisher as well as the subsequent Flow Specification NLRI value."
  # So this case is the one where the length framing and the RD have to
  # agree across the socket.
  def test_a_vpn_flow_spec_rule_crosses_a_session
    catcher = session(1, 134)
    sent = BGP::Update.new(
      BGP::Path_attribute.new(
        BGP::Origin.new(0),
        BGP::As_path.new(CLIENT_AS),
        BGP::Mp_reach.new(
          :safi => 134,
          :nlris => [{ :rd => [100, 200],
                       :destination_prefix => '192.0.2.0/24' }])))
    @c.send_update sent

    got = catcher.shift
    assert_not_nil(got, 'the server parsed an UPDATE')
    assert_equal(sent.to_shex, got.to_shex)
    mpr = got.path_attribute.find(BGP::Mp_reach)
    assert_not_nil(mpr, 'an Mp_reach, not an Attr::Raw')
    assert_equal(134, mpr.safi)
    rule = mpr.nlris.first
    assert_equal('RD=100:200 (0x64 0x00c8)', rule.rd.to_s)
    assert_equal('192.0.2.0/24', rule.components.first.prefix.to_s)
  end

  # Two rules in one attribute, which is what the length framing of section
  # 4.1 is for: the parse loop reads one length field after another, and
  # getting that wrong by one octet loses the second rule rather than
  # raising.
  def test_two_rules_in_one_update_cross_a_session
    catcher = session(1, 133)
    sent = BGP::Update.new(
      BGP::Path_attribute.new(
        BGP::Origin.new(0),
        BGP::As_path.new(CLIENT_AS),
        BGP::Mp_reach.new(
          :safi => 133,
          :nlris => [{ :destination_prefix => '192.0.2.0/24' },
                     { :source_prefix => '203.0.113.0/24',
                       :port => [[:eq, 80]] }])))
    @c.send_update sent

    got = catcher.shift
    assert_not_nil(got, 'the server parsed an UPDATE')
    assert_equal(sent.to_shex, got.to_shex)
    mpr = got.path_attribute.find(BGP::Mp_reach)
    assert_not_nil(mpr, 'an Mp_reach, not an Attr::Raw')
    assert_equal(2, mpr.nlris.size, 'both rules, so the framing agreed')
    assert_equal({ :destination_prefix => '192.0.2.0/24' },
                 mpr.nlris[0].to_hash)
    assert_equal({ :source_prefix => '203.0.113.0/24',
                   :port => [[:eq, 80]] },
                 mpr.nlris[1].to_hash)
  end

  # A withdrawal, which is the second parse loop: MP_UNREACH has its own
  # copy of the framing in mp_unreach.rb, so a fix to one does not fix the
  # other and this is what says so.
  def test_a_flow_spec_withdrawal_crosses_a_session
    catcher = session(1, 133)
    sent = BGP::Update.new(
      BGP::Path_attribute.new(
        BGP::Mp_unreach.new(
          :safi => 133,
          :nlris => [{ :destination_prefix => '192.0.2.0/24',
                       :ip_protocol => [[:eq, 6]],
                       :port => [[:eq, 25]] }])))
    @c.send_update sent

    got = catcher.shift
    assert_not_nil(got, 'the server parsed an UPDATE')
    assert_equal(sent.to_shex, got.to_shex)
    mpu = got.path_attribute.find(BGP::Mp_unreach)
    assert_not_nil(mpu, 'an Mp_unreach, not an Attr::Raw')
    assert_equal(0, got.path_attribute.undecoded.size, 'no coverage gap')
    assert_equal(133, mpu.safi)
    assert_equal({ :destination_prefix => '192.0.2.0/24',
                   :ip_protocol => [[:eq, 6]],
                   :port => [[:eq, 25]] },
                 mpu.nlris.first.to_hash)
  end

  # A rule with a traffic filtering action on it, RFC 8955 section 7. These
  # communities were implemented years before the NLRI they filter, so until
  # the wiring the two could not travel together.
  def test_a_rule_with_an_action_crosses_a_session
    catcher = session(1, 133)
    sent = BGP::Update.new(
      BGP::Path_attribute.new(
        BGP::Origin.new(0),
        BGP::As_path.new(CLIENT_AS),
        BGP::Extended_communities.new(
          BGP::Traffic_rate_bytes.new(0, 1_000_000.0)),
        BGP::Mp_reach.new(
          :safi => 133,
          :nlris => [{ :destination_prefix => '192.0.2.0/24' }])))
    @c.send_update sent

    got = catcher.shift
    assert_not_nil(got, 'the server parsed an UPDATE')
    assert_equal(sent.to_shex, got.to_shex)
    assert_equal(0, got.path_attribute.undecoded.size, 'no coverage gap')
    mpr = got.path_attribute.find(BGP::Mp_reach)
    assert_not_nil(mpr, 'an Mp_reach, not an Attr::Raw')
    assert_equal('192.0.2.0/24', mpr.nlris.first.components.first.prefix.to_s)
    ext = got.path_attribute.find(BGP::Extended_communities)
    assert_not_nil(ext, 'and the action came with it')
    assert_equal(1_000_000.0, ext.find(BGP::Traffic_rate_bytes).rate)
  end

  # Section 4.2: "Components MUST follow strict type ordering by increasing
  # numerical order." **That MUST binds a sender**, and bgp4r deviates from
  # it on purpose, because a test has to be able to put a rule no RFC allows
  # on the wire and watch a router decide. So this is the negative test the
  # library exists for, over a real session: out of order, a type twice, and
  # a type no RFC assigns.
  def test_a_rule_no_rfc_allows_crosses_a_session
    catcher = session(1, 133)
    rule = BGP::Flow_spec.new(
      BGP::Flow_spec::Port.new([:eq, 25]),
      BGP::Flow_spec::Destination_prefix.new('192.0.2.0/24'),
      BGP::Flow_spec::Port.new([:eq, 80]))
    sent = BGP::Update.new(
      BGP::Path_attribute.new(
        BGP::Origin.new(0),
        BGP::As_path.new(CLIENT_AS),
        BGP::Mp_reach.new(:safi => 133, :nlris => [rule])))
    @c.send_update sent

    got = catcher.shift
    assert_not_nil(got, 'the server parsed an UPDATE')
    assert_equal(sent.to_shex, got.to_shex, 'nothing normalised it')
    mpr = got.path_attribute.find(BGP::Mp_reach)
    assert_not_nil(mpr, 'an Mp_reach, not an Attr::Raw')
    back = mpr.nlris.first
    assert_equal(3, back.size, 'all three components survived')
    assert_equal([BGP::Flow_spec::Port,
                  BGP::Flow_spec::Destination_prefix,
                  BGP::Flow_spec::Port],
                 back.components.collect(&:class),
                 'in the order they were sent, out of order as that is')
  end
end
