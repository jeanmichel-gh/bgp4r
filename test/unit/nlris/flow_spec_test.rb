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

# The Flow Specification NLRI of RFC 8955 section 4 and section 8.
#
#   ruby -I. test/unit/nlris/flow_spec_test.rb
#
# The five worked examples the RFCs print are the vectors again, and
# here they are worth more than they were for the components, because
# each one also prints the **length** a correct encoder writes: 0x0b,
# 0x12, 0x09, 0x12 and 0x0f. That is the section 4.1 arithmetic checked
# against the document rather than against my own reading of it.
#
# See docs/flow-spec.md, whose claims test/unit/flow_spec_doc_test.rb
# asserts.
#
# BGP:: names are written out in full, see Conventions in CLAUDE.md.

require 'test/unit'
require 'bgp/nlris/flow_spec'

class FlowSpecTest < Test::Unit::TestCase

  def wire(hex)
    [hex].pack('H*').is_packed
  end

  # type and length octets built rather than typed, because five hand
  # written hex expectations were wrong while this family was written
  # and every one of them was the probe and not the library.
  def framed(components)
    format('%02x', components.size / 2) + components
  end

  # RFC 8955 section 4.3.1: "all packets to 192.0.2.0/24 and TCP port
  # 25". The document gives the length as 0x0b and says "This
  # constitutes an NLRI with an NLRI length of 11 octets."
  def test_the_rfc_8955_example_1_whole_nlri
    fs = BGP::Flow_spec.new(
      BGP::Flow_spec::Destination_prefix.new('192.0.2.0/24'),
      BGP::Flow_spec::Ip_protocol.new(:eq, 6),
      BGP::Flow_spec::Port.new(:eq, 25))
    assert_equal('0b' + '0118c00002' + '038106' + '048119', fs.to_shex)
    assert_equal(11, fs.encode.size - 1)
    assert_equal(3, fs.size)
  end

  # RFC 8955 section 4.3.2, length 0x12, "an NLRI length of 18 octets".
  def test_the_rfc_8955_example_2_whole_nlri
    fs = BGP::Flow_spec.new(
      BGP::Flow_spec::Destination_prefix.new('192.0.2.0/24'),
      BGP::Flow_spec::Source_prefix.new('203.0.113.0/24'),
      BGP::Flow_spec::Port.new([:ge, 137], [:and_le, 139], [:eq, 8080]))
    assert_equal('12' + '0118c00002' + '0218cb0071' + '040389458b911f90',
                 fs.to_shex)
    assert_equal(18, fs.encode.size - 1)
  end

  # RFC 8955 section 4.3.3, length 0x09, "an NLRI length of 9 octets".
  def test_the_rfc_8955_example_3_whole_nlri
    frag = BGP::Flow_spec::Fragment
    fs = BGP::Flow_spec.new(
      BGP::Flow_spec::Destination_prefix.new('192.0.2.1/32'),
      frag.new(:any, frag::DF | frag::FF))
    assert_equal('09' + '0120c0000201' + '0c8005', fs.to_shex)
    assert_equal(9, fs.encode.size - 1)
  end

  # RFC 8956 section 3.8.1, length 0x12. The destination octets are the
  # erratum 7571 corrected ones; see the note in
  # flow_spec_component_test.rb.
  def test_the_rfc_8956_example_1_whole_nlri
    fs = BGP::Flow_spec.new(
      BGP::Flow_spec::Destination_ipv6_prefix.new('2001:db8::/32'),
      BGP::Flow_spec::Source_ipv6_prefix.new('::1234:5678:9a00:0/104', 64),
      BGP::Flow_spec::Upper_layer_protocol.new(:eq, 6))
    assert_equal('12' + '01200020010db8' + '026840123456789a' + '038106',
                 fs.to_shex)
    assert_equal(18, fs.encode.size - 1)
  end

  # RFC 8956 section 3.8.2, length 0x0f, "an NLRI length of 15 octets".
  def test_the_rfc_8956_example_2_whole_nlri
    fs = BGP::Flow_spec.new(
      BGP::Flow_spec::Destination_ipv6_prefix.new('2001:db8::/32'),
      BGP::Flow_spec::Source_ipv6_prefix.new('::1234:5678:9a00:0/65-104'))
    assert_equal('0f' + '01200020010db8' + '0268412468acf134', fs.to_shex)
    assert_equal(15, fs.encode.size - 1)
  end

  VECTORS = [
    ['0b0118c00002038106048119', 1, 3],
    ['120118c000020218cb0071040389458b911f90', 1, 3],
    ['090120c00002010c8005', 1, 2],
    ['1201200020010db8026840123456789a038106', 2, 3],
    ['0f01200020010db80268412468acf134', 2, 2],
  ].freeze

  def test_every_vector_parses_back_and_re_encodes
    VECTORS.each do |hex, afi, count|
      fs = BGP::Flow_spec.new(wire(hex), afi)
      assert_equal(hex, fs.to_shex, "AFI #{afi} did not give back #{hex}")
      assert_equal(count, fs.size, "#{hex} should hold #{count} components")
    end
  end

  def test_every_vector_rebuilds_from_its_own_hash
    VECTORS.each do |hex, afi, _|
      fs = BGP::Flow_spec.new(wire(hex), afi)
      assert_equal(hex, BGP::Flow_spec.new(fs.to_hash).to_shex,
                   "#{hex} lost something through its hash")
    end
  end

  # RFC 8955 section 4.1, with the section's own examples: "the length
  # value of 239 is encoded as 0xef (single octet), while 240 is encoded
  # as 0xf0f0 (2 octets)", and "The highest value that can be
  # represented with this encoding is 4095."
  def test_the_section_4_1_length_encoding
    assert_equal('ef', BGP::Flow_spec.encode_length(239).unpack1('H*'))
    assert_equal('f0f0', BGP::Flow_spec.encode_length(240).unpack1('H*'))
    assert_equal('ffff', BGP::Flow_spec.encode_length(4095).unpack1('H*'))
    assert_equal('00', BGP::Flow_spec.encode_length(0).unpack1('H*'))
    assert_equal(239, BGP::Flow_spec::ONE_OCTET_MAX)
    assert_equal(4095, BGP::Flow_spec::MAX_LEN)
  end

  # The one refusal Conventions allows a constructor: a value that
  # cannot be represented at all, where the alternative is silently
  # writing a different length.
  def test_a_length_above_4095_cannot_be_written_and_says_so
    assert_raise(ArgumentError) { BGP::Flow_spec.encode_length(4096) }
    assert_raise(ArgumentError) { BGP::Flow_spec.encode_length(-1) }
  end

  # The two octet form on a real NLRI rather than on the helper alone.
  # Sixty eight octet values is 600 octets of components, so the length
  # is 0xf258.
  def test_an_nlri_past_239_octets_uses_the_two_octet_length
    fs = BGP::Flow_spec.new(*(1..60).collect do |i|
      BGP::Flow_spec::Port.new(:op => :eq, :value => i, :len => 3)
    end)
    assert_equal(600, fs.encode_value.size)
    assert_equal('f258', fs.to_shex[0, 4])
    assert_equal(602, fs.encode.size)
    assert_equal(fs.to_shex, BGP::Flow_spec.new(wire(fs.to_shex), 1).to_shex)
    assert_equal(60, BGP::Flow_spec.new(wire(fs.to_shex), 1).size)
  end

  # What Mp_reach#parse and Mp_unreach#parse will ask in place of the
  # prefix families' (blen+7)/8+1. The two guards answer nil so a caller
  # can stop rather than loop on octets that cannot hold a length.
  def test_nlri_size_is_what_the_parse_loops_need
    assert_equal(12, BGP::Flow_spec.nlri_size(wire('0b0118c00002038106048119')))
    assert_equal(242, BGP::Flow_spec.nlri_size(wire('f0f0') + 'x' * 240))
    assert_equal(1, BGP::Flow_spec.nlri_size(wire('00')))
    assert_nil(BGP::Flow_spec.nlri_size(wire('f0')))
    assert_nil(BGP::Flow_spec.nlri_size(wire('')))
    assert_nil(BGP::Flow_spec.nlri_size(nil))
  end

  # RFC 8955 section 8, Figure 7: "a fixed-length Route Distinguisher
  # field (8 octets) followed by the Flow Specification NLRI value", and
  # "The NLRI length field shall include both the 8 octets of the Route
  # Distinguisher as well as the subsequent Flow Specification NLRI
  # value."
  def test_the_safi_134_route_distinguisher
    fs = BGP::Flow_spec.new(:rd => [100, 200],
                            :destination_prefix => '192.0.2.0/24',
                            :port => [[:eq, 25]])
    assert_equal(134, fs.safi)
    assert_equal('10' + '00000064000000c8' + '0118c00002' + '048119', fs.to_shex)
    # the length covers the RD: 8 + 5 + 3
    assert_equal(16, fs.encode.size - 1)
    assert_equal(16, fs.to_shex[0, 2].to_i(16))
    back = BGP::Flow_spec.new(wire(fs.to_shex), 1, 134)
    assert_equal(fs.to_shex, back.to_shex)
    assert_equal('RD=100:200 (0x64 0x00c8)', back.rd.to_s)
    assert_equal(2, back.size)
    assert_equal(fs.to_shex, BGP::Flow_spec.new(back.to_hash).to_shex)
  end

  def test_no_route_distinguisher_is_read_for_safi_133
    fs = BGP::Flow_spec.new(wire('0b0118c00002038106048119'), 1, 133)
    assert_nil(fs.rd)
    assert_equal(3, fs.size)
  end

  # The AFI is a parse time question, since on the way out a component
  # already knows its own octets. On a build from values it is worked
  # out from the classes, and on a build from a hash from the keys,
  # because the six shared type numbers have a key each per family.
  def test_the_afi_is_inferred_from_the_components
    v4 = BGP::Flow_spec.new(BGP::Flow_spec::Port.new(:eq, 25))
    assert_equal(1, v4.afi)
    v6 = BGP::Flow_spec.new(BGP::Flow_spec::Source_ipv6_prefix.new('2001:db8::/32'))
    assert_equal(2, v6.afi)
    assert_equal(2, BGP::Flow_spec.new(:flow_label => [[:eq, 6]]).afi)
    assert_equal(1, BGP::Flow_spec.new(:ip_protocol => [[:eq, 6]]).afi)
    assert_equal(2, BGP::Flow_spec.new(:upper_layer_protocol => [[:eq, 6]]).afi)
  end

  # RFC 8955 section 4.2 makes an unknown component type malformed, and
  # an unknown type's parameter length cannot be known, so nothing after
  # it can be read either. The octets are kept all the same.
  def test_an_unknown_component_type_keeps_the_rest_of_the_value
    hex = framed('0118c00002' + '630102')
    fs = BGP::Flow_spec.new(wire(hex), 1)
    assert_equal([BGP::Flow_spec::Destination_prefix, BGP::Flow_spec::Unknown],
                 fs.components.collect(&:class))
    assert_equal(hex, fs.to_shex)
    assert_equal(99, fs.components.last.type)
    assert_equal('0102', fs.components.last.value.unpack1('H*'))
    assert_equal(hex, BGP::Flow_spec.new(fs.to_hash).to_shex)
    # and the component before it keeps its meaning, which is the whole
    # reason Unknown exists rather than the NLRI raising
    assert_equal('192.0.2.0/24', fs.components.first.prefix.to_s)
  end

  # RFC 8956 section 8.1.2 gives type 13's IPv4 name as Unassigned and
  # its IPv6 name as Flow Label, so one type number reads two ways and
  # the AFI is what decides. Both replay.
  def test_type_13_is_a_flow_label_in_ipv6_and_unknown_in_ipv4
    hex = framed('0da100000006')
    assert_equal(BGP::Flow_spec::Unknown,
                 BGP::Flow_spec.new(wire(hex), 1).components.first.class)
    assert_equal(BGP::Flow_spec::Flow_label,
                 BGP::Flow_spec.new(wire(hex), 2).components.first.class)
    assert_equal(hex, BGP::Flow_spec.new(wire(hex), 1).to_shex)
    assert_equal(hex, BGP::Flow_spec.new(wire(hex), 2).to_shex)
  end

  # RFC 7911 section 3 prepends a Path Identifier to the NLRI, so an
  # extended one is four octets longer. Named as Prefix names it.
  def test_the_rfc_7911_path_identifier
    fs = BGP::Flow_spec.new(BGP::Flow_spec::Port.new(:eq, 25))
    assert_equal(false, fs.extended?)
    fs.path_id = 100
    assert_equal(true, fs.extended?)
    assert_equal('00000064' + '03' + '048119', fs.to_shex)
    assert_equal({ :path_id => 100, :port => [[:eq, 25]] }, fs.to_hash)
    assert_equal(fs.to_shex, BGP::Flow_spec.new(fs.to_hash).to_shex)
    assert_equal('03048119', BGP::Flow_spec.new(BGP::Flow_spec::Port.new(:eq, 25)).to_shex)
  end

  # One key per component type cannot hold two of a type, which is the
  # problem #169 solved for Path_attribute with the same key. The
  # occurrences after the first ride in a list of their own hashes.
  def test_two_components_of_one_type_ride_in_duplicates
    fs = BGP::Flow_spec.new(BGP::Flow_spec::Port.new(:eq, 25),
                            BGP::Flow_spec::Port.new(:eq, 80))
    assert_equal('06' + '048119' + '048150', fs.to_shex)
    assert_equal({ :port => [[:eq, 25]],
                   :duplicates => [{ :port => [[:eq, 80]] }] }, fs.to_hash)
    assert_equal(fs.to_shex, BGP::Flow_spec.new(fs.to_hash).to_shex)
  end

  def test_an_ordinary_nlri_has_no_duplicates_key
    fs = BGP::Flow_spec.new(wire('0b0118c00002038106048119'), 1)
    assert_equal(false, fs.to_hash.key?(:duplicates))
    assert_equal(false, fs.to_hash.key?(:tail))
    assert_equal(false, fs.to_hash.key?(:length))
    assert_equal(false, fs.to_hash.key?(:rd))
    assert_equal(false, fs.to_hash.key?(:path_id))
  end

  # A Length longer than the octets that followed it. encode writes back
  # the length that arrived, so a capture that lied can be sent again,
  # which is what Orf keeps declared_len for.
  def test_a_length_that_disagrees_with_its_octets_is_written_back
    hex = '0a' + '0118c00002038106'
    fs = BGP::Flow_spec.new(wire(hex), 1)
    assert_equal(10, fs.declared_len)
    assert_equal(hex, fs.to_shex)
    assert_equal(10, fs.to_hash[:length])
    assert_equal(hex, BGP::Flow_spec.new(fs.to_hash).to_shex)
    # and a length that agrees keeps declared_len nil, so nothing
    # ordinary changes shape
    assert_nil(BGP::Flow_spec.new(wire('0b0118c00002038106048119'), 1).declared_len)
  end

  # Conventions: building and encoding never validate. Each of these is
  # something RFC 8955 section 4.2 forbids a sender, and all of them
  # have to reach the wire so a test can watch a router decide.
  def test_nothing_validates
    # out of order: section 4.2 says components MUST be in increasing
    # type order, and that MUST binds a sender
    out = BGP::Flow_spec.new(BGP::Flow_spec::Port.new(:eq, 25),
                             BGP::Flow_spec::Destination_prefix.new('192.0.2.0/24'))
    assert_equal('08' + '048119' + '0118c00002', out.to_shex)
    # a type twice, where section 4.2 allows it "exactly once"
    assert_equal('06048119048150',
                 BGP::Flow_spec.new(BGP::Flow_spec::Port.new(:eq, 25),
                                    BGP::Flow_spec::Port.new(:eq, 80)).to_shex)
    # an NLRI with no components at all
    assert_equal('00', BGP::Flow_spec.new.to_shex)
    assert_equal(true, BGP::Flow_spec.new.empty?)
    # a component type the registry reserves, RFC 8956 section 8.1.2
    assert_equal('03ff0102',
                 BGP::Flow_spec.new(BGP::Flow_spec::Unknown.new(255, "\x01\x02")).to_shex)
    # an IPv6 component in an NLRI whose other component is IPv4 only
    mixed = BGP::Flow_spec.new(BGP::Flow_spec::Destination_prefix.new('192.0.2.0/24'),
                               BGP::Flow_spec::Flow_label.new(:eq, 6))
    assert_equal('0b' + '0118c00002' + '0da100000006', mixed.to_shex)
  end

  def test_add_refuses_what_is_not_a_component
    fs = BGP::Flow_spec.new
    assert_raise(ArgumentError) { fs.add('192.0.2.0/24') }
    assert_raise(ArgumentError) { fs.add(BGP::Prefix.new('192.0.2.0/24')) }
    assert_equal(true, fs.empty?)
    fs << BGP::Flow_spec::Port.new(:eq, 25)
    assert_equal(1, fs.size)
  end

  def test_a_hash_key_that_is_not_a_component_says_so
    assert_raise(ArgumentError) { BGP::Flow_spec.new(:nonsense => 1) }
    assert_raise(ArgumentError) { BGP::Flow_spec.new(:prefix => '192.0.2.0/24') }
  end

  def test_octets_too_short_for_a_length_field_say_so
    assert_raise(ArgumentError) { BGP::Flow_spec.new(wire('f0'), 1) }
    assert_raise(ArgumentError) { BGP::Flow_spec.new(wire(''), 1) }
  end

  # The fourth build path Conventions names: another instance, re-parsed
  # through its own encode.
  def test_building_from_another_flow_spec
    fs = BGP::Flow_spec.new(wire('1201200020010db8026840123456789a038106'), 2)
    again = BGP::Flow_spec.new(fs)
    assert_equal(fs.to_shex, again.to_shex)
    assert_equal(2, again.afi)
    assert_equal(3, again.size)
  end

  def test_to_s_says_what_it_is
    fs = BGP::Flow_spec.new(:rd => [100, 200],
                            :destination_prefix => '192.0.2.0/24')
    assert_match(/Flow spec/, fs.to_s)
    assert_match(/RD=100:200/, fs.to_s)
    assert_match(/192\.0\.2\.0\/24/, fs.to_s)
    fs.path_id = 7
    assert_match(/ID=7/, fs.to_s)
  end

  # A component is kept only if it can give its own octets back, which
  # is stricter than catching an exception and has to be.
  #
  # `Prefix` does not raise on a truncated prefix. It pads the value out
  # to the number of octets its length octet demands and reports the
  # fault through `syntactically_correct?`, which is deliberate and long
  # predates this: in the prefix families `Mp_reach#parse` slices
  # exactly the right number of octets, so the padding only shows on a
  # malformed NLRI. A flow spec component list has no such guarantee, so
  # `01 18 c0` read as a component would come back three octets longer
  # than it arrived.
  #
  # Measured, before the guard: `040118c0` encoded as `040118c00000`.
  def test_a_component_that_cannot_give_its_octets_back_is_kept_whole
    { '040118c0' => '0118c0',   # a /24 with one prefix octet
      '030118'   => '0118',     # a /24 with none
      '0201ff'   => '01ff',     # a length octet of 255
    }.each do |hex, tail|
      fs = BGP::Flow_spec.new(wire(hex), 1)
      assert_equal(hex, fs.to_shex, "#{hex} did not come back")
      assert_equal(tail, fs.tail.unpack1('H*'), "#{hex} kept the wrong octets")
      assert_equal(0, fs.size, "#{hex} should hold no readable component")
      assert_equal(hex, BGP::Flow_spec.new(fs.to_hash).to_shex)
    end
  end

  # The other half of that guard: a class that does raise. An IPv6
  # prefix component truncated after its length octet reads its offset
  # as nil and dies inside the arithmetic, where the IPv4 one pads
  # instead. Both outcomes have to keep the octets, so the guard catches
  # the exception as well as comparing the re-encoding.
  def test_a_component_class_that_raises_also_keeps_its_octets
    { '020120'   => '0120',
      '03012001' => '012001',
    }.each do |hex, tail|
      fs = BGP::Flow_spec.new(wire(hex), 2)
      assert_equal(hex, fs.to_shex, "#{hex} did not come back")
      assert_equal(tail, fs.tail.unpack1('H*'))
      assert_equal(0, fs.size)
      assert_equal(hex, BGP::Flow_spec.new(fs.to_hash).to_shex)
    end
    # and the class really does raise on its own, so this is not the
    # re-encoding comparison catching it by another route
    assert_raise(TypeError) do
      BGP::Flow_spec::Destination_ipv6_prefix.new(wire('20'))
    end
  end

  def test_a_readable_component_before_an_unreadable_one_keeps_its_meaning
    hex = framed('048119' + '0118c0')
    fs = BGP::Flow_spec.new(wire(hex), 1)
    assert_equal(hex, fs.to_shex)
    assert_equal([BGP::Flow_spec::Port], fs.components.collect(&:class))
    assert_equal('0118c0', fs.tail.unpack1('H*'))
  end

  # What Nlri.factory will call once the gates are wired, shaped on
  # Prefix.new_ntop. The Path Identifier is already off the octets by
  # then, so it comes in as a value.
  def test_new_ntop
    fs = BGP::Flow_spec.new_ntop(wire('0b0118c00002038106048119'), 1, 133)
    assert_equal('0b0118c00002038106048119', fs.to_shex)
    assert_equal(3, fs.size)
    assert_equal(false, fs.extended?)
    with_id = BGP::Flow_spec.new_ntop(wire('03048119'), 1, 133, 100)
    assert_equal(100, with_id.path_id)
    assert_equal(true, with_id.extended?)
    assert_equal('00000064' + '03048119', with_id.to_shex)
    # and the defaults are IPv4 unicast flow spec
    assert_equal(1, BGP::Flow_spec.new_ntop(wire('00')).afi)
    assert_equal(133, BGP::Flow_spec.new_ntop(wire('00')).safi)
  end

  # Conventions: where an object rebuilds from its own to_hash, a test
  # must prove it, and the recipe has to exercise every field the class
  # carries, since a thin one passes for the wrong reason. All six are
  # here, and this is the recipe in test/unit/to_hash_catalog.rb, which
  # is the other half the suite requires.
  def test_every_field_rebuilds_from_its_own_to_hash
    fs = BGP::Flow_spec.new(:path_id => 100, :rd => [100, 200],
                            :destination_prefix => '192.0.2.0/24',
                            :port => [[:eq, 25]],
                            :duplicates => [{ :port => [[:eq, 80]] }],
                            :length => 99,
                            :tail => 'deadbeef')
    assert_equal(100, fs.path_id)
    assert_equal('RD=100:200 (0x64 0x00c8)', fs.rd.to_s)
    assert_equal(99, fs.declared_len)
    assert_equal('deadbeef', fs.tail.unpack1('H*'))
    assert_equal(3, fs.size)
    assert_equal(134, fs.safi)
    assert_equal('00000064' + '63' + '00000064000000c8' +
                 '0118c00002' + '048119' + '048150' + 'deadbeef', fs.to_shex)
    assert_equal(fs.to_shex, BGP::Flow_spec.new(fs.to_hash).to_shex)
  end

  # The registry tables, RFC 8956 section 8.1.2. Six type numbers mean a
  # different class per family and type 13 is in the IPv6 table only.
  def test_the_component_tables
    assert_equal((1..12).to_a, BGP::Flow_spec::V4.keys.sort)
    assert_equal((1..13).to_a, BGP::Flow_spec::V6.keys.sort)
    [1, 2, 3, 7, 8, 12].each do |t|
      assert_not_equal(BGP::Flow_spec::V4[t], BGP::Flow_spec::V6[t],
                       "type #{t} should read differently per family")
    end
    [4, 5, 6, 9, 10, 11].each do |t|
      assert_equal(BGP::Flow_spec::V4[t], BGP::Flow_spec::V6[t],
                   "type #{t} is the same component in both families")
    end
    # every class in either table is reachable from a hash key, and so
    # is Unknown, which is in neither
    (BGP::Flow_spec::V4.values + BGP::Flow_spec::V6.values).uniq.each do |k|
      assert_equal(k, BGP::Flow_spec::BY_KEY[k.hash_key])
    end
    assert_equal(BGP::Flow_spec::Unknown, BGP::Flow_spec::BY_KEY[:unknown])
  end

end
