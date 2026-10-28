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
end
