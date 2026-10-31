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

# The EVPN NLRI framing of RFC 7432 section 7.
#
#   ruby -I. test/unit/nlris/evpn_test.rb
#
# Every hex string here was produced by the library and read back before
# it was pasted, for the reason evpn_route_test.rb gives.
#
# See docs/evpn.md, whose claims test/unit/evpn_doc_test.rb asserts.
#
# BGP:: names are written out in full, see Conventions in CLAUDE.md.

require 'test/unit'
require 'bgp/nlris/evpn'

class EvpnTest < Test::Unit::TestCase

  def wire(hex)
    [hex].pack('H*').is_packed
  end

  # A route type no part has implemented yet, which is every one of them
  # in this part, so the framing can be exercised on its own.
  def unknown(type = 9, hex = '0011223344556677')
    BGP::Evpn::Unknown.new(type, wire(hex))
  end

  # RFC 7432 section 7: Route Type (1 octet), Length (1 octet), Route
  # Type specific (variable).
  def test_the_framing_is_a_type_octet_a_length_octet_and_a_body
    n = BGP::Evpn.new(unknown)
    assert_equal('09080011223344556677', n.to_shex)
    assert_equal(9, n.type)
    assert_equal(8, n.length, 'the Length counts the body alone')
    assert_equal(10, n.size)
  end

  def test_an_nlri_builds_four_ways
    n = BGP::Evpn.new(unknown)
    want = n.to_shex
    assert_equal(want, BGP::Evpn.new(n.encode.is_packed).to_shex)
    assert_equal(want, BGP::Evpn.new(n.to_hash).to_shex)
    assert_equal(want, BGP::Evpn.new(n).to_shex)
  end

  # What the two parse loops need in place of the prefix families'
  # `(blen+7)/8+1`. It counts the two framing octets, so a caller can
  # slice exactly one NLRI off.
  def test_nlri_size_counts_the_framing
    assert_equal(10, BGP::Evpn.nlri_size(wire('09080011223344556677')))
    assert_equal(2, BGP::Evpn.nlri_size(wire('0900')))
    assert_equal(257, BGP::Evpn.nlri_size(wire('09ff')))
  end

  # nil rather than a guess, so a loop can stop and let the leftover
  # raise, which is how an attribute bgp4r cannot read still becomes an
  # Attr::Raw with an Attr::Gap. The flow spec wiring relies on the same
  # contract from Flow_spec.nlri_size.
  def test_nlri_size_answers_nil_for_octets_too_short_to_frame
    assert_nil(BGP::Evpn.nlri_size(nil))
    assert_nil(BGP::Evpn.nlri_size(wire('')))
    assert_nil(BGP::Evpn.nlri_size(wire('09')))
  end

  # It reads the length from the octets and never from the body, so a
  # Length that lies is reported as it arrived.
  def test_nlri_size_reads_the_declared_length_not_the_real_one
    assert_equal(22, BGP::Evpn.nlri_size(wire('09140011223344556677')),
                 'a Length of 0x14 with 8 octets behind it still answers 22')
  end

  # Several NLRIs sit one after another in the attribute, which is where
  # this differs from a flow spec NLRI holding a list under one length.
  def test_consecutive_nlris_are_sliced_by_their_own_lengths
    s = wire('0902aabb' + '0a03ccddee')
    first = BGP::Evpn.nlri_size(s)
    assert_equal(4, first)
    a = BGP::Evpn.new(s.byteslice(0, first).is_packed)
    rest = s.byteslice(first, s.size - first).is_packed
    assert_equal(5, BGP::Evpn.nlri_size(rest))
    b = BGP::Evpn.new(rest)
    assert_equal([9, 10], [a.type, b.type])
    assert_equal(['aabb', 'ccddee'], [a.route.value.unpack1('H*'),
                                      b.route.value.unpack1('H*')])
  end

  # A Length that disagrees with the octets that came with it is kept
  # and written back, so a malformed capture replays byte for byte.
  # Conventions: building and encoding never validate.
  def test_a_length_that_lies_is_kept_and_echoed
    n = BGP::Evpn.new(wire('09140011223344556677'))
    assert_equal(20, n.declared_len)
    assert_equal(8, n.route.value.size, 'it took what was there')
    assert_equal('09140011223344556677', n.to_shex)
    assert_equal(20, n.length)
  end

  def test_an_honest_length_keeps_no_declared_length
    n = BGP::Evpn.new(wire('09080011223344556677'))
    assert_nil(n.declared_len)
    assert_equal(8, n.length)
    assert_equal({ :unknown => { :type => 9,
                                 :value => '0011223344556677' } }, n.to_hash)
  end

  # A kept Length rides in the hash as one more key, which is the
  # extra-key-only-when-unusual rule the library already uses for :tail
  # and :bits. No lie, no key, so an ordinary NLRI hashes as it would
  # have without this.
  def test_a_kept_length_round_trips_through_the_hash
    n = BGP::Evpn.new(wire('09140011223344556677'))
    assert_equal(20, n.to_hash[:length])
    assert_equal(n.to_shex, BGP::Evpn.new(n.to_hash).to_shex)
    refute(BGP::Evpn.new(unknown).to_hash.has_key?(:length))
  end

  # An unimplemented route type reads back whole. A two octet body is
  # not a layout any registered type can represent, so a registered one
  # falls back to Unknown and an unregistered one was never going to be
  # anything else. Either way the octets replay, which is the point.
  #
  # The registry list moves with each part that adds a route type, and
  # `test/unit/evpn_doc_test.rb` is what keeps it honest: it discovers
  # the classes the library defines rather than listing them.
  def test_an_unimplemented_route_type_reads_back_whole
    assert_equal((1..11).to_a, BGP::Evpn::ROUTES.keys.sort)
    (1..11).each do |t|
      n = BGP::Evpn.new(wire('%02x02aabb' % t))
      assert_instance_of(BGP::Evpn::Unknown, n.route)
      assert_equal(t, n.type)
      assert_equal('%02x02aabb' % t, n.to_shex)
    end
  end

  # A body a registered route type can read resolves to that class.
  def test_a_whole_body_resolves_to_its_route_type
    n = BGP::Evpn.new(wire('0119' \
                           '00000064000000c80011223344556677889900000064001f41'))
    assert_instance_of(BGP::Evpn::Ethernet_ad, n.route)
    assert_equal(1, n.type)
    assert_equal(100, n.route.ethernet_tag_id.value)
    assert_equal(500, n.route.label.label)
    assert_nil(n.declared_len)

    m = BGP::Evpn.new(wire('0417' \
                           '00000064000000c80011223344556677889920c0000201'))
    assert_instance_of(BGP::Evpn::Ethernet_segment, m.route)
    assert_equal('192.0.2.1', m.route.ip.address)

    # Route type 2 with an IPv4 address and both labels, 40 octets.
    t2 = BGP::Evpn.new(wire('0228' + '00000064000000c8' +
                            '00112233445566778899' + '00000064' +
                            '30' + '001122334455' + '20' + 'c0000201' +
                            '001f41' + '001f51'))
    assert_instance_of(BGP::Evpn::Mac_ip_advertisement, t2.route)
    assert_equal('00:11:22:33:44:55', t2.route.mac.to_s)
    assert_equal('192.0.2.1', t2.route.ip.address)
    assert_equal([500, 501], [t2.route.label1.label, t2.route.label2.label])

    t3 = BGP::Evpn.new(wire('0311' + '00000064000000c8' + '00000064' +
                            '20' + 'c0000201'))
    assert_instance_of(BGP::Evpn::Inclusive_multicast, t3.route)
    assert_equal('192.0.2.1', t3.route.ip.address)

    # Route type 5, the IPv4 form: body 34 octets, so Length 0x22.
    t5 = BGP::Evpn.new(wire('0522' + '00000064000000c8' +
                            '00000000000000000000' + '00000064' +
                            '08' + '0a000000' + '0a000001' + '001f41'))
    assert_instance_of(BGP::Evpn::Ip_prefix_route, t5.route)
    assert_equal('10.0.0.0/8', t5.route.ip_prefix)
    assert_equal('10.0.0.1', t5.route.gateway)
    assert_equal(500, t5.route.label.label)
  end

  # Route type 5 is the one layout with no in-band discriminator: the
  # body's own size, 34 or 58, says which family. A body that is
  # neither reproduces nothing and falls back to Unknown, replaying it.
  def test_route_type_5_reads_its_family_from_the_body_size
    v6 = BGP::Evpn.new(wire('053a' + '00000064000000c8' +
                            '00000000000000000000' + '00000064' + '20' +
                            '20010db8' + '00' * 12 +
                            '20010db8' + '00' * 11 + '01' + '001f41'))
    assert_instance_of(BGP::Evpn::Ip_prefix_route, v6.route)
    assert(v6.route.v6?)
    assert_equal('2001:db8::/32', v6.route.ip_prefix)

    odd = '00' * 32
    n = BGP::Evpn.new(wire('0520' + odd))
    assert_instance_of(BGP::Evpn::Unknown, n.route,
                       'a 32 octet body is neither 34 nor 58')
    assert_equal('0520' + odd, n.to_shex)
  end

  # Route type 2 is the one layout whose optional trailing field is
  # decided by what is left, which only works because the body is
  # bounded: Evpn slices exactly Length octets and hands them down.
  # One label, 37 octets; two, 40.
  def test_route_type_2_reads_its_second_label_from_what_is_left
    body = '00000064000000c8' + '00112233445566778899' + '00000064' +
           '30' + '001122334455' + '20' + 'c0000201' + '001f41'
    one = BGP::Evpn.new(wire('0225' + body))
    assert_instance_of(BGP::Evpn::Mac_ip_advertisement, one.route)
    assert_nil(one.route.label2)
    assert_equal('0225' + body, one.to_shex)

    two = BGP::Evpn.new(wire('0228' + body + '001f51'))
    assert_equal(501, two.route.label2.label)
    assert_equal('0228' + body + '001f51', two.to_shex)
  end

  # Two octets left over are not a Label2 and not an error at this
  # level: encode cannot reproduce the body, so the NLRI falls back to
  # Unknown and the octets replay.
  def test_two_octets_left_over_are_not_a_second_label
    body = '00000064000000c8' + '00112233445566778899' + '00000064' +
           '30' + '001122334455' + '20' + 'c0000201' + '001f41' + '0000'
    n = BGP::Evpn.new(wire('0227' + body))
    assert_instance_of(BGP::Evpn::Unknown, n.route)
    assert_equal('0227' + body, n.to_shex)
  end

  # **A route type is kept only if it can give its own octets back.**
  # Both layouts are fixed width and nothing in the framing guarantees
  # the Length agrees, so a short or long body falls back to Unknown
  # rather than inventing the fields it did not find. Same rule
  # Flow_spec applies to its components.
  def test_a_body_the_route_type_cannot_reproduce_falls_back_to_unknown
    short = '00000064000000c8001122334455667788990000006400'
    n = BGP::Evpn.new(wire('0118' + short))
    assert_instance_of(BGP::Evpn::Unknown, n.route,
                       'a 23 octet body is not a 25 octet route type 1')
    assert_equal('0118' + short, n.to_shex)
    assert_equal(24, n.declared_len)

    long = '00000064000000c80011223344556677889900000064001f41ff'
    m = BGP::Evpn.new(wire('011a' + long))
    assert_instance_of(BGP::Evpn::Unknown, m.route)
    assert_equal('011a' + long, m.to_shex,
                 'the extra octet replays rather than being dropped')
  end

  # And a route type 4 whose address length is not 32 or 128 still
  # resolves, because its own encode does reproduce those octets. So the
  # fallback is about what the class can represent, not about what the
  # RFC allows.
  def test_an_address_length_no_rfc_allows_still_resolves
    # 0416, then RD (8), ESI (10), a length octet of 24, three octets.
    n = BGP::Evpn.new(wire('0416' + '00000064000000c8' +
                           '00000000000000000000' + '18' + 'c00002'))
    assert_instance_of(BGP::Evpn::Ethernet_segment, n.route)
    assert_equal(24, n.route.ip.bitlen)
    assert_nil(n.route.ip.address, 'three octets are not a family')
  end

  # RFC 7911 section 3 prepends a Path Identifier to the NLRI.
  def test_a_path_identifier_prepends_four_octets
    n = BGP::Evpn.new_ntop(BGP::Evpn.new(unknown).encode, 7)
    assert(n.extended?)
    assert_equal('0000000709080011223344556677', n.to_shex)
    assert_equal(14, n.size)
    assert_equal(7, n.to_hash[:path_id])
    assert_equal(n.to_shex, BGP::Evpn.new(n.to_hash).to_shex)
  end

  def test_an_nlri_without_a_path_identifier_is_not_extended
    n = BGP::Evpn.new(unknown)
    refute(n.extended?)
    refute(n.to_hash.has_key?(:path_id))
  end

  # Nothing validates. A route type number the registry does not assign,
  # a zero length body and a body of 255 octets all build and encode.
  def test_nothing_validates
    assert_equal('fe00', BGP::Evpn.new(BGP::Evpn::Unknown.new(0xfe, '')).to_shex)
    assert_equal('0900', BGP::Evpn.new(BGP::Evpn::Unknown.new(9, '')).to_shex)
    big = BGP::Evpn.new(BGP::Evpn::Unknown.new(9, "\xaa".b * 255))
    assert_equal(255, big.length)
    assert_equal(257, big.encode.size)
    assert_equal(0, BGP::Evpn.new(BGP::Evpn::Unknown.new(0, '')).type)
  end

  def test_an_nlri_refuses_what_it_cannot_read
    assert_raise(ArgumentError) { BGP::Evpn.new }
    assert_raise(ArgumentError) { BGP::Evpn.new(42) }
    assert_raise(ArgumentError) { BGP::Evpn.new(:no_such_route_type => 1) }
  end

  def test_an_nlri_prints_its_route_and_its_path_identifier
    assert_equal('Unknown route type 9, 8 octets [0011223344556677]',
                 BGP::Evpn.new(unknown).to_s)
    n = BGP::Evpn.new_ntop(BGP::Evpn.new(unknown).encode, 7)
    assert_equal('[7] Unknown route type 9, 8 octets [0011223344556677]',
                 n.to_s)
  end

  def test_two_nlris_with_the_same_octets_are_equal
    assert_equal(BGP::Evpn.new(unknown), BGP::Evpn.new(unknown))
    refute_equal(BGP::Evpn.new(unknown), BGP::Evpn.new(unknown(10)))
    refute_equal(BGP::Evpn.new(unknown), 'not an Evpn')
  end


  # The three route types RFC 9251 adds, through the framing. Their
  # bodies are variable, so these are the first rows where the Length
  # octet is not a constant of the route type.
  def test_the_rfc_9251_route_types_frame_and_replay
    r6 = '061c' \
         '00000064000000c80000000a20c000020120e8010101200a00000104'
    r7 = '0726' \
         '00000064000000c8001122334455667788990000000a' \
         '20c000020120e8010101200a00000106'
    r8 = '082b' \
         '00000064000000c8001122334455667788990000000a' \
         '20c000020120e8010101200a000001000000006402'
    { r6 => BGP::Evpn::Selective_multicast,
      r7 => BGP::Evpn::Membership_report_synch,
      r8 => BGP::Evpn::Leave_synch }.each do |hex, klass|
      n = BGP::Evpn.new(wire(hex))
      assert_instance_of(klass, n.route, hex)
      assert_equal(hex, n.to_shex)
      assert_equal(klass.type, n.type)
      # The framing says how long it is, and the body's own fields agree.
      assert_equal(hex.size / 2, BGP::Evpn.nlri_size(wire(hex)))
      assert_equal(hex, BGP::Evpn.new(n.to_hash).to_shex)
    end
  end

  # An (*,*) body is shorter than an (S,G) one for the same route type,
  # which is what makes these the first variable length rows.
  def test_a_wildcard_multicast_route_is_shorter_than_an_s_g_one
    star = '0610' + '00000064000000c80000000a' + '000000' + '04'
    n = BGP::Evpn.new(wire(star))
    assert_instance_of(BGP::Evpn::Selective_multicast, n.route)
    assert_equal(star, n.to_shex)
    assert_equal(18, BGP::Evpn.nlri_size(wire(star)))
    assert(n.route.source.empty?)
    assert(n.route.group.empty?)
    assert(n.route.originator.empty?)
  end

  # **A length that lies inside the body makes the route unreadable even
  # though the route type is implemented**, because the triple is self
  # describing: a Multicast Source Length of 200 bits claims the rest of
  # the body. So the route-type-kept-only-if-it-can-give-its-own-octets-
  # back rule hands it to Unknown, which replays it. Route types 1 to 5
  # could only reach this with a truncated body; these three reach it
  # with a body of the right length and one field lying.
  def test_a_lying_triple_length_falls_back_to_unknown
    hex = '0613' + '00000064000000c80000000a' + 'c8ffffff' + '0000' + 'ff'
    n = BGP::Evpn.new(wire(hex))
    assert_instance_of(BGP::Evpn::Unknown, n.route)
    assert_equal(6, n.type)
    assert_equal(hex, n.to_shex)
    assert_equal(hex, BGP::Evpn.new(n.to_hash).to_shex)
  end


  # ---------------------------------------------------------------
  # Route type 11, RFC 9572 section 3.3, the Leaf A-D route. Its tests
  # live here and not in evpn_route_test.rb, because its Route Key is
  # an NLRI: the class reaches `Evpn.nlri_size` and `Evpn.new` at call
  # time, so it is the one route type that does not work against
  # evpn_route.rb alone. That file requires evpn_route.rb by itself on
  # purpose, which is what proves the other ten do not need the NLRI.
  # ---------------------------------------------------------------

  # Section 3.3: "The Route Key is the NLRI of the route for which this
  # Leaf A-D route is generated", and the terminology section says the
  # Leaf A-D route "embeds the entire NLRI of the triggering PMSI A-D
  # route". Entire, so the Route Type and Length octets are in there,
  # which is what makes the recursion self delimiting.
  def test_a_leaf_a_d_route_embeds_a_whole_nlri_as_its_route_key
    assert_equal(11, BGP::Evpn::Leaf_a_d.type)
    assert_equal(:leaf_a_d, BGP::Evpn::Leaf_a_d.hash_key)
    inner = BGP::Evpn.new(BGP::Evpn::Inclusive_multicast
                            .new([100, 200], 10, '10.0.0.1'))
    r = BGP::Evpn::Leaf_a_d.new(inner, '10.0.0.9')
    # The Route Key carries its own framing: route type 3, length 0x11.
    assert_equal('0311' \
                 '00000064000000c8' \
                 '0000000a' \
                 '200a000001' \
                 '200a000009', r.to_shex)
    assert_equal(inner.to_shex, r.route_key.to_shex)
    assert_instance_of(BGP::Evpn::Inclusive_multicast, r.route_key.route)
    assert_equal('10.0.0.9', r.originator.address)
    # And the whole thing framed as an NLRI of its own, 2 + 24.
    n = BGP::Evpn.new(r)
    assert_equal('0b18' \
                 '0311' \
                 '00000064000000c8' \
                 '0000000a' \
                 '200a000001' \
                 '200a000009', n.to_shex)
    assert_equal(26, BGP::Evpn.nlri_size(wire(n.to_shex)))
  end

  # **The only route type with neither an RD nor an Ethernet Tag ID**,
  # which follows from the Route Key carrying whatever the triggering
  # route carried. Section 3 confirms it from the other side: the RD
  # rule it states for types 9 and 10 names "non-Leaf A-D routes" as
  # the ones that must match, so this one is the stated exception.
  def test_a_leaf_a_d_route_has_no_rd_and_no_ethernet_tag_id
    r = BGP::Evpn::Leaf_a_d.new
    refute_respond_to(r, :rd)
    refute_respond_to(r, :ethernet_tag_id)
    assert_respond_to(r, :route_key)
    assert_respond_to(r, :originator)
    # Every other route type has at least one of the two.
    BGP::Evpn::ROUTES.each do |t, k|
      next if t == 11
      e = k.new
      assert(e.respond_to?(:rd) || e.respond_to?(:ethernet_tag_id),
             "route type #{t} should carry an RD or an Ethernet Tag ID")
    end
  end

  def test_route_type_11_builds_four_ways
    inner = BGP::Evpn.new(BGP::Evpn::Per_region_i_pmsi
                            .new([100, 200], 10, '00090000fde80000'))
    r = BGP::Evpn::Leaf_a_d.new(inner, '2001:db8::9')
    k = BGP::Evpn::Leaf_a_d
    assert_equal(r.to_shex, k.new(r.encode.is_packed).to_shex)
    assert_equal(r.to_shex, k.new(r).to_shex)
    assert_equal(r.to_shex, k.new(r.to_hash).to_shex)
    assert_equal({ :leaf_a_d =>
                   { :route_key =>
                     { :per_region_i_pmsi =>
                       { :rd => [100, 200], :ethernet_tag_id => 10,
                         :region_id => '00090000fde80000' } },
                     :originator => '2001:db8::9' } },
                 r.to_hash)
    # A Route Key may be given as the route itself, as its octets, or as
    # a hash, since all three are things Evpn builds from.
    plain = BGP::Evpn::Per_region_i_pmsi.new([100, 200], 10,
                                             '00090000fde80000')
    assert_equal(r.to_shex, k.new(plain, '2001:db8::9').to_shex)
    assert_equal(r.to_shex,
                 k.new(wire(inner.to_shex), '2001:db8::9').to_shex)
    assert_raise(ArgumentError) { k.new(1, 2, 3) }
    assert_raise(ArgumentError) { k.new(42, '10.0.0.1') }
  end

  # It prints its route type number, the route its Route Key holds, and
  # the originator. Asserted because a to_s nothing calls is a
  # NoMethodError waiting for the first reader who prints a route.
  def test_a_leaf_a_d_route_prints_its_route_key
    inner = BGP::Evpn.new(BGP::Evpn::Inclusive_multicast
                            .new([100, 200], 10, '10.0.0.1'))
    r = BGP::Evpn::Leaf_a_d.new(inner, '10.0.0.9')
    assert_match(/^\[11\] Leaf A-D: route key /, r.to_s)
    # The Route Key prints as the route it holds, so the nesting is
    # visible rather than hex.
    assert_match(/\[3\] Inclusive Multicast:/, r.to_s)
    assert_match(/originator 10\.0\.0\.9/, r.to_s)
    assert_match(/route key Unknown route type 0/, BGP::Evpn::Leaf_a_d.new.to_s)
  end

  # An absent Route Key is not nothing: there is no sensible default
  # NLRI, so it is a type 0 Unknown with no body, 2 octets, which
  # replays like any other.
  def test_an_absent_route_key_is_an_empty_unknown_nlri
    r = BGP::Evpn::Leaf_a_d.new
    assert_equal('000000', r.to_shex)
    assert_instance_of(BGP::Evpn::Unknown, r.route_key.route)
    assert_equal(0, r.route_key.type)
    assert(r.originator.empty?)
    assert_equal(r.to_shex,
                 BGP::Evpn::Leaf_a_d.new(r.encode.is_packed).to_shex)
  end

  # Nothing validates, so a Route Key may hold a route type bgp4r does
  # not implement, and a Leaf A-D route may hold another one, which no
  # RFC describes. Both replay.
  def test_a_route_key_holds_anything_and_replays
    unimplemented = BGP::Evpn.new(BGP::Evpn::Unknown.new(99, wire('aabbcc')))
    r = BGP::Evpn::Leaf_a_d.new(unimplemented, '10.0.0.9')
    assert_equal('6303aabbcc200a000009', r.to_shex)
    back = BGP::Evpn::Leaf_a_d.new(r.encode.is_packed)
    assert_equal(r.to_shex, back.to_shex)
    assert_instance_of(BGP::Evpn::Unknown, back.route_key.route)
    assert_equal(99, back.route_key.type)

    nested = BGP::Evpn::Leaf_a_d.new(BGP::Evpn.new(r), '2001:db8::1')
    assert_instance_of(BGP::Evpn::Leaf_a_d, nested.route_key.route)
    assert_equal(nested.to_shex,
                 BGP::Evpn::Leaf_a_d.new(nested.encode.is_packed).to_shex)
    assert_equal(nested.to_shex,
                 BGP::Evpn::Leaf_a_d.new(nested.to_hash).to_shex)
  end

  # A Route Key whose own Length lies about the octets behind it cannot
  # reproduce the body, so the encode-matches rule hands the whole NLRI
  # to Unknown, which replays it. The outer Length is 6 here and the
  # Route Key claims 17.
  def test_a_route_key_whose_length_lies_falls_back_to_unknown
    hex = '0b06' + '0311' + '00000064'
    n = BGP::Evpn.new(wire(hex))
    assert_instance_of(BGP::Evpn::Unknown, n.route)
    assert_equal(11, n.type)
    assert_equal(hex, n.to_shex)
    assert_equal(hex, BGP::Evpn.new(n.to_hash).to_shex)
  end

  # A Route Key too short to carry even its two framing octets has
  # nothing to frame, which is the one thing the class refuses, since
  # the alternative is inventing a length.
  def test_a_route_key_too_short_to_frame_is_refused
    assert_raise(ArgumentError) { BGP::Evpn::Leaf_a_d.new(wire('03')) }
    # Through the NLRI it is an Unknown that replays, as always.
    n = BGP::Evpn.new(wire('0b0103'))
    assert_instance_of(BGP::Evpn::Unknown, n.route)
    assert_equal('0b0103', n.to_shex)
  end

  # Two Leaf A-D NLRIs in a row come off one buffer, which is what the
  # parse loops do and the only thing that proves the recursion does not
  # over-read.
  def test_two_leaf_a_d_nlris_in_a_row_each_read_their_own
    inner = BGP::Evpn.new(BGP::Evpn::Inclusive_multicast
                            .new([100, 200], 10, '10.0.0.1'))
    one = BGP::Evpn.new(BGP::Evpn::Leaf_a_d.new(inner, '10.0.0.9'))
    buf = (one.encode + one.encode).is_packed
    a = BGP::Evpn.new(buf)
    b = BGP::Evpn.new(buf)
    assert_equal(one.to_shex, a.to_shex)
    assert_equal(one.to_shex, b.to_shex)
    assert(buf.empty?, 'both NLRIs read exactly their own octets')
  end

  # The 2026-10-30 open question, closed. Part 1 of the EVPN plan
  # recorded that RFC 9572 never says its length fields are in bits,
  # and deferred the answer to this part rather than guessing it.
  # Section 3.2 defers to RFC 7117, which carries the RFC 6514 section
  # 4.3 encoding: "If the Multicast Source field contains an IPv4
  # address, then the value of the Multicast Source Length field is 32."
  # 32 for IPv4 and 128 for IPv6 is bits, by the values and not by the
  # word, which no document in the chain uses.
  def test_the_rfc_9572_length_fields_hold_a_bit_count
    r = BGP::Evpn::S_pmsi.new([100, 200], 10, '192.0.2.1', 'ff0e::1',
                              '10.0.0.1')
    assert_equal(32, r.source.bitlen)
    assert_equal(128, r.group.bitlen)
    leaf = BGP::Evpn::Leaf_a_d
             .new(BGP::Evpn.new(BGP::Evpn::Per_region_i_pmsi.new), '10.0.0.9')
    assert_equal(32, leaf.originator.bitlen)
    assert_equal(128, BGP::Evpn::Leaf_a_d
                        .new(BGP::Evpn.new(BGP::Evpn::Per_region_i_pmsi.new),
                             '2001:db8::9').originator.bitlen)
  end

end
