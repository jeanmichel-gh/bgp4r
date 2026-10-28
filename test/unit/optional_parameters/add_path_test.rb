#--
# Copyright 2011, 2026 Jean-Michel Esnault.
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
require 'bgp4r'
require "bgp/optional_parameters/add_path"

class TestBgpOptionalParametersAddPath < Test::Unit::TestCase
  include BGP::OPT_PARM::CAP
  # RFC 7911 section 4: the Send/Receive field is 1 when the sender of the
  # capability is able to receive multiple paths, and 2 when it is able to
  # send them. So :send encodes 2 and :recv encodes 1.
  def test_1
    ap = Add_path.new
    ap.add( :send, 1, 1)
    assert_equal '0206450400010102', ap.to_shex
    ap.add( :recv, 2, 128)
    assert_equal '020a45080001010200028001', ap.to_shex
    ap.add :send_and_receive, :ipv6, :unicast
    assert_equal '020e450c000101020002010300028001', ap.to_shex
  end
  def test_2
    ap = Add_path.new
    ap.add( :send, 1, 1)
    ap.add( :send, 2, 128)
    ap.add( :send_and_recv, 2, 128)
    assert ap.send? 1, 1
    assert ! ap.send?( 1, 2)
    assert ap.send?( 2, 128)
    assert ap.recv?( 2, 128)
  end
  def test_3
    ap1 = Add_path.new_array [[2, 1 ,2 ], [1, 10, 10]]
    ap2 = Add_path.new_array [[:send, :ipv4 ,:multicast], [:recv, 10, 10]]
    assert_equal ap1.to_shex, ap2.to_shex
  end

  # RFC 7911 section 4, each value read off the wire. This is the side that
  # matters against a real router: it sends the field, bgp4r reads it, and
  # which question it answers is what decides whether a Path Identifier is
  # expected on the session.
  def test_the_wire_values_answer_the_questions_rfc_7911_section_4_gives_them
    recv_only = Add_path.new(['0206450400010101'].pack('H*'))
    assert   recv_only.recv?(1, 1), 'value 1 is able to receive (RFC 7911 section 4)'
    assert ! recv_only.send?(1, 1), 'value 1 is not able to send'

    send_only = Add_path.new(['0206450400010102'].pack('H*'))
    assert   send_only.send?(1, 1), 'value 2 is able to send (RFC 7911 section 4)'
    assert ! send_only.recv?(1, 1), 'value 2 is not able to receive'

    both = Add_path.new(['0206450400010103'].pack('H*'))
    assert both.send?(1, 1), 'value 3 is both (RFC 7911 section 4)'
    assert both.recv?(1, 1), 'value 3 is both (RFC 7911 section 4)'
  end

  # The three build paths agree, without a hex literal to pin them: a
  # capability built from symbols, one built from the field values, and one
  # parsed back from the wire bytes answer the same questions.
  def test_the_three_build_paths_agree_on_the_direction
    [[:recv, 1], [:send, 2], [:send_and_recv, 3]].each do |sym, val|
      from_sym = Add_path.new(sym, 1, 1)
      from_val = Add_path.new(val, 1, 1)
      from_wire = Add_path.new(from_sym.encode)
      assert_equal from_sym.to_shex, from_val.to_shex, "#{sym.inspect} is value #{val}"
      assert_equal from_sym.to_shex, from_wire.to_shex
      [from_sym, from_val, from_wire].each do |ap|
        assert_equal (val == 1 or val == 3), ap.recv?(1, 1), "recv? of #{sym.inspect}"
        assert_equal (val == 2 or val == 3), ap.send?(1, 1), "send? of #{sym.inspect}"
      end
    end
  end

  # Building and encoding are never validated. RFC 7911 section 4 says a
  # receiver SHOULD treat any other value as not understood and ignore it,
  # which is a receive side rule: bgp4r must still put it on the wire.
  def test_a_send_receive_value_no_rfc_defines_still_builds_and_encodes
    [0, 4, 255].each do |val|
      ap = Add_path.new(val, 1, 1)
      assert_equal "02064504000101%02x" % val, ap.to_shex
      assert_equal ap.to_shex, Add_path.new(ap.encode).to_shex
      assert ! ap.send?(1, 1), "#{val} answers neither question"
      assert ! ap.recv?(1, 1), "#{val} answers neither question"
    end
  end

  # The human readable form names the value the RFC gives it.
  def test_to_s_names_the_direction_the_rfc_gives_the_value
    assert_match(/RECV \(1\)/, Add_path.new(:recv, 1, 1).to_s)
    assert_match(/SEND \(2\)/, Add_path.new(:send, 1, 1).to_s)
    assert_match(/SEND_AND_RECV \(3\)/, Add_path.new(:send_and_recv, 1, 1).to_s)
  end

  # Same hole in the long form, where to_s_brief already fell back.
  def test_an_unnamed_address_family_prints_its_number
    cap = Add_path.new(:send_and_recv, 999, 77)
    assert_match(/AFI 999, SAFI 77, SEND_AND_RECV \(3\)/, cap.to_s)
    assert_match(/999, 77 SEND_AND_RECV/, cap.to_s_brief)
    assert_match(/AFI IPv4 \(1\), SAFI Unicast \(1\)/, Add_path.new(:send, 1, 1).to_s)
  end
end
