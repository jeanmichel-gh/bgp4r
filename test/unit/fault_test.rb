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
