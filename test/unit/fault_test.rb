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


  # ---- Fault::UNREACHABILITY, SAFI 81 ------------------------------------

  def test_unreachability_cases_match_their_findings
    assert_equal Fault::UNREACHABILITY.size, Fault.unreachability_catalog.size
    Fault.unreachability_catalog.each do |e|
      pa = Path_attribute.new(Fault.wire(e[:name]).is_packed, :as4byte => true)
      finding = Attr.strongest(pa.errors)
      assert finding, "#{e[:name]}: no finding"
      assert_equal e[:action], finding.action, "#{e[:name]} action"
      assert_equal e[:subcode], finding.subcode, "#{e[:name]} subcode"
      assert_match(/^draft-tantsura-(idr-unreachability-safi-06 section 5|bess-evpn-unreachability-02 section 4\.11)\.\d$/, e[:rfc])
      assert_raise(Malformed_attribute, e[:name].to_s) do
        Path_attribute.new(Fault.wire(e[:name]).is_packed, :as4byte => true, :policy => :strict)
      end
    end
  end

  # Kept out of CATALOG until the lab measures FRR and GoBGP on them, so
  # lab/fault_matrix.rb does not send them yet.
  def test_unreachability_cases_are_not_in_the_matrix_catalog
    names = Fault::UNREACHABILITY.collect(&:first)
    assert_equal [], names & Fault.names
    assert_equal names.size, names.uniq.size
  end

  def test_the_example_reach_has_no_finding
    pa = Path_attribute.new(Fault.unreach_reach(Fault.unreach_nlri).encode.is_packed, :as4byte => true)
    assert_equal [], pa.errors
  end

  # ---- REFRESH, docs/design/bgp-operations.md section 2 ----------------

  # Each case's octets, the length cases with the header's Length and
  # the body agreeing with each other and not with RFC 7313 section 5.
  def test_the_refresh_cases_on_the_wire
    want = {
      :refresh_unadvertised_family => ['ffffffffffffffffffffffffffffffff00170500020080'],
      :refresh_subtype_unknown     => ['ffffffffffffffffffffffffffffffff00170500020380',
                                       'ffffffffffffffffffffffffffffffff0017050002ff80'],
      :refresh_borr_length         => ['ffffffffffffffffffffffffffffffff0018050002018000'],
      :refresh_eorr_length         => ['ffffffffffffffffffffffffffffffff001605000202'],
      :refresh_eorr_without_borr   => ['ffffffffffffffffffffffffffffffff00170500020280'],
      :refresh_borr_before_eor     => ['ffffffffffffffffffffffffffffffff00170500020180'],
    }
    assert_equal(want.keys, BGP::Fault.refresh_names)
    want.each do |name, hex|
      assert_equal(hex, BGP::Fault.refresh(name, 2, 128).collect { |o| o.unpack1('H*') }, name.to_s)
    end
  end

  # What each case expects of a receiver, and the one that needs GR.
  def test_the_refresh_catalog_says_what_the_rfc_expects
    cat = BGP::Fault.refresh_catalog.to_h { |e| [e[:name], [e[:expected], e[:rfc], e[:gr]]] }
    assert_equal([:notification, 'RFC 7313 5', false], cat[:refresh_borr_length])
    assert_equal([:may_ignore, 'RFC 7313 4', false], cat[:refresh_eorr_without_borr])
    assert_equal([:ignore, 'RFC 7313 4', true], cat[:refresh_borr_before_eor])
    assert_equal([:ignore, 'RFC 2918 4', false], cat[:refresh_unadvertised_family])
    assert_raise(ArgumentError) { BGP::Fault.refresh(:origin_length) }
  end

  # A message read back through the factory: the long BoRR is refused
  # as RFC 7313 section 5 says, and a length off by any amount keeps
  # the header and the body in step.
  def test_message_length
    borr = BGP::Route_refresh.new(1, 1, :borr).encode
    assert_raise(BGP::Malformed_route_refresh) { BGP::Message.factory(BGP::Fault.message_length(borr, 1)) }
    assert_equal(borr, BGP::Fault.message_length(borr, 0))
    three = BGP::Fault.message_length(borr, 3)
    assert_equal([26, 26], [three.unpack1('@16n'), three.bytesize])
  end

  def test_the_behaviours
    assert_equal(%i[borr_without_eorr gr_restart gr_restart_no_f gr_restart_family_missing gr_never_back
                    gr_no_eor gr_new_connection gr_consecutive gr_consecutive_n gr_graceful_cease
                    gr_hard_reset gr_notification_no_n], BGP::Fault.behaviour_names)
    assert_equal('7313 4', BGP::Fault::BEHAVIOURS.first[3])
    cat = BGP::Fault.behaviour_catalog.to_h { |b| [b[:name], [b[:rfc], b[:needs]]] }
    assert_equal(['RFC 7313 4', nil], cat[:borr_without_eorr])
    assert_equal(['RFC 4724 4.2', :gr], cat[:gr_restart])
    assert_equal(['RFC 4724 4.2', :no_n], cat[:gr_consecutive])
    assert_equal(['RFC 8538 4.1', :n], cat[:gr_consecutive_n])
    assert_equal(['RFC 8538 3.2', :n], cat[:gr_hard_reset])
    assert_equal(['RFC 4724 4', :no_n], cat[:gr_notification_no_n])
  end

  # RFC 8538 section 3.1: a Hard Reset is Cease subcode 9, its data the
  # inner code and subcode. These two cannot be read inside.
  def test_the_gr_catalog
    assert_equal(%i[hard_reset_empty hard_reset_unknown_inner], BGP::Fault.gr_names)
    assert_equal(['ffffffffffffffffffffffffffffffff0015030609'], BGP::Fault.gr(:hard_reset_empty).collect { |o| o.unpack1('H*') })
    assert_equal(['ffffffffffffffffffffffffffffffff00170306096363'],
                 BGP::Fault.gr('hard_reset_unknown_inner').collect { |o| o.unpack1('H*') })
    BGP::Fault.gr_catalog.each do |c|
      assert_equal([:flush, 'RFC 8538 3.2', true], c.values_at(:expected, :rfc, :n), c[:name].to_s)
    end
    assert_raise(ArgumentError) { BGP::Fault.gr(:refresh_borr_length) }
  end

  # RFC 8210 section 12: each RTR case, its octets, and the Error Code a
  # router answers with. For the four single PDUs, Rtr::Validation finds
  # that code; the other two need the router's VRP table.
  # The RTR cache's behaviours, docs/design/bgp-operations.md 7b.
  def test_the_rtr_behaviours
    assert_equal(%i[rtr_no_data rtr_silent rtr_cache_reset], BGP::Fault.rtr_behaviour_names)
    assert_equal({ :name => :rtr_silent, :description => 'reads queries and answers none',
                   :expected => 'use the data until the Expire Interval, then drop it', :rfc => 'RFC 8210 6' },
                 BGP::Fault.rtr_behaviour_catalog[1])
    assert_equal([], BGP::Fault.rtr_behaviour_names & BGP::Fault.behaviour_names, "bgp4r-sim's are its own")
  end

  def test_the_rtr_catalog
    assert_equal(%i[rtr_unknown_pdu rtr_bad_version rtr_unexpected_version rtr_withdraw_unknown
                    rtr_duplicate_announce rtr_corrupt_length], BGP::Fault.rtr_names)
    hex = ->(n) { BGP::Fault.rtr(n, 0x22).collect { |o| o.unpack1('H*') } }
    response = '0103002200000008'
    eod = '01070022000000180000000100000e100000025800001c20'
    v4 = '0104000000000014%02x181800c00002000000fde7'
    assert_equal(['0163000000000008'], hex[:rtr_unknown_pdu])
    assert_equal(['0903002200000008'], hex[:rtr_bad_version])
    assert_equal(['0003002200000008'], hex[:rtr_unexpected_version])
    assert_equal([response, v4 % 0, eod], hex[:rtr_withdraw_unknown])
    assert_equal([response, v4 % 1, v4 % 1, eod], hex[:rtr_duplicate_announce])
    assert_equal([response, '010400000000001801181800c00002000000fde700000000', eod], hex[:rtr_corrupt_length])
    cat = BGP::Fault.rtr_catalog.to_h { |c| [c[:name], [c[:expected], c[:rfc]]] }
    assert_equal({ :rtr_unknown_pdu => [5, 'RFC 8210 12'], :rtr_bad_version => [4, 'RFC 8210 7, 12'],
                   :rtr_unexpected_version => [8, 'RFC 8210 7, 12'], :rtr_withdraw_unknown => [6, 'RFC 8210 12'],
                   :rtr_duplicate_announce => [7, 'RFC 8210 5.6, 12'], :rtr_corrupt_length => [0, 'RFC 8210 5.6, 12'] }, cat)
    found = { :rtr_unknown_pdu => 0, :rtr_bad_version => 0, :rtr_unexpected_version => 0, :rtr_corrupt_length => 1 }
    found.each do |name, i|
      octets = BGP::Fault.rtr(name)[i]
      assert_equal(cat[name].first, BGP::Rtr::Validation.check(octets, :negotiated => 1).first.code, name.to_s)
    end
    assert_raise(ArgumentError) { BGP::Fault.rtr(:hard_reset_empty) }
  end
end
