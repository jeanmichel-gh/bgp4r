#--
# Copyright 2010, 2026 Jean-Michel Esnault.
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

require 'test/unit'
require 'bgp4r'

class Optional_parameter_Test < Test::Unit::TestCase
  include BGP
  # draft-ietf-idr-ext-opt-param-01, which these two tests were written
  # against, became RFC 9072 in July 2021.
  #
  # RFC 9072 section 2, Figure 1: past 255 octets of Optional Parameters
  # the one octet length becomes a Non-Ext OP Len. octet of 255, a
  # Non-Ext OP Type octet of 255, and the two octet Extended Optional
  # Parameters Length.
  def test_rfc9072_the_outer_length_is_two_octets_past_255
    octet = String.new
    # A stand-in for an optional parameter, one octet with no header of
    # its own, so it writes the same thing either way. It still has to
    # take the keyword, because Open#encode tells every parameter which
    # form the message is in.
    def octet.encode(extended: false)
      [0xab].pack('C')
    end
    assert_match(/^(ff){16}011b01040064007801010101fe(ab){254}$/, 
            Open.new(4, 100, 120, '1.1.1.1', *([octet]*254)).to_shex)
    assert_match(/^(ff){16}011c01040064007801010101ff(ab){255}$/, 
            Open.new(4, 100, 120, '1.1.1.1', *([octet]*255)).to_shex)
    assert_match(/^(ff){16}012001040064007801010101ffff0100(ab){256}$/, 
            Open.new(4, 100, 120, '1.1.1.1', *([octet]*256)).to_shex)
    assert_match(/^(ff){16}012101040064007801010101ffff0101(ab){257}$/, 
            Open.new(4, 100, 120, '1.1.1.1', *([octet]*257)).to_shex)
  end
  # RFC 9072 section 2, Figure 2 "Extended Parameters Format": "The
  # rules for encoding Optional Parameters are unchanged with respect to
  # those given in [RFC4271], except that the Parameter Length field is
  # extended to be a two-octet unsigned integer."
  #
  # So each MBGP parameter is 02 0006 01 04 00010001, nine octets, not
  # the eight this test used to assert. bgp4r wrote the one octet length
  # inside the extended form and read it back the same way, which was
  # self consistent and wrong on the wire: 100 parameters came to
  # ffff0320 and 02 06, where the RFC wants ffff0384 and 02 0006.
  def test_rfc9072_a_parameter_length_is_two_octets_in_the_extended_form
    mbgp = OPT_PARM::CAP::Mbgp.new(1,1)
    open1 = Open.new(4, 100, 120, '1.1.1.1', *[mbgp]*100)
    open2 = Open.new(4, 100, 120, '1.1.1.1', *[mbgp]*10)
    assert_match(/^(ff){16}03a401040064007801010101\s*ffff0384\s*020006010400010001/, open1.to_shex)
    assert_match(/^(ff){16}006d01040064007801010101\s*50\s*0206010400010001/, open2.to_shex)
    assert_equal Open.new(open1).to_shex, open1.to_shex
    assert_equal Open.new(open2).to_shex, open2.to_shex
    assert Open.new(open1.encode).extended?
    assert !Open.new(open2.encode).extended?
  end

  # The parameter header on its own, both ways round. An optional
  # parameter encoded by itself is in the RFC 4271 form, as it always
  # was; the extended form is asked for.
  def test_rfc9072_the_parameter_header_either_way
    mbgp = BGP::OPT_PARM::CAP::Mbgp.new(1,1)
    assert_equal '0206010400010001',   mbgp.encode.unpack('H*')[0]
    assert_equal '020006010400010001', mbgp.encode(:extended => true).unpack('H*')[0]
    # The capability inside keeps the one octet code and one octet
    # length of RFC 5492 section 4: RFC 9072 widens the parameter header
    # and nothing else. A capability with no value and one whose code
    # bgp4r does not implement take the wider header too.
    assert_equal '0200020200',
                 BGP::OPT_PARM::CAP::Route_refresh.new.encode(:extended => true).unpack('H*')[0]
    assert_equal '02000564' + '03414243',
                 BGP::OPT_PARM::CAP::Unknown.new(100, 'ABC').encode(:extended => true).unpack('H*')[0]
  end

  # Optional_parameter.factory reads the parameter it is given and
  # leaves the rest, so the three octet header has to be consumed whole.
  def test_rfc9072_factory_consumes_the_three_octet_header
    s = ['020006010400010001' + '020006010400010002'].pack('H*').is_packed
    caps = BGP::OPT_PARM::Optional_parameter.factory(s, :extended => true)
    assert_equal 1, caps.size
    assert_equal 1, caps[0].safi
    assert_equal 9, s.size, 'the second parameter is left untouched'
    caps = BGP::OPT_PARM::Optional_parameter.factory(s, :extended => true)
    assert_equal 2, caps[0].safi
    assert_equal 0, s.size
  end

  UNKNOWN = BGP::OPT_PARM::Optional_parameter::Unknown

  # An OPEN carrying these parameter octets, as hex.
  #
  # The header is 19 octets and the message Type octet is one of them:
  # 16 marker, 2 length, 1 type. Then the body, which is version 1,
  # My Autonomous System 2, Hold Time 2, BGP Identifier 4 and Optional
  # Parameters Length 1, so 10 before the parameters. Leaving the Type
  # octet out shifts everything by one and the parser reads the version
  # as a parameter type, which is a confusing way to fail.
  def open_with(params_hex)
    n = params_hex.size / 2
    'ff' * 16 + ('%04x' % (19 + 10 + n)) + '01' +
      '04' + '0064' + '00b4' + '0a000001' + ('%02x' % n) + params_hex
  end

  # The IANA "BGP OPEN Optional Parameter Types" registry has 0 Reserved,
  # 1 Authentication (Deprecated, referencing RFC 4271 and RFC 5492), 3 to
  # 254 Unassigned and 255 reserved for the extended length of RFC 9072.
  # Only 2 is implemented, and every other value used to raise and take
  # the parse of the whole OPEN with it. A peer may well send 1, and a
  # negative test wants to send any of them.
  def test_a_parameter_type_bgp4r_cannot_read_is_kept_whole
    { 0 => '000401020000', 1 => '010401020000',
      3 => '030401020000', 254 => 'fe0401020000' }.each do |type, params|
      hex = open_with(params)
      open = BGP::Message.factory([hex].pack('H*'))
      assert_equal hex, open.to_shex, "parameter type #{type} must come back byte for byte"
      assert_equal 1, open.opt_parms.size
      parm = open.opt_parms.first
      assert_instance_of UNKNOWN, parm
      assert_equal type, parm.parm_type
      assert_equal '01020000', parm.value.unpack('H*')[0]
      assert_nil parm.declared_len, 'the length agreed with the octets, so nothing to keep'
    end
  end

  # A parameter with no value octets at all is still a parameter, since
  # the two octet header is all RFC 4271 section 4.2 needs.
  def test_a_parameter_type_bgp4r_cannot_read_with_no_value
    hex = open_with('0100')
    open = BGP::Message.factory([hex].pack('H*'))
    assert_equal hex, open.to_shex
    assert_equal '', open.opt_parms.first.value
    assert_equal({ :type => 1 }, open.opt_parms.first.to_hash,
                 'no value and no disagreeing length means neither key')
  end

  # The other half, and it is not about the type. A Parameter Length
  # longer than the octets behind it cannot be read whatever the type
  # says, so a Capabilities parameter lands here too. This used to slice
  # what was there, find no whole capability in it, and leave nothing: the
  # two octets that arrived were gone and encode wrote an Optional
  # Parameters Length of 0.
  def test_a_parameter_length_longer_than_its_octets_is_kept
    hex = open_with('0209')
    open = BGP::Message.factory([hex].pack('H*'))
    assert_equal hex, open.to_shex, 'the octets that arrived come back'
    parm = open.opt_parms.first
    assert_instance_of UNKNOWN, parm
    assert_equal 2, parm.parm_type, 'the type was Capabilities, and is kept'
    assert_equal '', parm.value
    assert_equal 9, parm.declared_len
    assert_equal({ :type => 2, :length => 9 }, parm.to_hash)
  end

  # The bug that was worse than the recorded one: an unreadable parameter
  # raised, so it took the readable parameters with it, including any that
  # had already been parsed.
  def test_a_parameter_bgp4r_cannot_read_does_not_stop_the_ones_around_it
    as4 = '020641040000fde8'
    unknown = '030400000000'
    [as4 + unknown, unknown + as4].each do |params|
      hex = open_with(params)
      open = BGP::Message.factory([hex].pack('H*'))
      assert_equal hex, open.to_shex
      assert_equal 2, open.opt_parms.size
      assert open.has?(BGP::OPT_PARM::CAP::As4),
             "the 4-octet AS capability must still be read, in #{params}"
      assert_equal 1, open.opt_parms.count { |p| p.is_a?(UNKNOWN) }
    end
  end

  def test_unknown_optional_parameter_builds_three_ways
    value = ['01020000'].pack('H*')
    from_values = UNKNOWN.new(1, value)
    from_hash = UNKNOWN.new(:type => 1, :value => '01020000')
    from_wire = UNKNOWN.new(from_values.encode.is_packed)
    assert_equal '010401020000', from_values.encode.unpack('H*')[0]
    assert_equal from_values.encode, from_hash.encode
    assert_equal from_values.encode, from_wire.encode
    assert_equal from_values.to_hash, from_wire.to_hash
    # And a copy of one, which is the fourth way the other classes take.
    assert_equal from_values.encode, UNKNOWN.new(from_values).encode
  end

  # RFC 9072 section 2, Figure 2: in the extended form the Parameter
  # Length is two octets. The width belongs to the enclosing OPEN, so it
  # is told to the parameter rather than guessed from the octets.
  def test_an_unknown_parameter_in_the_extended_form
    wire = ['03' + '0004' + '01020000'].pack('H*').is_packed
    parm = UNKNOWN.new(wire, true)
    assert_equal 3, parm.parm_type
    assert_equal '01020000', parm.value.unpack('H*')[0]
    assert_nil parm.declared_len
    assert_equal wire, parm.encode(:extended => true)
    # Read as the RFC 4271 form the same octets say something else, which
    # is why the form is not a property of the parameter.
    assert_equal 0, UNKNOWN.new(wire).declared_len.to_i
  end

  def test_unknown_optional_parameter_refuses_what_it_cannot_represent
    assert_raise(ArgumentError) { UNKNOWN.new(:nope) }
    assert_raise(ArgumentError) { UNKNOWN.new }
  end

  # Open#to_s walks every parameter, so this has to work or printing a
  # captured OPEN raises instead of showing it.
  def test_unknown_optional_parameter_prints
    assert_equal 'Unknown Optional Parameter (1), 4 value octets: [01020000]',
                 UNKNOWN.new(1, ['01020000'].pack('H*')).to_s
    assert_equal 'Unknown Optional Parameter (3), 1 value octet: [ab]',
                 UNKNOWN.new(3, ['ab'].pack('H*')).to_s
    assert_equal 'Unknown Optional Parameter (2), 0 value octets: [], ' \
                 'Parameter Length says 9',
                 UNKNOWN.new(['0209'].pack('H*').is_packed).to_s
    # And through the message that carries it.
    hex = open_with('0209')
    assert_match(/Parameter Length says 9/, BGP::Message.factory([hex].pack('H*')).to_s)
  end

  # Three classes in this namespace are called Unknown, one per level: a
  # parameter bgp4r cannot read, a capability it cannot read, and the
  # CAP alias of the second. They must stay three.
  #
  # Adding the first one broke the second, because capability.rb guards
  # its definition with `unless const_defined? :Unknown` and
  # Module#const_defined? searches the ancestors unless told not to.
  # Capability is a subclass of Optional_parameter, so the guard went
  # true, Capability::Unknown was never defined, and every reference to
  # it resolved up the chain to the parameter level class. Three tests in
  # two other files failed and none of them mentioned a constant.
  def test_the_three_unknown_classes_are_distinct
    unknowns = [BGP::OPT_PARM::Optional_parameter::Unknown,
                BGP::OPT_PARM::Capability::Unknown,
                BGP::OPT_PARM::CAP::Unknown]
    assert_equal 3, unknowns.uniq.size, unknowns.collect(&:name).inspect
    assert_equal BGP::OPT_PARM::Optional_parameter,
                 BGP::OPT_PARM::Optional_parameter::Unknown.superclass
    # The capability level one is a Capability, which is what tells it
    # apart: its hash is keyed on :code, where the parameter level one
    # is keyed on :type.
    assert BGP::OPT_PARM::Capability::Unknown.ancestors
             .include?(BGP::OPT_PARM::Capability)
  end
end
