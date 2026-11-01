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
require 'bgp/nlris/link_state'

# **RFC 9552 carries no worked example and no hex anywhere**, so every
# expectation here is this reader's arithmetic from the Figure 5 and
# Figure 6 field widths rather than the document's own octets. The hex
# is written out field by field beside each case for that reason; the
# arithmetic is the thing to doubt first when one of these fails.
class TestLinkState < Test::Unit::TestCase

  include BGP

  # A registered NLRI type, for the parts of this file that are about
  # the registry. Nested in the test class so it is invisible to
  # `BGP.constants`, which the to_hash catalog and the doc test walk.
  # Full class names inside it, since a nested class does not see the
  # `include` in the class around it.
  class Probe < BGP::Link_state::Type

    TYPE = 60000
    HASH_KEY = :probe

    attr_reader :n

    def initialize(arg)
      if arg.is_a?(String) and arg.is_packed?
        @n = arg.slice!(0, 4).unpack1('N').to_i
      elsif arg.is_a?(Hash)
        @n = self.class.unwrap(arg)[:n].to_i
      else
        @n = arg.to_i
      end
    end

    def encode_value
      [@n].pack('N')
    end

    def value_hash
      { :n => @n }
    end

  end

  # --- section 5.2, the framing ----------------------------------------

  # NLRI Type 1 (0x0001), Total NLRI Length 5 (0x0005), five octets of
  # body.
  def test_the_framing_is_two_octets_two_octets_and_the_body
    hex = '0001' + '0005' + '0102030405'
    n = BGP::Link_state.new_ntop([hex].pack('H*'))
    assert_equal(1, n.type)
    assert_equal(5, n.length)
    assert_equal(hex, n.to_shex)
    assert_equal(9, n.size)
  end

  # Section 5.2: "The Total NLRI Length field contains the cumulative
  # length, in octets, of the rest of the NLRI, not including the NLRI
  # Type field or itself."
  def test_the_length_counts_neither_the_type_nor_itself
    n = BGP::Link_state.new(BGP::Link_state::Unknown.new(
      1, ['0102030405'].pack('H*')))
    assert_equal(5, n.length)
    assert_equal(5, n.encode[2, 2].unpack1('n'))
    assert_equal(9, n.encode.size)
  end

  # "For VPN applications, it also includes the length of the Route
  # Distinguisher." So the same five-octet body is length 13 behind an
  # RD and not 5, which is the single detail most likely to be got
  # wrong here.
  def test_the_length_counts_the_route_distinguisher_too
    hex = '0001' + '000d' + '00000064000000c8' + '0102030405'
    n = BGP::Link_state.new_ntop([hex].pack('H*'), IANA::SAFI::BGP_LS_VPN)
    assert(n.vpn?)
    assert_equal(13, n.length)
    assert_equal('RD=100:200', n.rd.to_s(false))
    assert_equal(hex, n.to_shex)
  end

  # --- nlri_size -------------------------------------------------------

  # **It takes no SAFI, and that is section 5.2's doing.** The Total
  # NLRI Length covers the RD, so one arithmetic frames both SAFIs and
  # a VPN NLRI is simply eight octets longer.
  def test_nlri_size_frames_both_safis_with_no_safi_of_its_own
    plain = ['0001' + '0005' + '0102030405'].pack('H*')
    vpn   = ['0001' + '000d' + '00000064000000c8' + '0102030405'].pack('H*')
    assert_equal(9, BGP::Link_state.nlri_size(plain))
    assert_equal(plain.size, BGP::Link_state.nlri_size(plain))
    assert_equal(17, BGP::Link_state.nlri_size(vpn))
    assert_equal(vpn.size, BGP::Link_state.nlri_size(vpn))
  end

  def test_nlri_size_counts_the_four_framing_octets
    assert_equal(4, BGP::Link_state.nlri_size(['00010000'].pack('H*')))
  end

  def test_nlri_size_answers_nil_for_octets_too_short_to_frame
    [nil, '', 'ff', 'ffff', 'ffffff'].each do |hex|
      s = hex.nil? ? nil : [hex].pack('H*')
      assert_nil(BGP::Link_state.nlri_size(s),
                 "#{hex.inspect} should not frame an NLRI")
    end
  end

  # --- the SAFI is a parse-time input ----------------------------------

  # **The two readings of one capture, which is why the SAFI has to be
  # passed in.** Nothing in the octets says whether an RD is there:
  # figures 5 and 6 differ by eight octets and by nothing a reader can
  # see. So the same octets read as SAFI 71 put the RD inside the body,
  # and both readings replay byte for byte.
  def test_the_same_octets_read_two_ways_by_safi
    hex = '0001' + '000d' + '00000064000000c8' + '0102030405'
    plain = BGP::Link_state.new_ntop([hex].pack('H*'))
    vpn = BGP::Link_state.new_ntop([hex].pack('H*'), IANA::SAFI::BGP_LS_VPN)
    assert_equal(false, plain.vpn?)
    assert_nil(plain.rd)
    assert_equal('00000064000000c80102030405',
                 plain.nlri.value.unpack1('H*'))
    assert(vpn.vpn?)
    assert_equal('0102030405', vpn.nlri.value.unpack1('H*'))
    assert_equal(hex, plain.to_shex)
    assert_equal(hex, vpn.to_shex)
  end

  def test_safi_71_is_the_default
    n = BGP::Link_state.new_ntop(['00010000'].pack('H*'))
    assert_equal(IANA::SAFI::BGP_LS, n.safi)
    assert_equal(false, n.vpn?)
  end

  # A VPN body too short to hold a whole RD keeps every octet it has and
  # gets no RD at all, so it still replays. Ordinary negative testing
  # rather than a malformed capture.
  def test_a_vpn_body_too_short_for_an_rd_keeps_its_octets
    hex = '0001' + '0006' + '010203040506'
    n = BGP::Link_state.new_ntop([hex].pack('H*'), IANA::SAFI::BGP_LS_VPN)
    assert_nil(n.rd)
    assert_equal('010203040506', n.nlri.value.unpack1('H*'))
    assert_equal(hex, n.to_shex)
  end

  # Eight octets exactly is a whole RD and an empty body.
  def test_a_vpn_body_of_exactly_an_rd_has_an_empty_type_specific_part
    hex = '0001' + '0008' + '00000064000000c8'
    n = BGP::Link_state.new_ntop([hex].pack('H*'), IANA::SAFI::BGP_LS_VPN)
    assert_equal('RD=100:200', n.rd.to_s(false))
    assert_equal('', n.nlri.value)
    assert_equal(hex, n.to_shex)
  end

  # --- a Length that lies ----------------------------------------------

  def test_a_length_that_overruns_is_clamped_and_kept
    hex = '0001' + 'ffff' + '0102'
    n = BGP::Link_state.new_ntop([hex].pack('H*'))
    assert_equal(65535, n.declared_len)
    assert_equal(65535, n.length)
    assert_equal('0102', n.nlri.value.unpack1('H*'))
    assert_equal(hex, n.to_shex)
  end

  def test_a_length_that_agrees_records_no_declared_length
    n = BGP::Link_state.new_ntop(['000100020102'].pack('H*'))
    assert_nil(n.declared_len)
  end

  # A Length shorter than what arrived takes only what it claims and
  # leaves the rest, so a second NLRI behind it is read by the caller
  # rather than swallowed here.
  def test_a_length_shorter_than_the_octets_leaves_the_rest
    s = ['000100020102' + '000200020304'].pack('H*').is_packed
    a = BGP::Link_state.new(s)
    assert_equal('000100020102', a.to_shex)
    assert_equal('000200020304', s.unpack1('H*'))
  end

  # --- path identifiers ------------------------------------------------

  # RFC 7911 section 3 prepends four octets to the NLRI, which is a
  # property of the session and not of this family.
  def test_a_path_identifier_rides_in_front
    hex = '0001' + '0002' + '0102'
    n = BGP::Link_state.new_ntop([hex].pack('H*'), IANA::SAFI::BGP_LS, 7)
    assert(n.extended?)
    assert_equal('00000007' + hex, n.to_shex)
    assert_equal(7, n.path_id)
  end

  def test_no_path_identifier_is_the_default
    assert_equal(false, BGP::Link_state.new_ntop(
      ['00010000'].pack('H*')).extended?)
  end

  # --- the registry ----------------------------------------------------

  # Part 1 implements no NLRI type, so every type reads back as
  # Unknown. `bgp_ls_doc_test.rb` is what fails when that stops being
  # true, so this case is about the parse answer and not about a count.
  def test_no_nlri_type_is_implemented_yet
    (1..4).each do |t|
      hex = format('%04x0002abcd', t)
      n = BGP::Link_state.new_ntop([hex].pack('H*'))
      assert_equal(BGP::Link_state::Unknown, n.nlri.class,
                   "type #{t} should still read back as Unknown")
      assert_equal(hex, n.to_shex)
    end
  end

  def test_a_registered_type_reads_back_as_its_own_class
    with_registered(Probe) do
      n = BGP::Link_state.new_ntop(['ea600004deadbeef'].pack('H*'))
      assert_equal(Probe, n.nlri.class)
      assert_equal(0xdeadbeef, n.nlri.n)
      assert_equal('ea600004deadbeef', n.to_shex)
      # And from field values, which is the branch that takes an NLRI
      # type instance and writes the framing around it.
      assert_equal('ea60000400000007',
                   BGP::Link_state.new(Probe.new(7)).to_shex)
    end
  end

  # **An NLRI type is kept only if it can give its own octets back.**
  # Probe reads four octets, so a two-octet body cannot be one and
  # falls back to Unknown rather than inventing the two it did not find.
  def test_a_body_a_registered_type_cannot_reproduce_falls_back
    with_registered(Probe) do
      hex = 'ea6000020102'
      n = BGP::Link_state.new_ntop([hex].pack('H*'))
      assert_equal(BGP::Link_state::Unknown, n.nlri.class)
      assert_equal(hex, n.to_shex)
    end
  end

  def test_registering_a_type_twice_raises
    with_registered(Probe) do
      other = Class.new(BGP::Link_state::Type) do
        const_set(:TYPE, 60000)
        const_set(:HASH_KEY, :other)
      end
      assert_raise(ArgumentError) { BGP::Link_state.register(other) }
    end
  end

  def test_registering_a_hash_key_twice_raises
    with_registered(Probe) do
      other = Class.new(BGP::Link_state::Type) do
        const_set(:TYPE, 60001)
        const_set(:HASH_KEY, :probe)
      end
      assert_raise(ArgumentError) { BGP::Link_state.register(other) }
    end
  end

  # --- Unknown, the four ways in ---------------------------------------

  def test_builds_from_an_nlri_type_instance
    n = BGP::Link_state.new(BGP::Link_state::Unknown.new(
      5, ['abcd'].pack('H*')))
    assert_equal('00050002abcd', n.to_shex)
  end

  def test_builds_from_a_hash
    n = BGP::Link_state.new(:unknown => { :type => 5, :value => 'abcd' })
    assert_equal('00050002abcd', n.to_shex)
  end

  def test_builds_from_wire_bytes
    assert_equal('00050002abcd',
                 BGP::Link_state.new_ntop(['00050002abcd'].pack('H*')).to_shex)
  end

  # **The copy carries the Path Identifier, which is the one part of
  # this the four families before this one get wrong.** `encode` writes
  # the RFC 7911 identifier in front of the NLRI and `parse` does not
  # expect one, so a copy made through `encode` alone reads those four
  # octets as a Type and a Length. `Evpn`, `Mcast_vpn`, `Flow_spec` and
  # `Rt_constrain` all answer garbage for that today.
  def test_builds_from_another_link_state
    a = BGP::Link_state.new_ntop(
      ['0001000d00000064000000c80102030405'].pack('H*'),
      IANA::SAFI::BGP_LS_VPN, 9)
    b = BGP::Link_state.new(a)
    assert_equal(a.to_shex, b.to_shex)
    assert_equal(a.safi, b.safi)
    assert_equal(9, b.path_id)
    assert_equal('RD=100:200', b.rd.to_s(false))
  end

  def test_builds_from_another_link_state_with_no_path_identifier
    a = BGP::Link_state.new_ntop(['00010002abcd'].pack('H*'))
    b = BGP::Link_state.new(a)
    assert_equal(a.to_shex, b.to_shex)
    assert_equal(false, b.extended?)
  end

  def test_refuses_an_argument_it_cannot_read
    assert_raise(ArgumentError) { BGP::Link_state.new }
    assert_raise(ArgumentError) { BGP::Link_state.new(42) }
    assert_raise(ArgumentError) { BGP::Link_state.new(:nonesuch => 1) }
  end

  def test_the_nlri_type_builds_from_another_instance_and_refuses_junk
    a = BGP::Link_state::Unknown.new(5, ['abcd'].pack('H*'))
    b = BGP::Link_state::Unknown.new(a)
    assert_equal(a.to_shex, b.to_shex)
    assert_equal('abcd', a.value.unpack1('H*'),
                 'copying must not empty the instance it copied')
    assert_raise(ArgumentError) { BGP::Link_state::Unknown.new }
    assert_raise(ArgumentError) { BGP::Link_state::Unknown.new(1, 2, 3) }
  end

  # The type-specific part answers its own hex, which is the Type base's
  # `to_shex` and is what a reader printing one field of an NLRI gets.
  def test_the_nlri_type_answers_its_own_hex
    n = BGP::Link_state.new_ntop(['00050002abcd'].pack('H*'))
    assert_equal('abcd', n.nlri.to_shex)
    assert_equal('00050002abcd', n.to_shex)
  end

  # One `Unknown` per level, which is the family of classes Conventions
  # describes, and the pair this family's naming hazard is about: a
  # bare `Unknown` inside `Link_state` resolves to the NLRI one and
  # inside `Link_state::Tlv` to the TLV one, so both are written in
  # full everywhere. Asserted here rather than in the TLV test file,
  # which requires `link_state_tlv` alone and stays independent of this
  # level, the way `mcast_vpn_route_test.rb` does.
  def test_the_two_unknown_classes_are_distinct
    assert_not_equal(BGP::Link_state::Unknown, BGP::Link_state::Tlv::Unknown)
    assert_equal(BGP::Link_state::Type, BGP::Link_state::Unknown.superclass)
    assert_equal(BGP::Link_state::Tlv,
                 BGP::Link_state::Tlv::Unknown.superclass)
  end

  def test_two_nlris_with_the_same_octets_are_equal
    a = BGP::Link_state.new_ntop(['00050002abcd'].pack('H*'))
    b = BGP::Link_state.new_ntop(['00050002abcd'].pack('H*'))
    c = BGP::Link_state.new_ntop(['00050002abce'].pack('H*'))
    assert_equal(a, b)
    assert_not_equal(a, c)
    assert_not_equal(a, 'not an nlri')
  end

  # A registered class that raises rather than answering octets falls
  # back to Unknown too, so a decoder bug costs the capture nothing.
  def test_a_registered_type_that_raises_falls_back
    raiser = Class.new(BGP::Link_state::Type) do
      const_set(:TYPE, 60002)
      const_set(:HASH_KEY, :raiser)
      def initialize(*) ; raise 'nope' ; end
    end
    with_registered(raiser) do
      hex = 'ea620002abcd'
      n = BGP::Link_state.new_ntop([hex].pack('H*'))
      assert_equal(BGP::Link_state::Unknown, n.nlri.class)
      assert_equal(hex, n.to_shex)
    end
  end

  # A registered type's hash round trip, through the NLRI's own build
  # path, so parts 2 and 3 have the shape they need already measured.
  def test_a_registered_type_round_trips_through_the_nlri_hash
    with_registered(Probe) do
      n = BGP::Link_state.new(:probe => { :n => 9 })
      assert_equal('ea60000400000009', n.to_shex)
      assert_equal({ :probe => { :n => 9 } }, n.to_hash)
      assert_equal(n.to_shex, BGP::Link_state.new(n.to_hash).to_shex)
    end
  end

  # An `Rd` instance in the hash is taken as it is, where an Array is
  # splatted. Both are shapes a test writes.
  def test_an_rd_instance_in_the_hash_is_taken_as_it_is
    n = BGP::Link_state.new(:unknown => { :type => 1, :value => 'abcd' },
                            :rd => BGP::Rd.new(100, 200))
    assert_equal('0001000a00000064000000c8abcd', n.to_shex)
  end

  # --- to_hash ---------------------------------------------------------

  # The two-places rule in Conventions: a working round trip is
  # asserted here and in test/unit/to_hash_catalog.rb. All four fields
  # the class carries are exercised, since an assertion that misses one
  # passes for the wrong reason.
  def test_rebuilds_from_its_own_hash_with_every_field_set
    hex = '0002' + 'ffff' + '00000064000000c8' + '0102030405'
    n = BGP::Link_state.new_ntop([hex].pack('H*'),
                                 IANA::SAFI::BGP_LS_VPN, 11)
    assert_equal({ :unknown => { :type => 2, :value => '0102030405' },
                   :rd => [100, 200],
                   :length => 65535,
                   :path_id => 11 }, n.to_hash)
    assert_equal(n.to_shex, BGP::Link_state.new(n.to_hash).to_shex)
  end

  # The hash carrying an RD is what says the NLRI is a VPN one, since a
  # hash has nowhere else to put the SAFI. `Flow_spec` answers the same
  # question the same way for SAFI 134.
  def test_an_rd_in_the_hash_makes_it_a_vpn_nlri
    n = BGP::Link_state.new(:unknown => { :type => 1, :value => 'abcd' },
                            :rd => [100, 200])
    assert(n.vpn?)
    assert_equal(IANA::SAFI::BGP_LS_VPN, n.safi)
    assert_equal('0001000a00000064000000c8abcd', n.to_shex)
  end

  # No RD, no declared length and no path id, so an ordinary NLRI
  # hashes as the one key it has always been. Same rule as `:tail` and
  # `:bits` elsewhere in the library.
  def test_an_ordinary_hash_carries_one_key
    n = BGP::Link_state.new_ntop(['00010002abcd'].pack('H*'))
    assert_equal({ :unknown => { :type => 1, :value => 'abcd' } },
                 n.to_hash)
  end

  # --- the code point ranges -------------------------------------------

  # Table 12 of section 7.1.1: 0 Reserved, 1 to 4 defined, 5 to 64999
  # unassigned, 65000 to 65535 Private Use. Every one of them parses
  # and replays, which section 5.2 requires outright.
  def test_every_nlri_type_parses_and_replays
    [0, 1, 4, 5, 64999, 65000, 65535].each do |t|
      hex = format('%04x0002abcd', t)
      n = BGP::Link_state.new_ntop([hex].pack('H*'))
      assert_equal(t, n.type)
      assert_equal(hex, n.to_shex)
    end
  end

  def test_the_private_use_range_is_what_table_12_gives
    assert_equal(65000, BGP::Link_state::Unknown::PRIVATE_USE.first)
    assert_equal(65535, BGP::Link_state::Unknown::PRIVATE_USE.last)
    assert_equal(false, BGP::Link_state::Unknown.new(64999, '').private_use?)
    assert(BGP::Link_state::Unknown.new(65000, '').private_use?)
  end

  # --- Unknown keeps opaque octets -------------------------------------

  # **It does not read TLVs out of the body**, which is the RFC's own
  # word and not a shortcut: section 5.2 says "An implementation MUST
  # handle unknown Link-State NLRI types as opaque objects". The body
  # here is a perfectly well formed TLV, and it still comes back as
  # octets, because nothing establishes that an unknown type's body is
  # a TLV list at all.
  def test_an_unknown_type_keeps_opaque_octets_and_frames_no_tlvs
    body = '01000004c0000201'
    n = BGP::Link_state.new_ntop([format('ea60%04x', body.size / 2) +
                                  body].pack('H*'))
    assert_equal(BGP::Link_state::Unknown, n.nlri.class)
    assert_equal(body, n.nlri.value.unpack1('H*'))
    assert_equal(false, n.nlri.respond_to?(:tlvs))
  end

  def test_to_s_says_which_kind_of_unknown_it_is
    plain = BGP::Link_state.new_ntop(['00050002abcd'].pack('H*'))
    assert_match(/Unknown NLRI type 5, 2 octets/, plain.to_s)
    priv = BGP::Link_state.new_ntop(['fde80002abcd'].pack('H*'))
    assert_match(/Private use NLRI type 65000/, priv.to_s)
    vpn = BGP::Link_state.new_ntop(
      ['0001000800000064000000c8'].pack('H*'), IANA::SAFI::BGP_LS_VPN)
    assert_match(/^RD=100:200 /, vpn.to_s)
    assert_match(/^\[9\] /, BGP::Link_state.new_ntop(
      ['00050002abcd'].pack('H*'), IANA::SAFI::BGP_LS, 9).to_s)
  end

  # --- the one refusal, and nothing else -------------------------------

  def test_a_length_the_field_cannot_hold_is_refused
    n = BGP::Link_state.new(BGP::Link_state::Unknown.new(1, 'x' * 70000))
    assert_raise(ArgumentError) { n.encode }
  end

  # **Nothing validates.** Four things no RFC allows, each building and
  # encoding, because that is the reason this library exists.
  def test_nothing_validates
    # NLRI type 0, which Table 12 reserves.
    assert_equal('00000000', BGP::Link_state.new(
      BGP::Link_state::Unknown.new(0, '')).to_shex)
    # A Total NLRI Length that disagrees with the body, built rather
    # than parsed.
    assert_equal('0001000a01',
                 BGP::Link_state.new(:unknown => { :type => 1,
                                                   :value => '01' },
                                     :length => 10).to_shex)
    # An RD on a SAFI 71 NLRI, which no RFC describes. The constructor
    # reads an `:rd` key as the VPN form, so the octet level route is
    # the one to use: the eight octets go in the body, which is what
    # Conventions means by the octet level staying open.
    n = BGP::Link_state.new(BGP::Link_state::Unknown.new(
      1, ['00000064000000c8' + 'abcd'].pack('H*')))
    assert_equal(false, n.vpn?)
    assert_equal('0001000a00000064000000c8abcd', n.to_shex)
    # An empty NLRI, type and length and nothing else.
    assert_equal('00010000', BGP::Link_state.new(
      BGP::Link_state::Unknown.new(1, '')).to_shex)
  end

  # Not a test method: a helper, kept below every test and with no
  # `private` above it, because a test method after `private` never
  # runs and nothing says so.
  def with_registered(klass)
    BGP::Link_state.register(klass)
    yield
  ensure
    BGP::Link_state::TYPES.delete(klass.type)
    BGP::Link_state::BY_KEY.delete(klass.hash_key)
  end

end
