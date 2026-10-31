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

# RFC 6368 has no worked example and no hex, so every expectation here
# is this reader's arithmetic against the section 5 field list rather
# than octets the document printed. Each one spells the breakdown out in
# a comment for that reason: the field list is what makes a wrong
# expectation findable.
class TestAttrSet < Test::Unit::TestCase
  include BGP

  def wire(hex) [hex].pack('H*').is_packed end

  # The set used by most tests below. c0 optional transitive, 80 type
  # 128, 0f length 15, then 4 octets of origin AS and two attributes.
  SET = 'c0800f' + '0000fde8' + '40010100' + '40050400000064'

  # RFC 6368 section 5: optional transitive, type code 128, a 4-octet
  # Origin AS then the path attributes.
  def test_from_field_values
    a = Attr_set.new(65000, Origin.new(:igp), Local_pref.new(100))
    assert_equal SET, a.to_shex
    assert_equal 65000, a.origin_as
    assert a.is_optional?
    assert a.is_transitive?
    assert_equal 128, a.type
  end

  def test_from_wire
    a = Attr_set.new(wire(SET))
    assert_equal SET, a.to_shex, 'replays byte for byte'
    assert_equal 65000, a.origin_as
    assert_equal [Origin, Local_pref], a.attributes.attributes.collect(&:class)
  end

  def test_from_another_instance
    a = Attr_set.new(65000, Origin.new(:igp), Local_pref.new(100))
    assert_equal a.to_shex, Attr_set.new(a).to_shex
  end

  def test_from_a_ready_made_path_attribute
    pa = Path_attribute.new(Origin.new(:igp), Local_pref.new(100))
    assert_equal SET, Attr_set.new(65000, pa).to_shex
  end

  # Required by Conventions: where an object rebuilds from its own hash,
  # a test in its own file must say so, exercising every field it
  # carries. Both fields here, and both nested attributes.
  def test_its_own_hash_rebuilds_it
    a = Attr_set.new(65000, Origin.new(:igp), Local_pref.new(100))
    h = a.to_hash
    assert_equal({ :attr_set => { :origin_as => 65000,
                                  :attributes => { :origin => :igp,
                                                   :local_pref => 100 } } }, h)
    assert_equal a.to_shex, Attr_set.new(h).to_shex, 'the wrapped form'
    assert_equal a.to_shex, Attr_set.new(h[:attr_set]).to_shex, 'the bare form'
  end

  # The wrapped form has to be unwrapped rather than ignored. Without
  # that, neither key is found and an ATTR_SET with origin AS 0 and no
  # attributes is built in silence, which is the failure
  # Extended_community::Traffic_action records. Deleting the unwrap in
  # attr_set.rb fails this and the test above.
  def test_the_wrapped_form_is_not_read_as_an_empty_set
    a = Attr_set.new(65000, Origin.new(:igp))
    built = Attr_set.new(a.to_hash)
    assert_equal 65000, built.origin_as, 'not 0'
    assert_equal 1, built.attributes.attributes.size, 'not empty'
  end

  # RFC 6368 section 5: AS_PATH and AGGREGATOR inside "MUST be encoded
  # using 4-octet AS numbers", regardless of the capabilities advertised
  # to the peer. bgp4r's encode has a 2 against 4 octet switch, so this
  # is the one rule in the attribute that does not fall out, and it is
  # checked against the top level forms rather than against hex written
  # here.
  def test_the_nested_as_numbers_are_always_four_octets
    inside = Attr_set.new(65000,
                          As_path.new(65001, 65002),
                          Aggregator.new('10.0.0.1', 4200000001))
    same = Path_attribute.new(As_path.new(65001, 65002),
                              Aggregator.new('10.0.0.1', 4200000001))
    # 3 octets of attribute header plus 4 of origin AS is 14 hex chars.
    nested = inside.to_shex[14..-1]
    assert_equal same.encode(true).unpack1('H*'), nested, 'the 4 octet form'
    assert_not_equal same.encode.unpack1('H*'), nested, 'and not the 2 octet one'
  end

  # The same rule on the way in. A 2-octet parse reads AS 4200000001
  # back as 59905, silently, which is the truncation CLAUDE.md records
  # for As4_aggregator. Reverting Attr_set::INNER's :as4byte fails this.
  def test_the_nested_as_numbers_are_read_back_as_four_octets
    sent = Attr_set.new(65000, Aggregator.new('10.0.0.1', 4200000001))
    got = Attr_set.new(wire(sent.to_shex))
    agg = got.attributes.attributes.find { |x| x.is_a?(Aggregator) }
    assert_equal 4200000001, agg.asn
    assert_equal sent.to_shex, got.to_shex
  end

  # An ATTR_SET inside a Path_attribute, off the wire and back. This is
  # the registry path, and the only test that says attribute 128 is
  # wired in at all: without the Attr.register call the set comes back
  # as an Attr::Unknown.
  def test_it_round_trips_inside_a_path_attribute
    inner = Attr_set.new(65000, Origin.new(:igp), Local_pref.new(100))
    pa = Path_attribute.new(Origin.new(:egp), inner, Next_hop.new('10.0.0.1'))
    hex = pa.encode.unpack1('H*')
    back = Path_attribute.new(wire(hex))
    assert_equal hex, back.encode.unpack1('H*')
    assert_equal [Origin, Attr_set, Next_hop],
                 back.attributes.collect(&:class)
    assert_equal 0, back.errors.size, 'a well formed set is not an error'
    assert_equal 0, back.undecoded.size, 'and not a gap in bgp4r either'
  end

  def test_a_path_attribute_rebuilds_it_from_the_hash
    pa = Path_attribute.new(Attr_set.new(65000, Origin.new(:igp)))
    hex = pa.encode.unpack1('H*')
    assert_equal hex, Path_attribute.new(pa.to_hash).encode.unpack1('H*')
  end

  # The minimum length section 5 allows: 4 octets, the Origin AS alone.
  # c0 80 04 then the AS.
  def test_an_empty_set_is_four_octets_of_value
    assert_equal 'c080040000fde8', Attr_set.new(65000).to_shex
  end

  def test_attributes_can_be_added_after_building
    a = Attr_set.new(65000)
    a << Origin.new(:igp)
    a.add Local_pref.new(100)
    assert_equal SET, a.to_shex
  end

  # Conventions: building never validates, so each of these is a
  # deliberate deviation the library has to be able to put on the wire.
  def test_nothing_validates
    # Section 5 says the set can carry any attribute "except MP_REACH
    # and MP_UNREACH". Both still build.
    mp = Mp_reach.new(:afi => 1, :safi => 1, :nexthop => ['10.0.0.1'],
                      :nlris => ['20.0.0.0/8'])
    assert_match(/^c080/, Attr_set.new(65000, mp).to_shex)
    un = Mp_unreach.new(:afi => 1, :safi => 1, :nlris => ['20.0.0.0/8'])
    assert_match(/^c080/, Attr_set.new(65000, un).to_shex)
    # Section 5 says NEXT_HOP "SHOULD NOT be included".
    assert_match(/^c080/, Attr_set.new(65000, Next_hop.new('10.0.0.1')).to_shex)
    # An origin AS of 0, and a set nested in a set.
    assert_equal 'c0800400000000', Attr_set.new(0).to_shex
    # The inner set is c0 80 08 plus 8 octets of value, 11 in all, so
    # the outer value is 4 of origin AS plus those 11, which is 0x0f.
    # Written as 0x13 and 0x0b first, by putting each length where the
    # other belonged, and the library was right both times.
    nested = Attr_set.new(65000, Attr_set.new(65001, Origin.new(:igp)))
    assert_equal 'c0800f0000fde8c080080000fde940010100', nested.to_shex
  end

  # The header is made to lie through Attr::OVERRIDE_KEYS like any
  # other attribute, so a length below the 4 octet minimum of section 5
  # is reachable without the class refusing anything.
  def test_the_header_can_be_made_to_lie
    a = Attr_set.new(65000, Origin.new(:igp), :length => 2)
    assert_equal 'c080020000fde840010100', a.to_shex
  end

  # The one refusal, and it is representability rather than judgement:
  # section 5 gives the Origin AS as a 32-bit unsigned integer, so a
  # value that does not fit would be sent as a different AS.
  def test_an_origin_as_that_does_not_fit_is_refused
    [4294967296, -1, '65000', 1.5].each do |v|
      assert_raise(ArgumentError, v.inspect) { Attr_set.new(65000).origin_as = v }
    end
    assert_equal 4294967295, Attr_set.new(0xffffffff).origin_as
  end

  # A value too short to hold the Origin AS is kept and echoed, the way
  # pmsi_tunnel.rb keeps a value shorter than its own fixed part. A
  # reader that invented a zero AS instead would answer encode with
  # octets the peer never sent: c08003000000 came back as c080040000
  # 0000, one octet longer than it arrived. Deleting the branch in
  # attr_set.rb#parse fails every assertion here.
  def test_a_value_too_short_for_the_origin_as_is_kept_whole
    ['c08003000000', 'c0800100', 'c080020000'].each do |hex|
      a = Attr_set.new(wire(hex))
      assert_equal hex, a.to_shex, 'replays byte for byte'
      assert_equal({ :attr_set => { :tail => hex[6..-1] } }, a.to_hash)
      assert_equal hex, Attr_set.new(a.to_hash).to_shex, 'and rebuilds from it'
    end
  end

  # No tail, no key, so an ordinary set hashes as the two fields it has
  # always hashed as. Same rule as :tail and :bits elsewhere.
  def test_an_ordinary_set_has_no_tail_key
    h = Attr_set.new(65000, Origin.new(:igp)).to_hash
    assert !h[:attr_set].key?(:tail)
    assert_equal [:origin_as, :attributes], h[:attr_set].keys
  end

  # The whole attribute set has to survive one too, since a short value
  # arrives inside a Path_attribute in practice and the finding is what
  # reports it.
  def test_a_short_set_replays_inside_a_path_attribute
    hex = 'c08003000000'
    pa = Path_attribute.new(wire(hex))
    assert_equal hex, pa.encode.unpack1('H*')
    assert_equal 1, pa.errors.size
    assert_equal :treat_as_withdraw, pa.errors.first.action
  end

  # The shapes :attributes accepts in a hash. All four are reachable and
  # none was covered until this test: a Path_attribute, the hash one
  # answers, a bare attribute, and nothing at all.
  def test_the_attributes_key_takes_four_shapes
    # 4 octets of Origin AS plus a 4 octet ORIGIN is a value of 8.
    pa = Path_attribute.new(Origin.new(:igp))
    assert_equal 'c080080000fde840010100',
                 Attr_set.new(:origin_as => 65000, :attributes => pa).to_shex
    assert_equal 'c080080000fde840010100',
                 Attr_set.new(:origin_as => 65000, :attributes => pa.to_hash).to_shex
    assert_equal 'c080080000fde840010100',
                 Attr_set.new(:origin_as => 65000,
                              :attributes => Origin.new(:igp)).to_shex
    assert_equal 'c080040000fde8',
                 Attr_set.new(:origin_as => 65000).to_shex
  end

  def test_an_argument_it_cannot_read_raises
    [nil, 'not packed', 1.5, :igp, []].each do |arg|
      assert_raise(ArgumentError, arg.inspect) { Attr_set.new(arg) }
    end
  end

  def test_to_s_names_the_origin_as_and_the_nested_attributes
    s = Attr_set.new(65000, Origin.new(:igp)).to_s
    assert_match(/Attr Set/, s)
    assert_match(/Origin AS 65000/, s)
    assert_match(/igp/, s)
  end

end
