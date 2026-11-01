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
require 'bgp/nlris/mcast_vpn_route'
require 'bgp/nlris/rd'

# The primitives the MCAST-VPN route types of RFC 6514 section 4 share,
# plus the Route base and Mcast_vpn::Unknown. docs/mcast-vpn.md is the
# guide and test/unit/mcast_vpn_doc_test.rb asserts its claims.
#
# **There are no worked examples in RFC 6514 and none in RFC 7441.**
# That is worth saying because the flow spec tests lean on five of them
# across RFC 8955 and RFC 8956 and are stronger for it. Every
# expectation below is this reader's arithmetic from the figures and the
# four length sentences of section 4.3, computed with the library and
# pasted rather than typed, per the rule the RFC 4684 and RFC 6368 work
# earned: six hand written length expectations were wrong across #200
# and #204 and the library was right every time. So this file checks
# that the library agrees with how the figures were read here, and not
# that the reading is right. Nothing can check the reading from outside,
# because neither lab router implements SAFI 5.
#
# BGP:: names are written out in full, see Conventions in CLAUDE.md.
class Mcast_vpn_route_test < Test::Unit::TestCase

  M = BGP::Mcast_vpn

  # A miniature route type, so the Route base's four private helpers are
  # exercised before any real route type depends on them. It is shaped
  # like section 4.1, an RD then the trailing address, and it is
  # **deliberately not a route type**: it lives under this test class so
  # Mcast_vpn.constants never sees it, it is in no ROUTES entry, and its
  # TYPE is 0, which IANA's registry reserves and no route type will
  # ever take. The route types themselves arrive in later parts.
  class Probe < BGP::Mcast_vpn::Route

    TYPE     = 0
    HASH_KEY = :probe

    attr_reader :rd, :originator

    def initialize(*args)
      if args.size == 1 and args[0].is_a?(String) and args[0].is_packed?
        s = args[0]
        @rd = read_rd(s)
        @originator = BGP::Mcast_vpn::Originating_router.new(s)
      elsif args.size == 1 and args[0].is_a?(Hash)
        h = self.class.unwrap(args[0])
        @rd = coerce(BGP::Rd, h[:rd])
        @originator = coerce_or_default(BGP::Mcast_vpn::Originating_router,
                                       h[:originator])
      else
        @rd = coerce(BGP::Rd, args[0])
        @originator = coerce_or_default(BGP::Mcast_vpn::Originating_router,
                                        args[1])
      end
      self
    end

    def encode_value
      @rd.encode + @originator.encode
    end

    def value_hash
      { :rd => @rd.to_hash[:rd], :originator => @originator.to_hash }
    end

    # The one caller of addr_hash, which the real route types that carry
    # a Multicast Source will use.
    def hash_an_addr(a)
      addr_hash(a)
    end

    def to_s
      "probe #{@rd} #{@originator}"
    end

  end

  # Section 4.3: "If the Multicast Source field contains an IPv4
  # address, then the value of the Multicast Source Length field is 32."
  # So 0x20 then four octets.
  SRC_V4 = '20' + 'c0000201'
  SRC_V6 = '80' + '20010db8000000000000000000000001'

  def test_an_addr_is_a_length_in_bits_then_the_value
    a = M::Addr.new('192.0.2.1')
    assert_equal(32, a.bitlen)
    assert_equal(SRC_V4, a.to_shex)
    assert_equal(5, a.size)
    assert_equal('192.0.2.1', a.address)
    assert_equal('192.0.2.1/32', a.to_s)
  end

  def test_an_ipv6_addr_is_128_bits_and_sixteen_octets
    a = M::Addr.new('2001:db8::1')
    assert_equal(128, a.bitlen)
    assert_equal(SRC_V6, a.to_shex)
    assert_equal(17, a.size)
    assert_equal('2001:db8::1/128', a.to_s)
  end

  # A length of 0 and no octets, which is a wildcard source or group.
  def test_an_empty_addr_is_one_zero_octet
    a = M::Addr.new
    assert_equal('00', a.to_shex)
    assert_equal(1, a.size)
    assert(a.empty?)
    assert_equal('*', a.to_s)
    assert_nil(a.address)
  end

  # Section 4.3: "Usage of other values of the Multicast Source Length
  # and Multicast Group Length fields is outside the scope of this
  # document." Outside the scope is not malformed, so the octets are
  # kept and the family comes from the width rather than the length.
  def test_a_length_outside_the_scope_is_echoed_and_not_refused
    a = M::Addr.new(24, ['c00002'].pack('H*'))
    assert_equal('18c00002', a.to_shex)
    assert_nil(a.address, 'three octets are not an address')
    assert_equal('c00002/24', a.to_s)
  end

  # The 200 bit case is the one that found a bug in Evpn::Sized, where a
  # length claiming more than the body holds left unpack1 answering nil.
  # It is not repeated here: the value is what was there.
  def test_a_length_that_overruns_the_body_takes_what_is_there
    a = M::Addr.new(['c80102'].pack('H*').is_packed)
    assert_equal(200, a.bitlen)
    assert_equal('c80102', a.to_shex)
    assert_equal(2, a.value.size)
  end

  # **The bits-to-octets rounding is load bearing, and only a parse with
  # something behind it can show that.** In route types 3, 5, 6 and 7 an
  # Addr is followed by another field, so `octets_for` is what decides
  # where this one ends. A first version of this file had no such case,
  # and `octets_for(bitlen)` returning `bitlen` unrounded passed every
  # test in it: the only parse was of octets that ran out anyway, where
  # `[octets_for(200), 2].min` is 2 either way. Found by sabotage.
  def test_the_rounding_decides_where_the_field_ends
    s = ['20c0000201' + '20e0000001'].pack('H*').is_packed
    a = M::Addr.new(s)
    assert_equal(SRC_V4, a.to_shex)
    assert_equal('20e0000001', s.unpack1('H*'), 'the next field is untouched')
    b = M::Addr.new(s)
    assert_equal('20e0000001', b.to_shex)
    assert_equal('', s)
  end

  # And the same where the bit count is not a whole number of octets, so
  # the rounding up is what is under test rather than the division.
  def test_a_length_that_is_not_a_whole_octet_rounds_up
    s = ['14c00002' + 'ff'].pack('H*').is_packed
    a = M::Addr.new(s)
    assert_equal(20, a.bitlen)
    assert_equal('14c00002', a.to_shex, '20 bits occupy three octets')
    assert_equal('ff', s.unpack1('H*'), 'and not the octet behind them')
  end

  def test_an_addr_round_trips_four_ways
    a = M::Addr.new('192.0.2.1')
    assert_equal(SRC_V4, M::Addr.new(a.encode.dup.is_packed).to_shex)
    assert_equal(SRC_V4, M::Addr.new(a).to_shex)
    assert_equal(SRC_V4, M::Addr.new(a.to_hash).to_shex)
    assert_equal(SRC_V4, M::Addr.new(32, ['c0000201'].pack('H*')).to_shex)
  end

  # The wrapped form, which is what a route type's hash nests it under.
  def test_an_addr_reads_its_own_wrapped_hash
    a = M::Addr.new(24, ['c00002'].pack('H*'))
    assert_equal('18c00002', M::Addr.new(:addr => a.to_hash).to_shex)
  end

  # Conventions: building from an instance must not empty the instance,
  # since parse reads with slice!. This is the Esi#encode bug of #181
  # from the other direction.
  def test_building_an_addr_from_an_instance_leaves_it_whole
    a = M::Addr.new('192.0.2.1')
    M::Addr.new(a)
    assert_equal(SRC_V4, a.to_shex)
  end

  # Section 4.2: "Source AS (4 octets)".
  def test_a_source_as_is_four_octets
    s = M::Source_as.new(65000)
    assert_equal('0000fde8', s.to_shex)
    assert_equal(4, s.size)
    assert_equal(65000, s.value)
    assert_equal('AS 65000', s.to_s)
  end

  # Four octets whatever the session negotiated: the figure gives a
  # width and an NLRI carries no capability, so unlike AGGREGATOR this
  # field never follows the session.
  def test_a_four_octet_as_fits_and_builds
    assert_equal('0001117d', M::Source_as.new(70013).to_shex)
    assert_equal('ffffffff', M::Source_as.new(0xffffffff).to_shex)
  end

  def test_a_source_as_round_trips_three_ways
    s = M::Source_as.new(65000)
    assert_equal('0000fde8', M::Source_as.new(s.encode.dup.is_packed).to_shex)
    assert_equal('0000fde8', M::Source_as.new(s).to_shex)
    assert_equal('0000fde8', M::Source_as.new(s.to_hash).to_shex)
  end

  # A representability refusal, which Conventions allows: the
  # alternative is silently sending a different AS.
  def test_a_source_as_too_large_for_the_field_is_refused
    assert_raise(ArgumentError) { M::Source_as.new(0x100000000) }
  end

  # AS 0 is not a valid AS and builds, per the first Conventions bullet.
  def test_as_zero_builds
    assert_equal('00000000', M::Source_as.new.to_shex)
    assert_equal('00000000', M::Source_as.new(0).to_shex)
  end

  # The field with no length octet anywhere in either document. Its
  # width is what it is handed and its family comes from that width.
  def test_an_originating_router_has_no_length_octet
    o = M::Originating_router.new('10.0.0.1')
    assert_equal('0a000001', o.to_shex)
    assert_equal(4, o.size)
    assert_equal('10.0.0.1', o.address)
    assert_equal('10.0.0.1', o.to_s)
  end

  def test_an_originating_router_can_be_ipv6
    o = M::Originating_router.new('2001:db8::1')
    assert_equal('20010db8000000000000000000000001', o.to_shex)
    assert_equal(16, o.size)
    assert_equal('2001:db8::1', o.to_s)
  end

  # It takes everything it is handed, because it is last in every layout
  # that carries one and has no length to read.
  def test_an_originating_router_takes_every_octet_it_is_handed
    o = M::Originating_router.new(['0a0000010a000002'].pack('H*').is_packed)
    assert_equal('0a0000010a000002', o.to_shex)
    assert_equal(8, o.size)
    assert_nil(o.address, 'eight octets are neither family')
  end

  # A width that is neither family is kept rather than refused. It makes
  # the route unable to reproduce its body, which Mcast_vpn#read_route
  # catches; it is not this class's business.
  def test_a_width_that_is_neither_family_is_kept
    o = M::Originating_router.new(['0102030405'].pack('H*').is_packed)
    assert_equal('0102030405', o.to_shex)
    assert_nil(o.address)
    assert_equal('0x0102030405', o.to_s)
    assert_equal({ :octets => '0102030405' }, o.to_hash)
  end

  # The extra-key-only-when-unusual rule the library uses for :tail and
  # :bits: an ordinary field hashes as a plain address string.
  def test_an_ordinary_originating_router_hashes_as_an_address_string
    assert_equal('10.0.0.1', M::Originating_router.new('10.0.0.1').to_hash)
  end

  def test_an_originating_router_round_trips_four_ways
    o = M::Originating_router.new('10.0.0.1')
    assert_equal('0a000001',
                 M::Originating_router.new(o.encode.dup.is_packed).to_shex)
    assert_equal('0a000001', M::Originating_router.new(o).to_shex)
    assert_equal('0a000001', M::Originating_router.new(o.to_hash).to_shex)
    assert_equal('0a000001',
                 M::Originating_router.new(:originating_router => '10.0.0.1')
                                      .to_shex)
  end

  def test_an_odd_width_originating_router_round_trips_through_its_hash
    o = M::Originating_router.new(['0102030405'].pack('H*').is_packed)
    assert_equal('0102030405', M::Originating_router.new(o.to_hash).to_shex)
  end

  def test_an_empty_originating_router_is_no_octets
    o = M::Originating_router.new
    assert_equal('', o.to_shex)
    assert_equal(0, o.size)
    assert(o.empty?)
    assert_equal('(none)', o.to_s)
  end

  # Mcast_vpn::Unknown, the keep-what-you-cannot-read class for this
  # level. This is where the three mLDP route types land.
  def test_an_unknown_keeps_its_type_and_its_octets
    u = M::Unknown.new(0x43, ['0102030405'].pack('H*'))
    assert_equal(0x43, u.type)
    assert_equal('0102030405', u.to_shex)
    assert_match(/Unknown route type 67/, u.to_s)
  end

  def test_an_unknown_round_trips_three_ways
    u = M::Unknown.new(0x43, ['0102030405'].pack('H*'))
    assert_equal('0102030405', M::Unknown.new(u).to_shex)
    assert_equal('0102030405', M::Unknown.new(u.to_hash).to_shex)
    assert_equal(0x43, M::Unknown.new(u.to_hash).type)
    assert_equal('0102030405',
                 M::Unknown.new(:type => 0x43, :value => '0102030405').to_shex)
  end

  def test_an_unknown_hashes_under_its_own_key
    u = M::Unknown.new(1, ['ff'].pack('H*'))
    assert_equal({ :unknown => { :type => 1, :value => 'ff' } }, u.to_hash)
  end

  def test_an_unknown_refuses_an_argument_it_cannot_read
    assert_raise(ArgumentError) { M::Unknown.new }
    assert_raise(ArgumentError) { M::Unknown.new('not packed') }
  end

  # A copy, so building from an instance cannot empty it.
  def test_building_an_unknown_from_an_instance_leaves_it_whole
    u = M::Unknown.new(1, ['0102'].pack('H*'))
    M::Unknown.new(u)
    assert_equal('0102', u.to_shex)
  end

  # RFC 6514 section 4.1: "RD (8 octets)", which is the one field this
  # family takes from a class the library already had.
  def test_the_rd_size_is_eight
    assert_equal(8, M::RD_SIZE)
    assert_equal(8, BGP::Rd.new(100, 200).encode.size)
  end

  # The Route base is abstract: it has no TYPE and no HASH_KEY, so it
  # cannot answer either. Unknown is the one subclass this part defines.
  def test_the_route_base_is_abstract
    assert_raise(NameError) { M::Route.type }
    assert_raise(NameError) { M::Route.hash_key }
    assert_equal(:unknown, M::Unknown.hash_key)
  end

  # Each primitive refuses an argument it cannot read rather than
  # building something that is not what the caller asked for. This is
  # not the validation Conventions forbids: it is a shape it cannot
  # interpret at all, and the octet level routes stay open.
  def test_each_primitive_refuses_an_argument_it_cannot_read
    assert_raise(ArgumentError) { M::Addr.new(1, 2, 3) }
    assert_raise(ArgumentError) { M::Source_as.new(1, 2) }
    assert_raise(ArgumentError) { M::Originating_router.new(1, 2) }
  end

  # The four private helpers on the Route base, through the probe
  # subclass above, so they are exercised before a real route type
  # depends on them.
  def test_the_route_base_reads_an_rd_and_leaves_the_rest_to_the_field
    p = Probe.new(['00000064000000c8' + '0a000001'].pack('H*').is_packed)
    assert_equal('00000064000000c8', p.rd.to_shex)
    assert_equal('10.0.0.1', p.originator.address)
    assert_equal('00000064000000c80a000001', p.to_shex)
  end

  # coerce takes an instance or whatever the class builds from, and
  # splats an Array because that is the shape Rd#to_hash answers with.
  def test_the_route_base_coerces_a_field_from_values
    assert_equal('00000064000000c80a000001',
                 Probe.new([100, 200], '10.0.0.1').to_shex)
    assert_equal('00000064000000c80a000001',
                 Probe.new(BGP::Rd.new(100, 200),
                           M::Originating_router.new('10.0.0.1')).to_shex)
  end

  # coerce_or_default, for a field left out entirely.
  def test_the_route_base_defaults_a_field_that_is_left_out
    p = Probe.new([100, 200])
    assert_equal('00000064000000c8', p.to_shex)
    assert(p.originator.empty?)
  end

  def test_the_probe_round_trips_through_its_own_hash
    p = Probe.new([100, 200], '10.0.0.1')
    assert_equal({ :probe => { :rd => [100, 200],
                               :originator => '10.0.0.1' } }, p.to_hash)
    assert_equal(p.encode, Probe.new(p.to_hash).encode)
  end

  # addr_hash: the address string when the octets are a whole family and
  # the bit count agrees with them, and the Addr hash otherwise.
  def test_the_route_base_hashes_an_addr_two_ways
    p = Probe.new([100, 200])
    assert_equal('192.0.2.1', p.hash_an_addr(M::Addr.new('192.0.2.1')))
    assert_equal({ :bitlen => 0, :value => '' },
                 p.hash_an_addr(M::Addr.new), 'the absent field')
    assert_equal({ :bitlen => 24, :value => 'c00002' },
                 p.hash_an_addr(M::Addr.new(24, ['c00002'].pack('H*'))),
                 'three octets are not an address')
    assert_equal({ :bitlen => 24, :value => 'c0000201' },
                 p.hash_an_addr(M::Addr.new(24, ['c0000201'].pack('H*'))),
                 'a length that disagrees with its own octets')
  end

  # The base's instance type reads the class constant, which is what
  # every route type but Unknown will rely on.
  def test_the_route_base_takes_its_type_from_the_class
    assert_equal(0, Probe.new([100, 200]).type)
    assert_equal(0, Probe.type)
  end

  # ------------------------------------------------------------------
  # Route type 1, RFC 6514 section 4.1, the Intra-AS I-PMSI A-D route.
  # RD then the Originating Router's IP Address, which has no length
  # field, so the body is 12 octets with an IPv4 address and 24 with an
  # IPv6 one. Neither number is in the document: both are computed with
  # the library and pasted.

  RD      = '00000064000000c8'
  INTRA4  = RD + '0a000001'
  INTRA6  = RD + '20010db8000000000000000000000001'

  def test_route_type_1_is_an_rd_then_the_trailing_address
    r = M::Intra_as_i_pmsi.new([100, 200], '10.0.0.1')
    assert_equal(1, r.type)
    assert_equal(INTRA4, r.to_shex)
    assert_equal(12, r.encode.size)
    assert_equal('10.0.0.1', r.originator.address)
  end

  def test_route_type_1_with_an_ipv6_address_is_twenty_four_octets
    r = M::Intra_as_i_pmsi.new([100, 200], '2001:db8::1')
    assert_equal(INTRA6, r.to_shex)
    assert_equal(24, r.encode.size)
  end

  # **Route type 1 with an IPv4 address and route type 2 are both 12
  # octets.** So nothing in either body tells them apart and the Route
  # Type octet is the only discriminator. Not a problem the framing has
  # to solve, since the type is read first, but a reader comparing
  # lengths across this family should know the collision is there.
  def test_route_type_1_and_route_type_2_are_the_same_length
    r = M::Intra_as_i_pmsi.new([100, 200], '10.0.0.1')
    s = M::Inter_as_i_pmsi.new([100, 200], 65000)
    assert_equal(r.encode.size, s.encode.size)
    assert_equal(12, r.encode.size)
    assert_not_equal(r.type, s.type)
  end

  def test_route_type_1_round_trips_four_ways
    r = M::Intra_as_i_pmsi.new([100, 200], '10.0.0.1')
    assert_equal(INTRA4, M::Intra_as_i_pmsi.new(r.encode.dup.is_packed).to_shex)
    assert_equal(INTRA4, M::Intra_as_i_pmsi.new(r).to_shex)
    assert_equal(INTRA4, M::Intra_as_i_pmsi.new(r.to_hash).to_shex)
    assert_equal(INTRA4,
                 M::Intra_as_i_pmsi.new(:rd => [100, 200],
                                        :originator => '10.0.0.1').to_shex)
  end

  def test_route_type_1_hashes_under_its_own_key
    r = M::Intra_as_i_pmsi.new([100, 200], '10.0.0.1')
    assert_equal({ :intra_as_i_pmsi => { :rd => [100, 200],
                                         :originator => '10.0.0.1' } },
                 r.to_hash)
  end

  # The field left out entirely, which no section describes and which
  # builds, per Conventions.
  def test_route_type_1_builds_with_no_address_at_all
    r = M::Intra_as_i_pmsi.new([100, 200])
    assert_equal(RD, r.to_shex)
    assert(r.originator.empty?)
  end

  # The what-is-left rule, and the one place it can be seen: an address
  # of a width that is neither family is kept rather than refused.
  def test_route_type_1_keeps_an_address_of_an_odd_width
    r = M::Intra_as_i_pmsi.new([RD + '0102030405'].pack('H*').is_packed)
    assert_equal(RD + '0102030405', r.to_shex)
    assert_nil(r.originator.address)
    assert_equal(RD + '0102030405',
                 M::Intra_as_i_pmsi.new(r.to_hash).to_shex)
  end

  # ------------------------------------------------------------------
  # Route type 2, RFC 6514 section 4.2, the Inter-AS I-PMSI A-D route.
  # The one fixed length layout in the family.

  INTER = RD + '0000fde8'

  def test_route_type_2_is_an_rd_then_four_octets_of_source_as
    s = M::Inter_as_i_pmsi.new([100, 200], 65000)
    assert_equal(2, s.type)
    assert_equal(INTER, s.to_shex)
    assert_equal(12, s.encode.size)
    assert_equal(65000, s.source_as.value)
  end

  # Section 4.2: "Two-octet ASNs are encoded in the two low-order
  # octets of the Source AS field, with the two high-order octets set
  # to zero." That holds by construction, since Source_as writes a
  # 32-bit unsigned integer, and this asserts it rather than assuming.
  def test_a_two_octet_as_sits_in_the_low_order_octets
    s = M::Inter_as_i_pmsi.new([100, 200], 65000)
    assert_equal('0000fde8', s.source_as.to_shex)
    assert_equal('0000', s.source_as.to_shex[0, 4],
                 'the two high-order octets are zero')
  end

  def test_a_four_octet_as_fills_the_field
    s = M::Inter_as_i_pmsi.new([100, 200], 70013)
    assert_equal(RD + '0001117d', s.to_shex)
    assert_equal(12, s.encode.size, 'the layout does not grow for a 4-byte AS')
  end

  def test_route_type_2_round_trips_four_ways
    s = M::Inter_as_i_pmsi.new([100, 200], 65000)
    assert_equal(INTER, M::Inter_as_i_pmsi.new(s.encode.dup.is_packed).to_shex)
    assert_equal(INTER, M::Inter_as_i_pmsi.new(s).to_shex)
    assert_equal(INTER, M::Inter_as_i_pmsi.new(s.to_hash).to_shex)
    assert_equal(INTER,
                 M::Inter_as_i_pmsi.new(:rd => [100, 200],
                                        :source_as => 65000).to_shex)
  end

  # Source_as#to_hash merges flat, since :source_as collides with no
  # field of the route. That is the shape BGP::Label takes in EVPN
  # route type 1 for the same reason.
  def test_route_type_2_hashes_its_source_as_flat
    s = M::Inter_as_i_pmsi.new([100, 200], 65000)
    assert_equal({ :inter_as_i_pmsi => { :rd => [100, 200],
                                         :source_as => 65000 } },
                 s.to_hash)
  end

  def test_route_type_2_builds_with_no_source_as
    s = M::Inter_as_i_pmsi.new([100, 200])
    assert_equal(RD + '00000000', s.to_shex)
    assert_equal(12, s.encode.size)
  end

  # ------------------------------------------------------------------
  # Route type 5, RFC 6514 section 4.5, the Source Active A-D route.
  # RD, then the source and the group, each a length in bits and that
  # many bits of value.

  ACTIVE4 = RD + '20c0000201' + '20e8010101'
  ACTIVE6 = RD + '8020010db8000000000000000000000001' \
                 '80ff3e0000000000000000000000000001'

  def test_route_type_5_is_an_rd_then_a_source_and_a_group
    t = M::Source_active.new([100, 200], '192.0.2.1', '232.1.1.1')
    assert_equal(5, t.type)
    assert_equal(ACTIVE4, t.to_shex)
    assert_equal(18, t.encode.size)
    assert_equal('192.0.2.1', t.source.address)
    assert_equal('232.1.1.1', t.group.address)
  end

  def test_route_type_5_with_two_ipv6_addresses_is_forty_two_octets
    t = M::Source_active.new([100, 200], '2001:db8::1', 'ff3e::1')
    assert_equal(ACTIVE6, t.to_shex)
    assert_equal(42, t.encode.size)
  end

  def test_route_type_5_round_trips_four_ways
    t = M::Source_active.new([100, 200], '192.0.2.1', '232.1.1.1')
    assert_equal(ACTIVE4, M::Source_active.new(t.encode.dup.is_packed).to_shex)
    assert_equal(ACTIVE4, M::Source_active.new(t).to_shex)
    assert_equal(ACTIVE4, M::Source_active.new(t.to_hash).to_shex)
    assert_equal(ACTIVE4,
                 M::Source_active.new(:rd => [100, 200],
                                      :source => '192.0.2.1',
                                      :group => '232.1.1.1').to_shex)
  end

  def test_route_type_5_hashes_under_its_own_key
    t = M::Source_active.new([100, 200], '192.0.2.1', '232.1.1.1')
    assert_equal({ :source_active => { :rd => [100, 200],
                                       :source => '192.0.2.1',
                                       :group => '232.1.1.1' } },
                 t.to_hash)
  end

  # Section 4.5: "Use of the Source Active A-D routes with the
  # Multicast Source Length field of 0 is outside the scope of this
  # document." Outside the scope is not an error, the third such
  # sentence in this family, so a wildcard source builds and replays.
  def test_a_wildcard_source_is_outside_the_scope_and_still_builds
    t = M::Source_active.new([100, 200], nil, '232.1.1.1')
    assert_equal(RD + '00' + '20e8010101', t.to_shex)
    assert_equal(14, t.encode.size)
    assert(t.source.empty?)
    assert_match(/\(\*, 232\.1\.1\.1/, t.to_s)
    assert_equal(t.to_shex, M::Source_active.new(t.to_hash).to_shex)
  end

  # Section 4.5 also says a route whose group is in the SSM range
  # "MUST NOT be advertised by a router and MUST be discarded if
  # received". That is route filtering and not encoding, so bgp4r
  # builds one: 232.0.0.0/8 is the IPv4 SSM range of RFC 4607, which
  # RFC 6514 does not number itself.
  def test_a_group_in_the_ssm_range_builds
    t = M::Source_active.new([100, 200], '192.0.2.1', '232.1.1.1')
    assert_equal('232.1.1.1', t.group.address)
    assert_equal(ACTIVE4, t.to_shex, 'nothing refuses it')
  end

  # A source length that claims more than the body holds leaves the
  # group with nothing, which is what Addr's .to_i guard is for. The
  # route then cannot reproduce its own body, and Mcast_vpn#read_route
  # is what catches that; here the class itself just does not raise.
  def test_a_source_length_that_eats_the_group_does_not_raise
    t = M::Source_active.new([RD + 'c8' + '0102'].pack('H*').is_packed)
    assert_equal(200, t.source.bitlen)
    assert(t.group.empty?)
    assert_not_equal(RD + 'c80102', t.to_shex,
                     'so the NLRI falls back to Unknown')
  end

  # ------------------------------------------------------------------
  # Route type 3, RFC 6514 section 4.3, the S-PMSI A-D route: route
  # type 5 with the trailing address behind it, so it is the first
  # layout in this family with a variable field after a variable field.

  SPMSI4 = RD + '20c0000201' + '20e8010101' + '0a000001'
  SPMSI6 = RD + '8020010db8000000000000000000000001' \
                '80ff3e0000000000000000000000000001' \
                '20010db8000000000000000000000002'

  def test_route_type_3_is_route_type_5_with_a_trailing_address
    r = M::S_pmsi.new([100, 200], '192.0.2.1', '232.1.1.1', '10.0.0.1')
    assert_equal(3, r.type)
    assert_equal(SPMSI4, r.to_shex)
    assert_equal(22, r.encode.size)
    assert_equal('192.0.2.1', r.source.address)
    assert_equal('232.1.1.1', r.group.address)
    assert_equal('10.0.0.1', r.originator.address)
  end

  # The same body as route type 5 is in there, which is what the shared
  # module amounts to on the wire.
  def test_route_type_3_carries_route_type_5s_body_in_front_of_its_address
    r = M::S_pmsi.new([100, 200], '192.0.2.1', '232.1.1.1', '10.0.0.1')
    t = M::Source_active.new([100, 200], '192.0.2.1', '232.1.1.1')
    assert_equal(t.to_shex + '0a000001', r.to_shex)
  end

  def test_route_type_3_all_ipv6_is_fifty_eight_octets
    r = M::S_pmsi.new([100, 200], '2001:db8::1', 'ff3e::1', '2001:db8::2')
    assert_equal(SPMSI6, r.to_shex)
    assert_equal(58, r.encode.size)
  end

  def test_route_type_3_round_trips_four_ways
    r = M::S_pmsi.new([100, 200], '192.0.2.1', '232.1.1.1', '10.0.0.1')
    assert_equal(SPMSI4, M::S_pmsi.new(r.encode.dup.is_packed).to_shex)
    assert_equal(SPMSI4, M::S_pmsi.new(r).to_shex)
    assert_equal(SPMSI4, M::S_pmsi.new(r.to_hash).to_shex)
    assert_equal(SPMSI4,
                 M::S_pmsi.new(:rd => [100, 200],
                               :source => '192.0.2.1',
                               :group => '232.1.1.1',
                               :originator => '10.0.0.1').to_shex)
  end

  def test_route_type_3_hashes_under_its_own_key
    r = M::S_pmsi.new([100, 200], '192.0.2.1', '232.1.1.1', '10.0.0.1')
    assert_equal({ :s_pmsi => { :rd => [100, 200],
                                :source => '192.0.2.1',
                                :group => '232.1.1.1',
                                :originator => '10.0.0.1' } },
                 r.to_hash)
  end

  # **The order is what makes this layout readable at all**: the two
  # lengths are read first and each takes what it claims, so the
  # trailing address gets what is left. A length that claims more than
  # the body holds therefore eats the fields behind it, which is the
  # one way this layout can go wrong and is ordinary negative testing
  # rather than a malformed capture.
  def test_a_source_length_that_overruns_leaves_the_address_empty
    r = M::S_pmsi.new([RD + 'c8' + '20e8010101' + '0a000001']
                        .pack('H*').is_packed)
    assert_equal(200, r.source.bitlen)
    assert(r.group.empty?)
    assert(r.originator.empty?)
    assert_not_equal(RD + 'c820e80101010a000001', r.to_shex,
                     'so the NLRI falls back to Unknown')
  end

  # ------------------------------------------------------------------
  # Route types 6 and 7, RFC 6514 section 4.6, the C-Multicast Route.
  # One layout and two route type numbers.

  CMCAST = RD + '0000fde8' + '20c0000201' + '20e8010101'

  def test_route_type_6_is_an_rd_a_source_as_then_the_pair
    x = M::Shared_tree_join.new([100, 200], 65000, '192.0.2.1', '232.1.1.1')
    assert_equal(6, x.type)
    assert_equal(CMCAST, x.to_shex)
    assert_equal(22, x.encode.size)
    assert_equal(65000, x.source_as.value)
    assert_equal('192.0.2.1', x.source.address)
    assert_equal('232.1.1.1', x.group.address)
  end

  # **The whole point of section 4.6 being one subsection**: the two
  # route types encode identically and differ only in the Route Type
  # octet, which the NLRI writes and the body does not carry.
  def test_route_types_6_and_7_encode_identically
    a = M::Shared_tree_join.new([100, 200], 65000, '192.0.2.1', '232.1.1.1')
    b = M::Source_tree_join.new([100, 200], 65000, '192.0.2.1', '232.1.1.1')
    assert_equal(a.to_shex, b.to_shex)
    assert_equal(6, a.type)
    assert_equal(7, b.type)
    assert_not_equal(a.to_hash.keys, b.to_hash.keys, 'but the keys differ')
  end

  def test_route_type_7_is_the_same_layout
    x = M::Source_tree_join.new([100, 200], 65000, '192.0.2.1', '232.1.1.1')
    assert_equal(7, x.type)
    assert_equal(CMCAST, x.to_shex)
    assert_equal(22, x.encode.size)
  end

  def test_the_c_multicast_layout_all_ipv6_is_forty_six_octets
    [M::Shared_tree_join, M::Source_tree_join].each do |k|
      x = k.new([100, 200], 65000, '2001:db8::1', 'ff3e::1')
      assert_equal(46, x.encode.size, k.to_s)
    end
  end

  def test_the_c_multicast_layout_round_trips_four_ways
    [M::Shared_tree_join, M::Source_tree_join].each do |k|
      x = k.new([100, 200], 65000, '192.0.2.1', '232.1.1.1')
      assert_equal(CMCAST, k.new(x.encode.dup.is_packed).to_shex, k.to_s)
      assert_equal(CMCAST, k.new(x).to_shex, k.to_s)
      assert_equal(CMCAST, k.new(x.to_hash).to_shex, k.to_s)
      assert_equal(CMCAST,
                   k.new(:rd => [100, 200], :source_as => 65000,
                         :source => '192.0.2.1',
                         :group => '232.1.1.1').to_shex, k.to_s)
    end
  end

  def test_the_c_multicast_types_hash_under_their_own_keys
    fields = { :rd => [100, 200], :source_as => 65000,
               :source => '192.0.2.1', :group => '232.1.1.1' }
    assert_equal({ :shared_tree_join => fields },
                 M::Shared_tree_join.new([100, 200], 65000,
                                         '192.0.2.1', '232.1.1.1').to_hash)
    assert_equal({ :source_tree_join => fields },
                 M::Source_tree_join.new([100, 200], 65000,
                                         '192.0.2.1', '232.1.1.1').to_hash)
  end

  # **Route type 3 and the C-Multicast layout are both 22 octets with
  # IPv4 addresses.** The second length collision in this family, after
  # route type 1 against route type 2, and harmless for the same
  # reason: the Route Type octet is read before the body.
  def test_route_type_3_and_the_c_multicast_layout_are_the_same_length
    r = M::S_pmsi.new([100, 200], '192.0.2.1', '232.1.1.1', '10.0.0.1')
    x = M::Shared_tree_join.new([100, 200], 65000, '192.0.2.1', '232.1.1.1')
    assert_equal(22, r.encode.size)
    assert_equal(22, x.encode.size)
    assert_not_equal(r.to_shex, x.to_shex, 'the same length, different octets')
  end

  # The module is shared by four route types, so it is worth asserting
  # that all four really do read the pair, and that it is a module
  # rather than a class, which is what keeps the doc test's discovery
  # from counting it as a route type.
  def test_four_route_types_share_the_source_and_group_pair
    [M::S_pmsi, M::Source_active, M::Shared_tree_join,
     M::Source_tree_join].each do |k|
      assert(k.include?(M::Source_and_group), k.to_s)
    end
    assert_kind_of(Module, M::Source_and_group)
    assert(!M::Source_and_group.is_a?(Class),
           'a Class here would read as a route type with no row')
    assert(!M::C_multicast.is_a?(Class), 'the same for the 4.6 layout')
  end

  # The human readable form, in the house style evpn_route.rb uses:
  # the type in brackets, the route's name, then the fields. The RD
  # prints in its short form, since Rd#to_s(false) leaves off the hex.
  def test_each_route_type_names_itself
    assert_equal('[1] Intra-AS I-PMSI A-D: RD=100:200, ' \
                 'originating router 10.0.0.1',
                 M::Intra_as_i_pmsi.new([100, 200], '10.0.0.1').to_s)
    assert_equal('[2] Inter-AS I-PMSI A-D: RD=100:200, source AS 65000',
                 M::Inter_as_i_pmsi.new([100, 200], 65000).to_s)
    assert_equal('[5] Source Active A-D: RD=100:200, ' \
                 '(192.0.2.1/32, 232.1.1.1/32)',
                 M::Source_active.new([100, 200], '192.0.2.1',
                                      '232.1.1.1').to_s)
    assert_equal('[3] S-PMSI A-D: RD=100:200, ' \
                 '(192.0.2.1/32, 232.1.1.1/32), ' \
                 'originating router 10.0.0.1',
                 M::S_pmsi.new([100, 200], '192.0.2.1', '232.1.1.1',
                               '10.0.0.1').to_s)
  end

  # Route types 6 and 7 share one `to_s`, so the name a reader sees
  # comes off the class rather than being written twice.
  def test_the_c_multicast_types_name_themselves_from_the_class
    assert_equal('[6] Shared Tree Join: RD=100:200, AS 65000, ' \
                 '(192.0.2.1/32, 232.1.1.1/32)',
                 M::Shared_tree_join.new([100, 200], 65000, '192.0.2.1',
                                         '232.1.1.1').to_s)
    assert_equal('[7] Source Tree Join: RD=100:200, AS 65000, ' \
                 '(192.0.2.1/32, 232.1.1.1/32)',
                 M::Source_tree_join.new([100, 200], 65000, '192.0.2.1',
                                         '232.1.1.1').to_s)
  end

  # Nothing validates, per Conventions: a length no RFC describes on
  # either field, in one route, on the wire.
  def test_nothing_validates
    t = M::Source_active.new(:rd => [100, 200],
                             :source => { :bitlen => 7, :value => 'ff' },
                             :group => { :bitlen => 200, :value => 'aabb' })
    assert_equal(RD + '07ff' + 'c8aabb', t.to_shex)
    assert_equal(RD + '07ff' + 'c8aabb',
                 M::Source_active.new(t.to_hash).to_shex)
  end

end
