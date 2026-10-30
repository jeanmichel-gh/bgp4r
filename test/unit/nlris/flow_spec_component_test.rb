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

# The Flow Specification components of RFC 8955 section 4.2.2 and RFC
# 8956 section 3.
#
#   ruby -I. test/unit/nlris/flow_spec_component_test.rb
#
# The load bearing tests here are the five worked examples the two RFCs
# print: three in RFC 8955 section 4.3 and two in RFC 8956 section 3.8.
# Each gives the octets a correct encoder produces for a flow it
# describes in words, so building from values and comparing to the
# document's own hex is the one check that cannot pass for the wrong
# reason. Four hand written expectations were wrong while this was
# written and the RFC's hex caught every one.
#
# BGP:: names are written out in full, see Conventions in CLAUDE.md.

require 'test/unit'
require 'bgp/nlris/flow_spec_component'

class FlowSpecComponentTest < Test::Unit::TestCase

  def wire(hex)
    [hex].pack('H*').is_packed
  end

  # Parse a component from its value octets, which is what the type octet
  # leaves behind and what a component's own new reads.
  def from_value(klass, hex)
    klass.new(wire(hex)[1..-1].is_packed)
  end

  # RFC 8955 section 4.3.1: "all packets to 192.0.2.0/24 and TCP port
  # 25", encoded 0b 01 18 c0 00 02 03 81 06 04 81 19 where 0b is the
  # section 4.1 length and the rest is the three components.
  def test_the_rfc_8955_example_1_components
    assert_equal('0118c00002',
                 BGP::Flow_spec::Destination_prefix.new('192.0.2.0/24').to_shex)
    assert_equal('038106', BGP::Flow_spec::Ip_protocol.new(:eq, 6).to_shex)
    assert_equal('048119', BGP::Flow_spec::Port.new(:eq, 25).to_shex)
  end

  # RFC 8955 section 4.3.2: "all packets to 192.0.2.0/24 from
  # 203.0.113.0/24 and port {range [137, 139] or 8080}". The port
  # component is the hardest shape the API carries: three pairs, mixed
  # operators, an AND bit and a two octet value, and the document decodes
  # its three operator octets as ">=", "AND <=" and "end-of-list, value
  # size=2, ==".
  def test_the_rfc_8955_example_2_components
    assert_equal('0118c00002',
                 BGP::Flow_spec::Destination_prefix.new('192.0.2.0/24').to_shex)
    assert_equal('0218cb0071',
                 BGP::Flow_spec::Source_prefix.new('203.0.113.0/24').to_shex)
    assert_equal('040389458b911f90',
                 BGP::Flow_spec::Port.new([:ge, 137], [:and_le, 139], [:eq, 8080]).to_shex)
  end

  # RFC 8955 section 4.3.3: "all packets to 192.0.2.1/32 and fragment
  # { DF or FF }", whose bitmask the document decodes as "DF=1, FF=1".
  def test_the_rfc_8955_example_3_components
    assert_equal('0120c0000201',
                 BGP::Flow_spec::Destination_prefix.new('192.0.2.1/32').to_shex)
    frag = BGP::Flow_spec::Fragment
    assert_equal('0c8005', frag.new(:any, frag::DF | frag::FF).to_shex)
    assert_equal(0x05, frag::DF | frag::FF)
  end

  # RFC 8956 section 3.8.1: "packets from ::1234:5678:9a00:0/64-104 to
  # 2001:db8::/32 and upper-layer protocol tcp".
  def test_the_rfc_8956_example_1_components
    assert_equal('01200020010db8',
                 BGP::Flow_spec::Destination_ipv6_prefix.new('2001:db8::/32').to_shex)
    assert_equal('026840123456789a',
                 BGP::Flow_spec::Source_ipv6_prefix.new('::1234:5678:9a00:0/104', 64).to_shex)
    assert_equal('038106', BGP::Flow_spec::Upper_layer_protocol.new(:eq, 6).to_shex)
  end

  # RFC 8956 section 3.8.2: "all packets from ::1234:5678:9a00:0/65-104
  # to 2001:db8::/32". The source pattern is 39 bits, so the document
  # says its last octet "contains 1 bit of padding".
  def test_the_rfc_8956_example_2_components
    assert_equal('0268412468acf134',
                 BGP::Flow_spec::Source_ipv6_prefix.new('::1234:5678:9a00:0/65-104').to_shex)
  end

  # Both forms of section 3.1's note: "ipv6address/length if offset is 0
  # or ipv6address/offset-length".
  def test_the_two_ipv6_prefix_notations_agree
    a = BGP::Flow_spec::Source_ipv6_prefix.new('::1234:5678:9a00:0/65-104')
    b = BGP::Flow_spec::Source_ipv6_prefix.new('::1234:5678:9a00:0/104', 65)
    assert_equal(a.to_shex, b.to_shex)
    assert_equal(65, a.offset)
    assert_equal(104, a.length)
    assert_equal('::1234:5678:9a00:0/65-104', a.prefix)
    assert_equal('2001:db8::/32',
                 BGP::Flow_spec::Destination_ipv6_prefix.new('2001:db8::/32').prefix)
  end

  RFC_EXAMPLES = [
    [BGP::Flow_spec::Destination_prefix,      '0118c00002'],
    [BGP::Flow_spec::Source_prefix,           '0218cb0071'],
    [BGP::Flow_spec::Ip_protocol,             '038106'],
    [BGP::Flow_spec::Port,                    '048119'],
    [BGP::Flow_spec::Port,                    '040389458b911f90'],
    [BGP::Flow_spec::Destination_prefix,      '0120c0000201'],
    [BGP::Flow_spec::Fragment,                '0c8005'],
    [BGP::Flow_spec::Destination_ipv6_prefix, '01200020010db8'],
    [BGP::Flow_spec::Source_ipv6_prefix,      '026840123456789a'],
    [BGP::Flow_spec::Source_ipv6_prefix,      '0268412468acf134'],
  ].freeze

  def test_every_rfc_example_parses_back_and_re_encodes
    RFC_EXAMPLES.each do |klass, hex|
      assert_equal(hex, from_value(klass, hex).to_shex,
                   "#{klass} did not give back #{hex}")
    end
  end

  # RFC 8955 section 4.2.1.1, Table 1, "Comparison Operation
  # Combinations", read as the three bits lt, gt and eq. The octet is
  # e|a|len|0|lt|gt|eq, so with the end-of-list bit set and a one octet
  # value the low nibble is the table's row number.
  def test_the_numeric_operator_is_rfc_8955_table_1
    { :false => 0, :eq => 1, :gt => 2, :ge => 3,
      :lt => 4, :le => 5, :ne => 6, :true => 7 }.each do |sym, bits|
      octet = [BGP::Flow_spec::Port.new(sym, 0).to_shex[2, 2]].pack('H*').unpack1('C')
      assert_equal(0x80 | bits, octet, "#{sym} should be low nibble #{bits}")
    end
  end

  # RFC 8955 section 4.2.1.2: not is bit 6 and m is bit 7, so the two
  # low bits are (not << 1) | m.
  def test_the_bitmask_operator_is_rfc_8955_figure_3
    { :any => 0, :match => 1, :not_any => 2, :not_match => 3 }.each do |sym, bits|
      octet = [BGP::Flow_spec::Tcp_flags.new(sym, 0).to_shex[2, 2]].pack('H*').unpack1('C')
      assert_equal(0x80 | bits, octet, "#{sym} should be low two bits #{bits}")
    end
  end

  # RFC 8955 section 4.2.1.1: "e (end-of-list bit): Set in the last {op,
  # value} pair in the list".
  def test_the_end_of_list_bit_goes_on_the_last_pair_only
    s = BGP::Flow_spec::Port.new([:eq, 1], [:eq, 2], [:eq, 3]).to_shex
    assert_equal('0401010102810 3'.delete(' '), s)
    octets = [s].pack('H*').bytes
    assert_equal([0x01, 0x01, 0x81], [octets[1], octets[3], octets[5]])
  end

  # RFC 8955 section 4.2.1.1 on the AND bit: "If unset, the result of the
  # previous {op, value} pair is logically ORed with the current one. If
  # set, the operation is a logical AND."
  def test_the_and_bit_rides_in_the_operator_symbol
    plain = BGP::Flow_spec::Port.new([:le, 139], [:eq, 1]).to_shex
    anded = BGP::Flow_spec::Port.new([:and_le, 139], [:eq, 1]).to_shex
    assert_equal(0x40, [anded[2, 2]].pack('H*').unpack1('C') -
                       [plain[2, 2]].pack('H*').unpack1('C'))
    assert_equal(true, BGP::Flow_spec::Port.new(:and_eq, 1).pairs[0].and_bit)
    assert_equal(:eq, BGP::Flow_spec::Port.new(:and_eq, 1).pairs[0].op)
  end

  # RFC 8955 section 4.2.1.1: "The length of the value field for this
  # operator given as (1 << len). This encodes 1 (len=00), 2 (len=01), 4
  # (len=10), and 8 (len=11) octets." The smallest that holds the value
  # is what the RFC's own examples use: 25 in one octet, 8080 in two.
  def test_the_value_width_is_the_smallest_that_holds_it
    { 25 => 0, 255 => 0, 256 => 1, 8080 => 1, 0x10000 => 2,
      0xffffffff => 2, 0x1_0000_0000 => 3 }.each do |value, len|
      assert_equal(len, BGP::Flow_spec::Port.new(:eq, value).pairs[0].len,
                   "#{value} should take len #{len}")
    end
    assert_raise(ArgumentError) { BGP::Flow_spec::Port.new(:eq, 1 << 64) }
  end

  # RFC 8956 section 3.7: "Type 13 component values SHOULD be encoded as
  # 4-octet quantities (numeric_op len=10)". It is the one component
  # whose recommended width is wider than its values need, so a flow
  # label of 6 is four octets and not one.
  def test_the_flow_label_is_four_octets_even_for_a_small_value
    assert_equal('0da100000006', BGP::Flow_spec::Flow_label.new(:eq, 6).to_shex)
    assert_equal(2, BGP::Flow_spec::Flow_label.new(:eq, 6).pairs[0].len)
    assert_equal(0, BGP::Flow_spec::Port.new(:eq, 6).pairs[0].len)
  end

  # Conventions: building and encoding never validate. Every one of these
  # is something no RFC allows, and all of them have to reach the wire.
  def test_nothing_validates
    # RFC 8955 section 4.2.2.11 says DSCP MUST be a single octet.
    assert_equal('0bb10000000000000005',
                 BGP::Flow_spec::Dscp.new(:op => :eq, :value => 5, :len => 3).to_shex)
    # A list with no end-of-list bit anywhere.
    assert_equal('040119',
                 BGP::Flow_spec::Port.new(:op => :eq, :value => 25, :eol => false).to_shex)
    # Section 4.2.1.1: the first operator octet "MUST be encoded as unset".
    assert_equal('04c119', BGP::Flow_spec::Port.new(:and_eq, 25).to_shex)
    # Section 4.2.2.12 says Fragment MUST be a single octet.
    assert_equal('0c900005',
                 BGP::Flow_spec::Fragment.new(:op => :any, :value => 5, :len => 1).to_shex)
    # RFC 8956 section 3.6 reserves the bit IPv4 gives to DF.
    assert_equal('0c8001', BGP::Flow_spec::Ipv6_fragment.new(:any, 0x01).to_shex)
    # RFC 8956 section 3.1: "length MUST be in the range offset < length
    # < 129 or the component is malformed". This one has length < offset.
    assert_equal('020028', BGP::Flow_spec::Source_ipv6_prefix.new('::/0', 40).to_shex)
  end

  # RFC 8955 section 4.2.1.1 on bit 4 of the operator octet: "MUST be set
  # to 0 on NLRI encoding and MUST be ignored during decoding". Kept when
  # it arrives set, so a capture can be sent again, which is the rule
  # Conventions records for every reserved field here. 0x89 is example
  # 1's 0x81 with that bit on.
  def test_the_reserved_operator_bit_is_kept_and_written_back
    o = from_value(BGP::Flow_spec::Port, '048919')
    assert_equal('048919', o.to_shex)
    assert_equal(8, o.pairs[0].reserved)
    assert_equal(:eq, o.pairs[0].op)
    assert_equal(25, o.pairs[0].value)
    # Section 4.2.1.2 reserves two bits rather than one, 0x0c.
    b = from_value(BGP::Flow_spec::Fragment, '0c8c05')
    assert_equal('0c8c05', b.to_shex)
    assert_equal(12, b.pairs[0].reserved)
    # and a build from values writes them as 0, which is what the RFC
    # asks an encoder for.
    assert_nil(BGP::Flow_spec::Port.new(:eq, 25).pairs[0].reserved)
    assert_equal('048119', BGP::Flow_spec::Port.new(:eq, 25).to_shex)
  end

  # No reserved bit set means no :reserved key, so an ordinary pair
  # hashes as the two element Array it was written as. Same rule as a
  # kept tail, per Conventions.
  def test_the_reserved_key_appears_only_when_the_bit_arrived_set
    assert_equal({ :port => [[:eq, 25]] },
                 BGP::Flow_spec::Port.new(:eq, 25).to_hash)
    assert_equal({ :port => [{ :op => :eq, :value => 25, :len => 0, :reserved => 8 }] },
                 from_value(BGP::Flow_spec::Port, '048919').to_hash)
  end

  # A pair whose value field overruns what is left cannot be read, so its
  # operator octet and the remainder are kept whole and encode gives them
  # back. Operator 0x11 says len=01, two value octets, and one follows.
  def test_a_pair_whose_value_overruns_is_kept_whole
    o = from_value(BGP::Flow_spec::Port, '041100')
    assert_equal('041100', o.to_shex)
    assert_equal(0, o.pairs.size)
    assert_equal('1100', o.tail.unpack1('H*'))
    assert_equal({ :port => [{ :tail => '1100' }] }, o.to_hash)
    assert_equal('041100', BGP::Flow_spec::Port.new(o.to_hash).to_shex)
    # and the pairs before it are still read
    p2 = from_value(BGP::Flow_spec::Port, '0401191100')
    assert_equal(1, p2.pairs.size)
    assert_equal('1100', p2.tail.unpack1('H*'))
    assert_equal('0401191100', p2.to_shex)
  end

  def test_a_component_with_no_tail_has_no_tail_key
    assert_nil(BGP::Flow_spec::Port.new(:eq, 25).tail)
    assert_equal([[:eq, 25]], BGP::Flow_spec::Port.new(:eq, 25).to_hash[:port])
  end

  # RFC 8955 section 4.2 makes an unknown component type malformed, and
  # an unknown type's parameter length cannot be known, so nothing after
  # it can be read either. The octets are kept all the same.
  def test_an_unknown_type_keeps_the_rest_of_the_nlri_value
    o = BGP::Flow_spec::Unknown.new(wire('630102030405'))
    assert_equal(99, o.type)
    assert_equal('0102030405', o.value.unpack1('H*'))
    assert_equal('630102030405', o.to_shex)
    assert_equal({ :unknown => { :type => 99, :value => '0102030405' } }, o.to_hash)
    assert_equal('630102030405', BGP::Flow_spec::Unknown.new(o.to_hash).to_shex)
    assert_equal('630102030405', BGP::Flow_spec::Unknown.new(99, "\x01\x02\x03\x04\x05").to_shex)
  end

  # Conventions: where an object rebuilds from its own to_hash, a test
  # must prove it, and the recipe has to exercise every field the class
  # carries. These are the recipes in test/unit/to_hash_catalog.rb, which
  # is the other half the suite requires.
  NUMERIC = [
    BGP::Flow_spec::Ip_protocol, BGP::Flow_spec::Upper_layer_protocol,
    BGP::Flow_spec::Port, BGP::Flow_spec::Destination_port,
    BGP::Flow_spec::Source_port, BGP::Flow_spec::Icmp_type,
    BGP::Flow_spec::Icmpv6_type, BGP::Flow_spec::Icmp_code,
    BGP::Flow_spec::Icmpv6_code, BGP::Flow_spec::Packet_length,
    BGP::Flow_spec::Dscp, BGP::Flow_spec::Flow_label,
  ].freeze

  BITMASK = [
    BGP::Flow_spec::Tcp_flags, BGP::Flow_spec::Fragment,
    BGP::Flow_spec::Ipv6_fragment,
  ].freeze

  def test_every_operator_component_rebuilds_from_its_own_to_hash
    NUMERIC.each do |k|
      o = k.new([:ge, 137], { :op => :and_le, :value => 139, :reserved => 8 },
                { :op => :eq, :value => 8080, :eol => false }, { :tail => '1100' })
      assert_equal(o.to_shex, k.new(o.to_hash).to_shex, "#{k} lost something")
      assert_equal(3, o.pairs.size)
    end
    BITMASK.each do |k|
      o = k.new([:match, 0x02], { :op => :and_not_any, :value => 0x05, :reserved => 12 },
                { :op => :any, :value => 0x08, :eol => false }, { :tail => '1100' })
      assert_equal(o.to_shex, k.new(o.to_hash).to_shex, "#{k} lost something")
    end
  end

  def test_every_prefix_component_rebuilds_from_its_own_to_hash
    [[BGP::Flow_spec::Destination_prefix, '192.0.2.0/24'],
     [BGP::Flow_spec::Source_prefix, '203.0.113.0/24']].each do |k, pfx|
      o = k.new(pfx)
      assert_equal(o.to_shex, k.new(o.to_hash).to_shex, "#{k} lost something")
      assert_equal({ k.hash_key => pfx }, o.to_hash)
    end
    o = BGP::Flow_spec::Destination_ipv6_prefix.new('2001:db8::/32')
    assert_equal(o.to_shex, BGP::Flow_spec::Destination_ipv6_prefix.new(o.to_hash).to_shex)
    # offset and padding are the two fields the IPv4 class has not got.
    v6 = BGP::Flow_spec::Source_ipv6_prefix.new(
      :prefix => '::1234:5678:9a00:0/65-104', :padding => 1)
    assert_equal('0268412468acf135', v6.to_shex)
    assert_equal(1, v6.padding)
    assert_equal(v6.to_shex, BGP::Flow_spec::Source_ipv6_prefix.new(v6.to_hash).to_shex)
  end

  # RFC 8956 section 3.1: the padding "MUST be 0 on encoding and MUST be
  # ignored on decoding", so it only appears in the hash when it arrived
  # set, and only where length minus offset is not a whole octet.
  def test_the_padding_key_appears_only_when_it_arrived_set
    assert_equal({ :source_ipv6_prefix => { :prefix => '::1234:5678:9a00:0/65-104' } },
                 from_value(BGP::Flow_spec::Source_ipv6_prefix, '0268412468acf134').to_hash)
    assert_equal({ :prefix => '::1234:5678:9a00:0/65-104', :padding => 1 },
                 from_value(BGP::Flow_spec::Source_ipv6_prefix,
                            '0268412468acf135').to_hash[:source_ipv6_prefix])
  end

  # The one Hash a component may be handed that is not its own hash is a
  # single {op, value} pair. Pairs carry :op or :value and the wrapped
  # form carries this class's key, which is how the two are told apart.
  def test_a_single_pair_hash_is_not_read_as_the_components_own_hash
    a = BGP::Flow_spec::Port.new(:op => :eq, :value => 25)
    assert_equal('048119', a.to_shex)
    assert_equal('048119', BGP::Flow_spec::Port.new(:port => [[:eq, 25]]).to_shex)
    assert_equal('048119', BGP::Flow_spec::Port.new(:port => [:eq, 25]).to_shex)
    assert_raise(ArgumentError) { BGP::Flow_spec::Port.new({}) }
  end

  # Four type numbers mean one layout under two names, RFC 8956 section
  # 8.1.2's registry holding "both IPv4 and IPv6 Flow Specification
  # component type numbers in a single registry". Those are bare
  # subclasses, so they must agree on the type and differ in the key.
  def test_the_classes_that_share_a_type_number_agree_on_it
    [[BGP::Flow_spec::Ip_protocol, BGP::Flow_spec::Upper_layer_protocol, 3],
     [BGP::Flow_spec::Icmp_type, BGP::Flow_spec::Icmpv6_type, 7],
     [BGP::Flow_spec::Icmp_code, BGP::Flow_spec::Icmpv6_code, 8],
     [BGP::Flow_spec::Fragment, BGP::Flow_spec::Ipv6_fragment, 12]].each do |v4, v6, type|
      assert_equal(type, v4.type, "#{v4} should be type #{type}")
      assert_equal(type, v6.type, "#{v6} should be type #{type}")
      assert_not_equal(v4.hash_key, v6.hash_key, "#{v4} and #{v6} share a hash key")
    end
    # and the two prefix types, where the layout differs rather than the
    # name, so they are not subclasses of each other.
    assert_equal(1, BGP::Flow_spec::Destination_prefix.type)
    assert_equal(1, BGP::Flow_spec::Destination_ipv6_prefix.type)
    assert_equal(2, BGP::Flow_spec::Source_prefix.type)
    assert_equal(2, BGP::Flow_spec::Source_ipv6_prefix.type)
  end

  # RFC 8955 section 4.2.2.12, Figure 4, read with bit 7 least
  # significant, which section 4.3.3 confirms by encoding "DF or FF" as
  # 0x05. RFC 8956 section 3.6 keeps three of the four and reserves the
  # bit IPv4 gives to DF.
  def test_the_fragment_bits_are_figure_4
    assert_equal([0x01, 0x02, 0x04, 0x08],
                 [BGP::Flow_spec::Fragment::DF, BGP::Flow_spec::Fragment::ISF,
                  BGP::Flow_spec::Fragment::FF, BGP::Flow_spec::Fragment::LF])
    assert_equal(0x0f, BGP::Flow_spec::Fragment::DEFINED_BITS)
    assert_equal(0x0e, BGP::Flow_spec::Ipv6_fragment::DEFINED_BITS)
  end

  def test_to_s_says_what_it_is
    assert_match(/Port/, BGP::Flow_spec::Port.new(:eq, 25).to_s)
    assert_match(/eq 25/, BGP::Flow_spec::Port.new(:eq, 25).to_s)
    assert_match(/192\.0\.2\.0\/24/,
                 BGP::Flow_spec::Destination_prefix.new('192.0.2.0/24').to_s)
    assert_match(/type 99/, BGP::Flow_spec::Unknown.new(99, 'x').to_s)
  end

  def test_an_unknown_operator_is_refused
    assert_raise(ArgumentError) { BGP::Flow_spec::Port.new(:nonsense, 1) }
    assert_raise(ArgumentError) { BGP::Flow_spec::Tcp_flags.new(:ge, 1) }
  end

end
