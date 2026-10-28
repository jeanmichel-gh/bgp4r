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

class TestAttrCheck < Test::Unit::TestCase
  include BGP

  def b(hex) [hex.delete(' ')].pack('H*').is_packed end

  # [subcode, action] of each finding for one attribute.
  def check(hex, as4byte = false)
    Attr::Check.attribute(b(hex), as4byte).collect { |f| [f.subcode, f.action] }
  end

  TAW, DISCARD, RESET = :treat_as_withdraw, :attribute_discard, :session_reset

  def test_good_attributes_have_no_findings
    [ '40 01 01 00', '40 02 06 0202 0064 0065', '40 03 04 0a000001', '80 04 04 00000064',
      '40 05 04 00000064', '40 06 00', 'c0 07 06 0064 01010101', 'c0 08 04 00640001',
      '80 09 04 01010101', '80 0a 04 01010101', 'c0 10 08 0002006400000001',
      '40 02 00', 'c0 11 06 0201 fa56ea01' ].each do |hex|
      assert_equal [], check(hex), hex
    end
    assert_equal [], check('c0 07 08 fa56ea01 01010101', true)
  end

  # RFC 7606 section 7, one rule each.
  def test_origin
    assert_equal [[5, TAW]], check('40 01 02 0000')
    assert_equal [[5, TAW]], check('40 01 00')
    assert_equal [[6, TAW]], check('40 01 01 03')
  end

  def test_as_path
    assert_equal [[11, TAW]], check('40 02 04 0501 0064')        # unknown segment type
    assert_equal [[11, TAW]], check('40 02 02 0200')             # zero length segment
    assert_equal [[11, TAW]], check('40 02 04 0202 0064')        # segment overruns
    assert_equal [[11, TAW]], check('40 02 05 0201 0064 02')     # one octet left
    assert_equal [[11, TAW]], check('40 02 06 0202 0064 0065', true)  # 2 AS of 4 octets need 8
  end

  def test_as4_path
    assert_equal [[11, DISCARD]], check('c0 11 06 0301 fa56ea01')   # confed (RFC 6793 section 6)
    assert_equal [[11, DISCARD]], check('c0 11 04 0201 0064')
  end

  def test_fixed_lengths
    assert_equal [[5, TAW]], check('40 03 00')
    assert_equal [[5, TAW]], check('80 04 03 000064')
    assert_equal [[5, TAW]], check('40 05 05 0000006400')
    assert_equal [[5, DISCARD]], check('40 06 01 00')
    assert_equal [[5, TAW]], check('80 09 03 010101')
  end

  def test_aggregator_length_follows_the_session
    assert_equal [], check('c0 07 06 0064 01010101')
    assert_equal [[5, DISCARD]], check('c0 07 06 0064 01010101', true)
    assert_equal [[5, DISCARD]], check('c0 07 08 fa56ea01 01010101')
    assert_equal [[5, DISCARD]], check('c0 12 06 0064 01010101', true)
  end

  def test_multiples
    assert_equal [[5, TAW]], check('c0 08 05 0102030405')
    assert_equal [[5, TAW]], check('c0 08 00')
    assert_equal [[5, TAW]], check('80 0a 06 010101010202')
    assert_equal [[5, TAW]], check('c0 10 09 000200640000000100')
  end

  def test_mp_reach_and_unreach
    assert_equal [[9, RESET]], check('80 0e 04 00010104')
    assert_equal [[9, RESET]], check('80 0e 06 000101040a00')    # next hop says 4, 2 there
    assert_equal [], check('80 0e 0a 000101040a000001 00 00')
    assert_equal [[9, RESET]], check('80 0f 02 0001')
  end

  # RFC 7606 section 3 (c).
  def test_flags
    assert_equal [[4, TAW]], check('c0 01 01 00')
    assert_equal [[4, TAW]], check('c0 04 04 00000064')
    assert_equal [], check('60 01 01 00')        # the Partial bit is not checked
    assert_equal [], check('50 01 0001 00')      # nor the Extended Length bit
  end

  # RFC 4271 section 6.3.
  def test_unknown_types
    assert_equal [[2, RESET]], check('40 fa 01 78')
    assert_equal [], check('c0 fa 01 78')
    assert_equal [], check('80 fa 01 78')
  end

  # RFC 7606 section 4.
  def test_next_attribute_splits_and_reports_cuts
    s = b('40010100 4003040a000001')
    a, f = Attr::Check.next_attribute(s)
    assert_equal '40010100', a.unpack1('H*')
    assert_nil f
    assert a.is_packed?

    s = b('40 03 08 0a000001')
    a, f = Attr::Check.next_attribute(s)
    assert_equal '4003080a000001', a.unpack1('H*')
    assert_equal [3, 1, TAW], [f.type, f.subcode, f.action]
    assert_match(/4 octets left/, f.reason)
    assert_equal 0, s.size

    a, f = Attr::Check.next_attribute(b('4001'))
    assert_equal [nil, 1, TAW], [f.type, f.subcode, f.action]
  end

  def test_exact_reports_a_short_length_field
    # Parsing never sees this: next_attribute cuts at the length field.
    assert_equal [], check('40 01 01 0000')
    findings = Attr::Check.attribute(b('40 01 01 0000'), false, exact: true)
    assert_equal 1, findings.size
    assert_match(/length 1 but 2/, findings.first.reason)
  end

  def test_duplicates
    assert_equal [1, DISCARD], [Attr::Check.duplicate_finding(1).subcode, Attr::Check.duplicate_finding(1).action]
    assert_equal RESET, Attr::Check.duplicate_finding(14).action
    assert_equal RESET, Attr::Check.duplicate_finding(15).action
  end

  # RFC 7606 section 3 (h).
  def test_strongest
    d = Attr::Finding.new(6, 5, DISCARD, 'x')
    t = Attr::Finding.new(1, 5, TAW, 'y')
    r = Attr::Finding.new(14, 1, RESET, 'z')
    n = Attr::Finding.new(2, nil, nil, 'note')
    assert_equal t, Attr.strongest([d, t, n])
    assert_equal r, Attr.strongest([d, r, t])
    assert_nil Attr.strongest([n])
  end

  def test_finding_notification
    f = Attr::Finding.new(1, 6, TAW, 'x')
    assert_equal [3, 6], f.notification.to_hash.values_at(:code, :subcode)
    assert_nil Attr::Finding.new(1, nil, nil, 'x').notification
    assert_equal 'attribute 1: x (treat_as_withdraw)', f.to_s
  end

  # A Gap says bgp4r could not read an attribute, which is not a thing
  # a peer did wrong: RFC 7606 section 7 says what makes each attribute
  # malformed and a reader's missing code is not on any of those lists.
  # So it is not a Finding and carries nothing the RFC 7606 machinery
  # could act on.
  def test_gap_is_not_a_finding
    g = Attr::Gap.new(14, 'cannot parse nexthop for safi 70', ArgumentError, nil)
    assert_equal 'attribute 14: bgp4r could not decode it: cannot parse nexthop for safi 70', g.to_s
    assert_equal 'attribute ?: bgp4r could not decode it: x', Attr::Gap.new(nil, 'x', nil, nil).to_s
    assert_not_kind_of Attr::Finding, g
    assert !g.respond_to?(:action)
    assert !g.respond_to?(:subcode)
    assert !g.respond_to?(:notification)
  end

  def test_malformed_attribute
    e = Malformed_attribute.new([Attr::Finding.new(6, 5, DISCARD, 'a'), Attr::Finding.new(1, 6, TAW, 'b')])
    assert_equal [1, 6, TAW], [e.type, e.subcode, e.action]
    assert_equal 2, e.findings.size
    assert_equal 'attribute 1: b (treat_as_withdraw)', e.message
  end

end
