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
require 'bgp/nlris/link_state_tlv'

# **RFC 9552 carries no worked example and no hex anywhere**, measured
# by reading it: the six occurrences of "0x" in the document are the
# OSPF route type values of section 5.2.3.1. So every expectation in
# this file is this reader's arithmetic from the Figure 4 field widths,
# not the document's own octets, which is the RFC 4684, RFC 6368 and
# RFC 6514 situation rather than the flow spec one. Those three families
# cost nine wrong hand-written length expectations between them, every
# one of them the library being right, so the hex here is written out
# field by field in a comment beside each case and the arithmetic is
# the thing to doubt first.
class TestLinkStateTlv < Test::Unit::TestCase

  include BGP

  # **The type numbers here cannot expire, and part 1 chose ones that
  # did.** Every case below that is about a type with no registered
  # class uses 255 or 254, because Table 17 of section 7.1.7 reserves
  # TLV code points 0 to 255 and says they are "not to be allocated":
  # no document will ever define one and no part of this plan can
  # register a class for one.
  #
  # Part 1 used 256, 513 and 1024 for the same cases, which are a node
  # descriptor, a node descriptor sub-TLV and a node attribute, so part
  # 2 broke four of them the day the first descriptor landed and part 5
  # would have broken another. That is the fifth expiring example in
  # this plan after the four `docs/mcast-vpn.md` records, and the
  # lesson there was already written down: pick an example that cannot
  # expire rather than re-pointing it again.
  UNREGISTERED = 255
  UNREGISTERED_LOWER = 254

  # A registered TLV class, for the parts of this file that are about
  # the registry and about a type the library does implement. Nested in
  # the test class so it is invisible to `BGP.constants`, which is what
  # the to_hash catalog and the doc test both walk.
  #
  # Full class names inside it: a nested class does not see the
  # `include` in the class around it, which Conventions records.
  class Probe < BGP::Link_state::Tlv

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

  # --- section 5.1, the framing ----------------------------------------

  # Type 255 (0x00ff), length 4, value c0000201.
  def test_the_triplet_is_two_octets_two_octets_and_the_value
    t = BGP::Link_state::Tlv::Unknown.new(255, ['c0000201'].pack('H*'))
    assert_equal('00ff0004c0000201', t.to_shex)
    assert_equal(8, t.size)
  end

  # Section 5.1: "The Length field defines the length of the value
  # portion in octets (thus, a TLV with no value portion would have a
  # length of zero)."
  def test_a_tlv_with_no_value_has_a_length_of_zero
    t = BGP::Link_state::Tlv::Unknown.new(255, '')
    assert_equal('00ff0000', t.to_shex)
    assert_equal(0, t.length)
    assert_equal(4, t.size)
  end

  # Section 5.1: "The TLV is not padded to 4-octet alignment." A
  # one-octet value gives a five-octet TLV and not an eight-octet one,
  # which is where the neighbouring IGP encodings differ.
  def test_the_tlv_is_not_padded_to_four_octet_alignment
    t = BGP::Link_state::Tlv::Unknown.new(255, ['ff'].pack('H*'))
    assert_equal('00ff 00 01 ff'.delete(' '), t.to_shex)
    assert_equal(5, t.size)
  end

  # The Length counts the value and not the framing, so a 4-octet value
  # is length 4 in an 8-octet TLV. Stated as its own case because
  # counting the framing in is the commonest way to get a TLV length
  # wrong, and it reads plausibly either way.
  def test_the_length_counts_the_value_and_not_the_framing
    t = BGP::Link_state::Tlv::Unknown.new(255, ['0a0b0c0d'].pack('H*'))
    assert_equal(4, t.length)
    assert_equal(8, t.encode.size)
    assert_equal(4, t.encode[2, 2].unpack1('n'))
  end

  # --- factory, and the bounded parse ----------------------------------

  def test_factory_reads_one_tlv_and_leaves_the_rest
    s = ['00ff0004c000020100ff0002abcd'].pack('H*').is_packed
    t = BGP::Link_state::Tlv.factory(s)
    assert_equal('00ff0004c0000201', t.to_shex)
    assert_equal('00ff0002abcd', s.unpack1('H*'))
  end

  # Fewer than four octets cannot frame a TLV, so the list loop stops
  # and the caller keeps them as a tail rather than reading a Type out
  # of them.
  def test_factory_answers_nil_for_octets_too_short_to_frame
    [0, 1, 2, 3].each do |n|
      s = (['ff'] * n).join
      assert_nil(BGP::Link_state::Tlv.factory([s].pack('H*').is_packed),
                 "#{n} octets should not frame a TLV")
    end
  end

  def test_factory_answers_nil_for_nil
    assert_nil(BGP::Link_state::Tlv.factory(nil))
  end

  # A Length larger than what arrived takes what arrived and keeps the
  # Length it was told, so encode replays the peer's own claim. That is
  # the Evpn and Mcast_vpn rule and it is what makes a malformed
  # capture replayable.
  def test_a_length_that_overruns_is_clamped_and_kept
    hex = '00ff270f0102'          # type 256, length 9999, two octets
    t = BGP::Link_state::Tlv.factory([hex].pack('H*').is_packed)
    assert_equal(9999, t.declared_len)
    assert_equal(9999, t.length)
    assert_equal('0102', t.value.unpack1('H*'))
    assert_equal(hex, t.to_shex)
  end

  def test_a_length_that_agrees_records_no_declared_length
    t = BGP::Link_state::Tlv.factory(['00ff0002abcd'].pack('H*').is_packed)
    assert_nil(t.declared_len)
  end

  # --- parse_list ------------------------------------------------------

  def test_parse_list_reads_every_tlv_in_order
    hex = '00ff0004c0000201' + '00fe0000' + 'fde8000401020304'
    s = [hex].pack('H*').is_packed
    l = BGP::Link_state::Tlv.parse_list(s)
    assert_equal(3, l.size)
    assert_equal([255, 254, 65000], l.collect { |t| t.type })
    assert_equal(hex, l.collect { |t| t.to_shex }.join)
    assert_equal(0, s.size, 'parse_list should consume what it read')
  end

  # Octets that cannot frame a TLV are left where they are, so the
  # caller above keeps them as a tail. Three octets is the widest such
  # remainder there can be.
  def test_parse_list_leaves_a_short_tail_alone
    s = ['00ff0002abcd' + 'ffffff'].pack('H*').is_packed
    l = BGP::Link_state::Tlv.parse_list(s)
    assert_equal(1, l.size)
    assert_equal('ffffff', s.unpack1('H*'))
  end

  # **The two ways the loop could stall**, and section 5.1 permits the
  # first outright, so neither is hypothetical: a Length of 0 still
  # consumes the four framing octets, and a Length that overruns takes
  # everything left so the next call sees nothing.
  def test_a_zero_length_tlv_makes_progress
    s = ['00ff0000' * 3].pack('H*').is_packed
    l = BGP::Link_state::Tlv.parse_list(s)
    assert_equal(3, l.size)
    assert_equal(0, s.size)
  end

  def test_a_length_that_overruns_ends_the_list
    s = ['00ffffff0102'].pack('H*').is_packed
    l = BGP::Link_state::Tlv.parse_list(s)
    assert_equal(1, l.size)
    assert_equal(0, s.size)
  end

  # --- section 5.1, the ordering rule ----------------------------------

  def test_ascending_by_type_is_ordered
    a = BGP::Link_state::Tlv::Unknown.new(255, 'a')
    b = BGP::Link_state::Tlv::Unknown.new(257, 'a')
    assert(BGP::Link_state::Tlv.ordered?([a, b]))
    assert_equal(false, BGP::Link_state::Tlv.ordered?([b, a]))
  end

  # "If there are multiple TLVs of the same type within a single NLRI,
  # then the TLVs sharing the same type MUST be first in ascending
  # order based on the Length field".
  def test_the_same_type_orders_by_length_next
    a = BGP::Link_state::Tlv::Unknown.new(255, ['01'].pack('H*'))
    b = BGP::Link_state::Tlv::Unknown.new(255, ['0000'].pack('H*'))
    assert(BGP::Link_state::Tlv.ordered?([a, b]),
           'a shorter value sorts first even when its bytes are larger')
    assert_equal(false, BGP::Link_state::Tlv.ordered?([b, a]))
  end

  # "followed by ascending order based on the Value field. Comparison
  # of the Value fields is performed by treating the entire field as
  # opaque binary data and ordered lexicographically (i.e., treating
  # each byte of binary data as a symbol to compare, with the symbols
  # ordered by their numerical value)."
  #
  # The pair is 0x7f against 0x80 on purpose: a comparison that was not
  # by numerical byte value is most likely to disagree across the
  # signed boundary.
  def test_the_same_type_and_length_order_by_value_bytewise
    a = BGP::Link_state::Tlv::Unknown.new(255, ['7f'].pack('H*'))
    b = BGP::Link_state::Tlv::Unknown.new(255, ['80'].pack('H*'))
    assert(BGP::Link_state::Tlv.ordered?([a, b]))
    assert_equal(false, BGP::Link_state::Tlv.ordered?([b, a]))
  end

  def test_the_whole_value_is_compared_and_not_its_first_octet
    a = BGP::Link_state::Tlv::Unknown.new(255, ['0100'].pack('H*'))
    b = BGP::Link_state::Tlv::Unknown.new(255, ['01ff'].pack('H*'))
    assert(BGP::Link_state::Tlv.ordered?([a, b]))
    assert_equal(false, BGP::Link_state::Tlv.ordered?([b, a]))
  end

  # **The rule says the Length field, not the value's real size**, so a
  # TLV whose declared Length lies sorts by the lie. Worth its own case
  # because the readable implementation uses the real size and passes
  # every other ordering test here.
  def test_the_order_follows_the_length_field_and_not_the_real_size
    long = BGP::Link_state::Tlv.factory(['00ff270f01'].pack('H*').is_packed)
    short = BGP::Link_state::Tlv::Unknown.new(255, ['0000'].pack('H*'))
    assert_equal(9999, long.declared_len)
    assert_equal(1, long.value.size)
    assert(BGP::Link_state::Tlv.ordered?([short, long]),
           'the declared 9999 sorts behind a real 2')
    assert_equal(false, BGP::Link_state::Tlv.ordered?([long, short]))
  end

  def test_an_empty_list_and_a_single_tlv_are_ordered
    assert(BGP::Link_state::Tlv.ordered?([]))
    assert(BGP::Link_state::Tlv.ordered?(
      [BGP::Link_state::Tlv::Unknown.new(255, 'a')]))
  end

  # --- the registry ----------------------------------------------------

  # Part 1 implements no TLV type, so every TLV reads back as Unknown.
  # `bgp_ls_doc_test.rb` is what fails when that stops being true, so
  # this case is about the parse answer rather than about the count.
  # **The two type numbers this file leans on cannot be registered**,
  # which is what keeps every case above from expiring as part 1's did.
  # Both halves matter: the range is reserved by Table 17, and nothing
  # has registered one anyway.
  def test_the_example_types_cannot_expire
    [UNREGISTERED, UNREGISTERED_LOWER].each do |t|
      assert(BGP::Link_state::Tlv::Unknown::RESERVED.include?(t),
             "#{t} must be in the range Table 17 reserves")
      assert_nil(BGP::Link_state::Tlv::REGISTRY[t],
                 "#{t} must have no registered class")
      assert_equal(BGP::Link_state::Tlv::Unknown,
                   BGP::Link_state::Tlv.factory(
                     [format('%04x0002abcd', t)].pack('H*').is_packed).class)
    end
  end

  def test_a_registered_type_reads_back_as_its_own_class
    with_registered(Probe) do
      t = BGP::Link_state::Tlv.factory(['ea600004deadbeef'].pack('H*').is_packed)
      assert_equal(Probe, t.class)
      assert_equal(0xdeadbeef, t.n)
      assert_equal('ea600004deadbeef', t.to_shex)
    end
  end

  # A registered class writes its value and no framing of its own, so
  # the Length comes out of the one place that knows section 5.1.
  def test_a_registered_type_writes_no_framing_of_its_own
    with_registered(Probe) do
      assert_equal('ea60000400000007', Probe.new(7).to_shex)
      assert_equal(4, Probe.new(7).length)
    end
  end

  # **A registered type is kept only if it can give its own octets
  # back**, which is the rule Flow_spec, Evpn and Mcast_vpn each
  # record. Probe reads four octets, so a two-octet value cannot be one
  # and falls back to Unknown rather than inventing the two it did not
  # find.
  def test_a_value_a_registered_type_cannot_reproduce_falls_back
    with_registered(Probe) do
      hex = 'ea6000020102'
      t = BGP::Link_state::Tlv.factory([hex].pack('H*').is_packed)
      assert_equal(BGP::Link_state::Tlv::Unknown, t.class)
      assert_equal(hex, t.to_shex)
    end
  end

  def test_registering_a_type_twice_raises
    with_registered(Probe) do
      other = Class.new(BGP::Link_state::Tlv) do
        const_set(:TYPE, 60000)
        const_set(:HASH_KEY, :other)
      end
      assert_raise(ArgumentError) { BGP::Link_state::Tlv.register(other) }
    end
  end

  def test_registering_a_hash_key_twice_raises
    with_registered(Probe) do
      other = Class.new(BGP::Link_state::Tlv) do
        const_set(:TYPE, 60001)
        const_set(:HASH_KEY, :probe)
      end
      assert_raise(ArgumentError) { BGP::Link_state::Tlv.register(other) }
    end
  end

  def test_registering_the_same_class_twice_is_harmless
    with_registered(Probe) do
      assert_equal(Probe, BGP::Link_state::Tlv.register(Probe))
    end
  end

  # A hash whose key nothing knows raises rather than quietly building
  # a TLV of type 0, which is the Multicast_flags hazard Conventions
  # records: a class may refuse a hash, it may not accept one and build
  # something else.
  def test_a_hash_with_no_known_key_raises
    assert_raise(ArgumentError) do
      BGP::Link_state::Tlv.from_hash(:nonesuch => { :type => 1 })
    end
  end

  def test_from_hash_builds_a_registered_type
    with_registered(Probe) do
      t = BGP::Link_state::Tlv.from_hash(:probe => { :n => 9 })
      assert_equal(Probe, t.class)
      assert_equal('ea60000400000009', t.to_shex)
      assert_equal({ :probe => { :n => 9 } }, t.to_hash)
      assert_equal(t.to_shex,
                   BGP::Link_state::Tlv.from_hash(t.to_hash).to_shex)
    end
  end

  # --- Unknown, the four ways in ---------------------------------------

  def test_unknown_builds_from_field_values
    assert_equal('00ff0002abcd',
                 BGP::Link_state::Tlv::Unknown.new(
                   255, ['abcd'].pack('H*')).to_shex)
  end

  def test_unknown_builds_from_wire_bytes_through_the_factory
    hex = '00ff0002abcd'
    assert_equal(hex, BGP::Link_state::Tlv.factory(
      [hex].pack('H*').is_packed).to_shex)
  end

  def test_unknown_builds_from_another_instance
    a = BGP::Link_state::Tlv.factory(['00ff270f0102'].pack('H*').is_packed)
    b = BGP::Link_state::Tlv::Unknown.new(a)
    assert_equal(a.to_shex, b.to_shex)
    assert_equal(9999, b.declared_len)
    assert_equal('0102', a.value.unpack1('H*'),
                 'copying must not empty the instance it copied')
  end

  def test_unknown_refuses_an_argument_it_cannot_read
    assert_raise(ArgumentError) { BGP::Link_state::Tlv::Unknown.new }
    assert_raise(ArgumentError) { BGP::Link_state::Tlv::Unknown.new(1, 2, 3) }
  end

  def test_two_tlvs_with_the_same_octets_are_equal
    a = BGP::Link_state::Tlv::Unknown.new(255, ['abcd'].pack('H*'))
    b = BGP::Link_state::Tlv::Unknown.new(255, ['abcd'].pack('H*'))
    c = BGP::Link_state::Tlv::Unknown.new(255, ['abce'].pack('H*'))
    assert_equal(a, b)
    assert_not_equal(a, c)
    assert_not_equal(a, 'not a tlv')
  end

  # A registered class that raises rather than answering octets falls
  # back to Unknown too, so a decoder bug costs the capture nothing.
  # That is the `rescue StandardError` in `read_tlv`, which is there
  # for the same reason `Path_attribute` has one: bgp4r's own gap is
  # not the peer's error.
  def test_a_registered_type_that_raises_falls_back
    raiser = Class.new(BGP::Link_state::Tlv) do
      const_set(:TYPE, 60002)
      const_set(:HASH_KEY, :raiser)
      def initialize(*) ; raise 'nope' ; end
    end
    with_registered(raiser) do
      hex = 'ea620002abcd'
      t = BGP::Link_state::Tlv.factory([hex].pack('H*').is_packed)
      assert_equal(BGP::Link_state::Tlv::Unknown, t.class)
      assert_equal(hex, t.to_shex)
    end
  end

  # --- to_s ------------------------------------------------------------

  def test_to_s_says_which_kind_of_tlv_it_is
    plain = BGP::Link_state::Tlv::Unknown.new(255, ['abcd'].pack('H*'))
    assert_equal('Unknown TLV 255, 2 octets [abcd]', plain.to_s)
    empty = BGP::Link_state::Tlv::Unknown.new(255, '')
    assert_equal('Unknown TLV 255, 0 octets', empty.to_s)
    priv = BGP::Link_state::Tlv::Unknown.new(65000, ['00000a4c'].pack('H*'))
    assert_equal('Private use TLV 65000, 4 octets [00000a4c], ' \
                 'enterprise 2636', priv.to_s)
    short = BGP::Link_state::Tlv::Unknown.new(65000, ['01'].pack('H*'))
    assert_equal('Private use TLV 65000, 1 octets [01]', short.to_s)
  end

  # --- to_hash ---------------------------------------------------------

  # The two-places rule in Conventions: a working round trip is
  # asserted here and in test/unit/to_hash_catalog.rb. Every field the
  # class carries is exercised, the declared length included, since an
  # assertion that misses a field passes for the wrong reason.
  def test_unknown_rebuilds_from_its_own_hash
    t = BGP::Link_state::Tlv.factory(['00ff270f0102'].pack('H*').is_packed)
    assert_equal({ :unknown => { :type => 255, :value => '0102' },
                   :length => 9999 }, t.to_hash)
    assert_equal(t.to_shex,
                 BGP::Link_state::Tlv::Unknown.new(t.to_hash).to_shex)
    assert_equal(t.to_shex, BGP::Link_state::Tlv.from_hash(t.to_hash).to_shex)
  end

  # No declared length, no key, so an ordinary TLV hashes as the plain
  # pair it has always been. That is the same rule as `:tail` and
  # `:bits` elsewhere in the library.
  def test_an_ordinary_hash_carries_no_length_key
    t = BGP::Link_state::Tlv::Unknown.new(255, ['abcd'].pack('H*'))
    assert_equal({ :unknown => { :type => 255, :value => 'abcd' } },
                 t.to_hash)
  end

  # A bare field hash is what a test writes, where to_hash answers the
  # wrapped form. Both build, which Conventions records as the ordinary
  # state of affairs rather than an asymmetry to fix.
  def test_a_bare_field_hash_builds_too
    t = BGP::Link_state::Tlv::Unknown.new(:type => 255, :value => 'abcd',
                                          :length => 9999)
    assert_equal('00ff270fabcd', t.to_shex)
  end

  # --- the two code point ranges ---------------------------------------

  # Table 17 of section 7.1.7: "65000-65535 | Private Use", and section
  # 5.4 puts a 4-octet Enterprise Code first in such a TLV's value.
  # The Enterprise Code here is 2636, Juniper's, so the expectation is
  # checkable against the IANA Private Enterprise Numbers registry
  # rather than against this reader's arithmetic alone.
  #
  # **The first draft of this case used 0x00013039 and asserted 77865,
  # which is wrong: it is 77881.** The file header above says the
  # arithmetic is the thing to doubt first and it was right within the
  # hour, which is the eleventh such miss across the five families of
  # this plan and the library being right every time.
  def test_a_private_use_tlv_reads_its_enterprise_code
    t = BGP::Link_state::Tlv.factory(
      ['fde80006' + '00000a4c' + '0102'].pack('H*').is_packed)
    assert(t.private_use?)
    assert_equal(2636, t.enterprise_code)
    assert_equal('fde8000600000a4c0102', t.to_shex)
  end

  def test_the_private_use_range_is_what_table_17_gives
    assert_equal(65000, BGP::Link_state::Tlv::Unknown::PRIVATE_USE.first)
    assert_equal(65535, BGP::Link_state::Tlv::Unknown::PRIVATE_USE.last)
    assert_equal(false, BGP::Link_state::Tlv::Unknown.new(64999, '').private_use?)
    assert(BGP::Link_state::Tlv::Unknown.new(65000, '').private_use?)
  end

  # The reader answers nil rather than refusing, so a private-use TLV
  # too short to hold an Enterprise Code still replays.
  def test_a_private_use_tlv_too_short_for_an_enterprise_code_replays
    hex = 'fde80003010203'
    t = BGP::Link_state::Tlv.factory([hex].pack('H*').is_packed)
    assert_nil(t.enterprise_code)
    assert_equal(hex, t.to_shex)
  end

  def test_a_type_outside_the_private_use_range_has_no_enterprise_code
    t = BGP::Link_state::Tlv::Unknown.new(255, ['00013039'].pack('H*'))
    assert_nil(t.enterprise_code)
  end

  # Table 17 again: "0-255 | Reserved (not to be allocated)". So a TLV
  # type under 256 is one no document will ever define, and it parses
  # and replays from Unknown like any other.
  def test_a_type_in_the_reserved_range_parses_and_replays
    hex = '00ff0002abcd'
    t = BGP::Link_state::Tlv.factory([hex].pack('H*').is_packed)
    assert_equal(255, t.type)
    assert_equal(hex, t.to_shex)
    assert_equal(255, BGP::Link_state::Tlv::Unknown::RESERVED.last)
  end

  # --- the one refusal, and nothing else ------------------------------

  # The kind Conventions allows: a length the two-octet field cannot
  # hold cannot be written at all, so packing it would put a different
  # length on the wire than the caller asked for. Flow_spec refuses an
  # RFC 8955 section 4.1 length over 4095 in the same place.
  def test_a_length_the_field_cannot_hold_is_refused
    t = BGP::Link_state::Tlv::Unknown.new(255, 'x' * 70000)
    assert_raise(ArgumentError) { t.encode }
    t2 = BGP::Link_state::Tlv::Unknown.new(:type => 256, :value => 'ab',
                                           :length => 70000)
    assert_raise(ArgumentError) { t2.encode }
  end

  def test_a_length_at_the_limit_encodes
    t = BGP::Link_state::Tlv::Unknown.new(255, 'x' * 0xffff)
    assert_equal(0xffff + 4, t.encode.size)
  end

  # **Nothing validates.** Six things no RFC allows, each building and
  # encoding, because that is the reason this library exists.
  def test_nothing_validates
    # A type IANA reserves and will never allocate.
    assert_equal('00000000', BGP::Link_state::Tlv::Unknown.new(0, '').to_shex)
    # A Length that disagrees with the value, built rather than parsed.
    assert_equal('00ff000a01',
                 BGP::Link_state::Tlv::Unknown.new(
                   :type => 255, :value => '01', :length => 10).to_shex)
    # The same type twice in a row.
    a = BGP::Link_state::Tlv::Unknown.new(254, ['01'].pack('H*'))
    assert_equal(a.to_shex * 2, [a, a].collect { |t| t.to_shex }.join)
    # Descending order, which section 5.1 makes malformed in an NLRI.
    b = BGP::Link_state::Tlv::Unknown.new(255, ['01'].pack('H*'))
    assert_equal(false, BGP::Link_state::Tlv.ordered?([b, a]))
    assert_equal('00ff0001' + '01' + '00fe0001' + '01',
                 [b, a].collect { |t| t.to_shex }.join)
    # A private-use type with no Enterprise Code in it at all.
    assert_equal('fde80000', BGP::Link_state::Tlv::Unknown.new(65000, '').to_shex)
  end

  # --- this level on its own -------------------------------------------

  # **Nothing here reaches the NLRI level**, which is why this file
  # requires `link_state_tlv` alone and no test in it mentions
  # `Link_state::Unknown` or `Link_state::Type`. That is the
  # independence `mcast_vpn_route_test.rb` keeps by putting
  # `Leaf_a_d`'s tests in the NLRI file instead, and it is worth
  # keeping for the same reason: it is what says the TLV is a
  # primitive rather than half of a pair. The cross-level assertions,
  # including that the two `Unknown` classes are distinct, are in
  # `link_state_test.rb` and in `bgp_ls_doc_test.rb`.
  def test_the_tlv_level_needs_nothing_from_the_nlri_level
    assert_equal(BGP::Link_state::Tlv,
                 BGP::Link_state::Tlv::Unknown.superclass)
    assert_equal(Object, BGP::Link_state::Tlv.superclass)
  end

  # --- the four shared bases, part 5b-i --------------------------------

  # **This file is required on its own, so this is the whole content of
  # the move.** Before part 5b-i, requiring `link_state_tlv` alone gave
  # you `Tlv` and `Tlv::Unknown`; `Opaque32` came with the node
  # descriptors, `Addr_tlv` with the link descriptors and `Opaque_tlv`
  # with the node attributes. A TLV class in any of the family's files
  # now has its base from here, which is what stops a fourth file
  # requiring a third one sideways for a value shape.
  def test_this_file_defines_the_four_shared_bases
    [:Opaque32, :Addr_tlv, :Opaque_tlv, :Text_tlv].each do |name|
      assert(BGP::Link_state::Tlv.const_defined?(name, false),
             "Link_state::Tlv must define #{name} in link_state_tlv.rb")
      assert_equal(BGP::Link_state::Tlv,
                   BGP::Link_state::Tlv.const_get(name).superclass,
                   "#{name} is a base directly under Tlv")
    end
  end

  # Each is abstract: it supplies the value shape and no identity, so
  # `type`, `hash_key` and therefore `encode` all read a constant it
  # does not define. That is why each has a NO_RECIPE entry in
  # `to_hash_catalog.rb` rather than a round trip.
  def test_each_shared_base_is_abstract
    [BGP::Link_state::Tlv::Opaque32,
     BGP::Link_state::Tlv::Addr_tlv,
     BGP::Link_state::Tlv::Opaque_tlv,
     BGP::Link_state::Tlv::Text_tlv,
    ].each do |klass|
      assert_raise(NameError, klass.to_s) { klass.type }
      assert_raise(NameError, klass.to_s) { klass.hash_key }
    end
  end

  # And none of them is registered, so a base cannot read back as a TLV
  # type of its own. `Prefix_nlri` has the same guard one level up.
  def test_no_shared_base_is_registered
    bases = [BGP::Link_state::Tlv::Opaque32,
             BGP::Link_state::Tlv::Addr_tlv,
             BGP::Link_state::Tlv::Opaque_tlv,
             BGP::Link_state::Tlv::Text_tlv]
    assert_equal([], BGP::Link_state::Tlv::REGISTRY.values & bases)
    assert_equal([], BGP::Link_state::Tlv::BY_KEY.values & bases)
  end

  # A base is usable from here with three constants on top, which is
  # what every TLV class in the family is. Built and parsed through the
  # registry, so this exercises the shape rather than restating it.
  def test_a_base_takes_three_constants_and_works
    klass = Class.new(BGP::Link_state::Tlv::Opaque32) do
      const_set(:TYPE, 60200)
      const_set(:HASH_KEY, :tlv_test_opaque)
      const_set(:LABEL, 'Probe')
    end
    with_registered(klass) do
      t = klass.new(65000)
      assert_equal('eb28' + '0004' + '0000fde8', t.to_shex)
      assert_equal('Probe 65000', t.to_s)
      assert_equal(t.to_shex,
                   BGP::Link_state::Tlv.factory([t.to_shex].pack('H*')).to_shex)
      assert_equal(t.to_shex, klass.new(t.to_hash).to_shex)
    end
  end

  # Not a test method: a helper, kept below every test and with no
  # `private` above it, because a test method after `private` never
  # runs and nothing says so.
  def with_registered(klass)
    BGP::Link_state::Tlv.register(klass)
    yield
  ensure
    BGP::Link_state::Tlv::REGISTRY.delete(klass.type)
    BGP::Link_state::Tlv::BY_KEY.delete(klass.hash_key)
  end

end
