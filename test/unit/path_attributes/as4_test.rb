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

class TestAs4 < Test::Unit::TestCase
  include BGP

  BIG = 4200000001       # 0xfa56ea01
  BIG2 = 4200000002      # 0xfa56ea02

  def seq(*as) As_path::Sequence.new(*as) end
  def set(*as) As_path::Set.new(*as) end

  def path(*segs)
    Path_attribute.new(Origin.new(0), As_path.new(*segs), Next_hop.new('1.1.1.1'))
  end

  # What an OLD speaker sees: the attributes parsed back with 2-octet AS numbers.
  def over_old_session(pa)
    Path_attribute.new(pa.encode(false), false)
  end

  def hex(attr) attr.encode(false).unpack1('H*') end

  # RFC 6793 section 4.2.2

  def test_fixup_leaves_a_2_octet_path_alone
    pa = path(seq(100, 200))
    f = pa.as4_fixup
    assert_equal pa.encode(false), f.encode(false)
    assert f.has_no?(As4_path)
  end

  def test_fixup_puts_as_trans_in_as_path_and_adds_as4_path
    f = path(seq(100, BIG, 200)).as4_fixup
    assert_equal '400208020300645ba000c8', hex(f[:as_path])
    assert_equal 'c0110e020300000064fa56ea01000000c8', hex(f[:as4_path])
    assert_equal '100 23456 200', f[:as_path].as_path
    assert_equal '100 4200000001 200', f[:as4_path].as_path
  end

  def test_fixup_leaves_confed_segments_out_of_as4_path
    f = path(As_path::Confed_sequence.new(BIG2), seq(100, BIG)).as4_fixup
    assert_equal '(23456) 100 23456', f[:as_path].as_path
    assert_equal '100 4200000001', f[:as4_path].as_path
  end

  def test_fixup_as4_path_without_the_large_confed_segment
    f = path(As_path::Confed_sequence.new(BIG2), seq(100)).as4_fixup
    assert_equal '(23456) 100', f[:as_path].as_path
    assert_equal '100', f[:as4_path].as_path
  end

  def test_fixup_aggregator
    pa = Path_attribute.new(Origin.new(0), As_path.new(100), Aggregator.new('2.2.2.2', BIG))
    f = pa.as4_fixup
    assert_equal 'c007065ba002020202', hex(f[:aggregator])
    assert_equal 'c01208fa56ea0102020202', hex(f[:as4_aggregator])
    assert f.has_no?(As4_path)
  end

  def test_fixup_keeps_as4_attributes_the_caller_added
    mine = As4_path.new(seq(1, 2, 3))
    pa = path(seq(100, BIG))
    pa.add mine
    f = pa.as4_fixup
    assert_equal 1, f.attributes.count { |a| a.type == ATTR::AS4_PATH }
    assert_equal '1 2 3', f[:as4_path].as_path
  end

  def test_fixup_does_not_change_the_receiver
    pa = path(seq(100, BIG))
    before = pa.encode(true)
    pa.as4_fixup
    assert_equal before, pa.encode(true)
    assert pa.has_no?(As4_path)
  end

  def test_fixup_bang_changes_the_receiver
    pa = path(seq(100, BIG))
    assert_same pa, pa.as4_fixup!
    assert_equal '100 23456', pa[:as_path].as_path
    assert pa.has?(As4_path)
  end

  def test_encode_alone_still_cuts_the_as_number
    # Building never refuses: without as4_fixup a test can still send this.
    assert_equal '4002060202' + '0064ea01', hex(As_path.new(seq(100, BIG)))
  end

  # RFC 6793 section 4.2.3

  def test_merge_rebuilds_what_fixup_sent
    pa = Path_attribute.new(Origin.new(0), As_path.new(seq(100, BIG, 200), set(BIG2, 300)),
                            Next_hop.new('1.1.1.1'), Aggregator.new('2.2.2.2', BIG))
    m = over_old_session(pa.as4_fixup).as4_merge
    assert_equal '100 4200000001 200 {4200000002, 300}', m[:as_path].as_path
    assert_equal BIG, m[:aggregator].asn
    assert_equal '2.2.2.2', m[:aggregator].address
    assert m.has_no?(As4_path)
    assert m.has_no?(As4_aggregator)
    assert_equal pa.encode(true), m.encode(true)
  end

  def test_merge_keeps_ases_an_old_speaker_prepended
    old = path(seq(64512, 64513, 100, 23456))
    old.add As4_path.new(seq(100, BIG))
    m = old.as4_merge
    assert_equal '64512 64513 100 4200000001', m[:as_path].as_path
  end

  def test_merge_ignores_as4_path_longer_than_as_path
    old = path(seq(100, 23456))
    old.add As4_path.new(seq(1, 2, BIG))
    m = old.as4_merge
    assert_equal '100 23456', m[:as_path].as_path
    assert m.has_no?(As4_path)
  end

  def test_merge_counts_a_set_as_one
    old = path(seq(64512), set(23456, 300))
    old.add As4_path.new(set(BIG, 300))
    assert_equal '64512 {4200000001, 300}', old.as4_merge[:as_path].as_path
  end

  def test_merge_keeps_leading_confed_segments
    old = path(As_path::Confed_sequence.new(65000), seq(100, 23456))
    old.add As4_path.new(seq(100, BIG))
    assert_equal '(65000) 100 4200000001', old.as4_merge[:as_path].as_path
  end

  def test_merge_ignores_as4_attributes_when_aggregator_has_a_real_as
    old = Path_attribute.new(Origin.new(0), As_path.new(seq(100, 23456)), Aggregator.new('2.2.2.2', 200))
    old.add As4_path.new(seq(100, BIG))
    old.add As4_aggregator.new('3.3.3.3', BIG)
    m = old.as4_merge
    assert_equal '100 23456', m[:as_path].as_path
    assert_equal 200, m[:aggregator].asn
    assert m.has_no?(As4_path)
    assert m.has_no?(As4_aggregator)
  end

  def test_merge_without_as4_attributes_changes_nothing
    pa = path(seq(100, 200))
    assert_equal pa.encode(true), pa.as4_merge.encode(true)
  end

  def test_merge_bang_and_receiver
    old = path(seq(100, 23456))
    old.add As4_path.new(seq(100, BIG))
    before = old.encode(true)
    old.as4_merge
    assert_equal before, old.encode(true)
    assert_same old, old.as4_merge!
    assert_equal '100 4200000001', old[:as_path].as_path
  end

  def test_empty_segment_from_the_wire_survives
    pa = Path_attribute.new(Origin.new(0), As_path.new(['40020a0200020300645ba000c8'].pack('H*').b))
    assert_nothing_raised { pa.as4_fixup }
    assert_equal pa.encode(false), pa.as4_fixup.encode(false)
  end

  # B17. A malformed AS_PATH or AGGREGATOR arrives as an Attr::Raw, which
  # has no segments or asn. Both helpers used to raise NoMethodError, so
  # bgp4r could not send either fault over a session: Neighbor#send_update
  # calls as4_fixup on every 2-octet session.
  def test_fixup_passes_raw_attributes_through
    raw_path = Attr::Raw.new(ATTR::WELL_KNOWN_MANDATORY, ATTR::AS_PATH, "\x02\x02\x00".b)
    raw_aggr = Attr::Raw.new(ATTR::OPTIONAL_TRANSITIVE, ATTR::AGGREGATOR, "\x00\x64\x0a\x00".b)
    pa = Path_attribute.new(Origin.new(0), raw_path, raw_aggr)
    assert_nothing_raised { pa.as4_fixup }
    assert_equal pa.encode(false), pa.as4_fixup.encode(false), 'a raw attribute goes out as it was built'
    assert pa.as4_fixup.has_no?(As4_path)
  end

  def test_merge_passes_raw_attributes_through
    pa = Path_attribute.new(Origin.new(0),
                            Attr::Raw.new(ATTR::WELL_KNOWN_MANDATORY, ATTR::AS_PATH, "\x02\x02\x00".b),
                            Attr::Raw.new(ATTR::OPTIONAL_TRANSITIVE, ATTR::AS4_PATH, "\x02\x01".b))
    assert_nothing_raised { pa.as4_merge }
    assert_equal pa.encode(true), pa.as4_merge.encode(true)
  end

  # A good AS_PATH beside a raw one is still fixed up.
  def test_fixup_still_works_with_a_raw_aggregator
    pa = Path_attribute.new(As_path.new(100, BIG),
                            Attr::Raw.new(ATTR::OPTIONAL_TRANSITIVE, ATTR::AGGREGATOR, "\x00".b))
    f = pa.as4_fixup
    assert_equal '100 23456', f[:as_path].as_path
    assert_equal '100 4200000001', f[:as4_path].as_path
  end

end
