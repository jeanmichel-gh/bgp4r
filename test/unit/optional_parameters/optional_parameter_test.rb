#--
# Copyright 2010 Jean-Michel Esnault.
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
  def test_draft_ietf_idr_ext_opt_param_01_encoding
    octet = ''
    def octet.encode
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
  def test_draft_ietf_idr_ext_opt_param_01_parsing
    mbgp = OPT_PARM::CAP::Mbgp.new(1,1)
    open1 = Open.new(4, 100, 120, '1.1.1.1', *[mbgp]*100)
    open2 = Open.new(4, 100, 120, '1.1.1.1', *[mbgp]*10)
    assert_match(/^(ff){16}034001040064007801010101\s*ffff0320\s*0206010400010001/, open1.to_shex)
    assert_match(/^(ff){16}006d01040064007801010101\s*50\s*0206010400010001/, open2.to_shex)
    assert_equal Open.new(open1).to_shex, open1.to_shex
    assert_equal Open.new(open2).to_shex, open2.to_shex
  end
end
