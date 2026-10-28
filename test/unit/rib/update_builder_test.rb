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
require 'bgp/rib'

# BGP:: names are written out in full here, see Conventions in CLAUDE.md.
class TestBgpRibUpdateBuilder < Test::Unit::TestCase

  B = BGP::Rib::UpdateBuilder

  def setup
    @builder = B.new
    @info = BGP::Update::Info.new(true)
  end

  def v4_attrs(as_path = [65001], next_hop = '10.0.0.1')
    BGP::Path_attribute.new(BGP::Origin.new(0), BGP::Next_hop.new(next_hop),
                            BGP::As_path.new(*as_path))
  end

  # Export strips NEXT_HOP for a family that carries it in MP_REACH_NLRI.
  def v6_attrs(as_path = [65001])
    BGP::Path_attribute.new(BGP::Origin.new(0), BGP::As_path.new(*as_path))
  end

  def announce(prefix, pa, next_hop = '10.0.0.1', path_id = nil)
    B::Announce.new(prefix, pa, next_hop, path_id)
  end

  def size_of(msg)
    msg.encode(@info).bytesize
  end

  def test_nothing_in_nothing_out
    assert_equal([], @builder.build)
    assert_equal([], @builder.build(:announce => [], :withdraw => []))
  end

  # The economy of BGP: one attribute set, many prefixes.
  def test_prefixes_sharing_attributes_travel_together
    pa = v4_attrs
    msgs = @builder.build(:announce => [announce('10.1.0.0/16', pa),
                                        announce('10.2.0.0/16', pa),
                                        announce('10.3.0.0/16', pa)])
    assert_equal(1, msgs.size)
    assert_equal(%w[10.1.0.0/16 10.2.0.0/16 10.3.0.0/16], msgs[0].nlri.to_ary)
  end

  def test_different_attributes_need_different_messages
    msgs = @builder.build(:announce => [announce('10.1.0.0/16', v4_attrs([65001])),
                                        announce('10.2.0.0/16', v4_attrs([65001, 65009]))])
    assert_equal(2, msgs.size)
    assert_equal([1, 1], msgs.map { |m| m.nlri.to_ary.size })
  end

  # Equal attributes built twice are still one group: the comparison is on
  # the encoded octets, not on object identity.
  def test_equal_attributes_built_separately_are_one_group
    msgs = @builder.build(:announce => [announce('10.1.0.0/16', v4_attrs),
                                        announce('10.2.0.0/16', v4_attrs)])
    assert_equal(1, msgs.size)
  end

  def test_a_different_next_hop_is_a_different_group
    msgs = @builder.build(:announce => [announce('2011:1::/32', v6_attrs, '2011:9::1'),
                                        announce('2011:2::/32', v6_attrs, '2011:9::2')])
    assert_equal(2, msgs.size)
  end

  # The same order PeerAdapter applies a received UPDATE in, so a prefix in
  # both ends up announced.
  def test_withdrawals_come_before_announcements
    msgs = @builder.build(:announce => [announce('10.1.0.0/16', v4_attrs)],
                          :withdraw => [B::Withdraw.new('10.9.0.0/16')])
    assert_equal([:withdraw, :announce], msgs.map { |m| m.withdrawn ? :withdraw : :announce })
  end

  # RFC 4271 section 4.3: the Withdrawn Routes and NLRI fields, IPv4 only.
  def test_ipv4_uses_the_section_4_3_fields
    msgs = @builder.build(:announce => [announce('10.1.0.0/16', v4_attrs)],
                          :withdraw => [B::Withdraw.new('10.9.0.0/16')])
    w, a = msgs
    assert_equal(['10.9.0.0/16'], w.withdrawn.to_ary)
    assert(!w.path_attribute, 'a withdrawal carries no attributes')
    assert_equal(['10.1.0.0/16'], a.nlri.to_ary)
    assert_equal('10.0.0.1', a.path_attribute[BGP::Next_hop].next_hop)
  end

  # RFC 4760 section 3: the next hop travels inside MP_REACH_NLRI, so
  # NEXT_HOP has no place in the message.
  def test_ipv6_goes_in_mp_reach_with_the_next_hop_inside
    msgs = @builder.build(:announce => [announce('2011:1::/32', v6_attrs, '2011:9::1')])
    assert_equal(1, msgs.size)
    pa = msgs[0].path_attribute
    assert(pa.has?(BGP::Mp_reach))
    assert(!pa.has?(BGP::Next_hop), 'NEXT_HOP would be the wrong family here')
    assert_equal('2011:9::1', pa[BGP::Mp_reach].nexthops)
    assert_equal(2, pa[BGP::Mp_reach].afi)
    assert_nil(msgs[0].nlri, 'and nothing in the section 4.3 field')
  end

  # RFC 4760 section 4.
  def test_ipv6_withdrawals_go_in_mp_unreach
    msgs = @builder.build(:withdraw => [B::Withdraw.new('2011:1::/32')])
    assert_equal(1, msgs.size)
    assert(msgs[0].path_attribute.has?(BGP::Mp_unreach))
    assert_nil(msgs[0].withdrawn)
  end

  # A NEXT_HOP left on the attributes would be sent to the peer as an IPv4
  # next hop for an IPv6 route, so it is removed rather than trusted.
  def test_a_stray_next_hop_is_removed_for_an_mp_family
    pa = BGP::Path_attribute.new(BGP::Origin.new(0), BGP::As_path.new(65001),
                                 BGP::Next_hop.new('10.0.0.1'))
    msgs = @builder.build(:announce => [announce('2011:1::/32', pa, '2011:9::1')])
    assert(!msgs[0].path_attribute.has?(BGP::Next_hop))
  end

  def test_the_two_families_do_not_share_a_message
    msgs = @builder.build(:announce => [announce('10.1.0.0/16', v4_attrs),
                                        announce('2011:1::/32', v6_attrs, '2011:9::1')])
    assert_equal(2, msgs.size)
    assert_equal(1, msgs.count { |m| m.nlri })
    assert_equal(1, msgs.count { |m| m.path_attribute.has?(BGP::Mp_reach) })
  end

  # Add-path: the Path Identifier goes in front of each prefix (RFC 7911
  # section 3), in both fields.
  def test_path_identifiers_in_the_nlri_field
    msgs = @builder.build(:announce => [announce('10.1.0.0/16', v4_attrs, '10.0.0.1', 7)])
    assert_equal(['ID=7, 10.1.0.0/16'], msgs[0].nlri.to_ary)
  end

  def test_path_identifiers_in_a_withdrawal
    msgs = @builder.build(:withdraw => [B::Withdraw.new('10.1.0.0/16', 7)])
    assert_equal(['ID=7, 10.1.0.0/16'], msgs[0].withdrawn.to_ary)
  end

  def test_path_identifiers_in_mp_reach
    msgs = @builder.build(:announce => [announce('2011:1::/32', v6_attrs, '2011:9::1', 7)])
    mp = msgs[0].path_attribute[BGP::Mp_reach]
    assert_equal(7, mp.nlris.first.path_id)
  end

  def test_two_paths_to_one_prefix_in_one_message
    pa = v4_attrs
    msgs = @builder.build(:announce => [announce('10.1.0.0/16', pa, '10.0.0.1', 7),
                                        announce('10.1.0.0/16', pa, '10.0.0.1', 9)])
    assert_equal(1, msgs.size)
    assert_equal(['ID=7, 10.1.0.0/16', 'ID=9, 10.1.0.0/16'], msgs[0].nlri.to_ary)
  end

  # RFC 4271 section 4: "The maximum message size is 4096 octets." A batch
  # too big for one message is split, and nothing is lost in the splitting.
  def test_a_large_batch_is_split_and_every_prefix_survives
    pa = v4_attrs
    wanted = (0...4000).map { |i| "10.#{i / 256}.#{i % 256}.1/32" }
    msgs = @builder.build(:announce => wanted.map { |p| announce(p, pa) })
    assert(msgs.size > 1, 'it had to be split')
    assert(msgs.map { |m| size_of(m) }.max <= B::MAX_MESSAGE_SIZE,
           "largest message #{msgs.map { |m| size_of(m) }.max}")
    assert_equal(wanted, msgs.flat_map { |m| m.nlri.to_ary })
  end

  def test_a_large_withdrawal_batch_is_split_too
    wanted = (0...4000).map { |i| "10.#{i / 256}.#{i % 256}.1/32" }
    msgs = @builder.build(:withdraw => wanted.map { |p| B::Withdraw.new(p) })
    assert(msgs.size > 1)
    assert(msgs.map { |m| size_of(m) }.max <= B::MAX_MESSAGE_SIZE)
    assert_equal(wanted, msgs.flat_map { |m| m.withdrawn.to_ary })
  end

  def test_an_mp_batch_is_split_too
    pa = v6_attrs
    wanted = (0...2000).map { |i| "2011:#{format('%x', i)}::/32" }
    msgs = @builder.build(:announce => wanted.map { |p| announce(p, pa, '2011:9::1') })
    assert(msgs.size > 1)
    assert(msgs.map { |m| size_of(m) }.max <= B::MAX_MESSAGE_SIZE)
    assert_equal(wanted.size, msgs.sum { |m| m.path_attribute[BGP::Mp_reach].nlris.size })
  end

  # Path Identifiers cost 4 octets each, so the same prefixes need more
  # messages with add-path than without.
  def test_path_identifiers_cost_room
    pa = v4_attrs
    prefixes = (0...2000).map { |i| "10.#{i / 256}.#{i % 256}.1/32" }
    plain = @builder.build(:announce => prefixes.map { |p| announce(p, pa) })
    with_id = @builder.build(:announce => prefixes.map { |p| announce(p, pa, '10.0.0.1', 7) })
    assert(with_id.size > plain.size)
    assert(with_id.map { |m| size_of(m) }.max <= B::MAX_MESSAGE_SIZE)
  end

  def test_a_smaller_limit_splits_sooner
    pa = v4_attrs
    small = B.new(:max_size => 100)
    msgs = small.build(:announce => (0...40).map { |i| announce("10.0.#{i}.0/24", pa) })
    assert(msgs.size > 1)
    assert(msgs.map { |m| size_of(m) }.max <= 100)
    assert_equal(100, small.max_size)
  end

  # One prefix that cannot fit on its own is the only thing the arithmetic
  # cannot pack, so the final measurement raises rather than letting an
  # oversized message out.
  def test_a_message_that_cannot_fit_at_all_raises
    tiny = B.new(:max_size => 24)
    e = assert_raise(ArgumentError) { tiny.build(:announce => [announce('10.1.0.0/16', v4_attrs)]) }
    assert_match(/octet UPDATE/, e.message)
    assert_match(/RFC 4271 section 4/, e.message)
  end

  # Messages are sized the way the session will encode them. Without session
  # info the 4-octet AS form is assumed, which is the larger of the two, so
  # a message sized without it still fits when it is sent.
  def test_messages_are_sized_for_the_session
    pa = BGP::Path_attribute.new(BGP::Origin.new(0), BGP::Next_hop.new('10.0.0.1'),
                                 BGP::As_path.new(*(1..50).to_a))
    two_octet = B.new(:session_info => BGP::Update::Info.new(false))
    assert_equal(BGP::Update::Info, two_octet.session_info.class)
    msgs = two_octet.build(:announce => [announce('10.1.0.0/16', pa)])
    assert(msgs[0].encode(BGP::Update::Info.new(false)).bytesize <
           msgs[0].encode(@info).bytesize, 'the 2-octet form is the smaller')
  end

  # Each message owns its attributes, so nothing built here shares a mutable
  # attribute set with the caller or with another message.
  def test_a_message_does_not_share_attributes_with_the_caller
    pa = v4_attrs
    msgs = @builder.build(:announce => [announce('10.1.0.0/16', pa)])
    assert_not_same(pa, msgs[0].path_attribute)
    msgs[0].path_attribute.delete(BGP::Origin)
    assert(pa.has?(BGP::Origin), 'the caller still has its own')
  end

  def test_two_messages_from_one_group_do_not_share_attributes
    pa = v4_attrs
    msgs = @builder.build(:announce => (0...4000).map { |i| announce("10.#{i / 256}.#{i % 256}.1/32", pa) })
    assert(msgs.size > 1)
    assert_not_same(msgs[0].path_attribute, msgs[1].path_attribute)
  end

  def test_the_family_of_a_prefix
    assert_equal([1, 1], B.family('10.0.0.0/8'))
    assert_equal([2, 1], B.family('2011:1::/32'))
  end

  # A /0 takes its length octet and no prefix octet (RFC 4271 section 4.3),
  # which is the cheapest prefix there is, and a /32 the dearest in IPv4.
  def test_the_default_route_and_a_host_route_both_build
    pa = v4_attrs
    msgs = @builder.build(:announce => [announce('0.0.0.0/0', pa), announce('10.1.2.3/32', pa)])
    assert_equal(1, msgs.size)
    assert_equal(['0.0.0.0/0', '10.1.2.3/32'], msgs[0].nlri.to_ary)
  end

  # Every message this builds must parse back to what went in, which is the
  # round trip rule the rest of the library follows.
  def test_every_message_parses_back
    pa = v4_attrs
    msgs = @builder.build(:announce => [announce('10.1.0.0/16', pa), announce('10.2.0.0/16', pa),
                                        announce('2011:1::/32', v6_attrs, '2011:9::1')],
                          :withdraw => [B::Withdraw.new('10.9.0.0/16'),
                                        B::Withdraw.new('2011:9::/32')])
    assert_equal(4, msgs.size)
    msgs.each do |m|
      back = BGP::Message.factory(m.encode(@info), @info)
      assert_kind_of(BGP::Update, back)
      assert_equal(m.encode(@info), back.encode(@info), "#{m.class} did not round trip")
    end
  end

  # The 4096 octet limit is RFC 4271 section 4 and belongs to a BGP
  # message, so it is defined once on BGP::Message and read from there.
  # This file used to carry its own copy of the number, which is how one of
  # two copies goes stale.
  def test_the_message_limit_comes_from_bgp_message
    assert_equal BGP::Message::MAX_SIZE, BGP::Rib::UpdateBuilder::MAX_MESSAGE_SIZE
    assert_equal BGP::Message::MAX_SIZE, BGP::Rib::UpdateBuilder.new.max_size
    # max_size is the per session override RFC 8654 would need.
    assert_equal 9000, BGP::Rib::UpdateBuilder.new(:max_size => 9000).max_size
  end

end
