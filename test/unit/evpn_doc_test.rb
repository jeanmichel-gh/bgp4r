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

# docs/evpn.md makes claims about the library. This asserts the load
# bearing ones, the way building_objects_test.rb guards the other
# primer, because a claim nothing checks reads as verified in a document
# as much as in a comment.
#
#   ruby -I. test/unit/evpn_doc_test.rb
#
# **The route type table is discovered, not listed.** That shape came
# from a sabotage on the flow spec guard: a fourteenth component type
# was added and the first version of that guard passed, because it
# compared the document against a list in the test rather than against
# the library. So this enumerates the Route subclasses the library
# actually defines and cross-checks them against both the table and
# Evpn::ROUTES, which catches a class added to one and forgotten in the
# other, in either direction.
#
# BGP:: names are written out in full, see Conventions in CLAUDE.md.

require 'test/unit'
require 'bgp/nlris/evpn'
require 'bgp/path_attributes/extended_community'
require 'bgp/path_attributes/mp_reach'
require 'bgp/nlris/nlri'

class EvpnDocTest < Test::Unit::TestCase

  DOC = 'docs/evpn.md'
  DOC_PATH = File.expand_path("../../#{DOC}", __dir__)

  def doc
    @doc ||= File.read(DOC_PATH, :encoding => 'UTF-8')
  end

  # Every Route subclass the library defines, Unknown excluded: it is in
  # no row and in no ROUTES entry on purpose, since no type number
  # reaches it.
  def implemented
    BGP::Evpn.constants.collect { |c| BGP::Evpn.const_get(c) }
             .select { |k| k.is_a?(Class) && k < BGP::Evpn::Route }
             .reject { |k| k == BGP::Evpn::Unknown }
  end

  # The section 3 table, as {type number => the "In bgp4r" cell}.
  def table
    doc.lines.each_with_object({}) do |l, h|
      m = l.match(/^\|\s*(\d+)\s*\|([^|]*)\|([^|]*)\|\s*(\w+)\s*\|\s*$/)
      h[m[1].to_i] = m[4].downcase if m
    end
  end

  def test_the_document_exists
    assert(File.exist?(DOC_PATH), "#{DOC} must exist")
    assert_operator(doc.size, :>, 2000, "#{DOC} looks truncated")
  end

  # RFC 9572 section 3 Table 1 and Table 2 give eleven between them, so
  # the table has a row per type and no more.
  def test_the_table_has_a_row_for_each_of_the_eleven_route_types
    assert_equal((1..11).to_a, table.keys.sort,
                 "#{DOC} section 3 must have one row per route type, 1 to 11")
  end

  # The discovery guard. Both directions fail: a class in the library
  # whose row says no, and a row saying yes with no class behind it.
  def test_the_table_says_yes_for_exactly_what_the_library_implements
    built = implemented.collect(&:type).sort
    table.each do |type, cell|
      if built.include?(type)
        assert_equal('yes', cell,
                     "#{DOC} says #{cell.inspect} for route type #{type}, " \
                     'which the library implements')
      else
        assert_equal('no', cell,
                     "#{DOC} says #{cell.inspect} for route type #{type}, " \
                     'which the library does not implement')
      end
    end
  end

  # The half-wiring guard: a class added to evpn_route.rb and forgotten
  # in ROUTES parses as an Unknown however complete the class is, and
  # nothing else would say so.
  def test_every_route_class_is_registered_in_routes
    assert_equal(implemented.collect(&:type).sort, BGP::Evpn::ROUTES.keys.sort,
                 'a Route subclass is missing from Evpn::ROUTES, or vice versa')
    BGP::Evpn::ROUTES.each do |type, klass|
      assert_equal(type, klass.type,
                   "Evpn::ROUTES[#{type}] holds #{klass}, whose type is " \
                   "#{klass.type}")
    end
  end

  # RFC 7432 section 7: the Length counts the body alone, so an NLRI
  # occupies 2 + Length octets. The document says so in section 2 and
  # this is the claim everything downstream rests on.
  def test_the_length_counts_the_body_alone
    assert_match(/counts the body alone/, doc)
    assert_equal(2, BGP::Evpn::FRAMING)
    assert_equal(10, BGP::Evpn.nlri_size(['09080011223344556677'].pack('H*')))
    assert_equal(2, BGP::Evpn.nlri_size(['0900'].pack('H*')))
    assert_equal(255, BGP::Evpn::MAX_LEN)
  end

  def test_nlri_size_answers_nil_rather_than_guessing
    assert_match(/answers nil for octets too short to frame/, doc)
    assert_nil(BGP::Evpn.nlri_size(nil))
    assert_nil(BGP::Evpn.nlri_size(['09'].pack('H*')))
  end

  # Section 4's table of primitive widths.
  def test_the_primitive_widths_are_what_the_table_says
    assert_equal(10, BGP::Evpn::Esi::WIDTH)
    assert_equal(10, BGP::Evpn::Esi.new.encode.size)
    assert_equal(4, BGP::Evpn::Ethernet_tag_id::WIDTH)
    assert_equal(4, BGP::Evpn::Ethernet_tag_id.new.encode.size)
    assert_equal(6, BGP::Evpn::Mac_addr::WIDTH)
    assert_equal(48, BGP::Evpn::Mac_addr::BITS)
  end

  # RFC 7432 section 5's two reserved values, quoted in section 4.
  def test_the_two_reserved_esi_values
    assert_match(/ESI 0 denotes a single-homed\s+site/, doc)
    assert_match(/MAX-ESI/, doc)
    assert(BGP::Evpn::Esi.new.single_homed?)
    assert(BGP::Evpn::Esi.new(['ff' * 10].pack('H*').is_packed).max?)
  end

  # The claim the document calls the one memory reverses, with its four
  # citations. Each is quoted, so a reader can check it without opening
  # the RFC.
  def test_the_document_says_the_lengths_are_in_bits
    assert_match(/Both the IP and MAC address lengths are in\s+bits/, doc)
    assert_match(/The IP address length\s+is in bits/, doc)
    assert_match(/specifies the number of\s+bits in the prefix/, doc)
    assert_match(/RFC 9251 says it of all three lengths/, doc)
  end

  # And the one RFC that does not say. This was recorded as open in
  # part 1 rather than guessed, and part 7 closed it through the chain
  # RFC 9572 points at, so the test moved with the claim: what the
  # earlier version guarded against was the open question going quiet,
  # and what this one guards is the answer keeping its provenance.
  def test_the_document_settles_the_rfc_9572_units_and_says_how
    assert_match(/RFC 9572 is the one that does not say/, doc)
    assert_match(/RFC 7117/, doc)
    # The sentence that answers it, by value rather than by the word.
    assert_match(/the value of the Multicast Source Length\s+field is 32/, doc)
    # And which link of the chain is first hand, which is the part an
    # audit needs and the part prose loses first.
    assert_match(/draft-ietf-bess-rfc6514bis-00 section/, doc)
    assert_match(/RFC 7117 section 9\.2\.1 itself was not\s+read/, doc)
    # The library reads a bit count, which is what the answer means.
    r = BGP::Evpn::S_pmsi.new([1, 1], 1, '192.0.2.1', 'ff0e::1', '10.0.0.1')
    assert_equal(32, r.source.bitlen)
    assert_equal(4, r.source.value.size)
    assert_equal(128, r.group.bitlen)
    assert_equal(16, r.group.value.size)
  end

  # The difference between the two fields on consecutive lines of one
  # figure, which is the subtlety most likely to be coded wrong.
  def test_the_mac_width_does_not_follow_its_length_and_the_ip_does
    assert_match(/`Mac_addr` always takes 6/, doc)
    assert_match(/Its width follows its length/, doc)
    mac = BGP::Evpn::Mac_addr.new(['18001122334455'].pack('H*').is_packed)
    assert_equal(24, mac.bitlen)
    assert_equal(6, mac.value.size, 'the MAC stays six octets')
    addr = BGP::Evpn::Addr.new(['18c00002'].pack('H*').is_packed)
    assert_equal(24, addr.bitlen)
    assert_equal(3, addr.value.size, 'the IP follows its length')
    assert(BGP::Evpn::Addr.new.empty?, 'and a length of 0 is the absent field')
  end

  # Section 6's arithmetic, both sums, against RFC 9136 section 3.1's
  # "MUST be either 34 ... or 58".
  def test_the_route_type_5_lengths_add_up
    assert_match(/8 \+ 10 \+ 4 \+ 1 \+ 4 \+ 4 \+ 3 = 34/, doc)
    assert_match(/8 \+ 10 \+ 4 \+ 1 \+ 16 \+ 16 \+ 3 = 58/, doc)
    assert_equal(34, 8 + 10 + 4 + 1 + 4 + 4 + 3)
    assert_equal(58, 8 + 10 + 4 + 1 + 16 + 16 + 3)
  end

  # The claim that lets RFC 7432 section 14 say the outer Length alone
  # identifies route type 2's shape: six are possible and no two are
  # equal. Built from the library rather than from the document's list,
  # so a field width changing on either side fails here.
  def test_the_six_route_type_2_lengths_are_all_distinct
    assert_match(/33, 36, 37,\s*40, 49 and 52/, doc)
    sizes = [nil, '192.0.2.1', '2001:db8::1'].product([nil, 501]).collect do |ip, l2|
      BGP::Evpn::Mac_ip_advertisement.new([100, 200], BGP::Evpn::Esi.new, 0,
                                          '00:11:22:33:44:55', ip, 500,
                                          l2).encode.size
    end
    assert_equal([33, 36, 37, 40, 49, 52], sizes.sort)
    assert_equal(6, sizes.uniq.size, 'the outer Length could not identify them')
  end

  # Route type 3 is the only one of the five with no ESI, which the
  # document says because a reader will look for one.
  def test_route_type_3_has_no_ethernet_segment_identifier
    assert_match(/only one of the\s*five with no Ethernet Segment Identifier/, doc)
    r = BGP::Evpn::Inclusive_multicast.new([100, 200], 100, '192.0.2.1')
    refute_respond_to(r, :esi)
    assert_equal(17, r.encode.size)
  end

  # Route type 5's two traps, both asserted from the library. The
  # prefix is not packed down to its length, and the gateway has no
  # length octet, so a /8 route is 34 octets with four whole prefix
  # octets rather than one.
  def test_route_type_5_does_not_pack_its_prefix
    assert_match(/prefix length and not a field\s*width/, doc)
    assert_match(/GW IP Address has no length octet at all/, doc)
    r = BGP::Evpn::Ip_prefix_route.new([100, 200], BGP::Evpn::Esi.new, 0,
                                       '10.0.0.0/8', '10.0.0.1', 500)
    assert_equal(34, r.encode.size)
    assert_equal(4, r.prefix_octets.size, 'a /8 still occupies four octets')
    assert_equal(8, r.prefix_len)
    assert_equal('0a000000', r.prefix_octets.unpack1('H*'))
  end

  # And the 34 or 58 the section states, from the library rather than
  # from the document's text.
  def test_the_route_type_5_body_is_thirty_four_or_fifty_eight
    assert_match(/MUST be either 34 \(if IPv4/, doc)
    v4 = BGP::Evpn::Ip_prefix_route.new([1, 1], BGP::Evpn::Esi.new, 0,
                                        '10.0.0.0/8', nil, 0)
    v6 = BGP::Evpn::Ip_prefix_route.new([1, 1], BGP::Evpn::Esi.new, 0,
                                        '2001:db8::/32', nil, 0)
    assert_equal([34, 58], [v4.encode.size, v6.encode.size])
    assert_equal([BGP::Evpn::Ip_prefix_route::SIZE_V4,
                  BGP::Evpn::Ip_prefix_route::SIZE_V6],
                 [v4.encode.size, v6.encode.size])
    refute(v4.v6?)
    assert(v6.v6?)
  end

  # The three receive-side rules RFC 9136 adds, recorded as part 9's
  # work. This only checks the document still names them and that none
  # is implemented yet, so the note cannot quietly go stale.
  def test_the_rfc_9136_treat_as_withdraw_rules_are_recorded_for_later
    assert_match(/treat as withdraw/, doc)
    assert_match(/Overlay Index/, doc)
    assert_match(/belong to part 9/, doc)
    assert_match(/not a check `validation\.rb` can make/, doc)
  end

  # Section 7's count, and the community that makes it eleven. Every
  # claim here is read out of FACTORY rather than taken on trust, which
  # is what caught an earlier draft of this document saying bgp4r
  # registered no 0x03 sub-types at all.
  #
  # **This test read the other way round until part 8b**, asserting the
  # Default Gateway was *missing*, and it failed the moment the class
  # landed. That is the guard doing its job: the document said the
  # community was the one still to write, and it is not. The assertion
  # moved to the new truth rather than being weakened.
  def test_the_default_gateway_community_is_an_opaque_type
    assert_match(/type 0x03 sub-type 0x0d/, doc)
    assert_match(/\*\*eleven\*\* added, not ten/, doc)
    f = BGP::Extended_community::FACTORY
    assert_equal(BGP::Default_gateway, f[[0x03, 0x0d]])
    # Not an EVPN 0x06 sub-type, which is the whole reason it is the
    # eleventh and is invisible to anyone counting that registry.
    assert_equal(0x03, BGP::Default_gateway::TYPE)
    refute(f.has_key?([0x06, 0x0d]) && f[[0x06, 0x0d]] == BGP::Default_gateway)
    [[0x03, 0x00], [0x03, 0x0b], [0x03, 0x0c]].each do |k|
      assert(f.has_key?(k),
             "#{DOC} says #{k.inspect} is registered and it is not")
    end
  end

  # **Section 7b's bit-number table is read out of the document and
  # checked against the library**, so the two cannot drift. Each row
  # names a flag, the bit it occupies in its own field, and the bit it
  # occupies in the whole 8-octet community, which is the number the RFC
  # itself gives. That second number is the reason the table is worth
  # asserting: it is the document's own, so this checks the layout
  # against the RFC rather than against this reader's arithmetic.
  def test_the_bit_number_table_matches_where_the_library_puts_each_flag
    communities = {
      'ARP/ND R' => BGP::Arp_nd.new(:router => true),
      'ARP/ND O' => BGP::Arp_nd.new(:override => true),
      'ARP/ND I' => BGP::Arp_nd.new(:immutable => true),
      'DF AC-DF' => BGP::Df_election.new(0, :ac_df => true),
      'DF T'     => BGP::Df_election.new(0, :time_sync => true),
    }
    rows = doc.lines.each_with_object({}) do |l, h|
      m = l.match(/^\|\s*((?:ARP\/ND|DF)\s[\w-]+)\s*\|[^|]*\|\s*Bit (\d+)[^|]*\|[^|]*\|\s*$/)
      h[m[1]] = m[2].to_i if m
    end
    assert_equal(communities.keys.sort, rows.keys.sort,
                 "#{DOC} section 7b's bit table does not name the five flags")
    rows.each do |flag, bit|
      # The RFCs number a community's bits from the high bit of the type
      # octet, so bit n is 0x80 >> (n % 8) in octet n / 8.
      set = communities[flag].encode.unpack('C8').each_with_index
                             .flat_map { |o, i|
        (0..7).select { |b| (o & (0x80 >> b)) > 0 }.collect { |b| i * 8 + b }
      }
      # The type and sub-type octets' own bits are below 16.
      assert_equal([bit], set.reject { |b| b < 16 },
                   "#{DOC} says #{flag} is community bit #{bit}")
    end
  end

  # Section 7b's two claims about which bits a class reads: the one with
  # no reserved bit anywhere, and the one that is nothing but reserved.
  def test_the_two_extreme_communities_are_what_the_document_says
    assert_match(/One has no reserved bit anywhere/, doc)
    refute(BGP::Service_carving_time.const_defined?(:DEFINED_BITS, false),
           "#{DOC} says Service Carving Time has no DEFINED_BITS")
    assert_match(/One has no fields at all/, doc)
    assert_equal(0, BGP::Default_gateway::DEFINED_BITS)
    # And RFC 9722 adding a bit to RFC 8584's Bitmap, which a mask
    # covering only the first RFC would report as a reserved one.
    assert_match(/RFC 9722 section 2\.1 adds bit 3\*\*/, doc)
    df = BGP::Extended_community.factory(['0606001000000000'].pack('H*'))
    assert(df.time_sync?)
    assert_equal({ :df_election => [:default, [:time_sync]] }, df.to_hash,
                 'a T bit reads as a reserved bit, so the mask is short')
  end

  # Section 7's sub-type table, as {sub-type => the "In bgp4r" cell}.
  def community_table
    doc.lines.each_with_object({}) do |l, h|
      m = l.match(/^\|\s*0x([0-9a-f]{2})\s*\|([^|]*)\|([^|]*)\|\s*(\w+)\s*\|\s*$/)
      h[m[1].to_i(16)] = m[4].downcase if m
    end
  end

  # **The discovery guard for the community table**, the twin of the
  # route type one, and it fires in both directions: a 0x06 sub-type
  # registered in FACTORY whose row says no, and a row saying yes with
  # nothing registered behind it. The hard coded count this replaced
  # said "four", and adding the five of RFC 9251 is what made it false.
  def test_the_community_table_says_yes_for_exactly_what_is_registered
    t = community_table
    assert_operator(t.size, :>=, 18, "#{DOC} section 7's table lost rows")
    registered = BGP::Extended_community::FACTORY.keys
                   .select { |k| k[0] == 0x06 }.collect { |k| k[1] }.sort
    t.each do |sub, cell|
      if registered.include?(sub)
        assert_equal('yes', cell,
                     format("#{DOC} says %s for sub-type 0x%02x, which is " \
                            'registered', cell.inspect, sub))
      else
        assert_equal('no', cell,
                     format("#{DOC} says %s for sub-type 0x%02x, which is " \
                            'not registered', cell.inspect, sub))
      end
    end
    # And no registration without a row at all.
    registered.each do |sub|
      assert(t.has_key?(sub),
             format("#{DOC} section 7 has no row for sub-type 0x%02x", sub))
    end
  end

  # The five of RFC 9251, and the two claims about them a reader is
  # most likely to get backwards.
  def test_the_rfc_9251_communities_are_what_the_document_says
    assert_match(/Bit 15\s+\(shown as I\) defines IGMP Proxy Support/, doc)
    # I is the low bit of the Flags field, so bit 32 of the 48-bit value.
    assert_equal(1 << 32, BGP::Multicast_flags::IGMP_PROXY)
    assert_equal(1 << 33, BGP::Multicast_flags::MLD_PROXY)
    assert_equal('0609000100000000', BGP::Multicast_flags
                                       .new(:igmp_proxy => true).to_shex)
    assert_equal('0609000200000000', BGP::Multicast_flags
                                       .new(:mld_proxy => true).to_shex)
    # The EVI-RT split, which the sub-type decides.
    assert_match(/2 plus 4 for a Two-Octet AS-specific RT \(type 0\)/, doc)
    assert_equal('060a0064000000c8', BGP::Evi_rt_0.new(100, 200).to_shex)
    assert_equal('060b0a00000100c8', BGP::Evi_rt_1.new('10.0.0.1', 200).to_shex)
    assert_equal('060c0001117000c8', BGP::Evi_rt_2.new(70_000, 200).to_shex)
  end

  # Type 3, the contradiction. Both halves are asserted, because the
  # verdict without the mechanism is what a future audit would reopen.
  def test_the_evi_rt_type_3_contradiction_is_recorded
    assert_match(/Type 3 is the one RFC 9251 contradicts itself about/, doc)
    assert_match(/\*\*18-octet\*\* value field/, doc)
    assert_match(/follows the figure and the registry/, doc)
    # Six octets, not eighteen, and no field split.
    t3 = BGP::Evi_rt_3.new('aabbccddeeff')
    assert_equal(8, t3.encode.size)
    assert_nil(t3.global)
    assert_nil(t3.local)
    assert_equal({ :evi_rt_3 => { :value => 'aabbccddeeff' } }, t3.to_hash)
    # Where its three siblings do split.
    assert_equal(100, BGP::Evi_rt_0.new(100, 200).global)
    assert_raise(ArgumentError) { BGP::Evi_rt_3.new(100, 200) }
  end

  # Conventions' first bullet, as it applies here.
  def test_nothing_validates_on_the_way_out
    assert_match(/Nothing validates on the way out/, doc)
    assert_equal('fe00',
                 BGP::Evpn.new(BGP::Evpn::Unknown.new(0xfe, '')).to_shex)
    liar = BGP::Evpn.new(['09140011223344556677'].pack('H*').is_packed)
    assert_equal(20, liar.declared_len)
    assert_equal('09140011223344556677', liar.to_shex,
                 'a Length that lies must replay byte for byte')
  end

  # The two refusals the document says exist, and that they are the only
  # ones: a value the field cannot hold, never a combination merely
  # wrong by the RFC.
  def test_the_two_constructor_refusals
    assert_match(/80 bits or more/, doc)
    assert_raise(ArgumentError) { BGP::Evpn::Esi.new(1 << 80) }
    assert_raise(ArgumentError) { BGP::Evpn::Ethernet_tag_id.new(1 << 32) }
    assert_nothing_raised do
      BGP::Evpn::Esi.new(0xfe, '001122334455667788')
      BGP::Evpn::Ethernet_tag_id.new(0xffffffff)
    end
  end

  # The wiring, asserted from the library: both gates resolve SAFI 70
  # and the framing defers to the family. These are library facts, so a
  # site reverted fails here as well as in the functional test.
  def test_the_wiring_sites_resolve_safi_70
    assert_equal(70, IANA::SAFI::EVPN)
    assert_equal(25, IANA::AFI::L2VPN)
    assert_match(/It is wired in now/, doc)
    # nlri_size defers to the family rather than computing a prefix.
    octets = ['0119' + '00' * 25].pack('H*')
    assert_equal(27, BGP::Mp_reach.nlri_size(octets, 25, 70),
                 'the framing is 2 + Length, not the prefix arithmetic')
    # The parse gate answers an Evpn.
    one = BGP::Evpn.new(BGP::Evpn::Ethernet_ad.new([1, 1],
                                                   BGP::Evpn::Esi.new, 0, 500))
    assert_instance_of(BGP::Evpn,
                       BGP::Nlri.factory(one.encode, 25, 70))
    # The build gate fixes the AFI without being told it.
    mp = BGP::Mp_reach.new(:safi => 70, :nexthop => '10.0.0.1',
                           :nlris => [one])
    assert_equal(25, mp.afi, 'section 7 fixes the AFI, so set does not ask')
  end

  # RFC 7432 section 14's next hop, and the one thing about it that
  # differs from every family already wired: the AFI is 25 for both
  # families, so the field length is the only discriminator.
  def test_the_next_hop_family_comes_from_the_length
    assert_match(/the AFI cannot say which family it\s*is/, doc)
    one = BGP::Evpn.new(BGP::Evpn::Ethernet_ad.new([1, 1],
                                                   BGP::Evpn::Esi.new, 0, 500))
    v4 = BGP::Mp_reach.new(:safi => 70, :nexthop => '10.0.0.1',
                           :nlris => [one])
    v6 = BGP::Mp_reach.new(:safi => 70, :nexthop => '2001:db8::1',
                           :nlris => [one])
    assert_equal([25, 25], [v4.afi, v6.afi], 'AFI 25 either way')
    assert_equal('10.0.0.1',
                 BGP::Mp_reach.new(v4.encode.is_packed).nexthops)
    assert_equal('2001:db8::1',
                 BGP::Mp_reach.new(v6.encode.is_packed).nexthops)
  end

  # Interoperability is not measured yet and the document must not
  # pretend otherwise. The flow spec table names its asserting test per
  # row; until this one can, it says so.
  def test_interoperability_is_recorded_as_unmeasured
    assert_match(/Not measured yet/, doc)
  end

  def test_claude_md_points_at_the_document
    md = File.read(File.expand_path('../../CLAUDE.md', __dir__),
                   :encoding => 'UTF-8')
    assert_match(%r{docs/evpn\.md|evpn\.md}, md,
                 "CLAUDE.md no longer points at #{DOC}")
  end


  # Section 5's first keep and echo case, and the claim a reader
  # skimming the figure will get backwards.
  def test_the_four_defined_flag_bits_are_the_low_nibble
    assert_match(/The four defined bits are the low nibble/, doc)
    assert_match(/bit 7 is the least\s+significant/, doc)
    assert_equal(0x0f, BGP::Evpn::Flags::DEFINED_BITS)
    assert_equal(0x01, BGP::Evpn::Flags::V1)
    assert_equal(0x08, BGP::Evpn::Flags::IE)
    # No reserved bit set, no :bits entry.
    assert_equal([:v3], BGP::Evpn::Flags.new(:v3).to_hash)
    f = BGP::Evpn::Flags.new(['f4'].pack('H*').is_packed)
    assert_equal([:v3, { :bits => 0xf4 }], f.to_hash)
    assert_equal('f4', f.to_shex)
  end

  # Section 5's second case, and the sentence that says the RFC asks for
  # it rather than only Conventions. The quote is checked, since this is
  # the one place an RFC agrees with the keep and echo rule and a future
  # audit should be able to see that without opening RFC 9251.
  def test_the_document_quotes_the_rfc_asking_for_the_reserved_echo
    assert_match(/the first one an RFC\s+asks to be echoed in so many words/, doc)
    assert_match(/it MUST propagate it unchanged/, doc)
    assert_equal(4, BGP::Evpn::Leave_synch::RESERVED_SIZE)
    r = BGP::Evpn::Leave_synch.new
    assert(r.reserved_zero?)
    refute(r.to_hash[:leave_synch].has_key?(:reserved))
  end

  # Section 3's route type 6, 7, 8 table, read against the classes. The
  # ESI column is the row a reader will check, since route type 6 has
  # none and its two siblings do.
  def test_the_multicast_route_types_carry_the_fields_the_table_says
    assert_match(/Types 6, 7 and 8, the multicast triple/, doc)
    six = BGP::Evpn::Selective_multicast.new
    refute_respond_to(six, :esi, 'route type 6 has no ESI')
    assert_respond_to(BGP::Evpn::Membership_report_synch.new, :esi)
    assert_respond_to(BGP::Evpn::Leave_synch.new, :esi)
    # The two fields route type 8 adds.
    refute_respond_to(BGP::Evpn::Membership_report_synch.new,
                      :max_response_time)
    assert_respond_to(BGP::Evpn::Leave_synch.new, :max_response_time)
    assert_respond_to(BGP::Evpn::Leave_synch.new, :reserved)
    # And the triple, which all three share.
    [six, BGP::Evpn::Membership_report_synch.new,
     BGP::Evpn::Leave_synch.new].each do |r|
      [:source, :group, :originator].each do |f|
        assert_instance_of(BGP::Evpn::Addr, r.send(f))
      end
      assert_instance_of(BGP::Evpn::Flags, r.flags)
    end
  end

  # The FIXED_SIZE numbers the document prints, measured rather than
  # trusted, since a number in prose is the thing that goes stale.
  def test_the_fixed_sizes_the_document_prints_are_the_library_s
    assert_match(/28 octets for route type 6 with three IPv4 addresses, 64 with/,
                 doc)
    assert_equal(16, BGP::Evpn::Selective_multicast::FIXED_SIZE)
    assert_equal(26, BGP::Evpn::Membership_report_synch::FIXED_SIZE)
    assert_equal(31, BGP::Evpn::Leave_synch::FIXED_SIZE)
    v4 = ['192.0.2.1', '232.1.1.1', '10.0.0.1']
    v6 = ['2001:db8::1', 'ff0e::1', '2001:db8::9']
    assert_equal(28, BGP::Evpn::Selective_multicast
                       .new([1, 1], 1, *v4, [:v3]).encode.size)
    assert_equal(64, BGP::Evpn::Selective_multicast
                       .new([1, 1], 1, *v6, [:v3]).encode.size)
    assert_equal(38, BGP::Evpn::Membership_report_synch
                       .new([1, 1], nil, 1, *v4, [:v3]).encode.size)
    assert_equal(43, BGP::Evpn::Leave_synch
                       .new([1, 1], nil, 1, *v4, 10, [:v3]).encode.size)
  end

  # The module and not a base class claim, which exists because of the
  # discovery guard above: an abstract Route subclass would read as a
  # twelfth route type.
  def test_the_shared_fields_are_a_module_so_the_discovery_guard_holds
    assert_match(/share their fields through a module and not a base class/,
                 doc)
    refute(BGP::Evpn::Multicast_fields.is_a?(Class))
    assert(BGP::Evpn.constants.include?(:Multicast_fields))
    refute(implemented.include?(BGP::Evpn::Multicast_fields))
  end

  # The (*,G) claim, which is the one place an absent field is the
  # ordinary case rather than the unusual one.
  def test_a_zero_multicast_source_length_is_the_ordinary_star_g_case
    assert_match(/An absent Multicast Source is the ordinary case and not an error/,
                 doc)
    assert_match(/the Multicast\s+Source Length is set to 0/, doc)
    r = BGP::Evpn::Selective_multicast.new([1, 1], 1, nil, '232.1.1.1',
                                           '10.0.0.1', [:v2])
    assert(r.source.empty?)
    assert_equal(0, r.source.bitlen)
    assert_match(/\(\*,/, r.to_s)
  end


  # Section 3's route type 9 entry, and the reasoning behind Region_id
  # not being an extended community. The measurement is the claim, so
  # the test makes it again rather than trusting the prose.
  def test_the_region_id_is_not_decoded_as_an_extended_community
    assert_match(/does not decode them as an\s+extended community/, doc)
    assert_equal(8, BGP::Evpn::Region_id::WIDTH)
    # It cannot be rebuilt from its own to_hash, which is half the
    # reason.
    ec = BGP::Extended_community.factory(['00090000fde80000'].pack('H*'))
    assert_raise(ArgumentError) { BGP::Extended_community.new(ec.to_hash) }
    assert_raise(NoMethodError) { BGP::Extended_community.factory(ec.to_hash) }
    # And all three of section 6.2's examples are Unknown today, which
    # is the other half: sub-type 0x09 Source AS is unregistered.
    ['00090000fde80000', '0209000186a00000', '0101000000010000'].each do |h|
      assert_instance_of(BGP::Extended_community::Unknown,
                         BGP::Extended_community.factory([h].pack('H*')),
                         h)
    end
    assert_match(/sub-type 0x09, Source AS/, doc)
    # Where Region_id does round trip through its own hash.
    r = BGP::Evpn::Region_id.new('00090000fde80000')
    assert_equal(r.to_shex, BGP::Evpn::Region_id.new(r.to_hash).to_shex)
  end

  # Route type 10 is route type 6 less its Flags, which is why the
  # shared module does not carry the Flags.
  def test_route_type_10_is_route_type_6_without_the_flags
    assert_match(/route type 6 without its\s+Flags octet/, doc)
    assert_equal(BGP::Evpn::Selective_multicast::FIXED_SIZE - 1,
                 BGP::Evpn::S_pmsi::FIXED_SIZE)
    refute_respond_to(BGP::Evpn::S_pmsi.new, :flags)
    assert_respond_to(BGP::Evpn::Selective_multicast.new, :flags)
    assert(BGP::Evpn::S_pmsi.ancestors.include?(BGP::Evpn::Multicast_fields))
  end

  # Route type 11, the recursion. The claim that costs most if it is
  # wrong is that the Route Key is a whole NLRI, framing included.
  def test_the_leaf_a_d_route_key_is_a_whole_nlri
    assert_match(/only route type with neither an RD nor an Ethernet Tag/, doc)
    assert_match(/embeds the entire NLRI of the triggering PMSI A-D/, doc)
    inner = BGP::Evpn.new(BGP::Evpn::Inclusive_multicast
                            .new([1, 1], 1, '10.0.0.1'))
    r = BGP::Evpn::Leaf_a_d.new(inner, '10.0.0.9')
    # Framing included: the body starts with the Route Key's own Route
    # Type and Length octets.
    assert_equal(inner.to_shex, r.to_shex[0, inner.to_shex.size])
    assert_equal(3, r.route_key.type)
    assert_equal(inner.encode.size + r.originator.size, r.encode.size)
    refute_respond_to(r, :rd)
    refute_respond_to(r, :ethernet_tag_id)
  end

  # And that it reaches Evpn at call time, which is what lets a route
  # type in evpn_route.rb hold an NLRI from evpn.rb.
  def test_only_the_leaf_a_d_route_needs_the_nlri
    assert_match(/reaches `Evpn` at call time and not at load time/, doc)
    BGP::Evpn::ROUTES.each do |t, k|
      next if t == 11
      assert_nothing_raised("route type #{t} should build with no NLRI") do
        k.new
      end
    end
    # Route type 11 builds too, since Evpn is loaded here. What the
    # document records is that evpn_route.rb alone would not do.
    assert_nothing_raised { BGP::Evpn::Leaf_a_d.new }
  end

end
