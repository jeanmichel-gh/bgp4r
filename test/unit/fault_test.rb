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

require "test/unit"
require "bgp4r"

class TestFault < Test::Unit::TestCase
  include BGP

  def hex(attr) attr.encode.unpack1('H*') end

  def test_raw_keeps_the_attribute
    r = Fault.raw(Next_hop.new('10.0.0.1'))
    assert_instance_of Attr::Raw, r
    assert_equal '4003040a000001', hex(r)
  end

  def test_truncate
    assert_equal '400100', hex(Fault.truncate(Origin.new(0)))
    assert_equal '4003030a0000', hex(Fault.truncate(Next_hop.new('10.0.0.1'), 3))
  end

  def test_pad
    assert_equal '4001020000', hex(Fault.pad(Origin.new(0)))
    assert_equal '4001020000', hex(Fault.pad(Origin.new(0), 1))
    assert_equal '40010300ffff', hex(Fault.pad(Origin.new(0), 2, 0xff))
  end

  def test_length_field_only
    # The length field says 5 but the value is one octet (RFC 7606 section 4).
    assert_equal '40010500', hex(Fault.length(Origin.new(0), 5))
    assert_equal '40011400', hex(Fault.length(Origin.new(0), 20))
  end

  def test_flags
    assert_equal 'c0010100', hex(Fault.flags(Origin.new(0), ATTR::OPTIONAL_TRANSITIVE))
  end

  def test_retype
    assert_equal '40fa0100', hex(Fault.retype(Origin.new(0), 250))
  end

  def test_value
    assert_equal '400102dead', hex(Fault.value(Origin.new(0), 'dead'))
    assert_equal '4001020102', hex(Fault.value(Origin.new(0), "\x01\x02".b))
  end

  def test_faults_do_not_change_the_source
    origin = Origin.new(0)
    Fault.truncate(origin)
    Fault.pad(origin)
    Fault.flags(origin, ATTR::OPTIONAL)
    assert_equal '40010100', hex(origin)
  end

  # Each catalog entry builds the fault it names, and a lenient parse sees
  # exactly the RFC 7606 action and subcode the catalog promises.
  def test_catalog_entries_match_their_rfc
    assert_equal Fault::CATALOG.size, Fault.catalog.size
    Fault.catalog.each do |e|
      pa = Path_attribute.new(Fault.wire(e[:name]).is_packed, :as4byte => true)
      finding = Attr.strongest(pa.errors)
      assert finding, "#{e[:name]}: no finding"
      assert_equal e[:action], finding.action, "#{e[:name]} action"
      assert_equal e[:subcode], finding.subcode, "#{e[:name]} subcode"
      assert_match(/^RFC /, e[:rfc])
    end
  end

  # RFC 7606 section 3 (g): the first one counts, except MP_REACH_NLRI
  # and MP_UNREACH_NLRI, which reset the session.
  def test_duplicate
    pa = Fault.duplicate(Origin.new(0))
    assert_instance_of Path_attribute, pa
    assert_equal '4001010040010100', pa.encode.unpack1('H*')
    assert_equal 3, Fault.duplicate(Next_hop.new('10.0.0.1'), 3).size
    parsed = Path_attribute.new(Fault.wire(:duplicate_mp_reach).is_packed, :as4byte => true)
    assert_equal :session_reset, parsed.action
  end

  def test_wire_takes_both_shapes
    assert_equal '40011400', Fault.wire(:attr_overrun).unpack1('H*')
    assert_equal '4001010040010100', Fault.wire(:duplicate_attr).unpack1('H*')
  end

  # The faults in attributes that carry TLVs, each cutting the nesting at
  # a different level. The hex is pinned so a change to any of the three
  # attributes that moved these octets would show up here.
  def test_nested_attribute_faults
    { :prefix_sid_tlv         => 'c0280401ffff00',
      :prefix_sid_label_index => 'c02809010006000000000064',
      :pmsi_length            => 'c0160400060000',
      :tunnel_encap_tlv       => 'c017040008ffff',
      :tunnel_encap_sub_tlv   => 'c0171000080004060a0000000000010a000001',
    }.each do |name, hex|
      assert_equal hex, Fault.wire(name).unpack1('H*'), name.to_s
    end
    # RFC 9012 section 13: the TLV length says 4, but its one sub-TLV
    # needs 12, so the TLV does not end on its last sub-TLV.
    pa = Path_attribute.new(Fault.wire(:tunnel_encap_sub_tlv).is_packed, :as4byte => true)
    assert_match(/sub-TLV type 6 runs past TLV type 8/, Attr.strongest(pa.errors).reason)
    # RFC 8669 section 6 discards the attribute rather than withdrawing.
    ps = Path_attribute.new(Fault.wire(:prefix_sid_tlv).is_packed, :as4byte => true)
    assert_equal :attribute_discard, ps.action
  end

  def test_catalog_names_are_unique
    names = Fault::CATALOG.collect(&:first)
    assert_equal names.size, names.uniq.size
  end

  def test_build_unknown_fault_raises
    assert_raise(ArgumentError) { Fault.build(:no_such_fault) }
  end

  # A strict parse raises on each catalog fault (RFC 7606).
  def test_strict_parse_raises_on_each_fault
    Fault.catalog.each do |e|
      assert_raise(Malformed_attribute, e[:name].to_s) do
        Path_attribute.new(Fault.wire(e[:name]).is_packed, :as4byte => true, :policy => :strict)
      end
    end
  end

  # ---- Fault.update, the whole UPDATE --------------------------------

  # **Two programs build this and that is why it is here.**
  # lab/fault_matrix.rb sends every case to a router on a session of its
  # own and `bgp4r-sim` injects one case on a session that is already
  # up; two copies of "which attributes does a plain UPDATE need" is how
  # two programs come to put different octets on the wire for one
  # catalog name. The matrix had the only copy until #235 and now calls
  # this. **The move was checked rather than assumed**: all 18 cases
  # built byte for byte what the matrix's own method built, measured
  # before the swap.
  def test_names_are_the_catalogs_own
    assert_equal Fault::CATALOG.collect(&:first), Fault.names
  end

  OPTS = { :my_as => 65_001, :next_hop => '10.0.0.1',
           :prefixes => ['203.0.113.0/24'] }.freeze

  # The two octet strings below are the library's own, computed and
  # pasted: RFC 7606 carries no worked example of a whole UPDATE and
  # CLAUDE.md records seventeen hand written expectations in these
  # families that were wrong with the library right.
  def test_one_case_is_the_attribute_plus_what_a_plain_update_needs
    u = Fault.update(:med_length, OPTS)
    # Everything after the 19 octet header's Length field, so the
    # message length is not restated here: the Type, the two list
    # lengths, the four attributes and the prefix.
    assert_equal '020000001a8004050000000a004001010040' \
                 '02040201fde94003040a00000118cb0071', u.to_shex[36..-1]
    # The fault, then ORIGIN, AS_PATH and NEXT_HOP after it.
    assert_equal [ATTR::MULTI_EXIT_DISC, ATTR::ORIGIN, ATTR::AS_PATH, ATTR::NEXT_HOP],
                 u.path_attribute.attributes.collect(&:type)
    assert_equal ['203.0.113.0/24'], u.nlri.to_ary
  end

  # Not added when the fault is that attribute, or the UPDATE would
  # carry a good one beside the faulty one and the router would be
  # answering a duplicate rather than the case.
  def test_an_attribute_the_fault_is_about_is_not_added_beside_it
    %i[origin_length origin_value origin_flags].each do |name|
      types = Fault.update(name, OPTS).path_attribute.attributes.collect(&:type)
      assert_equal 1, types.count(ATTR::ORIGIN), name.to_s
    end
    assert_equal 1, Fault.update(:next_hop_length, OPTS)
                        .path_attribute.attributes.count { |a| a.type == ATTR::NEXT_HOP }
    assert_equal 1, Fault.update(:as_path_segment, OPTS)
                        .path_attribute.attributes.count { |a| a.type == ATTR::AS_PATH }
  end

  # A LOCAL_PREF only when asked for, which is what an internal session
  # wants (RFC 4271 section 5.1.5) and the fault matrix asks for there.
  # FRR 8.4.4 treats an internal route without one as a withdraw, so the
  # matrix's clean route never installed until it was added.
  def test_a_local_pref_is_added_when_asked_for
    plain = Fault.update(:med_length, OPTS).path_attribute
    assert_nil plain[ATTR::LOCAL_PREF]
    pa = Fault.update(:med_length, OPTS.merge(:local_pref => 100)).path_attribute
    assert_equal 100, pa[ATTR::LOCAL_PREF].to_i
  end

  # The two route reflection cases and no others. RFC 7606 sections 7.9
  # and 7.10 judge their length only from an internal peer, and from an
  # external one discard the attribute whatever its length, so the
  # catalog's treat_as_withdraw holds only on an internal session.
  def test_the_internal_cases_are_the_route_reflection_ones
    internal = Fault.catalog.select { |e| e[:ibgp] }
    assert_equal %i[originator_id_length cluster_list_length], internal.collect { |e| e[:name] }
    internal.each do |e|
      assert_equal :treat_as_withdraw, e[:action], e[:name].to_s
      assert_match(/\ARFC 7606 7\.(9|10)\z/, e[:rfc], e[:name].to_s)
    end
    assert_equal false, Fault.catalog.find { |e| e[:name] == :origin_length }[:ibgp]
  end

  def test_every_catalog_case_builds_an_update_that_encodes
    Fault.names.each do |name|
      u = Fault.update(name, OPTS)
      assert_instance_of Update, u, name.to_s
      assert_operator u.to_shex.size, :>, 38, name.to_s
    end
  end

  # Nothing validates, per Conventions: each of these is a shape
  # somebody will want and none of them is refused.
  def test_what_is_left_out_is_left_out
    # No AS_PATH value, which is an empty AS_PATH and what an internal
    # peer gets.
    assert_equal 'empty', Fault.update(:med_length, :prefixes => ['10.0.0.0/8'])
                               .path_attribute[:as_path].as_path
    # No next hop at all, which is an UPDATE RFC 4271 section 4.3 does
    # not allow.
    assert_equal false, Fault.update(:med_length, :my_as => 1)
                             .path_attribute.has?(Next_hop)
    # No NLRI, which is how a case carrying its own inside MP_REACH_NLRI
    # is sent on its own.
    assert_nil Fault.update(:duplicate_mp_reach, :my_as => 1).nlri
  end

  def test_an_unknown_name_is_refused_and_names_the_catalog
    e = assert_raise(ArgumentError) { Fault.update(:no_such_case) }
    assert_match(/CATALOG/, e.message)
  end

  # A fault put in an UPDATE with good attributes still parses in lenient
  # mode, with the fault in errors.
  def test_fault_inside_an_update
    pa = Path_attribute.new(Origin.new(0), As_path.new(100), Next_hop.new('10.0.0.1'))
    pa.append Fault.build(:community_length)
    u = Update.new(pa, Nlri.new('10.0.0.0/8'))
    # Encode and parse both as 2-octet, so only the fault is an error.
    parsed = Update.new(u.encode.is_packed, Update::Info.new(false))
    assert_equal 1, parsed.path_attribute.errors.size
    assert_equal :treat_as_withdraw, parsed.path_attribute.action
  end

end
